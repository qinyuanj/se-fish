local EpochTeardown = {}

local function release_disposable(record)
  if type(record.value) == "function" then
    return pcall(record.value)
  end
  return pcall(function()
    record.value:dispose()
  end)
end

local RELEASERS = {
  cleanup = {
    message = "Cleanup failed in '%s'",
    release = function(record)
      return pcall(record.value)
    end,
  },
  call = {
    message = "Failed to cleanup child of '%s'",
    release = function(record)
      return pcall(function()
        record.value:detach()
      end)
    end,
  },
  use = { message = "Dispose failed in '%s'", release = release_disposable },
  handle = { message = "Dispose failed in '%s'", release = release_disposable },
}

local function report(epoch, message, error_value, fallback_log)
  local tree = epoch._tree
  if tree and tree ~= epoch and type(tree._log_error) == "function" then
    tree:_log_error(message, error_value)
  else
    fallback_log(message, error_value)
  end
end

function EpochTeardown.release_from(epoch, index, fallback_log)
  local floor = math.max(index or 0, 0)
  while #epoch._attachments > floor do
    local record = table.remove(epoch._attachments)
    local releaser = RELEASERS[record.kind]
    if releaser then
      local ok, error_value = releaser.release(record)
      if not ok then
        report(epoch, releaser.message:format(tostring(epoch)), error_value, fallback_log)
      end
    end
  end
end

return EpochTeardown
