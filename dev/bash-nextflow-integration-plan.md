# qproj × vpipe:Bash / Nextflow / Python 整合计划(跨-session 入口)

> 把 qproj(R/Quarto 分析框架)扩展到 Bash + Nextflow + Python,并厘清"数十个项目的共享代码
> 如何复用 ~/vpipe"。用户 2026-07-20 立项。本文是跨-session 执行入口——接手先读它。
> 决策经 **Claude(主)+ Codex(gpt-5.6-sol, xhigh)三轮对抗** 收敛,Codex flag 均已 grep 实证核实
> (见下「已验证的实证事实」)。方法论与 `dev/provenance-extraction-plan.md`(门 2 溯源抽取)同构:
> 先在真实项目对抗硬化,再抽进框架,golden 回归保护。

## 0. 一句话结论

**编排在项目、计算在中央、单向依赖、按 BOM 原子锁版本。** qproj 项目里每语言一个瘦
driver(`analyses/p<code>.slurm` / `.nf` / uv package)负责 fan-out / 命名 / step 接线;所有实质
计算 primitive 留在 vpipe(shell toolkit / NF subworkflow / Python CLI);vpipe 对 qproj 无知;
每个项目用一个 `vpipe.lock` 原子锁定它依赖的 vpipe BOM。

## 1. 背景:两个框架的既有哲学(不复述,只记接口)

- **qproj**:双轴(`analyses/` numeric-prefix step + `analyses/data/<step>/` 专属目录)+ 写入纪律
  (step 只写自己 target,读上游用 `path_source`)。已扩展:Python 用 `analyses/` 里 `uv init --package`。
  详见 `R/directories.R` / `R/workflow.R` / `inst/templates/workflow.qmd`。
- **vpipe**(`~/vpipe`,git repo,被数十项目共享)。**三层执行模型(INV-ARCH-05)**:
  Nextflow(调度/dataflow)+ shell toolkit(`*.slurm` 原子任务)+ Python CLI(`vpipe <group> <cmd>` 解析/转换);
  容器/DB 走 `conf/tools.yml` + `conf/database.yml` + `COMMAND_PREFIX_*`,**不由 NF `container` 管**。

## 2. 已验证的实证事实(Codex flag,均 grep 核实,非声称)

| 事实 | 证据 | 影响 |
|---|---|---|
| 中央 `bin/` 堆 **18 个** `p*/pc*.slurm`,103 subcmd,56 个完全重复 branch | `ls ~/vpipe/bin/p*.slurm` | `p<code>.slurm` 住中央 = 架构债,非孵化区 |
| 跨项目互调:`pc028e7.slurm` 调 `p0101.slurm`;`p0108.slurm` 整个 usage 是 `pc037.slurm`(复制没改 help) | `bin/pc028e7.slurm:9`、`bin/p0108.slurm:16` | 中央堆放导致 copy lineage + 耦合 |
| `assembly.slurm` 早有 `fairy/metabat2/maxbin2/vamb/semibin2` primitive;`p0101.slurm bin_metabat` 只是 `for f in *_5k.fasta; do assembly.slurm fairy metabat2 …; done` | `bin/assembly.slurm:396,556`、`bin/p0101.slurm:218` | `bin_metabat` 是**编排**不是计算 → 属项目 driver,不上提 |
| vpipe 的 NF module **非自包含**:`metabat2.nf` `export VPIPEBIN=${params.vpipebin}; assembly.slurm metabat2` | `modules/local/metabat2.nf:15-16` | **pin NF ≠ pin 计算** → 必须 atomic pin BOM |
| `p0101.slurm` 顶部静态 `#SBATCH -p cpu_p`,但 `bin_vamb` 要 `--gres=gpu:1 -p gpu_p` | `bin/p0101.slurm:4,39` | 静态 header 给不出多资源 subcmd 的默认 → 需 submit 模式 |
| immutability 漏洞:`database.yml` **19 处** `current` symlink、`tools.yml` 一片 `-latest.img`、vpipe 版本仍 `0.1.0` | `conf/database.yml:19`、`conf/tools.yml:12`、`pyproject.toml:7` | pin commit 只完成 ~20%,DB/image 仍可变 |
| `core/manuscript.py` 是 qproj-aware(docstring "qproj-canonical naming"、操作 `analyses/data`、`detect_project_code`) | `pkgs/vpipe/src/vpipe/core/manuscript.py:1` | "整个 vpipe 对 qproj 无知"是**事实错误** → 只有计算内核须 qproj-free |
| `INV-SH-01` 规定必须 `source ${VPIPEBIN}/00-config.sh`,但**没规定** API version/public symbol/deprecation window | `docs/INVARIANTS.md:54` | source 的 ABI 面积巨大且无契约 → 需 public surface |

