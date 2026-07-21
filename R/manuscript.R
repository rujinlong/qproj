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
#' It also drops a minimal `_quarto.yml` so the manuscript directory is its own
#' Quarto project root. Manuscripts live under `analyses/manuscript/`, inside the
#' `analyses/` Quarto project the analysis notebooks use; without this file Quarto
#' walks up to `analyses/_quarto.yml` and merges that project's metadata into the
#' manuscript --- notably prepending its default `author:` to the manuscript's own
#' author list (the rendered byline then survives only by Quarto's name
#' de-duplication, which is fragile across Quarto versions).
#'
#' After scaffolding, generate the Word `reference-doc` once from a styled
#' source document with `vpipe docx extract-template <your-style.docx> -o
#' manuscript-template.docx`.
#'
#' @param name Manuscript file stem (no extension, no sub-directory). Defaults to
#'   `<project-code>-manuscript`, where the project code is derived from the
#'   enclosing project directory name (`p0101-BTEXvirome` -> `p0101`,
#'   `p0075e2-CRCprophage` -> `p0075e2`). When the directory name has no
#'   code-shaped prefix (e.g. a generic project), it falls back to
#'   `"090-manuscript"`. The stem is deliberately STABLE across revisions: date
#'   and version stamps live only on the rendered products
#'   (`<stem>-vYYMMDD.N-submission.docx` etc.), injected by the
#'   `manuscript-render` skill at render time --- so `here::i_am()`,
#'   `_quarto.yml`, the `data/<name>/` target, and git history stay anchored to
#'   one unchanging filename.
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
#'   # In p0101-BTEXvirome/: creates analyses/manuscript/p0101-manuscript.qmd
#'   use_manuscript()
#'   use_manuscript("99-manuscript")  # -> analyses/manuscript/99-manuscript.qmd
#' }
#' @export
use_manuscript <- function(name = manuscript_default_name(),
                           path_proj = "analyses/manuscript",
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

  # use_template() does not create intermediate directories; ensure path_proj exists
  # (notably the analyses/manuscript/ sub-directory on first scaffold).
  # ANCHOR AT THE PROJECT ROOT: usethis resolves `save_as` (and the two sibling files
  # written further down) against the project, whereas fs::* are CWD-relative. Mixing the
  # two split the scaffold in half whenever the caller was not at the project root --
  # and calling this from inside analyses/, the normal qproj working directory, made
  # use_template() fail outright ("cannot open file .../manuscript/<name>.qmd") because
  # the directory it needed had been created one level too deep instead.
  dir_proj <- usethis::proj_path(path_proj)
  fs::dir_create(dir_proj)

  usethis::use_template(
    "manuscript.qmd",
    save_as = fs::path(path_proj, filename),
    data = list(name = name, uuid = uuid, path_proj = path_proj, i_am_path = i_am_path),
    ignore = ignore,
    open = open,
    package = "qproj"
  )

  # Drop the title.tex partial verbatim (pandoc template syntax, no whisker).
  # `title_dest` is absolute (project-anchored, see dir_proj above); `title_show` is the
  # project-relative form used in messages so the output stays readable.
  title_dest <- fs::path(dir_proj, "title.tex")
  title_show <- fs::path(path_proj, "title.tex")
  if (fs::file_exists(title_dest)) {
    cli::cli_alert_info("{.file {title_show}} already exists; left untouched.")
  } else {
    title_src <- system.file("templates", "title.tex", package = "qproj")
    if (!nzchar(title_src)) {
      cli::cli_abort("Could not locate {.file title.tex} template in the qproj package.")
    }
    fs::file_copy(title_src, title_dest)
    cli::cli_alert_success("Wrote author-block partial {.file {title_show}}.")
  }

  # Isolate the manuscript as its own Quarto project root. Without a _quarto.yml
  # here, Quarto walks up to the analyses/ project config (analyses/_quarto.yml:
  # the analysis-notebook default author:, gfm, toc, cache) and merges it into the
  # manuscript --- prepending that author: to the manuscript author list, so the
  # rendered byline is correct only by Quarto's name de-dup (version-fragile).
  # `render:` is scoped to the manuscript so a bare `quarto render` here does not
  # sweep sibling files (supplementary/, archive/); explicit renders are unaffected.
  quarto_dest <- fs::path(dir_proj, "_quarto.yml")
  quarto_show <- fs::path(path_proj, "_quarto.yml")
  if (fs::file_exists(quarto_dest)) {
    cli::cli_alert_info("{.file {quarto_show}} already exists; left untouched.")
  } else {
    writeLines(c(
      "# qproj: make this manuscript its own Quarto project root so an ancestor",
      "# _quarto.yml (e.g. the analyses/ analysis-notebook project --- default",
      "# author:, gfm, toc, cache) is NOT merged into the manuscript. Without this,",
      "# Quarto prepends that project's author: to the manuscript author list, and",
      "# the rendered byline survives only by Quarto's name de-dup (version-fragile).",
      "# The manuscript .qmd is self-contained (its own author / format / toc blocks).",
      "project:",
      "  type: default",
      "  render:",
      glue::glue("    - {filename}")
    ), quarto_dest)
    cli::cli_alert_success("Wrote Quarto project isolation {.file {quarto_show}}.")
  }

  cli::cli_alert_info("Next: generate the Word {.code reference-doc} once from a styled source:")
  cli::cli_code(glue::glue(
    "vpipe docx extract-template <your-style.docx> -o ",
    "{fs::path(path_proj, 'manuscript-template.docx')}"
  ))

  invisible(NULL)
}

