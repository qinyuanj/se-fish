"""SE_FISH_QUALITY_E2E 门控只有一份实现：共享模块 e2e_gate 读环境变量，用例类只装饰。

端到端门控语义的任何改动都落在 e2e_gate.py 一处；这里钉住「共享模块按环境变量开合」
与「测试模块不再各自读这个变量」，防止门控头重新逐字复制回各回归文件。
"""
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SLOW = ROOT / 'tests/tooling/slow'
VARIABLE = 'SE_FISH_QUALITY_E2E'


class E2EGateSemanticsTest(unittest.TestCase):
    def test_gate_reflects_the_environment_variable_at_import(self):
        probe = ("import sys; sys.path.insert(0, {slow!r}); "
                 "import e2e_gate; print(e2e_gate.E2E)").format(slow=str(SLOW))
        for value, expected in ((None, 'False'), ('1', 'True'), ('0', 'False')):
            with self.subTest(value=value):
                env = {key: item for key, item in os.environ.items() if key != VARIABLE}
                if value is not None:
                    env[VARIABLE] = value
                result = subprocess.run([sys.executable, '-B', '-c', probe],
                                        capture_output=True, text=True, env=env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_gate_reason_names_the_variable(self):
        sys.path.insert(0, str(SLOW))
        import e2e_gate
        self.assertIn(VARIABLE, e2e_gate.E2E_REASON)


class E2EGateSharingTest(unittest.TestCase):
    def test_no_test_module_reads_the_gate_variable_directly(self):
        offenders = [path.name for path in SLOW.glob('*_test.py')
                     if f"environ.get('{VARIABLE}'" in path.read_text(encoding='utf-8')
                     or f'environ.get("{VARIABLE}"' in path.read_text(encoding='utf-8')]
        self.assertEqual(offenders, [], '门控变量只能由 e2e_gate.py 读取')

    def test_skip_unless_users_go_through_the_shared_gate(self):
        # 目录内 skipUnless 目前只有 E2E 门控一种语义；凡使用者必须经共享装饰器。
        offenders = [path.name for path in SLOW.glob('*_test.py')
                     if path.name != 'e2e_gate_test.py'
                     and 'skipUnless' in path.read_text(encoding='utf-8')
                     and 'import e2e_gate' not in path.read_text(encoding='utf-8')]
        self.assertEqual(offenders, [])


if __name__ == '__main__':
    unittest.main()
