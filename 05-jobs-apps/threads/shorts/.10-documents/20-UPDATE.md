# Updates

What changed, newest first.

---

## 2026-11-16 · First release
**Added:** Post finished short videos to one Threads account, once each. Nothing is made public unless you allow it: by default the post is prepared at Threads and stops there (`staged`).
**Added:** Threads cannot take a file upload, so the tool copies each video into a web folder you own and gives Threads that public address. The copy is moved aside afterwards, never deleted.
**Added:** A record of every post, a daily limit, a wait between posts, a check of Threads' own allowance, and a stop after repeated failures.
**Added:** Unclear answers are never resent: `resolve` asks Threads and settles them. Before posting, the tool also reads your recent posts and refuses to post the same text twice, even if its own record was lost.
**Added:** Only one computer may post for an account (`device.publisher`). Every post carries the AI label and your AI notice text.
**Added:** The 60-day token is renewed automatically before it runs out.
**Added:** `doctor`, `status`, `scan`, `token`, `approve`, `hold`, `resolve`, `kill`, `backup` and `config` commands. Every write is a preview unless you add `--live`.
