---
name: frg-new-repo
description: Scaffold a repo created from frgrisk/template-repo. Use when AGENTS.md still starts with `# TODO:`, when `docs/agents/` is missing, or when the user asks how to set up a new FRG repo.
---

# Scaffold a new FRG repo

Scaffolding for day one, deleted on the way out. This skill exists only until the
repo is its own.

Work the steps in order, confirming each with the user before starting the next.

## 1. Install the git hook

```bash
make pre-commit-install
```

**Done when** `.git/hooks/pre-commit` exists and running it exits 0.

Every developer repeats this in every clone: `.git/` is never tracked, so no
template and no `git clone` carries the hook across.

## 2. Install the engineering skills

The `mattpocock-skills` plugin is enabled for this repo in `.claude/settings.json`,
so Claude Code prompts to install it. On Codex:

```bash
codex plugin add mattpocock-skills@claude-plugins-official
```

If that marketplace isn't registered yet, run
`codex plugin marketplace add anthropics/claude-plugins-official` first.

**Done when** `/mattpocock-skills:ask-matt` resolves. Step 3 needs a skill from this
plugin.

Per-user, so each developer repeats it once. It replaces vendoring the skill files:
the plugin updates when upstream ships.

## 3. Configure the issue tracker

Run **`/mattpocock-skills:setup-matt-pocock-skills`**.

**Done when** `docs/agents/issue-tracker.md` and `docs/agents/domain.md` exist.

Nothing ships under `docs/agents/` by design. Where a repo tracks work is the one
thing a template cannot guess: GitHub Issues, Jira, or a hybrid like vor-stream's
Discussions-then-Jira. `triage`, `to-tickets`, and `to-spec` all read these files.

On GitHub Issues, tell the user the four triage labels need creating:
`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`. `wontfix`
already exists as a GitHub default.

## 4. Point the review workflow at this repo

`.github/workflows/claude-code-review.yml` reviews every PR with the same two-axis
`code-review` skill developers run locally. It authenticates with the org-level
`CLAUDE_CODE_OAUTH_TOKEN`, so nothing needs configuring. Two parts of it are
template defaults, though, written for a repo with no tracker and no code.

**The Spec axis's source**, now that step 3 has named a tracker. It defaults to
the PR's own description:

- **GitHub Issues**: `gh` is already on the tool allowlist, so tell the prompt to
  read the issue the PR closes.
- **Jira**: follow `references/jira-spec-axis.md`. It carries the fetch script to
  copy in, the workflow step, and the prompt change. Its token is org-level too.

**The tooling gate list.** The prompt names pre-commit as this repo's only gate,
so the reviewer skips what the hooks already catch. Name every check added since
(test suites, linters, a container build), or the reviewer re-reports what they
already found. `--allowedTools` needs the same pass: add the read-only commands
this stack investigates with, like `Bash(go doc:*)`.

**Done when** the prompt names this repo's real spec source and real checks, and
nothing in it still describes the template.

## 5. Make the docs the repo's own

Read what the repo actually contains, then draft real content for both:

- **`AGENTS.md`**: the `# TODO: repo name` title and the **Project context**
  section. Leave Conventions as it is.
- **`README.md`**: replace it wholesale, including the template notice on top.

**Done when** neither file contains `TODO: repo name`, `_Not yet written._`, or the
template notice.

## 6. Hand off the repository settings

GitHub templates copy files only, so this repo currently has no branch protection,
the factory merge defaults, and only GitHub's nine default labels. FRG runs
squash-merge only, with the squash commit taking the PR title and body, plus a
ruleset on the default branch.

These are settings rather than files, tracked outside the repo. Name them to the
user as their next action and move on.

**Done when** the user has been told which settings to apply.

## 7. Delete this skill

```bash
rm -rf .agents/skills/frg-new-repo .claude/skills/frg-new-repo
```

Absent from `skills-lock.json`, so `update-skills.sh` never restores it. Deletion
is permanent, which is the point.

**Done when** both paths are gone and the deletion is committed.

## Then

Point the user at **`/mattpocock-skills:ask-matt`**: it takes a situation and names
the skill or flow that fits. It ships with the plugin and stays current with it, so
let it do the routing.
