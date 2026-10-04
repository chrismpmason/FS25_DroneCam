---@class DroneCamMulti
---Shots with more than one vehicle in them, offered only while another
---vehicle is working the same field (DroneCamPeers):
---
---  Two-shot     a wide shot side-on to the pair, far enough off to fit both,
---               following them as they work
---  Pan across   a fixed spot off to the side, holding on the combine, then
---               panning across to the tractor and trailer coming to it
---  Unloading    out past the trailer on the far side from the combine, a
---               little above both, riding alongside for as long as the
---               combine is unloading
---
---Every spot is checked like the other creator shots: clear of trees and
---buildings, with a view of both vehicles. Other vehicles nearby are kept
---out of the camera by the vehicle floors (DroneCamCamera).
DroneCamMulti = {}

local S = DroneCamSettings

---Two vehicles further apart than this are not working together.
DroneCamMulti.TWO_SHOT_MAX_GAP = 150
---Room around the pair, and the distance and height the camera keeps.
DroneCamMulti.TWO_SHOT_MARGIN = 12
DroneCamMulti.TWO_SHOT_MIN_DISTANCE = 40
DroneCamMulti.TWO_SHOT_HEIGHT_FACTOR = 0.35
DroneCamMulti.TWO_SHOT_MIN_HEIGHT = 15
---Distances tried, as multiples of the one that just fits both in.
DroneCamMulti.TWO_SHOT_DISTANCES = { 1, 1.3 }
---Widest the lens opens to keep both in when the field holds the camera close.
DroneCamMulti.MAX_FOV = 75

---Pan across: the spot is off to the side of the line from the combine to
---the tractor and trailer, PAN_ALONG of the way along, PAN_OUT_FACTOR of the
---gap out (at least PAN_MIN_OUT), PAN_HEIGHT up.
DroneCamMulti.PAN_MIN_SEPARATION = 25
DroneCamMulti.PAN_ALONG = 0.35
DroneCamMulti.PAN_OUT_FACTOR = 0.6
DroneCamMulti.PAN_MIN_OUT = 35
DroneCamMulti.PAN_OUT_STEPS = { 1, 1.3 }
DroneCamMulti.PAN_HEIGHT = 12
---Each vehicle is framed this big; the view holds on the combine this long
---(seconds), then pans across over this fraction of the shot.
DroneCamMulti.PAN_FRAME = 25
DroneCamMulti.PAN_MIN_FOV = 20
DroneCamMulti.PAN_HOLD = 1.5
DroneCamMulti.PAN_SWEEP = 0.55
DroneCamMulti.PAN_DEFAULT_LENGTH = 8

---Unloading: how far out past the trailer, and along the combine's heading
---(behind is negative), the spots tried; how far above the taller vehicle.
DroneCamMulti.UNLOAD_OUT = { 12, 16, 20 }
DroneCamMulti.UNLOAD_ALONG = { -4, 0, -8 }
DroneCamMulti.UNLOAD_ABOVE = 3
---Room around the combine and trailer in frame.
DroneCamMulti.UNLOAD_MARGIN = 5
DroneCamMulti.UNLOAD_MIN_FOV = 30
DroneCamMulti.UNLOAD_CLEARANCE = 3

local function lerp(from, to, alpha)
    return from + (to - from) * alpha
end

local function smoothstep(t)
    t = math.min(math.max(t, 0), 1)
    return t * t * (3 - 2 * t)
end

local function getGround(x, z, fallback)
    return DroneCamRig.getGroundHeight(x, z, fallback)
end

---@return number, number, number
local function getAim(vehicle)
    local x, y, z = getWorldTranslation(vehicle.rootNode)
    return x, y + DroneCamCamera.LOOK_HEIGHT_OFFSET, z
end

