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
local function tick(seconds, working, headingRate)
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

print("\n-- settings round trip --")
DroneCam.settings.chaseDistance = 55
DroneCam.settings.sway = false
DroneCamSettings.store(DroneCam.settings)
local reloaded = DroneCamSettings.new()
DroneCamSettings.restore(reloaded)
check("float persisted", reloaded.chaseDistance == 55)
check("bool persisted", reloaded.sway == false)

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
