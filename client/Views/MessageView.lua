-- #315 消息提示 HUD：消息只是投影，不再拥有独立 ScreenMsg 生命周期。
local Modal = require("client.Views.EconomyModal")
local MessageView = {}

function MessageView.spec()
  return {
    name = "Message",
    mount = function(scope, ctx)
      local label = Modal.label(scope, ctx, ctx.root_node, "LabelMessage", "")
      label.Visible = false
      scope:effect("MessageProjection", function(es)
        local message = es:d(ctx.store.message)
        local text = type(message) == "table" and message.text or nil
        label.Text = text or ""
        label.Visible = type(text) == "string" and text ~= ""
      end)
    end,
  }
end

return MessageView
