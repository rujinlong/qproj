#' Build the in-memory graph object from per-step scan results
#'
#' @param scan_results `list` of per-step results from `scan_qmd()`.
#' @param render_order `character` vector of step names in render order.
#' @param project_root `character` absolute path to project root.
#' @param workflow `character` name of the workflow subdirectory.
#' @param r_functions `list` of records from `scan_r_functions()`; pass
#'   an empty list to disable function nodes.
#'
#' @return `list` with elements `metadata`, `nodes`, `edges`, `warnings`,
#'   `render_order`.
#' @keywords internal
#' @noRd
build_graph <- function(scan_results, render_order, project_root, workflow,
                        r_functions = list()) {

  step_names <- vapply(scan_results, function(r) r$name, character(1))
  order_idx <- stats::setNames(seq_along(render_order), render_order)

  nodes <- lapply(scan_results, function(r) {
    list(
      id              = r$name,
      type            = "step",
      group           = "step",
      file            = file.path(workflow, basename(r$file)),
      render_order    = unname(order_idx[r$name]) %|na|% NA_integer_,
      uses_path_data     = isTRUE(r$uses_path_data),
      uses_path_resource = isTRUE(r$uses_path_resource),
      uses_path_raw      = isTRUE(r$uses_path_raw),
      outputs_detected = vapply(r$outputs, function(o) o$file, character(1)),
      r_packages      = sort(unique(r$r_packages)),
      n_reads_from    = length(r$reads_from),
      n_bypass_access = length(r$bypass_access),
      n_uses_function = length(r$uses_function),
      n_dbi_calls     = length(r$dbi_calls)
    )
  })

  edges <- list()

  # reads_from edges
  for (r in scan_results) {
    for (rf in r$reads_from) {
      edges <- c(edges, list(list(
        source     = rf$target,
        target     = r$name,
        type       = "reads_from",
        confidence = rf$confidence,
        files_referenced = if (is.na(rf$file_arg)) character(0) else rf$file_arg,
        evidence = list(
          file  = file.path(workflow, basename(r$file)),
          line  = rf$line,
          chunk = rf$chunk,
          text  = rf$text
        )
      )))
    }
    for (b in r$bypass_access) {
      edges <- c(edges, list(list(
        source     = b$target,
        target     = r$name,
        type       = "bypass_access",
        confidence = "EXTRACTED",
        files_referenced = character(0),
        evidence = list(
          file  = file.path(workflow, basename(r$file)),
          line  = b$line,
          chunk = b$chunk,
          text  = b$text
        )
      )))
    }
  }

  # render_order edges (sequential pairs)
  if (length(render_order) >= 2L) {
    for (i in seq_len(length(render_order) - 1L)) {
      edges <- c(edges, list(list(
        source     = render_order[i],
        target     = render_order[i + 1L],
        type       = "render_order",
        confidence = "EXTRACTED",
        files_referenced = character(0),
        evidence   = list(file = NA_character_, line = NA_integer_, chunk = NA_character_, text = NA_character_)
      )))
    }
  }

  # uses_function edges + function nodes
  fn_callers <- list()  # name -> character vector of caller step ids
  fn_call_records <- list()  # name -> list of (step, args, line, chunk, text)
  for (r in scan_results) {
    seen_in_step <- character(0)
    for (uf in r$uses_function) {
      fn <- uf$target
      if (!fn %in% seen_in_step) {
        fn_callers[[fn]] <- unique(c(fn_callers[[fn]], r$name))
        seen_in_step <- c(seen_in_step, fn)
      }
      fn_call_records[[fn]] <- c(
        fn_call_records[[fn]] %||% list(),
        list(list(step = r$name, line = uf$line, chunk = uf$chunk,
                  args_captured = uf$args_captured, text = uf$text))
      )
    }
  }

  function_nodes <- lapply(r_functions, function(fr) {
    callers <- fn_callers[[fr$name]] %||% character(0)
    list(
      id        = paste0("fn:", fr$name),
      type      = "function",
      group     = "function",
      name      = fr$name,
      file      = fr$file,
      line      = fr$line,
      n_args    = fr$n_args,
      arg_names = fr$arg_names,
      kind      = fr$kind %||% "function",
      callers   = callers,
      n_callers = length(callers),
      unused    = length(callers) == 0L
    )
  })

  for (fr in r_functions) {
    callers <- fn_callers[[fr$name]] %||% character(0)
    for (caller in callers) {
      ev <- fn_call_records[[fr$name]]
      ev_for_caller <- Filter(function(x) identical(x$step, caller), ev)
      ev_kept <- utils::head(ev_for_caller, 5L)
      args_capt <- lapply(ev_kept, `[[`, "args_captured")
      first <- ev_kept[[1L]]
      edges <- c(edges, list(list(
        source     = caller,
        target     = paste0("fn:", fr$name),
        type       = "uses_function",
        confidence = "EXTRACTED",
        n_calls    = length(ev_for_caller),
        args_captured = args_capt,
        evidence = list(
          file  = file.path(workflow, paste0(caller, ".qmd")),
          line  = first$line, chunk = first$chunk, text = first$text
        )
      )))
    }
  }

  # writes_table / reads_table edges + table nodes
  table_writers <- list(); table_readers <- list()
  table_db_files <- list(); table_evidence <- list()
  for (r in scan_results) {
    for (d in r$dbi_calls) {
      tbl <- d$table
      who <- if (d$kind == "write") "writers" else "readers"
      bucket <- if (d$kind == "write") table_writers else table_readers
      bucket[[tbl]] <- unique(c(bucket[[tbl]] %||% character(0), r$name))
      if (d$kind == "write") table_writers <- bucket else table_readers <- bucket
      if (!is.na(d$db_file)) {
        table_db_files[[tbl]] <- unique(c(table_db_files[[tbl]] %||% character(0), d$db_file))
      }
      key <- paste(r$name, tbl, d$kind, sep = "|")
      table_evidence[[key]] <- list(
        file  = file.path(workflow, basename(r$file)),
        line  = d$line, chunk = d$chunk, text = d$text,
        confidence = d$confidence
      )
      if (d$kind == "write") {
        edges <- c(edges, list(list(
          source = r$name, target = paste0("tbl:", tbl),
          type = "writes_table", confidence = d$confidence,
          fn = d$fn, db_file = d$db_file,
          evidence = list(file = file.path(workflow, basename(r$file)),
                          line = d$line, chunk = d$chunk, text = d$text)
        )))
      } else {
        edges <- c(edges, list(list(
          source = paste0("tbl:", tbl), target = r$name,
          type = "reads_table", confidence = d$confidence,
          fn = d$fn, db_file = d$db_file,
          evidence = list(file = file.path(workflow, basename(r$file)),
                          line = d$line, chunk = d$chunk, text = d$text)
        )))
      }
    }
  }

  table_names <- unique(c(names(table_writers), names(table_readers)))
  table_nodes <- lapply(table_names, function(tbl) {
    writers <- table_writers[[tbl]] %||% character(0)
    readers <- table_readers[[tbl]] %||% character(0)
    db_files <- table_db_files[[tbl]] %||% character(0)
    list(
      id           = paste0("tbl:", tbl),
      type         = "table",
      group        = "table",
      name         = tbl,
      writers      = writers,
      readers      = readers,
      n_writers    = length(writers),
      n_readers    = length(readers),
      db_files     = db_files,
      first_writer = if (length(writers)) writers[[1L]] else NA_character_
    )
  })

  nodes <- c(nodes, function_nodes, table_nodes)

  # Aggregate warnings (per-step + cross-step forward-read check)
  warnings <- list()
  for (r in scan_results) {
    for (w in r$warnings) {
      warnings <- c(warnings, list(c(list(step = r$name, file = file.path(workflow, basename(r$file))), w)))
    }
  }
  for (e in edges) {
    if (e$type == "reads_from" && e$confidence == "EXTRACTED") {
      src_idx <- order_idx[e$source]
      tgt_idx <- order_idx[e$target]
      if (!is.na(src_idx) && !is.na(tgt_idx) && src_idx >= tgt_idx) {
        warnings <- c(warnings, list(list(
          type    = "FORWARD_READ",
          step    = e$target,
          file    = e$evidence$file,
          line    = e$evidence$line,
          chunk   = e$evidence$chunk,
          message = sprintf(
            "%s reads from %s, which is not earlier in the render order.",
            e$target, e$source
          ),
          text    = e$evidence$text
        )))
      }
      if (is.na(src_idx)) {
        warnings <- c(warnings, list(list(
          type    = "UNKNOWN_UPSTREAM",
          step    = e$target,
          file    = e$evidence$file,
          line    = e$evidence$line,
          chunk   = e$evidence$chunk,
          message = sprintf(
            "%s reads from %s, which is not a step in this workflow.",
            e$target, e$source
          ),
          text    = e$evidence$text
        )))
      }
    }
  }

  # Compute fan-in / fan-out per node, broken down by edge role:
  #   data  = reads_from + bypass_access  (file-system / sandbox flow)
  #   code  = uses_function               (R/*.R function calls)
  #   table = reads_table + writes_table  (DBI table dependencies)
  # render_order is excluded -- it would inflate every step uniformly.
  # The aggregate fan_in / fan_out sums all three roles and is what the
  # HTML viewer's node-size formula (18 + 4 * (fan_in + fan_out)) consumes;
  # the per-role breakdown lives under `fan_breakdown` for downstream
  # tooling that wants e.g. "data hub" vs "utility-using" classification.
  edge_role <- function(type) {
    if (type %in% c("reads_from", "bypass_access")) return("data")
    if (identical(type, "uses_function"))           return("code")
    if (type %in% c("reads_table", "writes_table")) return("table")
    NA_character_
  }
  empty_breakdown <- list(in_data = 0L, in_code = 0L, in_table = 0L,
                          out_data = 0L, out_code = 0L, out_table = 0L)
  fan_by_role <- list()
  for (e in edges) {
    role <- edge_role(e$type)
    if (is.na(role)) next
    src <- fan_by_role[[e$source]] %||% empty_breakdown
    tgt <- fan_by_role[[e$target]] %||% empty_breakdown
    src_key <- paste0("out_", role); tgt_key <- paste0("in_", role)
    src[[src_key]] <- src[[src_key]] + 1L
    tgt[[tgt_key]] <- tgt[[tgt_key]] + 1L
    fan_by_role[[e$source]] <- src
    fan_by_role[[e$target]] <- tgt
  }
  nodes <- lapply(nodes, function(n) {
    br <- fan_by_role[[n$id]] %||% empty_breakdown
    n$fan_breakdown <- br
    n$fan_in  <- br$in_data  + br$in_code  + br$in_table
    n$fan_out <- br$out_data + br$out_code + br$out_table
    n
  })

  n_by_type <- function(type) {
    sum(vapply(nodes, function(n) identical(n$type, type), logical(1)))
  }

  list(
    metadata = list(
      version          = "2.0",
      generated_at     = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
      project_root     = project_root,
      workflow_dir     = workflow,
      total_steps      = n_by_type("step"),
      total_functions  = n_by_type("function"),
      total_tables     = n_by_type("table"),
      total_edges      = length(edges),
      scanner_version  = as.character(utils::packageVersion("qproj"))
    ),
    nodes        = nodes,
    edges        = edges,
    warnings     = warnings,
    render_order = render_order
  )
}

