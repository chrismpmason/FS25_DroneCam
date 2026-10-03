---@class DroneCamDirector
---Chooses the shot for the Auto director modes.
---
---Story mode plays a sequence: establishing, push-in, two or three close-ups,
---fly-over, pull-out reveal, then round again. Each step has alternatives that
---stand in now and then, so no two loops are quite the same.
---
---Random mode mixes everything, roughly alternating wide shots (including the
---creator shots) with close-ups.
---
---In both, wide and fixed shots are held directorMinShot..directorMaxShot
---seconds, moving shots movingMinShot..movingMaxShot and close-ups
---closeUpMinShot..closeUpMaxShot; no shot follows itself; and as the vehicle
---nears the end of a row the headland shot is taken if a spot for it exists.
---
---Turns: nothing changes while the vehicle is turning, and a close-up that is
---on screen when a turn begins gives way to a steady wide shot straight away.
---
---This only decides which shot is wanted; DroneCamCamera plans and frames it
---and owns the blend from one shot to the next.
DroneCamDirector = {}

local DroneCamDirector_mt = Class(DroneCamDirector)

local S = DroneCamSettings

DroneCamDirector.STATIC_WIDE_SHOTS = { S.MODE_CHASE, S.MODE_TOPDOWN, S.MODE_ORBIT }

DroneCamDirector.FIXED_SHOTS = { S.SHOT_ESTABLISHING, S.SHOT_LONG_LENS, S.SHOT_EDGE_PAN, S.SHOT_HEADLAND }

DroneCamDirector.MOVING_SHOTS = { S.SHOT_PUSH_IN, S.SHOT_PULL_OUT, S.SHOT_FLY_OVER, S.SHOT_RISE_UP, S.SHOT_SLIDE }

DroneCamDirector.CLOSE_SHOTS = {
    S.SHOT_WHEEL, S.SHOT_IMPLEMENT, S.SHOT_SIDE, S.SHOT_FRONT, S.SHOT_REAR_QUARTER
}

