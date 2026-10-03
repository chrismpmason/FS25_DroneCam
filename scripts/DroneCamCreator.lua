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

---Drive-over: the camera sits on the ground in the vehicle's path, the vehicle
---drives over it, the camera swings round to watch it go and then rises into
---the chase position before anything towed behind can reach it.
DroneCamCreator.DRIVE_OVER_HEIGHT = 0.3
---The underside must clear the lens by this much as well (the near clip
---plane is pulled in to 0.05m for the shot).
DroneCamCreator.DRIVE_OVER_HEADROOM = 0.25
DroneCamCreator.DRIVE_OVER_NEAR_CLIP = 0.05
---How far ahead of the vehicle's front the camera goes: about nine seconds of
---driving, kept within 30-40m.
DroneCamCreator.DRIVE_OVER_LEAD_TIME = 9
DroneCamCreator.DRIVE_OVER_MIN_DISTANCE = 30
DroneCamCreator.DRIVE_OVER_MAX_DISTANCE = 40
---Longest the approach may take. With the 30m minimum distance this also sets
---the slowest speed the shot is used at: 2 m/s (7 km/h).
DroneCamCreator.DRIVE_OVER_MAX_APPROACH = 15
---Standing crop taller than this would hide the lens.
DroneCamCreator.DRIVE_OVER_MAX_CROP = 0.25
---The ground the vehicle rolls over at the camera must be this level, or its
---underside comes closer than measured.
DroneCamCreator.DRIVE_OVER_MAX_BUMP = 0.1
---Upward raycasts that measure the underside: every PROFILE_STEP metres from
---PROFILE_OVERHANG behind the vehicle to PROFILE_OVERHANG in front, at each
---of the PROFILE_ACROSS offsets from the centre line.
DroneCamCreator.DRIVE_OVER_PROFILE_STEP = 0.25
DroneCamCreator.DRIVE_OVER_PROFILE_OVERHANG = 1
DroneCamCreator.DRIVE_OVER_PROFILE_ACROSS = { -0.2, 0, 0.2 }
---Something towed behind needs a clear gap in front of it this long, empty
---all the way up on the centreline (no drawbar, top link or PTO shaft), to
---rise through.
DroneCamCreator.DRIVE_OVER_MIN_GAP = 2.5
---Height above whatever is towed that the camera rises to, and how close that
---may come before the camera must be up: a fixed margin plus a little per m/s.
DroneCamCreator.DRIVE_OVER_RISE_CLEARANCE = 0.8
DroneCamCreator.DRIVE_OVER_SAFE_DISTANCE = 1
DroneCamCreator.DRIVE_OVER_SAFE_PER_SPEED = 0.3
---Average climbing speed the rise may need; a tighter gap makes the shot
---unavailable rather than letting the camera shoot upwards.
DroneCamCreator.DRIVE_OVER_MAX_CLIMB = 4
DroneCamCreator.DRIVE_OVER_MIN_RISE_HEIGHT = 2.5
---Behind the vehicle's own rear by this much before the camera starts to rise.
DroneCamCreator.DRIVE_OVER_REAR_CLEARANCE = 0.3
DroneCamCreator.DRIVE_OVER_RISE_TIME = 1.2
---The "under" phase starts when the front is this far off: the view is held
---and tilts up to the underside instead of following the front overhead.
DroneCamCreator.DRIVE_OVER_UNDER_LEAD = 3
DroneCamCreator.DRIVE_OVER_UNDER_PITCH = math.rad(35)
DroneCamCreator.DRIVE_OVER_SWING_TIME = 1.4
---The swing turns faster than the usual 120 deg/s cap allows.
DroneCamCreator.DRIVE_OVER_SWING_YAW_RATE = math.rad(220)
DroneCamCreator.DRIVE_OVER_JOIN_TIME = 2.5
DroneCamCreator.DRIVE_OVER_TAIL_TIME = 5
---Abort while still well ahead if the vehicle stops or leaves the line.
DroneCamCreator.DRIVE_OVER_COMMIT_DISTANCE = 6
DroneCamCreator.DRIVE_OVER_STOP_SPEED = 0.5
DroneCamCreator.DRIVE_OVER_STOP_TIME = 2
DroneCamCreator.DRIVE_OVER_MAX_OFF_LINE = 0.5
---Room needed before a field edge, beyond the drive-over itself.
DroneCamCreator.DRIVE_OVER_EDGE_MARGIN = 20

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
    return DroneCamDirector.getIsFixed(shot) or DroneCamDirector.getIsMoving(shot) or DroneCamDirector.getIsHero(shot)
