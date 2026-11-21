# 试玩会话 87e37a0（未完成视觉取证）

- 日期：2026-11-20
- 地图：钓鱼怎么这么危险啊喂！（6aab8e60ee615830184f4963）
- 编辑器 pid：25864
- 试玩会话：87e37a0
- QA 存档槽：qa-20261120-144938-092823（本场开始前 qa-slot new，随后 deploy）
- 对应工单：试玩恢复后 56 条 C 级整批取证（#267）

## 结论

本场**不能**作为任何 C 级条款的取证。Windows 会话处于锁屏（前台窗口为「Windows 默认锁屏界面」，logonui 在跑）。桌面合成、PrintWindow、editor-cli 的 game 截图都拿不到游戏画面：视口是全黑或一块无效的黑白帧。客户端 CurrentCamera 读数为 nil。条款状态保持 blocked，不改矩阵。

## 已经确认的运行时事实（不是 C 级证据）

- play start --wait-ready 成功，editor_state=playing，in_game_runtime=true。
- log trace 在该会话窗口内 errorCount=0、warningCount=0。
- input state 有玩家坐标，出生点约 (-616, 1, 68)，状态 Idle。按住 W 约 1 秒后 X 从 -616.0 变为约 -625.4，引擎键盘注入可用。play input move 报 CAPABILITY_UNSUPPORTED，本场没有用它。
- 服务端能看到 1 名玩家「伯乐好马！」，角色名同为该名字；按 HumanoidRootPart 读取位置得到 nil（模型结构与该路径不一致，未再深挖）。
- 客户端日志：Z2–Z7 的钓鱼佬模型等待 10 秒后仍不存在，跳过吃动作（shrimpPond / crabLake / forestIsland / beachIsland / reefIsland / volcanoIsland）。这只是日志观察，未开子单，留到能看见画面的场次再决定。
- QA 槽在自动落账（会话期间 revision 至少到 5）。

## 抓屏清单

全部落在 tmp/，不作为证据：

- tmp/play-87e37a0-boot.png：PrintWindow 抓到编辑器主窗口，视口区域是白的。
- tmp/play-87e37a0-screen.png：桌面合成抓到的是锁屏壁纸与「输入你的 PIN」。
- tmp/play-87e37a0-game.png 与 tmp/play-87e37a0-game2.png：editor-cli screenshot game，1073×889、4782 字节，校验报 FRAME_VALID，画面是黑白块，不是游戏。
- tmp/play-87e37a0-print.png、tmp/play-87e37a0-focus.png：对标题为 client 的视口句柄做 PrintWindow，全黑。
- tmp/play-87e37a0-d2.png：第二块屏全黑。
- tmp/play-87e37a0-viewport.png：视口矩形的桌面合成，下面是壁纸。

## 收场

锁屏期间角色停在出生点，服务端每秒饥饿掉血 5（日志里从约 150 掉到 50，客户端弹出「我要饿死了！」）。继续挂着只会把本 QA 槽落成死亡档，所以已 play stop。编辑器留在编辑态，地图仍开着，pid 25864，editor_state 回到 idle 且 ready。QA 槽没有换，也没有切回正式存档。

## 下次怎么接

解开锁屏后沿用 QA 槽 qa-20261120-144938-092823，不要再 qa-slot new。槽未变就不必为了槽再 deploy。然后 play start --wait-ready，重新取画面。本槽已经有一段饥饿掉血的进度，若要干净新档，再另开槽。C 级 55 条（执行者=试玩且 blocked）仍全部未取证。工单标题写 56，地图正文写 55，本场没有改这个差额。