## 3. 核心架构:四个正交层(归位只是其一)

> ★ 关键教训(Codex 第三轮):"矛盾几乎全来自文件住错位置"是**过度归因**。Driver 归位只修
> **ownership**;版本耦合 / ABI / fleet drift 是**正交**问题,归位不自动解决。完整方案 = 四层叠加。

### L1 — 归位(ownership):`p<code>.{slurm,nf}` 回项目 `analyses/`
- 从 `~/vpipe/bin/` 搬回**项目自己的** `analyses/p<code>.slurm`(+ 可选 `analyses/p<code>.nf` + `nextflow.config`)。
- **用户全部人体工学保留**:一个项目一个文件、subcommand 按需、双模式(`bash`/`sbatch`)。
- 中央 vpipe 清 18 个项目文件 → **反碎片化**(碎片化是现状,非本方案)。
- ⚠ 归位**不杜绝**跨项目依赖(同一文件系统仍可硬编码 `~/github/.../p0101/...` 或经 PATH 调)——
  必须靠 **L4 的 CI firewall** 禁止,不能靠"搬目录期待自然消失"。

### L2 — 版本契约(pin / BOM):每项目一个 `analyses/vpipe.lock` ✅ 已实现(2026-07-21)

**完整格式规范:`dev/vpipe-lock-format-v1.md`(三个解析器照它实现的契约根)。** 摘要:

```yaml
lock_version: 1
resolved_version: "0.9.0"      # ─┐ Bash resolver 只读这三个:顶层、双引号、每行一个
git_commit: "675be1bb…"        #  │ (它在 batch 热路径,不能依赖任何外部程序)
release_path: "/home/allen/bioinfo/vpipe-releases/0.9.0+675be1b"   # ─┘
requires: ">=0.9,<1.0"
bom_digest: "sha256:…"         # tier-1(git tree SHA)+tier-3 → 确定性 → 不匹配 = 篡改 = hard fail
env_digest: "sha256:…"         # tier-2(观测态)→ 非确定性 → 不匹配 = 漂移 = 默认 WARN
shell_api: 1 ; nf_api: 1 ; python_api: 1
```

> ⚠ **本节原草案写的是 TOML,2026-07-21 改为 YAML(`DEC-D006`)**。理由:`proj_vpipe_pin()` 必须**写** lock,
> 而 R 生态**没有 TOML writer**(`RcppTOML` 只读且是编译包)——选 TOML 等于要在 R 里手写 TOML 序列化器。
> YAML 两侧零新依赖(`yaml` 已在 qproj Imports;PyYAML 已被 vpipe 用于 `tools.yml`/`database.yml`)。

- **两个 digest 而非一个**:单一 digest 若同时覆盖 tier-1 与 tier-2,则同一 commit 换天重新物化即得不同
  digest → 篡改检查彻底失效,而那是 lockfile 唯一值得拥有的性质。
- **atomic BOM**:NF source / shell toolkit / Python package / `tools.yml` / `database.yml` **必须来自同一 commit**——
  因 NF module 调裸 `assembly.slurm`(非自包含),分别 pin 会错位。实现方式:release 允许清单 == BOM 的 digest
  覆盖面,故「release 里每个文件都被 `bom_digest` 覆盖」。
