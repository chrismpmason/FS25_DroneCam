---@class DroneCamRig
---Measures the controlled vehicle and everything attached to it, in the
---vehicle's own frame, so the close-up shots can be placed and scaled for a
---compact tractor and a combine with a 12m header alike.
---
---Also answers the question every close-up depends on: how low may the camera
---go at a given spot without ending up inside the vehicle.
DroneCamRig = {}

---Fallback footprint for vehicles that do not report a size.
DroneCamRig.DEFAULT_WIDTH = 3
DroneCamRig.DEFAULT_LENGTH = 5
DroneCamRig.DEFAULT_HEIGHT = 3

---The camera is never allowed within this distance of a vehicle's box unless
---it is above the box by the same margin. Comfortably more than the camera's
---0.5m near clip plane.
DroneCamRig.HARD_MARGIN = 0.6

---Beyond the hard margin, the required height eases down to the ground over
---this distance, so a camera passing close to a vehicle rises over it in a
---smooth arc instead of jumping.
DroneCamRig.SOFT_FADE = 1.2

---Reference size for scale 1: a mid-sized tractor about 5m long and 3m tall.
DroneCamRig.REFERENCE_LENGTH = 5
DroneCamRig.REFERENCE_HEIGHT = 3
DroneCamRig.REFERENCE_WIDTH = 6
DroneCamRig.MIN_SCALE = 0.7
DroneCamRig.MAX_SCALE = 3

---@return integer|nil
local function getTerrainNode()
    if g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
        return g_currentMission.terrainRootNode
    end
    return g_terrainNode
end

---@return number @Terrain height at the position, or the fallback when there is no terrain
function DroneCamRig.getGroundHeight(x, z, fallback)
    local terrainNode = getTerrainNode()
    if terrainNode == nil then
        return fallback or 0
    end
    return getTerrainHeightAtWorldPos(terrainNode, x, 0, z)
end

---@return number, number @Horizontal unit vector, or nil when the node points straight up or down
local function getHorizontalDirection(node, lx, lz)
    local dx, _, dz = localDirectionToWorld(node, lx, 0, lz)
    local length = math.sqrt(dx * dx + dz * dz)
    if length < 0.0001 then
        return nil, nil
    end
    return dx / length, dz / length
end

