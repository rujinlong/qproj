#' Scan a single .qmd for path_*, library, ::, here::here usage
#'
#' Statically extracts the R code from a Quarto file via [knitr::purl()],
#' parses it via [base::parse()], and walks the AST collecting evidence of:
#'  - `path_source("<step>", ...)` calls (reads-from edges)
#'  - `path_target("<file>", ...)` calls (declared outputs)
#'  - `here::here(path_raw, "d<step>-...", ...)` calls (anti-pattern bypass)
#'  - `library()`, `pkg::fn` references (R package dependencies)
#'  - bare references to `path_data`, `path_resource`, `path_raw` symbols
#'
#' Confidence rules:
#'  - First arg is a string literal -> `EXTRACTED`
#'  - First arg is a symbol or expression -> `AMBIGUOUS` plus a warning
#'
#' @param qmd_path `character` path to a `.qmd` file.
#' @param ctx `list` optional cross-file context with elements:
#'   - `local_fns`: character vector of names of functions defined in
#'     the project's `R/*.R`, used for resolving local function calls
#'   - `pkg_name`: character scalar with the project's DESCRIPTION
#'     `Package` field, used for resolving `<pkg>::fn(...)` calls back
#'     to local functions
#'   - `scan_db`: logical, default TRUE. Set FALSE to skip DBI handling.
#'
#' @return A list capturing the extracted facts. See the source for fields.
#' @keywords internal
#' @noRd
scan_qmd <- function(qmd_path, ctx = list()) {

  ctx$local_fns <- ctx$local_fns %||% character(0)
  ctx$pkg_name  <- ctx$pkg_name  %||% NA_character_
  ctx$scan_db   <- ctx$scan_db   %||% TRUE

  yaml <- tryCatch(
    rmarkdown::yaml_front_matter(qmd_path),
    error = function(e) list()
  )
  step_name <- yaml$params$name %||% tools::file_path_sans_ext(basename(qmd_path))

  state <- new_scan_state(step_name, qmd_path)

  tmp_r <- tempfile(fileext = ".R")
  on.exit(unlink(tmp_r), add = TRUE)

  ok <- tryCatch({
    suppressMessages(knitr::purl(
      qmd_path, output = tmp_r,
      documentation = 1L, quiet = TRUE
    ))
    TRUE
  }, error = function(e) {
    cli::cli_warn("Failed to purl {.file {qmd_path}}: {conditionMessage(e)}")
    FALSE
  })

  if (!ok || !file.exists(tmp_r) || file.size(tmp_r) == 0L) {
    return(state)
  }

  state$chunk_index <- build_chunk_index(tmp_r)

  exprs <- tryCatch(
    parse(file = tmp_r, keep.source = TRUE),
    error = function(e) {
      cli::cli_warn("Parse error in {.file {qmd_path}}: {conditionMessage(e)}")
      expression()
    }
  )

  srcrefs <- attr(exprs, "srcref")
  for (i in seq_along(exprs)) {
    line <- if (!is.null(srcrefs) && length(srcrefs) >= i) {
      srcrefs[[i]][1L]
    } else {
      NA_integer_
    }
    # The qproj template's `setup` chunk creates path_* bindings and calls
    # dir.create(path_data) etc. We don't want those framework-internal
    # references to be reported as user-side `uses_path_data` etc.
    # path_source / path_target / here::here calls are still processed normally.
    in_setup <- identical(chunk_label_for(line, state$chunk_index), "setup")
    walk_expr(exprs[[i]], state, line = line, in_lhs = FALSE,
              in_setup = in_setup, ctx = ctx)
  }

  state$chunk_index <- NULL
  state
}

new_scan_state <- function(step_name, qmd_path) {
  state <- new.env(parent = emptyenv())
  state$name <- step_name
  state$file <- qmd_path
  state$reads_from <- list()
  state$outputs <- list()
  state$bypass_access <- list()
  state$uses_path_data <- FALSE
  state$uses_path_resource <- FALSE
  state$uses_path_raw <- FALSE
  state$r_packages <- character(0)
  state$warnings <- list()
  state$chunk_index <- list()
  state$uses_function <- list()
  state$dbi_calls    <- list()
  state$connections  <- list()
  state
}

# Map each line in the purled .R back to its chunk label, by reading the
# `## ----` separators and `#| label: <name>` lines knitr::purl(documentation=1)
# inserts in place of each chunk header.
build_chunk_index <- function(tmp_r) {
  lines <- readLines(tmp_r, warn = FALSE)
  n <- length(lines)
  if (n == 0L) return(list())

  sep_idx <- which(grepl("^##\\s*-{3,}", lines))
  if (length(sep_idx) == 0L) {
    return(list(list(start = 1L, end = n, label = NA_character_)))
  }

  label_re <- "^#\\|\\s*label:\\s*([A-Za-z0-9._-]+)\\s*$"
  labels <- vapply(sep_idx, function(i) {
    # Look at next ~5 lines for `#| label: <name>` (Quarto-style)
    j_max <- min(i + 5L, n)
    candidates <- lines[(i + 1L):j_max]
    hit <- candidates[grepl(label_re, candidates)]
    if (length(hit) > 0L) sub(label_re, "\\1", hit[[1L]]) else NA_character_
  }, character(1))

  # Each chunk runs from sep_idx[k] to sep_idx[k+1] - 1 (or n)
  ends <- c(sep_idx[-1L] - 1L, n)
  Map(function(s, e, lab) list(start = s, end = e, label = lab),
      sep_idx, ends, labels)
}

