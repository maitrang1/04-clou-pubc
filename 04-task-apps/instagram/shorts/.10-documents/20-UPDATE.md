# Updates

What changed, newest first.

---

## 2026-11-20 · Fully automatic
**Removed:** the review step. `approve`, `hold` and `approval.require_for_review` are gone; a `review` field in the video json is ignored, and every good video is sent on its own. `publish --again` stays for a person.
**Changed:** `scan` and `status` no longer show a held list.

---

## 2026-11-16 · First release
**Added:** Publish finished short videos to one Instagram professional account as Reels, once each. By default the video is only uploaded and checked by Instagram ("staged"): nothing is published until you set `post.public` to `true`.
**Added:** A record of every send, a daily limit, a container limit, a wait between sends, and a stop after repeated failures or Instagram's own limits. Instagram's own allowance is read before each public send.
**Added:** An unclear answer from the publish step is never resent: `resolve` asks Instagram and settles it.
**Added:** Videos marked for review wait until you run `approve`.
**Added:** `doctor`, `status`, `scan`, `token`, `kill`, `backup` and `config` commands. Every write is a preview unless you add `--live`.
**Added:** Videos Instagram would refuse (moov box not at the front, edit lists, wrong shape or size) are skipped with the fix named.