---World position to the rig's frame: x across (positive to the rig's side
---vector), z along (positive ahead of the controlled vehicle's root).
function DroneCamRig.toLocal(rig, wx, wz)
    local dx, dz = wx - rig.x, wz - rig.z
    return dx * rig.sideX + dz * rig.sideZ, dx * rig.fwdX + dz * rig.fwdZ
end

function DroneCamRig.toWorld(rig, lx, lz)
    return rig.x + rig.sideX * lx + rig.fwdX * lz, rig.z + rig.sideZ * lx + rig.fwdZ * lz
end

---Footprint of one vehicle as an oriented box on the ground.
local function getVehicleBox(vehicle)
    local size = vehicle.size or {}
    local width = size.width or DroneCamRig.DEFAULT_WIDTH
    local length = size.length or DroneCamRig.DEFAULT_LENGTH
    local height = size.height or DroneCamRig.DEFAULT_HEIGHT

    local fx, fz = getHorizontalDirection(vehicle.rootNode, 0, 1)
    if fx == nil then
        return nil
    end
    -- Local +X, whichever side the engine puts it on, so widthOffset lands on
    -- the side the vehicle's XML means.
    local sx, sz = getHorizontalDirection(vehicle.rootNode, 1, 0)
    if sx == nil then
        sx, sz = fz, -fx
    end

    local rx, ry, rz = getWorldTranslation(vehicle.rootNode)
    local lengthOffset, widthOffset = size.lengthOffset or 0, size.widthOffset or 0
    local cx = rx + fx * lengthOffset + sx * widthOffset
    local cz = rz + fz * lengthOffset + sz * widthOffset

    return {
        cx = cx, cz = cz,
        fx = fx, fz = fz, sx = sx, sz = sz,
        halfLength = length * 0.5,
        halfWidth = width * 0.5,
        ground = DroneCamRig.getGroundHeight(cx, cz, ry),
        height = height
    }
end

---@return boolean
local function getIsRidgeMarker(workArea)
    return WorkAreaType ~= nil and WorkAreaType.RIDGEMARKER ~= nil and workArea.type == WorkAreaType.RIDGEMARKER
end

---Collects the corners of the work areas that touch the ground or crop. When
---some areas are working right now only those count, so a folded side section
---or an idle implement does not stretch the shot.
local function getWorkCorners(vehicles)
    local all, processing = {}, {}

    for i = 1, #vehicles do
        local vehicle = vehicles[i]
        local spec = vehicle.spec_workArea

        if spec ~= nil and spec.workAreas ~= nil then
            for j = 1, #spec.workAreas do
                local workArea = spec.workAreas[j]
                local nodes = { workArea.start, workArea.width, workArea.height }

                if nodes[1] ~= nil and nodes[2] ~= nil and nodes[3] ~= nil
                    and entityExists(nodes[1]) and entityExists(nodes[2]) and entityExists(nodes[3])
                    and not getIsRidgeMarker(workArea) then

                    local isProcessing = vehicle.getIsWorkAreaProcessing ~= nil and vehicle:getIsWorkAreaProcessing(workArea)

                    for k = 1, 3 do
                        local x, _, z = getWorldTranslation(nodes[k])
                        all[#all + 1] = { x, z }
                        if isProcessing then
                            processing[#processing + 1] = { x, z }
                        end
                    end
                end
            end
        end
    end

    return #processing > 0 and processing or all
end

---Rear-most wheel centres of the controlled vehicle, one per side.
local function getWheels(rig, vehicle)
    local wheels = {}
    local spec = vehicle.spec_wheels

    if spec == nil or spec.wheels == nil then
        return wheels
    end

    for i = 1, #spec.wheels do
        local wheel = spec.wheels[i]
        local node = wheel.driveNode or wheel.repr or wheel.node

        if node ~= nil and entityExists(node) then
            local x, y, z = getWorldTranslation(node)
            local lx, lz = DroneCamRig.toLocal(rig, x, z)
            local radius = (wheel.physics ~= nil and wheel.physics.radius) or wheel.radius or 0.5
            -- The axle runs at hub height: the wheel centre above the ground.
            local hub = y - DroneCamRig.getGroundHeight(x, z, y - radius)

            wheels[#wheels + 1] = { lx = lx, lz = lz, y = y, radius = radius, hub = hub, vehicle = vehicle }

            -- Every node of the wheel, so a raycast hitting it is known for one.
            for _, part in ipairs({ wheel.node, wheel.repr, wheel.driveNode, wheel.linkNode }) do
                if part ~= nil and part ~= 0 then
                    rig.wheelNodes[part] = true
                end
            end
        end
    end

    return wheels
end

---Measures the vehicle combination.
---@param vehicle table @Controlled (root) vehicle
---@param heading number @Its heading in radians; the rig's forward axis
---@return table|nil
function DroneCamRig.measure(vehicle, heading)
    if vehicle == nil or vehicle.rootNode == nil then
        return nil
    end

    local x, y, z = getWorldTranslation(vehicle.rootNode)
    local fwdX, fwdZ = math.sin(heading), math.cos(heading)

    local rig = {
        x = x, y = y, z = z,
        fwdX = fwdX, fwdZ = fwdZ,
        sideX = fwdZ, sideZ = -fwdX,
        ground = DroneCamRig.getGroundHeight(x, z, y),
        boxes = {},
        wheelNodes = {}
    }

    local vehicles = vehicle.getChildVehicles ~= nil and vehicle:getChildVehicles() or { vehicle }

    local front, rear, halfWidth = -math.huge, math.huge, 0

    for i = 1, #vehicles do
        local child = vehicles[i]

        if child.rootNode ~= nil and entityExists(child.rootNode) then
            local box = getVehicleBox(child)

            if box ~= nil then
                box.isRoot = child == vehicle
                box.vehicle = child
                rig.boxes[#rig.boxes + 1] = box

                for _, cornerX in ipairs({ -1, 1 }) do
                    for _, cornerZ in ipairs({ -1, 1 }) do
                        local wx = box.cx + box.sx * box.halfWidth * cornerX + box.fx * box.halfLength * cornerZ
                        local wz = box.cz + box.sz * box.halfWidth * cornerX + box.fz * box.halfLength * cornerZ
                        local lx, lz = DroneCamRig.toLocal(rig, wx, wz)

                        front, rear = math.max(front, lz), math.min(rear, lz)
                        halfWidth = math.max(halfWidth, math.abs(lx))

                        if child == vehicle then
                            rig.rootFront = math.max(rig.rootFront or -math.huge, lz)
                            rig.rootRear = math.min(rig.rootRear or math.huge, lz)
                            rig.rootHalfWidth = math.max(rig.rootHalfWidth or 0, math.abs(lx))
                        end
                    end
                end

                if child == vehicle then
                    rig.rootHeight = box.height
                end
            end
        end
    end

    if #rig.boxes == 0 then
        return nil
    end

    -- Defaults only matter if the controlled vehicle is missing from its own
    -- child list, which the game does not do.
    rig.rootFront = rig.rootFront or DroneCamRig.DEFAULT_LENGTH * 0.5
    rig.rootRear = rig.rootRear or -DroneCamRig.DEFAULT_LENGTH * 0.5
    rig.rootHalfWidth = rig.rootHalfWidth or DroneCamRig.DEFAULT_WIDTH * 0.5
    rig.rootHeight = rig.rootHeight or DroneCamRig.DEFAULT_HEIGHT

    rig.front, rig.rear, rig.halfWidth = front, rear, halfWidth

    -- Front-mounted (weights, a header, a front mower) or behind.
    for i = 1, #rig.boxes do
        local box = rig.boxes[i]
        local _, centreAlong = DroneCamRig.toLocal(rig, box.cx, box.cz)
        box.centreAlong = centreAlong
        box.isFront = not box.isRoot and centreAlong >= rig.rootRear
    end

    local rootLength = rig.rootFront - rig.rootRear
    rig.scale = math.min(math.max(
        rootLength / DroneCamRig.REFERENCE_LENGTH,
        rig.rootHeight / DroneCamRig.REFERENCE_HEIGHT,
        halfWidth * 2 / DroneCamRig.REFERENCE_WIDTH,
        DroneCamRig.MIN_SCALE), DroneCamRig.MAX_SCALE)

    local corners = getWorkCorners(vehicles)
    if #corners > 0 then
        local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
        for i = 1, #corners do
            local lx, lz = DroneCamRig.toLocal(rig, corners[i][1], corners[i][2])
            minX, maxX = math.min(minX, lx), math.max(maxX, lx)
            minZ, maxZ = math.min(minZ, lz), math.max(maxZ, lz)
        end

        rig.work = {
            lx = (minX + maxX) * 0.5,
            lz = (minZ + maxZ) * 0.5,
            halfWidth = (maxX - minX) * 0.5,
            -- A combine header or front mower works ahead of the vehicle root.
            isFront = (minZ + maxZ) * 0.5 > 0
        }
    end

    rig.wheels = getWheels(rig, vehicle)

    -- Everything else's wheels: the drive-over's line must miss them too.
    rig.trainWheels = {}
    for i = 1, #vehicles do
        if vehicles[i] ~= vehicle and vehicles[i].rootNode ~= nil and entityExists(vehicles[i].rootNode) then
            for _, wheel in ipairs(getWheels(rig, vehicles[i])) do
                rig.trainWheels[#rig.trainWheels + 1] = wheel
            end
        end
    end

    return rig
end

---Footprints of a whole combination (another vehicle nearby), as boxes, for
---keeping the camera out of it. Nothing else is measured.
---@return table
function DroneCamRig.getVehicleBoxes(vehicle)
    local boxes = {}
    local children = vehicle.getChildVehicles ~= nil and vehicle:getChildVehicles() or { vehicle }
    for i = 1, #children do
        local child = children[i]
        if child.rootNode ~= nil and entityExists(child.rootNode) then
            local box = getVehicleBox(child)
            if box ~= nil then
                box.vehicle = child
                boxes[#boxes + 1] = box
            end
        end
    end
    return boxes
end

---Rear-most wheel on the given side of the controlled vehicle, estimated from
---its size if it reports no wheels.
---@param side number @1 or -1, in the rig's local x
---@return table @{lx, lz, radius}
function DroneCamRig.getRearWheel(rig, side)
    local best = nil

    for i = 1, #rig.wheels do
        local wheel = rig.wheels[i]
        if wheel.lx * side > 0 and (best == nil or wheel.lz < best.lz) then
            best = wheel
        end
    end

    if best ~= nil then
        return best
    end

    local radius = 0.6 * rig.scale
    return { lx = side * (rig.rootHalfWidth - radius * 0.5), lz = rig.rootRear + radius * 1.5, radius = radius }
end

---Horizontal distance from a point to a box's footprint; 0 inside it.
local function getDistanceOutside(box, x, z)
    local dx, dz = x - box.cx, z - box.cz
    local along = math.abs(dx * box.fx + dz * box.fz) - box.halfLength
    local across = math.abs(dx * box.sx + dz * box.sz) - box.halfWidth

    along, across = math.max(along, 0), math.max(across, 0)

    return math.sqrt(along * along + across * across)
end

---Lowest height the camera may have at (x, z) without being inside, or
---within the hard margin of, any vehicle in the rig.
---@param soft boolean @Also ease the requirement down over SOFT_FADE beyond the margin
---@param skipTrain boolean|nil @Ignore every vehicle in the train (the drive-over goes under all of it)
---@return number @Minimum world height, or -math.huge where nothing applies
function DroneCamRig.getVehicleFloor(rig, x, z, soft, skipTrain)
    local floor = -math.huge
    local margin = DroneCamRig.HARD_MARGIN
    local fade = DroneCamRig.SOFT_FADE

    for i = 1, #rig.boxes do
        local box = rig.boxes[i]

        if not skipTrain then
            local distance = getDistanceOutside(box, x, z)
            local top = box.ground + box.height + margin

            if distance <= margin then
                floor = math.max(floor, top)
            elseif soft and distance < margin + fade then
                floor = math.max(floor, top - (distance - margin) / fade * (top - box.ground))
            end
        end
    end

    return floor
end

---@param soft boolean @Count the eased zone beyond the margin as well
---@param skipTrain boolean|nil @Ignore every vehicle in the train
---@return boolean @True if the point is below the vehicle floor at its position
function DroneCamRig.getIsInsideVehicle(rig, x, y, z, soft, skipTrain)
    return y < DroneCamRig.getVehicleFloor(rig, x, z, soft, skipTrain)
end
