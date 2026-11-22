# 0017 放弃 WSL，本仓改为 Windows native only

**Status**: accepted（取代原 WSL 开发/Windows 部署方案；[ADR-0009](0009-blender-headless-only.md) 的接缝引用已随之改链）

> **后续变更**：`tools/acceptance_slot.lua` 后来改名 `tools/qa_slot.lua`；「唯一例外是 git 自带的 sh」所指的 `tools/hooks/pre-commit`、`tools/hooks/shim` 已整体删除，本仓现在没有任何非 Windows 原生的入口。下面「slow 车道的五条护栏」里的 `blender_transport` 已移入新增的 `art` 车道，不再随 `slow` 跑。

本机已无 WSL 开发端，agent 与人工都在 Windows 原生环境里工作（仓库检出在 `D:`，编辑器与宿主目录在 `C:`）。而当前工具链在 Windows 上是**整体不可执行**的，不是"需要装点东西"：`tools/wsl_seam.lua` 用 POSIX 命令实现文件系统探测，而 Lua 的 `os.execute` 在 Windows 上走 `cmd.exe`。实测（2026-11-15）：

- `seam.which("busted")` → `nil`；`seam.exists("README.md")` → `false`（文件明明在）；`seam.interop()` → `nil`。于是 `deploy`、`sync`、`test`、`blender` 全部起不来。
- `os.rename` 覆盖已存在目标 → `nil, "File exists", 17`，即 `tools/acceptance_slot.lua` 的"原子替换"在 Windows 上直接失败。
- `python3` 是 WindowsApps 的 0 字节假壳：`--version` 无输出但退出码 0，`which` 会误判可用；真解释器是 `python`（3.12.10）。

决定：**本仓只支持 Windows 原生单一环境**，取消"开发端/部署端"两级语义，只保留 **仓库检出** ↔ **宿主目录** 的二分。

- **接缝改名而非取消**：`tools/wsl_seam.lua` → `tools/seam.lua`，职责重述为"唯一发起外部进程与文件系统探测的地方"。`interop()` → `preflight()`（部署端工具就位）；删除 `to_windows`/`to_linux`；`windows_env` 改 `os.getenv`；`q()` → cmd 引用的 `quote()`；`which` 改按 PATH 遍历 `name.exe`/`name.bat`，且必须做一次真实调用验证（`--version` 有输出才算可用），防止假壳。
- **路径只有一种形式**：仓库内用相对路径；离开仓库一律正斜杠 + 盘符（`C:/Users/<用户名>/...`）。`lfs.currentdir()` 与 `%USERPROFILE%` 的反斜杠进接缝即归一。
- **文件系统探测纯 Lua**：存在性、递归枚举、建目录、绝对化用 `lfs` + `io`/`os`。删除也纯 Lua 递归，不设 `rmdir` 降级——口径只有一套。
- **子进程只有一种形状**：新增 `seam.spawn{ argv, cwd, env, stdout, stderr }`，cmd 引用、`set "X=1" &&`、`cd /d`、输出重定向全部收进接缝；只收 argv，不收整条字符串；断言 cmd 命令行 8191 字符上限。
- **解释器名统一 `lua`**：5.4 硬检查留在 `tools/cli.lua` 入口，不提供带版本号后缀的解释器别名。Blender 运行器只认 `python`。
- **唯一例外是 git 自带的 sh**：`tools/hooks/pre-commit`、`tools/hooks/shim` 保留 `#!/bin/sh`，由 Git for Windows 执行。这不要求在 PATH 上提供任何 shell，故不构成"第二个开发环境"，但作为显式前提写在此处。
- **测试支撑层重组**：`tests/support/sh_fs.lua` → `fs_fixture.lua`（lfs 实现，并收拢 `repo_root()`、`temp_dir()`、`list_dir()`、`find_on_path()`）；`sh_quote.lua` 删除，新增 `cmd_quote.lua`（两者都只对具体期望字面量断言，不拿两份实现互比——逐字相同的实现互比，规则写错时会一起错）；8 个直接吃 POSIX 的用例文件一并替换（`arch_policy_test`、`cli_entry_test`、`static_require_test`、`worktree_init_test`、`wsl_seam_test`、`blender_cli_test`、`deploy_plan_test`、`ability_presets_test`）。

备选方案（拒绝）：

1. **WSL 与 Windows 双轨并存**（加 `is_windows()` 分支、接缝双实现）：重新制造"测试到底跑在哪个实现上"说不清的问题，正是当年采用"只支持 WSL"时拒掉的那一类。
2. **用 PowerShell 包装文件操作**（`rmdir /s /q`、`Move-Item -Force`）：为一次目录删除把 PowerShell 拉回工具链，而 PowerShell 入口正是 #118–#121 刚退役的；且每次起进程的引号与开销都要另付。
3. **依赖 MSYS/Git Bash 作为开发 shell**（保留 sh 命令与单引号规则）：等于把"要装 Git Bash 并让它当 shell"变成隐性前提，而本机 agent 的 shell 与 Lua 的 `os.execute` 并不是同一个 shell。
4. **保留带版本号后缀的解释器别名**：为不改文档给每台机器加一层骗人的间接层；这类别名的存在理由本来就是"WSL 上裸 `lua` 可能是 5.1"。
5. **原地改写原 WSL 方案正文**：会洗掉"当年为什么只留 WSL、拒掉了哪三条备选"这段推理，而这正是现在要被推翻的东西。

后果：

- `exit_code.lua` 与 `cli.lua` 的退出码 3 从"WSL interop 失败"收窄为"外部工具不可用（busted / `editor-cli.exe` / Blender / robocopy 缺失）"。
- slow 车道的五条护栏重定基线：`deploy_transport` 的"interop 不可用"改义为"robocopy 缺失且零写入"，`blender_transport` 的 `--which` 只断言一条正斜杠路径，`pre_commit_hook` 夹具改复制 `tools/seam.lua`，`sync_transport`/`acceptance_slot_write` 只改注释。
- `tools/acceptance_slot.lua` 的替换语义变为"写入期间不破坏旧文件"，不再承诺替换瞬间原子。
- 文档面：`docs/agents/workflow.md`、`docs/agents/art-pipeline.md`、`GLOSSARY.md`、`docs/architecture.md`、`docs/packages-reference.md`、`AGENTS.md` 与 ADR-0009/0011 改口径；历史 ADR（0007、0014 等）正文里的 WSL 字样**不追改**。
- 本仓无 CI（历史上也从未有 `.github/`），故无 CI 改动项。

**历史与不撤销的部分**：上一次方向相反的迁移是 2026-10-22 的 #115/#116（`12ce496`、`3e78c25`、`5e2d70f`），同期 #118–#121 删除了 `uml.ps1` 与 `tools/quality/*.ps1`。本次是回程，但**这两件事都不撤销**：质量工具仍归 dsh-uml-viewer 插件，不复活 PowerShell 质量入口；原 WSL 方案拒掉的三条备选（保留 Windows 检出、rsync 写盘、在 WSL 装编辑器）今天依然不采纳，只是 WSL 已整体退出。
