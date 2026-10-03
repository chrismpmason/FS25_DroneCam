-- Harness that stubs the FS25 globals DroneCam touches, then drives the mod
-- through a realistic work session and checks the behaviour the brief specifies.

-- Root of the mod to test. Defaults to the current directory, so the suite is
-- run from the mod root as:  lua test/test_dronecam.lua
local MOD = os.getenv("MOD_DIR") or "."

local probe = io.open(MOD .. "/scripts/DroneCam.lua", "r")
if probe == nil then
    io.stderr:write(("could not find %s/scripts/DroneCam.lua - run this from the mod root, " ..
                     "or set MOD_DIR to the mod folder\n"):format(MOD))
    os.exit(2)
end
probe:close()

----------------------------------------------------------------- engine stubs

local nodes = {}
local nextNode = 10

local function newNode(name)
    nextNode = nextNode + 1
    nodes[nextNode] = { name = name, x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0, parent = nil }
    return nextNode
end

function Class(target, parent)
    target = target or {}
    target.__index = target
    if parent then setmetatable(target, { __index = parent }) end
    return target
end

function getRootNode() return 1 end
function createTransformGroup(name) return newNode(name) end
function createCamera(name, fov, near, far)
    assert(type(fov) == "number" and fov > 0 and fov < math.pi, "bad fov: " .. tostring(fov))
    assert(near > 0 and far > near, "bad clip planes")
    return newNode(name)
end
function link(parent, child) nodes[child].parent = parent end
function unlink(node) nodes[node].parent = nil end
function delete(node) nodes[node] = nil end
function setFastShadowUpdate() end
function setFovY(node, rad) assert(nodes[node], "setFovY on dead node") end
function entityExists(node) return nodes[node] ~= nil end

function setWorldTranslation(node, x, y, z)
    assert(nodes[node], "translate on dead node")
    assert(x == x and y == y and z == z, "NaN position")
    nodes[node].x, nodes[node].y, nodes[node].z = x, y, z
end

function setWorldRotation(node, rx, ry, rz)
    assert(nodes[node], "rotate on dead node")
    assert(rx == rx and ry == ry and rz == rz, "NaN rotation")
    nodes[node].rx, nodes[node].ry, nodes[node].rz = rx, ry, rz
end

function getWorldTranslation(node)
    local n = assert(nodes[node], "read of dead node")
    return n.x, n.y, n.z
end

-- Mirrors the engine: rotation is applied Y then X, local +Z is forward.
function localDirectionToWorld(node, lx, ly, lz)
    local n = assert(nodes[node], "direction of dead node")
    local cx, sx = math.cos(n.rx), math.sin(n.rx)
    local y1 = ly * cx - lz * sx
    local z1 = ly * sx + lz * cx
    local cy, sy = math.cos(n.ry), math.sin(n.ry)
    return lx * cy + z1 * sy, y1, -lx * sy + z1 * cy
end

TERRAIN_HEIGHT = 0
TERRAIN_FN = nil -- optional function(x, z) for hills
function getTerrainHeightAtWorldPos(terrain, x, y, z)
    assert(terrain ~= nil, "nil terrain node")
    if TERRAIN_FN ~= nil then return TERRAIN_FN(x, z) end
    return TERRAIN_HEIGHT
end

-- Solid things in the world: axis-aligned boxes {minX, maxX, minY, maxY,
-- minZ, maxZ}, standing in for trees, hedges and buildings.
OBSTACLES = {}

---Distance along a ray to a box, or nil if it misses (slab method).
local function rayBox(x, y, z, dx, dy, dz, box)
    local tMin, tMax = -math.huge, math.huge
    for _, axis in ipairs({ { x, dx, box[1], box[2] }, { y, dy, box[3], box[4] }, { z, dz, box[5], box[6] } }) do
        local origin, dir, lo, hi = axis[1], axis[2], axis[3], axis[4]
        if math.abs(dir) < 1e-12 then
            if origin < lo or origin > hi then return nil end
        else
            local t1, t2 = (lo - origin) / dir, (hi - origin) / dir
            if t1 > t2 then t1, t2 = t2, t1 end
            tMin, tMax = math.max(tMin, t1), math.min(tMax, t2)
            if tMin > tMax then return nil end
        end
    end
    if tMax < 0 then return nil end
    return math.max(tMin, 0)
end

function pointInBox(x, y, z, box, margin)
    margin = margin or 0
    return x > box[1] - margin and x < box[2] + margin and y > box[3] - margin and y < box[4] + margin
        and z > box[5] - margin and z < box[6] + margin
end

-- Collision bodies of the vehicle being driven, as world boxes rebuilt every
-- tick from vehicle.bodies. They carry the VEHICLE flag; OBSTACLES carry
-- STATIC_OBJECT. Raycasts only hit what their mask includes.
VEHICLE_BODIES = {}

function maskHas(mask, flag)
    return math.floor(mask / flag) % 2 == 1
end

RAYCAST_HIT = false
RaycastUtil = {}
function RaycastUtil.raycastClosest(x, y, z, dx, dy, dz, maxDistance, mask)
    assert(mask ~= nil and mask > 0, "bad collision mask")
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    assert(math.abs(len - 1) < 0.001, "direction not normalised: " .. len)
    if RAYCAST_HIT then return 99, x, y, z, maxDistance * 0.5 end
    local best, bestId = nil, nil
    local function consider(boxes, flag, idBase)
        if not maskHas(mask, flag) then return end
        for i, box in ipairs(boxes) do
            local t = rayBox(x, y, z, dx, dy, dz, box)
            if t ~= nil and t <= maxDistance and (best == nil or t < best) then best, bestId = t, idBase + i end
        end
    end
    consider(OBSTACLES, CollisionFlag.STATIC_OBJECT, 500)
    consider(VEHICLE_BODIES, CollisionFlag.VEHICLE, 900)
    if best ~= nil then return bestId, x + dx * best, y + dy * best, z + dz * best, best end
    return nil
end

NEAR_CLIP = 0.5
function setNearClip(node, distance)
    assert(nodes[node], "setNearClip on dead node")
    NEAR_CLIP = distance
end

-- Fields: FIELD is a rectangle {minX, maxX, minZ, maxZ}, or nil for no field.
FIELD = nil
FSDensityMapUtil_getFieldData = function(x, y, z)
    local f = FIELD
    return f ~= nil and x >= f[1] and x <= f[2] and z >= f[3] and z <= f[4], 0, 0
end

-- Crop: CROP_AT(x, z) returns fruit type index and growth state, 0 for bare
-- ground. Fruit type 1 is maize, harvest-ready from growth state 5.
CROP_AT = function() return 0, 0 end
FSDensityMapUtil = {
    getFruitTypeIndexAtWorldPos = function(x, z) return CROP_AT(x, z) end,
    getFieldDataAtWorldPosition = function(x, y, z) return FSDensityMapUtil_getFieldData(x, y, z) end
}
local MAIZE = { name = "MAIZE", minHarvestingGrowthState = 5, maxHarvestingGrowthState = 6, cutState = 8 }
g_fruitTypeManager = { getFruitTypeByIndex = function(self, index) if index == 1 then return MAIZE end end }

CollisionFlag = { STATIC_OBJECT = 1, BUILDING = 2, TREE = 4, VEHICLE = 8, TERRAIN = 16 }
GS_PRIO_LOW = 1
FSBaseMission = { INGAME_NOTIFICATION_INFO = { 1, 1, 1, 1 } }

local activeCamera = nil
g_cameraManager = {
    addCamera = function(self, node, focusBox, isDefault)
        assert(nodes[node], "addCamera on dead node")
        self.added = self.added or {}
        self.added[node] = true
    end,
    removeCamera = function(self, node) if self.added then self.added[node] = nil end end,
    setActiveCamera = function(self, node)
        assert(nodes[node], "activating a dead camera node")
        activeCamera = node
    end,
    getActiveCamera = function() return activeCamera end
}

