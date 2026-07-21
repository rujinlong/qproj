# Tests for R/vpipe_lock.R -- writing, resolving and verifying a vpipe pin.
#
# Most of these assert on refusals. A resolver that guesses does not announce itself: the
# job runs, produces plausible output, and nobody learns it used the wrong vpipe. So the
# behaviour worth protecting is that every ambiguous input becomes an error.
#
# The tests that need a materialised release or the vpipe CLI skip when it is absent, so
# this file stays runnable on a machine that has qproj but not vpipe.

# --- a lock written by hand in exactly the shape the writer emits -------------------

fake_lock_fields <- function(release_path = "/store/0.9.0+abcdef1") {
  list(
    resolved_version = "0.9.0",
    git_commit       = strrep("a", 40),
    release_path     = release_path,
    requires         = ">=0.9,<1.0",
    bom_digest       = "sha256:beef",
    tree_digest      = "sha256:f00d",
    env_digest       = "sha256:cafe",
    shell_api        = 1,
    nf_api           = 1,
    python_api       = 1,
    pinned_at        = "2026-07-21T12:00:00+0200",
    pinned_by        = "qproj 0.1.5"
  )
}

write_fake_lock <- function(dir, release_path = "/store/0.9.0+abcdef1") {
  path <- fs::path(dir, "vpipe.lock")
  writeLines(vpipe_lock_text(fake_lock_fields(release_path)), path)
  path
}

fake_release <- function(dir) {
  release <- fs::path(dir, "store", "0.9.0+abcdef1")
  fs::dir_create(fs::path(release, "bin"))
  fs::file_create(fs::path(release, "bin", "00-config.sh"))
  release
}


test_that("the default compatibility range matches the documented shape", {
  expect_equal(as.character(vpipe_default_requires("0.9.0")), ">=0.9,<1.0")
  expect_equal(as.character(vpipe_default_requires("1.4.2")), ">=1.4,<2.0")
  expect_equal(as.character(vpipe_default_requires("0.10.0")), ">=0.10,<1.0")
})

test_that("an unparseable version is refused rather than turned into a wrong range", {
  expect_error(vpipe_default_requires("nightly"), "Cannot derive")
  expect_error(vpipe_default_requires("9"), "Cannot derive")
})


test_that("the writer emits the frozen scalar form the Bash resolver requires", {
  text <- vpipe_lock_text(fake_lock_fields())

  # Top-level, double-quoted, exactly one line each -- the spec the grep-based reader
  # depends on. yaml::as.yaml() would emit these unquoted and silently break it, which is
  # why the writer is a template.
  for (key in c("resolved_version", "git_commit", "release_path")) {
    hits <- grep(paste0("^", key, ": \""), text, value = TRUE)
    expect_length(hits, 1)
    expect_match(hits, paste0("^", key, ': "[^"]*"$'))
  }

  # The API versions are plain integers, not strings: a consumer comparing them to a
  # number must not have to know they were quoted.
  expect_true(any(text == "shell_api: 1"))
})

test_that("what the writer emits parses back as YAML with the same values", {
  dir <- withr::local_tempdir()
  fields <- fake_lock_fields()
  path <- fs::path(dir, "vpipe.lock")
  writeLines(vpipe_lock_text(fields), path)

  parsed <- yaml::read_yaml(path)
  for (key in names(fields)) {
    expect_equal(as.character(parsed[[key]]), as.character(fields[[key]]), info = key)
  }
  expect_equal(parsed$lock_version, 1)
})

test_that("the round-trip check catches a lock that does not say what was intended", {
  dir <- withr::local_tempdir()
  fields <- fake_lock_fields()
  path <- fs::path(dir, "vpipe.lock")
  writeLines(vpipe_lock_text(fields), path)

  expect_true(vpipe_lock_verify_roundtrip(path, fields))

  # Simulate a template that wrote the wrong value: the check must not pass it.
  tampered <- fields
  tampered$git_commit <- strrep("b", 40)
  expect_error(vpipe_lock_verify_roundtrip(path, tampered), "does not read back")
})

test_that("the round-trip check rejects output that is not valid YAML", {
  dir <- withr::local_tempdir()
  path <- fs::path(dir, "vpipe.lock")
  writeLines(c("resolved_version: \"0.9.0\"", "  bad: [unclosed"), path)
  expect_error(vpipe_lock_verify_roundtrip(path, fake_lock_fields()), "not valid YAML")
})


