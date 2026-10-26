-- 鳄雀鳝资产交付契约（features/art/alligator_gar_asset.feature）的步骤处理器。
--
-- 只读美术工作区里步骤 06 产出的重导入校验报告；报告定位与读取见 tools/art_report.lua。
-- 资产本体不进本仓，所以验收必须对着美术工作区的真实产物跑：
--   <宿主目录同级>/美术资产/鳄雀鳝/validation/validation.json
--
-- 骨架是新建的 rig_quadruped_v1-draft（15 骨），断言全部按鳄雀鳝自己的交付契约写，
-- 不与罗非鱼/鲤鱼比对骨骼同构。本文件只覆盖接缝 B（导出链路自洽）；
-- 接缝 A（游戏内尺寸、外观、动画表现与碰撞体）是人工验收，条件写在 feature 文件头。
local report = require('tools.art_report')

local GAR = '鳄雀鳝'
local MODEL = 'output/fish_alligator_gar.fbx'
local ANIMATIONS = { 'Idle', 'Walk', 'Attack' }
-- 蒙皮自检摆幅最大的两段，与步骤 06 的 skinning 段一致
local SKIN_CLIPS = { 'Walk', 'Attack' }
local BASE_COLOR = 'output/AlligatorGar_BaseColor_1024.png'
-- rig_quadruped_v1-draft 的骨骼名单（第二只四足复用成功前不转正）
local BONES = { 'Root', 'Hips', 'Spine', 'Head', 'Jaw', 'Tail1', 'Tail2', 'UpperArm_L', 'Forearm_L',
  'UpperArm_R', 'Forearm_R', 'Thigh_L', 'Shin_L', 'Thigh_R', 'Shin_R' }

-- 尺度口径见 ADR-0004：首领按设计 5 米预摆，导入资源全长约 0.05，游戏端缩放 100 → 5 个游戏单位
local GAME_SCALE = 100
local LENGTH_TOLERANCE = 0.0015
-- 罗非鱼交付件的骨架世界缩放；鳄雀鳝沿用同一链路，节点层不另加补偿
local RIG_WORLD_SCALE = 0.05

local function model(world)
  return report.entry(world, GAR, MODEL)
end

local function is_close(value, target, tolerance)
  return math.abs(value - target) <= tolerance
end

