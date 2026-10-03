---@class DroneCamCamera
---Owns the engine camera node and everything that gives the shot its "drone"
---feel: framerate-independent exponential smoothing, a smoothed vehicle heading
---so U-turns sweep instead of snapping, terrain clamping, obstacle avoidance and
---a gentle blend in and out.
---
---The camera node is linked to a world-space transform group under the scene
---root rather than to the vehicle, so vehicle pitch and roll can never tip or
---gimbal-lock the shot.
DroneCamCamera = {}

local DroneCamCamera_mt = Class(DroneCamCamera)

DroneCamCamera.NEAR_CLIP = 0.5
DroneCamCamera.FAR_CLIP = 8000

---How much the aim point sits above the vehicle's root node, so the shot frames
---the cab rather than the axles.
DroneCamCamera.LOOK_HEIGHT_OFFSET = 2

---Rate at which the obstacle-avoidance height offset is added and removed, in
---metres per second. Climbing is quicker than settling back down so the camera
---never clips a canopy, but also never bobs.
DroneCamCamera.OBSTACLE_RISE_SPEED = 14
DroneCamCamera.OBSTACLE_FALL_SPEED = 4
DroneCamCamera.OBSTACLE_MAX_RISE = 60

---Terrain is sampled on a small grid rather than at a single point so a sharp
---ridge just under the camera still pushes it up.
DroneCamCamera.TERRAIN_SAMPLE_STEP = 3
---Close-ups sit low, so they sample a tighter grid: a ridge 3m away should not
---lift a camera that is filming a wheel.
DroneCamCamera.CLOSEUP_TERRAIN_SAMPLE_STEP = 1

---Below this ratio of horizontal to total length, the view is close enough to
---vertical that its heading is only partly trusted (about 20 degrees from
---straight down).
DroneCamCamera.YAW_TRUST_TILT = 0.35

---Fastest the view may turn left or right, in radians per second. Well above
---anything the vehicle itself does, so it only ever limits camera blends.
DroneCamCamera.MAX_YAW_RATE = math.rad(120)

---Close-ups replace the minClearance height floor with this one.
DroneCamCamera.CLOSEUP_CLEARANCE = 0.6

---Absolute minimum height above the ground for the camera itself, whatever it
---is aiming for. Just above the 0.5m near clip plane.
DroneCamCamera.HARD_GROUND_CLEARANCE = 0.55

---How far close-ups keep from the vehicle's footprint. More than DroneCamRig's
---margin plus fade, so a close-up at rest is never being lifted by them.
DroneCamCamera.CLOSEUP_GAP = 2.3

---Mature crop heights in metres by fruit type name. Generous on purpose: the
---cost of overestimating is a slightly higher shot, of underestimating a
---camera inside the maize. Unknown crops (mods) get the default.
DroneCamCamera.CROP_HEIGHTS = {
    WHEAT = 1.2, BARLEY = 1.1, OAT = 1.3, RYE = 1.6, TRITICALE = 1.4, SPELT = 1.4,
    CANOLA = 1.8, SOYBEAN = 1.1, SUNFLOWER = 2.5, MAIZE = 3.2, SORGHUM = 2.4,
    SUGARCANE = 4.5, COTTON = 1.5, RICE = 1.2, RICELONGGRAIN = 1.2, POPLAR = 8,
    GRASS = 0.8, MEADOW = 0.8, OILSEEDRADISH = 1.0, ALFALFA = 0.9, CLOVER = 0.6,
    POTATO = 0.7, SUGARBEET = 0.7, CARROT = 0.6, PARSNIP = 0.6, REDBEET = 0.6,
    GREENBEAN = 0.8, PEA = 1.0, SPINACH = 0.4, ONION = 0.6, GRAPE = 2.2, OLIVE = 4
}
DroneCamCamera.DEFAULT_CROP_HEIGHT = 2

---Distance kept above the estimated crop top.
DroneCamCamera.CROP_MARGIN = 0.6
DroneCamCamera.CROP_HARD_MARGIN = 0.3

---Crop is only looked up when the camera is lower than this above the ground;
---every wide angle flies far higher than any crop.
DroneCamCamera.CROP_CHECK_HEIGHT = 6

---The crop floor is sampled this far around the target position, then rate
---limited, so the camera rises before it reaches the edge of standing crop
---rather than jumping when it gets there.
DroneCamCamera.CROP_SAMPLE_STEP = 2
DroneCamCamera.CROP_RISE_SPEED = 20
DroneCamCamera.CROP_FALL_SPEED = 3

local function lerp(from, to, alpha)
    return from + (to - from) * alpha
end

---Framerate-independent smoothing factor.
---@param dtSeconds number
---@param stiffness number @Larger is tighter; 1/stiffness is the time constant
---@return number @Blend factor in [0, 1]
local function smoothingAlpha(dtSeconds, stiffness)
    return 1 - math.exp(-dtSeconds * stiffness)
end

---Wraps an angle difference into [-pi, pi] so smoothing always takes the short
---way round and a heading crossing north does not spin the camera.
local function normaliseAngleDiff(diff)
    while diff > math.pi do
        diff = diff - 2 * math.pi
    end
    while diff < -math.pi do
        diff = diff + 2 * math.pi
    end
    return diff
end

---@return integer @The terrain root node for height queries
local function getTerrainNode()
    if g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
        return g_currentMission.terrainRootNode
    end
    return g_terrainNode
end

---Collision mask for the clearance raycast. Vehicles are deliberately excluded:
---the camera should look past the tractor it is filming, not climb over it.
---Built lazily because CollisionFlag is a game global.
local obstacleCollisionMask = nil
local function getObstacleCollisionMask()
    if obstacleCollisionMask == nil then
        obstacleCollisionMask = CollisionFlag.STATIC_OBJECT + CollisionFlag.BUILDING + CollisionFlag.TREE
    end
    return obstacleCollisionMask
end

