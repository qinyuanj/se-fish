-- 统一客户端 Spoke 根视图树主干（ADR-0032 / #296，归属 L2 client.views）：
-- 挂载于宿主根 UI 节点，经 SpokeEggy.behaviour 绑定 Unit -> Tree 生命周期；
-- 树内所有动态创建子节点与局部信号均通过 ctx.create_node / ctx.own_node / ctx.connect 在同作用域 on_cleanup 对称释放；
-- 统一承载常驻 HUD、互斥模态弹窗 Phase、覆盖蒙版 Phase、动态集合 Dock，并在 store.on_reconnect 时整体干净重建。

local Spoke = require("common.packages.spoke.api")
local SpokeEggy = require("common.packages.spoke_eggy.api")
local ViewUtil = require("client.views.view_util")

local Effect = Spoke.Effect
local State = Spoke.State

local RootView = {}

local function sorted_keys(map)
  local keys = {}
  if type(map) ~= "table" then
    return keys
  end
  for key in pairs(map) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function readonly_item_signal(state)
  local fields = {
    now = function()
      return state:now()
    end,
    d = function(_, reader)
      return reader:d(state)
    end,
    subscribe = function(_, fn)
      return state:subscribe(fn)
    end,
    unsubscribe = function(_, fn)
      state:unsubscribe(fn)
    end,
  }
  return setmetatable({}, {
    __index = fields,
    __newindex = function(_, key)
      error("DockItemSignal 为只读信号，禁止写入字段: " .. tostring(key), 2)
    end,
    __metatable = false,
  })
end

local function default_create_node(kind, props)
  local world = game:GetService("World")
  return world:CreateUnit(kind, props)
end

local function destroy_node_safely(node)
  if node == nil then
    return
  end
  pcall(function() node:Destroy() end) -- 宿主节点可能已随父级销毁失效，忽略重复销毁异常
end

local function disconnect_safely(conn)
  if conn == nil then
    return
  end
  pcall(function() conn:Disconnect() end) -- 宿主连接可能已随节点销毁自动断开，忽略重复断开异常
end

local function own_node(scope, node)
  if node ~= nil then
    local destroyed = false
    local ok_sig, destroying_sig = pcall(function() return node.Destroying end) -- 宿主节点可能不暴露 Destroying 信号，按无信号处理
    local destroying_conn = nil
    if ok_sig and destroying_sig ~= nil and type(destroying_sig.Connect) == "function" then
      destroying_conn = destroying_sig:Connect(function()
        destroyed = true
      end)
    end
    scope:on_cleanup(function()
      disconnect_safely(destroying_conn)
      destroying_conn = nil
      if not destroyed then
        destroyed = true
        destroy_node_safely(node)
      end
    end)
  end
  return node
end

--- 创建节点并交给当前作用域托管：默认父级为根 UI，创建失败直接报错。
local function create_ctx_node(root_node, node_factory, scope, kind, props)
  local final_props = {}
  if type(props) == "table" then
    for k, v in pairs(props) do
      final_props[k] = v
    end
  end
  if final_props.Parent == nil then
    final_props.Parent = root_node
  end
  local node = node_factory(kind, final_props)
  if node == nil then
    error("RootView 动态创建 UI 节点失败: " .. tostring(kind), 2)
  end
  return own_node(scope, node)
end

--- 连接签名并在作用域清理时断开。
local function connect_scoped(scope, signal, handler)
  if signal == nil or type(signal.Connect) ~= "function" then
    return nil
  end
  local conn = signal:Connect(handler)
  scope:on_cleanup(function()
    disconnect_safely(conn)
  end)
  return conn
end

--- 服务表：选项注入的服务在前，store / root_node / clock 固定覆盖。
local function build_services(extra, store, root_node)
  local services = {}
  if type(extra) == "table" then
    for key, value in pairs(extra) do
      services[key] = value
    end
  end
  services.store = store
  services.root_node = root_node
  services.clock = store.clock
  return services
end

--- 视图上下文：根节点、只读 store、服务表与节点 / 连接托管入口。
local function new_context(root_node, store, services, node_factory, is_alive)
  local ctx = {
    root_node = root_node,
    store = store,
    clock = store.clock,
    services = services,
    is_alive = is_alive,
    own_node = own_node,
    connect = connect_scoped,
  }
  ctx.create_node = function(scope, kind, props)
    return create_ctx_node(root_node, node_factory, scope, kind, props)
  end
  return ctx
end

--- 1. 常驻 HUD：挂载于根视图树，不受弹窗切换重建影响。
local function mount_hud_specs(bs, ctx, hud_option)
  local hud_specs = hud_option
  if type(hud_specs) == "function" then
    hud_specs = hud_specs(bs, ctx)
  end
  for index, spec in ipairs(hud_specs) do
    local hud_name = spec.name or ("Hud_" .. tostring(index))
    local mount_fn = spec.mount
    if type(mount_fn) == "function" then
      bs:effect("Hud:" .. hud_name, function(hs)
        mount_fn(hs, ctx)
      end)
    end
  end
end

--- 2. 互斥模态弹窗 Phase：统一订阅 store.active_modal，同一时刻至多挂载一个弹窗。
local function mount_modal_specs(bs, ctx, modal_specs)
  local store = ctx.store
  for _, modal_id in ipairs(sorted_keys(modal_specs)) do
    local mount_fn = modal_specs[modal_id]
    if type(mount_fn) == "function" then
      local is_open = bs:memo("ModalOpen:" .. modal_id, function(ms)
        return ms:d(store.active_modal) == modal_id
      end)
      bs:phase("Modal:" .. modal_id, is_open, function(ps)
        mount_fn(ps, ctx)
      end)
    end
  end
