-- 小队 HUD 与队友抢救气泡（ADR-0032 / #314）。
-- HUD/邀请/队友行/场景节点全部由 RootView 作用域托管；成员行与气泡使用 Dock 键控复用。
-- 抢救只复用 #298 的 InteractAction / GameCfg.Rescue，不创建新的生命状态或倒计时。

local GameCfg = require("common.GameCfg")
local spoke = require("common.packages.spoke.api")

local State = spoke.State
local SquadView = {}

local NOTICE_TEXT = {
  disbanded = "DisbandText", left = "LeftText", restored = "RestoredText",
  full = "RestoreFullText", joined = "", ["save-failed"] = "UnavailableText",
}
local REASON_TEXT = {
  ["too-far"] = "TooFarText", full = "FullText", offline = "OfflineText",
  ["target-in-party"] = "TargetInPartyText", ["no-invite"] = "NoInviteText",
  expired = "NoInviteText", ["save-failed"] = "UnavailableText",
  ["already-in-party"] = "UnavailableText", invalid = "UnavailableText",
}

local function vec(x, y)
  if _G.Vector2 and type(_G.Vector2.New) == "function" then return _G.Vector2.New(x, y) end
  return { x = x, y = y }
end

local function resolution()
  local ok, value = pcall(function()
    local game_ui = rawget(_G, "GameUI")
    local eui = game_ui and game_ui:GetEuiManager() or nil
    return eui and eui:GetDeviceResolution() or nil
  end)
  if ok and value and type(value.x) == "number" and type(value.y) == "number" then return value end
  return { x = 1920, y = 1080 }
end

local function notify(ctx, text)
  if text == nil or text == "" then return end
  local callback = ctx.services and ctx.services.notify
  if type(callback) ~= "function" then callback = rawget(_G, "LocalMsgNotice") end
  if type(callback) == "function" then callback(text) end
end

local function notice_from_event(ctx, event)
  if type(event) ~= "table" then return end
  local payload = event.payload
  if event.channel == "PartyResult" and type(payload) == "table" then
    if payload.ok then return end
    local field = REASON_TEXT[payload.reason]
    if field then notify(ctx, GameCfg.Party.HUD[field]) end
  elseif event.channel == "PartyState" and type(payload) == "table" then
    local field = NOTICE_TEXT[payload.notice]
    if field then notify(ctx, GameCfg.Party.HUD[field] or "") end
  end
end

