## DBI / SQLite-style table dependency detection.
##
## Two layers:
##   1. Function-call mode: dbReadTable(con, "X") / dbWriteTable(con, "X", ...)
##      -> table arg is a string literal (EXTRACTED).
##   2. SQL-string mode: dbGetQuery(con, "SELECT * FROM X JOIN Y ...")
##      -> regex-extract table names from SQL keywords (INFERRED).
##
## A `dbConnect(driver, <path_expr>)` call at top level registers the
## resulting variable -> db_file binding for the rest of the .qmd, so that
## table calls can be tagged with a project-relative DB file path.

DBI_FNS_READ    <- c("dbReadTable", "dbExistsTable", "tbl")
DBI_FNS_WRITE   <- c("dbWriteTable", "dbAppendTable", "dbCreateTable",
                     "dbRemoveTable")
DBI_FNS_SQL     <- c("dbGetQuery", "dbSendQuery", "dbExecute",
                     "dbSendStatement")
DBI_FNS_CONNECT <- c("dbConnect")

## SQL keyword -> table-name regex. PCRE-compatible, case-insensitive.
SQL_READ_PATTERNS <- c(
  "(?i)\\bFROM\\s+[\"`']?([A-Za-z_][\\w]*)",
  "(?i)\\bJOIN\\s+[\"`']?([A-Za-z_][\\w]*)"
)
SQL_WRITE_PATTERNS <- c(
  "(?i)\\bINSERT\\s+INTO\\s+[\"`']?([A-Za-z_][\\w]*)",
  "(?i)\\bUPDATE\\s+[\"`']?([A-Za-z_][\\w]*)",
  "(?i)\\bDELETE\\s+FROM\\s+[\"`']?([A-Za-z_][\\w]*)",
  "(?i)\\bCREATE\\s+TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?[\"`']?([A-Za-z_][\\w]*)",
  "(?i)\\bDROP\\s+TABLE\\s+(?:IF\\s+EXISTS\\s+)?[\"`']?([A-Za-z_][\\w]*)"
)

## Strip an optional `pkg::` prefix and return the bare DBI function name.
strip_namespace <- function(fn_name) sub("^.*::", "", fn_name)

is_dbi_call <- function(fn_name) {
  bare <- strip_namespace(fn_name)
  bare %in% c(DBI_FNS_READ, DBI_FNS_WRITE, DBI_FNS_SQL, DBI_FNS_CONNECT)
}

classify_dbi_call <- function(fn_name) {
  bare <- strip_namespace(fn_name)
  if (bare %in% DBI_FNS_READ)    return("read")
  if (bare %in% DBI_FNS_WRITE)   return("write")
  if (bare %in% DBI_FNS_SQL)     return("sql")
  if (bare %in% DBI_FNS_CONNECT) return("connect")
  NULL
}

## Extract table names from a literal SQL string. Returns a list with
## character vectors `reads` and `writes`. Order-preserving, deduplicated.
extract_tables_from_sql <- function(sql) {
  if (!is.character(sql) || length(sql) != 1L || is.na(sql)) {
    return(list(reads = character(0), writes = character(0)))
  }
  one <- function(patterns) {
    found <- character(0)
    for (re in patterns) {
      m <- regmatches(sql, gregexpr(re, sql, perl = TRUE))[[1L]]
      if (length(m) == 0L) next
      for (hit in m) {
        cap <- regmatches(hit, regexec(re, hit, perl = TRUE))[[1L]]
        if (length(cap) >= 2L) found <- c(found, cap[2L])
      }
    }
    unique(found)
  }
  list(reads = one(SQL_READ_PATTERNS), writes = one(SQL_WRITE_PATTERNS))
}

## Try to interpret a path-construction R expression (the second arg to
## dbConnect) as a project-relative file path. Returns a single character
## or NA if the form is not recognised.
parse_db_path <- function(e, current_step) {
  if (is.character(e) && length(e) == 1L) return(e)
  if (!is.call(e)) return(NA_character_)

  fn <- tryCatch(extract_fn_name(e[[1L]]), error = function(...) NULL)
  if (is.null(fn)) return(NA_character_)
  args <- if (length(e) > 1L) as.list(e[-1L]) else list()
  lits <- function(xs) {
    out <- character(0)
    for (x in xs) {
      if (is.character(x) && length(x) == 1L) out <- c(out, x)
      else return(NULL)  # any non-literal arg -> bail
    }
    out
  }

  if (fn == "path_target") {
    parts <- lits(args)
    if (is.null(parts)) return(NA_character_)
    return(do.call(file.path, as.list(c(current_step, parts))))
  }
  if (fn == "path_source") {
    if (length(args) >= 1L && is.character(args[[1L]]) && length(args[[1L]]) == 1L) {
      step <- args[[1L]]
      rest <- if (length(args) >= 2L) lits(args[-1L]) else character(0)
      if (is.null(rest)) return(NA_character_)
      return(do.call(file.path, as.list(c(step, rest))))
    }
    return(NA_character_)
  }
  if (fn %in% c("here::here", "here", "file.path")) {
    parts <- lits(args)
    if (is.null(parts)) return(NA_character_)
    return(do.call(file.path, as.list(parts)))
  }
  NA_character_
}