`%|na|%` <- function(a, b) if (length(a) == 0L || is.na(a)) b else a

# ---------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------

#' @keywords internal
#' @noRd
render_json <- function(graph, output_path) {
  json <- jsonlite::toJSON(
    graph,
    pretty     = TRUE,
    auto_unbox = TRUE,
    null       = "null",
    na         = "null"
  )
  writeLines(json, output_path, useBytes = TRUE)
  invisible(output_path)
}

# ---------------------------------------------------------------------------
# Markdown
# ---------------------------------------------------------------------------

#' @keywords internal
#' @noRd
render_md <- function(graph, output_path) {

  meta <- graph$metadata
  generated <- substr(meta$generated_at, 1L, 10L)
  proj <- basename(meta$project_root)

  step_nodes <- Filter(function(n) identical(n$type, "step"), graph$nodes)
  fn_nodes   <- Filter(function(n) identical(n$type, "function"), graph$nodes)
  tbl_nodes  <- Filter(function(n) identical(n$type, "table"), graph$nodes)

  lines <- c()
  lines <- c(lines, "# QPROJ Workflow Graph Report")
  lines <- c(lines, "")
  lines <- c(lines, sprintf(
    "Generated: %s | Project: %s | Workflow: %s | Steps: %d | Functions: %d | Tables: %d | Edges: %d",
    generated, proj, meta$workflow_dir,
    meta$total_steps %||% 0L, meta$total_functions %||% 0L,
    meta$total_tables %||% 0L, meta$total_edges
  ))
  lines <- c(lines, "")
  # Visible AI handoff: any agent that opens this file should immediately
  # know that (1) the full graph JSON is large and should not be read
  # directly, (2) qg is the supported query CLI, (3) --help is one call away.
  lines <- c(lines,
    "## For AI assistants -- read this first",
    "",
    "This report is the AI navigation entry for the qproj dependency graph.",
    "**Do NOT read `qproj-graph.json` directly** -- it can be 100KB+ on real",
    "projects. Instead, query the graph with the bundled `qg` CLI:",
    "",
    "```bash",
    "bash .qproj/graph/qg --help              # full subcommand manual",
    "bash .qproj/graph/qg node <id>           # node metadata + neighbours",
    "bash .qproj/graph/qg impact <id>         # blast radius if you change <id>",
    "bash .qproj/graph/qg deps <id>           # what <id> depends on",
    "bash .qproj/graph/qg unused              # dead code candidates",
    "bash .qproj/graph/qg stale --days 90     # archive candidates",
    "bash .qproj/graph/qg paths <a> <b>       # all dep paths from a to b",
    "```",
    "",
    "`qg` only needs `jq` (`brew install jq` / `apt install jq`).",
    "Read `qproj-graph.json` only if `qg` does not surface the field you need.",
    "")

  # Pipeline overview
  lines <- c(lines, "## Workflow Overview")
  lines <- c(lines, "")
  lines <- c(lines, sprintf("Pipeline: %s", paste(graph$render_order, collapse = " -> ")))
  lines <- c(lines, "")

  # Step summary table
  lines <- c(lines, "## Step Summary")
  lines <- c(lines, "")
  lines <- c(lines, "| Step | Inputs | Upstream Deps | Key Outputs | Notes |")
  lines <- c(lines, "|------|--------|---------------|-------------|-------|")

  for (node in step_nodes) {
    inputs <- character(0)
    if (node$uses_path_data)     inputs <- c(inputs, "raw")
    if (node$uses_path_resource) inputs <- c(inputs, "resource")
    inputs_txt <- if (length(inputs)) paste(inputs, collapse = ", ") else "-"

    upstream <- unique(unlist(lapply(graph$edges, function(e) {
      if (e$type == "reads_from" && e$target == node$id && e$confidence == "EXTRACTED") {
        e$source
      }
    })))
    upstream_txt <- if (length(upstream)) paste(upstream, collapse = ", ") else "none"

    out_txt <- if (length(node$outputs_detected)) {
      head_n <- utils::head(node$outputs_detected, 3L)
      extra <- length(node$outputs_detected) - length(head_n)
      paste0(paste(head_n, collapse = ", "),
             if (extra > 0L) sprintf(" (+%d)", extra) else "")
    } else "-"

    notes <- character(0)
    if (length(upstream) == 0L && node$uses_path_data) notes <- c(notes, "entry")
    if (node$id == utils::tail(graph$render_order, 1L)) notes <- c(notes, "terminal")
    if (node$n_bypass_access > 0L) notes <- c(notes, sprintf("BYPASS x%d", node$n_bypass_access))
    notes_txt <- if (length(notes)) paste(notes, collapse = "; ") else "-"

    lines <- c(lines, sprintf("| %s | %s | %s | %s | %s |",
                              node$id, inputs_txt, upstream_txt, out_txt, notes_txt))
  }
  lines <- c(lines, "")

  # God nodes (high fan-out)
  fan_out <- table(vapply(graph$edges, function(e) {
    if (e$type == "reads_from" && e$confidence == "EXTRACTED") e$source else NA_character_
  }, character(1)))
  fan_out <- fan_out[!is.na(names(fan_out)) & fan_out >= 2L]
  if (length(fan_out) > 0L) {
    lines <- c(lines, "## God Nodes (high fan-out)")
    lines <- c(lines, "")
    for (nm in names(sort(fan_out, decreasing = TRUE))) {
      lines <- c(lines, sprintf("- **%s**: depended on by %d downstream steps", nm, as.integer(fan_out[nm])))
    }
    lines <- c(lines, "")
  }

  # R/ Functions Used
  used_fn_nodes <- Filter(function(n) !n$unused, fn_nodes)
  if (length(used_fn_nodes) > 0L) {
    lines <- c(lines, "## R/ Functions Used")
    lines <- c(lines, "")
    lines <- c(lines, "| Function | Defined | Used by | Args (literals) |")
    lines <- c(lines, "|---|---|---|---|")
    for (fn in used_fn_nodes) {
      callers <- unique(unlist(lapply(graph$edges, function(e) {
        if (identical(e$type, "uses_function") && identical(e$target, fn$id)) e$source
      })))
      args_summary <- character(0)
      for (e in graph$edges) {
        if (identical(e$type, "uses_function") && identical(e$target, fn$id)) {
          for (a in e$args_captured) {
            for (k in names(a)) args_summary <- c(args_summary, sprintf("%s=%s", k, format(a[[k]])))
          }
        }
      }
      args_txt <- if (length(args_summary)) paste(unique(args_summary), collapse = "; ") else "-"
      lines <- c(lines, sprintf("| `%s()` | %s:%d | %s | %s |",
                                fn$name, fn$file, fn$line %||% 0L,
                                paste(callers, collapse = ", "), args_txt))
    }
    lines <- c(lines, "")
  }

  # DBI Tables
  if (length(tbl_nodes) > 0L) {
    lines <- c(lines, "## DBI Tables")
    lines <- c(lines, "")
    lines <- c(lines, "| Table | DB file | Writers | Readers |")
    lines <- c(lines, "|---|---|---|---|")
    for (t in tbl_nodes) {
      db_txt <- if (length(t$db_files)) paste(t$db_files, collapse = ", ") else "?"
      w_txt  <- if (length(t$writers)) paste(t$writers, collapse = ", ") else "-"
      r_txt  <- if (length(t$readers)) paste(t$readers, collapse = ", ") else "-"
      lines <- c(lines, sprintf("| `%s` | %s | %s | %s |", t$name, db_txt, w_txt, r_txt))
    }
    lines <- c(lines, "")
  }

  # Unused R/ Functions
  unused_fn_nodes <- Filter(function(n) isTRUE(n$unused), fn_nodes)
  if (length(unused_fn_nodes) > 0L) {
    lines <- c(lines, "## Unused R/ Functions")
    lines <- c(lines, "")
    lines <- c(lines, "| Function | Defined |")
    lines <- c(lines, "|---|---|")
    for (fn in unused_fn_nodes) {
      lines <- c(lines, sprintf("| `%s()` | %s:%d |", fn$name, fn$file, fn$line %||% 0L))
    }
    lines <- c(lines, "")
  }

  # Warnings
  if (length(graph$warnings) > 0L) {
    lines <- c(lines, "## Warnings")
    lines <- c(lines, "")
    for (w in graph$warnings) {
      loc <- if (!is.null(w$file) && !is.na(w$file)) {
        sprintf("%s:%s", w$file, format_line_chunk(w$line, w$chunk))
      } else w$step
      lines <- c(lines, sprintf("- [%s] %s -- %s", w$type, loc, w$message))
    }
    lines <- c(lines, "")
  }

  # AI Tips
  lines <- c(lines, "## How to Use This Graph")
  lines <- c(lines, "")
  lines <- c(lines, "- For full dependency details: read `qproj-graph.json`")
  lines <- c(lines, "- For visual exploration: open `qproj-graph.html` in a browser")
  lines <- c(lines, "")
  lines <- c(lines, "## AI Navigation Tip")
  lines <- c(lines, "")
  lines <- c(lines, "When asked about data flow, check `reads_from` edges in `qproj-graph.json`.")
  lines <- c(lines, "When asked about inputs, check `uses_path_data` / `uses_path_resource` node attributes.")
  lines <- c(lines, "When asked about outputs, check `outputs_detected` node attributes.")
  lines <- c(lines, "")

  writeLines(lines, output_path, useBytes = TRUE)
  invisible(output_path)
}

