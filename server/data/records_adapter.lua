local GameCfg = require('common.game_cfg')
local Records = require('common.records')

local Adapter = {}

local function cfg() return GameCfg.Records end

local function classify(err)
    local text = tostring(err):lower()
    if text:find('throttl', 1, true) or text:find('limit', 1, true) or text:find('429', 1, true) then
        return 'throttled'
    end
    if text:find('timeout', 1, true) or text:find('timed out', 1, true) then return 'timeout' end
    return 'unknown'
end

function Adapter:Store()
    if self.Checked then return self.holder end
    self.Checked = true
    local ok, store = pcall(function() return game:GetService('DataStoreService'):GetDataStore(cfg().Store) end)
    if not ok or not store then
        print('[RecordsAdapter] DataStore 不可用，全服纪录按暂不可用处理', tostring(store))
        return nil
    end
    self.holder = store
    return store
end

function Adapter:Key(fishId) return cfg().KeyPrefix .. fishId end

-- 读一条鱼的全服纪录。返回 (ok, 三元组或 nil, 错误类别)：
--   ok = true 且值为 nil → 服务可用，这条鱼还没有纪录（"missing"）；
--   ok = false          → 读不到，必须按"暂不可用"处理，不能当成没有纪录。
-- 值损坏（缺重量或缺身份）按没有纪录处理：读不出可信的三元组，就不展示，也不猜。
function Adapter:Read(fishId)
    local store = self:Store()
    if not store then return false, nil, 'unavailable' end
    local key = self:Key(fishId)
    local ok, value = pcall(function() return store:GetAsync(key) end)
    if not ok then return false, nil, classify(value) end
    return true, Records.valid(value), nil
end

-- 提交候选：decide(current) 在 CAS 变换里执行。返回 (ok, won, 当前值, 错误类别)：
--   won = true  → 本次候选已写入，第三个返回的是写入后的三元组；
--   won = false → 候选没赢（已有更大纪录，或同重量按 UserID 决胜输了），第三个返回的是当时看到的当前值。
function Adapter:Submit(fishId, decide)
    local store = self:Store()
    if not store then return false, nil, nil, 'unavailable' end
    local key = self:Key(fishId)
    local seen, won
    local ok, value = pcall(function()
        return store:UpdateAsync(key, function(current)
            local valid = Records.valid(current)
            seen = valid
            local next_ = decide(valid)
            if not next_ then return nil end -- 放弃：不产生写入
            won = true
            return next_
        end)
    end)
    if not ok then return false, nil, nil, classify(value) end
    if won then return true, true, Records.valid(value), nil end
    return true, false, seen, nil
end

return Adapter
