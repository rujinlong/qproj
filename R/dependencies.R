#' Check or update dependency declarations
#'
#' @description
#' This uses [renv::dependencies()], which scans your project directory for
#' package-dependency declarations. It compares packages detected in the code
#' with those declared in the `DESCRIPTION` to determine missing and extra
#' package-dependency declarations.
#'
#' By default, `proj_update_deps()` will not remove extra package-dependency
#' declarations; you can change this by using `remove_extra = TRUE`.
#'
#' \describe{
#'   \item{proj_check_deps()}{Prints missing and extra dependencies.}
#'   \item{proj_update_deps()}{Updates `DESCRIPTION` file with missing and
#'     extra dependencies.}
#' }
#'
#' @param path `character`, path to the project directory. If your current
#' working-directory is in the project, the default will do the right thing.
#' @param remove_extra `logical`, indicates to remove dependency-declarations
#'  that [renv::dependencies()] can't find being used.
#'
#' @return Invisible `NULL` or list, called for side effects.
#'
#' @examples
#' # not run because it produces side effects
#' if (FALSE) {
#'
#'   # check DESCRIPTION for missing and extra dependencies
#'   proj_check_deps()
#'
#'   # update DESCRIPTION with missing dependencies
#'   proj_update_deps()
#' }
#' @export
#'
proj_check_deps <- function(path = usethis::proj_get()) {
  diff <- check_deps(path)

  if (length(diff$missing) > 0) {
    cli::cli_alert_danger("Missing from DESCRIPTION: {.pkg {diff$missing}}")
  } else {
    cli::cli_alert_success("No missing dependencies.")
  }

  if (length(diff$extra) > 0) {
    cli::cli_alert_info("Extra in DESCRIPTION (not used): {.pkg {diff$extra}}")
  } else {
    cli::cli_alert_success("No extra dependencies.")
  }

  if (length(diff$missing) > 0 || length(diff$extra) > 0) {
    cli::cli_alert_warning("Run {.fn proj_update_deps} to update DESCRIPTION automatically.")
  }

  invisible(diff)
}


#' @rdname proj_check_deps
#' @export
#'
proj_update_deps <- function(path = usethis::proj_get(), remove_extra = FALSE) {
  diff <- check_deps(path)

  if (length(diff$missing) > 0) {
    for (pkg in diff$missing) desc::desc_set_dep(pkg, type = "Imports", file = fs::path(path, "DESCRIPTION"))
    cli::cli_alert_success("Added to DESCRIPTION: {.pkg {diff$missing}}")
  } else {
    cli::cli_alert_success("No missing dependencies.")
  }

  if (length(diff$extra) > 0) {
    if (remove_extra) {
      for (pkg in diff$extra) desc::desc_del_dep(pkg, file = fs::path(path, "DESCRIPTION"))
      cli::cli_alert_success("Removed from DESCRIPTION: {.pkg {diff$extra}}")
    } else {
      cli::cli_alert_info("Extra in DESCRIPTION (not removed): {.pkg {diff$extra}}")
    }
  } else {
    cli::cli_alert_success("No extra dependencies.")
  }

  invisible(NULL)
}

#' Install dependencies
#'
#' Use to install the project's package dependencies from `DESCRIPTION`
#' using [pak::local_install_deps()].
#'
#' @inheritParams proj_check_deps
#'
#' @return Invisible `NULL`, called for side effects.
#' @examples
#' # not run because it produces side effects
#' if (FALSE) {
#'   proj_install_deps()
#' }
#' @export
#'
proj_install_deps <- function(path = usethis::proj_get()) {
  cli::cli_alert_info("Installing dependencies from DESCRIPTION using pak...")
  pak::local_install_deps(root = path)
  invisible(NULL)
}

# internal function, returns list of missing and extra dependencies
check_deps <- function(path = usethis::proj_get()) {

  file_desc <- fs::path(path, "DESCRIPTION")

  if (!fs::file_exists(file_desc)) {
    cli::cli_abort(c(
      "No {.file DESCRIPTION} found in {.path {path}}.",
      "i" = "Run {.fn proj_create} first, or pass {.arg path} pointing at an existing project."
    ))
  }

  deps <- suppressMessages(
    renv::dependencies(path = path, quiet = TRUE, progress = FALSE)
  )

  # Source == DESCRIPTION rows are the declared deps; the rest are detected from code
  detected <- unique(deps[deps[["Source"]] != file_desc, "Package", drop = TRUE])
  declared <- unique(deps[deps[["Source"]] == file_desc, "Package", drop = TRUE])

  list(
    missing = detected[!(detected %in% declared)],
    extra   = declared[!(declared %in% detected)]
  )
}
