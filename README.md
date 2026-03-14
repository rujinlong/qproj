# qproj

qproj is a lightweight framework for Quarto-based analysis workflows.
It helps you:

- keep each `.qmd` file writing to its own data directory with helpers
  like `proj_create_dir_target()`, `proj_path_target()`, and
  `proj_path_source()`;
- create workflow scaffolding with `proj_create()` and
  `proj_use_workflow()`;
- manage dependencies declared in `DESCRIPTION` with
  `proj_check_deps()` and `proj_install_deps()`.

## Installation

Install the development version from GitHub:

``` r
# install.packages("pak")
pak::pak("rujinlong/qproj")
```

## Create a class-ready repository

If you want to publish a fresh qproj-based repository for students to
clone, start with these commands in a clean directory:

``` r
# 1. Create the project scaffold (fills DESCRIPTION/NAMESPACE/README/.gitignore)
qproj::proj_create("my-class-project", fields = list(Title = "My Class Project"))

setwd("my-class-project")

# 2. Add a workflow directory and a first analysis file
qproj::proj_use_workflow("analyses")
qproj::use_qmd("00-import", path_proj = "analyses", open = FALSE)

# 3. Add more steps as needed
qproj::use_qmd("01-clean", path_proj = "analyses", open = FALSE)
```

Each `.qmd` created from the template writes to its own
`analyses/data/<name>` directory and can read from earlier steps via
`proj_path_source()`.

To share with students:

1. Initialize git and push the project to GitHub (e.g.
   `usethis::use_git()` then `usethis::use_github()`).
2. Mark the repository as a template on GitHub.
3. Students can click **Use this template** or run
   `usethis::create_from_github("your-org/my-class-project")` to get
   their own copy. They can immediately edit the `.qmd` files and render
   them with Quarto.

