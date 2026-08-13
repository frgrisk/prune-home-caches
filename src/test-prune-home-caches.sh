#!/usr/bin/env bash
# Copyright 2026 The Financial Risk Group, Inc.

# Test harness for prune-home-caches.sh.
#
# Builds a throwaway fixture tree that mimics /home, runs the REAL script
# against it via the HOME_MOUNT override, and asserts each safety property.
# Touches nothing outside its own temp directory.

set -uo pipefail

SCRIPT="${1:?usage: test-prune.sh /path/to/prune-home-caches.sh}"
FIXTURE="$(mktemp -d)"
# Go-style read-only modes must be relaxed before the fixture can be removed.
trap 'chmod -R u+w "$FIXTURE" 2>/dev/null; rm -rf -- "$FIXTURE"' EXIT

PASS=0
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

assert_exists()  { [[ -e "$1" ]] && ok "$2" || bad "$2 (missing: $1)"; }
assert_absent()  { [[ ! -e "$1" ]] && ok "$2" || bad "$2 (still present: $1)"; }

# --- build fixture ----------------------------------------------------------
build_fixture() {
    local u="$FIXTURE/alice"
    local old="202501010000"   # comfortably older than any age gate

    # VS Code: three server builds, one recent (kept as newest) + two stale.
    mkdir -p "$u/.vscode-server/cli/servers/Stable-new"
    mkdir -p "$u/.vscode-server/cli/servers/Stable-old1"
    mkdir -p "$u/.vscode-server/cli/servers/Stable-old2"
    # bin/ needs TWO entries: with only one it is trivially the newest and is
    # correctly retained, so a single-entry fixture asserts nothing.
    mkdir -p "$u/.vscode-server/bin/binnew" "$u/.vscode-server/bin/binold"
    echo x > "$u/.vscode-server/cli/servers/Stable-new/f"
    echo x > "$u/.vscode-server/cli/servers/Stable-old1/f"
    echo x > "$u/.vscode-server/cli/servers/Stable-old2/f"
    echo x > "$u/.vscode-server/bin/binnew/f"
    echo x > "$u/.vscode-server/bin/binold/f"
    touch -t "$old" "$u/.vscode-server/cli/servers/Stable-old1"
    touch -t "$old" "$u/.vscode-server/cli/servers/Stable-old2"
    touch -t "$old" "$u/.vscode-server/bin/binold"

    # Claude: active version pointed at by the launcher symlink, plus two old.
    mkdir -p "$u/.local/share/claude/versions" "$u/.local/bin"
    echo bin > "$u/.local/share/claude/versions/2.9.9"
    echo bin > "$u/.local/share/claude/versions/2.0.0"
    echo bin > "$u/.local/share/claude/versions/1.0.0"
    touch -t "$old" "$u/.local/share/claude/versions/2.0.0"
    touch -t "$old" "$u/.local/share/claude/versions/1.0.0"
    ln -sf "$u/.local/share/claude/versions/2.9.9" "$u/.local/bin/claude"

    # Cache: includes a dotfile and a nested dir, to prove both are cleared.
    mkdir -p "$u/.cache/pip" "$u/.cache/pre-commit/repoXYZ"
    echo data > "$u/.cache/pip/wheel"
    echo data > "$u/.cache/.hidden"
    echo data > "$u/.cache/pre-commit/repoXYZ/env"

    # Go modcache: read-only files and dirs, exactly as Go creates them.
    mkdir -p "$u/go/pkg/mod/cache/download/example.com"
    echo mod > "$u/go/pkg/mod/cache/download/example.com/v1.zip"
    mkdir -p "$u/go/pkg/mod/example.com@v1.0.0"
    echo src > "$u/go/pkg/mod/example.com@v1.0.0/main.go"
    chmod -R a-w "$u/go/pkg/mod"

    # A second user with nothing, to prove empty homes are handled.
    mkdir -p "$FIXTURE/bob/.cache"

    # Something outside the managed paths that must never be touched.
    mkdir -p "$u/projects"
    echo precious > "$u/projects/work.txt"
    echo precious > "$u/.bashrc"
}

run_script() {
    HOME_MOUNT="$FIXTURE" sudo -E "$SCRIPT" "$@" 2>&1
}

