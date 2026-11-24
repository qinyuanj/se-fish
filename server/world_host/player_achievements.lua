local GameCfg=require('common.game_cfg')
local Mgr={retry_at={},busy={}}

local function positiveId(value)
    return type(value)=='number' and value>0 and value==math.floor(value) and value or nil
end

local function target(definition)
    local real=positiveId(definition and definition.PlatformId)
    if real then return real,false end
    local placeholder=positiveId(definition and definition.PlaceholderId)
    if placeholder then return placeholder,true end
    return nil,false
end

local function debugEnabled()
    local debug=GameCfg.Debug
    return debug~=nil and debug.Enabled==true
end

function Mgr:confirm(player,data,key)
    if self.player_data:get_data_inst(player)~=data or self.busy[player.UserId] then return end
    if self.Save then
        local operation=self.Save:next_operation(player,'achievement-confirm')
        if not operation then return end
        self.busy[player.UserId]=true
        local accepted,reason=self.Save:execute(player,data,operation,function(draft)
            if not draft.Extra.achievements[key] then return nil,'not-completed' end
            draft.Extra.achievementDelivered=draft.Extra.achievementDelivered or {}
            draft.Extra.achievementDelivered[key]=true
            return {ok=true,achievement=key}
        end,function(ok,result)
            if self.player_data:get_data_inst(player)~=data then return end
            self.busy[player.UserId]=nil
            if not ok then print('[PlayerAchievements] 平台确认落账失败',player.UserId,key,tostring(result)) end
        end)
        if not accepted and self.player_data:get_data_inst(player)==data then
            self.busy[player.UserId]=nil
            print('[PlayerAchievements] 平台确认暂不能落账，保留补交',player.UserId,key,tostring(reason))
        end
    else
        data.Extra.achievementDelivered=data.Extra.achievementDelivered or {}
        data.Extra.achievementDelivered[key]=true
        data:UpdateData(function() end,true)
    end
end

function Mgr:update()
    if not self.player_data or not self.Players or not self.World then return end
    local now=self.World:GetServerTime()
    for _, player in ipairs(self.Players:GetPlayers()) do
        local data=self.player_data:get_data_inst(player)
        if data and data.inited and not self.busy[player.UserId]
            and now>=(self.retry_at[player.UserId] or 0) then
            for key,definition in pairs(GameCfg.Achievements) do
                local id,placeholder=target(definition)
                if placeholder and not debugEnabled() then id=nil end
                if data.Extra.achievements and data.Extra.achievements[key]
                    and not (data.Extra.achievementDelivered and data.Extra.achievementDelivered[key])
                    and id then
                    self.retry_at[player.UserId]=now+GameCfg.AchievementDelivery.RetrySec
                    if self.archive then
                        local ok,done=pcall(self.archive.IsAchievementCompleted,self.archive,player,id)
                        if not ok then
                            print('[PlayerAchievements] 平台查询失败，保留补交',player.UserId,key,tostring(done))
                        elseif done==true then
                            if not placeholder then self:confirm(player,data,key) end
                        elseif done==false then
                            local sent,err=pcall(self.archive.SetAchievementProgress,self.archive,player,id,1)
                            if not sent then print('[PlayerAchievements] 平台提交失败，保留补交',player.UserId,key,tostring(err)) end
                        end
                    end
                end
            end
        end
    end
end

function Mgr:on_player_removing(player)
    if not player or player.UserId == nil then return end
    self.retry_at[player.UserId],self.busy[player.UserId]=nil,nil
end

function Mgr.mount(scope, player_tree, opts)
    local player = opts.player
    local ok, archive = pcall(function() return game:GetService('ArchiveService') end)
    local session = setmetatable({
        busy = {}, retry_at = {}, player_data = opts.player_data, Save = opts.save,
        Players = { GetPlayers = function() return { player } end },
        World = { GetServerTime = function() return opts.clock.now() end },
        archive = ok and archive or nil,
    }, { __index = Mgr })
    player_tree.achievements = session
    scope:subscribe(opts.clock.on_second, function() session:update() end)
    scope:on_cleanup(function()
        session:on_player_removing(player)
        if player_tree.achievements == session then player_tree.achievements = nil end
    end)
    session:update()
    return session
end

return Mgr
