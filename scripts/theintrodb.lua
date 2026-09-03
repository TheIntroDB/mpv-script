-- theintrodb.lua - Skip intros, recaps, credits & previews using TheIntroDB
--
-- Fetches segment timestamps for the currently playing movie / TV episode from
-- the TheIntroDB API (https://api.theintrodb.org/v3/media) and provides:
--   * keybindings to skip each segment type
--   * a clickable on-screen button bar (toggle with theintrodb-toggle-ui)
--   * optional auto-skip of intros & recaps (toggle with theintrodb-auto-skip)
--
-- Identification: a TMDB ID (or IMDB ID) is read from the filename
--   tmdb-12345, tmdb_12345, tmdb12345, tt0123456, or from the
--   `theintrodb-tmdb_id` / `theintrodb-imdb_id` script options
--   (mpv --script-opts=theintrodb-tmdb_id=12345 ...).
-- TV episodes need season/episode: parsed from the filename (S01E02 or 1x02),
-- or set via script options.
--
-- Config: script-opts/theintrodb.conf  (see theintrodb.conf.example)
--
-- License: MIT

local utils = require "mp.utils"

-- ---------------------------------------------------------------------------
-- defaults (overridable via script-opts/theintrodb.conf)
-- ---------------------------------------------------------------------------
local o = {
    api_url = "https://api.theintrodb.org/v3/media",
    api_key = "",            -- optional Bearer key; include to see your pending submissions
    tmdb_api_key = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiI1NzlkZWYyZDY5ZWFlNDk4ZjJiOTI4MTgyNDdjM2ViMCIsInN1YiI6IjY2MjdmMGJlNjJmMzM1MDE0YmQ4NTFmMiIsInNjb3BlcyI6WyJhcGlfcmVhZCJdLCJ2ZXJzaW9uIjoxfQ.h3KpPvkiaz8uNz1bntAKqsPrxG_4UUWaY3kYME6N6m8",
    auto_detect = "yes",     -- when no id is given, look the media up on TMDB from the filename
    tmdb_id = "",            -- manual override
    imdb_id = "",            -- manual override (fallback when no tmdb_id)
    season = "",             -- manual override for TV
    episode = "",            -- manual override for TV
    duration_ms = "",        -- optional video duration to pick a release version
    auto_skip = "no",        -- auto-skip intro & recap segments
    auto_skip_types = "intro,recap",
    key_skip_intro = "Alt+i",
    key_skip_recap = "Alt+r",
    key_skip_credits = "Alt+c",
    key_skip_preview = "",
    key_skip_next = "n",
    key_toggle_ui = "Ctrl+i",
    key_toggle_auto_skip = "Alt+a",
    mouse_buttons = "yes",   -- clickable on-screen button bar
    show_osd = "yes",        -- OSD notifications on skip / load
    retry_secs = "5",        -- base delay before retrying a failed fetch (doubles)
    max_retries = "4",
}

local function read_opts()
    local prefix = "theintrodb-"
    for name, _ in pairs(o) do
        local v = mp.get_opt(prefix .. name)
        if v ~= nil then
            local cur = o[name]
            if type(cur) == "number" then
                o[name] = tonumber(v) or cur
            elseif type(cur) == "boolean" then
                o[name] = v == "yes" or v == "true" or v == "1"
            else
                o[name] = tostring(v)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------
local tidb = {
    media = nil,          -- parsed API response
    segments = {},        -- flat list: {kind=, start=, end=} in seconds
    segments_by_kind = { intro = {}, recap = {}, credits = {}, preview = {} },
    file_key = nil,       -- filename (cache key)
    identified = false,
    loaded = false,       -- data fetched for current file
    none_msg_shown = false,
    ui_visible = false,
    auto_skip = false,
    overlay_timer = nil,
    hide_timer = nil,
    mouse_pos = { x = -1, y = -1 },
    buttons = {},         -- {kind=, start=, end=, x0=, x1=, y0=, y1=}
    retry_timer = nil,
    retry_count = 0,
    last_fetch_error = nil,
    cache = {},           -- file_key -> media table (TheIntroDB responses)
    tmdb_cache = {},      -- file_key -> tmdb_id (auto-detect results)
    api_timer = nil,
    seek_grace_until = 0, -- skip grace after a manual seek
    hint_shown = false,
}

-- forward declarations (defined later in the file; Lua locals are not hoisted)
local build_segments, hide_overlay, update_overlay, on_mouse_left_click, show_overlay
local schedule_retry, fetch_media

local function log(...)
    mp.msg.log("info", string.format(...))
end

local function fmt_time(secs)
    if secs == nil then return "?" end
    local s = math.floor(secs + 0.5)
    if s < 0 then s = 0 end
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    local sec = s % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, sec)
    end
    return string.format("%d:%02d", m, sec)
