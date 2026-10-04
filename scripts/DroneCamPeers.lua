---@class DroneCamPeers
---Keeps track of the other vehicles around the one being filmed: combines,
---tractors with trailers or chaser bins, hired helpers and other players'
---vehicles working the same field; which tractor and trailer is coming to a
---combine; and whether a combine is unloading, and into what.
---
---The game's vehicle list is scanned twice a second rather than every frame.
---Everything here is read-only and client-side, like the rest of the mod: in
---multiplayer it reads what the game already shows every player (a pipe
---running, a tool lowered, a vehicle moving).
DroneCamPeers = {}

local DroneCamPeers_mt = Class(DroneCamPeers)

---Other vehicles further away than this are ignored.
DroneCamPeers.RADIUS = 250
---Vehicles this close are kept out of the camera, whatever the shot.
DroneCamPeers.BOX_RADIUS = 80
DroneCamPeers.SCAN_INTERVAL = 0.5
---Moving faster than this counts as moving, in m/s.
DroneCamPeers.MOVING_SPEED = 0.5
---A trailer this close to a combine's pipe end is taken to be the one it is
---unloading into, when the game does not say which (it only knows on the
---server).
DroneCamPeers.UNLOAD_TARGET_RANGE = 15
---Unloading counts as carrying on through pauses this short, so a pipe that
---stutters does not chop the shot up.
DroneCamPeers.UNLOAD_GRACE = 1.5
---A tractor with a trailer within this distance of a working combine, and
---getting closer at more than CLOSING_SPEED, is coming to it.
DroneCamPeers.HAULER_RANGE = 200
DroneCamPeers.CLOSING_SPEED = 0.5
---The line between two vehicles is sampled this often to decide whether they
---are in the same field; a few samples off the field (a track across it) are
---allowed.
DroneCamPeers.FIELD_SAMPLE_STEP = 10
DroneCamPeers.FIELD_OFF_ALLOWANCE = 0.2
---Used for "same field" when the game cannot say what is field.
DroneCamPeers.NO_FIELD_RADIUS = 150

function DroneCamPeers.new()
    local self = setmetatable({}, DroneCamPeers_mt)
    self:reset()
    return self
end

function DroneCamPeers:reset()
    self.timer = math.huge
    self.peers = {}
    self.nearby = {}
    self.lastPositions = {}
    self.lastGaps = {}
    self.unloading = nil
    self.unloadingSeenAt = nil
    self.time = 0
end

