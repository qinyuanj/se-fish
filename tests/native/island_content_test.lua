-- 三座岛内容接线（#136 蟹湖 / #141 树林岛 / #142 沙滩岛）的参数化合并测试。
-- 合并自 tests/native/beach_island_cfg_test.lua（7 例）、tests/native/forest_island_cfg_test.lua（6 例）、
-- tests/native/crab_lake_cfg_test.lua（5 例）：三份文件同构，只有岛序号与数值不同，断言集合一字不差。
-- 这里改成一张岛参数表驱动三座岛跑同一组断言，18 例收敛成 5 例——减掉的是抄表，不是覆盖面。
-- 只用静态内容表，不需要场景夹具：三座岛的水区几何与场景合同不在本文件的覆盖面里。
--
-- 失败方式（先列后写）：
--   1. 岛鱼模型号不在 FishCarrier.Models（官方模型库 7000544–7000563）里，即虚构官方模型号；
--   2. 信物链 / 渔夫兑换 / 出岛航线三表错位：第 i 行接了别的岛、精英信物换到别岛首领饵、
--      首领信物换到别岛船票、兑换出的船票名字对不上下一座岛（玩家走到下一岛门口上不了船）；
--   3. 摊位分级破了：本岛摊位等级不是区序号，本岛鱼饵或本岛最高竿级对应的鱼竿在低级摊位就能买到
--      （玩家提前买到高级新品），或本岛摊位上根本买不到（卡死在本岛）；
--   4. 未实装的鱼被摆进玩家可遇路径（抽鱼池 / 信物链精英与首领），抽上来一条不存在的鱼；
--   5. 可达性破了：不挂饵竿 1 抽不到保底鱼（新手卡死在第一竿）、竿 1 越级抽到高阶行、
--      本岛最高竿级也摸不到池里某一行（死行）、首领混进普通抽鱼池。
--
-- 留下的六类断言都是行为或跨真源守卫（真源 ↔ 真源）：
--   1. 模型号：岛鱼 Fish[x].Model 必须在 GameCfg.FishCarrier.Models 里。ContentValidation.Check 不查
--      Model 字段，写错的号要到 MgrFishUnit 建鱼时才会炸。
--   2. 三表绑定：Content.Exchanges[i] ↔ Interact.Fishermen[i] ↔ Ferry.Routes 的出岛腿必须说同一件事，
--      船票再按物品表名字对下一座岛。ContentValidation L112-126 只查 Exchanges 内部（鱼种、信物、
--      兑换物各自存在），跨表错位没人查。
--   3. 摊位分级：本岛摊位等级 = 区序号（ZoneMarkers.Resolve 用 Shop.Stands[i] 找第 i 区摊位锚点）；
--      本岛鱼饵 Zones[i].BaitItemId 与本岛抽鱼池要求的最高竿级对应的鱼竿是当地新品：
--      本岛摊位买得到，低一级摊位买不到。
--   4. 实装翻正：本岛抽鱼池与信物链上的每条鱼 implemented 必须为 true。
--   5. 可达性：在真实抽鱼池上跑 FishCatch.Select——不挂饵竿 1 只出保底行（含极品）、挂本岛饵竿 1
--      抽不到高阶行、岛屿最高竿级摸得到池里每一行、首领由首领饵必出所以不入池。
--      期望集合按池行的 Bait / RodLevel / Grade 派生，不抄 id 清单。
--   6. 战斗标签在册：Fish[x].Combat 必须在 GameCfg.FishCombat 里有参数表（防御式取值，写错只会静默不攻击）。
--
-- 砍掉的数值快照与接手方（接不住的就写「不再拦」）：
--   13 行抽鱼池的逐行数值快照（每行饵 id、权重、竿级的字面量）与逐岛可行域快照 ——
--     行内字段的合法性（竿级 1–7、权重/价格为正、饵与鱼种存在、编号不重复、七区各有普通池）
--     由 ContentValidation 接；FishCatch.Select 的竿级/饵过滤由 fish_loot_test、shrimp_pond_test、
--     growth_cleanup_test 接；逐行数字不再拦。可达性本身留在第 5 类（按池行派生）。
--   水区 Center / HalfX / HalfZ 常量与「两区水区不相交」—— 原来拦的是 tests/support/zone_fixtures
--     自己造的灰盒坐标（基架自测）；进 Water.Zones / ZoneIdByWater 与重叠、越界由 ZoneMarkers.Resolve
--     自己 error，zone_fixtures.Load 在每个用夹具的测试里都会跑一遍。数值常量不再拦。
--   FishCombat 的二十多个数字 —— 表存在与消费由 beach_combat_test、forest_combat_test、
--     crab_boss_combat_test、king_crab_combat_test 接（直接读 GameCfg.FishCombat.<名字>）；精确数字不再拦。
--   票价与 Return.Price 常量 —— ferry_test 的 test_config_pins（10 × 3^(i-1)）接。
--   摊位价目与具体上架行 —— shop_pages_test 的价格/等级基线 + ContentValidation 的「可用商品的价格/
--     等级与内容行一致」+ shop_test 的扣费接。
--   首领饵映射（item122 / item123 / item124 → 首领鱼）—— boss_bait_test 的 test_config_pins 全表钉住。
--   蟹湖「首领饵不走 Bait 库存、不按普通饵卖」口径 —— BossBait 标记由 ContentValidation L119 接，
--     BaitPrice 整表由 exchange_zones_127_test 钉住（item122 不在其中），Container 口径由
--     fish_loot_test 按 BossBait 物品接；item122 这个号本身不再单独拦。
--   信物链内部字段（EliteToken / BossToken / Result 等）—— ContentValidation L112-126 接。
--   GrillName 与烧烤坐标 —— grill_test 的 test_anchors_cover_zones_three_to_seven 接（index ≥ 3 有 GrillName、
--     更前面的区没有）；坐标本身是 zone_fixtures 的夹具值，不再拦。
--   「摊位锚点名 == 场景合同 ShopName」—— Scene.ShopName 由 ZoneMarkers.Resolve 从
--     Shop.Stands[i].AnchorName 派生，再断言一次等于把实现抄一遍（复述），删。
--   「精英 / 首领鱼带 Combat 标签」—— 标签到 GameCfg.FishCombat 的映射目前没人拦
--     （MgrFishUnit 用 `GameCfg.FishCombat and GameCfg.FishCombat[species.Combat]` 防御式取值，
--     缺表静默不攻击）；明确不再拦。
local cfg = require('common.GameCfg')
local FishCatch = require('common.FishCatch')