- **immutability 未修(用户裁定只出提案)**,但 BOM **观测并记录** `current`/`-latest` 在切 BOM 那一刻解析到什么
  → 把静默漂移变成可检测漂移。⚠ **实测推翻了本节原先对敞口规模的判断**:`COMMAND_PREFIX_*` 不是 `tools.yml`
  查表——`setup_cmd_prefix()` 按站点分支,**spark 上优先用原生 micromamba env**。120 个注册工具中
  **28 个解析到 micromamba env、1 个 apptainer、87 个为空**;`megahit` 实跑 `micromamba run -n megahit`,
  `tools.yml` 里那个 `.img` 根本不被触及。**`envs/megahit` 不含任何版本 → 敞口是 28 个无版本 conda env,
  远大于原先只盯的 7 个 `-latest.img`**(已回写 vpipe `IMP-055`)。
- 每 release 出 **BOM**(落在 release 内 `.vpipe-release.yml`);**`run_manifest.json` 未做**(顺延,见 §7-D)。
- shell contract ⊇ subcmd 名:argument order / named flags / env vars / cwd / output filenames / stdout+stderr / exit code 都是 public API。

### L3 — ABI 收窄(public surface):vpipe 暴露刻意设计的窄接口
- 项目只 `source` 一个 public surface `lib/vpipe/runtime-v1.sh`;`00-config.sh` / `01-functions.sh` 降 **private**
  (现状 source 注入全部函数/变量/`readonly`/`set -euo`/副作用,ABI 面积失控)。
- primitive 用 `BASH_SOURCE[0]` 定位 sibling config,**不依赖 caller 注入的 `VPIPEBIN`**。
- **禁 mixed runtime**:调用必须 `${VPIPE_ROOT}/bin/assembly.slurm`(`VPIPE_ROOT` 由 lock resolver 返回 immutable checkout),
  **不靠 `PATH`**——否则 `VPIPEBIN`=版本 A 而 `PATH` 命中版本 B。
- config:项目**不** include vpipe 根 `nextflow.config`;vpipe 暴露窄的 versioned `conf/public/*.config`,
  项目 config 先 include central defaults 再 override,CI 查 `nextflow config -flat`。
- 执行前 `vpipe contract check --lock analyses/vpipe.lock`,不兼容在计算开始前 hard fail。

### L4 — fleet 治理(distributed drift):`qproj deps audit` + firewall CI
- 归位把"集中可见的重复"换成"跨 repo 分布式漂移",除非有 fleet 视图 → **`qproj deps audit`**:
  列各项目 vpipe pin / contract 兼容性 / 待升级版本;`qproj deps update vpipe --to …` + 兼容测试(防 exact pin 变永久 fossilization)。
- **firewall CI**(受保护目录 = `modules/`+`subworkflows/`+通用 `bin/*.slurm`+计算 `core/`):禁出现
  `qproj`/`analyses/data`/`path_source`/project-code 推断;contract test 从随机非-qproj CWD 调命令,断言只写 caller 提供范围;
  跨项目硬编码路径 lint 禁止。qproj-aware 的 `core/manuscript.py` 隔离进 `integrations.qproj` adapter。

## 4. 分流矩阵 v2(判据 = "因什么而变",非"哪种语言")

| 因…而变 | 归属 |
|---|---|
| qproj layout / step 生命周期 / 路径纪律 | **qproj 包**(path helper、driver 模板、runner、lock resolver) |
| 项目特定 fan-out / 文件发现 / step 接线 / 命名 | **项目 driver** `analyses/p<code>.{slurm,nf}`(`bin_metabat` 那个 for 循环就在这) |
| 生信工具 / DB / 文件 schema / pipeline 方法 | **vpipe**(NF subworkflow=稳定 dataflow;shell=原子 kernel;Python CLI=parse/transform) |
| 统计方法 / domain 模型,脱离 qproj 仍有独立价值 | **独立内聚 R/py 包**(不建 `miscR` 垃圾场;两行 ggplot 不值得建包) |
| 研究假设 / 协变量 / figure 组成 | **项目 `analyses/`** |

