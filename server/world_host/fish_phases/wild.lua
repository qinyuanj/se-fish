local WildPhase = {}

function WildPhase.update(host, fish, now)
    if fish.wild_until and now >= fish.wild_until then
        print('[FishTree] 爆炸保底鱼到期消失', fish.fish_id, 'fish=' .. tostring(fish.Id))
        host:remove(fish)
    end
end

function WildPhase.mount(host, fish, ps)
    ps:subscribe(host:frame_clock().on_frame, function(frame)
        local now = host:begin_phase_frame(fish, frame and frame.now)
        if now then WildPhase.update(host, fish, now) end
    end)
end

return WildPhase
