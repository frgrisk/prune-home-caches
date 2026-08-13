#!/usr/bin/env bash
# Copyright 2026 The Financial Risk Group, Inc.

#
# prune-home-caches.sh — reclaim space on /home.
#
# Three stages:
#   builds    stale VS Code Remote server builds + Claude Code binaries
#   cache     every user's ~/.cache, wholesale
#   modcache  every user's ~/go/pkg/mod, wholesale
#
# Safety rules for the BUILDS stage (any one of which spares an item):
#   1. never remove a build backing a currently running process
#   2. always keep the most recently modified build per user, at any age
#   3. only remove items untouched for at least --age-days days
#   4. for Claude Code, always keep the target of ~/.local/bin/claude
#
# The cache and modcache stages are intentionally unconditional — no age gate
# and no in-use check. Both hold regenerable data, and at a weekly cadence a
# cache miss was judged cheaper than the bookkeeping. Accepted consequences:
#   - a full modcache wipe drops cache/download too, so every Go build after a
#     run re-fetches all dependencies from GOPROXY (network required)
#   - pre-commit hook environments live under ~/.cache and are rebuilt on the
#     next commit (network required, minutes)
#   - a user compiling at the moment this runs may see a transient error
# Use --no-cache / --no-modcache to opt out per stage.
#
# Requirements:
#   bash >= 4.2 (printf '%(%s)T'), coreutils (df, sort, readlink, rm, basename),
#   findutils (GNU find, for -printf), procps (ps)
#
# Usage:
#   prune-home-caches.sh [-n|--dry-run] [-a|--age-days N] [-d|--debug] [-h|--help]
#
# Exit codes: 0 success, 1 runtime error, 2 usage error

set -Eeuo pipefail
shopt -s nullglob

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# Overridable via environment ONLY so the test harness can run the real code
# against a throwaway fixture tree. Production always uses /home.
HOME_MOUNT="${HOME_MOUNT:-/home}"
readonly HOME_MOUNT
readonly SECONDS_PER_DAY=86400

# Restrict operations to these users; empty means every user under HOME_MOUNT.
declare -a TARGET_USERS=()

# Defaults; overridable by environment then by flags.
DRY_RUN="${DRY_RUN:-false}"
AGE_DAYS="${AGE_DAYS:-30}"
DEBUG="${DEBUG:-0}"

# Stages. All on by default; --no-* disables individually.
DO_BUILDS="${DO_BUILDS:-true}"
DO_CACHE="${DO_CACHE:-true}"
DO_MODCACHE="${DO_MODCACHE:-true}"

# Paths protected because a live process is using them. Populated by
# collect_inuse_paths; declared here so -u never trips on an empty run.
declare -a INUSE_PATHS=()

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_info()  { printf '[%(%Y-%m-%d %H:%M:%S)T] INFO: %s\n'  -1 "$*" >&2; }
log_warn()  { printf '[%(%Y-%m-%d %H:%M:%S)T] WARN: %s\n'  -1 "$*" >&2; }
log_error() { printf '[%(%Y-%m-%d %H:%M:%S)T] ERROR: %s\n' -1 "$*" >&2; }

log_debug() {
    [[ "$DEBUG" == "1" ]] || return 0
    printf '[%(%Y-%m-%d %H:%M:%S)T] DEBUG: %s\n' -1 "$*" >&2
}

die() {
    log_error "$*"
    exit 1
}

# ERR trap fires on any unhandled non-zero status thanks to -E/-e.
trap 'log_error "unexpected failure at ${SCRIPT_NAME}:${LINENO} (exit $?)"' ERR

# ---------------------------------------------------------------------------
# Usage and argument parsing
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Reclaims space on $HOME_MOUNT in three stages:

  builds    stale VS Code Remote server builds and superseded Claude Code
            binaries, subject to --age-days and the in-use protections
  cache     every user's ~/.cache, cleared wholesale (no age gate)
  modcache  every user's ~/go/pkg/mod, cleared wholesale (no age gate)

Options:
    -n, --dry-run        Report what would be removed, change nothing
    -a, --age-days NUM   Age gate for the builds stage only (default: $AGE_DAYS)
    -d, --debug          Emit per-item decision logging
    -u, --user NAME      Restrict to this user (repeatable; default: all users)
        --no-builds      Skip the builds stage
        --no-cache       Skip clearing ~/.cache
        --no-modcache    Skip clearing ~/go/pkg/mod
    -h, --help           Show this help message

