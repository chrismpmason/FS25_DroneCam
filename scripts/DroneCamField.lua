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

---Field size classes, see DroneCamField.getSizeClass.
DroneCamField.SIZE_SMALL = "small"
DroneCamField.SIZE_MEDIUM = "medium"
DroneCamField.SIZE_LARGE = "large"

---Outline of a game field as world coordinates, read once and kept: field
---outlines come from the map and do not move.
local outlineCache = setmetatable({}, { __mode = "k" })

local function getOutline(field)
    local outline = outlineCache[field]
    if outline ~= nil then
        return outline
    end

    local points = field.getPolygonPoints ~= nil and field:getPolygonPoints() or field.polygonPoints
    if points == nil or #points < 3 then
        return nil
    end

    outline = {}
    for i = 1, #points do
        local x, _, z = getWorldTranslation(points[i])
        outline[i] = { x, z }
    end
    outlineCache[field] = outline
    return outline
end

---@return boolean @True if the point is inside the outline (even-odd rule)
local function getIsInside(outline, x, z)
    local inside = false
    local j = #outline
    for i = 1, #outline do
        local xi, zi = outline[i][1], outline[i][2]
        local xj, zj = outline[j][1], outline[j][2]
        if (zi > z) ~= (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi then
            inside = not inside
        end
        j = i
    end
    return inside
end

---The game field the point lies in, from the game's own field data.
---@return table|nil
function DroneCamField.getGameField(x, z)
    local manager = g_fieldManager
    if manager == nil or manager.fields == nil then
        return nil
    end

    -- Quick route: the farmland at the point, and the field on it.
    if g_farmlandManager ~= nil and g_farmlandManager.getFarmlandAtWorldPosition ~= nil
        and manager.farmlandIdFieldMapping ~= nil then
        local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
        local field = farmland ~= nil and manager.farmlandIdFieldMapping[farmland.id] or nil
        local outline = field ~= nil and getOutline(field) or nil
        if outline ~= nil and getIsInside(outline, x, z) then
            return field
        end
    end

    for _, field in pairs(manager.fields) do
        local outline = getOutline(field)
        if outline ~= nil and getIsInside(outline, x, z) then
            return field
        end
    end

    return nil
end

---Size and shape of the game field the point lies in.
---@return table|nil @{field, areaHa, length (longest straight line across), centreX, centreZ}
function DroneCamField.getFieldInfo(x, z)
    local field = DroneCamField.getGameField(x, z)
    if field == nil then
        return nil
    end

    local outline = getOutline(field)
    local length = 0
    for i = 1, #outline do
        for j = i + 1, #outline do
            local dx, dz = outline[i][1] - outline[j][1], outline[i][2] - outline[j][2]
            length = math.max(length, math.sqrt(dx * dx + dz * dz))
        end
    end

    local centreX, centreZ
    if field.getCenterOfFieldWorldPosition ~= nil then
        centreX, centreZ = field:getCenterOfFieldWorldPosition()
    end
    if centreX == nil then
        centreX, centreZ = field.posX, field.posZ
    end
    if centreX == nil then
        local sumX, sumZ = 0, 0
        for i = 1, #outline do
            sumX, sumZ = sumX + outline[i][1], sumZ + outline[i][2]
        end
        centreX, centreZ = sumX / #outline, sumZ / #outline
    end

    return { field = field, areaHa = field.areaHa or 0, length = length, centreX = centreX, centreZ = centreZ }
end

---@param settings DroneCamSettings @fieldSmallHa and fieldLargeHa set the limits
---@return string @SIZE_SMALL, SIZE_MEDIUM or SIZE_LARGE; medium when there is no field
function DroneCamField.getSizeClass(info, settings)
    if info == nil then
        return DroneCamField.SIZE_MEDIUM
    end

    local small = settings.fieldSmallHa
    local large = math.max(settings.fieldLargeHa, small)
    if info.areaHa < small then
        return DroneCamField.SIZE_SMALL
    elseif info.areaHa > large then
        return DroneCamField.SIZE_LARGE
    end
    return DroneCamField.SIZE_MEDIUM
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
