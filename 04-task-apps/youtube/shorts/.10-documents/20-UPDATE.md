# Updates

What changed, newest first.

---

## 2026-11-20 · Fully automatic
**Removed:** the review and approval step. `approve`, `hold` and `approval.require_for_review` are gone; a `review` field in the video json is ignored, and every good video is sent on its own.
**Added:** `limits.retry_max` (default 2): a video that failed before its upload started is tried again on later runs. Old `held` rows are read as `ready`.
**Changed:** the daily cap default is now 8. `status` and `scan` no longer show a held list.

---

## 2026-11-16 · Better titles
**Changed:** The video title now starts with the car name, then the hook, in Title Case: `Ford Everest 2022. SUV Bảy Chỗ Máy Dầu Nhập Khẩu`. Set `post.title_pattern` and `post.title_case` to change it. The description and tags are unchanged.
**Changed:** The publish result is now two lines: `publish: <name>: posted and processed`, then the video link.

## 2026-11-16 · First real upload
**Changed:** The title body now comes from the video details file's own `title` when it has one. Without it, the first hook that is not spelled-out number text is used ("Ba mươi hai nghìn km" is skipped). Units after a number stay lowercase: `30.000 km`.
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