- scatter-gather 判据 = chunk 间独立 + merge 科学等价(**非**"文件大");COBRA overlap graph 不能拆 → per-sample fan-out。
- Python 上提判据(≥2 项目仅必要非充分):标准格式 parse/validate/normalize/transform + 无 project code/path +
  跨项目同语义 + 可纯函数测试 → `vpipe core/CLI`;cohort join / 实验设计 / 统计模型 → 项目 `analyses/src/`;
  多项目复用但带 domain assumption / heavy deps → 独立 package。
- CLI 深度 ≤3:默认 `vpipe <noun> <verb>`;top-level 只留 bootstrap(`version`/`which`/`run`/`contract check`);
  只有一 group 内 ≥2 稳定 subdomain 且各有多操作才用 `vpipe <domain> <entity> <verb>`。

## 5. 具体机制(可落地)

- **submit 模式解决 `#SBATCH` 静态资源**:driver 三入口 —
  `bash pCODE.slurm bin_metabat`(local)/ `bash pCODE.slurm submit bin_metabat`(registry 查资源→调 sbatch)/
  `sbatch -c.. --mem.. pCODE.slurm bin_metabat`(直接模式仍支持)。submit 先把 driver+lock+params+lib snapshot 进 run capsule 再提交。
- **site-portable Slurm(HMGU ↔ 家用 spark)**:`*.slurm` 顶部 `#SBATCH` 是**静态**的(Slurm 提交时即解析,脚本正文太晚改不了自己),所以 site 差异**必须在提交进程的环境层**注入,不能靠脚本内部检测。机制(全部 2026-07-20 实测):**Slurm 优先级 = 命令行 > `SBATCH_*` env > 脚本 `#SBATCH`**。三档:
  - **零摩擦(推荐,用户资源习惯走命令行)**:shell rc 按 site 自动 `export SBATCH_PARTITION`。已落 `~/.configure/configs/shell/zshrc_linux`(= `~/.zshrc`,**跨所有 Linux 机器含 HMGU 共享**)加 `case "$(hostname -s)" in spark*) export SBATCH_PARTITION=main ;; esac`——**hostname 守卫必须**(防 `main` 泄漏到 HMGU 误导 job)。效果:spark 上 `sbatch <hmgu-script>` 零前缀零改动自动落 `main`;`#SBATCH -q cpu_normal` 被 spark 无 QoS 静默忽略;命令行 `-p` 仍可覆盖。**现有全部 `*.slurm` 立即 site-portable,零脚本改动**。
  - **submit 模式(可选增强)**:`_vpipe_slurm_env <cpu|gpu>` 按 `_vpipe_detect_site`(vpipe 已有,判 hpc `ictstr*`/spark GB10/mac/local)export partition/qos;叠加 resource class + ceiling clamp(spark 20 CPU/120G)。
  - ⚠ 只影响 `sbatch`(srun/salloc 读 `SLURM_PARTITION`/`SALLOC_PARTITION`,如需另补)。spark 只有一个 `main` 分区(Default、无 QoS、两节点各 gpu:1、无 GPU 专区),全局 `SBATCH_PARTITION=main` 安全。`JAVA_CMD`(spark Nextflow 需 Java 17+)副作用面大,未全局 export,待定。
- **单文件 driver 内部模块化**(保单入口体验):case body → namespaced `cmd_*` functions + 显式 registry
  (`CMD_HANDLER/CMD_HELP/CMD_CPUS/CMD_MEM`);**不自动扫描 shell functions**(会扫进 source 进来的 `log_*`/`require_*`)。
  软阈值(~20 subcmd / 500 LOC / 出现 ≥2 独立 domain)再按 domain `source analyses/lib/pCODE-<domain>.sh`(内部实现,非用户入口)。
  阈值不按 LOC 硬定(<300 行的 driver 也已出现 copied help / 错项目名)。
- **`p<code>.nf` 的 pin**:`include from ../vpipe`(否决,mutable)/ `nextflow pull -r`(只适合跑完整 remote pipeline,非 local include 依赖)/
  **nf-core-style vendoring `--sha`(最接近正确)**。无项目特有 channel graph → 不建 `p<code>.nf`,直接 `nextflow run rujinlong/vpipe -r <commit>`;
  有 → 短期 git submodule pin 整树,长期建 `vpipe-components` custom remote vendoring subworkflow + transitive modules,`vpipe.lock` 锁同一 commit runtime。
