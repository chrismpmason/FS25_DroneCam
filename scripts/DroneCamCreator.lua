---@class DroneCamCreator
---The creator shots: the kind of framing a drone pilot or a cameraman on the
---ground would set up, as opposed to the drone simply following along.
---
---Shots that hold a framing:
---  Establishing   high over the whole field, drifting slowly round it
---  Long lens      a fixed spot far off, zoomed in tight on the vehicle
---  Field-edge pan a fixed spot just outside the field edge, panning to follow
---  Headland       a fixed spot past the end of the row, the vehicle turning
---                 towards it
---Shots that travel along a path over their length:
---  Push-in        from 150m away and high, flying in to the chase position
---  Pull-out       from close in front, rising and pulling back
---  Fly-over       along the vehicle's line, over it from front to back
---  Rise-up        from low behind, climbing to top-down
---  Slide          far out to the side, sliding past
---
---Every fixed spot is checked before the shot is offered: not inside or under a
---tree or building, and with a clear line of sight to the vehicle. If no spot
---passes, the shot is simply not available and the director picks another.
---While a fixed shot is on screen its sight line keeps being checked; if it
---stays blocked the shot is marked lost and the director moves on.
DroneCamCreator = {}

local S = DroneCamSettings

DroneCamCreator.ESTABLISHING_MIN_RADIUS = 40
---Beyond this a field is too big to take in at once anyway; framing a bigger
---one would only put the drone further off than a glide can reach calmly.
DroneCamCreator.ESTABLISHING_MAX_RADIUS = 250
---Used when the vehicle is not on a field (forced on, on a road).
DroneCamCreator.ESTABLISHING_FALLBACK_RADIUS = 120
DroneCamCreator.ESTABLISHING_DISTANCE_FACTOR = 1.2
DroneCamCreator.ESTABLISHING_MIN_DISTANCE = 90
DroneCamCreator.ESTABLISHING_HEIGHT_FACTOR = 0.7
DroneCamCreator.ESTABLISHING_MIN_HEIGHT = 60
DroneCamCreator.ESTABLISHING_DRIFT = math.rad(1.5)
---How far the aim leans from the field's centre towards the vehicle, so the
---vehicle is always somewhere in the shot.
DroneCamCreator.ESTABLISHING_VEHICLE_WEIGHT = 0.35

DroneCamCreator.LONG_LENS_DISTANCE = 150
DroneCamCreator.LONG_LENS_HEIGHT = 8
DroneCamCreator.LONG_LENS_MIN_FOV = 6
---Bearings tried for the long lens, in degrees off the vehicle's heading.
---Front quarters first, so the vehicle comes towards the lens.
DroneCamCreator.LONG_LENS_BEARINGS = { 40, 65, 100, 130 }

DroneCamCreator.EDGE_PAN_HEIGHT = 3
---How far past the field edge the camera stands: on the hedge line.
DroneCamCreator.EDGE_PAN_SETBACK = 3
DroneCamCreator.EDGE_PAN_MAX_DISTANCE = 250
---Offsets along the vehicle's line tried for the edge spot. Ahead first, so
---the vehicle drives towards and past the camera.
DroneCamCreator.EDGE_PAN_OFFSETS = { 20, 35, 5, 50, -10 }

DroneCamCreator.HEADLAND_HEIGHT = 3.5
---Spots tried past the end of the row: how far past it, and how far off the
---vehicle's line to either side. Several of each, since gateways, barns and
---hedges often stand right at the end of a field.
DroneCamCreator.HEADLAND_SETBACKS = { 6, 12, 20 }
DroneCamCreator.HEADLAND_OFFSETS = { 10, 18, 28, 40 }
---The headland shot is only offered while the end of the row is between
---these distances and no more than HEADLAND_MAX_ETA seconds away.
DroneCamCreator.HEADLAND_MIN_DISTANCE = 25
DroneCamCreator.HEADLAND_MAX_ETA = 14
DroneCamCreator.HEADLAND_MIN_SPEED = 0.5

---Fixed-spot shots never zoom wider than the configured field of view or
---tighter than this.
DroneCamCreator.SPOT_MIN_FOV = 20
DroneCamCreator.SLIDE_FOV = 35

---How often a fixed shot re-checks its sight line, and how long it may stay
---blocked before the shot is given up.
DroneCamCreator.SIGHT_CHECK_INTERVAL = 0.25
DroneCamCreator.SIGHT_LOST_TIME = 1