# --- test 1: dry run must change nothing ------------------------------------
printf '\n\033[1mTest 1: dry run is inert\033[0m\n'
build_fixture
before="$(find "$FIXTURE" | sort | md5sum)"
run_script --dry-run --age-days 30 >/dev/null
after="$(find "$FIXTURE" | sort | md5sum)"
[[ "$before" == "$after" ]] && ok "dry run left tree byte-identical" \
                            || bad "dry run MODIFIED the tree"

# --- test 2: real run, all stages -------------------------------------------
printf '\n\033[1mTest 2: real run\033[0m\n'
chmod -R u+w "$FIXTURE" 2>/dev/null || true; rm -rf -- "$FIXTURE"; mkdir -p "$FIXTURE"; build_fixture
u="$FIXTURE/alice"

# Record ownership/mode of .cache to prove they survive.
cache_before="$(stat -c '%U:%G:%a' "$u/.cache")"

run_script --age-days 30 >/dev/null

# builds stage
assert_exists "$u/.vscode-server/cli/servers/Stable-new" "newest build kept"
assert_absent "$u/.vscode-server/cli/servers/Stable-old1" "stale build removed"
assert_absent "$u/.vscode-server/cli/servers/Stable-old2" "second stale build removed"
assert_exists "$u/.vscode-server/bin/binnew"              "newest bin build kept"
assert_absent "$u/.vscode-server/bin/binold"              "stale bin build removed"

# claude stage — the -e vs -d trap
assert_exists "$u/.local/share/claude/versions/2.9.9" "active claude version kept"
assert_absent "$u/.local/share/claude/versions/2.0.0" "old claude version removed"
assert_absent "$u/.local/share/claude/versions/1.0.0" "oldest claude version removed"

# cache stage
assert_exists "$u/.cache"                       ".cache directory itself preserved"
assert_absent "$u/.cache/pip"                   "cache subdir cleared"
assert_absent "$u/.cache/.hidden"               "hidden cache file cleared"
assert_absent "$u/.cache/pre-commit"            "pre-commit envs cleared"
cache_after="$(stat -c '%U:%G:%a' "$u/.cache")"
[[ "$cache_before" == "$cache_after" ]] && ok "cache ownership/mode preserved ($cache_after)" \
                                        || bad "cache ownership/mode CHANGED: $cache_before -> $cache_after"

# modcache stage — read-only files must still be removed
assert_exists "$u/go/pkg/mod"                          "modcache directory preserved"
assert_absent "$u/go/pkg/mod/example.com@v1.0.0"       "read-only module dir removed"
assert_absent "$u/go/pkg/mod/cache/download"           "download cache removed"

# blast radius
assert_exists "$u/projects/work.txt" "unrelated project files untouched"
assert_exists "$u/.bashrc"           "dotfiles outside managed paths untouched"
assert_exists "$FIXTURE/bob/.cache"  "empty second home handled without error"

# --- test 3: --user scoping -------------------------------------------------
printf '\n\033[1mTest 3: --user scoping\033[0m\n'
chmod -R u+w "$FIXTURE" 2>/dev/null || true; rm -rf -- "$FIXTURE"; mkdir -p "$FIXTURE"; build_fixture
mkdir -p "$FIXTURE/bob/.cache/stuff"; echo d > "$FIXTURE/bob/.cache/stuff/f"
run_script --user alice --age-days 30 >/dev/null
assert_absent "$FIXTURE/alice/.cache/pip"      "targeted user's cache cleared"
assert_exists "$FIXTURE/bob/.cache/stuff/f"    "non-targeted user untouched"

# --- test 4: stage opt-outs -------------------------------------------------
printf '\n\033[1mTest 4: --no-* opt-outs\033[0m\n'
chmod -R u+w "$FIXTURE" 2>/dev/null || true; rm -rf -- "$FIXTURE"; mkdir -p "$FIXTURE"; build_fixture
run_script --no-cache --no-modcache --age-days 30 >/dev/null
assert_exists "$FIXTURE/alice/.cache/pip"                     "--no-cache preserved cache"
assert_exists "$FIXTURE/alice/go/pkg/mod/example.com@v1.0.0"  "--no-modcache preserved modcache"
assert_absent "$FIXTURE/alice/.vscode-server/cli/servers/Stable-old1" "builds stage still ran"

# --- summary ----------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
