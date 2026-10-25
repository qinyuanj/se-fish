"""tests/tooling/slow 环境变量门控的唯一实现（维护者指令，spec/116；#137 增设安装门控）。

两道门控共用 gate() 一处语义：变量严格等于 '1' 才释放，其余取值与缺省都跳过。
- SE_FISH_QUALITY_E2E：真实拉起 crapper/mutator 的端到端用例；spec/116 收尾复验
  （#122，维护者协调）以 SE_FISH_QUALITY_E2E=1 统一实跑，不得改成 mock 假绿。
- SE_FISH_QUALITY_INSTALL：经公开入口真实执行 `install` 的用例（真实上游安装器建 venv
  与 pip，或对本地 fixture 仓库跑完整 install 流程）；改安装器或 pin 时以
  SE_FISH_QUALITY_INSTALL=1 实跑。与 E2E 分开，是为了复验安装时不必连带跑 mutation 端到端。
用例类或方法装饰 @e2e_gate.skip_unless_e2e / @e2e_gate.skip_unless_install 即可，
测试模块不得各自读这些环境变量，也不得另写门控。
本模块不匹配 unittest discover 的 *_test.py 模式，只被用例模块导入。
"""
import os
import unittest


def gate(variable):
    """门控是否释放：只认导入时环境变量严格等于 '1'。"""
    return os.environ.get(variable) == '1'


E2E = gate('SE_FISH_QUALITY_E2E')
E2E_REASON = '真实拉起 crapper/mutator 的端到端用例默认跳过；spec/116 收尾复验（#122，维护者协调）以 SE_FISH_QUALITY_E2E=1 统一实跑'
skip_unless_e2e = unittest.skipUnless(E2E, E2E_REASON)

INSTALL = gate('SE_FISH_QUALITY_INSTALL')
INSTALL_REASON = '真实执行 install 的用例默认跳过（#137）；改安装器或固定提交时以 SE_FISH_QUALITY_INSTALL=1 实跑'
skip_unless_install = unittest.skipUnless(INSTALL, INSTALL_REASON)
