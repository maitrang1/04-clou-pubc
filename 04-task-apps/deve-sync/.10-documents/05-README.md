# Deve Sync

Makes Claude Code and VS Code look and behave the same on every computer you use, from one folder in your repo.
Nothing goes to any cloud service. Nothing is ever deleted.

---

## What it does
You keep your shared rules, agents, Claude settings, VS Code settings and extension list in one folder, `.deve-user`, inside your repo. The folder starts with a dot, so it travels through your locked dot-items bundle (see the bundle tool's guide), not through git. This program copies it into place on a new device (`pull`) and sends your changes back into the folder (`push`). Settings that belong to one computer only, such as folder paths, permissions and logins, stay where they are.

---

## Requirements
- Your repo folder with a `.deve-user` folder in it (a first `push` creates it).
- Windows, Linux or macOS.
- VS Code on the device, only if you want the extension list synced.

---

## Quick Start
1. Look first (changes nothing):
```
~/04-clou-base/04-task-apps/deve-sync/zig-out/bin/deve-sync status --repo ~/04-clou-base
```
You should see one line per item, for example:
```
claude-md              1 same · 0 differ · 0 only repo · 0 only here
vscode-extensions      2 same · 0 differ · 0 only repo · 0 only here
```
2. Set up a new device (shows the plan, writes nothing):
```
~/04-clou-base/04-task-apps/deve-sync/zig-out/bin/deve-sync pull --repo ~/04-clou-base
```
3. Do it for real:
```
~/04-clou-base/04-task-apps/deve-sync/zig-out/bin/deve-sync pull --repo ~/04-clou-base --go
```

---

## Where files go
Your Claude files go to the `.claude` folder in your home folder. VS Code files go to its normal user folder for your system. Before a different file is replaced, the old copy is saved in `~/.04-clou-secr/deve-backup`. Files that exist only on your device are left alone.

---

## Next
- **`10-HOW-TO.md`** — every command, with steps
- **`15-CONFIG.md`** — every setting and what is shared
- **`20-UPDATE.md`** — what changed, by date
