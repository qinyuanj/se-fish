--效果系统包 - 工具方法

local util = {}

---获取服务端时间戳，单位秒，倒计时与剩余时间换算统一走该时间源
---@return number 服务端时间戳
function util.getServerTime()
	return game:GetService("World"):GetServerTime()
end

---以"无归属"方式执行：常驻资源（跨端订阅、状态栏刷新循环等）不登记到任何脚本名下，
---避免随创建它的脚本销毁被连带回收（静默断开订阅/停止循环）。
---实现：借助 TimerService 单次计时器一跳，回调上下文为"显式无主"，
---回调内新建的连接/协程/计时器同样无归属，可跨脚本生命周期存活。
---注意：fn 会延后约一帧异步执行（调用方勿依赖同步完成）；引导跳在触发前仍短暂
---登记在调用脚本名下，调用脚本若在触发前被销毁需由调用方重试补齐
---@param fn function 待执行函数
function util.runDetached(fn)
	game:GetService("TimerService"):CreateTimer(1, 0.01, false, fn)
end

return util