format_line_chunk <- function(line, chunk) {
  if (!is.null(chunk) && !is.na(chunk)) {
    if (!is.null(line) && !is.na(line)) sprintf("%s@L%d", chunk, line) else chunk
  } else if (!is.null(line) && !is.na(line)) {
    sprintf("L%d", line)
  } else {
    "?"
  }
}

# ---------------------------------------------------------------------------
# HTML (visNetwork)
# ---------------------------------------------------------------------------

#' @keywords internal
#' @noRd
# Position nodes for the default LR "trunk + branches" layout.
#   step  -> horizontal trunk at y = 0, x = render_order rank * 4 * unit
#   func  -> upward branch (y > 0), x = mean(callers' x)
#   table -> downward branch (y < 0), x = mean((writers + readers)' x)
# Within each band, x-buckets get a ceil(sqrt(n)) column grid so a step
# with many fn/tbl spreads sideways instead of stretching into a single
# 1000+ pixel column. Returns named vectors aligned to graph$nodes:
#   list(x = c(id1 = ..., ...), y = c(id1 = ..., ...))
compute_branch_positions <- function(graph, unit = 70) {
  step_x_gap   <- 4 * unit
  band_offset  <- 2 * unit
  bucket_width <- step_x_gap / 2

  node_ids <- vapply(graph$nodes, `[[`, character(1), "id")
  if (length(node_ids) == 0L) return(list(x = numeric(0), y = numeric(0)))

  steps <- Filter(function(n) identical(n$type, "step"), graph$nodes)
  if (length(steps) == 0L) {
    z <- stats::setNames(rep(0, length(node_ids)), node_ids)
    return(list(x = z, y = z))
  }
  step_ids    <- vapply(steps, `[[`, character(1), "id")
  step_orders <- vapply(steps, function(n) as.integer(n$render_order %||% 0L), integer(1))
  ranks       <- integer(length(steps))
  ranks[order(step_orders, step_ids)] <- seq_along(steps)
  step_x      <- stats::setNames((ranks - 1L) * step_x_gap, step_ids)

  fallback_x <- mean(step_x)
  centre_x <- function(assoc) {
    xs <- step_x[unique(assoc)]
    xs <- xs[!is.na(xs)]
    if (length(xs)) mean(xs) else fallback_x
  }

  # Place each non-step node on its band; fn/tbl already carry the
  # caller / writer / reader vectors thanks to build_graph(), so we just
  # read them off the node -- no edge scan needed.
  placed <- lapply(graph$nodes, function(n) {
    if (identical(n$type, "step"))     return(c(x = unname(step_x[[n$id]]),  y = 0,           band = 0))
    if (identical(n$type, "function")) return(c(x = centre_x(n$callers),     y = +band_offset, band = +1))
    if (identical(n$type, "table"))    return(c(x = centre_x(c(n$writers, n$readers)), y = -band_offset, band = -1))
    c(x = fallback_x, y = 0, band = 0)
  })
  xs   <- vapply(placed, `[[`, numeric(1), "x")
  ys   <- vapply(placed, `[[`, numeric(1), "y")
  band <- vapply(placed, `[[`, numeric(1), "band")
  names(xs) <- names(ys) <- node_ids

  # Per-band grid pack within each x-bucket.
  for (b in c(+1, -1)) {
    in_band <- which(band == b)
    if (!length(in_band)) next
    buckets <- split(in_band, floor(xs[in_band] / bucket_width))
    for (idx in buckets) {
      idx  <- idx[order(node_ids[idx])]
      n    <- length(idx)
      cols <- max(1L, as.integer(ceiling(sqrt(n))))
      step <- step_x_gap / max(cols, 2L)
      cx   <- mean(xs[idx])
      col  <- ((seq_len(n) - 1L) %% cols)
      row  <- ((seq_len(n) - 1L) %/% cols)
      xs[idx] <- cx + (col - (cols - 1L) / 2) * step
      ys[idx] <- b * (band_offset + row * unit)
    }
  }
  list(x = xs, y = ys)
}

