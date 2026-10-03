---@class DroneCamSettings
---Holds every tunable value for the drone camera and persists them to
---modSettings/FS25_DroneCam.xml so they survive a restart and are shared
---between savegames.
DroneCamSettings = {}

DroneCamSettings.MODE_CHASE = 1
DroneCamSettings.MODE_TOPDOWN = 2
DroneCamSettings.MODE_ORBIT = 3
---Not angles of their own: the Auto director cuts between shots (see
---DroneCamDirector), either following a story sequence or at random.
DroneCamSettings.MODE_AUTO = 4
DroneCamSettings.MODE_AUTO_RANDOM = 5
DroneCamSettings.MODE_FIRST = 1
DroneCamSettings.MODE_LAST = 5

---@return boolean @True for either Auto director mode
function DroneCamSettings.getIsAutoMode(mode)
    return mode == DroneCamSettings.MODE_AUTO or mode == DroneCamSettings.MODE_AUTO_RANDOM
end

---Shots only the Auto director uses. They are numbered well clear of the
---MODE_FIRST..MODE_LAST range that Ctrl+C cycles through and that is saved.

-- Close-ups.
DroneCamSettings.SHOT_WHEEL = 101
DroneCamSettings.SHOT_IMPLEMENT = 102
DroneCamSettings.SHOT_SIDE = 103
DroneCamSettings.SHOT_FRONT = 104
DroneCamSettings.SHOT_REAR_QUARTER = 105

-- Creator shots that hold a framing: high over the field, or from a fixed spot.
DroneCamSettings.SHOT_ESTABLISHING = 201
DroneCamSettings.SHOT_LONG_LENS = 202
DroneCamSettings.SHOT_EDGE_PAN = 203
DroneCamSettings.SHOT_HEADLAND = 204

-- Creator shots that travel along a path over the length of the shot.
DroneCamSettings.SHOT_PUSH_IN = 211
DroneCamSettings.SHOT_PULL_OUT = 212
DroneCamSettings.SHOT_FLY_OVER = 213
DroneCamSettings.SHOT_RISE_UP = 214
DroneCamSettings.SHOT_SLIDE = 215

-- The hero shot: on the ground in the vehicle's path, letting it drive over.
DroneCamSettings.SHOT_DRIVE_OVER = 221

DroneCamSettings.MODE_L10N = {
    [DroneCamSettings.MODE_CHASE] = "droneCam_mode_chase",
    [DroneCamSettings.MODE_TOPDOWN] = "droneCam_mode_topDown",
    [DroneCamSettings.MODE_ORBIT] = "droneCam_mode_orbit",
    [DroneCamSettings.MODE_AUTO] = "droneCam_mode_auto",
    [DroneCamSettings.MODE_AUTO_RANDOM] = "droneCam_mode_autoRandom"
}

DroneCamSettings.XML_ROOT = "droneCam"
DroneCamSettings.XML_FILENAME = "modSettings/FS25_DroneCam.xml"