- **fanout/重复 loop**:**默认接受**(3-5 行 project loop 重复 < 错抽 policy 进中央)。要抽则边界严格:
  输入=显式 manifest(不接 glob)、不推项目命名、不写项目路径、不提交 SLURM、`--dry-run`、manifest 写进 run_manifest;
  且叫通用 **`vpipe foreach`/`vpipe batch`**,不藏 `assembly.slurm fanout`。原则:**centralize semantic capability,不 centralize `for` syntax**;
  一旦 helper 管 parallel scatter/retry/cache/gather,它就是 dataflow orchestration → 升为 NF subworkflow。

## 6. project capsule 布局(终态)

```
analyses/
├── pCODE.slurm        # 唯一 Bash UX;local / submit / sbatch 三模式
├── pCODE.nf           # 仅确有 project-specific channel graph 时存在
├── nextflow.config    # project overrides + include versioned public config
├── vpipe.lock         # machine-managed exact resolution(L2)
└── lib/               # 仅 driver 达拆分触发器时出现(内部实现)
        pCODE-binning.sh ...
```
执行:`pCODE.slurm` → {local / submit-snapshot / nf} → immutable vpipe release(由 `vpipe.lock` 锁 BOM)→ primitive。
qproj 负责 resolver / submission / step+write discipline / manifest;vpipe 完全不知 qproj。
★ 每个 subcmd 仍须注册 `step_id` + input contract + output root——不能因都藏进 `pCODE.slurm` 就绕过 numeric-prefix 与写入纪律。

## 7. 分阶段路线(每阶段可验)

