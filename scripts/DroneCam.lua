---@class DroneCam
---Mod entry point. Watches the vehicle the player is controlling, decides when
---the drone shot should be running, and owns the rules that guarantee the player
---is never left stuck in it.
---
---Purely client-side: no events are sent and nothing is synchronised, so it is
---safe in multiplayer and does nothing at all on a dedicated server.
DroneCam = {}

DroneCam.STATE_OFF = 1
DroneCam.STATE_ACTIVE = 2
DroneCam.STATE_BLEND_OUT = 3

DroneCam.settings = DroneCamSettings.new()
DroneCam.state = DroneCam.STATE_OFF
DroneCam.camera = nil
DroneCam.workDetect = nil
DroneCam.trackedVehicle = nil
DroneCam.isForced = false
DroneCam.hasUserOverride = false
DroneCam.hudWasVisible = nil

---@return table|nil @The vehicle the local player is controlling
local function getControlledVehicle()
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        return g_localPlayer:getCurrentVehicle()
    end

    if g_currentMission ~= nil then
        return g_currentMission.controlledVehicle
    end

    return nil
end

---@param vehicle table|nil
---@return boolean @True while the player is actually sitting in the vehicle
local function getIsPlayerInVehicle(vehicle)
    if vehicle == nil or vehicle.rootNode == nil then
        return false
    end

    if vehicle.spec_enterable == nil then
        return false
    end

    if vehicle.getIsEntered ~= nil then
        return vehicle:getIsEntered()
    end

    return true
end

---@param vehicle table
---@return integer|nil @Camera node of the vehicle camera the player was using
local function getVehicleCameraNode(vehicle)
    local spec = vehicle ~= nil and vehicle.spec_enterable or nil
    if spec == nil or spec.cameras == nil or spec.camIndex == nil then
        return nil
    end

    local camera = spec.cameras[spec.camIndex]
    if camera == nil then
        return nil
    end

    return camera.cameraNode
end

---@param text string
local function showNotification(text)
    if g_currentMission == nil or g_currentMission.hud == nil then
        return
    end

    g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, text)
end

---@param key string
---@return string
local function getText(key)
    return g_i18n:getText(key)
end

function DroneCam:loadMap()
    DroneCamSettings.restore(self.settings)
    self.workDetect = DroneCamWorkDetect.new(self.settings)
    self.state = DroneCam.STATE_OFF
end

function DroneCam:deleteMap()
    -- Restoring before teardown matters on map exit: the camera node is about to
    -- be destroyed along with the scene.
    self:restoreHud()

    if self.camera ~= nil then
        self.camera:delete()
        self.camera = nil
    end

    self.state = DroneCam.STATE_OFF
    self.trackedVehicle = nil
    self.isForced = false
    self.hasUserOverride = false

    DroneCamSettings.store(self.settings)
end

function DroneCam:mouseEvent(posX, posY, isDown, isUp, button)
end

function DroneCam:keyEvent(unicode, sym, modifier, isDown)
end

function DroneCam:draw()
end

---Creates the camera on first use, once the mission and scene are up.
---@return boolean @True if a camera is available
function DroneCam:ensureCamera()
    if self.camera ~= nil then
        return true
    end

    if g_cameraManager == nil or g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        return false
    end

    self.camera = DroneCamCamera.new(self.settings)

    return true
end

---Hides the HUD if that option is on, remembering what it was so it can be put
---back exactly as it was found.
function DroneCam:applyHud()
    if not self.settings.hideHud or self.hudWasVisible ~= nil then
        return
    end

    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    if hud == nil or hud.getIsVisible == nil or hud.setIsVisible == nil then
        return
    end

    self.hudWasVisible = hud:getIsVisible()
    hud:setIsVisible(false)
end

function DroneCam:restoreHud()
    if self.hudWasVisible == nil then
        return
    end

    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    if hud ~= nil and hud.setIsVisible ~= nil then
        hud:setIsVisible(self.hudWasVisible)
    end

    self.hudWasVisible = nil