function SquadView.hud_spec()
  return {
    name = "SquadHud",
    mount = function(scope, ctx)
      local hud = GameCfg.Party.HUD
      local screen = resolution()
      local panel = ctx.create_node(scope, "EUILayout", {
        Name = "PartyHud", Visible = false,
        Position = vec(screen.x - hud.RowWidth - hud.MarginRight, hud.MarginTop),
        Size = vec(hud.RowWidth, hud.RowHeight * hud.MaxRows),
      })
      panel.TouchEnabled = false

      local invite = ctx.create_node(scope, "EUILayout", {
        Name = "PartyInvite", Visible = false,
        Position = vec((screen.x - hud.InviteWidth) / 2, hud.InviteTop),
        Size = vec(hud.InviteWidth, hud.InviteHeight),
      })
      local text = ctx.create_node(scope, "EUITextLabel", {
        Name = "PartyInviteText", Parent = invite, Text = "",
        Position = vec(12, 8), Size = vec(hud.InviteWidth - 24, 28),
      })
      local countdown = ctx.create_node(scope, "EUITextLabel", {
        Name = "PartyInviteCountdown", Parent = invite, Text = "",
        Position = vec(12, 38), Size = vec(hud.InviteWidth - 24, 22),
      })
      local accept = ctx.create_node(scope, "EUIButton", {
        Name = "PartyInviteAccept", Parent = invite, ButtonText = hud.AcceptText,
        Position = vec(48, 66), Size = vec(110, 24), TouchEnabled = false,
      })
      local decline = ctx.create_node(scope, "EUIButton", {
        Name = "PartyInviteDecline", Parent = invite, ButtonText = hud.DeclineText,
        Position = vec(hud.InviteWidth - 158, 66), Size = vec(110, 24), TouchEnabled = false,
      })
      text.TouchEnabled, countdown.TouchEnabled = false, false

      local send = ctx.services and ctx.services.send_party
      ctx.connect(scope, accept.OnClicked, function()
        if type(send) == "function" then send({ action = "Accept" }) end
      end)
      ctx.connect(scope, decline.OnClicked, function()
        if type(send) == "function" then send({ action = "Decline" }) end
      end)
      scope:subscribe(ctx.store.on_server_event, function(event) notice_from_event(ctx, event) end)

      local invite_identity, fallback_expires_at = nil, nil
      scope:effect("PartyHudProjection", function(es)
        local party = es:d(ctx.store.party)
        es:d(ctx.clock.second)
        panel.Visible = party.state == "party"

        local invitation = party.invite
        if invitation then
          local identity = tostring(invitation.fromUserId) .. ":" .. tostring(invitation.expiresAt or "local")
          if identity ~= invite_identity then
            invite_identity = identity
            fallback_expires_at = invitation.expiresAt or (ctx.clock.now() + invitation.expiresInSec)
          end
          local left = math.max(0, math.ceil(fallback_expires_at - ctx.clock.now()))
          invite.Visible = left > 0
          accept.Disabled = not invite.Visible
          decline.Disabled = not invite.Visible
          accept.TouchEnabled = invite.Visible
          decline.TouchEnabled = invite.Visible
          text.Text = tostring(invitation.fromName or invitation.fromUserId) .. hud.InviteText
          countdown.Text = tostring(left) .. hud.InviteCountdownText
        else
          invite_identity, fallback_expires_at = nil, nil
          invite.Visible = false
          accept.Disabled, decline.Disabled = true, true
          accept.TouchEnabled, decline.TouchEnabled = false, false
          text.Text, countdown.Text = "", ""
        end
      end)
    end,
  }
end

function SquadView.member_spec()
  return {
    items = function(es, store)
      local party = es:d(store.party)
      if party.state ~= "party" then return {} end
      local rows = {}
      for _, row in ipairs(party.members) do
        if not row.self and #rows < GameCfg.Party.HUD.MaxRows then
          rows[#rows + 1] = {
            userId = row.userId, name = row.name, health = row.health, maxHealth = row.maxHealth,
            phase = row.phase, index = #rows + 1,
          }
        end
      end
      return rows
    end,
    key_of = function(row) return tostring(row.userId) end,
    mount = function(scope, ctx, item_signal)
      local hud = GameCfg.Party.HUD
      local panel = ctx.root_node:FindFirstChild("PartyHud", true) or ctx.root_node
      local row = ctx.create_node(scope, "EUILayout", {
        Name = "PartyMember" .. tostring(item_signal:now().userId), Parent = panel,
        Size = vec(hud.RowWidth, hud.RowHeight),
      })
      local name = ctx.create_node(scope, "EUITextLabel", {
        Name = "PartyMemberName" .. tostring(item_signal:now().userId), Parent = row,
        Position = vec(8, 6), Size = vec(hud.RowWidth - 90, 22), Text = "",
      })
      local health_text = ctx.create_node(scope, "EUITextLabel", {
        Name = "PartyHealthText" .. tostring(item_signal:now().userId), Parent = row,
        Position = vec(hud.RowWidth - 74, 6), Size = vec(68, 22), Text = "",
      })
      ctx.create_node(scope, "EUIFrame", {
        Name = "PartyHealthBar" .. tostring(item_signal:now().userId), Parent = row,
        Position = vec(8, 34), Size = vec(hud.BarWidth, hud.BarHeight),
        Image = hud.ColorBlockImage,
      })
      local fill = ctx.create_node(scope, "EUIFrame", {
        Name = "PartyHealthFill" .. tostring(item_signal:now().userId), Parent = row,
        Position = vec(8, 34), Size = vec(0, hud.BarHeight), Image = hud.ColorBlockImage,
      })
      row.TouchEnabled, name.TouchEnabled, health_text.TouchEnabled = false, false, false
      scope:effect("PartyMemberProjection", function(es)
        local value = es:d(item_signal)
        local health = value.health or 0
        local maximum = value.maxHealth or 0
        row.Position = vec(0, (value.index - 1) * hud.RowHeight)
        row.Visible = true
        name.Text = value.name
        health_text.Text = tostring(health) .. " / " .. tostring(maximum)
        local ratio = maximum > 0 and math.max(0, math.min(1, health / maximum)) or 0
        fill.Size = vec(hud.BarWidth * ratio, hud.BarHeight)
      end)
    end,
  }
