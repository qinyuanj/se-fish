-- Public facade for spoke: require("common.packages.spoke.api") returns an aggregate table
-- of the 13 public classes (#2 decision). SpokeRuntime and the utility types
-- (Heap, PackedTreeCoords, SpokeException, ...) stay internal; deep requires
-- are not blocked — tests and advanced usage can still reach the modules
-- directly under common/packages/spoke/runtime/ and common/packages/spoke/reactive/.

local Epoch = require("common.packages.spoke.runtime.epoch")
local Ticker = require("common.packages.spoke.runtime.ticker")
local SpokeTree = require("common.packages.spoke.runtime.spoke_tree")
local Dock = require("common.packages.spoke.runtime.dock")
local LambdaEpoch = require("common.packages.spoke.runtime.lambda_epoch")
local SpokeHandle = require("common.packages.spoke.runtime.spoke_handle")

local Trigger = require("common.packages.spoke.reactive.trigger")
local State = require("common.packages.spoke.reactive.state")
local Effect = require("common.packages.spoke.reactive.effect")
local Reaction = require("common.packages.spoke.reactive.reaction")
local Memo = require("common.packages.spoke.reactive.memo")
local Phase = require("common.packages.spoke.reactive.phase")
local EffectBuilder = require("common.packages.spoke.reactive.effect_builder")

return {
  -- Runtime layer
  Epoch = Epoch,
  Ticker = Ticker,
  SpokeTree = SpokeTree,
  Dock = Dock,
  LambdaEpoch = LambdaEpoch,
  SpokeHandle = SpokeHandle,
  -- Reactive layer
  Trigger = Trigger,
  State = State,
  Effect = Effect,
  Reaction = Reaction,
  Memo = Memo,
  Phase = Phase,
  EffectBuilder = EffectBuilder,
}
