-- spoke_eggy -- the SE (世界编辑器) host layer for spoke.
--
-- Where this package sits: the boundary ruling (#22) put the host layer outside
-- the core package, following the only upstream precedent, Spoke.Unity and its
-- SpokeBehaviour. Same division of labour as upstream -- the host layer owns a
-- tree's lifetime, never the frame pump. RunService.Heartbeat stays with the
-- consumer (docs/integration-best-practices.md).
--
-- Dependency direction: the two requires below are the whole dependency list, and
-- both stay inside common.packages.spoke. The core never requires this package and
-- this package is not one of api.lua's 13 public classes;
-- tests/package_boundary_spec.lua holds both directions. Loading this file reads no
-- host global -- the Unit is injected by the caller -- so the default busted lane
-- drives it with a fake unit (tests/host/spoke_eggy_spec.lua).
--
-- is_alive covers explicit destruction, including the cascade, and nothing else:
-- turning a round off fires no Destroying at all on SE, so no author callback runs
-- and nothing is left to flip it (#28, docs/research/se-teardown-probe-evidence.md
-- on branch wayfinder/28-teardown-probe). A disbanded round is not a dispose.

local spoke = require("common.packages.spoke.api")
local SpokeError = require("common.packages.spoke.runtime.spoke_error")

local spoke_eggy = {}

local Behaviour = {}
Behaviour.__index = Behaviour

local DEFAULT_NAME = "SpokeBehaviour"
local TREE_SUFFIX = ":SpokeTree"

-- Unit.Name is a Meta read-only String property
-- (/manual/se/game_api/unit/Unit.html section properties), but a client Unit may
-- report an empty string (#28), so a name is only a name when it is a non-empty
-- string. The probe also stands in for a host that throws on the read.
local function unit_name(unit)
  if unit == nil then
    return nil
  end
  local ok, name = pcall(function()
    return unit.Name
  end)
  if ok and type(name) == "string" and name ~= "" then
    return name
  end
  return nil
end

-- Unit.Destroying is documented by its Connect protocol, not by its Lua type.
-- Read both properties under pcall: host proxies may reject either access.
local function destroying_signal(unit)
  if unit == nil then
    return nil
  end
  local ok, signal, connect = pcall(function()
    local candidate = unit.Destroying
    if candidate == nil then
      return nil
    end
    return candidate, candidate.Connect
  end)
  if ok and type(connect) == "function" then
    return signal
  end
  return nil
end

-- Upstream UnityContext exists to pin a console message to a MonoBehaviour, to
-- flatten Unity stack noise, and to be the tree's logger. SE has the last one
-- only, so this is not a new type: it is the logger service the core already
-- accepts (spoke_tree.lua bootstrap takes `logger`, _log_error uses it).
--
-- Injecting it moves tree faults off SpokeError.log, the documented takeover
-- point (ADR 0002), so the default implementation forwards straight back to it.
-- That forwarding is the one deep require in this package.
local function prefixed_logger(tree_name)
  local prefix = "[" .. tree_name .. "] "
  local logger = {}
  function logger:log(message)
    SpokeError.log(prefix .. tostring(message))
  end
  function logger:error(message)
    SpokeError.log(prefix .. tostring(message))
  end
  return logger
end

-- spoke_eggy.behaviour(unit, init [, options]) -> Behaviour
--
-- The Lua stand-in for upstream "class ScorePanel : SpokeBehaviour": you write
-- only Init, and the package does the rest.
--
--   local b = spoke_eggy.behaviour(unit, function(s, self)
--     local roster = s:dock("roster")
--     s:effect(function()
--       if self.is_alive:now() then ... end
--     end)
--   end, { name = "ScorePanel" })
--
-- What it does, in this order, before returning:
--   1. builds the Behaviour with root = nil and is_alive = true;
--   2. spawns an Auto SpokeTree named (options.name or unit.Name or
--      "SpokeBehaviour") .. ":SpokeTree" -- upstream's
--      $"{GetType().Name}:SpokeTree", with the object's own name standing in for
--      the type name Lua tables do not carry;
--   3. the tree's root epoch is spoke.Effect.new("Init", init), so init receives
--      the EffectBuilder exactly like upstream Init(EffectBuilder); whatever init
--      returns is dropped, because upstream Init returns void and an Effect would
--      otherwise mirror a returned signal;
--   4. init receives the Behaviour as a second argument. That is the stand-in for
--      upstream's "this": Lua has no inherited members, so the lifecycle signal
--      has to be handed in rather than read off a base class. Inside init,
--      self.root is still nil, matching upstream, where root has not been
--      assigned until Spawn returns;
--   5. services are exported before init runs -- the default logger plus
--      options.services -- so s:try_import("logger") works and tree faults carry
--      the tree name;
--   6. connects unit.Destroying (see the ordering note on Behaviour below).
-- Auto means an Auto tree: everything init mounted is flushed before behaviour()
-- returns (spec 3.6), so the caller may use its ports immediately.
--
-- options (optional table):
--   name     tree name in logs and SpokeIntrospect; default unit.Name, then
--            "SpokeBehaviour" when the Unit has no name
--   services extra services exported before init runs; default {}
--   logger   replaces the default prefixed logger; put a logger here, not in
--            services, so there is one rule instead of two
--
-- Not offered, on purpose:
--   * a Manual tree. Driving one needs a pump the package must not own (#22).
--     SpokeTree.spawn_manual plus one unit.Destroying connection is the three
--     lines you would have written anyway.
--   * a global teardown bus (branch 3 of #25). A bus needs someone to fire it,
--     and a disbanded round fires nothing at all (#28), so the only remaining
--     caller is the one already holding the handle it would dispose.
--   * a headless form. A behaviour without a Unit is just SpokeTree.spawn.
function spoke_eggy.behaviour(unit, init, options)
  if type(init) ~= "function" then
    error("spoke_eggy.behaviour expects an init function", 2)
  end

  -- Validate the Unit before a tree exists: failing after spawn would leak one.
  local signal = destroying_signal(unit)
  if signal == nil then
    error("spoke_eggy.behaviour expects a Unit with a Destroying signal", 2)
  end

  options = options or {}
  local name = options.name
  if name == nil or name == "" then
    name = unit_name(unit)
  end
  if name == nil then
    name = DEFAULT_NAME
  end
  local tree_name = name .. TREE_SUFFIX

  local self = setmetatable({
    root = nil,
    unit = unit,
    is_alive = spoke.State.new(true),
    _connection = nil,
    _disposed = false,
    _pending_dispose = false,
  }, Behaviour)

  local services = {}
  if type(options.services) == "table" then
    for key, value in pairs(options.services) do
      services[key] = value
    end
  end
  services.logger = options.logger or prefixed_logger(tree_name)

  local tree = spoke.SpokeTree.spawn(tree_name, spoke.Effect.new("Init", function(s)
    init(s, self)
  end), services)
  self.root = tree

  -- dispose asked for inside init: the tree existed by then, but the handle had
  -- no root to detach yet. Run it now that the tree is attached, and never
  -- connect Destroying for a behaviour that is already dead.
  if self._pending_dispose then
    self._pending_dispose = false
    self:dispose()
    return self
  end

  -- Everything the callback needs is captured here, at connect time. #28 recorded
  -- that inside a real Destroying callback Parent is already nil while Name is
  -- still readable, so a handler that went back to the Unit for its tree would
  -- read a tree in an unknown state. It gets the handle instead: a closure, not
  -- the host's object graph.
  local behaviour = self
  self._connection = signal:Connect(function()
    behaviour:dispose()
  end)

  return self
end

-- The value behaviour() returns. One per call, independent of any other call on
-- the same Unit: no registry and no singleton, because a hidden global would be
-- the first thing this package owns that the consumer cannot see.
--
--   b.root      SpokeTree       the Auto tree; read b.root.fault, or dispose
--                               through the handle. nil inside init. Stays
--                               readable after dispose (detached, is_detached).
--   b.unit      Unit            the host object this behaviour is bound to
--   b.is_alive  State<boolean>  upstream IsAwake, renamed: a Unit has no Awake,
--                               and nothing on SE "wakes". Turns false when the
--                               behaviour is disposed, by the host or by hand,
--                               and never on a disbanded round (#28).
--   b:dispose()                 idempotent; detaches the tree and drops the
--                               Destroying connection
--
-- Ordering at unit.Destroying (branch 2 of #25), the part that is not obvious:
--   1. is_alive:set(false)  an Auto flush here, so an effect inside the dying
--                           tree that watches is_alive gets one last run while
--                           it is still mounted;
--   2. root:dispose()       detach in reverse order, as usual;
--   3. disconnect Destroying.
-- Upstream does it the other way round -- root.Dispose(), then
-- isAwake.Set(false) -- because nothing inside a destroyed MonoBehaviour can
-- observe the flip. In SE the flip is the only "you are being torn down" hook
-- the tree itself can see, so it goes first. Cost: an effect that mounts new
-- children while is_alive is false has them detached right afterwards.
--
-- A fault during init does not raise at the host: the tree bootstrap records it,
-- logs it, and leaves the tree faulted (spec 3.6). behaviour() still returns a
-- handle; check b.root.fault. Disposing from inside init is deferred to the end
-- of the active frame, per spec 3.6 -- here, until the tree is attached.
function Behaviour.dispose(self)
  if self._disposed then
    return
  end
  local tree = self.root
  if tree == nil then
    -- Called from inside init: there is no tree to detach yet.
    self._pending_dispose = true
    return
  end
  self._disposed = true
  self.is_alive:set(false)
  tree:dispose()
  local connection = self._connection
  self._connection = nil
  if connection ~= nil and type(connection.Disconnect) == "function" then
    connection:Disconnect()
  end
end

return spoke_eggy
