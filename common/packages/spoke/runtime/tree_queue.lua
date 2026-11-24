local Ordering = require("common.packages.spoke.runtime.ordering")

local TreeQueue = {}

local function compare_boost(a, b, boosted)
  return Ordering.compare_flag(boosted[a] == true, boosted[b] == true)
end

function TreeQueue.make_comparator(runtime)
  return function(a, b)
    local by_layer = Ordering.compare(a._flush_layer, b._flush_layer)
    if by_layer ~= 0 then
      return by_layer
    end
    local by_boost = compare_boost(a, b, runtime._boosted_trees)
    if by_boost ~= 0 then
      return by_boost
    end
    return Ordering.compare(a._timestamp, b._timestamp)
  end
end

function TreeQueue.discard(tree)
  tree._runtime_pending = false
  if type(tree._discard_pending) == "function" then
    tree:_discard_pending()
  end
end

function TreeQueue.has_live_head(queue)
  while queue:count() > 0 do
    local tree = queue:peek_min()
    if tree.is_detached or tree.fault then
      queue:remove_min()
      TreeQueue.discard(tree)
    else
      return true
    end
  end
  return false
end

function TreeQueue.drain(queue)
  while queue:count() > 0 do
    TreeQueue.discard(queue:remove_min())
  end
end

return TreeQueue
