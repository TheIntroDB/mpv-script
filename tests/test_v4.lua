-- tests/test_v4.lua - the mpv script against a stubbed mpv API.
--
--   lua5.1 tests/test_v4.lua        (run from the repo root; exits non-zero on failure)
--
-- What it pins, and why:
--   * the default endpoint is TheIntroDB API v4. /v2 and /v3 are frozen at
--     GET /media, so a client still pointed at them silently loses everything
--     added since - the bug this guards against re-introducing.
--   * the request the script builds still asks for the media the same way
--     (id + season + episode) and now goes to /v4/media.
--   * a v4 body parses into the same segments as before: v4 keys the response
--     by tvdb_id and no longer echoes tmdb_id, but the segment arrays are
--     unchanged, so the parser must not care which identity came back.
--   * a 429 follows the contract in TheIntroDB/.github
--     docs/rate-limit-contract.md: the wait is the one the API named, and a
--     spent daily budget stops the retries rather than burning all four on
--     requests that cannot succeed until the window rolls over.
--
-- The harness supplies a fake `mp` plus a tiny JSON decoder, because neither
-- exists in a plain Lua interpreter. Nothing here is loaded by mpv itself.

local script_dir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local root = script_dir .. "/.."

local failures = 0
local function check(cond, label, detail)
  if cond then
    print("ok   - " .. label)
  else
    failures = failures + 1
    print("FAIL - " .. label .. (detail and ("\n       " .. tostring(detail)) or ""))
  end
end

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local body = f:read("*a")
  f:close()
  return body
end

-- ---------------------------------------------------------------------------
-- a JSON decoder, only as good as the fixtures below
-- ---------------------------------------------------------------------------
local decode_json

