#' qproj: Lightweight Framework for Quarto Analysis Workflows
#'
#' A lightweight framework for Quarto-based analysis workflows.
#'
#' ## Setup functions
#'
#' - [proj_create()]: Create a new analysis project.
#' - [proj_use_workflow()]: Set up an `analyses/` workflow directory.
#' - [use_qmd()]: Create a new `.qmd` analysis file from template.
#'
#' ## Path helpers (use inside `.qmd` files)
#'
#' - [proj_create_dir_target()]: Create the target data directory for a `.qmd` file.
#' - [proj_path_target()]: Returns a path-generating function for the target directory.
#' - [proj_path_source()]: Returns a path-generating function for a source directory.
#' - [proj_dir_info()]: List files in a directory with metadata.
#'
#' ## Dependency management
#'
#' - [proj_check_deps()]: Check for missing/extra dependencies in DESCRIPTION.
#' - [proj_update_deps()]: Update DESCRIPTION with detected dependencies.
#' - [proj_install_deps()]: Install all dependencies from DESCRIPTION via pak.
#'
"_PACKAGE"
