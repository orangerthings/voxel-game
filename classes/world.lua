local ChunkSpace = require('classes.chunkspace')
World = ChunkSpace:extend("World")

function World:new()
    -- the
    World.super.new(self)
end

return World