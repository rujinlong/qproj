#' Scaffold a Quarto-canonical manuscript
#'
#' Create a dual-format (`pdf` + `docx`) manuscript `.qmd` from an opinionated
#' template and drop the companion `title.tex` LaTeX partial next to it. This
#' encodes the Quarto-canonical manuscript policy: one `.qmd` source renders to
#' `docx` (for supervisor Track Changes / journal submission), `pdf`
#' (self/preprint), and a `keep-tex` `.tex` escape hatch.
#'
#' The `title.tex` partial renders a proper multi-author / multi-affiliation /
#' corresponding-author title block via `authblk` --- vanilla Quarto `pdf`
#' garbles author superscripts for anything beyond a single author. It is
#' referenced by `template-partials:` in the manuscript YAML and is copied
#' verbatim (it uses pandoc `$...$` template syntax, not whisker `{{ }}`).
#'
#' After scaffolding, generate the Word `reference-doc` once from a styled
#' source document with `vpipe docx extract-template <your-style.docx> -o
#' manuscript-template.docx`.
#'
#' @param name Manuscript step name (no extension, no sub-directory). Manuscripts
#'   conventionally sort last, e.g. `"090-manuscript"` or `"99-manuscript"`.
#' @param path_proj Project sub-directory to create the file in. Default
#'   `"analyses/manuscript"` (the qproj convention: every manuscript lives in
#'   `analyses/manuscript/`). The qmd's `here::i_am()` is anchored relative to the
#'   `analyses/` axis, so `proj_path_*()` keep resolving to the shared
#'   `analyses/data/` tree regardless of the manuscript's sub-directory depth.
#' @param open Whether to open the new file for editing. Defaults to interactive.
#' @param ignore Whether to add the created files to `.Rbuildignore`.
#'
#' @return Invisibly `NULL`, called for its side effects.
#'
#' @seealso [use_qmd()] for ordinary analysis steps.
#'
#' @examples
#' \dontrun{
#'   use_manuscript()                 # creates analyses/manuscript/090-manuscript.qmd + title.tex
#'   use_manuscript("99-manuscript")  # -> analyses/manuscript/99-manuscript.qmd
#' }
#' @export
use_manuscript <- function(name = "090-manuscript", path_proj = "analyses/manuscript",
                           open = rlang::is_interactive(),
                           ignore = FALSE) {

  assertthat::assert_that(
    identical(name, basename(name)),
    msg = "you cannot specify a sub-directory to `path_proj`"
  )

  if (grepl("^00-", name)) {
    cli::cli_abort(c(
      "{.val {name}} starts with the reserved {.val 00-} prefix.",
      "i" = "qproj reserves {.val 00-} for the framework's {.code data/00-raw/} input region."
    ))
  }

  name <- tools::file_path_sans_ext(name)
  filename <- glue::glue("{name}.qmd")
  uuid <- uuid::UUIDgenerate()

  # qproj anchors `here` at the `analyses/` axis (so `proj_path_*()` resolve to
  # analyses/data/). When the manuscript sits in a sub-directory of it (the
  # default analyses/manuscript/), declare the qmd's path RELATIVE TO that axis
  # in `here::i_am()` so the data tree stays shared instead of collapsing to
  # <path_proj>/data/. For path_proj == "analyses" this is just the bare
  # filename (unchanged behaviour).
  here_subpath <- sub("^analyses/?", "", path_proj)
  i_am_path <- if (nzchar(here_subpath)) file.path(here_subpath, filename) else filename

  # use_template() does not create intermediate directories; ensure path_proj
  # exists (notably the analyses/manuscript/ sub-directory on first scaffold).
  fs::dir_create(path_proj)

  usethis::use_template(
    "manuscript.qmd",
    save_as = fs::path(path_proj, filename),
    data = list(name = name, uuid = uuid, path_proj = path_proj, i_am_path = i_am_path),
    ignore = ignore,
    open = open,
    package = "qproj"
  )

  # Drop the title.tex partial verbatim (pandoc template syntax, no whisker).
  title_dest <- fs::path(path_proj, "title.tex")
  if (fs::file_exists(title_dest)) {
    cli::cli_alert_info("{.file {title_dest}} already exists; left untouched.")
  } else {
    title_src <- system.file("templates", "title.tex", package = "qproj")
    if (!nzchar(title_src)) {
      cli::cli_abort("Could not locate {.file title.tex} template in the qproj package.")
    }
    fs::file_copy(title_src, title_dest)
    cli::cli_alert_success("Wrote author-block partial {.file {title_dest}}.")
  }

  cli::cli_alert_info("Next: generate the Word {.code reference-doc} once from a styled source:")
  cli::cli_code(glue::glue(
    "vpipe docx extract-template <your-style.docx> -o ",
    "{fs::path(path_proj, 'manuscript-template.docx')}"
  ))

  invisible(NULL)
}