local function lerp(from, to, alpha)
    return from + (to - from) * alpha
end

local function smoothstep(t)
    t = math.min(math.max(t, 0), 1)
    return t * t * (3 - 2 * t)
end

---@return boolean
function DroneCamCreator.getIsCreatorShot(shot)
    return DroneCamDirector.getIsFixed(shot) or DroneCamDirector.getIsMoving(shot)
end

---@return boolean @True for shots that are planned from a fixed spot
function DroneCamCreator.getNeedsPlan(shot)
    return DroneCamDirector.getIsFixed(shot)
end

---@return number, number, number @Point on the vehicle the creator shots aim at
local function getVehicleAim(vehicle)
    local x, y, z = getWorldTranslation(vehicle.rootNode)
    return x, y + DroneCamCamera.LOOK_HEIGHT_OFFSET, z
end

---@return number @Size the vehicle and its implements need in frame, in metres
local function getFramingSize(rig)
    return math.max(rig.front - rig.rear, rig.halfWidth * 2)
end

---Field of view that frames something of a given size at a given distance.
local function getFramingFov(distance, size, minFov, maxFov)
    local fov = math.deg(2 * math.atan(size * 0.5 / math.max(distance, 1)))
    return math.min(math.max(fov, minFov), maxFov)
end

local function getTerrainHeight(x, z, fallback)
    return DroneCamRig.getGroundHeight(x, z, fallback)
end

---@return number @1 or -1, the side to try first
local function pickFirstSide(camera)
    return camera.director.random() < 0.5 and -1 or 1
end

---Tries a list of candidate spots, returning the first that is clear and can
---see every aim point.
---@param candidates table @List of {x, y, z, ...extra}
---@param aims table @List of {x, y, z}: where the vehicle is and will be
local function findSpot(candidates, aims)
    for i = 1, #candidates do
        local c = candidates[i]
        if DroneCamSpot.getIsSpotClear(c.x, c.y, c.z) then
            local canSeeAll = true
            for j = 1, #aims do
                if not DroneCamSpot.getHasLineOfSight(c.x, c.y, c.z, aims[j][1], aims[j][2], aims[j][3]) then
                    canSeeAll = false
                    break
                end
            end
            if canSeeAll then
                return c
            end
        end
    end
    return nil
end

---How far ahead, in seconds of driving, a fixed spot must keep the vehicle in
---view: a spot that only sees where the vehicle is now would lose it behind
---the first tree.
DroneCamCreator.SIGHT_AHEAD_TIMES = { 0, 5, 10 }

---Aim points along the vehicle's coming path.
---@param distances table|nil @Metres ahead; by default from SIGHT_AHEAD_TIMES and its speed
local function getPathAims(camera, vehicle, distances)
    local x, y, z = getVehicleAim(vehicle)
    local fwdX, fwdZ = math.sin(camera.vehicleHeading), math.cos(camera.vehicleHeading)

    if distances == nil then
        distances = {}
        for i, seconds in ipairs(DroneCamCreator.SIGHT_AHEAD_TIMES) do
            distances[i] = seconds * (camera.vehicleSpeed or 0)
        end
    end

    local aims = {}
    for i, distance in ipairs(distances) do
        aims[i] = { x + fwdX * distance, y, z + fwdZ * distance }
    end
    return aims
end