chunk_label_for <- function(line, chunk_index) {
  if (is.na(line) || length(chunk_index) == 0L) return(NA_character_)
  for (ck in chunk_index) {
    if (line >= ck$start && line <= ck$end) return(ck$label)
  }
  NA_character_
}

# Recursively walk an R expression. Mutates `state` (environment).
walk_expr <- function(e, state, line = NA_integer_, in_lhs = FALSE,
                      in_setup = FALSE, in_dbconnect = FALSE, ctx = list()) {
  if (is.symbol(e)) {
    if (!in_lhs && !in_setup) flag_symbol(as.character(e), state)
    return(invisible())
  }
  if (!is.call(e)) return(invisible())

  # Try to register a connection from any `con <- dbConnect(...)` form,
  # whether top-level or nested inside `if (...) con <- ...` etc. This
  # mirrors the in_dbconnect suppression of path_source/path_target inside
  # the dbConnect path expression, so the two stay in sync.
  if (isTRUE(ctx$scan_db)) register_connection(e, state)

  fn_name <- extract_fn_name(e[[1L]])
  visit_call(fn_name, e, state, line = line, in_setup = in_setup,
             in_dbconnect = in_dbconnect, ctx = ctx)

  # When entering a dbConnect(...) call, mark the subtree so that any
  # path_source / path_target nested inside the connection's path argument
  # is not double-counted as a workflow read/write -- register_connection
  # has already turned that path expression into a db_file binding.
  child_in_dbconnect <- in_dbconnect ||
    (!is.null(fn_name) && identical(strip_namespace(fn_name), "dbConnect"))

  is_assignment <- !is.null(fn_name) && fn_name %in% c("<-", "=", "<<-")
  n <- length(e)
  if (n >= 2L) for (i in 2:n) {
    walk_expr(e[[i]], state, line = line,
              in_lhs = is_assignment && i == 2L,
              in_setup = in_setup,
              in_dbconnect = child_in_dbconnect, ctx = ctx)
  }
  invisible()
}

flag_symbol <- function(sym, state) {
  if (sym == "path_data") state$uses_path_data <- TRUE
  else if (sym == "path_resource") state$uses_path_resource <- TRUE
  else if (sym == "path_raw") state$uses_path_raw <- TRUE
}

extract_fn_name <- function(fn) {
  if (is.symbol(fn)) return(as.character(fn))
  if (is.call(fn) && length(fn) == 3L) {
    op <- fn[[1L]]
    if (is.symbol(op)) {
      op_name <- as.character(op)
      if (op_name %in% c("::", ":::")) {
        pkg <- as.character(fn[[2L]])
        f <- as.character(fn[[3L]])
        return(paste(pkg, f, sep = op_name))
      }
    }
  }
  NULL
}

visit_call <- function(fn_name, e, state, line, in_setup = FALSE,
                       in_dbconnect = FALSE, ctx = list()) {
  if (is.null(fn_name)) return(invisible())
  args <- if (length(e) > 1L) as.list(e[-1L]) else list()

  # Inside a dbConnect path expression, path_source / path_target are part of
  # the connection URL, not workflow reads/writes. Skip them entirely; the
  # connection itself was already registered by register_connection().
  if (in_dbconnect && fn_name %in% c("path_source", "path_target")) {
    return(invisible())
  }

  if (fn_name == "path_source") {
    handle_path_source(args, state, line, e, in_setup = in_setup)
  } else if (fn_name == "path_target") {
    handle_path_target(args, state, line)
  } else if (fn_name %in% c("here", "here::here")) {
    handle_here(args, state, line, e)
  } else if (fn_name %in% c("library", "require", "requireNamespace")) {
    handle_library(args, state)
  } else if (isTRUE(ctx$scan_db) && is_dbi_call(fn_name)) {
    handle_dbi_call(fn_name, args, state, line, e)
  } else if (is_local_function_call(fn_name, ctx)) {
    handle_local_fn(fn_name, args, state, line, e)
  } else if (grepl("::", fn_name, fixed = TRUE)) {
    pkg <- sub("::.*", "", fn_name)
    state$r_packages <- unique(c(state$r_packages, pkg))
  }
  invisible()
}