---@return number @Height of the top of a combination above the ground under it
local function getTop(vehicle)
    local top = 0
    for _, box in ipairs(DroneCamRig.getVehicleBoxes(vehicle)) do
        top = math.max(top, box.ground + box.height - getGround(box.cx, box.cz, box.ground))
    end
    return top > 0 and top or DroneCamRig.DEFAULT_HEIGHT
end

---@return number @Field of view (degrees) that fits a size at a distance
local function getFramingFov(distance, size, minFov, maxFov)
    local fov = math.deg(2 * math.atan2(size * 0.5, math.max(distance, 1)))
    return math.min(math.max(fov, minFov), maxFov)
end

---@return boolean @A spot clear of trees and buildings, seeing every aim point
local function getIsGoodSpot(x, y, z, aims)
    if not DroneCamSpot.getIsSpotClear(x, y, z) then
        return false
    end
    for _, aim in ipairs(aims) do
        if not DroneCamSpot.getHasLineOfSight(x, y, z, aim[1], aim[2], aim[3]) then
            return false
        end
    end
    return true
end

---@return boolean
function DroneCamMulti.getIsMultiShot(shot)
    return shot == S.SHOT_TWO_SHOT or shot == S.SHOT_PAN_ACROSS or shot == S.SHOT_UNLOADING
end

------------------------------------------------------------------- two-shot

