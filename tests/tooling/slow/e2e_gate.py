"""SE_FISH_QUALITY_E2E 门控的唯一实现（维护者指令，spec/116）。

真实拉起 crapper/mutator 的端到端用例默认跳过；spec/116 收尾复验（#122，维护者协调）
以 SE_FISH_QUALITY_E2E=1 统一实跑，不得改成 mock 假绿。
用例类装饰 @e2e_gate.skip_unless_e2e 即可，测试模块不得各自读这个环境变量。
本模块不匹配 unittest discover 的 *_test.py 模式，只被用例模块导入。
"""
import os
import unittest

E2E = os.environ.get('SE_FISH_QUALITY_E2E') == '1'
E2E_REASON = '真实拉起 crapper/mutator 的端到端用例默认跳过；spec/116 收尾复验（#122，维护者协调）以 SE_FISH_QUALITY_E2E=1 统一实跑'
skip_unless_e2e = unittest.skipUnless(E2E, E2E_REASON)
