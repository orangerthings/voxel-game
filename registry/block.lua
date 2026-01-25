BlockRegistry = {
    byId = {},
    byNamespace = {},
    propertiesById = {},
    nextId = 1
}

local template = {
    id = 0,
    namespace = "",
    transparent = false,
    texture = "debug_outline"
}

for k, _ in pairs(template) do
    BlockRegistry.propertiesById[k] = {}
end

function BlockRegistry:register(namespace, def)
    local id = self.nextId
    self.nextId = self.nextId + 1

    def.id = id
    def.namespace = namespace

    for k, v in pairs(template) do
        if def[k] == nil then
            def[k] = v
        end
    end

    for k, v in pairs(def) do
        if self.propertiesById[k] then
            self.propertiesById[k][id] = v
        end
    end

    self.byId[id] = def
    self.byNamespace[namespace] = def

    return id
end

function BlockRegistry:getById(id)
    return self.byId[id]
end

function BlockRegistry:getByNamespace(namespace)
    return self.byNamespace[namespace]
end

return BlockRegistry