---Where the two-shot puts the camera for a pair right now.
---@param perpX number|nil @Side reference to stay on (the last frame's)
---@return table @{x, y, z, lookX, lookY, lookZ, half, perpX, perpZ}
local function getTwoShotGeometry(camera, a, b, side, scale, perpX, perpZ)
    local ax, ay, az = getAim(a)
    local bx, by, bz = getAim(b)
    local midX, midY, midZ = (ax + bx) * 0.5, (ay + by) * 0.5, (az + bz) * 0.5
    local dx, dz = bx - ax, bz - az
    local gap = math.sqrt(dx * dx + dz * dz)
    local px, pz
    if gap > 1 then
        px, pz = dz / gap * side, -dx / gap * side
    else
        local hx, _, hz = localDirectionToWorld(a.rootNode, 1, 0, 0)
        local length = math.max(math.sqrt(hx * hx + hz * hz), 1e-6)
        px, pz = hx / length * side, hz / length * side
    end
    -- Stay on the same side as the pair turns or passes each other.
    if perpX ~= nil and px * perpX + pz * perpZ < 0 then
        px, pz = -px, -pz
    end

    local half = gap * 0.5 + DroneCamMulti.TWO_SHOT_MARGIN
    local fov = math.rad(camera.settings.fov)
    local distance = camera:capReach(math.max(DroneCamMulti.TWO_SHOT_MIN_DISTANCE, half / math.tan(fov * 0.5)) * scale)
    local height = camera:capHeight(math.max(DroneCamMulti.TWO_SHOT_MIN_HEIGHT, DroneCamMulti.TWO_SHOT_HEIGHT_FACTOR * distance))
    local x, z = midX + px * distance, midZ + pz * distance
    return { x = x, y = getGround(x, z, midY) + height, z = z, lookX = midX, lookY = midY, lookZ = midZ,
             half = half, perpX = px, perpZ = pz }
end

local function planTwoShot(camera, vehicle)
    local partner = camera.peers:getPartner(vehicle, DroneCamMulti.TWO_SHOT_MAX_GAP)
    if partner == nil then
        return nil, "no other vehicle working the field"
    end
    local first = camera.director ~= nil and camera.director.side or 1
    local aims = { { getAim(vehicle) }, { getAim(partner.vehicle) } }
    for _, side in ipairs({ first, -first }) do
        for _, scale in ipairs(DroneCamMulti.TWO_SHOT_DISTANCES) do
            local g = getTwoShotGeometry(camera, vehicle, partner.vehicle, side, scale)
            if getIsGoodSpot(g.x, g.y, g.z, aims) then
                return { shot = S.SHOT_TWO_SHOT, partner = partner.vehicle, side = side, scale = scale,
                         perpX = g.perpX, perpZ = g.perpZ, x = g.x, y = g.y, z = g.z }
            end
        end
    end
    return nil, "no clear spot to see both from"
end

----------------------------------------------------------------- pan across

local function planPanAcross(camera, vehicle)
    local approach = camera.peers:getApproach(vehicle)
    if approach == nil then
        return nil, "no tractor and trailer coming to a combine"
    end
    if approach.gap < DroneCamMulti.PAN_MIN_SEPARATION then
        return nil, "the trailer is already at the combine"
    end

    local cx, cy, cz = getAim(approach.combine)
    local hx, hy, hz = getAim(approach.hauler)
    local dx, dz = hx - cx, hz - cz
    local gap = math.max(math.sqrt(dx * dx + dz * dz), 1)
    local ux, uz = dx / gap, dz / gap
    local baseX, baseZ = cx + ux * gap * DroneCamMulti.PAN_ALONG, cz + uz * gap * DroneCamMulti.PAN_ALONG
    local out = math.max(DroneCamMulti.PAN_MIN_OUT, gap * DroneCamMulti.PAN_OUT_FACTOR)
    local aims = { { cx, cy, cz }, { hx, hy, hz } }

    local first = camera.director ~= nil and camera.director.side or 1
    for _, side in ipairs({ first, -first }) do
        for _, step in ipairs(DroneCamMulti.PAN_OUT_STEPS) do
            local reach = camera:capReach(out * step)
            local x, z = baseX + uz * side * reach, baseZ - ux * side * reach
            local y = getGround(x, z, cy) + DroneCamMulti.PAN_HEIGHT
            if getIsGoodSpot(x, y, z, aims) then
                return { shot = S.SHOT_PAN_ACROSS, combine = approach.combine, hauler = approach.hauler,
                         x = x, y = y, z = z }
            end
        end
    end
    return nil, "no clear spot to see both from"
end

---@return number @0 while holding on the combine (from when the camera has
---    glided in), easing to 1 on the tractor and trailer
local function getPanProgress(camera)
    local length = camera.shotDuration > 0 and camera.shotDuration or DroneCamMulti.PAN_DEFAULT_LENGTH
    local start = (camera.shotBlendDuration or 0) + DroneCamMulti.PAN_HOLD
    local sweep = math.max((length - start) * DroneCamMulti.PAN_SWEEP, 1)
    return smoothstep((camera.shotElapsed - start) / sweep)
end

------------------------------------------------------------------ unloading

---Where the unloading shot puts the camera right now.
---@return table @{x, y, z, lookX, lookY, lookZ, span}
local function getUnloadGeometry(unloading, out, along)
    local combine, carrier = unloading.combine, DroneCamPeers.getLoadCarrier(unloading.trailer)
    local cx, cy, cz = getWorldTranslation(combine.rootNode)
    local tx, ty, tz = getWorldTranslation(carrier.rootNode)
    local dx, dz = tx - cx, tz - cz
    local gap = math.max(math.sqrt(dx * dx + dz * dz), 0.1)
    local ux, uz = dx / gap, dz / gap

    local fx, _, fz = localDirectionToWorld(combine.rootNode, 0, 0, 1)
    local length = math.max(math.sqrt(fx * fx + fz * fz), 1e-6)
    fx, fz = fx / length, fz / length

    local x, z = tx + ux * out + fx * along, tz + uz * out + fz * along
    local top = math.max(getTop(combine), getTop(unloading.trailer))
    local y = getGround(x, z, ty) + top + DroneCamMulti.UNLOAD_ABOVE

    -- Between the pipe's end and the trailer, so both are in.
    local px, py, pz = tx, ty + 2, tz
    if unloading.pipeNode ~= nil and entityExists(unloading.pipeNode) then
        px, py, pz = getWorldTranslation(unloading.pipeNode)
    end
    return { x = x, y = y, z = z, lookX = (px + tx) * 0.5, lookY = (py + ty + 1) * 0.5, lookZ = (pz + tz) * 0.5,
             span = gap + 2 * DroneCamMulti.UNLOAD_MARGIN }
end

local function planUnloading(camera, vehicle)
    local unloading = camera.peers:getUnloading()
    if unloading == nil then
        return nil, "nothing unloading"
    end
    local aims = { { getAim(unloading.combine) }, { getAim(DroneCamPeers.getLoadCarrier(unloading.trailer)) } }
    for _, out in ipairs(DroneCamMulti.UNLOAD_OUT) do
        for _, along in ipairs(DroneCamMulti.UNLOAD_ALONG) do
            local g = getUnloadGeometry(unloading, out, along)
            if getIsGoodSpot(g.x, g.y, g.z, aims) then
                return { shot = S.SHOT_UNLOADING, combine = unloading.combine, trailer = unloading.trailer,
                         out = out, along = along, x = g.x, y = g.y, z = g.z }
            end
        end
    end
    return nil, "no clear spot beside the trailer"
end

------------------------------------------------------------------- shared

DroneCamMulti.PLANNERS = {
    [S.SHOT_TWO_SHOT] = planTwoShot,
    [S.SHOT_PAN_ACROSS] = planPanAcross,
    [S.SHOT_UNLOADING] = planUnloading
}

---@return table|nil, string|nil @Plan, or nil and why not
function DroneCamMulti.plan(camera, vehicle, shot)
    if camera.peers == nil or not camera.settings.multiVehicle then
        return nil, "multi-vehicle shots are off"
    end
    local planner = DroneCamMulti.PLANNERS[shot]
    if planner == nil then
        return nil, "not a multi-vehicle shot"
    end
    return planner(camera, vehicle)
end

---@return boolean
local function getIsAlive(vehicle)
    return vehicle ~= nil and vehicle.rootNode ~= nil and entityExists(vehicle.rootNode)
end

---Ends a multi-vehicle shot when what it was filming has gone: the partner
---stopped working or left, the trailer reached the combine, unloading ended.
function DroneCamMulti.update(camera, dtSeconds, vehicle)
    local plan = camera.plan
    if plan == nil or not DroneCamMulti.getIsMultiShot(plan.shot) or plan.shot ~= camera.shot or plan.isLost then
        return
    end
    local peers = camera.peers
    local reason = nil

    if plan.shot == S.SHOT_TWO_SHOT then
        local peer = peers:getPeer(plan.partner)
        if not getIsAlive(plan.partner) or peer == nil or not peer.isSameField
            or peer.distance > DroneCamMulti.TWO_SHOT_MAX_GAP * 1.2 then
            reason = "the other vehicle left"
        end
    elseif plan.shot == S.SHOT_PAN_ACROSS then
        if not getIsAlive(plan.combine) or not getIsAlive(plan.hauler) then
            reason = "a vehicle went away"
        end
    else
        local unloading = peers:getUnloading()
        if unloading == nil or unloading.combine ~= plan.combine or unloading.trailer ~= plan.trailer then
            reason = "unloading finished"
        end
    end

    if reason ~= nil then
        plan.isLost = true
        plan.lostReason = reason
    end
end

---@return number, number, number, number, number, number, nil, nil, number @Position and look target
function DroneCamMulti.getTransform(camera, vehicle, shot)
    local plan = camera.plan
    local aimX, aimY, aimZ = getAim(vehicle)
    if plan == nil or plan.shot ~= shot then
        local x, y, z = getWorldTranslation(vehicle.rootNode)
        return x, y + camera.settings.chaseHeight, z, aimX, aimY, aimZ, nil, nil, 0
    end

    if shot == S.SHOT_TWO_SHOT then
        if not getIsAlive(plan.partner) then
            return plan.x, plan.y, plan.z, aimX, aimY, aimZ, nil, nil, 0
        end
        local g = getTwoShotGeometry(camera, vehicle, plan.partner, plan.side, plan.scale, plan.perpX, plan.perpZ)
        plan.perpX, plan.perpZ = g.perpX, g.perpZ
        plan.x, plan.y, plan.z = g.x, g.y, g.z
        plan.frameSize, plan.lookX, plan.lookY, plan.lookZ = g.half * 2, g.lookX, g.lookY, g.lookZ
        return g.x, g.y, g.z, g.lookX, g.lookY, g.lookZ, nil, nil, 0
    end

    if shot == S.SHOT_PAN_ACROSS then
        local cx, cy, cz = aimX, aimY, aimZ
        if getIsAlive(plan.combine) then cx, cy, cz = getAim(plan.combine) end
        local hx, hy, hz = cx, cy, cz
        if getIsAlive(plan.hauler) then hx, hy, hz = getAim(plan.hauler) end
        local t = getPanProgress(camera)
        return plan.x, plan.y, plan.z, lerp(cx, hx, t), lerp(cy, hy, t), lerp(cz, hz, t), nil, nil, 0
    end

    -- Unloading.
    if not getIsAlive(plan.combine) or not getIsAlive(plan.trailer) then
        return plan.x, plan.y, plan.z, aimX, aimY, aimZ, nil, nil, 0
    end
    local unloading = camera.peers:getUnloading()
    local pipeNode = unloading ~= nil and unloading.combine == plan.combine and unloading.pipeNode or nil
    local g = getUnloadGeometry({ combine = plan.combine, trailer = plan.trailer, pipeNode = pipeNode }, plan.out, plan.along)
    plan.x, plan.y, plan.z = g.x, g.y, g.z
    plan.frameSize, plan.lookX, plan.lookY, plan.lookZ = g.span, g.lookX, g.lookY, g.lookZ
    return g.x, g.y, g.z, g.lookX, g.lookY, g.lookZ, nil, nil, 0
end

---@return number, number @Tracking 0..1 and terrain clearance
function DroneCamMulti.getTracking(camera, shot)
    local plan = camera.plan
    if shot == S.SHOT_UNLOADING then
        -- Riding alongside when the filmed vehicle is one of the two.
        local rides = plan ~= nil and plan.shot == shot and (camera.vehicle == plan.combine or camera.vehicle == plan.trailer)
        return rides and 1 or 0, DroneCamMulti.UNLOAD_CLEARANCE
    end
    return 0, camera.settings.minClearance
end

---@return number @Field of view in degrees
function DroneCamMulti.getFov(camera, vehicle, shot)
    local plan = camera.plan
    local fov = camera.settings.fov
    if plan == nil or plan.shot ~= shot then
        return fov
    end
    local maxFov = math.max(fov, DroneCamMulti.MAX_FOV)

    if shot == S.SHOT_PAN_ACROSS then
        local function fovFor(target)
            if not getIsAlive(target) then return fov end
            local x, y, z = getAim(target)
            local distance = math.sqrt((x - plan.x) ^ 2 + (y - plan.y) ^ 2 + (z - plan.z) ^ 2)
            return getFramingFov(distance, DroneCamMulti.PAN_FRAME, DroneCamMulti.PAN_MIN_FOV, fov)
        end
        return lerp(fovFor(plan.combine), fovFor(plan.hauler), getPanProgress(camera))
    end

    if plan.frameSize ~= nil and plan.lookX ~= nil then
        local distance = math.sqrt((plan.lookX - plan.x) ^ 2 + (plan.lookY - plan.y) ^ 2 + (plan.lookZ - plan.z) ^ 2)
        local minFov = shot == S.SHOT_UNLOADING and DroneCamMulti.UNLOAD_MIN_FOV or DroneCamCreator.SPOT_MIN_FOV
        return getFramingFov(distance, plan.frameSize, minFov, maxFov)
    end
    return fov
end
