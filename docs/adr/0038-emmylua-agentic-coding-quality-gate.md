# 0038 EmmyLua 作为 agentic coding 的诊断质量门禁

**Status**: accepted（2026-11-24；取代 #335/#336 的 LuaLS 路线，路线暂缓而非单据关闭）

## 背景

#335/#336 规划的是 sumneko lua-language-server 3.19.2：`.luarc.json` 实证、逐行基线、CI 门禁。两单反复引用的 `docs/research/lua-typing-and-refactoring.md` 在本 checkout 与 GitHub `main` 上都不存在（GitHub API 404），实测数字无法复核；同时 agent 改码规模上去后，Lua 语言服务的分析吞吐成为瓶颈。

EmmyLua Analyzer Rust 是另一个产品：VSCode 插件 `tangzx.emmylua` 本机已装，后端为 Rust 语言服务器；`emmylua_check` 是同一分析核心的 CI 友好 CLI，支持 50+ 条诊断，配置真源 `.emmyrc.json`（`.luarc.json` 只作迁移兼容）。它与 LuaLS 不是同一个服务器，两者在字符串键、动态字段上的 rename 语义没有权威逐项对比，不能假定谁自动覆盖谁。

## 决定

- **角色**：EmmyLua 作为 agentic coding 的**诊断型质量门禁**；LuaLS 路线（#335/#336）暂缓，不关闭、不重写历史 ADR。两单加评论指向本 ADR。
- **检查面**：只做诊断（未定义字段/全局、类型不匹配、改名后的残留调用点等），不含 formatter、注解完整度、文档生成。注解只在诊断确实需要时补。
- **范围**：`client/`、`common/`、`server/` 的自写代码；排除 `tests/`、三端 `packages/`、`_trigger/`、`data/`、`tmp/` 等工具与生成目录。`tests/` 不进 IDE 的 ignoreDir（rename/引用仍覆盖测试文件），由 CLI 门禁的 `-i` 单独排除。
- **配置与工具**：诊断规则真源是仓库根 `.emmyrc.json`，IDE 与 CLI 共用；门禁扫描范围由 `emmylua` 子命令的 `-i` 额外收窄。CLI 为 `emmylua_check`，固定版本 `0.25.1`，不 vendor 二进制，PATH 上找不到或 `--version` 不匹配时退出码 3；安装命令 `cargo install emmylua_check --version 0.25.1 --locked`。
- **入口与门禁**：`lua tools/cli.lua emmylua` 是本地与 CI 的唯一入口。pre-commit 在 `test guards` 之后运行它，拦住 agent 的本地提交；CI 增加独立的非 required 观察任务，稳定后再转 required。
- **基线**：`tools/emmylua_baseline.txt` 按「相对路径:行号:诊断码」逐行记录存量诊断（同行同码的多条按一条计）。门禁只拦基线外的新诊断；`--update-baseline` 只允许收窄（原来的条目可以消失，不能新增），否则退出码 2。
- **稳定性**：实测 `emmylua_check 0.25.1` 对个别跨文件推断项（本轮是 `fishing_phase.lua:225:assign-type-mismatch`）会偶发漏报。初始基线取多次实跑的并集，使存量波动不假红；任何并集外的新诊断仍会拦住。
- **验收**：只做最小红绿自检——人为引入一条基线外诊断时门禁红，撤销后绿。不做 L4b 改名对照实验，不以插件安装量或 IDE 补全速度计收益。

## 后果

- `docs/agents/workflow.md` 的工具链与完成判据收录新子命令；`tools/git_hooks.lua` 的 pre-commit 增加诊断门禁，已有同工具安装的 hook 需重装一次。
- 落地实测：临时 `common/emmylua_gate_probe.lua` 引入一条 `undefined-global` 时门禁退出码 1 并指向该行；删除后退出码 0。`test guards` 96/0、`test full` 1659/0。
- `emmylua_check` 是外部工具，Windows 实机调用以本 ADR 落地时的安装为准；版本升级必须同时更新本 ADR、CI 与 `tools/emmylua.lua` 的 `VERSION`。
- 字符串键与动态字段的改名盲区仍由 #337 的旧名字符串键守卫覆盖；EmmyLua 的诊断不能替代该守卫。
- EmmyLua 是专有工具名，原样保留，不进 `GLOSSARY.md`。

## 备选方案

- **继续推进 LuaLS（#335/#336）**：路线已拆好但依赖文档缺失，吞吐不满足本轮 agentic coding；暂缓而不废弃。
- **两套语言服务并行**：配置口径与基线真源容易漂移，且没有权威语义对照支撑「谁补谁」，暂不采用。
- **零存量直接卡全仓**：存量诊断未知，首日必红，最后只会关掉门禁；改用棘轮基线。
