# Gherkin 验收入口

```sh
bash tools/acceptance/run_acceptance.sh            # 代码收尾门：除 art 外的全部车道 + features/ 根下的裸 feature
bash tools/acceptance/run_acceptance.sh art        # 只跑指定车道，可给多个
bash tools/acceptance/run_acceptance.sh --all      # 全部车道
```

脚本在任意目录都可调用，默认用 `lua5.4`（可通过 `ACCEPTANCE_LUA_BIN` 指定）。车道名即 `features/` 下的一级目录名；未知车道、未知选项或 `--all` 与车道名混用时以非零退出。所选范围内没有 feature 时打印“所选范围内没有 feature 文件，跳过验收”，清理旧生成物并成功退出；不会安装依赖或生成报告。

`art` 车道断言的是仓库外美术工作区的产物（重导入校验报告），红绿取决于资产状态，与代码回归不在同一维度，因此无参数时写死排除，不进代码收尾门（决策见 #136）；美术资产交付时显式跑 `art`。`art` 读不到某条鱼的 `validation/validation.json` 时判失败，报错给出缺失的报告路径，并提示可用 `EGGY_ART_ASSETS` 指到美术资产根目录（见 `tools/art_report.lua`）。新增的其他车道默认进收尾门。

新增场景放在 `features/<车道>/<名字>.feature`，以 `# language: zh-CN` 开头，并在 `tools/acceptance/steps.lua` 登记对应步骤模块。存在 feature 时，入口逐个执行 parse → dry-check（advisory）→ generate → run；先清 `build/acceptance/generated/`，避免运行旧 spec。失败返回非零；`ACCEPTANCE_STRICT_TOOLS=1` 会让 dry-check 工具错误也使运行失败。

`tools/acceptance/bootstrap.lua` 在有场景需要执行时按需安装固定版本的 `acceptance4lua`；生成内容在被 Git 忽略的 `build/acceptance/`，依赖缓存位于 `.toolcache/`。不需要 luarocks 或 WSL。
