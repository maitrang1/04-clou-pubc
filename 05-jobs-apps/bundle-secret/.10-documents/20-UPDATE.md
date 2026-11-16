# Updates

What changed, newest first.

---

## 2026-11-16
**Added:** renames follow by themselves. `sync` notices a file with the same content under a new name, drops the old name from the vault and moves the old copy on your other devices to the trash folder. Two identical files, or a rename plus an edit, are not treated as a rename (the old name just comes back). New setting `sync.move_min_bytes`.

## 2026-11-15
**Added:** `sync`, `pull` and `push`. `sync` is two-way and never deletes anything: a change goes to the other side, a missing file comes back; a file changed on both sides is merged into one version (code, text) or the newest edit wins and the older copy goes to the `zzzz-delete-force-items` folder. `pull` makes the vault win, `push` makes this device win. A change of more than 50 files needs `--big`.
**Added:** a second locked file for your dot-folders and dot-files (`bundle-ditems.enc`, settings in `00-config-ditems.json`), next to the secrets bundle in the same vault repo with the same passphrase. A changed file is replaced on fetch and the old copy goes to the trash.

**Changed:** the default vault folder is `~/04-clou-vaul` and the saved passphrase file is `~/.04-clou-secr/04-clou-vaul.pass`. Rename your own folders or change `bundle.root` and `bundle.pass_file` in the settings.

## 2026-11-14
**Added:** first version. `pack`, `unpack`, `check`, `status`. Locks your secret files into one file with a passphrase (Argon2id + AES-256-GCM), refuses unsafe paths, saves a replaced local file to a trash folder, leaves the file alone when nothing changed.
**Sessions not shared:** saved logins (`*session*`, `pick.skip`) stay per device; a login on two machines can make Facebook or Zalo flag the account.
**`--reseed`:** after you re-authorize a token on one device, `ship --reseed` publishes it; on a device that has an old or revoked token, `fetch --reseed` takes the bundle's copy (old copy to the trash). Without it token files are never compared.
**Seed-only files:** tokens a program refreshes by itself (`*token.json`, `pick.seed_only`) are copied to a new device once, then never compared or replaced, and a refreshed copy no longer makes a new bundle.
**Fetch and ship:** `fetch --go` pulls the vault repo and writes new secrets (a local file that differs is kept). `ship --go` locks, commits only the bundle and pushes, and refuses when another device shipped a newer bundle. Both are dry-runs without `--go`.
**Passphrase file:** new `keep-pass` saves the passphrase to an owner-only file on this device (checked against the bundle first), so you need not type it. The program refuses the file if others can read it. Keep one offline copy too.
**Own repo:** the bundle now lives in its own small private repo (`bundle.root`, default `~/04-clou-vaul`), not in your code repo. The vault repo accepts only the bundle and a README.
**Renamed:** `secret-bundle` is now `bundle-secret` (file `bundle-secret.enc`, env `BUNDLE_SECRET_PASS`).
**Safer:** a bundle another passphrase made is never replaced by accident (`--rekey` to do it on purpose).
**Tested:** 34 unit tests and a two-device, two-repo run in scratch folders (51 checks). Not run on Windows or macOS.
