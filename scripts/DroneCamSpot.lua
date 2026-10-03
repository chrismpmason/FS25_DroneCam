---@class DroneCamSpot
---Checks candidate positions for the fixed-point shots: the camera must not be
---inside or under a tree or building, and must be able to see the vehicle past
---terrain, trees and buildings.
DroneCamSpot = {}

---How far above a spot to look for a canopy or roof. Anything found between
---there and the spot means the spot is inside or underneath it.
DroneCamSpot.OVERHEAD_CHECK = 40

---Nothing may be this close to the spot sideways, so the camera is never
---tucked against a trunk or a wall.
DroneCamSpot.SIDE_CLEARANCE = 2

---Sight lines are also checked against the terrain every this many metres,
---since a raycast can graze past a ridge.
DroneCamSpot.TERRAIN_SAMPLE_STEP = 8
DroneCamSpot.TERRAIN_SIGHT_MARGIN = 0.5

local obstacleMask = nil
local sightMask = nil

---@return integer, integer @Masks for "something solid here" and "something blocking the view"
local function getMasks()
    if obstacleMask == nil then
        obstacleMask = CollisionFlag.STATIC_OBJECT + CollisionFlag.BUILDING + CollisionFlag.TREE
        sightMask = obstacleMask + CollisionFlag.TERRAIN
    end
    return obstacleMask, sightMask
end

---@return boolean @True if the ray hits anything in the mask
local function getIsHit(x, y, z, dirX, dirY, dirZ, distance, mask)
    local hitId = RaycastUtil.raycastClosest(x, y, z, dirX, dirY, dirZ, distance, mask)
    return hitId ~= nil and hitId ~= 0
end

local function getTerrainHeight(x, z)
    local terrainNode = g_currentMission ~= nil and g_currentMission.terrainRootNode or g_terrainNode
    if terrainNode == nil then
        return 0
    end
    return getTerrainHeightAtWorldPos(terrainNode, x, 0, z)
end

---@param groundMargin number|nil @How far above the terrain the spot must be; TERRAIN_SIGHT_MARGIN by default
---@return boolean @True if the camera could stand here: not inside, under or against anything
function DroneCamSpot.getIsSpotClear(x, y, z, groundMargin)
    local mask = getMasks()

    if y < getTerrainHeight(x, z) + (groundMargin or DroneCamSpot.TERRAIN_SIGHT_MARGIN) then
        return false
    end

    local above = DroneCamSpot.OVERHEAD_CHECK
    if getIsHit(x, y + above, z, 0, -1, 0, above, mask) then
        return false
    end

    local reach = DroneCamSpot.SIDE_CLEARANCE
    if getIsHit(x, y, z, 1, 0, 0, reach, mask) or getIsHit(x, y, z, -1, 0, 0, reach, mask)
        or getIsHit(x, y, z, 0, 0, 1, reach, mask) or getIsHit(x, y, z, 0, 0, -1, reach, mask) then
        return false
    end

    return true
end

---@param terrainMargin number|nil @Clearance the line must keep over the terrain; TERRAIN_SIGHT_MARGIN by default
---@return boolean @True if nothing solid lies between the two points
function DroneCamSpot.getHasLineOfSight(x, y, z, targetX, targetY, targetZ, terrainMargin)
    local _, mask = getMasks()
    local dx, dy, dz = targetX - x, targetY - y, targetZ - z
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

    if distance < 1 then
        return true
    end

    local inv = 1 / distance
    -- Stop just short of the target: the ray would otherwise hit the ground
    -- the vehicle stands on.
    if getIsHit(x, y, z, dx * inv, dy * inv, dz * inv, distance - 1, mask) then
        return false
    end

    local samples = math.floor(distance / DroneCamSpot.TERRAIN_SAMPLE_STEP)
    for i = 1, samples - 1 do
        local f = i / samples
        local px, py, pz = x + dx * f, y + dy * f, z + dz * f
        if py < getTerrainHeight(px, pz) + (terrainMargin or DroneCamSpot.TERRAIN_SIGHT_MARGIN) then
            return false
        end
    end

    return true
end

---How far up a vehicle's underside is above a point on the ground, from an
---upward raycast against vehicle collision.
---@param maxHeight number @How far up to look
---@return number|nil @Clearance in metres, maxHeight if nothing is there, nil if raycasts are unavailable
---@return integer|nil @The collision shape it hit, if any
function DroneCamSpot.getVehicleClearance(x, groundY, z, maxHeight)
    if RaycastUtil == nil or RaycastUtil.raycastClosest == nil or CollisionFlag == nil then
        return nil
    end

    local start = 0.02
    local hitId, _, _, _, distance = RaycastUtil.raycastClosest(x, groundY + start, z, 0, 1, 0, maxHeight, CollisionFlag.VEHICLE)
    if hitId == nil or hitId == 0 or distance == nil then
        return maxHeight, nil
    end
    return distance + start, hitId
end

---@return boolean @A clear spot with a clear view of the target
function DroneCamSpot.getIsGoodSpot(x, y, z, targetX, targetY, targetZ)
    return DroneCamSpot.getIsSpotClear(x, y, z) and DroneCamSpot.getHasLineOfSight(x, y, z, targetX, targetY, targetZ)
end
