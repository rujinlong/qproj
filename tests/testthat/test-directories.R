{ # create a scope for the test file

  # be quiet and leave no footprints
  withr::local_options(list(usethis.quiet = TRUE))
  if (interactive()) usethis::local_project()
  tempdir <-
    withr::local_tempdir(tmpdir = fs::path(tempdir(), "qproj-directories"))

  { # create scope for tests

    # create project for tests
    projdir <- fs::path(tempdir, "proj01")
    proj_create(path = projdir)

    # change to project directory
    usethis::local_project(projdir)

    # create workflow
    name_workflow <- "analyses"
    suppressMessages(
      proj_use_workflow(name_workflow)
    )

    # change to workflow directory
    workdir <- fs::path(projdir, name_workflow)
    withr::local_dir(workdir)

    # create qmd file (creates the file but we set up here manually)
    name_rmd <- "01-clean"
    suppressMessages(
      use_qmd(name_rmd, path_proj = name_workflow, open = FALSE)
    )

    # establish here
    suppressMessages(
      here::i_am(glue::glue("{name_rmd}.qmd"))
    )

    is_dir_empty <- function(path) {
      identical(length(fs::dir_ls(path)), 0L)
    }

    dir_target <- fs::path(workdir, "data", name_rmd)

    test_that("proj_create_dir_target() works", {

      proj_create_dir_target(name_rmd, clean = TRUE)
      expect_true(fs::dir_exists(dir_target))
      expect_true(is_dir_empty(dir_target))

      # write temporary file to target
      writeLines("foo", fs::path(dir_target, "temp.txt"))

      proj_create_dir_target(name_rmd, clean = FALSE)
      expect_true(fs::dir_exists(dir_target))
      expect_true(!is_dir_empty(dir_target))

      proj_create_dir_target(name_rmd, clean = TRUE)
      expect_true(fs::dir_exists(dir_target))
      expect_true(is_dir_empty(dir_target))

    })

    test_that("proj_path_target() works", {

      path_target <- proj_path_target(name_rmd)

      expect_target <- function(...) {
        expect_identical(
          path_target(...),
          do.call(here::here, list("data", name_rmd, ...))
        )
      }

      expect_target("foo")

    })

    test_that("proj_path_source() works", {

      path_source <- proj_path_source(name_rmd)

      expect_source <- function(...) {
        expect_identical(
          path_source(...),
          do.call(here::here, list("data", ...))
        )
      }

      # forward read produces a warning whose text identifies the offender
      expect_warning(
        expect_source("02-plot", "temp.csv"),
        "is not previous to"
      )

      expect_source("00-import", "temp.csv")

      # no-arg call is a hard error
      expect_error(
        path_source(),
        "needs the upstream step name"
      )

      # single-arg with a file extension is a likely-mistake warning
      # (it also fires the forward-read warning since "raw.csv" sorts after the
      # current step name; check both, in the order they're emitted)
      expect_warning(
        expect_warning(
          path_source("raw.csv"),
          "looks like a file name"
        ),
        "is not previous to"
      )

    })

    test_that("proj_dir_info() honours custom timezone", {

      df <- proj_dir_info(".", tz = "Asia/Shanghai")
      expect_identical(attr(df$modification_time, "tzone"), "Asia/Shanghai")

    })

    test_that("proj_dir_info() works", {

      # expecting workflow directory - only path and type are constant
      # across platforms.

      # we also have to specify the order because Windows - aaaaaaaaaugh
      df <- proj_dir_info(".", cols = c("path", "type"))
      df_by_path <- df[order(df$path), ]

      expect_snapshot(df_by_path)

    })

  }

}
