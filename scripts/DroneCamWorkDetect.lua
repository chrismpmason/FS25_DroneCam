---@class DroneCamWorkDetect
---Decides whether the vehicle the player is controlling is currently doing
---field work, and applies hysteresis so that headland turns do not drop the
---drone shot.
---
---Detection walks the whole attacher tree via getChildVehicles() because the
---implement that actually touches the ground is almost never the vehicle the
---player sits in.
DroneCamWorkDetect = {}

local DroneCamWorkDetect_mt = Class(DroneCamWorkDetect)

---@param settings DroneCamSettings
---@return DroneCamWorkDetect
function DroneCamWorkDetect.new(settings)
    local self = setmetatable({}, DroneCamWorkDetect_mt)

    self.settings = settings
    self.workingTime = 0
    self.idleTime = 0
    self.isWorking = false

    return self
end

---Forgets all accumulated timers. Called when the controlled vehicle changes so
---the new vehicle starts from a clean slate.
function DroneCamWorkDetect:reset()
    self.workingTime = 0
    self.idleTime = 0
    self.isWorking = false
end

---True while any work area of the vehicle processed ground within the last
---~200ms. getIsWorkAreaProcessing is the authoritative test; getIsWorkAreaActive
---only reports that the area *could* work, so it is used as a fallback for
---implements that never stamp lastProcessingTime.
---@param vehicle table
---@return boolean
local function getHasProcessingWorkArea(vehicle)
    local spec = vehicle.spec_workArea
    if spec == nil or spec.workAreas == nil then
        return false
    end

    for i = 1, #spec.workAreas do
        local workArea = spec.workAreas[i]

        if vehicle.getIsWorkAreaProcessing ~= nil and vehicle:getIsWorkAreaProcessing(workArea) then
            return true
        end
    end

    return false
end

---Combines keep threshing for a moment after the last work area tick, so treat
---an actively filling combine as working in its own right.
---@param vehicle table
---@return boolean
local function getIsCombineWorking(vehicle)
    local spec = vehicle.spec_combine
    if spec == nil then
        return false
    end

    return spec.isFilling == true
end

---@param vehicle table
---@return boolean
local function getIsAIWorking(vehicle)
    local spec = vehicle.spec_aiFieldWorker
    if spec == nil then
        return false
    end

    return spec.isActive == true
end

---True while the vehicle has an automated job running: a hired worker (any
---FS25 AI job, which includes Courseplay's), or Courseplay or AutoDrive by
---their own flags when those mods are installed.
---@return boolean
function DroneCamWorkDetect.getIsAIJobActive(vehicle)
    if vehicle == nil then
        return false
    end

    if vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive() == true then
        return true
    end

    -- Courseplay
    if vehicle.getIsCpActive ~= nil and vehicle:getIsCpActive() == true then
        return true
    end

    -- AutoDrive
    local ad = vehicle.ad
    if ad ~= nil and ad.stateModule ~= nil and ad.stateModule.isActive ~= nil and ad.stateModule:isActive() == true then
        return true
    end

    return false
end

---Tests the vehicle and every vehicle attached to it.
---@param vehicle table @Root vehicle (the one the player controls)
---@param followAI boolean @Whether an AI helper driving this vehicle counts as work
---@return boolean
function DroneCamWorkDetect.getIsVehicleWorking(vehicle, followAI)
    if vehicle == nil then
        return false
    end

    local vehicles
    if vehicle.getChildVehicles ~= nil then
        vehicles = vehicle:getChildVehicles()
    else
        vehicles = { vehicle }
    end

    for i = 1, #vehicles do
        local childVehicle = vehicles[i]

        if getHasProcessingWorkArea(childVehicle) then
            return true
        end

        if getIsCombineWorking(childVehicle) then
            return true
        end

        if followAI and getIsAIWorking(childVehicle) then
            return true
        end
    end

    return false
end

---Advances the hysteresis timers.
---@param vehicle table @Controlled vehicle, may be nil
---@param dt number @Frame time in milliseconds
---@return boolean @True once work has been continuous for startDelay seconds,
---                 and stays true until stopDelay seconds of no work have passed
function DroneCamWorkDetect:update(vehicle, dt)
    local settings = self.settings
    local dtSeconds = dt * 0.001
    local isWorkingNow = DroneCamWorkDetect.getIsVehicleWorking(vehicle, settings.followAI)

    if isWorkingNow then
        self.idleTime = 0
        self.workingTime = self.workingTime + dtSeconds

        if not self.isWorking and self.workingTime >= settings.startDelay then
            self.isWorking = true
        end
    else
        self.workingTime = 0
        self.idleTime = self.idleTime + dtSeconds

        if self.isWorking and self.idleTime >= settings.stopDelay then
            self.isWorking = false
        end
    end

    return self.isWorking
end
