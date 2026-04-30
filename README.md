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
qproj::proj_create("myProject", fields = list(Title = "My Class Project"))

setwd("myProject")

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

## Common pitfall: re-run `params` + `setup` when you switch files

The `path_target`, `path_source`, `path_data`, `path_resource`, and
`path_raw` bindings are session-global variables created by each
`.qmd` file's `setup` chunk. They close over the current step's name
(`params$name`).

When you `quarto render <file>`, this just works — Quarto starts a
fresh R session for that file, runs `params` then `setup`, and every
subsequent chunk inherits the right bindings.

**In interactive RStudio sessions, every open `.qmd` shares the same R
global environment.** Whichever file's `setup` chunk you ran most
recently wins. Two failure modes are common:

- *Stale bindings (silent bug).* You switch from `01-import.qmd` to
  `02-clean.qmd` and run a code chunk **without** re-running
  `02-clean.qmd`'s `params` and `setup` chunks first. Your `path_*`
  bindings still point at `01-import`'s directories — reads and writes
  go to the wrong folder, and nothing complains.
- *Missing bindings (loud error).* No `setup` has been run yet in this
  session, so the very first chunk that uses `path_target` errors with
  `object 'params' not found`.

**Rule of thumb**: when you switch to a different `.qmd` to run code
interactively, run its `params` and `setup` chunks first.

Hygiene-based workarounds in your current IDE, from lightest to most
invasive:

1. `quarto render <file>` — fresh session, correct bindings, but
   produces a build artefact.
2. Restart R (RStudio: `Ctrl+Shift+F10` / `Cmd+Shift+0`) before working
   in a different `.qmd`.
3. One `.Rproj` per workflow, so `path_*` bindings cannot collide
   across unrelated work.

**Or remove the trap entirely**: switch to
[Positron](https://positron.posit.co/), Posit's next-generation IDE
(the spiritual successor to RStudio). Positron supports **multiple
isolated R sessions in one window** — you can attach a separate
session to each `.qmd`. Each session has its own global environment,
so `path_*` bindings from one file literally cannot leak into another.
The whole class of pitfalls above becomes structurally impossible — no
discipline required. See [this video
tutorial](https://www.youtube.com/watch?v=sItCFWvLDJQ) for the
multi-session workflow.

See `vignette("design-philosophy")` for the full reasoning behind
qproj's closure-based path bindings.

