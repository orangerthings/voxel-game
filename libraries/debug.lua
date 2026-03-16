local Debug = {}
 
local timers = {}
local stats = {} -- dict of {sum, count}

function Debug.timerStart(label, t)
    t = t or 0 -- code for stats
    timers[label] = {lovr.timer.getTime(), t}
end

function Debug.timerStop(label)
    if timers[label] then
        local elapsed = lovr.timer.getTime() - timers[label][1]
        local t = timers[label][2] or 0
        timers[label] = nil

        stats[t] = stats[t] or {avg = 0, sum = 0, count = 0}
        stats[t].sum = stats[t].sum + elapsed
        stats[t].count = stats[t].count + 1

        print(string.format("%s: %.6f seconds", label, elapsed))
        return elapsed
    end
end

function Debug.getAverage(t)
    if stats[t] and stats[t].count > 0 then
        return stats[t].sum / stats[t].count
    else
        return 0
    end
end

function Debug.printAverages()
    for t, _ in pairs(stats) do
        print(string.format("Average time taken for debug code %d: %.6f seconds", t, Debug.getAverage(t)))
    end
end

return Debug