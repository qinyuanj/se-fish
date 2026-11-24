
local game_cfg = require("common.game_cfg")
local view_util = require("client.views.view_util")
local rescue_view = require("client.views.rescue_view")

local squad_view = {}

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

local function notice_from_event(ctx, event)
  if type(event) ~= "table" then return end
  local payload = event.payload
  if event.channel == "PartyResult" and type(payload) == "table" then
    if payload.ok then return end
    local field = REASON_TEXT[payload.reason]
    if field then view_util.notify(ctx, game_cfg.Party.HUD[field]) end
  elseif event.channel == "PartyState" and type(payload) == "table" then
    local field = NOTICE_TEXT[payload.notice]
    if field then view_util.notify(ctx, game_cfg.Party.HUD[field] or "") end
  end
end

function squad_view.hud_spec()
  return {
    name = "SquadHud",
    mount = function(scope, ctx)
      local hud = game_cfg.Party.HUD
      local screen = view_util.get_resolution(ctx)
      local panel = ctx.create_node(scope, "EUILayout", {
        Name = "PartyHud", Visible = false,
        Position = view_util.vec2(screen.x - hud.RowWidth - hud.MarginRight, hud.MarginTop),
        Size = view_util.vec2(hud.RowWidth, hud.RowHeight * hud.MaxRows),
      })
      panel.TouchEnabled = false

      local invite = ctx.create_node(scope, "EUILayout", {
        Name = "PartyInvite", Visible = false,
        Position = view_util.vec2((screen.x - hud.InviteWidth) / 2, hud.InviteTop),
        Size = view_util.vec2(hud.InviteWidth, hud.InviteHeight),
      })
      local text = ctx.create_node(scope, "EUITextLabel", {
        Name = "PartyInviteText", Parent = invite, Text = "",
        Position = view_util.vec2(12, 8), Size = view_util.vec2(hud.InviteWidth - 24, 28),
      })
      local countdown = ctx.create_node(scope, "EUITextLabel", {
        Name = "PartyInviteCountdown", Parent = invite, Text = "",
        Position = view_util.vec2(12, 38), Size = view_util.vec2(hud.InviteWidth - 24, 22),
      })
      local accept = ctx.create_node(scope, "EUIButton", {
        Name = "PartyInviteAccept", Parent = invite, ButtonText = hud.AcceptText,
        Position = view_util.vec2(48, 66), Size = view_util.vec2(110, 24), TouchEnabled = false,
      })
      local decline = ctx.create_node(scope, "EUIButton", {
        Name = "PartyInviteDecline", Parent = invite, ButtonText = hud.DeclineText,
        Position = view_util.vec2(hud.InviteWidth - 158, 66), Size = view_util.vec2(110, 24), TouchEnabled = false,
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

function squad_view.member_spec()
  return {
    items = function(es, store)
      local party = es:d(store.party)
      if party.state ~= "party" then return {} end
      local rows = {}
      for _, row in ipairs(party.members) do
        if not row.self and #rows < game_cfg.Party.HUD.MaxRows then
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
      local hud = game_cfg.Party.HUD
      local panel = ctx.root_node:FindFirstChild("PartyHud", true) or ctx.root_node
      local row = ctx.create_node(scope, "EUILayout", {
        Name = "PartyMember" .. tostring(item_signal:now().userId), Parent = panel,
        Size = view_util.vec2(hud.RowWidth, hud.RowHeight),
      })
      local name = ctx.create_node(scope, "EUITextLabel", {
        Name = "PartyMemberName" .. tostring(item_signal:now().userId), Parent = row,
        Position = view_util.vec2(8, 6), Size = view_util.vec2(hud.RowWidth - 90, 22), Text = "",
      })
      local health_text = ctx.create_node(scope, "EUITextLabel", {
        Name = "PartyHealthText" .. tostring(item_signal:now().userId), Parent = row,
        Position = view_util.vec2(hud.RowWidth - 74, 6), Size = view_util.vec2(68, 22), Text = "",
      })
      ctx.create_node(scope, "EUIFrame", {
        Name = "PartyHealthBar" .. tostring(item_signal:now().userId), Parent = row,
        Position = view_util.vec2(8, 34), Size = view_util.vec2(hud.BarWidth, hud.BarHeight),
        Image = hud.ColorBlockImage,
      })
      local fill = ctx.create_node(scope, "EUIFrame", {
        Name = "PartyHealthFill" .. tostring(item_signal:now().userId), Parent = row,
        Position = view_util.vec2(8, 34), Size = view_util.vec2(0, hud.BarHeight), Image = hud.ColorBlockImage,
      })
      row.TouchEnabled, name.TouchEnabled, health_text.TouchEnabled = false, false, false
      scope:effect("PartyMemberProjection", function(es)
        local value = es:d(item_signal)
        local health = value.health or 0
        local maximum = value.maxHealth or 0
        row.Position = view_util.vec2(0, (value.index - 1) * hud.RowHeight)
        row.Visible = true
        name.Text = value.name
        health_text.Text = tostring(health) .. " / " .. tostring(maximum)
        local ratio = maximum > 0 and math.max(0, math.min(1, health / maximum)) or 0
        fill.Size = view_util.vec2(hud.BarWidth * ratio, hud.BarHeight)
      end)
    end,
  }
end

function squad_view.rescue_state(options)
  return rescue_view.create_state("squad_view.rescue_rows", options)
end

function squad_view.rescue_driver_spec(shared)
  return rescue_view.driver_spec(shared, {
    name = "SquadRescueDriver",
    mode = "squad",
  })
end

function squad_view.rescue_bubble_spec(shared)
  return rescue_view.bubble_spec(shared, {
    key_prefix = "",
    scene_kind = "squad_rescue",
    scene_prefix = "SceneNodeSquadRescue_",
    button_prefix = "BtnSquadRescue",
    log_tag = "[squad_view]",
    fail_label = "队友抢救按钮创建失败",
  })
end

return squad_view
