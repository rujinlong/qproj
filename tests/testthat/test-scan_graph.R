fixture_root <- testthat::test_path("fixtures", "scan_minimal")
fixture_dir  <- fs::path(fixture_root, "analyses")

skip_if_missing_suggests <- function() {
  needed <- c("knitr", "rmarkdown", "jsonlite")
  miss <- needed[!vapply(needed, requireNamespace, logical(1), quietly = TRUE)]
  if (length(miss)) skip(paste("missing Suggests:", paste(miss, collapse = ", ")))
}

# ---- low-level: scan_qmd() -------------------------------------------------

test_that("scan_qmd() extracts EXTRACTED reads_from from a literal-string call", {
  skip_if_missing_suggests()
  res <- scan_qmd(fs::path(fixture_dir, "02-clean.qmd"))
  expect_identical(res$name, "02-clean")
  expect_length(res$reads_from, 1L)
  edge <- res$reads_from[[1L]]
  expect_identical(edge$target, "01-import")
  expect_identical(edge$confidence, "EXTRACTED")
  expect_identical(edge$file_arg, "seqs.csv")
})

test_that("scan_qmd() flags variable step argument as AMBIGUOUS", {
  skip_if_missing_suggests()
  res <- scan_qmd(fs::path(fixture_dir, "03-analyze.qmd"))
  conf <- vapply(res$reads_from, function(e) e$confidence, character(1))
  expect_true("EXTRACTED" %in% conf)
  expect_true("AMBIGUOUS" %in% conf)
  warn_types <- vapply(res$warnings, function(w) w$type, character(1))
  expect_true("AMBIGUOUS_PATH_SOURCE" %in% warn_types)
})

test_that("scan_qmd() detects bypass_access via here::here(path_raw, 'd<step>')", {
  skip_if_missing_suggests()
  res <- scan_qmd(fs::path(fixture_dir, "02-clean.qmd"))
  expect_length(res$bypass_access, 1L)
  expect_identical(res$bypass_access[[1L]]$target, "01-import")
  warn_types <- vapply(res$warnings, function(w) w$type, character(1))
  expect_true("ANTI_PATTERN_BYPASS_ACCESS" %in% warn_types)
})

test_that("scan_qmd() does NOT flag setup-chunk d00-resource as bypass", {
  skip_if_missing_suggests()
  # All five fixtures have the standard binding `path_resource <- here::here(path_raw, "d00-resource")`.
  # None of those should produce bypass warnings.
  for (name in c("01-import", "03-analyze", "99-publish")) {
    res <- scan_qmd(fs::path(fixture_dir, paste0(name, ".qmd")))
    expect_length(res$bypass_access, 0L)
  }
})

test_that("scan_qmd() ignores commented-out path_source() calls", {
  skip_if_missing_suggests()
  res <- scan_qmd(fs::path(fixture_dir, "02-clean.qmd"))
  targets <- vapply(res$reads_from, function(e) e$target, character(1))
  expect_false("nonexistent-step" %in% targets)
})

test_that("scan_qmd() collects path_target outputs and r_packages", {
  skip_if_missing_suggests()
  res <- scan_qmd(fs::path(fixture_dir, "01-import.qmd"))
  outs <- vapply(res$outputs, function(o) o$file, character(1))
  expect_setequal(outs, c("seqs.csv", "metadata.tsv"))
  expect_true(all(c("dplyr", "readr", "qproj") %in% res$r_packages))
})

test_that("scan_qmd() flags path_data and path_resource symbol references", {
  skip_if_missing_suggests()
  res_import  <- scan_qmd(fs::path(fixture_dir, "01-import.qmd"))
  res_analyze <- scan_qmd(fs::path(fixture_dir, "03-analyze.qmd"))
  expect_true(res_import$uses_path_data)
  expect_false(res_import$uses_path_resource)
  expect_true(res_analyze$uses_path_resource)
})

