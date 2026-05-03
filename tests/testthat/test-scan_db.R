test_that("classify_dbi_call() routes function names correctly", {
  expect_identical(classify_dbi_call("dbReadTable"),       "read")
  expect_identical(classify_dbi_call("DBI::dbReadTable"),  "read")
  expect_identical(classify_dbi_call("dplyr::tbl"),        "read")
  expect_identical(classify_dbi_call("dbWriteTable"),      "write")
  expect_identical(classify_dbi_call("DBI::dbAppendTable"),"write")
  expect_identical(classify_dbi_call("dbGetQuery"),        "sql")
  expect_identical(classify_dbi_call("DBI::dbExecute"),    "sql")
  expect_identical(classify_dbi_call("dbConnect"),         "connect")
  expect_null(classify_dbi_call("not_a_dbi_fn"))
})

test_that("extract_tables_from_sql() finds table names via FROM/JOIN/INSERT etc", {
  res <- extract_tables_from_sql("SELECT * FROM raw_seqs JOIN ref_lookup ON r = l")
  expect_setequal(res$reads, c("raw_seqs", "ref_lookup"))
  expect_length(res$writes, 0L)

  res2 <- extract_tables_from_sql("INSERT INTO audit_log VALUES (?)")
  expect_setequal(res2$writes, "audit_log")
  expect_length(res2$reads, 0L)

  res3 <- extract_tables_from_sql("CREATE TABLE IF NOT EXISTS results (x INT)")
  expect_setequal(res3$writes, "results")

  res4 <- extract_tables_from_sql("UPDATE log SET n = n + 1 WHERE step = 'x'")
  expect_setequal(res4$writes, "log")

  # Quoted identifier support
  res5 <- extract_tables_from_sql('SELECT * FROM "raw_seqs"')
  expect_setequal(res5$reads, "raw_seqs")
})

test_that("extract_tables_from_sql() handles non-string and empty inputs", {
  expect_identical(extract_tables_from_sql(NA_character_),
                   list(reads = character(0), writes = character(0)))
  expect_identical(extract_tables_from_sql("no SQL keywords here"),
                   list(reads = character(0), writes = character(0)))
})

test_that("parse_db_path() resolves path_target / path_source / file.path / literal", {
  step <- "02-clean"
  expect_identical(parse_db_path(quote(path_target("db.sqlite")), step),
                   "02-clean/db.sqlite")
  expect_identical(parse_db_path(quote(path_source("01-import", "x.sqlite")), step),
                   "01-import/x.sqlite")
  expect_identical(parse_db_path(quote(here::here("data", "shared.sqlite")), step),
                   "data/shared.sqlite")
  expect_identical(parse_db_path("absolute.sqlite", step),
                   "absolute.sqlite")
  expect_true(is.na(parse_db_path(quote(some_var), step)))
})

# ---- end-to-end on the fixture --------------------------------------------

fixture_root <- testthat::test_path("fixtures", "scan_minimal")

skip_if_missing_suggests <- function() {
  needed <- c("knitr", "rmarkdown", "jsonlite")
  miss <- needed[!vapply(needed, requireNamespace, logical(1), quietly = TRUE)]
  if (length(miss)) skip(paste("missing Suggests:", paste(miss, collapse = ", ")))
}

test_that("scan_qmd() detects dbWriteTable + dbConnect path on 02-clean", {
  skip_if_missing_suggests()
  ctx <- list(local_fns = c("qc_filter","qc_norm","qc_unused"),
              pkg_name = "scanFixture", scan_db = TRUE)
  res <- scan_qmd(fs::path(fixture_root, "analyses", "02-clean.qmd"), ctx = ctx)
  writes <- Filter(function(d) d$kind == "write", res$dbi_calls)
  expect_length(writes, 1L)
  expect_identical(writes[[1L]]$table, "raw_seqs")
  expect_identical(writes[[1L]]$confidence, "EXTRACTED")
  expect_identical(writes[[1L]]$db_file, "02-clean/db.sqlite")
})

test_that("scan_qmd() extracts SQL FROM/JOIN/INSERT INTO from 03-analyze", {
  skip_if_missing_suggests()
  ctx <- list(local_fns = c("qc_filter","qc_norm","qc_unused"),
              pkg_name = "scanFixture", scan_db = TRUE)
  res <- scan_qmd(fs::path(fixture_root, "analyses", "03-analyze.qmd"), ctx = ctx)
  reads <- Filter(function(d) d$kind == "read", res$dbi_calls)
  read_tables <- vapply(reads, function(d) d$table, character(1))
  expect_setequal(read_tables, c("raw_seqs", "ref_lookup"))
  # All INFERRED via SQL regex
  expect_true(all(vapply(reads, function(d) d$confidence == "INFERRED", logical(1))))

  writes <- Filter(function(d) d$kind == "write", res$dbi_calls)
  expect_setequal(vapply(writes, function(d) d$table, character(1)), "audit_log")
})

test_that("scan_qmd(scan_db = FALSE) skips DBI handling entirely", {
  skip_if_missing_suggests()
  ctx <- list(local_fns = character(0), pkg_name = NA_character_, scan_db = FALSE)
  res <- scan_qmd(fs::path(fixture_root, "analyses", "03-analyze.qmd"), ctx = ctx)
  expect_length(res$dbi_calls, 0L)
})

test_that("AMBIGUOUS_TABLE_NAME warning fires for non-literal table arg", {
  skip_if_missing_suggests()
  qmd <- withr::local_tempfile(fileext = ".qmd")
  writeLines(c(
    "---", "title: t", "params:", "  name: t", "---",
    "```{r}", "tbl_name <- 'dynamic'",
    "DBI::dbReadTable(con, tbl_name)",
    "```"
  ), qmd)
  ctx <- list(local_fns = character(0), pkg_name = NA_character_, scan_db = TRUE)
  res <- scan_qmd(qmd, ctx = ctx)
  warn_types <- vapply(res$warnings, function(w) w$type, character(1))
  expect_true("AMBIGUOUS_TABLE_NAME" %in% warn_types)
})

test_that("AMBIGUOUS_SQL warning fires for non-literal SQL arg", {
  skip_if_missing_suggests()
  qmd <- withr::local_tempfile(fileext = ".qmd")
  writeLines(c(
    "---", "title: t", "params:", "  name: t", "---",
    "```{r}", "sql_var <- 'SELECT * FROM x'",
    "DBI::dbGetQuery(con, sql_var)",
    "```"
  ), qmd)
  ctx <- list(local_fns = character(0), pkg_name = NA_character_, scan_db = TRUE)
  res <- scan_qmd(qmd, ctx = ctx)
  warn_types <- vapply(res$warnings, function(w) w$type, character(1))
  expect_true("AMBIGUOUS_SQL" %in% warn_types)
})