# A call is a "local function call" if its bare name is one of the names
# defined in the project's R/ directory (passed via ctx$local_fns), and the
# call form is either bare (`my_fn(...)`) or qualified by the project's own
# package (`<pkg_name>::my_fn(...)`).
is_local_function_call <- function(fn_name, ctx) {
  if (length(ctx$local_fns) == 0L) return(FALSE)
  if (fn_name %in% ctx$local_fns) return(TRUE)
  if (!grepl("::", fn_name, fixed = TRUE)) return(FALSE)
  pkg  <- sub("::.*", "", fn_name)
  bare <- sub("^.*::", "", fn_name)
  !is.na(ctx$pkg_name) && identical(pkg, ctx$pkg_name) && bare %in% ctx$local_fns
}

handle_local_fn <- function(fn_name, args, state, line, e) {
  bare <- sub("^.*::", "", fn_name)
  text <- deparse_short(e)
  chunk <- chunk_label_for(line, state$chunk_index)

  # Capture only literal scalar args (named or positional).
  named <- names(args) %||% character(length(args))
  captured <- list()
  for (i in seq_along(args)) {
    a <- args[[i]]
    if ((is.character(a) || is.numeric(a) || is.logical(a)) && length(a) == 1L) {
      key <- if (nzchar(named[i])) named[i] else paste0("$", i)
      captured[[key]] <- a
    }
  }

  state$uses_function <- c(state$uses_function, list(list(
    target        = bare,
    line          = line,
    chunk         = chunk,
    args_captured = captured,
    text          = text
  )))
}

handle_path_source <- function(args, state, line, e, in_setup = FALSE) {
  if (length(args) < 1L) return()
  a1 <- args[[1L]]
  text <- deparse_short(e)
  chunk <- chunk_label_for(line, state$chunk_index)

  if (is.character(a1) && length(a1) == 1L) {
    target <- a1
    if (grepl("^00-", target)) {
      # Standard binding `path_raw <- path_source("00-raw")` in setup chunks
      # is template boilerplate; only flag uses_path_raw for genuine user calls.
      if (!in_setup) state$uses_path_raw <- TRUE
      return()
    }
    file_arg <- NA_character_
    if (length(args) >= 2L && is.character(args[[2L]]) && length(args[[2L]]) == 1L) {
      file_arg <- args[[2L]]
    }
    state$reads_from <- c(state$reads_from, list(list(
      target = target, confidence = "EXTRACTED",
      file_arg = file_arg, line = line, chunk = chunk, text = text
    )))
  } else {
    repr <- deparse_short(a1, max = 60L)
    state$reads_from <- c(state$reads_from, list(list(
      target = paste0("<", repr, ">"), confidence = "AMBIGUOUS",
      file_arg = NA_character_, line = line, chunk = chunk, text = text
    )))
    state$warnings <- c(state$warnings, list(list(
      type = "AMBIGUOUS_PATH_SOURCE", line = line, chunk = chunk,
      message = sprintf(
        "path_source() called with non-literal step argument: %s", repr
      ),
      text = text
    )))
  }
}

handle_path_target <- function(args, state, line) {
  if (length(args) < 1L) return()
  for (a in args) {
    if (is.character(a) && length(a) == 1L) {
      state$outputs <- c(state$outputs, list(list(
        file = a, line = line,
        chunk = chunk_label_for(line, state$chunk_index)
      )))
      return()
    }
  }
}

handle_here <- function(args, state, line, e) {
  if (length(args) < 2L) return()
  a1 <- args[[1L]]; a2 <- args[[2L]]
  if (!(is.symbol(a1) && as.character(a1) == "path_raw" &&
        is.character(a2) && length(a2) == 1L && grepl("^d\\d{2,3}-", a2))) {
    return()
  }
  target_step <- sub("^d", "", a2)
  # Skip framework-reserved 00-* (e.g. d00-resource is the standard path_resource binding).
  if (grepl("^00-", target_step)) return()
  # Skip self-access — that's equivalent to using path_data and is not a bypass.
  if (identical(target_step, state$name)) return()

  text <- deparse_short(e)
  chunk <- chunk_label_for(line, state$chunk_index)
  state$bypass_access <- c(state$bypass_access, list(list(
    target = target_step, line = line, chunk = chunk, text = text
  )))
  state$warnings <- c(state$warnings, list(list(
    type = "ANTI_PATTERN_BYPASS_ACCESS", line = line, chunk = chunk,
    message = sprintf(
      "Direct here::here() access to d%s detected. Prefer path_source('%s', ...) instead.",
      target_step, target_step
    ),
    text = text
  )))
}

handle_library <- function(args, state) {
  if (length(args) < 1L) return()
  a1 <- args[[1L]]
  pkg <- if (is.symbol(a1)) {
    as.character(a1)
  } else if (is.character(a1) && length(a1) == 1L) {
    a1
  } else {
    NULL
  }
  if (!is.null(pkg)) state$r_packages <- unique(c(state$r_packages, pkg))
}

deparse_short <- function(e, max = 200L) {
  text <- paste(deparse(e, width.cutoff = 500L), collapse = " ")
  if (nchar(text) > max) text <- paste0(substr(text, 1L, max - 3L), "...")
  text
}