test_that("scan_qmd() does not flag template setup-chunk references as user use", {
  skip_if_missing_suggests()
  # An untouched workflow.qmd template only contains setup-chunk bindings;
  # uses_path_data / uses_path_resource / uses_path_raw must all be FALSE.
  proj_root <- withr::local_tempdir()
  suppressMessages(proj_create(proj_root))
  withr::local_dir(proj_root)
  suppressMessages(proj_use_workflow("analyses"))
  use_qmd("01-import", path_proj = "analyses", open = FALSE)
  res <- scan_qmd("analyses/01-import.qmd")
  expect_false(res$uses_path_data)
  expect_false(res$uses_path_resource)
  expect_false(res$uses_path_raw)
})

# ---- end-to-end: proj_scan_graph() -----------------------------------------

test_that("proj_scan_graph() emits all three artifacts and respects formats", {
  skip_if_missing_suggests()
  skip_if_not_installed("visNetwork")
  skip_if_not_installed("htmlwidgets")

  out <- withr::local_tempdir()
  g <- proj_scan_graph(
    path = fixture_root,
    workflow = "analyses",
    output_dir = out,
    quiet = TRUE
  )
  expect_true(file.exists(fs::path(out, "qproj-graph.json")))
  expect_true(file.exists(fs::path(out, "QPROJ_GRAPH_REPORT.md")))
  expect_true(file.exists(fs::path(out, "qproj-graph.html")))
  # _files/ sidecar should have been pruned
  expect_false(dir.exists(fs::path(out, "qproj-graph_files")))

  step_nodes <- Filter(function(n) identical(n$type, "step"), g$nodes)
  expect_identical(length(step_nodes), 5L)
  expect_gt(length(g$edges), 0L)
  expect_identical(g$render_order[length(g$render_order)], "README")
})

test_that("proj_scan_graph() emits function and table nodes when scan = all", {
  skip_if_missing_suggests()
  out <- withr::local_tempdir()
  g <- proj_scan_graph(
    path = fixture_root, workflow = "analyses",
    output_dir = out, formats = "json", quiet = TRUE
  )
  fn_nodes  <- Filter(function(n) identical(n$type, "function"), g$nodes)
  tbl_nodes <- Filter(function(n) identical(n$type, "table"), g$nodes)
  expect_setequal(vapply(fn_nodes, function(n) n$name, character(1)),
                  c("qc_filter", "qc_norm", "qc_unused"))
  expect_setequal(vapply(tbl_nodes, function(n) n$name, character(1)),
                  c("raw_seqs", "ref_lookup", "audit_log"))
  unused <- Filter(function(n) isTRUE(n$unused), fn_nodes)
  expect_identical(vapply(unused, function(n) n$name, character(1)), "qc_unused")
})

test_that("proj_scan_graph(scan = 'step') reproduces v1 behavior", {
  skip_if_missing_suggests()
  out <- withr::local_tempdir()
  g <- proj_scan_graph(
    path = fixture_root, workflow = "analyses",
    output_dir = out, formats = "json", scan = "step", quiet = TRUE
  )
  expect_identical(g$metadata$total_functions, 0L)
  expect_identical(g$metadata$total_tables, 0L)
})

test_that("HTML nodes_df carries `group` for visGroups filtering", {
  skip_if_missing_suggests()
  skip_if_not_installed("visNetwork")
  skip_if_not_installed("htmlwidgets")
  out <- withr::local_tempdir()
  proj_scan_graph(
    path = fixture_root, workflow = "analyses",
    output_dir = out, quiet = TRUE
  )
  html <- paste(readLines(fs::path(out, "qproj-graph.html")), collapse = "\n")
  # htmlwidgets serializes data.frame columns array-style:
  # "group":["step","step",...,"function",...,"table",...]
  expect_match(html, '"group":\\[[^]]*"step"',     fixed = FALSE)
  expect_match(html, '"group":\\[[^]]*"function"', fixed = FALSE)
  expect_match(html, '"group":\\[[^]]*"table"',    fixed = FALSE)
})

# ---- v2 viewer features (stats bar, layout switcher, search, PNG, panel) ---

