-- 玩家行为表共用件（L2 server.world_host）：盲盒 / 平台商店 / 渔夫 / 商店四套行为表原来各写一份
-- 同语义的推进样板（意图袋、帧活跃判定、写档、幂等重放、实例装配），集中到这里按 spec 生成。
-- 各模块只保留自己的业务分支；本模块不反向 require 任何玩家模块。

local PlayerBehaviorKit = {}

--- 取（必要时建）存档 extra 下的意图袋：intents / deliveries 两个子表保证存在。
---@param data table 玩家存档草稿
---@param key string 存档 extra 下的键名（如 "lottery" / "platformShop"）
---@return table<string, any>
function PlayerBehaviorKit.bag(data, key)
  local extra = data.extra
  if type(extra) ~= "table" then extra = {}; data.extra = extra end
  local value = extra[key]
  if type(value) ~= "table" then value = {}; extra[key] = value end
  value.intents, value.deliveries = value.intents or {}, value.deliveries or {}
  return value
end

--- 意图 / 交付表的稳定键序：推进与清理都按 key 排序，同一份存档两端顺序一致。
---@param map table|nil
---@return string[]
function PlayerBehaviorKit.sorted_keys(map)
  local keys = {}
  for key in pairs(map or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

--- 造一套意图推进方法，并交回对应的取袋函数。
--- 生成的 write 走 behavior.reply 回失败包（各模块自己的频道），故不在这里固定频道。
---@param behavior table 行为表（self 的实参形态是玩家树，reply 只能从行为表取）
---@param spec { env_field: string, bag_key: string } env_field 环境字段名，bag_key 存档 extra 下的键名
---@return table methods { sync_frame_active, sync_tree, current_token, write }
---@return fun(data: table): table<string, any> bag
function PlayerBehaviorKit.methods(behavior, spec)
  local methods = {}
  local function bag(data) return PlayerBehaviorKit.bag(data, spec.bag_key) end
  local function env_of(self) return self[spec.env_field] end

  -- 帧相位活跃判定：有待交付或未结清的 intent 才订阅 on_frame 推进。
  function methods.sync_frame_active(self)
    local env = env_of(self)
    if env.lifecycle.disposed then return end
    local value = bag(env.data)
    local active = next(value.deliveries) ~= nil
    if not active then
      for _, intent in pairs(value.intents) do
        if intent.state == "awaiting" or intent.state == "paid" then
          active = true
          break
        end
      end
    end
    env.frame_active:set(active)
  end

  -- 存档草稿落账后同步回树；已销毁不再同步。
  function methods.sync_tree(self)
    local env = env_of(self)
    if not env.lifecycle.disposed then env.tree:sync_from_data(env.data) end
  end

  -- 本回合的平台会话令牌；没有会话时返回 nil。
  function methods.current_token(self)
    local env = env_of(self)
    local session = env.save and env.save.sessions[env.player.UserId]
    return session and session.token or nil
  end

  -- 单次写档：占用 working 锁 → execute → 成功时同步树并重算帧活跃 → 回 done；
  -- 未被接受时释放锁并回一条失败包（各模块的 reply 契约）。
  function methods.write(self, kind, transform, done)
    local env = env_of(self)
    if env.lifecycle.disposed or env.working then return false, "pending" end
    local operation, reason = env.save:next_operation(env.player, kind)
    if not operation then return false, reason or "pending" end
    env.working = true
    local accepted, failure = env.save:execute(env.player, env.data, operation, transform,
      function(ok, result)
        env.working = nil
        if ok then methods.sync_tree(self) end
        methods.sync_frame_active(self)
        done(ok, result, operation)
      end)
    if not accepted then
      env.working = nil
      behavior.reply(self, { ok = false, reason = failure, deliveryPending = true })
    end
    return accepted, failure
  end

  return methods, bag
end

--- 造幂等请求解析方法 (self, payload)：命中重放的请求把结果回放给客户端，不再改状态。
---@param behavior table 行为表（self 的实参形态是玩家树，reply 只能从行为表取）
---@param spec { env_field: string, kind: string } env_field 环境字段名，kind 存档操作类别（如 "shop"）
---@return fun(self: table, payload: table): table|nil, boolean|nil
function PlayerBehaviorKit.resolve_fn(behavior, spec)
  return function(self, payload)
    local env = self[spec.env_field]
    local request_id = payload.operation
    if request_id ~= nil and type(request_id) ~= "table" then return nil, false end
    if request_id == nil then request_id = payload.seq end
    local operation, mode = env.save:resolve_request(env.player, env.data, spec.kind, request_id)
    if not operation then return nil, false end
    if mode ~= "replay" then return operation end
    local accepted = env.save:execute(env.player, env.data, operation, function() return nil, "expired" end,
      function(ok, result)
        if ok then result.operation = operation behavior.reply(self, result) end
      end)
    return nil, accepted
  end
end

--- 造玩家交互实例的 mount 方法 (scope, tree, opts)：依赖集中进 env、行为表方法铺到句柄、
--- handle 接到树上对应的动作信号；清理时把 env.cleaned 置位。
---@param spec { env_field: string, behavior: table, action_key: string } env_field 环境字段名，action_key 树上的动作键（interact / shop）
---@return fun(scope: table, tree: table, opts: table|nil): table
function PlayerBehaviorKit.mounter(spec)
  return function(scope, tree, opts)
    opts = type(opts) == "table" and opts or {}
    ---@type table<string, any>
    local handle = {
      [spec.env_field] = {
        player = tree.player,
        data = tree.data,
        save = opts.save,
        remote = opts.remote,
        tree = tree,
        opts = opts,
        cleaned = false,
        last_seq = 0,
      },
    }
    for name, method in pairs(spec.behavior) do
      handle[name] = method
    end
    local function handle_action(actor, payload)
      return handle:handle(actor, payload)
    end
    local actions = tree.actions
    if actions and actions[spec.action_key] then
      scope:subscribe(actions[spec.action_key], function(event)
        event.result = handle_action(tree.player, event.payload)
      end)
    end
    scope:on_cleanup(function() handle[spec.env_field].cleaned = true end)
    return { handle = handle_action }
  end
end

return PlayerBehaviorKit
