local Debug = {}
 
local timers = {}

function Debug.timerStart(label)
    timers[label] = lovr.timer.getTime()
end

function Debug.timerStop(label)
    if timers[label] then
        local elapsed = lovr.timer.getTime() - timers[label]
        timers[label] = nil
        print(string.format("%s: %.6f seconds", label, elapsed))
        return elapsed
    end
end

return Debug