test_that("HTML viewer injects stats bar, toolbar, side panel and PNG export", {
  skip_if_missing_suggests()
  skip_if_not_installed("visNetwork")
  skip_if_not_installed("htmlwidgets")
  out <- withr::local_tempdir()
  proj_scan_graph(
    path = fixture_root, workflow = "analyses",
    output_dir = out, quiet = TRUE
  )
  html <- paste(readLines(fs::path(out, "qproj-graph.html")), collapse = "\n")
  # stats bar is plain HTML (real id="..."); the rest live in a JS string
  # injected by onRender, so the id attribute appears escaped as id=\"...\".
  expect_match(html, 'id="qproj-stats-bar"',  fixed = TRUE)
  expect_match(html, 'qproj-layout-sel',      fixed = TRUE)
  expect_match(html, 'qproj-search',          fixed = TRUE)
  expect_match(html, 'qproj-edge-label-toggle', fixed = TRUE)
  expect_match(html, 'qproj-png-export',      fixed = TRUE)
  expect_match(html, 'qproj-side-panel',      fixed = TRUE)
  expect_match(html, 'var QPROJ_GRAPH = ',    fixed = TRUE)
  # Edges carry per-edge labels (hidden via font.size = 0 by default)
  expect_match(html, '"label":\\[[^]]*"seqs.csv"',    fixed = FALSE)
  # 8-digit hex (#RRGGBBAA) -- INFERRED edges should appear with alpha != FF
  expect_match(html, '#26A69A8C', fixed = TRUE)  # reads_table INFERRED, teal 55%
  expect_match(html, '#1E88E5FF', fixed = TRUE)  # reads_from EXTRACTED, blue 100%
})

test_that("HTML viewer arranges steps on a trunk and fn/tbl on branches", {
  skip_if_missing_suggests()
  skip_if_not_installed("visNetwork")
  skip_if_not_installed("htmlwidgets")
  out <- withr::local_tempdir()
  g <- proj_scan_graph(
    path = fixture_root, workflow = "analyses",
    output_dir = out, quiet = TRUE
  )
  pos <- compute_branch_positions(g)
  ids <- vapply(g$nodes, `[[`, character(1), "id")
  expect_setequal(names(pos$x), ids)
  expect_setequal(names(pos$y), ids)
  # Steps live on the trunk (y == 0); functions above (y > 0); tables below.
  by_type <- split(g$nodes, vapply(g$nodes, `[[`, character(1), "type"))
  for (n in by_type$step)         expect_equal(pos$y[[n$id]], 0)
  for (n in by_type[["function"]]) expect_gt(pos$y[[n$id]], 0)
  for (n in by_type$table)        expect_lt(pos$y[[n$id]], 0)
  # Trunk is monotonic in render_order: lower order -> smaller x.
  step_ids  <- vapply(by_type$step, `[[`, character(1), "id")
  step_ord  <- vapply(by_type$step, function(n) as.integer(n$render_order), integer(1))
  expect_identical(order(pos$x[step_ids]), order(step_ord))

  # The HTML must ship the (x, y) on the nodes so vis.js honours them.
  html <- paste(readLines(fs::path(out, "qproj-graph.html")), collapse = "\n")
  expect_match(html, '"x":\\[', fixed = FALSE)
  expect_match(html, '"y":\\[', fixed = FALSE)
  # Layout switcher must capture baseXY and rotate it for UD/RL/DU,
  # not call hierarchical layout (which would put fn/tbl on the trunk).
  expect_match(html, "baseXY",                  fixed = TRUE)
  expect_match(html, "highlightEdgesFor",       fixed = TRUE)
  expect_match(html, "clearEdgeHighlight",      fixed = TRUE)
  expect_match(html, "DIM_EDGE_COLOR",          fixed = TRUE)
})

