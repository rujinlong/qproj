# shellcheck shell=bash
# qproj.sh — shell-side path helpers for qproj project drivers (analyses/p<code>.slurm).
#
# Mirrors the R path discipline in R/directories.R / inst/templates/workflow.qmd so a
# Bash driver writes ONLY to its own target directory and reads upstream data through
# path_source(), exactly like a rendered .qmd step. Source this at the top of a driver:
#
#   source "$(command -v qproj.sh || Rscript -e 'cat(system.file("scripts/qproj.sh", package="qproj"))')"
#   qproj_init --step-file "${BASH_SOURCE[0]}"          # locate ROOT + default STEP
#   # optional, per-subcommand step id (a driver may host several steps):
#   qproj_set_step "01-assembly"
#
#   input="$(path_source 00-raw "${sid}_R1.fq.gz")"     # read upstream (assign FIRST, see below)
#   out="$(path_target result.tsv)"                     # write to own target dir
#
# ── R ↔ shell semantics (ROOT = the here::i_am() workflow root, i.e. analyses/) ──
#   path_target f...        ->  $ROOT/data/$STEP/f...
#   path_source up f...     ->  $ROOT/data/$up/f...
#   path_raw f...           ->  $ROOT/data/00-raw/d$STEP/f...     (this step's raw inputs)
#   path_resource f...      ->  $ROOT/data/00-raw/d00-resource/f... (shared raw resources)
#   path_run_state f...     ->  $ROOT/data/$STEP/run-state/f...   (NEW: shared-FS run state,
#                               for Nextflow -work-dir / resume cache; NOT node-local
#                               /localscratch — must survive cross-node + restart)
#   create_dir_target [--clean]  ->  mkdir -p (and optionally empty) $ROOT/data/$STEP
#
# ── set -e trap (drivers run under vpipe's `set -euo pipefail`) ──
#   ALWAYS split assignment from use:
#       input="$(path_source 00-raw x.fq)"      # <- ok: a failing subst aborts here
#       run_tool "$input"
#   NOT `run_tool "$(path_source 00-raw x.fq)"` — a command-substitution failure is
#   masked by the outer command's exit status. (integration plan §7-A)
#
# These functions only PRINT paths (no side effects) except create_dir_target; they are
# safe to call inside `$( )`. ROOT/STEP are resolved once by qproj_init and cached in
# QPROJ_ROOT / QPROJ_STEP (overridable by exporting either before sourcing).

# --- ROOT discovery: walk up until a dir has BOTH _quarto.yml AND data/ (the workflow
#     root anchored by here::i_am on the analyses/ axis). Nearest match wins. ---
_qproj_find_root() {
    local d
    d="$(cd -- "${1:-.}" 2>/dev/null && pwd -P)" || return 1
    while [ -n "$d" ]; do
        if [ -f "$d/_quarto.yml" ] && [ -d "$d/data" ]; then
            printf '%s\n' "$d"
            return 0
        fi
        [ "$d" = "/" ] && break
        d="$(dirname -- "$d")"
    done
    return 1
}

# --- step id from a driver file path (basename without extension); never guesses $0 ---
_qproj_step_from_file() {
    local base
    base="$(basename -- "$1")"
    printf '%s\n' "${base%.*}"
}

# qproj_init [--step-file <path>] [--root <dir>] [--step <name>]
# Resolve QPROJ_ROOT (from --root, else existing env, else search up from --step-file's
# dir, else CWD) and QPROJ_STEP (from --step, else --step-file basename, else existing env).
qproj_init() {
    local step_file="" root_arg="" step_arg=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --step-file) step_file="$2"; shift 2 ;;
            --root)      root_arg="$2";  shift 2 ;;
            --step)      step_arg="$2";  shift 2 ;;
            *) printf 'qproj_init: unknown arg %s\n' "$1" >&2; return 2 ;;
        esac
    done

    if [ -n "$root_arg" ]; then
        QPROJ_ROOT="$(cd -- "$root_arg" && pwd -P)" || return 1
    elif [ -n "${QPROJ_ROOT:-}" ]; then
        QPROJ_ROOT="$(cd -- "$QPROJ_ROOT" && pwd -P)" || return 1
    else
        local search_from="."
        [ -n "$step_file" ] && search_from="$(dirname -- "$step_file")"
        QPROJ_ROOT="$(_qproj_find_root "$search_from")" || {
            printf 'qproj_init: no workflow root (a dir with _quarto.yml + data/) at or above %s\n' \
                "$search_from" >&2
            return 1
        }
    fi

    if [ -n "$step_arg" ]; then
        QPROJ_STEP="$step_arg"
    elif [ -n "$step_file" ]; then
        QPROJ_STEP="$(_qproj_step_from_file "$step_file")"
    elif [ -n "${QPROJ_STEP:-}" ]; then
        :
    else
        printf 'qproj_init: cannot determine STEP (pass --step-file or --step)\n' >&2
        return 2
    fi

    export QPROJ_ROOT QPROJ_STEP
}

# qproj_set_step <name> — override the current step id (a driver hosting several steps
# calls this per subcommand so path_target/path_raw land in that step's directory).
qproj_set_step() {
    [ -n "${1:-}" ] || { printf 'qproj_set_step: need a step name\n' >&2; return 2; }
    QPROJ_STEP="$1"; export QPROJ_STEP
}

