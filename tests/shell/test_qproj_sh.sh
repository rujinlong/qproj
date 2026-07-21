#!/usr/bin/env bash
#
# Regression harness for inst/scripts/qproj.sh (the Bash path helpers a project driver
# sources) and for the canonical resolver emitted by qproj::proj_shell_bootstrap().
#
# Why this file exists: the A and C stages of the bash/nextflow integration claimed
# "14 unit tests pass" / "unit test caught the subshell-export trap", but those tests
# were written in a scratch directory and never committed -- the claims were therefore
# unreproducible and qproj.sh had zero regression protection (pm EL-005). This harness
# re-establishes them in the repository.
#
# Usage:
#   tests/shell/test_qproj_sh.sh [<path to qproj.sh>] [<path to bootstrap block>]
#
# Both arguments are optional; qproj.sh defaults to the copy in this checkout, and the
# resolver tests are skipped when no bootstrap block is supplied (it is generated from R,
# so a standalone shell run cannot produce it). tests/testthat/test-shell.R passes both.
#
# Each assertion runs in a FRESH `bash -c` under `set -uo pipefail`, mirroring how a
# driver runs under vpipe's `set -euo pipefail`: a helper that trips `set -u` or leaks
# state between calls has to fail here rather than in a live job.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LIB="${1:-$(cd -- "$HERE/../.." && pwd -P)/inst/scripts/qproj.sh}"
BOOT="${2:-}"

[ -r "$LIB" ] || { printf 'cannot read qproj.sh at %s\n' "$LIB" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
OUT=""; ERR=""; RC=0

ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
nok() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }
skip(){ SKIP=$((SKIP + 1)); printf '  skip  %s (%s)\n' "$1" "${2:-}"; }

is()       { if [ "$2" = "$3" ];            then ok "$1"; else nok "$1" "want [$3] got [$2]"; fi; }
contains() { case "$2" in *"$3"*) ok "$1";; *) nok "$1" "[$2] does not contain [$3]";; esac; }

# Run a snippet in a pristine bash with qproj.sh sourced; capture stdout/stderr/rc.
# `source` happens inside the child, so no test can contaminate another.
sh_run() {
  OUT="$(bash -c "set -uo pipefail; . '$LIB'; $1" 2>"$TMP/.err")"; RC=$?
  ERR="$(cat "$TMP/.err")"
}

# Same, but sourcing the generated bootstrap block instead of qproj.sh directly.
boot_run() {
  OUT="$(bash -c "set -uo pipefail; . '$BOOT'; $1" 2>"$TMP/.err")"; RC=$?
  ERR="$(cat "$TMP/.err")"
}

# ---- fixture: a minimal workflow root (a dir holding BOTH _quarto.yml and data/) ----
ROOT="$TMP/proj/analyses"
mkdir -p "$ROOT/data" "$ROOT/sub/deeper"
: > "$ROOT/_quarto.yml"
INIT="qproj_init --root '$ROOT' --step 010-import"

printf '\n== ROOT / STEP resolution ==\n'

sh_run "$INIT && printf '%s' \"\$QPROJ_ROOT\""
is "qproj_init --root resolves the workflow root" "$OUT" "$ROOT"

sh_run "qproj_init --root '$ROOT' --step-file /somewhere/pc047e3.slurm && printf '%s' \"\$QPROJ_STEP\""
is "--step-file derives STEP from the basename" "$OUT" "pc047e3"

sh_run "cd '$ROOT/sub/deeper' && qproj_init --step s && printf '%s' \"\$QPROJ_ROOT\""
is "walks up from CWD to the workflow root" "$OUT" "$ROOT"

# Nearest match wins: a nested root must shadow the outer one.
mkdir -p "$ROOT/sub/inner/data"; : > "$ROOT/sub/inner/_quarto.yml"
sh_run "cd '$ROOT/sub/inner' && qproj_init --step s && printf '%s' \"\$QPROJ_ROOT\""
is "nearest workflow root wins over an outer one" "$OUT" "$ROOT/sub/inner"

sh_run "cd '$TMP' && qproj_init --step s"
is "no workflow root above CWD -> rc=1" "$RC" "1"
contains "...and says what it looked for" "$ERR" "_quarto.yml"

# A two-arg option with its value missing must return a handleable rc, NOT die on `set -u`
# when the function reaches for \$2. That distinction is the whole point of the guard.
sh_run "qproj_init --root '$ROOT' --step"
is "--step without a value -> rc=2 (not a set -u abort)" "$RC" "2"

