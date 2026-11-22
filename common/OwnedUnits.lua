local OwnedUnits = {}

local Registry = {}

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

---@param owner table|string
---@return number
function OwnedUnits.Count(owner)
    if owner == nil then return 0 end
    local entry = Registry[owner]
    return entry and #entry.Units or 0
end

return OwnedUnits
