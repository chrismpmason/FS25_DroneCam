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
function getTerrainHeightAtWorldPos(terrain, x, y, z)
    assert(terrain ~= nil, "nil terrain node")
    return TERRAIN_HEIGHT
end

RAYCAST_HIT = false
RaycastUtil = {}
function RaycastUtil.raycastClosest(x, y, z, dx, dy, dz, maxDistance, mask)
    assert(mask ~= nil and mask > 0, "bad collision mask")
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    assert(math.abs(len - 1) < 0.001, "direction not normalised: " .. len)
    if RAYCAST_HIT then return 99, x, y, z, maxDistance * 0.5 end
    return nil
end

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
InputAction = { DRONECAM_TOGGLE = 1, DRONECAM_MODE = 2, DRONECAM_FORCE = 3, DRONECAM_HUD = 4 }
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
dofile(MOD .. "/scripts/DroneCamDirector.lua")
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
            nodes[vehicle.rootNode].x = nodes[vehicle.rootNode].x + fx * 8 * (dt / 1000)
            nodes[vehicle.rootNode].z = nodes[vehicle.rootNode].z + fz * 8 * (dt / 1000)

            -- Keep the vehicle camera roughly where the game would put it.
            nodes[vehicleCamNode].x = nodes[vehicle.rootNode].x
            nodes[vehicleCamNode].y = nodes[vehicle.rootNode].y + 3
            nodes[vehicleCamNode].z = nodes[vehicle.rootNode].z
            nodes[vehicleCamNode].ry = heading + math.pi

            if working then
                vehicle.spec_workArea.workAreas[1].lastProcessingTime = g_currentMission.time
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
        maxTurn = math.max(maxTurn, math.deg(math.abs(rx - prx)), math.deg(math.abs(wrapAngle(ry - pry))))
        px, py, pz, prx, pry = x, y, z, rx, ry
        if onStep ~= nil then onStep(dtSeconds) end
    end)

    return maxStep, maxTurn
end

-- Per-frame limits for "no hard cuts", at 16ms frames. The vehicle itself
-- moves 0.13m a frame; a cut between angles is a 40-80m or 45-90 degree jump.
local MAX_STEP = 2.5
local MAX_TURN = 4

local CHASE = DroneCamSettings.MODE_CHASE
local TOPDOWN = DroneCamSettings.MODE_TOPDOWN
local ORBIT = DroneCamSettings.MODE_ORBIT
local AUTO = DroneCamSettings.MODE_AUTO

print("\n-- auto director: mode cycle --")
tick(12, false)
DroneCam.settings.mode = CHASE
local cycled = {}
for i = 1, 4 do
    DroneCam:onCycleMode()
    cycled[i] = DroneCam.settings.mode
end
check("Ctrl+C cycles chase -> top-down -> orbit -> auto -> chase",
      cycled[1] == TOPDOWN and cycled[2] == ORBIT and cycled[3] == AUTO and cycled[4] == CHASE,
      table.concat(cycled, ","))
DroneCam.settings.mode = ORBIT
DroneCam:onCycleMode()
check("auto director is announced by name", NOTIFICATIONS[#NOTIFICATIONS] == "droneCam_mode: droneCam_mode_auto",
      NOTIFICATIONS[#NOTIFICATIONS])
DroneCam.settings.mode = CHASE

print("\n-- auto director: choosing angles --")
local director = DroneCamDirector.new(DroneCam.settings)
director.random = makeRng(12345)
director:start(CHASE, 0)

local switches, repeats = 0, 0
local seen = {}
local held, minHeld, maxHeld = 0, math.huge, 0
local lastShot = director.shot
for _ = 1, 40000 do -- 2000 simulated seconds, driving dead straight
    held = held + 0.05
    local previousTime = director.shotTime
    local shot = director:update(0.05, 0)
    if director.shotTime < previousTime then
        switches = switches + 1
        if shot == lastShot then repeats = repeats + 1 end
        minHeld, maxHeld = math.min(minHeld, held), math.max(maxHeld, held)
        seen[shot] = true
        held = 0
    end
    lastShot = shot
end
check("switches angle regularly", switches > 120, tostring(switches))
check("never repeats the same angle twice in a row", repeats == 0, tostring(repeats))
check("uses chase, top-down and orbit", seen[CHASE] and seen[TOPDOWN] and seen[ORBIT])
check("holds each angle at least 10s", minHeld >= 10 - 1e-6, ("min=%.2f"):format(minHeld))
check("holds each angle at most 15s", maxHeld <= 15 + 0.05 + 1e-6, ("max=%.2f"):format(maxHeld))
check("hold times spread across 10-15s", minHeld < 10.5 and maxHeld > 14.5,
      ("min=%.2f max=%.2f"):format(minHeld, maxHeld))

local fresh = DroneCamDirector.new(DroneCam.settings)
fresh.random = makeRng(99)
fresh:start(nil, 0)
check("starts on a random angle when none is on screen",
      fresh.shot == CHASE or fresh.shot == TOPDOWN or fresh.shot == ORBIT, tostring(fresh.shot))
fresh:start(DroneCamSettings.MODE_AUTO, 0)
check("never opens on auto itself", fresh.shot ~= DroneCamSettings.MODE_AUTO)

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

print("\n-- auto director: in flight --")
tick(12, false)
DroneCam.settings.mode = AUTO
tick(3, true)
check("engages in auto director mode", droneIsActive())
local camera = DroneCam.camera
check("director running", camera.director.isRunning)
check("flying one of the three angles",
      camera.shot == CHASE or camera.shot == TOPDOWN or camera.shot == ORBIT, tostring(camera.shot))
camera.director.random = makeRng(2024)

local changes, sameTwice = 0, 0
local blendLengths = {}
local blending = 0
local shotSeen = camera.shot
local maxStep, maxTurn = measureMotion(75, true, 0, function(dtSeconds)
    if camera.shot ~= shotSeen then
        changes = changes + 1
        shotSeen = camera.shot
    end
    if camera.fromPose ~= nil then
        blending = blending + dtSeconds
    elseif blending > 0 then
        blendLengths[#blendLengths + 1] = blending
        blending = 0
    end
end)
print(("        75s: %d changes, worst frame %.2fm / %.2f deg"):format(changes, maxStep, maxTurn))
check("changes angle several times in 75s", changes >= 4 and changes <= 8, tostring(changes))
check("no hard cut in position", maxStep < MAX_STEP, ("%.2fm in one frame"):format(maxStep))
check("no hard cut in rotation", maxTurn < MAX_TURN, ("%.2f deg in one frame"):format(maxTurn))
local blendOk = #blendLengths >= 4
for i = 1, #blendLengths do
    if math.abs(blendLengths[i] - 2) > 0.05 then blendOk = false end
end
check("each change blends over about 2 seconds", blendOk, table.concat(blendLengths, ", "))

print("\n-- auto director: no change during a headland in flight --")
tick(4, true) -- let any blend in progress finish
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
