# 设计哲学


qproj 是一个轻量级的 Quarto 分析工作流脚手架。 它是 Quarto 时代对
[projthis](https://ijlyttle.github.io/projthis/)
的重构，在原有”每个分析文件写到自己的数据目录”的设计之上加入了两条新理念：

1.  **用 Quarto (`.qmd`) 取代 R Markdown
    (`.Rmd`)**，工作流配置文件改名为 `_qproj.yml`。
2.  **`analyses/data/`
    目录结构被重新设计**：每个步骤显式区分**产出**（`data/<step>/`）和**输入**——既包括项目共享输入（`data/00-raw/d00-resource/`），也包括步骤专属输入（`data/00-raw/d<step>/`）。

设计目标依然是”最简单的能工作的方案”。 qproj 不与
[renv](https://rstudio.github.io/renv/)（版本锁定）或
[targets](https://docs.ropensci.org/targets/)（对象级 DAG）竞争。
它的定位是这些更重工具的轻量入门版，把成长路径让出来。

## 三大核心理念

1.  **工作流**是 `analyses/` 目录里一组按序渲染的 `.qmd` 文件，共用一个
    `data/` 目录。
2.  `data/` 目录采用**双轴结构**：产出 vs 输入、私有 vs 共享。
3.  包依赖通过项目的 `DESCRIPTION` 文件管理。

这三条理念彼此独立。

## 命名约定（硬性规则）

| 前缀 | 使用者 | 含义 |
|----|----|----|
| `00-` | 仅框架 | 保留给 `data/00-raw/`（输入区） |
| `01-`、`02-`、… | 用户 | 分析步骤（`01-import.qmd`、`02-clean.qmd`、…） |
| `001-`、`010-`、… | 用户 | 需要更细分时（例如要在 `01-` 和 `02-` 之间插步骤） |

**为什么用户步骤必须从 `01-` 起？** 每个 `.qmd` 模板里都有这一行：

``` r
path_raw <- path_source("00-raw")
```

`path_source()` 内部会校验”被读取的目录必须在当前步骤之前（按字典序）“。
只要当前步骤从 `01-` 起步，`"00-raw"` 总是排在更早，校验静默通过。
违反约定（例如把某步命名为 `00-import.qmd`）会触发”00-raw 不在 00-import
之前”的 warning——因为字典序里 `"00-i" < "00-r"`。

这是一个**用命名约定来保证运行时正确性**的优雅设计。
框架不强制约定本身，但只要你遵守，框架就 work。

## `.qmd` 文件的有序序列

一个工作流目录看起来像这样：

    analyses/
      data/
        01-import/             ← 步骤 01 的产出
        02-clean/              ← 步骤 02 的产出
        99-publish/            ← 步骤 99 的产出
        00-raw/                ← 输入区（框架保留）
          d00-resource/        ← 项目共享输入
          d01-import/          ← 步骤 01 的专属输入
          d02-clean/           ← 步骤 02 的专属输入
      01-import.qmd
      02-clean.qmd
      99-publish.qmd
      README.qmd

默认情况下，`.qmd` 文件按**字典序**渲染。 `README.qmd` 永远最后。
下划线开头的文件（`_*.qmd`）跳过——它们是 partial。

如果确实要打破默认顺序，在工作流目录放一个 `_qproj.yml`：

``` yaml
render:
  first:
    - 01-import.qmd
  last:
    - 99-publish.qmd
```

这是个逃生口，不是推荐路径。 地道的 qproj 项目仅靠数字前缀就够了。 详见
`proj_workflow_config()`。

## 数据布局：产出 vs 输入

![qproj 五个 `path_*` 绑定与目录的对应关系，以 `02-clean.qmd`
的视角为例。](figures/qproj_paths.jpg)

这是 qproj 相对 projthis 最重要的概念变化。
每个步骤可以访问**五个**路径绑定，沿两根坐标轴各自承担不同角色：

|  | 内部管道 | 外部世界（手动放进来） |
|----|----|----|
| **本步骤独占** | `path_target` 写到 `data/<step>/` | `path_data` 读自 `data/00-raw/d<step>/` |
| **上游** | `path_source(prev)` 读自 `data/<prev>/` | — |
| **项目共享** | — | `path_resource` 读自 `data/00-raw/d00-resource/` |

三点观察：

1.  **所有”外部世界来的数据”都集中在 `data/00-raw/` 这棵子树里。** 这是
    raw 数据的唯一入口。 子目录的 `d`
    前缀（`d00-resource`、`d01-import`、…）标记它们是纯**数据**（**d**ata），没有同名
    `.qmd` 文件。

2.  **产出和输入物理隔离。** `data/<step>/`（产出）和
    `data/00-raw/d<step>/`（输入）有意分在不同子树里，这样擦掉产出不会误伤输入。

3.  **`path_data` 是严格私有的。** 没有任何公开 API（不像 `path_source`
    那种半公开的访问机制）把它暴露给下游。
    下游想要这些数据，必须由当前步骤**清洗 / 处理 / 决定要不要发布到
    `path_target`**。
    这种不对称是有意的：原始输入数据通常需要归一化才该进入管道，而不是裸传递。

| 目录 | 角色 | 谁写 | 谁读 | `clean = TRUE` 时 |
|----|----|----|----|----|
| `data/<step>/` | 本步骤产出 | 仅本步骤 | 后续步骤通过 `path_source` | **被擦掉** |
| `data/00-raw/d00-resource/` | 项目级共享输入资源（参考库、字典、外部下载） | 项目管理员（普通用户也可放） | 任何步骤 | 不动 |
| `data/00-raw/d<step>/` | 本步骤专属输入 | 仅本步骤 | **仅本步骤**（严格私有） | 不动 |

## 五个路径绑定

`.qmd` 模板（`inst/templates/workflow.qmd`）自动注入：

``` r
path_target   <- qproj::proj_path_target(params$name)            # 函数
path_source   <- qproj::proj_path_source(params$name)            # 函数
path_raw      <- path_source("00-raw")                           # 字符串
path_resource <- here::here(path_raw, "d00-resource")            # 字符串
path_data     <- here::here(path_raw, paste0("d", params$name))  # 字符串
```

| 名称 | 类型 | 解析为 | 角色 |
|----|----|----|----|
| `path_target` | **函数** | `path_target("a.csv")` → `data/<step>/a.csv` | 本步骤**唯一**的写入位置 |
| `path_source` | **函数** | `path_source("01-import", "x.csv")` → `data/01-import/x.csv` | 读上游产出（含顺序校验） |
| `path_raw` | 字符串 | `data/00-raw` | 输入区根目录（一般不直接用） |
| `path_resource` | 字符串 | `data/00-raw/d00-resource` | 项目级共享输入资源 |
| `path_data` | 字符串 | `data/00-raw/d<step>` | **本步骤专属输入** |

`proj_path_target()` 和 `proj_path_source()` 是 [function
factory](https://adv-r.hadley.nz/function-factories.html)：返回函数，并把当前步骤的
name 闭包进去。 这样 `path_source(...)`
每次调用时都能做顺序校验，调用点不必每次重新提 name。 `path_target`
用相同模式部分是为了 API 对称，部分是为了让
`path_target()`（无参）能直接拿到目录本身（如
`proj_dir_info(path_target())`）。

`path_raw` 用 `path_source("00-raw")` 而不是
`here::here("data", "00-raw")`：结果一致，但走 `path_source`
这条统一管道，将来若要给 raw 访问加日志或权限钩子，只改一处即可。 这也是
`01-` 命名规则要紧的原因——保证这里的顺序校验静默通过。

## 交互式工作流：切换文档时重跑 `params` + `setup`

5 个 `path_*` 绑定是 **session 级全局变量**。 每份 `.qmd` 的 `setup`
chunk 在创建它们时，把 `params$name`（当前步骤名）闭包进去。

用 `quarto render <file>` 渲染单个文件时，这套机制很稳：

1.  Quarto 为该文件起一个**全新的 R session**；
2.  `params` chunk 把 `params$name` 设为该步骤的名字；
3.  `setup` chunk 创建 5 个 `path_*` 绑定，各自闭包了那个 name；
4.  后续所有 chunk 都继承到正确的绑定。

但**在 RStudio 的交互式 session 里**，所有打开的 `.qmd` 共用同一个 R
全局环境。 最近一次跑过的 `setup` chunk 决定了当前 `path_*` 指向哪里。
两种典型出错模式：

- **绑定残留（静默 bug）。** 你从 `01-import.qmd` 切到
  `02-clean.qmd`，**不重跑 `02-clean.qmd` 的 `setup`** 就执行某个代码
  chunk。`path_*` 仍然绑在 `01-import`
  上，读写跑到错误目录，**且没有任何报错**。
- **绑定缺失（直接报错）。** 当前 session 里根本没跑过任何
  `setup`——第一个使用 `path_target` 的 chunk 就会报
  `Error: object 'params' not found`。

> [!WARNING]
>
> ### 经验法则
>
> **每当你切到另一个 `.qmd` 准备执行代码，先重跑它的 `params` 和 `setup`
> chunk。**

**当前 IDE 内的卫生型规避**，从最轻到最重：

1.  用 `quarto render <file>` 跑完整个文件——会自动获得 fresh session
    和正确的绑定，但产出一份构建物；
2.  切到不同 `.qmd` 之前重启 R（RStudio：<kbd>Ctrl+Shift+F10</kbd> /
    <kbd>Cmd+Shift+0</kbd>）；
3.  每个工作流单独开一个 `.Rproj`，让 `path_*`
    在不同文件之间根本不可能撞上。

> [!TIP]
>
> ### 或者：用 Positron 把陷阱直接消除
>
> [Positron](https://positron.posit.co/) 是 Posit 公司的下一代
> IDE（RStudio 的精神后继）。
> 它支持**在同一个窗口里同时打开多个互相隔离的 R session**——你可以给每份
> `.qmd` 配一个独立 session。 每个 session 有自己的独立全局环境，所以
> `01-import.qmd` 的 `path_*` 绑定**根本不可能泄漏**到 `02-clean.qmd`。
> 上面整类陷阱在结构上就**不可能发生**——无需任何自律。
>
> 多 session
> 工作流的演示见[这个视频教程](https://www.youtube.com/watch?v=sItCFWvLDJQ)。

这背后是一个 trade-off：qproj
的路径绑定刻意做成**闭包**，而不是每次调用都要传步骤名的函数（`path_target("02-clean", "a.csv")`
那种 call-site explicit 但冗长）。 闭包形式让 chunk
里的代码保持简洁，代价是要求单 session 用户保持 session 卫生——或者使用
Positron 这种支持每文件独立 session 的 IDE。

## `clean = TRUE` 与输入数据保护

`proj_create_dir_target(name, clean = TRUE)`
在每次渲染前清空步骤的产出目录，但**只**操作 `data/<step>/`。
输入区（`data/00-raw/...`）从不被触碰。

这是设计的核心安全保证：

- 你手动放进 `path_data` 或 `path_resource`
  的文件，每次工作流重跑都安全。
- 正因如此，你才敢在重现性运行时打开 `clean = TRUE`。
- 想清空输入区，必须显式操作（如 `fs::dir_delete(path_data)`）。

函数定义里 `clean = TRUE` 是默认，但模板里覆盖成了 `clean = FALSE`。
这不矛盾：从函数视角看，显式调用通常是想要 fresh
state；从模板视角看，交互开发期间反复渲染不该丢上一次的部分产出。
正式重跑时手动改一下模板那行即可。

## 时间方向校验

`path_source(...)` 在被请求的目录字典序晚于当前步骤时发出
`warning()`（不是 `stop()`）：

``` r
# 在 02-clean.qmd 中
path_source("01-import", "raw.csv")  # 通过
path_source("99-publish", "x.csv")   # warning：「"99-publish" is not previous to "02-clean"」
```

“提醒、不阻断”的姿态符合 qproj 整体的轻量哲学。

> [!NOTE]
>
> ### 实现细节
>
> `_qproj.yml` 的 `render.first` / `render.last` 用带 `.qmd`
> 后缀的文件名，但 `path_source` 内部用不带后缀的 bare
> name（`"01-import"` 而非 `"01-import.qmd"`）跑顺序校验。 所以
> `_qproj.yml` 实际上**不影响** `path_source` 的越界校验。
> 在实践中这只在以下两个条件同时成立时才相关：(a) 你用 `_qproj.yml`
> 重排顺序，(b) 你跨越重排过的边界调用 `path_source`。 因为 `_qproj.yml`
> 本身就不被鼓励，这种情况几乎不出现。

## 包依赖管理

针对分析项目，qproj 复用 R 包开发里的 `DESCRIPTION` 文件惯例：

- `proj_create()` 写一个最小 `DESCRIPTION`（Package、Title、Version）。
- `proj_check_deps()` 用 `renv::dependencies()` 扫描所有源码里的
  `library()` / `::` 调用，跟 `DESCRIPTION` 的 `Imports` 对比。
- `proj_update_deps()` 把缺的塞进去（可选 `remove_extra = TRUE`
  删多余的）。
- `proj_install_deps()` 调用 `pak::local_install_deps()`。

`Remotes:` 字段用来指定 GitHub 或私有仓库，需要你手动维护。

这套机制**有意不锁版本**，区别于 `renv`。 它只声明依赖，仅此而已。
将来若需要锁版本，`renv` 原生支持读 `DESCRIPTION`，升级路径平滑。

## 总结

qproj 的工作是让 Quarto
分析项目快速跑起来，并提供刚好够用的结构来保持多步工作流的整洁：

- 一条**命名约定**（`00-` 保留、用户从 `01-` 起步）保证 `path_source`
  顺序校验静默通过。
- 一套**双轴数据布局**（产出 vs 输入 × 私有 vs
  共享）让每个目录的角色从位置就能看出来。
- 一种**基于 DESCRIPTION 的依赖声明**和 R 生态衔接。

当你的工作流超出这套抽象，自然的下一步是：

- [renv](https://rstudio.github.io/renv/) 用于固定版本号。
- [targets](https://docs.ropensci.org/targets/) 用于对象级 DAG。
- 完整的 [Quarto](https://quarto.org/) 生态用于更丰富的文档格式。

采用任何一种都是成功——qproj 已经把你干净地交接出去了。
