local host_signal = {}

function host_signal.connect(scope, signal, handler)
  if scope == nil or signal == nil or type(signal.Connect) ~= "function" then return nil end
  local connection = signal:Connect(handler)
  scope:on_cleanup(function()
    pcall(function() connection:Disconnect() end) -- 宿主单位或信号可能已先卸载
  end)
  return connection
end

return host_signal