---Default values. Each entry is {key, type, default, min, max}; the min/max are
---also used to sanitise whatever is read back from disk, so a hand-edited file
---can never put the camera into an unusable state.
DroneCamSettings.SCHEMA = {
    { "enabled",         "bool",  true },
    { "mode",            "int",   DroneCamSettings.MODE_CHASE, DroneCamSettings.MODE_FIRST, DroneCamSettings.MODE_LAST },
    { "fov",             "float", 55,    20,  120 },
    { "startDelay",      "float", 2,     0,   60 },
    { "stopDelay",       "float", 6,     0,   60 },
    { "minClearance",    "float", 8,     1,   100 },
    { "chaseDistance",   "float", 40,    5,   200 },
    { "chaseHeight",     "float", 25,    2,   200 },
    { "chaseLookAhead",  "float", 8,     0,   100 },
    { "topDownHeight",   "float", 60,    5,   300 },
    { "topDownNorthUp",  "bool",  false },
    { "orbitRadius",     "float", 45,    5,   200 },
    { "orbitHeight",     "float", 20,    2,   200 },
    { "orbitSpeed",      "float", 6,     -90, 90 },
    { "posStiffness",    "float", 1.5,   0.1, 20 },
    { "lookStiffness",   "float", 3,     0.1, 20 },
    { "headingStiffness","float", 1,     0.1, 20 },
    { "blendTime",       "float", 1,     0,   5 },
    { "shotBlendTime",   "float", 2,     0,   10 },
    { "directorMinShot", "float", 10,    3,   120 },
    { "directorMaxShot", "float", 15,    3,   120 },
    { "closeUps",        "bool",  true },
    { "closeUpMinShot",  "float", 6,     2,   60 },
    { "closeUpMaxShot",  "float", 10,    2,   60 },
    { "movingMinShot",   "float", 7,     3,   60 },
    { "movingMaxShot",   "float", 10,    3,   60 },
    { "followAI",        "bool",  false },
    { "sway",            "bool",  true },
    { "swayAmplitude",   "float", 0.4,   0,   3 },
    { "hideHud",         "bool",  false }
}

---Creates a settings table populated with the defaults from the schema.
---@return DroneCamSettings
function DroneCamSettings.new()
    local self = {}

    for _, entry in ipairs(DroneCamSettings.SCHEMA) do
        self[entry[1]] = entry[3]
    end

    return self
end

---Clamps a numeric value to the range declared in the schema entry.
local function sanitise(entry, value)
    if value == nil then
        return nil
    end

    local minValue, maxValue = entry[4], entry[5]
    if minValue ~= nil and maxValue ~= nil then
        return math.min(math.max(value, minValue), maxValue)
    end

    return value
end

---@return string @Absolute path of the settings file
function DroneCamSettings.getXmlFilePath()
    return getUserProfileAppPath() .. DroneCamSettings.XML_FILENAME
end

local function getPathForKey(key)
    return ("%s.%s"):format(DroneCamSettings.XML_ROOT, key)
end

---Reads any previously stored settings over the top of the defaults. Missing or
---out-of-range entries keep their default, so a partial file is still usable.
---@param settings DroneCamSettings
function DroneCamSettings.restore(settings)
    local xmlPath = DroneCamSettings.getXmlFilePath()
    if not fileExists(xmlPath) then
        return
    end

    local xmlFileId = loadXMLFile("DroneCam", xmlPath)
    if xmlFileId == nil or xmlFileId == 0 then
        return
    end

    for _, entry in ipairs(DroneCamSettings.SCHEMA) do
        local key, valueType = entry[1], entry[2]
        local path = getPathForKey(key)
        local value

        if valueType == "bool" then
            value = getXMLBool(xmlFileId, path)
        elseif valueType == "int" then
            value = sanitise(entry, getXMLInt(xmlFileId, path))
        else
            value = sanitise(entry, getXMLFloat(xmlFileId, path))
        end

        if value ~= nil then
            settings[key] = value
        end
    end

    delete(xmlFileId)
end

---Writes the current settings to disk, creating modSettings/ if needed.
---@param settings DroneCamSettings
function DroneCamSettings.store(settings)
    local xmlPath = DroneCamSettings.getXmlFilePath()

    createFolder(getUserProfileAppPath() .. "modSettings")

    local xmlFileId = createXMLFile("DroneCam", xmlPath, DroneCamSettings.XML_ROOT)
    if xmlFileId == nil or xmlFileId == 0 then
        return
    end

    for _, entry in ipairs(DroneCamSettings.SCHEMA) do
        local key, valueType = entry[1], entry[2]
        local path = getPathForKey(key)
        local value = settings[key]

        if valueType == "bool" then
            setXMLBool(xmlFileId, path, value == true)
        elseif valueType == "int" then
            setXMLInt(xmlFileId, path, math.floor(value))
        else
            setXMLFloat(xmlFileId, path, value)
        end
    end

    saveXMLFile(xmlFileId)
    delete(xmlFileId)
end