---@param settings DroneCamSettings
---@return DroneCamCamera
function DroneCamCamera.new(settings)
    local self = setmetatable({}, DroneCamCamera_mt)

    self.settings = settings

    self.rootTransform = createTransformGroup("droneCamRoot")
    link(getRootNode(), self.rootTransform)

    self.cameraNode = createCamera("droneCam", math.rad(settings.fov), DroneCamCamera.NEAR_CLIP, DroneCamCamera.FAR_CLIP)
    link(self.rootTransform, self.cameraNode)
    setFastShadowUpdate(self.cameraNode, true)

    g_cameraManager:addCamera(self.cameraNode, nil, false)

    self.appliedFov = nil
    self:setFov(settings.fov)

    self.director = DroneCamDirector.new(settings)
    self.director.isShotAvailable = function(shot)
        return self:getIsShotAvailable(shot)
    end
    self.director.isShotStillUsable = function(shot)
        return self:getIsShotStillUsable(shot)
    end

    self.frameId = 0
    self.vehicleSpeed = 0

    self:resetState()

    return self
end

---Releases the camera node. Safe to call more than once.
function DroneCamCamera:delete()
    if self.cameraNode ~= nil then
        g_cameraManager:removeCamera(self.cameraNode)
        self.cameraNode = nil
    end

    if self.rootTransform ~= nil then
        -- Deleting the parent also deletes the camera node it holds.
        delete(self.rootTransform)
        self.rootTransform = nil
    end
end

function DroneCamCamera:resetState()
    self.posX, self.posY, self.posZ = 0, 0, 0
    self.lookX, self.lookY, self.lookZ = 0, 0, 1
    self.heading = 0
    self.orbitAngle = 0
    self.heightBoost = 0
    self.blendTime = 0
    self.returnNode = nil
    self.blendOutActive = false
    self.vehicleHeading = 0
    self:resetTracking()
    self:resetShot()
end

---Forgets per-flight state used by the close-ups.
function DroneCamCamera:resetTracking()
    self.rig = nil
    self.lastVehicleX, self.lastVehicleY, self.lastVehicleZ = nil, nil, nil
    self.cropFloor = 0
    self.lastRotY = nil
    -- The flight starts from the vehicle's own camera, which is usually inside
    -- the cab. The hard floors that keep the camera out of the vehicle and the
    -- crop only take hold once it has flown clear, or they would yank it out.
    self.floorsArmed = false
end

---Forgets which angle is on screen, so the next frame takes up the wanted one
---directly instead of blending to it.
function DroneCamCamera:resetShot()
    self.shot = nil
    self.shotSide = 1
    self.plan = nil
    self.planCache = {}
    self.shotElapsed = 0
    self.shotDuration = 0
    self.fromPose = nil
    self.shotBlendElapsed = 0
    self.shotBlendDuration = 0
    self.blendBearingDiff = nil

    if self.director ~= nil then
        self.director:reset()
    end
end

---@return integer|nil
function DroneCamCamera:getCameraNode()
    return self.cameraNode
end

---Seeds the smoothing state from an existing camera node so the drone starts
---exactly where the player was looking and glides out from there.
---@param fromNode integer|nil @Camera node currently showing the scene
---@param vehicle table @Vehicle to be filmed
function DroneCamCamera:activate(fromNode, vehicle)
    self.heightBoost = 0
    self.blendTime = 0
    self.returnNode = nil
    self.blendOutActive = false
    self:resetTracking()
    self:resetShot()

    local seeded = false

    if fromNode ~= nil and entityExists(fromNode) then
        local cx, cy, cz = getWorldTranslation(fromNode)
        local dx, dy, dz = localDirectionToWorld(fromNode, 0, 0, -1)

        self.posX, self.posY, self.posZ = cx, cy, cz
        self.lookX, self.lookY, self.lookZ = cx + dx * 20, cy + dy * 20, cz + dz * 20
        seeded = true
    end

    if vehicle ~= nil and vehicle.rootNode ~= nil then
        local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
        local dirX, _, dirZ = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)

        self.heading = math.atan2(dirX, dirZ)
        self.vehicleHeading = self.heading
        -- Start the orbit behind the vehicle so the first frame is not a
        -- side-on view that then swings round.
        self.orbitAngle = self.heading + math.pi

        if not seeded then
            self.posX, self.posY, self.posZ = vx, vy + self.settings.chaseHeight, vz
            self.lookX, self.lookY, self.lookZ = vx, vy, vz
        end
    end

    self:setFov(self.settings.fov)
    g_cameraManager:setActiveCamera(self.cameraNode)
end

---Starts flying the shot back towards the camera that will take over, so the
---hand-off is a move rather than a cut.
---A nil node means there is nothing to fly back to, in which case the next
---update reports the blend as finished straight away.
---@param toNode integer|nil @Camera node that will become active afterwards
function DroneCamCamera:beginBlendOut(toNode)
    self.returnNode = toNode
    self.blendOutActive = true
    self.blendTime = 0
end

---Abandons a blend-out and resumes filming, used when work restarts mid-handoff.
function DroneCamCamera:cancelBlendOut()
    self.returnNode = nil
    self.blendOutActive = false
    self.blendTime = 0
end

---@return boolean @True while a blend-out is in progress
function DroneCamCamera:getIsBlendingOut()
    return self.blendOutActive == true
end

---Sets the camera's field of view, in degrees, if it has changed. Most shots
---use the configured value; the long lens and the fixed spots zoom in.
function DroneCamCamera:setFov(fov)
    if self.cameraNode == nil or (self.appliedFov ~= nil and math.abs(self.appliedFov - fov) < 0.01) then
        return
    end

    setFovY(self.cameraNode, math.rad(fov))
    self.appliedFov = fov
end

---Highest terrain height on a small grid around the given world position.
---@param step number|nil @Grid spacing, TERRAIN_SAMPLE_STEP by default
---@return number
local function getTerrainHeightAround(x, z, step)
    local terrainNode = getTerrainNode()
    if terrainNode == nil then
        return 0
    end

    step = step or DroneCamCamera.TERRAIN_SAMPLE_STEP
    local height = getTerrainHeightAtWorldPos(terrainNode, x, 0, z)

    for offsetX = -step, step, step do
        for offsetZ = -step, step, step do
            local sample = getTerrainHeightAtWorldPos(terrainNode, x + offsetX, 0, z + offsetZ)
            if sample > height then
                height = sample
            end
        end
    end

    return height
end

---@return number @Terrain height straight below the position
local function getTerrainHeightAt(x, z)
    local terrainNode = getTerrainNode()
    if terrainNode == nil then
        return 0
    end
    return getTerrainHeightAtWorldPos(terrainNode, x, 0, z)
end