sh_run "qproj_init --root '$ROOT' --step s --bogus"
is "unknown argument -> rc=2" "$RC" "2"

sh_run "qproj_init --root '$ROOT' --step ../escape"
is "STEP containing / is rejected -> rc=2" "$RC" "2"

sh_run "qproj_init --root '$ROOT' --step .."
is "STEP '..' is rejected -> rc=2" "$RC" "2"

sh_run "qproj_init --root '$ROOT' --step-file /somewhere/.hidden"
is "a dotfile driver yielding an empty STEP is rejected -> rc=2" "$RC" "2"

printf '\n== path helpers ==\n'

sh_run "$INIT && path_target"
is "path_target -> data/<step>" "$OUT" "$ROOT/data/010-import"

sh_run "$INIT && path_target out.tsv"
is "path_target <file>" "$OUT" "$ROOT/data/010-import/out.tsv"

sh_run "$INIT && path_source 00-raw x.fq"
is "path_source <upstream> <file>" "$OUT" "$ROOT/data/00-raw/x.fq"

sh_run "$INIT && path_source"
is "path_source without an upstream -> rc=2" "$RC" "2"

sh_run "$INIT && path_source ''"
is "path_source with an empty upstream -> rc=2" "$RC" "2"

sh_run "$INIT && path_source reads.fq"
contains "path_source warns when arg 1 looks like a file" "$ERR" "looks like a file"

sh_run "$INIT && path_raw r1.fq"
is "path_raw -> data/00-raw/d<step>/" "$OUT" "$ROOT/data/00-raw/d010-import/r1.fq"

sh_run "$INIT && path_resource 01-fastq"
is "path_resource -> data/00-raw/d00-resource/" "$OUT" "$ROOT/data/00-raw/d00-resource/01-fastq"

sh_run "$INIT && path_run_state"
is "path_run_state -> data/.run-state/<step>/" "$OUT" "$ROOT/data/.run-state/010-import"

# The load-bearing property of the .run-state layout (see the C stage): run state must NOT
# live under the step target, or create_dir_target --clean / an ERR trap would wipe the
# -resume cache along with the outputs.
sh_run "$INIT && t=\"\$(path_target)\"; r=\"\$(path_run_state)\"; case \"\$r\" in \"\$t\"/*) printf inside;; *) printf sibling;; esac"
is "run-state is a SIBLING of the target, not inside it" "$OUT" "sibling"

sh_run "path_target"
is "path_* before qproj_init -> rc=1" "$RC" "1"
contains "...and says to call qproj_init first" "$ERR" "qproj_init"

printf '\n== qproj_set_step ==\n'

sh_run "$INIT && qproj_set_step 020-assemble && path_target"
is "qproj_set_step re-points path_target" "$OUT" "$ROOT/data/020-assemble"

sh_run "$INIT && qproj_set_step ../escape"
is "qproj_set_step rejects a path component with / -> rc=2" "$RC" "2"

printf '\n== create_dir_target ==\n'

sh_run "$INIT && create_dir_target >/dev/null && [ -d '$ROOT/data/010-import' ] && printf yes"
is "create_dir_target makes the target directory" "$OUT" "yes"

sh_run "$INIT && create_dir_target >/dev/null && : > '$ROOT/data/010-import/stale' && create_dir_target --clean >/dev/null && ls '$ROOT/data/010-import' | wc -l | tr -d ' '"
is "--clean empties the target" "$OUT" "0"

# Defence in depth: STEP is validated at init, so reach past it by setting the variable
# directly -- the rm -rf guard must still refuse anything not strictly under data/.
sh_run "$INIT && QPROJ_STEP=.. create_dir_target --clean"
is "--clean refuses a STEP escaping data/ -> rc=1" "$RC" "1"
contains "...and says it is refusing" "$ERR" "refusing"

printf '\n== set -e discipline ==\n'

# A failing command substitution used INLINE is masked by the outer command's exit status;
# the same substitution used in an ASSIGNMENT aborts. qproj.sh documents this; assert it,
# because every driver depends on the assign-first idiom being the safe one.
OUT="$(bash -c "set -euo pipefail; . '$LIB'; $INIT >/dev/null; echo \"\$(path_source)\" >/dev/null; printf reached" 2>/dev/null)"
is "inline \$(path_source) failure is MASKED (the trap being documented)" "$OUT" "reached"

