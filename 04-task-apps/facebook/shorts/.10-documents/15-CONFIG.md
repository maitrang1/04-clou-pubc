# Config Reference

Plain facts: where things go, what the settings mean. For steps, see `10-HOW-TO.md`.

---

## The Program
| Item | Value |
|---|---|
| Program | `/home/mai_trang/04-clou-base/04-task-apps/facebook/shorts/zig-out/bin/facebook-shorts` |
| Settings file | `/home/mai_trang/04-clou-base/04-task-apps/facebook/shorts/00-config.json` (or `--config FILE`, or the `FACE_SHOR_CONFIG` variable) |
| Run | `facebook-shorts <command> [--config FILE] [--json] [--live]` |
| Built with | Zig 0.16.0 and SQLite (built in) |
| Works on | Linux, Windows, macOS |

An unknown or misspelled setting is refused with its line and column, so a typo can never change behaviour quietly. A path starting with `~/` means your home folder; a path with no start is read from the folder that holds the settings file.

---

## Settings (`00-config.json`)
| Setting | What it does | Default | Allowed |
|---|---|---|---|
| `data_dir` | Folder for the ledger, log, kill file, backups | `~/.facebook-shorts` | any folder |
| `db_file` | Ledger file name inside `data_dir` | `ledger.db` | a file name |
| `secrets_dir` | Folder with your secret files | `~/.04-clou-secr` | any folder |
| `tz_offset_hours` | Your time zone, shown in `status` | `7` | -12 to 14 |
| `source` | Where the finished videos wait | | |
| `source.dir` | The hand-off folder (`<name>.json` + `<name>.mp4`) | empty: you must set it | any folder |
| `source.slot_hours` | Start hours of the day parts a video is made in. The newest day part goes first; inside it the oldest video goes first. An empty day part = the pick steps back to the one before (yesterday too) | `"8,14,20"` | ascending hours 0..23, up to 8 |
| `source.max_age_h` | A video made longer ago than this is skipped, never deleted (0 = no limit) | `48` | 0 or more |
| `limits` | How much it may send | | |
| `limits.daily_cap` | Most sends in any 24 hours | `3` | 1 to 30 |
| `limits.gap_min_s` | Shortest wait between two sends (seconds) | `600` | 0 or more |
| `limits.gap_max_s` | Longest random wait between two sends | `1800` | at least `gap_min_s` |
| `limits.disk_min_mb` | Stop when less disk space is free (0 = off) | `500` | 0 or more |
| `limits.run_budget_s` | A run longer than this stops uploading | `1800` | 1 or more |
| `limits.usage_stop_pct` | Stop when Facebook says you used this % of your allowance | `80` | 1 to 100 |
| `limits.quota_block_h` | Hours to stop after Facebook says "too many requests" | `24` | 1 or more |
| `video` | What a video must look like | | |
| `video.min_s` / `video.max_s` | Shortest and longest length (seconds) | `3` / `90` | min at most max |
| `video.min_w` / `video.min_h` | Smallest width and height (pixels) | `540` / `960` | 1 or more |
| `video.rec_w` / `video.rec_h` | The size Facebook recommends; smaller videos get a note in `scan` | `1080` / `1920` | 1 or more |
| `video.fps_min` / `video.fps_max` | Allowed frames per second | `24` / `60` | min at most max |
| `video.max_mb` | Biggest file (MB). Facebook does not publish its limit, so this is cautious | `1024` | 1 or more |
| `video.vcodec` | Video format name (`avc1` = H.264; empty = do not check) | `avc1` | `avc1`, `hvc1`, `vp09`, `av01`, empty |
| `video.acodec` | Audio format name (`mp4a` = AAC; empty = do not check audio) | `mp4a` | `mp4a` or empty |
| `video.audio_channels` | Audio channels | `2` | 1 or more |
| `video.audio_rate` | Audio sample rate (Hz) | `48000` | 1 or more |
| `video.probe_tool` | Path to `ffprobe` if you want it to read the videos (empty = built-in reader) | empty | a path or empty |
| `post` | How the post looks | | |
| `post.public` | `false` saves a draft on the Page; `true` publishes for everyone | `false` | `true`, `false` |
| `post.ai_notice_required` | Refuse a video that has no AI notice text | `true` | `true`, `false` |
| `post.desc_max` | Longest caption (characters, counted cautiously) | `2000` | 100 or more |
| `post.title_max` | Longest title | `100` | 1 or more |
| `post.title_pattern` | How the title is built from the video details. `{brand} {model} {year}` is never cut; only `{hook}` is shortened to fit `title_max`. Missing brand, model or year = the hook alone | `"{brand} {model} {year}. {hook}"` | must contain `{hook}` once; other placeholders: `{brand}` `{model}` `{year}` |
| `post.title_case` | Write the title in Title Case (every word starts with a capital; words that already have capitals, like SUV or VF3, stay as written) | `true` | `true` or `false` |
| `post.tags_max` | Most hashtags used | `10` | 0 or more |
| `post.reel_url_base` | Start of the link shown after a send | `https://www.facebook.com/reel` | a web address |
| `net` | Network behaviour | | |
| `net.timeout_s` | Wait for a normal answer (seconds) | `60` | 1 or more |
| `net.upload_timeout_s` | Wait for a whole upload (seconds) | `1800` | 1 or more |
| `net.chunk_kb` | Read the file in pieces of this size (KB) | `256` | 1 or more |
| `net.backoff_ms` | Pause before a retry (grows each time) | `2000` | 0 or more |
| `net.status_poll_s` | Seconds between "is it done?" checks | `5` | 1 or more |
| `net.status_poll_max_s` | Give up waiting after this many seconds | `300` | at least `status_poll_s` |
| `net.resume_max` | How many times a cut upload is resumed | `3` | 0 or more |
| `net.body_cap_kb` | Largest answer accepted from Facebook (KB) | `512` | 1 or more |
| `net.user_agent` | Name the program gives itself | `facebook-shorts/0.1` | text |
| `net.allow_hosts` | The only websites it will talk to | `graph.facebook.com`, `rupload.facebook.com` | at least one |
| `breaker` | Stop after repeated failures | | |
| `breaker.fails` | Failures in a row before it stops | `3` | 1 or more |
| `breaker.cool_h` | Hours it stays stopped | `6` | 1 or more |
| `account` | Which Page | | |
| `account.page_id_env` | Name of the variable that holds your Page id | `FACE_SHOR_PAGE_ID` | a name |
| `account.page_id_file` | Name of the file (in `secrets_dir`) that holds it | `face-shor-page-id` | a file name |
| `approval` | People in the loop | | |
| `approval.require_for_review` | Hold videos marked `review:true` until you approve | `true` | `true`, `false` |
| `graph` | Facebook connection | | |
| `graph.base` | Facebook's address | `https://graph.facebook.com` | a web address |
| `graph.version` | Facebook interface version | `v27.0` | like `v27.0` |
| `graph.app_id_env` / `graph.app_id_file` | Where your Meta app id is kept | `FACE_APP_ID` / `face-app-id` | names |
| `graph.app_secret_env` / `graph.app_secret_file` | Where your Meta app secret is kept | `FACE_APP_SECRET` / `face-app-secret` | names |
| `graph.page_token_env` / `graph.page_token_file` | Where your Page token is kept | `FACE_SHOR_PAGE_TOKEN` / `face-shor-page-token` | names |
| `graph.need_scopes` | Permissions the token must have (`token` and `doctor` check) | `pages_show_list`, `pages_read_engagement`, `pages_manage_posts` | permission names |
| `retry_pre_send` | Extra tries when Facebook is briefly down before anything is uploaded | `2` | 0 or more |
| `token_warn_days` | `status` warns when the token ends within this many days | `14` | 0 or more |