NOTIFICATIONS = {}
local hudVisible = true
g_currentMission = {
    time = 0,
    terrainRootNode = 2,
    hud = {
        getIsVisible = function() return hudVisible end,
        setIsVisible = function(self, v) hudVisible = v end,
        addSideNotification = function(self, colour, text)
            assert(colour ~= nil and text ~= nil, "bad notification")
            NOTIFICATIONS[#NOTIFICATIONS + 1] = text
        end
    }
}

g_gui = { getIsGuiVisible = function() return false end }
g_i18n = { getText = function(self, key) return key end }
g_inputBinding = {
    registerActionEvent = function() return true, 1 end,
    setActionEventTextPriority = function() end,
    setActionEventTextVisibility = function() end
}
InputAction = { DRONECAM_TOGGLE = 1, DRONECAM_MODE = 2, DRONECAM_FORCE = 3, DRONECAM_HUD = 4,
                DRONECAM_DRIVE_OVER = 5, DRONECAM_DEBUG = 6 }
-- Text drawn on screen, one entry per renderText call.
RENDERED = {}
function renderText(x, y, size, text) RENDERED[#RENDERED + 1] = text end
function setTextColor() end
function setTextAlignment() end
function setTextBold() end
RenderText = { ALIGN_LEFT = 0 }
Utils = { overwrittenFunction = function(old, new) return function(...) return new(...) end end }
Enterable = { onRegisterActionEvents = function() end }

-- Settings are kept in memory and keyed by path, so nothing touches the disk.
local STORE = {}
function getUserProfileAppPath() return "profile/" end
function createFolder() end
function fileExists(p) return STORE[p] ~= nil end
function createXMLFile(name, path, root) STORE[path] = {}; CURRENT = STORE[path]; return 77 end
function loadXMLFile(name, path) CURRENT = STORE[path]; return 78 end
function saveXMLFile() end
function setXMLBool(id, k, v) CURRENT[k] = v end
function setXMLInt(id, k, v) CURRENT[k] = v end
function setXMLFloat(id, k, v) CURRENT[k] = v end
function getXMLBool(id, k) return CURRENT[k] end
function getXMLInt(id, k) return CURRENT[k] end
function getXMLFloat(id, k) return CURRENT[k] end

local listeners = {}
function addModEventListener(l) listeners[#listeners + 1] = l end

------------------------------------------------------------------- load mod

dofile(MOD .. "/scripts/DroneCamSettings.lua")
dofile(MOD .. "/scripts/DroneCamWorkDetect.lua")
dofile(MOD .. "/scripts/DroneCamRig.lua")
dofile(MOD .. "/scripts/DroneCamField.lua")
dofile(MOD .. "/scripts/DroneCamSpot.lua")
dofile(MOD .. "/scripts/DroneCamKit.lua")
dofile(MOD .. "/scripts/DroneCamDirector.lua")
dofile(MOD .. "/scripts/DroneCamCreator.lua")
dofile(MOD .. "/scripts/DroneCamCamera.lua")
dofile(MOD .. "/scripts/DroneCam.lua")

assert(#listeners == 1, "mod did not register exactly one event listener")

--------------------------------------------------------------------- vehicle

local vehicle
local vehicleCamNode = newNode("vehicleCam")

local function makeVehicle()
    local root = newNode("vehicleRoot")
    nodes[root].y = 0
    local v = {
        rootNode = root,
        isWorking = false,
        spec_enterable = { camIndex = 1, cameras = { { cameraNode = vehicleCamNode } } },
        spec_workArea = { workAreas = { { lastProcessingTime = -10000 } } }
    }
    function v:getIsEntered() return true end
    function v:getChildVehicles() return { self } end
    function v:getIsWorkAreaProcessing(wa) return wa.lastProcessingTime + 200 >= g_currentMission.time end
    function v:setActiveCameraIndex(i)
        g_cameraManager:setActiveCamera(self.spec_enterable.cameras[i].cameraNode)
    end
    return v
end

vehicle = makeVehicle()

local playerCamNode = newNode("playerCam")
g_localPlayer = {
    getCurrentVehicle = function() return vehicle end,
    camera = { makeCurrent = function() g_cameraManager:setActiveCamera(playerCamNode) end }
}

local heading = 0

---Advances simulated time, moving the vehicle forward and stamping its work area.
---onStep, if given, is called after every frame.
local function tick(seconds, working, headingRate, onStep)
    local dt = 16
    local steps = math.floor(seconds * 1000 / dt)
    for _ = 1, steps do
        g_currentMission.time = g_currentMission.time + dt

        if vehicle ~= nil then
            heading = heading + (headingRate or 0) * (dt / 1000)
            nodes[vehicle.rootNode].ry = heading
            local fx, _, fz = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
            nodes[vehicle.rootNode].x = nodes[vehicle.rootNode].x + fx * VEHICLE_SPEED * (dt / 1000)
            nodes[vehicle.rootNode].z = nodes[vehicle.rootNode].z + fz * VEHICLE_SPEED * (dt / 1000)

            -- Keep the vehicle camera roughly where the game would put it.
            nodes[vehicleCamNode].x = nodes[vehicle.rootNode].x
            nodes[vehicleCamNode].y = nodes[vehicle.rootNode].y + 3
            nodes[vehicleCamNode].z = nodes[vehicle.rootNode].z
            nodes[vehicleCamNode].ry = heading + math.pi

            -- Carry wheels, implements and work area nodes along rigidly.
            local root = nodes[vehicle.rootNode]
            for _, part in ipairs(vehicle.attached or {}) do
                local n = nodes[part.node]
                n.x = root.x + math.cos(heading) * part.across + math.sin(heading) * part.along
                n.z = root.z - math.sin(heading) * part.across + math.cos(heading) * part.along
                n.y = root.y + part.up
                n.ry = heading
            end

            -- Collision bodies {minAcross, maxAcross, minY, maxY, minAlong,
            -- maxAlong} as world boxes (bounding the rotated box).
            VEHICLE_BODIES = {}
            local c, s = math.cos(heading), math.sin(heading)
            for _, b in ipairs(vehicle.bodies or {}) do
                local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
                for _, across in ipairs({ b[1], b[2] }) do
                    for _, along in ipairs({ b[5], b[6] }) do
                        local wx = root.x + c * across + s * along
                        local wz = root.z - s * across + c * along
                        minX, maxX, minZ, maxZ = math.min(minX, wx), math.max(maxX, wx), math.min(minZ, wz), math.max(maxZ, wz)
                    end
                end
                VEHICLE_BODIES[#VEHICLE_BODIES + 1] = { minX, maxX, root.y + b[3], root.y + b[4], minZ, maxZ }
            end

            if working then
                for _, child in ipairs(vehicle:getChildVehicles()) do
                    local spec = child.spec_workArea
                    for _, workArea in ipairs(spec and spec.workAreas or {}) do
                        workArea.lastProcessingTime = g_currentMission.time
                    end
                end
            end
        end

        DroneCam:update(dt)

        if onStep ~= nil then
            onStep(dt / 1000)
        end
    end
end

local function droneIsActive()
    local node = DroneCam.camera and DroneCam.camera:getCameraNode()
    return node ~= nil and activeCamera == node
end

-- The drive-over's swing turns the view faster than anything else may, by
-- design. Its frames are kept out of the general smoothness limits and held
-- to their own (SWING_MAX_TURN is checked by the drive-over tests).
SWING_MAX_TURN = 0
function countTurn(turn)
    local camera = DroneCam.camera
    local plan = camera and camera.plan
    if camera ~= nil and camera.shot == DroneCamSettings.SHOT_DRIVE_OVER and plan ~= nil and plan.phase == "swing" then
        SWING_MAX_TURN = math.max(SWING_MAX_TURN, turn)
        return 0
    end
    return turn
end

VEHICLE_SPEED = 8

local failures = 0
local function check(label, condition, detail)
    if condition then
        print(("  PASS  %s"):format(label))
    else
        failures = failures + 1
        print(("  FAIL  %s  %s"):format(label, detail or ""))
    end
end

------------------------------------------------------------------- the tests

print("\n-- load --")
DroneCam:loadMap()
g_cameraManager:setActiveCamera(vehicleCamNode)
check("settings defaults loaded", DroneCam.settings.startDelay == 2 and DroneCam.settings.stopDelay == 6)
check("starts in chase mode", DroneCam.settings.mode == DroneCamSettings.MODE_CHASE)

print("\n-- engages only after startDelay --")
tick(1.5, true)
check("still on vehicle camera at 1.5s", not droneIsActive())
tick(1.0, true)
check("drone engaged by 2.5s", droneIsActive())

print("\n-- framing --")
tick(6, true)
local cn = DroneCam.camera:getCameraNode()
local cx, cy, cz = getWorldTranslation(cn)
local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
local horizontal = math.sqrt((cx - vx) ^ 2 + (cz - vz) ^ 2)
check("camera is above the vehicle", cy > vy + 10, ("cy=%.1f vy=%.1f"):format(cy, vy))
check("camera trails at about chase distance", math.abs(horizontal - 40) < 12,
      ("horizontal=%.1f"):format(horizontal))

-- The camera's -Z axis should point at the vehicle.
local lx, ly, lz = localDirectionToWorld(cn, 0, 0, -1)
local tx, ty, tz = vx - cx, vy - cy, vz - cz
local tlen = math.sqrt(tx * tx + ty * ty + tz * tz)
local dot = (lx * tx + ly * ty + lz * tz) / tlen
check("camera is aimed at the vehicle", dot > 0.9, ("dot=%.3f"):format(dot))

print("\n-- terrain clamp --")
TERRAIN_HEIGHT = 120
tick(8, true)
cx, cy, cz = getWorldTranslation(cn)
check("stays above terrain + clearance", cy >= 120 + DroneCam.settings.minClearance - 0.5,
      ("cy=%.1f"):format(cy))
TERRAIN_HEIGHT = 0
tick(8, true)

print("\n-- obstacle avoidance --")
local _, beforeY = getWorldTranslation(cn)
RAYCAST_HIT = true
tick(3, true)
local _, blockedY = getWorldTranslation(cn)
check("rises when the view is blocked", blockedY > beforeY + 2,
      ("%.1f -> %.1f"):format(beforeY, blockedY))
RAYCAST_HIT = false
tick(12, true)
local _, clearedY = getWorldTranslation(cn)
check("settles back once clear", clearedY < blockedY - 2, ("%.1f"):format(clearedY))

print("\n-- headland turn survives the gap --")
tick(4, false, math.rad(60))
check("still flying 4s into a turn", droneIsActive())
tick(3, true, math.rad(60))
check("still flying once work resumes", droneIsActive())

print("\n-- stops after stopDelay --")
tick(5, false)
check("still flying at 5s idle", droneIsActive())
tick(3, false)
check("handed back to the vehicle camera", not droneIsActive() and activeCamera == vehicleCamNode)
check("state reset to off", DroneCam.state == DroneCam.STATE_OFF)

print("\n-- modes --")
for _, mode in ipairs({ DroneCamSettings.MODE_TOPDOWN, DroneCamSettings.MODE_ORBIT }) do
    DroneCam.settings.mode = mode
    DroneCam.hasUserOverride = false
    tick(4, true)
    check("engaged in mode " .. mode, droneIsActive())
    cx, cy, cz = getWorldTranslation(cn)
    vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    if mode == DroneCamSettings.MODE_TOPDOWN then
        tick(6, true)
        cx, cy, cz = getWorldTranslation(cn)
        vx, vy, vz = getWorldTranslation(vehicle.rootNode)
        local horiz = math.sqrt((cx - vx) ^ 2 + (cz - vz) ^ 2)
        check("top-down sits overhead", horiz < 12, ("horiz=%.1f"):format(horiz))
        local dx, dy, dz = localDirectionToWorld(cn, 0, 0, -1)
        check("top-down looks straight down", dy < -0.98, ("dy=%.3f"):format(dy))
    else
        tick(6, true)
        cx, cy, cz = getWorldTranslation(cn)
        vx, vy, vz = getWorldTranslation(vehicle.rootNode)
        local horiz = math.sqrt((cx - vx) ^ 2 + (cz - vz) ^ 2)
        check("orbit holds its radius", math.abs(horiz - 45) < 15, ("horiz=%.1f"):format(horiz))
    end
    tick(9, false)
end
DroneCam.settings.mode = DroneCamSettings.MODE_CHASE

print("\n-- leaving the vehicle always restores --")
tick(4, true)
check("flying before exit", droneIsActive())
vehicle.getIsEntered = function() return false end
tick(0.1, false)
check("restored on exit", not droneIsActive())
vehicle.getIsEntered = function() return true end

print("\n-- menu opens --")
tick(4, true)
check("flying before menu", droneIsActive())
g_gui.getIsGuiVisible = function() return true end
tick(0.1, true)
check("restored when a menu opens", not droneIsActive())
g_gui.getIsGuiVisible = function() return false end
tick(9, false)

print("\n-- vehicle deleted under us --")
tick(4, true)
check("flying before delete", droneIsActive())
local deadVehicle = vehicle
vehicle = nil
tick(0.1, false)
check("no crash, drone released", not droneIsActive())
vehicle = deadVehicle
tick(9, false)

print("\n-- player takes manual control of the camera --")
DroneCam.hasUserOverride = false
tick(4, true)
check("flying before override", droneIsActive())
g_cameraManager:setActiveCamera(vehicleCamNode)
tick(0.1, true)
check("stands down after a manual switch", not droneIsActive())
tick(5, true)
check("does not fight the player", not droneIsActive())
tick(9, false)
tick(4, true)
check("re-engages on the next job", droneIsActive())

print("\n-- force toggle --")
tick(9, false)
check("idle before force", not droneIsActive())
DroneCam:onToggleForce()
tick(1.5, false)
check("forced on without field work", droneIsActive())
DroneCam:onToggleForce()
tick(3, false)
check("forced off again", not droneIsActive())

print("\n-- hud hiding --")
DroneCam.settings.hideHud = true
tick(4, true)
check("hud hidden while flying", hudVisible == false)
tick(12, false)
check("hud restored after landing", hudVisible == true)
DroneCam.settings.hideHud = false

print("\n-- auto toggle --")
DroneCam:onToggleEnabled()
check("auto disabled", DroneCam.settings.enabled == false)
tick(6, true)
check("stays off while disabled", not droneIsActive())
DroneCam:onToggleEnabled()
tick(4, true)
check("back on when re-enabled", droneIsActive())

print("\n-- combine harvesting (no work area ticks of its own) --")
tick(12, false)
local cutter = {
    spec_workArea = { workAreas = { { lastProcessingTime = -10000 } } },
    spec_combine = { isFilling = false }
}
function cutter:getIsWorkAreaProcessing(wa) return wa.lastProcessingTime + 200 >= g_currentMission.time end
vehicle.getChildVehicles = function(self) return { self, cutter } end
cutter.spec_combine.isFilling = true
tick(4, false)
check("engages for a filling combine", droneIsActive())
cutter.spec_combine.isFilling = false
tick(9, false)
check("lands when the combine stops", not droneIsActive())

print("\n-- ai helper, gated by the followAI setting --")
local helper = { spec_aiFieldWorker = { isActive = true } }
vehicle.getChildVehicles = function(self) return { self, helper } end
DroneCam.settings.followAI = false
tick(6, false)
check("ignores the helper when followAI is off", not droneIsActive())
DroneCam.settings.followAI = true
tick(4, false)
check("follows the helper when followAI is on", droneIsActive())
DroneCam.settings.followAI = false
tick(9, false)
vehicle.getChildVehicles = function(self) return { self } end

------------------------------------------------------------- auto director

---Park-Miller generator with math.random's calling convention, so the
---director's choices are the same on every platform.
local function makeRng(seed)
    local state = seed
    return function(n)
        state = (state * 16807) % 2147483647
        local f = (state - 1) / 2147483646
        if n == nil then
            return f
        end
        return math.floor(f * n) + 1
    end
end

local function wrapAngle(a)
    while a > math.pi do a = a - 2 * math.pi end
    while a < -math.pi do a = a + 2 * math.pi end
    return a
end

---Largest per-frame camera move (metres) and turn (degrees) while ticking.
---A hard cut shows up as tens of metres or tens of degrees in a single frame.
local function measureMotion(seconds, working, headingRate, onStep)
    local px, py, pz = getWorldTranslation(cn)
    local prx, pry = nodes[cn].rx, nodes[cn].ry
    local maxStep, maxTurn = 0, 0

    tick(seconds, working, headingRate, function(dtSeconds)
        local x, y, z = getWorldTranslation(cn)
        local rx, ry = nodes[cn].rx, nodes[cn].ry
        maxStep = math.max(maxStep, math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2))
        maxTurn = math.max(maxTurn, countTurn(math.max(math.deg(math.abs(rx - prx)), math.deg(math.abs(wrapAngle(ry - pry))))))
        px, py, pz, prx, pry = x, y, z, rx, ry
        if onStep ~= nil then onStep(dtSeconds) end
    end)

    return maxStep, maxTurn
end

-- Per-frame limits for "no hard cuts", at 16ms frames. The vehicle itself
-- moves 0.13m a frame; a cut between angles is a 40-80m or 45-90 degree jump.
local MAX_STEP = 2.5
local MAX_TURN = 3

local CHASE = DroneCamSettings.MODE_CHASE
local TOPDOWN = DroneCamSettings.MODE_TOPDOWN
local ORBIT = DroneCamSettings.MODE_ORBIT
local AUTO = DroneCamSettings.MODE_AUTO

print("\n-- auto director: mode cycle --")
tick(12, false)
DroneCam.settings.mode = CHASE
local AUTO_RANDOM = DroneCamSettings.MODE_AUTO_RANDOM
local cycled = {}
for i = 1, 6 do
    DroneCam:onCycleMode()
    cycled[i] = DroneCam.settings.mode
end
check("Ctrl+C cycles chase -> top-down -> orbit -> auto story -> auto random -> drive-over -> chase",
      cycled[1] == TOPDOWN and cycled[2] == ORBIT and cycled[3] == AUTO and cycled[4] == AUTO_RANDOM
      and cycled[5] == DroneCamSettings.MODE_DRIVE_OVER and cycled[6] == CHASE, table.concat(cycled, ","))
DroneCam.settings.mode = AUTO_RANDOM
DroneCam:onCycleMode()
check("drive-over mode is announced by name", NOTIFICATIONS[#NOTIFICATIONS] == "droneCam_mode: droneCam_mode_driveOver",
      NOTIFICATIONS[#NOTIFICATIONS])
DroneCam.settings.mode = ORBIT
DroneCam:onCycleMode()
check("auto director (story) is announced by name", NOTIFICATIONS[#NOTIFICATIONS] == "droneCam_mode: droneCam_mode_auto",
      NOTIFICATIONS[#NOTIFICATIONS])
DroneCam:onCycleMode()
check("auto director (random) is announced by name",
      NOTIFICATIONS[#NOTIFICATIONS] == "droneCam_mode: droneCam_mode_autoRandom", NOTIFICATIONS[#NOTIFICATIONS])
DroneCam.settings.mode = CHASE

print("\n-- auto director (random): choosing shots --")
local isClose = DroneCamDirector.getIsCloseUp
local isMoving = DroneCamDirector.getIsMoving
local CLOSE_SHOTS = DroneCamDirector.CLOSE_SHOTS
local HEADLAND = DroneCamSettings.SHOT_HEADLAND

---Everything is available except the headland shot, which the camera only
---offers near the end of a row.
local function notHeadland(shot) return shot ~= HEADLAND and shot ~= DroneCamSettings.SHOT_DRIVE_OVER end

local director = DroneCamDirector.new(DroneCam.settings)
director.random = makeRng(12345)
director.isShotAvailable = notHeadland
director:start(CHASE, 0, false)

---Runs a director dead straight for a long time and gathers statistics.
local function survey(d, seconds)
    local stats = { switches = 0, repeats = 0, seen = {}, groupChanges = 0, sides = {}, order = {},
                    wide = { min = math.huge, max = 0 }, moving = { min = math.huge, max = 0 },
                    close = { min = math.huge, max = 0 } }
    local held = 0
    local lastShot = d.shot
    stats.order[1] = d.shot
    for _ = 1, math.floor(seconds / 0.05) do
        held = held + 0.05
        local previousTime = d.shotTime
        local shot = d:update(0.05, 0)
        if d.shotTime < previousTime then
            stats.switches = stats.switches + 1
            stats.order[#stats.order + 1] = shot
            if shot == lastShot then stats.repeats = stats.repeats + 1 end
            if isClose(shot) ~= isClose(lastShot) then stats.groupChanges = stats.groupChanges + 1 end
            local group = isClose(lastShot) and stats.close or (isMoving(lastShot) and stats.moving or stats.wide)
            group.min, group.max = math.min(group.min, held), math.max(group.max, held)
            stats.seen[shot] = true
            stats.sides[d.side] = true
            held = 0
        end
        lastShot = shot
    end
    return stats
end

local function seenAll(seen, list)
    for _, shot in ipairs(list) do
        if not seen[shot] then return false end
    end
    return true
end

local stats = survey(director, 4000)
check("switches shot regularly", stats.switches > 350, tostring(stats.switches))
check("never repeats the same shot twice in a row", stats.repeats == 0, tostring(stats.repeats))
check("uses chase, top-down and orbit", seenAll(stats.seen, DroneCamDirector.STATIC_WIDE_SHOTS))
check("uses all five close-ups", seenAll(stats.seen, CLOSE_SHOTS))
check("uses establishing, long lens and field-edge pan",
      seenAll(stats.seen, { DroneCamSettings.SHOT_ESTABLISHING, DroneCamSettings.SHOT_LONG_LENS, DroneCamSettings.SHOT_EDGE_PAN }))
check("uses all five moving shots", seenAll(stats.seen, DroneCamDirector.MOVING_SHOTS))
check("shots are filmed from both sides", stats.sides[1] and stats.sides[-1])
check("wide and fixed shots held 10-15s", stats.wide.min >= 10 - 1e-6 and stats.wide.max <= 15.05 + 1e-6,
      ("%.2f-%.2f"):format(stats.wide.min, stats.wide.max))
check("moving shots held 7-10s", stats.moving.min >= 7 - 1e-6 and stats.moving.max <= 10.05 + 1e-6,
      ("%.2f-%.2f"):format(stats.moving.min, stats.moving.max))
check("close-ups held 6-10s", stats.close.min >= 6 - 1e-6 and stats.close.max <= 10.05 + 1e-6,
      ("%.2f-%.2f"):format(stats.close.min, stats.close.max))
check("hold times spread across their ranges",
      stats.wide.min < 10.5 and stats.wide.max > 14.5 and stats.close.min < 6.5 and stats.close.max > 9.5
      and stats.moving.min < 7.5 and stats.moving.max > 9.5)
local alternation = stats.groupChanges / stats.switches
check("roughly alternates wide and close (65-85% of cuts change group)",
      alternation > 0.65 and alternation < 0.85, ("%.0f%%"):format(alternation * 100))

local noImplement = DroneCamDirector.new(DroneCam.settings)
noImplement.random = makeRng(555)
noImplement.isShotAvailable = function(shot) return shot ~= DroneCamSettings.SHOT_IMPLEMENT and notHeadland(shot) end
noImplement:start(CHASE, 0, false)
check("skips the implement shot when there is no implement",
      not survey(noImplement, 1500).seen[DroneCamSettings.SHOT_IMPLEMENT])

local noSpots = DroneCamDirector.new(DroneCam.settings)
noSpots.random = makeRng(556)
noSpots.isShotAvailable = function(shot) return not DroneCamDirector.getIsFixed(shot) and shot ~= DroneCamSettings.SHOT_DRIVE_OVER end
noSpots:start(CHASE, 0, false)
local noSpotStats = survey(noSpots, 1500)
local anyFixed = false
for _, shot in ipairs(DroneCamDirector.FIXED_SHOTS) do anyFixed = anyFixed or noSpotStats.seen[shot] == true end
check("skips fixed shots that have no good spot", not anyFixed and noSpotStats.repeats == 0)

DroneCam.settings.closeUps = false
local wideOnly = DroneCamDirector.new(DroneCam.settings)
wideOnly.random = makeRng(31)
wideOnly.isShotAvailable = notHeadland
wideOnly:start(CHASE, 0, false)
local wideStats = survey(wideOnly, 1500)
local anyClose = false
for _, shot in ipairs(CLOSE_SHOTS) do anyClose = anyClose or wideStats.seen[shot] == true end
check("close-ups can be switched off", not anyClose and wideStats.repeats == 0)
DroneCam.settings.closeUps = true

local fresh = DroneCamDirector.new(DroneCam.settings)
fresh.random = makeRng(99)
fresh.isShotAvailable = notHeadland
fresh:start(nil, 0, false)
check("random mode opens on a wide angle when none is on screen",
      fresh.shot == CHASE or fresh.shot == TOPDOWN or fresh.shot == ORBIT, tostring(fresh.shot))
fresh:start(DroneCamSettings.MODE_AUTO, 0, false)
check("never opens on auto itself", fresh.shot ~= DroneCamSettings.MODE_AUTO)

print("\n-- auto director (story): the sequence --")
local STORY = DroneCamDirector.STORY
check("story is establishing -> push-in -> close-ups -> fly-over -> pull-out",
      #STORY == 5 and STORY[1][1] == DroneCamSettings.SHOT_ESTABLISHING and STORY[2][1] == DroneCamSettings.SHOT_PUSH_IN
      and STORY[3] == DroneCamDirector.CLOSE_UPS and STORY[4][1] == DroneCamSettings.SHOT_FLY_OVER
      and STORY[5][1] == DroneCamSettings.SHOT_PULL_OUT)
local storyDirector = DroneCamDirector.new(DroneCam.settings)
storyDirector.random = makeRng(2468)
storyDirector.isShotAvailable = notHeadland
storyDirector:start(nil, 0, true)
local storyStats = survey(storyDirector, 3000)

---Which story step a shot belongs to: 1 establishing, 2 push-in, 3 close-up,
---4 fly-over, 5 pull-out.
local STEP_OF = {}
for step, entry in ipairs(DroneCamDirector.STORY) do
    if entry == DroneCamDirector.CLOSE_UPS then
        for _, shot in ipairs(CLOSE_SHOTS) do STEP_OF[shot] = step end
    else
        for _, shot in ipairs(entry) do STEP_OF[shot] = step end
    end
end
STEP_OF[DroneCamSettings.SHOT_DRIVE_OVER] = DroneCamDirector.HERO_STEP

local outOfOrder, loops, runs, badRun, usualCount, standInCount = 0, 0, {}, 0, 0, 0
local closeRun = 0
local order = storyStats.order
check("story opens on the establishing step", STEP_OF[order[1]] == 1, tostring(order[1]))
for i = 1, #order do
    local step = STEP_OF[order[i]]
    if step == nil then
        -- A shot that is not part of the story at all.
        outOfOrder = outOfOrder + 1
    else
        if step == 3 then
            closeRun = closeRun + 1
        elseif closeRun > 0 then
            runs[#runs + 1] = closeRun
            if closeRun < 2 or closeRun > 3 then badRun = badRun + 1 end
            closeRun = 0
        end
        local previous = i > 1 and STEP_OF[order[i - 1]] or nil
        if previous ~= nil then
            local expected = previous == 3 and { 3, 4 } or { previous % 5 + 1 }
            if step ~= expected[1] and step ~= expected[2] then outOfOrder = outOfOrder + 1 end
            if step == 1 and previous == 5 then loops = loops + 1 end
        end
        if step ~= 3 then
            local entry = DroneCamDirector.STORY[step]
            if order[i] == entry[1] then usualCount = usualCount + 1 else standInCount = standInCount + 1 end
        end
    end
end
check("follows establishing -> push-in -> close-ups -> fly-over -> pull-out -> repeat",
      outOfOrder == 0, outOfOrder .. " out of order")
check("goes round the loop many times", loops >= 20, tostring(loops))
check("plays 2-3 close-ups per loop", badRun == 0 and #runs >= 20, ("%d runs, %d bad"):format(#runs, badRun))
local twos, threes = 0, 0
for _, r in ipairs(runs) do if r == 2 then twos = twos + 1 elseif r == 3 then threes = threes + 1 end end
check("sometimes two close-ups, sometimes three", twos > 3 and threes > 3, ("%d twos, %d threes"):format(twos, threes))
local standInShare = standInCount / (usualCount + standInCount)
check("varies each loop with stand-ins (20-50% of story steps)", standInShare > 0.2 and standInShare < 0.5,
      ("%.0f%%"):format(standInShare * 100))
check("story uses every stand-in", storyStats.seen[DroneCamSettings.SHOT_LONG_LENS] and storyStats.seen[DroneCamSettings.SHOT_EDGE_PAN]
      and storyStats.seen[DroneCamSettings.SHOT_RISE_UP] and storyStats.seen[DroneCamSettings.SHOT_SLIDE]
      and storyStats.seen[ORBIT])
check("story never repeats a shot", storyStats.repeats == 0)

local gappy = DroneCamDirector.new(DroneCam.settings)
gappy.random = makeRng(1357)
gappy.isShotAvailable = function(shot)
    return notHeadland(shot) and shot ~= DroneCamSettings.SHOT_ESTABLISHING and shot ~= DroneCamSettings.SHOT_FLY_OVER
end
gappy:start(nil, 0, true)
local gappyStats = survey(gappy, 1500)
check("story falls back to stand-ins when the usual shot has no spot",
      not gappyStats.seen[DroneCamSettings.SHOT_ESTABLISHING] and not gappyStats.seen[DroneCamSettings.SHOT_FLY_OVER]
      and gappyStats.seen[DroneCamSettings.SHOT_LONG_LENS] and gappyStats.seen[DroneCamSettings.SHOT_SLIDE]
      and gappyStats.repeats == 0)

print("\n-- auto director: headland shot near the end of the row --")
local rowEnd = false
local headlander = DroneCamDirector.new(DroneCam.settings)
headlander.random = makeRng(97)
headlander.isShotAvailable = function(shot) return shot ~= DroneCamSettings.SHOT_DRIVE_OVER and (shot ~= HEADLAND or rowEnd) end
headlander:start(nil, 0, true)
survey(headlander, 40)
check("no headland shot mid-row", headlander.shot ~= HEADLAND)
rowEnd = true
headlander.shotTime = headlander.shotLength
headlander:update(0.05, 0)
check("takes the headland shot when the row end comes up", headlander.shot == HEADLAND)
rowEnd = false
headlander.shotTime = headlander.shotLength
headlander:update(0.05, 0)
check("then carries on with the story", headlander.shot ~= HEADLAND and STEP_OF[headlander.shot] ~= nil)

print("\n-- auto director: holds through a headland turn --")
local dt = 0.016
local function runDirector(d, seconds, headingAt, startTime)
    local t = startTime
    local switchedAt = nil
    local before = d.shot
    for _ = 1, math.floor(seconds / dt) do
        t = t + dt
        d:update(dt, headingAt(t))
        if switchedAt == nil and d.shot ~= before then switchedAt = t end
    end
    return t, switchedAt
end

local turner = DroneCamDirector.new(DroneCam.settings)
turner.random = makeRng(4242)
turner:start(CHASE, 0)
turner.shotLength = 10
local turnStart, turnRate, turnLength = 8, math.rad(30), 5
local function headlandHeading(t)
    if t < turnStart then return 0 end
    return math.min(t - turnStart, turnLength) * turnRate
end
local t, switchedAt = runDirector(turner, turnStart, headlandHeading, 0)
check("no change on the straight before the shot is due", switchedAt == nil)
t, switchedAt = runDirector(turner, turnLength, headlandHeading, t)
check("recognises a 30 deg/s headland turn", turner:getIsTurning())
check("does not change angle mid-turn, even when overdue", switchedAt == nil,
      ("switched at %.2fs"):format(switchedAt or -1))
local straightAgain = t
t, switchedAt = runDirector(turner, 6, headlandHeading, t)
check("changes angle once straight again", switchedAt ~= nil)
local waited = (switchedAt or 0) - straightAgain
check("waits until the vehicle has settled on the new line",
      waited >= DroneCamDirector.STRAIGHT_SETTLE_TIME and waited < 3.5, ("waited %.2fs"):format(waited))

local wobbler = DroneCamDirector.new(DroneCam.settings)
wobbler.random = makeRng(7)
wobbler:start(CHASE, 0)
wobbler.shotLength = 10
-- Steering corrections: +-1.5 degrees of heading, about 3 deg/s at the peak.
local _, wobbleSwitch = runDirector(wobbler, 14, function(t2) return math.rad(1.5) * math.sin(t2 * 2) end, 0)
check("ordinary steering corrections do not hold the cut", wobbleSwitch ~= nil and wobbleSwitch < 11,
      ("switched at %s"):format(tostring(wobbleSwitch)))

local escaper = DroneCamDirector.new(DroneCam.settings)
escaper.random = makeRng(808)
escaper:start(CHASE, 0)
escaper:cutTo(DroneCamSettings.SHOT_WHEEL)
local te = runDirector(escaper, 2, function() return 0 end, 0)
check("close-up holds on the straight", escaper.shot == DroneCamSettings.SHOT_WHEEL)
local escapedAt, closeAgain = nil, false
local headlandStart = te
for _ = 1, math.floor(6 / dt) do
    te = te + dt
    escaper:update(dt, (te - headlandStart) * math.rad(30))
    if escapedAt == nil and not isClose(escaper.shot) then escapedAt = te end
    if escapedAt ~= nil and isClose(escaper.shot) then closeAgain = true end
end
check("a turn sends a close-up to a wide angle within a second",
      escapedAt ~= nil and escapedAt - headlandStart < 1, ("after %.2fs"):format((escapedAt or 99) - headlandStart))
check("no close-up for the rest of the turn", not closeAgain)

print("\n-- auto director: in flight --")
tick(12, false)
DroneCam.settings.mode = AUTO
tick(3, true)
check("engages in auto director mode", droneIsActive())
local camera = DroneCam.camera
check("director running", camera.director.isRunning)
check("story opens on an establishing shot (or a stand-in)",
      camera.shot == DroneCamSettings.SHOT_ESTABLISHING or camera.shot == DroneCamSettings.SHOT_LONG_LENS
      or camera.shot == DroneCamSettings.SHOT_EDGE_PAN, tostring(camera.shot))
camera.director.random = makeRng(2024)

local changes, sameTwice = 0, 0
local blendLengths = {}
local blending = 0
local shotSeen = camera.shot
-- Only time glides that start while measuring; take-off may still be gliding.
local countThisGlide = camera.fromPose == nil
local maxStep, maxTurn = measureMotion(75, true, 0, function(dtSeconds)
    if camera.shot ~= shotSeen then
        changes = changes + 1
        shotSeen = camera.shot
        countThisGlide = true
        blending = 0
    end
    if camera.fromPose ~= nil then
        blending = blending + dtSeconds
    elseif blending > 0 then
        if countThisGlide then blendLengths[#blendLengths + 1] = blending end
        blending = 0
    end
end)
print(("        75s: %d changes, worst frame %.2fm / %.2f deg"):format(changes, maxStep, maxTurn))
check("changes angle several times in 75s", changes >= 5 and changes <= 12, tostring(changes))
check("no hard cut in position", maxStep < MAX_STEP, ("%.2fm in one frame"):format(maxStep))
check("no hard cut in rotation", maxTurn < MAX_TURN, ("%.2f deg in one frame"):format(maxTurn))
local blendOk, twoSecond = #blendLengths >= 4, 0
for i = 1, #blendLengths do
    if blendLengths[i] < 2 - 0.05 or blendLengths[i] > DroneCamCamera.MAX_GLIDE_TIME + 0.05 then blendOk = false end
    if math.abs(blendLengths[i] - 2) < 0.05 then twoSecond = twoSecond + 1 end
end
check("each change glides for 2 seconds, longer only for long journeys", blendOk and twoSecond >= 2,
      table.concat(blendLengths, ", "))

print("\n-- auto director: no change during a headland in flight --")
-- Start from a wide angle: a close-up would rightly give way as the turn begins.
camera.director:cutTo(CHASE)
camera.director.shotLength = 60
tick(7, true) -- let the glide finish, however far it had to come
camera.director.shotTime = camera.director.shotLength - 0.5
local shotBeforeTurn = camera.shot
tick(5, true, math.rad(40))
check("angle held through the turn", camera.shot == shotBeforeTurn and camera.fromPose == nil)
tick(4, true)
check("angle changes after the turn", camera.shot ~= shotBeforeTurn)
tick(3, true)

print("\n-- auto director: entering and leaving --")
tick(12, false)
DroneCam.settings.mode = ORBIT
tick(6, true)
check("flying orbit", droneIsActive() and camera.shot == ORBIT)
DroneCam:onCycleMode()
tick(0.5, true)
check("switching to auto keeps the angle on screen", camera.shot == ORBIT and camera.fromPose == nil)
camera.director.shotTime = camera.director.shotLength
local _, turnOnCut = measureMotion(3, true)
check("first auto change is smooth", camera.shot ~= ORBIT and turnOnCut < MAX_TURN, ("%.2f deg"):format(turnOnCut))
camera.director.shotTime = 0
tick(8, true)
local autoShot = camera.shot
DroneCam.settings.mode = autoShot == CHASE and DroneCamSettings.MODE_TOPDOWN or CHASE
local leaveStep, leaveTurn = measureMotion(3, true)
check("leaving auto blends instead of cutting", leaveStep < MAX_STEP and leaveTurn < MAX_TURN,
      ("%.2fm / %.2f deg"):format(leaveStep, leaveTurn))
check("director stopped outside auto", not camera.director.isRunning)

print("\n-- manual changes blend too --")
DroneCam.settings.mode = CHASE
tick(4, true)
DroneCam.settings.mode = TOPDOWN
local manualStep, manualTurn = measureMotion(3, true)
check("chase -> top-down by hand is smooth", manualStep < MAX_STEP and manualTurn < MAX_TURN,
      ("%.2fm / %.2f deg"):format(manualStep, manualTurn))
local _, lookDown = localDirectionToWorld(cn, 0, 0, -1)
check("and still ends looking straight down", lookDown < -0.98, ("dy=%.3f"):format(lookDown))
DroneCam.settings.mode = ORBIT
local quickStep, quickTurn = measureMotion(0.5, true)
DroneCam.settings.mode = CHASE
local quickStep2, quickTurn2 = measureMotion(3, true)
check("a second change mid-blend does not jump",
      math.max(quickStep, quickStep2) < MAX_STEP and math.max(quickTurn, quickTurn2) < MAX_TURN,
      ("%.2fm / %.2f deg"):format(math.max(quickStep, quickStep2), math.max(quickTurn, quickTurn2)))

tick(4, true)

-- The orbit keeps circling while it is not on screen. Park it in front of the
-- vehicle: taking it up as-is would swing the camera half way round.
camera.orbitAngle = camera.heading
local function bearingFromBehind()
    local x, _, z = getWorldTranslation(cn)
    local vx2, _, vz2 = getWorldTranslation(vehicle.rootNode)
    return math.deg(math.abs(wrapAngle(math.atan2(x - vx2, z - vz2) - (camera.heading + math.pi))))
end
local worstSwing = 0
DroneCam.settings.mode = ORBIT
tick(2.5, true, 0, function() worstSwing = math.max(worstSwing, bearingFromBehind()) end)
check("chase -> orbit picks up the orbit from behind the vehicle", worstSwing < 30,
      ("swung %.0f deg round"):format(worstSwing))

-- Proves the limits above would catch a cut: with the blend switched off the
-- same change has to fail them.
DroneCam.settings.shotBlendTime = 0
DroneCam.settings.mode = TOPDOWN
local _, cutTurn = measureMotion(0.1, true)
check("sanity: without blending the change is a hard cut", cutTurn > MAX_TURN * 5, ("%.2f deg"):format(cutTurn))
DroneCam.settings.shotBlendTime = 2
DroneCam.settings.mode = CHASE
tick(12, false)

------------------------------------------------------------------ close-ups

local WHEEL = DroneCamSettings.SHOT_WHEEL
local IMPLEMENT = DroneCamSettings.SHOT_IMPLEMENT
local SIDE = DroneCamSettings.SHOT_SIDE
local FRONT = DroneCamSettings.SHOT_FRONT
local REAR_QUARTER = DroneCamSettings.SHOT_REAR_QUARTER

---Builds a vehicle combination: a root vehicle with wheels and any number of
---implements, each with one work area. Offsets are from the root vehicle:
---across (its local +X), up, along (forward).
local function makeRig(spec)
    local v = makeVehicle()
    v.size = { width = spec.width, length = spec.length, height = spec.height }
    v.spec_workArea = { workAreas = {} }
    v.attached = {}
    local function attach(node, across, up, along)
        v.attached[#v.attached + 1] = { node = node, across = across, up = up, along = along }
    end

    v.spec_wheels = { wheels = {} }
    for _, w in ipairs(spec.wheels) do
        for _, s in ipairs({ -1, 1 }) do
            local node = newNode("wheel")
            attach(node, s * w.across, w.radius, w.along)
            v.spec_wheels.wheels[#v.spec_wheels.wheels + 1] = { driveNode = node, physics = { radius = w.radius } }
        end
    end

    for name, value in pairs(spec.specs or {}) do v[name] = value end

    local children = { v }
    for _, imp in ipairs(spec.implements or {}) do
        local child = { rootNode = newNode("implement"), size = { width = imp.width, length = imp.length, height = imp.height } }
        attach(child.rootNode, 0, 0, imp.along)
        if not imp.noWork then
            local half = imp.workWidth / 2
            local front, back = imp.along + imp.workDepth / 2, imp.along - imp.workDepth / 2
            local s, w, h = newNode("workStart"), newNode("workWidth"), newNode("workHeight")
            attach(s, half, 0, front)
            attach(w, -half, 0, front)
            attach(h, half, 0, back)
            child.spec_workArea = { workAreas = { { start = s, width = w, height = h, lastProcessingTime = -10000 } } }
            function child:getIsWorkAreaProcessing(wa) return wa.lastProcessingTime + 200 >= g_currentMission.time end
        end
        -- What it is (spec_trailer, spec_sprayer...), and the state the
        -- game reports: lowered (if it can say), fold time (if it folds).
        -- Read live from the spec, so a test can fold or lower it mid-pass.
        for name, value in pairs(imp.specs or {}) do child[name] = value end
        local parent = imp.attachedTo ~= nil and children[imp.attachedTo] or v
        function child:getAttacherVehicle() return parent end
        if imp.lowered ~= nil then
            function child:getIsLowered(default) return imp.lowered end
        end
        if imp.fold ~= nil then
            child.spec_foldable = {}
            function child:getFoldAnimTime() return imp.fold end
        end
        if imp.wheels ~= nil then
            child.spec_wheels = { wheels = {} }
            for _, w in ipairs(imp.wheels) do
                for _, s in ipairs({ -1, 1 }) do
                    local node = newNode("wheel")
                    attach(node, s * w.across, w.radius, w.along)
                    child.spec_wheels.wheels[#child.spec_wheels.wheels + 1] = { driveNode = node, physics = { radius = w.radius } }
                end
            end
        end
        children[#children + 1] = child
    end
    v.getChildVehicles = function() return children end

    -- Collision bodies, all given relative to the root vehicle (see tick).
    v.bodies = {}
    for _, b in ipairs(spec.bodies or {}) do v.bodies[#v.bodies + 1] = b end
    for _, imp in ipairs(spec.implements or {}) do
        for _, b in ipairs(imp.bodies or {}) do v.bodies[#v.bodies + 1] = b end
    end

    return v
end

local SMALL_TRACTOR = {
    width = 2.0, length = 3.6, height = 2.5,
    wheels = { { across = 0.8, along = -0.9, radius = 0.6 }, { across = 0.8, along = 1.0, radius = 0.4 } },
    implements = { { along = -3.2, width = 2.5, length = 1.5, height = 1.1, workWidth = 2.5, workDepth = 1.0 } }
}
local TRACTOR = {
    width = 2.6, length = 5, height = 3,
    wheels = { { across = 1.0, along = -1.2, radius = 0.8 }, { across = 1.0, along = 1.5, radius = 0.55 } },
    implements = { { along = -4.6, width = 4, length = 2.5, height = 1.4, workWidth = 4, workDepth = 1.6 } }
}
local COMBINE = {
    width = 3.6, length = 9, height = 4,
    wheels = { { across = 1.4, along = 1.6, radius = 0.95 }, { across = 1.3, along = -2.8, radius = 0.65 } },
    implements = { { along = 5.6, width = 9, length = 2, height = 1.5, workWidth = 9, workDepth = 1.5 } }
}

local plainVehicle = vehicle

---Puts the player in a new vehicle and lands any drone that was flying.
local function driveVehicle(v)
    vehicle = v
    tick(12, false)
end

-- In a block of its own: Lua 5.1 allows only 200 locals per function.
do

---Where a close-up puts the camera for the current vehicle, in its frame.
local function shotGeometry(shot, side)
    camera.vehicle = vehicle
    camera.rig = nil
    camera.vehicleHeading = heading
    camera.shotSide = side
    local px, py, pz, lx, ly, lz = camera:getCloseUpTransform(vehicle, shot)
    local rig = camera:getRig(vehicle)
    local across, along = DroneCamRig.toLocal(rig, px, pz)
    local lookAcross, lookAlong = DroneCamRig.toLocal(rig, lx, lz)
    return {
        rig = rig, across = across, along = along, height = py - rig.ground,
        lookAcross = lookAcross, lookAlong = lookAlong, lookHeight = ly - rig.ground,
        clear = DroneCamRig.getVehicleFloor(rig, px, pz, true) <= py,
        distance = math.sqrt(across * across + along * along)
    }
end

local ALL_CLOSE = { WHEEL, IMPLEMENT, SIDE, FRONT, REAR_QUARTER }
local SHOT_NAMES = { [WHEEL] = "wheel", [IMPLEMENT] = "implement", [SIDE] = "side",
                     [FRONT] = "front", [REAR_QUARTER] = "rear quarter" }

print("\n-- close-ups: placement on a tractor with a cultivator --")
driveVehicle(makeRig(TRACTOR))
local rigNow = DroneCamRig.measure(vehicle, heading)
check("rig sees the tractor and the implement", #rigNow.boxes == 2 and rigNow.rear < -5)
check("rig finds the worked strip behind", rigNow.work ~= nil and not rigNow.work.isFront
      and math.abs(rigNow.work.halfWidth - 2) < 0.01, rigNow.work and rigNow.work.halfWidth)

for _, side in ipairs({ 1, -1 }) do
    for _, shot in ipairs(ALL_CLOSE) do
        local g = shotGeometry(shot, side)
        check(("%s (side %d) is clear of the tractor and implement"):format(SHOT_NAMES[shot], side), g.clear)
    end
end

local g = shotGeometry(WHEEL, 1)
local rearWheel = DroneCamRig.getRearWheel(g.rig, 1)
check("wheel cam is low", g.height < 1.5, ("%.2fm"):format(g.height))
check("wheel cam sits beside the rear wheel", g.across > 0 and math.abs(g.along - rearWheel.lz) < 2
      and math.abs(g.across - rearWheel.lx) < 4, ("across %.2f along %.2f"):format(g.across, g.along))
check("wheel cam looks at the rear wheel", math.abs(g.lookAlong - rearWheel.lz) < 0.01
      and math.abs(g.lookAcross - rearWheel.lx) < 0.01)
check("wheel cam on the other side mirrors it", shotGeometry(WHEEL, -1).across < 0)

g = shotGeometry(IMPLEMENT, 1)
check("implement cam is behind the implement", g.along < g.rig.rear, ("%.2f vs %.2f"):format(g.along, g.rig.rear))
check("implement cam is low", g.height < 3, ("%.2fm"):format(g.height))
check("implement cam looks at the worked soil", g.lookHeight < 0.5 and g.lookAlong < g.along + 4
      and g.lookAlong > g.along)

g = shotGeometry(SIDE, 1)
check("side tracking is about 8m out from the side", math.abs(g.across - g.rig.halfWidth - 8 * g.rig.scale) < 0.01
      and g.rig.scale > 0.9 and g.rig.scale < 1.2, ("%.2f out at scale %.2f"):format(g.across - g.rig.halfWidth, g.rig.scale))
check("side tracking is about 3m up", math.abs(g.height - 3 * g.rig.scale) < 0.01, ("%.2fm"):format(g.height))

g = shotGeometry(FRONT, 1)
check("front low is ahead of the tractor", g.along > g.rig.front + 5, ("%.2f"):format(g.along))
check("front low is low", g.height < 2, ("%.2fm"):format(g.height))
check("front low looks back at the tractor", g.lookAlong < g.along - 5)

g = shotGeometry(REAR_QUARTER, 1)
check("rear quarter is behind the cab and out to the side", g.along < g.rig.rootRear and g.across > g.rig.halfWidth)
check("rear quarter is at cab height", math.abs(g.height - 0.85 * g.rig.rootHeight) < 0.01, ("%.2fm"):format(g.height))

print("\n-- close-ups: scale with the vehicle --")
local tractorSide, tractorFront = shotGeometry(SIDE, 1), shotGeometry(FRONT, 1)
local tractorWheel = shotGeometry(WHEEL, 1)
driveVehicle(makeRig(SMALL_TRACTOR))
local smallSide, smallFront = shotGeometry(SIDE, 1), shotGeometry(FRONT, 1)
local smallWheel = shotGeometry(WHEEL, 1)
local smallClear = true
for _, shot in ipairs(ALL_CLOSE) do smallClear = smallClear and shotGeometry(shot, 1).clear and shotGeometry(shot, -1).clear end
check("every close-up is clear of a small tractor", smallClear)
driveVehicle(makeRig(COMBINE))
local combineSide, combineFront = shotGeometry(SIDE, 1), shotGeometry(FRONT, 1)
local combineWheel = shotGeometry(WHEEL, 1)
local combineClear = true
for _, shot in ipairs(ALL_CLOSE) do combineClear = combineClear and shotGeometry(shot, 1).clear and shotGeometry(shot, -1).clear end
check("every close-up is clear of a combine with a 9m header", combineClear)
print(("        scale: small %.2f, tractor %.2f, combine %.2f"):format(
      smallSide.rig.scale, tractorSide.rig.scale, combineSide.rig.scale))
check("scale grows with the vehicle", smallSide.rig.scale < tractorSide.rig.scale
      and combineSide.rig.scale > 1.5 * smallSide.rig.scale)
check("side tracking stands further off a combine",
      combineSide.distance > 1.5 * smallSide.distance, ("%.1f vs %.1f"):format(combineSide.distance, smallSide.distance))
check("front low stands further ahead of a combine",
      combineFront.along - combineFront.rig.front > 1.5 * (smallFront.along - smallFront.rig.front))
check("wheel cam keeps clear of a combine's bigger wheels", combineWheel.distance > smallWheel.distance)

local header = shotGeometry(IMPLEMENT, 1)
check("rig finds a combine header in front", header.rig.work ~= nil and header.rig.work.isFront)
check("implement cam on a combine sits off the end of the header", header.across > header.rig.work.halfWidth
      and math.abs(header.along - header.rig.work.lz) < 4, ("across %.1f along %.1f"):format(header.across, header.along))

print("\n-- crop height --")
CROP_AT = function() return 1, 5 end
check("ripe maize is counted at full height", DroneCamCamera.getCropHeightAt(0, 0) == 3.2)
CROP_AT = function() return 1, 2 end
check("young maize is shorter", math.abs(DroneCamCamera.getCropHeightAt(0, 0) - 3.2 * 2 / 5) < 1e-9)
CROP_AT = function() return 1, 8 end
check("stubble does not count", DroneCamCamera.getCropHeightAt(0, 0) == 0)
CROP_AT = function() return 0, 0 end
check("bare ground does not count", DroneCamCamera.getCropHeightAt(0, 0) == 0)

---Flies the director over the current vehicle, checking every frame that the
---camera is out of the ground, the crop and the vehicle, and moves smoothly.
local function flyAndCheck(seconds, headingRate, cropHeight)
    local result = { inside = 0, underground = 0, inCrop = 0, maxStep = 0, maxTurn = 0, seen = {},
                     lowest = math.huge, closeFrames = 0 }
    local px, py, pz = getWorldTranslation(cn)
    local prx, pry = nodes[cn].rx, nodes[cn].ry

    tick(seconds, true, headingRate, function()
        local x, y, z = getWorldTranslation(cn)
        local rx, ry = nodes[cn].rx, nodes[cn].ry
        result.maxStep = math.max(result.maxStep, math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2))
        result.maxTurn = math.max(result.maxTurn, countTurn(math.max(math.deg(math.abs(rx - prx)), math.deg(math.abs(wrapAngle(ry - pry))))))
        px, py, pz, prx, pry = x, y, z, rx, ry

        if camera.floorsArmed then
            local rigCheck = DroneCamRig.measure(vehicle, heading)
            if y < DroneCamRig.getVehicleFloor(rigCheck, x, z, false, DroneCamCreator.getIsDriveOverLow(camera)) - 1e-6 then result.inside = result.inside + 1 end
            if y < TERRAIN_HEIGHT + 0.5 then result.underground = result.underground + 1 end
            if cropHeight ~= nil and y < TERRAIN_HEIGHT + cropHeight then result.inCrop = result.inCrop + 1 end
        end

        if camera.shot ~= nil then result.seen[camera.shot] = true end
        if isClose(camera.shot) and camera.fromPose == nil then
            result.closeFrames = result.closeFrames + 1
            result.lowest = math.min(result.lowest, y - TERRAIN_HEIGHT)
        end
    end)

    return result
end

local function allCloseSeen(seen)
    for _, shot in ipairs(ALL_CLOSE) do
        if not seen[shot] then return false end
    end
    return true
end

print("\n-- close-ups in flight: tractor with a cultivator --")
driveVehicle(makeRig(TRACTOR))
DroneCam.settings.mode = AUTO
tick(3, true)
camera.director.random = makeRng(4711)
local flight = flyAndCheck(300, 0)
print(("        300s: worst frame %.2fm / %.2f deg, lowest close-up %.2fm"):format(flight.maxStep, flight.maxTurn, flight.lowest))
check("flies every close-up", allCloseSeen(flight.seen))
local wideSeen = 0
for shot in pairs(flight.seen) do if not isClose(shot) then wideSeen = wideSeen + 1 end end
check("and wide shots in between", wideSeen >= 4, tostring(wideSeen))
check("never inside the tractor or implement", flight.inside == 0, flight.inside .. " frames")
check("never into the ground", flight.underground == 0, flight.underground .. " frames")
check("close-ups go well below the 8m minimum", flight.lowest < 2, ("%.2fm"):format(flight.lowest))
check("smooth glide between every shot", flight.maxStep < MAX_STEP and flight.maxTurn < MAX_TURN,
      ("%.2fm / %.2f deg"):format(flight.maxStep, flight.maxTurn))

print("\n-- close-ups track the vehicle --")
camera.director:cutTo(WHEEL)
camera.director.shotLength = 30
tick(7, true) -- let the glide finish, however far it had to come
local trackedWorst = 0
tick(5, true, 0, function()
    local x, _, z = getWorldTranslation(cn)
    local rigNow2 = DroneCamRig.measure(vehicle, heading)
    local wheelNow = DroneCamRig.getRearWheel(rigNow2, camera.shotSide)
    local wx, wz = DroneCamRig.toWorld(rigNow2, wheelNow.lx, wheelNow.lz)
    trackedWorst = math.max(trackedWorst, math.sqrt((x - wx) ^ 2 + (z - wz) ^ 2))
end)
check("wheel cam stays beside the wheel at working speed", trackedWorst < 4.5, ("%.2fm away"):format(trackedWorst))

print("\n-- safety net: a shot aimed into the vehicle --")
-- Every real shot keeps clear, so prove the floors on their own: aim the
-- wheel cam straight into the cab and check the camera rises over instead.
local realCloseUp = camera.getCloseUpTransform
camera.getCloseUpTransform = function(self, v, shot)
    local _, _, _, lx, ly, lz = realCloseUp(self, v, shot)
    local rx, ry, rz = getWorldTranslation(v.rootNode)
    return rx, ry + 1, rz, lx, ly, lz, nil, nil
end
local net = flyAndCheck(5, 0)
camera.getCloseUpTransform = nil
local _, netY = getWorldTranslation(cn)
check("camera never enters the vehicle, even when aimed into it", net.inside == 0, net.inside .. " frames")
check("it rises over the cab instead", netY >= TERRAIN_HEIGHT + TRACTOR.height + DroneCamRig.HARD_MARGIN - 1e-6,
      ("%.2fm"):format(netY))
check("and rises smoothly", net.maxStep < MAX_STEP, ("%.2fm"):format(net.maxStep))
camera.director:cutTo(CHASE)
tick(4, true)

print("\n-- close-ups in flight: a headland turn --")
camera.director:cutTo(SIDE)
camera.director.shotLength = 30
tick(4, true)
check("side tracking on screen before the turn", camera.shot == SIDE)
local turnFlight = flyAndCheck(1.0, math.rad(40))
check("turn starts: close-up gives way to a wide angle", not isClose(camera.director.shot))
local restOfTurn = flyAndCheck(3.5, math.rad(40))
local closeInTurn = false
for _, shot in ipairs(ALL_CLOSE) do closeInTurn = closeInTurn or (restOfTurn.seen[shot] and shot ~= SIDE) end
check("no new close-up during the turn", not closeInTurn)
check("leaving the close-up in a turn is still smooth and clear",
      math.max(turnFlight.maxStep, restOfTurn.maxStep) < MAX_STEP and math.max(turnFlight.maxTurn, restOfTurn.maxTurn) < MAX_TURN
      and turnFlight.inside + restOfTurn.inside == 0,
      ("%.2fm / %.2f deg, %d inside"):format(math.max(turnFlight.maxStep, restOfTurn.maxStep),
          math.max(turnFlight.maxTurn, restOfTurn.maxTurn), turnFlight.inside + restOfTurn.inside))

print("\n-- close-ups in flight: tractor with nothing attached --")
local SOLO = { width = TRACTOR.width, length = TRACTOR.length, height = TRACTOR.height, wheels = TRACTOR.wheels }
local solo = makeRig(SOLO)
solo.spec_workArea = { workAreas = { { lastProcessingTime = -10000 } } } -- works, but has no work area nodes
vehicle = solo
tick(3, true)
camera.director.random = makeRng(1234)
local soloFlight = flyAndCheck(200, 0)
check("no implement shot without an implement", not soloFlight.seen[IMPLEMENT])
check("the other close-ups still fly", soloFlight.seen[WHEEL] and soloFlight.seen[SIDE]
      and soloFlight.seen[FRONT] and soloFlight.seen[REAR_QUARTER])
check("solo tractor: never inside, smooth", soloFlight.inside == 0 and soloFlight.maxStep < MAX_STEP
      and soloFlight.maxTurn < MAX_TURN)

print("\n-- close-ups in flight: combine in standing maize --")
CROP_AT = function() return 1, 5 end
-- Random mode: about every other shot is a close-up, so all five come up.
DroneCam.settings.mode = AUTO_RANDOM
driveVehicle(makeRig(COMBINE))
tick(3, true)
camera.director.random = makeRng(90210)
local maize = flyAndCheck(300, 0, 3.2 + DroneCamCamera.CROP_HARD_MARGIN - 1e-6)
DroneCam.settings.mode = AUTO
print(("        300s: worst frame %.2fm / %.2f deg, lowest close-up %.2fm"):format(maize.maxStep, maize.maxTurn, maize.lowest))
check("flies every close-up over a combine", allCloseSeen(maize.seen))
check("never into the maize", maize.inCrop == 0, maize.inCrop .. " frames")
check("never inside the combine or header", maize.inside == 0, maize.inside .. " frames")
check("still lower than the wide angles", maize.lowest < 6, ("%.2fm"):format(maize.lowest))
check("smooth over the maize", maize.maxStep < MAX_STEP and maize.maxTurn < MAX_TURN,
      ("%.2fm / %.2f deg"):format(maize.maxStep, maize.maxTurn))

CROP_AT = function() return 0, 0 end
DroneCam.settings.mode = CHASE
driveVehicle(plainVehicle)
end

------------------------------------------------------------- creator shots

-- In a block of its own: Lua 5.1 allows only 200 locals per function.
do
local S = DroneCamSettings
local ESTABLISHING, LONG_LENS, EDGE_PAN = S.SHOT_ESTABLISHING, S.SHOT_LONG_LENS, S.SHOT_EDGE_PAN
local PUSH_IN, PULL_OUT, FLY_OVER, RISE_UP, SLIDE = S.SHOT_PUSH_IN, S.SHOT_PULL_OUT, S.SHOT_FLY_OVER, S.SHOT_RISE_UP, S.SHOT_SLIDE
local FIXED = { ESTABLISHING, LONG_LENS, EDGE_PAN, HEADLAND }
local SHOT_LABEL = { [ESTABLISHING] = "establishing", [LONG_LENS] = "long lens", [EDGE_PAN] = "field-edge pan",
                     [HEADLAND] = "headland", [PUSH_IN] = "push-in", [PULL_OUT] = "pull-out", [FLY_OVER] = "fly-over",
                     [RISE_UP] = "rise-up", [SLIDE] = "slide" }

local function insideAnyObstacle(x, y, z, margin)
    for _, box in ipairs(OBSTACLES) do
        if pointInBox(x, y, z, box, margin) then return true end
    end
    return false
end

---Independent sight-line check: does the segment pass through any box?
local function segmentBlocked(x, y, z, tx, ty, tz)
    local dx, dy, dz = tx - x, ty - y, tz - z
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    for _, box in ipairs(OBSTACLES) do
        local t = rayBox(x, y, z, dx / length, dy / length, dz / length, box)
        if t ~= nil and t < length - 1 then return true end
    end
    return false
end

---Puts the vehicle at a spot on the map, heading north (+z), and lands the drone.
local function placeVehicle(v, x, z)
    vehicle = v
    tick(12, false)
    nodes[v.rootNode].x, nodes[v.rootNode].z = x, z
    heading = 0
    tick(0.1, false)
end

---Points the camera's bookkeeping at the current vehicle as update() would,
---so the planners can be called directly.
local function primeCamera(speed)
    camera.vehicle = vehicle
    camera.rig = nil
    camera.frameId = camera.frameId + 1
    camera.heading, camera.vehicleHeading = heading, heading
    camera.vehicleSpeed = speed or 8
end

print("\n-- spot checks --")
OBSTACLES = {
    { 10, 14, 0, 12, -2, 2 },       -- a tree
    { 20, 40, 15, 25, -10, 10 },    -- a canopy overhead
    { -20, -10, 0, 8, -5, 5 },      -- a barn
}
check("spot inside a tree is rejected", not DroneCamSpot.getIsSpotClear(12, 5, 0))
check("spot under a canopy is rejected", not DroneCamSpot.getIsSpotClear(30, 5, 0))
check("spot against a wall is rejected", not DroneCamSpot.getIsSpotClear(-8.5, 3, 0))
check("open spot is accepted", DroneCamSpot.getIsSpotClear(0, 3, 30))
check("spot below ground is rejected", not DroneCamSpot.getIsSpotClear(0, -1, 30))
check("sight line through the barn is blocked", not DroneCamSpot.getHasLineOfSight(-40, 3, 0, 0, 2, 0))
check("clear sight line is clear", DroneCamSpot.getHasLineOfSight(0, 3, 40, 0, 2, 0))
TERRAIN_FN = function(x, z) return z > 15 and z < 25 and 20 or 0 end
check("sight line over a ridge is blocked", not DroneCamSpot.getHasLineOfSight(0, 3, 60, 0, 2, 0))
TERRAIN_FN = nil
OBSTACLES = {}

print("\n-- field edges --")
FIELD = { -100, 100, -300, 300 }
local east = DroneCamField.getEdgeDistance(0, 0, 1, 0)
check("finds the field edge", east ~= nil and math.abs(east - 100) < 0.6, tostring(east))
check("no edge when off the field", DroneCamField.getEdgeDistance(500, 0, 1, 0) == nil)
local probe = DroneCamField.probe(0, 0)
check("measures the whole field", probe ~= nil and math.abs(probe.x) < 1 and math.abs(probe.z) < 1
      and math.abs(probe.radius - 300) < 2, probe and ("(%.1f, %.1f) r=%.1f"):format(probe.x, probe.z, probe.radius))

-- The world for the creator shots: a 200m x 600m field running north, a
-- hedge of trees all along its east edge, a forest to the south-east and a
-- barn across the north end of the rows.
local HEDGE = { 100, 106, 0, 10, -400, 400 }
local FOREST = { 100, 400, 0, 18, -400, -50 }
local BARN = { -16, 16, 0, 9, 303, 318 }
OBSTACLES = { HEDGE, FOREST, BARN }
FIELD = { -100, 100, -300, 300 }

local tractorRig = makeRig(TRACTOR)

do
print("\n-- fixed shots: picking spots --")
placeVehicle(tractorRig, 0, -100)
primeCamera(8)
for _, shot in ipairs({ ESTABLISHING, LONG_LENS, EDGE_PAN }) do
    local planOk, clear, sight = true, true, true
    for _ = 1, 12 do -- both first-side choices, several times over
        primeCamera(8)
        local plan = DroneCamCreator.plan(camera, vehicle, shot)
        if plan == nil then
            planOk = false
        else
            camera.plan = plan
            camera.shotElapsed = 0
            local px, py, pz = DroneCamCreator.getTransform(camera, vehicle, shot)
            local ax, ay, az = getWorldTranslation(vehicle.rootNode)
            if insideAnyObstacle(px, py, pz, DroneCamSpot.SIDE_CLEARANCE - 0.01) then clear = false end
            if segmentBlocked(px, py, pz, ax, ay + 2, az) then sight = false end
        end
    end
    check(SHOT_LABEL[shot] .. " finds a spot", planOk)
    check(SHOT_LABEL[shot] .. " spot is clear of trees and buildings", clear)
    check(SHOT_LABEL[shot] .. " spot can see the tractor", sight)
end

primeCamera(8)
local edgePlan = DroneCamCreator.plan(camera, vehicle, EDGE_PAN)
check("field-edge pan stands at the open west edge, not in the hedge",
      edgePlan ~= nil and edgePlan.x < -100 and edgePlan.x > -106, edgePlan and ("x=%.1f"):format(edgePlan.x))
check("field-edge pan is low", edgePlan ~= nil and edgePlan.y - TERRAIN_HEIGHT < 4)

-- A clump of trees just inside the west edge: the usual spot can see the
-- tractor now, but would lose it behind the trees within a few seconds.
OBSTACLES[#OBSTACLES + 1] = { -95, -85, 0, 10, -79, -30 }
local stillInView = true
for _ = 1, 6 do
    primeCamera(8)
    local plan = DroneCamCreator.plan(camera, vehicle, EDGE_PAN)
    local ax, ay, az = getWorldTranslation(vehicle.rootNode)
    for _, ahead in ipairs({ 0, 40, 80 }) do
        if plan == nil or segmentBlocked(plan.x, plan.y, plan.z, ax, ay + 2, az + ahead) then stillInView = false end
    end
end
check("field-edge pan picks a spot that keeps the tractor in view as it drives on", stillInView)
OBSTACLES[#OBSTACLES] = nil

local lensPlan
for _ = 1, 6 do
    primeCamera(8)
    lensPlan = DroneCamCreator.plan(camera, vehicle, LONG_LENS)
    local ax, _, az = getWorldTranslation(vehicle.rootNode)
    local far = math.sqrt((lensPlan.x - ax) ^ 2 + (lensPlan.z - az) ^ 2)
    if far < 140 or pointInBox(lensPlan.x, lensPlan.y, lensPlan.z, FOREST, 0) then lensPlan = nil break end
end
check("long lens stands about 150m away, never in the forest", lensPlan ~= nil)
camera.plan = lensPlan
camera.shot = LONG_LENS
local lensFov = DroneCamCreator.getFov(camera, vehicle, LONG_LENS)
check("long lens zooms in tight", lensFov < 15 and lensFov >= DroneCamCreator.LONG_LENS_MIN_FOV, ("%.1f deg"):format(lensFov))

primeCamera(8)
local estPlan = DroneCamCreator.plan(camera, vehicle, ESTABLISHING)
camera.plan, camera.shot, camera.shotElapsed = estPlan, ESTABLISHING, 0
local ex, ey, ez = DroneCamCreator.getTransform(camera, vehicle, ESTABLISHING)
-- The field is 200m x 600m; the camera must stand far enough off, and high
-- enough, to take in all of it.
check("establishing frames the whole field from high up",
      estPlan ~= nil and ey > 150 and estPlan.distance >= 299 and math.abs(estPlan.centreX) < 1
      and estPlan.centreZ > -300 and estPlan.centreZ < 300,
      estPlan and ("%.0fm up, %.0fm out"):format(ey, estPlan.distance))
camera.shotElapsed = 10
local ex2, _, ez2 = DroneCamCreator.getTransform(camera, vehicle, ESTABLISHING)
local driftAngle = math.deg(math.abs(wrapAngle(math.atan2(ex2 - estPlan.centreX, ez2 - estPlan.centreZ)
    - math.atan2(ex - estPlan.centreX, ez - estPlan.centreZ))))
check("establishing drifts slowly round the field", driftAngle > 10 and driftAngle < 20,
      ("%.1f deg in 10s"):format(driftAngle))
end

do
print("\n-- headland shot --")
placeVehicle(tractorRig, 0, 150)
primeCamera(8)
check("no headland shot with the row end 150m off", DroneCamCreator.plan(camera, vehicle, HEADLAND) == nil)
placeVehicle(tractorRig, 0, 220)
primeCamera(8)
local headPlan = DroneCamCreator.plan(camera, vehicle, HEADLAND)
check("headland shot offered 10s before the row end", headPlan ~= nil)
check("headland spot is past the end of the row", headPlan ~= nil and headPlan.z > 300)
check("headland spot is not in the barn", headPlan ~= nil and not insideAnyObstacle(headPlan.x, headPlan.y, headPlan.z, 1.99))
check("headland spot can see the tractor", headPlan ~= nil and not segmentBlocked(headPlan.x, headPlan.y, headPlan.z, 0, 2, 220))
primeCamera(0)
check("no headland shot when stopped", DroneCamCreator.plan(camera, vehicle, HEADLAND) == nil)
placeVehicle(tractorRig, 0, 290)
primeCamera(8)
check("no headland shot right at the row end", DroneCamCreator.plan(camera, vehicle, HEADLAND) == nil)
end

print("\n-- fixed shots: nowhere good to stand --")
OBSTACLES = { HEDGE, FOREST, BARN, { -2000, 2000, 40, 300, -2000, 2000 } } -- a canopy over everything
placeVehicle(tractorRig, 0, 220)
primeCamera(8)
local anyPlanned = false
for _, shot in ipairs(FIXED) do
    camera.planCache = {}
    anyPlanned = anyPlanned or camera:getIsShotAvailable(shot)
end
check("no fixed shot is offered when every spot is covered", not anyPlanned)
OBSTACLES = { HEDGE, FOREST, BARN }

do
print("\n-- moving shots: their paths --")
placeVehicle(tractorRig, 0, -100)
primeCamera(8)
camera.shotSide = 1
local function pathAt(shot, progress)
    camera.shot = shot
    camera.shotDuration = 10
    camera.shotElapsed = progress * 10
    camera.rig = nil
    local px, py, pz, lx, ly, lz, yaw, pitch, weight = DroneCamCreator.getTransform(camera, vehicle, shot)
    local rig = camera:getRig(vehicle)
    local across, along = DroneCamRig.toLocal(rig, px, pz)
    return { across = across, along = along, height = py - rig.ground, rig = rig,
             distance = math.sqrt(across * across + along * along), yaw = yaw, pitch = pitch, weight = weight }
end

local p0, p1 = pathAt(PUSH_IN, 0), pathAt(PUSH_IN, 1)
check("push-in starts about 150m away and high", p0.distance > 145 and p0.height >= 60, ("%.0fm, %.0fm up"):format(p0.distance, p0.height))
check("push-in ends at the chase position", math.abs(p1.along + DroneCam.settings.chaseDistance) < 0.5
      and math.abs(p1.height - DroneCam.settings.chaseHeight) < 0.5 and math.abs(p1.across) < 0.5)

local monotonic, last = true, pathAt(PULL_OUT, 0)
check("pull-out starts close and low", last.distance < 12 and last.height < 3, ("%.1fm, %.1fm up"):format(last.distance, last.height))
for i = 1, 10 do
    local p = pathAt(PULL_OUT, i / 10)
    if p.distance < last.distance - 1e-6 or p.height < last.height - 1e-6 then monotonic = false end
    last = p
end
check("pull-out rises and pulls back the whole way", monotonic and last.distance > 40 and last.height > 30)

local over, alwaysAbove = pathAt(FLY_OVER, 0), true
local topY = 0
for _, box in ipairs(over.rig.boxes) do topY = math.max(topY, box.ground + box.height) end
check("fly-over starts ahead of the tractor", over.along > over.rig.front)
for i = 0, 20 do
    local p = pathAt(FLY_OVER, i / 20)
    if p.height + over.rig.ground < topY + 4 then alwaysAbove = false end
end
local mid = pathAt(FLY_OVER, 0.5)
check("fly-over passes over the tractor", math.abs(mid.across) < 3 and mid.along < over.rig.front and mid.along > over.rig.rear)
check("fly-over stays well above the tractor", alwaysAbove)
check("fly-over ends behind", pathAt(FLY_OVER, 1).along < over.rig.rear)

local r0, r1 = pathAt(RISE_UP, 0), pathAt(RISE_UP, 1)
check("rise-up starts low behind", r0.height < 3 and r0.along < r0.rig.rear and r0.weight < 0.01)
check("rise-up ends top-down overhead", r1.distance < 0.5 and math.abs(r1.height - DroneCam.settings.topDownHeight) < 0.5
      and r1.weight > 0.99 and math.abs(r1.pitch + math.pi / 2) < 1e-6)

local s0, s1 = pathAt(SLIDE, 0), pathAt(SLIDE, 1)
check("slide stays far out to the side", s0.across > 60 and s1.across > 60)
check("slide slides past", s0.along > 30 and s1.along < -30)
camera.shot = SLIDE
check("slide uses a longer lens", DroneCamCreator.getFov(camera, vehicle, SLIDE) <= DroneCamCreator.SLIDE_FOV)
end

---Flies the current vehicle, checking every frame: clear of obstacles, the
---vehicle and the ground, smooth, and (for fixed spots once settled) with a
---clear view of the vehicle.
local function flyWorld(seconds, headingRate, onStep)
    local r = { inObstacle = 0, inside = 0, underground = 0, blockedFixed = 0, fixedFrames = 0, maxStep = 0,
                maxTurn = 0, maxFov = 0, seen = {}, order = {} }
    local px, py, pz = getWorldTranslation(cn)
    local prx, pry = nodes[cn].rx, nodes[cn].ry
    local pfov = camera.appliedFov
    local lastShot = camera.shot
    local wasFlying = droneIsActive()
    r.order[1] = wasFlying and camera.shot or nil

    tick(seconds, true, headingRate, function(dtSeconds)
        local x, y, z = getWorldTranslation(cn)
        local rx, ry = nodes[cn].rx, nodes[cn].ry
        -- Only judge movement between frames the drone was flying in: taking
        -- off starts from wherever the vehicle camera happens to be.
        local flying = droneIsActive()
        if flying and wasFlying then
            r.maxStep = math.max(r.maxStep, math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2))
            r.maxTurn = math.max(r.maxTurn, countTurn(math.max(math.deg(math.abs(rx - prx)), math.deg(math.abs(wrapAngle(ry - pry))))))
            r.maxFov = math.max(r.maxFov, math.abs(camera.appliedFov - pfov))
        end
        wasFlying = flying
        px, py, pz, prx, pry, pfov = x, y, z, rx, ry, camera.appliedFov

        if insideAnyObstacle(x, y, z, 0) then r.inObstacle = r.inObstacle + 1 end
        if camera.floorsArmed then
            local rigCheck = DroneCamRig.measure(vehicle, heading)
            if y < DroneCamRig.getVehicleFloor(rigCheck, x, z, false, DroneCamCreator.getIsDriveOverLow(camera)) - 1e-6 then r.inside = r.inside + 1 end
            if y < TERRAIN_HEIGHT + 0.5 then r.underground = r.underground + 1 end
        end

        if DroneCamDirector.getIsFixed(camera.shot) and camera.fromPose == nil and camera.shotElapsed > 1 then
            r.fixedFrames = r.fixedFrames + 1
            local ax, ay, az = getWorldTranslation(vehicle.rootNode)
            if segmentBlocked(x, y, z, ax, ay + 2, az) then r.blockedFixed = r.blockedFixed + 1 end
        end

        if flying and camera.shot ~= lastShot then
            r.order[#r.order + 1] = camera.shot
            lastShot = camera.shot
        end
        if camera.shot ~= nil then r.seen[camera.shot] = true end
        if onStep then onStep(dtSeconds) end
    end)

    return r
end

do
print("\n-- creator shots in flight: story mode down a long field --")
FIELD = { -100, 100, -300, 3000 }
OBSTACLES = { { 100, 106, 0, 10, -400, 3100 }, FOREST }
placeVehicle(tractorRig, 0, -250)
DroneCam.settings.mode = AUTO
tick(0.5, true)
camera.director.random = makeRng(8642)
local story = flyWorld(300, 0)
print(("        300s: %d shots, worst frame %.2fm / %.2f deg / %.2f deg fov"):format(#story.order, story.maxStep, story.maxTurn, story.maxFov))
local storyBad = 0
for i = 2, #story.order do
    local a, b = STEP_OF[story.order[i - 1]], STEP_OF[story.order[i]]
    if a ~= nil and b ~= nil and not (b == a % 5 + 1 or (a == 3 and b == 3)) then storyBad = storyBad + 1 end
end
check("story sequence holds in flight", storyBad == 0, storyBad .. " out of order")
check("flies establishing, push-in, close-ups, fly-over and pull-out",
      (story.seen[ESTABLISHING] or story.seen[LONG_LENS] or story.seen[EDGE_PAN])
      and (story.seen[PUSH_IN] or story.seen[RISE_UP]) and (story.seen[FLY_OVER] or story.seen[SLIDE])
      and (story.seen[PULL_OUT] or story.seen[ORBIT]))
check("never inside a tree or building", story.inObstacle == 0, story.inObstacle .. " frames")
check("never inside the tractor", story.inside == 0, story.inside .. " frames")
check("never into the ground", story.underground == 0, story.underground .. " frames")
check("fixed spots keep sight of the tractor", story.fixedFrames > 0 and story.blockedFixed == 0,
      ("%d of %d frames blocked"):format(story.blockedFixed, story.fixedFrames))
check("smooth glide between every shot", story.maxStep < MAX_STEP and story.maxTurn < MAX_TURN,
      ("%.2fm / %.2f deg"):format(story.maxStep, story.maxTurn))
check("zoom changes smoothly", story.maxFov < 1, ("%.2f deg in a frame"):format(story.maxFov))
end

do
print("\n-- creator shots in flight: random mode --")
DroneCam.settings.mode = AUTO_RANDOM
placeVehicle(tractorRig, 0, -250)
tick(0.5, true)
camera.director.random = makeRng(97531)
local randomFlight = flyWorld(300, 0)
local creatorSeen = 0
for shot in pairs(SHOT_LABEL) do if randomFlight.seen[shot] then creatorSeen = creatorSeen + 1 end end
print(("        300s: %d creator shots seen, worst frame %.2fm / %.2f deg"):format(creatorSeen, randomFlight.maxStep, randomFlight.maxTurn))
check("random mode mixes in creator shots", creatorSeen >= 4, tostring(creatorSeen))
check("random mode: clear, smooth, sighted", randomFlight.inObstacle == 0 and randomFlight.inside == 0
      and randomFlight.underground == 0 and randomFlight.blockedFixed == 0
      and randomFlight.maxStep < MAX_STEP and randomFlight.maxTurn < MAX_TURN)

end

do
print("\n-- creator shots in flight: the headland --")
FIELD = { -100, 100, -300, 300 }
OBSTACLES = { HEDGE, FOREST, BARN }
DroneCam.settings.mode = AUTO
placeVehicle(tractorRig, 0, 150)
tick(0.5, true)
camera.director.random = makeRng(1111)
camera.director:cutTo(CHASE)
camera.director.shotLength = 60
tick(7, true)
-- Row end now ~ 30m + the 7s just driven... make the cut due as the end nears.
camera.director.shotTime = camera.director.shotLength
tick(0.1, true)
check("takes the headland shot as the row end nears", camera.shot == HEADLAND, SHOT_LABEL[camera.shot] or tostring(camera.shot))
local headPlanNow = camera.plan or { x = 0, y = 0, z = 0 }
local hx, hy, hz = headPlanNow.x, headPlanNow.y, headPlanNow.z
-- Drive into the headland, turn round inside the field (a 15m radius turn at
-- this speed), drive back.
local _, _, rowZ = getWorldTranslation(vehicle.rootNode)
local headlandFlight = flyWorld(math.max((275 - rowZ) / 8, 0), 0)
local turnFlight = flyWorld(6, math.rad(30))
check("headland shot holds through the turn", camera.shot == HEADLAND and headlandFlight.order[2] == nil
      and turnFlight.order[2] == nil)
local cx2, cy2, cz2 = getWorldTranslation(cn)
check("camera stays at its spot past the row end", math.sqrt((cx2 - hx) ^ 2 + (cz2 - hz) ^ 2) < 2)
local _, _, vzNow = getWorldTranslation(vehicle.rootNode)
local lookDirX, lookDirY, lookDirZ = localDirectionToWorld(cn, 0, 0, -1)
local vxNow, vyNow = getWorldTranslation(vehicle.rootNode)
local toX, toY, toZ = vxNow - cx2, vyNow + 2 - cy2, vzNow - cz2
local toLen = math.sqrt(toX * toX + toY * toY + toZ * toZ)
check("and turns to follow the tractor", (lookDirX * toX + lookDirY * toY + lookDirZ * toZ) / toLen > 0.95)
check("headland: clear, smooth, sighted", turnFlight.inObstacle == 0 and turnFlight.blockedFixed == 0
      and headlandFlight.blockedFixed == 0 and turnFlight.maxTurn < MAX_TURN,
      ("obstacle %d, blocked %d+%d of %d+%d, turn %.2f"):format(turnFlight.inObstacle, headlandFlight.blockedFixed,
          turnFlight.blockedFixed, headlandFlight.fixedFrames, turnFlight.fixedFrames, turnFlight.maxTurn))
local after = flyWorld(16, 0)
check("moves on once the tractor is straight again", after.order[2] ~= nil)

end

do
print("\n-- fixed shot loses sight of the tractor --")
FIELD = { -100, 100, -300, 3000 }
OBSTACLES = { HEDGE, FOREST }
placeVehicle(tractorRig, 0, -250)
DroneCam.settings.mode = AUTO_RANDOM
tick(3, true)
camera.director.random = makeRng(4444)
local edgeFound = false
for _ = 1, 20 do
    camera.planCache = {}
    if camera:getIsShotAvailable(EDGE_PAN) then
        camera.director:cutTo(EDGE_PAN)
        camera.director.shotLength = 60
        edgeFound = true
        break
    end
    tick(0.5, true)
end
tick(7, true)
check("field-edge pan on screen", edgeFound and camera.shot == EDGE_PAN)
local spotX, spotY, spotZ = camera.plan.x, camera.plan.y, camera.plan.z
local ax2, _, az2 = getWorldTranslation(vehicle.rootNode)
-- Drop a wall between the camera and the tractor.
local midX, midZ = (spotX + ax2) / 2, (spotZ + az2) / 2
OBSTACLES[#OBSTACLES + 1] = { midX - 3, midX + 3, 0, 40, midZ - 60, midZ + 60 }
local lostAt = nil
tick(4, true, 0, function()
    if lostAt == nil and camera.director.shot ~= EDGE_PAN then lostAt = camera.shotElapsed end
end)
check("gives up a blocked fixed shot within about a second", lostAt ~= nil and lostAt < 2,
      lostAt and ("after %.2fs"):format(lostAt) or "never")
end
OBSTACLES = {}
FIELD = nil

DroneCam.settings.mode = CHASE
driveVehicle(plainVehicle)
end

--------------------------------------------------------------- drive-over

-- In a function of its own: Lua 5.1 allows only 200 locals per function.
(function()
local DRIVE_OVER = DroneCamSettings.SHOT_DRIVE_OVER
local camera = DroneCam.camera
local cn = camera:getCameraNode()

-- A tractor with a real underside: the body starts 0.65m up.
local BODY = { -1.0, 1.0, 0.65, 3.0, -2.5, 2.5 }
local SOLO_TRACTOR = { width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels, bodies = { BODY } }
-- The same with front weights hanging down to 0.45m.
local LOW_TRACTOR = { width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels,
                      bodies = { BODY, { -0.5, 0.5, 0.45, 1.0, 2.2, 2.8 } } }
-- Too low anywhere between the wheels: 0.30m all across.
local VERY_LOW_TRACTOR = { width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels,
                           bodies = { { -1.0, 1.0, 0.30, 3.0, -2.5, 2.5 } } }
-- Low all across, but enough: the camera comes down to suit.
local LOWISH_TRACTOR = { width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels,
                         bodies = { { -1.0, 1.0, 0.42, 3.0, -2.5, 2.5 } } }
-- Your trailer case: a hitch at 0.53m on the centre line at the back of the
-- tractor (5m from the front), the rest of the underside at 0.65m.
local HITCH_TRACTOR = { width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels,
                        bodies = { BODY, { -0.15, 0.15, 0.53, 1.0, -3.0, -2.0 } } }
-- A trailer 4.5m behind: body 0.9m up, an axle right across at 0.6m, its
-- wheels just inside the tractor's.
local TRAILER_WHEELS = { { across = 0.95, along = -9, radius = 0.5 } }
local TOWED = { along = -9, width = 2.5, length = 4, height = 2.5, noWork = true, specs = { spec_trailer = {} },
                wheels = TRAILER_WHEELS,
                bodies = { { -1.25, 1.25, 0.9, 2.5, -11, -7 }, { -1.25, 1.25, 0.6, 0.7, -9.1, -8.9 } } }
local TRAILED_CLEAR = { width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels, bodies = { BODY },
                        implements = { TOWED } }
-- The same with a drawbar down the middle of the gap, 0.4m up.
local TOWED_DRAWBAR = { along = -9, width = 2.5, length = 4, height = 2.5, noWork = true, specs = { spec_trailer = {} },
                        wheels = TRAILER_WHEELS,
                        bodies = { { -1.25, 1.25, 0.9, 2.5, -11, -7 }, { -1.25, 1.25, 0.6, 0.7, -9.1, -8.9 },
                                   { -0.1, 0.1, 0.4, 0.6, -7, -2.5 } } }
local TRAILED_DRAWBAR = { width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels, bodies = { BODY },
                          implements = { TOWED_DRAWBAR } }
local MOUNTED = { width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels, bodies = { BODY },
                  implements = TRACTOR.implements }
local COMBINE_BODY = { width = 3.6, length = 9, height = 4, wheels = COMBINE.wheels, bodies = { { -1.5, 1.5, 0.8, 4, -4.5, 4.5 } },
                       implements = COMBINE.implements }

---Gives a rig a work area of its own if nothing attached has one (a tractor
---alone, or pulling trailers), so the drone flies for it.
local function makeWorking(spec)
    local v = makeRig(spec)
    local hasWork = false
    for _, imp in ipairs(spec.implements or {}) do
        if not imp.noWork then hasWork = true end
    end
    if not hasWork then
        v.spec_workArea = { workAreas = { { lastProcessingTime = -10000 } } }
    end
    return v
end

---Lands, puts the vehicle at (0, z) heading north at the given speed and gets
---the drone flying straight in random mode.
local function startOn(spec, z, speed)
    vehicle = makeWorking(spec)
    VEHICLE_SPEED = speed or 3
    tick(12, false)
    nodes[vehicle.rootNode].x, nodes[vehicle.rootNode].z = 0, z or 0
    heading = 0
    DroneCam.settings.mode = AUTO_RANDOM
    tick(4, true)
    camera.director.random = makeRng(31337)
    -- Hold whatever is on screen while the checks run.
    camera.director.shotLength = 600
end

local function available()
    camera.planCache = {}
    return camera:getIsShotAvailable(DRIVE_OVER)
end

print("\n-- drive-over: when it is offered --")
FIELD, OBSTACLES = nil, {}
startOn(SOLO_TRACTOR)
check("offered on a straight run with room underneath", available())
camera.planCache = {}
local plan = camera:getPlan(DRIVE_OVER)
local rig = DroneCamRig.measure(vehicle, heading)
local pAcross, pAlong = DroneCamRig.toLocal(rig, plan.x, plan.z)
check("camera goes 30-40m ahead of the front", pAlong - rig.rootFront >= 30 - 1e-6 and pAlong - rig.rootFront <= 40 + 1e-6,
      ("%.1fm"):format(pAlong - rig.rootFront))
check("about 0.3m up", math.abs(plan.y - TERRAIN_HEIGHT - 0.3) < 1e-6)
check("centred between the wheels", math.abs(pAcross) < 0.05, ("%.2f"):format(pAcross))

-- A tree canopy overhanging the spot: the view of the tractor underneath is
-- clear, but the camera would be sitting under a tree.
OBSTACLES = { { plan.x - 3, plan.x + 3, 2.5, 12, plan.z - 3, plan.z + 3 } }
check("not offered under a tree", not available())
OBSTACLES = {}

CROP_AT = function() return 1, 5 end
check("not offered in standing maize", not available())
local realFruit = g_fruitTypeManager.getFruitTypeByIndex
g_fruitTypeManager.getFruitTypeByIndex = function(self, index)
    if index == 2 then return { name = "GRASS", minHarvestingGrowthState = 4, cutState = 9 } end
    return realFruit(self, index)
end
CROP_AT = function() return 2, 1 end
check("offered over short young grass", available())
g_fruitTypeManager.getFruitTypeByIndex = realFruit
CROP_AT = function() return 0, 0 end

FIELD = { -100, 100, -300, 60 }
check("not offered with the row end 60m ahead", not available())
FIELD = { -100, 100, -300, 3000 }
check("offered with plenty of row left", available())
FIELD = nil

VEHICLE_SPEED = 1
tick(4, true)
check("not offered when crawling along", not available())
VEHICLE_SPEED = 3
tick(4, true)
tick(1, true, math.rad(30))
check("not offered while turning", not available())
tick(1, true, math.rad(-30))
tick(0.6, true)
check("not offered until settled on the new line", not available())
tick(3, true)
check("offered again once straight", available())

startOn(LOW_TRACTOR)
check("front weights down to 0.45m: offered, with the camera brought down to suit", available())
startOn(MOUNTED)
check("not offered with a mounted cultivator (on the ground)", not available())
startOn(TRAILED_DRAWBAR)
check("a drawbar down the middle: offered, on a line beside it", available())
-- A shaft high in the middle of the gap: the camera stays down under it.
local TOWED_SHAFT = { along = -9, width = 2.5, length = 4, height = 2.5, noWork = true, specs = { spec_trailer = {} },
                      wheels = TRAILER_WHEELS,
                      bodies = { TOWED.bodies[1], TOWED.bodies[2], { -0.1, 0.1, 1.0, 1.2, -6, -4 } } }
startOn({ width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels, bodies = { BODY }, implements = { TOWED_SHAFT } })
check("a shaft high in the gap: offered, the camera stays down under it", available())
-- A frame right across the gap, 0.3m up: no line clears it.
local TOWED_FRAME = { along = -9, width = 2.5, length = 4, height = 2.5, noWork = true, specs = { spec_trailer = {} },
                      wheels = TRAILER_WHEELS,
                      bodies = { TOWED.bodies[1], TOWED.bodies[2], { -1.5, 1.5, 0.3, 0.5, -6, -4 } } }
startOn({ width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels, bodies = { BODY }, implements = { TOWED_FRAME } })
camera.planCache = {}
local _, frameWhy = DroneCamCreator.plan(camera, vehicle, DRIVE_OVER, false)
check("a frame low across the whole gap: not offered, and says where",
      (frameWhy or ""):find("underside too low", 1, true) ~= nil and (frameWhy or ""):find("behind the vehicle", 1, true) ~= nil,
      frameWhy)
startOn(TRAILED_CLEAR)
check("offered with a trailer behind", available())
startOn(COMBINE_BODY)
check("not offered with a header out front that cannot say it is raised", not available())

---Point to box distance; 0 inside.
local function boxDistance(x, y, z, b)
    local dx = math.max(b[1] - x, 0, x - b[2])
    local dy = math.max(b[3] - y, 0, y - b[4])
    local dz = math.max(b[5] - z, 0, z - b[6])
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

---Runs a drive-over to the end and records what the camera did.
---@param onFrame function|nil @(plan, phase, rig) every frame, to fold or lower kit mid-pass
local function flyDriveOver(spec, speed, onFrame)
    startOn(spec, 0, speed)
    local r = { phases = {}, order = {}, swingTime = 0, swingYaw = 0, closest = math.huge, wentUnder = false,
                lowError = 0, clipOk = true, maxStep = 0, maxTurn = 0, startPitch = nil, done = false,
                chaseGap = nil, underTowed = false, towedLowError = 0, runUp = nil, lostReason = nil }
    if not available() then return nil end
    camera.director:cutTo(DRIVE_OVER)
    SWING_MAX_TURN = 0

    local px, py, pz = getWorldTranslation(cn)
    local prx, pry = nodes[cn].rx, nodes[cn].ry
    local lastPhase = nil
    tick(45, true, 0, function(dtSeconds)
        local x, y, z = getWorldTranslation(cn)
        local rx, ry = nodes[cn].rx, nodes[cn].ry
        local p = camera.plan
        local phase = camera.shot == DRIVE_OVER and p ~= nil and p.shot == DRIVE_OVER and p.phase or nil
        r.maxStep = math.max(r.maxStep, math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2))
        r.maxTurn = math.max(r.maxTurn, countTurn(math.max(math.deg(math.abs(rx - prx)), math.deg(math.abs(wrapAngle(ry - pry))))))
        if phase ~= lastPhase and phase ~= nil then r.order[#r.order + 1] = phase end
        -- Judge the approach view once the tractor is 20m out and the aim has settled.
        if phase == "approach" and camera.fromPose == nil and r.startPitch == nil and p.along ~= nil then
            local rigNow = DroneCamRig.measure(vehicle, heading)
            if p.along <= rigNow.rootFront + 20 then r.startPitch = math.deg(rx) end
        end
        if phase == "swing" then
            r.swingTime = r.swingTime + dtSeconds
            r.swingYaw = r.swingYaw + math.deg(wrapAngle(ry - pry))
        end
        if (phase == "under" or phase == "swing") then
            r.lowError = math.max(r.lowError, math.abs(y - TERRAIN_HEIGHT - (p.height or 0.3)))
            if NEAR_CLIP > 0.05 + 1e-9 then r.clipOk = false end
        end
        for _, b in ipairs(VEHICLE_BODIES) do r.closest = math.min(r.closest, boxDistance(x, y, z, b)) end
        local rigNow = DroneCamRig.measure(vehicle, heading)
        if phase == "under" and r.runUp == nil and p.underStart ~= nil then
            r.runUp = p.underStart - rigNow.rootFront
        end
        -- Under anything towed: still down at the planned height.
        for _, box in ipairs(phase ~= nil and rigNow.boxes or {}) do
            if not box.isRoot then
                local dx, dz = x - box.cx, z - box.cz
                if math.abs(dx * box.fx + dz * box.fz) < box.halfLength and math.abs(dx * box.sx + dz * box.sz) < box.halfWidth then
                    r.underTowed = true
                    r.towedLowError = math.max(r.towedLowError, math.abs(y - TERRAIN_HEIGHT - (p.height or 0.3)))
                end
            end
        end
        if onFrame ~= nil and p ~= nil then onFrame(p, phase, rigNow) end
        if phase ~= nil then
            for _, b in ipairs(VEHICLE_BODIES) do r.closestOn = math.min(r.closestOn or math.huge, boxDistance(x, y, z, b)) end
        elseif lastPhase ~= nil and r.firstOff == nil then
            -- The first frame of whatever comes next: how far from the kit,
            -- whether it is gliding, and how far from where the shot wants it.
            r.firstOff = math.huge
            for _, b in ipairs(VEHICLE_BODIES) do r.firstOff = math.min(r.firstOff, boxDistance(x, y, z, b)) end
            r.firstOffGliding = camera.fromPose ~= nil
            local wx, wy, wz = camera:getShotTransform(vehicle)
            -- (Higher is allowed: the floors may lift it over something.)
            local below = math.min(y - wy, 0)
            r.firstOffGap = math.sqrt((x - wx) ^ 2 + below ^ 2 + (z - wz) ^ 2)
        end
        if p ~= nil and p.isLost then r.lostReason = p.lostReason end
        local across, along = DroneCamRig.toLocal(rigNow, x, z)
        if math.abs(across) < rigNow.rootHalfWidth and along < rigNow.rootFront and along > rigNow.rootRear then
            r.wentUnder = true
        end
        if phase == "tail" then
            local chaseX, chaseY, chaseZ = camera:getModeTransform(vehicle, DroneCamSettings.MODE_CHASE)
            r.chaseGap = math.sqrt((x - chaseX) ^ 2 + (y - chaseY) ^ 2 + (z - chaseZ) ^ 2)
        end
        if p ~= nil and p.isDone then r.done = true end
        lastPhase = phase
        px, py, pz, prx, pry = x, y, z, rx, ry
    end)
    r.shotAfter = camera.shot
    r.swingMaxTurn = SWING_MAX_TURN
    return r
end

print("\n-- drive-over: in flight, tractor alone --")
local solo = flyDriveOver(SOLO_TRACTOR)
check("drive-over runs", solo ~= nil)
if solo ~= nil then
    print(("        phases %s, swing %.2fs / %.0f deg, closest to the body %.2fm"):format(
          table.concat(solo.order, ">"), solo.swingTime, solo.swingYaw, solo.closest))
    check("goes approach > under > swing > trail > rise > join > tail",
          table.concat(solo.order, ">") == "approach>under>swing>trail>rise>join>tail", table.concat(solo.order, ">"))
    check("looks slightly upward at the oncoming tractor", solo.startPitch ~= nil and solo.startPitch > 0 and solo.startPitch < 10,
          tostring(solo.startPitch))
    check("the tractor really drives over the camera", solo.wentUnder)
    check("starts tilting up at least 3m before the front arrives", solo.runUp ~= nil and solo.runUp >= 3 - 0.1,
          tostring(solo.runUp))
    check("sits 0.3m up while it passes", solo.lowError < 0.01, ("off by %.3fm"):format(solo.lowError))
    check("swings round about 180 degrees", math.abs(math.abs(solo.swingYaw) - 180) < 10, ("%.0f deg"):format(solo.swingYaw))
    check("in 1-1.5 seconds", solo.swingTime >= 1 and solo.swingTime <= 1.5, ("%.2fs"):format(solo.swingTime))
    check("the swing turns smoothly", solo.swingMaxTurn < 4, ("%.2f deg in a frame"):format(solo.swingMaxTurn))
    check("never touches the tractor's underside", solo.closest >= 0.2, ("%.2fm"):format(solo.closest))
    check("near clip pulled in while underneath", solo.clipOk)
    check("near clip back to normal afterwards", math.abs(NEAR_CLIP - DroneCamCamera.NEAR_CLIP) < 1e-9)
    check("ends in the chase position", solo.chaseGap ~= nil and solo.chaseGap < 3, tostring(solo.chaseGap))
    check("then hands back to the director", solo.done and solo.shotAfter ~= DRIVE_OVER)
    check("smooth apart from the swing", solo.maxStep < MAX_STEP and solo.maxTurn < MAX_TURN,
          ("%.2fm / %.2f deg"):format(solo.maxStep, solo.maxTurn))
end

print("\n-- drive-over: in flight, with a trailer --")
local towed = flyDriveOver(TRAILED_CLEAR, 3.5)
check("drive-over runs with a trailer", towed ~= nil)
if towed ~= nil then
    print(("        phases %s, closest to any body %.2fm"):format(table.concat(towed.order, ">"), towed.closest))
    check("the trailer goes over the camera too", towed.underTowed)
    check("still down at its height under the trailer", towed.towedLowError < 0.01, ("off by %.3fm"):format(towed.towedLowError))
    check("never touches the tractor, the axle or the trailer", towed.closest >= 0.15, ("%.2fm"):format(towed.closest))
    check("stays down until the trailer has passed, then rises", towed.done
          and table.concat(towed.order, ">") == "approach>under>swing>trail>rise>join>tail", table.concat(towed.order, ">"))
end

print("\n-- drive-over: the tractor stops on the way --")
startOn(SOLO_TRACTOR)
local stoppedUnder = false
if available() then
    camera.director:cutTo(DRIVE_OVER)
    tick(4, true)
    VEHICLE_SPEED = 0
    tick(6, false, 0, function()
        local x, _, z = getWorldTranslation(cn)
        local rigNow = DroneCamRig.measure(vehicle, heading)
        local across, along = DroneCamRig.toLocal(rigNow, x, z)
        if math.abs(across) < rigNow.rootHalfWidth and along < rigNow.rootFront and along > rigNow.rootRear then
            stoppedUnder = true
        end
    end)
end
check("gives up the drive-over when the tractor stops", camera.director.shot ~= DRIVE_OVER)
check("without the tractor ever reaching the camera", not stoppedUnder)
VEHICLE_SPEED = 3

print("\n-- take-off to a far first shot --")
FIELD, OBSTACLES = { -100, 100, -300, 3000 }, {}
vehicle = makeWorking(SOLO_TRACTOR)
VEHICLE_SPEED = 3
tick(12, false)
nodes[vehicle.rootNode].x, nodes[vehicle.rootNode].z = 0, 0
heading = 0
DroneCam.settings.mode = AUTO
-- Always the lowest draw: the story opens on its usual establishing shot,
-- which on this long field is some 300m out and 175m up.
camera.director.random = function(n) if n then return 1 end return 0 end
local takeOffStep, wasActive = 0, false
local tpx, tpy, tpz = 0, 0, 0
tick(14, true, 0, function()
    local x, y, z = getWorldTranslation(cn)
    local active = droneIsActive()
    if active and wasActive then
        takeOffStep = math.max(takeOffStep, math.sqrt((x - tpx) ^ 2 + (y - tpy) ^ 2 + (z - tpz) ^ 2))
    end
    wasActive, tpx, tpy, tpz = active, x, y, z
end)
local estX, estY, estZ = DroneCamCreator.getTransform(camera, vehicle, camera.shot)
local arrivedBy = math.sqrt((tpx - estX) ^ 2 + (tpy - estY) ^ 2 + (tpz - estZ) ^ 2)
check("story opens on the far establishing shot", camera.shot == DroneCamSettings.SHOT_ESTABLISHING and estY > 150)
check("take-off flies out to it smoothly", takeOffStep < MAX_STEP, ("%.2fm in a frame"):format(takeOffStep))
check("and gets there", arrivedBy < 10, ("%.1fm short"):format(arrivedBy))
camera.director.random = makeRng(5)
FIELD = nil

print("\n-- drive-over: why it is turned down --")
FIELD, OBSTACLES = nil, {}
local function reasonFor(spec, setup)
    startOn(spec)
    if setup ~= nil then setup() end
    camera.planCache = {}
    local plan, reason = DroneCamCreator.plan(camera, vehicle, DRIVE_OVER, false)
    if setup ~= nil then setup(true) end
    return plan, reason or ""
end
local function says(reason, text) return reason:find(text, 1, true) ~= nil end

local _, why = reasonFor(VERY_LOW_TRACTOR)
check("too low on every line: says so, and where", says(why, "underside too low: best line 0.30m") and says(why, "needs 0.35m"), why)
_, why = reasonFor(MOUNTED)
check("mounted cultivator: says it is on the ground", says(why, "implement on the ground"), why)
local drawbarPlan = reasonFor(TRAILED_DRAWBAR)
check("drawbar: the camera goes beside it, not under it", drawbarPlan ~= nil and math.abs(drawbarPlan.lineOffset) >= 0.2,
      drawbarPlan and tostring(drawbarPlan.lineOffset))
_, why = reasonFor(COMBINE_BODY)
check("header that cannot say it is raised: counted as lowered, says so", says(why, "lowered on the front"), why)
_, why = reasonFor(SOLO_TRACTOR, function(undo) CROP_AT = undo and function() return 0, 0 end or function() return 1, 5 end end)
check("standing crop: says how high", says(why, "standing crop 3.2m"), why)
_, why = reasonFor(SOLO_TRACTOR, function(undo) FIELD = (not undo) and { -100, 100, -300, 60 } or nil end)
check("row end: says how far", says(why, "row end too close"), why)
_, why = reasonFor(SOLO_TRACTOR, function(undo)
    if undo then VEHICLE_SPEED = 3 return end
    VEHICLE_SPEED = 1
    tick(3, true)
end)
check("too slow: says the speed", says(why, "too slow"), why)

print("\n-- drive-over: front weights and slopes --")
-- Front weights hang off the front linkage: a small separate implement.
local WEIGHT = { along = 3.2, width = 0.8, length = 0.8, height = 1.0, workWidth = 0.1, workDepth = 0.1,
                 bodies = { { -0.4, 0.4, 0.6, 1.0, 2.8, 3.6 } } }
local WEIGHT_LOW = { along = 3.2, width = 0.8, length = 0.8, height = 1.0, workWidth = 0.1, workDepth = 0.1,
                     bodies = { { -0.4, 0.4, 0.42, 1.0, 2.8, 3.6 } } }
local WITH_WEIGHT = { width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels, bodies = { BODY }, implements = { WEIGHT } }
local WITH_LOW_WEIGHT = { width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels, bodies = { BODY }, implements = { WEIGHT_LOW } }
local weightPlan, weightWhy = reasonFor(WITH_WEIGHT)
check("front weights do not rule it out when they clear the lens", weightPlan ~= nil, weightWhy)
if weightPlan ~= nil then
    local r = DroneCamRig.measure(vehicle, heading)
    local _, spotAlong = DroneCamRig.toLocal(r, weightPlan.x, weightPlan.z)
    check("the 30-40m is measured from the weights, not the bonnet", spotAlong - 3.6 >= 30 - 0.01, ("%.1f"):format(spotAlong))
end
_, why = reasonFor(WITH_LOW_WEIGHT)
local lowWeightPlan = reasonFor(WITH_LOW_WEIGHT)

-- The test tractor does not follow the terrain, so the slope starts just
-- ahead of it and runs on past the spot.
local slopePlan, slopeWhy = reasonFor(SOLO_TRACTOR, function(undo)
    if undo then TERRAIN_FN = nil return end
    local _, _, z0 = getWorldTranslation(vehicle.rootNode)
    local slopeFrom = z0 + 8
    TERRAIN_FN = function(x, z) return z > slopeFrom and (z - slopeFrom) * 0.10 or 0 end
end)
-- 10%: 0.15m either side of the spot, more than a bump is allowed to be.
check("a steady 10% slope is fine", slopePlan ~= nil, slopeWhy)
local spotPlan = reasonFor(SOLO_TRACTOR)
_, why = reasonFor(SOLO_TRACTOR, function(undo)
    TERRAIN_FN = (not undo) and function(x, z)
        return math.abs(z - spotPlan.z) < 0.5 and 0.3 or 0
    end or nil
end)
check("a bump where the camera sits is not, and it says so", says(why, "ground not even"), why)

print("\n-- drive-over: adaptive clearance --")
local hitchPlan, hitchWhy = reasonFor(HITCH_TRACTOR)
check("a 0.53m hitch on the centre line no longer rules it out", hitchPlan ~= nil, hitchWhy)
check("the camera moves to a line beside the hitch", hitchPlan ~= nil and math.abs(hitchPlan.lineOffset) >= 0.25
      and math.abs(hitchPlan.height - 0.3) < 1e-6, hitchPlan and DroneCamCamera.describeDriveOverLine(hitchPlan))
check("and stays inside the tyres", hitchPlan ~= nil and math.abs(hitchPlan.lineOffset) <= 0.57 + 1e-6)

local lowishPlan, lowishWhy = reasonFor(LOWISH_TRACTOR)
check("0.42m all across: the camera comes down to 0.22m", lowishPlan ~= nil and math.abs(lowishPlan.height - 0.22) < 1e-6
      and math.abs(lowishPlan.lineOffset) < 1e-6, lowishPlan and DroneCamCamera.describeDriveOverLine(lowishPlan) or lowishWhy)
local nearMin = reasonFor({ width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels,
                            bodies = { { -1.0, 1.0, 0.36, 3.0, -2.5, 2.5 } } })
check("0.36m: still offered, camera at 0.16m", nearMin ~= nil and math.abs(nearMin.height - 0.16) < 1e-6)
local _, belowMin = reasonFor({ width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels,
                                bodies = { { -1.0, 1.0, 0.34, 3.0, -2.5, 2.5 } } })
check("0.34m: under the 0.35m minimum, turned down", says(belowMin, "underside too low"), belowMin)

-- In flight with the camera lowered.
local lowFlight = flyDriveOver(LOWISH_TRACTOR)
check("lowered drive-over runs", lowFlight ~= nil and lowFlight.done)
if lowFlight ~= nil then
    check("sits at its lowered height as the tractor passes", lowFlight.lowError < 0.01, ("off by %.3fm"):format(lowFlight.lowError))
    check("never touches the low underside", lowFlight.closest >= 0.15, ("%.2fm"):format(lowFlight.closest))
end

-- And beside the hitch.
local hitchFlight = flyDriveOver(HITCH_TRACTOR)
check("drive-over beside the hitch runs", hitchFlight ~= nil and hitchFlight.done)
if hitchFlight ~= nil then
    check("never touches the hitch", hitchFlight.closest >= 0.15, ("%.2fm"):format(hitchFlight.closest))
end

startOn(LOWISH_TRACTOR)
DroneCam.settings.showDebug = true
tick(1.2, true)
RENDERED = {}
DroneCam:draw()
local overlay = table.concat(RENDERED, "\n")
check("the overlay shows the chosen height and line", says(overlay, "possible now - camera 0.22m up, on the centre line"), overlay)
DroneCam.settings.showDebug = false

print("\n-- drive-over: what is attached --")
do
    local function tractorWith(...)
        return { width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels, bodies = { BODY }, implements = { ... } }
    end
    local function trailerAt(along, axle, attachedTo, wheels)
        return { along = along, width = 2.5, length = 4, height = 2.5, noWork = true, specs = { spec_trailer = {} },
                 attachedTo = attachedTo, wheels = wheels or { { across = 0.95, along = along, radius = 0.5 } },
                 bodies = { { -1.25, 1.25, 0.9, 2.5, along - 2, along + 2 }, { -1.25, 1.25, axle, axle + 0.1, along - 0.1, along + 0.1 } } }
    end

    -- Two trailers: both go over the camera, and both are measured.
    local TWO = tractorWith(trailerAt(-9, 0.6), trailerAt(-15, 0.6, 2))
    local twoPlan, twoWhy = reasonFor(TWO)
    check("two trailers: offered when both clear", twoPlan ~= nil, twoWhy)
    local _, lowSecond = reasonFor(tractorWith(trailerAt(-9, 0.6), trailerAt(-15, 0.3, 2)))
    check("the second trailer too low: turned down, and says it is the trailer",
          says(lowSecond, "underside too low") and says(lowSecond, "under the trailer"), lowSecond)
    local _, narrow = reasonFor(tractorWith(trailerAt(-9, 0.6, nil, { { across = 0.3, along = -9, radius = 0.4 } })))
    check("a trailer whose wheels run down the middle: no line misses them",
          says(narrow, "no line clear of the wheels"), narrow)

    local riseAlong = nil
    local twoFlight = flyDriveOver(TWO, 3, function(p, phase, rigNow)
        if p.riseStarted and riseAlong == nil then riseAlong = p.along - rigNow.rear end
    end)
    check("two trailers: the run completes", twoFlight ~= nil and twoFlight.done)
    if twoFlight ~= nil then
        check("never touches either trailer", twoFlight.closest >= 0.15, ("%.2fm"):format(twoFlight.closest))
        check("rises only once the second trailer has gone over", riseAlong ~= nil and riseAlong <= -0.3 + 0.05,
              tostring(riseAlong))
    end

    -- A trailed sprayer, boom unfolded and lowered to 0.7m: the boom goes over
    -- the camera as well.
    local function sprayer(boom)
        return { along = -9, width = 3, length = 5, height = 3, workWidth = 24, workDepth = 0.5,
                 specs = { spec_sprayer = {} }, fold = 1, wheels = { { across = 0.95, along = -9, radius = 0.5 } },
                 bodies = { { -1.4, 1.4, 0.9, 3, -11.5, -6.5 }, { -1.4, 1.4, 0.6, 0.7, -9.1, -8.9 },
                            { -12, 12, boom, boom + 0.3, -11.9, -11.6 } } }
    end
    local SPRAYER = sprayer(0.7)
    local sprayPlan, sprayWhy = reasonFor(tractorWith(SPRAYER))
    check("trailed sprayer, boom unfolded: a drive-over", sprayPlan ~= nil, sprayWhy)
    SPRAYER.fold = 0
    check("and with the boom folded", reasonFor(tractorWith(SPRAYER)) ~= nil)
    SPRAYER.fold = 1
    local _, lowBoom = reasonFor(tractorWith(sprayer(0.3)))
    check("boom set too low to clear: turned down, says it is the sprayer",
          says(lowBoom, "underside too low") and says(lowBoom, "under the sprayer"), lowBoom)
    local selfSprayer = { width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels, bodies = { BODY },
                          specs = { spec_sprayer = {} } }
    check("self-propelled sprayer: a drive-over", reasonFor(selfSprayer) ~= nil)

    local sprayFlight = flyDriveOver(tractorWith(SPRAYER))
    check("sprayer: the run completes", sprayFlight ~= nil and sprayFlight.done)
    if sprayFlight ~= nil then
        check("the sprayer and its boom go over the camera", sprayFlight.underTowed)
        check("never touches the boom, the axle or the tank", sprayFlight.closest >= 0.15, ("%.2fm"):format(sprayFlight.closest))
    end

    -- Folding while the camera is down.
    local folded = false
    local onWay = flyDriveOver(tractorWith(SPRAYER), 3, function(p, phase, rigNow)
        if phase == "approach" and camera.fromPose == nil and not folded and p.along > rigNow.front + 15 then
            folded = true
            SPRAYER.fold = 0.6
        end
    end)
    SPRAYER.fold = 1
    check("boom folding on the way: called off, says why", onWay ~= nil and onWay.lostReason ~= nil
          and says(onWay.lostReason, "sprayer folding or unfolding on the way"), onWay and tostring(onWay.lostReason))
    check("and glides away as usual", onWay ~= nil and onWay.maxStep < MAX_STEP, onWay and ("%.2fm"):format(onWay.maxStep))

    folded = false
    local midPass = flyDriveOver(tractorWith(SPRAYER), 3, function(p, phase)
        if phase == "swing" and not folded then
            folded = true
            SPRAYER.fold = 0.6
        end
    end)
    SPRAYER.fold = 1
    check("boom folding during the pass: called off, says why", midPass ~= nil and midPass.lostReason ~= nil
          and says(midPass.lostReason, "during the pass, cut away"), midPass and tostring(midPass.lostReason))
    check("cuts straight out rather than gliding through the sprayer", midPass ~= nil and midPass.maxStep > 3
          and (midPass.closestOn or 0) >= 0.15 and (midPass.firstOff or 0) >= 0.5,
          midPass and ("%.2fm step, %.2fm closest, %.2fm on the cut"):format(midPass.maxStep, midPass.closestOn or -1,
                                                                            midPass.firstOff or -1))
    check("already at the next shot on the first frame, no glide", midPass ~= nil and midPass.firstOffGliding == false
          and (midPass.firstOffGap or math.huge) < 1, midPass and ("gliding %s, %.2fm off"):format(
              tostring(midPass.firstOffGliding), midPass.firstOffGap or -1))
    check("and is not in the middle of a drive-over any more", camera.shot ~= DRIVE_OVER)

    -- Slurry tanker: fine on its own, not with the dribble bar down.
    local tanker = { along = -9, width = 2.8, length = 5, height = 3, workWidth = 2, workDepth = 0.5,
                     specs = { spec_sprayer = { isSlurryTanker = true } }, wheels = { { across = 0.95, along = -9, radius = 0.5 } },
                     bodies = { { -1.4, 1.4, 0.9, 3, -11.5, -6.5 }, { -1.4, 1.4, 0.6, 0.7, -9.1, -8.9 } } }
    local function bar(lowered, bottom)
        return { along = -12.2, width = 12, length = 1, height = 1.5, workWidth = 12, workDepth = 0.5,
                 specs = { spec_sprayer = {} }, attachedTo = 2, lowered = lowered,
                 bodies = { { -6, 6, bottom, 1.5, -12.7, -11.7 } } }
    end
    check("slurry tanker on its own: a drive-over", reasonFor(tractorWith(tanker)) ~= nil)
    local _, barDown = reasonFor(tractorWith(tanker, bar(true, 0.2)))
    check("dribble bar lowered: not a drive-over, says why", says(barDown, "dribble bar or injector lowered"), barDown)
    local barUp, barUpWhy = reasonFor(tractorWith(tanker, bar(false, 1.0)))
    check("dribble bar raised: a drive-over", barUp ~= nil, barUpWhy)

    -- Kit on the ground.
    local _, baler = reasonFor(tractorWith({ along = -6, width = 2.8, length = 4, height = 3, workWidth = 2.2, workDepth = 1,
                                             specs = { spec_baler = {} }, lowered = false,
                                             bodies = { { -1.4, 1.4, 0.9, 3, -8, -4 } } }))
    check("baler: always a wheel pass", says(baler, "baler picks up off the ground"), baler)
    local function mower(lowered)
        return { along = -3.5, width = 3, length = 1.5, height = 1.2, workWidth = 3, workDepth = 1,
                 specs = { spec_mower = {} }, lowered = lowered, bodies = { { -1.5, 1.5, 0.9, 1.2, -4.2, -2.8 } } }
    end
    local _, mowerDown = reasonFor(tractorWith(mower(true)))
    check("mower lowered: on the ground, says so", says(mowerDown, "mower on the ground"), mowerDown)
    local mowerUp, mowerUpWhy = reasonFor(tractorWith(mower(false)))
    check("mower raised: off the ground, the underside decides", mowerUp ~= nil, mowerUpWhy)
    local _, selfMower = reasonFor({ width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels, bodies = { BODY },
                                     specs = { spec_mower = {} } })
    check("self-propelled mower: works the ground itself", says(selfMower, "works the ground itself"), selfMower)

    -- Combine: only with the header raised.
    local function combineWith(header)
        return { width = 3.6, length = 9, height = 4, wheels = COMBINE.wheels, bodies = { { -1.5, 1.5, 0.8, 4, -4.5, 4.5 } },
                 specs = { spec_combine = {} }, implements = { header } }
    end
    local HEADER = { along = 5.6, width = 9, length = 2, height = 1.5, workWidth = 9, workDepth = 1.5,
                     specs = { spec_cutter = {} }, lowered = true, bodies = { { -4.5, 4.5, 1.0, 2.0, 4.6, 6.6 } } }
    local _, headerDown = reasonFor(combineWith(HEADER))
    check("combine, header lowered: not a drive-over, says why", says(headerDown, "header lowered on the front"), headerDown)
    HEADER.lowered = false
    local headerPlan, headerWhy = reasonFor(combineWith(HEADER))
    check("combine, header raised and clear: a drive-over", headerPlan ~= nil, headerWhy)
    if headerPlan ~= nil then
        local r = DroneCamRig.measure(vehicle, heading)
        local _, spotAlong = DroneCamRig.toLocal(r, headerPlan.x, headerPlan.z)
        check("the 30-40m is measured from the header", spotAlong - 6.6 >= 30 - 0.01, ("%.1f"):format(spotAlong))
    end
    local headerFlight = flyDriveOver(combineWith(HEADER))
    check("combine: the run completes", headerFlight ~= nil and headerFlight.done)
    if headerFlight ~= nil then
        check("never touches the header or the combine", headerFlight.closest >= 0.15, ("%.2fm"):format(headerFlight.closest))
    end
    local lowered = false
    local headerDrop = flyDriveOver(combineWith(HEADER), 3, function(p, phase, rigNow)
        if phase == "approach" and camera.fromPose == nil and not lowered and p.along > rigNow.front + 15 then
            lowered = true
            HEADER.lowered = true
        end
    end)
    HEADER.lowered = false
    check("header lowered on the way: called off", headerDrop ~= nil and headerDrop.lostReason ~= nil
          and says(headerDrop.lostReason, "header lowered on the way"), headerDrop and tostring(headerDrop.lostReason))

    startOn(tractorWith(SPRAYER))
    DroneCam.settings.showDebug = true
    tick(1.2, true)
    RENDERED = {}
    DroneCam:draw()
    local trainLine = table.concat(RENDERED, "\n")
    check("the overlay lists the train", says(trainLine, "Train: vehicle, sprayer (fold 1.00)"), trainLine)
    DroneCam.settings.showDebug = false
end

print("\n-- drive-over: nothing lifts the camera off the ground --")
startOn(SOLO_TRACTOR)
local stayedDown, ran, worst = true, false, 0
if available() then
    camera.director:cutTo(DRIVE_OVER)
    -- Lift left over from the shot before, and every obstacle raycast hitting.
    camera.heightBoost = 15
    tick(3, true)
    RAYCAST_HIT = true
    tick(30, true, 0, function()
        local p = camera.plan
        local phase = camera.shot == DRIVE_OVER and p ~= nil and p.phase or nil
        if phase == "under" or phase == "swing" then
            ran = true
            local _, y = getWorldTranslation(cn)
            worst = math.max(worst, math.abs(y - TERRAIN_HEIGHT - (p.height or 0.3)))
        end
    end)
    RAYCAST_HIT = false
end
check("the drive-over ran", ran)
check("stays 0.3m up as the tractor passes, whatever the obstacle raycast says", ran and worst < 0.01,
      ("off by %.2fm"):format(worst))

print("\n-- debug overlay --")
startOn(SOLO_TRACTOR)
DroneCam.settings.showDebug = false
DroneCam:onToggleDebug()
check("Ctrl+Shift+D turns the overlay on", DroneCam.settings.showDebug == true)
tick(1.2, true)
RENDERED = {}
DroneCam:draw()
local shown = table.concat(RENDERED, "\n")
check("shows the shot on screen", says(shown, "DroneCam shot: "), shown)
check("shows the drive-over is possible", says(shown, "Drive-over: possible now"), shown)
check("shows the camera's height and any obstacle lift", says(shown, "above ground, obstacle lift"), shown)
startOn(MOUNTED)
tick(1.2, true)
RENDERED = {}
DroneCam:draw()
shown = table.concat(RENDERED, "\n")
check("shows why the drive-over is turned down", says(shown, "Drive-over: not possible: implement on the ground"), shown)
DroneCam:onToggleDebug()
RENDERED = {}
DroneCam:draw()
check("and goes away again", #RENDERED == 0)

print("\n-- Ctrl+G: drive-over on demand --")
-- Catch "[DroneCam]" lines written to log.txt (the game logs print output).
local LOGGED = {}
local realPrint = print
print = function(text, ...)
    if type(text) == "string" and text:sub(1, 10) == "[DroneCam]" then LOGGED[#LOGGED + 1] = text end
    return realPrint(text, ...)
end
local function onScreen()
    RENDERED = {}
    DroneCam:draw()
    return table.concat(RENDERED, "\n")
end
local function logged(text)
    for _, line in ipairs(LOGGED) do
        if says(line, text) then return true end
    end
    return false
end

startOn(SOLO_TRACTOR)
DroneCam.settings.mode = CHASE
DroneCam.settings.showDebug = false
tick(3, true)
DroneCam:onForceDriveOver()
tick(1, true)
check("Ctrl+G starts a drive-over in chase mode", camera.shot == DRIVE_OVER and camera.forcedShot == DRIVE_OVER)
check("and says so on screen", says(onScreen(), "droneCam_driveOver"), onScreen())
check("and in log.txt", logged("[DroneCam] Ctrl+G: drive-over asked for") and logged("[DroneCam] Ctrl+G: drive-over started"))
tick(6, true)
check("the message is still up 7 seconds later", says(onScreen(), "droneCam_driveOver"))
tick(1.5, true)
check("and gone after 8", not says(onScreen(), "droneCam_driveOver"), onScreen())
local forcedPhases = {}
tick(32, true, 0, function()
    local p = camera.plan
    if camera.shot == DRIVE_OVER and p ~= nil and forcedPhases[#forcedPhases] ~= p.phase then
        forcedPhases[#forcedPhases + 1] = p.phase
    end
end)
check("runs the whole drive-over", table.concat(forcedPhases, ">") == "under>swing>trail>rise>join>tail"
      or table.concat(forcedPhases, ">") == "approach>under>swing>trail>rise>join>tail", table.concat(forcedPhases, ">"))
check("then goes back to chase", camera.shot == CHASE and camera.forcedShot == nil)
check("and logs that it finished", logged("[DroneCam] Ctrl+G: drive-over finished"))

startOn(MOUNTED)
DroneCam.settings.mode = CHASE
tick(3, true)
DroneCam:onForceDriveOver()
tick(1, true)
check("Ctrl+G with a mounted implement: no drive-over", camera.shot ~= DRIVE_OVER)
check("and says why on screen", says(onScreen(), "droneCam_driveOverNot: implement on the ground"), onScreen())
check("and writes the reason to log.txt", logged("[DroneCam] Ctrl+G: no drive-over - implement on the ground"))
tick(7, true)
check("the reason is still readable 7 seconds later", says(onScreen(), "implement on the ground"))

-- A started drive-over that is dropped says so, with the reason.
startOn(SOLO_TRACTOR)
DroneCam.settings.mode = CHASE
tick(3, true)
DroneCam:onForceDriveOver()
tick(2, true)
VEHICLE_SPEED = 0
tick(5, false)
check("a dropped Ctrl+G drive-over is logged with the reason", logged("[DroneCam] Ctrl+G: drive-over dropped - the vehicle stopped"))
check("and shown on screen", says(onScreen(), "droneCam_driveOverDropped: the vehicle stopped"), onScreen())
VEHICLE_SPEED = 3
print = realPrint

print("\n-- debug overlay stays up until switched off --")
startOn(SOLO_TRACTOR)
DroneCam.settings.showDebug = false
DroneCam:onToggleDebug()
tick(12, false)
check("drone landed", not droneIsActive())
check("overlay still up with the drone down", says(onScreen(), "DroneCam: drone not flying"), onScreen())
vehicle.getIsEntered = function() return false end
tick(1, false)
check("and out of the vehicle", says(onScreen(), "DroneCam: drone not flying"))
vehicle.getIsEntered = function() return true end
tick(4, true)
check("and back to the full overlay when flying", says(onScreen(), "DroneCam shot:"))
DroneCam:onToggleDebug()
check("until Ctrl+Shift+D again", onScreen() == "")

-- Not working, drone landed: Ctrl+G takes off for it and lands afterwards.
startOn(SOLO_TRACTOR)
DroneCam.settings.mode = CHASE
tick(12, false)
check("drone landed before Ctrl+G", not droneIsActive())
DroneCam:onForceDriveOver()
local tookOff, dropped = false, false
tick(2, false, 0, function() tookOff = tookOff or camera.shot == DRIVE_OVER end)
check("Ctrl+G takes off and starts the drive-over", tookOff and droneIsActive())
tick(45, false)
check("and lands again when it is over", not droneIsActive() and not DroneCam.isForced)

print("\n-- drive-over mode --")
local WHEEL_PASS, LOW_CHASE = DroneCamSettings.SHOT_WHEEL_PASS, DroneCamSettings.SHOT_LOW_CHASE
local MODE_DO = DroneCamSettings.MODE_DRIVE_OVER
LOGGED = {}
local realPrint2 = print
print = function(text, ...)
    if type(text) == "string" and text:sub(1, 10) == "[DroneCam]" then LOGGED[#LOGGED + 1] = text end
    return realPrint2(text, ...)
end
local function countLogged(text)
    local n = 0
    for _, line in ipairs(LOGGED) do if says(line, text) then n = n + 1 end end
    return n
end
local function screen()
    RENDERED = {}
    DroneCam:draw()
    return table.concat(RENDERED, "\n")
end

---Drives in drive-over mode, recording the passes and every frame's safety.
local function driveMode(seconds, headingRate, record)
    record = record or { passes = {}, phases = {}, closest = math.huge, lowestWheelPass = math.huge,
                         turningShots = {}, maxStep = 0, maxTurn = 0 }
    local px, py, pz = getWorldTranslation(cn)
    local prx, pry = nodes[cn].rx, nodes[cn].ry
    local lastShot = camera.shot
    tick(seconds, true, headingRate, function()
        local x, y, z = getWorldTranslation(cn)
        local rx, ry = nodes[cn].rx, nodes[cn].ry
        record.maxStep = math.max(record.maxStep, math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2))
        record.maxTurn = math.max(record.maxTurn, countTurn(math.max(math.deg(math.abs(rx - prx)), math.deg(math.abs(wrapAngle(ry - pry))))))
        px, py, pz, prx, pry = x, y, z, rx, ry
        if camera.shot ~= lastShot then
            if DroneCamCreator.getIsGroundPass(camera.shot) then record.passes[#record.passes + 1] = camera.shot end
            lastShot = camera.shot
        end
        for _, b in ipairs(VEHICLE_BODIES) do record.closest = math.min(record.closest, boxDistance(x, y, z, b)) end
        local p = camera.plan
        -- While the vehicle goes by (on the approach the camera may still be
        -- settling from the shot before).
        if camera.shot == WHEEL_PASS and p ~= nil and p.phase == "pass" and camera.fromPose == nil then
            record.lowestWheelPass = math.min(record.lowestWheelPass, y - TERRAIN_HEIGHT)
            record.wheelPassHighest = math.max(record.wheelPassHighest or 0, y - TERRAIN_HEIGHT)
            -- Outside every footprint the whole way past.
            local rigNow = DroneCamRig.measure(vehicle, heading)
            if y < DroneCamRig.getVehicleFloor(rigNow, x, z, false) - 1e-6 then record.insideRig = true end
        end
        if camera.modeIsTurning then record.turningShots[camera.shot] = true end
    end)
    return record
end

-- A tractor on its own: drive-overs.
startOn(SOLO_TRACTOR)
DroneCam.settings.mode = MODE_DO
local soloMode = driveMode(70, 0)
check("sets up a drive-over on the straight", soloMode.passes[1] == DRIVE_OVER, tostring(soloMode.passes[1]))
check("and another after it on a long run", #soloMode.passes >= 2, tostring(#soloMode.passes))
check("holds the low chase in between", camera.shot == LOW_CHASE or DroneCamCreator.getIsGroundPass(camera.shot))
check("never touches the tractor", soloMode.closest >= 0.2, ("%.2fm"):format(soloMode.closest))
check("smooth apart from the swing", soloMode.maxStep < MAX_STEP and soloMode.maxTurn < MAX_TURN,
      ("%.2fm / %.2f deg"):format(soloMode.maxStep, soloMode.maxTurn))
check("logs each pass", countLogged("[DroneCam] Drive-over mode: drive-over set up") >= 2
      and countLogged("[DroneCam] Drive-over mode: drive-over finished") >= 1)

-- A headland turn: low chase through it, the next drive-over once straight.
local turnRecord = driveMode(6, math.rad(30))
local onlyChase = true
for shot in pairs(turnRecord.turningShots) do
    if shot ~= LOW_CHASE and not DroneCamCreator.getIsGroundPass(shot) then onlyChase = false end
end
check("low chase through the turn", onlyChase and camera.shot == LOW_CHASE, tostring(camera.shot))
check("and says it is waiting for the turn", says(screen(), "Drive-over mode: waiting - turning"), screen())
local afterTurn = driveMode(8, 0)
check("next drive-over set up once straight again", afterTurn.passes[1] == DRIVE_OVER, tostring(afterTurn.passes[1]))

-- With a cultivator working the ground: a wheel pass instead.
startOn(MOUNTED)
DroneCam.settings.mode = MODE_DO
local cult = driveMode(45, 0)
check("a ground-working implement gets a wheel pass instead", cult.passes[1] == WHEEL_PASS, tostring(cult.passes[1]))
check("low on the ground as it passes", cult.lowestWheelPass < 0.45 and (cult.wheelPassHighest or 99) < 0.5,
      ("%.2f-%.2fm"):format(cult.lowestWheelPass, cult.wheelPassHighest or -1))
check("never inside the tractor or the implement", not cult.insideRig and cult.closest >= 0.2, ("%.2fm"):format(cult.closest))
check("wheel pass runs through to the chase", countLogged("[DroneCam] Drive-over mode: wheel pass finished") >= 1)

-- Not possible: says why, on screen and in the log, once, and stays on the chase.
startOn(SOLO_TRACTOR)
DroneCam.settings.mode = MODE_DO
CROP_AT = function() return 1, 5 end
local before = countLogged("waiting - standing crop")
local cropMode = driveMode(20, 0)
check("stays on the low chase when it can't", camera.shot == LOW_CHASE and #cropMode.passes == 0)
check("shows why on screen", says(screen(), "Drive-over mode: waiting - standing crop 3.2m high"), screen())
check("logs why, once rather than every second", countLogged("waiting - standing crop") - before == 1,
      tostring(countLogged("waiting - standing crop") - before))
CROP_AT = function() return 0, 0 end
local cleared = driveMode(6, 0)
check("goes as soon as it can", cleared.passes[1] == DRIVE_OVER)

-- What is attached: a wheel pass, saying why not a drive-over.
check("the cultivator's wheel pass says why it is not a drive-over",
      countLogged("[DroneCam] Drive-over mode: wheel pass set up (no drive-over: implement on the ground)") >= 1)
do
    local LOW_SPRAYER = { along = -9, width = 3, length = 5, height = 3, workWidth = 24, workDepth = 0.5,
                          specs = { spec_sprayer = {} }, fold = 1, wheels = { { across = 0.95, along = -9, radius = 0.5 } },
                          bodies = { { -1.4, 1.4, 0.9, 3, -11.5, -6.5 }, { -1.4, 1.4, 0.6, 0.7, -9.1, -8.9 },
                                     { -12, 12, 0.3, 0.6, -11.9, -11.6 } } }
    startOn({ width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels, bodies = { BODY }, implements = { LOW_SPRAYER } })
    DroneCam.settings.mode = MODE_DO
    local lowSpray = driveMode(8, 0)
    check("sprayer with the boom too low: a wheel pass instead", lowSpray.passes[1] == WHEEL_PASS, tostring(lowSpray.passes[1]))
    check("and says why not a drive-over",
          countLogged("wheel pass set up (no drive-over: underside too low") >= 1)

    -- The boom unfolds as the sprayer comes level with the camera beside it.
    local cutAway, folded = false, false
    tick(30, true, 0, function()
        local p = camera.plan
        if camera.shot == WHEEL_PASS and p ~= nil and p.phase == "pass" and not folded then
            folded = true
            LOW_SPRAYER.fold = 0.4
        end
        if p ~= nil and p.lostReason ~= nil and says(p.lostReason, "sprayer folding or unfolding during the pass, cut away") then
            cutAway = true
        end
    end)
    LOW_SPRAYER.fold = 1
    check("a boom unfolding beside the camera: the wheel pass is cut away", folded and cutAway)
    check("and logged", countLogged("wheel pass dropped: sprayer folding or unfolding during the pass, cut away") >= 1)
end

-- No room before the row end: waits on the chase, says so.
startOn(SOLO_TRACTOR)
DroneCam.settings.mode = MODE_DO
FIELD = { -100, 100, -300, 40 }
driveMode(6, 0)
check("row end too close: waits and says so", camera.shot == LOW_CHASE and says(screen(), "waiting - row end too close"))
FIELD = nil

print = realPrint2
DroneCam.settings.mode = CHASE

print("\n-- drive-over in the story: a hero shot about one loop in three --")
-- Wichmann-Hill: Park-Miller's consecutive draws are too correlated for a
-- frequency test that rolls at the same point in every loop.
local function makeWH(seed)
    local s1, s2, s3 = seed % 30000 + 1, (seed * 7) % 30000 + 1, (seed * 13) % 30000 + 1
    return function(n)
        s1 = (171 * s1) % 30269
        s2 = (172 * s2) % 30307
        s3 = (170 * s3) % 30323
        local f = (s1 / 30269 + s2 / 30307 + s3 / 30323) % 1
        if n == nil then return f end
        return math.floor(f * n) + 1
    end
end
local hero = DroneCamDirector.new(DroneCam.settings)
hero.random = makeWH(1)
hero.isShotAvailable = function(shot) return shot ~= HEADLAND end
hero.isShotStillUsable = function(shot)
    if shot == DRIVE_OVER then return hero.shotTime < 12 end
    return true
end
hero:start(nil, 0, true)
local heroStats = survey(hero, 6000)
local loops, heroes, misplaced = 0, 0, 0
for i = 2, #heroStats.order do
    local a, b = STEP_OF[heroStats.order[i - 1]], STEP_OF[heroStats.order[i]]
    if b == 1 and a == 5 then loops = loops + 1 end
    if heroStats.order[i] == DRIVE_OVER then
        heroes = heroes + 1
        if a ~= 3 or STEP_OF[heroStats.order[i + 1] or 0] ~= 5 then
            if heroStats.order[i + 1] ~= nil then misplaced = misplaced + 1 end
        end
    end
end
local share = heroes / math.max(loops, 1)
check("drive-over in about one loop in three", share > 0.22 and share < 0.45, ("%d of %d loops"):format(heroes, loops))
check("always after the close-ups, in place of the fly-over", misplaced == 0, misplaced .. " misplaced")

local randomHero = DroneCamDirector.new(DroneCam.settings)
randomHero.random = makeWH(171717)
randomHero.isShotAvailable = hero.isShotAvailable
randomHero.isShotStillUsable = function(shot)
    if shot == DRIVE_OVER then return randomHero.shotTime < 12 end
    return true
end
randomHero:start(nil, 0, false)
check("random mode uses the drive-over too", survey(randomHero, 3000).seen[DRIVE_OVER] == true)

DroneCam.settings.mode = CHASE
VEHICLE_SPEED = 8
driveVehicle(plainVehicle)
VEHICLE_BODIES = {}
end)()

--------------------------------------------------------- field-size aware

-- In a function of its own: Lua 5.1 allows only 200 locals per function.
-- (The leading semicolon stops Lua reading it as a call on the line before.)
;(function()
local camera = DroneCam.camera
local cn = camera:getCameraNode()
local S = DroneCamSettings

---A game field: a rectangle outline of nodes, with its area.
local function makeField(minX, maxX, minZ, maxZ)
    local points = {}
    for _, corner in ipairs({ { minX, minZ }, { maxX, minZ }, { maxX, maxZ }, { minX, maxZ } }) do
        local node = newNode("fieldPoint")
        nodes[node].x, nodes[node].z = corner[1], corner[2]
        points[#points + 1] = node
    end
    local field = { areaHa = (maxX - minX) * (maxZ - minZ) / 10000, rect = { minX, maxX, minZ, maxZ } }
    function field:getPolygonPoints() return points end
    function field:getCenterOfFieldWorldPosition() return (minX + maxX) / 2, (minZ + maxZ) / 2 end
    return field
end

local SMALL_FIELD = makeField(2000, 2060, 0, 100)      -- 0.6 ha, 117m across
local MEDIUM_FIELD = makeField(3000, 3200, 0, 300)     -- 6 ha
local LARGE_FIELD = makeField(4000, 4400, -500, 500)   -- 40 ha
g_fieldManager = { fields = { SMALL_FIELD, MEDIUM_FIELD, LARGE_FIELD } }

print("\n-- field size: detection --")
local small = DroneCamField.getFieldInfo(2030, 50)
local medium = DroneCamField.getFieldInfo(3100, 150)
local large = DroneCamField.getFieldInfo(4200, 0)
check("finds the field being worked from the game's field data",
      small ~= nil and small.field == SMALL_FIELD and medium.field == MEDIUM_FIELD and large.field == LARGE_FIELD)
check("reads its area", math.abs(small.areaHa - 0.6) < 1e-9 and math.abs(large.areaHa - 40) < 1e-9)
check("measures its longest dimension", math.abs(small.length - math.sqrt(60 ^ 2 + 100 ^ 2)) < 0.01
      and math.abs(large.length - math.sqrt(400 ^ 2 + 1000 ^ 2)) < 0.01, ("%.1f"):format(small.length))
check("finds its centre", small.centreX == 2030 and small.centreZ == 50)
local settings = DroneCam.settings
check("sorts fields into small, medium and large",
      DroneCamField.getSizeClass(small, settings) == "small" and DroneCamField.getSizeClass(medium, settings) == "medium"
      and DroneCamField.getSizeClass(large, settings) == "large")
check("medium when no field is found", DroneCamField.getFieldInfo(9000, 9000) == nil
      and DroneCamField.getSizeClass(nil, settings) == "medium")
settings.fieldSmallHa, settings.fieldLargeHa = 0.5, 50
check("the limits are settings you can tune",
      DroneCamField.getSizeClass(small, settings) == "medium" and DroneCamField.getSizeClass(large, settings) == "medium")
settings.fieldSmallHa, settings.fieldLargeHa = 2, 10

-- The game's quick lookup: farmland at a point, and the field on it.
g_farmlandManager = { getFarmlandAtWorldPosition = function(self, x, z) return { id = 7 } end }
g_fieldManager.farmlandIdFieldMapping = { [7] = MEDIUM_FIELD }
check("uses the farmland lookup when it fits", DroneCamField.getGameField(3100, 150) == MEDIUM_FIELD)
check("and falls back when the farmland's field is elsewhere", DroneCamField.getGameField(2030, 50) == SMALL_FIELD)
g_farmlandManager = nil
g_fieldManager.farmlandIdFieldMapping = nil

print("\n-- field size: story mixes --")
local function makeWH(seed)
    local s1, s2, s3 = seed % 30000 + 1, (seed * 7) % 30000 + 1, (seed * 13) % 30000 + 1
    return function(n)
        s1 = (171 * s1) % 30269
        s2 = (172 * s2) % 30307
        s3 = (170 * s3) % 30323
        local f = (s1 / 30269 + s2 / 30307 + s3 / 30323) % 1
        if n == nil then return f end
        return math.floor(f * n) + 1
    end
end

---Runs a story director for a field class and counts what it shows.
local function mix(class)
    local d = DroneCamDirector.new(settings)
    d.random = makeWH(2468)
    d.fieldClass = class
    d.isShotAvailable = function(shot) return shot ~= HEADLAND end
    d.isShotStillUsable = function(shot)
        if shot == S.SHOT_DRIVE_OVER then return d.shotTime < 12 end
        return true
    end
    d:start(nil, 0, true)
    local stats = survey(d, 6000)
    local counts, total, loops = {}, 0, 0
    for i, shot in ipairs(stats.order) do
        counts[shot] = (counts[shot] or 0) + 1
        total = total + 1
        if i > 1 and shot == d.story.steps[1][1] then loops = loops + 1 end
    end
    local close = 0
    for _, shot in ipairs(DroneCamDirector.CLOSE_SHOTS) do close = close + (counts[shot] or 0) end
    -- Every loop has exactly one run of close-ups, so runs count loops.
    local runs = 0
    for i = 2, #stats.order do
        if isClose(stats.order[i]) and not isClose(stats.order[i - 1]) then runs = runs + 1 end
    end
    local function share(...)
        local n = 0
        for _, shot in ipairs({ ... }) do n = n + (counts[shot] or 0) end
        return n / total
    end
    return {
        close = close / total,
        chase = share(S.MODE_CHASE),
        establishing = share(S.SHOT_ESTABLISHING, S.SHOT_LONG_LENS),
        big = share(S.SHOT_ESTABLISHING, S.SHOT_LONG_LENS, S.SHOT_PUSH_IN, S.SHOT_PULL_OUT),
        pullOut = counts[S.SHOT_PULL_OUT] or 0,
        driveOverPerLoop = (counts[S.SHOT_DRIVE_OVER] or 0) / math.max(runs, 1),
        story = d.story
    }
end

local smallMix, mediumMix, largeMix = mix("small"), mix("medium"), mix("large")
print(("        close-ups %.0f/%.0f/%.0f%%, establishing+long lens %.0f/%.0f/%.0f%%, big shots %.0f/%.0f/%.0f%% (small/medium/large)"):format(
      smallMix.close * 100, mediumMix.close * 100, largeMix.close * 100,
      smallMix.establishing * 100, mediumMix.establishing * 100, largeMix.establishing * 100,
      smallMix.big * 100, mediumMix.big * 100, largeMix.big * 100))
check("medium plays the usual story", mediumMix.story == DroneCamDirector.STORIES.medium
      and DroneCamDirector.STORIES.medium.steps == DroneCamDirector.STORY)
check("small: more close-ups", smallMix.close > mediumMix.close + 0.05)
check("small: more chase", smallMix.chase > mediumMix.chase + 0.05)
check("small: drive-over in more loops (about 60% against 33%)",
      smallMix.driveOverPerLoop > 0.5 and smallMix.driveOverPerLoop < 0.72
      and mediumMix.driveOverPerLoop > 0.22 and mediumMix.driveOverPerLoop < 0.45,
      ("%.2f vs %.2f per loop"):format(smallMix.driveOverPerLoop, mediumMix.driveOverPerLoop))
check("small: fewer establishing and long lens shots", smallMix.establishing < mediumMix.establishing * 0.6)
check("small: no long pull-outs", smallMix.pullOut == 0)
check("large: more establishing, push-ins, pull-outs and long lens", largeMix.big > mediumMix.big + 0.05)
check("large: more long lens and establishing on their own", largeMix.establishing > mediumMix.establishing * 1.3)
check("large: fewer close-ups", largeMix.close < mediumMix.close - 0.03)

print("\n-- field size: a change of field waits for the next loop --")
local switcher = DroneCamDirector.new(settings)
switcher.random = makeWH(99)
switcher.fieldClass = "small"
switcher.isShotAvailable = function(shot) return shot ~= HEADLAND and shot ~= S.SHOT_DRIVE_OVER end
switcher:start(nil, 0, true)
check("starts on the small-field story", switcher.story == DroneCamDirector.STORIES.small)
-- Into the second step, then the field changes.
local guard = 0
while switcher.storyStep == 1 and guard < 4000 do switcher:update(0.05, 0); guard = guard + 1 end
switcher.fieldClass = "large"
local stayed = true
guard = 0
while switcher.storyStep ~= 1 and guard < 20000 do
    switcher:update(0.05, 0)
    if switcher.storyStep ~= 1 and switcher.story ~= DroneCamDirector.STORIES.small then stayed = false end
    guard = guard + 1
end
check("keeps the small-field story to the end of the loop", stayed)
check("then takes up the large-field story", switcher.story == DroneCamDirector.STORIES.large)

---Drives the cultivator rig north through a field at 2.5 m/s in story mode
---and records how far out the camera goes.
local function flyField(field, seconds)
    local r = field.rect
    FIELD = { r[1], r[2], r[3], r[4] }
    OBSTACLES = {}
    vehicle = makeRig(TRACTOR)
    VEHICLE_SPEED = 2.5
    tick(12, false)
    nodes[vehicle.rootNode].x, nodes[vehicle.rootNode].z = (r[1] + r[2]) / 2, r[3] + 8
    heading = 0
    DroneCam.settings.mode = AUTO
    camera.director.random = makeWH(1357)
    local result = { farthest = 0, highest = 0, maxStep = 0, maxTurn = 0 }
    local px, py, pz = getWorldTranslation(cn)
    local prx, pry = nodes[cn].rx, nodes[cn].ry
    local was = false
    tick(seconds, true, 0, function()
        local x, y, z = getWorldTranslation(cn)
        local rx, ry = nodes[cn].rx, nodes[cn].ry
        local flying = droneIsActive()
        if flying and was then
            local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
            result.farthest = math.max(result.farthest, math.sqrt((x - vx) ^ 2 + (z - vz) ^ 2))
            result.highest = math.max(result.highest, y - vy)
            result.maxStep = math.max(result.maxStep, math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2))
            result.maxTurn = math.max(result.maxTurn, countTurn(math.max(math.deg(math.abs(rx - prx)), math.deg(math.abs(wrapAngle(ry - pry))))))
        end
        was, px, py, pz, prx, pry = flying, x, y, z, rx, ry
    end)
    result.class = camera.fieldClass
    result.reach = camera.fieldReach
    result.directorClass = camera.director.fieldClass
    return result
end

print("\n-- field size: in flight --")
for _, case in ipairs({ { SMALL_FIELD, "small", 34 }, { MEDIUM_FIELD, "medium", 100 }, { LARGE_FIELD, "large", 150 } }) do
    local field, class, seconds = case[1], case[2], case[3]
    local flight = flyField(field, seconds)
    local info = DroneCamField.getFieldInfo(field.rect[1] + 1, field.rect[3] + 1)
    local reach = math.max(info.length, DroneCamCamera.FIELD_MIN_REACH)
    print(("        %s: farthest %.0fm of %.0fm reach, highest %.0fm, worst frame %.2fm / %.2f deg"):format(
          class, flight.farthest, reach, flight.highest, flight.maxStep, flight.maxTurn))
    check(class .. " field is recognised in flight", flight.class == class and flight.directorClass == class)
    check(class .. ": shots stay within the field's reach", flight.farthest <= reach * 1.1 + 10,
          ("%.0fm for a %.0fm field"):format(flight.farthest, reach))
    check(class .. ": smooth", flight.maxStep < MAX_STEP and flight.maxTurn < MAX_TURN,
          ("%.2fm / %.2f deg"):format(flight.maxStep, flight.maxTurn))
end

print("\n-- field size: shots pulled in on a small field --")
local flight = flyField(SMALL_FIELD, 6)
local reach = camera.fieldReach
check("reach is set by the small field", math.abs(reach - math.sqrt(60 ^ 2 + 100 ^ 2)) < 1, ("%.1f"):format(reach))
camera.shotSide = 1
camera.shotDuration, camera.shotElapsed = 10, 0
camera.rig = nil
local pushX, pushY, pushZ = DroneCamCreator.getTransform(camera, vehicle, S.SHOT_PUSH_IN)
local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
local pushFrom = math.sqrt((pushX - vx) ^ 2 + (pushZ - vz) ^ 2)
check("push-in starts inside the field's reach, not 150m out", pushFrom <= reach + 1, ("%.0fm"):format(pushFrom))
camera.shotElapsed = 10
local slideX, _, slideZ = DroneCamCreator.getTransform(camera, vehicle, S.SHOT_SLIDE)
check("slide stays within reach", math.sqrt((slideX - vx) ^ 2 + (slideZ - vz) ^ 2) <= reach + 1)
camera.planCache = {}
local lens = camera:getPlan(S.SHOT_LONG_LENS)
check("long lens stands within reach", lens == nil or math.sqrt((lens.x - vx) ^ 2 + (lens.z - vz) ^ 2) <= reach + 1)
local est = camera:getPlan(S.SHOT_ESTABLISHING)
check("establishing frames the game's field, within reach", est ~= nil and est.centreX == 2030 and est.centreZ == 50
      and est.distance <= reach + 1)
-- A tiny 40m x 50m paddock (0.2 ha): 64m across, so heights are held to
-- about 38m, well under the usual 60m top-down.
local TINY_FIELD = makeField(6000, 6040, 0, 50)
g_fieldManager.fields[#g_fieldManager.fields + 1] = TINY_FIELD
flyField(TINY_FIELD, 5)
vx, vy, vz = getWorldTranslation(vehicle.rootNode)
local topDownHeight = select(2, camera:getModeTransform(vehicle, S.MODE_TOPDOWN)) - vy
check("top-down comes down for a tiny field", topDownHeight < 40, ("%.1fm"):format(topDownHeight))
local _, chaseY = camera:getModeTransform(vehicle, S.MODE_CHASE)
check("chase keeps its usual 25m height", math.abs(chaseY - vy - 25) < 1e-6)

print("\n-- field size: no field --")
-- Still flying over the small field; now the game stops reporting a field.
local fields = g_fieldManager.fields
g_fieldManager.fields = {}
local before = camera.fieldReach
tick(1.1, true)
check("no field found: medium mix", camera.fieldClass == "medium" and camera.director.fieldClass == "medium")
-- A fixed expectation, not the mod's own constant: about 40 m/s at most.
check("and the limit eases off rather than jumping", camera.fieldReach > before
      and camera.fieldReach - before <= 40 * 1.1 + 1, ("%.0f -> %.0f"):format(before, camera.fieldReach))
g_fieldManager.fields = fields
local noField = flyField({ rect = { 8000, 8100, 0, 300 } }, 4)
check("flying with no field at all: medium mix, no limit", noField.class == "medium"
      and camera.fieldReach == DroneCamCamera.FIELD_NO_LIMIT)

g_fieldManager = nil
FIELD, OBSTACLES = nil, {}
DroneCam.settings.mode = CHASE
VEHICLE_SPEED = 8
driveVehicle(plainVehicle)
end)()

------------------------------------------------- hired workers, CP and AD

;(function()
local camera = DroneCam.camera
local S = DroneCamSettings

---A working tractor with an automated job that can be switched on and off.
local function startJob(kind)
    vehicle = makeRig({ width = 2.6, length = 5, height = 3, wheels = TRACTOR.wheels })
    vehicle.spec_workArea = { workAreas = { { lastProcessingTime = -10000 } } }
    local job = { active = false }
    if kind == "helper" then
        function vehicle:getIsAIActive() return job.active end
    elseif kind == "courseplay" then
        function vehicle:getIsCpActive() return job.active end
    else
        vehicle.ad = { stateModule = { isActive = function() return job.active end } }
    end
    VEHICLE_SPEED = 3
    tick(12, false)
    DroneCam.settings.mode = AUTO_RANDOM
    tick(4, true)
    job.active = true
    return job
end

print("\n-- helper jobs keep the drone up --")
for _, kind in ipairs({ "helper", "courseplay", "autodrive" }) do
    local job = startJob(kind)
    check(kind .. ": drone up while working", droneIsActive())
    -- The work stops (turning at the end, waiting for a trailer) but the job runs on.
    tick(20, false)
    check(kind .. ": stays up while the job runs, working or not", droneIsActive())
    job.active = false
    tick(10, false)
    check(kind .. ": hands back once the job ends", not droneIsActive())
end

print("\n-- standing still during a job: steady wide shots only --")
local job = startJob("helper")
VEHICLE_SPEED = 0
camera.director.random = makeRng(777)
local seen, badShots = {}, {}
tick(120, false, 0, function()
    if camera.isStationary and camera.fromPose == nil and camera.shot ~= nil then
        seen[camera.shot] = true
        if not DroneCamCamera.STATIONARY_SHOTS[camera.shot] then badShots[#badShots + 1] = camera.shot end
    end
end)
check("drone still up after two minutes standing still", droneIsActive())
check("only chase, top-down, orbit, establishing or long lens", #badShots == 0, table.concat(badShots, ","))
local kinds = 0
for _ in pairs(seen) do kinds = kinds + 1 end
check("still changes shot while standing", kinds >= 3, tostring(kinds))
camera.planCache = {}
check("no drive-over offered while standing", not camera:getIsShotAvailable(S.SHOT_DRIVE_OVER))
local orbitBefore = camera.orbitAngle
tick(2, false)
local orbitRate = math.deg(camera.orbitAngle - orbitBefore) / 2
check("the orbit circles slowly", math.abs(orbitRate - DroneCam.settings.orbitSpeed * 0.5) < 0.2, ("%.1f deg/s"):format(orbitRate))
VEHICLE_SPEED = 3
tick(4, false)
check("moving again: the full mix comes back", not camera.isStationary)

print("\n-- standing down during a job --")
job = startJob("helper")
tick(10, false)
check("up on the job", droneIsActive())
DroneCam:onToggleForce()
tick(8, true)
check("Ctrl+F hands back during a job", not droneIsActive() and not DroneCam.isForced)
tick(10, true)
check("and stays handed back while the job runs, even working", not droneIsActive())
job.active = false
tick(1, true)
tick(4, true)
check("the next job (or work) brings it back", droneIsActive())

job = startJob("courseplay")
tick(10, false)
DroneCam:onToggleEnabled()
tick(8, false)
check("Ctrl+D hands back during a job", not droneIsActive())
DroneCam:onToggleEnabled()
job.active = false

job = startJob("autodrive")
tick(10, false)
vehicle.getIsEntered = function() return false end
tick(0.2, false)
check("leaving the vehicle hands back during a job", not droneIsActive())
vehicle.getIsEntered = function() return true end
job.active = false

DroneCam.settings.mode = CHASE
VEHICLE_SPEED = 8
driveVehicle(plainVehicle)
end)()

print("\n-- settings round trip --")
DroneCam.settings.chaseDistance = 55
DroneCam.settings.sway = false
DroneCam.settings.mode = AUTO
DroneCamSettings.store(DroneCam.settings)
local reloaded = DroneCamSettings.new()
DroneCamSettings.restore(reloaded)
check("float persisted", reloaded.chaseDistance == 55)
check("bool persisted", reloaded.sway == false)
check("auto director mode persisted", reloaded.mode == AUTO, tostring(reloaded.mode))
check("director timings default to 10-15s with a 2s blend",
      reloaded.directorMinShot == 10 and reloaded.directorMaxShot == 15 and reloaded.shotBlendTime == 2)

print("\n-- out of range values are clamped --")
CURRENT = STORE[DroneCamSettings.getXmlFilePath()]
CURRENT["droneCam.chaseDistance"] = 99999
CURRENT["droneCam.mode"] = 42
local clamped = DroneCamSettings.new()
DroneCamSettings.restore(clamped)
check("distance clamped", clamped.chaseDistance == 200, tostring(clamped.chaseDistance))
check("mode clamped", clamped.mode == DroneCamSettings.MODE_LAST, tostring(clamped.mode))

print("\n-- teardown --")
DroneCam:deleteMap()
check("camera node released", DroneCam.camera == nil)
check("notifications were emitted", #NOTIFICATIONS > 0)

print(("\n%s"):format(failures == 0 and "ALL CHECKS PASSED" or (failures .. " CHECK(S) FAILED")))
os.exit(failures == 0 and 0 or 1)