render_html <- function(graph, output_path) {

  node_label <- function(n) {
    if (identical(n$type, "function")) sprintf("%s()", n$name)
    else if (identical(n$type, "table")) sprintf("[%s]", n$name)
    else n$id
  }

  step_tooltip <- function(n) {
    ups <- unique(unlist(lapply(graph$edges, function(e) {
      if (identical(e$type, "reads_from") && identical(e$target, n$id) &&
          identical(e$confidence, "EXTRACTED")) e$source
    })))
    sprintf(
      "<b>%s</b><br>file: %s<br>order: %s<br>upstream: %s<br>outputs: %s<br>packages: %s",
      n$id, n$file, as.character(n$render_order),
      if (length(ups)) paste(ups, collapse = ", ") else "(none)",
      if (length(n$outputs_detected)) paste(utils::head(n$outputs_detected, 5L), collapse = ", ") else "(none)",
      if (length(n$r_packages)) paste(utils::head(n$r_packages, 5L), collapse = ", ") else "(none)"
    )
  }
  fn_tooltip <- function(n) {
    sprintf(
      "<b>%s()</b><br>file: %s:%s<br>callers: %d<br>args: %s%s",
      n$name, n$file, as.character(n$line %||% "?"),
      n$n_callers,
      if (length(n$arg_names)) paste(n$arg_names, collapse = ", ") else "(none)",
      if (isTRUE(n$unused)) "<br><i>unused</i>" else ""
    )
  }
  tbl_tooltip <- function(n) {
    sprintf(
      "<b>[%s]</b><br>db: %s<br>writers: %s<br>readers: %s",
      n$name,
      if (length(n$db_files)) paste(n$db_files, collapse = ", ") else "?",
      if (length(n$writers)) paste(n$writers, collapse = ", ") else "(none)",
      if (length(n$readers)) paste(n$readers, collapse = ", ") else "(none)"
    )
  }

  nodes_df <- data.frame(
    id    = vapply(graph$nodes, `[[`, character(1), "id"),
    label = vapply(graph$nodes, node_label, character(1)),
    group = vapply(graph$nodes, `[[`, character(1), "group"),
    title = vapply(graph$nodes, function(n) {
      switch(n$type,
        step     = step_tooltip(n),
        "function" = fn_tooltip(n),
        table    = tbl_tooltip(n),
        n$id
      )
    }, character(1)),
    color = vapply(graph$nodes, function(n) {
      if (identical(n$type, "function")) {
        if (isTRUE(n$unused)) "#BDBDBD" else "#9C27B0"
      } else if (identical(n$type, "table")) "#26A69A"
      else if (isTRUE(n$n_bypass_access > 0L)) "#FFB74D"
      else if (isTRUE(n$n_reads_from == 0L && n$uses_path_data)) "#81C784"
      else "#64B5F6"
    }, character(1)),
    shape = vapply(graph$nodes, function(n) {
      switch(n$type, step = "box", "function" = "ellipse", table = "diamond", "box")
    }, character(1)),
    # Size encodes connectivity: hub nodes draw the eye to refactor risk.
    # Floor 18 (readable label) + 4 per incident edge, capped at 50.
    size = vapply(graph$nodes, function(n) {
      total <- (n$fan_in %||% 0L) + (n$fan_out %||% 0L)
      max(18L, min(50L, 18L + 4L * total))
    }, integer(1)),
    stringsAsFactors = FALSE
  )

  # Trunk-and-branch layout: step nodes sit on a horizontal trunk; fn/tbl
  # hang above/below their associated steps. The JS layout switcher rotates
  # these (x, y) for UD/RL/DU and falls back to physics only for "force".
  branch_pos <- compute_branch_positions(graph)
  nodes_df$x <- unname(branch_pos$x[nodes_df$id])
  nodes_df$y <- unname(branch_pos$y[nodes_df$id])

  visible_types <- c("reads_from", "bypass_access",
                     "uses_function", "writes_table", "reads_table")
  keep <- vapply(graph$edges, function(e) {
    e$type %in% visible_types && !is.na(e$source) && !is.na(e$target) &&
      e$source %in% nodes_df$id && e$target %in% nodes_df$id
  }, logical(1))
  edges_kept <- graph$edges[keep]

  edge_color <- function(e) {
    switch(e$type,
      reads_from    = "#1E88E5",
      bypass_access = "#E53935",
      uses_function = "#9C27B0",
      writes_table  = "#E53935",
      reads_table   = "#26A69A",
      "#888888"
    )
  }

  # confidence -> visual: EXTRACTED full opacity, INFERRED 55%, AMBIGUOUS 35%
  # Combine into 8-digit hex (#RRGGBBAA) for vis.js direct support.
  conf_alpha <- function(conf) {
    switch(conf %||% "EXTRACTED",
           EXTRACTED = "FF",
           INFERRED  = "8C",   # ~55%
           AMBIGUOUS = "59",   # ~35%
           "FF")
  }

  # Compact label per edge type (toggleable in the viewer).
  # reads_from   -> file argument (e.g. "seqs.csv")
  # uses_function-> first literal arg (e.g. "threshold=0.05")
  # reads_table  -> SQL fn name (dbReadTable / tbl / dbGetQuery)
  # writes_table -> SQL fn name (dbWriteTable / dbExecute)
  edge_label <- function(e) {
    if (identical(e$type, "reads_from")) {
      f <- if (is.null(e$files_referenced) || length(e$files_referenced) == 0L) ""
           else e$files_referenced[[1L]]
      return(f %||% "")
    }
    if (identical(e$type, "uses_function")) {
      ac <- e$args_captured %||% list()
      if (length(ac) == 0L || length(ac[[1L]]) == 0L) return("")
      first_call <- ac[[1L]]
      first_arg_name  <- names(first_call)[[1L]]
      first_arg_value <- first_call[[1L]]
      return(sprintf("%s=%s", first_arg_name, format(first_arg_value)))
    }
    if (identical(e$type, "reads_table") || identical(e$type, "writes_table")) {
      return(e$fn %||% "")
    }
    ""
  }

  if (length(edges_kept) == 0L) {
    edges_df <- data.frame(from = character(0), to = character(0),
                           color = character(0), dashes = logical(0),
                           title = character(0), arrows = character(0),
                           label = character(0), stringsAsFactors = FALSE)
  } else {
    edges_df <- data.frame(
      from   = vapply(edges_kept, `[[`, character(1), "source"),
      to     = vapply(edges_kept, `[[`, character(1), "target"),
      color  = vapply(edges_kept, function(e) {
        paste0(edge_color(e), conf_alpha(e$confidence))
      }, character(1)),
      # Only bypass_access uses dashed lines (anti-pattern, attention-grabbing).
      # AMBIGUOUS edges are already visually demoted via 35% alpha alone,
      # so no dashes -- avoids confusion with bypass.
      dashes = vapply(edges_kept, function(e) {
        identical(e$type, "bypass_access")
      }, logical(1)),
      title  = vapply(edges_kept, function(e) {
        sprintf("%s (%s)", e$type, e$confidence)
      }, character(1)),
      arrows = "to",
      # Pre-compute the label text but render hidden by default; the in-page
      # toggle button in layout_switcher_js() makes it visible on demand.
      label  = vapply(edges_kept, edge_label, character(1)),
      stringsAsFactors = FALSE
    )
  }

  legend_nodes <- data.frame(
    label = c("step", "function", "table"),
    shape = c("box", "ellipse", "diamond"),
    color = c("#64B5F6", "#9C27B0", "#26A69A"),
    stringsAsFactors = FALSE
  )

  vn <- visNetwork::visNetwork(nodes_df, edges_df,
                               main = NULL,
                               width = "100%", height = "100vh")
  vn <- visNetwork::visGroups(vn, groupname = "step",
                              shape = "box", color = "#64B5F6")
  vn <- visNetwork::visGroups(vn, groupname = "function",
                              shape = "ellipse", color = "#9C27B0")
  vn <- visNetwork::visGroups(vn, groupname = "table",
                              shape = "diamond", color = "#26A69A")
  # Default view is hierarchical LR with curved edges (matches the dropdown's
  # initial selection). Switching to force-directed via the dropdown rewrites
  # these to straight + physics-enabled.
  vn <- visNetwork::visEdges(vn, arrows = "to",
                             smooth = list(enabled = TRUE, type = "cubicBezier"),
                             width = 1,
                             # Edge labels exist on every edge but are hidden
                             # at size 0 by default; the in-page toggle button
                             # in layout_switcher_js() raises this to 11.
                             # NOTE: do NOT set `multi = "html"` here -- our
                             # label content (file_arg, captured args, fn name)
                             # is not HTML-escaped for vis.js rendering.
                             font = list(size = 0, color = "#37474F",
                                         strokeWidth = 3, strokeColor = "#FFFFFF"))
  # Default layout: trunk-and-branch via predefined (x, y) on the nodes.
  # We disable hierarchical and physics so vis.js honours the coordinates
  # we computed in R. Layout-switcher rotates these for UD/RL/DU; only
  # "Force-directed" overwrites them with random seeds.
  vn <- visNetwork::visPhysics(vn, enabled = FALSE)
  # Disable visNetwork's built-in highlightNearest -- it only thickens
  # selected edges, never dims the rest, which is exactly the bug we fix in
  # the custom selectNode handler in layout_switcher_js().
  vn <- visNetwork::visOptions(vn,
    selectedBy        = list(variable = "group", multiple = TRUE),
    highlightNearest  = FALSE,
    nodesIdSelection  = TRUE
  )
  vn <- visNetwork::visLegend(vn, addNodes = legend_nodes,
                              useGroups = FALSE, position = "right",
                              main = "Node types")
  vn <- visNetwork::visInteraction(vn, hover = TRUE, dragNodes = TRUE)

  # Layout switcher: dropdown that toggles between hierarchical (LR/UD/RL/DU,
  # curved edges, physics off) and force-directed (straight edges, physics on
  # then frozen after stabilization).
  vn <- htmlwidgets::onRender(vn, layout_switcher_js())

  htmlwidgets::saveWidget(vn, file = normalizePath(output_path, mustWork = FALSE),
                          selfcontained = TRUE)
  # Inject CSS so the network truly fills the browser viewport with no margin.
  patch_html_fullscreen(output_path)
  # Inject a fixed top stats bar (Steps | Functions (n unused) | Tables | Warnings).
  patch_html_stats_bar(output_path, graph)
  # Inject the full graph as `QPROJ_GRAPH` global so the side detail panel
  # can show metadata richer than the visNetwork node tooltip.
  patch_html_inject_graph(output_path, graph)
  # htmlwidgets sometimes leaves a `<basename>_files/` sidecar even when
  # selfcontained = TRUE. The HTML is already standalone, so prune it.
  sidecar <- sub("\\.html$", "_files", output_path)
  if (dir.exists(sidecar)) unlink(sidecar, recursive = TRUE, force = TRUE)
  invisible(output_path)
}