test_that("a relative lock path cannot escape the project", {
  dir <- withr::local_tempdir()
  fs::file_create(fs::path(dir, "DESCRIPTION"))
  withr::local_options(usethis.quiet = TRUE)
  usethis::proj_set(dir, force = TRUE)

  # `..` is normalised rather than rejected by both fs and usethis, so containment has to
  # be re-checked afterwards -- this is the bug that let path_proj="../outside" write
  # outside the project in the sibling APIs.
  expect_error(vpipe_lock_path("../outside/vpipe.lock", strict = TRUE), "inside the project")
  expect_error(vpipe_lock_path("/tmp/abs.lock", strict = TRUE), NA)
})

test_that("an absolute lock path is honoured (drivers resolve their own)", {
  expect_equal(
    as.character(vpipe_lock_path("/store/x/vpipe.lock", strict = FALSE)),
    "/store/x/vpipe.lock"
  )
})


test_that("resolving without a lock is an error, never a fallback", {
  dir <- withr::local_tempdir()
  expect_error(
    proj_vpipe_resolve(fs::path(dir, "vpipe.lock")),
    "has not pinned vpipe"
  )
})

test_that("resolving a lock with no release_path is an error", {
  dir <- withr::local_tempdir()
  path <- fs::path(dir, "vpipe.lock")
  writeLines(c("lock_version: 1", "resolved_version: \"0.9.0\""), path)
  expect_error(proj_vpipe_resolve(path), "no.*release_path")
})

test_that("resolving to an absent or incomplete release names the login-node fix", {
  dir <- withr::local_tempdir()

  path <- write_fake_lock(dir, release_path = fs::path(dir, "store", "absent"))
  expect_error(proj_vpipe_resolve(path), "read-only\\s+on\\s+compute nodes")

  fs::dir_create(fs::path(dir, "store", "empty"))
  path <- write_fake_lock(dir, release_path = fs::path(dir, "store", "empty"))
  expect_error(proj_vpipe_resolve(path), "not present or is incomplete")
})

test_that("resolving a complete release returns its path", {
  dir <- withr::local_tempdir()
  release <- fake_release(dir)
  path <- write_fake_lock(dir, release_path = release)
  expect_equal(as.character(proj_vpipe_resolve(path)), as.character(release))
})


test_that("a missing vpipe CLI is reported rather than assumed", {
  withr::local_envvar(VPIPE_CLI = "/nonexistent/vpipe")
  expect_error(vpipe_bin(), "set but does not exist")
})

test_that("pinning refuses a checkout that is not there", {
  dir <- withr::local_tempdir()
  fs::file_create(fs::path(dir, "DESCRIPTION"))
  withr::local_options(usethis.quiet = TRUE)
  usethis::proj_set(dir, force = TRUE)
  skip_if(!nzchar(Sys.which("vpipe")), "vpipe CLI not on PATH")

  expect_error(
    proj_vpipe_pin(vpipe_repo = fs::path(dir, "no-such-checkout")),
    "No vpipe checkout"
  )
})


test_that("Bash reads back exactly what R wrote (cross-parser round trip)", {
  # The mitigation the lock format spec (§4) requires in exchange for letting the Bash
  # resolver parse YAML with an anchored grep. Three parsers read this file -- R here,
  # Bash in qproj.sh, Python in `vpipe contract check` -- and nothing but a test like this
  # would notice them drifting apart.
  skip_on_os("windows")
  lib <- system.file("scripts", "qproj.sh", package = "qproj")
  if (!nzchar(lib) || !file.exists(lib)) {
    lib <- testthat::test_path("..", "..", "inst", "scripts", "qproj.sh")
  }
  skip_if(!file.exists(lib), "qproj.sh not found")

  dir <- withr::local_tempdir()
  release <- fake_release(dir)
  lock <- write_fake_lock(dir, release_path = release)
  fields <- fake_lock_fields(release_path = release)

  snippet <- paste0(
    "set -uo pipefail; . '", lib, "'; export QPROJ_VPIPE_LOCK='", lock, "'; ",
    "printf '%s\\n' \"$(qproj_vpipe_root)\" ",
    "\"$(_qproj_lock_field \"$QPROJ_VPIPE_LOCK\" resolved_version)\" ",
    "\"$(_qproj_lock_field \"$QPROJ_VPIPE_LOCK\" git_commit)\""
  )
  out <- suppressWarnings(system2("bash", c("-c", shQuote(snippet)), stdout = TRUE, stderr = FALSE))

  expect_equal(out[1], as.character(fields$release_path))
  expect_equal(out[2], as.character(fields$resolved_version))
  expect_equal(out[3], as.character(fields$git_commit))

  # And the R parser agrees with both.
  parsed <- yaml::read_yaml(lock)
  expect_equal(parsed$release_path, out[1])
  expect_equal(parsed$git_commit, out[3])
})