---Estimated height of the crop standing at a position, 0 for bare ground or
---stubble. Growing crop scales with its growth stage; harvest-ready and later
---stages count as fully grown.
---@return number
function DroneCamCamera.getCropHeightAt(x, z)
    if FSDensityMapUtil == nil or FSDensityMapUtil.getFruitTypeIndexAtWorldPos == nil or g_fruitTypeManager == nil then
        return 0
    end

    local fruitTypeIndex, growthState = FSDensityMapUtil.getFruitTypeIndexAtWorldPos(x, z)
    if fruitTypeIndex == nil or fruitTypeIndex == 0 or growthState == nil or growthState == 0 then
        return 0
    end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil then
        return DroneCamCamera.DEFAULT_CROP_HEIGHT
    end

    if fruitType.cutState ~= nil and fruitType.cutState > 0 and growthState == fruitType.cutState then
        return 0
    end

    local fullHeight = DroneCamCamera.CROP_HEIGHTS[fruitType.name] or DroneCamCamera.DEFAULT_CROP_HEIGHT
    local readyState = fruitType.minHarvestingGrowthState or 0

    if readyState > 0 and growthState < readyState then
        return fullHeight * math.max(growthState / readyState, 0.25)
    end

    return fullHeight
end

---Tallest crop on a small cross of samples around a position.
local function getCropHeightAround(x, z)
    local step = DroneCamCamera.CROP_SAMPLE_STEP
    return math.max(DroneCamCamera.getCropHeightAt(x, z),
                    DroneCamCamera.getCropHeightAt(x + step, z),
                    DroneCamCamera.getCropHeightAt(x - step, z),
                    DroneCamCamera.getCropHeightAt(x, z + step),
                    DroneCamCamera.getCropHeightAt(x, z - step))
end

---Low-amplitude, low-frequency drift so the shot never looks perfectly rigid.
---Two sine terms per axis at incommensurate rates avoid an obvious cycle.
---@return number, number, number
function DroneCamCamera:getSwayOffset()
    if not self.settings.sway then
        return 0, 0, 0
    end

    local amplitude = self.settings.swayAmplitude
    local t = (g_currentMission ~= nil and g_currentMission.time or 0) * 0.001

    local swayX = (math.sin(t * 0.37) * 0.7 + math.sin(t * 0.91) * 0.3) * amplitude
    local swayY = (math.sin(t * 0.29 + 1.7) * 0.7 + math.sin(t * 0.73 + 0.4) * 0.3) * amplitude * 0.6
    local swayZ = (math.sin(t * 0.43 + 3.1) * 0.7 + math.sin(t * 0.83 + 2.2) * 0.3) * amplitude

    return swayX, swayY, swayZ
end

---Computes where the camera wants to be and what it wants to look at, for one
---angle.
---@param vehicle table
---@param mode integer @MODE_CHASE, MODE_TOPDOWN or MODE_ORBIT
---@return number, number, number @Desired camera position
---@return number, number, number @Desired look target
---@return number|nil @Explicit yaw override (used by the top-down mode)
---@return number|nil @Explicit pitch override
---@return number|nil @How much of the override applies; all of it when nil
function DroneCamCamera:getModeTransform(vehicle, mode)
    if DroneCamDirector.getIsCloseUp(mode) then
        return self:getCloseUpTransform(vehicle, mode)
    end

    if DroneCamCreator.getIsCreatorShot(mode) then
        return DroneCamCreator.getTransform(self, vehicle, mode)
    end

    local settings = self.settings
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)

    -- Smoothed heading, expressed as a forward vector.
    local headingX, headingZ = math.sin(self.heading), math.cos(self.heading)

    if mode == DroneCamSettings.MODE_TOPDOWN then
        local yaw = 0
        if not settings.topDownNorthUp then
            -- Screen-up follows the vehicle's heading.
            yaw = math.atan2(-headingX, -headingZ)
        end

        return vx, vy + settings.topDownHeight, vz,
               vx, vy, vz,
               yaw, -math.pi * 0.5
    end

    if mode == DroneCamSettings.MODE_ORBIT then
        local offsetX = math.sin(self.orbitAngle) * settings.orbitRadius
        local offsetZ = math.cos(self.orbitAngle) * settings.orbitRadius

        return vx + offsetX, vy + settings.orbitHeight, vz + offsetZ,
               vx, vy + DroneCamCamera.LOOK_HEIGHT_OFFSET, vz,
               nil, nil
    end

    -- Chase: behind and above, aiming slightly ahead of the vehicle.
    return vx - headingX * settings.chaseDistance,
           vy + settings.chaseHeight,
           vz - headingZ * settings.chaseDistance,
           vx + headingX * settings.chaseLookAhead,
           vy + DroneCamCamera.LOOK_HEIGHT_OFFSET,
           vz + headingZ * settings.chaseLookAhead,
           nil, nil
end

---Measurements of the vehicle combination, taken at most once per frame.
---@return table|nil
function DroneCamCamera:getRig(vehicle)
    if self.rig == nil and vehicle ~= nil then
        self.rig = DroneCamRig.measure(vehicle, self.vehicleHeading)
    end
    return self.rig
end

---Plan for a fixed creator shot, worked out at most once per frame however
---often the director asks while choosing.
---@return table|nil
function DroneCamCamera:getPlan(shot)
    local cached = self.planCache[shot]
    if cached ~= nil and cached.frameId == self.frameId then
        return cached.plan
    end

    local plan = nil
    if self.vehicle ~= nil then
        plan = DroneCamCreator.plan(self, self.vehicle, shot)
    end
    self.planCache[shot] = { frameId = self.frameId, plan = plan }

    return plan
end

---@return boolean @False for a shot with nothing to film or nowhere to film it from
function DroneCamCamera:getIsShotAvailable(shot)
    if shot == DroneCamSettings.SHOT_IMPLEMENT then
        local rig = self:getRig(self.vehicle)
        return rig ~= nil and rig.work ~= nil
    end

    if DroneCamCreator.getNeedsPlan(shot) then
        return self:getPlan(shot) ~= nil
    end

    if DroneCamCreator.getIsCreatorShot(shot) then
        return self:getRig(self.vehicle) ~= nil
    end

    return true
end

---@return boolean @False once the shot on screen can no longer carry on
function DroneCamCamera:getIsShotStillUsable(shot)
    if shot == DroneCamSettings.SHOT_IMPLEMENT then
        return self:getIsShotAvailable(shot)
    end

    if DroneCamCreator.getNeedsPlan(shot) then
        if shot ~= self.shot then
            -- Chosen this frame and not taken up yet: its plan is in the cache.
            return self:getPlan(shot) ~= nil
        end
        return self.plan ~= nil and self.plan.shot == shot and not self.plan.isLost
    end

    return true