end

-- ---------------------------------------------------------------------------
-- identification: tmdb/imdb id + season/episode from filename & options
-- ---------------------------------------------------------------------------
-- split a comma-separated list, trimmed ("intro, recap" -> {"intro","recap"})
local function split_csv(s)
    local out = {}
    for part in string.gmatch(s or "", "[^,]+") do
        local p = part:gsub("^%s+", ""):gsub("%s+$", "")
        if p ~= "" then out[#out + 1] = p end
    end
    return out
end

-- returns season, episode or nil,nil
local function split_season_episode(s)
    local se, ep = string.match(s, "[Ss]%s*(%d+)%s*[Ee]%s*(%d+)")
    if not se then
        se, ep = string.match(s, "(%d+)%s*[xX]%s*(%d+)")
    end
    if not se then
        se, ep = string.match(s, "[Ss]eason%s+(%d+)%s+[Ee]pisode%s+(%d+)")
    end
    return se, ep
end

local function identify(path)
    local tmdb_id = o.tmdb_id
    local imdb_id = o.imdb_id
    local season, episode = o.season, o.episode

    local base = path or ""
    if tmdb_id == "" then
        tmdb_id = string.match(base, "[Tt][Mm][Dd][Bb][%s_%-%.]*(%d+)")
    end
    if imdb_id == "" then
        imdb_id = string.match(base, "tt%d%d%d%d%d%d%d%d?")
    end
    if season == "" or episode == "" then
        local se, ep = split_season_episode(base)
        if se then
            if season == "" then season = tostring(tonumber(se)) end
            if episode == "" then episode = tostring(tonumber(ep)) end
        end
    end
    -- normalize: empty strings become nil so callers can check truthiness
    if tmdb_id == "" then tmdb_id = nil end
    if imdb_id == "" then imdb_id = nil end
    if season == "" then season = nil end
    if episode == "" then episode = nil end
    return tmdb_id, imdb_id, season, episode
end

-- ---------------------------------------------------------------------------
-- API fetch (curl subprocess, cached per file, rate-limit retry with backoff)
-- ---------------------------------------------------------------------------
local function api_url(tmdb_id, imdb_id, season, episode, duration_ms)
    local params = {}
    if tmdb_id then
        params[#params + 1] = "tmdb_id=" .. tostring(tmdb_id)
    elseif imdb_id then
        params[#params + 1] = "imdb_id=" .. tostring(imdb_id)
    end
    if season and episode then
        params[#params + 1] = "season=" .. tostring(season)
        params[#params + 1] = "episode=" .. tostring(episode)
    end
    if duration_ms and duration_ms ~= "" then
        params[#params + 1] = "duration_ms=" .. tostring(duration_ms)
    end
    return o.api_url .. "?" .. table.concat(params, "&")
end

local function on_fetch_result(status, stdout, file_key, tmdb_id, imdb_id)
    if file_key ~= tidb.file_key then return end -- stale (file changed while fetching)
    tidb.retry_timer = nil
    if status ~= 0 then
        tidb.last_fetch_error = "curl exit " .. tostring(status)
        schedule_retry(file_key, tmdb_id, imdb_id)
        return
    end
    -- parse "HTTP<code>BODY" response
    local http_code = tonumber(string.match(stdout or "", "^HTTP(%d+)")) or 0
    local body = string.match(stdout or "", "^HTTP%d+(.*)$") or ""
    if http_code == 429 then
        tidb.last_fetch_error = "rate limited (429)"
        schedule_retry(file_key, tmdb_id, imdb_id)
        return
    end
    if http_code == 404 or http_code == 400 then
        tidb.media = nil
        tidb.loaded = true
        tidb.retry_count = 0
        if o.show_osd == "yes" then
            mp.osd_message("TheIntroDB: no data found for this media", 2.5)
        end
        return
    end
    if http_code ~= 200 then
        tidb.last_fetch_error = "HTTP " .. tostring(http_code)
        schedule_retry(file_key, tmdb_id, imdb_id)
        return
    end
    local ok, data = pcall(utils.parse_json, body)
    if not ok or data == nil then
        tidb.last_fetch_error = "invalid JSON"
        schedule_retry(file_key, tmdb_id, imdb_id)
        return
    end
    tidb.retry_count = 0
    tidb.media = data
    tidb.loaded = true
    tidb.cache[file_key] = data
    build_segments(data)
    if o.show_osd == "yes" then
        local count = #tidb.segments
        if count == 0 then
            mp.osd_message("TheIntroDB: no segments for this media", 2)
        else
            mp.osd_message(
                string.format("TheIntroDB: %d segment(s) loaded", count), 1.5)
        end
    end
end

schedule_retry = function(file_key, tmdb_id, imdb_id)
    if file_key ~= tidb.file_key then return end
    if tidb.retry_count >= tonumber(o.max_retries) then
        tidb.last_fetch_error = nil
        if o.show_osd == "yes" then
            mp.osd_message("TheIntroDB: fetch failed, giving up", 2.5)
        end
        return
    end
    tidb.retry_count = tidb.retry_count + 1
    local delay = tonumber(o.retry_secs) * (2 ^ (tidb.retry_count - 1))
    log("fetch failed (%s), retrying in %ds", tidb.last_fetch_error, delay)
    tidb.retry_timer = mp.add_timeout(delay, function()
        tidb.retry_timer = nil
        fetch_media(file_key, tmdb_id, imdb_id)
    end)
end

fetch_media = function(file_key, tmdb_id, imdb_id)
    if file_key ~= tidb.file_key then return end
    if tidb.cache[file_key] then
        tidb.media = tidb.cache[file_key]
        tidb.loaded = true
        build_segments(tidb.media)
        return
    end
    local url = api_url(tmdb_id, imdb_id, tidb.season, tidb.episode, o.duration_ms)
    local args = {
        "curl", "-s", "--max-time", "10", "-w", "HTTP%{http_code}",
    }
    if o.api_key ~= "" then
        args[#args + 1] = "-H"
        args[#args + 1] = "Authorization: Bearer " .. o.api_key
    end
    args[#args + 1] = url
    mp.command_native_async({ name = "subprocess", args = args, capture_stdout = true },
        function(success, res)
            if not success or not res then
                on_fetch_result(1, nil, file_key, tmdb_id, imdb_id)
                return
            end
            on_fetch_result(res.status or 0, res.stdout or "", file_key, tmdb_id, imdb_id)
        end)
end

-- ---------------------------------------------------------------------------
-- segment handling
-- ---------------------------------------------------------------------------
build_segments = function(data)
    local duration = mp.get_property_number("duration") or 0
    tidb.segments = {}
    for _, kind in ipairs({ "intro", "recap", "credits", "preview" }) do
        tidb.segments_by_kind[kind] = {}
        local list = data[kind]
        if type(list) == "table" then
            for _, seg in ipairs(list) do
                if type(seg) == "table" then
                    local start_ms = seg.start_ms
                    local end_ms = seg["end_ms"]
                    -- 0-length => "no segment"
                    if start_ms == 0 and end_ms == 0 then
                        -- skip
                    elseif end_ms == nil or end_ms == 0 then
                        -- end of media
                        if start_ms ~= nil and start_ms > 0 then
                            tidb.segments[#tidb.segments + 1] = {
                                kind = kind, start = start_ms / 1000, ["end"] = nil,
                            }
                        end
                    else
                        local start = (start_ms or 0) / 1000
                        local fin = end_ms / 1000
                        -- clamp end to duration
                        if duration > 0 and fin > duration then fin = duration end
                        tidb.segments[#tidb.segments + 1] = {
                            kind = kind, start = start, ["end"] = fin,
                        }
                    end
                end
            end
        end
    end
    table.sort(tidb.segments, function(a, b)
        local as = a.start or 0
        local bs = b.start or 0
        if as == bs then
            local ae = a["end"] or math.huge
            local be = b["end"] or math.huge
            return ae < be
        end
        return as < bs
    end)
    for _, seg in ipairs(tidb.segments) do
        tidb.segments_by_kind[seg.kind][#tidb.segments_by_kind[seg.kind] + 1] = seg
    end
    hide_overlay()
    update_overlay()
end

local function segment_contains(seg, pos)
    local s = seg.start or 0
    local e = seg["end"] or math.huge
    return pos >= s and (e == math.huge or pos <= e)
end

local function current_segment(pos)
    for _, seg in ipairs(tidb.segments) do
        if segment_contains(seg, pos) then return seg end
    end
    return nil
end

local function next_segment_after(pos)
    local best = nil
    for _, seg in ipairs(tidb.segments) do
        local s = seg.start or 0
        if s > pos then
            if best == nil or s < (best.start or 0) then best = seg end
        end
    end
    return best
end

local function duration()
    return mp.get_property_number("duration") or 0
end

local function do_skip(seg, via_ui)
    if seg == nil then return false end
    local target = seg["end"]
    if target == nil or target == math.huge then
        target = duration()
    end
    -- don't skip "to" a position we're already past
    local pos = mp.get_property_number("time-pos") or 0
    if target <= pos then return false end
    -- land just before EOF if the segment runs to the end
    local max = duration()
    if max > 0 and target >= max - 0.2 then
        target = math.max(0, max - 0.1)
    end
    mp.set_property("pause", "no")
    mp.commandv("seek", tostring(target), "absolute", "exact")
    tidb.seek_grace_until = mp.get_time() + 1.5
    if o.show_osd == "yes" then
        local label = seg.kind:sub(1, 1):upper() .. seg.kind:sub(2)
        if seg["end"] == nil or seg["end"] == math.huge then
            mp.osd_message(string.format("Skipped %s → end", label), 1.2)
        else
            mp.osd_message(
                string.format("Skipped %s → %s", label, fmt_time(seg["end"])), 1.2)
        end
    end
    return true
end

local function skip_kind(kind)
    local pos = mp.get_property_number("time-pos") or 0
    -- try to find a segment of this kind that contains the position
    for _, seg in ipairs(tidb.segments_by_kind[kind]) do
        if segment_contains(seg, pos) then
            if do_skip(seg, false) then return end
        end
    end
    -- else next upcoming segment of this kind
    local next_seg = nil
    for _, seg in ipairs(tidb.segments_by_kind[kind]) do
        local s = seg.start or 0
        if s > pos then
            if next_seg == nil or s < (next_seg.start or 0) then next_seg = seg end
        end
    end
    if next_seg then
        do_skip(next_seg, false)
        return
    end
    if o.show_osd == "yes" then
        mp.osd_message("TheIntroDB: no " .. kind .. " segment", 1.5)
    end
end

local function skip_next()
    local pos = mp.get_property_number("time-pos") or 0
    local seg = current_segment(pos)
    if seg and seg["end"] then
        if do_skip(seg, false) then return end
    end
    local nxt = next_segment_after(pos)
    if nxt then
        do_skip(nxt, false)
        return
    end
    if o.show_osd == "yes" then
        mp.osd_message("TheIntroDB: nothing to skip", 1.5)
    end
end

-- ---------------------------------------------------------------------------
-- auto-skip (intro/recap by default)
-- ---------------------------------------------------------------------------
local auto_skip_timer = nil

local function auto_skip_tick()
    if not tidb.auto_skip then return end
    local paused = mp.get_property_bool("pause")
    if paused then return end
    local pos = mp.get_property_number("time-pos")
    if pos == nil then return end
    if mp.get_time() < tidb.seek_grace_until then return end
    -- only seek forward, never fight the user
    local seg = current_segment(pos)
    if seg == nil then return end
    local want = {}
    for _, kind in ipairs(split_csv(o.auto_skip_types)) do
        want[kind] = true
    end
    if not want[seg.kind] then return end
    if seg["end"] == nil or seg["end"] == math.huge then return end -- don't auto-skip to EOF
    do_skip(seg, false)
end

local function start_auto_skip_timer()
    if auto_skip_timer then
        auto_skip_timer:kill()
        auto_skip_timer = nil
    end
    auto_skip_timer = mp.add_periodic_timer(0.4, auto_skip_tick)
end

local function toggle_auto_skip()
    tidb.auto_skip = not tidb.auto_skip
    if tidb.auto_skip then
        start_auto_skip_timer()
        mp.osd_message("TheIntroDB: auto-skip ON", 1.2)
    else
        if auto_skip_timer then auto_skip_timer:kill() end
        auto_skip_timer = nil
        mp.osd_message("TheIntroDB: auto-skip OFF", 1.2)
    end
end

-- ---------------------------------------------------------------------------
-- on-screen button bar (ASS overlay, clickable)
-- ---------------------------------------------------------------------------
local function button_style(kind)
    local colors = {
        intro   = "&H00FFFF&", -- yellow
        recap   = "&HFFFF00&", -- cyan
        credits = "&H00FF00&", -- green
        preview = "&HFF00FF&", -- magenta
    }
    return colors[kind] or "&HFFFFFF&"
end

local function fmt_seg_label(seg)
    local s = fmt_time(seg.start)
    local e = (seg["end"] == nil or seg["end"] == math.huge) and "END" or fmt_time(seg["end"])
    return string.format("%s %s→%s", seg.kind, s, e)
end

local function build_overlay()
    if not tidb.ui_visible then
        mp.set_osd_ass(0, 0, "")
        return
    end
    if #tidb.segments == 0 then
        mp.set_osd_ass(0, 0, "")
        return
    end
    local sw, sh = mp.get_osd_size()
    if sw == nil or sw == 0 then return end
    local bheight = 26
    local gap = 6
    local labels = {}
    local widths = {}
    local total = 0
    for i, seg in ipairs(tidb.segments) do
        local label = fmt_seg_label(seg)
        labels[i] = label
        -- rough width estimate: 0.55 * chars * fontsize
        widths[i] = math.ceil(#label * 0.58 * bheight * 0.75) + 24
        total = total + widths[i] + gap
    end
    total = total - gap
    local x0 = (sw - total) / 2
    local y0 = sh - 50
    tidb.buttons = {}
    local ass = {}
    ass[#ass + 1] = "[Script Info]\nScriptType: v4.00+\nPlayResX: " .. sw .. "\nPlayResY: " .. sh .. "\n"
    local cx = x0
    for i, seg in ipairs(tidb.segments) do
        local w = widths[i]
        local color = button_style(seg.kind)
        ass[#ass + 1] = string.format(
            "{\\an2\\pos(%d,%d)\\bord0\\shad0\\blur1\\1c%s\\3c%s\\alpha&H50&}",
            math.floor(cx + w / 2), math.floor(y0), color, color)
        ass[#ass + 1] = string.format("{\\r}{\\an2\\pos(%d,%d)\\bord0.6\\shad0\\1c&H000000&\\alpha&H00&}%s{\\r}",
            math.floor(cx + w / 2), math.floor(y0), labels[i])
        tidb.buttons[#tidb.buttons + 1] = {
            kind = seg.kind, start = seg.start, fin = seg["end"],
            x0 = cx, x1 = cx + w, y0 = y0 - bheight, y1 = y0 + bheight,
        }
        cx = cx + w + gap
    end
    mp.set_osd_ass(0, 0, table.concat(ass, "\n"))
end

update_overlay = function()
    if tidb.ui_visible then build_overlay() end
end

local function remove_mouse_bindings()
    if o.mouse_buttons == "yes" then
        mp.remove_key_binding("theintrodb-mouse-left")
        mp.remove_key_binding("theintrodb-mouse-right")
    end
end

show_overlay = function()
    tidb.ui_visible = true
    if o.mouse_buttons == "yes" then
        mp.add_key_binding("MBTN_LEFT", "theintrodb-mouse-left", on_mouse_left_click)
        mp.add_key_binding("MBTN_RIGHT", "theintrodb-mouse-right", on_mouse_left_click)
    end
    build_overlay()
    -- auto-hide: remove click bindings too, so invisible buttons never intercept
    if tidb.hide_timer then tidb.hide_timer:kill() end
    tidb.hide_timer = mp.add_timeout(4.0, function()
        tidb.hide_timer = nil
        if tidb.ui_visible then
            tidb.ui_visible = false
            remove_mouse_bindings()
            mp.set_osd_ass(0, 0, "")
        end
    end)
end

hide_overlay = function()
    tidb.ui_visible = false
    remove_mouse_bindings()
    if tidb.hide_timer then tidb.hide_timer:kill() end
    tidb.hide_timer = nil
    mp.set_osd_ass(0, 0, "")
end

local function toggle_overlay()
    if tidb.ui_visible then
        hide_overlay()
    else
        show_overlay()
    end
end

local function button_at(x, y)
    if x == nil or y == nil then return nil end
    for _, b in ipairs(tidb.buttons) do
        if x >= b.x0 and x <= b.x1 and y >= b.y0 and y <= b.y1 then
            return b
        end
    end
    return nil
end

local function on_mouse_move(e)
    if e and e.x then tidb.mouse_pos = { x = e.x, y = e.y } end
    if button_at(tidb.mouse_pos.x, tidb.mouse_pos.y) then
        show_overlay()
    end
end

on_mouse_left_click = function(e)
    local b = button_at(e.x or tidb.mouse_pos.x, e.y or tidb.mouse_pos.y)
    if b then
        -- build a fake seg
        local seg = { kind = b.kind, start = b.start, ["end"] = b.fin }
        do_skip(seg, true)
    end
end

-- ---------------------------------------------------------------------------
-- auto-detection: resolve a TMDB id from the filename via TMDB search
-- ---------------------------------------------------------------------------
local function urlencode(s)
    s = tostring(s)
    s = s:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return s
end

-- returns title, year, is_tv, ep_hint (episode number parsed from the
-- filename when it used "Show - 01" / "Show E02" style naming)
local function parse_title_for_search(filename)
    local base = filename:gsub("%.[%w]+$", "")  -- strip extension

    local t = base
    t = t:gsub("%[[^%]]*%]", " ")               -- [group] tags
    t = t:gsub("[._]", " ")                     -- separators
    t = t:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    -- find the earliest "metadata" cut point: the title ends there
    local cut_pos = nil
    local is_tv = false
    local ep_hint = nil

    local function consider(pos, tv, ep)
        if pos and (cut_pos == nil or pos < cut_pos) then
            cut_pos = pos
            if tv then is_tv = true end
            if ep then ep_hint = ep end
        end
    end

    -- TV markers (highest priority)
    local i = t:find("[Ss]%d+[Ee]%d+")
    consider(i, true)
    i = t:find("%d+[xX]%d+")
    consider(i, true)
    local i2, _, e2 = t:find("%s%-%s(%d+)")     -- "Show - 01"
    consider(i2, true, e2)
    i2, _, e2 = t:find("%s[Ee](%d+)")            -- "Show E02"
    consider(i2, true, e2)

    -- year: the last plausible 4-digit group (title digits come first,
    -- the release year comes last, before the technical suffix)
    local year, year_pos
    for p, y in t:gmatch("()(%d%d%d%d)") do
        local yv = tonumber(y)
        if yv and yv >= 1900 and yv <= 2100 then
            year, year_pos = y, p
        end
    end
    if year_pos then
        local before = t:sub(1, year_pos - 1):gsub("%s+", "")
        if before == "" then
            year = nil  -- numeric title ("1917.1080p"): digits are the title
        elseif year_pos > 1 then
            consider(year_pos, false)
        end
    end

    -- first technical marker (resolution / source / codec)
    local tl = t:lower()
    local tech = { "1080p", "720p", "2160p", "480p", "4k", "web%-dl",
        "webrip", "bluray", "hdtv", "x264", "x265", "hevc", "h264", "h265",
        "aac", "ac3", "dts" }
    for _, pat in ipairs(tech) do
        local ti = tl:find(pat)
        if ti then
            consider(ti, false)
            break  -- only the first marker matters
        end
    end

    if cut_pos then
        t = t:sub(1, cut_pos - 1)
    end

    -- clean leftovers; keep pure-digit words ("1917") as the title
    -- only when nothing else survived the cut
    local out, digit_out = {}, {}
    for w in t:gmatch("%S+") do
        local wl = w:lower():gsub("[^%w%.]", "")
        if wl ~= "" and not wl:match("^%d+$") then
            out[#out + 1] = w
        else
            digit_out[#digit_out + 1] = w
        end
    end
    t = table.concat(out, " ")
    if t == "" then
        t = table.concat(digit_out, " ")
    end
    return t, year, is_tv, ep_hint
end

-- async TMDB search; calls cb(tmdb_id or nil)
local function tmdb_search(title, year, is_tv, cb)
    if o.tmdb_api_key == "" then cb(nil) return end
    local endpoint = is_tv and "/search/tv" or "/search/movie"
    local url = "https://api.themoviedb.org/3" .. endpoint
        .. "?query=" .. urlencode(title)
        .. "&language=en-US"
    if year then
        url = url .. (is_tv and "&first_air_date_year=" or "&year=") .. year
    end
    -- note: the key is sent ONLY as a Bearer header (TMDB v4 JWTs are not
    -- accepted via the api_key query parameter)
    local args = {
        "curl", "-s", "--max-time", "10",
        "-H", "Authorization: Bearer " .. o.tmdb_api_key,
        url,
    }
    mp.command_native_async({ name = "subprocess", args = args, capture_stdout = true },
        function(success, res)
            if not success or not res or res.status ~= 0 then cb(nil) return end
            local ok, data = pcall(utils.parse_json, res.stdout or "")
            if not ok or not data or not data.results or #data.results == 0 then
                cb(nil)
                return
            end
            -- prefer a result matching the year, else the top hit
            local best = data.results[1]
            if year then
                for _, r in ipairs(data.results) do
                    local d = r.release_date or r.first_air_date or ""
                    if d:sub(1, 4) == year then best = r break end
                end
            end
            cb(best.id)
        end)
end

-- called when no explicit id was found: guess title, search TMDB, then fetch
local function auto_detect(file_key, filename)
    if tidb.tmdb_cache[file_key] then
        local cached = tidb.tmdb_cache[file_key]
        if cached and cached ~= "" then
            fetch_media(file_key, cached, nil)
        end
        return
    end
    local title, year, is_tv, ep_hint = parse_title_for_search(filename)
    if not title or title == "" then
        mp.osd_message("TheIntroDB: could not parse a title from the filename", 3)
        return
    end
    if o.show_osd == "yes" then
        mp.osd_message(
            string.format("TheIntroDB: searching TMDB for \"%s\"%s...",
                title, year and (" (" .. year .. ")") or ""), 2)
    end
    tmdb_search(title, year, is_tv, function(id)
        if file_key ~= tidb.file_key then return end  -- stale (file changed)
        tidb.tmdb_cache[file_key] = id or ""
        if id then
            tidb.tmdb_id = tostring(id)
            -- TV with an episode-only filename ("Show - 01"): assume season 1
            if is_tv and (not tidb.season or not tidb.episode) and ep_hint then
                tidb.season = tidb.season or "1"
                tidb.episode = tidb.episode or ep_hint
            end
            if is_tv and (not tidb.season or not tidb.episode) then
                mp.osd_message(
                    string.format("TheIntroDB: found TMDB %d but no season/episode in the filename", id), 3)
                return
            end
            if o.show_osd == "yes" then
                mp.osd_message(string.format("TheIntroDB: matched TMDB %d", id), 1.5)
            end
            fetch_media(file_key, tostring(id), nil)
        else
            mp.osd_message(
                string.format("TheIntroDB: no TMDB match for \"%s\"", title), 3)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- file load lifecycle
-- ---------------------------------------------------------------------------
local function on_file_loaded()
    read_opts()  -- re-read script-opts (they can change per file / reload)
    local path = mp.get_property("path") or ""
    local filename = mp.get_property("filename") or ""
    local file_key = filename
    -- resolve ids for this file
    local tmdb_id, imdb_id, season, episode = identify(filename)
    tidb.file_key = file_key
    tidb.media = nil
    tidb.loaded = false
    tidb.none_msg_shown = false
    tidb.segments = {}
    for _, k in ipairs({ "intro", "recap", "credits", "preview" }) do
        tidb.segments_by_kind[k] = {}
    end
    tidb.buttons = {}
    tidb.retry_count = 0
    -- clear any state carried over from the previous file
    tidb.tmdb_id, tidb.imdb_id, tidb.season, tidb.episode = nil, nil, nil, nil
    if tidb.retry_timer then tidb.retry_timer:kill() end
    tidb.retry_timer = nil
    hide_overlay()

    -- store resolved ids so the fetch uses them
    tidb.tmdb_id = tmdb_id
    tidb.imdb_id = imdb_id
    tidb.season = season
    tidb.episode = episode

    if not tmdb_id and not imdb_id then
        if o.auto_detect == "yes" then
            auto_detect(file_key, filename)
        else
            mp.osd_message("TheIntroDB: no TMDB/IMDB id in filename (see README)", 3.5)
        end
        return
    end
    fetch_media(file_key, tmdb_id, imdb_id)
end

-- ---------------------------------------------------------------------------
-- bindings
-- ---------------------------------------------------------------------------
read_opts()  -- must run before bind() reads o.key_* values

local function bind(keys, name, fn)
    if keys and keys ~= "" then
        mp.add_key_binding(keys, name, fn)
    end
end

bind(o.key_skip_intro, "theintrodb-skip-intro", function() skip_kind("intro") end)
bind(o.key_skip_recap, "theintrodb-skip-recap", function() skip_kind("recap") end)
bind(o.key_skip_credits, "theintrodb-skip-credits", function() skip_kind("credits") end)
bind(o.key_skip_preview, "theintrodb-skip-preview", function() skip_kind("preview") end)
bind(o.key_skip_next, "theintrodb-skip-next", skip_next)
bind(o.key_toggle_ui, "theintrodb-toggle-ui", toggle_overlay)
bind(o.key_toggle_auto_skip, "theintrodb-toggle-auto-skip", toggle_auto_skip)

if o.mouse_buttons == "yes" then
    mp.add_key_binding("MOUSE_MOVE", "theintrodb-mouse-move", on_mouse_move)
    -- MBTN_LEFT/RIGHT are bound dynamically in show_overlay() so they only
    -- intercept clicks while the button bar is on screen (the OSC keeps
    -- working normally otherwise).
end

-- ---------------------------------------------------------------------------
-- init
-- ---------------------------------------------------------------------------
tidb.auto_skip = (o.auto_skip == "yes")
if tidb.auto_skip then
    start_auto_skip_timer()
end

mp.register_event("file-loaded", on_file_loaded)
-- also react to end-file to clean overlay
mp.register_event("end-file", function()
    hide_overlay()
    tidb.file_key = nil
    tidb.media = nil
    tidb.segments = {}
end)

-- debug hook: expose internals for the test harness (no-op in real mpv)
if mp.get_opt("theintrodb-debug") == "yes" then
    _G.__tidb_debug = function() return tidb end
end

log("loaded (TheIntroDB %s)", "1.0.0")
