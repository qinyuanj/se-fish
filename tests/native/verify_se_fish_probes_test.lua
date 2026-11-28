-- ADR-0044 本地多人与调试插件 AI 探针套件单测（纯 Lua 5.4，不依赖编辑器进程）。

local function load_run_module()
  return assert(loadfile(".agents/skills/verify-se-fish/scripts/probe_local_mp_run.lua"))()
end

local function run_chunk_with_env(path, env_overrides)
  local printed = {}
  local saved_print = _G.print
  local saved_game = rawget(_G, "game")
  local saved_client_spoke = rawget(_G, "ClientSpoke")
  local saved_nonce = rawget(_G, "PROBE_MP_NONCE")
  local saved_loaded = {}
  local mods = env_overrides.loaded or {}
  for k, v in pairs(mods) do
    saved_loaded[k] = package.loaded[k]
    package.loaded[k] = v
  end

  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    printed[#printed + 1] = table.concat(parts, "\t")
  end
  _G.game = env_overrides.game
  _G.ClientSpoke = env_overrides.ClientSpoke
  _G.PROBE_MP_NONCE = env_overrides.nonce

  local fn = assert(loadfile(path))
  local ok, result = pcall(fn)

  _G.print = saved_print
  _G.game = saved_game
  _G.ClientSpoke = saved_client_spoke
  _G.PROBE_MP_NONCE = saved_nonce
  for k in pairs(mods) do
    package.loaded[k] = saved_loaded[k]
  end

  assert.is_true(ok, tostring(result))
  return result, table.concat(printed, "\n")
end

local function make_player(uid, name, pos, phase)
  local char = {
    Position = pos or { x = 1, y = 2, z = 3 },
    IsA = function(_, t) return t == "EggyUnit" end,
    UnitType = "EggyUnit",
    Name = name .. "_char",
    UnitId = "u_" .. tostring(uid),
  }
  return {
    UserId = uid,
    Name = name,
    Character = char,
    GetAttribute = function(_, k)
      if k == "SurvivalPhase" then return phase or "alive" end
      return nil
    end,
  }
end

local function make_signal(val)
  return { now = function() return val end }
end

describe("ADR-0044 语义探针套件", function()
  local runner = load_run_module()

  describe("probe_local_mp_server.lua", function()
    local function build_server_env(players, opts)
      opts = opts or {}
      local descendants = {}
      for _, p in ipairs(players) do
        if p.Character then descendants[#descendants + 1] = p.Character end
      end
      for _, extra in ipairs(opts.extra_eggy or {}) do
        descendants[#descendants + 1] = extra
      end
      local cur, act, trees = {}, {}, {}
      for _, p in ipairs(opts.runtime_players or players) do
        cur[p.UserId] = p
        act[p.UserId] = p
        trees[p.UserId] = true
      end
      local sessions = opts.sessions or {}
      local SaveHost = { sessions = sessions, QaSlot = opts.qa_slot or "qa1" }
      local PlayerDataHost = {
        Save = SaveHost,
        get_data_inst = function(_, player)
          return { data = { FishCoin = 100, Zone = 1 }, owner = player.UserId }
        end,
      }
      local ServerRuntime = {
        current = function()
          return {
            runtime_env = { current_players = cur, active_players = act, player_trees = trees, leaving_players = {} },
            get_world = function() return { squad = { party_of = {}, online = cur } } end,
          }
        end,
      }
      local GameCfg = { Save = { KeyPrefix = "fish:", QaSlot = opts.qa_slot or "qa1" } }
      return {
        nonce = opts.nonce or "test1",
        game = {
          GetService = function(_, name)
            if name == "Players" then return { GetPlayers = function() return players end } end
            if name == "World" then
              return {
                GetServerTime = function() return 123.45 end,
                GetDescendants = function() return descendants end,
              }
            end
          end,
        },
        loaded = {
          ["server.world_host.server_runtime"] = ServerRuntime,
          ["server.player_data_host"] = PlayerDataHost,
          ["server.save_host"] = SaveHost,
          ["common.game_cfg"] = GameCfg,
        },
      }
    end

    it("正确统计 0 人与 1 人场景", function()
      local _, raw0 = run_chunk_with_env(".agents/skills/verify-se-fish/scripts/probe_local_mp_server.lua",
        build_server_env({}, { nonce = "n0" }))
      local parsed0 = runner.parse_server_log(raw0, "n0")
      assert.is_true(parsed0.complete)
      assert.are.equal(0, parsed0.summary.players)
      assert.are.equal(0, parsed0.summary.save_key_conflicts)

      local p1 = make_player("u1", "玩家一")
      local _, raw1 = run_chunk_with_env(".agents/skills/verify-se-fish/scripts/probe_local_mp_server.lua",
        build_server_env({ p1 }, { nonce = "n1" }))
      local parsed1 = runner.parse_server_log(raw1, "n1")
      assert.are.equal(1, parsed1.summary.players)
      assert.is_true(parsed1.summary.runtime_consistent)
    end)

    it("识别 2 人独立存档键、存档键冲突与非 Player AI 单位", function()
      local p1 = make_player("1001", "Alice")
      local p2 = make_player("1002", "Bob")
      local _, raw_ok = run_chunk_with_env(".agents/skills/verify-se-fish/scripts/probe_local_mp_server.lua",
        build_server_env({ p1, p2 }, { nonce = "ok2" }))
      local parsed_ok = runner.parse_server_log(raw_ok, "ok2")
      assert.are.equal(2, parsed_ok.summary.players)
      assert.are.equal(0, parsed_ok.summary.dup_uid)
      assert.are.equal(0, parsed_ok.summary.save_key_conflicts)
      assert.are.equal(2, #parsed_ok.players)

      local _, raw_conflict = run_chunk_with_env(".agents/skills/verify-se-fish/scripts/probe_local_mp_server.lua",
        build_server_env({ p1, p2 }, {
          nonce = "cf2",
          sessions = { ["1001"] = { Key = "fish:shared" }, ["1002"] = { Key = "fish:shared" } },
        }))
      local parsed_cf = runner.parse_server_log(raw_conflict, "cf2")
      assert.are.equal(1, parsed_cf.summary.save_key_conflicts)
      assert.are.equal(1, #parsed_cf.conflicts)

      local npc_ai = {
        IsA = function(_, t) return t == "EggyUnit" end,
        Name = "DebugAI_1",
        UnitId = "ai_99",
        Position = { x = 5, y = 1, z = 2 },
      }
      local _, raw_ai = run_chunk_with_env(".agents/skills/verify-se-fish/scripts/probe_local_mp_server.lua",
        build_server_env({ p1 }, { nonce = "ai1", extra_eggy = { npc_ai } }))
      local parsed_ai = runner.parse_server_log(raw_ai, "ai1")
      assert.are.equal(1, parsed_ai.summary.players)
      assert.are.equal(1, parsed_ai.summary.eggy_non_player)
      assert.are.equal("DebugAI_1", parsed_ai.eggy_samples[1].name)
    end)
  end)

  describe("probe_local_mp_client.lua", function()
    it("输出当前窗口 LocalPlayer 与 ClientStore 摘要并兼容空 Store", function()
      local p1 = make_player("2001", "WinA", { x = 10, y = 2, z = 3 })
      local p2 = make_player("2002", "WinB", { x = 12, y = 2, z = 3 })
      local _, raw = run_chunk_with_env(".agents/skills/verify-se-fish/scripts/probe_local_mp_client.lua", {
        nonce = "cli1",
        game = {
          GetService = function(_, name)
            if name == "Players" then
              return { LocalPlayer = p1, GetPlayers = function() return { p1, p2 } end }
            end
          end,
        },
        ClientSpoke = {
          Store = {
            connected = make_signal(true),
            zone_id = make_signal(2),
            zone_name = make_signal("浅滩"),
            coin = make_signal(500),
            position = make_signal({ x = 10, y = 2, z = 3 }),
            survival = make_signal({ phase = "alive" }),
            party = make_signal({ state = "in_party", members = { { userId = "2001", self = true } } }),
            local_character = make_signal(p1.Character),
          },
        },
      })
      local parsed = runner.parse_client_log(raw, "cli1")
      assert.is_true(parsed.complete)
      assert.are.equal("2001", parsed.client.local_uid)
      assert.are.equal(2, parsed.client.players_visible)
      assert.are.equal("2001", parsed.client.party_self_uid)

      local _, raw_nil = run_chunk_with_env(".agents/skills/verify-se-fish/scripts/probe_local_mp_client.lua", {
        nonce = "cli2",
        game = { GetService = function() return nil end },
        ClientSpoke = nil,
      })
      local parsed_nil = runner.parse_client_log(raw_nil, "cli2")
      assert.is_true(parsed_nil.complete)
      assert.is_false(parsed_nil.client.store)
      assert.is_nil(parsed_nil.client.local_uid)
    end)
  end)

  describe("probe_local_mp_run.lua 判定与解析", function()
    it("校验参数解析与非法模式拒绝", function()
      local opts, err = runner.parse_args({ "--mode", "local-mp", "--instance", "30256", "--json" })
      assert.is_nil(err)
      assert.are.equal("local-mp", opts.mode)
      assert.are.equal("30256", opts.instance)
      assert.is_true(opts.json)

      local bad, bad_err = runner.parse_args({ "--mode", "invalid" })
      assert.is_nil(bad)
      assert.is_truthy(bad_err)
    end)

    it("准确判定 --player 路由精准命中与串台回退，并解析 screenshot --list", function()
      local wins = runner.parse_screenshot_list(table.concat({
        "1 hwnd=0x001122 pid=100 rect=0,0,1280,720 proc=client title=WinA",
        "2 hwnd=0x003344 pid=200 rect=1280,0,1280,720 proc=client title=WinB",
      }, "\n"))
      assert.are.equal(2, #wins)
      assert.are.equal("0x003344", wins[2].hwnd)

      local server = {
        summary = {
          players = 2, dup_uid = 0, save_keys = 2, save_key_missing = 0,
          save_key_conflicts = 0, runtime = true, rt_current = 2, rt_trees = 2,
          runtime_consistent = true,
        },
        players = { { idx = 1, uid = "1001", name = "A" }, { idx = 2, uid = "1002", name = "B" } },
      }
      local ok_runs = {
        { target_uid = "1001", client = { local_uid = "1001" } },
        { target_uid = "1002", client = { local_uid = "1002" } },
      }
      local rep_ok = runner.evaluate("local-mp", server, ok_runs, wins)
      local map_ok = {}
      for _, c in ipairs(rep_ok.checks) do map_ok[c.id] = c.status end
      assert.are.equal("CONFIRMED", map_ok.players_multi)
      assert.are.equal("CONFIRMED", map_ok.unique_save_key)
      assert.are.equal("CONFIRMED", map_ok.client_player_routing)
      assert.are.equal("CONFIRMED", map_ok.multi_window_screenshot)

      local miss_runs = {
        { target_uid = "1001", client = { local_uid = "1001" } },
        { target_uid = "1002", client = { local_uid = "1001" } },
      }
      local rep_miss = runner.evaluate("local-mp", server, miss_runs, wins)
      local map_miss = {}
      for _, c in ipairs(rep_miss.checks) do map_miss[c.id] = c.status end
      assert.are.equal("MISMATCH", map_miss.client_player_routing)

      local md = runner.render_markdown(rep_miss)
      assert.is_truthy(md:find("client_player_routing", 1, true))
      assert.is_truthy(md:find("MISMATCH", 1, true))
    end)

    it("在 debug-ai 模式下区分 AI 进入 Players 与仅存在非 Player EggyUnit", function()
      local srv_non_player = {
        summary = { players = 1, runtime = true, rt_current = 1, runtime_consistent = true, eggy_scan = "ok", eggy_non_player = 1 },
        players = { { idx = 1, uid = "1001", name = "Host" } },
      }
      local rep = runner.evaluate("debug-ai", srv_non_player, { { client = { local_uid = "1001", store = true } } }, {})
      local map = {}
      for _, c in ipairs(rep.checks) do map[c.id] = c.status end
      assert.are.equal("MISMATCH", map.ai_in_players)
      assert.are.equal("CONFIRMED", map.client_local_player)
    end)
  end)
end)