end

---@return boolean @True for shots that are planned from a fixed spot
function DroneCamCreator.getNeedsPlan(shot)
    return DroneCamDirector.getIsFixed(shot) or DroneCamDirector.getIsHero(shot)
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

---Front edge (rig-local along) of whatever is towed behind the controlled
---vehicle, and the height of its top above the ground at the vehicle.
---@return number|nil, number
local function getTowedFront(rig)
    local front, top = nil, 0

    for i = 1, #rig.boxes do
        local box = rig.boxes[i]
        if not box.isRoot then
            local _, centreAlong = DroneCamRig.toLocal(rig, box.cx, box.cz)
            local alongExtent = math.abs(box.fx * rig.fwdX + box.fz * rig.fwdZ) * box.halfLength
                + math.abs(box.sx * rig.fwdX + box.sz * rig.fwdZ) * box.halfWidth
            if centreAlong < rig.rootRear then
                local edge = centreAlong + alongExtent
                front = front == nil and edge or math.max(front, edge)
                top = math.max(top, box.ground + box.height - rig.ground)
            end
        end
    end

    return front, top
end

---@return boolean @True if anything other than the controlled vehicle sits ahead of its rear (a header, a front mower)
local function getHasFrontImplement(rig)
    for i = 1, #rig.boxes do
        local box = rig.boxes[i]
        if not box.isRoot then
            local _, centreAlong = DroneCamRig.toLocal(rig, box.cx, box.cz)
            if centreAlong >= rig.rootRear then
                return true
            end
        end
    end
    return false
end

