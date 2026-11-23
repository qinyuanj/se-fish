local IntrospectLabels = {}

local rawequal = rawequal or function(a, b) return a == b end

function IntrospectLabels.frame_kind(frame)
  return frame.type or frame.kind or "None"
end

function IntrospectLabels.epoch_type_name(epoch)
  if type(epoch) ~= "table" then
    return "<unknown>"
  end
  local metatable = getmetatable(epoch)
  if type(metatable) ~= "table" then
    return "<unknown>"
  end
  return metatable._default_name or "Epoch"
end

function IntrospectLabels.epoch_frame_name(epoch)
  if epoch == nil then
    return "<null>"
  end
  return tostring(epoch)
end

function IntrospectLabels.append_fault_suffix(label, epoch)
  if type(epoch) == "table" and epoch.fault ~= nil then
    label = label .. " [Faulted: " .. tostring(epoch.fault.cause) .. "]"
  end
  return label
end

function IntrospectLabels.frame_epoch_label(epoch, frames)
  local indices = {}
  for index, frame in ipairs(frames) do
    if rawequal(frame.epoch, epoch) then
      indices[#indices + 1] = tostring(index - 1)
    end
  end
  if #indices == 0 then
    return tostring(epoch)
  end
  return "(" .. table.concat(indices, ",") .. ")-" .. tostring(epoch)
end

return IntrospectLabels