local function planEstablishing(camera, vehicle, rig)
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    local aimX, aimY, aimZ = getVehicleAim(vehicle)

    local field = DroneCamField.probe(vx, vz)
    local centreX, centreZ, radius = vx, vz, DroneCamCreator.ESTABLISHING_FALLBACK_RADIUS
    if field ~= nil then
        centreX, centreZ = field.x, field.z
        radius = math.min(math.max(field.radius, DroneCamCreator.ESTABLISHING_MIN_RADIUS), DroneCamCreator.ESTABLISHING_MAX_RADIUS)
    end

    local ground = getTerrainHeight(centreX, centreZ, vy)
    local distance = math.max(radius * DroneCamCreator.ESTABLISHING_DISTANCE_FACTOR, DroneCamCreator.ESTABLISHING_MIN_DISTANCE)
    local height = math.max(radius * DroneCamCreator.ESTABLISHING_HEIGHT_FACTOR, DroneCamCreator.ESTABLISHING_MIN_HEIGHT)

    -- Start behind the vehicle's line of travel and work round both ways.
    local base = camera.heading + math.pi
    local first = pickFirstSide(camera)
    local candidates = {}
    for i = 0, 4 do
        for _, sign in ipairs({ first, -first }) do
            if i > 0 or sign == first then
                local bearing = base + sign * i * math.pi / 4
                local x = centreX + math.sin(bearing) * distance
                local z = centreZ + math.cos(bearing) * distance
                local y = math.max(ground + height, getTerrainHeight(x, z, vy) + DroneCamCreator.ESTABLISHING_MIN_HEIGHT * 0.5)
                candidates[#candidates + 1] = { x = x, y = y, z = z, bearing = bearing, height = y - ground }
            end
        end
    end

    local spot = findSpot(candidates, { { aimX, aimY, aimZ } })
    if spot == nil then
        return nil
    end

    return {
        shot = S.SHOT_ESTABLISHING,
        centreX = centreX, centreZ = centreZ, ground = ground,
        distance = distance, height = spot.height, bearing = spot.bearing,
        drift = DroneCamCreator.ESTABLISHING_DRIFT * (camera.director.random() < 0.5 and -1 or 1)
    }
end

local function planLongLens(camera, vehicle, rig)
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    local distance = DroneCamCreator.LONG_LENS_DISTANCE * math.min(math.max(rig.scale, 1), 2)
    local first = pickFirstSide(camera)

    local candidates = {}
    for _, offset in ipairs(DroneCamCreator.LONG_LENS_BEARINGS) do
        for _, sign in ipairs({ first, -first }) do
            local bearing = camera.heading + sign * math.rad(offset)
            local x, z = vx + math.sin(bearing) * distance, vz + math.cos(bearing) * distance
            local y = getTerrainHeight(x, z, vy) + DroneCamCreator.LONG_LENS_HEIGHT * math.max(rig.scale, 1)
            candidates[#candidates + 1] = { x = x, y = y, z = z }
        end
    end

    local spot = findSpot(candidates, getPathAims(camera, vehicle))
    if spot == nil then
        return nil
    end

    return { shot = S.SHOT_LONG_LENS, x = spot.x, y = spot.y, z = spot.z,
             frame = getFramingSize(rig) * 1.8 + 4 }
end

local function planEdgePan(camera, vehicle, rig)
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    if DroneCamField.getIsOnField(vx, vz) ~= true then
        return nil
    end

    local fwdX, fwdZ = math.sin(camera.heading), math.cos(camera.heading)
    local first = pickFirstSide(camera)

    local candidates = {}
    for _, sign in ipairs({ first, -first }) do
        local dirX, dirZ = fwdZ * sign, -fwdX * sign
        local edge = DroneCamField.getEdgeDistance(vx, vz, dirX, dirZ, DroneCamCreator.EDGE_PAN_MAX_DISTANCE)

        if edge ~= nil then
            local out = edge + DroneCamCreator.EDGE_PAN_SETBACK
            for _, along in ipairs(DroneCamCreator.EDGE_PAN_OFFSETS) do
                local x = vx + dirX * out + fwdX * along
                local z = vz + dirZ * out + fwdZ * along
                -- The edge is not straight: only keep spots that really are
                -- off the field.
                if DroneCamField.getIsOnField(x, z) == false then
                    candidates[#candidates + 1] = { x = x, y = getTerrainHeight(x, z, vy) + DroneCamCreator.EDGE_PAN_HEIGHT, z = z }
                end
            end
        end
    end

    local spot = findSpot(candidates, getPathAims(camera, vehicle))
    if spot == nil then
        return nil
    end

    return { shot = S.SHOT_EDGE_PAN, x = spot.x, y = spot.y, z = spot.z, frame = getFramingSize(rig) * 3 + 10 }
end

local function planHeadland(camera, vehicle, rig)
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    local speed = camera.vehicleSpeed or 0

    if speed < DroneCamCreator.HEADLAND_MIN_SPEED or DroneCamField.getIsOnField(vx, vz) ~= true then
        return nil
    end

    local fwdX, fwdZ = math.sin(camera.vehicleHeading), math.cos(camera.vehicleHeading)
    local reach = speed * DroneCamCreator.HEADLAND_MAX_ETA
    local edge = DroneCamField.getEdgeDistance(vx, vz, fwdX, fwdZ, reach)

    if edge == nil or edge < DroneCamCreator.HEADLAND_MIN_DISTANCE then
        return nil
    end

    local sideX, sideZ = fwdZ, -fwdX
    local first = pickFirstSide(camera)
    local candidates = {}

    for _, setback in ipairs(DroneCamCreator.HEADLAND_SETBACKS) do
        for _, offset in ipairs(DroneCamCreator.HEADLAND_OFFSETS) do
            for _, sign in ipairs({ first, -first }) do
                local across = sign * offset * math.max(rig.scale, 1)
                local x = vx + fwdX * (edge + setback) + sideX * across
                local z = vz + fwdZ * (edge + setback) + sideZ * across
                if DroneCamField.getIsOnField(x, z) == false then
                    candidates[#candidates + 1] = { x = x, y = getTerrainHeight(x, z, vy) + DroneCamCreator.HEADLAND_HEIGHT, z = z }
                end
            end
        end
    end

    -- The vehicle must stay in view all the way up to where it turns.
    local spot = findSpot(candidates, getPathAims(camera, vehicle, { 0, edge * 0.5, math.max(edge - 3, 0) }))
    if spot == nil then
        return nil
    end

    return { shot = S.SHOT_HEADLAND, x = spot.x, y = spot.y, z = spot.z, frame = getFramingSize(rig) * 3 + 10 }
end

local PLANNERS = {
    [S.SHOT_ESTABLISHING] = planEstablishing,
    [S.SHOT_LONG_LENS] = planLongLens,
    [S.SHOT_EDGE_PAN] = planEdgePan,
    [S.SHOT_HEADLAND] = planHeadland
}

---Finds a spot for a fixed shot.
---@return table|nil @The plan, or nil if there is nowhere good to put the camera
function DroneCamCreator.plan(camera, vehicle, shot)
    local planner = PLANNERS[shot]
    local rig = camera:getRig(vehicle)
    if planner == nil or rig == nil then
        return nil
    end

    local plan = planner(camera, vehicle, rig)
    if plan ~= nil then
        plan.sightTimer = 0
        plan.blockedTime = 0
        plan.isLost = false
    end
    return plan
end

---Re-checks a fixed shot's sight line every SIGHT_CHECK_INTERVAL seconds, from
---where the camera actually is.
function DroneCamCreator.updateSight(plan, dtSeconds, cameraX, cameraY, cameraZ, vehicle)
    if plan == nil then
        return
    end

    plan.sightTimer = plan.sightTimer + dtSeconds
    if plan.sightTimer < DroneCamCreator.SIGHT_CHECK_INTERVAL then
        return
    end

    local interval = plan.sightTimer
    plan.sightTimer = 0

    local aimX, aimY, aimZ = getVehicleAim(vehicle)
    if DroneCamSpot.getHasLineOfSight(cameraX, cameraY, cameraZ, aimX, aimY, aimZ) then
        plan.blockedTime = 0
    else
        plan.blockedTime = plan.blockedTime + interval
        if plan.blockedTime >= DroneCamCreator.SIGHT_LOST_TIME then
            plan.isLost = true
        end
    end
end

---Position along a moving shot's path in the vehicle's (smoothed) frame:
---across, along, height above the ground at the vehicle.
local function getMovingPath(camera, rig, shot, progress)
    local settings = camera.settings
    local scale = rig.scale
    local side = camera.shotSide
    local gap = DroneCamCamera.CLOSEUP_GAP
    local eased = smoothstep(progress)

    local topHeight = 0
    for i = 1, #rig.boxes do
        topHeight = math.max(topHeight, rig.boxes[i].ground + rig.boxes[i].height - rig.ground)
    end

    if shot == S.SHOT_PUSH_IN then
        return lerp(side * 30, 0, eased), lerp(-150, -settings.chaseDistance, eased), lerp(60, settings.chaseHeight, eased),
               lerp(0, settings.chaseLookAhead, eased)
    elseif shot == S.SHOT_PULL_OUT then
        local startAcross = side * (rig.halfWidth + math.max(gap, 3.5 * scale))
        return lerp(startAcross, side * 25 * scale, eased),
               lerp(rig.rootFront + 4 * scale, rig.front + 45 * scale, eased),
               lerp(1.8 * scale, 35 * scale, eased), 0
    elseif shot == S.SHOT_FLY_OVER then
        return side * 2, lerp(rig.front + 25 * scale, rig.rear - 25 * scale, eased), topHeight + 5 * scale, 0
    elseif shot == S.SHOT_RISE_UP then
        local startAlong = rig.rear - math.max(gap, 5 * scale)
        return 0, lerp(startAlong, 0, eased), lerp(2 * scale, settings.topDownHeight, eased), 0
    end

    -- Slide.
    return side * 70 * scale, lerp(40 * scale, -40 * scale, eased), 10 * scale, 0
end

---Camera transform for a creator shot.
---@return number, number, number, number, number, number @Position and look target
---@return number|nil, number|nil, number|nil @Yaw and pitch override, and its weight
function DroneCamCreator.getTransform(camera, vehicle, shot)
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    local aimX, aimY, aimZ = getVehicleAim(vehicle)
    local plan = camera.plan

    if DroneCamDirector.getIsFixed(shot) then
        if plan == nil or plan.shot ~= shot then
            -- Should not happen: fixed shots are only chosen with a plan.
            return vx, vy + camera.settings.chaseHeight, vz, aimX, aimY, aimZ, nil, nil, 0
        end

        if shot == S.SHOT_ESTABLISHING then
            local bearing = plan.bearing + plan.drift * camera.shotElapsed
            local w = DroneCamCreator.ESTABLISHING_VEHICLE_WEIGHT
            return plan.centreX + math.sin(bearing) * plan.distance,
                   plan.ground + plan.height,
                   plan.centreZ + math.cos(bearing) * plan.distance,
                   lerp(plan.centreX, aimX, w), lerp(plan.ground, aimY, w), lerp(plan.centreZ, aimZ, w),
                   nil, nil, 0
        end

        return plan.x, plan.y, plan.z, aimX, aimY, aimZ, nil, nil, 0
    end

    local rig = camera:getRig(vehicle)
    if rig == nil then
        return vx, vy + camera.settings.chaseHeight, vz, aimX, aimY, aimZ, nil, nil, 0
    end

    local progress = camera:getShotProgress()
    local across, along, height, lookAhead = getMovingPath(camera, rig, shot, progress)

    -- Moving shots are framed on the smoothed heading like the wide angles, so
    -- a long path 150m out does not wag with every steering correction.
    local fwdX, fwdZ = math.sin(camera.heading), math.cos(camera.heading)
    local sideX, sideZ = fwdZ, -fwdX

    local px = vx + sideX * across + fwdX * along
    local pz = vz + sideZ * across + fwdZ * along
    local py = rig.ground + height

    local lookX, lookZ = aimX + fwdX * lookAhead, aimZ + fwdZ * lookAhead

    if shot == S.SHOT_RISE_UP then
        -- Ends exactly as the top-down angle does, heading-up and straight
        -- down; ease that rotation in late so the climb itself is aimed.
        local yaw = math.atan2(-fwdX, -fwdZ)
        if camera.settings.topDownNorthUp then
            yaw = 0
        end
        local weight = smoothstep(progress) ^ 3
        return px, py, pz, lookX, aimY, lookZ, yaw, -math.pi * 0.5, weight
    end

    return px, py, pz, lookX, aimY, lookZ, nil, nil, 0
end

---How tightly a creator shot rides along with the vehicle (0..1), and the
---lowest it may go above the terrain.
---@return number, number
function DroneCamCreator.getTracking(camera, shot)
    local settings = camera.settings
    local close = DroneCamCamera.CLOSEUP_CLEARANCE

    if shot == S.SHOT_ESTABLISHING or shot == S.SHOT_PUSH_IN or shot == S.SHOT_SLIDE then
        return 0, settings.minClearance
    elseif shot == S.SHOT_FLY_OVER then
        return 1, close
    elseif shot == S.SHOT_PULL_OUT or shot == S.SHOT_RISE_UP then
        local eased = smoothstep(camera:getShotProgress())
        return 1 - eased, lerp(close, settings.minClearance, eased)
    end

    -- Fixed spots near the ground: placed and checked when planned.
    return 0, close
end

---@return number @Field of view in degrees for a creator shot
function DroneCamCreator.getFov(camera, vehicle, shot)
    local fov = camera.settings.fov
    local plan = camera.plan

    if shot == S.SHOT_SLIDE then
        return math.min(DroneCamCreator.SLIDE_FOV, fov)
    end

    if plan ~= nil and plan.shot == shot and plan.frame ~= nil then
        local aimX, aimY, aimZ = getVehicleAim(vehicle)
        local dx, dy, dz = aimX - plan.x, aimY - plan.y, aimZ - plan.z
        local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
        local minFov = shot == S.SHOT_LONG_LENS and DroneCamCreator.LONG_LENS_MIN_FOV or DroneCamCreator.SPOT_MIN_FOV
        return getFramingFov(distance, plan.frame, minFov, fov)
    end

    return fov
end