The builds stage never removes a build in use by a running process, nor the
newest build for any user, regardless of age. The cache and modcache stages
are unconditional: everything regenerates, but the next build after a run is
slower and needs network.
EOF
    exit "${1:-0}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run)  DRY_RUN=true; shift ;;
            -d|--debug)    DEBUG=1; shift ;;
            --no-builds)   DO_BUILDS=false; shift ;;
            --no-cache)    DO_CACHE=false; shift ;;
            --no-modcache) DO_MODCACHE=false; shift ;;
            -u|--user)
                [[ $# -ge 2 ]] || { log_error "--user requires a value"; usage 2; }
                TARGET_USERS+=("$2")
                shift 2
                ;;
            --user=*) TARGET_USERS+=("${1#*=}"); shift ;;
            -a|--age-days)
                [[ $# -ge 2 ]] || { log_error "--age-days requires a value"; usage 2; }
                AGE_DAYS="$2"
                shift 2
                ;;
            --age-days=*) AGE_DAYS="${1#*=}"; shift ;;
            -h|--help)    usage 0 ;;
            --)           shift; break ;;
            *)            log_error "unknown option: $1"; usage 2 ;;
        esac
    done

    [[ "$AGE_DAYS" =~ ^[0-9]+$ ]] \
        || { log_error "--age-days must be a non-negative integer, got: $AGE_DAYS"; usage 2; }

    # Validate usernames before they are concatenated into a path. Without this
    # a value like '../..' would resolve TARGET_HOMES outside HOME_MOUNT.
    local u
    for u in ${TARGET_USERS[@]+"${TARGET_USERS[@]}"}; do
        [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] \
            || { log_error "invalid username: $u"; usage 2; }
    done
}

# ---------------------------------------------------------------------------
# Preflight validation
# ---------------------------------------------------------------------------

