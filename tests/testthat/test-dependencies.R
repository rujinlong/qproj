{ # create a scope for the test file

  testthat_dir <- getwd()

  # be quiet and leave no footprints
  withr::local_options(list(usethis.quiet = TRUE))
  if (interactive()) usethis::local_project()
  tempdir <- withr::local_tempdir(tmpdir = fs::path(tempdir(), "qproj-deps"))

  { # create another scope for the project

    # create project
    suppressMessages({
      usethis::create_project(tempdir, rstudio = FALSE, open = FALSE)
      usethis::local_project(tempdir)
    })

    # create a description file
    usethis::use_description(check_name = FALSE)

    # add a dependency
    usethis::use_package("desc")

    fs::file_copy(
      fs::path(testthat_dir, "..", "sample_code", "sample.qmd"),
      "."
    )

    test_that("renv returns what we expect", {
      suppressMessages(
        expect_true(
          "Package" %in% names(renv::dependencies(dev = TRUE))
        )
      )

    })

    test_that("check_deps works", {

      result <- check_deps()
      expect_equal(sort(result$missing), c("renv", "rmarkdown"))
      expect_equal(result$extra, "desc")

    })

    test_that("proj_check_deps works", {

      result <- proj_check_deps()
      expect_true(is.list(result))
      expect_true("missing" %in% names(result))
      expect_true("extra" %in% names(result))
      expect_equal(sort(result$missing), c("renv", "rmarkdown"))
      expect_equal(result$extra, "desc")

    })

    test_that("update_check_deps works", {

      # update dependencies, don't remove extra dependencies
      expect_no_error(proj_update_deps())

      # update dependencies, do remove extra dependencies
      expect_no_error(proj_update_deps(remove_extra = TRUE))

      # ensure nothing missing or extra
      expect_identical(
        check_deps(),
        list(missing = character(0), extra = character(0))
      )

      # make sure output works (nothing missing or extra)
      result <- proj_check_deps()
      expect_equal(result$missing, character(0))
      expect_equal(result$extra, character(0))

    })

  }

}
