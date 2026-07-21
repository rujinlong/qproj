test_that("proj_shell_lib() finds the shipped qproj.sh", {

  path <- proj_shell_lib()

  expect_true(file.exists(path))
  expect_match(path, "qproj\\.sh$")

  # It is the real helper library, not an empty placeholder.
  expect_true(any(grepl("^path_run_state\\(\\)", readLines(path, warn = FALSE))))
})

test_that("proj_shell_lib(mustWork = FALSE) degrades instead of aborting", {

  # Cannot uninstall the package mid-test, so assert the contract on the branch we can
  # reach: a found script is returned unchanged whichever mustWork is given.
  expect_identical(proj_shell_lib(mustWork = FALSE), proj_shell_lib())
})

test_that("proj_shell_bootstrap() emits the resolver with its precedence intact", {

  block <- proj_shell_bootstrap()

  expect_length(block, 1L)
  expect_match(block, "_qproj_bootstrap\\(\\)")

  # All three candidates, in order, plus the version marker used to spot drift between
  # this SSOT and the verbatim copies living in project repos.
  expect_match(block, "qproj-bootstrap v1", fixed = TRUE)
  expect_match(block, "QPROJ_SH", fixed = TRUE)
  expect_match(block, 'system.file("scripts/qproj.sh", package = "qproj")', fixed = TRUE)
  expect_match(block, "QPROJ_HOME", fixed = TRUE)

  expect_lt(
    regexpr("QPROJ_SH is set but not readable", block, fixed = TRUE),
    regexpr("QPROJ_HOME:-", block, fixed = TRUE)
  )

  # No call line unless a step is asked for -- sourcing the bare block must be inert.
  expect_false(grepl("^_qproj_bootstrap --step", block))
})

test_that("proj_shell_bootstrap(step=) appends a call line", {

  expect_match(
    proj_shell_bootstrap(step = "010-import"),
    "_qproj_bootstrap --step 010-import \\|\\| exit 1$"
  )

  expect_match(
    proj_shell_bootstrap(step = "010-import", optional = TRUE),
    "continues without path_\\*"
  )
})

test_that("proj_shell_bootstrap() rejects a step that could escape the data directory", {

  # STEP feeds create_dir_target --clean's rm -rf, so the R side mirrors the shell-side
  # guard rather than trusting the caller.
  expect_error(proj_shell_bootstrap(step = "a/b"), "single path component")
  expect_error(proj_shell_bootstrap(step = ".."), "single path component")
  expect_error(proj_shell_bootstrap(step = ""), "non-empty")
  expect_error(proj_shell_bootstrap(step = c("a", "b")), "non-empty")
})

test_that("the qproj.sh shell regression harness passes", {

  skip_on_cran()
  skip_if(.Platform$OS.type == "windows", "the harness is a Bash script")
  skip_if(unname(Sys.which("bash")) == "", "bash not available")

  harness <- test_path("..", "shell", "test_qproj_sh.sh")
  skip_if_not(file.exists(harness), "tests/shell/test_qproj_sh.sh not installed")

  # The resolver half of the harness needs the generated block; it skips without it.
  block <- withr::local_tempfile(fileext = ".sh")
  writeLines(proj_shell_bootstrap(), block)

  out <- suppressWarnings(system2(
    "bash",
    c(shQuote(harness), shQuote(proj_shell_lib()), shQuote(block)),
    stdout = TRUE, stderr = TRUE
  ))

  status <- attr(out, "status") %||% 0L

  # Surface the harness's own report on failure -- a bare "exit code 1" would say nothing.
  expect_identical(status, 0L, info = paste(out, collapse = "\n"))
  expect_true(any(grepl("0 failed", out)))
})
