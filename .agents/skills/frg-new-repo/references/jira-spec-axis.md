# Give the Spec axis a Jira ticket

Wiring for `.github/workflows/claude-code-review.yml` when this repo tracks work
in Jira. Three edits, and no secret to create: `JIRA_READONLY_TOKEN` is org-level,
the same as `CLAUDE_CODE_OAUTH_TOKEN`.

The point of the extra step: the token stays in a step that runs before the
review agent, and the agent only ever reads a file. That is why `curl` is not on
its tool allowlist.

## 1. Copy the script in

```bash
mkdir -p .github/scripts
cp .claude/skills/frg-new-repo/references/fetch-jira-ticket.sh .github/scripts/
chmod +x .github/scripts/fetch-jira-ticket.sh
```

Read its header comment before wiring it up: it lists every input and every dead
end it swallows. It parses ticket keys out of the PR title; if this repo cites
them elsewhere, change what feeds `PR_TITLE`, not the parsing.

## 2. Add the fetch step

Goes immediately before `Run Claude Code Review`, with `JIRA_KEY_PREFIX` set to
this repo's project key.

```yaml
      # Hand the Spec axis the originating ticket. Runs before Claude so the
      # credential stays in this step and the reviewer only ever reads a file,
      # which is why curl is not on its tool allowlist. See the script for what
      # the token needs and for the dead ends it handles by skipping.
      - name: Fetch the Jira ticket for the Spec axis
        # A backstop only. The script handles every expected dead end itself and
        # exits 0; this makes sure even an unforeseen one cannot stop the review.
        continue-on-error: true
        env:
          JIRA_TOKEN: ${{ secrets.JIRA_READONLY_TOKEN }}
          JIRA_SITE: https://frgrisk.atlassian.net
          JIRA_KEY_PREFIX: XX
          # Read through the environment, never interpolated into the script: a
          # PR title is attacker-controlled and would otherwise run as shell.
          PR_TITLE: ${{ github.event.pull_request.title }}
        run: ./.github/scripts/fetch-jira-ticket.sh
```

## 3. Point the prompt at the file

Replace the Spec axis paragraph in the `prompt:` block with this, so the PR
description stays the fallback rather than the source:

```text
            For the Spec axis, the spec is `jira-tickets.md` in the working
            directory when that file exists: it holds every ticket this PR
            cites, with each ticket's description and recent comments.
            When it doesn't, fall back to this pull request's own description,
            read with `gh pr view ${{ github.event.pull_request.number }} --json title,body`.
            If neither states what was asked for, report the spec as unavailable
            rather than inferring it from the diff.
```

## 4. Nothing to do about the token

`JIRA_READONLY_TOKEN` is an org-level scoped Atlassian API token, holding
`read:jira-work` and nothing else, so this repo inherits it. If it is ever unset,
the fetch skips and the review falls back to the PR description: a missing token
degrades the review rather than breaking it.

Scoped tokens must go through `api.atlassian.com`, which the script handles; the
site URL answers 401.