# ── internal: derive the manuscript stem from the project code ────────────────

#' Detect the project code from the enclosing project directory name
#'
#' Walks up from `start` to the first directory that contains a `DESCRIPTION`
#' (the project root) and extracts the leading project code from its name:
#' `p`, an optional class letter (`c`/`r`/`f`/`t`), a run of digits, and zero or
#' more `e<digits>` derivative suffixes. Returns `NA_character_` when the name
#' has no code-shaped prefix (e.g. a generic project directory), so callers can
#' fall back gracefully.
#'
#' Examples of the mapping (directory name -> code):
#' `p0101-BTEXvirome` -> `p0101`; `p0075e2-CRCprophage` -> `p0075e2`;
#' `pc028e1e2-duckBiome` -> `pc028e1e2`; `pf102-DFG_chickenPhage` -> `pf102`;
#' `my-analysis` -> `NA`.
#'
#' @param start Directory to start the upward search from. Defaults to the
#'   current working directory.
#' @return A length-1 character project code, or `NA_character_`.
#' @noRd
detect_project_code <- function(start = getwd()) {
  root <- start
  while (root != dirname(root)) {
    if (fs::file_exists(fs::path(root, "DESCRIPTION"))) break
    root <- dirname(root)
  }
  nm <- basename(root)
  if (grepl("^p[a-z]?[0-9]{2,}", nm)) {
    sub("^(p[a-z]?[0-9]+(e[0-9]+)*).*$", "\\1", nm)
  } else {
    NA_character_
  }
}

#' Default manuscript stem: `<project-code>-manuscript`, else `090-manuscript`
#'
#' The canonical manuscript source keeps a STABLE name (no date, no version):
#' version/date stamps live only on the rendered products
#' (`<stem>-vYYMMDD.N-submission.docx` etc.), injected by the `manuscript-render`
#' skill's `render.sh` at render time. A stable stem keeps `here::i_am()`,
#' `_quarto.yml` `render:`, `params$name`'s `data/<name>/` target, and git
#' history all anchored to one unchanging filename across revisions.
#'
#' @param start Directory to derive the project code from (see
#'   [detect_project_code()]). Defaults to the current working directory.
#' @return A length-1 character stem.
#' @noRd
manuscript_default_name <- function(start = getwd()) {
  code <- detect_project_code(start)
  if (is.na(code)) "090-manuscript" else paste0(code, "-manuscript")
}
