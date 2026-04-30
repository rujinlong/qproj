# Design Philosophy


qproj is a lightweight framework for organizing Quarto-based analysis
workflows. It is a Quarto-era refinement of
[projthis](https://ijlyttle.github.io/projthis/), with two ideas layered
on top of the original “each analysis file writes to its own data
directory” philosophy:

1.  **Quarto (`.qmd`) replaces R Markdown (`.Rmd`)**, and the workflow
    config file is renamed `_qproj.yml`.
2.  **The `analyses/data/` layout is restructured**: each step now
    distinguishes its **outputs** (`data/<step>/`) from its **inputs**,
    with separate locations for project-shared inputs
    (`data/00-raw/d00-resource/`) and step-specific inputs
    (`data/00-raw/d<step>/`).

The goal remains “the simplest thing that works”. qproj does not aspire
to compete with [renv](https://rstudio.github.io/renv/) (package version
locking) or [targets](https://docs.ropensci.org/targets/) (object-level
workflow DAGs). It aspires to be a lightweight first step toward those
tools, leaving the upgrade path open.

## Three main ideas

1.  A **workflow** is a sequence of `.qmd` files in `analyses/`, sharing
    one `data/` directory.
2.  The `data/` directory has a **two-axis structure**: outputs vs
    inputs, private vs shared.
3.  Package dependencies are managed via the project’s `DESCRIPTION`
    file.

These three ideas are independent of each other.

## Naming convention (hard rule)

| Prefix | Used by | Meaning |
|----|----|----|
| `00-` | Framework only | Reserved for `data/00-raw/`, the input region |
| `01-`, `02-`, … | User | Analysis steps (`01-import.qmd`, `02-clean.qmd`, …) |
| `001-`, `010-`, … | User | When finer-grained ordering is needed (e.g., to insert a step between `01-` and `02-`) |

**Why must user steps start at `01-` or higher?** Each `.qmd` template
includes:

``` r
path_raw <- path_source("00-raw")
```

`path_source()` validates that the requested directory comes earlier
(lexicographically) than the current step. As long as the current step
starts with `01-` or higher, `"00-raw"` always sorts earlier and the
check passes silently. Violating the convention (e.g., naming a step
`00-import.qmd`) would trigger a spurious warning, because
`"00-i" < "00-r"` in lexicographic order.

This is a deliberate design where **a naming convention guarantees
runtime correctness**. The framework does not enforce the convention
itself — but if you follow it, things just work.

## Sequence of `.qmd` files

A workflow looks like:

    analyses/
      data/
        01-import/             ← step 01's output
        02-clean/              ← step 02's output
        99-publish/            ← step 99's output
        00-raw/                ← input region (framework-reserved)
          d00-resource/        ← project-shared inputs
          d01-import/          ← step 01's private inputs
          d02-clean/           ← step 02's private inputs
      01-import.qmd
      02-clean.qmd
      99-publish.qmd
      README.qmd

By default, `.qmd` files render in **lexicographic order**. `README.qmd`
is always rendered last. Files starting with an underscore (`_*.qmd`)
are skipped — they are partials.

If you genuinely need to override the order, place a `_qproj.yml` file
in the workflow directory:

``` yaml
render:
  first:
    - 01-import.qmd
  last:
    - 99-publish.qmd
```

This is an escape hatch, not the recommended path. Idiomatic qproj
projects rely on numeric prefixes alone. See `proj_workflow_config()`
for details.

## Data layout: outputs vs inputs

![How qproj’s five `path_*` bindings map to folders, illustrated from
`02-clean.qmd`’s perspective.](figures/qproj_paths.jpg)

This is the most important conceptual change from projthis. Each step
has access to **five** path bindings, each playing a different role
along two axes:

|  | Internal pipeline | External world (placed by hand) |
|----|----|----|
| **Step’s own** | `path_target` writes to `data/<step>/` | `path_data` reads from `data/00-raw/d<step>/` |
| **Upstream** | `path_source(prev)` reads from `data/<prev>/` | — |
| **Project-wide** | — | `path_resource` reads from `data/00-raw/d00-resource/` |

Three observations:

1.  **Everything from the external world lives under `data/00-raw/`.**
    This is the single entry point for raw data. The `d` prefix on
    subdirectories (`d00-resource`, `d01-import`, …) marks them as
    **d**ata-only — there is no corresponding `.qmd` file.

2.  **Outputs and inputs are physically separated.** `data/<step>/`
    (output) and `data/00-raw/d<step>/` (input) live in different
    subtrees on purpose, so wiping outputs cannot accidentally destroy
    inputs.

3.  **`path_data` is strictly private to the current step.** No public
    API (no `path_source`-style accessor) exposes it to downstream
    steps. Downstream code wanting the data must let the current step
    **clean / process / decide** what to publish via `path_target`. This
    asymmetry is intentional: raw inputs typically need normalization
    before joining the pipeline, not naked passing-through.

    > [!WARNING]
    >
    > ### Anti-pattern: reading another step’s `path_data` directly
    >
    > Nothing prevents `02-clean.qmd` from reaching across the boundary
    > with `here::here(path_raw, "d01-import", "raw.fastq")`. The path
    > resolves and the file is reachable. Do not do this.
    >
    > The right move is to let `01-import.qmd` write the data (raw or
    > normalized) via `path_target()`, then have `02-clean.qmd` read it
    > via `path_source("01-import", ...)`. Each step then declares
    > **what it publishes** as its public surface; private inputs stay
    > private.
    >
    > This is a soft boundary — qproj keeps it loose so you retain
    > flexibility when you genuinely need to bypass it, but the
    > convention is what makes the pipeline readable to a future
    > maintainer (or to you, six months later).

| Directory | Role | Who writes | Who reads | On `clean = TRUE` |
|----|----|----|----|----|
| `data/<step>/` | Step output | Current step only | Downstream steps via `path_source` | **Wiped** |
| `data/00-raw/d00-resource/` | Project-shared inputs (reference databases, dictionaries, downloads) | Project maintainer (any user may also drop files) | Any step | Untouched |
| `data/00-raw/d<step>/` | Step-specific private inputs | Current step only | **Current step only** (strictly private) | Untouched |

## The five path bindings

The `.qmd` template (`inst/templates/workflow.qmd`) automatically
injects:

``` r
path_target   <- qproj::proj_path_target(params$name)            # function
path_source   <- qproj::proj_path_source(params$name)            # function
path_raw      <- path_source("00-raw")                           # string
path_resource <- here::here(path_raw, "d00-resource")            # string
path_data     <- here::here(path_raw, paste0("d", params$name))  # string
```

| Name | Type | Resolves to | Role |
|----|----|----|----|
| `path_target` | **function** | `path_target("a.csv")` → `data/<step>/a.csv` | The **only** place this step writes |
| `path_source` | **function** | `path_source("01-import", "x.csv")` → `data/01-import/x.csv` | Read upstream output (with order check) |
| `path_raw` | string | `data/00-raw` | Root of the input region (rarely used directly) |
| `path_resource` | string | `data/00-raw/d00-resource` | Project-shared inputs |
| `path_data` | string | `data/00-raw/d<step>` | **Step-specific inputs** |

`proj_path_target()` and `proj_path_source()` are [function
factories](https://adv-r.hadley.nz/function-factories.html). They return
functions that have closed over the current step’s name. This is what
lets `path_source(...)` validate the order check on every call without
making you re-state the current step’s name. `path_target` follows the
same pattern partly for symmetry, partly so you can call `path_target()`
(no arguments) to get the directory itself, e.g.,
`proj_dir_info(path_target())`.

`path_raw` is built via `path_source("00-raw")` rather than
`here::here("data", "00-raw")`. The result is identical, but routing the
read through `path_source` keeps a single chokepoint should we ever want
to log or hook raw-data access. This is also why the `01-` naming rule
matters — it keeps the order check silent.

## Interactive workflows: re-run `params` + `setup` when you switch files

The five `path_*` bindings are **session-global variables**. Each
`.qmd`’s `setup` chunk creates them, closing over `params$name` (the
current step’s name).

When `quarto render <file>` is invoked, this is robust:

1.  Quarto starts a **fresh R session** for that file.
2.  The `params` chunk sets `params$name` to the step’s name.
3.  The `setup` chunk creates the five `path_*` bindings, each closed
    over that name.
4.  Every subsequent chunk inherits the correct bindings.

In an **interactive RStudio session**, however, every open `.qmd` shares
the same R global environment. Whichever file’s `setup` chunk you ran
most recently wins. Two failure modes:

- **Stale bindings (silent bug).** You switch from `01-import.qmd` to
  `02-clean.qmd` and run a code chunk before re-running `02-clean.qmd`’s
  `setup`. The `path_*` bindings still point at `01-import`’s
  directories. Reads and writes go to the wrong folder, and nothing
  complains.
- **Missing bindings (loud error).** No `setup` has been run yet in this
  session — the very first chunk that uses `path_target` errors with
  `object 'params' not found`.

> [!WARNING]
>
> ### Rule of thumb
>
> **When you switch to a different `.qmd` to run code interactively,
> re-run its `params` and `setup` chunks first.**

**Hygiene-based workarounds** in your current IDE, from lightest to most
invasive:

1.  Render the whole file via `quarto render <file>` — fresh session,
    correct bindings for free, at the cost of producing a build
    artefact.
2.  Restart R (RStudio: <kbd>Ctrl+Shift+F10</kbd> /
    <kbd>Cmd+Shift+0</kbd>) before working in a different `.qmd`.
3.  One `.Rproj` per workflow, so `path_*` bindings cannot collide
    across unrelated work.

> [!TIP]
>
> ### Or: remove the trap entirely with Positron
>
> [Positron](https://positron.posit.co/) is Posit’s next-generation IDE
> (the spiritual successor to RStudio). It supports **multiple isolated
> R sessions in one window** — you can attach a separate session to each
> `.qmd` you have open. Each session has its own independent global
> environment, so `path_*` bindings from `01-import.qmd` literally
> cannot leak into `02-clean.qmd`. The entire class of pitfalls
> described above becomes **structurally impossible** — no discipline
> required.
>
> For a walkthrough of the multi-session workflow, see [this video
> tutorial](https://www.youtube.com/watch?v=sItCFWvLDJQ).

The trade-off behind all this: qproj’s path bindings are deliberately
**closures** rather than functions you call with the step’s name
(`path_target("02-clean", "a.csv")` would have been call-site-explicit
but verbose). The closure form keeps each chunk’s code clean, at the
cost of demanding session hygiene from single-session users — or a
per-file-session IDE like Positron.

## `clean = TRUE` and input safety

`proj_create_dir_target(name, clean = TRUE)` clears the step’s output
directory before each render, but **only** touches `data/<step>/`. The
input region (`data/00-raw/...`) is never touched.

This is the central safety guarantee:

- Files you place by hand in `path_data` or `path_resource` survive
  every workflow re-run.
- This is what makes `clean = TRUE` safe to enable for reproducible
  runs.
- To clear the input region, you must do so explicitly (e.g.,
  `fs::dir_delete(path_data)`).

The function default is `clean = TRUE`, but the template overrides it to
`clean = FALSE`. This is not a contradiction: from the function’s
standpoint, an explicit call usually wants a fresh state; from the
template’s standpoint, interactive iterative renders should not throw
away partial outputs. Flip the template line manually for production
runs.

## Syncing strategy: git for code, drive for inputs, never sync derived

The `data/` tree is excluded from git: it’s typically too large, and the
framework writes the corresponding `.gitignore` rule itself
(`R/create.R::proj_use_workflow()`). git/GitHub therefore carries only
the code, vignettes, READMEs, and `DESCRIPTION` — the parts that change
one keystroke at a time. The `data/` itself flows through a different
channel.

Recommended split:

- **Sync** `data/00-raw/` — the entire input region, including
  `d00-resource` and every `d<step>/` — via cloud storage (OneDrive,
  Google Drive, Dropbox, NextCloud, …). These are files placed by hand;
  they must be byte-identical across team members’ machines.
- **Don’t sync** `data/[01-99]*/` — every step’s output directory. Each
  member regenerates them locally by re-rendering the workflow against
  the synced `data/00-raw/`.

The “don’t sync derived” half is not just to save bandwidth — it is a
**first-class reproducibility checkpoint**. Members independently
re-derive every step from the same raw inputs, and at any point during
or near the end of a project the team can compare each member’s
`data/<step>/` outputs:

- identical → that step is reproducible across machines.
- divergent → there is an unfixed source of nondeterminism (a forgotten
  seed, package-version skew, OS-specific tooling) that must be tracked
  down before the result is trustworthy.

For research, this is the form of reproducibility that actually matters:
not “the original author can re-run it” but “anyone on the team gets the
same numbers and figures from the same raw data.”

The discipline this assumes: every chunk that uses randomness sets a
fixed seed at the top of its `.qmd` file. Pinning package versions via
[renv](https://rstudio.github.io/renv/) is the logical next step, but
most teams reserve it for end-of-project Docker bundling rather than
daily work, where the cost of frequent re-resolves outweighs the
marginal reproducibility gain.

> [!WARNING]
>
> ### Two practical caveats
>
> - **Large files.** Multi-GB fastq / bam / model files do not sync well
>   over consumer cloud — bandwidth, partial-resume reliability, and
>   quota all bite. Keep these on institutional storage, S3, or `rsync`,
>   and document the retrieval recipe in the project’s top-level
>   `README.md` instead of relying on the sync drive.
> - **Sensitive data.** Patient data, unpublished sequencing, and
>   anything covered by IRB / ethics / DPA agreements typically cannot
>   live on consumer cloud at all. Confirm the data-governance rules
>   **before** picking a sync mechanism — the wrong default here turns a
>   workflow convenience into a compliance incident.

## Time-direction check

`path_source(...)` issues a `warning()` (not `stop()`) when the
requested directory does not come earlier than the current step:

``` r
# inside 02-clean.qmd
path_source("01-import", "raw.csv")  # OK
path_source("99-publish", "x.csv")   # warning: "99-publish" is not previous to "02-clean"
```

The “warn, don’t block” stance is consistent with qproj’s lightweight
philosophy.

> [!NOTE]
>
> ### Implementation note
>
> `_qproj.yml`’s `render.first` / `render.last` use file names with the
> `.qmd` suffix, while `path_source` runs its order check on bare names
> (`"01-import"` rather than `"01-import.qmd"`). So `_qproj.yml` does
> **not** influence the order check inside `path_source`. In practice
> this only matters if you both (a) rely on `_qproj.yml` to reorder and
> (b) call `path_source` across the reordered boundary; since
> `_qproj.yml` is discouraged in the first place, this rarely surfaces.

## Dependency management

For analysis projects, qproj reuses the `DESCRIPTION` file from R
package conventions:

- `proj_create()` writes a minimal `DESCRIPTION` (Package, Title,
  Version).
- `proj_check_deps()` uses `renv::dependencies()` to scan all source
  code for `library()` / `::` calls and compares against `DESCRIPTION`’s
  `Imports`.
- `proj_update_deps()` adds missing entries (with optional
  `remove_extra = TRUE` to drop unused).
- `proj_install_deps()` calls `pak::local_install_deps()`.

`Remotes:` can be used for GitHub or private repositories; you maintain
it manually.

This deliberately **does not lock package versions** the way `renv`
does. It declares dependencies, no more. Should you later need version
locking, `renv` reads `DESCRIPTION` natively, so the upgrade path is
trivial.

## Summary

qproj’s job is to get a Quarto-based analysis off the ground quickly,
with just enough structure to keep multi-step workflows organized:

- A **naming convention** (`00-` reserved, users start at `01-`) makes
  the path-source order check silent.
- A **two-axis data layout** (outputs vs inputs × private vs shared)
  makes the role of each directory self-evident from its location.
- A **DESCRIPTION-based dependency declaration** integrates with the
  wider R ecosystem.

When the workflow grows past these abstractions, the natural next steps
are:

- [renv](https://rstudio.github.io/renv/) for pinned package versions.
- [targets](https://docs.ropensci.org/targets/) for object-level
  workflow DAGs.
- The full [Quarto](https://quarto.org/) ecosystem for richer document
  formats.

Adopting any of these is a sign of success — qproj has handed you off
cleanly.
