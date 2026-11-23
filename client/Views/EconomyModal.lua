-- 三类经济模态弹窗的轻量节点工具；所有节点与连接仍由 RootView 作用域拥有。
local EconomyModal = {}

function EconomyModal.panel(scope, ctx, name, title)
  local panel = ctx.create_node(scope, "EUIImage", {
    Parent = ctx.root_node, Name = name, Visible = true,
    Position = Vector2.New(0, 0), Size = Vector2.New(900, 600),
  })
  EconomyModal.label(scope, ctx, panel, "Label" .. name:gsub("Screen", "") .. "Title", title)
  return panel
end

function EconomyModal.label(scope, ctx, parent, name, text)
  return ctx.create_node(scope, "EUITextLabel", {
    Parent = parent, Name = name, Text = text or "", Visible = true,
  })
end

function EconomyModal.button(scope, ctx, parent, name, text, on_click)
  local button = ctx.create_node(scope, "EUIButton", {
    Parent = parent, Name = name, ButtonText = text, Visible = true,
  })
  button.TouchEnabled = true
  ctx.connect(scope, button.OnClicked, on_click)
  return button
end

function EconomyModal.close(scope, ctx, parent, name, modal_id)
  return EconomyModal.button(scope, ctx, parent, name, "关闭", function()
    local services = ctx.services or {}
    if type(services.close_modal) == "function" then services.close_modal(modal_id) end
  end)
end

return EconomyModal
