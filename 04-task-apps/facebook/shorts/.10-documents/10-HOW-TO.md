# How To

Every step, one small piece at a time. See `05-README.md` first for the quick start. `EXE` below means `/home/mai_trang/04-clou-base/04-task-apps/facebook/shorts/zig-out/bin/facebook-shorts`.

Steps 1 and 2 are done once, on Facebook's website and on your machine, with your own account. They cannot be tested without it, so they are marked untested.

---

## 1 · Get your Page token (once, untested here)
1. Open `developers.facebook.com`, create an app, and note its **App ID** and **App Secret**.
2. Make sure your Facebook account can create content on the Page you want to post to.
3. Ask Facebook for a long-lived Page token with the permissions `pages_show_list`, `pages_read_engagement`, `pages_manage_posts`.
4. Note your **Page ID**.

Facebook may ask for app review before a new app can post. Try your own Page first, in development mode. If Facebook asks for review, that is a separate step on their side.

## 2 · Save your secrets (once)
Put each value in its own file in `~/.04-clou-secr/` (one value per file, nothing else in it):
| File | Holds |
|---|---|
| `face-shor-page-token` | the Page token |
| `face-shor-page-id` | the Page ID |
| `face-app-id` | the App ID |
| `face-app-secret` | the App Secret |

You can use variables instead (`FACE_SHOR_PAGE_TOKEN`, `FACE_SHOR_PAGE_ID`, `FACE_APP_ID`, `FACE_APP_SECRET`). Never paste a secret into the settings file or into a chat.

## 3 · Point it at your videos
Open `/home/mai_trang/04-clou-base/04-task-apps/facebook/shorts/00-config.json` and set `source.dir` to the folder where your finished videos wait. Each video needs a matching details file: `clip.mp4` and `clip.json`.

## 4 · Check that everything is ready
```
EXE doctor
```
You see:
```
ok   config: 00-config.json is valid
ok   source: 1 pair(s) found
ok   secret FACE_SHOR_PAGE_TOKEN: present
ok   disk: 7733 MB free (min 500)
ok   token: valid, never expires
ok   page: reachable (name read)
```
Not working? Read the line that starts with `FAIL`; it says what is missing.

## 5 · See what is waiting
```
EXE scan
```
You see:
```
ready    demo
1 ready · 0 held · 0 invalid · 0 skipped · 0 already sent
```
A video that cannot be sent shows the plain reason (too short, wrong shape, no audio, and so on).

## 6 · Preview a send
```
EXE publish
```
It prints the caption it would use and sends nothing.

## 7 · Send one video
```
EXE publish --live
```
You see:
```
posted: demo | saved as DRAFT on the Page (not public); set post.public to publish
url: https://www.facebook.com/reel/9876543210
```
Open your Page and look in its drafts. Run the same command again: it says `nothing | no ready pair` and sends nothing.

## 8 · Make posts public
Only when you are happy with the draft: in `00-config.json` set `post.public` to `true`. The next send is published for everyone.

## 9 · Approve a video that needs review
Videos marked `review:true` wait for you.
```
EXE approve --video clip --live
```
To take it back: `EXE hold --video clip --live`. Without `--live` you only see what would happen.

## 10 · When the answer is unclear
If Facebook's answer is lost, the video is marked unsure and nothing is resent. `status` shows it and the exit code is 5.
```
EXE resolve --video clip --live
```
It asks Facebook and settles the video. If Facebook cannot tell yet, wait a few minutes and run it again. If you looked at the Page yourself, you can answer: `--as posted` or `--as failed`. Only then can a failed video be sent again with `EXE publish --video clip --again --live`.

## 11 · Check on things
```
EXE status
```
You see:
```
posted 1 · failed 0 · unsure 0 · sending 0
last 24 h: 1 of 3 (cap)
kill file: off · run: free to send
```
`EXE token` checks your token (valid, permissions). `EXE backup --live` copies the record of sends.

## 12 · Stop everything at once
```
EXE kill --on
```
Nothing is written or sent until you run `EXE kill --off --live`.

## 13 · Run it on a schedule
The tool does not schedule itself. Your automation hub runs `EXE publish --live` a few times a day. Ask whoever manages the hub to add the job (`15-FEAT` lists the exact line, switched off at first).

---

## When something goes wrong
| Message | What to do |
|---|---|
| `blocked: daily cap reached: 3 of 3 in the last 24 h` | Wait, or raise `limits.daily_cap` (at most 30) |
| `blocked: min gap between sends: wait N s` | Wait; the pause is `limits.gap_min_s` to `limits.gap_max_s` |
| `blocked: breaker open …` | Several failures in a row. Wait, or look at `run.jsonl`, then `EXE config --reset-breaker --live` |
| `breaker open: Facebook flagged the action (error 368)` | Stop. Look at your Page for warnings first, then `EXE config --reset-breaker --live` |
| `stopped by Facebook limit …` | Facebook said slow down. It waits by itself |
| `blocked: kill file is on` | `EXE kill --off --live` |
| `blocked: another run is active` | A send is already running; wait for it |
| `refused | no ai_notice in the json` | Add the AI notice text to the video's details file |
| `invalid | too small / too short / wrong shape …` | Make the video again with the right size or length |
| `config | no Page token …` | Do step 2 |
| `token: missing permission …` | Make a new token with all three permissions (step 1) |
| `unsure` (exit 5) | Step 10 |
| `error: config: … at line N col M` | A setting is misspelled; fix that line |
