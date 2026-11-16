# Config Reference

Plain facts: where things go, what the settings mean. For steps, see `10-HOW-TO.md`.

---

## The Program
| Item | Value |
|---|---|
| Program | `/home/mai_trang/04-clou-base/05-jobs-apps/threads/shorts/zig-out/bin/threads-shorts` |
| Settings file | `/home/mai_trang/04-clou-base/05-jobs-apps/threads/shorts/00-config.json` (or `--config FILE`, or the `THRE_SHOR_CONFIG` variable) |
| Run | `threads-shorts <command> [--config FILE] [--json] [--live]` |
| Built with | Zig 0.16.0 and SQLite (built in) |
| Works on | Linux, Windows, macOS |

An unknown or misspelled setting is refused with its line and column, so a typo can never change behaviour quietly. A path starting with `~/` means your home folder; a path with no start is read from the folder that holds the settings file.

---

## Settings (`00-config.json`)
| Setting | What it does | Default | Allowed |
|---|---|---|---|
| `data_dir` | Folder for the record of sends, log, kill file, backups | `~/.threads-shorts` | any folder |
| `db_file` | Record file name inside `data_dir` | `ledger.db` | a file name |
| `secrets_dir` | Folder with your secret files | `~/.04-clou-secr` | any folder |
| `tz_offset_hours` | Your time zone, shown in `status` | `7` | -12 to 14 |
| `device` | Which computer may post | | |
| `device.publisher` | `true` on the ONE computer that posts for this account. Two computers posting would double-post, so `publish --live` is refused everywhere else | `false` | `true` or `false` |
| `source` | Where the finished videos wait | | |
| `source.dir` | The hand-off folder (`<name>.json` + `<name>.mp4`) | empty: you must set it | any folder |
| `source.max_age_days` | A video older than this is skipped, never deleted (0 = no limit) | `14` | 0 or more |
| `host` | Your own web folder: Threads fetches the video from it | | |
| `host.dir` | The folder your web server shows. The tool copies each video here under a random name | empty: you must set it | any folder |
| `host.done_dir` | Where the copy is moved when Threads is done with it. Must be OUTSIDE the folder your web server shows | empty: you must set it | any folder |
| `host.base_url` | The public address of `host.dir`, for example `https://files.example.com/v` | empty: you must set it | an `https://` address |
| `host.selfcheck` | Before posting, fetch the video from its public address to make sure Threads can too | `true` | `true` or `false` |
| `limits` | How much it may post | | |
| `limits.daily_cap` | Most posts in any 24 hours (Threads itself allows 250) | `3` | 1 to 50 |
| `limits.quota_margin` | Stop when Threads says this many posts are left in its own 250 allowance | `10` | 0 or more |
| `limits.gap_min_s` | Shortest pause between two posts, in seconds | `600` | 0 or more |
| `limits.gap_max_s` | Longest pause (the real pause is random in between) | `1800` | at least `gap_min_s` |
| `limits.disk_min_mb` | Stop when the disk has less free space than this | `500` | 0 or more |
| `limits.run_budget_s` | A single run stops waiting after this many seconds | `1800` | 1 or more |
| `limits.unsure_wait_min` | `resolve` will not call a post "failed" before this many minutes passed since the request left (Threads can post a little late) | `60` | 0 or more |
| `limits.quota_block_h` | After a Threads limit answer, stay quiet this many hours | `6` | 1 or more |
| `video` | What a video must look like (Threads' own limits) | | |
| `video.min_s` | Shortest video, seconds | `1` | 1 to `max_s` |
| `video.max_s` | Longest video, seconds (Threads allows 300) | `90` | up to 300 |
| `video.max_w` | Widest video, pixels | `1920` | 1 or more |
| `video.fps_min` | Lowest frame rate | `23` | 1 or more |
| `video.fps_max` | Highest frame rate | `60` | at least `fps_min` |
| `video.max_mb` | Largest file, megabytes (Threads allows 1024) | `1024` | 1 to 1024 |
| `video.max_mbps` | Highest bit rate, megabits per second | `100` | 1 or more |
| `video.vcodecs` | Accepted video formats | `["avc1","hvc1"]` (H.264, HEVC) | a list |
| `video.acodec` | Accepted audio format | `mp4a` (AAC) | a name |
| `video.audio_channels_max` | Most audio channels (mono or stereo) | `2` | 1 or 2 |
| `video.audio_rate_max` | Highest audio sample rate, Hz | `48000` | 1 or more |
| `video.probe_tool` | Name of `ffprobe` if you want it to read the files; empty = the built-in reader | empty | a program name |
| `post` | What the post looks like | | |
| `post.public` | `false` = prepare the post at Threads but do NOT publish it (state `staged`). `true` = publish for everyone | `false` | `true` or `false` |
| `post.ai_notice_required` | Refuse a video that has no AI notice text | `true` | `true` or `false` |
| `post.text_max` | Longest text, in Threads units (Threads allows 500) | `500` | 100 to 500 |
| `post.text_unit` | How length is counted: `weighted` (emoji count as 4, letters as 1), `chars`, or `bytes` | `weighted` | `weighted`, `chars`, `bytes` |
| `post.text_margin` | Units kept free as a safety margin | `10` | below `text_max` |
| `post.url_in_text` | Put the video's listing link in the text | `true` | `true` or `false` |
| `post.reply_control` | Who may reply | `everyone` | `everyone`, `accounts_you_follow`, `mentioned_only`, `parent_post_author_only`, `followers_only` |
| `net` | Network behaviour | | |
| `net.timeout_s` | Give up on one call after this many seconds | `60` | 1 or more |
| `net.copy_chunk_kb` | Piece size when copying a video to `host.dir` | `256` | 1 or more |
| `net.backoff_ms` | Wait before a retry, times the try number | `2000` | 0 or more |
| `net.settle_s` | Wait this long after creating the post before checking it (Threads asks for about 30) | `30` | 0 or more |
| `net.status_poll_s` | Seconds between checks while Threads works on the video (Threads asks for 60) | `60` | 1 or more |
| `net.status_poll_max_s` | Stop checking after this many seconds; the next run carries on | `300` | at least `status_poll_s` |
| `net.body_cap_kb` | Largest answer read from Threads | `512` | 1 or more |
| `net.user_agent` | Name shown to the servers | `threads-shorts/0.1` | text |
| `net.allow_hosts` | The only servers it will talk to | `graph.threads.com`, `graph.threads.net` | a list |
| `net.auth_style` | How the token is sent: `form` is how Meta documents it. `bearer` only after your own test shows it works | `form` | `form` or `bearer` |
| `breaker` | Stop after repeated trouble | | |
| `breaker.fails` | Failures in a row that open the stop | `3` | 1 or more |
| `breaker.cool_h` | Hours the stop stays open | `6` | 1 or more |
| `safety` | Extra checks | | |
| `safety.dup_probe` | Before posting, read your recent posts and stop if one starts the same way (protects against a lost record of sends) | `true` | `true` or `false` |
| `safety.dup_chars` | How many starting characters are compared | `80` | 10 or more |
| `account` | Names of your secrets (never the values) | | |
| `account.token_env` | Variable that holds the access token | `THRE_SHOR_TOKEN` | a name |
| `account.token_file` | File in `secrets_dir` that holds the token (renewed automatically) | `thre-shor-token` | a file name |
| `account.token_meta_file` | File with the day the token was issued, used to count the 60 days | `thre-shor-token-meta` | a file name |
| `account.user_id_env` | Variable with your Threads user number (optional: it is read from Threads when missing) | `THRE_SHOR_USER_ID` | a name |
| `account.user_id_file` | File with the user number | `thre-shor-user-id` | a file name |
| `account.app_id_env` | Variable with the Threads App ID (optional: lets `token` check permissions) | `THRE_SHOR_APP_ID` | a name |
| `account.app_id_file` | File with the App ID | `thre-shor-app-id` | a file name |
| `account.app_secret_env` | Variable with the Threads App Secret (optional) | `THRE_SHOR_APP_SECRET` | a name |
| `account.app_secret_file` | File with the App Secret | `thre-shor-app-secret` | a file name |
| `approval` | Review rules | | |
| `approval.require_for_review` | Videos marked `review:true` wait until you approve them | `true` | `true` or `false` |
| `graph` | Where Threads lives | | |
| `graph.base` | Address of the Threads service | `https://graph.threads.com` | an `https://` address |
| `graph.version` | Service version | `v1.0` | like `v1.0` |
| `graph.need_scopes` | Permissions the token must have | `threads_basic`, `threads_content_publish` | a list |
| `retry_pre_send` | Tries again for problems that happen before anything is public | `2` | 0 or more |
| `token_warn_days` | `status` and `doctor` warn when the token has fewer days left | `14` | 1 or more |
| `token_refresh_days` | Renew the token automatically when fewer days are left (tokens last 60) | `30` | 1 to 59 |

---

## Files it keeps
| File | Holds |
|---|---|
| `<data_dir>/ledger.db` | Every post and its state, the daily count, the stop switches |
| `<data_dir>/run.jsonl` | A log, one line per event, secrets removed |
| `<data_dir>/KILL` | The kill switch (`1` = stop everything) |
| `<data_dir>/backup/` | Copies made by `backup` |
| `host.dir` / `host.done_dir` | The video copies (moved to `done_dir`, never deleted) |

## Exit codes
| Code | Meaning |
|---|---|
| 0 | Done |
| 1 | Failed |
| 2 | Wrong setting or missing secret |
| 3 | Blocked (kill switch, stop, limit, dead token, not the posting computer, held for review) |
| 4 | Nothing to do (also: Threads is still working, the next run carries on) |
| 5 | Unsure whether it posted: run `resolve` |
