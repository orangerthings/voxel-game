local Debug = require('libraries.debug')

Data = {}

function Data.iterateVisible(t, fn, ...)
    for k, v in pairs(t) do
        if (type(k) == "string" and not string.match(k, "^_")) or type(k) ~= "string" then
            fn(k, v, ...)
        end
    end
end

local blacklisted = {
    ["function"] = true,
    ["cdata"] = true
}

-- 1. replace all table references with interned references
-- 2a. store metatables separately
-- 2b. if there is a classic class, store the class name instead of the metatable
-- 3. remove all unsupported data types
function Data.internTable(absolved)
    local interned = {}
    local visited = {}

    local function getId(t)
        if t == absolved then
            return "_master"
        end
        return string.format("table: %p", t)
    end

    local function intern(t)
        if visited[t] then
            return
        end
        visited[t] = true
        local id = getId(t)
        local clone = {}
        -- store metatable or class name
        local mt = getmetatable(t)
        if mt then
            if mt.className then
                clone._className = mt.className
            else
                clone._meta = mt
            end
        end
        interned[id] = clone
        Data.iterateVisible(t, function(k, v)
            -- skip unsupported types
            if blacklisted[type(v)] then
                return
            end
            if type(v) == "table" then
                local vid = getId(v)
                clone[k] = { _interned = true, id = vid }
                intern(v)
            else
                clone[k] = v
            end
        end)
    end

    intern(absolved)

    return interned
end

-- the old legacy version that mutated the input table
function Data.internTableLegacy(absolved)
    local interned = {}

    local function addToInterned(t, id)
        if t == absolved then
            id = "_master"
        end
        if interned[id] == nil then
            -- store metatable or class name
            local mt = getmetatable(t)
            if mt then
                if mt.className then
                    t._className = mt.className
                else
                    t._meta = mt
                end
            end

            interned[id] = t
        end
    end

    local function intern(t)
        t._visited = true
        -- create unique id
        local id = string.format("table: %p", t)
        addToInterned(t, id)
        Data.iterateVisible(t, function(k, v)
            if blacklisted[type(v)] then
                t[k] = nil
            end
            if type(v) == "table" then
                if not v._interned then -- skip past intern objects
                    local vid = string.format("table: %p", v)
                    -- replace with interned reference
                    t[k] = {_interned = true, id = vid}
                    if not v._visited and not v._ignore then
                        intern(v)
                    else
                        addToInterned(v, vid)
                    end
                end
            end
        end)
        return t
    end
    intern(absolved)

    return interned
end

local classes = {}

-- to absolve is just the opposite of to intern
-- 1. replace all interned references with actual tables
-- 2. restore metatables or classic classes
function Data.absolveTable(interned)
    local function absolve(t)
        if not t._ignore then
            Data.iterateVisible(t, function(k, v)
                -- restore table
                if type(v) == "table" then
                    if v._interned then
                        t[k] = interned[v.id]
                    else
                        absolve(v)
                    end
                end
            end)
            -- restore metatables
            if t._meta then
                setmetatable(t, t._meta)
                t._meta = nil
            end
            -- restore classic classes
            if t._className then
                local class = classes[t._className]
                if class == nil then
                    local ok, result = pcall(require, "classes."..t._className:lower())
                    if ok then
                        class = result
                        classes[t._className] = class
                    else
                        error("Could not load class "..t._className)
                    end
                end
                setmetatable(t, class)
                if type(t.onRestore) == "function" then
                    t:onRestore()   
                end
                t._className = nil
            end
        end
    end
    for _, t in pairs(interned) do
        absolve(t)
    end
    -- after all ends are tied, the absolved table should be the master table
    return interned._master
end

-- time for messages

Data.createMessage = function(type, payload, name, intern)
    intern = intern or true
    local debugLabel = string.format("Message type %s created", type)
    Debug.timerStart(debugLabel)

    payload = Data.internTable(payload)

    Debug.timerStop(debugLabel)
    return {
        type = type,
        payload = payload,
        name = name
    }
end

Data.readMessage = function(message, absolve)
    absolve = absolve or true
    local debugLabel = string.format("Message type %s read", message.type)
    Debug.timerStart(debugLabel)

    local payload = Data.absolveTable(message.payload)
    
    Debug.timerStop(debugLabel)
    return message.type, payload, message.name
end

return Data