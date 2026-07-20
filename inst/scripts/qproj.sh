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
#   path_run_state f...     ->  $ROOT/data/.run-state/$STEP/f...  (NEW: shared-FS run state,
#                               a SIBLING of the step target so create_dir_target --clean /
#                               ERR-trap cleanup never destroys it; for Nextflow work/cache/
#                               history; NOT node-local /localscratch — survives cross-node+restart)
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
#     root anchored by here::i_am on the analyses/ axis). Nearest match wins.
# NOTE: resolves PHYSICAL ancestors (pwd -P). A driver located under a symlinked directory
# (analyses/foo -> /elsewhere) searches from the physical target, so it may miss the logical
# analyses/ root. Such a driver should pass `qproj_init --root <analyses>` explicitly. ---
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

# --- a step must be a single, safe path component. This is a SAFETY gate, not cosmetics:
#     create_dir_target --clean does `rm -rf $ROOT/data/$STEP`, so STEP="/" would wipe data/
#     and STEP=".." would wipe $ROOT. Reject empty / "." / ".." / anything with a slash.
_qproj_validate_step() {
    case "${1:-}" in
        ""|.|..) return 1 ;;
        */*)     return 1 ;;
        *)       return 0 ;;
    esac
}

# qproj_init [--step-file <path>] [--root <dir>] [--step <name>]
# Resolve QPROJ_ROOT (from --root, else existing env, else search up from --step-file's
# dir, else CWD) and QPROJ_STEP (from --step, else --step-file basename, else existing env).
qproj_init() {
    local step_file="" root_arg="" step_arg=""
    while [ $# -gt 0 ]; do
        # each two-arg option must have its value present, else `$2` under `set -u`
        # would kill the whole caller instead of returning a handleable error (rc=2).
        case "$1" in
            --step-file|--root|--step)
                [ $# -ge 2 ] || { printf 'qproj_init: %s needs a value\n' "$1" >&2; return 2; } ;;
        esac
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

    # e.g. a dotfile driver yielding empty STEP, or a caller-supplied "/" / ".." — reject
    # before any path could feed create_dir_target --clean's rm -rf.
    _qproj_validate_step "$QPROJ_STEP" || {
        printf 'qproj_init: invalid STEP %s (need a single path component, not empty/./.. or with /)\n' \
            "$QPROJ_STEP" >&2
        return 2
    }

    export QPROJ_ROOT QPROJ_STEP
}

# qproj_set_step <name> — override the current step id (a driver hosting several steps
# calls this per subcommand so path_target/path_raw land in that step's directory).
qproj_set_step() {
    _qproj_validate_step "${1:-}" || {
        printf 'qproj_set_step: invalid step %s (need a single path component, not empty/./.. or with /)\n' \
            "${1:-}" >&2
        return 2
    }
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
# NOTE: this only COMPOSES the path; unlike the R proj_path_source it does NOT validate that
# <upstream> is actually earlier in the workflow DAG (no render-config sort). Callers are
# trusted to pass a real upstream step — the double-axis write discipline is advisory here.
path_source() {
    _qproj_require_init path_source || return 1
    if [ $# -lt 1 ]; then
        printf 'path_source: needs the upstream step name as the first argument\n' >&2
        printf '  e.g. path_source 00-raw sample.fq\n' >&2
        return 2
    fi
    local up="$1"; shift
    # An empty upstream would silently collapse to $ROOT/data/<file> (reading the data root);
    # reject it rather than resolve a wrong path (R version at least warns on empty upstream).
    if [ -z "$up" ]; then
        printf 'path_source: upstream step is empty; pass a real step name (e.g. 00-raw)\n' >&2
        return 2
    fi
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

# path_run_state [f...] -> $ROOT/data/.run-state/$STEP/f...
# Deliberately a SIBLING of the step target (under data/.run-state/), NOT data/$STEP/run-state/:
# create_dir_target --clean wipes data/$STEP and a driver ERR trap may `rm -rf "$(path_target)"`,
# either of which would destroy the -resume work/cache/history if run-state lived inside the
# target. Keeping it outside the target's cleanup boundary preserves resume across retries.
# (Still under data/ so the framework's data/* gitignore covers it.)
path_run_state() {
    _qproj_require_init path_run_state || return 1
    _qproj_join ".run-state" "$QPROJ_STEP" "$@"
}

# create_dir_target [--clean] — ensure (optionally empty) $ROOT/data/$STEP exists.
# Mirrors proj_create_dir_target(clean=): with --clean, delete then recreate.
create_dir_target() {
    _qproj_require_init create_dir_target || return 1
    local clean=0
    [ "${1:-}" = "--clean" ] && clean=1
    local dir; dir="$(_qproj_join "$QPROJ_STEP")"
    if [ "$clean" = 1 ] && [ -d "$dir" ]; then
        # Defence-in-depth (STEP is already validated): RESOLVE symlinks/.. via pwd -P, then
        # rm only a STRICT descendant of $ROOT/data/. A plain glob can't do this — the pattern
        # "$ROOT/data/"?* still matches "$ROOT/data/.." (?* = the two dots), which resolves to
        # $ROOT. Normalising first guards against rm -rf of data/, $ROOT, or a hand-set
        # QPROJ_STEP="..".
        local _rp _dp
        _rp="$(cd -- "$dir" && pwd -P)" || { printf 'create_dir_target: cannot resolve %s\n' "$dir" >&2; return 1; }
        _dp="$(cd -- "$QPROJ_ROOT/data" && pwd -P)" || return 1
        case "$_rp" in
            "$_dp"/?*) rm -rf -- "$_rp" ;;
            *) printf 'create_dir_target: refusing to clean %s (resolves to %s, not strictly under %s)\n' \
                   "$dir" "$_rp" "$_dp" >&2
               return 1 ;;
        esac
    fi
    mkdir -p -- "$dir"
    printf '%s\n' "$dir"
}

# qproj_nf_prepare — route a Nextflow run's state onto the SHARED run-state tree
# (data/.run-state/$STEP/), never /localscratch: -resume needs the work dir, the session
# cache AND the run history to survive across Slurm nodes + restarts, and a compute-local
# work/cache silently breaks resume when the next attempt lands on another node.
#
# EXPORTS (call it DIRECTLY, never `$(qproj_nf_prepare)` — a command-substitution subshell
# would drop the exports, the same "source|grep drops exports" trap):
#   NXF_WORK       Nextflow work dir (= -work-dir default)       -> shared FS
#   NXF_CACHE_DIR  session cache + history (Nextflow >= 24.10)   -> shared FS
#   QPROJ_NF_LOG   log path; pass as a GLOBAL flag: `nextflow -log "$QPROJ_NF_LOG" run ...`
#
# NXF_CACHE_DIR (verified in Nextflow docs, introduced 24.10.0; spark runs 26.04) lets the
# cache+history live on shared FS WITHOUT cd-ing into a launch dir — so the caller's CWD is
# preserved and relative pipeline/input paths + the launch-dir nextflow.config still resolve.
# (It must differ from the launch dir; it does — it's under data/.run-state/.) For Nextflow
# < 24.10, fall back to cd-ing into a shared launch dir instead.
#
# Usage (driver keeps full control of nextflow flags; -log is GLOBAL, BEFORE `run`):
#   qproj_init --step 022-humann
#   qproj_nf_prepare
#   nextflow -log "$QPROJ_NF_LOG" run pipeline.nf -resume -profile spark ...
# Recommend publishDir mode:'copy' (not symlink into work) so outputs outlive work cleanup.
# A driver ERR trap may `rm -rf "$(path_target)"` safely: run-state is a SIBLING
# (data/.run-state/$STEP), not inside the target, so cleanup never destroys resume state.
qproj_nf_prepare() {
    _qproj_require_init qproj_nf_prepare || return 1
    local state; state="$(_qproj_join ".run-state" "$QPROJ_STEP")"
    mkdir -p "$state"/{work,cache,log}
    export NXF_WORK="$state/work"                    # -work-dir default -> shared FS
    export NXF_CACHE_DIR="$state/cache"              # session cache + history (>=24.10) -> shared
    export QPROJ_NF_LOG="$state/log/nextflow.log"    # caller: nextflow -log "$QPROJ_NF_LOG" run ...
}
