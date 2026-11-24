local Modal = require("client.views.economy_modal")
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