test_that("nodes carry fan_in / fan_out for size encoding", {
  skip_if_missing_suggests()
  out <- withr::local_tempdir()
  g <- proj_scan_graph(
    path = fixture_root, workflow = "analyses",
    output_dir = out, formats = "json", quiet = TRUE
  )
  by_id <- stats::setNames(g$nodes, vapply(g$nodes, function(n) n$id, character(1)))
  # 02-clean has at least 2 incoming (reads_from + bypass_access from 01-import)
  # and out >= 3 (reads_from to 03-analyze, uses_function qc_filter, writes_table raw_seqs).
  expect_gte(by_id[["02-clean"]]$fan_in,  2L)
  expect_gte(by_id[["02-clean"]]$fan_out, 3L)
  # Unused function should have zero callers (= zero in-degree).
  expect_identical(by_id[["fn:qc_unused"]]$fan_in, 0L)
  # README has nothing connecting to it.
  expect_identical(by_id[["README"]]$fan_in,  0L)
  expect_identical(by_id[["README"]]$fan_out, 0L)
})

test_that("fan_breakdown splits totals by edge role (data/code/table)", {
  skip_if_missing_suggests()
  out <- withr::local_tempdir()
  g <- proj_scan_graph(
    path = fixture_root, workflow = "analyses",
    output_dir = out, formats = "json", quiet = TRUE
  )
  by_id <- stats::setNames(g$nodes, vapply(g$nodes, function(n) n$id, character(1)))

  # 02-clean fan_out role breakdown:
  #  data  : reads_from -> 03-analyze     (1)
  #  code  : uses_function -> qc_filter   (1)
  #  table : writes_table -> raw_seqs     (1)
  bd2 <- by_id[["02-clean"]]$fan_breakdown
  expect_identical(bd2$out_code,  1L)
  expect_identical(bd2$out_table, 1L)
  expect_gte(bd2$out_data, 1L)

  # qc_filter is a code-side recipient only, so its in_data / in_table = 0.
  bdq <- by_id[["fn:qc_filter"]]$fan_breakdown
  expect_identical(bdq$in_data,  0L)
  expect_identical(bdq$in_code,  1L)
  expect_identical(bdq$in_table, 0L)

  # Sanity: aggregates equal sum of breakdown.
  for (n in g$nodes) {
    bd <- n$fan_breakdown
    expect_identical(n$fan_in,  bd$in_data  + bd$in_code  + bd$in_table)
    expect_identical(n$fan_out, bd$out_data + bd$out_code + bd$out_table)
  }
})

test_that("dbConnect path expressions do not double-count as workflow reads", {
  skip_if_missing_suggests()
  out <- withr::local_tempdir()
  g <- proj_scan_graph(
    path = fixture_root, workflow = "analyses",
    output_dir = out, formats = "json", quiet = TRUE
  )
  # Before the in_dbconnect fix, 03-analyze.qmd's
  #   con <- DBI::dbConnect(SQLite(), path_source("02-clean", "db.sqlite"))
  # would produce a spurious second 02-clean -> 03-analyze reads_from edge,
  # in addition to the legitimate path_source("02-clean", "clean.csv").
  reads_02_to_03 <- Filter(function(e) {
    e$type == "reads_from" && e$source == "02-clean" && e$target == "03-analyze" &&
      e$confidence == "EXTRACTED"
  }, g$edges)
  expect_length(reads_02_to_03, 1L)
})

test_that("nested `con <- dbConnect(...)` registers the connection", {
  # Regression for reviewer must-fix #2: register_connection must run inside
  # walk_expr, not just on top-level expressions, so a dbConnect nested in
  # an `if (cond) con <- ...` still records the db_file binding.
  skip_if_missing_suggests()
  qmd <- withr::local_tempfile(fileext = ".qmd")
  writeLines(c(
    "---", "title: t", "params:", "  name: t", "---",
    "```{r}",
    "use_db <- TRUE",
    'if (use_db) con <- DBI::dbConnect(RSQLite::SQLite(), "nested.sqlite")',
    'DBI::dbWriteTable(con, "x", data.frame(a = 1))',
    "```"
  ), qmd)
  ctx <- list(local_fns = character(0), pkg_name = NA_character_, scan_db = TRUE)
  res <- scan_qmd(qmd, ctx = ctx)
  expect_identical(unname(unlist(as.list(res$connections))), "nested.sqlite")
  writes <- Filter(function(d) d$kind == "write", res$dbi_calls)
  expect_length(writes, 1L)
  expect_identical(writes[[1L]]$db_file, "nested.sqlite")
})

