# Config Reference

Plain facts: where things go, what the settings mean. For steps, see `10-HOW-TO.md`.

---

## The Program
| Item | Value |
|---|---|
| Program | `/home/mai_trang/04-clou-base/04-task-apps/instagram/shorts/zig-out/bin/instagram-shorts` |
| Settings file | `/home/mai_trang/04-clou-base/04-task-apps/instagram/shorts/00-config.json` (or `--config FILE`, or the `INST_SHOR_CONFIG` variable) |
| Run | `instagram-shorts <command> [--config FILE] [--json] [--live]` |
| Built with | Zig 0.16.0 and SQLite (built in) |
| Works on | Linux, Windows, macOS |

An unknown or misspelled setting is refused with its line and column, so a typo can never change behaviour quietly. A path starting with `~/` means your home folder; a path with no start is read from the folder that holds the settings file.

---

## Settings (`00-config.json`)
| Setting | What it does | Default | Allowed |
|---|---|---|---|
| `data_dir` | Folder for the ledger, log, kill file, backups | `~/.instagram-shorts` | any folder |
| `db_file` | Ledger file name inside `data_dir` | `ledger.db` | a file name |
| `secrets_dir` | Folder with your secret files | `~/.04-clou-secr` | any folder |
| `tz_offset_hours` | Your time zone, shown in `status` | `7` | -12 to 14 |
| `source` | Where the finished videos wait | | |
| `source.dir` | The hand-off folder (`<name>.json` + `<name>.mp4`) | empty: you must set it | any folder |
| `source.max_age_days` | A video older than this is skipped, never deleted (0 = no limit) | `14` | 0 or more |
| `limits` | How much it may send | | |
| `limits.daily_cap` | Most publishes in any 24 hours | `3` | 1 to `meta_cap` |
| `limits.meta_cap` | Hard ceiling for `daily_cap`. Meta's pages say 50 or 100; we stay at or under the lower | `25` | 1 to 50 |
| `limits.container_cap` | Most upload containers made in any 24 hours (Meta allows 400) | `40` | 1 to 400 |
| `limits.gap_min_s` | Shortest wait between two publishes (seconds) | `600` | 0 or more |
| `limits.gap_max_s` | Longest random wait between two publishes | `1800` | at least `gap_min_s` |
| `limits.disk_min_mb` | Stop when less disk space is free (0 = off) | `500` | 0 or more |
| `limits.run_budget_s` | A run longer than this stops uploading | `1800` | 1 or more |
| `limits.usage_stop_pct` | Stop when Instagram says you used this % of your allowance | `80` | 1 to 100 |
| `limits.quota_block_h` | Hours to stop after Instagram says "too many requests" | `24` | 1 or more |
| `video` | What a video must look like (Instagram's Reels rules) | | |
| `video.min_s` / `video.max_s` | Shortest and longest length (seconds) | `3` / `90` | min at most max, max up to 900 |
| `video.min_w` / `video.min_h` | Smallest width and height (pixels) | `540` / `960` | 1 or more |
| `video.rec_w` / `video.rec_h` | The size we aim for; smaller videos get a note in `scan` | `1080` / `1920` | 1 or more |
| `video.max_w` | Widest allowed (pixels) | `1920` | up to 1920 |
| `video.aspect_w` / `video.aspect_h` | The shape required (9:16) | `9` / `16` | 1 or more |
| `video.aspect_tol_pct` | How far from that shape is still fine (%) | `2` | 0 to 50 |
| `video.fps_min` / `video.fps_max` | Allowed frames per second | `23` / `60` | min at most max |
| `video.max_mb` | Biggest file (MB). Instagram's limit is 300 | `300` | 1 to 300 |
| `video.vcodec` | Video format name (`avc1` = H.264; empty = do not check) | `avc1` | `avc1`, `hvc1`, empty |
| `video.acodec` | Audio format name (`mp4a` = AAC; empty = do not check audio) | `mp4a` | `mp4a` or empty |
| `video.audio_channels_max` | Most audio channels (1 or 2 are fine) | `2` | 1 or more |
| `video.audio_rate_max` | Highest audio sample rate (Hz) | `48000` | 1 or more |
| `video.probe_tool` | Path to `ffprobe` if you want it to read the videos (empty = built-in reader) | empty | a path or empty |
| `post` | How the post looks | | |
| `post.public` | `false` stops at a finished upload (nothing is published); `true` publishes for everyone | `false` | `true`, `false` |
| `post.ai_notice_required` | Refuse a video that has no AI notice text | `true` | `true`, `false` |
| `post.caption_max` | Longest caption (characters). Instagram's limit is 2200 | `2200` | 100 to 2200 |
| `post.tags_max` | Most hashtags used (Instagram allows 30) | `10` | 0 to 30 |
| `post.share_to_feed` | Also show the Reel in the Feed tab | `true` | `true`, `false` |
| `post.thumb_offset_ms` | Which moment of the video becomes the cover (milliseconds) | `0` | 0 or more |
| `net` | Network behaviour | | |
| `net.timeout_s` | Wait for a normal answer (seconds) | `60` | 1 or more |
| `net.upload_timeout_s` | Wait for a whole upload (seconds) | `1800` | 1 or more |
| `net.chunk_kb` | Read the file in pieces of this size (KB) | `256` | 1 or more |
| `net.backoff_ms` | Pause before a retry (grows each time) | `2000` | 0 or more |
| `net.status_poll_s` | Seconds between "is it ready?" checks (Instagram asks for about once a minute) | `60` | 1 or more |
| `net.status_poll_max_s` | Give up waiting after this many seconds (Instagram: at most about 5 minutes) | `300` | at least `status_poll_s` |
| `net.resume_max` | How many times a cut upload is started again | `2` | 0 or more |
| `net.notready_wait_s` | Pause before asking again when Instagram says "not ready yet" | `30` | 0 or more |
| `net.body_cap_kb` | Largest answer accepted from Instagram (KB) | `512` | 1 or more |
| `net.user_agent` | Name the program gives itself | `instagram-shorts/0.1` | text |
| `net.allow_hosts` | The only websites it will talk to | `graph.facebook.com`, `rupload.facebook.com` | at least one |
| `breaker` | Stop after repeated failures | | |
| `breaker.fails` | Failures in a row before it stops | `3` | 1 or more |
| `breaker.cool_h` | Hours it stays stopped | `6` | 1 or more |
| `account` | Which Instagram account | | |
| `account.ig_user_id_env` | Name of the variable that holds your Instagram user id | `INST_SHOR_USER_ID` | a name |
| `account.ig_user_id_file` | Name of the file (in `secrets_dir`) that holds it | `inst-shor-user-id` | a file name |
| `graph` | Instagram connection | | |
| `graph.base` | Meta's address | `https://graph.facebook.com` | a web address |
| `graph.version` | Interface version | `v27.0` | like `v27.0` |
| `graph.login` | Login type. Only `facebook` works: Meta documents the upload we use for it alone | `facebook` | `facebook` |
| `graph.token_env` / `graph.token_file` | Where your access token is kept | `INST_SHOR_TOKEN` / `inst-shor-token` | names |
| `retry_pre_send` | Extra tries when Instagram is briefly down before anything is uploaded | `2` | 0 or more |
| `retry_publish` | Extra tries of the publish step when Instagram says "not ready yet" (never after an unclear answer) | `2` | 0 or more |

Secrets are never settings. The program looks for each secret first in its variable, then in the file of that name inside `secrets_dir`.

---

## Input
| Part | Meaning |
|---|---|
| `<name>.mp4` | The finished short video (9:16, `moov` box at the front, no edit lists, H.264, AAC) |
| `<name>.json` | Its details, written after the video is final: `car`, `code`, `template`, `mp4`, `seconds`, `width`, `height`, `hooks`, `description`, `hashtags`, `ai_notice`, `review`, `plates`, `made_at`, `listing_url` |
| `<name>.rejected` | A person rejected it: never sent |
| `<name>.stale` | It is being rebuilt: never sent |

The program only reads this folder. It never changes, moves or removes anything in it.

## Output
| Item | Value |
|---|---|
| Result | One Reel per video on your account. With `post.public` `false` the video is only uploaded and checked ("staged"): nothing is published |
| Ledger | `<data_dir>/ledger.db`: one row per send, so nothing is sent twice |
| Log | `<data_dir>/run.jsonl`: one line per event, secrets removed |
| Kill file | `<data_dir>/KILL`: `1` stops every write, `0` lets it run |
| Backups | `<data_dir>/backup/ledger-<seconds>.db` |

## States of a video
| State | Meaning |
|---|---|
| `staged` | Uploaded and checked by Instagram, NOT published. Gone after 24 hours |
| `posted` | Published |
| `failed` | Stopped with a reason; a person retries with `--again` |
| `expired` | A staged upload ran out after 24 hours; a person retries with `--again` |
| `unsure` | The publish answer was lost or unclear; run `resolve`. Never retried by itself |

## Exit codes
| Code | Meaning |
|---|---|
| 0 | Done |
| 1 | Failed |
| 2 | Settings or usage problem |
| 3 | Blocked: kill file, cap, wait time, breaker, Instagram limit, bad token |
| 4 | Nothing to send |
| 5 | Unsure: Instagram did not confirm; run `resolve` |

## Files In This Tool
```
00-config.json   — the settings
main.zig         — the commands
co-*.zig         — settings, network, safety switches, logging
ap-*.zig         — everything that talks to Instagram
rw-*.zig         — the ledger, the video checks, the caption
cm-*.zig         — one file per command
df-inst-errors.json — what each Instagram error code means
te-*.zig         — tests and the pretend Instagram
sqlite3.c, sqlite3.h — the built-in database
```
