-- 静态刷新点热点聚类，以及当前 UI 会话内按目标隔离的临时地点避让。
local _, ns = ...
local DistanceSquared = ns.Util.DistanceSquared
-- 固定半径密度峰值：中心始终是真实刷新点，不用跨区域均值或单链扩张。
local hotspotRules = { radius = 150, separation = 300, maxDisplayed = 3, deduplicateRadius = 3,
    algorithm = "fixed_radius_density_real_spawn", cacheLimit = 64 }
ns.route.hotspotCache, ns.route.hotspotCacheOrder = {}, {}
ns.route.hotspotCacheHits, ns.route.hotspotCacheMisses = 0, 0

local function BuildHotspots(points, cacheKey)
    local ordered = {}
    for _, point in ipairs(points) do ordered[#ordered + 1] = point end
    table.sort(ordered, function(a, b)
        if a.world.x ~= b.world.x then return a.world.x < b.world.x end
        if a.world.y ~= b.world.y then return a.world.y < b.world.y end
        return (a.entityID or 0) < (b.entityID or 0)
    end)
    local unique, duplicateGrid = {}, {}
    local function CellKey(x, y) return x .. ":" .. y end
    for _, point in ipairs(ordered) do
        local cx, cy = math.floor(point.world.x / hotspotRules.deduplicateRadius), math.floor(point.world.y / hotspotRules.deduplicateRadius)
        local duplicate
        for dx = -1, 1 do
            for dy = -1, 1 do
                for _, other in ipairs(duplicateGrid[CellKey(cx + dx, cy + dy)] or {}) do
                    if DistanceSquared(point.world, other.world) <= hotspotRules.deduplicateRadius ^ 2 then duplicate = true; break end
                end
                if duplicate then break end
            end
            if duplicate then break end
        end
        if not duplicate then
            unique[#unique + 1] = point
            local key = CellKey(cx, cy)
            duplicateGrid[key] = duplicateGrid[key] or {}
            duplicateGrid[key][#duplicateGrid[key] + 1] = point
        end
    end
    local signatureParts = {}
    for _, point in ipairs(unique) do
        signatureParts[#signatureParts + 1] = table.concat({ point.version or "", point.reportedMapID,
            point.world.continentID, point.world.x, point.world.y, point.entityID or 0 }, ":")
    end
    local signature = table.concat(signatureParts, ";")
    local cached = ns.route.hotspotCache[cacheKey]
    if cached and cached.signature == signature then ns.route.hotspotCacheHits = ns.route.hotspotCacheHits + 1
    else
        ns.route.hotspotCacheMisses = ns.route.hotspotCacheMisses + 1
        local grid, ranked = {}, {}
        for index, point in ipairs(unique) do
            local key = CellKey(math.floor(point.world.x / hotspotRules.radius), math.floor(point.world.y / hotspotRules.radius))
            grid[key] = grid[key] or {}; grid[key][#grid[key] + 1] = index
        end
        for index, point in ipairs(unique) do
            local cx, cy = math.floor(point.world.x / hotspotRules.radius), math.floor(point.world.y / hotspotRules.radius)
            local count, spread = 0, 0
            for dx = -1, 1 do
                for dy = -1, 1 do
                    for _, otherIndex in ipairs(grid[CellKey(cx + dx, cy + dy)] or {}) do
                        local distance = DistanceSquared(point.world, unique[otherIndex].world)
                        if distance <= hotspotRules.radius ^ 2 then count, spread = count + 1, spread + distance end
                    end
                end
            end
            ranked[#ranked + 1] = { index = index, count = count, spread = spread / count }
        end
        table.sort(ranked, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            if a.spread ~= b.spread then return a.spread < b.spread end
            return a.index < b.index
        end)
        local centres = {}
        local minimum = ranked[1] and ranked[1].count >= 2 and 2 or 1
        for _, candidate in ipairs(ranked) do
            local separated = candidate.count >= minimum
            if separated then
                for _, centre in ipairs(centres) do
                    if DistanceSquared(unique[candidate.index].world, unique[centre.index].world) < hotspotRules.separation ^ 2 then
                        separated = false; break
                    end
                end
            end
            if separated then centres[#centres + 1] = candidate end
        end
        if not cached then
            if #ns.route.hotspotCacheOrder >= hotspotRules.cacheLimit then
                ns.route.hotspotCache[table.remove(ns.route.hotspotCacheOrder, 1)] = nil
            end
            ns.route.hotspotCacheOrder[#ns.route.hotspotCacheOrder + 1] = cacheKey
        end
        cached = { signature = signature, centres = centres }
        ns.route.hotspotCache[cacheKey] = cached
    end
    local result = {}
    for _, centre in ipairs(cached.centres) do
        -- 缓存只含几何索引，不保留旧进度/目标对象；每次返回当前任务快照。
        local point = unique[centre.index]
        local copy = {}
        for key, value in pairs(point) do copy[key] = value end
        copy.hotspot = { id = point.reportedMapID .. ":" .. string.format("%.3f:%.3f", point.world.x, point.world.y),
            pointCount = centre.count, uniqueLocationCount = #unique, radius = hotspotRules.radius,
            sparseFallback = centre.count == 1, algorithm = hotspotRules.algorithm }
        result[#result + 1] = copy
    end
    return result
end

local function VisibleHotspots(points, selected)
    if not selected.hotspot then return {} end
    local function Summary(point, main)
        return { id = point.hotspot.id, selected = main, pointCount = point.hotspot.pointCount,
            radius = point.hotspot.radius, sparseFallback = point.hotspot.sparseFallback,
            x = point.x, y = point.y, world = point.world, coordinateMapID = point.coordinateMapID,
            targetMapID = point.reportedMapID, source = point.source, precision = "static_hotspot" }
    end
    local alternatives = {}
    for _, point in ipairs(points) do
        if point.hotspot.id ~= selected.hotspot.id then alternatives[#alternatives + 1] = point end
    end
    table.sort(alternatives, function(a, b)
        local da, db = DistanceSquared(selected.world, a.world), DistanceSquared(selected.world, b.world)
        if da ~= db then return da < db end
        return a.hotspot.id < b.hotspot.id
    end)
    local visible = { Summary(selected, true) }
    for index = 1, math.min(#alternatives, hotspotRules.maxDisplayed - 1) do
        visible[#visible + 1] = Summary(alternatives[index], false)
    end
    return visible
end

-- 临时地点避让按任务/子目标隔离，不写入角色存档中的时间戳。
local spotRules = { radius = 150, duration = 600, maximum = 64 }
ns.route.spotAvoidances = ns.route.spotAvoidances or {}

local function SpotBlocked(point, questID, mapID, now, extra)
    local function Matches(avoid)
        local distance = DistanceSquared(point.world, avoid.world)
        return avoid.questID == questID and avoid.objectiveKey == point.objectiveKey and avoid.mapID == mapID
            and avoid.expiresAt > now and distance and distance <= spotRules.radius ^ 2
    end
    if extra and Matches(extra) then return true end
    for _, avoid in ipairs(ns.route.spotAvoidances) do if Matches(avoid) then return true end end
    return false
end

local function QuestHasAvoidance(questID, mapID, now)
    for _, avoid in ipairs(ns.route.spotAvoidances) do
        if avoid.questID == questID and avoid.mapID == mapID and avoid.expiresAt > now then return true end
    end
    return false
end

local function RetireFinishedAvoidances(quest, identities)
    if quest.status == "in_progress" and not identities.mappingComplete then return end
    local pending, kept = {}, {}
    if quest.status == "in_progress" then
        for _, objective in ipairs(identities.objectives) do if not objective.finished then pending[objective.key] = true end end
    end
    for _, avoid in ipairs(ns.route.spotAvoidances) do
        if avoid.questID ~= quest.questID or pending[avoid.objectiveKey] then kept[#kept + 1] = avoid end
    end
    ns.route.spotAvoidances = kept
end

local function PruneSpotAvoidances(active, mapID, now)
    local kept, nextCheck = {}, nil
    for _, avoid in ipairs(ns.route.spotAvoidances) do
        if active[avoid.questID] and avoid.mapID == mapID and avoid.expiresAt > now then
            kept[#kept + 1] = avoid
            nextCheck = not nextCheck and avoid.expiresAt or math.min(nextCheck, avoid.expiresAt)
        end
    end
    ns.route.spotAvoidances, ns.route.nextSpotCheck = kept, nextCheck
end

ns.Hotspots = {
    rules = hotspotRules, spotRules = spotRules, Build = BuildHotspots, Visible = VisibleHotspots,
    Blocked = SpotBlocked, HasAvoidance = QuestHasAvoidance,
    RetireFinished = RetireFinishedAvoidances, Prune = PruneSpotAvoidances,
}