---@return table @Root vehicles the game knows about
local function getAllVehicles()
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    if system == nil or system.vehicles == nil then
        return {}
    end

    local list = {}
    for _, vehicle in pairs(system.vehicles) do
        if type(vehicle) == "table" and vehicle.rootNode ~= nil
            and (vehicle.rootVehicle == nil or vehicle.rootVehicle == vehicle) and entityExists(vehicle.rootNode) then
            list[#list + 1] = vehicle
        end
    end
    return list
end

local function getChildren(vehicle)
    if vehicle.getChildVehicles ~= nil then
        return vehicle:getChildVehicles()
    end
    return { vehicle }
end

---@return table|nil @The first vehicle in the combination that passes the test
local function findChild(vehicle, test)
    local children = getChildren(vehicle)
    for i = 1, #children do
        if test(children[i]) then
            return children[i]
        end
    end
    return nil
end

---@return boolean
function DroneCamPeers.getIsCombine(vehicle)
    return findChild(vehicle, function(child) return child.spec_combine ~= nil end) ~= nil
end

---Tractors with a trailer or tipper body, and chaser bins (a pipe and a load,
---but no thresher).
---@return boolean
function DroneCamPeers.getIsHauler(vehicle)
    if DroneCamPeers.getIsCombine(vehicle) then
        return false
    end
    return findChild(vehicle, function(child)
        return child.spec_trailer ~= nil or (child.spec_pipe ~= nil and child.spec_fillUnit ~= nil)
    end) ~= nil
end

---@return table|nil @The part of a hauler that takes the load (its trailer), or the vehicle itself
function DroneCamPeers.getLoadCarrier(vehicle)
    return findChild(vehicle, function(child)
        return child ~= vehicle and (child.spec_trailer ~= nil or child.spec_fillUnit ~= nil)
    end) or vehicle
end

local function getIsTurnedOn(vehicle)
    return findChild(vehicle, function(child)
        return child.getIsTurnedOn ~= nil and child:getIsTurnedOn() == true
    end) ~= nil
end

local function getIsAnyLowered(vehicle)
    return findChild(vehicle, function(child)
        return child ~= vehicle and DroneCamKit.getIsLowered(child) == true
            and DroneCamKit.LOWERING_MATTERS[(DroneCamKit.getKind(child))] == true
    end) ~= nil
end

---@return string @What a vehicle is, for the overlay
function DroneCamPeers.getLabel(vehicle)
    if DroneCamPeers.getIsCombine(vehicle) then
        return "combine"
    elseif DroneCamPeers.getIsHauler(vehicle) then
        return "tractor and trailer"
    end
    return "vehicle"
end

---Whether a combine is unloading, and where.
---@return table|nil, table|nil @Discharge node, target root vehicle (nil if the game does not say)
function DroneCamPeers.getUnloadState(combine)
    local unloader = findChild(combine, function(child) return child.spec_dischargeable ~= nil end)
    if unloader == nil or unloader.getCurrentDischargeNode == nil then
        return nil, nil
    end

    local node = unloader:getCurrentDischargeNode()
    if node == nil or node.node == nil or not entityExists(node.node) then
        return nil, nil
    end

    -- The pipe's effect is what every player sees; the discharge state is
    -- the server's own record.
    local state = unloader.getDischargeState ~= nil and unloader:getDischargeState() or nil
    local objectState = Dischargeable ~= nil and Dischargeable.DISCHARGE_STATE_OBJECT or nil
    local isActive = node.isEffectActive == true or (objectState ~= nil and state == objectState)
    if not isActive then
        return nil, nil
    end

    local target = node.dischargeObject
    if target ~= nil and target.rootVehicle ~= nil then
        target = target.rootVehicle
    end
    return node, target
end

---@return boolean @True if the two points look to be in the same field
function DroneCamPeers.getIsSameField(ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local distance = math.sqrt(dx * dx + dz * dz)
    local onA = DroneCamField.getIsOnField(ax, az)

    if onA == nil then
        return distance <= DroneCamPeers.NO_FIELD_RADIUS
    end
    if onA ~= true or DroneCamField.getIsOnField(bx, bz) ~= true then
        return false
    end

    local samples = math.max(math.floor(distance / DroneCamPeers.FIELD_SAMPLE_STEP), 1)
    local off = 0
    for i = 1, samples - 1 do
        local f = i / samples
        if DroneCamField.getIsOnField(ax + dx * f, az + dz * f) ~= true then
            off = off + 1
        end
    end
    return off <= samples * DroneCamPeers.FIELD_OFF_ALLOWANCE
end

---Rescans every SCAN_INTERVAL seconds.
---@param vehicle table @The vehicle being filmed
function DroneCamPeers:update(dtSeconds, vehicle)
    self.time = self.time + dtSeconds
    self.timer = self.timer + dtSeconds
    if self.timer < DroneCamPeers.SCAN_INTERVAL or vehicle == nil or vehicle.rootNode == nil then
        return
    end
    local interval = self.timer
    self.timer = 0
    local isFresh = interval < 2 * DroneCamPeers.SCAN_INTERVAL + 0.5

    local vx, _, vz = getWorldTranslation(vehicle.rootNode)
    local peers, nearby, positions = {}, {}, {}

    for _, other in ipairs(getAllVehicles()) do
        if other ~= vehicle then
            local x, _, z = getWorldTranslation(other.rootNode)
            local distance = math.sqrt((x - vx) ^ 2 + (z - vz) ^ 2)

            if distance <= DroneCamPeers.BOX_RADIUS then
                nearby[#nearby + 1] = other
            end

            if distance <= DroneCamPeers.RADIUS then
                local last = self.lastPositions[other]
                local speed = 0
                if last ~= nil and isFresh then
                    speed = math.sqrt((x - last[1]) ^ 2 + (z - last[2]) ^ 2) / interval
                end
                positions[other] = { x, z }

                local isMoving = speed > DroneCamPeers.MOVING_SPEED
                -- A hired worker, Courseplay or AutoDrive job counts, like the
                -- player's own vehicle under one.
                local isWorking = DroneCamWorkDetect.getIsVehicleWorking(other, true)
                    or DroneCamWorkDetect.getIsAIJobActive(other)
                    or (isMoving and (getIsTurnedOn(other) or getIsAnyLowered(other)))

                peers[#peers + 1] = {
                    vehicle = other, x = x, z = z, distance = distance, speed = speed,
                    isMoving = isMoving, isWorking = isWorking,
                    isCombine = DroneCamPeers.getIsCombine(other),
                    isHauler = DroneCamPeers.getIsHauler(other),
                    isSameField = DroneCamPeers.getIsSameField(vx, vz, x, z)
                }
            end
        end
    end

    self.peers, self.nearby, self.lastPositions = peers, nearby, positions
    self:updateApproaches(vehicle, vx, vz, interval, isFresh)
    self:updateUnloading(vehicle)
end

---@return table|nil @Peer entry for a vehicle
function DroneCamPeers:getPeer(vehicle)
    for i = 1, #self.peers do
        if self.peers[i].vehicle == vehicle then
            return self.peers[i]
        end
    end
    return nil
end

---The vehicles that count for the multi-vehicle shots: in the same field and
---either working or (for haulers) moving.
---@return table
function DroneCamPeers:getActive()
    local list = {}
    for i = 1, #self.peers do
        local peer = self.peers[i]
        if peer.isSameField and (peer.isWorking or (peer.isHauler and peer.isMoving)) then
            list[#list + 1] = peer
        end
    end
    return list
end

---For each hauler: the working combine nearest it (the filmed vehicle
---included) and how fast the gap is closing.
function DroneCamPeers:updateApproaches(vehicle, vx, vz, interval, isFresh)
    local combines = {}
    if DroneCamPeers.getIsCombine(vehicle) then
        combines[1] = { vehicle = vehicle, x = vx, z = vz }
    end
    local haulers = {}
    if DroneCamPeers.getIsHauler(vehicle) then
        haulers[1] = { vehicle = vehicle, x = vx, z = vz }
    end
    for _, peer in ipairs(self:getActive()) do
        if peer.isCombine and peer.isWorking then
            combines[#combines + 1] = peer
        elseif peer.isHauler then
            haulers[#haulers + 1] = peer
        end
    end

    local gaps, approaches = {}, {}
    for _, hauler in ipairs(haulers) do
        local best, bestGap = nil, math.huge
        for _, combine in ipairs(combines) do
            local gap = math.sqrt((hauler.x - combine.x) ^ 2 + (hauler.z - combine.z) ^ 2)
            if gap < bestGap then
                best, bestGap = combine, gap
            end
        end
        if best ~= nil and bestGap <= DroneCamPeers.HAULER_RANGE then
            local key = hauler.vehicle
            gaps[key] = { combine = best.vehicle, gap = bestGap }
            local last = self.lastGaps[key]
            local closing = 0
            if last ~= nil and last.combine == best.vehicle and isFresh then
                closing = (last.gap - bestGap) / interval
            end
            if closing > DroneCamPeers.CLOSING_SPEED then
                approaches[#approaches + 1] = { combine = best.vehicle, hauler = hauler.vehicle, gap = bestGap, closing = closing }
            end
        end
    end
    self.lastGaps = gaps
    self.approaches = approaches
end

---A tractor and trailer coming to a working combine, with the filmed vehicle
---one of the two.
---@return table|nil @{combine, hauler, gap, closing}
function DroneCamPeers:getApproach(vehicle)
    for _, approach in ipairs(self.approaches or {}) do
        if approach.combine == vehicle or approach.hauler == vehicle then
            return approach
        end
    end
    return nil
end

---The other vehicle a two-shot pairs the filmed one with: for a combine, the
---nearest tractor and trailer; for a tractor and trailer, the nearest
---combine; otherwise the nearest vehicle working the field.
---@param maxGap number @Further apart than this they are not working together
---@return table|nil @Peer entry
function DroneCamPeers:getPartner(vehicle, maxGap)
    local isCombine = DroneCamPeers.getIsCombine(vehicle)
    local isHauler = DroneCamPeers.getIsHauler(vehicle)
    local best, bestScore = nil, math.huge
    for _, peer in ipairs(self:getActive()) do
        if peer.distance <= maxGap then
            local score = peer.distance
            local isMatch = (isCombine and peer.isHauler) or (isHauler and peer.isCombine)
            if not isMatch then
                -- Any working vehicle will do, but a natural pair comes first.
                score = score + maxGap
            end
            if score < bestScore then
                best, bestScore = peer, score
            end
        end
    end
    return best
end

---Finds a combine that is unloading into a trailer, where the vehicle being
---filmed is the combine, the trailer, or in the same field. A combine counts
---whether or not it is still harvesting (they often stop to unload).
function DroneCamPeers:updateUnloading(vehicle)
    local combines = {}
    if DroneCamPeers.getIsCombine(vehicle) then
        combines[1] = vehicle
    end
    for _, peer in ipairs(self.peers) do
        if peer.isCombine and peer.isSameField then
            combines[#combines + 1] = peer.vehicle
        end
    end

    local found = nil
    for _, combine in ipairs(combines) do
        local node, target = DroneCamPeers.getUnloadState(combine)
        if node ~= nil then
            if target == nil then
                local px, _, pz = getWorldTranslation(node.node)
                local best = DroneCamPeers.UNLOAD_TARGET_RANGE
                local candidates = { vehicle }
                for _, peer in ipairs(self.peers) do
                    candidates[#candidates + 1] = peer.vehicle
                end
                for _, candidate in ipairs(candidates) do
                    if candidate ~= combine and DroneCamPeers.getIsHauler(candidate) then
                        local carrier = DroneCamPeers.getLoadCarrier(candidate)
                        local x, _, z = getWorldTranslation(carrier.rootNode)
                        local d = math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
                        if d < best then
                            best, target = d, candidate
                        end
                    end
                end
            end

            if target ~= nil and target ~= combine and target.rootNode ~= nil and entityExists(target.rootNode) then
                found = { combine = combine, trailer = target, pipeNode = node.node }
                break
            end
        end
    end

    if found ~= nil then
        if self.unloading ~= nil and self.unloading.combine == found.combine and self.unloading.trailer == found.trailer then
            self.unloading.pipeNode = found.pipeNode
        else
            self.unloading = found
        end
        self.unloadingSeenAt = self.time
    elseif self.unloading ~= nil and (self.unloadingSeenAt == nil
        or self.time - self.unloadingSeenAt > DroneCamPeers.UNLOAD_GRACE
        or not entityExists(self.unloading.combine.rootNode) or not entityExists(self.unloading.trailer.rootNode)) then
        self.unloading = nil
    end
end

---@return table|nil @{combine, trailer, pipeNode} while a combine is unloading
---    and the filmed vehicle is one of the two or in the same field
function DroneCamPeers:getUnloading()
    return self.unloading
end

---@return string @What the scan found, for the debug overlay
function DroneCamPeers:describe()
    local active = self:getActive()
    local parts = {}
    for i = 1, math.min(#active, 4) do
        parts[#parts + 1] = ("%s %.0fm"):format(DroneCamPeers.getLabel(active[i].vehicle), active[i].distance)
    end
    local text = #active == 0 and "none working this field" or (("%d working this field (%s)"):format(#active, table.concat(parts, ", ")))
    if self.unloading ~= nil then
        text = text .. "; unloading"
    end
    local approach = (self.approaches or {})[1]
    if approach ~= nil then
        text = text .. ("; trailer coming to a combine, %.0fm off"):format(approach.gap)
    end
    return text
end
