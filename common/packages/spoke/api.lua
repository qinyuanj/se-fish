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

---@class Spoke.API
---@field Epoch Spoke.EpochClass
---@field Ticker Spoke.TickerClass
---@field SpokeTree Spoke.SpokeTreeClass
---@field Dock Spoke.DockClass
---@field LambdaEpoch Spoke.LambdaEpochClass
---@field SpokeHandle Spoke.SpokeHandleClass
---@field Trigger Spoke.TriggerClass
---@field State Spoke.StateClass
---@field Effect Spoke.EffectClass
---@field Reaction Spoke.ReactionClass
---@field Memo Spoke.MemoClass
---@field Phase Spoke.PhaseClass
---@field EffectBuilder Spoke.EffectBuilderClass
return {
  Epoch = Epoch,
  Ticker = Ticker,
  SpokeTree = SpokeTree,
  Dock = Dock,
  LambdaEpoch = LambdaEpoch,
  SpokeHandle = SpokeHandle,
  Trigger = Trigger,
  State = State,
  Effect = Effect,
  Reaction = Reaction,
  Memo = Memo,
  Phase = Phase,
  EffectBuilder = EffectBuilder,
}
