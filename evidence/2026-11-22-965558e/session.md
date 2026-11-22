# 试玩会话 965558e 记录（2026-11-22）

## 环境
- 地图「钓鱼怎么这么危险啊喂！」(6aab8e60ee615830184f4963)，编辑器 pid 43084，CLI 0.20.17。
- 截图通道：`lua tools/cli.lua screenshot`（PrintWindow 后台抓屏），显示虚拟屏 DISPLAY5，选中窗口 client 1872x1200。
- 部署：`lua tools/cli.lua deploy` ok（validate OK、push 1 个文件、编辑器已同步）；QA 槽 qa-20261122-043446-622596。
- 试玩：`play start --wait-ready` → playtest_id 965558e，ready_confirmed=true，in_game_runtime=true，editor_state=playing。

## 本场观察（截图留存 tmp/）
- 首帧 `tmp/qa267-spawn.png`：主 HUD 右上「图鉴｜地图商店｜盲盒」三入口并列可见（#275 的修复在本次部署上现场复核成立，对应 3-23 已 evidenced）；左上角色血量/饥饿数值；下方背包 5 格等；右侧攻击键与摇杆；开场剧情对话 1/5「钓鱼怎么这么危险啊喂！」含「下一段」「已读，开始钓鱼」；新手任务 1/9「拾取 5 只纸船（幼鱼）」。
- 帧新旧：连拍 md5 均不同（角色动画），窗口尺寸稳定 1872x1200。
- 操控：`input joystick 0 -1` 后 `input state`：position.z 由约 68 → 58.15，velocity.z=-7，moving=true，摇杆移动生效。

## 未取证 / 阻碍
- `input touch` 点击 EUI 按钮（试了屏幕坐标、窗口坐标、视口相对坐标）与 `input key enter` 均未能推进开场对话（画面仅动画变化），触摸坐标映射未打通；菜单类 C 级条款（图鉴/商店分页等）本场无法打开取证。仅 13-16 已知因缺品级入口而 blocked（#276 open），本场未再复核。
- 其余 C 级条款多为需真实长时游玩（抛竿钓鱼、战斗、逐区首领、摆渡六航线、抽奖/盲盒实抽、烧烤、3 倍体型、水下/顶墙、双人组队）的观测，本场未取证，保持 blocked。

## 结论
本场仅完成「部署 → 试玩 → 截图 → 移动操控」链路验证，**未新增 evidenced 条款**，矩阵状态不变。
