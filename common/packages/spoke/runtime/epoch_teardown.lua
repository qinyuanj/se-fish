---@class Spoke.EpochTeardown
local EpochTeardown = {}

---@param record Spoke.EpochAttachment
---@return boolean ok
---@return any ...
local function release_disposable(record)
  if type(record.value) == "function" then
    return pcall(record.value)
  end
  return pcall(function()
    record.value:dispose()
  end)
end

---@class Spoke.AttachmentReleaser
---@field message string
---@field release fun(record: Spoke.EpochAttachment): boolean, any...

---@type table<string, Spoke.AttachmentReleaser?>
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

---@param epoch Spoke.EpochInternal
---@param message string
---@param error_value any
---@param fallback_log fun(message: string, error_value: any)
local function report(epoch, message, error_value, fallback_log)
  local tree = epoch._tree
  if tree and tree._is_tree and tree ~= epoch and type((tree --[[@as Spoke.SpokeTreeInternal]])._log_error) == "function" then
    (tree --[[@as Spoke.SpokeTreeInternal]]):_log_error(message, error_value)
  else
    fallback_log(message, error_value)
  end
end

---@param epoch Spoke.EpochInternal
---@param index integer?
---@param fallback_log fun(message: string, error_value: any)
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