- **A 基石 ✅ 完成(2026-07-20)**:ship `inst/scripts/qproj.sh`(driver `source` 的 shell path helper,镜像 R:
  `path_target`=`$ROOT/data/$STEP/`、`path_source up`=`$ROOT/data/$up/`、`path_raw`=`$ROOT/data/00-raw/d$STEP/`、
  `path_resource`=`$ROOT/data/00-raw/d00-resource/`、`create_dir_target [--clean]`,外加**新** `path_run_state`=
  `$ROOT/data/.run-state/$STEP/`(shared-FS,非 localscratch;**兄弟**于 step target 而非其子目录——理由见 C 阶段));
  ROOT 定位=从 `--step-file`(不猜 `$0`)向上找
  `_quarto.yml`+`data/`(对齐 `here::i_am` 的 analyses/ 轴,最近命中优先),STEP 从 `--step-file` basename 派生、
  `qproj_set_step` 可按 subcmd 覆盖。`proj_use_workflow`(R/create.R)扩 gitignore(`.nextflow*`/`analyses/**/work/`/`.command.*`)。
  **验证**:`bash -n`+`shellcheck` 零 warning;14 项单元测试全过(ROOT/STEP 定位、五 path helper、set_step 覆盖、
  create_dir、set -e 下 assign-first、文件名误用告警);Rscript 实测 gitignore 输出正确。**driver `set -e` 陷阱**已
  在 qproj.sh 头部文档化:`input="$(path_source ..)"` 先赋值(command subst 失败被外层命令掩盖)。
  ~~**未接线**:driver 如何定位 qproj.sh(`system.file("scripts/qproj.sh")` vs env)留待 B 阶段试点确定。~~
  **✅ 接线已闭合(2026-07-21)** —— B 阶段实际用硬编码 dev-checkout 路径绕过了这个 TODO,且两个调用方
  (`analyses/pc047e3.slurm` 与 `workflow/run_local.sh`)的 resolver **已分叉**(前者三级+静默跳过、后者一级+裸 bash 崩)。
  现定契约并两侧实现:
  - **R 侧 SSOT**:新增 `R/shell.R` —— exported `proj_shell_lib()`(返回已装包的 qproj.sh,找不到 loud abort)
    与 `proj_shell_bootstrap(step, optional)`(返回 canonical bash 块;`step=` 时附带调用行)。
  - **解析优先级**:`$QPROJ_SH`(**设了但不可读 = hard error**,绝不静默降级——防 typo 落到另一份旧 qproj.sh)
    → `system.file()`(装了包的站点 authoritative)→ `$QPROJ_HOME/inst/scripts/qproj.sh`(dev checkout,默认
    `~/github/rujinlong/qproj`)→ 全落空则列出所有尝试路径后 fail。解析成功后 **export `QPROJ_SH`**,子脚本与
    nested `srun` 复用同一份(免二次 Rscript、且保证同版本)。
  - **为何不能用更简单的机制**(三条都实测排除):① 相对脚本自身定位 —— sbatch 下脚本从 spool 副本执行
    (job 96 实证 `$0`=`/var/spool/slurmd/job00096/slurm_script`);② PATH 查找 —— 重新引入 L3 要防的
    mixed runtime;③ 只靠 `system.file()` —— **`~/R/` 是节点本地**(2026-07-21 实测 spark1 inode 16267508 /
    spark2 3151102,mtime 亦不同),login 节点装的包 batch job 看不见,而 `~/github` 才是 autofs 共享。
  - **两处副本策略**:上述三条排除后 resolver 必须以逐字副本内嵌于每个 driver。故 SSOT 在 R,副本带
    `# qproj-bootstrap v2` 版本标记供 grep 查漂移(★ 块内容一变必须同 commit bump,否则旧副本与新版同号、drift 检测失效),两处脚本头部均注明「勿手改,回 qproj 改 SSOT 再生成」。
  - **回归测试(补上 A/C 阶段声称却从未入库的那批)**:`tests/shell/test_qproj_sh.sh` 45 项断言(ROOT/STEP 定位、
    五个 path helper、set_step、create_dir_target 的 rm -rf 越界防护、set -e assign-first vs inline 掩盖、
    `qproj_nf_prepare` 的三个 export + `$(...)` 丢 export 反证 + `--clean` 不毁 run-state、resolver 六种情形),
    经 `tests/testthat/test-shell.R` 接入 `devtools::test()`。**验证**:45/45 过、testthat 20/20 过、
    `bash -n`+`shellcheck` 零 warning(两个改过的脚本 shellcheck findings 各 **减少** 1 条 SC1090、无新增);
    真 **sbatch job 96**(spark2)证 spool 下 driver 告警 0 行、path_* 解析正确、rc=0;`run_local.sh` 的
    `RAW`/`WORK` 与改动前逐字一致。
- **B driver 归位试点 ✅ 完成(2026-07-20,试点=pc047e3-HpyloriTcell,轻量归位)**:
  `pc047e3.slurm`(291 行,10 subcmd metagenomics read-level 预处理)从 `~/vpipe/bin/` 搬入
  `pc047e3-HpyloriTcell/analyses/`。改造:① `source "${VPIPEBIN}/00-config.sh"` → `VPIPE_ROOT="${VPIPE_ROOT:-$HOME/vpipe}";
  source "${VPIPE_ROOT}/bin/00-config.sh"`(显式 immutable root,非 PATH;`VPIPEBIN` 从 `VPIPE_ROOT` 派生保兼容);
  ② source qproj.sh(dev-checkout fallback,qproj 未装)+ `qproj_init --step pc047e3`。**中央 `~/vpipe/bin/pc047e3.slurm`
  → warning shim 转发**(软过渡,候选 INV-ARCH-06)。调用方 `workflow/run_local.sh`:`PC` 指项目 driver、
  `RAW`/`WORK` 硬编码 → `path_resource 01-fastq`/`path_target`(逐字节一致已验证)。**验证**:bash-n+shellcheck
  零新 warning(SITE_LOCAL/GZ_C 是原 driver pre-existing);bash 双模式(项目内定位 ROOT/项目外 warning 不炸)+
  **sbatch job 95**(`/var/spool/slurmd/.../slurm_script` 证 spool 执行,qproj_init warning=0 证显式 `--step`+cwd
  绕过 spool 下 `BASH_SOURCE` 陷阱)+ shim 转发 全过。
  ⚠ **pc047e3 特例**:它是 read-level 预处理(fastp/metaphlan/minimap2),**不调 `assembly.slurm`**——故本试点验证的是
  L1 归位 + qproj.sh 接线 + `VPIPE_ROOT`(非 PATH),**未**覆盖计划原设想的 `${VPIPE_ROOT}/bin/assembly.slurm` mixed-runtime
  修复(那需选一个调 assembly.slurm 的 binning driver 如 p0101 另做,留后续)。
