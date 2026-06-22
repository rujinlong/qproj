{ # create a scope for the test file

  testthat_dir <- getwd()

  # leave no footprints
  withr::local_options(list(usethis.quiet = TRUE))
  if (interactive()) usethis::local_project(quiet = TRUE)
  tempdir <-
    withr::local_tempdir(tmpdir = fs::path(tempdir(), "qproj-workflow"))

  { # create scope for tests

    # create project for tests
    localdir <- fs::path(tempdir, "proj01")
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
        use_qmd("01-import", path_proj = "analyses", open = FALSE)
      )

      # check that the file is there
      expect_true(
        fs::file_exists(
          fs::path(localdir, "analyses", "01-import.qmd")
        )
      )

      # check qproj:: references in the template
      content <- readLines(fs::path(localdir, "analyses", "01-import.qmd"))
      expect_true(any(grepl("qproj::", content)))
      expect_false(any(grepl("projthis::", content)))

      # 00- prefix is reserved for framework input region; users start at 01-
      expect_error(
        use_qmd("00-foo", path_proj = "analyses", open = FALSE),
        "reserved.*00-"
      )

    })

    test_that("use_manuscript() scaffolds qmd + title.tex", {

      expect_no_error(
        use_manuscript("090-manuscript", path_proj = "analyses", open = FALSE)
      )

      qmd <- fs::path(localdir, "analyses", "090-manuscript.qmd")
      tex <- fs::path(localdir, "analyses", "title.tex")
      expect_true(fs::file_exists(qmd))
      expect_true(fs::file_exists(tex))

      # dual-format Quarto-canonical YAML with the author-block recipe
      content <- readLines(qmd)
      expect_true(any(grepl("template-partials", content)))
      expect_true(any(grepl("authblk", content)))
      expect_true(any(grepl("reference-doc", content)))
      expect_true(any(grepl("keep-tex", content)))
      # whisker substitution happened
      expect_true(any(grepl('name: "090-manuscript"', content, fixed = TRUE)))

      # title.tex partial is the verbatim pandoc-template (not whisker-mangled)
      tex_content <- readLines(tex)
      expect_true(any(grepl("\\affil", tex_content, fixed = TRUE)))

      # idempotent on title.tex: a second call must not clobber it
      writeLines(c(tex_content, "% sentinel"), tex)
      expect_no_error(
        use_manuscript("091-manuscript", path_proj = "analyses", open = FALSE)
      )
      expect_true(any(grepl("% sentinel", readLines(tex), fixed = TRUE)))

      # sub-directory names are rejected
      expect_error(
        use_manuscript("foo/bar", path_proj = "analyses", open = FALSE),
        "you cannot specify a sub-directory"
      )
    })

    test_that("proj_workflow_config() returns NULL when _qproj.yml absent", {

      # at this point analyses/ has no _qproj.yml yet
      expect_null(proj_workflow_config(fs::path(localdir, "analyses")))

    })

    test_that("proj_workflow_config() works", {

      fs::file_copy(
        fs::path(testthat_dir, "..", "sample_code", "_qproj.yml"),
        fs::path(localdir, "analyses", "_qproj.yml")
      )

      expect_true(
        fs::file_exists(fs::path(localdir, "analyses", "_qproj.yml"))
      )

      # config file has a specific order
      config <- proj_workflow_config(fs::path(localdir, "analyses"))

      expect_identical(
        config,
        list(render = list(first = "01-import.qmd", last = "README.qmd"))
      )

      expect_no_message(proj_workflow_config(fs::path(localdir, "analyses")))

    })

  }

}
