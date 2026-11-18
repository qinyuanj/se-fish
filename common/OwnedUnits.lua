-- 运行期单位的归属登记（#207）：建单位时交给所有者保管，所有者清空时统一销毁。
-- 这是「建了谁负责拆」的唯一答案，客户端与服务端共用；纯 Lua、无引擎依赖，测试直接 require 即可验证。
-- 对外只有三件事：
--   Track(owner, unit)：登记并返回单位本身，便于「建并登记」一行写完；
--   Clear(owner)：销毁所有者名下的全部单位，幂等，重复调用不报错；
--   Count(owner)：取所有者当前名下的单位数，供测试与排查。
-- 所有者可以是任意表或字符串标识。同一单位重复登记只记一次（重复销毁会把同一个节点拆两遍）；
-- 单个单位销毁失败只打一条日志，不阻断其余单位，失败的单位也照样摘出登记表。
-- 登记表以所有者为键，清空时整条记录摘掉：短命的所有者（一次气泡、一个界面实例）不会留在表里。
local OwnedUnits = {}

-- 所有者 → { Units = { 单位… }, Index = { [单位] = 下标 } }；Index 用来给重复登记去重。
local Registry = {}

---把单位交给所有者保管，返回单位本身。空所有者或空单位不登记（也返回原值），不报错。
---@param owner table|string
---@param unit table|nil
---@return table|nil
function OwnedUnits.Track(owner, unit)
    if owner == nil or unit == nil then return unit end
    local entry = Registry[owner]
    if not entry then
        entry = { Units = {}, Index = {} }
        Registry[owner] = entry
    end
    if not entry.Index[unit] then
        entry.Units[#entry.Units + 1] = unit
        entry.Index[unit] = #entry.Units
    end
    return unit
end

---销毁所有者名下的全部单位。幂等：没有记录或重复调用都是空操作。
---先摘记录再逐个销毁，单个单位销毁失败不会让它留在登记表里。
---@param owner table|string
function OwnedUnits.Clear(owner)
    if owner == nil then return end
    local entry = Registry[owner]
    if not entry then return end
    Registry[owner] = nil
    for _, unit in ipairs(entry.Units) do
        local ok, err = pcall(function() unit:Destroy() end)
        if not ok then
            print('[OwnedUnits] 单位销毁失败', tostring(owner), tostring(err))
        end
    end
end

---取所有者当前名下的单位数。
---@param owner table|string
---@return number
function OwnedUnits.Count(owner)
    if owner == nil then return 0 end
    local entry = Registry[owner]
    return entry and #entry.Units or 0
end

return OwnedUnits