local function planDriveOver(camera, vehicle, rig)
    local director = camera.director
    local speed = camera.vehicleSpeed or 0

    -- A straight run at a steady working speed.
    if director == nil or not director.isRunning or director:getIsTurning()
        or director.straightTime < DroneCamDirector.STRAIGHT_SETTLE_TIME then
        return nil
    end
    if speed <= 0 then
        return nil
    end

    -- Nothing out in front to run into the camera first.
    if getHasFrontImplement(rig) then
        return nil
    end

    local distance = math.min(math.max(speed * DroneCamCreator.DRIVE_OVER_LEAD_TIME, DroneCamCreator.DRIVE_OVER_MIN_DISTANCE),
                              DroneCamCreator.DRIVE_OVER_MAX_DISTANCE)
    if distance / speed > DroneCamCreator.DRIVE_OVER_MAX_APPROACH then
        return nil
    end

    -- Centred between the rear wheels.
    local left, right = DroneCamRig.getRearWheel(rig, -1), DroneCamRig.getRearWheel(rig, 1)
    local centreAcross = (left.lx + right.lx) * 0.5
    local function world(across, along)
        return DroneCamRig.toWorld(rig, across, along)
    end

    -- The underside along the camera's line must clear the lens: the whole
    -- length and a little past each end (weights and hitches stick out past
    -- the nominal size), and a little either side of the centre.
    local height = DroneCamCreator.DRIVE_OVER_HEIGHT
    local needed = height + DroneCamCreator.DRIVE_OVER_HEADROOM
    local along = rig.rootRear - DroneCamCreator.DRIVE_OVER_PROFILE_OVERHANG
    while along <= rig.rootFront + DroneCamCreator.DRIVE_OVER_PROFILE_OVERHANG do
        for _, offset in ipairs(DroneCamCreator.DRIVE_OVER_PROFILE_ACROSS) do
            local x, z = world(centreAcross + offset, along)
            local clearance = DroneCamSpot.getVehicleClearance(x, getTerrainHeight(x, z, rig.ground), z, needed + 1)
            if clearance == nil or clearance < needed then
                return nil
            end
        end
        along = along + DroneCamCreator.DRIVE_OVER_PROFILE_STEP
    end

    -- Anything towed needs a clear gap to rise through, and time to do it.
    local towedFront, towedTop = getTowedFront(rig)
    local riseHeight = math.max(towedTop + DroneCamCreator.DRIVE_OVER_RISE_CLEARANCE, DroneCamCreator.DRIVE_OVER_MIN_RISE_HEIGHT)
    local safeDistance = DroneCamCreator.DRIVE_OVER_SAFE_DISTANCE + DroneCamCreator.DRIVE_OVER_SAFE_PER_SPEED * speed

    if towedFront ~= nil then
        local gap = rig.rootRear - towedFront
        if gap < DroneCamCreator.DRIVE_OVER_MIN_GAP then
            return nil
        end

        local riseStart = gap - DroneCamCreator.DRIVE_OVER_REAR_CLEARANCE
        local climbTime = (riseStart - safeDistance) / speed
        if climbTime <= 0 or (riseHeight - height) / climbTime > DroneCamCreator.DRIVE_OVER_MAX_CLIMB then
            return nil
        end

        local a = towedFront + 0.1
        while a <= rig.rootRear - 0.1 do
            local x, z = world(centreAcross, a)
            local clearance = DroneCamSpot.getVehicleClearance(x, getTerrainHeight(x, z, rig.ground), z, riseHeight)
            if clearance == nil or clearance < riseHeight then
                return nil
            end
            a = a + DroneCamCreator.DRIVE_OVER_PROFILE_STEP
        end
    end

    local spotAlong = rig.rootFront + distance
    local x, z = world(centreAcross, spotAlong)
    local ground = getTerrainHeight(x, z, rig.ground)
    local y = ground + height

    -- Level ground where the vehicle rolls over the camera.
    local fwdX, fwdZ = rig.fwdX, rig.fwdZ
    for _, offset in ipairs({ -1.5, -0.75, 0.75, 1.5 }) do
        local bump = getTerrainHeight(x + fwdX * offset, z + fwdZ * offset, ground) - ground
        if math.abs(bump) > DroneCamCreator.DRIVE_OVER_MAX_BUMP then
            return nil
        end
    end

    -- No standing crop to hide the lens, at the spot or on the way to it.
    local step = 2
    local sampled = 0
    while sampled <= distance + 2 do
        local cx, cz = world(centreAcross, rig.rootFront + sampled)
        if DroneCamCamera.getCropHeightAt(cx, cz) > DroneCamCreator.DRIVE_OVER_MAX_CROP then
            return nil
        end
        sampled = sampled + step
    end

    -- Not in or under anything, and able to see the vehicle coming.
    local frontX, frontZ = world(centreAcross, rig.rootFront)
    local frontY = rig.ground + rig.rootHeight * 0.4
    if not DroneCamSpot.getIsSpotClear(x, y, z, height - 0.05)
        or not DroneCamSpot.getHasLineOfSight(x, y, z, frontX, frontY, frontZ, 0.1) then
        return nil
    end

    -- No headland turn before it is all over.
    local runOut = distance + (rig.front - rig.rear)
        + speed * (DroneCamCreator.DRIVE_OVER_SWING_TIME + DroneCamCreator.DRIVE_OVER_RISE_TIME
                   + DroneCamCreator.DRIVE_OVER_JOIN_TIME + DroneCamCreator.DRIVE_OVER_TAIL_TIME)
        + DroneCamCreator.DRIVE_OVER_EDGE_MARGIN
    local vx, _, vz = getWorldTranslation(vehicle.rootNode)
    if DroneCamField.getIsOnField(vx, vz) == true
        and DroneCamField.getEdgeDistance(vx, vz, fwdX, fwdZ, runOut) ~= nil then
        return nil
    end

    return {
        shot = S.SHOT_DRIVE_OVER,
        x = x, y = y, z = z, ground = ground,
        centreAcross = centreAcross,
        riseHeight = riseHeight,
        safeDistance = safeDistance,
        phase = "approach",
        stopTime = 0, swingTime = 0, riseTime = 0, riseProgress = 0, joinTime = 0, tailTime = 0,
        isDone = false
    }
end

