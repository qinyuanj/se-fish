# tools/naming 数据

#337 把 L3a/L3b 的一次性脚本提成可复跑的 `lua tools/cli.lua naming`，数据随仓库入库。

| 文件 | 内容 | 来源 |
| --- | --- | --- |
| `l3a_renames.txt` | 449 个「旧标识符 新标识符」 | L3a 提交 `b3a1855` 的改名清单；含注释/docs 口径 |
| `l3b_renames.txt` | 45 个方法名「旧 新」 | L3b 提交 `9685b9e` 的改名清单 |
| `post_l3_renames.txt` | 18 个 L3 之后迁移的「旧 新」 | PR #345 与 ADR-0037 L4d 收尾键（仅用于旧名字符串守卫，不参与 L3a/L3b 历史重放） |
| `l3b_keydefs.txt` | L3b 逐处字符串键/官方词定义清单（文件:行 + 上下文） | `tools/naming` 提升前的 `l3b_keydefs.txt`，保留作 grep 索引 |
| `string_key_exemptions.txt` | 旧名字符串守卫的逐条豁免（path<TAB>旧名<TAB>理由） | #337 逐条确认的官方/协议点 |

## 范围

本单只搬「工具 + 守卫」：#337 不继续改业务代码。`tests/native/guards/data/legacy_pascal_names_baseline.txt` 里冻结的 107 个名字与 ADR-0034 的 L4（文档 571 处）都另开一层做，避免把工具验证和一次新的业务改名混在同一个 diff 里。

## 口径

- **L3a** 是标识符级替换：方法名、局部变量、字段都改；跳过引号内字符串，但**注释和 `docs/`（不含 `docs/adr/`）一起改**。这与 `b3a1855` 的实际 diff 一致。
- **L3b** 只改成员访问/定义（`.Name` / `:Name`），并按 L3b 当年的脚本口径（官方构造器、`Vector3:Length`、`Task:Spawn`、`BaseController:Move/GetState`、`Unit:Destroy`）跳过；测试替身裸表键只在 `tests/` 下按上下文处理。
- `l3a_renames.txt` 保留的是 **L3a WIP 提交**的 449 个名字。其中 `CastAbility`、`AddAbility`、`GetAttrConfig`、`MoveDirection`、`getState`、`Board`、`WeaponAction`、`Attach` 等随后在 `982392f`/`c5e8367` 回退为官方契约；这是 `b3a1855` 与后续修补之间的差额，不应把当前 HEAD 上的回退名再改一遍。因此 `--apply` 只应在**对应层的父提交干净 worktree**上重放，或在确认过 diff 的新层上使用；不要直接在已收绿的 HEAD 上跑 `--apply`。
- `--recon` 与 `--apply` 共用同一份收集逻辑，recon 的编辑清单就是 apply 会落的那批。

## 重放验收

```bash
# L3a：父提交 e2a59d1，目标提交 b3a1855
git worktree add --detach tmp/replay-l3a e2a59d1
lua tools/cli.lua naming --recon --layer l3a --root tmp/replay-l3a --summary
lua tools/cli.lua naming --apply --layer l3a --root tmp/replay-l3a
git -C tmp/replay-l3a add -A && git -C tmp/replay-l3a diff --cached --stat
# 与 git show --stat b3a1855 一致：300 files changed, 5609 insertions(+), 5609 deletions(-)
```

```bash
# L3b：父提交 c75e740，目标提交 9685b9e
git worktree add --detach tmp/replay-l3b c75e740
lua tools/cli.lua naming --recon --layer l3b --root tmp/replay-l3b --summary
lua tools/cli.lua naming --apply --layer l3b --root tmp/replay-l3b
git -C tmp/replay-l3b add -A && git -C tmp/replay-l3b diff --cached --stat
# 与 git show --stat 9685b9e 一致：129 files changed, 876 insertions(+), 876 deletions(-)
```

`--apply` 会拒绝脏工作区；同一个 worktree 重放第二次前，先 `git -C tmp/replay-l3a reset --hard e2a59d1 && git -C tmp/replay-l3a clean -fdq`。重放完删除 worktree：`git worktree remove --force tmp/replay-l3a`。
