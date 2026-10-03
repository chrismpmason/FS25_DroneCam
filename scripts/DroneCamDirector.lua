---@class DroneCamDirector
---Chooses the angle for the Auto director mode. It mixes wide angles (held
---directorMinShot..directorMaxShot seconds) with close-ups (held
---closeUpMinShot..closeUpMaxShot seconds), roughly alternating between the two,
---and never repeats the angle being left.
---
---Turns are handled in two ways: no new angle is chosen while the vehicle is
---turning, and a close-up that is on screen when a turn begins gives way to a
---wide angle straight away, since a camera tucked in beside a wheel has no good
---view of a headland turn.
---
---This only decides which angle is wanted; DroneCamCamera owns the blend from
---one angle to the next.
DroneCamDirector = {}

local DroneCamDirector_mt = Class(DroneCamDirector)

DroneCamDirector.WIDE_SHOTS = {
    DroneCamSettings.MODE_CHASE,
    DroneCamSettings.MODE_TOPDOWN,
    DroneCamSettings.MODE_ORBIT
}

DroneCamDirector.CLOSE_SHOTS = {
    DroneCamSettings.SHOT_WHEEL,
    DroneCamSettings.SHOT_IMPLEMENT,
    DroneCamSettings.SHOT_SIDE,
    DroneCamSettings.SHOT_FRONT,
    DroneCamSettings.SHOT_REAR_QUARTER
}

---Chance that the next angle comes from the other group (wide after a
---close-up, close-up after a wide). Below 1 so the pattern is not mechanical.
DroneCamDirector.SWITCH_GROUP_CHANCE = 0.75

---Yaw rate, in radians per second, above which the vehicle counts as turning.
---Steering corrections on a straight run stay well under it; even a wide
---headland turn is several times faster.
DroneCamDirector.TURN_RATE = math.rad(6)

---How long the vehicle must have been running straight again before a held
---change of angle is let through.
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

local function contains(list, value)
    for i = 1, #list do
        if list[i] == value then
            return true
        end
    end
    return false
end

---@param shot integer|nil
---@return boolean
function DroneCamDirector.getIsCloseUp(shot)
    return contains(DroneCamDirector.CLOSE_SHOTS, shot)
end

---@param settings DroneCamSettings
---@return DroneCamDirector
function DroneCamDirector.new(settings)
    local self = setmetatable({}, DroneCamDirector_mt)

    self.settings = settings
    -- Swappable so the tests can make the choices deterministic.
    self.random = math.random
    -- Set by the camera: some close-ups need something to film (the implement
    -- shot needs a work area).
    self.isShotAvailable = nil

    self:reset()

    return self
end

---Stops directing. The next start() begins a fresh sequence.
function DroneCamDirector:reset()
    self.isRunning = false
    self.shot = nil
    self.side = 1
    self.shotTime = 0
    self.shotLength = 0
    self.lastHeading = nil
    self.yawRate = 0
    self.straightTime = 0
end

---@return boolean
function DroneCamDirector:getIsAvailable(shot)
    if DroneCamDirector.getIsCloseUp(shot) and not self.settings.closeUps then
        return false
    end
    return self.isShotAvailable == nil or self.isShotAvailable(shot)
end

---Makes the given angle the current one and starts its clock.
function DroneCamDirector:cutTo(shot)
    self.shot = shot
    self.shotTime = 0
    self.shotLength = self:pickShotLength(shot)
    -- Close-ups are one-sided; alternate sides at random so they vary.
    self.side = self.random() < 0.5 and -1 or 1
end

---Starts directing, opening on the given angle so switching into the mode does
---not itself move the camera. A nil or unknown angle opens on a random wide
---one, as an establishing shot.
---@param initialShot integer|nil @Angle currently on screen
---@param heading number|nil @Vehicle heading in radians
function DroneCamDirector:start(initialShot, heading)
    if not contains(DroneCamDirector.WIDE_SHOTS, initialShot) then
        initialShot = DroneCamDirector.WIDE_SHOTS[self.random(#DroneCamDirector.WIDE_SHOTS)]
    end

    self.isRunning = true
    self:cutTo(initialShot)
    self.lastHeading = heading
    self.yawRate = 0
    self.straightTime = 0
end

---@return number @Seconds to hold the given angle
function DroneCamDirector:pickShotLength(shot)
    local settings = self.settings
    local minLength, maxLength

    if DroneCamDirector.getIsCloseUp(shot) then
        minLength, maxLength = settings.closeUpMinShot, settings.closeUpMaxShot
    else
        minLength, maxLength = settings.directorMinShot, settings.directorMaxShot
    end
    maxLength = math.max(maxLength, minLength)

    return minLength + (maxLength - minLength) * self.random()
end

---@param list table
---@return table @Entries of list that are available and are not the current angle
function DroneCamDirector:getCandidates(list)
    local candidates = {}

    for i = 1, #list do
        if list[i] ~= self.shot and self:getIsAvailable(list[i]) then
            candidates[#candidates + 1] = list[i]
        end
    end

    return candidates
end

---@param wideOnly boolean|nil
---@return integer @A random angle other than the current one
function DroneCamDirector:pickNextShot(wideOnly)
    local isClose = DroneCamDirector.getIsCloseUp(self.shot)
    local switchGroup = self.random() < DroneCamDirector.SWITCH_GROUP_CHANCE
    local wantClose = not wideOnly and (isClose ~= switchGroup)

    local candidates = self:getCandidates(wantClose and DroneCamDirector.CLOSE_SHOTS or DroneCamDirector.WIDE_SHOTS)
    if #candidates == 0 then
        candidates = self:getCandidates(DroneCamDirector.WIDE_SHOTS)
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

    local isTurning = self:getIsTurning()

    if isTurning then
        self.straightTime = 0
    else
        self.straightTime = self.straightTime + dtSeconds
    end

    self.shotTime = self.shotTime + dtSeconds

    if isTurning then
        if DroneCamDirector.getIsCloseUp(self.shot) then
            self:cutTo(self:pickNextShot(true))
        end
    elseif self.shotTime >= self.shotLength and self.straightTime >= DroneCamDirector.STRAIGHT_SETTLE_TIME then
        self:cutTo(self:pickNextShot(false))
    elseif DroneCamDirector.getIsCloseUp(self.shot) and not self:getIsAvailable(self.shot) then
        -- What the close-up was filming has gone (implement detached, close-ups
        -- switched off): move on rather than film nothing.
        self:cutTo(self:pickNextShot(true))
    end

    return self.shot
end
