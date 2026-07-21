# Pinning vpipe: writing, resolving and verifying `analyses/vpipe.lock`.
#
# A project driver used to reach for `$HOME/vpipe`, the live working checkout. That makes
# every analysis depend on whatever branch happens to be checked out there, with no record
# of what actually ran and no error when it changes. These functions replace that with a
# recorded pin resolving to an immutable release tree.
#
# Division of labour (integration plan L2/L4): qproj owns the lock, because a pin belongs
# to the *project*. vpipe owns the bill of materials, because that describes a *release*.
# vpipe is never told where the lock came from -- it is handed a path like any other -- so
# the compute layer stays usable by projects that have never heard of qproj.
#
# The lock format is specified in dev/vpipe-lock-format-v1.md. It is read by three
# parsers: this file (R), `qproj_vpipe_root` in inst/scripts/qproj.sh (Bash), and
# `vpipe contract check` (Python). The Bash one cannot afford a YAML library in the batch
# hot path, so the spec freezes the three fields it needs as top-level, double-quoted,
# one-per-line scalars -- which is why the writer below emits an explicit template rather
# than calling yaml::as.yaml(), whose output is unquoted and would silently break it.

#' Locate the vpipe CLI used to take and verify pins
#'
#' This is the *bootstrapper*, deliberately distinct from the pinned *runtime* a driver
#' then executes -- the same split as `rustup` versus a pinned toolchain.
#'
#' @return A single string: the path to the `vpipe` executable.
#' @noRd
vpipe_bin <- function() {

  bin <- Sys.getenv("VPIPE_CLI", unset = NA_character_)

  if (!is.na(bin) && nzchar(bin)) {
    if (!file.exists(bin)) {
      cli::cli_abort(c(
        "{.envvar VPIPE_CLI} is set but does not exist: {.path {bin}}.",
        "i" = "Unset it to fall back to the {.code vpipe} on {.envvar PATH}."
      ))
    }
    return(bin)
  }

  bin <- unname(Sys.which("vpipe"))

  if (!nzchar(bin)) {
    cli::cli_abort(c(
      "No {.code vpipe} executable found on {.envvar PATH}.",
      "i" = "Taking or verifying a pin needs the vpipe CLI (the bootstrapper).",
      "i" = "Point at one explicitly with {.envvar VPIPE_CLI}."
    ))
  }

  bin
}

#' Default vpipe source checkout
#' @noRd
vpipe_repo_default <- function() {

  repo <- Sys.getenv("VPIPE_HOME", unset = "")

  if (nzchar(repo)) fs::path_expand(repo) else fs::path_expand("~/vpipe")
}

#' Run the vpipe CLI, aborting with its own diagnostics on failure
#' @noRd
vpipe_run <- function(args, what) {

  bin <- vpipe_bin()
  err <- tempfile("vpipe-stderr-")
  on.exit(unlink(err), add = TRUE)

  out <- suppressWarnings(system2(bin, args, stdout = TRUE, stderr = err))
  status <- attr(out, "status")

  if (!is.null(status) && status != 0L) {
    cli::cli_abort(c(
      "{what} failed (exit {status}).",
      "x" = paste(readLines(err, warn = FALSE), collapse = "\n"),
      "i" = "Command: {.code {bin} {paste(args, collapse = ' ')}}"
    ))
  }

  trimws(out)
}

#' Anchor the lock path, tolerating an absolute path from a caller outside the project
#'
#' Readers may be handed an absolute path (a driver resolving its own lock); writers are
#' project-relative. Both go through the containment check in [proj_anchor()] when
#' relative, so a `path_proj` of `"../elsewhere/vpipe.lock"` cannot escape the project --
#' `..` is normalised rather than rejected by both fs and usethis, so containment has to
#' be re-checked after normalisation.
#'
#' @noRd
vpipe_lock_path <- function(path_proj, strict) {

  if (fs::is_absolute_path(path_proj)) return(fs::path_norm(path_proj))

  if (strict) return(proj_anchor(path_proj, arg = "path_proj"))

  proj_anchor_soft(path_proj)
}

#' Default compatibility range for a resolved version
#'
#' `0.9.0` -> `">=0.9,<1.0"`, matching the integration plan. Note that semver permits
#' breaking changes at *minor* bumps below 1.0, so this default is deliberately generous;
#' pass `requires` explicitly to pin a narrower band.
#'
#' @noRd
vpipe_default_requires <- function(version) {

  parts <- suppressWarnings(as.integer(strsplit(version, "[.]")[[1]]))

  if (length(parts) < 2L || anyNA(parts[1:2])) {
    cli::cli_abort(c(
      "Cannot derive a compatibility range from version {.val {version}}.",
      "i" = "Pass {.arg requires} explicitly, e.g. {.val >=0.9,<1.0}."
    ))
  }

  glue::glue(">={parts[1]}.{parts[2]},<{parts[1] + 1}.0")
}