end

---@return number @How far through the shot on screen we are, 0..1
function DroneCamCamera:getShotProgress()
    if self.shotDuration <= 0 then
        return 1
    end
    return math.min(self.shotElapsed / self.shotDuration, 1)
end

---Close-up angles, placed from the measured rig so they scale with it. Every
---position keeps at least CLOSEUP_GAP from the vehicle footprints; heights are
---above the ground at the vehicle and are lifted further by the crop and
---terrain floors in update().
---@return number, number, number, number, number, number, nil, nil
function DroneCamCamera:getCloseUpTransform(vehicle, shot)
    local rig = self:getRig(vehicle)
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)

    if rig == nil then
        return vx, vy + self.settings.chaseHeight, vz, vx, vy, vz, nil, nil
    end

    local side = self.shotSide
    local scale = rig.scale
    local gap = DroneCamCamera.CLOSEUP_GAP
    local ground = rig.ground

    -- Camera and aim point in the rig's frame: x across, z along, y up from the ground.
    local cx, cy, cz, lx, ly, lz

    if shot == DroneCamSettings.SHOT_WHEEL then
        -- Low beside the rear wheel and a little ahead of it, so the tread
        -- turns towards the lens.
        local wheel = DroneCamRig.getRearWheel(rig, side)
        local wheelHeight = math.max(wheel.radius, 0.4)

        cx = side * (math.max(rig.rootHalfWidth, math.abs(wheel.lx) + wheel.radius * 0.5) + gap)
        cz = wheel.lz + wheel.radius * 1.5
        cy = math.max(wheelHeight, DroneCamCamera.CLOSEUP_CLEARANCE)
        lx, ly, lz = wheel.lx, wheelHeight, wheel.lz

    elseif shot == DroneCamSettings.SHOT_IMPLEMENT and rig.work ~= nil then
        local work = rig.work

        if work.isFront then
            -- Header or front mower: off the end of it and a little ahead,
            -- watching the crop go in. There is no "behind" that is not the
            -- vehicle itself.
            cx = side * (math.max(math.abs(work.lx) + work.halfWidth, rig.halfWidth) + gap)
            cz = work.lz + 1.5 * scale
            cy = 1.6 * scale
            lx, ly, lz = work.lx + side * work.halfWidth * 0.5, 0.8, work.lz
        else
            -- Behind the rearmost implement, low, looking forward and down at
            -- the strip it has just worked.
            cx = work.lx + side * work.halfWidth * 0.35
            cz = rig.rear - gap - 0.15 * work.halfWidth
            cy = 1.3 * scale + 0.1 * work.halfWidth
            lx, ly, lz = work.lx, 0.2, math.max(work.lz - 1, rig.rear + 0.5)
        end

    elseif shot == DroneCamSettings.SHOT_SIDE then
        -- About 3m up and 8m out from the side, level with the middle of the rig.
        local middle = (rig.front + rig.rear) * 0.5
        cx = side * (rig.halfWidth + 8 * scale)
        cz = middle
        cy = 3 * scale
        lx, ly, lz = 0, rig.rootHeight * 0.5, middle

    elseif shot == DroneCamSettings.SHOT_FRONT then
        -- Ahead and low, just off the line, looking back at the vehicle
        -- coming towards the lens.
        cx = side * 1.5 * scale
        cz = rig.front + 10 * scale
        cy = math.max(scale, DroneCamCamera.CLOSEUP_CLEARANCE)
        lx, ly, lz = 0, rig.rootHeight * 0.6, rig.rootFront

    else
        -- Rear quarter (and the implement shot's fallback): behind and out to
        -- one side at cab height, aiming at the cab.
        cx = side * (rig.halfWidth + 4 * scale)
        cz = rig.rootRear - 4 * scale
        cy = rig.rootHeight * 0.85
        lx, ly, lz = 0, rig.rootHeight * 0.75, (rig.rootFront + rig.rootRear) * 0.5
    end

    local px, pz = DroneCamRig.toWorld(rig, cx, cz)
    local tx, tz = DroneCamRig.toWorld(rig, lx, lz)

    return px, ground + cy, pz, tx, ground + ly, tz, nil, nil
end

---Radius below which a pose is treated as directly overhead and so has no
---meaningful bearing of its own.
DroneCamCamera.OVERHEAD_RADIUS = 1

---How far above the vehicle's roof a close-up blend arcs at the peak of a
---quarter turn or more round it.
DroneCamCamera.ARC_CLEARANCE = 2

---Average speed limit for a glide between shots, in metres per second, and the
---longest a glide may take however far it has to go.
DroneCamCamera.MAX_GLIDE_SPEED = 60
DroneCamCamera.MAX_GLIDE_TIME = 8

local function smoothstep(t)
    return t * t * (3 - 2 * t)
end

---How tightly an angle follows the vehicle's movement (see update()) and how
---high above the terrain it must stay.
---@return number, number @Tracking 0..1, terrain clearance in metres
function DroneCamCamera:getShotTracking(shot)
    if DroneCamDirector.getIsCloseUp(shot) then
        return 1, DroneCamCamera.CLOSEUP_CLEARANCE
    end
    if DroneCamCreator.getIsCreatorShot(shot) then
        return DroneCamCreator.getTracking(self, shot)
    end
    return 0, self.settings.minClearance
end

---@return number @Field of view for a shot, in degrees
function DroneCamCamera:getShotFov(vehicle, shot)
    if DroneCamCreator.getIsCreatorShot(shot) then
        return DroneCamCreator.getFov(self, vehicle, shot)
    end
    return self.settings.fov
end

---Describes one angle relative to the vehicle: bearing, radius and height of the
---camera around it, and the look target as an offset from it. Blending in these
---terms swings the camera round the vehicle at a distance, where blending world
---positions would fly it straight through the tractor.
---
---Bearings, yaw and the look offset are measured from the vehicle's heading, so
---a pose frozen at the start of a blend turns with the vehicle: a close-up
---being left during a turn stays beside the wheel instead of the wheel driving
---into it.
---@return table
function DroneCamCamera:getShotPose(vehicle, mode)
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    local px, py, pz, lx, ly, lz, yaw, pitch, overrideWeight = self:getModeTransform(vehicle, mode)
    local dx, dz = px - vx, pz - vz
    local heading = self.vehicleHeading
    local fwdX, fwdZ = math.sin(heading), math.cos(heading)
    local lookDX, lookDZ = lx - vx, lz - vz
    local tracking, clearance = self:getShotTracking(mode)

    return {
        radius = math.sqrt(dx * dx + dz * dz),
        bearing = math.atan2(dx, dz) - heading,
        height = py - vy,
        lookAcross = lookDX * fwdZ - lookDZ * fwdX,
        lookY = ly - vy,
        lookAlong = lookDX * fwdX + lookDZ * fwdZ,
        yaw = yaw ~= nil and yaw - heading or nil, pitch = pitch,
        overrideWeight = yaw ~= nil and (overrideWeight or 1) or 0,
        tracking = tracking,
        clearance = clearance,
        fov = self:getShotFov(vehicle, mode)
    }
end

---Interpolates between two poses.
---@param from table
---@param to table
---@param t number @Blend factor in [0, 1]
---@return table
function DroneCamCamera:blendPoses(from, to, t)
    -- An overhead pose has no bearing of its own, so borrow the other one's.
    local fromBearing, toBearing = from.bearing, to.bearing
    if from.radius < DroneCamCamera.OVERHEAD_RADIUS then
        fromBearing = toBearing
    elseif to.radius < DroneCamCamera.OVERHEAD_RADIUS then
        toBearing = fromBearing
    end

    -- Both ends move every frame (the vehicle turns, the orbit circles), so a
    -- swing of about half a turn could flip between going left and going right.
    -- Keep whichever way round the blend started on.
    local bearingDiff = normaliseAngleDiff(toBearing - fromBearing)
    if self.blendBearingDiff ~= nil then
        bearingDiff = self.blendBearingDiff + normaliseAngleDiff(bearingDiff - self.blendBearingDiff)
    end
    self.blendBearingDiff = bearingDiff

    -- A low close-up swinging round to the other side would sweep past the
    -- implement at wheel height. Lift the path into an arc over the vehicle,
    -- more the further round it goes, so it flies over instead of being
    -- shoved up by the vehicle floor at the last moment.
    local arcLift = 0
    if from.tracking > 0 or to.tracking > 0 then
        local rig = self.rig
        local vehicleHeight = rig ~= nil and rig.rootHeight or DroneCamRig.DEFAULT_HEIGHT
        local swing = math.min(math.abs(bearingDiff) / (math.pi * 0.5), 1)
        arcLift = (vehicleHeight + DroneCamCamera.ARC_CLEARANCE) * swing * math.sin(math.pi * t)
    end

    local yaw, pitch
    if from.overrideWeight > 0 and to.overrideWeight > 0 then
        yaw = from.yaw + normaliseAngleDiff(to.yaw - from.yaw) * t
        pitch = lerp(from.pitch, to.pitch, t)
    elseif from.overrideWeight > 0 then
        yaw, pitch = from.yaw, from.pitch
    elseif to.overrideWeight > 0 then
        yaw, pitch = to.yaw, to.pitch
    end

    return {
        radius = lerp(from.radius, to.radius, t),
        bearing = fromBearing + bearingDiff * t,
        height = lerp(from.height, to.height, t) + arcLift,
        lookAcross = lerp(from.lookAcross, to.lookAcross, t),
        lookY = lerp(from.lookY, to.lookY, t),
        lookAlong = lerp(from.lookAlong, to.lookAlong, t),
        yaw = yaw, pitch = pitch,
        overrideWeight = lerp(from.overrideWeight, to.overrideWeight, t),
        tracking = lerp(from.tracking, to.tracking, t),
        clearance = lerp(from.clearance, to.clearance, t),
        fov = lerp(from.fov, to.fov, t)
    }
end

---Times the glide into a newly entered shot. A long glide also extends the
---director's hold on the shot by the extra time, so a shot that is a long way
---off still gets its full time on screen once the camera arrives.
function DroneCamCamera:startGlide(vehicle, shot)
    self.shotBlendDuration = self:getGlideDuration(self.fromPose, self:getShotPose(vehicle, shot))

    local extra = self.shotBlendDuration - self.settings.shotBlendTime
    if extra > 0 and self.director.isRunning and self.director.shot == shot then
        self.director.shotLength = self.director.shotLength + extra
    end
end

---Pose describing where the camera is right now, in the same vehicle-relative
---terms as getShotPose, to glide out from at take-off.
---@return table
function DroneCamCamera:getCameraPose(vehicle)
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    local heading = self.vehicleHeading
    local fwdX, fwdZ = math.sin(heading), math.cos(heading)
    local dx, dz = self.posX - vx, self.posZ - vz
    local lookDX, lookDZ = self.lookX - vx, self.lookZ - vz

    return {
        radius = math.sqrt(dx * dx + dz * dz),
        bearing = math.atan2(dx, dz) - heading,
        height = self.posY - vy,
        lookAcross = lookDX * fwdZ - lookDZ * fwdX,
        lookY = self.lookY - vy,
        lookAlong = lookDX * fwdX + lookDZ * fwdZ,
        overrideWeight = 0,
        -- The vehicle camera rides with the vehicle.
        tracking = 1,
        clearance = DroneCamCamera.CLOSEUP_CLEARANCE,
        fov = self.appliedFov or self.settings.fov
    }
end

---How long the glide between two poses takes: shotBlendTime normally, longer
---when the camera has a long way to travel (a fixed spot 150m off, the start of
---a push-in), so it never streaks across the sky.
---@return number @Seconds
function DroneCamCamera:getGlideDuration(from, to)
    local minimum = self.settings.shotBlendTime
    if minimum <= 0 then
        return 0
    end

    local turn = 0
    if from.radius >= DroneCamCamera.OVERHEAD_RADIUS and to.radius >= DroneCamCamera.OVERHEAD_RADIUS then
        turn = math.abs(normaliseAngleDiff(to.bearing - from.bearing))
    end

    local radial = to.radius - from.radius
    local around = (from.radius + to.radius) * 0.5 * turn
    local vertical = to.height - from.height
    local travel = math.sqrt(radial * radial + around * around + vertical * vertical)

    return math.min(math.max(travel / DroneCamCamera.MAX_GLIDE_SPEED, minimum), math.max(DroneCamCamera.MAX_GLIDE_TIME, minimum))
end

---@return number @Eased progress of the current change of angle, 1 when settled
function DroneCamCamera:getShotBlendAlpha()
    if self.fromPose == nil then
        return 1
    end

    local duration = self.shotBlendDuration
    if duration <= 0 then
        return 1
    end

    return smoothstep(math.min(self.shotBlendElapsed / duration, 1))
end

---@return table @Pose currently being aimed for, mid-blend or not
function DroneCamCamera:getCurrentPose(vehicle)
    local pose = self:getShotPose(vehicle, self.shot)

    if self.fromPose ~= nil then
        pose = self:blendPoses(self.fromPose, pose, self:getShotBlendAlpha())
    end

    return pose
end

---@param heading number|nil @Raw vehicle heading in radians
---@return integer @Angle that should be on screen
function DroneCamCamera:getWantedShot(dtSeconds, heading)
    local mode = self.settings.mode

    if not DroneCamSettings.getIsAutoMode(mode) then
        if self.director.isRunning then
            self.director:reset()
        end
        return mode
    end

    local isStory = mode == DroneCamSettings.MODE_AUTO

    if not self.director.isRunning then
        -- Open on whatever is already on screen, so choosing the mode is not
        -- itself a change of angle.
        self.director:start(self.shot, heading, isStory)
    else
        self.director:setStory(isStory)
    end

    return self.director:update(dtSeconds, heading)
end

---Takes up a new shot: its plan (if it is a fixed shot), its clock and its side.
function DroneCamCamera:enterShot(shot)
    self.shot = shot
    self.shotSide = self.director.side
    self.shotElapsed = 0
    self.shotDuration = self.director.isRunning and self.director.shotLength or 0
    self.plan = DroneCamCreator.getNeedsPlan(shot) and self:getPlan(shot) or nil
end

---Follows the wanted angle, starting a blend whenever it changes.
---@param heading number|nil @Raw vehicle heading in radians
function DroneCamCamera:updateShot(dtSeconds, vehicle, heading)
    self.shotElapsed = self.shotElapsed + dtSeconds

    local wanted = self:getWantedShot(dtSeconds, heading)

    if self.shot == nil then
        -- First frame after activation: glide out from wherever the vehicle
        -- camera left the drone, like any other change of shot, so taking off
        -- to an establishing shot 400m away is a flight and not a streak.
        self.fromPose = self:getCameraPose(vehicle)
        self.shotBlendElapsed = 0
        self.blendBearingDiff = nil
        self:enterShot(wanted)
        self:startGlide(vehicle, wanted)
    elseif wanted ~= self.shot then
        -- Freeze wherever the camera is aiming right now, part-way through an
        -- earlier blend included, so a quick second change never jumps. The
        -- director has already moved on to the next shot by now, so the
        -- outgoing one is framed with its own side, plan and progress, which
        -- enterShot only replaces afterwards.
        self.fromPose = self:getCurrentPose(vehicle)
        self.shotBlendElapsed = 0
        self.blendBearingDiff = nil
        self:enterShot(wanted)
        self:startGlide(vehicle, wanted)

        if wanted == DroneCamSettings.MODE_ORBIT then
            -- Start circling from the camera's current bearing rather than
            -- wherever the orbit angle last happened to be.
            local vx, _, vz = getWorldTranslation(vehicle.rootNode)
            local dx, dz = self.posX - vx, self.posZ - vz
            if dx * dx + dz * dz > DroneCamCamera.OVERHEAD_RADIUS * DroneCamCamera.OVERHEAD_RADIUS then
                self.orbitAngle = math.atan2(dx, dz)
            else
                self.orbitAngle = self.heading + math.pi
            end
        end
    elseif self.fromPose ~= nil then
        self.shotBlendElapsed = self.shotBlendElapsed + dtSeconds

        if self.shotBlendElapsed >= self.shotBlendDuration then
            self.fromPose = nil
            self.blendBearingDiff = nil
        end
    end
end

---Desired transform for the angle on screen, blended while it changes.
---@return number, number, number @Desired camera position
---@return number, number, number @Desired look target
---@return number|nil, number|nil @Yaw and pitch override
---@return number @How much of the override to apply, 0..1
---@return number, number @Tracking 0..1 and terrain clearance, see getShotTracking
---@return number @Field of view in degrees
function DroneCamCamera:getShotTransform(vehicle)
    if self.fromPose == nil then
        local px, py, pz, lx, ly, lz, yaw, pitch, weight = self:getModeTransform(vehicle, self.shot)
        local tracking, clearance = self:getShotTracking(self.shot)
        return px, py, pz, lx, ly, lz, yaw, pitch, yaw ~= nil and (weight or 1) or 0,
               tracking, clearance, self:getShotFov(vehicle, self.shot)
    end

    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    local pose = self:getCurrentPose(vehicle)
    local heading = self.vehicleHeading
    local fwdX, fwdZ = math.sin(heading), math.cos(heading)
    local bearing = pose.bearing + heading

    return vx + math.sin(bearing) * pose.radius,
           vy + pose.height,
           vz + math.cos(bearing) * pose.radius,
           vx + fwdZ * pose.lookAcross + fwdX * pose.lookAlong,
           vy + pose.lookY,
           vz - fwdX * pose.lookAcross + fwdZ * pose.lookAlong,
           pose.yaw ~= nil and pose.yaw + heading or nil, pose.pitch, pose.overrideWeight,
           pose.tracking, pose.clearance, pose.fov
end

---Raises the camera while the line from the aim point to the camera is blocked
---by a tree or a building, and lets it settle again once the view is clear.
---Raising rather than zooming in keeps the framing consistent.
---@param dtSeconds number
function DroneCamCamera:updateObstacleClearance(dtSeconds)
    local dx = self.posX - self.lookX
    local dy = self.posY - self.lookY
    local dz = self.posZ - self.lookZ
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

    local isBlocked = false

    if distance > 1 then
        local invDistance = 1 / distance
        local hitId, _, _, _, hitDistance = RaycastUtil.raycastClosest(
            self.lookX, self.lookY, self.lookZ,
            dx * invDistance, dy * invDistance, dz * invDistance,
            distance, getObstacleCollisionMask())

        -- Ignore hits right at the far end: that is usually the ground the
        -- camera is already clearing, not something between us and the vehicle.
        if hitId ~= nil and hitId ~= 0 and hitDistance ~= nil and hitDistance < distance - 1 then
            isBlocked = true
        end
    end

    if isBlocked then
        self.heightBoost = math.min(self.heightBoost + DroneCamCamera.OBSTACLE_RISE_SPEED * dtSeconds,
                                    DroneCamCamera.OBSTACLE_MAX_RISE)
    else
        self.heightBoost = math.max(self.heightBoost - DroneCamCamera.OBSTACLE_FALL_SPEED * dtSeconds, 0)
    end
end

---No vehicle reaches this high, so above it the rig is not even measured.
DroneCamCamera.VEHICLE_CHECK_HEIGHT = 10

---@return table|nil @The rig, if the position is low enough for it to matter
function DroneCamCamera:getRigNear(vehicle, x, y, z)
    if y - getTerrainHeightAt(x, z) > DroneCamCamera.VEHICLE_CHECK_HEIGHT then
        return nil
    end
    return self:getRig(vehicle)
end

---Raises a desired position over standing crop. The crop is sampled a little
---around the position and the floor it gives is rate limited, so the camera
---climbs on the approach to taller crop instead of jumping at its edge.
---@return number @Adjusted height
function DroneCamCamera:applyCropFloor(dtSeconds, x, y, z)
    local ground = getTerrainHeightAt(x, z)
    local target = 0

    if y - ground < DroneCamCamera.CROP_CHECK_HEIGHT then
        target = getCropHeightAround(x, z)
    end

    if target > self.cropFloor then
        self.cropFloor = math.min(target, self.cropFloor + DroneCamCamera.CROP_RISE_SPEED * dtSeconds)
    else
        self.cropFloor = math.max(target, self.cropFloor - DroneCamCamera.CROP_FALL_SPEED * dtSeconds)
    end

    if self.cropFloor > 0 then
        y = math.max(y, ground + self.cropFloor + DroneCamCamera.CROP_MARGIN)
    end

    return y
end

---Last line of defence, applied to where the camera actually is after
---smoothing: never into the ground, the crop or the vehicle. The floors on the
---desired position normally keep the camera well clear of these, so this only
---bites if smoothing lag or a sudden manoeuvre would otherwise carry it in.
---
---The vehicle floor used here is the eased one, so a camera drifting towards
---the vehicle is lifted progressively over the last metre or so, never
---snapped up in a single frame.
function DroneCamCamera:applyHardFloors(vehicle)
    local ground = getTerrainHeightAt(self.posX, self.posZ)
    self.posY = math.max(self.posY, ground + DroneCamCamera.HARD_GROUND_CLEARANCE)

    local rig = self:getRigNear(vehicle, self.posX, self.posY, self.posZ)

    if not self.floorsArmed then
        if rig == nil or not DroneCamRig.getIsInsideVehicle(rig, self.posX, self.posY, self.posZ, true) then
            self.floorsArmed = true
        end
        return
    end

    if self.posY - ground < DroneCamCamera.CROP_CHECK_HEIGHT then
        local crop = DroneCamCamera.getCropHeightAt(self.posX, self.posZ)
        if crop > 0 then
            self.posY = math.max(self.posY, ground + crop + DroneCamCamera.CROP_HARD_MARGIN)
        end
    end

    if rig ~= nil then
        self.posY = math.max(self.posY, DroneCamRig.getVehicleFloor(rig, self.posX, self.posZ, true))
    end
end

---Advances the shot by one frame.
---@param dt number @Frame time in milliseconds
---@param vehicle table @Vehicle being filmed
---@return boolean @True when a blend-out has finished and the camera should be handed back
function DroneCamCamera:update(dt, vehicle)
    if self.cameraNode == nil or vehicle == nil or vehicle.rootNode == nil then
        return self.blendOutActive == true
    end

    local settings = self.settings
    local dtSeconds = dt * 0.001

    self.frameId = self.frameId + 1

    -- Smooth the vehicle heading first; every mode is built on top of it, so a
    -- U-turn becomes a slow sweeping pan rather than a snap.
    local dirX, _, dirZ = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
    local targetHeading = nil
    if dirX ~= 0 or dirZ ~= 0 then
        targetHeading = math.atan2(dirX, dirZ)
        self.heading = self.heading
            + normaliseAngleDiff(targetHeading - self.heading) * smoothingAlpha(dtSeconds, settings.headingStiffness)
        -- Close-ups are framed on the real heading: a camera beside a wheel
        -- cannot lag the way a drone 40m back can.
        self.vehicleHeading = targetHeading
    end

    self.vehicle = vehicle
    self.rig = nil

    self.orbitAngle = self.orbitAngle + math.rad(settings.orbitSpeed) * dtSeconds

    -- Ground speed, for judging how soon the end of the row comes up.
    local vehicleX, vehicleY, vehicleZ = getWorldTranslation(vehicle.rootNode)
    if self.lastVehicleX ~= nil and dtSeconds > 0 then
        local dx, dz = vehicleX - self.lastVehicleX, vehicleZ - self.lastVehicleZ
        local speed = math.sqrt(dx * dx + dz * dz) / dtSeconds
        self.vehicleSpeed = self.vehicleSpeed + (speed - self.vehicleSpeed) * smoothingAlpha(dtSeconds, 2)
    end

    local isBlendingOut = self.blendOutActive == true
    local desiredPosX, desiredPosY, desiredPosZ
    local desiredLookX, desiredLookY, desiredLookZ
    local desiredFov = settings.fov
    local yawOverride, pitchOverride
    local overrideWeight = 0
    local tracking, clearance = 0, settings.minClearance

    if isBlendingOut then
        self.blendTime = self.blendTime + dtSeconds

        if self.returnNode == nil or not entityExists(self.returnNode) then
            return true
        end

        -- Chase the transform of the camera that is about to take over.
        local cx, cy, cz = getWorldTranslation(self.returnNode)
        local lx, ly, lz = localDirectionToWorld(self.returnNode, 0, 0, -1)

        desiredPosX, desiredPosY, desiredPosZ = cx, cy, cz
        desiredLookX, desiredLookY, desiredLookZ = cx + lx * 20, cy + ly * 20, cz + lz * 20
    else
        self.blendTime = math.min(self.blendTime + dtSeconds, math.max(settings.blendTime, 0.0001))

        self:updateShot(dtSeconds, vehicle, targetHeading)

        desiredPosX, desiredPosY, desiredPosZ,
        desiredLookX, desiredLookY, desiredLookZ,
        yawOverride, pitchOverride, overrideWeight, tracking, clearance, desiredFov = self:getShotTransform(vehicle)

        local swayX, swayY, swayZ = self:getSwayOffset()
        desiredPosX = desiredPosX + swayX
        desiredPosY = desiredPosY + swayY
        desiredPosZ = desiredPosZ + swayZ

        desiredPosY = desiredPosY + self.heightBoost

        -- Never below the terrain plus the clearance for this angle.
        local step = lerp(DroneCamCamera.TERRAIN_SAMPLE_STEP, DroneCamCamera.CLOSEUP_TERRAIN_SAMPLE_STEP, tracking)
        local minY = getTerrainHeightAround(desiredPosX, desiredPosZ, step) + clearance
        if desiredPosY < minY then
            desiredPosY = minY
        end

        desiredPosY = self:applyCropFloor(dtSeconds, desiredPosX, desiredPosY, desiredPosZ)

        -- Rise over the vehicle and its implements rather than through them.
        -- The soft floor eases in short of the footprint, so a blend that
        -- passes close lifts in an arc.
        local rig = self:getRigNear(vehicle, desiredPosX, desiredPosY, desiredPosZ)
        if rig ~= nil then
            desiredPosY = math.max(desiredPosY, DroneCamRig.getVehicleFloor(rig, desiredPosX, desiredPosZ, true))
        end
    end

    -- Close-ups ride along with the vehicle: move the camera by however far the
    -- vehicle moved before smoothing, so the smoothing only softens changes of
    -- framing and never leaves the shot trailing metres behind.
    if not isBlendingOut and tracking > 0 and self.lastVehicleX ~= nil then
        local moveX = (vehicleX - self.lastVehicleX) * tracking
        local moveY = (vehicleY - self.lastVehicleY) * tracking
        local moveZ = (vehicleZ - self.lastVehicleZ) * tracking

        self.posX, self.posY, self.posZ = self.posX + moveX, self.posY + moveY, self.posZ + moveZ
        self.lookX, self.lookY, self.lookZ = self.lookX + moveX, self.lookY + moveY, self.lookZ + moveZ
    end
    self.lastVehicleX, self.lastVehicleY, self.lastVehicleZ = vehicleX, vehicleY, vehicleZ

    -- Ease the position stiffness in over the blend window so activation and
    -- hand-off start gently instead of lurching.
    local blendDuration = math.max(settings.blendTime, 0.0001)
    local blendProgress = math.min(self.blendTime / blendDuration, 1)
    local stiffnessScale = 0.4 + 0.6 * blendProgress

    local posAlpha = smoothingAlpha(dtSeconds, settings.posStiffness * stiffnessScale)
    local lookAlpha = smoothingAlpha(dtSeconds, settings.lookStiffness)

    self.posX = lerp(self.posX, desiredPosX, posAlpha)
    self.posY = lerp(self.posY, desiredPosY, posAlpha)
    self.posZ = lerp(self.posZ, desiredPosZ, posAlpha)

    self.lookX = lerp(self.lookX, desiredLookX, lookAlpha)
    self.lookY = lerp(self.lookY, desiredLookY, lookAlpha)
    self.lookZ = lerp(self.lookZ, desiredLookZ, lookAlpha)

    if not isBlendingOut then
        self:updateObstacleClearance(dtSeconds)
        self:applyHardFloors(vehicle)
        DroneCamCreator.updateSight(self.plan, dtSeconds, self.posX, self.posY, self.posZ, vehicle)
        self:setFov(desiredFov)
    elseif self.appliedFov ~= nil then
        -- Zoom back out to the normal field of view on the way home.
        self:setFov(lerp(self.appliedFov, settings.fov, posAlpha))
    end

    setWorldTranslation(self.cameraNode, self.posX, self.posY, self.posZ)

    -- A camera node looks along its own -Z axis, so aim that axis at the look
    -- target: pitch comes from the vertical component, yaw from the horizontal.
    local dx = self.lookX - self.posX
    local dy = self.lookY - self.posY
    local dz = self.lookZ - self.posZ
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)

    local rotX, rotY = 0, 0

    if length > 0.001 then
        local invLength = 1 / length
        rotX = math.asin(math.min(math.max(dy * invLength, -1), 1))
        rotY = math.atan2(-dx * invLength, -dz * invLength)

        -- Looking almost straight down, the heading of the view is set by a
        -- horizontal offset of a few centimetres and can swing half a turn in
        -- a frame. Trust it less the closer to vertical the view is, holding
        -- the previous heading instead.
        if self.lastRotY ~= nil then
            local trust = math.min(math.sqrt(dx * dx + dz * dz) * invLength / DroneCamCamera.YAW_TRUST_TILT, 1)
            rotY = self.lastRotY + normaliseAngleDiff(rotY - self.lastRotY) * trust * trust
        end
    end

    -- Top-down fixes its rotation outright. While blending to or from it, ease
    -- between that and the aimed rotation.
    if pitchOverride ~= nil and yawOverride ~= nil and overrideWeight > 0 then
        if overrideWeight >= 1 then
            rotX, rotY = pitchOverride, yawOverride
        else
            rotX = lerp(rotX, pitchOverride, overrideWeight)
            rotY = rotY + normaliseAngleDiff(yawOverride - rotY) * overrideWeight
        end
    end

    -- Some changes of angle need the view to turn right round, such as top-down
    -- (facing forward) to the front close-up (facing back). Cap the turn rate
    -- so that happens as a steady pan across the blend, not a whip.
    if self.lastRotY ~= nil and not isBlendingOut then
        local maxTurn = DroneCamCamera.MAX_YAW_RATE * dtSeconds
        local turn = normaliseAngleDiff(rotY - self.lastRotY)
        rotY = self.lastRotY + math.min(math.max(turn, -maxTurn), maxTurn)
    end

    self.lastRotY = rotY
    setWorldRotation(self.cameraNode, rotX, rotY, 0)

    if isBlendingOut then
        local isCloseEnough = length > 0
            and math.abs(self.posX - desiredPosX) < 0.5
            and math.abs(self.posY - desiredPosY) < 0.5
            and math.abs(self.posZ - desiredPosZ) < 0.5

        if self.blendTime >= blendDuration or isCloseEnough then
            return true
        end
    end

    return false
end