OUT="$(bash -c "set -euo pipefail; . '$LIB'; $INIT >/dev/null; x=\"\$(path_source)\"; printf reached" 2>/dev/null)"
is "assign-first \$(path_source) failure ABORTS (the safe idiom)" "$OUT" ""

printf '\n== qproj_nf_prepare ==\n'

sh_run "$INIT && qproj_nf_prepare && printf '%s' \"\$NXF_WORK\""
is "direct call exports NXF_WORK" "$OUT" "$ROOT/data/.run-state/010-import/work"

sh_run "$INIT && qproj_nf_prepare && printf '%s' \"\$NXF_CACHE_DIR\""
is "direct call exports NXF_CACHE_DIR" "$OUT" "$ROOT/data/.run-state/010-import/cache"

sh_run "$INIT && qproj_nf_prepare && printf '%s' \"\$QPROJ_NF_LOG\""
is "direct call exports QPROJ_NF_LOG" "$OUT" "$ROOT/data/.run-state/010-import/log/nextflow.log"

# The trap the C stage's test caught: a command substitution runs in a subshell, so the
# exports never reach the caller. Asserted so nobody "tidies" the call site into $( ).
sh_run "$INIT && _=\$(qproj_nf_prepare) && printf '[%s]' \"\${NXF_WORK:-unset}\""
is "\$(qproj_nf_prepare) loses the exports (subshell)" "$OUT" "[unset]"

sh_run "$INIT && qproj_nf_prepare && create_dir_target --clean >/dev/null && [ -d \"\$NXF_WORK\" ] && printf survived"
is "create_dir_target --clean does NOT destroy run-state" "$OUT" "survived"

printf '\n== bootstrap resolver ==\n'

if [ -z "$BOOT" ] || [ ! -r "$BOOT" ]; then
  skip "resolver tests" "no bootstrap block passed as \$2"
else
  boot_run "QPROJ_SH='$LIB' _qproj_bootstrap --root '$ROOT' --step s && path_target"
  is "\$QPROJ_SH wins and the helpers load" "$OUT" "$ROOT/data/s"

  boot_run "QPROJ_SH='$TMP/nope.sh' _qproj_bootstrap --root '$ROOT' --step s"
  is "QPROJ_SH set but unreadable -> rc=1 (no silent downgrade)" "$RC" "1"
  contains "...and names the unreadable path" "$ERR" "$TMP/nope.sh"

  # With QPROJ_SH unset, an uninstalled package must fall through to the dev checkout.
  # PATH is emptied so the system.file() probe cannot succeed by accident.
  CHECKOUT="$TMP/checkout"; mkdir -p "$CHECKOUT/inst/scripts"; cp "$LIB" "$CHECKOUT/inst/scripts/qproj.sh"
  boot_run "unset QPROJ_SH; PATH=/nonexistent QPROJ_HOME='$CHECKOUT' _qproj_bootstrap --root '$ROOT' --step s && path_target"
  is "falls back to the \$QPROJ_HOME dev checkout" "$OUT" "$ROOT/data/s"

  boot_run "unset QPROJ_SH; PATH=/nonexistent QPROJ_HOME='$TMP/absent' _qproj_bootstrap --root '$ROOT' --step s"
  is "nothing found anywhere -> rc=1" "$RC" "1"
  contains "...and lists the dev checkout it tried" "$ERR" "dev checkout"
  contains "...and suggests a fix" "$ERR" "QPROJ_SH="

  # The resolved path is exported so child scripts / nested srun reuse the same file.
  boot_run "unset QPROJ_SH; PATH=/nonexistent QPROJ_HOME='$CHECKOUT' _qproj_bootstrap --root '$ROOT' --step s && bash -c 'printf %s \"\$QPROJ_SH\"'"
  is "resolved QPROJ_SH is exported to children" "$OUT" "$CHECKOUT/inst/scripts/qproj.sh"

  # The bootstrap forwards "$@" to qproj_init, so init failures must surface as its rc
  # rather than being swallowed by the resolver. (An EXISTING --root is deliberately
  # trusted without a _quarto.yml check -- that is qproj_init's documented escape hatch
  # for drivers under symlinked directories -- so use a nonexistent one here.)
  boot_run "QPROJ_SH='$LIB' _qproj_bootstrap --root '$TMP/absent-root' --step s"
  is "qproj_init's failure rc surfaces through the bootstrap" "$RC" "1"
fi

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
