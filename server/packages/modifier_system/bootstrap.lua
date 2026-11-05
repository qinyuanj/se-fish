-- #176 本图补的空钩子，不是官方包文件：引擎生成的 __OfficialPackageBootstrap__ 会 require 本模块，
-- 本图导入的旧版 modifier_system 没有 bootstrap.lua。返回空表，引擎无函数可调，与缺失时行为一致。
-- 整包重新导入取得官方 bootstrap.lua 后，以官方文件为准。
return {}
