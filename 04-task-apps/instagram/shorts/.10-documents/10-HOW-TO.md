# How To

One tiny step at a time. Every command uses the full path, so you can paste it anywhere. Replace `~/…` with your own folders if you moved things.

> Everything here is a **preview** until you add `--live`. Nothing is published until `post.public` is `true`.

---

## Part 1 · One-time setup (you do this, once)

**Step 1 · Account.** Your Instagram account must be **professional** (Business or Creator) and **linked to a Facebook Page**. In the Instagram app: Settings → Account type → switch to professional, then link a Page.

**Step 2 · Meta app.** At developers.facebook.com create an app of type **Business**, add **Facebook Login for Business**, and give it the permissions `instagram_basic`, `instagram_content_publish`, `pages_read_engagement`. Add your own account to the app's roles. Using only your own account normally needs no App Review (Meta says so for apps that serve your own account; if Meta asks for review anyway, that is a separate step).

**Step 3 · Token and id.** Make an access token for that account (try the **Page token** first, then the **user token**: Meta's own pages disagree on which one is needed). Find your Instagram user id (a long number).

**Step 4 · Save them.** Put each in its own file; never paste them into chat or into `00-config.json`:
```
~/.04-clou-secr/inst-shor-token       (the token)
~/.04-clou-secr/inst-shor-user-id     (the number)
```
You should see: both files exist and only you can read them.

---

## Part 2 · Build

```
cd /home/mai_trang/04-clou-base/04-task-apps/instagram/shorts && zig build -Doptimize=ReleaseSafe
```
You should see: the file `zig-out/bin/instagram-shorts` exists. The first build takes about two minutes.

---

## Part 3 · Point it at your videos

Open `/home/mai_trang/04-clou-base/04-task-apps/instagram/shorts/00-config.json` and set `"source": {"dir": "<the folder with your videos>"}`.

**What a video must look like** (otherwise `scan` skips it and says why):
- 9:16, 540×960 or bigger, up to 1920 wide, 3 to 90 seconds, 23–60 frames per second.
- H.264 video and AAC audio.
- The `moov` box at the front **and no edit list**. With ffmpeg make it like this:
```
ffmpeg -i in.mp4 -c:v libx264 -pix_fmt yuv420p -c:a aac -ac 2 -ar 48000 -movflags +faststart -use_editlist 0 out.mp4
```
(A plain ffmpeg file has an edit list; Instagram refuses it.)

---

## Part 4 · Check, then try

**Step 5 · Doctor.**
```
/home/mai_trang/04-clou-base/04-task-apps/instagram/shorts/zig-out/bin/instagram-shorts doctor
```
You should see: lines starting with `ok`. A `FAIL` line says what is missing.

**Step 6 · Scan.**
```
/home/mai_trang/04-clou-base/04-task-apps/instagram/shorts/zig-out/bin/instagram-shorts scan
```
You should see: your videos as `ready` (or `invalid` with the reason).

**Step 7 · Preview.**
```
/home/mai_trang/04-clou-base/04-task-apps/instagram/shorts/zig-out/bin/instagram-shorts publish
```
You should see: `dry-run: would send …` and "nothing was sent".

**Step 8 · First real run, use a throwaway account.**
```
/home/mai_trang/04-clou-base/04-task-apps/instagram/shorts/zig-out/bin/instagram-shorts publish --live
```
You should see: `staged: … container FINISHED, NOT published`. Instagram accepted and checked the video. Nothing is visible yet.

**Step 9 · Publish for real.** Set `"public": true` in `post`, then:
```
/home/mai_trang/04-clou-base/04-task-apps/instagram/shorts/zig-out/bin/instagram-shorts publish --live --video <name>
```
You should see: `posted: … published` and a link. A staged video is used if it is younger than 24 hours; otherwise run it again with `--again`.

---

## When something stops
| You see | What it means | Do this |
|---|---|---|
| `invalid … edit lists` / `moov atom` | the file is not fast-start | re-make it with the ffmpeg line above |
| `blocked … daily cap` | enough sent today | wait; `status` shows the count |
| `blocked … breaker` | several failures in a row | read `status`, fix, wait or `config --reset-breaker --live` |
| `unsure` (exit 5) | Instagram did not confirm the publish | `instagram-shorts resolve --video <name>`; never publish it again by hand first |
| `expired` | a staged video ran out after 24 h | `publish --video <name> --again --live` |
| `held` | marked for review | `instagram-shorts approve --video <name> --live` |

Stop everything at once: `instagram-shorts kill --on`. Allow again: `instagram-shorts kill --off --live`.
