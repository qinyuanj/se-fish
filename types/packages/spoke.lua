---@meta common.packages.spoke.api
-- 上游 spoke 包的公开契约声明（仅类型，不进运行期与打包）。
-- 导出键一致性由 tests/native/guards/package_types_guard_test.lua 守卫。

---@class SpokeHandleInstance
---@field dispose fun(self: SpokeHandleInstance)

---@class SpokeState
---@field now fun(self: SpokeState): any
---@field set fun(self: SpokeState, value: any)
---@field update fun(self: SpokeState, fn: fun(prev: any): any)
---@field subscribe fun(self: SpokeState, fn: fun(value: any)): SpokeHandleInstance
---@field unsubscribe fun(self: SpokeState, fn: any)

---@class SpokeMemo
---@field now fun(self: SpokeMemo): any
---@field subscribe fun(self: SpokeMemo, fn: fun(value: any)): SpokeHandleInstance
---@field unsubscribe fun(self: SpokeMemo, fn: any)

---@class SpokeTrigger
---@field invoke fun(self: SpokeTrigger, payload?: any)
---@field subscribe fun(self: SpokeTrigger, fn: fun(payload?: any)): SpokeHandleInstance
---@field unsubscribe fun(self: SpokeTrigger, fn: any)

---@class SpokeDock
---@field call fun(self: SpokeDock, key: string, epoch: any): any
---@field drop fun(self: SpokeDock, key: string)
---@field get fun(self: SpokeDock, key: string): any
---@field has fun(self: SpokeDock, key: string): boolean
---@field keys fun(self: SpokeDock): string[]
---@field detach fun(self: SpokeDock)

---@class SpokeEffectBuilder
---@field d fun(self: SpokeEffectBuilder, signal: any): any
---@field subscribe fun(self: SpokeEffectBuilder, trigger: any, fn: fun(...: any)): SpokeHandleInstance
---@field use fun(self: SpokeEffectBuilder, resource: any): any
---@field call fun(self: SpokeEffectBuilder, epoch: any): any
---@field export fun(self: SpokeEffectBuilder, key: string, value: any)
---@field import fun(self: SpokeEffectBuilder, key: string): any
---@field try_import fun(self: SpokeEffectBuilder, key: string): any
---@field on_cleanup fun(self: SpokeEffectBuilder, fn: fun())
---@field log fun(self: SpokeEffectBuilder, message: any)
---@field memo fun(self: SpokeEffectBuilder, ...: any): SpokeMemo
---@field effect fun(self: SpokeEffectBuilder, ...: any): SpokeEffect
---@field reaction fun(self: SpokeEffectBuilder, ...: any): any
---@field phase fun(self: SpokeEffectBuilder, ...: any): any
---@field dock fun(self: SpokeEffectBuilder, name?: string): SpokeDock

---@class SpokeEffect
---@field now fun(self: SpokeEffect): any
---@field subscribe fun(self: SpokeEffect, fn: fun(value: any)): SpokeHandleInstance
---@field unsubscribe fun(self: SpokeEffect, fn: any)
---@field detach fun(self: SpokeEffect)

---@class SpokeTreeInstance
---@field name string
---@field is_detached boolean
---@field fault any
---@field flush fun(self: SpokeTreeInstance)
---@field tick fun(self: SpokeTreeInstance)
---@field dispose fun(self: SpokeTreeInstance)
---@field detach fun(self: SpokeTreeInstance)

---@class SpokeAPI
local M = {}

M.Epoch = {}
---@param ... any
---@return any
function M.Epoch.new(...) end
---@param name string
---@param definition? table
---@return any
function M.Epoch.extend(name, definition) end

M.Ticker = {}
---@param ... any
---@return any
function M.Ticker.new(...) end
---@param name string
---@param definition? table
---@return any
function M.Ticker.extend(name, definition) end

M.SpokeTree = {}
---@param ... any
---@return SpokeTreeInstance
function M.SpokeTree.new(...) end
---@param ... any
---@return SpokeTreeInstance
function M.SpokeTree.spawn(...) end
---@param ... any
---@return SpokeTreeInstance
function M.SpokeTree.spawn_eager(...) end
---@param ... any
---@return SpokeTreeInstance
function M.SpokeTree.spawn_manual(...) end

M.Dock = {}
---@param ... any
---@return SpokeDock
function M.Dock.new(...) end

M.LambdaEpoch = {}
---@param ... any
---@return any
function M.LambdaEpoch.new(...) end

M.SpokeHandle = {}
---@param id? any
---@param on_dispose? fun()
---@return SpokeHandleInstance
function M.SpokeHandle.of(id, on_dispose) end
---@return SpokeHandleInstance
function M.SpokeHandle.new() end
---@param value any
---@return boolean
function M.SpokeHandle.is(value) end

M.Trigger = {}
---@param name? string
---@return SpokeTrigger
function M.Trigger.new(name) end

M.State = {}
---@param ... any
---@return SpokeState
function M.State.new(...) end

M.Effect = {}
---@param ... any
---@return SpokeEffect
function M.Effect.new(...) end

M.Reaction = {}
---@param ... any
---@return any
function M.Reaction.new(...) end

M.Memo = {}
---@param ... any
---@return SpokeMemo
function M.Memo.new(...) end

M.Phase = {}
---@param ... any
---@return any
function M.Phase.new(...) end

M.EffectBuilder = {}
---@param ... any
---@return SpokeEffectBuilder
function M.EffectBuilder.new(...) end

return M
