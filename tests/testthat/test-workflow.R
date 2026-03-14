{ # create a scope for the test file

  testthat_dir <- getwd()

  # leave no footprints
  withr::local_options(list(usethis.quiet = TRUE))
  if (interactive()) usethis::local_project(quiet = TRUE)
  tempdir <-
    withr::local_tempdir(tmpdir = fs::path(tempdir(), "qproj-workflow"))

  { # create scope for tests

    # create project for tests
    localdir <- fs::path(tempdir, "proj-01")
    proj_create(path = localdir)

    # change to project directory
    usethis::local_project(localdir)

    # create workflow directory
    suppressMessages(
      proj_use_workflow("analyses")
    )

    test_that("use_qmd() works", {

      # name cannot contain a subdirectory
      expect_error(
        use_qmd("foo/bar"),
        "you cannot specify a sub-directory to `path_proj`"
      )

      # we create a Quarto file, and it is where we expect
      expect_no_error(
        use_qmd("00-import", path_proj = "analyses", open = FALSE)
      )

      # check that the file is there
      expect_true(
        fs::file_exists(
          fs::path(localdir, "analyses", "00-import.qmd")
        )
      )

      # check qproj:: references in the template
      content <- readLines(fs::path(localdir, "analyses", "00-import.qmd"))
      expect_true(any(grepl("qproj::", content)))
      expect_false(any(grepl("projthis::", content)))

    })

    test_that("proj_workflow_config() works", {

      fs::file_copy(
        fs::path(testthat_dir, "..", "sample_code", "_projthis.yml"),
        fs::path(localdir, "analyses", "_projthis.yml")
      )

      expect_true(
        fs::file_exists(fs::path(localdir, "analyses", "_projthis.yml"))
      )

      # config file has a specific order
      config <- proj_workflow_config(fs::path(localdir, "analyses"))

      expect_identical(
        config,
        list(render = list(first = "00-import.Rmd", last = "README.Rmd"))
      )

    })

  }

}
