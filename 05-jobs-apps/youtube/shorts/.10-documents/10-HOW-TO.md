# How To

Every command, with steps. See `05-README.md` first for the quick start. In every command below, `shorts` means:
`/home/mai_trang/04-clou-base/05-jobs-apps/youtube/shorts/zig-out/bin/shorts` (Windows: `...\zig-out\bin-windows\shorts.exe`).

Steps marked **(not run against real Google yet)** were tested against a copy of Google's behavior only. Do them once with one private video, as shown below.

---

## Create your Google client id (once, about 10 minutes)
Google forces these four steps by hand. After them you never do them again.
1. Open `console.cloud.google.com`, make a new project, and name it anything.
2. In that project open **APIs & Services > Library**, search **YouTube Data API v3**, press **Enable**.
3. Open **OAuth consent screen**. Choose **External**, fill the app name and your email. Add the two permissions `.../auth/youtube.upload` and `.../auth/youtube.readonly`. Then press **Publish app** so the status says **In production**. If you skip this, your sign-in stops working after 7 days. You will see a "Google has not verified this app" warning later; that is your own app, so you may continue.
4. Open **Credentials > Create credentials > OAuth client ID**, type **Desktop app**. Copy the client id and the client secret.

Save them on your computer. Replace the two values, keep the quotes:
```
mkdir -p ~/.04-clou-secr
printf '%s' 'YOUR_CLIENT_ID' > ~/.04-clou-secr/yout-client-id.txt
printf '%s' 'YOUR_CLIENT_SECRET' > ~/.04-clou-secr/yout-client-secret.txt
```
Windows (PowerShell): put the same text in `%USERPROFILE%\.04-clou-secr\yout-client-id.txt` and `yout-client-secret.txt`. Never paste these into a chat or an email.

Use this Google project for this tool only.

---

## Point it at your videos
Open `00-config.json` and set `source.dir` to the folder the video maker fills, for example:
```
"source": { "dir": "/home/you/videos-out", "slot_hours": "8,14,20", "max_age_h": 48 },
```
Each video is two files with the same name: `xe-001.mp4` and `xe-001.json`.

## See what it found
```
shorts scan
```
You see (real output from a sample folder):
```
ready     xe-001  1080x1920 15s
held      xe-002  1080x1920 15s  review video: needs shorts approve
invalid   xe-003-wide  not vertical or square (1920x1080): YouTube would not make it a Short
invalid   xe-004-long  too long (90s, video.max_s 60): it would not be a Short
invalid   xe-005-nolabel  json has no ai_notice: every post must carry the AI label
---
5 videos: 1 ready 1 held 3 invalid
```
A video that is not vertical or square, is too long, or has no AI notice is never sent.

## Check what would be sent
Nothing leaves your computer:
```
shorts publish
```
You see:
```
dry run: would upload xe-001 (2304 bytes)
  title: Ford Everest 2022. Xe Dep, Gia Tot
  privacy: private · kids: false · AI label: on · notify: false · tags: 2 · description: 48 bytes
  nothing was sent. Add --live to send.
```

---

## Connect your Google account (once) (not run against real Google yet)
1. Run:
```
shorts login --live
```
2. It prints an address and waits. Open that address in a browser on the same computer, sign in as the channel owner, and press **Allow**.
3. You see `stored: sign-in saved to ... (mode 600)`.

No browser on that computer? Run `shorts login --live --paste`, open the address on any other device, press **Allow**, then copy the whole address the browser ends on and paste it into the terminal.

Run `login` only once. Google keeps only a few sign-ins per app and cancels the older ones. If a sign-in already exists the tool refuses; use `--force` only when `shorts token` says it is dead.

## Check that everything is ready (not run against real Google yet)
```
shorts doctor
```
Every line should say `ok`. A `FAIL` line tells you what to fix. `doctor` never uploads.

---

## Send the first video, privately (not run against real Google yet)
1. Send one:
```
shorts publish --live
```
You see two lines: `publish: xe-001: posted and processed`, then the video link `https://www.youtube.com/watch?v=...`.
2. Open YouTube Studio and check the video: it is **private**, it shows as a **Short**, the AI label is on, and the "made for kids" answer is **No**.
3. Happy? Open `00-config.json`, set `"public": true` in the `post` section. From now on new videos go out public.

Each run sends at most one video. Run it a few times a day, by hand or from your computer's scheduler:
```
shorts publish --live
```
Exit code 4 means "nothing to do right now"; it is not an error.

---

## Let a person look first (videos marked for review)
A video with `"review": true` waits. See it, then decide:
```
shorts approve --video xe-002
shorts approve --video xe-002 --live
```
The first line only shows what would change. `--live` writes it. To park a video instead: `shorts hold --video xe-002 --live`.

## When it says "unsure"
This means the internet dropped after the video was sent and YouTube could not say if it arrived. The tool will never upload it again by itself. Ask YouTube:
```
shorts resolve --video xe-001 --live
```
If it finds the video it marks it sent. If not, check YouTube Studio by hand. To send it again on purpose (a double is possible): `shorts approve --video xe-001 --resend --live`.

## See the state
```
shorts status
```
You see:
```
ledger: 1 ready · 0 held · 0 sending · 0 posted · 0 failed · 0 unsure
today (Pacific day): 0 of 3 sends
breaker: closed · daily stop: no · kill file: off
sign-in: never checked here (run: shorts token)
```
The cap counts per Pacific-time day because that is when Google resets its limits.

## Stop everything at once
```
shorts kill on
```
Every send, approve and resolve is refused until `shorts kill off`.

## Copy the ledger
```
shorts backup
```
The copy goes to the `backup` folder inside the data folder. It never overwrites an older copy.

---

## If something goes wrong
| You see | Do this |
|---|---|
| `error: no client id` | Do "Create your Google client id" and save the two files |
| `error: not logged in` | Run `shorts login --live` |
| `error: refresh token dead` | Set the consent screen to **In production** (step 3), then `shorts login --live --force` |
| `blocked: kill file is on` | `shorts kill off` |
| `blocked: another run is active` | Wait; two runs never overlap |
| `blocked: daily cap reached` | Wait for the next Pacific-time day, or raise `limits.daily_cap` |
| `stopped until the next Pacific midnight` | Google's upload quota or your channel's daily limit is used up; it resumes by itself |
| `breaker open` | Several sends failed or YouTube refused one. Read `shorts status` and the log, then `shorts config --reset-breaker --live` |
| `YouTube refused (forbidden)` | A person must look at your channel and the video |
| `nothing to do: no ready video` | Nothing passes the checks; run `shorts scan` for the reason |

The log is `log/run.log` in the data folder (`~/.04-clou-data/youtube-shorts` unless you changed it). It never holds a password or token.
