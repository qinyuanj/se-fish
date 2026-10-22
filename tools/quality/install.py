"""固定工具组合的安装：viewer / crapper / mutator / dryer checkout、登记补丁、Lua 依赖与 Busted rocks。

viewer 及其工具 checkout 由 uml-viewer 上游 POSIX 安装器（固定提交的 `scripts/get-uml-viewer`）
拉取并建 Linux venv；本模块负责它之前的精确预检与之后的补丁应用、复核。上游安装器遇到
本地修改会拒绝 fetch，因此已登记补丁在交给它之前先反向撤下，结束后再应用并逐字复核。
"""
from __future__ import annotations

import io
import os
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

from locking import repository_lock

# 上游安装器自己在工具 checkout 内建的路径，不算用户改动（与 uml_posix.PROVISIONED_DIRECTORIES 同口径）。
PROVISIONED = (".venv", "__pycache__", ".pytest_cache")
PREFIX = {"viewer": "UML_VIEWER"}
REPAIR = "请将该 checkout 移到备份目录后重跑 tools/quality/project install"


class InstallError(RuntimeError):
    pass


def git(*args, check=True, **kwargs):
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    result = subprocess.run(["git", *map(str, args)], **kwargs)
    if check and result.returncode:
        raise InstallError(f"git {' '.join(map(str, args))} 失败：{(result.stderr or '').strip()}")
    return result


def provisioned(path):
    parts = Path(path.rstrip("/")).parts
    return any(part in PROVISIONED or part.endswith(".egg-info") for part in parts)


def normalize(diff):
    """补丁逐字比对；只忽略换行风格、`index` 缩写行与 Git 空白上下文行的写法差异。"""
    lines = []
    for line in diff.replace("\r\n", "\n").split("\n"):
        if line.startswith("index "):
            continue
        lines.append("" if line == " " else line)
    return "\n".join(lines).strip()


def expected_diff(project_root, tool):
    return normalize("\n".join((project_root / patch).read_text(encoding="utf-8")
                               for patch in tool.get("patches", []) if patch))


def preflight(name, directory, project_root, tool):
    """已有 checkout 的 dirty 只能精确等于仍需保留的登记补丁；否则保留现场失败。"""
    if not directory.exists():
        return
    if not (directory / ".git").exists():
        raise InstallError(f"{name} 安装目录不是 git checkout：{directory}，保留现场；{REPAIR}")
    if git("-C", directory, "diff", "--cached", "--name-only").stdout.strip():
        raise InstallError(f"{name} 有未登记暂存内容，保留现场；{REPAIR}")
    status = git("-C", directory, "status", "--porcelain", "-z").stdout
    untracked = [entry[3:] for entry in status.split("\0")
                 if entry.startswith("?? ") and not provisioned(entry[3:])]
    if untracked:
        raise InstallError(f"{name} 有未跟踪内容 {'、'.join(untracked)}，保留现场；{REPAIR}")
    actual = normalize(git("-C", directory, "diff", "--no-ext-diff").stdout)
    if actual and actual != expected_diff(project_root, tool):
        raise InstallError(f"{name} 有未登记差异（含历史私有补丁），保留现场；{REPAIR}")


def withdraw_patches(directory, project_root, tool):
    """预检已证明 dirty 等于登记补丁；交给上游安装器前撤下，使其看到干净副本。"""
    for patch in reversed([p for p in tool.get("patches", []) if p]):
        path = project_root / patch
        if git("-C", directory, "apply", "--reverse", "--check", path, check=False).returncode == 0:
            git("-C", directory, "apply", "--reverse", path)


def apply_patches(name, directory, project_root, tool):
    for patch in [p for p in tool.get("patches", []) if p]:
        path = project_root / patch
        if git("-C", directory, "apply", "--reverse", "--check", path, check=False).returncode == 0:
            continue
        if git("-C", directory, "apply", "--check", path, check=False).returncode:
            raise InstallError(f"{name} 补丁无法应用：{patch}")
        git("-C", directory, "apply", path)
    actual = normalize(git("-C", directory, "diff", "--no-ext-diff").stdout)
    if actual != expected_diff(project_root, tool):
        raise InstallError(f"{name} 未提交差异与登记补丁不一致；请重新生成补丁"
                           f"（git -C {directory} diff > <patch>）")


def run_viewer_installer(project_root, root, config, python):
    """从 viewer 固定提交导出 scripts/ 后执行上游 POSIX 安装器；不依赖兄弟工作树的未提交状态。"""
    viewer = config["tools"]["viewer"]
    source = (project_root / viewer["source"]).resolve()
    archive = subprocess.run(["git", "-C", str(source), "archive", "--format=tar", viewer["commit"], "scripts"],
                             capture_output=True)
    if archive.returncode:
        raise InstallError(f"无法从 viewer 固定提交读取安装器：{archive.stderr.decode(errors='replace').strip()}")
    env = os.environ.copy()
    for name, tool in config["tools"].items():
        prefix = PREFIX.get(name, name.upper())
        env[f"{prefix}_REPO_URL"] = str((project_root / tool["source"]).resolve())
        env[f"{prefix}_REF"] = tool["commit"]
    if python:
        env["UML_PYTHON_EXECUTABLE"] = python
    with tempfile.TemporaryDirectory(prefix="se-fish-viewer-installer-") as temporary:
        with tarfile.open(fileobj=io.BytesIO(archive.stdout)) as bundle:
            bundle.extractall(temporary, filter="data")
        result = subprocess.run(["sh", str(Path(temporary) / "scripts/get-uml-viewer"), "--install-only"],
                                cwd=root, env=env)
    if result.returncode:
        raise InstallError(f"uml-viewer 上游安装器失败（退出码 {result.returncode}）")


