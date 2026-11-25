# 0017 本仓改为 Windows native only

**Status**: accepted

agent 与人工均在 Windows 原生环境工作（仓库在 `D:`，编辑器与宿主在 `C:`），不再使用 WSL 开发端。

## 决定

**本仓只支持 Windows 原生单一环境**，取消「开发端 / 部署端」两级语义，只保留 **仓库检出 ↔ 宿主目录** 的二分。

- **唯一接缝 `tools/seam.lua`**：全仓唯一发起外部进程与文件系统探测的模块。`preflight()` 检查外部工具就位；`quote()` 封装 cmd 引用；`which()` 按 `PATH` 遍历 `.exe`/`.bat` 并真实调用 `--version` 验证有输出，避开 WindowsApps 0 字节假壳（如 `python3`）。
- **路径只有一种形式**：仓库内用相对路径；离开仓库一律正斜杠 + 盘符（`C:/...`），反斜杠进接缝即归一。
- **文件系统探测纯 Lua**：存在性、递归枚举、建目录、绝对化与递归删除统一用 `lfs` + `io`/`os`，不设 shell 降级。
- **子进程只收 `argv`**：`seam.spawn{ argv, cwd, env, stdout, stderr }` 阻塞等完，`seam.spawn_bg` 同一份 argv 形状起完不等（并发用它，日志与退出码落临时目录，由 `bg_done` / `bg_output` / `bg_close` 收）；两者都不收整条命令串，都断言 cmd 8191 字符上限。
- **解释器名统一**：Lua 5.4 只认 `lua`（硬检查在 `tools/cli.lua`），Blender 运行器只认 `python`。

## 拒绝的方案

1. **WSL 与 Windows 双轨并存**：重新制造「测试跑在哪个实现上」的歧义。
2. **用 PowerShell 或 MSYS/Git Bash 包装文件/子进程操作**：引入隐性 shell 依赖与引号分叉，且 Lua `os.execute` 在 Windows 上固定走 `cmd.exe`。
3. **保留带版本号后缀的解释器别名**：徒增机器配置间接层。

## 后果

- 退出码 3 语义为「外部工具不可用（busted / `editor-cli.exe` / Blender / robocopy / `emmylua_check` 缺失）」。
- `tools/qa_slot.lua` 的文件替换语义为「写入期间不破坏旧文件」，不承诺 Windows 下 `os.rename` 瞬间原子替换。
- 测试支撑层由 `tests/support/fs_fixture.lua` 与 `tests/support/cmd_quote.lua` 承载，不再依赖 POSIX 命令。
- 质量工具仍归 dsh-uml-viewer 插件，不恢复 PowerShell 质量脚本；CI（`.github/workflows/test.yml`）运行在 Windows runner 上执行 `full` 车道与 EmmyLua 门禁。
