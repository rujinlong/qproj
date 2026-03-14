test_that("sort_files works", {

  files_sorted <- c("00-import.qmd", "01-clean.qmd", "zoom.qmd", "README.qmd")

   expect_identical(
     sort_files(files_sorted, first = NULL, last = NULL),
     files_sorted
   )

   expect_identical(
     sort_files(rev(files_sorted), first = NULL, last = NULL),
     files_sorted
   )

   expect_identical(
     sort_files(tolower(files_sorted), first = NULL, last = NULL),
     tolower(files_sorted)
   )

   files_sorted_zoom_first <- c("zoom.qmd", "00-import.qmd", "01-clean.qmd", "README.qmd")
   expect_identical(
      sort_files(files_sorted, first = "zoom.qmd", last = NULL),
      files_sorted_zoom_first
   )

   files_sorted_00_last <- c("01-clean.qmd", "zoom.qmd", "00-import.qmd", "README.qmd")
   expect_identical(
      sort_files(files_sorted, first = NULL, last = "00-import.qmd"),
      files_sorted_00_last
   )

})

test_that("print utilities work", {

   expect_no_error(pui_done("wooo!"))
   expect_no_error(pui_info("so, ..."))
   expect_no_error(pui_oops("well, ..."))
   expect_no_error(pui_todo("next, ..."))

})