return { patterns = {
  { '^鳄雀鳝的重导入校验报告已产出且没有失败项$', function(world)
      local failures = report.load(world, GAR).failures
      assert(type(failures) == 'table' and #failures == 0,
        '校验报告自带失败项：' .. table.concat(failures, '；'))
  end },

  -- 模型件：分件约定与首领档预算
  { '^查看鳄雀鳝模型件 output/fish_alligator_gar.fbx$', function(world)
      model(world)
  end },
  { '^鳄雀鳝网格数为 (%d+) 且骨架数为 (%d+)$', function(world, meshes, rigs)
      assert(model(world).mesh_count == tonumber(meshes),
        '网格数应为 ' .. meshes .. '，实际 ' .. tostring(model(world).mesh_count))
      assert(model(world).armature_count == tonumber(rigs),
        '骨架数应为 ' .. rigs .. '，实际 ' .. tostring(model(world).armature_count))
  end },
  { '^鳄雀鳝材质数为 (%d+)$', function(world, count)
      assert(#model(world).materials == tonumber(count),
        '材质数应为 ' .. count .. '，实际 ' .. tostring(#model(world).materials))
  end },
  { '^鳄雀鳝三角面数不超过 (%d+)$', function(world, budget)
      assert(model(world).triangles <= tonumber(budget),
        '三角面数 ' .. tostring(model(world).triangles) .. ' 超过预算 ' .. budget)
  end },
  { '^鳄雀鳝模型件不含动画片段$', function(world)
      assert(model(world).animation_clips == 0,
        '模型件内嵌了 ' .. tostring(model(world).animation_clips)
          .. ' 个动画片段，分件约定要求动画单独成件')
  end },

  -- 模型件：尺度口径（ADR-0004）
  { '^鳄雀鳝静止姿态全长约为 ([%d%.]+)$', function(world, target)
      local length = model(world).rest_dimensions[2]
      assert(is_close(length, tonumber(target), LENGTH_TOLERANCE),
        '静止姿态全长 ' .. tostring(length) .. ' 偏离 ' .. target)
  end },
  { '^鳄雀鳝游戏端缩放 (%d+) 后全长为 ([%d%.]+) 个游戏单位$', function(world, scale, target)
      assert(tonumber(scale) == GAME_SCALE, '游戏端缩放应为 ' .. GAME_SCALE)
      local game_length = model(world).rest_dimensions[2] * tonumber(scale)
      assert(is_close(game_length, tonumber(target), 0.05),
        '缩放 ' .. scale .. ' 后全长 ' .. tostring(game_length) .. ' 不是 ' .. target .. ' 个游戏单位')
  end },

  -- 模型件：rig_quadruped_v1-draft 骨骼名单
  { '^查看鳄雀鳝模型件的骨骼名$', function(world)
      model(world)
  end },
  { '^鳄雀鳝骨骼恰好是 (.+)$', function(world, expected)
      local wanted = {}
      for name in expected:gmatch('[^,%s]+') do wanted[#wanted + 1] = name end
      -- FBX 往返不保证骨骼顺序，按集合比对；名单本身仍要恰好一致（不多不少）
      table.sort(wanted)
      local actual = { table.unpack(model(world).bones) }
      table.sort(actual)
      assert.same(wanted, actual)
  end },

  -- 动画：分件、非空、骨架一致
  { '^逐段查看鳄雀鳝 output 下的 3 个动画文件$', function(world)
      for _, clip in ipairs(ANIMATIONS) do
        report.entry(world, GAR, 'output/fish_alligator_gar_' .. clip .. '.fbx')
      end
  end },
  { '^鳄雀鳝每段都没有网格且只有一个骨架$', function(world)
      for _, clip in ipairs(ANIMATIONS) do
        local entry = report.entry(world, GAR, 'output/fish_alligator_gar_' .. clip .. '.fbx')
        assert(entry.mesh_count == 0,
          clip .. ' 应为纯骨架文件，实际 ' .. tostring(entry.mesh_count) .. ' 个网格')
        assert(entry.armature_count == 1,
          clip .. ' 骨架数应为 1，实际 ' .. tostring(entry.armature_count))
      end
  end },
  { '^鳄雀鳝每段恰好内嵌 1 个动画片段$', function(world)
      for _, clip in ipairs(ANIMATIONS) do
        local entry = report.entry(world, GAR, 'output/fish_alligator_gar_' .. clip .. '.fbx')
        assert(entry.animation_clips == 1,
          clip .. ' 应恰好内嵌 1 个动画片段，实际 ' .. tostring(entry.animation_clips))
      end
  end },
  { '^每段的骨骼名与鳄雀鳝模型件一致$', function(world)
      for _, clip in ipairs(ANIMATIONS) do
        local entry = report.entry(world, GAR, 'output/fish_alligator_gar_' .. clip .. '.fbx')
        assert.same(model(world).bones, entry.bones)
      end
  end },
  { '^鳄雀鳝每段的探针骨位移都大于 0$', function(world)
      for _, clip in ipairs(ANIMATIONS) do
        local entry = report.entry(world, GAR, 'output/fish_alligator_gar_' .. clip .. '.fbx')
        -- 探针按段区分（Idle=Tail2, Walk=Forearm_L, Attack=Jaw）；字段名沿用报告的通用口径
        local travel = entry.probe_bone_travel
        assert(type(travel) == 'number' and travel > 0,
          clip .. ' 是空动画（探针骨位移 ' .. tostring(travel) .. '）')
      end
  end },

  -- 蒙皮：形变后仍是鳄雀鳝的大小
  { '^把鳄雀鳝模型件网格挂到 Walk 与 Attack 的动画骨架上逐帧求包围盒$', function(world)
      local skinning = report.load(world, GAR).skinning
      assert(type(skinning) == 'table', '校验报告没带蒙皮自检段')
      for _, clip in ipairs(SKIN_CLIPS) do
        assert(type(skinning[clip]) == 'table', '蒙皮自检缺 ' .. clip .. ' 段')
      end
  end },
  { '^鳄雀鳝全长始终在 ([%d%.]+) 到 ([%d%.]+) 之间$', function(world, low, high)
      local skinning = report.load(world, GAR).skinning
      for _, clip in ipairs(SKIN_CLIPS) do
        local section = skinning[clip]
        assert(section.length_min >= tonumber(low) and section.length_max <= tonumber(high),
          clip .. ' 形变后全长跑到 [' .. tostring(section.length_min) .. ', '
            .. tostring(section.length_max) .. ']，骨架与网格不匹配')
      end
  end },

  -- 贴图：1024 仅 BaseColor
  { '^查看鳄雀鳝 output 下的交付贴图$', function(world)
      report.entry(world, GAR, BASE_COLOR)
  end },
  { '^鳄雀鳝只有 1 张 BaseColor 且是 1024 见方$', function(world)
      local entry = report.entry(world, GAR, BASE_COLOR)
      assert.same({ 1024, 1024 }, entry.size,
        BASE_COLOR .. ' 尺寸应为 1024 见方，实际 ' .. table.concat(entry.size, 'x'))
      -- 目录里多出 Normal/ORM 就超出「仅 BaseColor」的交付约定
      local listed = report.load(world, GAR).textures_listed
      assert.same({ 'AlligatorGar_BaseColor_1024.png' }, listed,
        'output/ 里的贴图应只有 AlligatorGar_BaseColor_1024.png，实际 ' .. tostring(listed))
  end },
  { '^鳄雀鳝模型件内嵌的 BaseColor 是 sRGB$', function(world)
      local textures = model(world).textures
      assert(type(textures) == 'table' and #textures == 1,
        '模型件内嵌贴图应为 1 张（仅 BaseColor），实际 ' .. tostring(#textures))
      assert(textures[1].colorspace == 'sRGB',
        'BaseColor 色彩空间应为 sRGB，实际 ' .. tostring(textures[1].colorspace))
      assert.same({ 1024, 1024 }, textures[1].size,
        '内嵌 BaseColor 应为 1024 见方，实际 ' .. table.concat(textures[1].size, 'x'))
  end },

  -- 节点结构：与罗非鱼/鲤鱼/鳄雀鳝交付件同构的缩放链路
  { '^查看鳄雀鳝模型件的节点缩放$', function(world)
      assert(type(model(world).node_scale) == 'table', '校验报告没带节点缩放')
  end },
  { '^鳄雀鳝网格节点缩放为 1 且骨架世界缩放为 ([%d%.]+)$', function(world, rig_scale)
      assert(is_close(tonumber(rig_scale), RIG_WORLD_SCALE, 1e-6),
        '骨架世界缩放口径应为 ' .. tostring(RIG_WORLD_SCALE))
      local node_scale = model(world).node_scale
      for _, value in ipairs(node_scale.mesh_local) do
        assert(is_close(value, 1.0, 1e-4),
          '网格节点带自身缩放 ' .. table.concat(node_scale.mesh_local, ', ')
            .. '，这一层不许另加补偿')
      end
      for _, value in ipairs(node_scale.rig_world) do
        assert(is_close(value, RIG_WORLD_SCALE, 1e-4),
          '骨架世界缩放应为 ' .. tostring(RIG_WORLD_SCALE) .. '，实际 '
            .. table.concat(node_scale.rig_world, ', '))
      end
  end },
} }
