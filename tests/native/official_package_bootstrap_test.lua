-- #176 引擎生成的 unit_scripts/World/__OfficialPackageBootstrap__.lua 对列出的模块做
-- pcall(require) 并按名依次调用表内函数；模块缺失时引擎记 module not found。
-- 失败方式：模块文件缺失、返回非表、表内出现会被引擎执行的函数。
describe('官方包 bootstrap 钩子', function()
    it('modifier_system.bootstrap 可加载且不注册任何启动函数', function()
        local ok, bootstrap = pcall(require, 'server.packages.modifier_system.bootstrap')
        assert.is_true(ok, tostring(bootstrap))
        assert.is_table(bootstrap)
        for name, fn in pairs(bootstrap) do
            assert.are_not.equal('function', type(fn), '意外的启动函数：' .. tostring(name))
        end
    end)
end)
