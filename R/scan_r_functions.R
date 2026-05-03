#' Scan a project's R/ directory for top-level function definitions
#'
#' Parses every `*.R` file under `r_dir` and extracts top-level function
#' definitions of the form `name <- function(...) {...}` (or `=`/`<<-`).
#' Also recognises `setMethod("X", ..., function(...))` (S4) but only
#' surfaces the generic name, not a separate node per signature.
#'
#' @param r_dir `character` directory to scan, typically `<project>/R`.
#'
#' @return `list` of zero or more function records:
#'   `list(name, file, line, n_args, arg_names, kind = "function" | "S4")`.
#' @keywords internal
#' @noRd
scan_r_functions <- function(r_dir) {
  if (!dir.exists(r_dir)) return(list())

  r_files <- list.files(r_dir, pattern = "\\.R$", full.names = TRUE,
                        recursive = FALSE, ignore.case = TRUE)
  if (length(r_files) == 0L) return(list())

  out <- list()
  for (f in r_files) {
    exprs <- tryCatch(
      parse(file = f, keep.source = TRUE),
      error = function(e) {
        cli::cli_warn("Parse error in {.file {f}}: {conditionMessage(e)}")
        expression()
      }
    )
    srcrefs <- attr(exprs, "srcref")
    rel <- file.path(basename(dirname(f)), basename(f))

    for (i in seq_along(exprs)) {
      e <- exprs[[i]]
      line <- if (!is.null(srcrefs) && length(srcrefs) >= i) srcrefs[[i]][1L] else NA_integer_
      rec <- as_function_record(e, rel, line)
      if (!is.null(rec)) out <- c(out, list(rec))
    }
  }
  out
}

# Try to interpret a top-level expression as a function definition.
# Returns NULL if it isn't one we recognise.
as_function_record <- function(e, rel_file, line) {
  if (!is.call(e)) return(NULL)

  op <- tryCatch(as.character(e[[1L]]), error = function(...) NA_character_)
  if (is.na(op)) return(NULL)

  # Pattern 1: assignment whose RHS is a function() literal.
  if (op %in% c("<-", "=", "<<-") && length(e) == 3L) {
    rhs <- e[[3L]]
    if (is.call(rhs) && identical(rhs[[1L]], as.symbol("function"))) {
      lhs <- e[[2L]]
      name <- if (is.symbol(lhs)) as.character(lhs) else NULL
      if (is.null(name) || name == "") return(NULL)
      args <- names(rhs[[2L]])  # formals = pairlist
      args <- args[nzchar(args)]
      return(list(
        name      = name,
        file      = rel_file,
        line      = line,
        n_args    = length(args),
        arg_names = args,
        kind      = "function"
      ))
    }
  }

  # Pattern 2: setMethod("X", ..., function(...))
  if (op == "setMethod" && length(e) >= 4L) {
    arg1 <- e[[2L]]
    if (is.character(arg1) && length(arg1) == 1L) {
      # Try to find the function() literal among remaining args.
      fn_arg <- NULL
      for (j in 3:length(e)) {
        candidate <- e[[j]]
        if (is.call(candidate) && identical(candidate[[1L]], as.symbol("function"))) {
          fn_arg <- candidate
          break
        }
      }
      if (!is.null(fn_arg)) {
        args <- names(fn_arg[[2L]]); args <- args[nzchar(args)]
        return(list(
          name      = arg1,
          file      = rel_file,
          line      = line,
          n_args    = length(args),
          arg_names = args,
          kind      = "S4"
        ))
      }
    }
  }

  NULL
}

#' Read the Package field from a project DESCRIPTION file
#'
#' Returns `NA_character_` if no DESCRIPTION exists or it has no `Package:` line.
#'
#' @keywords internal
#' @noRd
project_pkg_name <- function(path) {
  d <- file.path(path, "DESCRIPTION")
  if (!file.exists(d)) return(NA_character_)
  tryCatch(
    unname(desc::desc_get_field("Package", file = d, default = NA_character_)),
    error = function(e) NA_character_
  )
}
