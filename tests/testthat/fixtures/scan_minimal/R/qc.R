#' Filter sequences by a quality threshold.
qc_filter <- function(x, threshold = 0.05, method = "median") {
  x[x > threshold]
}

#' Normalize a numeric vector by a chosen method.
qc_norm <- function(x, method = "median") {
  if (method == "median") x / stats::median(x) else x / mean(x)
}

#' Helper that no .qmd actually calls -- should appear as `unused = TRUE`.
qc_unused <- function(x) {
  identity(x)
}