def install_lua_tools(root, config):
    for name, tool in config["lua_tools"].items():
        directory = root / ".toolcache" / name
        if not (directory / ".git").exists():
            if directory.exists():
                raise InstallError(f"{name} 缓存不是 git checkout，保留现场；请移走后重跑 tools/quality/project install")
            directory.parent.mkdir(parents=True, exist_ok=True)
            git("clone", "-q", tool["url"], directory, capture_output=False)
            git("-C", directory, "checkout", "-q", "--detach", tool["commit"])
        actual = git("-C", directory, "rev-parse", "HEAD").stdout.strip()
        if actual != tool["commit"]:
            raise InstallError(f"{name} 缓存提交不符：{actual}，预期 {tool['commit']}；"
                               f"请移走缓存后重跑 tools/quality/project install")
        print(f"{name} {actual}")
        if "native" in tool:
            build_native(name, directory, tool["native"], config)


def lua_include_flags(config):
    """系统 Lua 头文件经 pkg-config 解析（`lua.pkg_config`，默认 lua5.4）。"""
    package = config.get("lua", {}).get("pkg_config", "lua5.4")
    result = subprocess.run(["pkg-config", "--cflags", package], capture_output=True, text=True)
    if result.returncode:
        raise InstallError(f"找不到 Lua 头文件（pkg-config {package} 失败）；请安装 liblua5.4-dev 与 pkg-config")
    return result.stdout.split()


def build_native(name, directory, native, config):
    """把 checkout 内的 C 源码编成 Lua 可 require 的共享库；产物已存在则跳过。

    不链接 liblua：符号由加载它的 Lua 5.4 解释器提供（Linux 上 C 模块的常规做法）。
    """
    output = directory / native["output"]
    if output.is_file():
        print(f"{name} 已构建 {output.name}，跳过")
        return
    sources = [str(directory / source) for source in native["sources"]]
    command = ["cc", "-shared", "-fPIC", "-O2", *lua_include_flags(config), "-o", str(output), *sources]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        output.unlink(missing_ok=True)
        raise InstallError(f"{name} 原生库构建失败：{' '.join(command)}\n{result.stderr.strip()}")
    print(f"{name} 构建 {output.name}")


def install_rocks(config):
    """按 busted.rocks 清单经 LuaRocks（用户树）安装固定版本；已安装则跳过，可重跑。"""
    spec = config["busted"]
    luarocks = list(spec.get("luarocks", ["luarocks"]))
    import shutil
    if not spec["rocks"]:
        return
    if shutil.which(luarocks[0]) is None:
        raise InstallError("缺少 LuaRocks 命令；无法安装 Busted 固定依赖，请先安装 LuaRocks 3.x")
    for rock in spec["rocks"]:
        listed = subprocess.run([*luarocks, "list", rock["name"], "--porcelain"], capture_output=True, text=True)
        rows = [line.split("\t") for line in listed.stdout.splitlines()]
        if any(len(f) >= 3 and f[0] == rock["name"] and f[1] == rock["version"] and f[2] == "installed"
               for f in rows):
            continue
        if subprocess.run([*luarocks, "install", "--local", rock["name"], rock["version"]]).returncode:
            raise InstallError(f"{rock['name']} {rock['version']} 安装失败")


def install(project_root, root, config, install_only=False, python=None):
    """持锁完成全部工具替换；返回后由调用方另行持锁运行 doctor。"""
    project_root, root = Path(project_root).resolve(), Path(root).resolve()
    with repository_lock(root):
        for name, tool in config["tools"].items():
            source = (project_root / tool["source"]).resolve()
            if git("-C", source, "cat-file", "-e", f"{tool['commit']}^{{commit}}", check=False).returncode:
                raise InstallError(f"{name} 本地来源 {source} 缺少固定提交 {tool['commit']}")
        checkouts = {name: root / ".uml-viewer" / tool["directory"] for name, tool in config["tools"].items()}
        # 全部工具先预检，任何一项不符都在改动前失败。
        for name, tool in config["tools"].items():
            preflight(name, checkouts[name], project_root, tool)
        for name, tool in config["tools"].items():
            if checkouts[name].exists():
                withdraw_patches(checkouts[name], project_root, tool)
        run_viewer_installer(project_root, root, config, python)
        for name, tool in config["tools"].items():
            apply_patches(name, checkouts[name], project_root, tool)
        if install_only:
            return 0
        install_lua_tools(root, config)
        install_rocks(config)
    return None