## Walk a top-level expression and, if it is `con <- dbConnect(driver, path)`,
## register `con -> parsed_db_path` in `state$connections`.
register_connection <- function(e, state) {
  if (!is.call(e) || length(e) != 3L) return(invisible())
  if (!is.symbol(e[[1L]])) return(invisible())
  op <- as.character(e[[1L]])
  if (!op %in% c("<-", "=", "<<-")) return(invisible())

  lhs <- e[[2L]]; rhs <- e[[3L]]
  if (!is.symbol(lhs)) return(invisible())
  if (!is.call(rhs)) return(invisible())

  fn <- tryCatch(extract_fn_name(rhs[[1L]]), error = function(...) NULL)
  if (is.null(fn) || strip_namespace(fn) != "dbConnect") return(invisible())

  con_name <- as.character(lhs)
  path_expr <- if (length(rhs) >= 3L) rhs[[3L]] else NULL
  db_file <- if (!is.null(path_expr)) parse_db_path(path_expr, state$name) else NA_character_

  prev <- state$connections[[con_name]]
  state$connections[[con_name]] <- db_file
  if (!is.null(prev) && !identical(prev, db_file)) {
    state$warnings <- c(state$warnings, list(list(
      type    = "AMBIGUOUS_MULTI_DB", line = NA_integer_, chunk = NA_character_,
      message = sprintf("Connection variable `%s` rebound to a different db_file; later DBI calls may be tagged inconsistently.", con_name),
      text    = sprintf("%s <- dbConnect(...)", con_name)
    )))
  }
  invisible()
}

## Resolve the db_file tag for a DBI call given its `con` argument.
resolve_db_file <- function(con_arg, state) {
  if (is.symbol(con_arg)) {
    nm <- as.character(con_arg)
    return(state$connections[[nm]] %||% NA_character_)
  }
  NA_character_
}

## Main DBI handler -- called from visit_call() for any fn whose bare name
## matches DBI_FNS_*. `connect` is registered separately at top level.
handle_dbi_call <- function(fn_name, args, state, line, e) {
  kind <- classify_dbi_call(fn_name)
  if (is.null(kind) || kind == "connect") return(invisible())
  if (length(args) < 2L) return(invisible())

  chunk    <- chunk_label_for(line, state$chunk_index)
  text     <- deparse_short(e)
  con_arg  <- args[[1L]]
  db_file  <- resolve_db_file(con_arg, state)
  bare     <- strip_namespace(fn_name)

  add_call <- function(table, kind_label, confidence) {
    state$dbi_calls <- c(state$dbi_calls, list(list(
      table      = table,
      kind       = kind_label,           # "read" or "write"
      confidence = confidence,           # "EXTRACTED" or "INFERRED"
      fn         = bare,
      line       = line,
      chunk      = chunk,
      db_file    = db_file,
      text       = text
    )))
  }

  if (kind %in% c("read", "write")) {
    a2 <- args[[2L]]
    if (is.character(a2) && length(a2) == 1L) {
      add_call(a2, kind, "EXTRACTED")
    } else {
      state$warnings <- c(state$warnings, list(list(
        type    = "AMBIGUOUS_TABLE_NAME", line = line, chunk = chunk,
        message = sprintf("%s() called with non-literal table name.", bare),
        text    = text
      )))
    }
    return(invisible())
  }

  ## kind == "sql" -- second arg should be a literal SQL string
  a2 <- args[[2L]]
  if (is.character(a2) && length(a2) == 1L) {
    tabs <- extract_tables_from_sql(a2)
    for (t in tabs$reads)  add_call(t, "read",  "INFERRED")
    for (t in tabs$writes) add_call(t, "write", "INFERRED")
    if (length(tabs$reads) == 0L && length(tabs$writes) == 0L) {
      state$warnings <- c(state$warnings, list(list(
        type    = "EMPTY_SQL_PARSE", line = line, chunk = chunk,
        message = sprintf("%s() SQL produced no recognisable table names.", bare),
        text    = text
      )))
    }
  } else {
    state$warnings <- c(state$warnings, list(list(
      type    = "AMBIGUOUS_SQL", line = line, chunk = chunk,
      message = sprintf("%s() called with non-literal SQL; cannot extract tables statically.", bare),
      text    = text
    )))
  }
  invisible()
}
