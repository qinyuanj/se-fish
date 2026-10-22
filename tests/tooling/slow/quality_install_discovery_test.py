"""公开安装入口的固定提交、补丁与现场保护；unittest discover 不得启动显式安装验收。

安装用例全部使用本地 fixture 仓库：桩 viewer 安装器按上游 `scripts/get-uml-viewer` 的
契约工作（读 `<工具>_REPO_URL` / `<工具>_REF`，副本有本地修改即拒绝），不联网、
不依赖 LOVE / Herdr，也不读取主工作区的 `.uml-viewer` 或 `.toolcache`。
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ENTRY = ROOT / "tools/quality/project"

# 直接问 loader「discover 收进了哪些模块」：删掉或漏掉一个回归文件
# 只会让 `Ran N tests` 静默下降，因此这里钉「目录全集 == 收集全集」（#93 补的防漏断言）。
DISCOVER_PROBE = (
    "import unittest\n"
    "loader = unittest.TestLoader()\n"
    "suite = loader.discover({directory!r}, pattern='*_test.py')\n"
    "def walk(node):\n"
    "    for child in node:\n"
    "        if isinstance(child, unittest.TestSuite):\n"
    "            walk(child)\n"
    "        else:\n"
    "            print(type(child).__module__)\n"
    "walk(suite)\n"
)

# 桩安装器：与上游 POSIX 安装器同一契约——按环境变量取来源与固定提交，
# 副本有本地修改（不含安装器自己建的 .venv）时拒绝并保留现场。
STUB_INSTALLER = r'''#!/bin/sh
set -e
[ "$1" = --install-only ] || { echo "stub installer: 只接受 --install-only" >&2; exit 2; }
mkdir -p .uml-viewer
for tool in uml-viewer crapper mutator dryer; do
  case "$tool" in uml-viewer) prefix=UML_VIEWER ;; *) prefix=$(printf %s "$tool" | tr a-z A-Z) ;; esac
  eval "url=\${${prefix}_REPO_URL:?缺少 ${prefix}_REPO_URL}"
  eval "ref=\${${prefix}_REF:?缺少 ${prefix}_REF}"
  directory=".uml-viewer/$tool"
  if [ -e "$directory" ]; then
    if [ -n "$(git -C "$directory" status --porcelain -- . ':!.venv')" ]; then
      echo "stub installer: 安装副本有本地修改，已保留，请先处理：$directory" >&2
      exit 1
    fi
  else
    git init -q "$directory"
  fi
  git -C "$directory" fetch -q --depth 1 "$url" "$ref"
  git -C "$directory" checkout -q --detach FETCH_HEAD
done
cp .uml-viewer/uml-viewer/scripts/uml ./uml
echo "stub installer: done"
'''

PATCH = """diff --git a/src/crapper/core.py b/src/crapper/core.py
index 0000000..1111111 100644
--- a/src/crapper/core.py
+++ b/src/crapper/core.py
@@ -1,2 +1,3 @@
 def score():
+    # se-fish 登记补丁
     return 1
