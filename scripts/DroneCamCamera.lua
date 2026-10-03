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

    self.appliedFov = settings.fov

    self.director = DroneCamDirector.new(settings)

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
    self:resetShot()
end

---Forgets which angle is on screen, so the next frame takes up the wanted one
---directly instead of blending to it.
function DroneCamCamera:resetShot()
    self.shot = nil
    self.fromPose = nil
    self.shotBlendElapsed = 0
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
        -- Start the orbit behind the vehicle so the first frame is not a
        -- side-on view that then swings round.
        self.orbitAngle = self.heading + math.pi

        if not seeded then
            self.posX, self.posY, self.posZ = vx, vy + self.settings.chaseHeight, vz
            self.lookX, self.lookY, self.lookZ = vx, vy, vz
        end
    end

    self:applyFov()
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

---Re-applies the configured field of view if it has changed.
function DroneCamCamera:applyFov()
    if self.cameraNode == nil then
        return
    end

    setFovY(self.cameraNode, math.rad(self.settings.fov))
    self.appliedFov = self.settings.fov
end

---Highest terrain height on a small grid around the given world position.
---@return number
local function getTerrainHeightAround(x, z)
    local terrainNode = getTerrainNode()
    if terrainNode == nil then
        return 0
    end

    local step = DroneCamCamera.TERRAIN_SAMPLE_STEP
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
function DroneCamCamera:getModeTransform(vehicle, mode)
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

---Radius below which a pose is treated as directly overhead and so has no
---meaningful bearing of its own.
DroneCamCamera.OVERHEAD_RADIUS = 1

local function smoothstep(t)
    return t * t * (3 - 2 * t)
end

---Describes one angle relative to the vehicle: bearing, radius and height of the
---camera around it, and the look target as an offset from it. Blending in these
---terms swings the camera round the vehicle at a distance, where blending world
---positions would fly it straight through the tractor.
---@return table
function DroneCamCamera:getShotPose(vehicle, mode)
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    local px, py, pz, lx, ly, lz, yaw, pitch = self:getModeTransform(vehicle, mode)
    local dx, dz = px - vx, pz - vz

    return {
        radius = math.sqrt(dx * dx + dz * dz),
        bearing = math.atan2(dx, dz),
        height = py - vy,
        lookX = lx - vx, lookY = ly - vy, lookZ = lz - vz,
        yaw = yaw, pitch = pitch,
        overrideWeight = yaw ~= nil and 1 or 0
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
        height = lerp(from.height, to.height, t),
        lookX = lerp(from.lookX, to.lookX, t),
        lookY = lerp(from.lookY, to.lookY, t),
        lookZ = lerp(from.lookZ, to.lookZ, t),
        yaw = yaw, pitch = pitch,
        overrideWeight = lerp(from.overrideWeight, to.overrideWeight, t)
    }
end

---@return number @Eased progress of the current change of angle, 1 when settled
function DroneCamCamera:getShotBlendAlpha()
    if self.fromPose == nil then
        return 1
    end

    local duration = self.settings.shotBlendTime
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

    if mode ~= DroneCamSettings.MODE_AUTO then
        if self.director.isRunning then
            self.director:reset()
        end
        return mode
    end

    if not self.director.isRunning then
        -- Open on whatever is already on screen, so choosing the mode is not
        -- itself a change of angle.
        self.director:start(self.shot, heading)
    end

    return self.director:update(dtSeconds, heading)
end

---Follows the wanted angle, starting a blend whenever it changes.
---@param heading number|nil @Raw vehicle heading in radians
function DroneCamCamera:updateShot(dtSeconds, vehicle, heading)
    local wanted = self:getWantedShot(dtSeconds, heading)

    if self.shot == nil then
        -- First frame after activation: the activation blend already eases in.
        self.shot = wanted
    elseif wanted ~= self.shot then
        -- Freeze wherever the camera is aiming right now, part-way through an
        -- earlier blend included, so a quick second change never jumps.
        self.fromPose = self:getCurrentPose(vehicle)
        self.shotBlendElapsed = 0
        self.blendBearingDiff = nil
        self.shot = wanted

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

        if self.shotBlendElapsed >= self.settings.shotBlendTime then
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
function DroneCamCamera:getShotTransform(vehicle)
    if self.fromPose == nil then
        local px, py, pz, lx, ly, lz, yaw, pitch = self:getModeTransform(vehicle, self.shot)
        return px, py, pz, lx, ly, lz, yaw, pitch, yaw ~= nil and 1 or 0
    end

    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    local pose = self:getCurrentPose(vehicle)

    return vx + math.sin(pose.bearing) * pose.radius,
           vy + pose.height,
           vz + math.cos(pose.bearing) * pose.radius,
           vx + pose.lookX, vy + pose.lookY, vz + pose.lookZ,
           pose.yaw, pose.pitch, pose.overrideWeight
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

    if self.appliedFov ~= settings.fov then
        self:applyFov()
    end

    -- Smooth the vehicle heading first; every mode is built on top of it, so a
    -- U-turn becomes a slow sweeping pan rather than a snap.
    local dirX, _, dirZ = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
    local targetHeading = nil
    if dirX ~= 0 or dirZ ~= 0 then
        targetHeading = math.atan2(dirX, dirZ)
        self.heading = self.heading
            + normaliseAngleDiff(targetHeading - self.heading) * smoothingAlpha(dtSeconds, settings.headingStiffness)
    end

    self.orbitAngle = self.orbitAngle + math.rad(settings.orbitSpeed) * dtSeconds

    local isBlendingOut = self.blendOutActive == true
    local desiredPosX, desiredPosY, desiredPosZ
    local desiredLookX, desiredLookY, desiredLookZ
    local yawOverride, pitchOverride
    local overrideWeight = 0

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
        yawOverride, pitchOverride, overrideWeight = self:getShotTransform(vehicle)

        local swayX, swayY, swayZ = self:getSwayOffset()
        desiredPosX = desiredPosX + swayX
        desiredPosY = desiredPosY + swayY
        desiredPosZ = desiredPosZ + swayZ

        desiredPosY = desiredPosY + self.heightBoost

        -- Never below the terrain plus the configured clearance.
        local minY = getTerrainHeightAround(desiredPosX, desiredPosZ) + settings.minClearance
        if desiredPosY < minY then
            desiredPosY = minY
        end
    end

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
    end

    -- Top-down fixes its rotation outright. While blending to or from it, ease
    -- between that and the aimed rotation; the aimed yaw is unstable straight
    -- overhead, but its weight has reached zero by the time the camera is there.
    if pitchOverride ~= nil and yawOverride ~= nil and overrideWeight > 0 then
        if overrideWeight >= 1 then
            rotX, rotY = pitchOverride, yawOverride
        else
            rotX = lerp(rotX, pitchOverride, overrideWeight)
            rotY = rotY + normaliseAngleDiff(yawOverride - rotY) * overrideWeight
        end
    end

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
