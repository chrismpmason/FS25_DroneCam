---@class DroneCamKit
---What is attached decides which ground pass the camera may do. The camera
---stays on the ground until the whole train has gone over it, so:
---
---  Trailers, chaser bins, bale trailers, low loaders, muck spreaders: a
---    drive-over if the underside clears (the raycasts decide), else a
---    wheel pass.
---  Sprayers (trailed or self-propelled): always offered a drive-over, boom
---    folded or not; the boom is part of the underside the raycasts measure.
---  Slurry tankers: a drive-over only with no dribble bar or injector lowered.
---  Balers, forage wagons (anything with a pickup): always a wheel pass.
---  Mowers, rakes, tedders, drills, cultivators, ploughs and anything else
---    with a work area: a wheel pass while lowered (or when it cannot say).
---  Headers and other front tools: a drive-over only while raised.
---  A self-propelled machine working the ground itself: a wheel pass.
---
---Every unit in the train is checked. A drive-over in progress snapshots the
---fold and lowered state of each unit, so anything folding, unfolding, being
---lowered or raised (or attached or detached) during the pass is noticed.
DroneCamKit = {}

---Kit that works the ground, by specialization, with the name used in the
---reasons shown on screen. Pickups (balers, forage wagons, loader wagons) are
---always on the ground while working; the rest only while lowered.
DroneCamKit.GROUND_KIT = {
    { spec = "spec_baler", label = "baler", isPickup = true },
    { spec = "spec_forageWagon", label = "forage wagon", isPickup = true },
    { spec = "spec_pickup", label = "pickup", isPickup = true },
    { spec = "spec_mower", label = "mower" },
    { spec = "spec_windrower", label = "rake" },
    { spec = "spec_tedder", label = "tedder" },
    { spec = "spec_sowingMachine", label = "drill" },
    { spec = "spec_treePlanter", label = "tree planter" },
    { spec = "spec_plow", label = "plough" },
    { spec = "spec_cultivator", label = "cultivator" },
    { spec = "spec_weeder", label = "weeder" },
    { spec = "spec_mulcher", label = "mulcher" },
    { spec = "spec_roller", label = "roller" },
    { spec = "spec_stonePicker", label = "stone picker" }
}

---A fold animation time change bigger than this counts as folding.
DroneCamKit.FOLD_TOLERANCE = 0.001

---@return boolean @True if the vehicle has a work area that is not a ridge marker
local function getHasWorkArea(vehicle)
    local spec = vehicle.spec_workArea
    if spec == nil or spec.workAreas == nil then
        return false
    end
    for i = 1, #spec.workAreas do
        local workArea = spec.workAreas[i]
        local isRidgeMarker = WorkAreaType ~= nil and WorkAreaType.RIDGEMARKER ~= nil and workArea.type == WorkAreaType.RIDGEMARKER
        if workArea.start ~= nil and workArea.width ~= nil and workArea.height ~= nil and not isRidgeMarker then
            return true
        end
    end
    return false
end

---@return table|nil @The vehicle this one is attached to
local function getAttacherVehicle(vehicle)
    if vehicle.getAttacherVehicle ~= nil then
        return vehicle:getAttacherVehicle()
    end
    return nil
end

---@return boolean
local function getIsSlurryTanker(vehicle)
    return vehicle ~= nil and vehicle.spec_sprayer ~= nil and vehicle.spec_sprayer.isSlurryTanker == true
end