#' Serialise a lock in the frozen scalar form the Bash resolver can read
#' @noRd
vpipe_lock_text <- function(fields) {

  quoted <- function(key) glue::glue('{key}: "{fields[[key]]}"')
  plain  <- function(key) glue::glue("{key}: {fields[[key]]}")

  c(
    "# vpipe.lock -- machine-managed. Do not hand-edit; regenerate with",
    "# qproj::proj_vpipe_pin(). Format: dev/vpipe-lock-format-v1.md",
    "lock_version: 1",
    "",
    "# Read by the Bash resolver (qproj_vpipe_root). Top-level, double-quoted, one per",
    "# line -- it parses these without a YAML library, and fails closed on any other shape.",
    quoted("resolved_version"),
    quoted("git_commit"),
    quoted("release_path"),
    "",
    "# Compatibility constraint, checked by `vpipe contract check`.",
    quoted("requires"),
    "",
    "# bom_digest covers tier-1 (git tree SHAs) + tier-3: deterministic, so a mismatch",
    "# means the release tree was tampered with -- a hard failure.",
    "# env_digest covers tier-2 (what `current` symlinks and container backends resolved",
    "# to when the pin was taken): NOT reproducible, so a mismatch is reported as drift,",
    "# not as an error.",
    quoted("bom_digest"),
    quoted("env_digest"),
    "",
    "# Declared contract surface. These are all 1 = legacy baseline, and carry no",
    "# enforcement yet: the public surface they describe does not exist until vpipe's",
    "# ABI-narrowing phase. Recorded and compared, nothing more.",
    plain("shell_api"),
    plain("nf_api"),
    plain("python_api"),
    "",
    "# Provenance of this pin.",
    quoted("pinned_at"),
    quoted("pinned_by"),
    ""
  )
}

#' Pin this project to an immutable vpipe release
#'
#' Materialises the vpipe commit named by `ref` into the release store (on a host that can
#' write to it), then records the resulting release in `analyses/vpipe.lock` so every
#' driver in this project resolves to exactly that tree.
#'
#' The digests are read back out of the materialised release's own manifest rather than
#' cut separately. A separately-cut bill of materials would describe the working checkout,
#' not the tree that will actually run, and the two can differ.
#'
#' @param path_proj Where to write the lock, relative to the project root.
#' @param ref Commit-ish in the vpipe checkout to pin. Defaults to the current release
#'   tag if there is one; pass `"HEAD"` to pin whatever is checked out.
#' @param requires Compatibility range recorded in the lock. Defaults to
#'   `">=<major>.<minor>,<major+1>.0"` for the resolved version.
#' @param vpipe_repo The vpipe source checkout to archive from. Defaults to
#'   `$VPIPE_HOME`, else `~/vpipe`.
#' @param digest Passed through to the bill of materials: sha256 every container image
#'   instead of fingerprinting by path, size and mtime. Slow (images are gigabyte-scale).
#'
#' @return Invisibly, the absolute path to the lock that was written.
#'
#' @examples
#'   \dontrun{
#'   proj_vpipe_pin()                  # pin the current vpipe release
#'   proj_vpipe_pin(ref = "v0.9.0")    # pin a specific one
#'   }
#' @export
proj_vpipe_pin <- function(path_proj = "analyses/vpipe.lock",
                           ref = "HEAD",
                           requires = NULL,
                           vpipe_repo = NULL,
                           digest = FALSE) {

  lock <- vpipe_lock_path(path_proj, strict = TRUE)
  repo <- if (is.null(vpipe_repo)) vpipe_repo_default() else fs::path_expand(vpipe_repo)

  if (!fs::dir_exists(repo)) {
    cli::cli_abort(c(
      "No vpipe checkout at {.path {repo}}.",
      "i" = "Set {.envvar VPIPE_HOME} or pass {.arg vpipe_repo}."
    ))
  }

  args <- c("contract", "resolve", "--ref", ref, "--materialize", "--repo", repo)
  if (isTRUE(digest)) args <- c(args, "--digest")

  release <- vpipe_run(args, what = glue::glue("Materialising vpipe {ref}"))
  release <- release[nzchar(release)]

  if (length(release) != 1L) {
    cli::cli_abort(c(
      "Expected exactly one release path from {.code vpipe contract resolve}.",
      "x" = "Got {length(release)} line{?s}: {.val {release}}."
    ))
  }

  manifest_path <- fs::path(release, ".vpipe-release.yml")

  if (!fs::file_exists(manifest_path)) {
    cli::cli_abort(c(
      "Materialised release has no manifest: {.path {manifest_path}}.",
      "i" = "The release is incomplete; re-materialise it."
    ))
  }

  manifest <- yaml::read_yaml(manifest_path)
  version <- manifest$release$version

  if (is.null(version) || !nzchar(version)) {
    cli::cli_abort(c(
      "The pinned vpipe commit is not tagged, so it has no version to record.",
      "i" = "Tag the release in vpipe first, then pin that tag.",
      "i" = "A pin naming an untagged commit cannot satisfy any {.field requires} range."
    ))
  }

  fields <- list(
    resolved_version = version,
    git_commit       = manifest$release$git_commit,
    release_path     = release,
    requires         = if (is.null(requires)) vpipe_default_requires(version) else requires,
    bom_digest       = manifest$bom$bom_digest,
    env_digest       = manifest$bom$env_digest,
    shell_api        = manifest$bom$tier3$shell_api,
    nf_api           = manifest$bom$tier3$nf_api,
    python_api       = manifest$bom$tier3$python_api,
    pinned_at        = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    pinned_by        = paste("qproj", utils::packageVersion("qproj"))
  )

  empty <- names(fields)[vapply(fields, function(x) is.null(x) || !nzchar(as.character(x)), logical(1))]

  if (length(empty)) {
    cli::cli_abort(c(
      "The release manifest is missing field{?s} needed for a lock: {.field {empty}}.",
      "i" = "Manifest: {.path {manifest_path}}."
    ))
  }

  fs::dir_create(fs::path_dir(lock))
  writeLines(vpipe_lock_text(fields), lock)

  vpipe_lock_verify_roundtrip(lock, fields)

  pui_done("Pinned vpipe {.val {version}} ({substr(fields$git_commit, 1, 12)})")
  pui_info("Release: {.path {release}}")
  pui_info("Lock: {.path {lock}}")

  invisible(lock)
}

