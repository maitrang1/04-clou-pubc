# Updates

What changed, newest first.

---

## 2026-11-16
**Changed:** The pick now follows the day parts of `source.slot_hours` (8, 14, 20 h): the newest day part goes first, the oldest video inside it first, and an empty day part steps back to the one before. Videos made more than `source.max_age_h` (48) hours ago are skipped. This replaces `source.max_age_days`.
**Fixed:** Resuming a cut upload now works with the spelling Facebook really uses for the byte counter.

---

## 2026-11-15 · First release
**Added:** Publish finished short videos to one Facebook Page as Reels, once each, as a draft unless you allow public posts.
**Added:** A record of every send, a daily limit, a wait between sends, and a stop after repeated failures or Facebook's own limits.
**Added:** Unclear answers are never resent: `resolve` asks Facebook and settles them.
**Added:** Videos marked for review wait until you run `approve`.
**Added:** `doctor`, `status`, `scan`, `token`, `kill` and `backup` commands. Every write is a preview unless you add `--live`.
