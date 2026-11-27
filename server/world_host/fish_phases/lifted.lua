local GameCfg = require('common.game_cfg')

local LiftedPhase = {}
local LiftedBehavior = {}

function LiftedBehavior.request_lift(self, fish)
    local env = self.lifted_env
    local cfg = env.cfg
    local owner = fish.Owner
    if fish.State ~= self.State.await_lift or self.held[owner.UserId]
        or fish.LiftAttempts >= cfg().LiftAttempts then return false end
    local controller = owner.Character and owner.Character.Controller
    if not controller then return false end
    fish.LiftAttempts = fish.LiftAttempts + 1
    fish.lift_at = self:now()
    -- SE 实测 Lift 的指定目标支持 WorldUnit；仍由原生 OnLiftedBegin 确认成功。
    local ok, err = pcall(function() controller:Lift(fish.carrier.body) end)
    if not ok then print('[FishTree] Lift 调用失败', owner.UserId, tostring(err)) end
    return ok
end

function LiftedBehavior.resolve_lifter(self, fish, liftunit)
    if liftunit == nil then return fish.lift_at and fish.Owner or nil end
    if fish.Owner.Character == liftunit then return fish.Owner end
    for _, player in ipairs(self:players()) do
        if player.Character == liftunit then return player end
    end
end

function LiftedBehavior.on_lifted(self, fish, liftunit)
    local env = self.lifted_env
    local cfg, createUnit = env.cfg, env.createUnit
    if self.Fish[fish.Id] ~= fish or fish.State ~= self.State.await_lift then return end
    local holder = self:resolve_lifter(fish, liftunit)
    local character = holder and holder.Character
    if not character or self.held[holder.UserId] then
        print('[FishTree] 抓举回调找不到空手的抓举者', fish.Id)
        return
    end
    local offset = cfg().LiftSocketOffset
    local ok, mount = pcall(createUnit, self, 'SkeletalSocketMount', {
        Name = 'FishMount_' .. tostring(fish.Id),
        Parent = character,
        SocketName = cfg().LiftSocket,
        SocketOffset = Vector3.New(offset.x, offset.y, offset.z),
    })
    if not ok or not mount then
        print('[FishTree] 顶鱼挂点创建失败', fish.Id, tostring(mount))
        return
    end
    fish.mount = mount
    fish.holder = holder
    self:set_state(fish, self.State.held)
    fish.holder_tree = self.get_player_tree and self:get_player_tree(holder) or nil
    if fish.holder_tree_state then fish.holder_tree_state:set(fish.holder_tree) end
    self.held[holder.UserId] = fish
    pcall(function() fish.carrier.body.Parent = mount end)
    print('[FishTree] 举起', holder.UserId, fish.fish_id, fish.mult, 'fish=' .. tostring(fish.Id))
    if self.cast then self.cast:PushState(holder) end
end

function LiftedBehavior.get_held(self, player)
    return player and self.held[player.UserId] or nil
end

function LiftedBehavior.held_info(self, player)
    local fish = self:get_held(player)
    return fish and { fishId = fish.fish_id, mult = fish.mult } or nil
end

function LiftedBehavior.can_cast(self, player)
    return self:get_held(player) == nil
end

function LiftedBehavior.drop(self, player)
    local fish = self:get_held(player)
    return fish ~= nil and self:release(fish, 'drop')
end

function LiftedBehavior.stabilize(self, fish)
    local env = self.lifted_env
    local readPosition, cfg = env.readPosition, env.cfg
    local body = fish.carrier.body
    local anchor = fish.Anchor
    if not body or not anchor then return end
    local pos = readPosition(body)
    local tol = cfg().AwaitDriftTolerance
    if pos and math.abs(pos.x - anchor.x) <= tol and math.abs(pos.y - anchor.y) <= tol
        and math.abs(pos.z - anchor.z) <= tol then return end
    pcall(function()
        body.Position = anchor
        body.LinearVelocity = Vector3.New(0, 0, 0)
        body.AngularVelocity = Vector3.New(0, 0, 0)
    end)
end

--- 把行为表挂到管理器上；方法名与签名沿用拆分前的 Mgr 方法，依赖从 mgr.lifted_env 读取。
function LiftedPhase.install(Mgr, context)
    for _, key in ipairs({ 'readPosition', 'cfg', 'createUnit' }) do
        assert(type(context[key]) == 'function', 'LiftedPhase.install: context.' .. key .. ' 必须是函数')
    end
    Mgr.lifted_env = context
    for name, method in pairs(LiftedBehavior) do
        Mgr[name] = method
    end
end

function LiftedPhase.update(host, fish, now)
    if fish.State ~= host.State.await_lift then return end
    host:stabilize(fish)
    if fish.lift_at and now - fish.lift_at >= GameCfg.FishUnit.LiftConfirmSec then
        if not host:request_lift(fish) and fish.LiftAttempts >= GameCfg.FishUnit.LiftAttempts and not fish.lift_gave_up then
            fish.lift_gave_up = true
            print('[FishTree] 抓举未确认，放弃重试', fish.Owner.UserId, 'fish=' .. tostring(fish.Id))
        end
    end
end

function LiftedPhase.mount(host, fish, ps)
    ps:effect('HolderAlive', function(es)
        local holder_tree = es:d(fish.holder_tree_state)
        fish.holder_tree = holder_tree
        if not holder_tree then return end
        if fish.State ~= host.State.held and fish.State ~= host.State.await_lift then return end
        local alive = holder_tree.memos and holder_tree.memos.is_alive
        local session = holder_tree.session_alive
        if not alive or not session then return end
        if not es:d(alive) or not es:d(session) then
            local reason = session:now() == false and 'leave' or 'life'
            if fish.State == host.State.held then
                host:release(fish, reason)
            elseif fish.State == host.State.await_lift then
                host:release_await_lift(fish, reason)
            end
        end
    end)
    ps:subscribe(host:frame_clock().on_frame, function(frame)
        local now = host:begin_phase_frame(fish, frame and frame.now)
        if now then LiftedPhase.update(host, fish, now) end
    end)
    ps:on_cleanup(function()
        if fish.mount then pcall(function() fish.mount:Destroy() end) end
        fish.mount = nil
    end)
end

return LiftedPhase