---What a unit is, for the rules.
---@return string, string @Kind ("carrier", "sprayer", "slurryTanker", "slurryTool",
---    "header", "pickup", "ground") and the name to show
function DroneCamKit.getKind(vehicle)
    -- A dribble bar or injector hangs off the tanker that feeds it (the game
    -- links them the same way, ManureBarrel); check it before its own sprayer.
    if getIsSlurryTanker(getAttacherVehicle(vehicle)) then
        return "slurryTool", "dribble bar or injector"
    end
    local sprayer = vehicle.spec_sprayer
    if sprayer ~= nil then
        if sprayer.isSlurryTanker then
            return "slurryTanker", "slurry tanker"
        elseif sprayer.isManureSpreader then
            return "carrier", "muck spreader"
        end
        return "sprayer", "sprayer"
    end
    if vehicle.spec_cutter ~= nil then
        return "header", "header"
    end
    for _, kit in ipairs(DroneCamKit.GROUND_KIT) do
        if vehicle[kit.spec] ~= nil then
            return kit.isPickup and "pickup" or "ground", kit.label
        end
    end
    if getHasWorkArea(vehicle) then
        return "ground", "implement"
    end
    if vehicle.spec_trailer ~= nil then
        return "carrier", "trailer"
    end
    if vehicle.spec_combine ~= nil then
        return "carrier", "combine"
    end
    return "carrier", "implement"
end

---@return boolean|nil @Lowered, raised (false), or nil when it cannot say
function DroneCamKit.getIsLowered(vehicle)
    if vehicle.getIsLowered == nil or getAttacherVehicle(vehicle) == nil then
        return nil
    end
    -- Kit with no way of lifting reports the default: count it as down.
    return vehicle:getIsLowered(true) == true
end

---@return number|nil @Fold animation time, or nil if it does not fold
function DroneCamKit.getFoldTime(vehicle)
    if vehicle.spec_foldable == nil or vehicle.getFoldAnimTime == nil then
        return nil
    end
    return vehicle:getFoldAnimTime()
end

---Kinds whose lowered state decides anything (anything on the front too).
DroneCamKit.LOWERING_MATTERS = { ground = true, pickup = true, header = true, slurryTool = true }

---@return string @The vehicle's XML file as the allow list matches it: the
---    part after the mods folder for a mod ("FS25_SomeTrailer/trailer.xml"),
---    the game's own path otherwise ("data/vehicles/.../trailer.xml")
function DroneCamKit.getVehicleKey(vehicle)
    local file = tostring(vehicle.configFileName or "?"):gsub("\\", "/")
    local lower = file:lower()
    local cut = nil
    local from = 1
    while true do
        local s, e = lower:find("/mods/", from, true)
        if s == nil then
            break
        end
        cut, from = e, e + 1
    end
    if cut ~= nil then
        file = file:sub(cut + 1)
    end
    return file
end

