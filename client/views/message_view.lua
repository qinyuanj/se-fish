local modal = require("client.views.economy_modal")
local message_view = {}

function message_view.spec()
  return {
    name = "Message",
    mount = function(scope, ctx)
      local label = modal.label(scope, ctx, ctx.root_node, "LabelMessage", "")
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

return message_view
