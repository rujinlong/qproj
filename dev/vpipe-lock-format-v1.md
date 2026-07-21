# `vpipe.lock` 格式规范 v1

> **状态**:阶段 D 契约根。三个解析器(R / Bash / Python)照本文件实现,任何一侧改动必须同 commit 改本文件并 bump `lock_version`。
> **归属**:qproj 拥有 lock(它是**项目**的 pin);vpipe 拥有 BOM(它是**release** 的物料清单)。vpipe 不知道 qproj 存在——`vpipe contract check --lock <path>` 只接受调用者给的路径,绝不推断 `analyses/` 布局(L4 firewall)。

## 1. 为什么是 YAML(DEC-D006,偏离计划 §3-L2 的 TOML 草案)

`proj_vpipe_pin()` 必须**写** lock,而 R 生态**没有 TOML writer**——`RcppTOML` 只读且是编译包。选 TOML 等于要在 R 里手写 TOML 序列化器。YAML 则两侧零新依赖:`yaml` 已在 qproj `Imports`,PyYAML 已被 vpipe 用于 `conf/tools.yml` / `conf/database.yml`。`conda-lock` 亦用 YAML,有先例。

## 2. 文件位置

`<project_root>/analyses/vpipe.lock` — 计划 §6 的 project capsule 布局。**必须进 git**(它是该项目的可重现性记录)。已实测 pc047e3 的 `analyses/.gitignore` 不会吞掉它。

## 3. Schema

```yaml
# vpipe.lock -- machine-managed. 勿手改;用 qproj::proj_vpipe_pin() 重新生成。
lock_version: 1

# ---- Bash resolver 只读这三个字段(约束见 §4)----
resolved_version: "0.9.0"
git_commit: "81b9b33f2c4d8e0a1b6f9c3e7d5a2b8c4e1f0a9d"
release_path: "/home/allen/bioinfo/vpipe-releases/0.9.0+81b9b33"

# ---- 兼容约束 ----
requires: ">=0.9,<1.0"

# ---- 两个 digest(为何是两个见 §5)----
bom_digest: "sha256:...."   # 身份:tier-1 的 git object SHA,确定性
tree_digest: "sha256:...."  # 完整性:物化树磁盘字节的哈希 —— 唯一能发现 release 被改过的
env_digest: "sha256:...."   # 漂移:tier-2 观测态,非确定性

# ---- 声明的契约面 ----
# ⚠ 诚实边界:阶段 D 一律为 1 = "legacy baseline surface,尚未收窄"。
#    public surface 是阶段 E(L3 ABI 收窄)才存在的东西,本期这三个数只被记录与比对,
#    无实质约束内容。有意义的 bump 从阶段 E 开始。
shell_api: 1
nf_api: 1
python_api: 1

# ---- 这次 pin 的来源 ----
pinned_at: "2026-07-21T14:32:05+02:00"
pinned_by: "qproj 0.1.5"
```

## 4. Bash 解析器的硬约束(**改 schema 时必须遵守**)

`qproj.sh` 的 `qproj_vpipe_root` 在 batch 热路径上运行,**不能依赖任何外部程序**(不能 shell out 到 Python——那会把 vpipe CLI 重新塞回 PATH 依赖,正是 DEC-D002 / L3 要禁的)。因此它对 YAML 的读取是**受限的锚定 grep**,而这只在以下约束成立时才可接受:

1. `resolved_version` / `git_commit` / `release_path` **必须是顶层标量、每个占一整行**,不得嵌套、不得多行、不得流式(`{a: 1}`)
2. 值**必须**用双引号包裹(消除注释符 `#`、空格、尾随空白的歧义)
3. 解析器 **fail-closed**:某字段匹配到 **0 次或 ≥2 次**一律 abort,绝不取第一个
4. 解析器**绝不回落** `$HOME/vpipe`——找不到 lock / 字段缺失 / release 树不存在或不可读,一律响亮 abort 并给出可执行的修复指令

> **强制缓解措施**:三解析器 round-trip 测试(R 写 → Bash 读 → Python 读,断言三者取到同一组值)。没有这条测试,「Bash 手搓 YAML」不可接受。

## 5. 为什么是两个 digest(DEC-D008)

BOM 分三层证据,只有 tier-1 是确定性的:

| 层 | 内容 | 可重现? |
|---|---|---|
| **tier-1 内容寻址** | `git_commit` + 各子树 tree SHA(`bin/`、`modules/`、`subworkflows/`、`workflows/`、`conf/`、`pkgs/vpipe/src/`、`main.nf`、`nextflow.config`) | ✅ 单凭 commit 即可重算 |
| **tier-2 观测态** | 20 处 DB `current` 与 7 处 `-latest.img` 在**切 BOM 那一刻**解析到了什么(`realpath` / 存在性 / 容器指纹) | ❌ 换一天重算即不同 |
| **tier-3 声明契约** | `shell_api` / `nf_api` / `python_api` | ✅ |

若单一 digest 同时覆盖 tier-1 + tier-2,则**同一个 commit 在不同日子重新物化会得到不同 digest** → digest 作为 tamper 检查彻底失效。故拆开:

- `bom_digest` 只盖 tier-1(+tier-3)→ 确定性,**不匹配 = lock 没有指向这个 release = hard fail**
- `tree_digest` 盖**磁盘上的字节** → **不匹配 = release 被改过 = hard fail**
- `env_digest` 只盖 tier-2 → **不匹配 = 环境漂移 = 默认 WARN**(附逐条 diff),`--strict` 才 fail

> ⚠ **本节曾写「`bom_digest` 不匹配 = 树被篡改」,2026-07-21 由独立审计推翻并修正。**
> `bom_digest` 的输入全部是**从 git 读出的 object SHA**,没有任何一位来自被解压的文件 ——
> 它证明**身份**不证明**完整性**。实证:往已 pin 的 `bin/assembly.slurm` 追加一行,
> `contract check` 七项全绿。故新增第三个 digest `tree_digest`(由磁盘字节算出)。

默认不对 tier-2 漂移 hard fail 是刻意的:live 配置本就未 pin(硬约束禁改),`current` 会动。默认 fail 会让每个项目永久红灯,工具随即被绕过。

## 6. BOM 不进 lock

BOM 有 30+ 条目(20 DB + 7 容器 + 8 tree SHA),塞进 lock 会让它不可读,且 BOM 属于 **release** 而非 **project**。lock 只带两个 digest 引用它。BOM 实体落在 release store 内:

```
~/bioinfo/vpipe-releases/0.9.0+81b9b33/
├── .vpipe-release.yml     # BOM + 物化 provenance(物化时写入,随后连同整树冻结)
├── bin/  conf/  modules/  subworkflows/  workflows/  pkgs/  main.nf  nextflow.config
└── ...                    # = git archive <commit> 的完整展开
```

读取:`vpipe bom show --release <path>`。

## 7. Release store 与物化(DEC-D007)

`~/bioinfo/vpipe-releases/<resolved_version>+<sha7>/`,可经 `VPIPE_RELEASE_STORE` 覆盖。

**实测约束(2026-07-21)**:spark2 上 `~/bioinfo` 是 `10.100.0.1:/home/allen/bioinfo` 的 **nfs4 `ro`** 挂载;spark1 是本地 ext4 rw。由此:

- 内核**免费替我们强制了 immutability** —— 计算节点物理上改不动 pinned 树
- 物化(`git archive <commit> | tar -x` → 原子 `mv` → `chmod -R a-w`)**只在 spark1 / 提交时**进行
- batch job **只校验不物化**:缺 pin 即响亮 abort。附带好处是并发 job 不会抢同一次解压,job 也不会中途拉代码
- 盘余 603 G,~40 MB/pin(`git archive HEAD` 实测 40.6 MB / 1589 tracked files)。已用 84% → 需 `vpipe bom prune`

## 8. 版本 SSOT

vpipe 现有三处版本互相分叉且全部停滞:`pkgs/vpipe/pyproject.toml` = `0.1.0`、`nextflow.config` manifest = `0.1.0`、22 个 git tag 用了 4 种互不兼容的日期格式(`v26.0502.3` / `v260323.1` / `v260516.1` / `v26.0602.1`)。

→ **git tag 为 SSOT**;首个 legacy baseline = **`v0.9.0`**(对齐 §3-L2 示例的 `>=0.9,<1.0`;留 `0.9.x` 给 D–G 阶段,`1.0` 留给 L3 ABI 收窄落地)。`pyproject` / `manifest` 降为镜像值,**`vpipe version` 本身即是自己版本元数据的漂移检测器**——报三处值并在分叉时告警。

已实测:仓内**无任何地方** pin `vpipe==0.1.0`,bump 安全。