test_that("proj_scan_graph() with formats = c('json', 'md') skips html", {
  skip_if_missing_suggests()

  out <- withr::local_tempdir()
  proj_scan_graph(
    path = fixture_root,
    workflow = "analyses",
    output_dir = out,
    formats = c("json", "md"),
    quiet = TRUE
  )
  expect_true(file.exists(fs::path(out, "qproj-graph.json")))
  expect_true(file.exists(fs::path(out, "QPROJ_GRAPH_REPORT.md")))
  expect_false(file.exists(fs::path(out, "qproj-graph.html")))
})

test_that("proj_scan_graph() honors _qproj.yml render.last", {
  skip_if_missing_suggests()

  out <- withr::local_tempdir()
  g <- proj_scan_graph(
    path = fixture_root,
    workflow = "analyses",
    output_dir = out,
    formats = "json",
    quiet = TRUE
  )
  # _qproj.yml puts 99-publish last among non-README files; README always last.
  ro <- g$render_order
  expect_identical(ro[length(ro)], "README")
  expect_identical(ro[length(ro) - 1L], "99-publish")
})

test_that("proj_scan_graph() builds a 02-clean -> 01-import bypass edge", {
  skip_if_missing_suggests()

  out <- withr::local_tempdir()
  g <- proj_scan_graph(
    path = fixture_root,
    workflow = "analyses",
    output_dir = out,
    formats = "json",
    quiet = TRUE
  )
  bypass_edges <- Filter(function(e) e$type == "bypass_access", g$edges)
  expect_length(bypass_edges, 1L)
  expect_identical(bypass_edges[[1L]]$source, "01-import")
  expect_identical(bypass_edges[[1L]]$target, "02-clean")
})

# ---- qg query CLI -----------------------------------------------------------

skip_if_missing_jq <- function() {
  if (Sys.which("jq") == "") skip("jq not on PATH")
}

run_qg <- function(out_dir, ...) {
  qg <- fs::path(out_dir, "qg")
  json <- fs::path(out_dir, "qproj-graph.json")
  withr::with_envvar(
    list(QPROJ_GRAPH_JSON = as.character(json)),
    system2("bash", c(as.character(qg), ...), stdout = TRUE, stderr = TRUE)
  )
}

test_that("proj_scan_graph() installs qg next to the graph, executable", {
  skip_if_missing_suggests()
  out <- withr::local_tempdir()
  proj_scan_graph(
    path = fixture_root, workflow = "analyses",
    output_dir = out, formats = c("json", "md"), quiet = TRUE
  )
  qg <- fs::path(out, "qg")
  expect_true(file.exists(qg))
  # Owner-executable bit must be set (mode is the octmode class).
  expect_match(as.character(file.info(qg)$mode), "7..", fixed = FALSE)
  # First line is the bash shebang so kernels can exec it directly.
  first_line <- readLines(qg, n = 1L)
  expect_match(first_line, "^#!/.*bash")
})

test_that("qg --help shows the manual", {
  skip_if_missing_suggests(); skip_if_missing_jq()
  out <- withr::local_tempdir()
  proj_scan_graph(path = fixture_root, output_dir = out,
                  formats = c("json", "md"), quiet = TRUE)
  txt <- run_qg(out, "--help")
  expect_true(any(grepl("qg --", txt)))
  expect_true(any(grepl("impact", txt)))
  expect_true(any(grepl("unused", txt)))
})

