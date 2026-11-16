# Config Reference

Plain facts: what is shared, where it goes, what the settings mean. For steps, see `10-HOW-TO.md`.

---

## The Program
| Item | Value |
|---|---|
| File | `~/04-clou-base/05-jobs-apps/deve-sync/zig-out/bin/deve-sync` |
| Run | `deve-sync <status\|check\|pull\|push\|version\|help> --repo <folder> [--config <file>] [--home <folder>] [--only <item>] [--go]` |
| Settings file | `~/04-clou-base/05-jobs-apps/deve-sync/00-config.json` (or `--config`) |
| Built with | Zig 0.16.0, no other software |

---

## Settings (`00-config.json`)
Every setting is required unless marked optional. A wrong or unknown setting is refused with its line and column.

| Setting | What it does | Default | Allowed |
|---|---|---|---|
| `vers` | file format number | `1` | `1` |
| `src` | folder inside the repo that holds the shared copy | `.deve-user` | one plain folder name |
| `claude_envz` | environment variable that moves Claude's folder | `CLAUDE_CONFIG_DIR` | letters, digits, `_` |
| `file_maxz_kbyt` | biggest file that is synced, in KB (bigger files are skipped and counted) | `512` | 1 to 4096 |
| `backup_dir` | where old copies go before they are replaced | `{home}/.04-clou-secr/deve-backup` | starts with `{home}` or `{appdata}`, or absolute |
| `roots.claude` | Claude's folder per system (`linux`, `macos`, `windows`) | `{home}/.claude` | same as `backup_dir` |
| `roots.vscode` | VS Code's user folder per system | system default | same as `backup_dir` |
| `scan.names` | file name patterns that stop a push (`*` = any text) | key, token, secret, password-like names | any list |
| `scan.text` | text markers that stop a push | common key prefixes | any list |
| `sync.tie_secs` | two edits this close (seconds) count as the same moment: the repo copy wins | `120` | 0 to 86400 |
| `sync.trash_dir` | folder in the repo that receives the losing copy of a conflict (same relative path) | `zzzz-delete-90d` | one folder name |
| `sync.big_files` | most files one run may change on one side without `--big` | `50` | 1 to 1000000 |
| `sync.base_dir` | where this device remembers what it and the repo last agreed on | `{home}/.04-clou-secr/deve-base` | starts with `{home}` or `{appdata}`, or absolute |
| `sync.merge_globs` | files that may be merged into one version when both sides changed them | code and text types | any list |
| `sync.git_bin` | the git command used for the merge | `git` | one word, no spaces |
| `vscode.bin` | the VS Code command | `code` | one word, no spaces |
| `vscode.tmos_secs` | time limit for that command | `120` | 5 to 600 |
| `items` | the list of things to sync (below) | 12 items | at least one |

`{home}` = your home folder · `{appdata}` = the Windows app-data folder · `{repo}` = the repo folder.

### One item (`items`)
| Setting | What it does | Allowed |
|---|---|---|
| `id` | the item's name (used by `--only`) | letters, digits, `-`, `_`; unique |
| `kind` | `file` one file · `dir` a whole folder · `merge` chosen keys of a JSON file · `exts` an extension list | those four |
| `root` | which folder `to` is inside: `claude`, `vscode` or `repo` | those three |
| `to` | path inside that folder (not used by `exts`) | relative, `/` only, no `..` |
| `from` | path inside the shared folder (optional for `merge` with only `set`) | relative, `/` only, no `..` |
| `keys` | `merge`: the JSON keys that are shared (optional) | plain names |
| `set` | `merge`: keys written on this device from a template, never sent back (optional) | `key` and `value`, value may use `{repo}` |
| `skip` | patterns of files to leave out (optional) | any list |

---

## What is shared
| Item | Goes to |
|---|---|
| Your Claude rules file | `CLAUDE.md` in Claude's folder |
| Shared Claude settings | only the listed keys of `settings.json` |
| Claude agents, skills, rules, commands, keybindings | the same names in Claude's folder |
| VS Code settings, keybindings, snippets | VS Code's user folder |
| VS Code extension list | installed with VS Code's own command |
| Memory folder path | `.claude/settings.local.json` in the repo, for this device only |

## What is never shared
Logins and credentials, sessions and chat history, caches, backups, plugins, and anything else Claude or VS Code writes while it runs.

---

## Output
| Item | Value |
|---|---|
| Exit code | 0 ok · 1 failed · 2 wrong use or config · 3 not in sync (`check`) |
| Old copies | `backup_dir/<date_time>/<item>/<file>`, owner-only |
| Fingerprint | the `deve_sha256` line of `check` |

---

## Files In This Tool
```
00-config.json   — all settings
.10-documents/   — these guides
```
