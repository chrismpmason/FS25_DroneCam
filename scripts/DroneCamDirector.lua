---@class DroneCamDirector
---Chooses the angle for the Auto director mode. Each angle is held for a random
---directorMinShot..directorMaxShot seconds, the next one is never the angle being
---left, and no change is made while the vehicle is turning, so a headland turn
---is always filmed from one steady viewpoint.
---
---This only decides which angle is wanted; DroneCamCamera owns the blend from
---one angle to the next.
DroneCamDirector = {}

local DroneCamDirector_mt = Class(DroneCamDirector)

---The angles the director cuts between.
DroneCamDirector.SHOTS = {
    DroneCamSettings.MODE_CHASE,
    DroneCamSettings.MODE_TOPDOWN,
    DroneCamSettings.MODE_ORBIT
}

---Yaw rate, in radians per second, above which the vehicle counts as turning.
---Steering corrections on a straight run stay well under it; even a wide
---headland turn is several times faster.
DroneCamDirector.TURN_RATE = math.rad(6)

---How long the vehicle must have been running straight again before a change
---of angle that was held back by a turn is let through.
DroneCamDirector.STRAIGHT_SETTLE_TIME = 1.5

---Stiffness of the yaw-rate filter, so a single flick of the wheel or a frame
---time spike is not taken for a turn.
DroneCamDirector.YAW_RATE_STIFFNESS = 4

local function normaliseAngleDiff(diff)
    while diff > math.pi do
        diff = diff - 2 * math.pi
    end
    while diff < -math.pi do
        diff = diff + 2 * math.pi
    end
    return diff
end

---@param settings DroneCamSettings
---@return DroneCamDirector
function DroneCamDirector.new(settings)
    local self = setmetatable({}, DroneCamDirector_mt)

    self.settings = settings
    -- Swappable so the tests can make the choices deterministic.
    self.random = math.random

    self:reset()

    return self
end

---Stops directing. The next start() begins a fresh sequence.
function DroneCamDirector:reset()
    self.isRunning = false
    self.shot = nil
    self.shotTime = 0
    self.shotLength = 0
    self.lastHeading = nil
    self.yawRate = 0
    self.straightTime = 0
end

---@param shot integer|nil
---@return boolean
local function getIsDirectorShot(shot)
    for i = 1, #DroneCamDirector.SHOTS do
        if DroneCamDirector.SHOTS[i] == shot then
            return true
        end
    end
    return false
end

---Starts directing, opening on the given angle so switching into the mode does
---not itself move the camera. A nil or unknown angle opens on a random one.
---@param initialShot integer|nil @Angle currently on screen
---@param heading number|nil @Vehicle heading in radians
function DroneCamDirector:start(initialShot, heading)
    if not getIsDirectorShot(initialShot) then
        initialShot = DroneCamDirector.SHOTS[self.random(#DroneCamDirector.SHOTS)]
    end

    self.isRunning = true
    self.shot = initialShot
    self.shotTime = 0
    self.shotLength = self:pickShotLength()
    self.lastHeading = heading
    self.yawRate = 0
    self.straightTime = 0
end

---@return number @Seconds to hold the next angle
function DroneCamDirector:pickShotLength()
    local minLength = self.settings.directorMinShot
    local maxLength = math.max(self.settings.directorMaxShot, minLength)

    return minLength + (maxLength - minLength) * self.random()
end

---@return integer @A random angle other than the current one
function DroneCamDirector:pickNextShot()
    local candidates = {}

    for i = 1, #DroneCamDirector.SHOTS do
        if DroneCamDirector.SHOTS[i] ~= self.shot then
            candidates[#candidates + 1] = DroneCamDirector.SHOTS[i]
        end
    end

    return candidates[self.random(#candidates)]
end

---@return boolean @True while the filtered yaw rate says the vehicle is turning
function DroneCamDirector:getIsTurning()
    return math.abs(self.yawRate) > DroneCamDirector.TURN_RATE
end

---Advances the shot clock and cuts to a new angle when one is due and the
---vehicle is running straight.
---@param dtSeconds number
---@param heading number|nil @Raw (unsmoothed) vehicle heading in radians
---@return integer|nil @Angle that should be on screen
function DroneCamDirector:update(dtSeconds, heading)
    if not self.isRunning then
        return self.shot
    end

    if heading ~= nil then
        if self.lastHeading ~= nil and dtSeconds > 0 then
            local rate = normaliseAngleDiff(heading - self.lastHeading) / dtSeconds
            local alpha = 1 - math.exp(-dtSeconds * DroneCamDirector.YAW_RATE_STIFFNESS)
            self.yawRate = self.yawRate + (rate - self.yawRate) * alpha
        end

        self.lastHeading = heading
    end

    if self:getIsTurning() then
        self.straightTime = 0
    else
        self.straightTime = self.straightTime + dtSeconds
    end

    self.shotTime = self.shotTime + dtSeconds

    if self.shotTime >= self.shotLength and self.straightTime >= DroneCamDirector.STRAIGHT_SETTLE_TIME then
        self.shot = self:pickNextShot()
        self.shotTime = 0
        self.shotLength = self:pickShotLength()
    end

    return self.shot
end
