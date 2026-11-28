# 0038 EmmyLua 作为 agentic coding 的诊断质量门禁

**Status**: accepted（2026-11-24；2026-11-28 修订：统一 IDE 与 CLI 忽略范围、建立 `types/packages/` 公开契约层、关闭 `unnecessary-if` 并将基线升级为「相对路径:诊断码:计数」棘轮）

## 背景

#335/#336 规划的是 sumneko lua-language-server 3.19.2：`.luarc.json` 实证、逐行基线、CI 门禁。两单反复引用的 `docs/research/lua-typing-and-refactoring.md` 在本 checkout 与 GitHub `main` 上都不存在（GitHub API 404），实测数字无法复核；同时 agent 改码规模上去后，Lua 语言服务的分析吞吐成为瓶颈。

EmmyLua Analyzer Rust 是另一个产品：后端为 Rust 语言服务器 `emmylua_ls`（供 Zed 等读取 `.emmyrc.json` 的编辑器接入），`emmylua_check` 是同一分析核心的 CI 友好 CLI，支持 50+ 条诊断，配置真源 `.emmyrc.json`（`.luarc.json` 只作迁移兼容）。它与 LuaLS 不是同一个服务器，两者在字符串键、动态字段上的 rename 语义没有权威逐项对比，不能假定谁自动覆盖谁。

## 决定

- **角色**：EmmyLua 作为 agentic coding 的**诊断型质量门禁**；正式放弃 LuaLS 路线，#335/#336 按 `not planned` 关闭并评论指向本 ADR，本地 LuaLS 产物与实验分支一并清理。
- **检查面**：只做诊断（未定义字段/全局、类型不匹配、改名后的残留调用点等），不含 formatter、注解完整度、文档生成。注解只在诊断确实需要时补。
- **范围**：`client/`、`common/`、`server/` 的自写代码；IDE 与 CLI 统一排除 `tests/`、三端 `packages/`、`server/_trigger/`、自动生成的编辑器 API 声明 `EggyEditorAPI.lua`，以及 `data/`、`docs/`、`tools/`、`tmp/` 等非业务目录。Busted 测试未维护类型声明且测试桩高度动态，保留在 IDE 扫描范围会产生 2.8 万+ 噪音，因此与 CLI 门禁一并在 `.emmyrc.json` 的 `ignoreDir` / `ignoreGlobs` 中排除；`emmylua` 子命令的 `-i` 与 `in_scope` 继续保留作为兜底防线。
- **配置与工具**：诊断规则、引擎全局声明（如 `RemoteEvent`）、公开包契约目录（`workspace.library = ["types"]`）与忽略范围的真源是仓库根 `.emmyrc.json`，IDE 与 CLI 共用。关闭与跨端/单测防御判空冲突的 `unnecessary-if`。上游 `packages/` 的公开入口在 `types/packages/` 以 `---@meta <module_name>` 声明，由 `tests/native/guards/package_types_guard_test.lua` 守卫覆盖与导出键一致性。官方导出的 `EggyAPI.lua` 存根保持原样不改写，其存根缺陷造成的误报留在基线内。CLI 为 `emmylua_check`，固定版本 `0.25.1`，不 vendor 二进制，PATH 上找不到或 `--version` 不匹配时退出码 3；CI 从官方 Release 下载 `emmylua_check-win32-x64.zip` 并校验 SHA-256，本地同样可直接下载预编译包或执行 `cargo install emmylua_check --version 0.25.1 --locked`。
- **入口与门禁**：`lua tools/cli.lua emmylua` 是本地与 CI 的唯一入口。pre-commit 在 `test guards` 之后运行它，拦住 agent 的本地提交（`git-hook-init` / `worktree-init` 识别自家签名头并自动升级旧版 `pre-commit`，第三方 hook 仍拒绝覆盖）；CI 直接将其并入 `test.yml` 的 `full` job 作为 required 门禁步骤，不再单开第二个 runner 与观察任务（2026-11-24 复盘收口）。
- **基线**：`tools/emmylua_baseline.txt` 按「相对路径:诊断码:计数」记录存量诊断（同行同码按一条计），避免增删行导致行号漂移假红。门禁只拦超过基线计数的新诊断；`--update-baseline` 只允许收窄（只能减少计数或删减条目，不能新增），否则退出码 2。
- **稳定性**：`server/world_host/fishing_phase.lua` 的 `pcall` 跨文件推断波动已通过显式类型收口消除；基线内仅余官方 `EggyAPI.lua` 存根缺陷连锁诊断与历史 `Implicit self` 提示。
- **验收**：只做最小红绿自检——人为引入一条基线外诊断时门禁红，撤销后绿。不做 L4b 改名对照实验，不以插件安装量或 IDE 补全速度计收益。

## 后果

- `docs/agents/workflow.md` 的工具链与完成判据收录新子命令；`tools/git_hooks.lua` 的 pre-commit 增加诊断门禁，`git-hook-init` / `worktree-init` 支持识别自家签名头并自动升级旧版 `pre-commit`（第三方 hook 仍拒绝覆盖）。
- `emmylua_check` 是外部工具，Windows 实机调用以本 ADR 落地时的安装为准；版本升级必须同时更新本 ADR、CI（含预编译包 SHA-256）与 `tools/emmylua.lua` 的 `VERSION`（2026-11-24 复盘收口）。
- 字符串键与动态字段的改名盲区仍由 #337 的旧名字符串键守卫覆盖；EmmyLua 的诊断不能替代该守卫。
- EmmyLua 是专有工具名，原样保留，不进 `GLOSSARY.md`。

## 备选方案

- **继续推进 LuaLS（#335/#336）**：路线依赖的调研文档未入主干且吞吐不满足本轮 agentic coding，已正式放弃并关闭两单。
- **两套语言服务并行**：配置口径与基线真源容易漂移，且没有权威语义对照支撑「谁补谁」，暂不采用。
- **零存量直接卡全仓**：存量诊断未知，首日必红，最后只会关掉门禁；改用棘轮基线。
