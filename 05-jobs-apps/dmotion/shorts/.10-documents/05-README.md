# Facebook Shorts

Publishes your finished short videos to one Facebook Page as Reels, one time each, safely.
No cloud service of its own, no extra install. It only talks to Facebook.

---

## What it does
You point it at a folder where finished videos wait (each video comes with a small details file). It picks the oldest ready one, sends it to your Page, and writes down what happened, so the same video is never sent twice. By default it saves a **draft** on your Page and publishes nothing for everyone to see until you allow it. Every post is labelled as AI-made.

---

## Requirements
- Linux, Windows or macOS (64-bit)
- A Facebook Page you manage, and a Meta developer app with a Page token (`10-HOW-TO.md` shows how)
- Nothing else to install

---

## Quick Start
1. Set your Page details (use your own values):
```
export FACE_SHOR_PAGE_ID=<YOUR_PAGE_ID>
export FACE_SHOR_PAGE_TOKEN=<YOUR_PAGE_TOKEN>
```
2. In `/home/mai_trang/04-clou-base/05-jobs-apps/facebook/shorts/00-config.json` set `source.dir` to your videos folder.
3. Preview (sends nothing):
```
/home/mai_trang/04-clou-base/05-jobs-apps/facebook/shorts/zig-out/bin/facebook-shorts publish
```
You see:
```
dry-run: would publish 'demo' (0 MB) as DRAFT
  caption: Look at this one

Clean and ready.

#cars #vietnam

Made with AI.
  nothing was sent. Add --live to send.
```
4. Send for real:
```
/home/mai_trang/04-clou-base/05-jobs-apps/facebook/shorts/zig-out/bin/facebook-shorts publish --live
```
You see:
```
posted: demo | saved as DRAFT on the Page (not public); set post.public to publish
url: https://www.facebook.com/reel/9876543210
```

---

## Safety built in
- Nothing is sent without `--live`.
- Each video is sent once. Running again changes nothing.
- A daily limit (3 by default), a wait between sends, and a stop after repeated failures.
- If Facebook's answer is lost, the video is marked unsure and is never resent by itself.
- A kill switch stops everything.

---

## Next
- **`10-HOW-TO.md`**: every step and option
- **`15-CONFIG.md`**: every setting
- **`20-UPDATE.md`**: what changed

## License
PolyForm Noncommercial 1.0.0: free for personal and noncommercial use; commercial use needs a paid license from the owner. See `25-LICENSE`.
