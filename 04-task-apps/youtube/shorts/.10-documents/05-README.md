# YouTube Shorts Publisher

Sends your finished short videos to your YouTube channel as Shorts, one time each, by itself.
No cloud service, no extra account. It talks only to Google, and keeps its own small list of what it sent.

---

## What it does
A video maker puts finished videos in a folder. This tool picks the freshest one that passes its checks (the newest day part first, then the oldest video inside it) and uploads it to your channel. It writes down every send, so a video is never uploaded twice, even if the internet drops at the wrong moment. Out of the box it is careful: videos stay **private**, carry an AI label, and at most 3 go out a day.

---

## Requirements
- Linux (x86_64) or Windows (x86_64)
- A Google account with a YouTube channel
- A free Google Cloud project with the YouTube Data API turned on (`10-HOW-TO.md` walks you through it, once)

---

## Quick Start
1. Tell it where the videos are. Open `00-config.json` and set `source.dir` to the video maker's output folder.
2. Look at what it sees:
```
/home/mai_trang/04-clou-base/04-task-apps/youtube/shorts/zig-out/bin/shorts scan
```
You see one line per video, like `ready     xe-001  1080x1920 15s`, and a count line.
3. Check what it would send. Nothing leaves your computer yet:
```
/home/mai_trang/04-clou-base/04-task-apps/youtube/shorts/zig-out/bin/shorts publish
```
You see `dry run: would upload xe-001` with the title and `privacy: private`.
4. Connect your Google account once and send for real: follow `10-HOW-TO.md` from "Connect your Google account".

---

## Where Output Goes
Your video appears on your channel as **private**. Open YouTube Studio, check it, and when you are happy set `post.public` to `true` in `00-config.json`. The tool also keeps a ledger and a log in its data folder (`~/.04-clou-data/youtube-shorts` unless you change it).

## What it never does
It never sends without `--live`. It never makes a video public unless you switch `post.public` on. It never hides the AI label. It never deletes anything.

---

## Privacy
This tool is a personal program that runs on your own computer. It asks Google for one permission only: to upload videos to your own YouTube channel. It does not read your channel, your videos, your comments or any other account data. The sign-in token stays in a file on your computer and is sent only to Google. Nothing is sent to the author or to any other service, and no data is collected or shared. To remove its access, delete the token file and revoke the app in your Google Account under Security > Third-party access.

## License
PolyForm Noncommercial 1.0.0 (plain-English copy in `25-LICENSE`). Free for personal and noncommercial use; commercial use needs a paid license from the owner.

## Next
- **`10-HOW-TO.md`**: every command, with steps
- **`15-CONFIG.md`**: where things go and every setting
- **`20-UPDATE.md`**: what changed, by date
