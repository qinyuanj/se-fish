"""公开 mutation 入口保留运行期间的外部保存与有效快照。"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


# 真实拉起 crapper/mutator 的端到端用例默认跳过（维护者指令，spec/116）：
# 收尾复验（#122）以 SE_FISH_QUALITY_E2E=1 统一实跑，不得改成 mock 假绿。
import os as _os
_E2E = _os.environ.get('SE_FISH_QUALITY_E2E') == '1'
_E2E_REASON = '真实拉起 crapper/mutator 的端到端用例默认跳过；spec/116 收尾复验（#122，维护者协调）以 SE_FISH_QUALITY_E2E=1 统一实跑'

ROOT = Path(__file__).resolve().parents[3]
PYTHON = ROOT / '.uml-viewer/crapper/.venv/bin/python'
OLD = b'{:namespace "common.Example" :forms [] :outcomes {}}\n'
EDIT = '-- 用户运行期间保存\nreturn {}\n'.encode('utf-8')
SOURCE = b'local M={}\nfunction M.value(x) return x + 1 end\nreturn M\n'


@unittest.skipUnless(_E2E, _E2E_REASON)
class MutationSourceSafetyTest(unittest.TestCase):
    def fixture(self, root, action='edit', phase='worker'):
        source = root / 'common/Example.lua'
        source.parent.mkdir()
        source.write_bytes(SOURCE)
        snapshot = root / '.metrics/mutate/common.Example.edn'
        snapshot.parent.mkdir(parents=True)
        snapshot.write_bytes(OLD)
        quality = root / 'tools/quality'
        shutil.copytree(ROOT / 'tools/quality', quality)
        # 图上入口：原生 uml 读取临时项目的 uml-quality.json，viewer 本体用本检出的固定安装。
        shutil.copy(ROOT / 'uml', root)
        shutil.copy(ROOT / 'uml-quality.json', root)
        # 使用隔离 checkout 的实际包，临时项目自身也拥有公开分发入口。
        for name in ('mutator', 'crapper'):
            shutil.copytree(ROOT / f'.uml-viewer/{name}/src', root / f'.uml-viewer/{name}/src')
        # symlink 复用已安装 venv（含 tree-sitter）；mutation.py 把临时项目的 src 插到 sys.path 最前。
        (root / '.uml-viewer/crapper/.venv').symlink_to(PYTHON.parents[1].resolve(), target_is_directory=True)
        (root / 'coverage.lua').write_text("local f=assert(io.open('luacov.stats.out','w')); f:write('3:common/Example.lua\\n1 1 1 \\n'); f:close()\n")
        operation = ('target.unlink(missing_ok=True)' if action == 'delete' else
                     f'target.write_bytes({EDIT!r})')
        (root / 'test.py').write_text(
            'from pathlib import Path\n'
            f'target=Path({str(source)!r})\n'
            f'root=Path({str(root)!r})\n'
            f'if {"Path.cwd() != root" if phase == "worker" else "Path.cwd() == root"}:\n'
            f'    {operation}\n', encoding='utf-8')
        config = json.loads((quality / 'project.json').read_text(encoding='utf-8'))
        config['commands'] = {'coverage': [config['lua']['executable'], 'coverage.lua'],
                              'mutation_test': [str(PYTHON), '-B', str(root / 'test.py')]}
        config['paths']['luacov'] = str(ROOT / '.toolcache/luacov/src')
        (quality / 'project.json').write_text(json.dumps(config), encoding='utf-8')
        return source, snapshot

    def invoke(self, root, entry):
        env = os.environ.copy()
        env['PYTHONPATH'] = os.pathsep.join(str(root / f'.uml-viewer/{name}/src') for name in ('mutator', 'crapper'))
        env['UML_VIEWER_TOOL_ROOT'] = str((ROOT / '.uml-viewer/uml-viewer').resolve())
        if entry == 'downstream':
            # 下游直接用上游 mutator CLI：不再安装任何项目侧 worker 适配器。
            command = [str(PYTHON), '-B', '-c', 'from mutator.cli import main; main()',
                       '--root', str(root), 'common/Example.lua', '--no-coverage',
                       '--test-command', f'"{PYTHON}" -B "{root / "test.py"}"', '--max-workers', '1']
        elif entry == 'uml':
            command = [str(root / 'uml'), 'mutate', 'common/Example.lua', '--max-workers', '1']
        else:
            command = [str(root / 'tools/quality/project'), 'mutation', 'common/Example.lua', '--max-workers', '1']
        return subprocess.run(command, cwd=root, env=env, capture_output=True, text=True,
                              encoding='utf-8', errors='replace', timeout=90)

    def test_worker_deletion_is_not_recreated_at_public_entries(self):
        for entry in ('project', 'uml', 'downstream'):
            with self.subTest(entry=entry), tempfile.TemporaryDirectory(prefix='mutation-safety-') as directory:
                root = Path(directory)
                source, snapshot = self.fixture(root, action='delete')
                result = self.invoke(root, entry)
                self.assertFalse(source.exists(), result.stdout + result.stderr)
                self.assertNotIn(result.returncode, (0, 3))
                self.assertIn('被删除', result.stdout + result.stderr)
                self.assertEqual(snapshot.read_bytes(), OLD)

    def test_uml_worker_edit_preserves_source_and_snapshot(self):
        with tempfile.TemporaryDirectory(prefix='mutation-safety-') as directory:
            root = Path(directory)
            source, snapshot = self.fixture(root)
            result = self.invoke(root, 'uml')
            self.assertEqual(source.read_bytes(), EDIT, result.stdout + result.stderr)
            self.assertEqual(result.returncode, 1)
            self.assertIn('源码', result.stdout + result.stderr)
            self.assertEqual(snapshot.read_bytes(), OLD)

    def test_success_only_mutates_worker_copy(self):
        for entry in ('project', 'uml', 'downstream'):
            with self.subTest(entry=entry), tempfile.TemporaryDirectory(prefix='mutation-safety-') as directory:
                root = Path(directory)
                source, snapshot = self.fixture(root)
                (root / 'test.py').write_text(
                    'from pathlib import Path\n'
                    f'root=Path({str(root)!r})\n'
                    'if Path.cwd() != root:\n'
                    '    assert Path("common/Example.lua").read_bytes() != '
                    f'{SOURCE!r}\n', encoding='utf-8')
                result = self.invoke(root, entry)
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                self.assertEqual(source.read_bytes(), SOURCE)
                self.assertIn(':file "common/Example.lua"', snapshot.read_text(encoding='utf-8'))
                self.assertIn(':survived 2', snapshot.read_text(encoding='utf-8'))

    def test_failure_does_not_revert_baseline_save(self):
        with tempfile.TemporaryDirectory(prefix='mutation-safety-') as directory:
            root = Path(directory)
            source, snapshot = self.fixture(root, phase='baseline')
            with (root / 'test.py').open('a', encoding='utf-8') as stream:
                stream.write('print("基线原错误", flush=True)\nraise SystemExit(7)\n')
            result = self.invoke(root, 'project')
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn('基线原错误', result.stdout + result.stderr)
            self.assertIn('源码已变化', result.stdout + result.stderr)
            self.assertEqual(source.read_bytes(), EDIT)
            self.assertEqual(snapshot.read_bytes(), OLD)

    def test_baseline_failure_reports_deleted_source_at_all_entries(self):
        for entry in ('project', 'uml', 'downstream'):
            with self.subTest(entry=entry), tempfile.TemporaryDirectory(prefix='mutation-safety-') as directory:
                root = Path(directory)
                source, snapshot = self.fixture(root, action='delete', phase='baseline')
                with (root / 'test.py').open('a', encoding='utf-8') as stream:
                    stream.write('print("删除基线原错误", flush=True)\nraise SystemExit(7)\n')
                result = self.invoke(root, entry)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn('删除基线原错误', result.stdout + result.stderr)
                self.assertIn('被删除', result.stdout + result.stderr)
                self.assertFalse(source.exists())
                self.assertEqual(snapshot.read_bytes(), OLD)

    def _lock_source_during_failure(self, root, source):
        # 外部进程在失败前撤掉源码读权限；公开入口结束后才恢复，字节本身不变。
        (root / 'test.py').write_text(
            'import os\n'
            f'os.chmod({str(source)!r}, 0)\n'
            'print("不可读基线原错误",flush=True)\nraise SystemExit(7)\n', encoding='utf-8')

    def _release_source_lock(self, source):
        source.chmod(0o644)

    @unittest.skipIf(os.geteuid() == 0, 'root 无视文件权限，无法制造不可读源码')
    def test_unreadable_source_diagnostic_preserves_baseline_failure(self):
        with tempfile.TemporaryDirectory(prefix='mutation-safety-') as directory:
            root = Path(directory)
            source, snapshot = self.fixture(root)
            self._lock_source_during_failure(root, source)
            try:
                result = self.invoke(root, 'project')
            finally:
                self._release_source_lock(source)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 2, output)
            self.assertIn('不可读基线原错误', output)
            self.assertIn('无法核对', output)
            self.assertEqual(source.read_bytes(), SOURCE)
            self.assertEqual(snapshot.read_bytes(), OLD)

    @unittest.skipIf(os.geteuid() == 0, 'root 无视文件权限，无法制造不可读源码')
    def test_unreadable_source_diagnostic_preserves_coverage_exception(self):
        with tempfile.TemporaryDirectory(prefix='mutation-safety-') as directory:
            root = Path(directory)
            source, snapshot = self.fixture(root)
            self._lock_source_during_failure(root, source)
            command = f'"{PYTHON}" -B test.py'
            (root / 'coverage.lua').write_text(
                'os.execute(' + json.dumps(command) + ')\n', encoding='utf-8')
            try:
                result = self.invoke(root, 'project')
            finally:
                self._release_source_lock(source)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 1, output)
            self.assertIn('未生成 LuaCov 统计', output)
            self.assertIn('无法核对', output)
            self.assertEqual(source.read_bytes(), SOURCE)
            self.assertEqual(snapshot.read_bytes(), OLD)

    def test_legacy_backup_never_overwrites_user_source(self):
        with tempfile.TemporaryDirectory(prefix='mutation-safety-') as directory:
            root = Path(directory)
            source, snapshot = self.fixture(root)
            source.write_bytes(EDIT)
            backup = root / 'target/mutator-backup/common/Example.lua'
            backup.parent.mkdir(parents=True)
            backup.write_bytes(SOURCE)
            result = self.invoke(root, 'downstream')
            self.assertEqual(source.read_bytes(), EDIT, result.stdout + result.stderr)
            self.assertNotIn(result.returncode, (0, 3))
            self.assertIn('备份', result.stdout + result.stderr)
            self.assertEqual(backup.read_bytes(), SOURCE)
            self.assertEqual(snapshot.read_bytes(), OLD)

    def test_coverage_edit_stops_before_publishing(self):
        with tempfile.TemporaryDirectory(prefix='mutation-safety-') as directory:
            root = Path(directory)
            source, snapshot = self.fixture(root)
            with (root / 'coverage.lua').open('a', encoding='utf-8') as stream:
                stream.write("local f=assert(io.open('common/Example.lua','wb')); f:write('return {}\\n'); f:close()\n")
            result = self.invoke(root, 'project')
            self.assertEqual(source.read_bytes(), b'return {}\n')
            self.assertEqual(snapshot.read_bytes(), OLD, result.stdout + result.stderr)
            self.assertEqual(result.returncode, 1)
            self.assertIn('源码', result.stdout + result.stderr)

    def test_coverage_failure_reports_save_and_preserves_original_error(self):
        with tempfile.TemporaryDirectory(prefix='mutation-safety-') as directory:
            root = Path(directory)
            source, snapshot = self.fixture(root)
            with (root / 'coverage.lua').open('a', encoding='utf-8') as stream:
                stream.write("local f=assert(io.open('common/Example.lua','wb')); f:write('return {}\\n'); f:close(); print('覆盖率原错误'); os.exit(7)\n")
            result = self.invoke(root, 'project')
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn('覆盖率原错误', result.stdout + result.stderr)
            self.assertIn('源码已变化', result.stdout + result.stderr)
            self.assertEqual(source.read_bytes(), b'return {}\n')
            self.assertEqual(snapshot.read_bytes(), OLD)

    def test_coverage_exception_reports_deletion_and_original_error(self):
        with tempfile.TemporaryDirectory(prefix='mutation-safety-') as directory:
            root = Path(directory)
            source, snapshot = self.fixture(root)
            # 成功退出却不产生统计，触发公开 coverage 转换前异常。
            (root / 'coverage.lua').write_text("assert(os.remove('common/Example.lua'))\n")
            result = self.invoke(root, 'project')
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('未生成 LuaCov 统计', result.stdout + result.stderr)
            self.assertIn('被删除', result.stdout + result.stderr)
            self.assertFalse(source.exists())
            self.assertEqual(snapshot.read_bytes(), OLD)

    def test_project_baseline_edit_stops_before_publishing(self):
        with tempfile.TemporaryDirectory(prefix='mutation-safety-') as directory:
            root = Path(directory)
            source, snapshot = self.fixture(root, phase='baseline')
            result = self.invoke(root, 'project')
            self.assertEqual(source.read_bytes(), EDIT)
            self.assertEqual(snapshot.read_bytes(), OLD, result.stdout + result.stderr)
            self.assertEqual(result.returncode, 1)
            self.assertIn('源码', result.stdout + result.stderr)

    def test_project_worker_edit_is_preserved_on_downstream_failure(self):
        with tempfile.TemporaryDirectory(prefix='mutation-safety-') as directory:
            root = Path(directory)
            source, snapshot = self.fixture(root)
            result = self.invoke(root, 'project')
            self.assertEqual(source.read_bytes(), EDIT, result.stdout + result.stderr)
            self.assertEqual(result.returncode, 1)
            self.assertIn('源码', result.stdout + result.stderr)
            self.assertEqual(snapshot.read_bytes(), OLD)

    def test_downstream_worker_edit_is_preserved_without_publishing(self):
        with tempfile.TemporaryDirectory(prefix='mutation-safety-') as directory:
            root = Path(directory)
            source, snapshot = self.fixture(root)
            result = self.invoke(root, 'downstream')
            self.assertEqual(source.read_bytes(), EDIT, result.stdout + result.stderr)
            self.assertNotIn(result.returncode, (0, 3))
            self.assertIn('源码', result.stdout + result.stderr)
            self.assertEqual(snapshot.read_bytes(), OLD)


if __name__ == '__main__':
    unittest.main()
