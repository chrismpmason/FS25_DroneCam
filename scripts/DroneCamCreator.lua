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
---drives over it, the camera swings round to watch it go, and once anything
---towed has gone over it too, rises into the chase position. What is attached
---decides whether it may (DroneCamKit).
DroneCamCreator.DRIVE_OVER_HEIGHT = 0.3
---The underside must clear the lens by this much as well (the near clip
---plane is pulled in to 0.05m for the shot).
DroneCamCreator.DRIVE_OVER_HEADROOM = 0.2
---The camera comes down to suit a lower underside (underside minus HEADROOM),
---but no lower than this; a line with less than MIN_CLEARANCE (the lowest
---camera plus its headroom) is not used.
DroneCamCreator.DRIVE_OVER_MIN_HEIGHT = 0.12
DroneCamCreator.DRIVE_OVER_MIN_CLEARANCE = DroneCamCreator.DRIVE_OVER_MIN_HEIGHT + DroneCamCreator.DRIVE_OVER_HEADROOM
---A collision shape hit underneath whose name (or a parent's) has one of
---these in it is a wheel or axle: it is taken at hub height.
DroneCamCreator.WHEEL_SHAPE_WORDS = { "wheel", "tire", "tyre", "axle", "hub" }
---Lines are tried every LINE_STEP across the gap between the wheels; the lens
---takes up a line and its neighbours either side. Lines within LINE_TIE of
---the best clearance count as equal, and the most central of them is used.
DroneCamCreator.DRIVE_OVER_LINE_STEP = 0.1
DroneCamCreator.DRIVE_OVER_LINE_TIE = 0.02
---A tyre is taken to be at least this wide either side of its centre, or
---this fraction of its radius, plus LENS_MARGIN for the camera beside it.
DroneCamCreator.DRIVE_OVER_MIN_TYRE_HALF = 0.25
DroneCamCreator.DRIVE_OVER_TYRE_HALF_FACTOR = 0.35
DroneCamCreator.DRIVE_OVER_LENS_MARGIN = 0.15
---The underside map is kept this long (seconds) per vehicle: several hundred
---rays, not to be cast again for every check.
DroneCamCreator.DRIVE_OVER_GRID_CACHE_TIME = 5
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
---PROFILE_OVERHANG behind the vehicle to PROFILE_OVERHANG in front, on every
---line across the gap between the wheels.
DroneCamCreator.DRIVE_OVER_PROFILE_STEP = 0.25
DroneCamCreator.DRIVE_OVER_PROFILE_OVERHANG = 1
---The camera stays down until the whole train (trailers, sprayer boom and
---all) has gone over it, then rises this high behind it.
DroneCamCreator.DRIVE_OVER_RISE_HEIGHT = 2.5
---Behind the rear of the whole train by this much before the camera rises.
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
---Something on the front no wider than the vehicle plus this, and no longer
---than FRONT_ATTACHMENT_LENGTH, is front weights rather than a header.
DroneCamCreator.DRIVE_OVER_FRONT_ATTACHMENT_SLACK = 0.3
DroneCamCreator.DRIVE_OVER_FRONT_ATTACHMENT_LENGTH = 2
---The view from the spot is checked to this fraction of the vehicle's
---height, with this much clearance over the terrain: a line from a lens 0.3m
---up to the vehicle's bonnet grazes every ripple in the field.
DroneCamCreator.DRIVE_OVER_SIGHT_HEIGHT = 0.75
DroneCamCreator.DRIVE_OVER_SIGHT_MARGIN = 0.05
---Wheel pass: the drive-over's partner for a vehicle with an implement
---working the ground, which leaves no way up between them. The camera sits
---WHEEL_PASS_HEIGHT up just outside the widest part of the combination
---(WHEEL_PASS_GAP clear of it), 25-35m ahead, and pans along the vehicle as
---it rolls past, then rises into the chase once everything has gone by.
DroneCamCreator.WHEEL_PASS_HEIGHT = 0.4
DroneCamCreator.WHEEL_PASS_GAP = 2.2
DroneCamCreator.WHEEL_PASS_MIN_DISTANCE = 25
DroneCamCreator.WHEEL_PASS_MAX_DISTANCE = 35
---The view pans back along the rig from the front of the tractor to the
---implement: starting when the front is this far short of level with the
---camera, ending this far after the implement has gone by.
DroneCamCreator.WHEEL_PASS_PAN_START = 4
DroneCamCreator.WHEEL_PASS_PAN_END = 1.5
---Once everything has gone by, it watches the implement drive away this
---long (seconds) before rising.
DroneCamCreator.WHEEL_PASS_WATCH_TIME = 2.5
---The view may turn this fast while following the rig past, close in at speed.
DroneCamCreator.WHEEL_PASS_YAW_RATE = math.rad(240)
DroneCamCreator.WHEEL_PASS_RISE_HEIGHT = 3
---While still well off, it gives up if the vehicle drifts this far off its line.
DroneCamCreator.WHEEL_PASS_MAX_OFF_LINE = 1

---Any obstacle lift left from the shot before drains away this fast (m/s)
---while the drive-over is set up, so the camera settles onto its spot.
DroneCamCreator.DRIVE_OVER_LIFT_DRAIN = 10

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
        or shot == S.SHOT_WHEEL_PASS
end

---@return boolean @True for shots that are planned from a fixed spot
function DroneCamCreator.getNeedsPlan(shot)
    return DroneCamDirector.getIsFixed(shot) or DroneCamDirector.getIsHero(shot) or shot == S.SHOT_WHEEL_PASS
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

    -- The game's own outline of the field when there is one, otherwise the
    -- edges found by sampling.
    local centreX, centreZ, radius = vx, vz, DroneCamCreator.ESTABLISHING_FALLBACK_RADIUS
    local info = camera.fieldInfo
    if info ~= nil then
        centreX, centreZ, radius = info.centreX, info.centreZ, info.length * 0.5
    else
        local field = DroneCamField.probe(vx, vz)
        if field ~= nil then
            centreX, centreZ, radius = field.x, field.z, field.radius
        end
    end
    radius = math.min(math.max(radius, DroneCamCreator.ESTABLISHING_MIN_RADIUS), DroneCamCreator.ESTABLISHING_MAX_RADIUS)

    local ground = getTerrainHeight(centreX, centreZ, vy)
    local distance = camera:capReach(math.max(radius * DroneCamCreator.ESTABLISHING_DISTANCE_FACTOR, DroneCamCreator.ESTABLISHING_MIN_DISTANCE))
    local height = camera:capHeight(math.max(radius * DroneCamCreator.ESTABLISHING_HEIGHT_FACTOR, DroneCamCreator.ESTABLISHING_MIN_HEIGHT))

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
    local distance = camera:capReach(DroneCamCreator.LONG_LENS_DISTANCE * math.min(math.max(rig.scale, 1), 2))
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

---Front weights, a front linkage counterweight: no wider than the vehicle
---plus FRONT_ATTACHMENT_SLACK and no longer than FRONT_ATTACHMENT_LENGTH.
---Fine as long as its underside clears the lens, whatever it reports about
---being lowered.
---@return boolean
local function getIsSmallFront(rig, box)
    return box.halfWidth <= rig.rootHalfWidth + DroneCamCreator.DRIVE_OVER_FRONT_ATTACHMENT_SLACK
        and box.halfLength * 2 <= DroneCamCreator.DRIVE_OVER_FRONT_ATTACHMENT_LENGTH
        and box.centreAlong > 0
end

---@return number @Front edge (rig-local along) of the vehicle and anything on
---    its front (weights, a raised header): all of it goes over the camera
local function getTrainFront(rig)
    local front = rig.rootFront
    for i = 1, #rig.boxes do
        local box = rig.boxes[i]
        if box.isFront then
            local alongExtent = math.abs(box.fx * rig.fwdX + box.fz * rig.fwdZ) * box.halfLength
                + math.abs(box.sx * rig.fwdX + box.sz * rig.fwdZ) * box.halfWidth
            front = math.max(front, box.centreAlong + alongExtent)
        end
    end
    return front
end

---@return string @Which part of the train is over the given point (rig-local along)
local function getUnitAt(rig, along)
    if along > rig.rootFront then
        for i = 1, #rig.boxes do
            local box = rig.boxes[i]
            if box.isFront and box.vehicle ~= nil and math.abs(along - box.centreAlong) <= box.halfLength + 0.5 then
                local _, label = DroneCamKit.getKind(box.vehicle)
                return "under the " .. label .. " on the front"
            end
        end
        return "in front of the vehicle"
    elseif along >= rig.rootRear then
        return ("%.1fm from the front"):format(rig.rootFront - along)
    end
    local nearest, nearestLabel = math.huge, nil
    for i = 1, #rig.boxes do
        local box = rig.boxes[i]
        if not box.isRoot and not box.isFront and box.vehicle ~= nil then
            local distance = math.max(math.abs(along - box.centreAlong) - box.halfLength, 0)
            if distance < nearest then
                local _, label = DroneCamKit.getKind(box.vehicle)
                nearest, nearestLabel = distance, label
            end
        end
    end
    if nearestLabel ~= nil and nearest < 0.5 then
        return ("under the %s, %.1fm from the front"):format(nearestLabel, rig.rootFront - along)
    end
    return ("behind the vehicle, %.1fm from the front"):format(rig.rootFront - along)
end

---@return string|nil @Why what is attached rules out a drive-over, or nil
local function getKitProblem(camera, rig)
    return DroneCamKit.getDriveOverProblem(rig, function(box)
        return getIsSmallFront(rig, box)
    end, camera.settings ~= nil and camera.settings.driveOverAllow or nil)
end

---Checks the run is straight, by whichever rules apply.
---@param rules boolean|string @false/nil: the story's (via the director);
---    "mode": drive-over mode's (the camera tracks turning itself);
---    true: Ctrl+G (only refuses a turn in progress)
---@return string|nil @Why not, or nil if fine
local function getStraightProblem(camera, rules)
    local director = camera.director
    if rules == "mode" then
        -- (Drive-over mode does not plan at all mid-turn; it says so itself.)
        if (camera.modeStraightTime or 0) < DroneCamDirector.STRAIGHT_SETTLE_TIME then
            return "not straight long enough yet"
        end
    elseif not rules then
        if director == nil or not director.isRunning then
            return "Auto director is off"
        end
        if director:getIsTurning() then
            return "turning"
        end
        if director.straightTime < DroneCamDirector.STRAIGHT_SETTLE_TIME then
            return "not straight long enough yet"
        end
    elseif director ~= nil and director.isRunning and director:getIsTurning() then
        return "turning"
    end
    return nil
end

---@return number @The vehicle's speed in m/s: the game's own figure when it
---    has one, since the camera's estimate takes a moment to settle after take-off
local function getVehicleSpeed(camera, vehicle)
    if vehicle.getLastSpeed ~= nil then
        return vehicle:getLastSpeed() / 3.6
    end
    return camera.vehicleSpeed or 0
end

---@return string|nil @Why there is not room before the row end, or nil if there is
local function getRowEndProblem(rig, vehicle, distance, speed)
    local runOut = distance + (rig.front - rig.rear)
        + speed * (DroneCamCreator.DRIVE_OVER_SWING_TIME + DroneCamCreator.DRIVE_OVER_RISE_TIME
                   + DroneCamCreator.DRIVE_OVER_JOIN_TIME + DroneCamCreator.DRIVE_OVER_TAIL_TIME)
        + DroneCamCreator.DRIVE_OVER_EDGE_MARGIN
    local vx, _, vz = getWorldTranslation(vehicle.rootNode)
    if DroneCamField.getIsOnField(vx, vz) == true then
        local edge = DroneCamField.getEdgeDistance(vx, vz, rig.fwdX, rig.fwdZ, runOut)
        if edge ~= nil then
            return ("row end too close: %.0fm, needs %.0fm"):format(edge, runOut)
        end
    end
    return nil
end

---How far either side of the centre line the camera may go: up to the inside
---of the nearest tyre (front or rear), less room for the lens.
---@return number
local function getTyreRoom(wheel)
    return math.max(DroneCamCreator.DRIVE_OVER_MIN_TYRE_HALF, wheel.radius * DroneCamCreator.DRIVE_OVER_TYRE_HALF_FACTOR)
        + DroneCamCreator.DRIVE_OVER_LENS_MARGIN
end

local function getLineSpan(rig, centreAcross)
    local span = math.huge
    for i = 1, #rig.wheels do
        local wheel = rig.wheels[i]
        span = math.min(span, math.abs(wheel.lx - centreAcross) - getTyreRoom(wheel))
    end
    if span == math.huge then
        -- No wheels to go by: keep to the middle half of the vehicle.
        span = rig.rootHalfWidth * 0.5
    end
    return math.max(span, 0)
end

---@return boolean @True if a line (rig-local across) runs into the wheels of anything towed
local function getIsLineOnTrainWheels(rig, across)
    for i = 1, #rig.trainWheels do
        local wheel = rig.trainWheels[i]
        if math.abs(across - wheel.lx) < getTyreRoom(wheel) then
            return true
        end
    end
    return false
end

---@return number @How far a box reaches along the rig's forward axis from its centre
local function getAlongExtent(rig, box)
    return math.abs(box.fx * rig.fwdX + box.fz * rig.fwdZ) * box.halfLength
        + math.abs(box.sx * rig.fwdX + box.sz * rig.fwdZ) * box.halfWidth
end

---@return table|nil @The towed unit's box over a point (rig-local along), nearest centre first
local function getTowedBoxAt(rig, along)
    local best, bestDistance = nil, math.huge
    for i = 1, #rig.boxes do
        local box = rig.boxes[i]
        if not box.isRoot and not box.isFront and box.vehicle ~= nil then
            local distance = math.abs(along - box.centreAlong)
            if distance <= getAlongExtent(rig, box) and distance < bestDistance then
                best, bestDistance = box, distance
            end
        end
    end
    return best
end

---@return string|nil @The name of a hit collision shape, or of the first of
---    its parents that names a wheel, tyre, hub or axle; nil if unnamed
---@return boolean @True if it is part of a wheel or axle
local function getShapeIdentity(rig, hitId)
    if hitId == nil or getName == nil or not entityExists(hitId) then
        return nil, rig.wheelNodes[hitId] == true
    end
    local name = getName(hitId)
    local node = hitId
    for _ = 1, 4 do
        if node == nil or node == 0 or not entityExists(node) then
            break
        end
        if rig.wheelNodes[node] then
            return name, true
        end
        local nodeName = tostring(getName(node)):lower()
        for _, word in ipairs(DroneCamCreator.WHEEL_SHAPE_WORDS) do
            if nodeName:find(word, 1, true) ~= nil then
                return name, true
            end
        end
        node = getParent ~= nil and getParent(node) or nil
    end
    return name, false
end

---@return number|nil @Hub height of the wheel nearest a point (rig-local along), any unit
local function getHubNear(rig, along)
    local best, bestDistance = nil, math.huge
    for _, list in ipairs({ rig.wheels, rig.trainWheels }) do
        for _, wheel in ipairs(list) do
            local distance = math.abs(wheel.lz - along)
            if distance < bestDistance then
                best, bestDistance = wheel.hub, distance
            end
        end
    end
    return best
end

---What one upward ray says about the underside, weighed against the other
---sources: what the shape it hit is, the wheels (radius and hub height) of the
---unit above, and the allow list. Mod collision is often rough: a box round
---the wheels, or axles modelled at the bottom of the tyres.
---  A wheel or axle shape (by node, or a name with wheel/tyre/hub/axle
---    in it): the hub height, where the axle really is.
---  A towed unit on the allow list: its hub height, or clear if it has none.
---  A towed unit's axle line (between its first and last axle, a wheel
---    radius either side) reading below its hub height: the hub height. An
---    axle runs at hub height; anything lower there is the collision, not
---    the trailer.
---Anywhere else the collision is taken as it is.
---@return number, string|nil @Clearance to use, and why it differs from the reading
local function judgeReading(rig, along, raw, hitId, allow, maxHeight)
    local name, isWheel = getShapeIdentity(rig, hitId)
    if isWheel then
        local hub = getHubNear(rig, along)
        if hub ~= nil and hub > raw then
            return hub, ("wheel or axle shape%s: hub height used"):format(name ~= nil and (" '" .. name .. "'") or "")
        end
        return raw, nil
    end

    local box = getTowedBoxAt(rig, along)
    if box == nil then
        return raw, nil
    end
    local hub, first, last = nil, math.huge, -math.huge
    for _, wheel in ipairs(rig.trainWheels) do
        if wheel.vehicle == box.vehicle then
            hub = math.max(hub or 0, wheel.hub)
            first = math.min(first, wheel.lz - wheel.radius)
            last = math.max(last, wheel.lz + wheel.radius)
        end
    end

    if DroneCamKit.getIsAllowed(box.vehicle, allow) then
        local trusted = math.max(raw, hub or maxHeight)
        return trusted, trusted > raw and "on the allow list" or nil
    end
    if hub ~= nil and raw < hub and along >= first and along <= last then
        return hub, "low reading on the axle line: hub height used"
    end
    return raw, nil
