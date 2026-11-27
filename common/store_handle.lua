-- DataStore 句柄获取（L2 共享层）：DataStore 服务与句柄的取得统一走这里。
-- 放 L2 与 server.data 同层：数据层的校验模块（records_adapter）不能依赖 L3 的 common.engine_read。

local StoreHandle = {}

--- 取（并缓存）DataStore 句柄：首次尝试后无论成败都记下，避免每次读写都重新取服务刷屏。
---@param host table 缓存宿主：读写 host[fields.checked] / host[fields.store]
---@param fields { checked: string, store: string } 缓存字段名（各宿主既有字段名不同，测试会直接复位）
---@param store_name string
---@param failure_log string 取不到时打印的固定说明（模块自述影响面）
---@return any store
function StoreHandle.get(host, fields, store_name, failure_log)
  if host[fields.checked] then return host[fields.store] end
  host[fields.checked] = true
  -- 保留原始 pcall 错误文本：调用方要把它打出来溯源（服务缺失与 GetDataStore 失败文案不同）。
  local ok, store = pcall(function()
    -- EggyAPI 未声明 DataStoreService:GetDataStore，服务句柄按 any 取以避免静态误报。
    ---@type any
    local service = game:GetService("DataStoreService")
    if service == nil then return nil end
    return service:GetDataStore(store_name)
  end)
  if not ok or not store then
    print(failure_log, tostring(store))
    return nil
  end
  host[fields.store] = store
  return store
end

return StoreHandle
