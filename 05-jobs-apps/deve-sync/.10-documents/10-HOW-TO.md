# How To

`EXE` = `~/04-clou-base/05-jobs-apps/deve-sync/zig-out/bin/deve-sync` · `REPO` = `~/04-clou-base` (your repo folder). See `05-README.md` for the quick start.
Every command that writes is a dry-run until you add `--go`.

---

## Build it (once per device)
```
cd ~/04-clou-base/05-jobs-apps/deve-sync && zig build
```
You should see no output and a new file `zig-out/bin/deve-sync`.

---

## See what differs
```
EXE status --repo REPO
```
Each line is one item. **same** = identical · **differ** = both sides have it, but different · **only repo** = the repo has it, this device does not · **only here** = this device has it, the repo does not.
To look at one item only, add `--only claude-agents`.

---

## Set up a new device
1. Get the repo onto the device and run the guard setup from your repo guide. Then fetch the dot-items bundle (it brings the `.deve-user` folder): `bundle-secret fetch --repo REPO --config <bundle-secret>/00-config-ditems.json --go`.
2. Build the program (above).
3. Look: `EXE pull --repo REPO`
4. Do it: `EXE pull --repo REPO --go`
You should see a line like: `pulled: wrote 36 · replaced 0 · installed 2 extension(s)` (your numbers depend on what you share).
5. Restart Claude Code and VS Code. Log in to Claude once; logins are never copied.

---

## Share a change you made on this device
1. Change a setting, an agent or a rule on this device as usual.
2. Look: `EXE push --repo REPO`
3. Send it: `EXE push --repo REPO --go` (or just `EXE sync --repo REPO --go`)
4. The dot-items bundle carries it to your other devices on its own schedule (or run `bundle-secret sync ... --config <bundle-secret>/00-config-ditems.json --go`). On the other devices `EXE sync --repo REPO --go` then applies it.
Only keys named in the config are shared from your Claude settings. Paths and permissions stay on the device.

---

## Keep devices in step (sync)
`EXE sync --repo REPO --go` is the safe everyday command (it also runs by itself on a schedule). A change on one side goes to the other, a missing file comes back, nothing is ever deleted. If you changed the same file on two devices, code and text are merged into one version when the edits do not overlap; otherwise the newest edit wins on both sides and the older copy is moved to the `zzzz-delete-90d` folder in the repo (nothing is lost, nothing to resolve by hand). If you prefer the other version, take it from that folder, or run `EXE push --repo REPO --only claude-agents --go` (this device wins) or the same with `pull` (the repo wins). More than 50 changed files at once are refused; check the list and add `--big`. On a new device with no history, run one `pull` first.

---

## Get your old file back
Before a replace, the old copy goes to `~/.04-clou-secr/deve-backup/<date_time>/<item>/<file>`. Copy it back by hand.

---

## Check that two devices match
```
EXE check --repo REPO
```
You should see `deve_state same` and a `deve_sha256` line. Two devices with the same `deve_sha256` have the same setup. Exit code 3 means something differs.

---

## When something goes wrong
| Message | What to do |
|---|---|
| `push stopped by the secret guard` | The named file looks like a key or password. Remove the secret from it, or add that file to the item's `skip` list in `00-config.json`. Nothing was written. |
| `a settings file on this device is not valid JSON` | Fix that file by hand. It was not touched. Run again. |
| `n/a (editor command not found)` | VS Code's `code` command is not on this device's path. The extension list is skipped. |
| `a link or folder sits where a file should go` | Move that link or folder away, then run again. |
| `unknown item` | Run `status` to see the item names. |
| `config problem ... at line N, column M` | Fix that spot in `00-config.json`. |
| `no repo folder given` | Add `--repo REPO`. |