"""

# 最小 Lua C 模块：只用 Lua 5.4 公开头文件，证明 install 按系统头文件编出可加载的 .so。
NATIVE_SOURCE = """#include "lua.h"
#include "lauxlib.h"
static int answer(lua_State *L) { lua_pushinteger(L, 42); return 1; }
int luaopen_fixnative(lua_State *L) {
  lua_newtable(L);
  lua_pushcfunction(L, answer);
  lua_setfield(L, -2, "answer");
  return 1;
}
"""


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def fixture_repository(path, files):
    path.mkdir(parents=True)
    git("init", "-q", str(path))
    for relative, content in files.items():
        target = path / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        if relative.startswith("scripts/"):
            target.chmod(0o755)
    git("-C", str(path), "add", "-A")
    git("-C", str(path), "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
        "commit", "-q", "-m", "fixture")
    commit = git("-C", str(path), "rev-parse", "HEAD")
    # 再加一个提交，确保安装取的是登记提交而不是分支顶端。
    (path / "LATER").write_text("later\n", encoding="utf-8")
    git("-C", str(path), "add", "-A")
    git("-C", str(path), "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
        "commit", "-q", "-m", "later")
    return commit


def fixture_installation(sandbox):
    """driver 是带公开入口的项目检出，target 是 --root 指向的空安装根。"""
    sources = sandbox / "sources"
    commits = {
        "viewer": fixture_repository(sources / "uml-viewer", {
            "scripts/get-uml-viewer": STUB_INSTALLER,
            "scripts/uml": "#!/bin/sh\n# Thin Unix entry, installed in the examined project.\n"}),
        "crapper": fixture_repository(sources / "crapper", {
            "src/crapper/core.py": "def score():\n    return 1\n"}),
        "mutator": fixture_repository(sources / "mutator", {
            "src/mutator/engine.py": "def run():\n    return 0\n"}),
        "dryer": fixture_repository(sources / "dryer", {
            "src/dryer/cli.py": "def main():\n    return 0\n"}),
    }
    lua_commit = fixture_repository(sources / "luafix", {"src/luafix.lua": "return {}\n"})
    driver = sandbox / "driver"
    shutil.copytree(ROOT / "tools/quality", driver / "tools/quality",
                    ignore=shutil.ignore_patterns("__pycache__"))
    (driver / "tools/quality/patches/crapper-fixture.patch").write_text(PATCH, encoding="utf-8")
    config = json.loads((ROOT / "tools/quality/project.json").read_text(encoding="utf-8"))
    directories = {"viewer": "uml-viewer", "crapper": "crapper", "mutator": "mutator", "dryer": "dryer"}
    config["tools"] = {
        name: {"directory": directory, "source": os.path.relpath(sources / directory, driver),
               "commit": commits[name]}
        for name, directory in directories.items()}
    config["tools"]["crapper"]["patches"] = ["tools/quality/patches/crapper-fixture.patch"]
    config["lua_tools"] = {"luafix": {"url": str(sources / "luafix"), "commit": lua_commit, "modules": ["luafix"]}}
    config["busted"]["rocks"] = []
    (driver / "tools/quality/project.json").write_text(json.dumps(config), encoding="utf-8")
    target = sandbox / "installation"
    target.mkdir()
    return driver, target, config


def install(driver, target, *extra):
    env = os.environ.copy()
    env["QUALITY_PYTHON"] = sys.executable
    # install 必须是首个参数：入口只按 $1 判定是否用宿主 Python 引导。
    return subprocess.run([str(driver / "tools/quality/project"), "install", "--root", str(target), *extra],
                          capture_output=True, text=True, encoding="utf-8", errors="replace",
                          timeout=120, env=env)


class QualityInstallTest(unittest.TestCase):
    def test_empty_root_installs_pinned_tools_and_registered_patch_then_repeats(self):
        with tempfile.TemporaryDirectory(prefix="quality-install-") as directory:
            driver, target, config = fixture_installation(Path(directory))
            for _ in range(2):
                result = install(driver, target, "--install-only")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                for tool in config["tools"].values():
                    checkout = target / ".uml-viewer" / tool["directory"]
                    self.assertEqual(git("-C", str(checkout), "rev-parse", "HEAD"), tool["commit"])
                crapper = target / ".uml-viewer/crapper/src/crapper/core.py"
                self.assertIn("# se-fish 登记补丁", crapper.read_text(encoding="utf-8"))
                self.assertEqual(git("-C", str(target / ".uml-viewer/mutator"), "status", "--porcelain"), "")
                self.assertTrue((target / "uml").is_file(), "上游安装器生成的根入口缺失")

    def test_unregistered_edit_fails_and_preserves_bytes(self):
        with tempfile.TemporaryDirectory(prefix="quality-dirty-") as directory:
            driver, target, _ = fixture_installation(Path(directory))
            result = install(driver, target, "--install-only")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for relative in ("mutator/src/mutator/engine.py", "crapper/src/crapper/core.py"):
                source = target / ".uml-viewer" / relative
                original = source.read_bytes()
                edited = original + b"# user unsaved change\n"
                source.write_bytes(edited)
                try:
                    result = install(driver, target, "--install-only")
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn("保留现场", result.stdout + result.stderr)
                    self.assertEqual(source.read_bytes(), edited, f"{relative} 的未登记改动被覆盖")
                finally:
                    source.write_bytes(original)

    def test_untracked_content_fails_and_is_preserved(self):
        with tempfile.TemporaryDirectory(prefix="quality-untracked-") as directory:
            driver, target, _ = fixture_installation(Path(directory))
            result = install(driver, target, "--install-only")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            note = target / ".uml-viewer/crapper/notes.txt"
            note.write_text("keep me\n", encoding="utf-8")
            result = install(driver, target, "--install-only")
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("保留现场", result.stdout + result.stderr)
            self.assertEqual(note.read_text(encoding="utf-8"), "keep me\n")

    def test_source_without_pinned_commit_is_named(self):
        with tempfile.TemporaryDirectory(prefix="quality-missing-commit-") as directory:
            driver, target, config = fixture_installation(Path(directory))
            config["tools"]["mutator"]["commit"] = "0" * 40
            (driver / "tools/quality/project.json").write_text(json.dumps(config), encoding="utf-8")
            result = install(driver, target, "--install-only")
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("mutator", result.stdout + result.stderr)
            self.assertIn("0" * 40, result.stdout + result.stderr)
            self.assertFalse((target / ".uml-viewer/mutator").exists())

    def test_full_install_pins_lua_tools_then_runs_doctor(self):
        with tempfile.TemporaryDirectory(prefix="quality-lua-tools-") as directory:
            driver, target, config = fixture_installation(Path(directory))
            result = install(driver, target)
            output = result.stdout + result.stderr
            checkout = target / ".toolcache/luafix"
            self.assertEqual(git("-C", str(checkout), "rev-parse", "HEAD"), config["lua_tools"]["luafix"]["commit"],
                             output)
            self.assertEqual(git("-C", str(checkout), "remote", "get-url", "origin"),
                             config["lua_tools"]["luafix"]["url"])
            # fixture 安装根没有 uml-quality.json：失败点证明 install 结束后确实交给了 doctor。
            self.assertEqual(result.returncode, 1, output)
            self.assertIn("缺少标准分发配置", output)

    def test_native_lua_tool_is_built_for_lua54_and_not_rebuilt(self):
        """原生库按 `native` 描述编成 Linux 共享库，Lua 5.4 可加载；重复安装跳过已构建产物。"""
        with tempfile.TemporaryDirectory(prefix="quality-native-") as directory:
            sandbox = Path(directory)
            driver, target, config = fixture_installation(sandbox)
            commit = fixture_repository(sandbox / "sources/luanative", {"src/fixnative.c": NATIVE_SOURCE})
            config["lua_tools"]["luanative"] = {
                "url": str(sandbox / "sources/luanative"), "commit": commit, "modules": [],
                "native": {"module": "fixnative", "output": "fixnative.so", "sources": ["src/fixnative.c"]}}
            (driver / "tools/quality/project.json").write_text(json.dumps(config), encoding="utf-8")
            install(driver, target)
            library = target / ".toolcache/luanative/fixnative.so"
            self.assertTrue(library.is_file(), "原生库未构建")
            loaded = subprocess.run([
                config["lua"]["executable"], "-e",
                f"package.cpath={str(library.parent / '?.so')!r}; print(require('fixnative').answer())",
            ], capture_output=True, text=True)
            self.assertEqual((loaded.returncode, loaded.stdout.strip()), (0, "42"), loaded.stderr)
            built = library.stat().st_mtime_ns
            result = install(driver, target)
            self.assertIn("luanative", result.stdout + result.stderr)
            self.assertEqual(library.stat().st_mtime_ns, built, "重复安装重新构建了已有产物")


class QualityDoctorPinTest(unittest.TestCase):
    def test_doctor_reports_bootstrap_pin_drift_before_cache_checks(self):
        with tempfile.TemporaryDirectory(prefix="quality-pin-") as directory:
            sandbox = Path(directory)
            shutil.copytree(ROOT / "tools/acceptance", sandbox / "tools/acceptance")
            shutil.copy(ROOT / "tools/win_shell.lua", sandbox / "tools/win_shell.lua")
            # doctor 先核对标准分发映射（#95），隔离沙箱按仓库根布局提供同一份声明，
            # 本用例的核对对象仍是 bootstrap 固定提交漂移。
            shutil.copy(ROOT / "uml-quality.json", sandbox / "uml-quality.json")
            settings = json.loads((ROOT / "tools/quality/project.json").read_text(encoding="utf-8"))
            settings["lua_tools"]["dry4lua"]["commit"] = "0" * 40
            config = sandbox / "config.json"
            config.write_text(json.dumps(settings), encoding="utf-8")
            result = subprocess.run([str(ENTRY), "--root", str(sandbox), "--config", str(config), "doctor"],
                                    cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 1, output)
            self.assertIn("dry4lua", output)
            self.assertIn("bootstrap", output)
            self.assertIn("固定提交不一致", output)
            self.assertFalse((sandbox / ".toolcache").exists())


class QualityDiscoveryTest(unittest.TestCase):
    def test_discovery_collects_every_regression_file(self):
        """Python 闸门只看退出码：删文件或漏收集只会让 `Ran N tests` 静默下降。

        这里直接问 loader 收进了哪些模块，钉「目录中的 *_test.py 全集 == discover 收集全集」，
        新加的文件没被 pattern 收进、或文件被误删导致覆盖面下降，都在这里红。
        """
        directory = ROOT / "tests/tooling/slow"
        result = subprocess.run([
            sys.executable, "-I", "-B", "-c", DISCOVER_PROBE.format(directory=str(directory)),
        ], cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        collected = {line.strip() for line in result.stdout.splitlines() if line.strip()}
        expected = {path.stem for path in directory.glob("*_test.py")}
        self.assertEqual(collected, expected,
                         f"discover 未收全回归文件：漏 {sorted(expected - collected)}，"
                         f"多 {sorted(collected - expected)}")

    def test_discovery_skips_installation_without_an_explicit_checkout(self):
        with tempfile.TemporaryDirectory(prefix="quality-discovery-") as directory:
            sandbox = Path(directory)
            # 发现仅加载安装 suite；cwd 中的缓存哨兵必须保持原样。
            cache = sandbox / ".toolcache/dry4lua"
            cache.mkdir(parents=True)
            sentinel = cache / "sentinel"
            sentinel.write_bytes(b"untouched\n")
            result = subprocess.run([
                sys.executable, "-I", "-B", "-m", "unittest", "discover",
                "-s", str(ROOT / "tests/tooling/slow"), "-p", "quality_install_test.py",
            ], cwd=sandbox, capture_output=True, text=True, encoding="utf-8", errors="replace")
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("skipped=1", output)
            self.assertIn("Ran 0 tests", output)
            self.assertEqual(sentinel.read_bytes(), b"untouched\n")
            self.assertEqual(list(sandbox.iterdir()), [sandbox / ".toolcache"])


if __name__ == "__main__":
    unittest.main()
