# prune-home-caches

Instructions for coding agents in this repository. `CLAUDE.md` imports this file,
so every agent reads the same thing.

## Conventions

- **Commits**: [Conventional Commits](https://www.conventionalcommits.org/).
- **PRs**: squash merge only. The squash commit takes the PR title and
  description, so write them as the permanent commit message.
- **Copyright headers**: added by the `addlicense` pre-commit hook. Never write
  them by hand.
- **Shell**: `bash-defensive-patterns` is the bar, and `shellcheck` runs as a
  pre-commit hook. See [Shell conventions](#shell-conventions) below for what
  that means in practice.
- **Pre-commit**: `make pre-commit-install` once per clone; `make pre-commit` to
  run every hook. `make` lists all targets.

## Project context

This repo versions and packages `prune-home-caches`, a bash tool that reclaims disk space on the `/home` mount of
shared development servers. The tool is finished, tested, and running in production, where its first full run
took a shared `/home` from 94% to 56%. **The work here is packaging and distribution, not development.** Don't
rewrite, refactor or "improve" the script, units, tests or spec.

It prunes in three stages:

| Stage      | Target                                             | Policy                                                                                                                          |
| ---------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `builds`   | VS Code Remote server builds, Claude Code binaries | 30-day age gate; never removes a build in use by a running process, the newest per user, or the target of `~/.local/bin/claude` |
| `cache`    | every user's `~/.cache`                            | wholesale, no age gate                                                                                                          |
| `modcache` | every user's `~/go/pkg/mod`                        | wholesale, no age gate                                                                                                          |

Ships as a noarch RPM that installs a systemd timer running weekly with `Persistent=true`. See
[`README.md`](README.md) for the operator runbook.

The script needs only bash ≥ 4.2, GNU coreutils, GNU findutils (`find -printf`) and `ps`, and assumes homes live
under `/home`.

The spec builds natively on EL8, EL9 and EL10, each picking up its own dist tag. A release ships all three,
every one built and verified on its own EL: units verify, 25 assertions pass. Don't widen the claim past EL10
without adding a matrix leg to `release.yml` and proving it there.

### Layout

```text
src/            prune-home-caches.sh, test-prune-home-caches.sh
systemd/        prune-home-caches.service, prune-home-caches.timer
rpm/            prune-home-caches.spec
```

If you move a file, update `Source0` and `%install` in the spec to match, then rebuild to confirm.

### Testing

The harness builds a throwaway fixture under `mktemp -d` and never touches the real `/home`, so it is
container-safe. It needs root:

```bash
sudo ./src/test-prune-home-caches.sh ./src/prune-home-caches.sh   # expect: 25 passed, 0 failed
```

Also check `bash -n` on both scripts, `shellcheck`, and `systemd-analyze verify` on the units. The last one is
not optional; see the traps below.

### Traps

Four bugs found the hard way. The comments in the source explaining them are load-bearing; keep them.

| Don't                                    | Why                                                                                                                     |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `ProtectHome=read-write` in the service  | Not a valid value. systemd **ignores the line** and only warns. Caught solely by `systemd-analyze verify`.              |
| Add `OnBootSec=` alongside `OnCalendar=` | Monotonic trigger; on a long-booted host it fires immediately and leaves `NEXT` empty, so the weekly run never happens. |
| Drop `\|\| true` after `ps ... \| grep`  | grep exits non-zero when nothing matches, which is the common case, aborting the script under `set -e`.                 |
| Test Claude versions with `-d`           | They are files, not directories. An early draft silently listed **every user's active binary** for deletion.            |

`ExecStart` must match the packaged path (`/usr/sbin/`, not `/usr/local/sbin/`). Nothing in `rpmbuild` checks
this; verify by extracting the built RPM.

### Non-goals

- Don't broaden scope to logs, databases or general disk cleanup. The narrow contract is deliberate.
- Don't add an age gate to `cache` or `modcache`. Wholesale was an explicit operator decision, accepted knowing
  it forces a weekly re-download of Go modules and `pre-commit` environments.
- Don't convert back to cron. `Persistent=true` is required because these hosts are not reliably up at the
  scheduled time.
- No config file. Behavior is controlled by flags: `--dry-run` `--age-days N` `--user NAME` `--no-builds`
  `--no-cache` `--no-modcache` `--debug`.

### Shell conventions

The script follows the `bash-defensive-patterns` skill: `set -Eeuo pipefail`, an ERR trap, `[[ ]]`, `local -r`,
leveled logging, `command -v` dependency checks, validated inputs, `printf` over `echo`, and no `ls` parsing.
It was audited against that standard, and a follow-up audit fixed three gaps (undeclared dependencies, an
unvalidated `--user` permitting path traversal, swallowed stderr). Hold new contributions to the same bar.

## Agent skills

### Issue tracker

GitHub Issues in `frgrisk/prune-home-caches`, driven by the `gh` CLI. See
`docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles, each label string equal to its name. See
`docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and one `docs/adr/` at the repo root. See
`docs/agents/domain.md`.
