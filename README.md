# TheIntroDB mpv script

Skip intros, recaps, credits, and previews in mpv using community-submitted
timestamps from [TheIntroDB](https://theintrodb.org). The script fetches the
segment data for whatever movie or episode you are playing and gives you:

- **Keybindings** to skip each segment type (intro, recap, credits, preview)
- **Skip to next segment** — jumps past whichever segment you are in
- **Clickable on-screen button bar** (toggle with `I`)
- **Optional auto-skip** of intros and recaps (`Ctrl+I` to toggle)

Requires mpv ≥ 0.33 (for `utils.parse_json` and `mp.command_native_async`).
No external dependencies beyond `curl` (present on macOS/Linux by default).

## Installation

Copy `scripts/theintrodb.lua` into your mpv `scripts/` directory, and
optionally `script-opts/theintrodb.conf.example` → `script-opts/theintrodb.conf`:

| Platform | Config dir |
| --- | --- |
| Linux | `~/.config/mpv/` |
| macOS | `~/.config/mpv/` |
| Windows | `%APPDATA%/mpv/` |

## How it identifies media

The script needs a **TMDB ID** (preferred) or **IMDB ID** for the current
file. It resolves it from, in order:

1. `script-opts` — `theintrodb-tmdb_id` / `theintrodb-imdb_id`
2. The filename — any of:
   - `tmdb-12345`, `tmdb_12345`, `tmdb12345` (case-insensitive)
   - an IMDB id: `tt0111161`
3. **Automatic**: if no explicit id is found, the filename is cleaned up
   (strips release-group tags, resolution, codecs, year, episode markers) and
   searched on TMDB (`/search/movie` or `/search/tv` depending on whether a
   season/episode was detected). The top hit is used. Results are cached per
   file for the session. Disable with `auto_detect=no` in the config.

For TV episodes it also needs **season** and **episode**, parsed from
`S01E02`, `s01e02`, `1x02`, or `Season 1 Episode 2` in the filename — or set
explicitly via script-opts. If auto-detect finds a TV show but no season/
episode could be parsed from the filename, it reports so and skips (a wrong
episode is worse than no skip).

Example — file `Some.Movie.2024.1080p.tmdb-12345.mkv` will be looked up as
TMDB 12345; `Show.S01E02.720p.mkv` will be looked up as a TV episode with the
season/episode parsed from the name. If no id is found, the script prints a
hint (no API request is made).

For streams or files with no id in the name, pass it explicitly:

```sh
mpv --script-opts=theintrodb-tmdb_id=12345 'https://.../video.mkv'
mpv --script-opts=theintrodb-tmdb_id=16085,theintrodb-season=1,theintrodb-episode=4 "video.mp4"
```

## Key bindings

| Key | Action |
| --- | --- |
| `Alt+i` | Skip intro |
| `Alt+r` | Skip recap |
| `Alt+c` | Skip credits |
| `n` | Skip to next segment (whichever segment is current/upcoming) |
| `Ctrl+i` | Toggle the clickable button bar |
| `Alt+a` | Toggle auto-skip (intro & recap) |

All keys are configurable in `script-opts/theintrodb.conf`
(`key_skip_intro`, `key_skip_recap`, `key_skip_credits`, `key_skip_preview`,
`key_skip_next`, `key_toggle_ui`, `key_toggle_auto_skip`). The defaults are
chosen to avoid clashing with flower-mpv-config's keymap (which uses `[`/`]`
for subtitle scale, `s` for screenshots, etc.) and with mpv's built-in
bindings.

## Auto-skip

With `auto_skip=yes` in the config (or after pressing `Ctrl+I`), the script
watches playback and automatically jumps over **intro** and **recap**
segments. It never fights you: it only skips when playback is moving
forward, and won't skip after a recent manual seek. Credits and previews are
never auto-skipped — they only skip on demand.

## Development

```sh
# syntax check
luac -p scripts/theintrodb.lua

# manual test with a known movie (replace 12345 with any TMDB id)
ffmpeg -f lavfi -i testsrc=duration=600:size=1280x720:rate=30 -f lavfi -i sine=frequency=440:duration=600 \
  -c:v libx264 -preset ultrafast -c:a aac -shortest /tmp/test-video.mkv
mpv --script=scripts/theintrodb.lua --script-opts=theintrodb-tmdb_id=12345 /tmp/test-video.mkv
```

## License

MIT — see [LICENSE](LICENSE).
