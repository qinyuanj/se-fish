-- 引擎生成的 unit_scripts/World/__OfficialPackageBootstrap__.lua 对列出的模块做
-- pcall(require) 并按名依次调用表内函数；模块缺失时引擎记 module not found。
-- #177 起使用官方 bootstrap.lua。失败方式：模块文件缺失、返回非表、启动函数清单增减未经复核。
describe('官方包 bootstrap 钩子', function()
    it('modifier_system.bootstrap 可加载且导出官方的 4 个启动函数', function()
        local ok, bootstrap = pcall(require, 'server.packages.modifier_system.bootstrap')
        assert.is_true(ok, tostring(bootstrap))
        assert.is_table(bootstrap)
        local names = {}
        for name, fn in pairs(bootstrap) do
            if type(fn) == 'function' then names[#names + 1] = name end
        end
        table.sort(names)
        assert.same({
            'ensureModifierEvents',
            'ensureObtainBeforeEvents',
            'replayPreplacedModifierObtain',
            'watchObtainBeforeEvents',
        }, names)
    end)
end)
