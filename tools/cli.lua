-- tools/cli.lua —— agent 与人日常检查的唯一公开工具入口（#145；先例：monopoly / se-defense
-- tools/cli.lua 的封闭命令集，但保持顶层路由表 + 平铺模块，不迁移到 packages / foundation 结构）。
--
-- 用法（仓库任意子目录、任一 worktree 均可执行）：
--   lua5.4 tools/cli.lua <子命令> [args...]
--   lua5.4 tools/cli.lua --help | -h
--
-- 入口流程：Lua 5.4 预检 → 由本脚本位置推导仓库根并据此拼 package.path → 查静态路由表 →
-- require(<mod>) → mod.main(args, env) → 统一 os.exit。
-- 子模块接口：return { main = function(args, env) -> 退出码 }，env = { repo_root =, command = }；
-- 不需要环境的模块忽略第二参数即可。包内自行消费 --help/-h。
-- 进程当前目录不改：deploy / sync 等按当前目录读写，与之前一致。
--
-- 退出码：0 成功 / 1 业务失败 / 2 用法错误（未知子命令、模块加载失败、未知参数）/
--         3 平台或工具不可用（busted 缺失、editor-cli.exe 或 Blender 找不到、WSL interop 失败）。
-- ADR 0008 的「编辑器没装或没打开本图 → 打印跳过并返回 0」不受退出码 3 影响。
--
-- 不进清单（不挂路由）及理由：
--   - verify：只剩一项检查，不包编排；收尾直接跑 `test full`。
--   - quality / uml：质量工具由人直接用 `./uml crap|mutate|dry`，CLI 不包装。
--   - 内部模块：部署 / 同步计划（deploy_plan、sync_plan）、WSL 接缝（wsl_seam）、
--     宿主目录定位（eggy_workspace）、编辑器收尾（editor_finalize）——只供子命令调用。
--   - 一次性离线脚本：内容校验（validate_content）、布局规划与探针生成（plan_zone_layout、
--     gen_zone_layout_probe、gen_config_anchor_probe）、基线转换（baseline_csv）、
--     锚点坐标 dry-run（anchor_coord_sync_dry_run）、空间合同核对（zone_space_contract）。
-- 新工具是否挂路由：人或 agent 日常反复调用的才挂；其余按上面归类留在模块里。

-- 解释器预检必须最先做；整个文件只用 5.1 也能解析的语法，否则旧解释器连提示都打不出来。
if _VERSION ~= "Lua 5.4" then
  io.stderr:write("tools/cli.lua 需要 Lua 5.4，当前是 " .. tostring(_VERSION)
    .. "；请用 lua5.4 tools/cli.lua（WSL 上裸 lua 可能指向 5.1）\n")
  os.exit(1)
end

local M = {}

M.commands = {
  { name = "test", mod = "tools.test", summary = "按测试车道跑 busted：test [fast|full] [-- <busted 参数>...]，缺省 fast" },
  { name = "deploy", mod = "tools.deploy", summary = "仓库三端一级子树镜像进编辑器宿主目录（robocopy /MIR + 编辑器收尾）" },
  { name = "sync",   mod = "tools.sync",   summary = "从宿主回同步配置 / API 存根 / data/，--packages 追加三端官方包" },
  { name = "acceptance-slot", mod = "tools.acceptance_slot", summary = "查看、新建或切换 #93 验收存档槽（试玩前需 deploy）" },
  { name = "ability-presets", mod = "tools.ability_presets", summary = "重建技能包的编辑器侧预设（复制官方模板、刷壳与属性、回写 GameCfg key）" },
  { name = "blender", mod = "tools.blender", summary = "在 Windows 侧无头 Blender 执行脚本（唯一 Blender 入口，透传 JSON 与退出码）" },
  { name = "worktree-init", mod = "tools.worktree_init", summary = "把新 worktree 补齐到能跑 full（复制上游 blender-* skill、父目录建工具 symlink；幂等）" },
}

-- 被 require（如测试读路由表）时只交出路由表，不执行入口流程。
local loaded_as = ...
if loaded_as == "tools.cli" then
  return M
end

-- 仓库根 = 入口脚本所在目录（tools/）的上一级，不依赖当前目录；相对路径按 PWD 绝对化。
local function repo_root()
  local script = arg and arg[0] or "tools/cli.lua"
  local dir = script:match("^(.*)/[^/]*$") or "."
  local root
  if dir == "." then
    root = ".."
  else
    root = dir:match("^(.*)/[^/]*$") or "."
    if root == "" then root = "/" end
  end
  if root:sub(1, 1) ~= "/" then
    local pwd = os.getenv("PWD")
    if pwd and pwd:sub(1, 1) == "/" then
      root = root == "." and pwd or (pwd .. "/" .. root)
    end
  end
  return root
end

local ROOT = repo_root()
package.path = ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;" .. package.path

local function usage()
  local lines = { "用法: lua5.4 tools/cli.lua <子命令> [args...]", "", "子命令（封闭命令集）：" }
  for _, c in ipairs(M.commands) do
    lines[#lines + 1] = string.format("  %-15s %s", c.name, c.summary)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "退出码："
  lines[#lines + 1] = "  0 成功"
  lines[#lines + 1] = "  1 业务失败（含测试失败）"
  lines[#lines + 1] = "  2 用法错误（未知子命令、模块加载失败、未知参数）"
  lines[#lines + 1] = "  3 平台或工具不可用（busted 缺失、editor-cli.exe 或 Blender 找不到、WSL interop 失败）"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  lua5.4 tools/cli.lua <子命令> --help   子命令帮助"
  return table.concat(lines, "\n") .. "\n"
end

local name = arg[1]
if name == nil or name == "--help" or name == "-h" then
  io.write(usage())
  os.exit(0)
end

local entry
for _, c in ipairs(M.commands) do
  if c.name == name then entry = c end
end
if not entry then
  io.stderr:write("未知子命令: " .. name .. "\n\n" .. usage())
  os.exit(2)
end

local ok, mod = pcall(require, entry.mod)
if not ok or type(mod) ~= "table" or type(mod.main) ~= "function" then
  -- 只印第一行：require 失败时后面跟着一长串搜索路径，对使用者是噪音；
  -- 真要追，直接 `lua5.4 <模块文件>` 跑一次就有完整报错。
  io.stderr:write("子命令加载失败: " .. name .. " (" .. entry.mod .. ")\n"
    .. (tostring(mod):match("^[^\r\n]*") or "") .. "\n")
  os.exit(2)
end

local rest = {}
for i = 2, #arg do rest[#rest + 1] = arg[i] end
local code = mod.main(rest, { repo_root = ROOT, command = name })
os.exit(type(code) == "number" and code or 0)
