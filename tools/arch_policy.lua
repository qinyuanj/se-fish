-- 架构分层的唯一声明与 Lua 5.4 门禁。业务源码不依赖本模块。
-- levels 与 uml-viewer 一样按“内层优先”排列；靠前的是低层。
local lfs = require('lfs')

local M = {}

M.policy = {
  roots = { 'client', 'common', 'server' },
  -- 内层优先：官方包、配置内容、共享规则、运行端适配、应用流程、入口。
  levels = {
    { ids = { 'client.packages', 'server.packages', 'common.packages' } },
    { ids = { 'common.cfg' } },
    {
      ids = { 'server.Data' },
      modules = {
        'server.SwingRegistry', 'server.TableMgr',
        'common.AttrGrowth', 'common.AttrModel', 'common.BlindboxDraw', 'common.BodyScale',
        'common.BossPhase', 'common.CarryMount', 'common.ContentValidation', 'common.FishCatch',
        'common.FlightPath', 'common.GameCfg', 'common.GrillCurve', 'common.LotteryDraw',
        'common.LotteryEligibility', 'common.MathWaterJudge', 'common.NpcDialogue', 'common.QuestSteps',
        'common.RateLimit', 'common.Records', 'common.ReelDisplay', 'common.ReelProgress',
        'common.SpecialItem', 'common.Vitals',
      },
    },
    {
      modules = {
        'client.DamageFloat', 'client.FishCombatLabel', 'client.GameUI', 'client.InteractionBubble',
        'client.PressGesture', 'client.WeaponAim',
        'server.FishBehaviors', 'server.MgrUtil',
        'common.DamageNotice', 'common.FXUtil', 'common.GarBiteNotice', 'common.REUtil',
        'common.TeleportUtil', 'common.Util',
      },
    },
    {
      ids = { 'server.Mgr', 'server.AbilityBehaviors', 'client.ScreenHandlers' },
      modules = {
        'server.AbilityAPI', 'client.MgrGameUI',
        'client.LocalAttackButton', 'client.LocalAttr', 'client.LocalCastSource', 'client.LocalGM',
        'client.LocalGarBite', 'client.LocalInteract', 'client.LocalLoot', 'client.LocalLottery',
        'client.LocalMgrUtil', 'client.LocalMotorUnitCtrl', 'client.LocalReelIn', 'client.LocalShop',
      },
    },
    { modules = { 'client.main', 'server.main' } },
  },
  cycle_exempt = { '^client%.packages%.', '^server%.packages%.', '^common%.packages%.' },
  forbidden = {
    { name = 'common_independent', from = { '^common%.' }, to = { '^client%.', '^server%.' } },
    { name = 'client_not_server', from = { '^client%.' }, to = { '^server%.' } },
    { name = 'server_not_client', from = { '^server%.' }, to = { '^client%.' } },
  },
}