_qproj_require_init() {
    if [ -z "${QPROJ_ROOT:-}" ] || [ -z "${QPROJ_STEP:-}" ]; then
        printf '%s: call qproj_init first (QPROJ_ROOT/QPROJ_STEP unset)\n' "${1:-qproj}" >&2
        return 1
    fi
}

# join ROOT/data + the remaining args with '/', printing one absolute path
_qproj_join() {
    local out="$QPROJ_ROOT/data"
    local seg
    for seg in "$@"; do
        [ -n "$seg" ] && out="$out/$seg"
    done
    printf '%s\n' "$out"
}

# path_target [f...] -> $ROOT/data/$STEP/f...
path_target() {
    _qproj_require_init path_target || return 1
    _qproj_join "$QPROJ_STEP" "$@"
}

# path_source <upstream-step> [f...] -> $ROOT/data/<upstream>/f...
path_source() {
    _qproj_require_init path_source || return 1
    if [ $# -lt 1 ]; then
        printf 'path_source: needs the upstream step name as the first argument\n' >&2
        printf '  e.g. path_source 00-raw sample.fq\n' >&2
        return 2
    fi
    local up="$1"; shift
    # Cheap honesty guard: a file-looking first arg is almost surely a mistake.
    case "$up" in
        *.*) printf 'path_source: %s looks like a file, not a step; did you mean path_source <step> %s ?\n' \
            "$up" "$up" >&2 ;;
    esac
    _qproj_join "$up" "$@"
}

# path_raw [f...] -> $ROOT/data/00-raw/d$STEP/f...  (this step's raw input region)
path_raw() {
    _qproj_require_init path_raw || return 1
    _qproj_join "00-raw" "d$QPROJ_STEP" "$@"
}

# path_resource [f...] -> $ROOT/data/00-raw/d00-resource/f...  (raw shared by many steps)
path_resource() {
    _qproj_require_init path_resource || return 1
    _qproj_join "00-raw" "d00-resource" "$@"
}

# path_run_state [f...] -> $ROOT/data/$STEP/run-state/f...
# Shared-FS run state for orchestrators (Nextflow -work-dir / NXF_CACHE_DIR / -log).
# MUST be on a shared filesystem (visible to controller + compute), NOT /localscratch,
# because Nextflow resume needs cross-node + cross-restart persistence (plan §C / D5).
path_run_state() {
    _qproj_require_init path_run_state || return 1
    _qproj_join "$QPROJ_STEP" "run-state" "$@"
}

# create_dir_target [--clean] — ensure (optionally empty) $ROOT/data/$STEP exists.
# Mirrors proj_create_dir_target(clean=): with --clean, delete then recreate.
create_dir_target() {
    _qproj_require_init create_dir_target || return 1
    local clean=0
    [ "${1:-}" = "--clean" ] && clean=1
    local dir; dir="$(_qproj_join "$QPROJ_STEP")"
    if [ "$clean" = 1 ] && [ -d "$dir" ]; then
        rm -rf -- "$dir"
    fi
    mkdir -p -- "$dir"
    printf '%s\n' "$dir"
}

# qproj_nf_prepare — route a Nextflow run's state onto the SHARED run-state tree
# ($ROOT/data/$STEP/run-state/), never /localscratch: -resume needs the work dir, the
# LevelDB cache AND the run history to survive across Slurm nodes + restarts, and a
# compute-local work/cache silently breaks resume when the next attempt lands elsewhere.
#
# It creates run-state/{work,launch,log} and EXPORTS three variables:
#   NXF_WORK        Nextflow work dir (= -work-dir default) -> shared FS
#   QPROJ_NF_LOG    log path; pass to nextflow as `-log "$QPROJ_NF_LOG"`
#   QPROJ_NF_LAUNCH launch dir; `cd` into it before `nextflow run` so `.nextflow/` (the
#                   resume cache + history) also lands on shared FS. (Nextflow has NO
#                   NXF_CACHE_DIR env var — the local LevelDB cache lives in <launch>/
#                   .nextflow/, so the cd is what shares it — verified against Nextflow docs.)
#
# ⚠ Call it DIRECTLY, never `$(qproj_nf_prepare)` — command substitution runs it in a
#   subshell, so the exports would be lost (the same "source|grep drops exports" trap).
# Usage (driver keeps full control of nextflow flags):
#   qproj_init --step 022-humann
#   qproj_nf_prepare
#   ( cd "$QPROJ_NF_LAUNCH" && nextflow run pipeline.nf -log "$QPROJ_NF_LOG" -resume -profile spark ... )
# Recommend publishDir mode:'copy' (not symlink into work) so outputs outlive work cleanup,
# and a driver-side `trap 'rm -rf "$(path_target)"' ERR` for atomic-ish failure cleanup (MVP).
qproj_nf_prepare() {
    _qproj_require_init qproj_nf_prepare || return 1
    local state; state="$(_qproj_join "$QPROJ_STEP" "run-state")"
    mkdir -p "$state"/{work,launch,log}
    export NXF_WORK="$state/work"                    # -work-dir default -> shared FS
    export QPROJ_NF_LOG="$state/log/nextflow.log"    # caller: nextflow run ... -log "$QPROJ_NF_LOG"
    export QPROJ_NF_LAUNCH="$state/launch"           # caller: cd here -> .nextflow/ cache+history shared
}