#' Read back a freshly written lock and confirm it says what was intended
#'
#' The writer emits text rather than calling a YAML serialiser, so nothing else would
#' catch a template that produced valid-looking but wrong output. Reading it back with a
#' real parser turns that into an immediate failure instead of a pin that resolves
#' somewhere unexpected months later.
#'
#' @noRd
vpipe_lock_verify_roundtrip <- function(lock, fields) {

  parsed <- tryCatch(
    yaml::read_yaml(lock),
    error = function(e) {
      cli::cli_abort(c(
        "The lock just written is not valid YAML: {.path {lock}}.",
        "x" = conditionMessage(e)
      ))
    }
  )

  for (key in names(fields)) {
    if (!identical(as.character(parsed[[key]]), as.character(fields[[key]]))) {
      cli::cli_abort(c(
        "The lock just written does not read back as intended.",
        "x" = "{.field {key}}: wrote {.val {fields[[key]]}}, read {.val {parsed[[key]]}}.",
        "i" = "{.path {lock}}"
      ))
    }
  }

  invisible(TRUE)
}

#' Resolve this project's pin to an immutable vpipe release directory
#'
#' The R counterpart of `qproj_vpipe_root` in `qproj.sh`. Like it, this never falls back
#' to `~/vpipe`: a resolver that guesses produces a job which runs, emits plausible
#' output, and never reveals that it used the wrong vpipe.
#'
#' @param path_proj The lock, relative to the project root (or an absolute path).
#'
#' @return A single string: the absolute path to the pinned release.
#'
#' @examples
#'   \dontrun{
#'   Sys.setenv(VPIPE_ROOT = proj_vpipe_resolve())
#'   }
#' @export
proj_vpipe_resolve <- function(path_proj = "analyses/vpipe.lock") {

  lock <- vpipe_lock_path(path_proj, strict = FALSE)

  if (!fs::file_exists(lock)) {
    cli::cli_abort(c(
      "No vpipe.lock at {.path {lock}}.",
      "i" = "This project has not pinned vpipe. Take a pin with {.run qproj::proj_vpipe_pin()}."
    ))
  }

  parsed <- yaml::read_yaml(lock)
  release <- parsed$release_path

  if (is.null(release) || !nzchar(release)) {
    cli::cli_abort(c(
      "{.path {lock}} has no {.field release_path}.",
      "i" = "Regenerate it with {.run qproj::proj_vpipe_pin()}."
    ))
  }

  if (!fs::file_exists(fs::path(release, "bin", "00-config.sh"))) {
    cli::cli_abort(c(
      "The pinned vpipe release is not present or is incomplete: {.path {release}}.",
      "i" = "Materialise it {.strong on the login node} -- the release store is read-only
             on compute nodes by design, so a job can verify a pin but never create one.",
      "i" = "{.code vpipe contract resolve --lock {lock} --materialize}"
    ))
  }

  release
}

#' Verify this project's pin before starting any compute
#'
#' Runs `vpipe contract check`, which is where the digest, version-range and API checks
#' live -- they need a real parser, so neither this function nor the Bash resolver
#' reimplements them.
#'
#' @param path_proj The lock, relative to the project root (or an absolute path).
#' @param strict Treat environment drift as a failure. Off by default: the databases and
#'   container images a run depends on are not pinnable at all yet (20 paths resolve
#'   through `current` symlinks, and on this cluster 28 tool backends are unversioned
#'   conda environments), so drift is expected and a check that is always red is a check
#'   everyone learns to skip.
#'
#' @return Invisibly `TRUE`. Aborts if the contract is violated.
#'
#' @examples
#'   \dontrun{
#'   proj_vpipe_check()
#'   }
#' @export
proj_vpipe_check <- function(path_proj = "analyses/vpipe.lock", strict = FALSE) {

  lock <- vpipe_lock_path(path_proj, strict = FALSE)

  args <- c("contract", "check", "--lock", lock)
  if (isTRUE(strict)) args <- c(args, "--strict")

  out <- vpipe_run(args, what = "vpipe contract check")
  cat(out, sep = "\n")

  invisible(TRUE)
}
