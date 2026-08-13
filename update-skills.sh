#!/usr/bin/env bash
# Copyright 2026 The Financial Risk Group, Inc.

set -Eeuo pipefail
trap 'exit 130' INT

# Verify dependencies
command -v npx &>/dev/null || { echo "ERROR: npx not found" >&2; exit 1; }
command -v jq &>/dev/null || { echo "ERROR: jq not found" >&2; exit 1; }

# Install for the agent-neutral directory plus Claude Code. The second target is
# what produces the shared .agents/skills/ tree with .claude/skills/ symlinked
# into it; with claude-code alone the CLI copies real files into .claude/skills/
# and never creates .agents/.
AGENTS=(-a universal -a claude-code)
LOCK_FILE="skills-lock.json"

# Find skills currently installed from a given source
installed_skills_for() {
  local -r source="$1"
  if [[ -f "$LOCK_FILE" ]]; then
    jq -r --arg src "$source" '.skills | to_entries[] | select(.value.source == $src) | .key' "$LOCK_FILE"
  fi
}

# Update a skill package.
# With skill args: remove + re-add only those skills.
# Without: remove all skills from this source (via lock file), then re-add entire package.
update_package() {
  local -r pkg="$1"
  shift

  echo ""
  echo "--- $pkg ---"

  if [[ $# -gt 0 ]]; then
    npx skills remove -s "$@" -y 2>/dev/null || true
    npx skills add "$pkg" -s "$@" "${AGENTS[@]}" -y
  else
    # Find and remove all currently installed skills from this source
    local -a current_skills=()
    while IFS= read -r skill; do
      [[ -n "$skill" ]] && current_skills+=("$skill")
    done < <(installed_skills_for "$pkg")
    if [[ ${#current_skills[@]} -gt 0 ]]; then
      npx skills remove -s "${current_skills[@]}" -y 2>/dev/null || true
    fi
    npx skills add "$pkg" "${AGENTS[@]}" -y
  fi
}

# Re-pull a curated source using only the skills already recorded in the lock
# file, so a skill renamed away upstream is not silently re-added. It also holds
# a package to a subset when it ships more skills than we want.
update_curated() {
  local -r pkg="$1"
  local -a skills=()
  while IFS= read -r skill; do
    [[ -n "$skill" ]] && skills+=("$skill")
  done < <(installed_skills_for "$pkg")
  if [[ ${#skills[@]} -eq 0 ]]; then
    echo "WARNING: no lock entries for $pkg; skipping (seed it once with 'npx skills add')" >&2
    return
  fi
  update_package "$pkg" "${skills[@]}"
}

# Same, but bail out before touching anything if the source isn't reachable.
# frgrisk/skills is private: an unauthenticated runner would otherwise complete
# the remove step, fail the add, and leave the skill deleted from the tree.
update_curated_private() {
  local -r pkg="$1"
  if ! GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "https://github.com/${pkg}.git" &>/dev/null; then
    echo "WARNING: cannot reach private repo $pkg; leaving its skills untouched." >&2
    echo "         Authenticate git for github.com/$pkg to update them." >&2
    return
  fi
  update_curated "$pkg"
}

# Curated subsets: re-pull exactly the skills in the lock file, not the whole
# package. frgrisk/skills ships far more than we vendor here.
update_curated_private "frgrisk/skills"

echo ""
echo "=== Done ==="
echo "Updated skills in .claude/skills/:"
ls -1 .claude/skills/
