# Config Reference

Plain facts. All settings live in `00-config.json` next to the program (pass `--config <path>` from another folder). An unknown or wrong setting is refused with its line and column.

---

## The Program
| Item | Value |
|---|---|
| File | `bundle-secret` (`.exe` on Windows) |
| Run | `bundle-secret <pack\|unpack\|check\|fetch\|ship\|keep-pass\|status\|version\|help> --repo <folder> [flags]` |
| Flags | `--repo` · `--config` · `--home` · `--bundle-root` · `--go` · `--rekey` (pack, ship: replace a bundle another passphrase made) · `--replace` (fetch: replace a differing local file) · `--reseed` (token files in `pick.seed_only`: pack/ship publish this device's copy, fetch/unpack take the bundle's copy) |
| Exit codes | 0 ok · 1 failed · 2 usage or config · 3 `check` found a difference, `fetch` kept a local file, or `ship` is behind |
| Built with | Zig 0.16.0, standard library only |

---

## Settings
| Key | What | Default |
|---|---|---|
| `pick.dirs` | folder names whose files are picked | `[".secrets"]` |
| `pick.files` | file patterns picked anywhere (`*` = any run) | `*token.json`, `*client_secret.json`, `*credentials.json` |
| `pick.skip_dirs` | folder names never entered | `.git`, `zig-out`, `.zig-cache`, `node_modules`, `zzzz-dele-90da`, `zzzz-delete-force-items` |
| `pick.skip_markers` | a folder holding one of these files is a browser profile and is skipped | `Local State`, `Preferences` |
| `pick.skip` | path patterns to leave out. Sessions (saved logins) are per device, so they are not shared | `*session*` |
| `pick.seed_only` | files a program rewrites by itself (refreshed tokens). A new device gets them once; after that they are never compared or replaced, and a refreshed copy never makes a new bundle. `--reseed` overrides this on purpose | `*token.json` |
| `pick.file_maxz_kbyt` | biggest file picked (KB) | 256 |
| `pick.total_maxz_mbyt` | biggest bundle (MB); more is refused | 64 |
| `bundle.root` | folder that holds the bundle (the vault repo). `{home}` = your home. Empty = the repo being scanned. Must be empty, start with `{home}`, or be absolute | `{home}/04-clou-vaul` |
| `bundle.path` | the bundle file name, relative to `bundle.root` | `bundle-secret.enc` |
| `bundle.need_git` | refuse to write the bundle unless `bundle.root` is a git checkout (has `.git`) | `true` |
| `bundle.pass_file` | local file that holds the passphrase (`keep-pass` writes it, owner-only). Empty = never use a file | `{home}/.04-clou-secr/04-clou-vaul.pass` |
| `bundle.pass_envz` | env variable that may hold the passphrase | `BUNDLE_SECRET_PASS` |
| `bundle.pass_min` | shortest passphrase for `pack` | 16 |
| `git.bin` | the git program | `git` |
| `git.timeout_secs` | give up on one git command after this many seconds | 120 |
| `fetch.on_differ` | `keep` leaves a local file that differs; `replace` takes the bundle's value (old copy to the trash) | `keep` |
| `ship.message` | the commit message `ship` uses | `update bundle` |
| `state.file` | remembers which bundle this device last absorbed (so `ship` can tell it is behind) | `{home}/.04-clou-secr/bundle-secret-state.json` |
| `argon.time` / `argon.memo_kbyt` / `argon.para` | lock cost | 3 / 65536 / 1 |
| `unpack.file_mode` | mode of restored files (owner only) | `600` |
| `unpack.trash` | where a replaced local file is saved (`{home}` = your home) | `{home}/.04-clou-secr/bundle-trash` |

---

## Files
| What | Where |
|---|---|
| The bundle | `<bundle.root>/<bundle.path>` (commit and push it in the vault repo) |
| Old local copies | `unpack.trash/<yyMMdd_HHmmss>/<path>` (outside both repos, never committed) |
| Sync state | `state.file` (one line, the bundle's sha256; written by `pack --go`, `unpack --go`, `fetch --go`, `ship --go`) |
| Passphrase | first found: the env variable (`bundle.pass_envz`), then `bundle.pass_file` (owner-only), then typed hidden. Never in git |

---

## Second settings file (`00-config-ditems.json`)
Same settings as above, tuned for dot-items. Different values:
| Setting | Value | Why |
|---|---|---|
| `bundle.path` | `bundle-ditems.enc` | its own locked file in the same vault repo |
| `pick.dirs` / `pick.files` | none / `.*` and `*/.*` | every dot-folder and dot-file, at any depth |
| `pick.skip` | public docs, `.github`, `.gitignore`, key and password files, per-device settings, `*session*`, `*history*` | these stay out of the bundle |
| `pick.file_maxz_kbyt` | `512` | the biggest note is about 230 KB |
| `fetch.on_differ` | `replace` | a changed file is updated; the old copy goes to the trash |
| `state.file` / `unpack.trash` | own files (`bundle-ditems-state.json`, `bundle-ditems-trash`) | never mixed with the secrets bundle |

---

## Sync settings (`sync`)
| Setting | What it does | Default | Allowed |
|---|---|---|---|
| `sync.merge_globs` | files that may be merged into one version when both sides changed them (empty = never merge, the secrets default) | none; the dot-items file lists code and text types | any list of patterns |
| `sync.retired` | paths you moved or renamed on purpose: ignored on both sides, never brought back, never deleted | none | any list of paths or patterns |
| `sync.move_min_bytes` | a file smaller than this (bytes) is never taken for a rename | `16` | 1 to 1048576 |
| `sync.move_min_sim` | percent of the text that must stay the same for a rename plus an edit to count as a rename (a new file name needs 20 more) | `60` | 30 to 80 |
| `sync.tie_secs` | two edits this close (seconds) count as the same moment: the vault copy wins | `120` | 0 to 86400 |
| `sync.trash_dir` | folder in the repo that receives the losing copy of a conflict (same relative path) | `zzzz-dele-90da` | one folder name |
| `sync.big_files` | most files one run may change on one side without `--big` | `50` | 1 to 1000000 |
| `sync.base_dir` | where this device remembers what it and the vault last agreed on | `{home}/.04-clou-secr/bundle-secret-base` | starts with `{home}`, or absolute |
