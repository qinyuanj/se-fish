"""串行复验公开质量入口；全量 mutation 仅作用显式选定的代表文件（取代 verify.ps1）。

每个阶段都经公开入口 `tools/quality/project` 以子进程执行，各自持仓库锁；本模块自身不持锁，
否则子进程会被同仓库互斥拒绝。
"""
from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENTRY = HERE / "project"
TOOLING = "tests/tooling/slow"
INSTALL_SUITE = f"{TOOLING}/quality_install_test.py"
# 复验明确选定 1 个代表文件，本机逻辑核心充裕，故显式放开到 12 个 worker（#98 AC3 的扩充依据）；
# 墙钟预算不扩充，沿用 mutation 的 60 分钟默认值。超过预算会以退出码 4 失败关闭，
# 部分范围不作为验收证据。
WORKERS = ["--max-workers", "12"]


class VerifyError(RuntimeError):
    pass


def tooling_python(root):
    python = Path(root) / ".uml-viewer/crapper/.venv/bin/python"
    if not python.is_file():
        raise VerifyError(f"缺少 crapper venv：{python}；请先运行 tools/quality/project install")
    return python


def run_test_tooling(root):
    """用 crapper venv 发现并执行 tests/tooling/slow；退出码透传。"""
    root = Path(root)
    return subprocess.run([str(tooling_python(root)), "-B", "-m", "unittest", "discover",
                           "-s", str(root / TOOLING), "-p", "*_test.py"],
                          cwd=root).returncode


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stage(root, arguments, allowed=(0,)):
    code = subprocess.run([str(ENTRY), "--root", str(root), *arguments], cwd=root).returncode
    if code not in allowed:
        raise VerifyError(f"质量阶段失败（退出码 {code}）：{' '.join(arguments)}")


def verify(root, file, install_root=None):
    root = Path(root).resolve()
    source = root / file
    if not source.is_file():
        raise VerifyError(f"找不到代表文件：{file}")
    before = digest(source)
    stage(root, ["doctor"])
    stage(root, ["quality"])
    stage(root, ["mutation", file, *WORKERS], (0, 3))
    stage(root, ["mutation", file, *WORKERS], (0, 3))
    stage(root, ["mutation", "--mutate-all", file, *WORKERS], (0, 3))
    if digest(source) != before:
        raise VerifyError("mutation 运行后原业务源码发生变化。")
    if run_test_tooling(root):
        raise VerifyError("公开质量入口失败路径测试未通过。")
    # discover 按设计从不执行安装 suite：quality_install_test.py 的模块入口只吃显式独立检出，
    # 被导入时恒 SkipTest。这里补一条自动执行路径，缺省独立检出时降级为警告而不阻塞复验。
    suite = root / INSTALL_SUITE
    if not install_root:
        print(f"警告：未提供 --install-root，安装 suite 未执行：{suite} 需要独立检出的绝对路径；"
              "手工步骤见 tools/quality/README.md。", file=sys.stderr)
    elif subprocess.run([str(tooling_python(root)), "-I", "-B", str(suite), str(install_root)],
                        cwd=root).returncode:
        raise VerifyError("安装 suite（独立检出）未通过。")
    if subprocess.run([str(root / "uml"), "ir"], cwd=root).returncode:
        raise VerifyError("IR 生成失败。")
    print("命令验证完成；核对第二次差分的复用记录。GUI 展示、右键刷新、邮件队列和协议重启需按 "
          "README 的真实窗口步骤另行验收。")
    return 0