Secrets are never settings. The program looks for each secret first in its variable, then in the file of that name inside `secrets_dir`.

---

## Input
| Part | Meaning |
|---|---|
| `<name>.mp4` | The finished short video (9:16) |
| `<name>.json` | Its details, written after the video is final: `car`, `code`, `template`, `mp4`, `seconds`, `width`, `height`, `hooks`, `description`, `hashtags`, `ai_notice`, `review`, `plates`, `made_at`, `listing_url` |
| `<name>.rejected` | A person rejected it: never sent |
| `<name>.stale` | It is being rebuilt: never sent |

The program only reads this folder. It never changes, moves or removes anything in it.

## Output
| Item | Value |
|---|---|
| Result | One Reel per video on your Page (a draft unless `post.public` is `true`) |
| Ledger | `<data_dir>/ledger.db`: one row per send, so nothing is sent twice |
| Log | `<data_dir>/run.jsonl`: one line per event, secrets removed |
| Kill file | `<data_dir>/KILL`: `1` stops every write, `0` lets it run |
| Backups | `<data_dir>/backup/ledger-<seconds>.db` |

## Exit codes
| Code | Meaning |
|---|---|
| 0 | Done |
| 1 | Failed |
| 2 | Settings or usage problem |
| 3 | Blocked: kill file, cap, wait time, breaker, Facebook limit, bad token, or a video waiting for approval |
| 4 | Nothing to send |
| 5 | Unsure: Facebook did not confirm; run `resolve` |

## Files In This Tool
```
00-config.json   — the settings
main.zig         — the commands
co-*.zig         — settings, network, safety switches, logging
ap-*.zig         — everything that talks to Facebook
rw-*.zig         — the ledger, the video checks, the caption
cm-*.zig         — one file per command
df-face-errors.json — what each Facebook error code means
te-*.zig         — tests and the pretend Facebook
sqlite3.c, sqlite3.h — the built-in database
```