local function skip_ws(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return j + 1
end

decode_json = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local out = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "}" then return out, i + 1 end
    while true do
      local key, value
      key, i = decode_json(s, i)
      i = skip_ws(s, i)
      assert(s:sub(i, i) == ":", "expected : at " .. i)
      value, i = decode_json(s, i + 1)
      out[key] = value
      i = skip_ws(s, i)
      local delim = s:sub(i, i)
      i = i + 1
      if delim == "}" then return out, i end
      assert(delim == ",", "expected , or } at " .. i)
    end
  elseif c == "[" then
    local out = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "]" then return out, i + 1 end
    while true do
      local value
      value, i = decode_json(s, i)
      out[#out + 1] = value
      i = skip_ws(s, i)
      local delim = s:sub(i, i)
      i = i + 1
      if delim == "]" then return out, i end
      assert(delim == ",", "expected , or ] at " .. i)
    end
  elseif c == '"' then
    local out = {}
    i = i + 1
    while true do
      local ch = s:sub(i, i)
      if ch == '"' then return table.concat(out), i + 1 end
      if ch == "\\" then
        local esc = s:sub(i + 1, i + 1)
        out[#out + 1] = ({ n = "\n", t = "\t", r = "\r" })[esc] or esc
        i = i + 2
      else
        out[#out + 1] = ch
        i = i + 1
      end
    end
  elseif s:sub(i, i + 3) == "true" then
    return true, i + 4
  elseif s:sub(i, i + 4) == "false" then
    return false, i + 5
  elseif s:sub(i, i + 3) == "null" then
    return nil, i + 4
  else
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    assert(num, "unexpected character at " .. i .. ": " .. s:sub(i, i + 10))
    return tonumber(num), i + #num
  end
end

-- ---------------------------------------------------------------------------
-- the fake mpv API
-- ---------------------------------------------------------------------------
local opts = { ["theintrodb-debug"] = "yes" }
local props = { duration = 600, pause = false }
local events = {}
local requests = {}          -- every subprocess argv the script issued
local timeouts = {}          -- every delay the script asked mpv to wait, in seconds
local osd = {}               -- every OSD message the script showed
local answer = { code = 200, body = "" }

local function inert_timer()
  return { kill = function() end }
end

mp = {
  get_opt = function(name) return opts[name] end,
  get_property = function(name) return props[name] end,
  get_property_number = function(name)
    local v = props[name]
    return v ~= nil and tonumber(v) or nil
  end,
  get_property_bool = function(name) return props[name] == true end,
  get_time = function() return 0 end,
  set_property = function(name, value) props[name] = value end,
  commandv = function() end,
  osd_message = function(msg) osd[#osd + 1] = msg end,
  set_osd_ass = function() end,
  get_osd_size = function() return 1280, 720 end,
  add_key_binding = function() end,
  remove_key_binding = function() end,
  register_event = function(name, fn) events[name] = fn end,
  add_timeout = function(delay, fn)
    timeouts[#timeouts + 1] = delay
    return inert_timer()
  end,
  add_periodic_timer = function() return inert_timer() end,
  command_native_async = function(o, cb)
    requests[#requests + 1] = o.args
    cb(true, { status = 0, stdout = answer.body .. "\n" .. tostring(answer.code) })
  end,
  msg = { log = function() end },
}

package.preload["mp.utils"] = function()
  return { parse_json = function(s) return select(1, decode_json(s, 1)) end }
end

-- ---------------------------------------------------------------------------
-- the static pin: the shipped default, not any single request
-- ---------------------------------------------------------------------------
local script_src = read_file(root .. "/scripts/theintrodb.lua")
local conf_src = read_file(root .. "/script-opts/theintrodb.conf.example")

check(
  script_src:find('api_url = "https://api.theintrodb.org/v4/media"', 1, true) ~= nil,
  "the script's default api_url is the v4 /media endpoint"
)
check(
  conf_src:find("#api_url=https://api.theintrodb.org/v4/media", 1, true) ~= nil,
  "the shipped conf example documents the v4 endpoint"
)
for _, file in ipairs({ "/scripts/theintrodb.lua", "/script-opts/theintrodb.conf.example", "/README.md" }) do
  check(
    read_file(root .. file):find("api.theintrodb.org/v3", 1, true) == nil,
    file .. " carries no v3 reference"
  )
end

-- ---------------------------------------------------------------------------
-- the request, and the v4 body
-- ---------------------------------------------------------------------------
assert(loadfile(root .. "/scripts/theintrodb.lua"))()

check(events["file-loaded"] ~= nil, "the script registers a file-loaded handler")

props.filename = "Some.Show.S01E02.1080p.tmdb-615.mkv"
props.path = "/tv/" .. props.filename
props.url = "file:///tv/" .. props.filename

-- a v4 body for the same episode TheIntroDB answers for Futurama tmdb_id=615
answer = {
  code = 200,
  body = '{"tvdb_id":73871,"type":"tv","season":1,"episode":2,'
    .. '"intro":[{"start_ms":null,"end_ms":14600}],'
    .. '"credits":[{"start_ms":1267233,"end_ms":null}]}',
}

events["file-loaded"]()

check(#requests == 1, "one request was issued for the file", "got " .. #requests)
local args = requests[1]
local url = args and args[#args] or ""

check(
  url:match("^https://api%.theintrodb%.org/v4/media%?") ~= nil,
  "the request goes to /v4/media",
  url
)
check(url:find("tmdb_id=615", 1, true) ~= nil, "the request names the media", url)
check(
  url:find("season=1", 1, true) ~= nil and url:find("episode=2", 1, true) ~= nil,
  "the request carries season and episode",
  url
)

local state = _G.__tidb_debug()
check(state ~= nil, "the debug hook is exposed")
local segments = state and state.segments or {}

check(#segments == 2, "the v4 body parsed into two segments", "got " .. #segments)
check(
  segments[1] and segments[1].kind == "intro" and segments[1].start == 0 and segments[1]["end"] == 14.6,
  "the intro parses with a null start as 0:00 and a 14.6s end",
  segments[1] and string.format("%s %s->%s", segments[1].kind, tostring(segments[1].start), tostring(segments[1]["end"]))
)
check(
  segments[2] and segments[2].kind == "credits" and segments[2]["end"] == nil
    and math.abs(segments[2].start - 1267.233) < 0.001,
  "the credits segment keeps its null end (runs to the end of the media)",
  segments[2] and string.format("%s %s->%s", segments[2].kind, tostring(segments[2].start), tostring(segments[2]["end"]))
)

-- ---------------------------------------------------------------------------
-- the 429 contract (TheIntroDB/.github docs/rate-limit-contract.md):
-- wait what the API named, and never spend a budget that is already gone
-- ---------------------------------------------------------------------------

local function scenario(code, body, filename)
  -- each case starts outside a limit, with nothing recorded
  state.limited_until = nil
  state.limited_targets = {}
  state.retry_count = 0
  timeouts, osd, requests = {}, {}, {}
  props.filename = filename or "Show.S01E03.tmdb-615.mkv"
  props.path = "/tv/" .. props.filename
  props.url = "file:///tv/" .. props.filename
  answer = { code = code, body = body }
  events["file-loaded"]()
end

local delays = function() return table.concat(timeouts, ",") end

-- the payload a live burst 429 actually returns
scenario(429, '{"code":"rate_limit_exceeded","error":"Too many requests",'
  .. '"retry_after":"10 seconds","retry_after_seconds":10}')
check(
  #timeouts == 1 and timeouts[1] == 10,
  "a burst 429 waits the 10s the body names, not the script's 5s backoff",
  "delays: " .. delays()
)
check(state.retry_count == 1, "the burst retry counts against max_retries")

-- a spent daily budget: no retry at all, and the user is told
scenario(429, '{"code":"usage_limit_exceeded","error":"Usage limit exceeded",'
  .. '"retry_after":"14.0 hours","retry_after_seconds":50321}')
check(
  #timeouts == 0,
  "a spent daily budget schedules no retry at all",
  "delays: " .. delays()
)
check(
  state.limited_until ~= nil and state.limited_until > os.time(),
  "the state records when the limit lifts"
)
check(
  #osd == 1 and osd[1]:find("daily limit reached", 1, true) ~= nil
    and osd[1]:find("h", 1, true) ~= nil,
  "the user is told the budget is spent and roughly when it returns",
  osd[1]
)
check(
  state.retry_count == 0,
  "a spent budget does not accumulate retries on the way to giving up"
)

-- the per-title budget is the same kind of limit, but scoped to its title
scenario(429, '{"code":"specific_media_usage_limit_exceeded",'
  .. '"error":"Specific media usage limit exceeded","retry_after_seconds":43200}')
check(#timeouts == 0, "the per-title budget stops rather than retrying", delays())
check(state.limited_until == nil, "and does not hold the whole account")
check(next(state.limited_targets) ~= nil, "it is held against the media target")

-- the episode that spent it is not asked for again...
requests = {}
events["file-loaded"]()
check(
  #requests == 0,
  "the spent episode is not asked for again",
  "requests: " .. #requests
)

-- ...but the next episode is, because the limit was that title's, not the account's
answer = { code = 200, body = '{"tvdb_id":73871,"intro":[{"start_ms":1000,"end_ms":5000}]}' }
props.filename = "Show.S01E04.tmdb-615.mkv"
props.path = "/tv/" .. props.filename
props.url = "file:///tv/" .. props.filename
requests = {}
events["file-loaded"]()
check(
  #requests == 1,
  "but the next episode is still asked for",
  "requests: " .. #requests
)

-- with no code at all, the size of the wait decides, at the 300s line
scenario(429, '{"error":"slow down","retry_after_seconds":3600}')
check(#timeouts == 0, "without a code, an hour-long wait reads as a daily budget", delays())
scenario(429, '{"error":"slow down","retry_after_seconds":120}')
check(
  #timeouts == 1 and timeouts[1] == 120,
  "without a code, a two-minute wait reads as a burst and is waited out",
  delays()
)

-- a body we cannot read keeps the script's own backoff rather than guessing
scenario(429, "<html><body>429 Too Many Requests</body></html>")
check(
  #timeouts == 1 and timeouts[1] == 5,
  "an unreadable 429 body falls back to the script's own backoff",
  delays()
)

-- the human string is honoured when the number is missing
scenario(429, '{"code":"rate_limit_exceeded","retry_after":"7 seconds"}')
check(
  #timeouts == 1 and timeouts[1] == 7,
  "retry_after in words is read when retry_after_seconds is absent",
  delays()
)

-- clamped at the day rather than taken literally
scenario(429, '{"code":"usage_limit_exceeded","retry_after_seconds":999999}')
check(
  state.limited_until ~= nil and state.limited_until - os.time() <= 86400,
  "an over-long wait is clamped to the day"
)

-- and while limited, a new file spends no request at all
props.filename = "Other.Show.S02E05.tmdb-615.mkv"
props.path = "/tv/" .. props.filename
props.url = "file:///tv/" .. props.filename
requests, timeouts = {}, {}
events["file-loaded"]()
check(
  #requests == 0,
  "a file-load inside the wait issues no request at all",
  "requests: " .. #requests
)

print("")
if failures > 0 then
  print(string.format("%d check(s) failed", failures))
  os.exit(1)
end
print("all checks passed")
