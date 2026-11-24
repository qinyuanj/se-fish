-- spoke 加载探针：不入任何 .busted 车道，执行方式与 tests/probes/ 其它探针一致。
--   lua tests/probes/spoke_load.lua
-- 目的：验证 common/packages/spoke/ 落位与 require 前缀、Auto 树的同步 flush、
-- dispose 后不再回调。库的完整行为规格由上游 specs 负责，本探针不重复。

package.path = "./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if not ok then failures = failures + 1 end
  print(string.format("[spoke_load] %-22s %s %s", name, ok and "OK" or "FAIL", detail or ""))
end

local ok_api, spoke = pcall(require, "common.packages.spoke.api")
check("require api", ok_api, ok_api and "" or tostring(spoke))
if not ok_api then print("[spoke_load] failures=" .. failures) os.exit(1) end

local names = { "Epoch", "Ticker", "SpokeTree", "Dock", "LambdaEpoch", "SpokeHandle",
  "Trigger", "State", "Effect", "Reaction", "Memo", "Phase", "EffectBuilder" }
local missing = {}
for _, n in ipairs(names) do
  if type(spoke[n]) ~= "table" then missing[#missing + 1] = n end
end
check("13 个公共类", #missing == 0, table.concat(missing, ","))
check("内部类型不外露", spoke.SpokeRuntime == nil and spoke.Heap == nil)

local State, Effect, SpokeTree = spoke.State, spoke.Effect, spoke.SpokeTree

local count = State.new(0)
local seen = {}
local ok_tree, tree = pcall(function()
  local Root = Effect.new(function(d)
    d:effect(function()
      seen[#seen + 1] = count:now()
    end, { count })
  end)
  return SpokeTree.spawn("probe", Root)
end)
check("spawn Auto 树", ok_tree, ok_tree and "" or tostring(tree))
if not ok_tree then print("[spoke_load] failures=" .. failures) os.exit(1) end

check("首帧同步运行一次", #seen == 1, "seen=" .. #seen)

count:set(1)
check("Auto 树同步 flush", #seen == 2 and seen[2] == 1,
  "seen=" .. #seen .. " last=" .. tostring(seen[#seen]))

tree:dispose()
count:set(2)
check("dispose 后不再回调", #seen == 2, "seen=" .. #seen)

print("[spoke_load] failures=" .. failures)
os.exit(failures == 0 and 0 or 1)