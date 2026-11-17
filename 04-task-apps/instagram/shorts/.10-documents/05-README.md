# instagram-shorts

Publishes your finished short videos to **one Instagram professional account as Reels**, once each, safely. A small command-line program. No screen, no account with us, nothing leaves your computer except the calls to Instagram.

## What it does
- Looks in one folder for finished videos (`<name>.mp4` + `<name>.json`).
- Checks each video against Instagram's rules and skips a bad one with a plain reason.
- Uploads the oldest ready video and waits until Instagram says it is ready.
- **By default it stops there** ("staged"): nothing is published. Set `post.public` to `true` and it publishes.
- Writes every step in a small database so a video is never sent twice.
- Puts the AI label on every post.

## What it never does
Delete anything, post twice, send without `--live`, publish without your say-so, hide the AI label, or use any other service than Instagram.

## Quick look
```
instagram-shorts doctor      is everything ready? (reads only)
instagram-shorts scan        what is waiting in the folder?
instagram-shorts publish     preview what it would do
instagram-shorts publish --live   really do it
instagram-shorts status      what happened, how many left today
```
Step by step: see `10-HOW-TO.md`. Every setting: see `15-CONFIG.md`. What changed: see `20-UPDATE.md`.

## You need
- An Instagram **professional** account (Business or Creator) linked to a Facebook Page.
- A Meta developer app and an access token (one-time setup in the guide).
- Zig 0.16.0 to build it (or a ready program).

## License
PolyForm Noncommercial 1.0.0: free for personal and noncommercial use; commercial use needs a paid license from the owner. See `25-LICENSE`.
