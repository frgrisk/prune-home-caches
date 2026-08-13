# template-repo

> [!IMPORTANT]
> Just generated a repo from this template? Run **`/frg-new-repo`** in an agent
> session. It walks the whole setup, after which you can replace this README with
> your own.

The foundation for new FRG repositories. **Use this template** on GitHub to inherit
FRG's pre-commit hooks, CI, Dependabot config, and the agent skills FRG
standardizes on.

## What you get

| Path | Purpose |
| --- | --- |
| `AGENTS.md` + `CLAUDE.md` | Agent instructions; `CLAUDE.md` imports `AGENTS.md` |
| `.agents/skills/` + `.claude/skills/` | `frg-brand-materials`, refreshed weekly by CI, plus `frg-new-repo` |
| `Makefile` | `make` to list targets |
| `.pre-commit-config.yaml` | Copyright headers, secret scanning, hygiene, ruff, `uv lock` |
| `.github/workflows/` | Pre-commit checks; Claude code review on every PR; weekly skill updates |
| `.github/dependabot.yml` | Monthly Actions and pre-commit hook bumps |
| `.gitattributes` / `.gitignore` | LF endings, vendored-skill handling, standard ignores |

## Agent skills

### From a plugin

The engineering flow (`tdd`, `code-review`, `triage`, `to-spec`, `wayfinder`,
`domain-modeling`, and 16 more) comes from
[`mattpocock-skills`](https://github.com/mattpocock/skills) in the
`claude-plugins-official` marketplace. Install it once per user:

- **Claude Code**: enabled for this repo in `.claude/settings.json`; accept the
  install prompt.
- **Codex**: `codex plugin add mattpocock-skills@claude-plugins-official`. If that
  marketplace isn't registered yet, run
  `codex plugin marketplace add anthropics/claude-plugins-official` first.

Those are the only two agents with a plugin route to this marketplace. Skills are
namespaced, so run **`/mattpocock-skills:ask-matt`** to find the right one for a
task.

### Vendored into the repo

`/frg-brand-materials` from `frgrisk/skills`, for on-brand decks, proposals, and
reports. Pinned in `skills-lock.json`, so it works offline. Plus `/frg-new-repo`,
which scaffolds a fresh repo and then deletes itself.

`./update-skills.sh` refreshes this tree; CI runs it weekly and opens one rolling
PR. Change a vendored skill upstream rather than here, since the next run overwrites
local edits.

## Notes

- **Python tooling runs through uv.** There's no `pyproject.toml`, because this
  template seeds Go, Terraform, and docs repos too. `make` installs pre-commit into
  a gitignored local `.venv`; see [`AGENTS.md`](AGENTS.md) if the repo grows Python.
- **Repository settings aren't inherited.** GitHub templates copy files only.
  `/frg-new-repo` names the ones to apply.
