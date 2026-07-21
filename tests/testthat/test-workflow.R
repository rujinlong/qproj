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

    test_that("use_manuscript() default lands the whole scaffold in analyses/manuscript/", {

      # The default path_proj is a SUB-directory of the analyses/ axis, and the three
      # pieces are written by two different mechanisms: usethis::use_template() resolves
      # `save_as` against the PROJECT ROOT, while fs::* are CWD-relative. Mixing them used
      # to split the scaffold apart, so assert all three land together.
      expect_no_error(use_manuscript("092-manuscript", open = FALSE))

      dir_ms <- fs::path(localdir, "analyses", "manuscript")
      expect_true(fs::dir_exists(dir_ms))
      for (f in c("092-manuscript.qmd", "title.tex", "_quarto.yml")) {
        expect_true(fs::file_exists(fs::path(dir_ms, f)), info = f)
      }

      # here::i_am() is declared relative to the analyses/ axis, so proj_path_*() keep
      # resolving to the SHARED analyses/data/ rather than collapsing to manuscript/data/.
      content <- readLines(fs::path(dir_ms, "092-manuscript.qmd"))
      expect_true(any(grepl('i_am("manuscript/092-manuscript.qmd"', content, fixed = TRUE)))

      # _quarto.yml isolates the manuscript as its own Quarto project root
      expect_true(any(grepl("^project:", readLines(fs::path(dir_ms, "_quarto.yml")))))
    })

    test_that("use_qmd()/use_manuscript() are CWD-independent (no stray directories)", {

      # Working from inside analyses/ is the normal qproj state. Before the fix,
      # fs::dir_create(path_proj) resolved against the CWD: use_qmd() silently created an
      # empty analyses/analyses/, and use_manuscript() failed outright because
      # use_template() then had no directory to write its qmd into.
      withr::local_dir(fs::path(localdir, "analyses"))

      expect_no_error(use_qmd("02-from-subdir", path_proj = "analyses", open = FALSE))
      expect_no_error(use_manuscript("093-manuscript", open = FALSE))

      expect_true(fs::file_exists(fs::path(localdir, "analyses", "02-from-subdir.qmd")))
      expect_true(
        fs::file_exists(fs::path(localdir, "analyses", "manuscript", "093-manuscript.qmd"))
      )

      # nothing was created one level too deep
      expect_false(fs::dir_exists(fs::path(localdir, "analyses", "analyses")))
    })

    test_that("proj_use_workflow()/proj_workflow_config() are CWD-independent too", {

      # Same defect class as above, in two sibling public APIs (Codex, 2026-07-21).
      withr::local_dir(fs::path(localdir, "analyses"))

      suppressMessages(proj_use_workflow("analyses"))
      expect_false(fs::dir_exists(fs::path(localdir, "analyses", "analyses")))
      # .gitignore belongs at the project root, not wherever the caller stood...
      expect_false(fs::file_exists(fs::path(localdir, "analyses", ".gitignore")))
      # ...while the RULE TEXT stays project-relative, because git resolves rules
      # relative to the file the rule lives in.
      expect_true(any(grepl("^analyses/data/\\*$", readLines(fs::path(localdir, ".gitignore")))))

      writeLines(c("render:", "  first: 01-a.qmd"),
                 fs::path(localdir, "analyses", "_qproj.yml"))
      # Returned NULL for a config that exists when called from inside analyses/.
      expect_false(is.null(proj_workflow_config("analyses")))
      # An absolute path must keep working: proj_path_source() passes here::here().
      expect_false(
        is.null(proj_workflow_config(as.character(fs::path(localdir, "analyses"))))
      )
      fs::file_delete(fs::path(localdir, "analyses", "_qproj.yml"))
    })

    test_that("path_proj cannot escape the project", {

      # usethis::proj_path() rejects absolute paths but NORMALISES "..", so
      # path_proj = "../outside" used to resolve outside the project and really wrote
      # files there (Codex, 2026-07-21).
      expect_error(
        use_qmd("01-escape", path_proj = "../outside", open = FALSE),
        "stay inside the project"
      )
      expect_error(
        use_manuscript("094-escape", path_proj = "../outside", open = FALSE),
        "stay inside the project"
      )
      expect_error(
        suppressMessages(proj_use_workflow("../outside")),
        "stay inside the project"
      )
      expect_false(fs::dir_exists(fs::path(localdir, "..", "outside")))

      # Absolute paths keep being rejected by usethis, with no directory left behind.
      expect_error(use_qmd("01-abs", path_proj = tempdir(), open = FALSE), "absolute")
    })

    test_that("detect_project_code / manuscript_default_name derive from project dir", {

      tmp <- withr::local_tempdir()

      proj <- fs::dir_create(fs::path(tmp, "p0101-BTEXvirome"))
      fs::file_create(fs::path(proj, "DESCRIPTION"))
      expect_equal(detect_project_code(proj), "p0101")
      expect_equal(manuscript_default_name(proj), "p0101-manuscript")

      # derivative project: the `e<n>` suffix stays in the code
      deriv <- fs::dir_create(fs::path(tmp, "p0075e2-CRCprophage"))
      fs::file_create(fs::path(deriv, "DESCRIPTION"))
      expect_equal(detect_project_code(deriv), "p0075e2")
      expect_equal(manuscript_default_name(deriv), "p0075e2-manuscript")

      # a sub-directory resolves up to the project root's DESCRIPTION
      sub <- fs::dir_create(fs::path(proj, "analyses", "manuscript"))
      expect_equal(detect_project_code(sub), "p0101")

      # no code-shaped prefix -> NA -> fall back to 090-manuscript
      generic <- fs::dir_create(fs::path(tmp, "my-analysis"))
      fs::file_create(fs::path(generic, "DESCRIPTION"))
      expect_true(is.na(detect_project_code(generic)))
      expect_equal(manuscript_default_name(generic), "090-manuscript")
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