local PLANNERS = {
    [S.SHOT_ESTABLISHING] = planEstablishing,
    [S.SHOT_LONG_LENS] = planLongLens,
    [S.SHOT_EDGE_PAN] = planEdgePan,
    [S.SHOT_HEADLAND] = planHeadland,
    [S.SHOT_DRIVE_OVER] = planDriveOver
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
    if plan == nil or plan.shot == S.SHOT_DRIVE_OVER then
        -- The drive-over watches its own approach (updateDriveOver).
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

---@return boolean @True while the drive-over has the camera down by the vehicle, before it joins the chase
function DroneCamCreator.getIsDriveOverLow(camera)
    local plan = camera.plan
    return camera.shot == S.SHOT_DRIVE_OVER and camera.fromPose == nil and plan ~= nil
        and plan.shot == S.SHOT_DRIVE_OVER and plan.phase ~= "join" and plan.phase ~= "tail" and not plan.isDone
end

---How much of the gentle sway to apply: none while the drive-over has the
---camera placed to the centimetre, fading back in as it joins the chase.
---@return number @0..1
function DroneCamCreator.getSwayScale(camera)
    local plan = camera.plan
    if camera.shot ~= S.SHOT_DRIVE_OVER or camera.fromPose ~= nil or plan == nil or plan.shot ~= S.SHOT_DRIVE_OVER
        or plan.isDone or plan.phase == "tail" then
        return 1
    elseif plan.phase == "join" then
        return smoothstep(plan.joinTime / DroneCamCreator.DRIVE_OVER_JOIN_TIME)
    end
    return 0
end

---Advances the drive-over through its phases:
---  approach  the vehicle drives towards the camera
---  under     its front is close: hold the heading, tilt up to the underside
---  swing     it is overhead: turn round in DRIVE_OVER_SWING_TIME
---  rise      it has passed: climb clear of anything towed before it arrives
---  join      glide into the chase position
---  tail      hold the chase for a moment, then hand back to the director
function DroneCamCreator.updateDriveOver(camera, dtSeconds, vehicle)
    local plan = camera.plan
    if camera.shot ~= S.SHOT_DRIVE_OVER or plan == nil or plan.shot ~= S.SHOT_DRIVE_OVER
        or plan.isDone or plan.isLost then
        return
    end

    local rig = camera:getRig(vehicle)
    if rig == nil then
        return
    end

    local across, along = DroneCamRig.toLocal(rig, plan.x, plan.z)
    local speed = camera.vehicleSpeed or 0
    plan.along = along

    if plan.phase == "approach" or plan.phase == "under" then
        if along > rig.rootFront + DroneCamCreator.DRIVE_OVER_COMMIT_DISTANCE then
            -- Still well clear: give up if the vehicle stops, turns or leaves
            -- the line rather than wait for something that will not come.
            if speed < DroneCamCreator.DRIVE_OVER_STOP_SPEED then
                plan.stopTime = plan.stopTime + dtSeconds
            else
                plan.stopTime = 0
            end
            if plan.stopTime > DroneCamCreator.DRIVE_OVER_STOP_TIME
                or math.abs(across - plan.centreAcross) > DroneCamCreator.DRIVE_OVER_MAX_OFF_LINE
                or camera.director:getIsTurning() then
                plan.isLost = true
                return
            end
        end

        -- The swing is centred on the moment the middle of the vehicle is
        -- overhead. The tilt before it gets at least UNDER_LEAD metres of
        -- its own, however fast the vehicle is going.
        local middle = (rig.rootFront + rig.rootRear) * 0.5
        local swingStart = middle + speed * DroneCamCreator.DRIVE_OVER_SWING_TIME * 0.5
        local underStart = math.max(rig.rootFront, swingStart) + DroneCamCreator.DRIVE_OVER_UNDER_LEAD

        if plan.phase == "approach" and along <= underStart then
            plan.phase = "under"
            plan.underStart = along
            plan.underEnd = swingStart
            plan.yaw0 = camera.lastRotY or 0
            plan.pitch0 = camera.lastRotX or 0
        end

        if plan.phase == "under" and along <= plan.underEnd then
            plan.phase = "swing"
            plan.swingTime = 0
            plan.swingPitch = plan.underPitch or DroneCamCreator.DRIVE_OVER_UNDER_PITCH
        end
    elseif plan.phase == "swing" then
        plan.swingTime = plan.swingTime + dtSeconds
    end

    -- The rise starts once the vehicle itself has passed, swing or no swing,
    -- and is paced by whatever is towed so it is always up in time.
    if (plan.phase == "swing" or plan.phase == "rise") then
        if not plan.riseStarted and along <= rig.rootRear - DroneCamCreator.DRIVE_OVER_REAR_CLEARANCE then
            plan.riseStarted = true
            local towedFront = getTowedFront(rig)
            plan.riseStartGap = towedFront ~= nil and (along - towedFront) or nil
        end

        if plan.riseStarted then
            plan.riseTime = plan.riseTime + dtSeconds
            local progress = plan.riseTime / DroneCamCreator.DRIVE_OVER_RISE_TIME
            local towedFront = getTowedFront(rig)
            if plan.riseStartGap ~= nil and towedFront ~= nil then
                local span = math.max(plan.riseStartGap - plan.safeDistance, 0.01)
                progress = math.max(progress, (plan.riseStartGap - (along - towedFront)) / span)
            end
            plan.riseProgress = math.min(math.max(plan.riseProgress, progress), 1)
        end
    end

    if plan.phase == "swing" and plan.swingTime >= DroneCamCreator.DRIVE_OVER_SWING_TIME then
        plan.phase = "rise"
    end

    if plan.phase == "rise" and plan.riseProgress >= 1 then
        plan.phase = "join"
        plan.joinTime = 0
    elseif plan.phase == "join" then
        plan.joinTime = plan.joinTime + dtSeconds
        if plan.joinTime >= DroneCamCreator.DRIVE_OVER_JOIN_TIME then
            plan.phase = "tail"
            plan.tailTime = 0
        end
    elseif plan.phase == "tail" then
        plan.tailTime = plan.tailTime + dtSeconds
        if plan.tailTime >= DroneCamCreator.DRIVE_OVER_TAIL_TIME then
            plan.isDone = true
        end
    end
end

---Transform for the drive-over, phase by phase.
local function getDriveOverTransform(camera, vehicle, plan)
    local rig = camera:getRig(vehicle)
    local chaseX, chaseY, chaseZ, chaseLookX, chaseLookY, chaseLookZ = camera:getModeTransform(vehicle, S.MODE_CHASE)

    if rig == nil then
        return chaseX, chaseY, chaseZ, chaseLookX, chaseLookY, chaseLookZ, nil, nil, 0
    end

    local lookHeight = rig.ground + rig.rootHeight * 0.4
    local frontX, frontZ = DroneCamRig.toWorld(rig, plan.centreAcross, rig.rootFront)
    -- Watching it go: aim at the middle of the vehicle, not its rear face,
    -- which is right overhead just after it passes.
    local awayX, awayY, awayZ = getVehicleAim(vehicle)

    local riseY = plan.ground + plan.riseHeight
    local y = lerp(plan.y, riseY, smoothstep(plan.riseProgress))

    local phase = plan.phase
    if phase == "approach" then
        return plan.x, plan.y, plan.z, frontX, lookHeight, frontZ, nil, nil, 0
    end

    if phase == "under" then
        -- Hold the heading and tilt up as the front comes overhead.
        local span = math.max(plan.underStart - plan.underEnd, 0.01)
        local tilt = smoothstep((plan.underStart - (plan.along or plan.underStart)) / span)
        local pitch = lerp(plan.pitch0, DroneCamCreator.DRIVE_OVER_UNDER_PITCH, tilt)
        plan.underPitch = pitch
        return plan.x, plan.y, plan.z, frontX, lookHeight, frontZ, plan.yaw0, pitch, 1
    end

    if phase == "swing" then
        local t = math.min(plan.swingTime / DroneCamCreator.DRIVE_OVER_SWING_TIME, 1)
        local eased = smoothstep(t)
        local yaw = plan.yaw0 + camera.shotSide * math.pi * eased
        -- End the tilt exactly where aiming at the departing vehicle would put
        -- it, so the hand-over at the end of the swing is seamless.
        local dx, dy, dz = awayX - plan.x, awayY - y, awayZ - plan.z
        local departPitch = math.atan2(dy, math.max(math.sqrt(dx * dx + dz * dz), 0.01))
        local pitch = lerp(plan.swingPitch, departPitch, eased)
        -- Hand over to aiming at the departing vehicle for the last fifth.
        local weight = 1 - smoothstep((t - 0.8) / 0.2)
        return plan.x, y, plan.z, awayX, awayY, awayZ, yaw, pitch, weight
    end

    if phase == "rise" then
        return plan.x, y, plan.z, awayX, awayY, awayZ, nil, nil, 0
    end

    local joined = phase == "join" and smoothstep(plan.joinTime / DroneCamCreator.DRIVE_OVER_JOIN_TIME) or 1
    return lerp(plan.x, chaseX, joined), lerp(riseY, chaseY, joined), lerp(plan.z, chaseZ, joined),
           lerp(awayX, chaseLookX, joined), lerp(awayY, chaseLookY, joined), lerp(awayZ, chaseLookZ, joined),
           nil, nil, 0
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

    if shot == S.SHOT_DRIVE_OVER then
        if plan == nil or plan.shot ~= shot then
            return vx, vy + camera.settings.chaseHeight, vz, aimX, aimY, aimZ, nil, nil, 0
        end
        return getDriveOverTransform(camera, vehicle, plan)
    end

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

    if shot == S.SHOT_DRIVE_OVER then
        local plan = camera.plan
        if plan == nil or plan.shot ~= shot or plan.phase == "tail" then
            return 0, settings.minClearance
        elseif plan.phase == "join" then
            return 0, lerp(close, settings.minClearance, smoothstep(plan.joinTime / DroneCamCreator.DRIVE_OVER_JOIN_TIME))
        end
        return 0, DroneCamCreator.DRIVE_OVER_HEIGHT - 0.05
    end

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
