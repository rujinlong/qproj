# qproj 溯源引擎抽取计划（门 2 / Tier 2）

> 把 pc051e1-PhageNAMPT 里对抗硬化过的 provenance 引擎抽进 `qproj/R/`,成为可复用框架。
> 用户 2026-07-18 立项:`pv_*` 命名保留;用**真实项目 p0101-BTEXvirome** 当第二 fixture、迭代改进;完成后 **Codex 审核**。
> 本文是跨 session 执行入口 —— 接手先读它。源系统的对抗史与铁律见 pc051e1 `docs/PROVENANCE_NEXT.md` / `PROVENANCE_GRAPH_DESIGN.md`。

## 安全网(已就位)
- **golden baseline**:pc051e1 commit `e4469e6`,tag `provenance-preextract-golden`。
  `Rscript scripts/release.R --check` = **265 ok · 0 fail · 2 skip**,输出 **md5 `e2a111460a00fcf9e08d064724ee527e`**。
- **铁律**:抽取全程 **pc051e1 不动**,直到阶段 E 才改它的 shim;每次改完 pc051e1 侧,`release --check` 输出 md5 **必须复现 golden**(或逐字解释差异),且负控套件仍"全部按预期"。

## 现状勘查(2026-07-18 已做)
- qproj 是真 R 包(`~/github/rujinlong/qproj`,roxygen md,RoxygenNote 7.3.3),**`yaml` 已在 Imports**;`jsonlite` 在 Suggests(observe 用它写 manifest → 需**提到 Imports**)。
- qproj/R/ 尚无 provenance 代码;`tests/testthat/fixtures/` 是既有约定 → **第二 fixture 的家**。
- pc051e1 `DESCRIPTION` 已 `Imports: qproj`。
- 源引擎 5 文件 + 耦合:`_provenance_common.R`(base)← `_provenance_tx.R` / `_provenance_schema.R` source 它;`release.R` / `observe_run.R` source common+schema(+tx)。

## 端状态架构
```
qproj/R/provenance-common.R   pv_path_* · pv_t_* typed validators · asset-group registry · 闭包/code-bundle 算法
qproj/R/provenance-schema.R   pv_contract_validate · pv_top_keys · typed AST · axes-overlap policy
qproj/R/provenance-tx.R       pv_tx_* 事务/journal/recover
qproj/R/provenance-release.R  pv_release_check(root, contract_path, ...) · pv_release_manifest(...) · C1..C17
qproj/R/provenance-observe.R  pv_observe_run(root, asset=, producer=, fresh=, label=)
   导出:仅入口函数 @export(pv_release_check/pv_release_manifest/pv_observe_run);
         内部 helper 不导出(同包可见)。负控/探针改用 qproj:::pv_*(或按需 @export)。
pc051e1/scripts/release.R      瘦 shim:parse args → qproj::pv_release_check(root=here::here(),…)
pc051e1/scripts/observe_run.R  瘦 shim
pc051e1/publication.yml        契约,不动
pc051e1/scripts/build_all_supp_tables.R  项目专属(补充表编号),留在 pc051e1
qproj/tests/testthat/fixtures/p0101 (或指向真 repo)  第二 fixture
```

## ★ 核心难点:root 贯通(门 2 的全部意义)
`PV_PROJ_ROOT` 现在是**加载时** `local({ getwd() + 自校验 scripts/_provenance_common.R 存在 })` 的全局常量。
**包化后立刻炸**(实测:`load_all(qproj)` 报「必须从项目根加载」)—— 因为包从 qproj 目录加载,cwd 无那文件。
这正是门 2 被推迟的原因:root 必须**从外部显式传**,传错要**立刻可观测**(不能退回隐式全局 —— Codex R19-C 判过:「有参数没人传」比「没有参数」更坏)。

**churn 有界**(已数):`PV_PROJ_ROOT` 引用 ~8 处、`pv_path_abs()` 调用 ~8 处。判定函数**多数已有 `root` 参数**(schema.R 内部 6 个 call site **已显式传 root**),只需去默认。真正要新加线的两处:

1. **common.R:324 `pv_resolver_call` —— ★ 轴根 vs 项目根消歧(最易错、Codex 必查)**:
   该函数局部 `root` 是**轴根**(契约相对串,如 `analyses/manuscript/figures`),而 `pv_path_abs(p)`/`pv_path_abs(root)` 需要**项目根**(绝对)。**同一个词指两个东西**。
   → 修法(照 PROVENANCE_NEXT「root 贯通」节):**先改名**(轴根 → `axis_root`),再给函数加**项目根**参数 `proj_root`,`pv_path_abs(p, proj_root)` / `pv_path_abs(axis_root, proj_root)`。
2. **tx.R `pv_tx_journal_valid(j)` / `pv_tx_recover(verbose)` —— 无 root 参数(文档已标承重、未做)**:
   `pv_path_abs(x$path)` 用默认。→ 加 `root` 参数,`pv_path_abs(x$path, root)`。
   ★ recovery 跑在**契约加载之前**(无 cfg)→ root 的真相源**只能是 PROJ**(两条 CLI 传 `PROJ`)。
3. **schema.R**:`pv_contract_path_safe`/`pv_contract_axes`/`pv_contract_validate` 去 `= PV_PROJ_ROOT` 默认(内部已threads)。
4. **pv_path_abs**:去 `= PV_PROJ_ROOT` 默认 → **root 必需**(传漏立刻 `argument "root" is missing` 报错 = 门 2 要的「传错立刻可观测」)。
5. 入口函数 `pv_release_check`/`pv_observe_run` 收 `root`,一路下传。**删加载时 `PV_PROJ_ROOT <- local({...})`**。

## 分阶段(每阶段可验、pc051e1 全程绿)
- **A 机械搬运**:`cp` 5 文件 → qproj/R/(重命名),roxygen 文件头,`jsonlite` 提 Imports,`document()`。**先只求 load_all 过**(需先做 root 的加载时修复,否则炸)。
- **B root 贯通**:按上「核心难点」1-5 改;`load_all` 过;写 qproj 内 smoke test(拿一个绝对 root 跑 `pv_contract_validate`)。
- **C 抽 CLI 逻辑**:`release.R` 的 `if(DO_CHECK)`@1767 / `if(DO_MANIFEST)`@1953 主块 → `pv_release_check`/`pv_release_manifest`;`observe_run.R` 的 asset/producer 模式 → `pv_observe_run`。
  ⚠️ **observe 的 re-exec-under-lock**(`pv_tx_reexec_under_lock(SCRIPT_PATH,…)`,用 `--file=` 拿脚本路径)是移植硬点:包里无脚本路径 → 改「内部 re-exec 参数」或让 shim 传自身路径(PROVENANCE_NEXT 门 2 附录已给方向:child 验证继承的 lock fd,或内部 re-exec 参数而非纯环境变量)。
- **D 第二 fixture = p0101-BTEXvirome**:给 p0101 写 `publication.yml`(它的真实资产,需先摸 p0101 结构)→ 跑 `qproj::pv_release_check(root=<p0101>)`。**这一步会暴露所有"pc051e1-专属假设"**(硬编码路径名、`table_S<N>` 约定、`meta` 轴名…)→ **迭代改进框架**直到 p0101 也能跑。qproj/tests 加两个 fixture 测试(pc051e1 契约 + p0101 契约)。
- **E 改接 pc051e1 shim** → `qproj::`;`release --check` md5 **必须 == golden `e2a1114`**;负控套件"全部按预期"。**这是唯一动 pc051e1 的阶段。**
- **F Codex soundness 审核**:严格照 PROVENANCE_NEXT「送 Codex 惯例」—— soundness/completeness 措辞(非"攻击")、prompt 声明「所有『已做』是声称、请评估是否闭合」+「计数一律跑动态输出」、送审前跑 ghost 检查、`BASE=$(git rev-parse --short HEAD)` 脚本填 hash、**PID 等待**(`kill -0`,绝不 `pgrep -f codex`)。逐条裁决 flag→修→复核。
- **G 收尾**:`R CMD INSTALL qproj` → pc051e1 最终回归(md5==golden)→ 两仓库 commit;更新 pc051e1 PROVENANCE_NEXT 把门 2 从「产品决策」移到「已做」。

## 诚实边界(完成后如实声称,勿夸大)
「移植性已证」= pc051e1 回归(golden md5)+ p0101 真项目跑通。**p0101 是真第二数据点**(满足文档「两个数据点才能画直线」,比合成 fixture 强 —— §19i/§19j 的合成第三组明确不算)。仍未覆盖:第 3、第 4 个项目的多样性、Windows、真并发。这些留门 2 之后。