local function sorted_keys(map)
  local out = {}
  for key in pairs(map) do out[#out + 1] = key end
  table.sort(out)
  return out
end

local function classify(policy, id)
  for rank, group in ipairs(policy.levels) do
    for _, module in ipairs(group.modules or {}) do
      if id == module then return rank - 1, module end
    end
    for _, prefix in ipairs(group.ids or {}) do
      if id == prefix or id:sub(1, #prefix + 1) == prefix .. '.' then
        return rank - 1, prefix
      end
    end
  end
end

local function matches(id, patterns)
  for _, pattern in ipairs(patterns) do
    if id:match(pattern) then return true end
  end
  return false
end

local function cycles(modules, edges)
  local adjacency, index_of, low, stacked, stack = {}, {}, {}, {}, {}
  local components, counter = {}, 0
  for _, id in ipairs(modules) do adjacency[id] = {} end
  for _, edge in ipairs(edges) do
    if adjacency[edge.from] and adjacency[edge.to] then
      adjacency[edge.from][edge.to] = true
    end
  end
  local function visit(id)
    counter = counter + 1
    index_of[id], low[id] = counter, counter
    stack[#stack + 1], stacked[id] = id, true
    for _, target in ipairs(sorted_keys(adjacency[id])) do
      if not index_of[target] then
        visit(target)
        low[id] = math.min(low[id], low[target])
      elseif stacked[target] then
        low[id] = math.min(low[id], index_of[target])
      end
    end
    if low[id] == index_of[id] then
      local component = {}
      repeat
        local member = table.remove(stack)
        stacked[member] = nil
        component[#component + 1] = member
      until member == id
      if #component > 1 or adjacency[id][id] then
        table.sort(component)
        components[#components + 1] = component
      end
    end
  end
  for _, id in ipairs(modules) do if not index_of[id] then visit(id) end end
  table.sort(components, function(a, b) return a[1] < b[1] end)
  return components
end

local function projection_cycles(modules, edges)
  local views = { [''] = true }
  for _, id in ipairs(modules) do
    local prefix
    for part in id:gmatch('[^.]+') do
      prefix = prefix and prefix .. '.' .. part or part
      views[prefix] = true
    end
  end
  local result = {}
  for _, view in ipairs(sorted_keys(views)) do
    local children, nodes, node_seen = {}, {}, {}
    local prefix = view == '' and '' or view .. '.'
    for _, id in ipairs(modules) do
      if view == '' or id:sub(1, #prefix) == prefix then
        local rest = id:sub(#prefix + 1)
        local segment = rest:match('^([^.]+)')
        if segment then
          local child = prefix .. segment
          children[id] = child
          if not node_seen[child] then nodes[#nodes + 1], node_seen[child] = child, true end
        end
      end
    end
    local projected = {}
    for _, edge in ipairs(edges) do
      local from, to = children[edge.from], children[edge.to]
      if from and to and from ~= to then projected[#projected + 1] = { from = from, to = to } end
    end
    table.sort(nodes)
    for _, component in ipairs(cycles(nodes, projected)) do
      result[#result + 1] = { view = view, component = component }
    end
  end
  return result
end

function M.check(policy, graph)
  local known = {}
  for _, id in ipairs(graph.modules) do known[id] = true end
  local violations = {}
  local function add(item) violations[#violations + 1] = item end
  for _, id in ipairs(graph.modules) do
    if not classify(policy, id) then add({ kind = 'unclassified_module', module = id }) end
  end
  local edges = {}
  for _, edge in ipairs(graph.edges) do
    if known[edge.from] and known[edge.to] then
      edges[#edges + 1] = edge
      local from_rank, from_prefix = classify(policy, edge.from)
      local to_rank, to_prefix = classify(policy, edge.to)
      if from_rank and to_rank and from_rank < to_rank then
        add({ kind = 'layer_violation', from = edge.from, to = edge.to,
          from_prefix = from_prefix, to_prefix = to_prefix })
      end
      for _, rule in ipairs(policy.forbidden or {}) do
        if matches(edge.from, rule.from) and matches(edge.to, rule.to) then
          add({ kind = 'forbidden_dependency', rule = rule.name, from = edge.from, to = edge.to })
        end
      end
    end
  end
  local seen_cycles = {}
  local function add_cycle(component, view)
    local signature = table.concat(component, ',')
    if seen_cycles[signature] then return end
    seen_cycles[signature] = true
    local exempt = #component > 0
    for _, id in ipairs(component) do
      if not matches(id, policy.cycle_exempt or {}) then exempt = false end
    end
    if not exempt then add({ kind = 'dependency_cycle', cycle = component, view = view }) end
  end
  for _, component in ipairs(cycles(graph.modules, edges)) do add_cycle(component) end
  for _, item in ipairs(projection_cycles(graph.modules, edges)) do
    add_cycle(item.component, item.view)
  end
  table.sort(violations, function(a, b)
    local left, right = a.from or a.module or a.cycle[1], b.from or b.module or b.cycle[1]
    if left ~= right then return left < right end
    return a.kind < b.kind
  end)
  local messages = {}
  for _, item in ipairs(violations) do
    if item.kind == 'dependency_cycle' then
      messages[#messages + 1] = item.kind .. ': ' .. table.concat(item.cycle, ' -> ')
    elseif item.kind == 'unclassified_module' then
      messages[#messages + 1] = item.kind .. ': ' .. item.module
    else
      messages[#messages + 1] = item.kind .. ': ' .. item.from .. ' -> ' .. item.to
    end
  end
  return { ok = #violations == 0, violations = violations,
    message = table.concat(messages, '\n') }
end

local function blank(text)
  return (text:gsub('[^\r\n]', ' '))
end

local function mask(source)
  local out, holes, index = {}, {}, 1
  while index <= #source do
    local char, next_char = source:sub(index, index), source:sub(index + 1, index + 1)
    local long = source:match('^%[(=*)%[', index)
    if char == '-' and next_char == '-' then
      local eqs = source:match('^%[(=*)%[', index + 2)
      local stop
      if eqs then
        local closer = ']' .. eqs .. ']'
        local found = source:find(closer, index + 4 + #eqs, true)
        stop = found and found + #closer - 1 or #source
      else
        local newline = source:find('\n', index, true)
        stop = newline and newline - 1 or #source
      end
      out[#out + 1] = blank(source:sub(index, stop))
      index = stop + 1
    elseif long then
      local closer = ']' .. long .. ']'
      local found = source:find(closer, index + 2 + #long, true)
      local stop = found and found + #closer - 1 or #source
      out[#out + 1] = source:sub(index, stop)
      holes[#holes + 1] = { index + 2 + #long, stop - #closer }
      index = stop + 1
    elseif char == '"' or char == "'" then
      local cursor = index + 1
      while cursor <= #source do
        local current = source:sub(cursor, cursor)
        if current == '\\' then cursor = cursor + 2
        elseif current == char then break
        else cursor = cursor + 1 end
      end
      local stop = math.min(cursor, #source)
      out[#out + 1] = source:sub(index, stop)
      holes[#holes + 1] = { index + 1, stop - 1 }
      index = stop + 1
    else
      out[#out + 1] = char
      index = index + 1
    end
  end
  return table.concat(out), holes
end

local function in_hole(holes, position)
  for _, hole in ipairs(holes) do
    if position >= hole[1] and position <= hole[2] then return true end
  end
  return false
end

function M.requires(source)
  local text, holes = mask(source)
  local names, seen, from = {}, {}, 1
  while true do
    local first, last = text:find('require', from, true)
    if not first then break end
    from = last + 1
    local before = first > 1 and text:sub(first - 1, first - 1) or ''
    local previous_token = text:sub(1, first - 1):match('([%.:]+)%s*$')
    local after = text:sub(last + 1, last + 1)
    local cursor = last + 1
    while text:sub(cursor, cursor):match('%s') do cursor = cursor + 1 end
    if text:sub(cursor, cursor) == '(' then
      cursor = cursor + 1
      while text:sub(cursor, cursor):match('%s') do cursor = cursor + 1 end
    end
    local quote = text:sub(cursor, cursor)
    local value
    if quote == '"' or quote == "'" then
      local stop = cursor + 1
      while stop <= #text do
        local char = text:sub(stop, stop)
        if char == '\\' then stop = stop + 2
        elseif char == quote then break
        else stop = stop + 1 end
      end
      -- 只把完整字符串字面量交给 Lua 解码，空环境且不拼接其他源码。
      local literal = text:sub(cursor, stop)
      local decode = load('return ' .. literal, '静态 require 字符串', 't', {})
      if decode then value = decode() end
    else
      local eqs = text:match('^%[(=*)%[', cursor)
      if eqs then
        local start = cursor + 2 + #eqs
        local stop = text:find(']' .. eqs .. ']', start, true)
        if stop then value = text:sub(start, stop - 1):gsub('^\r?\n', '') end
      end
    end
    local name = value and value:match('^[A-Za-z_][%w_.]*$')
    if name and not seen[name] and not in_hole(holes, first)
      and previous_token ~= '.' and previous_token ~= ':'
      and not before:match('[%w_]') and not after:match('[%w_]') then
      names[#names + 1], seen[name] = name, true
    end
  end
  table.sort(names)
  return names
end

local function collect(root, relative, files)
  local directory = root .. '/' .. relative
  for entry in lfs.dir(directory) do
    if entry ~= '.' and entry ~= '..' then
      local path = relative .. '/' .. entry
      local attr = lfs.attributes(root .. '/' .. path)
      if attr.mode == 'directory' then
        if entry ~= '_trigger' then collect(root, path, files) end
      elseif attr.mode == 'file' and entry:sub(-4) == '.lua' then
        files[#files + 1] = path
      end
    end
  end
end

function M.scan(root, policy)
  local files = {}
  for _, source_root in ipairs(policy.roots) do collect(root, source_root, files) end
  table.sort(files)
  local known, requires_by_module = {}, {}
  for _, path in ipairs(files) do
    local id = path:sub(1, -5):gsub('/', '.')
    known[id] = true
    local handle, err = io.open(root .. '/' .. path, 'rb')
    if not handle then return nil, err end
    local source = handle:read('*a')
    handle:close()
    requires_by_module[id] = M.requires(source)
  end
  local modules, edges = sorted_keys(known), {}
  for _, from in ipairs(modules) do
    for _, to in ipairs(requires_by_module[from]) do
      if known[to] then edges[#edges + 1] = { from = from, to = to } end
    end
  end
  return { modules = modules, edges = edges }
end

function M.levels_edn(policy)
  local groups = {}
  for _, group in ipairs(policy.levels) do
    local ids = {}
    for _, id in ipairs(group.ids or {}) do ids[#ids + 1] = id end
    for _, id in ipairs(group.modules or {}) do ids[#ids + 1] = id end
    groups[#groups + 1] = '[:' .. table.concat(ids, ' :') .. ']'
  end
  return ':levels [' .. table.concat(groups, ' ') .. ']'
end

return M
