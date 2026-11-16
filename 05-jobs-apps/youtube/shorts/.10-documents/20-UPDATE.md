# Updates

What changed, newest first.

---

## 2026-11-16 · First real upload
**Changed:** The pick now follows the day parts of `source.slot_hours` (8, 14, 20 h): the newest day part goes first, the oldest video inside it first, and an empty day part steps back to the one before. Videos made more than `source.max_age_h` (48) hours ago are skipped. This replaces `source.max_age_days`.
**Added:** The tool now asks for two permissions: upload, and read-only (to check your own uploads: processing status, `doctor`, `resolve`). Add both under Data Access in your Google project, then run `login --force` once.
**Added:** `post.include_listing_url`: leave the listing address out of the description.
**Changed:** The default data folder is now `~/.04-clou-data/youtube-shorts`.
**Tested live:** one video uploaded privately to a real channel and processed; its link, privacy, Short status and AI label were checked in YouTube Studio.

## 2026-11-15 · First release
**Added:** Upload finished short videos from a folder to your YouTube channel as Shorts, once each, with `publish`.
**Added:** Safe defaults: videos stay private, carry the AI label and the "made for kids" answer, no subscriber notice, 3 sends a day, a random wait between sends.
**Added:** A ledger that survives crashes and lost answers. If the internet drops after the last byte, the tool asks YouTube instead of uploading again; if it still cannot tell, the video is marked unsure and `resolve` settles it.
**Added:** `scan`, `status`, `doctor` to see what is going on without sending anything.
**Added:** `approve` and `hold` so a person can look at videos marked for review before they go.
**Added:** `login` for the one-time Google sign-in, `token` to check it, `kill` to stop every write at once, `backup` for the ledger.
**Added:** An interrupted upload resumes by itself on the next run; a run that cannot finish in time stops cleanly and picks up where it stopped.
**Known limit:** The first real upload with your own Google account has not been run by the maker of this tool; `10-HOW-TO.md` marks those steps.