end

---Puts the player back in their vehicle camera immediately, with no blend.
---Used for everything that must not be allowed to fail: leaving the vehicle,
---the vehicle being deleted, a menu opening, the map unloading.
---@param vehicle table|nil
function DroneCam:hardRestore(vehicle)
    self:restoreHud()

    if self.state == DroneCam.STATE_OFF then
        return
    end

    self.state = DroneCam.STATE_OFF

    if self.camera ~= nil then
        self.camera:resetState()
    end

    -- Only take the camera back if we still hold it; if something else already
    -- became active, forcing a switch here would fight it.
    local cameraNode = self.camera ~= nil and self.camera:getCameraNode() or nil
    if cameraNode == nil or g_cameraManager == nil or g_cameraManager:getActiveCamera() ~= cameraNode then
        return
    end

    if getIsPlayerInVehicle(vehicle) and vehicle.setActiveCameraIndex ~= nil then
        vehicle:setActiveCameraIndex(vehicle.spec_enterable.camIndex)
    elseif g_localPlayer ~= nil and g_localPlayer.camera ~= nil and g_localPlayer.camera.makeCurrent ~= nil then
        -- No vehicle to go back to (it was deleted under us): fall back to the
        -- on-foot camera rather than leaving a dead camera active.
        g_localPlayer.camera:makeCurrent()
    end
end

---@param vehicle table
function DroneCam:startDrone(vehicle)
    if not self:ensureCamera() then
        return
    end

    local fromNode = g_cameraManager:getActiveCamera()

    self.camera:activate(fromNode, vehicle)
    self.state = DroneCam.STATE_ACTIVE
    self:applyHud()
end

---@param vehicle table
function DroneCam:stopDrone(vehicle)
    if self.state ~= DroneCam.STATE_ACTIVE or self.camera == nil then
        return
    end

    self.camera:beginBlendOut(getVehicleCameraNode(vehicle))
    self.state = DroneCam.STATE_BLEND_OUT
end

function DroneCam:update(dt)
    if g_dedicatedServer ~= nil or g_currentMission == nil then
        return
    end

    local vehicle = getControlledVehicle()

    -- Anything that means "the player should not be in a drone shot right now"
    -- is handled up front, before any state is advanced.
    local isMenuOpen = g_gui ~= nil and g_gui.getIsGuiVisible ~= nil and g_gui:getIsGuiVisible()

    if not getIsPlayerInVehicle(vehicle) or isMenuOpen then
        self:hardRestore(vehicle)

        if self.workDetect ~= nil then
            self.workDetect:reset()
        end

        self.isForced = false
        self.hasUserOverride = false
        self.trackedVehicle = nil

        return
    end

    if vehicle ~= self.trackedVehicle then
        self:hardRestore(self.trackedVehicle)
        self.workDetect:reset()
        self.isForced = false
        self.hasUserOverride = false
        self.trackedVehicle = vehicle
    end

    local isWorking = self.workDetect:update(vehicle, dt)

    -- A manual camera change by the player wins until the job stops, so the mod
    -- never fights someone who has deliberately looked somewhere else.
    if not isWorking then
        self.hasUserOverride = false
    end

    local shouldRun = (self.isForced or (self.settings.enabled and isWorking)) and not self.hasUserOverride

    if shouldRun then
        if self.state == DroneCam.STATE_OFF then
            self:startDrone(vehicle)
        elseif self.state == DroneCam.STATE_BLEND_OUT then
            -- Work restarted during the hand-off; pick the shot back up from
            -- wherever the camera has drifted to.
            self.camera:cancelBlendOut()
            self.state = DroneCam.STATE_ACTIVE
            self:applyHud()
        end
    elseif self.state == DroneCam.STATE_ACTIVE then
        self:stopDrone(vehicle)
    end

    if self.state == DroneCam.STATE_OFF or self.camera == nil then
        return
    end

    -- Something else became the active camera (the player cycled the vehicle
    -- view, a cutscene started): stand down and remember the override.
    if g_cameraManager:getActiveCamera() ~= self.camera:getCameraNode() then
        self:restoreHud()
        self.camera:resetState()
        self.state = DroneCam.STATE_OFF
        self.isForced = false
        self.hasUserOverride = true

        return
    end

    if self.camera:update(dt, vehicle) then
        self:hardRestore(vehicle)
    end
