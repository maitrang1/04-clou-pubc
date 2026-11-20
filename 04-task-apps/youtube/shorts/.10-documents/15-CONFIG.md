# Config Reference

Plain facts: where things go and what each setting does. For steps, see `10-HOW-TO.md`.

---

## The Program
| Item | Value |
|---|---|
| File | `shorts` (Linux, macOS) · `shorts.exe` (Windows), next to `00-config.json` |
| Run | `shorts <command> [--config FILE] [--json] [--live]` |
| Built with | Zig 0.16.0, standard library only, plus the public-domain SQLite library for the ledger |
| Commands | `doctor` `status` `scan` `publish` `resolve` `login` `token` `kill` `backup` `config` `version` |

A wrong or unknown setting stops the program with the line and column. It never guesses.
Every command that writes something (`publish`, `resolve`, `login`) only shows what it would do until you add `--live`. `kill`, `backup` and `status` act at once.

## Exit codes
| Code | Meaning |
|---|---|
| 0 | Done |
| 1 | Failed (the message says why) |
| 2 | Wrong usage or a bad setting |
| 3 | Blocked: kill file, another run, breaker open, daily limit, cap, or a sign-in problem |
| 4 | Nothing to do (no ready video, or the gap between sends has not passed) |
| 5 | Unsure: an answer was lost, run `resolve` |

## Where things live
| What | Where |
|---|---|
| Videos to send | the folder in `source.dir` (read only, never changed) |
| Data (ledger, log, backups, lock, kill file) | `data_dir`, or the variable `YOUT_HOME`, or `~/.04-clou-data/youtube-shorts` |
| Secrets (client id, client secret, sign-in token) | `secrets_dir`, or `~/.04-clou-secr`. Files are made with mode 600, folders with mode 700 |
| Ledger | `ledger.db` in the data folder (one row per video) |
| Log | `log/run.log` in the data folder. Tokens are never written to it |

## Secrets (variables or files, never in `00-config.json`)
| Variable | File in the secrets folder | What it is |
|---|---|---|
| `YOUT_CLIENT_ID` | `yout-client-id.txt` | Your Google OAuth client id |
| `YOUT_CLIENT_SECRET` | `yout-client-secret.txt` | Its secret (needed for Desktop clients) |
| none | `yout-refresh-token.txt` | Made by `login`. Do not copy it to another computer |

A variable wins over the file. The names can be changed in the `google` section below.

## Settings (`00-config.json`)
A relative path is read from the folder that holds `00-config.json`.

