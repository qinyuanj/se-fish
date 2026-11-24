-- 服务端共享世界 Auto SpokeTree（ADR-0032 §1 / #295）：
-- 全局唯一宿主容器，按 GameCfg.Zones 顺序挂载 7 个钓鱼区子域骨架
-- （地面物品、鱼饵刷新点、摆渡航线 Dock）与全局小队 SquadDock。
-- 本模块归属 L2（server.WorldHost），零反向依赖存量旧债务模块。

local GameCfg = require("common.game_cfg")
local spoke = require("common.packages.spoke.api")
local GroundLoot = require("server.WorldHost.GroundLoot")
local FerryRoute = require("server.WorldHost.FerryRoute")
local SquadDock = require("server.WorldHost.SquadDock")

local SpokeTree = spoke.SpokeTree
local Effect = spoke.Effect

local SharedWorldTree = {}

local function assert_clock(clock)
  if type(clock) ~= "table"
      or type(clock.now) ~= "function"
      or type(clock.second) ~= "table"
      or type(clock.on_second) ~= "table"
      or type(clock.on_frame) ~= "table" then
    error("SharedWorldTree.spawn 需要有效的 SpokeClock 实例", 3)
  end
end

---@param opts { clock: table, zones?: table[], logger?: table, on_mount_zone?: fun(s: table, zone: table), on_mount_world?: fun(s: table, world: table) }
function SharedWorldTree.spawn(opts)
  if type(opts) ~= "table" then
    error("SharedWorldTree.spawn 需要参数表", 2)
  end
  assert_clock(opts.clock)

  local clock = opts.clock
  local zone_defs = opts.zones or GameCfg.Zones
  if type(zone_defs) ~= "table" or #zone_defs == 0 then
    error("SharedWorldTree.spawn 需要非空钓鱼区配置", 2)
  end

  local zones = {}
  local zone_list = {}
  local handle = {
    clock = clock,
    zones = zones,
    zone_list = zone_list,
    squads = nil,
    tree = nil,
  }

  local services = opts.logger and { logger = opts.logger } or nil
  local root = Effect.new("SharedWorldRoot", function(s)
    s:export("clock", clock)
    s:export("world", handle)

    -- 严格按配置顺序挂载 7 个钓鱼区子域骨架，保证声明顺序即坐标与逆序清理顺序。
    for index, zone_cfg in ipairs(zone_defs) do
      local zone_id = zone_cfg.Id
      s:effect("FishingZone:" .. zone_id, function(zs)
        local zone = {
          index = index,
          id = zone_id,
          name = zone_cfg.Name,
          water_id = zone_cfg.WaterId,
          bait_item_id = zone_cfg.BaitItemId,
          ground_loot = zs:dock("GroundLoot:" .. zone_id),
          bait_spots = zs:dock("BaitSpots:" .. zone_id),
          ferry_routes = zs:dock("FerryRoutes:" .. zone_id),
        }
        zs:export("zone", zone)
        zones[zone_id] = zone
        zone_list[index] = zone

        if type(opts.on_mount_zone) == "function" then
          opts.on_mount_zone(zs, zone)
        end
      end)
    end

    handle.squads = s:dock("SquadDock")

    if type(opts.on_mount_world) == "function" then
      opts.on_mount_world(s, handle)
    end
    -- 子 Effect 按声明顺序在根 Init 后运行：此时七个区的 Dock 已建好，GroundLoot 才能初始补货。
    s:effect("GroundLoot", function(gs)
      GroundLoot.mount(handle, {
        scope = gs,
        create_unit = opts.create_unit,
        remote = opts.remote,
        bait_spots = opts.bait_spots,
        logger = opts.logger,
        lookup_tree = opts.lookup_tree,
      })
    end)
  end)

  handle.tree = SpokeTree.spawn("SharedWorldTree", root, services)
  FerryRoute.mount(handle, {
    remote = opts.remote,
    player_data = opts.player_data,
    save = opts.save,
    interact = opts.interact,
    players_service = opts.players_service,
    lookup_tree = opts.lookup_tree,
  })
  SquadDock.mount(handle, {
    remote = opts.remote,
    player_data = opts.player_data,
    lookup_tree = opts.lookup_tree,
    session_epoch = opts.session_epoch,
    logger = opts.logger,
  })

  function handle:get_zone(zone_id)
    return zones[zone_id]
  end

  function handle:is_disposed()
    return self.tree.is_detached == true
  end

  function handle:is_faulted()
    return self.tree.fault ~= nil
  end

  function handle:fault()
    return self.tree.fault
  end

  function handle:dispose()
    if self.tree and not self.tree.is_detached then
      self.tree:dispose()
    end
  end

  return handle
end

return SharedWorldTree