-- 三座岛的参数：Index 是钓鱼区 / 信物链 / 渔夫 / 摊位的序号（蟹湖 3、树林岛 4、沙滩岛 5）。
-- 水区 ID、鱼种、船票、鱼竿一律按序号从真源派生，不另抄一份 id 清单。
local ISLANDS = {
  { Id = 'crabLake', Index = 3, Name = '蟹湖' },
  { Id = 'forestIsland', Index = 4, Name = '树林岛' },
  { Id = 'beachIsland', Index = 5, Name = '沙滩岛' },
}

-- 按序号取本岛钓鱼区，顺带钉住「第 Index 个钓鱼区就是这座岛」：行序错位先在这里红
local function zoneOf(island)
  local zone = cfg.Zones[island.Index]
  assert.is_not_nil(zone, '缺第 ' .. island.Index .. ' 个钓鱼区')
  assert.are.equal(island.Id, zone.Id, '第 ' .. island.Index .. ' 个钓鱼区不是 ' .. island.Name)
  return zone
end

local function chainOf(island)
  local chain = cfg.Content.Exchanges[island.Index]
  assert.is_not_nil(chain, island.Name .. ' 缺信物链')
  return chain
end

-- 本岛抽鱼池：行必须存在、非空，且每行都指得到鱼种
local function poolOf(island)
  local zone = zoneOf(island)
  local rows = cfg.Casting.Zones[zone.WaterId]
  assert.is_not_nil(rows, island.Name .. ' 缺抽鱼池 ' .. tostring(zone.WaterId))
  assert.is_true(#rows > 0, island.Name .. ' 抽鱼池为空')
  for _, row in ipairs(rows) do
    assert.is_not_nil(cfg.Fish[row.Id], island.Name .. ' 抽鱼池行指向不存在的鱼种 ' .. tostring(row.Id))
  end
  return rows
end

-- 玩家在本岛实际会遇到的鱼种：抽鱼池行 + 信物链的精英 / 首领（首领由首领饵必出，不入池）
local function islandSpecies(island)
  local chain = chainOf(island)
  local list = {}
  for _, row in ipairs(poolOf(island)) do list[#list + 1] = cfg.Fish[row.Id] end
  for _, key in ipairs({ 'EliteFish', 'BossFish' }) do
    local species = cfg.Fish[chain[key]]
    assert.is_not_nil(species, island.Name .. ' 信物链 ' .. key .. ' 指向不存在的鱼种 ' .. tostring(chain[key]))
    list[#list + 1] = species
  end
  return list
end

-- 跑一遍真实抽签，收集 FishCatch.Select 在（竿级, 饵）下能抽到的全部鱼种。
-- 可用权重和直接用 Select 传给 random 的参数取出，不在这里重写它的过滤条件。
local function drawSet(rows, rodLevel, baitId)
  local total
  FishCatch.Select(rows, rodLevel, baitId, function(max) total = max; return 1 end)
  local found = {}
  if not total then return found end
  for roll = 1, total do
    local id = FishCatch.Select(rows, rodLevel, baitId, function() return roll end)
    if id then found[id] = true end
  end
  return found
end

describe("TestIslandContent", function()
  -- 模型号真源是官方模型库：鱼种写哪个号，号本身必须在册（防虚构号）
  it("test_island_species_models_are_official", function()
    local models = cfg.FishCarrier.Models
    for _, island in ipairs(ISLANDS) do
      for _, species in ipairs(islandSpecies(island)) do
        assert.is_not_nil(models[species.Model],
          island.Name .. ' 鱼种 ' .. species.Id .. ' 的模型号 ' .. tostring(species.Model) .. ' 不在官方注册表')
      end
    end
  end)

  -- 信物链 / 渔夫兑换 / 出岛航线三表绑定：同一序号说的必须是同一座岛与同一张船票
  it("test_exchange_chain_fisherman_and_ferry_bind_to_same_island", function()
    for _, island in ipairs(ISLANDS) do
      local zone = zoneOf(island)
      local chain = chainOf(island)
      local nextZone = cfg.Zones[island.Index + 1]
      assert.is_not_nil(nextZone, island.Name .. ' 不是最后一区，但表里没有下一区')
      assert.are.equal(zone.Id, chain.ZoneId, island.Name .. ' 的信物链挂了别的钓鱼区')
      local fisherman = cfg.Interact.Fishermen[island.Index]
      assert.is_not_nil(fisherman, island.Name .. ' 缺第 ' .. island.Index .. ' 位渔夫')
      assert.are.equal(chain.ZoneId, fisherman.ZoneId, island.Name .. ' 的渔夫兑换挂到别的岛')
      assert.are.equal(chain.BossBait, fisherman.Exchange[chain.EliteToken],
        island.Name .. ' 的精英信物换到的不是本岛首领饵')
      assert.are.equal(chain.Result, fisherman.Exchange[chain.BossToken],
        island.Name .. ' 的首领信物换到的不是本岛船票')
      -- 兑换出的船票要真能开到下一座岛：物品表名字、钓鱼区表名字、航线去程票三处对上
      local ticket = cfg.Items.Definitions[chain.Result]
      assert.is_not_nil(ticket, island.Name .. ' 的兑换物 ' .. tostring(chain.Result) .. ' 不在物品表')
      assert.are.equal(nextZone.Name .. '船票', ticket.Name, island.Name .. ' 兑换出的不是开往下一岛的船票')
      local route
      for _, candidate in ipairs(cfg.Ferry.Routes) do
        if candidate.FromZoneId == island.Id then route = candidate end
      end
      assert.is_not_nil(route, island.Name .. ' 缺出岛航线')
      assert.are.equal(nextZone.Id, route.ToZoneId, island.Name .. ' 的出岛航线终点不是下一座岛')
      assert.are.equal(chain.Result, route.Outbound.Ticket, island.Name .. ' 的出岛航线去程票不是本岛信物链的兑换物')
    end
  end)

  -- 摊位分级：等级 = 区序号；本岛鱼饵与本岛最高竿级的鱼竿是当地新品，本岛买得到、低一级买不到
  it("test_lower_stand_cannot_buy_island_new_goods", function()
    local pages = { '钓具', '武器', '升级', '金币' }
    local function shelf(level)
      local index = {}
      for _, page in ipairs(pages) do
        for _, row in ipairs(cfg.Shop.ListForPage(level, page)) do
          if row.ItemId then index[row.ItemId] = row end
        end
      end
      return index
    end
    local function rodsFor(level)
      local keys = {}
      for key, item in pairs(cfg.Items.Definitions) do
        if item.Type == '鱼竿' and item.Level == level then keys[#keys + 1] = key end
      end
      return keys
    end
    for _, island in ipairs(ISLANDS) do
      local zone = zoneOf(island)
      local stand = cfg.Shop.Stands[island.Index]
      assert.is_not_nil(stand, island.Name .. ' 缺第 ' .. island.Index .. ' 号摊位')
      assert.are.equal(island.Index, stand.Level, island.Name .. ' 的摊位等级不是本区序号')
      local need = 0
      for _, row in ipairs(poolOf(island)) do
        if row.RodLevel > need then need = row.RodLevel end
      end
      local rods = rodsFor(need)
      assert.is_true(#rods > 0, island.Name .. ' 抽鱼池要求的竿级 ' .. need .. ' 没有对应鱼竿')
      local want = { zone.BaitItemId }
      for _, key in ipairs(rods) do want[#want + 1] = key end
      local here, lower = shelf(stand.Level), shelf(stand.Level - 1)
      for _, key in ipairs(want) do
        assert.is_not_nil(here[key], island.Name .. ' 的 ' .. stand.Level .. ' 级摊位买不到 ' .. key)
        assert.is_nil(lower[key], stand.Level - 1 .. ' 级摊位提前卖出了 ' .. island.Name .. ' 的新品 ' .. key)
      end
    end
  end)

  -- 实装翻正：未实装的鱼不得出现在玩家可遇路径上
  it("test_island_species_are_implemented", function()
    for _, island in ipairs(ISLANDS) do
      for _, species in ipairs(islandSpecies(island)) do
        assert.is_true(species.implemented,
          island.Name .. ' 鱼种 ' .. species.Id .. ' 未标 implemented 却出现在玩家可遇路径上')
      end
    end
  end)

  -- 可达性：真实抽鱼池上跑 FishCatch.Select——保底（不挂饵竿 1）、门槛（竿 1 不越级）、
  -- 池顶（岛屿最高竿级摸得到每一行）、首领不入普通池
  it("test_island_pool_reachability", function()
    for _, island in ipairs(ISLANDS) do
      local zone = zoneOf(island)
      local chain = chainOf(island)
      local rows = poolOf(island)
      local bait = zone.BaitItemId
      local byId, maxRodLevel, bossRows = {}, 0, 0
      for _, row in ipairs(rows) do
        byId[row.Id] = row
        if row.RodLevel > maxRodLevel then maxRodLevel = row.RodLevel end
        if cfg.Fish[row.Id].Grade == 'boss' then bossRows = bossRows + 1 end
      end
      assert.are.equal(0, bossRows, island.Name .. ' 的首领混进了普通抽鱼池（首领只由首领饵必出）')
      -- 保底：不挂饵 + 竿 1 只能出不需要饵的保底行（含极品），且池里每条保底行都摸得到
      local noBait = drawSet(rows, 1, nil)
      assert.is_true(next(noBait) ~= nil, island.Name .. ' 不挂饵竿 1 抽不到任何鱼')
      for id in pairs(noBait) do
        assert.is_not_nil(byId[id], island.Name .. ' 抽到池外的鱼种 ' .. tostring(id))
        assert.are.equal(0, byId[id].Bait, island.Name .. ' 的 ' .. id .. ' 要鱼饵，却被无饵抽中')
        assert.is_true(byId[id].RodLevel <= 1, island.Name .. ' 竿 1 越级抽到了 ' .. id)
      end
      for _, row in ipairs(rows) do
        if row.Bait == 0 and row.RodLevel <= 1 then
          assert.is_true(noBait[row.Id] == true, island.Name .. ' 的保底行 ' .. row.Id .. ' 抽不到')
        end
      end
      -- 门槛：挂本岛饵 + 竿 1 抽不到高阶行，也抽不到用别的饵的行
      local lowRod = drawSet(rows, 1, bait)
      assert.is_true(next(lowRod) ~= nil, island.Name .. ' 挂本岛饵竿 1 抽不到任何鱼')
      for id in pairs(lowRod) do
        assert.is_not_nil(byId[id], island.Name .. ' 抽到池外的鱼种 ' .. tostring(id))
        assert.is_true(byId[id].RodLevel <= 1,
          island.Name .. ' 竿 1 越级抽到了 ' .. id .. '（该行竿级 ' .. tostring(byId[id].RodLevel) .. '）')
        assert.is_true(byId[id].Bait == 0 or byId[id].Bait == bait,
          island.Name .. ' 的 ' .. id .. ' 用了本岛之外的鱼饵 ' .. tostring(byId[id].Bait))
      end
      -- 池顶：岛屿最高竿级 + 本岛饵要摸得到池里每一行（含精英），否则就是死行
      local top = drawSet(rows, maxRodLevel, bait)
      for _, row in ipairs(rows) do
        if row.Bait == 0 or row.Bait == bait then
          assert.is_true(top[row.Id] == true,
            island.Name .. ' 在最高竿级 ' .. maxRodLevel .. ' 也抽不到 ' .. row.Id)
        end
      end
      assert.is_true(top[chain.EliteFish] == true,
        island.Name .. ' 的精英鱼 ' .. tostring(chain.EliteFish) .. ' 不在可达集合里')
    end
  end)

  -- 战斗标签在册：MgrFishUnit 用 \`GameCfg.FishCombat and GameCfg.FishCombat[tag]\` 防御式取值，
  -- 标签写错不会有任何报错，只是这条鱼在场上永不攻击（追不动、不还手、死了不掉落也不进图鉴）。
  -- 战斗参数表本身由 beach/forest/crab_boss/king_crab 各战斗测试直接消费，这里只钉「标签指得到表」。
  it("test_island_species_combat_tags_are_registered", function()
    for _, island in ipairs(ISLANDS) do
      for _, species in ipairs(islandSpecies(island)) do
        if species.Combat ~= nil then
          assert.is_not_nil(cfg.FishCombat[species.Combat],
            island.Name .. ' 鱼种 ' .. species.Id .. ' 的 Combat 标签 ' .. tostring(species.Combat) ..
              ' 在 GameCfg.FishCombat 里没有参数')
        end
      end
    end
  end)
end)
