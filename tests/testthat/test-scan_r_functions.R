fixture_root <- testthat::test_path("fixtures", "scan_minimal")
r_dir <- fs::path(fixture_root, "R")

test_that("scan_r_functions() extracts top-level function definitions", {
  fns <- scan_r_functions(r_dir)
  names <- vapply(fns, function(f) f$name, character(1))
  expect_setequal(names, c("qc_filter", "qc_norm", "qc_unused"))
})

test_that("scan_r_functions() captures arg_names and n_args", {
  fns <- scan_r_functions(r_dir)
  by_name <- stats::setNames(fns, vapply(fns, function(f) f$name, character(1)))
  expect_identical(by_name$qc_filter$arg_names, c("x", "threshold", "method"))
  expect_identical(by_name$qc_filter$n_args, 3L)
  expect_identical(by_name$qc_unused$arg_names, "x")
})

test_that("scan_r_functions() returns empty list when r_dir missing", {
  expect_identical(scan_r_functions(fs::path(fixture_root, "no-such-dir")), list())
})

test_that("project_pkg_name() reads DESCRIPTION Package field", {
  expect_identical(project_pkg_name(fixture_root), "scanFixture")
})

test_that("project_pkg_name() returns NA when DESCRIPTION absent", {
  tmp <- withr::local_tempdir()
  expect_true(is.na(project_pkg_name(tmp)))
})
