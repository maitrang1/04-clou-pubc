# Updates

What changed, newest first.

---

## 2026-11-15
**Added:** `sync`, the safe two-way command (never deletes; a missing file comes back; a file changed on two devices is merged into one version or both copies are kept and nobody wins). `pull` now makes the repo win and `push` makes this device win, and neither undoes a change the other side made alone. A change of more than 50 files needs `--big`.
**Changed:** the shared folder is now `.deve-user` (a dot-folder) and travels through the locked dot-items bundle, not through git. Run the bundle tool's `ship` after a `push`, and `fetch` before a `pull` on another device.
**Added:** first version. `status`, `check`, `pull`, `push`. Keeps Claude rules, agents, shared Claude settings, VS Code settings and the extension list the same on every device, through one folder in your repo.
**Safe by design:** nothing is deleted; a replaced file is saved first; a file that looks like a secret stops a push before anything is written; device-only settings (paths, permissions, logins) are never shared.
**Check:** `check` prints one fingerprint line; two devices with the same line have the same setup.
**Tested:** 27 unit tests and a two-device run in scratch folders (50 checks). Built for Windows and macOS, not run there yet.
