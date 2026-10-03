---@class DroneCamField
---Finds the edges of the field the vehicle is working, by stepping outwards
---until the ground stops being field. Used by the creator shots that frame the
---whole field or stand at its edge.
DroneCamField = {}

---Step between samples when searching for an edge, in metres. An edge found
---between two samples is then narrowed down to about half a metre.
DroneCamField.STEP = 4
DroneCamField.REFINE_STEPS = 3

---Furthest an edge is searched for. Beyond this a field is treated as having
---no edge in that direction.
DroneCamField.MAX_DISTANCE = 500

---Directions sampled when measuring the whole field.
DroneCamField.PROBE_DIRECTIONS = 8

---@return boolean|nil @Whether the point is on a field; nil when the game cannot say
function DroneCamField.getIsOnField(x, z)
    if FSDensityMapUtil == nil or FSDensityMapUtil.getFieldDataAtWorldPosition == nil then
        return nil
    end

    local isOnField = FSDensityMapUtil.getFieldDataAtWorldPosition(x, 0, z)
    return isOnField == true
end

---Distance from a point on a field to the field's edge in a direction.
---@param dirX number @Unit direction
---@param dirZ number
---@param maxDistance number|nil
---@return number|nil @Metres to the edge, nil if off-field or no edge within range
function DroneCamField.getEdgeDistance(x, z, dirX, dirZ, maxDistance)
    if DroneCamField.getIsOnField(x, z) ~= true then
        return nil
    end

    maxDistance = maxDistance or DroneCamField.MAX_DISTANCE
    local step = DroneCamField.STEP
    local distance = step

    while distance <= maxDistance do
        if not DroneCamField.getIsOnField(x + dirX * distance, z + dirZ * distance) then
            local inside, outside = distance - step, distance
            for _ = 1, DroneCamField.REFINE_STEPS do
                local middle = (inside + outside) * 0.5
                if DroneCamField.getIsOnField(x + dirX * middle, z + dirZ * middle) then
                    inside = middle
                else
                    outside = middle
                end
            end
            return outside
        end

        distance = distance + step
    end

    return nil
end

---Rough centre and size of the field around a point, from its edges in
---several directions.
---@return table|nil @{x, z, radius}, nil if the point is not on a field
function DroneCamField.probe(x, z)
    if DroneCamField.getIsOnField(x, z) ~= true then
        return nil
    end

    local count = DroneCamField.PROBE_DIRECTIONS
    local points = {}
    local sumX, sumZ = 0, 0

    for i = 1, count do
        local angle = (i - 1) * 2 * math.pi / count
        local dirX, dirZ = math.sin(angle), math.cos(angle)
        local distance = DroneCamField.getEdgeDistance(x, z, dirX, dirZ) or DroneCamField.MAX_DISTANCE
        local px, pz = x + dirX * distance, z + dirZ * distance

        points[i] = { px, pz }
        sumX, sumZ = sumX + px, sumZ + pz
    end

    local centreX, centreZ = sumX / count, sumZ / count
    local radius = 0
    for i = 1, count do
        local dx, dz = points[i][1] - centreX, points[i][2] - centreZ
        radius = math.max(radius, math.sqrt(dx * dx + dz * dz))
    end

    return { x = centreX, z = centreZ, radius = radius }
end