end

---Map of the underside: for each line across the gap between the wheels, the
---lowest clearance along the whole train, from a little past its rear to a
---little past its front: the camera stays down until all of it has gone over.
---Kept for DRIVE_OVER_GRID_CACHE_TIME, since it takes several hundred rays.
---@return table|nil @{columns = {{offset, clearance}}, lowest = {clearance, along},
---    lowestRaw = {clearance, along, offset, hitId, used, why}}
local function getUndersideGrid(camera, vehicle, rig, centreAcross, span, vehicleFront)
    local now = camera.activeTime or 0
    local cached = camera.undersideGrid
    -- A boom folding or a header moving changes the underside: measure again.
    local signature = DroneCamKit.getSignature(vehicle)
    if cached ~= nil and cached.vehicle == vehicle and now >= cached.time and cached.signature == signature
        and now - cached.time < DroneCamCreator.DRIVE_OVER_GRID_CACHE_TIME
        and math.abs(cached.span - span) < 0.01 and math.abs(cached.front - vehicleFront) < 0.01
        and math.abs(cached.rear - (rig.rear - rig.rootRear)) < 0.01 then
        return cached.grid
    end

    local step = DroneCamCreator.DRIVE_OVER_LINE_STEP
    local count = math.floor(span / step + 1e-6)
    local maxHeight = DroneCamCreator.DRIVE_OVER_HEIGHT + DroneCamCreator.DRIVE_OVER_HEADROOM + 1
    local grid = { columns = {}, lowest = { clearance = math.huge, along = 0 }, lowestRaw = nil }
    local allow = camera.settings ~= nil and camera.settings.driveOverAllow or nil

    -- Every PROFILE_STEP along, and on every axle line too: an axle is thinner
    -- than the step and could fall between two rays.
    local alongs = {}
    local along = rig.rear - DroneCamCreator.DRIVE_OVER_PROFILE_OVERHANG
    while along <= vehicleFront + DroneCamCreator.DRIVE_OVER_PROFILE_OVERHANG do
        alongs[#alongs + 1] = along
        along = along + DroneCamCreator.DRIVE_OVER_PROFILE_STEP
    end
    for _, list in ipairs({ rig.wheels, rig.trainWheels }) do
        for _, wheel in ipairs(list) do
            alongs[#alongs + 1] = wheel.lz
        end
    end

    -- One column beyond the outermost line each side, for the lens's width.
    for i = -(count + 1), count + 1 do
        local offset = i * step
        local column = { offset = offset, clearance = math.huge }
        for _, along in ipairs(alongs) do
            local x, z = DroneCamRig.toWorld(rig, centreAcross + offset, along)
            local raw, hitId = DroneCamSpot.getVehicleClearance(x, getTerrainHeight(x, z, rig.ground), z, maxHeight)
            if raw == nil then
                return nil
            end
            local clearance, why = judgeReading(rig, along, raw, hitId, allow, maxHeight)
            column.clearance = math.min(column.clearance, clearance)
            if clearance < grid.lowest.clearance then
                grid.lowest = { clearance = clearance, along = along }
            end
            if hitId ~= nil and (grid.lowestRaw == nil or raw < grid.lowestRaw.clearance) then
                grid.lowestRaw = { clearance = raw, along = along, offset = offset, hitId = hitId, used = clearance, why = why }
            end
        end
        grid.columns[#grid.columns + 1] = column
    end

    camera.undersideGrid = { vehicle = vehicle, time = now, span = span, front = vehicleFront, signature = signature,
                             rear = rig.rear - rig.rootRear, grid = grid }
    DroneCamCreator.reportUnderside(camera, rig, grid)
    return grid
end

---Says which collision shape gave the lowest reading under the train, how
---high, and what was made of it: on the overlay, and in log.txt as a
---"[DroneCam]" line whenever it changes.
function DroneCamCreator.reportUnderside(camera, rig, grid)
    local raw = grid.lowestRaw
    local note
    if raw == nil then
        note = "nothing hit underneath"
    else
        local name = nil
        if getName ~= nil and entityExists(raw.hitId) then
            name = getName(raw.hitId)
        end
        note = ("lowest collision %.2fm, shape '%s' (node %s), %s, %s"):format(raw.clearance, tostring(name or "?"),
            tostring(raw.hitId), getUnitAt(rig, raw.along),
            math.abs(raw.offset) < 0.05 and "on the centre line" or ("%+.2fm off centre"):format(raw.offset))
        if raw.why ~= nil then
            note = note .. (" - counted as %.2fm (%s)"):format(raw.used, raw.why)
        end
    end
    camera.undersideNote = note
    if note ~= camera.undersideLogged then
        camera.undersideLogged = note
        print("[DroneCam] Underside: " .. note)
    end
end

---@param forced boolean|string @See getStraightProblem; Ctrl+G (true) also
---    skips the row-end check, but nothing that could clip is ever skipped
---@return table|nil, string|nil @The plan, or nil and the reason it cannot be done
local function planDriveOver(camera, vehicle, rig, forced)
    local speed = getVehicleSpeed(camera, vehicle)

    -- Nothing on the ground, lowered on the front or hanging off a slurry
    -- tanker: the whole train goes over the camera.
    local kitProblem = getKitProblem(camera, rig)
    if kitProblem ~= nil then
        return nil, kitProblem
    end

    -- A straight run at a steady working speed.
    local straightProblem = getStraightProblem(camera, forced)
    if straightProblem ~= nil then
        return nil, straightProblem
    end

    if speed <= 0.1 then
        return nil, "not moving"
    end
    local distance = math.min(math.max(speed * DroneCamCreator.DRIVE_OVER_LEAD_TIME, DroneCamCreator.DRIVE_OVER_MIN_DISTANCE),
                              DroneCamCreator.DRIVE_OVER_MAX_DISTANCE)
    if distance / speed > DroneCamCreator.DRIVE_OVER_MAX_APPROACH then
        return nil, ("too slow: %.1f km/h, needs %.1f"):format(speed * 3.6,
            DroneCamCreator.DRIVE_OVER_MIN_DISTANCE / DroneCamCreator.DRIVE_OVER_MAX_APPROACH * 3.6)
    end

    -- Weights or a raised header on the front go over the camera first.
    local vehicleFront = getTrainFront(rig)

    -- The camera's line: anywhere between the wheels, wherever the underside
    -- of the whole train is highest (beside a drawbar rather than under it),
    -- centre preferred, never in the track of anything towed.
    local left, right = DroneCamRig.getRearWheel(rig, -1), DroneCamRig.getRearWheel(rig, 1)
    local centreAcross = (left.lx + right.lx) * 0.5
    local function world(across, along)
        return DroneCamRig.toWorld(rig, across, along)
    end

    local grid = getUndersideGrid(camera, vehicle, rig, centreAcross, getLineSpan(rig, centreAcross), vehicleFront)
    if grid == nil then
        return nil, "cannot measure the underside"
    end

    -- Each line's clearance is the lowest over the lens's width (its own
    -- column and the ones either side); best first, the centre winning a
    -- near tie.
    local lines = {}
    for i = 2, #grid.columns - 1 do
        local offset = grid.columns[i].offset
        if not getIsLineOnTrainWheels(rig, centreAcross + offset) then
            local clearance = math.min(grid.columns[i - 1].clearance, grid.columns[i].clearance, grid.columns[i + 1].clearance)
            lines[#lines + 1] = { offset = offset, clearance = clearance }
        end
    end
    table.sort(lines, function(a, b)
        if math.abs(a.clearance - b.clearance) > DroneCamCreator.DRIVE_OVER_LINE_TIE then
            return a.clearance > b.clearance
        end
        return math.abs(a.offset) < math.abs(b.offset)
    end)

    local chosen = lines[1]
    if chosen == nil then
        return nil, "no line clear of the wheels of everything towed"
    end
    if chosen.clearance < DroneCamCreator.DRIVE_OVER_MIN_CLEARANCE then
        local lowest = grid.lowest
        local reason = ("underside too low: best line %.2fm (lowest %.2fm %s), needs %.2fm"):format(
            chosen.clearance, lowest.clearance, getUnitAt(rig, lowest.along), DroneCamCreator.DRIVE_OVER_MIN_CLEARANCE)
        -- Under something towed: say how to allow it anyway.
        local box = getTowedBoxAt(rig, lowest.along)
        if box ~= nil then
            reason = reason .. (" - to allow it, add %s to driveOverAllow in %s"):format(
                DroneCamKit.getVehicleKey(box.vehicle), DroneCamSettings.XML_FILENAME)
        end
        return nil, reason
    end
    local height = math.max(math.min(DroneCamCreator.DRIVE_OVER_HEIGHT, chosen.clearance - DroneCamCreator.DRIVE_OVER_HEADROOM),
                            DroneCamCreator.DRIVE_OVER_MIN_HEIGHT)
    local lineAcross = centreAcross + chosen.offset

    local spotAlong = vehicleFront + distance
    local x, z = world(lineAcross, spotAlong)
    local ground = getTerrainHeight(x, z, rig.ground)
    local y = ground + height

    -- Even ground where the vehicle rolls over the camera. A steady slope is
    -- fine (the vehicle sits on it the same way); only a bump or a dip
    -- against the line of the slope changes the clearance.
    local fwdX, fwdZ = rig.fwdX, rig.fwdZ
    local reach = 1.5
    local behind = getTerrainHeight(x - fwdX * reach, z - fwdZ * reach, ground)
    local ahead = getTerrainHeight(x + fwdX * reach, z + fwdZ * reach, ground)
    for _, offset in ipairs({ -1.5, -0.75, 0, 0.75, 1.5 }) do
        local h = offset == 0 and ground or getTerrainHeight(x + fwdX * offset, z + fwdZ * offset, ground)
        local line = behind + (ahead - behind) * (offset + reach) / (2 * reach)
        if math.abs(h - line) > DroneCamCreator.DRIVE_OVER_MAX_BUMP then
            return nil, ("ground not even at the spot: %.2fm bump"):format(math.abs(h - line))
        end
    end

    -- No standing crop to hide the lens, at the spot or on the way to it.
    local step = 2
    local sampled = 0
    while sampled <= distance + 2 do
        local cx, cz = world(lineAcross, vehicleFront + sampled)
        local crop = DroneCamCamera.getCropHeightAt(cx, cz)
        if crop > DroneCamCreator.DRIVE_OVER_MAX_CROP then
            return nil, ("standing crop %.1fm high"):format(crop)
        end
        sampled = sampled + step
    end

    -- Not in or under anything, and able to see the vehicle coming: aimed
    -- high on it, since a line from a lens 0.3m up grazes the field.
    local frontX, frontZ = world(centreAcross, vehicleFront)
    local frontY = rig.ground + rig.rootHeight * DroneCamCreator.DRIVE_OVER_SIGHT_HEIGHT
    if not DroneCamSpot.getIsSpotClear(x, y, z, height - 0.05) then
        return nil, "spot under or against a tree or building"
    end
    if not DroneCamSpot.getHasLineOfSight(x, y, z, frontX, frontY, frontZ, DroneCamCreator.DRIVE_OVER_SIGHT_MARGIN) then
        return nil, "no clear view of the vehicle from the spot"
    end

    -- No headland turn before it is all over.
    if forced ~= true then
        local rowEndProblem = getRowEndProblem(rig, vehicle, distance, speed)
        if rowEndProblem ~= nil then
            return nil, rowEndProblem
        end
    end

    return {
        shot = S.SHOT_DRIVE_OVER,
        x = x, y = y, z = z, ground = ground,
        centreAcross = lineAcross,
        lineOffset = chosen.offset,
        underside = chosen.clearance,
        height = height,
        riseHeight = DroneCamCreator.DRIVE_OVER_RISE_HEIGHT,
        -- Anything folding, being lowered or raised, attached or detached
        -- from here on calls the drive-over off (updateDriveOver).
        kit = DroneCamKit.snapshot(vehicle),
        phase = "approach",
        stopTime = 0, swingTime = 0, riseTime = 0, riseProgress = 0, joinTime = 0, tailTime = 0,
        isDone = false
    }
end

---@param rules boolean|string @See getStraightProblem
---@return table|nil, string|nil @The plan, or nil and the reason it cannot be done
local function planWheelPass(camera, vehicle, rig, rules)
    local speed = getVehicleSpeed(camera, vehicle)

    local straightProblem = getStraightProblem(camera, rules)
    if straightProblem ~= nil then
        return nil, straightProblem
    end
    if speed <= 0.1 then
        return nil, "not moving"
    end
    local distance = math.min(math.max(speed * DroneCamCreator.DRIVE_OVER_LEAD_TIME, DroneCamCreator.WHEEL_PASS_MIN_DISTANCE),
                              DroneCamCreator.WHEEL_PASS_MAX_DISTANCE)
    if distance / speed > DroneCamCreator.DRIVE_OVER_MAX_APPROACH then
        return nil, ("too slow: %.1f km/h, needs %.1f"):format(speed * 3.6,
            DroneCamCreator.WHEEL_PASS_MIN_DISTANCE / DroneCamCreator.DRIVE_OVER_MAX_APPROACH * 3.6)
    end

    -- Just outside the widest part: the vehicle, or what it is working.
    local halfWidth = rig.halfWidth
    if rig.work ~= nil then
        halfWidth = math.max(halfWidth, math.abs(rig.work.lx) + rig.work.halfWidth)
    end
    local out = halfWidth + DroneCamCreator.WHEEL_PASS_GAP
    local along = rig.front + distance
    local height = DroneCamCreator.WHEEL_PASS_HEIGHT

    local first = camera.director ~= nil and camera.director.side or 1
    local reason = nil
    for _, side in ipairs({ first, -first }) do
        local x, z = DroneCamRig.toWorld(rig, side * out, along)
        local ground = getTerrainHeight(x, z, rig.ground)
        local y = ground + height
        local crop = DroneCamCamera.getCropHeightAt(x, z)
        local frontX, frontZ = DroneCamRig.toWorld(rig, side * rig.rootHalfWidth, rig.rootFront)
        local frontY = rig.ground + rig.rootHeight * DroneCamCreator.DRIVE_OVER_SIGHT_HEIGHT

        if crop > DroneCamCreator.DRIVE_OVER_MAX_CROP then
            reason = ("standing crop %.1fm high beside the track"):format(crop)
        elseif not DroneCamSpot.getIsSpotClear(x, y, z, height - 0.05) then
            reason = "spot under or against a tree or building"
        elseif not DroneCamSpot.getHasLineOfSight(x, y, z, frontX, frontY, frontZ, DroneCamCreator.DRIVE_OVER_SIGHT_MARGIN) then
            reason = "no clear view of the vehicle from the spot"
        else
            if rules ~= true then
                local rowEndProblem = getRowEndProblem(rig, vehicle, distance, speed)
                if rowEndProblem ~= nil then
                    return nil, rowEndProblem
                end
            end
            return {
                shot = S.SHOT_WHEEL_PASS,
                x = x, y = y, z = z, ground = ground,
                across = side * out,
                kit = DroneCamKit.snapshot(vehicle),
                phase = "approach",
                stopTime = 0, riseTime = 0, riseProgress = 0, joinTime = 0, tailTime = 0,
                isDone = false
            }
        end
    end

    return nil, reason
end

local PLANNERS = {
    [S.SHOT_ESTABLISHING] = planEstablishing,
    [S.SHOT_LONG_LENS] = planLongLens,
    [S.SHOT_EDGE_PAN] = planEdgePan,
    [S.SHOT_HEADLAND] = planHeadland,
    [S.SHOT_DRIVE_OVER] = planDriveOver,
    [S.SHOT_WHEEL_PASS] = planWheelPass
}

---Drive-over mode's choice: a drive-over when what is attached allows it and
---the whole train clears the camera (DroneCamKit), otherwise a wheel pass.
---@param rules boolean|string @See getStraightProblem
---@return integer, table|nil, string|nil @Shot, its plan or nil, and why not
---    (with a wheel pass, its plan's driveOverReason says why not a drive-over)
function DroneCamCreator.planGroundPass(camera, vehicle, rules)
    local plan, driveReason = DroneCamCreator.plan(camera, vehicle, S.SHOT_DRIVE_OVER, rules)
    if plan ~= nil then
        return S.SHOT_DRIVE_OVER, plan, nil
    end

    local wheelPlan, wheelReason = DroneCamCreator.plan(camera, vehicle, S.SHOT_WHEEL_PASS, rules)
    if wheelPlan ~= nil then
        wheelPlan.driveOverReason = driveReason
        return S.SHOT_WHEEL_PASS, wheelPlan, nil
    end

    if wheelReason == nil or wheelReason == driveReason then
        return S.SHOT_DRIVE_OVER, nil, driveReason
    end
    return S.SHOT_DRIVE_OVER, nil, ("%s; wheel pass: %s"):format(tostring(driveReason), wheelReason)
end

---Finds a spot for a fixed shot.
---@param forced boolean|nil @For the drive-over: asked for with the force key
---@return table|nil, string|nil @The plan, or nil and (for the drive-over) why not
function DroneCamCreator.plan(camera, vehicle, shot, forced)
    local planner = PLANNERS[shot]
    if planner == nil then
        return nil, "not a planned shot"
    end
    local rig = camera:getRig(vehicle)
    if rig == nil then
        return nil, "cannot measure the vehicle"
    end

    local plan, reason = planner(camera, vehicle, rig, forced)
    if plan ~= nil then
        plan.sightTimer = 0
        plan.blockedTime = 0
        plan.isLost = false
    end
    return plan, reason
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

---@return boolean @True for the shots that put the camera on the ground
function DroneCamCreator.getIsGroundPass(shot)
    return shot == S.SHOT_DRIVE_OVER or shot == S.SHOT_WHEEL_PASS
end

---@return boolean @True from the moment a ground pass is chosen (gliding in included) until it joins the chase
---    (and, when one is called off with kit over or beside it, until the cut)
function DroneCamCreator.getIsDriveOverGrounded(camera)
    local plan = camera.plan
    return DroneCamCreator.getIsGroundPass(camera.shot) and plan ~= nil and plan.shot == camera.shot
        and plan.phase ~= "join" and plan.phase ~= "tail" and not plan.isDone and (not plan.isLost or plan.cutAway == true)
end

---@return boolean @True while a ground pass has the camera down on its spot (not gliding, not yet joining the chase)
function DroneCamCreator.getIsGroundPassLow(camera)
    return camera.fromPose == nil and DroneCamCreator.getIsDriveOverGrounded(camera)
end

---@return boolean @True if the vehicle is turning, by the director or (in drive-over mode) the camera's own tracking
local function getIsTurning(camera)
    return camera.modeIsTurning == true or (camera.director ~= nil and camera.director:getIsTurning())
end

---Advances the wheel pass through its phases:
---  approach  the vehicle drives towards the camera
---  pass      it is going by: the view follows it part by part
---  watch     everything has gone by: watch the implement drive away for
---            WHEEL_PASS_WATCH_TIME
---  rise      climb to WHEEL_PASS_RISE_HEIGHT
---  join, tail  as the drive-over
function DroneCamCreator.updateWheelPass(camera, dtSeconds, vehicle)
    local plan = camera.plan
    if camera.shot ~= S.SHOT_WHEEL_PASS or plan == nil or plan.shot ~= S.SHOT_WHEEL_PASS
        or plan.isDone or plan.isLost then
        return
    end

    local rig = camera:getRig(vehicle)
    if rig == nil then
        return
    end

    local across, along = DroneCamRig.toLocal(rig, plan.x, plan.z)
    plan.along = along

    -- A boom unfolding swings out towards a camera beside the train: called
    -- off on the way, a cut to the chase once the train is level with it.
    if plan.kit ~= nil and (plan.phase == "approach" or plan.phase == "pass") then
        local change = DroneCamKit.getChange(plan.kit, vehicle, true)
        if change ~= nil then
            plan.isLost = true
            if along > rig.front + DroneCamCreator.DRIVE_OVER_COMMIT_DISTANCE then
                plan.lostReason = change .. " on the way"
            else
                plan.lostReason = change .. " during the pass, cut away"
                plan.cutAway = true
            end
            return
        end
    end

    if plan.phase == "approach" or plan.phase == "pass" then
        if along > rig.rootFront + DroneCamCreator.DRIVE_OVER_COMMIT_DISTANCE then
            local speed = camera.vehicleSpeed or 0
            if speed < DroneCamCreator.DRIVE_OVER_STOP_SPEED then
                plan.stopTime = plan.stopTime + dtSeconds
            else
                plan.stopTime = 0
            end
            local turning = getIsTurning(camera)
            if plan.stopTime > DroneCamCreator.DRIVE_OVER_STOP_TIME or turning
                or math.abs(across - plan.across) > DroneCamCreator.WHEEL_PASS_MAX_OFF_LINE then
                plan.isLost = true
                plan.lostReason = plan.stopTime > DroneCamCreator.DRIVE_OVER_STOP_TIME and "the vehicle stopped"
                    or (turning and "the vehicle turned" or "the vehicle left the line")
                return
            end
        end

        if plan.phase == "approach" and along <= rig.rootFront then
            plan.phase = "pass"
        end
        if plan.phase == "pass" and along <= rig.rear then
            plan.phase = "watch"
            plan.watchTime = 0
        end
    elseif plan.phase == "watch" then
        plan.watchTime = plan.watchTime + dtSeconds
        if plan.watchTime >= DroneCamCreator.WHEEL_PASS_WATCH_TIME then
            plan.phase = "rise"
            plan.riseTime = 0
        end
    elseif plan.phase == "rise" then
        plan.riseTime = plan.riseTime + dtSeconds
        plan.riseProgress = math.min(plan.riseTime / DroneCamCreator.DRIVE_OVER_RISE_TIME, 1)
        if plan.riseProgress >= 1 then
            plan.phase = "join"
            plan.joinTime = 0
        end
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

---The parts of the rig the wheel pass looks at in turn, front to back, on
---the camera's side: the front of the tractor, its front wheel, the cab, its
---rear wheel, then the implement working the ground (or the rear of the rig
---if nothing is). Rig-local: across, along, height above the ground.
---@return table @{{across, along, height}, ...}, along descending
local function getWheelPassSubjects(rig, side)
    local front, rear = nil, nil
    for _, wheel in ipairs(rig.wheels) do
        if wheel.lx * side > 0 then
            if front == nil or wheel.lz > front.lz then front = wheel end
            if rear == nil or wheel.lz < rear.lz then rear = wheel end
        end
    end
    local rootLength = rig.rootFront - rig.rootRear
    local frontLz = front ~= nil and front.lz or rig.rootFront - rootLength * 0.25
    local rearLz = rear ~= nil and rear.lz or rig.rootRear + rootLength * 0.25
    local bodyAcross = side * rig.rootHalfWidth * 0.5

    local subjects = {
        { bodyAcross, rig.rootFront, rig.rootHeight * 0.45 },
        { front ~= nil and front.lx or bodyAcross, frontLz, front ~= nil and front.hub or 0.6 },
        { bodyAcross, (frontLz + rearLz) * 0.5, rig.rootHeight * 0.6 },
        { rear ~= nil and rear.lx or bodyAcross, rearLz, rear ~= nil and rear.hub or 0.6 }
    }

    local work = rig.work
    if work ~= nil and work.lz < rearLz then
        -- The near half of the implement, at the height of its body.
        local height = 0.5
        for _, box in ipairs(rig.boxes) do
            if not box.isRoot and math.abs(box.centreAlong - work.lz) <= box.halfLength + 0.5 then
                height = math.max(height, box.height * 0.4)
            end
        end
        subjects[#subjects + 1] = { work.lx + side * work.halfWidth * 0.5, work.lz, height }
    elseif rig.rear < rearLz - 0.5 then
        subjects[#subjects + 1] = { 0, rig.rear + 0.5, 0.6 }
    end
    return subjects
end

---Smooth curve through the subjects' values (index k: 1 across, 3 height)
---at a point along the rig: a cubic through each pair, its slope at each
---subject set by its neighbours, so the aim glides through every subject
---rather than stopping at each.
local function getSubjectValue(subjects, along, k)
    local n = #subjects
    if along >= subjects[1][2] then
        return subjects[1][k]
    elseif along <= subjects[n][2] then
        return subjects[n][k]
    end
    local function slope(i)
        if i <= 1 or i >= n then
            return 0
        end
        return (subjects[i + 1][k] - subjects[i - 1][k]) / (subjects[i + 1][2] - subjects[i - 1][2])
    end
    for i = 1, n - 1 do
        local a, b = subjects[i], subjects[i + 1]
        if along <= a[2] and along >= b[2] then
            local span = b[2] - a[2]
            local t = (along - a[2]) / span
            local t2, t3 = t * t, t * t * t
            return (2 * t3 - 3 * t2 + 1) * a[k] + (t3 - 2 * t2 + t) * span * slope(i)
                + (-2 * t3 + 3 * t2) * b[k] + (t3 - t2) * span * slope(i + 1)
        end
    end
    return subjects[n][k]
end

---Where the wheel pass is looking. Until the front is WHEEL_PASS_PAN_START
---short of level with the camera, at the front of the tractor, following it
---in; then panning back along the rig (front wheel, cab, rear wheel) to the
---implement, which it reaches WHEEL_PASS_PAN_END after the implement has
---gone by, and then following that away. The pan starts and ends at rest,
---so the view never jerks. Worked out from the rig as it is this frame, so
---it never lags behind.
---@return number, number, number @World position
function DroneCamCreator.getWheelPassSubject(camera, vehicle, plan)
    local rig = camera:getRig(vehicle)
    if rig == nil then
        return getVehicleAim(vehicle)
    end
    local side = plan.across >= 0 and 1 or -1
    local subjects = getWheelPassSubjects(rig, side)
    local _, cameraAlong = DroneCamRig.toLocal(rig, plan.x, plan.z)
    local first, last = subjects[1][2], subjects[#subjects][2]

    local panFrom = first + DroneCamCreator.WHEEL_PASS_PAN_START
    local panTo = last - DroneCamCreator.WHEEL_PASS_PAN_END
    local progress = math.min(math.max((panFrom - cameraAlong) / math.max(panFrom - panTo, 0.01), 0), 1)
    local along = lerp(first, last, smoothstep(progress))

    local x, z = DroneCamRig.toWorld(rig, getSubjectValue(subjects, along, 1), along)
    return x, getTerrainHeight(x, z, rig.ground) + getSubjectValue(subjects, along, 3), z
end
---Transform for the wheel pass, phase by phase. The camera stays put from
---arrival until it rises; only the view turns, held exactly on the subject
---(DroneCamCamera does no look smoothing while the pass is low).
local function getWheelPassTransform(camera, vehicle, plan)
    local rig = camera:getRig(vehicle)
    local chaseX, chaseY, chaseZ, chaseLookX, chaseLookY, chaseLookZ = camera:getModeTransform(vehicle, S.MODE_CHASE)
    if rig == nil then
        return chaseX, chaseY, chaseZ, chaseLookX, chaseLookY, chaseLookZ, nil, nil, 0
    end

    local lookX, lookY, lookZ = DroneCamCreator.getWheelPassSubject(camera, vehicle, plan)

    local riseY = plan.ground + DroneCamCreator.WHEEL_PASS_RISE_HEIGHT
    local risen = smoothstep(plan.riseProgress)
    local y = lerp(plan.y, riseY, risen)

    local phase = plan.phase
    if phase == "approach" or phase == "pass" or phase == "watch" then
        return plan.x, plan.y, plan.z, lookX, lookY, lookZ, nil, nil, 0
    end

    local awayX, awayY, awayZ = getVehicleAim(vehicle)
    if phase == "rise" then
        return plan.x, y, plan.z, lerp(lookX, awayX, risen), lerp(lookY, awayY, risen), lerp(lookZ, awayZ, risen), nil, nil, 0
    end

    local joined = phase == "join" and smoothstep(plan.joinTime / DroneCamCreator.DRIVE_OVER_JOIN_TIME) or 1
    return lerp(plan.x, chaseX, joined), lerp(riseY, chaseY, joined), lerp(plan.z, chaseZ, joined),
           lerp(awayX, chaseLookX, joined), lerp(awayY, chaseLookY, joined), lerp(awayZ, chaseLookZ, joined),
           nil, nil, 0
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
    if not DroneCamCreator.getIsGroundPass(camera.shot) or camera.fromPose ~= nil or plan == nil or plan.shot ~= camera.shot
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
---  trail     anything towed is still going over: stay down, watch it go
---  rise      the whole train has passed: climb behind it
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

    -- Anything folding or unfolding, lowered or raised while the camera is
    -- still down: the underside it measured no longer holds. Called off while
    -- nothing has reached the camera; once something has, the camera cannot
    -- move without going through the kit, so it cuts straight to the chase.
    if plan.kit ~= nil and not plan.riseStarted then
        local change = DroneCamKit.getChange(plan.kit, vehicle)
        if change ~= nil then
            plan.isLost = true
            if along > rig.front + DroneCamCreator.DRIVE_OVER_COMMIT_DISTANCE then
                plan.lostReason = change .. " on the way"
            else
                plan.lostReason = change .. " during the pass, cut away"
                plan.cutAway = true
            end
            return
        end
    end

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
                or getIsTurning(camera) then
                plan.isLost = true
                plan.lostReason = plan.stopTime > DroneCamCreator.DRIVE_OVER_STOP_TIME and "the vehicle stopped"
                    or (getIsTurning(camera) and "the vehicle turned" or "the vehicle left the line")
                return
            end
        end

        -- The swing is centred on the moment the middle of the vehicle is
        -- overhead. The tilt before it gets at least UNDER_LEAD metres of
        -- its own, however fast the vehicle is going.
        local middle = (rig.rootFront + rig.rootRear) * 0.5
        local swingStart = middle + speed * DroneCamCreator.DRIVE_OVER_SWING_TIME * 0.5
        local underStart = math.max(rig.rootFront, swingStart) + DroneCamCreator.DRIVE_OVER_UNDER_LEAD

        if plan.phase == "approach" and along <= underStart and camera.heightBoost > 0.05 then
            -- Still lifted from the shot before (a tree it had to clear):
            -- never let the vehicle pass over a camera that is not on the ground.
            plan.isLost = true
            plan.lostReason = "camera still lifted when the vehicle arrived"
            return
        end

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

    -- The rise starts once the whole train has gone over, swing or no swing.
    if plan.phase == "swing" or plan.phase == "trail" or plan.phase == "rise" then
        if not plan.riseStarted and along <= rig.rear - DroneCamCreator.DRIVE_OVER_REAR_CLEARANCE then
            plan.riseStarted = true
        end
        if plan.riseStarted then
            plan.riseTime = plan.riseTime + dtSeconds
            plan.riseProgress = math.min(plan.riseTime / DroneCamCreator.DRIVE_OVER_RISE_TIME, 1)
        end
    end

    if plan.phase == "swing" and plan.swingTime >= DroneCamCreator.DRIVE_OVER_SWING_TIME then
        plan.phase = plan.riseStarted and "rise" or "trail"
    elseif plan.phase == "trail" and plan.riseStarted then
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

    if phase == "trail" or phase == "rise" then
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

    -- Far points are pulled in to keep within the field (camera:capReach),
    -- keeping their direction from the vehicle.
    local function fit(distance)
        return distance > 0 and camera:capReach(distance) / distance or 1
    end

    if shot == S.SHOT_PUSH_IN then
        local k = fit(math.sqrt(150 * 150 + 30 * 30))
        return lerp(side * 30 * k, 0, eased), lerp(-150 * k, -camera:capReach(settings.chaseDistance), eased),
               lerp(camera:capHeight(60), camera:capHeight(settings.chaseHeight), eased),
               lerp(0, settings.chaseLookAhead, eased)
    elseif shot == S.SHOT_PULL_OUT then
        local startAcross = side * (rig.halfWidth + math.max(gap, 3.5 * scale))
        local k = fit(math.sqrt(25 * 25 + 45 * 45) * scale)
        return lerp(startAcross, side * 25 * scale * k, eased),
               lerp(rig.rootFront + 4 * scale, rig.front + 45 * scale * k, eased),
               lerp(1.8 * scale, camera:capHeight(35 * scale), eased), 0
    elseif shot == S.SHOT_FLY_OVER then
        return side * 2, lerp(rig.front + 25 * scale, rig.rear - 25 * scale, eased), topHeight + 5 * scale, 0
    elseif shot == S.SHOT_RISE_UP then
        local startAlong = rig.rear - math.max(gap, 5 * scale)
        return 0, lerp(startAlong, 0, eased), lerp(2 * scale, camera:capHeight(settings.topDownHeight), eased), 0
    end

    -- Slide.
    local k = fit(math.sqrt(70 * 70 + 40 * 40) * scale)
    return side * 70 * scale * k, lerp(40 * scale * k, -40 * scale * k, eased), camera:capHeight(10 * scale), 0
end

---Camera transform for a creator shot.
---@return number, number, number, number, number, number @Position and look target
---@return number|nil, number|nil, number|nil @Yaw and pitch override, and its weight
function DroneCamCreator.getTransform(camera, vehicle, shot)
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    local aimX, aimY, aimZ = getVehicleAim(vehicle)
    local plan = camera.plan

    if DroneCamCreator.getIsGroundPass(shot) then
        if plan == nil or plan.shot ~= shot then
            return vx, vy + camera.settings.chaseHeight, vz, aimX, aimY, aimZ, nil, nil, 0
        end
        if shot == S.SHOT_WHEEL_PASS then
            return getWheelPassTransform(camera, vehicle, plan)
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

    if DroneCamCreator.getIsGroundPass(shot) then
        local plan = camera.plan
        if plan == nil or plan.shot ~= shot or plan.phase == "tail" then
            return 0, settings.minClearance
        elseif plan.phase == "join" then
            return 0, lerp(close, settings.minClearance, smoothstep(plan.joinTime / DroneCamCreator.DRIVE_OVER_JOIN_TIME))
        end
        local height = shot == S.SHOT_WHEEL_PASS and DroneCamCreator.WHEEL_PASS_HEIGHT
            or (plan.height or DroneCamCreator.DRIVE_OVER_HEIGHT)
        return 0, height - 0.05
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