end

--- 覆盖蒙版活跃条件：spec.when 可为函数（按 store 派生）、信号表或省略（读 store.overlays 标志）。
local function overlay_condition(bs, spec, overlay_id, store)
  if type(spec.when) == "function" then
    return bs:memo("OverlayWhen:" .. overlay_id, function(ms)
      return spec.when(ms, store) == true
    end)
  end
  if type(spec.when) == "table" and type(spec.when.now) == "function" then
    return spec.when
  end
  return bs:memo("OverlayWhen:" .. overlay_id, function(ms)
    local flags = ms:d(store.overlays)
    return type(flags) == "table" and flags[overlay_id] == true
  end)
end

--- 3. 覆盖蒙版 Phase：可由业务状态派生或显式 store.overlays 独立控制。
local function mount_overlay_specs(bs, ctx, overlay_specs)
  local store = ctx.store
  for _, overlay_id in ipairs(sorted_keys(overlay_specs)) do
    local spec = overlay_specs[overlay_id]
    if type(spec) == "table" and type(spec.mount) == "function" then
      local cond = overlay_condition(bs, spec, overlay_id, store)
      bs:phase("Overlay:" .. overlay_id, cond, function(ps)
        spec.mount(ps, ctx)
      end)
    end
  end
end

--- 单个 Dock 项：已有则原地刷新，新 key 建 state 与只读信号后交给 dock。
local function sync_dock_item(ctx, spec, dock, entries, key, item)
  local existing = entries[key]
  if existing ~= nil then
    existing.state:set(item)
    return
  end
  local item_state = State.new("DockItemState:" .. key, item)
  local ro_item = readonly_item_signal(item_state)
  entries[key] = { state = item_state }
  dock:call(key, Effect.new("DockItem:" .. key, function(is)
    spec.mount(is, ctx, ro_item, key)
  end))
end

--- Dock 同步体：按稳定 key 增量增删与原地刷新。
local function sync_dock_items(es, ctx, spec, dock, entries)
  local list = spec.items(es, ctx.store) or {}
  local seen = {}
  for _, item in ipairs(list) do
    local key = spec.key_of(item)
    if type(key) == "string" and key ~= "" then
      seen[key] = true
      sync_dock_item(ctx, spec, dock, entries, key, item)
    end
  end
  ViewUtil.drop_stale_keys(entries, seen, dock)
end

--- 4. 动态集合 Dock：项移除时自动对称释放节点与连接。
local function mount_dock_spec(bs, ctx, spec, dock_id, active_docks)
  local dock = bs:dock("Dock:" .. dock_id)
  active_docks[dock_id] = dock
  ---@type table<string, { state: { set: fun(self: table, value: any) } }>
  local entries = {}
  bs:on_cleanup(function()
    if active_docks[dock_id] == dock then
      active_docks[dock_id] = nil
    end
    entries = {}
  end)

  if type(spec.items) == "function" and type(spec.key_of) == "function" then
    bs:effect("DockSync:" .. dock_id, function(es)
      sync_dock_items(es, ctx, spec, dock, entries)
    end)
  end
end

local function mount_dock_specs(bs, ctx, dock_specs, active_docks)
  for _, dock_id in ipairs(sorted_keys(dock_specs)) do
    local spec = dock_specs[dock_id]
    if type(spec) == "table" and type(spec.mount) == "function" then
      mount_dock_spec(bs, ctx, spec, dock_id, active_docks)
    end
  end
end

--- RootBody 装配体：HUD -> 模态 -> 覆盖蒙版 -> Dock，顺序沿用拆分前。
local function mount_root_body(bs, ctx, sources)
  mount_hud_specs(bs, ctx, sources.hud)
  mount_modal_specs(bs, ctx, sources.modals)
  mount_overlay_specs(bs, ctx, sources.overlays)
  mount_dock_specs(bs, ctx, sources.docks, sources.active_docks)
end

---@param root_node table 宿主根 UI 节点（须带 Destroying 信号）
---@param store table 只读 ClientStore
---@param options table|nil { name?, logger?, services?, create_node?, hud?, modals?, overlays?, docks? }
---@return table view_handle
function RootView.mount(root_node, store, options)
  if root_node == nil then
    error("RootView.mount 需要非空 root_node", 2)
  end
  if type(store) ~= "table" then
    error("RootView.mount 需要只读 ClientStore", 2)
  end

  options = options or {}
  local node_factory = options.create_node or default_create_node
  local active_docks = {}
  local services = build_services(options.services, store, root_node)
  local sources = {
    hud = options.hud or {},
    modals = options.modals or {},
    overlays = options.overlays or {},
    docks = options.docks or {},
    active_docks = active_docks,
  }

  local behaviour = SpokeEggy.behaviour(root_node, function(s, self)
    local ctx = new_context(root_node, store, services, node_factory, self.is_alive)
    -- 当 store.on_reconnect 触发时，RootBody 自动逆序清理上一轮全部子节点与监听，再以干净状态重建
    local body_triggers = store.on_reconnect ~= nil and { store.on_reconnect } or nil
    s:effect("RootBody", function(bs) mount_root_body(bs, ctx, sources) end, body_triggers)
  end, {
    name = options.name or "ClientRootView",
    services = services,
    logger = options.logger,
  })

  local handle = {
    behaviour = behaviour,
    root = behaviour.root,
    is_alive = behaviour.is_alive,
  }

  function handle.get_dock(_, dock_id)
    return active_docks[dock_id]
  end

  function handle.dispose(_)
    behaviour:dispose()
  end

  return handle
end

return RootView
