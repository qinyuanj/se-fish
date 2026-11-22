local GrillCurve = {}

function GrillCurve.Rate(elapsed, cfg)
    if type(elapsed) ~= 'number' or elapsed ~= elapsed or elapsed >= math.huge then return nil end
    if elapsed < 0 then elapsed = 0 end
    if elapsed >= cfg.BurnSec then return 0 end
    if elapsed < cfg.RiseSec then
        return 1 + (cfg.MaxRate - 1) * (elapsed / cfg.RiseSec)
    end
    if elapsed < cfg.RiseSec + cfg.HoldSec then return cfg.MaxRate end
    local falling = (elapsed - cfg.RiseSec - cfg.HoldSec) / cfg.FallSec
    return cfg.MaxRate * (1 - falling)
end

function GrillCurve.IsBurnt(elapsed, cfg)
    return type(elapsed) == 'number' and elapsed >= cfg.BurnSec
end

function GrillCurve.Format(rate)
    return string.format('%.2f', rate)
end

return GrillCurve
