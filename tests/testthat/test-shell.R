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
  expect_match(block, "qproj-bootstrap v2", fixed = TRUE)
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
    "_qproj_bootstrap --step '010-import' \\|\\| exit 1$"
  )

  expect_match(
    proj_shell_bootstrap(step = "010-import", optional = TRUE),
    "continues without path_\\*"
  )
})

test_that("proj_shell_bootstrap() rejects a step that could escape the data directory", {

  # STEP feeds create_dir_target --clean's rm -rf.
  expect_error(proj_shell_bootstrap(step = "a/b"), "plain step id")
  expect_error(proj_shell_bootstrap(step = ".."), "plain step id")
  expect_error(proj_shell_bootstrap(step = ""), "non-empty")
  expect_error(proj_shell_bootstrap(step = c("a", "b")), "non-empty")

  # nzchar(NA_character_) is TRUE, so an NA slips past a naive emptiness check and would
  # render as the literal string "NA" (Codex review, 2026-07-21).
  expect_error(proj_shell_bootstrap(step = NA_character_), "non-empty")
})

test_that("proj_shell_bootstrap() cannot be made to emit extra shell statements", {

  # The step is pasted into generated Bash. Without a guard, `a; echo PWNED` emitted
  # `_qproj_bootstrap --step a; echo PWNED || exit 1` -- two statements (Codex, 2026-07-21).
  for (bad in c("a; echo PWNED", "a b", "a$(id)", "a`id`", "a\nb", "a'b", 'a"b', "-a", ".a/b")) {
    expect_error(proj_shell_bootstrap(step = bad), "plain step id", info = bad)
  }

  # A legal step is still single-quoted, so the call line stays one argument.
  expect_match(
    proj_shell_bootstrap(step = "010-import"),
    "--step '010-import'", fixed = TRUE
  )
})

test_that("the emitted resolver survives an unset HOME under set -u", {

  skip_if(.Platform$OS.type == "windows", "the block is Bash")
  skip_if(unname(Sys.which("bash")) == "", "bash not available")

  # `sbatch --export=NIL` drops HOME. A bare $HOME under `set -euo pipefail` aborted the
  # whole driver instead of reaching the resolver's own error path (Codex, 2026-07-21).
  block <- withr::local_tempfile(fileext = ".sh")
  writeLines(proj_shell_bootstrap(), block)

  out <- suppressWarnings(system2(
    "env",
    c("-u", "HOME", "-u", "QPROJ_SH", "-u", "QPROJ_HOME", "bash", "-c",
      shQuote(paste0(
        "set -euo pipefail; . ", shQuote(block),
        "; PATH=/nonexistent; _qproj_bootstrap --step s || printf handled; printf ' after'"
      ))),
    stdout = TRUE, stderr = TRUE
  ))

  expect_false(any(grepl("unbound variable", out)), info = paste(out, collapse = "\n"))
  expect_true(any(grepl("handled after", out)), info = paste(out, collapse = "\n"))
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