check_dependencies() {
    local -a missing=()
    local -ar required=(df du cut awk grep head tail find sort ps readlink rm basename)
    local cmd

    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    [[ ${#missing[@]} -eq 0 ]] || die "missing required commands: ${missing[*]}"

    # GNU find is required for -printf; BSD find will fail here.
    find /dev/null -maxdepth 0 -printf '' >/dev/null 2>&1 \
        || die "GNU find with -printf support is required"
}

check_preconditions() {
    [[ -d "$HOME_MOUNT" ]] || die "$HOME_MOUNT does not exist or is not a directory"

    if [[ "$DRY_RUN" != "true" && ${EUID:-$(id -u)} -ne 0 ]]; then
        die "must run as root to prune other users' files (or pass --dry-run)"
    fi
}

# Used space on the home mount, in MiB. Echoes an integer or fails.
get_home_used_mb() {
    local raw
    raw="$(df -BM --output=used "$HOME_MOUNT" | tail -n 1)" \
        || { log_error "df failed for $HOME_MOUNT"; return 1; }
    raw="${raw//[!0-9]/}"
    [[ -n "$raw" ]] || { log_error "could not parse df output for $HOME_MOUNT"; return 1; }
    printf '%s\n' "$raw"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# True if $1 is present in INUSE_PATHS.
is_in_use() {
    local -r needle="$1"
    local path
    for path in "${INUSE_PATHS[@]}"; do
        [[ "$path" == "$needle" ]] && return 0
    done
    return 1
}

# Collect filesystem paths referenced by running processes. grep exits 1 when
# nothing matches, which under -e/pipefail would abort the script, so the
# pipeline is explicitly tolerated and an empty result treated as valid.
collect_inuse_paths() {
    local -r pattern='/home/[^/]+/(\.vscode-server/(cli/servers|bin)|\.local/share/claude/versions)/[^/ ]+'
    local output=""

    output="$(ps -eo args 2>/dev/null | grep -oE "$pattern" | sort -u || true)"

    INUSE_PATHS=()
    if [[ -n "$output" ]]; then
        mapfile -t INUSE_PATHS <<<"$output"
    fi

    log_info "protected by live processes: ${#INUSE_PATHS[@]}"
    local path
    for path in "${INUSE_PATHS[@]}"; do
        log_debug "in use: $path"
    done
}

# Emit "<mtime_epoch>\t<path>" for each child of $1, newest first.
# $2 selects the find type predicate ("d" for directories, "" for any).
list_children_by_mtime() {
    local -r dir="$1"
    local -r type_filter="${2:-}"
    local -a find_args=("$dir" -mindepth 1 -maxdepth 1)

    [[ -n "$type_filter" ]] && find_args+=(-type "$type_filter")
    find_args+=(-printf '%T@\t%p\n')

    find "${find_args[@]}" 2>/dev/null | sort -rn || true
}

# Remove a path, honouring dry-run. Returns 0 only if space was actually freed.
remove_path() {
    local -r path="$1"
    local -r reason="$2"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN would remove ($reason): $path"
        return 1
    fi

    if rm -rf -- "$path"; then
        log_info "removed ($reason): $path"
        return 0
    fi

    log_warn "failed to remove: $path"
    return 1
}

# Extract the username from <HOME_MOUNT>/<user>/... without spawning cut.
user_from_path() {
    local path="${1#"$HOME_MOUNT"/}"
    printf '%s\n' "${path%%/*}"
}

# Home directories this run operates on, honouring --user.
declare -a TARGET_HOMES=()

resolve_target_homes() {
    local u d
    TARGET_HOMES=()

    if [[ ${#TARGET_USERS[@]} -gt 0 ]]; then
        for u in "${TARGET_USERS[@]}"; do
            d="$HOME_MOUNT/$u"
            if [[ -d "$d" ]]; then
                TARGET_HOMES+=("$d")
            else
                log_warn "no such home directory, skipping: $d"
            fi
        done
        log_info "scoped to ${#TARGET_HOMES[@]} user(s): ${TARGET_USERS[*]}"
    else
        for d in "$HOME_MOUNT"/*; do
            [[ -d "$d" ]] && TARGET_HOMES+=("$d")
        done
        log_info "operating on all ${#TARGET_HOMES[@]} home directories"
    fi
}

# Apparent size of a directory tree in bytes; 0 if it cannot be read.
dir_size_bytes() {
    local -r dir="$1"
    local out
    out="$(du -sbx "$dir" 2>/dev/null | cut -f1 || true)"
    [[ "$out" =~ ^[0-9]+$ ]] || out=0
    printf '%s\n' "$out"
}

human_gb() {
    local -r bytes="$1"
    awk -v b="$bytes" 'BEGIN { printf "%.2fG", b/1073741824 }'
}

# Empty a directory's contents while preserving the directory itself, its
# ownership and its mode. Recreating these as root would lock the owner out,
# and some tools assume the directory already exists. Returns bytes freed.
#
# Handles dotfiles (find, not globbing) and the read-only 0444/0555 modes Go
# uses in the module cache (root bypasses those).
empty_directory_contents() {
    local -r dir="$1"
    local -r label="$2"
    local bytes

    [[ -d "$dir" ]] || { printf '0\n'; return 0; }

    bytes="$(dir_size_bytes "$dir")"
    [[ "$bytes" -gt 0 ]] || { printf '0\n'; return 0; }

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN would clear $label ($(human_gb "$bytes")): $dir"
        printf '%s\n' "$bytes"
        return 0
    fi

    # Capture stderr rather than discarding it: a partial failure here (locked
    # file, I/O error) must say why, not just that it happened.
    local err=""
    if err="$(find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>&1)"; then
        log_info "cleared $label ($(human_gb "$bytes")): $dir"
        printf '%s\n' "$bytes"
        return 0
    fi

    log_warn "failed to fully clear $label: $dir${err:+ — ${err%%$'\n'*}}"
    printf '0\n'
    return 0
}

# ---------------------------------------------------------------------------
# Pruning
# ---------------------------------------------------------------------------

prune_vscode_builds() {
    local -r now="$1"
    local removed=0
    local home base sub dir newest line mtime path age_days

    for home in "${TARGET_HOMES[@]}"; do
        base="$home/.vscode-server"
        [[ -d "$base" ]] || continue
        for sub in "cli/servers" "bin"; do
            dir="$base/$sub"
            [[ -d "$dir" ]] || continue

            newest=""
            while IFS=$'\t' read -r mtime path; do
                [[ -n "${path:-}" ]] || continue

                # Rule 2: the most recent build for this user is always kept.
                if [[ -z "$newest" ]]; then
                    newest="$path"
                    log_debug "newest, keeping: $path"
                    continue
                fi

                # Rule 1: never touch a build backing a live session.
                if is_in_use "$path"; then
                    log_info "in use, keeping: $path"
                    continue
                fi

                # Rule 3: age gate.
                age_days=$(( (now - ${mtime%.*}) / SECONDS_PER_DAY ))
                if [[ "$age_days" -lt "$AGE_DAYS" ]]; then
                    log_debug "only ${age_days}d old, keeping: $path"
                    continue
                fi

                remove_path "$path" "stale ${age_days}d build" && removed=$(( removed + 1 ))
            done < <(list_children_by_mtime "$dir" d)
        done
    done

    log_info "vscode server builds removed: $removed"
}

prune_claude_versions() {
    local -r now="$1"
    local removed=0
    local home vdir user keep mtime path age_days

    for home in "${TARGET_HOMES[@]}"; do
        vdir="$home/.local/share/claude/versions"
        [[ -d "$vdir" ]] || continue
        user="$(user_from_path "$vdir")"

        # Rule 4: the active version is whatever the launcher symlink resolves
        # to. These entries are regular files, not directories, so test -e.
        keep="$(readlink -f "$home/.local/bin/claude" 2>/dev/null || true)"
        if [[ -z "$keep" || ! -e "$keep" ]]; then
            keep="$(list_children_by_mtime "$vdir" | head -n 1 | cut -f2- || true)"
        fi

        if [[ -z "$keep" ]]; then
            log_warn "no active Claude version resolved for $user, skipping user"
            continue
        fi
        log_debug "active version for $user: $keep"

        while IFS=$'\t' read -r mtime path; do
            [[ -n "${path:-}" ]] || continue
            [[ "$path" != "$keep" ]] || continue

            if is_in_use "$path"; then
                log_info "running, keeping: $path"
                continue
            fi

            age_days=$(( (now - ${mtime%.*}) / SECONDS_PER_DAY ))
            if [[ "$age_days" -lt "$AGE_DAYS" ]]; then
                log_debug "only ${age_days}d old, keeping: $path"
                continue
            fi

            remove_path "$path" "superseded ${age_days}d version" && removed=$(( removed + 1 ))
        done < <(list_children_by_mtime "$vdir")
    done

    log_info "claude versions removed: $removed"
}

# Wipe every user's ~/.cache wholesale. Per the XDG spec this directory holds
# non-essential regenerable data, so no age gate is applied: at a weekly
# cadence a cache miss is cheaper than the bookkeeping.
#
# Known costs, accepted deliberately:
#   - pre-commit hook environments live here; affected users pay a slow first
#     commit (and need network) after each run
#   - a user building at the moment this runs may see a transient cache error
prune_user_caches() {
    local total=0 bytes home dir

    for home in "${TARGET_HOMES[@]}"; do
        dir="$home/.cache"
        [[ -d "$dir" ]] || continue
        bytes="$(empty_directory_contents "$dir" "cache")"
        total=$(( total + bytes ))
    done

    log_info "user caches cleared: $(human_gb "$total")"
    printf '%s\n' "$total"
}

# Wipe every user's Go module cache, equivalent to `go clean -modcache` run as
# each user. Done by path rather than by invoking go, because go is not
# reliably on PATH in a non-login root context and querying it per user is
# fragile. This also removes cache/download, so the next build re-fetches from
# GOPROXY over the network.
#
# Limitation: only the default GOPATH (~/go) is covered. A user with a custom
# GOPATH or GOMODCACHE outside their home is not touched, and is reported.
prune_go_modcache() {
    local total=0 bytes home dir user

    for home in "${TARGET_HOMES[@]}"; do
        dir="$home/go/pkg/mod"
        [[ -d "$dir" ]] || continue
        user="$(user_from_path "$dir")"
        bytes="$(empty_directory_contents "$dir" "go modcache")"
        total=$(( total + bytes ))
        log_debug "modcache handled for $user"
    done

    log_info "go module caches cleared: $(human_gb "$total")"
    printf '%s\n' "$total"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"
    check_dependencies
    check_preconditions

    local now before after
    printf -v now '%(%s)T' -1

    before="$(get_home_used_mb)"
    log_info "starting prune (age>${AGE_DAYS}d, dry_run=${DRY_RUN}), ${HOME_MOUNT} used=${before}M"

    resolve_target_homes
    collect_inuse_paths

    if [[ "$DO_BUILDS" == "true" ]]; then
        prune_vscode_builds "$now"
        prune_claude_versions "$now"
    else
        log_info "skipping build prune (--no-builds)"
    fi

    if [[ "$DO_CACHE" == "true" ]]; then
        prune_user_caches >/dev/null
    else
        log_info "skipping user caches (--no-cache)"
    fi

    if [[ "$DO_MODCACHE" == "true" ]]; then
        prune_go_modcache >/dev/null
    else
        log_info "skipping go modcache (--no-modcache)"
    fi

    after="$(get_home_used_mb)"
    log_info "done, ${HOME_MOUNT} used=${after}M, freed=$(( before - after ))M"
}

main "$@"
