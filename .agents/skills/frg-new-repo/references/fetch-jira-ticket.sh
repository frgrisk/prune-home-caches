#!/usr/bin/env bash
# Copyright 2026 The Financial Risk Group, Inc.
#
# Write the Jira ticket(s) a pull request cites into a markdown file, for the
# Spec axis of the Claude Code Review workflow to read.
#
# This runs as its own workflow step, before the review agent, so the Jira
# credential stays here: the agent reads the file and never sees the token.
# That is why curl is not on the agent's tool allowlist.
#
# Nothing here is worth failing a review over. Every expected problem (no token,
# no cited ticket, Jira unreachable, a token that has expired) logs and exits 0
# leaving no file, and the review falls back to the pull request description.
#
# Requires: curl, jq. Reads its inputs from the environment:
#   JIRA_TOKEN        scoped API token with read:jira-work (empty disables the fetch)
#   JIRA_SITE         e.g. https://frgrisk.atlassian.net
#   JIRA_KEY_PREFIX   this repo's Jira project key, e.g. VS
#   PR_TITLE          pull request title, which is where a PR cites ticket keys
#   OUT_FILE          path to write (default: jira-tickets.md)
#
# PR_TITLE arrives through the environment on purpose. A pull request title is
# attacker-controlled, so interpolating it into a workflow's run block would let
# a crafted title execute as shell.
#
# If this repo cites tickets somewhere other than the PR title, change what feeds
# PR_TITLE rather than this script's parsing.

set -Eeuo pipefail

readonly MAX_TICKETS=5
# Comments are sparse on most tickets but carry real scope when present: a split
# into stacked PRs, a merge-order constraint, a requirement walked back. Take
# the most recent, since later comments amend earlier ones.
readonly MAX_COMMENTS=10
readonly OUT_FILE="${OUT_FILE:-jira-tickets.md}"

log() { printf '%s\n' "$*"; }

# Expected dead ends: say why, leave no file, let the review proceed.
skip() {
  log "$*"
  log "The Spec axis will fall back to the pull request description."
  exit 0
}

work_dir=""
# Must end successfully. An EXIT trap's last status becomes the script's, so a
# trailing failed test here would report failure out of a clean skip.
cleanup() {
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    rm -rf "$work_dir"
  fi
  return 0
}
trap cleanup EXIT

main() {
  local dep
  for dep in curl jq; do
    command -v "$dep" >/dev/null 2>&1 || skip "$dep is not installed."
  done

  [[ -n "${JIRA_TOKEN:-}" ]] || skip "No JIRA_READONLY_TOKEN is set."
  [[ -n "${JIRA_SITE:-}" ]] || skip "No JIRA_SITE is set."
  [[ -n "${PR_TITLE:-}" ]] || skip "The pull request title is empty."
  # Interpolated into a regex below, so hold it to the shape of a Jira key.
  [[ "${JIRA_KEY_PREFIX:-}" =~ ^[A-Z][A-Z0-9]*$ ]] ||
    skip "JIRA_KEY_PREFIX is unset or is not a Jira project key."

  # A title may cite several tickets, written "[VS-1] [VS-2]" or "[VS-1], [VS-2]".
  # Take them all, deduplicated, in the order written.
  local -a keys=()
  local key
  while IFS= read -r key; do
    [[ -n "$key" ]] && keys+=("$key")
  done < <(printf '%s' "$PR_TITLE" |
    grep -oE "${JIRA_KEY_PREFIX}-[0-9]+" | awk '!seen[$0]++')

  ((${#keys[@]} > 0)) || skip "The pull request title cites no $JIRA_KEY_PREFIX ticket."

  # Bound the fan-out so a pathological title cannot become a request storm.
  local truncated=""
  if ((${#keys[@]} > MAX_TICKETS)); then
    truncated="${keys[*]:MAX_TICKETS}"
    keys=("${keys[@]:0:MAX_TICKETS}")
    log "Title cites more than $MAX_TICKETS tickets; ignoring:$truncated"
  fi

  # Scoped tokens must go through the api.atlassian.com gateway rather than the
  # site URL, which answers 401. The gateway needs the site's cloudId.
  local cloud_id
  cloud_id=$(curl -sS --fail --max-time 20 "$JIRA_SITE/_edge/tenant_info" |
    jq -r '.cloudId // empty') || skip "Could not reach $JIRA_SITE to resolve its cloudId."
  [[ -n "$cloud_id" ]] || skip "$JIRA_SITE returned no cloudId."

  work_dir=$(mktemp -d)
  local out="$work_dir/ticket.md"
  : >"$out"

  local fetched=0 missing=""
  for key in "${keys[@]}"; do
    # REST v2, not v3: v3 renders description as Atlassian Document Format JSON,
    # while v2 returns the plain text a reviewer can actually read.
    if ! curl -sS --fail --max-time 30 \
      -H "Authorization: Bearer $JIRA_TOKEN" \
      -H "Accept: application/json" \
      "https://api.atlassian.com/ex/jira/$cloud_id/rest/api/2/issue/$key?fields=summary,description,issuetype,status,comment" \
      -o "$work_dir/$key.json"; then
      log "Could not fetch $key: the token may have expired or lack access, or the issue may not exist."
      missing="$missing $key"
      continue
    fi

    jq -r --argjson max "$MAX_COMMENTS" '
      def comment_block:
        "### \(.author.displayName // "unknown") on \((.created // "")[0:10])\n\n\(.body // "(empty)")\n";

      "# \(.key): \(.fields.summary)\n\n"
      + "- Type: \(.fields.issuetype.name)\n- Status: \(.fields.status.name)\n\n"
      + "## Description\n\n\(.fields.description // "(no description set)")\n"
      + (
          ((.fields.comment.comments // []) | .[-$max:]) as $shown
          | ($shown | length) as $count
          | if $count == 0 then ""
            else "\n## Comments (\($count) of \(.fields.comment.total // $count))\n\n"
                 + ([$shown[] | comment_block] | join("\n"))
            end
        )
    ' "$work_dir/$key.json" >>"$out" ||
      { log "Could not render $key."; missing="$missing $key"; continue; }

    fetched=$((fetched + 1))
  done

  ((fetched > 0)) || skip "None of the cited tickets could be fetched."

  # Mark a partial spec as partial, so it is never mistaken for the whole ask.
  if [[ -n "$missing$truncated" ]]; then
    printf '\n---\n\nNote: this is an incomplete spec. The pull request also cites%s%s, which could not be included.\n' \
      "$missing" "${truncated:+ $truncated}" >>"$out"
  fi

  # One file, one predictable path for the prompt. Say up front when it holds
  # more than one ticket, so a reader does not stop at the first heading.
  if ((fetched > 1)); then
    { printf 'This pull request cites %d tickets. All of them are below.\n\n' "$fetched"; cat "$out"; } >"$out.final"
    mv "$out.final" "$out"
  fi

  mv "$out" "$OUT_FILE"
  log "Wrote $OUT_FILE with $fetched of ${#keys[@]} cited ticket(s)."
}

main "$@"
