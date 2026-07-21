# Locating the shell-side path helpers (inst/scripts/qproj.sh) from a Bash driver.
#
# Background: a qproj project driver (analyses/p<code>.slurm) has to `source` qproj.sh
# before it can call path_target()/path_source(). Three obvious mechanisms are all ruled
# out on the target sites, which is why an explicit contract is needed:
#
#   * relative to the script itself -- under `sbatch` the script executes from a spool
#     copy (/var/spool/slurmd/.../slurm_script), so $0 and BASH_SOURCE point elsewhere.
#   * PATH lookup -- qproj.sh is a sourced library, not a command; putting it on PATH
#     invites the mixed-runtime failure the plan's L3 layer exists to prevent.
#   * system.file() alone -- R libraries are not necessarily shared across compute nodes.
#     Measured 2026-07-21 on the spark cluster: ~/R/aarch64-unknown-linux-gnu-library/4.6
#     has different inode+mtime on spark1 vs spark2 (16267508 vs 3151102), i.e. it is
#     node-local, while ~/github is autofs-shared. Installing on the login node does not
#     make the package visible to a batch job.
#
# Hence the documented precedence in proj_shell_bootstrap(): explicit $QPROJ_SH, then the
# installed package, then a dev checkout, then a loud failure.

#' Path to the shell-side qproj path helpers
#'
#' Returns the filesystem path of `qproj.sh`, the Bash counterpart of the R path
#' discipline ([proj_path_target()] / [proj_path_source()]). A project driver
#' (`analyses/p<code>.slurm`) sources it to get `path_target`, `path_source`,
#' `path_raw`, `path_resource`, `path_run_state`, `create_dir_target` and
#' `qproj_nf_prepare`.
#'
#' This is the authoritative answer for an *installed* qproj. Drivers should not call
#' it directly in a hot loop -- they use the resolver emitted by
#' [proj_shell_bootstrap()], which consults this only as one of several candidates
#' (see that function for why an installed package cannot be the sole mechanism).
#'
#' @param mustWork If `TRUE` (default), abort when qproj is not installed with the
#'   script present. If `FALSE`, return `""` the way [base::system.file()] does.
#'
#' @return A single string: the absolute path to `qproj.sh`, or `""` when
#'   `mustWork = FALSE` and it cannot be found.
#'
#' @examples
#'   \dontrun{
#'   proj_shell_lib()
#'   }
#' @export
#'
proj_shell_lib <- function(mustWork = TRUE) {

  path <- system.file("scripts", "qproj.sh", package = "qproj")

  if (!nzchar(path) || !file.exists(path)) {
    if (isTRUE(mustWork)) {
      cli::cli_abort(c(
        "Cannot find {.file scripts/qproj.sh} in the installed {.pkg qproj}.",
        "i" = "Install the package ({.code devtools::install()}) so {.fn system.file} can see it.",
        "i" = "A driver can also point at a checkout: {.envvar QPROJ_HOME} or {.envvar QPROJ_SH}."
      ))
    }
    return("")
  }

  path
}

# The canonical Bash resolver. Kept as a single string constant so there is exactly one
# copy in this package; drivers embed it verbatim. The trailing version marker lets a
# grep (`rg 'qproj-bootstrap v'` across project repos) spot copies that lag this source.
#
# ★ BUMP THE MARKER WHENEVER THIS BLOCK CHANGES, in the same commit. A marker that stays
#   put while the content moves is worse than none: a copy taken before the change still
#   reads "v<N>" and is indistinguishable from an up-to-date one, so the grep reports
#   agreement where there is drift. (v1 -> v2 on 2026-07-21 for the unset-HOME fix.)
qproj_bootstrap_block <- '# ── qproj shell path helpers ── canonical block; SSOT = qproj::proj_shell_bootstrap()
# Locate order: $QPROJ_SH (set-but-unreadable is a HARD error, never a silent downgrade --
#   a typo must not quietly fall through to a different, older qproj.sh)
#   -> installed R package via system.file()   (authoritative wherever qproj is installed)
#   -> $QPROJ_HOME/inst/scripts/qproj.sh       (dev checkout; default ~/github/rujinlong/qproj)
#   -> loud failure listing every location tried.
# Never derives its own location from $0/BASH_SOURCE: under sbatch the script runs from a
#   spool copy, so those point at /var/spool/slurmd/.../slurm_script.
# The resolved path is exported as QPROJ_SH so child scripts and nested `srun` reuse the
#   same file without paying for another Rscript startup or risking a different version.
# Set QPROJ_OPTIONAL=1 in the caller to downgrade a miss to a warning (path_* unavailable).
_qproj_bootstrap() {                                    # qproj-bootstrap v2
    local p tried
    if [ -n "${QPROJ_SH:-}" ]; then
        [ -r "$QPROJ_SH" ] || {
            printf "qproj: QPROJ_SH is set but not readable: %s\\n" "$QPROJ_SH" >&2
            return 1
        }
        p="$QPROJ_SH"
    else
        # `|| true`: a missing Rscript / uninstalled package must not kill the caller,
        # which runs under vpipe\x27s `set -euo pipefail`.
        p="$(Rscript -e \x27cat(system.file("scripts/qproj.sh", package = "qproj"))\x27 2>/dev/null || true)"
        tried="installed R package -> ${p:-<qproj not installed>}"
        if [ -z "$p" ] || [ ! -r "$p" ]; then
            if [ -n "${QPROJ_HOME:-}" ]; then
                p="$QPROJ_HOME/inst/scripts/qproj.sh"
            else
                # `sbatch --export=NIL` drops HOME entirely, and a bare $HOME under `set -u`
                # would abort the whole driver instead of falling through to the error below.
                # Resolve it from passwd the way the site batch bootstrap does.
                local home="${HOME:-}"
                [ -n "$home" ] || home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"
                p="${home}/github/rujinlong/qproj/inst/scripts/qproj.sh"
            fi
            tried="$tried; dev checkout -> $p"
            [ -r "$p" ] || {
                printf "qproj: cannot locate qproj.sh (QPROJ_SH unset; %s)\\n" "$tried" >&2
                printf "  fix: export QPROJ_SH=<path>, or install qproj, or export QPROJ_HOME=<checkout>\\n" >&2
                return 1
            }
        fi
    fi
    # shellcheck source=/dev/null
    . "$p" || return 1
    QPROJ_SH="$p"; export QPROJ_SH
    qproj_init "$@"
}'

