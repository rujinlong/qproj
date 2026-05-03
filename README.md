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

For users who collaborate with AI coding assistants on qproj projects,
`proj_scan_graph()` exports a static dependency graph for AI consumption.
See [Advanced usage](#advanced-usage-knowledge-graph-for-ai-assistants)
below — an opt-in advanced feature.

## Installation

Install the development version from GitHub:

``` r
# install.packages("pak")
pak::pak("rujinlong/qproj")
```

## Create a class-ready repository

If you want to publish a fresh qproj-based repository for students to
clone, start with these commands in a clean directory:

Numeric prefixes determine render order. The `00-` prefix is
reserved for the framework's `data/00-raw/` input region — start your
own steps at `01-` or higher. See `vignette("design-philosophy")` for
the full rationale.

``` r
# 1. Create the project scaffold (fills DESCRIPTION/NAMESPACE/README/.gitignore)
qproj::proj_create("myProject", fields = list(Title = "My Class Project"))

setwd("myProject")

# 2. Add a workflow directory (also drops in `_quarto.yml`) and a first analysis file
qproj::proj_use_workflow("analyses")
qproj::use_qmd("01-import", path_proj = "analyses", open = FALSE)

# 3. Add more steps as needed
qproj::use_qmd("02-clean", path_proj = "analyses", open = FALSE)
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

## Advanced usage: knowledge graph for AI assistants

`proj_scan_graph()` statically scans an entire qproj workflow and emits
a compact dependency graph for AI coding assistants (Claude Code,
Gemini CLI, etc.) to consume in a single read — typically saving
50,000+ tokens per session on a 10-step workflow vs. reading every
`.qmd` file.

This is an **opt-in advanced feature**; ordinary users pay nothing for
it (no extra hard dependencies, no extra files generated).

### One-line use

From the project root:

``` r
qproj::proj_scan_graph()
```

This writes three files into `.qproj/graph/`:

| File | Reader | Purpose |
|------|--------|---------|
| `qproj-graph.json` | AI assistants | Full graph: nodes, edges, evidence, warnings |
| `QPROJ_GRAPH_REPORT.md` | AI assistants (entry point) | < 2 KB navigation summary, read first |
| `qproj-graph.html` | Humans | Self-contained interactive `visNetwork` view |

### What the scanner detects

Three layers, all on by default. Each layer can be turned off via the
`scan` argument.

#### Step layer — `.qmd` ↔ `.qmd` file dependencies

| Source pattern | Recorded as |
|---|---|
| `path_source("01-import", "x.csv")` | `reads_from` edge, `EXTRACTED` |
| `path_source(prev_step, ...)` (variable) | `reads_from` edge, `AMBIGUOUS` + warning |
| `path_target("clean.csv")` | declared output |
| `here::here(path_raw, "d01-import", ...)` from another step | `bypass_access` edge + anti-pattern warning |
| `library(pkg)` and `pkg::fn` | step's R package dependencies |

#### R layer — `.qmd` → `R/*.R` function dependencies

Every `.qmd` setup chunk runs `devtools::load_all()`, silently exposing
**every** `R/*.R` function. The R layer surfaces which subset is
actually used, with literal scalar arguments captured.

| Source pattern | Recorded as |
|---|---|
| `qc_filter(threshold = 0.05)` (defined in `R/qc.R`) | `uses_function` edge to `fn:qc_filter`; `args_captured = {threshold: 0.05}` |
| `<your-pkg>::qc_filter(...)` | same as above |
| `R/qc.R` defines `qc_helper()` but no `.qmd` calls it | `unused = TRUE` on the `fn:qc_helper` node — exposes dead code |

#### DB layer — DBI/SQLite table dependencies

Cross-`.qmd` table sharing through SQLite (or any DBI back-end). The
file-level `path_source` view sees only "they share the same `.sqlite`
file"; the DB layer goes one level deeper and tracks **which tables**
each step writes vs. reads.

| Source pattern | Recorded as |
|---|---|
| `DBI::dbWriteTable(con, "raw_seqs", df)` | `writes_table` edge to `tbl:raw_seqs`, `EXTRACTED` |
| `DBI::dbReadTable(con, "raw_seqs")` / `dplyr::tbl(con, "raw_seqs")` | `reads_table` edge from `tbl:raw_seqs`, `EXTRACTED` |
| `DBI::dbGetQuery(con, "SELECT * FROM raw_seqs JOIN ref_lookup ...")` | both `raw_seqs` and `ref_lookup` recorded as reads, `INFERRED` (regex) |
| `DBI::dbExecute(con, "INSERT INTO audit_log VALUES (?)")` | `audit_log` recorded as write, `INFERRED` |
| `con <- DBI::dbConnect(SQLite(), path_target("db.sqlite"))` | binds `con` → `<step>/db.sqlite`; every later DBI call in the `.qmd` is tagged with that `db_file` |

SQL is **not** parsed at the column level. Only table names are
extracted, via regex on `FROM` / `JOIN` / `INSERT INTO` / `UPDATE` /
`DELETE FROM` / `CREATE TABLE` / `DROP TABLE`. Non-literal SQL or
non-literal table names emit an `AMBIGUOUS_*` warning rather than
silently being missed.

The scan is purely static — no `.qmd` is rendered, no R code runs.
`knitr::purl()` extracts the R code, then `base::parse()` walks the
AST, so commented-out code and string-literal mentions are correctly
ignored.

### Common invocations

``` r
# Default: all three layers, all three artifacts
qproj::proj_scan_graph()

# Skip the HTML viewer (no visNetwork required)
qproj::proj_scan_graph(formats = c("json", "md"))

# Reproduce the v1 step-only graph (skip R and DB layers)
qproj::proj_scan_graph(scan = "step")

# Custom output location (relative to project root, or absolute)
qproj::proj_scan_graph(output_dir = "docs/graph")

# Different R/ source directory
qproj::proj_scan_graph(r_dir = "src/R")

# Quiet mode for CI / Makefile targets
qproj::proj_scan_graph(quiet = TRUE)
```

### HTML viewer

The interactive `qproj-graph.html` shows all three node types together:

- **steps** as boxes (blue / green for entry / orange when bypass detected)
- **functions** as ellipses (purple, grey when `unused = TRUE`)
- **tables** as diamonds (teal)

Edges are color-coded by type: blue = `reads_from`, red dashed =
`bypass_access`, purple = `uses_function`, red = `writes_table`, teal =
`reads_table`.

The viewer ships with a built-in `selectedBy` dropdown (top-right) so
you can hide all functions or all tables to declutter when the graph
gets dense. Click any node to highlight its 1-hop neighbors; hover for
full metadata (file path, callers, `db_file`, etc.).

### Output structure and `.gitignore`

```
<project_root>/
  .qproj/
    graph/
      qproj-graph.json          ← commit (small, team-shared AI context)
      QPROJ_GRAPH_REPORT.md     ← commit (small, AI navigation entry)
      qg                        ← commit (executable, ~10 KB query CLI)
      qproj-graph.html          ← optional — large (~800 KB), regeneratable
```

Suggested `.gitignore` snippet:

```
.qproj/graph/qproj-graph.html
```

### `qg` — graph query CLI

Generated alongside the JSON, `qg` is a self-contained `bash` + `jq`
wrapper that lets you (and your AI assistant) ask dependency questions
without reading the full JSON. Only dependency: `jq` (`brew install jq`
on macOS, `apt install jq` on Debian).

```bash
bash .qproj/graph/qg --help              # full subcommand manual

# Discovery
bash .qproj/graph/qg list step           # list all step ids
bash .qproj/graph/qg node 02-clean       # node metadata + neighbours

# Tracing (use BEFORE any structural change)
bash .qproj/graph/qg upstream 02-clean   # direct incoming edges
bash .qproj/graph/qg downstream 02-clean # direct outgoing edges
bash .qproj/graph/qg deps 02-clean       # transitive ancestry
bash .qproj/graph/qg impact 02-clean     # transitive blast radius
bash .qproj/graph/qg paths 01 03         # all paths from 01 to 03

# Cleanup (use BEFORE submission / archiving)
bash .qproj/graph/qg unused              # dead functions + orphan tables
bash .qproj/graph/qg bypass              # bypass_access anti-pattern
bash .qproj/graph/qg stale --days 90     # archive candidates (no commits + no readers)
```

Default output is one fact per line (greppable, pipe-friendly). Add
`--human` for readable tables, `--json` for raw JSON.

### Optional: regenerate on every commit

We deliberately do **not** install a git hook automatically — that's
your environment to manage. To keep the graph in sync without thinking
about it, add a Makefile target:

```makefile
.PHONY: graph
graph:
	Rscript -e 'qproj::proj_scan_graph(quiet = TRUE)'
```

Then call `make graph` after structural changes (new step, new R
function, new DBI table).

### How AI assistants should use the output

Tell the AI to start with the small markdown report; the report itself
points at `qg` for follow-up queries:

> *"Read `.qproj/graph/QPROJ_GRAPH_REPORT.md` first. For dependency
> questions, query the graph with `bash .qproj/graph/qg <subcommand>`
> (`qg --help` lists subcommands). Do NOT read `qproj-graph.json`
> directly. Do NOT read individual `.qmd` files unless `qg` cannot
> answer the question."*

Common refactor / cleanup prompts (paste verbatim):

- **Before deleting a step:** *"Run `qg impact <step-id>`; list every
  downstream node and explain what would break."*
- **Before submission cleanup:** *"Run `qg unused` and `qg stale
  --days 90`; propose a shortlist of nodes to archive or delete."*
- **Understanding inherited code:** *"Run `qg deps <step-id>` to map
  the full ancestry; explain what data this step ultimately depends
  on."*

To make the AI discover this on its own (no per-prompt instruction),
add one line to your project `CLAUDE.md` / `AGENTS.md` / `GEMINI.md`:

```
If `.qproj/graph/qg` exists, query the dependency graph with it
(`bash .qproj/graph/qg --help`) instead of reading qproj-graph.json.
```

### Required packages

`proj_scan_graph()` lives in `Suggests`, not `Imports`. The first call
prompts you to install whichever are missing:

- `knitr`, `rmarkdown`, `jsonlite` — always required
- `visNetwork`, `htmlwidgets` — only if `"html"` is in `formats`

These stay out of qproj's hard dependencies so ordinary users pay
nothing for a feature they may never use.

For warning types, `EXTRACTED` vs `INFERRED` vs `AMBIGUOUS` confidence
levels, and the limitations of the static scan, see
`vignette("knowledge-graph")`.