---Everything that is not a close-up, for random mode's wide/close mix.
DroneCamDirector.WIDE_SHOTS = {}
for _, list in ipairs({ DroneCamDirector.STATIC_WIDE_SHOTS, DroneCamDirector.FIXED_SHOTS, DroneCamDirector.MOVING_SHOTS }) do
    for _, shot in ipairs(list) do
        DroneCamDirector.WIDE_SHOTS[#DroneCamDirector.WIDE_SHOTS + 1] = shot
    end
end

---Steady shots to fall back on when a close-up has to give way in a turn.
---Nothing that moves along a path, and nothing that needs the vehicle to be
---heading anywhere in particular.
DroneCamDirector.TURN_SHOTS = { S.MODE_CHASE, S.MODE_TOPDOWN, S.MODE_ORBIT, S.SHOT_ESTABLISHING, S.SHOT_LONG_LENS }

---The story. Each entry is a step: a list whose first shot is the usual one
---and the rest are stand-ins, or CLOSE_UPS for a run of close-ups.
DroneCamDirector.CLOSE_UPS = "closeUps"
DroneCamDirector.STORY = {
    { S.SHOT_ESTABLISHING, S.SHOT_LONG_LENS, S.SHOT_EDGE_PAN },
    { S.SHOT_PUSH_IN, S.SHOT_RISE_UP },
    DroneCamDirector.CLOSE_UPS,
    { S.SHOT_FLY_OVER, S.SHOT_SLIDE },
    { S.SHOT_PULL_OUT, S.MODE_ORBIT }
}

---Chance a story step plays its usual shot rather than a stand-in.
DroneCamDirector.STORY_USUAL_CHANCE = 0.65
DroneCamDirector.STORY_CLOSE_UPS_MIN = 2
DroneCamDirector.STORY_CLOSE_UPS_MAX = 3

---Chance that the next shot in random mode comes from the other group (wide
---after a close-up, close-up after a wide). Below 1 so the pattern is not
---mechanical.
DroneCamDirector.SWITCH_GROUP_CHANCE = 0.75

---Yaw rate, in radians per second, above which the vehicle counts as turning.
---Steering corrections on a straight run stay well under it; even a wide
---headland turn is several times faster.
DroneCamDirector.TURN_RATE = math.rad(6)

---How long the vehicle must have been running straight again before a held
---change of shot is let through.
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

---@return boolean
function DroneCamDirector.getIsCloseUp(shot)
    return contains(DroneCamDirector.CLOSE_SHOTS, shot)
end

---@return boolean
function DroneCamDirector.getIsMoving(shot)
    return contains(DroneCamDirector.MOVING_SHOTS, shot)
end

---@return boolean
function DroneCamDirector.getIsFixed(shot)
    return contains(DroneCamDirector.FIXED_SHOTS, shot)
end

---@param settings DroneCamSettings
---@return DroneCamDirector
function DroneCamDirector.new(settings)
    local self = setmetatable({}, DroneCamDirector_mt)

    self.settings = settings
    -- Swappable so the tests can make the choices deterministic.
    self.random = math.random
    -- Set by the camera. isShotAvailable says whether a shot could start now
    -- (the implement shot needs a work area, fixed shots need a clear spot);
    -- isShotStillUsable whether the one on screen can carry on.
    self.isShotAvailable = nil
    self.isShotStillUsable = nil

    self:reset()

    return self
end

---Stops directing. The next start() begins a fresh sequence.
function DroneCamDirector:reset()
    self.isRunning = false
    self.isStory = false
    self.shot = nil
    self.side = 1
    self.shotTime = 0
    self.shotLength = 0
    self.lastHeading = nil
    self.yawRate = 0
    self.straightTime = 0
    self.storyStep = 1
    self.closeUpsLeft = nil
end

---@return boolean
function DroneCamDirector:getIsAvailable(shot)
    if DroneCamDirector.getIsCloseUp(shot) and not self.settings.closeUps then
        return false
    end
    return self.isShotAvailable == nil or self.isShotAvailable(shot)
end

---@return boolean
function DroneCamDirector:getIsStillUsable(shot)
    if DroneCamDirector.getIsCloseUp(shot) and not self.settings.closeUps then
        return false
    end
    return self.isShotStillUsable == nil or self.isShotStillUsable(shot)
end

---Makes the given shot the current one and starts its clock.
function DroneCamDirector:cutTo(shot)
    self.shot = shot
    self.shotTime = 0
    self.shotLength = self:pickShotLength(shot)
    -- Many shots are one-sided; pick a side at random so they vary.
    self.side = self.random() < 0.5 and -1 or 1
end

---Starts directing. A wide shot already on screen is kept, so choosing the
---mode is not itself a change of shot; otherwise the opening is the story's
---first step, or a random wide angle.
---@param initialShot integer|nil @Shot currently on screen
---@param heading number|nil @Vehicle heading in radians
---@param isStory boolean
function DroneCamDirector:start(initialShot, heading, isStory)
    self.isRunning = true
    self.isStory = isStory == true
    self.storyStep = 1
    self.closeUpsLeft = nil

    if contains(DroneCamDirector.STATIC_WIDE_SHOTS, initialShot) then
        self:cutTo(initialShot)
    elseif self.isStory then
        self:cutTo(self:pickStoryShot())
    else
        local wide = DroneCamDirector.STATIC_WIDE_SHOTS
        self:cutTo(wide[self.random(#wide)])
    end

    self.lastHeading = heading
    self.yawRate = 0
    self.straightTime = 0
end

---Switches between story and random without changing the shot on screen.
function DroneCamDirector:setStory(isStory)
    if self.isStory ~= isStory then
        self.isStory = isStory
        self.storyStep = 1
        self.closeUpsLeft = nil
    end
end

---@return number @Seconds to hold the given shot
function DroneCamDirector:pickShotLength(shot)
    local settings = self.settings
    local minLength, maxLength

    if DroneCamDirector.getIsCloseUp(shot) then
        minLength, maxLength = settings.closeUpMinShot, settings.closeUpMaxShot
    elseif DroneCamDirector.getIsMoving(shot) then
        minLength, maxLength = settings.movingMinShot, settings.movingMaxShot
    else
        minLength, maxLength = settings.directorMinShot, settings.directorMaxShot
    end
    maxLength = math.max(maxLength, minLength)

    return minLength + (maxLength - minLength) * self.random()
end

---@return table @Entries of list that are available and are not the current shot
function DroneCamDirector:getCandidates(list)
    local candidates = {}

    for i = 1, #list do
        if list[i] ~= self.shot and self:getIsAvailable(list[i]) then
            candidates[#candidates + 1] = list[i]
        end
    end

    return candidates
end

---@return integer|nil
function DroneCamDirector:pickFrom(list)
    local candidates = self:getCandidates(list)
    if #candidates == 0 then
        return nil
    end
    return candidates[self.random(#candidates)]
end

function DroneCamDirector:advanceStory()
    self.closeUpsLeft = nil
    self.storyStep = self.storyStep % #DroneCamDirector.STORY + 1
end

---Next shot of the story, skipping steps that have nothing available.
---@return integer
function DroneCamDirector:pickStoryShot()
    for _ = 1, #DroneCamDirector.STORY do
        local step = DroneCamDirector.STORY[self.storyStep]

        if step == DroneCamDirector.CLOSE_UPS then
            if self.closeUpsLeft == nil then
                local spread = DroneCamDirector.STORY_CLOSE_UPS_MAX - DroneCamDirector.STORY_CLOSE_UPS_MIN + 1
                self.closeUpsLeft = DroneCamDirector.STORY_CLOSE_UPS_MIN + math.min(math.floor(self.random() * spread), spread - 1)
            end

            local shot = self:pickFrom(DroneCamDirector.CLOSE_SHOTS)
            if shot ~= nil then
                self.closeUpsLeft = self.closeUpsLeft - 1
                if self.closeUpsLeft <= 0 then
                    self:advanceStory()
                end
                return shot
            end
        else
            -- Usual shot first most of the time, otherwise a random stand-in
            -- first; either way the rest follow in case the first is unavailable.
            local order = {}
            if self.random() < DroneCamDirector.STORY_USUAL_CHANCE or #step == 1 then
                order[1] = step[1]
            else
                order[1] = step[1 + self.random(#step - 1)]
            end
            for i = 1, #step do
                if step[i] ~= order[1] then
                    order[#order + 1] = step[i]
                end
            end

            for i = 1, #order do
                if order[i] ~= self.shot and self:getIsAvailable(order[i]) then
                    self:advanceStory()
                    return order[i]
                end
            end
        end

        self:advanceStory()
    end

    return self:pickFrom(DroneCamDirector.STATIC_WIDE_SHOTS) or DroneCamSettings.MODE_CHASE
end

---@return integer
function DroneCamDirector:pickRandomShot()
    local isClose = DroneCamDirector.getIsCloseUp(self.shot)
    local switchGroup = self.random() < DroneCamDirector.SWITCH_GROUP_CHANCE
    local wantClose = isClose ~= switchGroup

    return self:pickFrom(wantClose and DroneCamDirector.CLOSE_SHOTS or DroneCamDirector.WIDE_SHOTS)
        or self:pickFrom(DroneCamDirector.WIDE_SHOTS)
        or self:pickFrom(DroneCamDirector.STATIC_WIDE_SHOTS)
        or DroneCamSettings.MODE_CHASE
end

---@param isTurnStarting boolean @A close-up is giving way to a turn
---@return integer @A shot other than the current one
function DroneCamDirector:pickNextShot(isTurnStarting)
    if isTurnStarting then
        -- A run of close-ups is cut short by the turn; the story carries on
        -- from the step after it once the vehicle is straight again.
        if self.isStory and DroneCamDirector.STORY[self.storyStep] == DroneCamDirector.CLOSE_UPS then
            self:advanceStory()
        end
        return self:pickFrom(DroneCamDirector.TURN_SHOTS) or DroneCamSettings.MODE_CHASE
    end

    -- Only available while the end of the row is coming up: always worth it.
    if self.shot ~= DroneCamSettings.SHOT_HEADLAND and self:getIsAvailable(DroneCamSettings.SHOT_HEADLAND) then
        return DroneCamSettings.SHOT_HEADLAND
    end

    if self.isStory then
        return self:pickStoryShot()
    end
    return self:pickRandomShot()
end

---@return boolean @True while the filtered yaw rate says the vehicle is turning
function DroneCamDirector:getIsTurning()
    return math.abs(self.yawRate) > DroneCamDirector.TURN_RATE
end

---Advances the shot clock and cuts to a new shot when one is due and the
---vehicle is running straight.
---@param dtSeconds number
---@param heading number|nil @Raw (unsmoothed) vehicle heading in radians
---@return integer|nil @Shot that should be on screen
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
    elseif not self:getIsStillUsable(self.shot) then
        -- What the shot was filming has gone (implement detached, close-ups
        -- switched off) or a fixed spot has lost sight of the vehicle.
        self:cutTo(self:pickNextShot(false))
    end

    return self.shot
end
