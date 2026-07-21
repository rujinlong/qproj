#' @importFrom rlang `%||%`
NULL

# sort files:
#  - remove anything starting with an underscore
#  - reserve README until end
#  - get first and last files
#  - sort remainder
#  - assemble unique set
#
sort_files <- function(files, first, last) {

  # return sorted, put README at the end

  # logical, length of files
  is_readme <- grepl("^readme\\.qmd$", files, ignore.case = TRUE)
  starts_with_underscore <- grepl("^_.*\\.qmd$", files, ignore.case = TRUE)
  is_first <- files %in% first
  is_last <- files %in% last

  files_first <- files[is_first]
  files_last <- files[is_last]
  files_readme <- files[is_readme]
  files_remainder <- sort(files[!(is_first | is_last | is_readme)])

  unique(c(files_first, files_remainder, files_last, files_readme))
}

# CRAN R package name rules: starts with a letter, ends with a letter or digit,
# contains only ASCII letters, digits and dots, no consecutive dots, length >= 2.
is_valid_pkg_name <- function(name) {
  nchar(name) >= 2 &&
    grepl("^[A-Za-z][A-Za-z0-9.]*[A-Za-z0-9]$", name) &&
    !grepl("\\.\\.", name)
}

# ── project-root anchoring ───────────────────────────────────────────────────────
#
# Every `path_proj` argument is documented as "relative to the project directory", but the
# functions consuming them used to mix two resolution bases: `usethis::use_template(save_as=)`
# resolves against the PROJECT ROOT, while `fs::dir_create()` / `fs::file_copy()` /
# `writeLines()` are CWD-relative. The two agree only when the caller happens to sit at the
# project root -- and working inside `analyses/` is the normal qproj state, where the
# mismatch created stray `analyses/analyses/` directories and split scaffolds in half.

#' The active project root, or the working directory when there is none
#'
#' [proj_use_workflow()] is a bootstrapping function: it legitimately runs in a bare
#' directory that is not yet a project, so requiring an active usethis project would be a
#' new hard prerequisite. Anchor to the project when one is discoverable (which is what
#' fixes the "called from inside analyses/" case) and fall back to the working directory
#' otherwise, reproducing the old CWD-relative behaviour exactly.
#'
#' @return An absolute [fs::path].
#' @noRd
proj_root_or_wd <- function() {
  tryCatch(
    fs::path(usethis::proj_path()),
    error = function(e) fs::path_abs(fs::path_wd())
  )
}

#' Resolve `path_proj` under `root`, refusing anything that escapes it
#'
#' @param root Absolute base directory.
#' @param path_proj Path relative to `root`.
#' @param arg Name of the caller's argument, for the error message.
#' @return An absolute [fs::path] inside `root`.
#' @noRd
proj_contain <- function(root, path_proj, arg = "path_proj") {

  if (fs::is_absolute_path(path_proj)) {
    cli::cli_abort(c(
      "{.arg {arg}} must be relative to the project, not absolute.",
      "x" = "Got {.path {path_proj}}."
    ))
  }

  # `..` is NORMALISED rather than rejected (both by fs and by usethis::proj_path), so
  # "../outside" silently resolved to a directory outside the project and files really
  # were written there. Containment has to be re-checked after normalisation.
  dir <- fs::path_norm(fs::path(root, path_proj))

  if (!identical(as.character(dir), as.character(root)) &&
      !fs::path_has_parent(dir, root)) {
    cli::cli_abort(c(
      "{.arg {arg}} must stay inside the project.",
      "x" = "{.path {path_proj}} resolves to {.path {dir}}, which is outside {.path {root}}."
    ))
  }

  dir
}

#' Resolve a project-relative `path_proj` to an absolute path inside the project
#'
#' Strict variant for the scaffolders that call [usethis::use_template()], which already
#' requires an active project -- so this adds no new prerequisite.
#'
#' @param path_proj Path relative to the project root.
#' @param arg Name of the caller's argument, for the error message.
#' @return An absolute [fs::path] inside the project.
#' @noRd
proj_anchor <- function(path_proj, arg = "path_proj") {
  proj_contain(fs::path(usethis::proj_path()), path_proj, arg)
}

#' Anchor a path that is usually project-relative but may legitimately be absolute
#'
#' Used by readers rather than scaffolders. [proj_workflow_config()] is documented as
#' taking a project-relative path yet is called internally with an absolute
#' `here::here()`, and it runs during renders where no usethis project is necessarily
#' discoverable. Its contract is "return `NULL` when there is no config", so anchoring
#' must never turn into a hard failure: an absolute path is kept, and a relative one falls
#' back to itself if no project can be found.
#'
#' @param path_proj Path, absolute or relative to the project root.
#' @return An [fs::path].
#' @noRd
proj_anchor_soft <- function(path_proj) {

  if (fs::is_absolute_path(path_proj)) {
    return(fs::path_norm(path_proj))
  }

  tryCatch(
    usethis::proj_path(path_proj),
    error = function(e) fs::path_norm(path_proj)
  )
}

pui_done <- function(x, .envir = parent.frame()) cli::cli_alert_success(x, .envir = .envir)
pui_info <- function(x, .envir = parent.frame()) cli::cli_alert_info(x, .envir = .envir)
pui_oops <- function(x, .envir = parent.frame()) cli::cli_alert_danger(x, .envir = .envir)
pui_todo <- function(x, .envir = parent.frame()) cli::cli_alert_warning(x, .envir = .envir)