- **C run state 分离 ✅ 完成(2026-07-20;§7-C 事实经 2026-07-21 实证修订,见下 ⚠)**:qproj.sh 加 `qproj_nf_prepare`——
  建 `data/.run-state/$STEP/{work,cache,log}` 并 **export** `NXF_WORK`(→shared)、`NXF_CACHE_DIR`(session cache+history
  →shared)、`QPROJ_NF_LOG`;driver 直接调用(⚠ 非 `$(...)`,否则子 shell 丢 export——单元测试实抓此坑)后
  `nextflow -log "$QPROJ_NF_LOG" run pipeline.nf -resume ...`(**无需 cd**,caller CWD 保留 → 相对 pipeline/input 路径与
  launch-dir 的 `nextflow.config` 仍能解析)。run-state 是 step target 的**兄弟**(`data/.run-state/$STEP`,非
  `data/$STEP/run-state/`):否则 `create_dir_target --clean` 与 driver 的 `trap 'rm -rf "$(path_target)"' ERR` 会连带
  毁掉 resume 所需的 cache。
  **flag 纠错(cli-experiment 实抓)**:`-log` 是 nextflow **global** option,在 `run` **之前**(`nextflow -log X run ...`,
  非 `run ... -log X`)。
  > ⚠ **本条曾载有一条错误事实,2026-07-21 实证推翻(pm `EL-001`/`EL-006`)**。原文写「**无 `NXF_CACHE_DIR`** 这个 env,
  > 靠 `cd $launch` 落 shared」并 export 一个 `QPROJ_NF_LAUNCH`。实际:`NXF_CACHE_DIR` **自 Nextflow 24.10.0 起存在**,
  > Codex 修复 commit `1b74c6e` 已据此改了实现,但当时没回写本文档 → 文档与 shipped 代码分叉。**实证**:①
  > `unzip -p nextflow-{26.04.3,24.10.4}-one.jar | strings | grep NXF_CACHE_DIR` 两 jar 均命中;② 最小 pipeline 真跑
  > (rc=0)后 launch 目录下**既无 `./work` 也无 `./.nextflow`**,`NXF_CACHE_DIR` 内实际生成 `cache/ history/ plr/`;
  > ③ **负对照**:第二次 `-resume` → `cached=1 completed=0`,把 `NXF_CACHE_DIR` 换成空目录 → `cached=0 completed=1`。
  > 代码里**没有** `QPROJ_NF_LAUNCH`。**教训**:reviewer 推翻已写进 SSOT 文档的事实性声称时,必须同一次提交回写文档。

  **验证**:单元测试(直接调用 export 生效)+ **真实 minimal NF 实跑**(Java via minced env)。**建议(文档化,非强制)**:
  publishDir `mode:'copy'`(产物 outlive work cleanup) + driver 侧 `trap 'rm -rf "$(path_target)"' ERR`(MVP;
  staging→promote 可选 hardening)。
