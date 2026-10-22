# 0008 WSL 开发、Windows 部署的接缝

**Status**: accepted

开发端迁到 WSL2：仓库检出、Lua 5.4、Busted、原生 node 与 teamai 都在 WSL 运行；部署端仍是 Windows 侧的 eggitor 编辑器、`editor-cli.exe` 与宿主目录。两者之间只保留一层窄接缝 `tools/wsl_seam.lua`：仓库内路径一律是 Linux 形式，只有拼 `robocopy.exe` / `editor-cli.exe` 的命令行时用 `wslpath` 转成 Windows 形式；目录枚举、存在性判断、删除与输出捕获都是 POSIX 实现，直接作用于 `/mnt/c` 下的路径。

接缝层的约定：

- **只支持 WSL**，不保留 Windows 原生分支。Windows 检出不再是部署站。
- interop 按 PATH 解析 `cmd.exe` 与 `robocopy.exe`，不写死 `/mnt/c/...`；`deploy` 在镜像之前预检，失败时非零退出且一个文件都不写。
- 不能用 `wslpath -w` 的退出码判断 interop：它对不存在的路径也返回 0。
- Windows 环境推导（`USERPROFILE`、`%TEMP%`）经 `cmd.exe` 取值；输出里的 UNC 警告按「盘符开头的行」跳过，选中行含 `%` 视为变量未定义。
- 宿主目录默认由 `USERPROFILE` 拼出；`EGGY_WORKSPACE` 接受 `/mnt/c/...` 与 `C:\...` 两种形式，空串当作未设置。
- robocopy 的成功判据不变：退出码 < 8，且日志里有 `ROBOCOPY` 横幅（横幅证明命令真的执行过）。
- `editor-cli.exe` 的位置由接缝层推导；interop 或推导失败报错并返回非零，编辑器没装或没打开本图则打印跳过并返回 0。

备选方案（拒绝）：

1. **保留 Windows 检出作部署站**：两个检出会漂移，测试与部署跑在不同树上的事实无法用文档约束住。
2. **用 rsync 直接写 `/mnt/c`**：会改变既有的镜像与字节核对口径（`/MIR` 的删除语义、robocopy 退出码与横幅证据），9P 上的时间戳行为也与 Windows 侧不同。
3. **在 WSL 安装编辑器组件**：编辑器只随 Windows 客户端分发，开发端不承担编辑器运行环境。

后果：部署链路的测试分成两层——fast 车道用桩验证编辑器命令边界（跳过/失败/推送复核），slow 车道用真 CLI 子进程、真 interop 与真 `robocopy` 验证文件树、stale 删除、退出码与隔离。`EGGY_WORKSPACE` 与临时宿主目录只落在 Windows `%TEMP%` 下，测试不碰真实宿主目录。开发端不再有平台相关 pending。
