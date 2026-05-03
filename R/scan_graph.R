#' Scan a qproj workflow into a static dependency graph
#'
#' @description
#' Advanced feature for AI-assisted workflows. Statically scans a qproj
#' analysis workflow (no R code is executed) and emits up to three artifacts
#' under `output_dir`:
#'
#' - `qproj-graph.json` — full machine-readable dependency graph
#' - `QPROJ_GRAPH_REPORT.md` — compact navigation report (designed for AI)
#' - `qproj-graph.html` — self-contained interactive `visNetwork` view
#'
#' The scanner detects three layers (each can be turned off via `scan`):
#'  - **step layer** — always on. `path_source("<step>", ...)`,
#'    `path_target("<file>", ...)`, `here::here(path_raw, "d<step>-...", ...)`,
#'    `library()` / `pkg::fn`, `path_data` / `path_resource` / `path_raw`.
#'  - **R layer** — calls into functions defined in the project's `R/*.R`
#'    (loaded via `devtools::load_all()` in each `.qmd`'s setup chunk).
#'    Captures literal scalar arguments. Functions defined but never called
#'    are flagged `unused = TRUE`.
#'  - **db layer** — DBI table dependencies. `dbReadTable / dbWriteTable /
#'    dplyr::tbl` literal table args (EXTRACTED), and table names extracted
#'    from SQL strings passed to `dbGetQuery / dbExecute` via regex
#'    (INFERRED). `dbConnect()` paths are parsed (path_target / path_source /
#'    here::here / file.path / literal) so each table node carries its
#'    project-relative `db_file`.
#'
#' Scanner output is consumed by AI assistants (Claude Code, Gemini CLI, etc.)
#' so they can reason about workflow structure without reading every `.qmd`.
#' Typical token saving on a 5-step workflow: ~10x vs. reading the raw files.
#'
#' @param path `character` project root (default: current directory).
#' @param workflow `character` workflow subdirectory under `path`
#'   (default: `"analyses"`).
#' @param r_dir `character` directory of project R functions, relative to
#'   `path` (default: `"R"`). If absent, the R layer is skipped silently.
#' @param output_dir `character` output directory, relative to `path`
#'   (default: `".qproj/graph"`).
#' @param scan `character` subset of `c("step", "R", "db")` selecting
#'   which detection layers to run. Default: all three on. Set
#'   `scan = "step"` to reproduce v1 behavior.
#' @param formats `character` subset of `c("json", "md", "html")`. Choose
#'   only the artifacts you need; `"html"` requires `visNetwork` and
#'   `htmlwidgets`.
#' @param include_data_nodes `logical` if `TRUE`, also emit data-file nodes
#'   in addition to step nodes. Currently a placeholder for future use.
#' @param quiet `logical` suppress CLI progress messages.
#'
#' @return Invisibly, the in-memory graph object (a list with `metadata`,
#'   `nodes`, `edges`, `warnings`, `render_order`).
#'
#' @section Suggested packages:
#' Calling `proj_scan_graph()` requires (Suggests, not Imports):
#' `knitr`, `rmarkdown`, `jsonlite`, plus `visNetwork` and `htmlwidgets`
#' if `"html"` is in `formats`.
#'
#' @examples
#' \dontrun{
#'   # From inside a qproj project root:
#'   qproj::proj_scan_graph()
#'
#'   # JSON + MD only, skipping the HTML viewer:
#'   qproj::proj_scan_graph(formats = c("json", "md"))
#' }
#' @export
proj_scan_graph <- function(path = ".",
                            workflow = "analyses",
                            r_dir = "R",
                            output_dir = ".qproj/graph",
                            scan = c("step", "R", "db"),
                            formats = c("json", "md", "html"),
                            include_data_nodes = FALSE,
                            quiet = FALSE) {

  formats <- match.arg(formats, c("json", "md", "html"), several.ok = TRUE)
  scan    <- match.arg(scan, c("step", "R", "db"), several.ok = TRUE)

  required <- c("knitr", "rmarkdown", "jsonlite")
  if ("html" %in% formats) required <- c(required, "visNetwork", "htmlwidgets")
  rlang::check_installed(
    required,
    reason = "to scan a qproj workflow into a graph."
  )

  project_root <- normalizePath(path, mustWork = TRUE)
  workflow_dir <- file.path(project_root, workflow)
  if (!dir.exists(workflow_dir)) {
    cli::cli_abort(c(
      "Workflow directory not found: {.path {workflow_dir}}",
      "i" = "Specify {.arg workflow} or run {.fn proj_use_workflow} first."
    ))
  }

  # Discover .qmd files (skip _*.qmd partials).
  qmd_files <- list.files(workflow_dir, pattern = "\\.qmd$",
                          full.names = TRUE, recursive = FALSE)
  qmd_files <- qmd_files[!grepl("^_", basename(qmd_files))]
  if (length(qmd_files) == 0L) {
    cli::cli_abort(c(
      "No .qmd files found in {.path {workflow_dir}}.",
      "i" = "Use {.fn use_qmd} to create one."
    ))
  }

  if (!quiet) pui_info("Scanning {length(qmd_files)} .qmd file{?s} in {.path {workflow}}/")

  # Determine render order via existing sort_files() + _qproj.yml.
  config <- proj_workflow_config(workflow_dir)
  render <- if (is.null(config)) list() else config$render %||% list()
  render_first <- render$first %||% character(0)
  render_last <- render$last %||% character(0)

  basenames <- basename(qmd_files)
  ordered_basenames <- sort_files(basenames, first = render_first, last = render_last)
  render_order <- tools::file_path_sans_ext(ordered_basenames)

  # Re-order qmd_files to match render order.
  qmd_files <- file.path(workflow_dir, ordered_basenames)

  # R layer: extract function definitions from R/*.R if requested + present.
  r_functions <- list()
  ctx <- list(local_fns = character(0), pkg_name = NA_character_,
              scan_db = "db" %in% scan)
  if ("R" %in% scan) {
    r_dir_abs <- if (fs::is_absolute_path(r_dir)) r_dir else file.path(project_root, r_dir)
    if (dir.exists(r_dir_abs)) {
      r_functions <- scan_r_functions(r_dir_abs)
      ctx$local_fns <- vapply(r_functions, function(fr) fr$name, character(1))
      ctx$pkg_name  <- project_pkg_name(project_root)
      if (!quiet) pui_info("Found {length(r_functions)} function{?s} in {.path {r_dir}}/")
    } else if (!quiet) {
      pui_info("R layer skipped: no {.path {r_dir}}/ directory")
    }
  }

  # Scan each file with the assembled context.
  scan_results <- lapply(qmd_files, function(f) {
    if (!quiet) pui_info("  scanning {.file {basename(f)}}")
    scan_qmd(f, ctx = ctx)
  })

  # Build graph.
  graph <- build_graph(
    scan_results, render_order,
    project_root = project_root, workflow = workflow,
    r_functions  = r_functions
  )

  # Write outputs. Honor absolute output_dir verbatim.
  out_abs <- if (fs::is_absolute_path(output_dir)) {
    output_dir
  } else {
    file.path(project_root, output_dir)
  }
  dir.create(out_abs, showWarnings = FALSE, recursive = TRUE)

  if ("json" %in% formats) {
    p <- file.path(out_abs, "qproj-graph.json")
    render_json(graph, p)
    if (!quiet) pui_done("wrote {.file {file.path(output_dir, 'qproj-graph.json')}}")
  }
  if ("md" %in% formats) {
    p <- file.path(out_abs, "QPROJ_GRAPH_REPORT.md")
    render_md(graph, p)
    if (!quiet) pui_done("wrote {.file {file.path(output_dir, 'QPROJ_GRAPH_REPORT.md')}}")
  }
  if ("html" %in% formats) {
    p <- file.path(out_abs, "qproj-graph.html")
    render_html(graph, p)
    if (!quiet) pui_done("wrote {.file {file.path(output_dir, 'qproj-graph.html')}}")
  }

  # Always install the qg query CLI alongside the graph. It's a 200-line
  # bash+jq wrapper that exposes node / impact / deps / unused / stale / paths
  # subcommands so AI assistants (and humans) can answer dependency questions
  # without reading the full JSON. Sized at ~10 KB; cheaper to ship than to
  # justify omitting.
  install_qg(out_abs, output_dir, quiet)

  if (!quiet && length(graph$warnings) > 0L) {
    pui_todo("{length(graph$warnings)} warning{?s} -- see report for details")
  }
  if (!quiet) {
    pui_info("AI prompt: {.code Read .qproj/graph/QPROJ_GRAPH_REPORT.md first; query the graph via bash .qproj/graph/qg --help}")
  }

  invisible(graph)
}

# Copy inst/scripts/qg next to the graph and chmod +x. Warn if jq is not
# installed, but never fail -- users with the JSON can still use jq later.
install_qg <- function(out_abs, output_dir, quiet) {
  src <- system.file("scripts", "qg", package = "qproj")
  if (!nzchar(src) || !file.exists(src)) return(invisible())  # dev-mode fallback handled by load_all
  dst <- file.path(out_abs, "qg")
  file.copy(src, dst, overwrite = TRUE)
  Sys.chmod(dst, mode = "0755")
  if (!quiet) pui_done("wrote {.file {file.path(output_dir, 'qg')}} (graph query CLI)")
  if (!quiet && Sys.which("jq") == "") {
    pui_oops("{.code jq} not found on PATH -- {.code qg} needs it. Install: {.code brew install jq} (mac) or {.code apt install jq} (debian).")
  }
}
