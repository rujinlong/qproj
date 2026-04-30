{ # create a scope for the test file

  # be quiet and leave no footprints
  withr::local_options(list(usethis.quiet = TRUE))
  if (interactive()) usethis::local_project()
  tempdir <- withr::local_tempdir(tmpdir = fs::path(tempdir(), "qproj-create"))

  test_that("proj_create() works", {

    localdir <- fs::path(tempdir, "proj-01")

    # capture output
    expect_no_error(
      proj_create(path = localdir)
    )

    # DESCRIPTION exists
    expect_true(
      fs::file_exists(fs::path(localdir, "DESCRIPTION"))
    )

    # README.md exists
    expect_true(
      fs::file_exists(fs::path(localdir, "README.md"))
    )

    # NAMESPACE exists
    expect_true(
      fs::file_exists(fs::path(localdir, "NAMESPACE"))
    )

    # .gitignore exists
    expect_true(
      fs::file_exists(fs::path(localdir, ".gitignore"))
    )

  })

  test_that("proj_use_workflow() works", {

    localdir <- fs::path(tempdir, "proj-02")
    fs::dir_create(localdir)
    withr::local_dir(localdir)

    expect_no_error(
      proj_use_workflow(path_proj = "analyses")
    )

    expect_true(fs::dir_exists("analyses"))
    expect_true(fs::dir_exists("analyses/data"))
    expect_true(fs::file_exists("analyses/data/README.md"))
    expect_true(fs::file_exists("analyses/README.md"))
    expect_true(fs::file_exists("analyses/_quarto.yml"))
    expect_true(fs::file_exists(".gitignore"))

    quarto_yml <- yaml::read_yaml("analyses/_quarto.yml")
    expect_identical(quarto_yml$format$gfm, "default")

    gitignore_lines <- readLines(".gitignore")
    expect_true("analyses/data/*" %in% gitignore_lines)
    expect_true("!analyses/data/README.md" %in% gitignore_lines)

  })

  test_that("proj_create() applies fields and protects existing directories", {

    custom_path <- fs::path(tempdir, "proj-03")

    expect_no_error(
      proj_create(
        path = custom_path,
        fields = list(Title = "Custom Title", Version = "9.9.9")
      )
    )

    desc_obj <- desc::description$new(file = fs::path(custom_path, "DESCRIPTION"))
    expect_identical(desc_obj$get("Title")[[1]], "Custom Title")
    expect_identical(desc_obj$get("Version")[[1]], "9.9.9")

    occupied <- fs::path(tempdir, "proj-occupied")
    fs::dir_create(occupied)
    fs::file_create(fs::path(occupied, "existing.txt"))

    expect_error(
      proj_create(path = occupied),
      "already exists and is not empty"
    )

    expect_error(
      proj_create(fs::path(tempdir, "proj-04"), fields = list("not_named")),
      "`fields` must be a named list"
    )

    expect_false(fs::dir_exists(fs::path(tempdir, "proj-04")))

    file_path <- fs::path(tempdir, "proj-file")
    fs::file_create(file_path)

    expect_error(
      proj_create(path = file_path),
      "already exists and is not a directory"
    )

  })

}


