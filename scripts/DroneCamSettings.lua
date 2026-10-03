---@class DroneCamSettings
---Holds every tunable value for the drone camera and persists them to
---modSettings/FS25_DroneCam.xml so they survive a restart and are shared
---between savegames.
DroneCamSettings = {}

DroneCamSettings.MODE_CHASE = 1
DroneCamSettings.MODE_TOPDOWN = 2
DroneCamSettings.MODE_ORBIT = 3
---Not an angle of its own: cuts between the three above (see DroneCamDirector).
DroneCamSettings.MODE_AUTO = 4
DroneCamSettings.MODE_FIRST = 1
DroneCamSettings.MODE_LAST = 4

---Close-up angles. These are not modes: only the Auto director uses them, so
---they sit outside the MODE_FIRST..MODE_LAST range that Ctrl+C cycles through.
DroneCamSettings.SHOT_WHEEL = 5
DroneCamSettings.SHOT_IMPLEMENT = 6
DroneCamSettings.SHOT_SIDE = 7
DroneCamSettings.SHOT_FRONT = 8
DroneCamSettings.SHOT_REAR_QUARTER = 9

DroneCamSettings.MODE_L10N = {
    [DroneCamSettings.MODE_CHASE] = "droneCam_mode_chase",
    [DroneCamSettings.MODE_TOPDOWN] = "droneCam_mode_topDown",
    [DroneCamSettings.MODE_ORBIT] = "droneCam_mode_orbit",
    [DroneCamSettings.MODE_AUTO] = "droneCam_mode_auto"
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
