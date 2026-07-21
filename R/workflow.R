#' Use opinionated qmd template
#'
#' Use this function to create a new, templated Quarto file in a workflow
#' directory.
#'
#' This is an opinionated system; it introduces restrictions to help keep you
#' "inside the boat":
#'
#' - All the Quarto files in a workflow are in the same directory; there
#'   are no sub-directories with Quarto files.
#'
#' - Using [here::i_am()] establishes the root of the workflow as the
#'   directory that contains the Quarto file. In other words, when the
#'   Quarto file is rendered, this directory becomes the [here::here()] root.
#'
#' - It creates a dedicated data-directory for this file to write to, making
#'   sure that this data-directory is empty at the start of the rendering. It
#'   also provides an accessor function `path_target()` that you can use later
#'   in the file to compose paths to this data-directory. For example:
#'
#'   ```
#'   write.csv(mtcars, path_target("mtcars.csv"))
#'   ```
#'
#'   It also provides an accessor function to the data directory itself, which
#'   can be useful for reading data from "previous" files.
#'
#'   ```
#'   fun_data <- read.csv(path_source("00-import", "fun_data.csv"))
#'   ```
#'
#' @param name `character` name of the workflow component.
#' @param path_proj `character` path to workflow directory,
#'   relative to the project directory. Defaults to `"analyses"`.
#' @param open `logical` indicates to open the file for interactive editing.
#' @param ignore `logical` indicates to add this file to `.Rbuildignore`.
#'
#' @return Invisible `NULL`, called for side effects.
#'
#' @examples
#' # not run because it creates side effects
#' \dontrun{
#'   # creates file `01-clean.qmd`
#'   use_qmd("01-clean")
#' }
#' @export
#'
use_qmd <- function(name, path_proj = "analyses",
                    open = rlang::is_interactive(),
                    ignore = FALSE) {

  # ensure that we are not using a subdirectory
  assertthat::assert_that(
    identical(name, basename(name)),
    msg = "you cannot specify a sub-directory to `path_proj`"
  )

  name <- tools::file_path_sans_ext(name)

  if (grepl("^00-", name)) {
    cli::cli_abort(c(
      "{.val {name}} starts with the reserved {.val 00-} prefix.",
      "i" = "qproj reserves {.val 00-} for the framework's {.code data/00-raw/} input region.",
      "i" = "Start your own steps at {.val 01-} or higher (e.g. {.code use_qmd(\"01-import\")})."
    ))
  }

  filename <- glue::glue("{name}.qmd")
  uuid <- uuid::UUIDgenerate()

  # Anchor `here::i_am()` relative to the `analyses/` axis so a step placed in a
  # sub-directory of analyses/ (e.g. path_proj = "analyses/manuscript") keeps
  # `proj_path_*()` resolving to the shared analyses/data/ tree. For the default
  # path_proj == "analyses" this is just the bare filename (unchanged behaviour).
  here_subpath <- sub("^analyses/?", "", path_proj)
  i_am_path <- if (nzchar(here_subpath)) file.path(here_subpath, filename) else filename

  # use_template() does not create intermediate directories; ensure path_proj exists
  # (e.g. analyses/manuscript/ when a step is placed in a sub-directory).
  # ANCHOR AT THE PROJECT ROOT: `save_as` below is resolved by usethis against the
  # project, so a bare `fs::dir_create(path_proj)` -- which is CWD-relative -- creates the
  # wrong directory whenever the caller is not sitting at the project root. Working from
  # inside analyses/ is the normal state for a qproj user, and there it silently produced
  # a stray, empty analyses/analyses/ while the qmd landed correctly under the root.
  fs::dir_create(usethis::proj_path(path_proj))

  usethis::use_template(
    "workflow.qmd",
    save_as = fs::path(path_proj, filename),
    data = list(name = name, uuid = uuid, path_proj = path_proj, i_am_path = i_am_path),
    ignore = ignore,
    open = open,
    package = "qproj"
  )

  invisible(NULL)
}


#' Get workflow configuration
#'
#' Looks for a file named `_qproj.yml` in `path_proj`. If present, reads
#' using [yaml::read_yaml()]; if not present, returns `NULL`.
#'
#' The configuration supports a single element, `render`.
#'
#' ```
#' render:
#'   first:
#'     00-import.qmd
#'   last:
#'     99-publish.qmd
#' ```
#'
#' @param path_proj `character` path to workflow directory,
#'   relative to the project directory.
#'
#' @return `NULL`, or `list` describing workflow configuration
#'
#' @keywords internal
#' @export
#'
proj_workflow_config <- function(path_proj) {

  path_yml <- fs::path(path_proj, "_qproj.yml")

  if (!fs::file_exists(path_yml)) {
    return(NULL)
  }

  yaml::read_yaml(path_yml)
}

