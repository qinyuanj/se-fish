local Epoch = require("common.packages.spoke.runtime.epoch")

local LambdaEpoch = Epoch.extend("LambdaEpoch", {
  constructor = function(self, init_fn)
    self._init_fn = init_fn
  end,

  init = function(self, s)
    return self._init_fn(s)
  end,
})

return LambdaEpoch