---@param allow table|nil @Entries from the settings' driveOverAllow list
---@return boolean @True if the allow list names this vehicle: its whole key,
---    the end of it ("trailer.xml" after a slash) or its mod ("FS25_SomeTrailer")
function DroneCamKit.getIsAllowed(vehicle, allow)
    if allow == nil or #allow == 0 then
        return false
    end
    local key = DroneCamKit.getVehicleKey(vehicle):lower()
    for _, entry in ipairs(allow) do
        local name = tostring(entry):gsub("\\", "/"):lower()
        if name ~= "" and (key == name or key:sub(-#name - 1) == "/" .. name or key:sub(1, #name + 1) == name .. "/") then
            return true
        end
    end
    return false
end

---Why the train rules out a drive-over (a wheel pass instead), or nil if
---the underside is all that is left to decide. Units on the allow list are
---not asked.
---@param rig table @DroneCamRig measurement; its boxes carry the vehicles
---@param isSmallFront function @(box) True for front weights and the like
---@param allow table|nil @The settings' driveOverAllow list
---@return string|nil
function DroneCamKit.getDriveOverProblem(rig, isSmallFront, allow)
    for i = 1, #rig.boxes do
        local box = rig.boxes[i]
        local unit = box.vehicle
        if unit ~= nil and not (box.isFront and isSmallFront(box)) and not (not box.isRoot and DroneCamKit.getIsAllowed(unit, allow)) then
            local kind, label = DroneCamKit.getKind(unit)
            local lowered = DroneCamKit.getIsLowered(unit)

            if kind == "pickup" then
                return label .. " picks up off the ground"
            elseif box.isRoot then
                if kind == "ground" or kind == "header" then
                    return "the vehicle works the ground itself"
                end
            elseif box.isFront then
                if lowered ~= false then
                    return label .. " lowered on the front"
                end
            elseif kind == "slurryTool" then
                if lowered ~= false then
                    return label .. " lowered"
                end
            elseif kind == "ground" or kind == "header" then
                if lowered ~= false then
                    return label .. " on the ground"
                end
            end
        end
    end
    return nil
end

---@return table @The fold and lowered state of every unit in the train
function DroneCamKit.snapshot(vehicle)
    local units = vehicle.getChildVehicles ~= nil and vehicle:getChildVehicles() or { vehicle }
    local states = {}
    for i = 1, #units do
        local unit = units[i]
        local kind, label = DroneCamKit.getKind(unit)
        states[i] = {
            vehicle = unit,
            kind = kind,
            label = unit == vehicle and "vehicle" or label,
            fold = DroneCamKit.getFoldTime(unit),
            lowered = DroneCamKit.getIsLowered(unit)
        }
    end
    return states
end

---@param rig table|nil @The measured rig, to tell what is on the front
---@param allow table|nil @The settings' driveOverAllow list
---@return string @Every unit in the train and its state, for the debug
---    overlay: lowered only where it decides anything ("n/a" on a plain
---    trailer), fold time, and each towed unit's key for the allow list
function DroneCamKit.describe(vehicle, rig, allow)
    local isFront = {}
    for _, box in ipairs(rig ~= nil and rig.boxes or {}) do
        if box.vehicle ~= nil then
            isFront[box.vehicle] = box.isFront
        end
    end

    local parts = {}
    for i, state in ipairs(DroneCamKit.snapshot(vehicle)) do
        local text = state.label
        if state.vehicle ~= vehicle then
            text = text .. " [" .. DroneCamKit.getVehicleKey(state.vehicle) .. "]"
            if DroneCamKit.getIsAllowed(state.vehicle, allow) then
                text = text .. " allowed"
            end
            local lowered = "n/a"
            if DroneCamKit.LOWERING_MATTERS[state.kind] or isFront[state.vehicle] then
                lowered = state.lowered == nil and "can't tell" or (state.lowered and "yes" or "no")
            end
            text = text .. " (lowered " .. lowered .. (state.fold ~= nil and (", fold %.2f)"):format(state.fold) or ")")
        end
        parts[i] = text
    end
    return table.concat(parts, ", ")
end

---@return string @The snapshot as a string, to tell whether anything moved
function DroneCamKit.getSignature(vehicle)
    local parts = {}
    for i, state in ipairs(DroneCamKit.snapshot(vehicle)) do
        parts[i] = ("%s:%s:%s"):format(tostring(state.vehicle), state.fold ~= nil and ("%.3f"):format(state.fold) or "-",
            tostring(state.lowered))
    end
    return table.concat(parts, "|")
end

---@param foldOnly boolean|nil @Ignore lowering and raising (beside the train they cannot reach the camera)
---@return string|nil @What has changed since the snapshot, or nil if nothing
function DroneCamKit.getChange(states, vehicle, foldOnly)
    local units = vehicle.getChildVehicles ~= nil and vehicle:getChildVehicles() or { vehicle }
    if #units ~= #states then
        return "something was attached or detached"
    end
    for i = 1, #states do
        local state = states[i]
        local unit = units[i]
        if unit ~= state.vehicle then
            return "something was attached or detached"
        end
        local fold = DroneCamKit.getFoldTime(unit)
        if state.fold ~= nil and fold ~= nil and math.abs(fold - state.fold) > DroneCamKit.FOLD_TOLERANCE then
            return state.label .. " folding or unfolding"
        end
        local lowered = DroneCamKit.getIsLowered(unit)
        if not foldOnly and lowered ~= state.lowered then
            return state.label .. (lowered and " lowered" or " raised")
        end
    end
    return nil
end
