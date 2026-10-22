"""从公开 POSIX 入口验证 argv 转发、覆盖率失败不消费旧报告与 Busted 固定依赖校验。"""
import importlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]


ENTRY = ROOT / "tools/quality/project"

# 桩 venv 解释器：记录收到的 argv，按约定退出码返回，用于验证入口原样转发。
FAKE_PYTHON = '''#!/bin/sh
printf '%s\\n' "$@" > "$(dirname "$0")/argv.txt"
exit 7
'''


class PosixEntryTest(unittest.TestCase):
    """公开入口是 POSIX sh 薄转发：argv 原样交给 project.py，退出码透传。"""

    def _sandbox(self, directory, with_venv=True):
        root = Path(directory)
        (root / "tools/quality").mkdir(parents=True)
        shutil.copy2(ENTRY, root / "tools/quality/project")
        if with_venv:
            python = root / ".uml-viewer/crapper/.venv/bin/python"
            python.parent.mkdir(parents=True)
            python.write_text(FAKE_PYTHON, encoding="utf-8")
            python.chmod(0o755)
        return root

    def test_entry_is_executable_posix_shell(self):
        self.assertTrue(os.access(ENTRY, os.X_OK), "入口必须可直接执行")
        self.assertTrue(ENTRY.read_text(encoding="utf-8").startswith("#!/bin/sh\n"))

    def test_forwards_argv_verbatim_and_passes_exit_code(self):
        with tempfile.TemporaryDirectory(prefix="se-fish-entry-") as directory:
            root = self._sandbox(directory)
            arguments = ["mutation", "common/Rate Limit.lua", "--lines", "3", "$HOME", "*"]
            result = subprocess.run([str(root / "tools/quality/project"), *arguments],
                                    cwd=tempfile.gettempdir(), capture_output=True, text=True)
            self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
            received = (root / ".uml-viewer/crapper/.venv/bin/argv.txt").read_text(encoding="utf-8").splitlines()
            self.assertEqual(received, ["-B", str(root / "tools/quality/project.py"), *arguments])

    def test_missing_venv_names_install_in_chinese(self):
        with tempfile.TemporaryDirectory(prefix="se-fish-entry-") as directory:
            root = self._sandbox(directory, with_venv=False)
            result = subprocess.run([str(root / "tools/quality/project"), "doctor"],
                                    capture_output=True, text=True, encoding="utf-8")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("缺少质量工具 Python 环境", result.stderr)
            self.assertIn("tools/quality/project install", result.stderr)

    def test_install_bootstraps_with_host_python_when_venv_is_missing(self):
        with tempfile.TemporaryDirectory(prefix="se-fish-entry-") as directory:
            root = self._sandbox(directory, with_venv=False)
            host = root / "host-python"
            host.write_text(FAKE_PYTHON, encoding="utf-8")
            host.chmod(0o755)
            env = dict(os.environ, QUALITY_PYTHON=str(host))
            result = subprocess.run([str(root / "tools/quality/project"), "install", "--root", str(root)],
                                    capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
            received = (root / "argv.txt").read_text(encoding="utf-8").splitlines()
            self.assertEqual(received, ["-B", str(root / "tools/quality/project.py"), "install", "--root", str(root)])

    def test_install_detection_only_looks_at_the_first_argument(self):
        # install 探测只判 $1：其它位置出现 install（如同名文件参数）不得切到宿主 Python 引导。
        with tempfile.TemporaryDirectory(prefix="se-fish-entry-") as directory:
            root = self._sandbox(directory)
            host = root / "host-python"
            host.write_text("#!/bin/sh\nexit 9\n", encoding="utf-8")
            host.chmod(0o755)
            env = dict(os.environ, QUALITY_PYTHON=str(host))
            result = subprocess.run([str(root / "tools/quality/project"), "mutation", "install"],
                                    capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 7,
                             "非首位的 install 触发了宿主 Python 引导（退出码应透传 venv 桩的 7）")

    def test_viewer_checkout_matches_registered_patch(self):
        result = subprocess.run([str(ENTRY), "doctor"],
                                cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_failed_full_suite_invalidates_old_coverage(self):
        with tempfile.TemporaryDirectory(prefix="se-fish-quality-") as directory:
            environment = os.environ.copy()
            environment.pop("LUA_PATH", None)
            environment.pop("LUA_CPATH", None)
            root = Path(directory)
            lcov = root / "target/coverage/lua/lcov.info"
            lcov.parent.mkdir(parents=True)
            lcov.write_text("SF:common/Old.lua\nDA:1,1\nend_of_record\n")
            config = root / "project.json"
            config.write_text(json.dumps({
                "lua": {"executable": "lua5.4", "version": "Lua 5.4."},
                "commands": {"coverage": ["lua5.4", "-e", "error('完整测试基线失败')"]},
                "paths": {"lcov": "target/coverage/lua/lcov.info",
                          "stats": "build/quality/luacov.stats.out",
                          "luacov": str(ROOT / ".toolcache/luacov/src")},
            }), encoding="utf-8")
            result = subprocess.run([str(ENTRY), "--root", str(root), "--config", str(config), "coverage"],
                                    capture_output=True, text=True, encoding="utf-8", errors="replace",
                                    env=environment)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("完整测试基线失败", result.stdout + result.stderr)
            self.assertFalse(lcov.exists(), "失败后旧 LCOV 仍可被自动发现")


# 桩脚本：按 mode 扮演 Lua 解释器（interp）或测试命令（test），每次调用记录 argv。
# 解释器分支响应 -v 并模拟 report_lcov.lua 写出 LCOV；测试分支模拟通过完整测试并产出统计。
STUB_SCRIPT = r'''
import json
import sys
from pathlib import Path

log = Path(sys.argv[1])
mode = sys.argv[2]
rest = sys.argv[3:]
with log.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps({"mode": mode, "argv": rest}) + "\n")
if rest and rest[0] == "-v":
    print("Lua 5.4.6  stub interpreter")
    sys.exit(0)
if mode == "test":
    Path("luacov.stats.out").write_text("stub stats\n", encoding="utf-8")
    sys.exit(0)
if any("report_lcov.lua" in item for item in rest):
    Path(rest[-1]).write_text("SF:common/Stub.lua\nDA:1,1\nLF:1\nLH:1\nend_of_record\n", encoding="utf-8")
sys.exit(0)
'''


class QualityInterpreterTest(unittest.TestCase):
    """测试命令 argv 整体不透明：版本检查与报告脚本只能走 lua.executable。"""

    def _make_stub_quality_root(self, directory):
        root = Path(directory)
        log = root / "invocations.jsonl"
        stub = root / "stub.py"
        stub.write_text(STUB_SCRIPT, encoding="utf-8")

        def launcher(name, mode):
            path = root / name
            path.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{stub}" "{log}" {mode} "$@"\n',
                            encoding="utf-8")
            path.chmod(0o755)
            return path

        fake_lua = launcher("fake-lua", "interp")
        test_cmd = launcher("test-cmd", "test")
        config = root / "project.json"
        config.write_text(json.dumps({
            "lua": {"executable": str(fake_lua), "version": "Lua 5.4."},
            "commands": {
                "coverage": [str(test_cmd), "--lane", "full"],
                "mutation_test": [str(test_cmd), "--lane", "fast"],
            },
            "paths": {"lcov": "target/coverage/lua/lcov.info",
                      "stats": "build/quality/luacov.stats.out",
                      "luacov": "unused-by-stub"},
        }), encoding="utf-8")
        return root, config, log

    def _run_quality(self, root, config, *arguments):
        return subprocess.run([str(ENTRY), "--root", str(root), "--config", str(config), *arguments],
                              capture_output=True, text=True, encoding="utf-8", errors="replace")

    def _invocations(self, log, mode):
        return [json.loads(line)["argv"] for line in log.read_text(encoding="utf-8").splitlines()
                if json.loads(line)["mode"] == mode]

    def test_coverage_uses_interpreter_not_test_command_for_version_and_report(self):
        with tempfile.TemporaryDirectory(prefix="se-fish-interp-") as directory:
            root, config, log = self._make_stub_quality_root(directory)
            result = self._run_quality(root, config, "coverage")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((root / "target/coverage/lua/lcov.info").is_file())
            interpreter = self._invocations(log, "interp")
            test_command = self._invocations(log, "test")
            self.assertIn(["-v"], interpreter, "版本检查必须使用 Lua 解释器")
            self.assertTrue(any(any("report_lcov.lua" in item for item in argv) for argv in interpreter),
                            f"报告脚本必须使用 Lua 解释器：{interpreter}")
            self.assertEqual(test_command, [["--lane", "full"]],
                             "测试命令只应收到原始 argv，不应被当作解释器调用 -v 或报告脚本")

    def test_mutation_test_command_is_run_as_opaque_argv(self):
        with tempfile.TemporaryDirectory(prefix="se-fish-interp-") as directory:
            root, config, log = self._make_stub_quality_root(directory)
            result = self._run_quality(root, config, "test")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            interpreter = self._invocations(log, "interp")
            test_command = self._invocations(log, "test")
            self.assertIn(["-v"], interpreter)
            self.assertEqual(test_command, [["--lane", "fast"]],
                             "mutation_test 首项不应被当作 Lua 解释器做版本检查")


class BustedPinnedConfigTest(unittest.TestCase):
    """project.json 登记 Busted 固定依赖：版本校验、doctor 与安装共用同一份 pins。"""

    def test_project_config_pins_busted_dependencies(self):
        config = json.loads((ROOT / "tools/quality/project.json").read_text(encoding="utf-8"))
        # Debian/Ubuntu 的裸 lua 由 alternatives 决定，可能是 5.1；解释器契约写明 lua5.4。
        self.assertEqual(config["lua"]["executable"], "lua5.4")
        self.assertIn("Lua 5.4.", config["lua"]["version"])
        busted = config["busted"]
        self.assertEqual(busted["command"], "busted")
        # LuaRocks 默认树跟随系统 lua 版本，固定依赖必须查 / 装 5.4 树。
        self.assertEqual(busted["luarocks"], ["luarocks", "--lua-version=5.4"])
        # 原生 Linux 上 Python 子进程能直接解析 LuaRocks 的 sh 垫片：测试 argv 首项是裸 busted。
        self.assertEqual(config["commands"]["coverage"][0], "busted")
        self.assertEqual(config["commands"]["mutation_test"][0], "busted")
        self.assertEqual(busted["version"], "2.3.0")
        rocks = {rock["name"]: rock["version"] for rock in busted["rocks"]}
        self.assertEqual(rocks["busted"], "2.3.0-1")
        self.assertEqual(rocks["luassert"], "1.9.0-1")
        self.assertEqual(rocks["luacov"], "0.17.0-1")
        self.assertEqual(busted["sources"]["busted"]["url"], "https://github.com/lunarmodules/busted.git")
        self.assertEqual(busted["sources"]["busted"]["commit"], "56e6d68204d1456afa77f1346bf4e050df65b629")
        self.assertEqual(busted["sources"]["luassert"]["url"], "https://github.com/lunarmodules/luassert.git")
        self.assertEqual(busted["sources"]["luassert"]["commit"], "8d8dc8a54cc468048a128a867f6449a6c3fdd11a")
        # LuaCov 0.17.0-1 由 lua_tools.luacov 的固定提交承载（同一上游 commit）。
        self.assertEqual(config["lua_tools"]["luacov"]["commit"], "b1f9eae400da976b93edb7f94cf5d05f538a0655")


class DoctorBustedTest(unittest.TestCase):
    """doctor 的 Busted 固定依赖校验：失败信息区分解释器缺失、Busted 缺失与版本不符。"""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, str(ROOT / "tools/quality"))

    def setUp(self):
        import project
        self.project = importlib.reload(project)
        self.config = {
            "lua": {"executable": "lua5.4", "version": "Lua 5.4."},
            "busted": {
                "command": "busted",
                "luarocks": ["luarocks", "--lua-version=5.4"],
                "version": "2.3.0",
                "rocks": [{"name": "luassert", "version": "1.9.0-1"},
                          {"name": "luacov", "version": "0.17.0-1"},
                          {"name": "busted", "version": "2.3.0-1"}],
            },
        }

    def _completed(self, stdout="", returncode=0):
        return subprocess.CompletedProcess(args=[], returncode=returncode, stdout=stdout, stderr="")

    def _porcelain(self, name, version):
        return self._completed(f"{name}\t{version}\tinstalled\t/home/user/.luarocks/lib/luarocks/rocks-5.4\n")

    def test_missing_busted_config_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "busted"):
            self.project.doctor_busted(ROOT, {"lua": self.config["lua"]})

    def test_missing_busted_command_is_distinct_from_interpreter_failure(self):
        with mock.patch.object(self.project.shutil, "which", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "Busted"):
                self.project.doctor_busted(ROOT, self.config)

    def test_busted_outside_path_points_to_luarocks_user_bin(self):
        with tempfile.TemporaryDirectory(prefix="se-fish-lr-bin-") as directory:
            busted = Path(directory) / "busted"
            busted.write_text("#!/bin/sh\n", encoding="utf-8")
            busted.chmod(0o755)

            def fake_which(name, *args, **kwargs):
                return "/mock/luarocks" if name == "luarocks" else None

            def fake_run(argv, **kwargs):
                if argv == ["/mock/luarocks", "--lua-version=5.4", "path", "--lr-bin"]:
                    return self._completed(f"{directory}:/usr/local/bin\n")
                raise AssertionError(f"意外调用：{argv}")

            with mock.patch.object(self.project.shutil, "which", side_effect=fake_which), \
                    mock.patch.object(self.project.subprocess, "run", side_effect=fake_run):
                with self.assertRaises(RuntimeError) as caught:
                    self.project.doctor_busted(ROOT, self.config)
            message = str(caught.exception)
            self.assertIn("不在 PATH", message)
            self.assertIn(f'export PATH="{directory}:$PATH"', message)

    def test_busted_version_mismatch(self):
        def fake_run(argv, **kwargs):
            if argv[1:] == ["--version"]:
                return self._completed("2.2.0\n")
            raise AssertionError(f"意外调用：{argv}")

        with mock.patch.object(self.project.shutil, "which", return_value="/mock/busted"), \
                mock.patch.object(self.project.subprocess, "run", side_effect=fake_run):
            with self.assertRaisesRegex(RuntimeError, "2\\.2\\.0"):
                self.project.doctor_busted(ROOT, self.config)

    def test_missing_pinned_rock_is_reported_by_name(self):
        def fake_run(argv, **kwargs):
            if argv[1:] == ["--version"]:
                return self._completed("2.3.0\n")
            if "list" in argv:
                self.assertEqual(argv[:3], ["/mock/luarocks", "--lua-version=5.4", "list"])
                return self._completed("")
            raise AssertionError(f"意外调用：{argv}")

        with mock.patch.object(self.project.shutil, "which", side_effect=["/mock/busted", "/mock/luarocks"]), \
                mock.patch.object(self.project.subprocess, "run", side_effect=fake_run):
            with self.assertRaisesRegex(RuntimeError, r"luassert.*1\.9\.0-1"):
                self.project.doctor_busted(ROOT, self.config)

    def test_pinned_environment_passes(self):
        versions = {"luassert": "1.9.0-1", "luacov": "0.17.0-1", "busted": "2.3.0-1"}

        def fake_run(argv, **kwargs):
            if argv[1:] == ["--version"]:
                return self._completed("2.3.0\n")
            if "list" in argv:
                return self._porcelain(argv[3], versions[argv[3]])
            raise AssertionError(f"意外调用：{argv}")

        with mock.patch.object(self.project.shutil, "which", side_effect=["/mock/busted", "/mock/luarocks"]), \
                mock.patch.object(self.project.subprocess, "run", side_effect=fake_run):
            self.assertIsNone(self.project.doctor_busted(ROOT, self.config))


if __name__ == "__main__":
    unittest.main()
