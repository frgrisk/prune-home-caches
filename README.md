# prune-home-caches

Reclaims disk space on the `/home` mount of shared development servers. Ships as a noarch RPM that installs a
weekly systemd timer.

It was written for a shared `/home` that had hit 94% full. The cause was tooling caches, not user data. The
first full run took it to 56%.

## Requirements

The script itself needs only bash ≥ 4.2, GNU coreutils, GNU findutils (it uses `find -printf`), and `ps`. It
assumes user home directories live under `/home`.

Packaging is a noarch RPM, and the spec builds on EL8, EL9 and EL10, each taking its own dist tag. Releases
publish the el9 build, which installs cleanly on all three, with the units verifying and all 25 assertions
passing.

On a systemd distro outside that family, install `src/prune-home-caches.sh` and the two units by hand. Nothing
in them is RHEL-specific.

---

## What runs

```text
prune-home-caches.timer          Sun 03:30 UTC, Persistent=true
└── prune-home-caches.service
    ├── builds     VS Code server builds + Claude binaries   [30d age gate]
    ├── cache      every user's ~/.cache                     [wholesale]
    └── modcache   every user's ~/go/pkg/mod                 [wholesale]
```

`Persistent=true` means a powered-off Sunday catches up on next boot.

The **builds** stage keeps anything in use by a running process, anything that is the newest build for that
user, and the current target of `~/.local/bin/claude`. The **cache** and **modcache** stages have no age gate,
because everything there regenerates.

---

## Why /home fills up

VS Code Remote never garbage-collects server builds. It keeps one directory per release, ~380MB each, forever,
and they accumulate per user. Same pattern for the Claude Code extension.

Where the space went on the host this was written for:

| Share of reclaimed space |      |
| ------------------------ | ---- |
| VS Code + Claude builds  | ~45% |
| `~/go/pkg/mod`           | ~22% |
| `~/.cache`               | ~20% |

The remainder was smaller caches, not itemized. Measure your own with `--dry-run` before deploying.

---

## Commands

```bash
systemctl list-timers prune-home-caches.timer   # next run
journalctl -u prune-home-caches.service -n 30   # last run
sudo systemctl start prune-home-caches.service  # run now, for real

sudo /usr/sbin/prune-home-caches.sh --dry-run   # preview
```

Flags: `--dry-run` `--age-days N` `--user NAME` `--no-builds` `--no-cache` `--no-modcache` `--debug`

Exit codes: `0` ok · `1` runtime · `2` usage

A default run legitimately does nothing until builds pass 30 days. To confirm it still works:
`--dry-run --age-days 0 --debug`.

---

## Known costs

Accepted deliberately, since the weekly cadence makes them cheap:

- A full modcache wipe drops `cache/download`, so Go re-fetches all deps from GOPROXY (**network required**)
- `pre-commit` envs live in `~/.cache`; the first commit after a run rebuilds them (**network, minutes**)
- Someone compiling at 03:30 Sunday may see a transient error

Opt out per stage with `--no-cache` / `--no-modcache`.

---

## Deploying to a host

Install enables the timer automatically. Take the package straight from a release:

```bash
sudo dnf install https://github.com/frgrisk/prune-home-caches/releases/download/v1.0.0/prune-home-caches-1.0.0-1.el9.noarch.rpm
sudo dnf remove prune-home-caches      # disables the timer cleanly
```

The asset name carries the version, so the URL pins a tag rather than tracking `latest`. `gh release download
v1.0.0 --repo frgrisk/prune-home-caches` fetches it without hand-writing the path.

After installing, confirm `systemctl list-timers` shows a non-empty `NEXT`. Empty means it will never fire.

Build the RPM on any host with `rpm-build`. The spec takes a source tarball, so produce one from the checkout
first:

```bash
mkdir -p rpmbuild/SOURCES
git archive --format=tar.gz --prefix=prune-home-caches-1.0.0/ \
    -o rpmbuild/SOURCES/prune-home-caches-1.0.0.tar.gz HEAD
rpmbuild --define "_topdir $PWD/rpmbuild" -bb rpm/prune-home-caches.spec
```

The prefix must match `%{name}-%{version}`, or `%setup` won't find the tree.

### Cutting a release

Pushing a `v*` tag builds the RPM in an `almalinux:9` container, installs it, verifies the units and the
packaged `ExecStart` path, then attaches the package to a GitHub release. The tag must match `Version` in the
spec, or the build stops before publishing anything. Run the workflow manually to exercise the build without
spending a version number.

### Installed paths

```text
/usr/sbin/prune-home-caches.sh                  # the script
/usr/sbin/test-prune-home-caches.sh             # test harness
/usr/lib/systemd/system/prune-home-caches.*     # unit files (package-owned)
/usr/share/doc/prune-home-caches/README.md      # this document
/usr/share/licenses/prune-home-caches/LICENSE   # MIT
```

The service is sandboxed: `ProtectSystem=strict` plus `ReadWritePaths=/home` means a bug cannot write outside
`/home`.

Do not drop copies of the units into `/etc/systemd/system/`. Those shadow the package-owned ones and survive
`dnf remove`.

---

## Before editing

Run the tests. They use a throwaway fixture and never touch the real `/home`, but they do need root:

```bash
sudo ./src/test-prune-home-caches.sh ./src/prune-home-caches.sh
# 25 passed, 0 failed
```

Four traps, all found the hard way. The comments explaining them are load-bearing:

| Don't                               | Why                                                                                                                     |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `ProtectHome=read-write`            | Not a valid value. systemd **ignores the line** and warns. Only `systemd-analyze verify` catches it.                    |
| `OnBootSec=` with `OnCalendar=`     | Monotonic trigger; on a long-booted host it fires immediately and leaves `NEXT` empty, so the weekly run never happens. |
| Drop `\|\| true` after `ps \| grep` | grep exits 1 when nothing matches, which is the common case, so the script aborts under `set -e`.                       |
| Test Claude versions with `-d`      | They are files, not dirs. An early draft listed **every user's active binary** for deletion.                            |

The script follows `bash-defensive-patterns`: `set -Eeuo pipefail`, an ERR trap, `[[ ]]`, `local -r`, leveled
logging, `command -v` dependency checks, validated inputs, `printf` over `echo`, and no `ls` parsing.

See [`AGENTS.md`](AGENTS.md) for the repo layout and the full contributor contract.