test_that("qg list step / list function / list table partition the nodes", {
  skip_if_missing_suggests(); skip_if_missing_jq()
  out <- withr::local_tempdir()
  proj_scan_graph(path = fixture_root, output_dir = out,
                  formats = c("json", "md"), quiet = TRUE)
  steps <- run_qg(out, "list", "step")
  fns   <- run_qg(out, "list", "function")
  tbls  <- run_qg(out, "list", "table")
  expect_true("02-clean" %in% steps)
  expect_true("fn:qc_filter" %in% fns)
  expect_true("tbl:raw_seqs" %in% tbls)
  # No overlap between kinds.
  expect_length(intersect(steps, fns), 0L)
  expect_length(intersect(steps, tbls), 0L)
})

test_that("qg impact 02-clean returns downstream tables and steps but not callees", {
  skip_if_missing_suggests(); skip_if_missing_jq()
  out <- withr::local_tempdir()
  proj_scan_graph(path = fixture_root, output_dir = out,
                  formats = c("json", "md"), quiet = TRUE)
  imp <- run_qg(out, "impact", "02-clean")
  ids <- sub("\t.*", "", imp)
  # Downstream step + tables 02-clean writes/reads:
  expect_true("03-analyze"   %in% ids)
  expect_true("tbl:raw_seqs" %in% ids)
  # qc_filter is a callee (uses_function from 02-clean -> fn); changing
  # 02-clean does NOT impact the function definition. Must NOT appear.
  expect_false("fn:qc_filter" %in% ids)
})

test_that("qg deps 03-analyze includes upstream step + the functions it uses", {
  skip_if_missing_suggests(); skip_if_missing_jq()
  out <- withr::local_tempdir()
  proj_scan_graph(path = fixture_root, output_dir = out,
                  formats = c("json", "md"), quiet = TRUE)
  deps <- run_qg(out, "deps", "03-analyze")
  ids <- sub("\t.*", "", deps)
  # 03-analyze reads_from 02-clean, uses fn:qc_norm, reads tables.
  expect_true("02-clean"   %in% ids)
  expect_true("fn:qc_norm" %in% ids)
})

test_that("qg unused finds dead functions and orphan tables", {
  skip_if_missing_suggests(); skip_if_missing_jq()
  out <- withr::local_tempdir()
  proj_scan_graph(path = fixture_root, output_dir = out,
                  formats = c("json", "md"), quiet = TRUE)
  un <- run_qg(out, "unused")
  expect_true(any(grepl("^function\tfn:qc_unused", un)))
  expect_true(any(grepl("^orphan_table\ttbl:audit_log", un)))
})

test_that("qg paths returns at least one path between connected steps", {
  skip_if_missing_suggests(); skip_if_missing_jq()
  out <- withr::local_tempdir()
  proj_scan_graph(path = fixture_root, output_dir = out,
                  formats = c("json", "md"), quiet = TRUE)
  paths <- run_qg(out, "paths", "01-import", "03-analyze")
  expect_gte(length(paths), 1L)
  # First and last node of each path must be the requested endpoints.
  for (p in paths) {
    parts <- strsplit(p, " ", fixed = TRUE)[[1L]]
    expect_identical(parts[[1L]],            "01-import")
    expect_identical(parts[[length(parts)]], "03-analyze")
  }
})

test_that("QPROJ_GRAPH_REPORT.md mentions qg in its AI handoff", {
  skip_if_missing_suggests()
  out <- withr::local_tempdir()
  proj_scan_graph(path = fixture_root, output_dir = out,
                  formats = c("json", "md"), quiet = TRUE)
  md <- paste(readLines(fs::path(out, "QPROJ_GRAPH_REPORT.md")), collapse = "\n")
  expect_match(md, "For AI assistants",       fixed = TRUE)
  expect_match(md, ".qproj/graph/qg --help",  fixed = TRUE)
  expect_match(md, "Do NOT read",             fixed = TRUE)
})

test_that("proj_scan_graph() aborts if workflow dir is missing", {
  skip_if_missing_suggests()
  out <- withr::local_tempdir()
  expect_error(
    proj_scan_graph(
      path = fixture_root,
      workflow = "does-not-exist",
      output_dir = out,
      quiet = TRUE
    ),
    "Workflow directory not found"
  )
})
