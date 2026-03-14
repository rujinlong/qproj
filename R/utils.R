#' @importFrom rlang `%||%`
NULL

# sort files:
#  - remove anything starting with an underscore
#  - reserve README until end
#  - get first and last files
#  - sort remainder
#  - assemble unique set
#
sort_files <- function(files, first, last) {

  # return sorted, put README at the end

  # logical, length of files
  is_readme <- grepl("^readme\\.qmd$", files, ignore.case = TRUE)
  starts_with_underscore <- grepl("^_.*\\.qmd$", files, ignore.case = TRUE)
  is_first <- files %in% first
  is_last <- files %in% last

  files_first <- files[is_first]
  files_last <- files[is_last]
  files_readme <- files[is_readme]
  files_remainder <- sort(files[!(is_first | is_last | is_readme)])

  unique(c(files_first, files_remainder, files_last, files_readme))
}

pui_done <- function(x) cli::cli_alert_success(x)
pui_info  <- function(x) cli::cli_alert_info(x)
pui_oops  <- function(x) cli::cli_alert_danger(x)
pui_todo  <- function(x) cli::cli_alert_warning(x)