#' Canonical Bash bootstrap block for a project driver
#'
#' Returns the block of Bash a qproj project driver embeds to locate, source and
#' initialise the shell path helpers ([proj_shell_lib()]). This function is the single
#' source of truth for that resolver: every driver carries a verbatim copy, because none
#' of the usual indirections survive the deployment targets --- `sbatch` runs the script
#' from a spool copy (so `$0` / `BASH_SOURCE` are useless), PATH lookup reintroduces the
#' mixed-runtime hazard, and an R library is not guaranteed to be shared across compute
#' nodes (measured: `~/R/...` is node-local on the spark cluster while `~/github` is not).
#'
#' Resolution precedence, in order:
#'
#' 1. `$QPROJ_SH` --- explicit override. **Set but unreadable is a hard error**, never a
#'    silent fallback: a typo must not quietly resolve to a different qproj.sh.
#' 2. The installed package, via [proj_shell_lib()] / `system.file()`.
#' 3. `$QPROJ_HOME/inst/scripts/qproj.sh` --- dev checkout, defaulting to
#'    `~/github/rujinlong/qproj`.
#' 4. Otherwise fail, printing every location that was tried.
#'
#' The block defines one function, `_qproj_bootstrap`, which forwards its arguments to
#' `qproj_init` and exports the resolved `QPROJ_SH` so child scripts and nested `srun`
#' inherit it. A driver calls it with an explicit step:
#'
#' ```
#' _qproj_bootstrap --step pc047e3 || exit 1
#' ```
#'
#' Pass the step explicitly rather than `--step-file`: under `sbatch` the basename would
#' be `slurm_script`.
#'
#' @param step Optional step id. When supplied, the returned text includes the
#'   `_qproj_bootstrap --step <step>` call line and the surrounding failure handling;
#'   otherwise only the function definition is returned and the caller writes its own
#'   call. Must match `^[A-Za-z0-9][A-Za-z0-9._-]*$` --- **stricter than the shell-side
#'   `_qproj_validate_step`**, because this text is pasted into generated Bash, where
#'   whitespace or a shell metacharacter would change the emitted script rather than
#'   just name an odd directory. The value is single-quoted in the output as well.
#' @param optional If `TRUE`, the emitted call line tolerates a miss (warn and carry on,
#'   with `path_*` unavailable) instead of exiting. Only meaningful with `step`.
#'
#' @return A single string containing the Bash block, newline separated.
#'
#' @examples
#'   cat(proj_shell_bootstrap(step = "010-import"))
#' @export
#'
proj_shell_bootstrap <- function(step = NULL, optional = FALSE) {

  if (is.null(step)) {
    return(qproj_bootstrap_block)
  }

  if (!is.character(step) || length(step) != 1L || is.na(step) || !nzchar(step)) {
    cli::cli_abort("{.arg step} must be a single non-empty, non-{.code NA} string.")
  }

  # DELIBERATELY STRICTER than the shell-side _qproj_validate_step. That guard only has to
  # keep a slash or a dot-segment out of create_dir_target --clean's rm -rf; this function
  # GENERATES SHELL SOURCE, so anything the shell parser treats as syntax -- whitespace,
  # `;`, `$(`, a newline, a quote -- would change the meaning of the emitted script rather
  # than merely name an odd directory. Restricting to the project's actual step vocabulary
  # (010-import, pc047e3, ...) is cheap and removes the whole class.
  if (!grepl("^[A-Za-z0-9][A-Za-z0-9._-]*$", step) || step %in% c(".", "..")) {
    cli::cli_abort(c(
      "{.arg step} must be a plain step id, not {.val {step}}.",
      "i" = "Allowed: letters, digits, {.code .}, {.code _}, {.code -}; must start with a
             letter or digit. E.g. {.val 010-import} or {.val pc047e3}.",
      "x" = "This text is pasted into generated Bash, so whitespace or shell metacharacters
             would alter the emitted script; a {.code /} or {.code ..} would additionally let
             {.code create_dir_target --clean} delete outside the step directory."
    ))
  }

  # Belt and braces: even a pattern-clean step is single-quoted, so the emitted line stays
  # one argument if the pattern is ever loosened.
  quoted <- paste0("'", gsub("'", "'\\\\''", step), "'")

  call_line <- if (isTRUE(optional)) {
    paste0(
      '_qproj_bootstrap --step ', quoted, ' || {\n',
      '    printf "qproj: path helpers unavailable; %s continues without path_*\\n" ',
      quoted, ' >&2\n',
      '}'
    )
  } else {
    paste0('_qproj_bootstrap --step ', quoted, ' || exit 1')
  }

  paste(qproj_bootstrap_block, "", call_line, sep = "\n")
}