| Setting | What it does | Default | Allowed |
|---|---|---|---|
| `data_dir` | Where the ledger and log live. Empty = `YOUT_HOME` or `~/.04-clou-data/youtube-shorts` | empty | a folder path |
| `secrets_dir` | Where the secret files live. Empty = `~/.04-clou-secr` | empty | a folder path |
| `tz_offset_hours` | Time zone for the log's time stamps only | `7` | -12 to 14 |
| `db_file` | Ledger file name | `ledger.db` | a file name |
| `kill_file` | Name of the stop file | `KILL` | a file name |
| `source.dir` | The folder the video maker fills. **You must set this** | empty | a folder path |
| `source.slot_hours` | Start hours of the day parts a video is made in. The newest day part goes first; inside it the oldest video goes first. An empty day part = the pick steps back to the one before (yesterday too) | `"8,14,20"` | ascending hours 0..23, up to 8 |
| `source.max_age_h` | A video made longer ago than this is skipped, never deleted (0 = no limit) | `48` | 0 or more |
| `limits.daily_cap` | Most sends per Pacific-time day | `8` | 1 to `daily_cap_max` |
| `limits.daily_cap_max` | Highest cap you may set (YouTube allows 100 uploads a day per project) | `100` | 1 to 100000 |
| `limits.gap_min_s` / `gap_max_s` | A random wait between two sends, in seconds | `600` / `1800` | min up to max |
| `limits.disk_min_mb` | Stop when the data folder has less free space | `500` | 0 or more |
| `limits.retry_max` | How many times a failed video (upload never started) is tried again on later runs | `2` | 0 to 5 |
| `limits.run_budget_s` | A run that lasts longer than this stops itself (an unfinished upload resumes next run). Must be longer than `net.upload_timeout_s` | `2400` | more than `upload_timeout_s` |
| `video.min_s` / `max_s` | Allowed length in seconds. A Short is up to 180 | `3` / `60` | 1 to 180 |
| `video.min_w` / `min_h` | Smallest picture size in pixels | `540` / `960` | 1 or more |
| `video.max_mb` | Largest file | `512` | 1 or more |
| `video.want_faststart` | Warn when the MP4 index is not at the front | `true` | true or false |
| `post.public` | **The public switch.** `false` = the video stays private | `false` | true or false |
| `post.visibility` | When `public` is false: `private` or `unlisted` | `private` | private, unlisted, public |
| `post.made_for_kids` | The "made for kids" answer YouTube requires | `false` | true or false |
| `post.ai_notice_required` | Locked on: every video carries the AI label | `true` | only `true` |
| `post.notify_subscribers` | Tell subscribers about a new video | `false` | true or false |
| `post.shorts_tag` | Add `#Shorts` to the title | `false` | true or false |
| `post.include_listing_url` | Put the listing address from the json into the description | `true` | true or false |
| `post.category_id` | YouTube category number | `2` | digits. `doctor` checks it |
| `post.title_max` | Title length in characters | `100` | 1 to 100 |
| `post.title_pattern` | How the title is built. `{brand} {model} {year}` is never cut; only `{hook}` is shortened, at a word. A missing brand, model or year drops that part | `{brand} {model} {year}. {hook}` | text with `{hook}` once; other placeholders: `{brand}` `{model}` `{year}` |
| `post.title_case` | Title Case: every word starts with a capital, the rest stays as written (SUV, VF3, VinFast keep their spelling) | `true` | true or false |
| `post.desc_max_bytes` | Description length in bytes (not characters) | `5000` | 1 to 5000 |
| `post.tags_max_chars` | Total tag length | `500` | 0 to 500 |
| `post.hashtags_max` | Most hashtags. YouTube ignores all of them above 60 | `15` | 0 to 60 |
| `net.timeout_s` | Wait for an ordinary answer | `60` | 1 or more |
| `net.upload_timeout_s` | Wait for the whole upload | `1800` | 1 or more |
| `net.chunk_kb` | Size of each read from the video file (memory use) | `256` | 4 to 65536 |
| `net.backoff_ms` | First wait before a retry, doubles each time | `2000` | any |
| `net.retries` | Retries after a lost answer | `5` | 0 to 10 |
| `net.status_poll_s` / `status_poll_max_s` | How often and how long to watch YouTube process the video | `10` / `180` | 1 up to max |
| `net.body_cap_kb` | Largest answer accepted | `1024` | 1 or more |
| `net.user_agent` | Name sent to Google | `youtube-shorts/0.1` | text |
| `net.allow_hosts` | The only internet addresses the program may talk to | `*.googleapis.com`, `accounts.google.com` | a list |
| `breaker.fails` | Failed sends in a row that open the breaker | `3` | 1 or more |
| `breaker.cool_h` | Hours the breaker stays open | `6` | 1 or more |
| `google.auth_url` `token_url` `api_base` `upload_base` | Google's addresses | Google's own | https addresses |
| `google.scope` | The permissions asked for: upload, plus read-only to check your own uploads | `youtube.upload youtube.readonly` | those two only; upload is required |
| `google.client_id_env` `client_secret_env` | Names of the variables | `YOUT_CLIENT_ID` `YOUT_CLIENT_SECRET` | text |
| `google.client_id_file` `client_secret_file` `refresh_token_file` | Names of the secret files | see above | file names |
| `google.loopback_port` | Port for the sign-in page on this computer. 0 = any free port | `0` | 0 to 65535 |
| `google.login_wait_s` | How long `login` waits for your browser | `300` | 1 or more |
| `google.watch_url` | Start of a video's address, stored in the ledger | `https://www.youtube.com/watch?v=` | text |
| `google.region_code` | Region used to check the category | `US` | two letters |
| `retry_pre_send` | Retries before any video byte is sent | `2` | 0 to 5 |
| `token_warn_days` | `status` warns when the sign-in was not checked for this many days | `30` | 1 or more |

## What the video maker hands over
For each video, two files with the same name in `source.dir`: `name.mp4` and `name.json`. The json is written last. A file `name.rejected` (a person said no) or `name.stale` (being re-made) is never sent. The json needs `car`, `template`, `hooks` (the first is the title), `ai_notice`, and may have `description`, `hashtags`, `listing_url`, `review`, `made_at`.