end

function SquadView.rescue_state(options)
  options = options or {}
  return {
    rows = State.new("SquadView.rescue_rows", {}),
    get_players = options.get_players,
    get_local_player = options.get_local_player,
  }
end

function SquadView.rescue_driver_spec(shared)
  return {
    name = "SquadRescueDriver",
    mount = function(scope, ctx)
      local function refresh()
        local list = {}
        local party = ctx.store.party:now()
        local me = type(shared.get_local_player) == "function" and shared.get_local_player() or nil
        local position = ctx.store.position:now()
        local players = type(shared.get_players) == "function" and shared.get_players() or {}
        local by_id = {}
        for _, player in ipairs(players) do
          if type(player) == "table" and player.UserId ~= nil then by_id[player.UserId] = player end
        end
        if party.state == "party" and position then
          for _, row in ipairs(party.members) do
            local target = by_id[row.userId]
            local target_position = target and target.Character and target.Character.Position
            if target ~= me and not row.self and (row.phase == "downed" or row.phase == "rescuing") and target_position then
              local dx, dz = position.x - target_position.x, position.z - target_position.z
              if dx * dx + dz * dz <= GameCfg.Rescue.Range * GameCfg.Rescue.Range then
                list[#list + 1] = { userId = row.userId, position = target_position }
              end
            end
          end
        end
        shared.rows:set(list)
      end
      scope:subscribe(ctx.clock.on_frame, refresh)
      scope:subscribe(ctx.store.party, refresh)
      refresh()
    end,
  }
end

function SquadView.rescue_bubble_spec(shared)
  return {
    items = function(es) return es:d(shared.rows) end,
    key_of = function(row) return tostring(row.userId) end,
    mount = function(scope, ctx, item_signal)
      local row = item_signal:now()
      local create_scene = ctx.services and ctx.services.create_scene_node
      local node
      if type(create_scene) == "function" then
        node = ctx.own_node(scope, create_scene(row, GameCfg.Rescue.BubbleHeight, "squad_rescue"))
      else
        node = ctx.create_node(scope, "EUIImage", { Name = "SceneNodeSquadRescue_" .. tostring(row.userId) })
      end
      local ok, button = pcall(ctx.create_node, scope, "EUIButton", {
        Name = "BtnSquadRescue" .. tostring(row.userId), Parent = node,
        ButtonText = GameCfg.Rescue.PromptText, TouchEnabled = true,
      })
      if not ok then
        if node and type(node.Destroy) == "function" then node:Destroy() end
        print("[SquadView] 队友抢救按钮创建失败", tostring(button))
        return
      end
      ctx.connect(scope, button.OnClicked, function()
        local next_seq = ctx.services and ctx.services.next_seq
        local send = ctx.services and ctx.services.send_interact
        if type(send) == "function" then
          send({ target = GameCfg.Rescue.Target, action = GameCfg.Rescue.Action,
            targetUserId = item_signal:now().userId,
            seq = type(next_seq) == "function" and next_seq() or 1 })
        end
      end)
    end,
  }
end

return SquadView