# Returns the JS callback (string) used by htmlwidgets::onRender() to
# inject a layout-mode dropdown into the rendered visNetwork widget. The
# callback receives `el` (widget container) and `x` (widget data); `this`
# is the visNetwork htmlwidget instance, whose `network` field holds the
# vis.js Network object we control.
layout_switcher_js <- function() {
  '
function(el, x) {
  var widget = this;
  // visNetwork stores the vis-network instance on the DOM element as
  // `el.chart` (its own JS code references it that way throughout). We
  // try every known location to be resilient across visNetwork builds.
  var network = el.chart || widget.network || (this && this.network);
  if (!network && window.HTMLWidgets && HTMLWidgets.getInstance) {
    var iv = HTMLWidgets.getInstance(el);
    if (iv) network = iv.chart || iv.network;
  }
  if (!network) { console.warn("qproj: visNetwork instance not found"); return; }

  // Build the toolbar (layout dropdown + node search + edge-label toggle).
  var ctrl = document.createElement("div");
  ctrl.id = "qproj-toolbar";
  ctrl.style.cssText =
    "position:fixed; top:5px; right:14px; z-index:10001; " +
    "background:#37474F; color:#ECEFF1; padding:5px 10px; border-radius:4px; " +
    "font:12px/1.3 -apple-system, system-ui, sans-serif; " +
    "box-shadow:0 1px 4px rgba(0,0,0,0.25); display:flex; gap:14px; align-items:center;";
  ctrl.innerHTML =
    "<label style=\\"display:flex; gap:6px; align-items:center;\\">" +
      "<span style=\\"color:#B0BEC5; text-transform:uppercase; letter-spacing:0.05em; font-size:11px;\\">Layout</span>" +
      "<select id=\\"qproj-layout-sel\\" style=\\"font-size:12px; padding:2px 4px;\\">" +
        "<option value=\\"LR\\" selected>LR (hierarchical)</option>" +
        "<option value=\\"UD\\">UD (hierarchical)</option>" +
        "<option value=\\"RL\\">RL (hierarchical)</option>" +
        "<option value=\\"DU\\">DU (hierarchical)</option>" +
        "<option value=\\"force\\">Force-directed</option>" +
      "</select>" +
    "</label>" +
    "<label style=\\"display:flex; gap:6px; align-items:center;\\">" +
      "<span style=\\"color:#B0BEC5; text-transform:uppercase; letter-spacing:0.05em; font-size:11px;\\">Search</span>" +
      "<input id=\\"qproj-search\\" type=\\"text\\" placeholder=\\"node name...\\" " +
             "style=\\"font-size:12px; padding:2px 6px; width:140px;\\">" +
    "</label>" +
    "<button id=\\"qproj-edge-label-toggle\\" type=\\"button\\" " +
            "style=\\"font-size:12px; padding:2px 8px; cursor:pointer;\\">Show edge labels</button>" +
    "<button id=\\"qproj-png-export\\" type=\\"button\\" " +
            "style=\\"font-size:12px; padding:2px 8px; cursor:pointer;\\">PNG</button>";
  document.body.appendChild(ctrl);

  // Detail side-panel for node click. Hidden off-screen by default.
  var panel = document.createElement("div");
  panel.id = "qproj-side-panel";
  panel.style.cssText =
    "position:fixed; top:38px; right:-380px; width:360px; height:calc(100vh - 38px); " +
    "z-index:10000; background:#FAFAFA; color:#263238; " +
    "border-left:1px solid #B0BEC5; box-shadow:-2px 0 8px rgba(0,0,0,0.08); " +
    "transition:right 0.2s ease-out; " +
    "font:13px/1.5 -apple-system, system-ui, sans-serif; " +
    "overflow-y:auto; box-sizing:border-box;";
  panel.innerHTML =
    "<div style=\\"padding:10px 16px; border-bottom:1px solid #ECEFF1; " +
    "display:flex; justify-content:space-between; align-items:center; background:#ECEFF1;\\">" +
      "<div style=\\"font-weight:600; font-size:14px;\\" id=\\"qproj-panel-title\\">Node detail</div>" +
      "<button id=\\"qproj-panel-close\\" type=\\"button\\" " +
              "style=\\"font-size:18px; line-height:1; padding:0 6px; cursor:pointer; background:none; border:none; color:#546E7A;\\">&times;</button>" +
    "</div>" +
    "<div id=\\"qproj-panel-body\\" style=\\"padding:14px 16px;\\"></div>";
  document.body.appendChild(panel);

  // Pull the DataSet handles up here so every helper below uses the same
  // names; the force branch in applyLayout would otherwise rely on `var`
  // hoisting from the search section, which works only by accident.
  var nodes = network.body.data.nodes;
  var edges = network.body.data.edges;

  // ---------- Trunk-and-branch base coordinates ----------
  // Snapshot the (x, y) we predefined in R. UD/RL/DU rotate these instead
  // of letting vis-network re-layout from scratch, so the trunk stays a
  // trunk no matter the orientation.
  var baseXY = {};
  nodes.forEach(function(n) {
    if (n.x != null && n.y != null) baseXY[n.id] = { x: n.x, y: n.y };
  });

  // ---------- Layout switching ----------
  function applyLayout(v) {
    if (v === "force") {
      // vis-network caches each (x, y) from the hierarchical layout on
      // the internal node object. A bare setOptions leaves those positions
      // pinned, and DataSet.update({x: null}) is a no-op (null/undefined
      // fields are ignored), so physics has nothing to simulate and fit()
      // can snap the already-stable graph off-screen -- canvas looks blank.
      // The reliable fix is to OVERWRITE every node with a random seed
      // position, then explicitly call stabilize().
      var seeds = [];
      nodes.forEach(function(n) {
        seeds.push({ id: n.id,
                     x: (Math.random() - 0.5) * 600,
                     y: (Math.random() - 0.5) * 600,
                     fixed: false });
      });
      nodes.update(seeds);

      network.setOptions({
        layout:  { hierarchical: { enabled: false } },
        edges:   { smooth: false },
        physics: { enabled: true,
                   solver: "barnesHut",
                   stabilization: { enabled: true, iterations: 250,
                                    updateInterval: 25, fit: true },
                   barnesHut: { gravitationalConstant: -8000,
                                springLength: 150, springConstant: 0.04,
                                avoidOverlap: 0.5 } }
      });
      network.stabilize(250);
      network.once("stabilizationIterationsDone", function() {
        network.setOptions({ physics: { enabled: false } });
        network.fit({ animation: { duration: 300 } });
      });
    } else {
      // LR/UD/RL/DU rotate the baseXY snapshot so the trunk-branch shape
      // is preserved regardless of orientation. We never re-enable
      // vis-networks built-in hierarchical engine (it would put functions
      // and tables on the trunk too, which is exactly what we want to avoid).
      var rot = {
        LR: function(p) { return { x:  p.x, y:  p.y }; },
        UD: function(p) { return { x:  p.y, y: -p.x }; },
        RL: function(p) { return { x: -p.x, y:  p.y }; },
        DU: function(p) { return { x:  p.y, y:  p.x }; }
      }[v] || function(p) { return p; };
      var updates = [];
      Object.keys(baseXY).forEach(function(id) {
        var q = rot(baseXY[id]);
        updates.push({ id: id, x: q.x, y: q.y, fixed: false });
      });
      network.setOptions({
        layout:  { hierarchical: { enabled: false } },
        edges:   { smooth: { enabled: true, type: "cubicBezier" } },
        physics: { enabled: false }
      });
      nodes.update(updates);
      setTimeout(function() { network.fit({ animation: false }); }, 80);
    }
  }
  document.getElementById("qproj-layout-sel").addEventListener("change", function(ev) {
    applyLayout(ev.target.value);
  });

  // ---------- Node search (dim non-matches) ----------
  // Cache original colors as full ColorObject snapshots so the dim/restore
  // round-trip cannot drop the border color (vis.js merges shallow on
  // update; passing a bare string later loses the explicit border).
  var originalColors = {};
  nodes.forEach(function(n) {
    var c = n.color;
    if (c && typeof c === "object") {
      originalColors[n.id] = { background: c.background, border: c.border || c.background };
    } else {
      originalColors[n.id] = { background: c, border: c };
    }
  });

  // Cache each edge color/width so the click-driven dim/restore round-trip
  // can put it back exactly as ingested. The 8-digit hex color encodes the
  // confidence alpha; losing that on restore would silently change the
  // visual semantics, so we snapshot the full string.
  var originalEdges = {};
  edges.forEach(function(e) {
    originalEdges[e.id] = { color: e.color, width: e.width || 1 };
  });
  var DIM_EDGE_COLOR = "rgba(207,216,220,0.35)";

  function applySearch(q) {
    q = (q || "").trim().toLowerCase();
    var updates = [];
    nodes.forEach(function(n) {
      var labelStr = (n.label || n.id || "").toLowerCase();
      var idStr    = (n.id    || "").toLowerCase();
      var match    = q === "" || labelStr.indexOf(q) !== -1 || idStr.indexOf(q) !== -1;
      if (match) {
        updates.push({ id: n.id, color: originalColors[n.id], opacity: 1 });
      } else {
        updates.push({ id: n.id, color: { background: "#ECEFF1",
                                          border:     "#CFD8DC" },
                                  opacity: 0.25 });
      }
    });
    nodes.update(updates);
  }
  var searchInput = document.getElementById("qproj-search");
  searchInput.addEventListener("input", function(ev) { applySearch(ev.target.value); });

  // ---------- Click-driven edge highlight (the core fix) ----------
  // The visNetwork built-in highlightNearest only thickens the selected
  // node edges; non-connected edges keep their full color, so they stay
  // visually loud in dense subgraphs (e.g. an import step wired to many
  // DB tables). We dim every other edge to a near-invisible grey and bump
  // the connected ones to their original color at width 3.
  // Track the currently dimmed-for node id so repeated clicks (or blank-
  // canvas spam) skip a full edge sweep when nothing would change. Each
  // sweep otherwise triggers a vis-network redraw of every edge.
  var dimmedFor = null;
  function highlightEdgesFor(nodeId) {
    if (dimmedFor === nodeId) return;
    var connectedSet = {};
    network.getConnectedEdges(nodeId).forEach(function(eid) {
      connectedSet[eid] = true;
    });
    var updates = [];
    edges.forEach(function(e) {
      if (connectedSet[e.id]) {
        updates.push({ id: e.id, color: originalEdges[e.id].color, width: 3 });
      } else {
        updates.push({ id: e.id, color: DIM_EDGE_COLOR, width: 1 });
      }
    });
    edges.update(updates);
    dimmedFor = nodeId;
  }
  function clearEdgeHighlight() {
    if (dimmedFor === null) return;
    var updates = [];
    edges.forEach(function(e) {
      var orig = originalEdges[e.id] || { color: e.color, width: 1 };
      updates.push({ id: e.id, color: orig.color, width: orig.width });
    });
    edges.update(updates);
    dimmedFor = null;
  }

  // ---------- Edge label toggle ----------
  var labelsVisible = false;
  var btn = document.getElementById("qproj-edge-label-toggle");
  btn.addEventListener("click", function() {
    labelsVisible = !labelsVisible;
    network.setOptions({
      edges: { font: { size: labelsVisible ? 11 : 0,
                       color: "#37474F", strokeWidth: 3, strokeColor: "#FFFFFF" } }
    });
    btn.textContent = labelsVisible ? "Hide edge labels" : "Show edge labels";
    btn.style.background = labelsVisible ? "#90A4AE" : "";
  });

  // ---------- Detail side panel (click node) ----------
  // QPROJ_GRAPH is injected as a window-scoped global. Build a quick lookup.
  var graphData = (typeof QPROJ_GRAPH !== "undefined") ? QPROJ_GRAPH : { nodes: [], edges: [], warnings: [] };
  var nodeIndex = {};
  graphData.nodes.forEach(function(n) { nodeIndex[n.id] = n; });

  // Chained replaces (& must come first) avoid the brittle char-class +
  // dict lookup, which broke down when R double-escaped the JS source.
  function escHtml(s) {
    if (s === undefined || s === null) return "";
    return String(s)
      .replace(/&/g,  "&amp;")
      .replace(/</g,  "&lt;")
      .replace(/>/g,  "&gt;")
      .replace(/"/g,  "&quot;")
      .replace(/\'/g, "&#39;");
  }
  function listOrDash(arr) {
    if (!arr || arr.length === 0) return "<i>none</i>";
    return arr.map(escHtml).join(", ");
  }
  function row(k, v) {
    return "<div style=\\"margin-bottom:6px;\\"><span style=\\"color:#78909C; font-size:11px; text-transform:uppercase; letter-spacing:0.05em;\\">" +
           escHtml(k) + "</span><br>" + v + "</div>";
  }

  function renderNodeDetail(node) {
    var meta = nodeIndex[node.id];
    if (!meta) return "<i>No metadata for " + escHtml(node.id) + ".</i>";
    var html = "";

    // Edges directly involving this node.
    var inE = [], outE = [];
    graphData.edges.forEach(function(e) {
      if (e.target === node.id) inE.push(e);
      if (e.source === node.id) outE.push(e);
    });

    if (meta.type === "step") {
      html += row("File",        escHtml(meta.file));
      html += row("Render order", escHtml(meta.render_order));
      var bd = meta.fan_breakdown || {};
      var fanLine = function(dir) {
        var d = bd[dir + "_data"]  || 0;
        var c = bd[dir + "_code"]  || 0;
        var t = bd[dir + "_table"] || 0;
        return "<span title=\\"data + code + table\\">" + (d + c + t) +
               " <span style=\\"color:#90A4AE;\\">(" + d + " data + " + c +
               " code + " + t + " table)</span></span>";
      };
      html += row("Fan in",  fanLine("in"));
      html += row("Fan out", fanLine("out"));
      html += row("Inputs", [
        meta.uses_path_data     ? "raw"      : null,
        meta.uses_path_resource ? "resource" : null,
        meta.uses_path_raw      ? "path_raw" : null
      ].filter(function(x){return x;}).map(escHtml).join(", ") || "<i>none</i>");
      html += row("Outputs",    listOrDash(meta.outputs_detected));
      html += row("R packages", listOrDash(meta.r_packages));
    } else if (meta.type === "function") {
      html += row("Defined",   escHtml(meta.file) + ":" + escHtml(meta.line));
      html += row("Callers",   escHtml(meta.n_callers) +
                                (meta.unused ? "  <span style=\\"color:#E53935;\\">(unused)</span>" : ""));
      html += row("Arguments", listOrDash(meta.arg_names));
    } else if (meta.type === "table") {
      html += row("DB file(s)", listOrDash(meta.db_files));
      html += row("Writers",   listOrDash(meta.writers));
      html += row("Readers",   listOrDash(meta.readers));
    }

    // Edge evidence list (compact).
    function edgeRow(e, dir) {
      var other = dir === "in" ? e.source : e.target;
      var ev = e.evidence || {};
      var loc = (ev.file ? escHtml(ev.file) : "") +
                (ev.chunk ? ":" + escHtml(ev.chunk) : "") +
                (ev.line ? "@L" + escHtml(ev.line) : "");
      return "<li style=\\"margin-bottom:4px;\\">" +
             "<code>" + escHtml(e.type) + "</code> " +
             (dir === "in" ? "&larr; " : "&rarr; ") + escHtml(other) +
             " <span style=\\"color:#90A4AE; font-size:11px;\\">(" + escHtml(e.confidence) + ")</span>" +
             (loc ? "<br><span style=\\"color:#78909C; font-size:11px;\\">" + loc + "</span>" : "") +
             (ev.text ? "<br><code style=\\"font-size:11px; background:#ECEFF1; padding:2px 4px; display:inline-block; max-width:100%; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;\\">" + escHtml(ev.text) + "</code>" : "") +
             "</li>";
    }
    if (inE.length) {
      html += row("Incoming edges (" + inE.length + ")",
                  "<ul style=\\"margin:0; padding-left:18px;\\">" + inE.map(function(e){return edgeRow(e, "in");}).join("") + "</ul>");
    }
    if (outE.length) {
      html += row("Outgoing edges (" + outE.length + ")",
                  "<ul style=\\"margin:0; padding-left:18px;\\">" + outE.map(function(e){return edgeRow(e, "out");}).join("") + "</ul>");
    }
    return html;
  }

  function showPanel(node) {
    document.getElementById("qproj-panel-title").textContent = node.label || node.id;
    document.getElementById("qproj-panel-body").innerHTML    = renderNodeDetail(node);
    panel.style.right = "0";
  }
  function hidePanel() { panel.style.right = "-380px"; }
  document.getElementById("qproj-panel-close").addEventListener("click", hidePanel);

  network.on("selectNode", function(params) {
    if (params.nodes.length > 0) {
      var nid = params.nodes[0];
      highlightEdgesFor(nid);
      showPanel(nodes.get(nid));
    }
  });
  network.on("deselectNode", function() {
    clearEdgeHighlight();
    hidePanel();
  });
  // Clicking on blank canvas should also clear -- selectNode does not fire
  // when the click did not land on a node, but "click" does. We only clear
  // here when no nodes are currently selected (otherwise selectNode handler
  // already ran on the new selection).
  network.on("click", function(params) {
    if (params.nodes.length === 0) clearEdgeHighlight();
  });

  // ---------- Focus mode (double-click node) ----------
  var focusedId = null;
  function focusOn(nodeId) {
    focusedId = nodeId;
    var keep = {};
    keep[nodeId] = true;
    network.getConnectedNodes(nodeId).forEach(function(id) { keep[id] = true; });
    var nodeUpdates = [];
    nodes.forEach(function(n) {
      nodeUpdates.push({ id: n.id, hidden: !keep[n.id] });
    });
    nodes.update(nodeUpdates);
    // Hide every edge whose either endpoint was hidden, otherwise the
    // arrows would dangle in empty space.
    var edgeUpdates = [];
    edges.forEach(function(e) {
      edgeUpdates.push({ id: e.id, hidden: !(keep[e.from] && keep[e.to]) });
    });
    edges.update(edgeUpdates);
    setTimeout(function() { network.fit({ animation: { duration: 300 } }); }, 50);
  }
  function unfocus() {
    if (focusedId === null) return;
    focusedId = null;
    var nodeUpdates = [];
    nodes.forEach(function(n) { nodeUpdates.push({ id: n.id, hidden: false }); });
    nodes.update(nodeUpdates);
    var edgeUpdates = [];
    edges.forEach(function(e) { edgeUpdates.push({ id: e.id, hidden: false }); });
    edges.update(edgeUpdates);
    setTimeout(function() { network.fit({ animation: { duration: 300 } }); }, 50);
  }
  network.on("doubleClick", function(params) {
    if (params.nodes.length > 0) focusOn(params.nodes[0]);
    else                          unfocus();
  });

  // ---------- PNG export ----------
  document.getElementById("qproj-png-export").addEventListener("click", function() {
    var canvas = el.querySelector("canvas");
    if (!canvas) { alert("No canvas found to export."); return; }
    canvas.toBlob(function(blob) {
      var a = document.createElement("a");
      a.href     = URL.createObjectURL(blob);
      a.download = "qproj-graph.png";
      document.body.appendChild(a);
      a.click();
      setTimeout(function() {
        URL.revokeObjectURL(a.href);
        document.body.removeChild(a);
      }, 100);
    });
  });
}
'
}

# Embed the full graph JSON as a window-scoped JS global so client-side
# controls (detail panel, focus mode) can look up node metadata without
# round-tripping to the .json file.
patch_html_inject_graph <- function(html_path, graph) {
  payload <- jsonlite::toJSON(graph, auto_unbox = TRUE, null = "null", na = "null")
  script <- c(
    "<script>",
    paste0("var QPROJ_GRAPH = ", payload, ";"),
    "</script>"
  )
  html <- readLines(html_path, warn = FALSE)
  body_close <- grep("</body>", html, fixed = TRUE)
  if (length(body_close) >= 1L) {
    html <- append(html, script, after = body_close[[1L]] - 1L)
    writeLines(html, html_path, useBytes = TRUE)
  }
  invisible(html_path)
}

# Inject viewport CSS into a saved htmlwidgets HTML so the visNetwork canvas
# fills the browser window. Idempotent; safe to call once per file.
patch_html_fullscreen <- function(html_path) {
  html <- readLines(html_path, warn = FALSE)
  css <- c(
    "<style>",
    "  html, body { margin: 0; padding: 0; height: 100%; width: 100%; overflow: hidden; }",
    "  .html-widget, .htmlwidget_container { width: 100% !important; height: 100vh !important; }",
    "  #htmlwidget_container { width: 100% !important; height: 100vh !important; }",
    "</style>"
  )
  head_close <- grep("</head>", html, fixed = TRUE)
  if (length(head_close) >= 1L) {
    # Use append() to be safe regardless of where </head> sits in the file.
    html <- append(html, css, after = head_close[[1L]] - 1L)
    writeLines(html, html_path, useBytes = TRUE)
  }
  invisible(html_path)
}

# Inject a fixed top stats bar summarising the graph: Steps | Functions
# (with unused count) | Tables | Warnings. Clicking the warnings count
# scrolls a JS alert listing them (the HTML viewer has no Markdown panel).
patch_html_stats_bar <- function(html_path, graph) {
  meta <- graph$metadata
  fn_nodes <- Filter(function(n) identical(n$type, "function"), graph$nodes)
  n_unused <- sum(vapply(fn_nodes, function(n) isTRUE(n$unused), logical(1)))
  n_warn <- length(graph$warnings)

  warn_lines <- vapply(graph$warnings, function(w) {
    sprintf("[%s] %s -- %s",
            w$type %||% "?", w$step %||% "?",
            w$message %||% "")
  }, character(1))
  warn_js_payload <- jsonlite::toJSON(warn_lines, auto_unbox = FALSE)

  bar_html <- c(
    "<style>",
    "  #qproj-stats-bar { position: fixed; top: 0; left: 0; right: 0; z-index: 10000;",
    "    background: #263238; color: #ECEFF1; font: 13px/1.4 -apple-system, system-ui, sans-serif;",
    "    padding: 6px 14px; box-shadow: 0 1px 4px rgba(0,0,0,0.25); display: flex; gap: 18px; align-items: center; }",
    "  #qproj-stats-bar .stat { display: inline-flex; gap: 5px; align-items: baseline; }",
    "  #qproj-stats-bar .stat .v { font-weight: 600; font-size: 14px; }",
    "  #qproj-stats-bar .stat .k { color: #B0BEC5; font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; }",
    "  #qproj-stats-bar .warn { cursor: pointer; }",
    "  #qproj-stats-bar .warn.zero .v { color: #66BB6A; }",
    "  #qproj-stats-bar .warn.nonzero .v { color: #FFB74D; }",
    "  #qproj-stats-bar .unused { color: #B0BEC5; font-size: 12px; }",
    "  #qproj-stats-bar .title { font-weight: 600; margin-right: 8px; color: #B0BEC5; font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; }",
    "  .html-widget, #htmlwidget_container { padding-top: 36px; box-sizing: border-box; }",
    "</style>",
    "<div id=\"qproj-stats-bar\">",
    "  <span class=\"title\">qproj graph</span>",
    sprintf("  <span class=\"stat\"><span class=\"v\">%d</span><span class=\"k\">steps</span></span>",
            meta$total_steps %||% 0L),
    sprintf("  <span class=\"stat\"><span class=\"v\">%d</span><span class=\"k\">functions</span>%s</span>",
            meta$total_functions %||% 0L,
            if (n_unused > 0L) sprintf(" <span class=\"unused\">(%d unused)</span>", n_unused) else ""),
    sprintf("  <span class=\"stat\"><span class=\"v\">%d</span><span class=\"k\">tables</span></span>",
            meta$total_tables %||% 0L),
    sprintf("  <span class=\"stat warn %s\" id=\"qproj-warn-stat\"><span class=\"v\">%d</span><span class=\"k\">warnings</span></span>",
            if (n_warn > 0L) "nonzero" else "zero", n_warn),
    "</div>",
    "<script>",
    sprintf("  var QPROJ_WARNINGS = %s;", warn_js_payload),
    "  document.addEventListener('DOMContentLoaded', function() {",
    "    var ws = document.getElementById('qproj-warn-stat');",
    "    if (ws) ws.addEventListener('click', function() {",
    "      if (QPROJ_WARNINGS.length === 0) { alert('No warnings.'); return; }",
    "      alert(QPROJ_WARNINGS.join('\\n'));",
    "    });",
    "  });",
    "</script>"
  )

  html <- readLines(html_path, warn = FALSE)
  body_open <- grep("<body[^>]*>", html)
  if (length(body_open) >= 1L) {
    # `append(after = i)` is safe even if `i == length(html)`; the naive
    # `c(html[1:i], bar, html[(i+1):length(html)])` would generate a
    # decreasing seq and inject `NA` lines in that edge case.
    html <- append(html, bar_html, after = body_open[[1L]])
    writeLines(html, html_path, useBytes = TRUE)
  }
  invisible(html_path)
}
