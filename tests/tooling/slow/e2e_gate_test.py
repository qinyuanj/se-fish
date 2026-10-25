"""门控只有一份实现：共享模块 e2e_gate 读环境变量，用例类或方法只装饰。

E2E（SE_FISH_QUALITY_E2E）与安装（SE_FISH_QUALITY_INSTALL，#137）两道门控的语义都落在
e2e_gate.py 的 gate() 一处；这里钉住「共享模块按环境变量开合」「测试模块不再各自读这些变量」
与「真实执行 install 的回归文件必须经共享门控」，防止门控头重新逐字复制回各回归文件。
"""
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SLOW = ROOT / 'tests/tooling/slow'
# 变量名 -> e2e_gate 中对应的开关属性与跳过原因属性。
GATES = {'SE_FISH_QUALITY_E2E': ('E2E', 'E2E_REASON'),
         'SE_FISH_QUALITY_INSTALL': ('INSTALL', 'INSTALL_REASON')}


def regression_sources():
    return {path.name: path.read_text(encoding='utf-8') for path in SLOW.glob('*_test.py')
            if path.name != 'e2e_gate_test.py'}


class E2EGateSemanticsTest(unittest.TestCase):
    def test_gate_reflects_the_environment_variable_at_import(self):
        for variable, (flag, _) in GATES.items():
            probe = ("import sys; sys.path.insert(0, {slow!r}); "
                     "import e2e_gate; print(e2e_gate.{flag})").format(slow=str(SLOW), flag=flag)
            for value, expected in ((None, 'False'), ('1', 'True'), ('0', 'False'), ('true', 'False')):
                with self.subTest(variable=variable, value=value):
                    env = {key: item for key, item in os.environ.items() if key not in GATES}
                    if value is not None:
                        env[variable] = value
                    result = subprocess.run([sys.executable, '-B', '-c', probe],
                                            capture_output=True, text=True, env=env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), expected)

    def test_gates_are_independent(self):
        # 释放一道门控不得连带释放另一道：复验安装不必跑 mutation 端到端，反之亦然。
        probe = ("import sys; sys.path.insert(0, {slow!r}); "
                 "import e2e_gate; print(e2e_gate.E2E, e2e_gate.INSTALL)").format(slow=str(SLOW))
        for variable, expected in (('SE_FISH_QUALITY_E2E', 'True False'),
                                   ('SE_FISH_QUALITY_INSTALL', 'False True')):
            with self.subTest(variable=variable):
                env = {key: item for key, item in os.environ.items() if key not in GATES}
                env[variable] = '1'
                result = subprocess.run([sys.executable, '-B', '-c', probe],
                                        capture_output=True, text=True, env=env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_gate_reason_names_the_variable(self):
        sys.path.insert(0, str(SLOW))
        import e2e_gate
        for variable, (_, reason) in GATES.items():
            with self.subTest(variable=variable):
                self.assertIn(variable, getattr(e2e_gate, reason))


class E2EGateSharingTest(unittest.TestCase):
    def test_no_test_module_reads_the_gate_variable_directly(self):
        offenders = sorted(name for name, text in regression_sources().items()
                           for variable in GATES
                           if f"environ.get('{variable}'" in text or f'environ.get("{variable}"' in text
                           or f"environ['{variable}']" in text or f'environ["{variable}"]' in text)
        self.assertEqual(offenders, [], '门控变量只能由 e2e_gate.py 读取')

    def test_skip_unless_users_go_through_the_shared_gate(self):
        # 目录内 skipUnless 只有共享门控这一种语义；凡使用者必须经共享装饰器。
        offenders = [name for name, text in regression_sources().items()
                     if 'skipUnless' in text and 'import e2e_gate' not in text]
        self.assertEqual(offenders, [])

    def test_install_only_callers_go_through_the_shared_gate(self):
        # 真实执行 install 的回归（#137）：带 --install-only 实参的文件必须导入共享门控。
        # 只钉文件级，具体哪个用例受门控由装饰器决定（如锁冲突下秒退的 install 仍默认运行）。
        offenders = [name for name, text in regression_sources().items()
                     if ("'--install-only'" in text or '"--install-only"' in text)
                     and 'import e2e_gate' not in text]
        self.assertEqual(offenders, [])


if __name__ == '__main__':
    unittest.main()
