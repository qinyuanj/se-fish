# 0023 资产表落在团队仓 docs 的 SE 命名空间

**Status**: accepted（2026-11-18；决策单 [#224](https://github.com/qinyuanj/se-fish/issues/224)，地图 [#223](https://github.com/qinyuanj/se-fish/issues/223)。配套改动在团队仓 `eggy/teamai-netease`：`docs/eggy-se/`、`manifest/projects.yaml` 的 `docs: [eggy-se]`、`scripts/fetch-se-assets.py`、`scripts/check.py` 门禁，与本 ADR 同批合入）

官方 `manual/se/` 按编辑器分类发布 11 张资产目录 CSV（2.58 MB / 7549 行：8 张状态同步编辑器 + 3 张世界编辑器），给出资产名称、编号与 AI 生成的外观描述。它们是「描述」而不是「清单」：2.19 MB（85%）是描述列，工程侧导出的 `data/OfficialAsset.lua` 没有这一层，编号也属于另一代（见 [CSV 与官方导出的覆盖口径 #226](https://github.com/qinyuanj/se-fish/issues/226)）。数据可从 S3 直链一条命令复现，11 个文件 sha256 与人工下载副本逐字节一致，所以「要不要入库」本不是唯一解。

蛋仔有世界图（SE，状态同步）与原点版（FS，帧同步）两个体系：这 11 张表全部属于 SE 域，FS 工程既不产出也不需要。团队仓已有的隔离机制是按项目分发——`skills/`、`hooks/`、`learnings/` 都已按 `eggy-se` / `eggy-fs` 切开，而 `docs/` 至今没有声明过命名空间。

决定：

- **落点**：团队仓 `docs/eggy-se/`。`assets/` 放 11 个 CSV 原样，`assets.md` 是单文件索引（适用范围与发现路径、口径声明、11 表速查、查询范式、更新与校验）。
- **隔离**：`manifest/projects.yaml` 的 eggy-se 项目增加 `docs: [eggy-se]`。docs 命名空间就是 `docs/` 下第一段路径名，`teamai pull` 在拷贝层按当前项目 withhold 掉非当前项目的 ns；`teamai projects add --namespaces` 不覆盖 docs/wiki，只能手写。`scripts/check.py` 的项目隔离门禁同步覆盖 `docs`，否则删掉这一行会静默变成全员下发。
- **不进 skill**：数据不放进任何 `skills/<ns>/<name>/references/`。skill 确实天生按项目隔离，但它整目录复制进每台机器每个已注册工具的技能目录（本机有 `~/.claude/skills`、`~/.codex/skills`、`~/.dsh/skills` 三处），2.58 MB 会放大成约 7.7 MB/人/次 pull；而 `teamai recall` 只索引 `SKILL.md`、不递归 `references/`，付了这个代价也换不到召回可见性。
- **发现路径**：`docs/` 下所有 `.md` 都进 `teamai recall`，所以 `assets.md` 会被日常检索命中；再在既有 `skills/eggy-se/eggy-se-lua-coding/references/create-unit-and-asset.md` 加一段指针，让写资产代码的会话在激活技能时就知道数据在哪。
- **不建查询脚本**：11 张表实测 0 个引号、无字段内分号、列数逐行恒定（2/4/7 列），`awk -F';'` 与 `grep -n` 就是完整方案。`assets.md` 负责沉淀「问哪类问题查哪张表、用哪条命令」。
- **时效**：`scripts/fetch-se-assets.py` 只做下载与 sha256 对照报告，不重算 manifest、不做字节转换；`assets.md` 记抓取日期。不装 hook、不定时任务——谁发现资产缺失谁触发重导。
- **口径**：数据以 CSV 为准，不与 `OfficialAsset.lua` 合并，两代编号不互换。
- **字节基准**（[#227](https://github.com/qinyuanj/se-fish/issues/227) 落定）：入库前把上游 CRLF 规范化为 LF，并在 `.gitattributes` 里用 `docs/eggy-se/assets/*.csv text eol=lf` 显式钉住；`manifest.json` 同时记 `sha256Upstream`（下载原件，fetch 对照）与 `sha256InRepo`（入库字节，clone / pull 对照），11/11 文件 LF→CRLF 回写可逐字节还原上游。

备选方案（拒绝）：

1. **进 skill 的 `references/`**：天然隔离、零配置，但 2.58 MB × 每台机器每个工具目录，且 recall 看不见 `references/`，代价换不回发现性。
2. **docs 放数据 + 另建 `eggy-se-assets` 技能只放查询指引**：多一个技能目录要维护，而「激活时看得见」用既有技能里一段指针就买到了。
3. **不入库，只入 fetch 脚本与索引**：仓库不膨胀，但每次查询都要联网，与「任一团内 SE 工程、任意时刻能答」冲突。
4. **入库但不上命名空间（全员下发）**：这 11 张表全部属于 SE 域，发给 FS 与通用工程既没必要，也会让「哪些数据属于哪个模式」变模糊。

后果：

- `teamai recall` 不按 docs 命名空间过滤（索引直接递归团队仓 `docs/`），FS 成员仍可能召回 `assets.md` 的标题，而本机镜像里没有对应文件。属于可接受的召回噪音，不另修。
- docs 镜像只增不删，改名或拆分文件要成员手工清理旧副本。
- 数据时效落在人身上：官方更新不会通知，只能靠「发现资产缺失」触发重导。
- `manifest/projects.yaml` 从此是这份数据分发范围的唯一开关，改动必须过 `check.py` 门禁。