end

-- Input ----------------------------------------------------------------------

function DroneCam:onToggleEnabled()
    self.settings.enabled = not self.settings.enabled
    self.hasUserOverride = false

    if not self.settings.enabled then
        self.isForced = false
        self:stopDrone(self.trackedVehicle)
    end

    DroneCamSettings.store(self.settings)

    showNotification(("%s: %s"):format(getText("droneCam_auto"),
        getText(self.settings.enabled and "droneCam_on" or "droneCam_off")))
end

function DroneCam:onCycleMode()
    local mode = self.settings.mode + 1
    if mode > DroneCamSettings.MODE_LAST then
        mode = DroneCamSettings.MODE_FIRST
    end

    self.settings.mode = mode
    self.hasUserOverride = false
    DroneCamSettings.store(self.settings)

    showNotification(("%s: %s"):format(getText("droneCam_mode"),
        getText(DroneCamSettings.MODE_L10N[mode])))
end

function DroneCam:onToggleForce()
    self.isForced = not self.isForced
    self.hasUserOverride = false

    if not self.isForced then
        -- Fall straight back to the vehicle camera unless real field work is
        -- keeping the shot alive on its own.
        local isWorking = self.workDetect ~= nil and self.workDetect.isWorking
        if not (self.settings.enabled and isWorking) then
            self:stopDrone(self.trackedVehicle)
        end
    end

    showNotification(("%s: %s"):format(getText("droneCam_force"),
        getText(self.isForced and "droneCam_on" or "droneCam_off")))
end

function DroneCam:onToggleHud()
    self.settings.hideHud = not self.settings.hideHud
    DroneCamSettings.store(self.settings)

    if self.settings.hideHud then
        if self.state ~= DroneCam.STATE_OFF then
            self:applyHud()
        end
    else
        self:restoreHud()
    end

    showNotification(("%s: %s"):format(getText("droneCam_hideHud"),
        getText(self.settings.hideHud and "droneCam_on" or "droneCam_off")))
end

---Registers the mod's actions alongside the vehicle's own, so they are live
---whenever the player is in a vehicle and are cleaned up by the game on exit.
function DroneCam.registerActionEvents(vehicle, superFunc, isActiveForInput, isActiveForInputIgnoreSelection)
    if superFunc ~= nil then
        superFunc(vehicle, isActiveForInput, isActiveForInputIgnoreSelection)
    end

    if not isActiveForInputIgnoreSelection then
        return
    end

    local actions = {
        { InputAction.DRONECAM_TOGGLE, DroneCam.onToggleEnabled },
        { InputAction.DRONECAM_MODE,   DroneCam.onCycleMode },
        { InputAction.DRONECAM_FORCE,  DroneCam.onToggleForce },
        { InputAction.DRONECAM_HUD,    DroneCam.onToggleHud }
    }

    for i = 1, #actions do
        local action, callback = actions[i][1], actions[i][2]

        if action ~= nil then
            local _, actionEventId = g_inputBinding:registerActionEvent(action, DroneCam, callback, false, true, false, true)

            if actionEventId ~= nil then
                g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_LOW)
                g_inputBinding:setActionEventTextVisibility(actionEventId, false)
            end
        end
    end
end

if Enterable ~= nil then
    Enterable.onRegisterActionEvents = Utils.overwrittenFunction(Enterable.onRegisterActionEvents, DroneCam.registerActionEvents)
end

addModEventListener(DroneCam)