- **D 版本契约 ✅ 完成(2026-07-21)**:vpipe `v0.9.0` legacy baseline(git tag = 版本 SSOT,`vpipe version`
  同时充当自己版本元数据的漂移检测器 —— 此前 pyproject / nf manifest / 22 个 4 种格式的 tag 三方分叉且全停滞);
  `vpipe bom generate|show|list|prune`;`vpipe contract check|resolve`;qproj `proj_vpipe_pin/_resolve/_check`
  + `qproj.sh` 的 `qproj_vpipe_root`;试点 pc047e3 已 pin(commit `0d389f2`)。
  - **release store = `~/bioinfo/vpipe-releases/<ver>+<sha7>`**(`DEC-D007`)。实测 `~/bioinfo` 在 spark1 是本地
    ext4 rw、在 spark2 是 nfs4 **`ro`** → **内核免费强制不可变**,并强制「提交时物化、job 内只校验」的纪律。
    release 只装 runtime(允许清单由代码实际触及推导),40.6 MB → 20.8 MB。
  - **Bash resolver 不 shell out 到 Python**,这条被 job 100 实证救了命:计算节点上 `vpipe` CLI **根本不存在**
    (`~/.local` 是节点本地盘)。若当初让它调 Python,spark2 上每个 batch job 都会失败。代价(bash 手搓 YAML)
    由**跨解析器 round-trip 测试**承担,且解析器 fail-closed、无任何回落分支。
  - **验收(sbatch job 100, spark2)**:spool 执行确证;`~/bioinfo` 不可写;正常路径 rc=0 且
    `VPIPE`/`VPIPEBIN`/`assembly.slurm` 全落在 pinned release 内;失败路径 rc=1 响亮 abort 零回落;
    **负对照** —— 把 lock 翻到另一个 commit,driver 连同 00-config.sh 自算的 `VPIPE` 一起跟随到另一棵树。
    没有负对照,「pin 生效」就只是在读我们自己刚赋的变量值。
  - **试点覆盖面扩大**:按用户 2026-07-21 裁定,pc047e3 的 megahit 算 `assembly.slurm` 覆盖面内(只验代码链路
    在位、不真跑组装),新增 `megahit` subcmd 委托 `${VPIPE_ROOT}/bin/assembly.slurm` → **闭掉 §4 那条已知缺口**。
  - **未做(顺延)**:`run_manifest.json`;`database.yml`/`tools.yml` 的实际 immutability 修改(用户裁定只出提案);
    三个 `*_api` 目前一律为 1 且**无实质约束内容**(public surface 要到 E 阶段才存在)。
- **E ABI 收窄**:vpipe 暴露 `lib/vpipe/runtime-v1.sh` + `conf/public/*.config`,00-config/functions 降 private。
- **F fleet 治理**:`qproj deps audit` + firewall CI + `integrations.qproj` 隔离 `manuscript.py`。
- **G Codex soundness 审 + 两仓 commit**(照 provenance 计划惯例:PID 等待、计数跑动态、送审前 ghost 检查)。

## 8. 给 vpipe 的 backlog 提案(`/vpipe-ask --update` 落 IMPROVE_BACKLOG.md,写前 grep 去重;提案不擅改)

1. **新 `INV-ARCH-06`**:禁新增 `bin/p[0-9]*.slurm`/`bin/pc[0-9]*.slurm`;现有 18 个进 drain(抽 primitive→warning shim→下个 major 移 `archive/`)。
2. **immutability**:`database.yml` 19 处 `current` + `tools.yml` `-latest.img` → release/digest pin。
3. **`scripts/audit_subcmd_reuse.py`**:branch hash 归一化 + 调用指纹 + `git blame` 分辨 copy lineage vs 独立实现;CI 对新增完全重复 fail、近似 warning。
4. **`integrations.qproj` adapter** + 计算层 firewall CI(禁 `qproj`/`analyses/data`/project-code 推断)。
5. **public shell surface** `lib/vpipe/runtime-v1.sh`(补 `INV-SH-01` 缺的 API version/deprecation window)。

## 9. 诚实边界(完成后如实声称)

- 归位解决 **ownership + 人体工学 + 中央债**,不解决版本/ABI/fleet(四层须叠加)。
- 未覆盖:真并发下的 lock/race、Windows、staging 跨-FS 原子替换(须同 FS)、vpipe 全 entry 是否都能强制 `copy`(须逐 entry 验)。
- 判据"≥2 项目"只触发 **extraction review**,须两个**独立**需求(`git blame` 排除 copy lineage)+ I/O contract + fixture + contract test + owner 才上提。
