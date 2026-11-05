-- #176 本图补的空钩子，不是官方包文件：引擎生成的 __OfficialPackageBootstrap__ 会 require 本模块，
-- 本图导入的旧版 modifier_system 没有 bootstrap.lua。返回空表，引擎无函数可调，与缺失时行为一致。
-- 官方新版 bootstrap 预建 ECA 与预放置效果所需的事件单位，本图不用；整包升级时以官方文件为准。
return {}
