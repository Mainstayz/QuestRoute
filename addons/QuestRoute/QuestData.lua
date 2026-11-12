-- 原生任务日志、玩家上下文、任务 POI 及客户端优先的详情 API。
local _, ns = ...
local Util = ns.Util
local InvalidArguments, IsFinite, IsID, Accessible = Util.InvalidArguments, Util.IsFinite, Util.IsID, Util.Accessible
local ParsePage, AddPage, ToWorld = Util.ParsePage, Util.AddPage, Util.ToWorld
local GetDatabase, ReadDatabaseQuest = ns.Database.Get, ns.Database.ReadQuest

local function ReadQuest(info, category, includeObjectives)
    local questID = info.questID
    local isComplete = C_QuestLog.IsComplete(questID)
    local isFailed = C_QuestLog.IsFailed(questID)
    local readyForTurnIn = C_QuestLog.ReadyForTurnIn(questID)
    local status = "in_progress"
    if isFailed then
        status = "failed"
    elseif readyForTurnIn then
        status = "ready_for_turn_in"
    elseif isComplete then
        status = "complete"
    end

    local quest = {
        questID = questID,
        title = info.title,
        category = category,
        logIndex = info.questLogIndex,
        level = info.level,
        suggestedGroup = info.suggestedGroup,
        frequency = info.frequency,
        classification = info.questClassification,
        isHidden = info.isHidden,
        isTask = info.isTask,
        isStory = info.isStory,
        isComplete = isComplete,
        isFailed = isFailed,
        readyForTurnIn = readyForTurnIn,
        status = status,
    }

    local tag = C_QuestLog.GetQuestTagInfo(questID)
    if tag then
        quest.tag = { id = tag.tagID, name = tag.tagName, isElite = tag.isElite, tradeskillLineID = tag.tradeskillLineID }
    end

    if includeObjectives then
        local rawObjectives = C_QuestLog.GetQuestObjectives(questID)
        quest.objectivesLoaded = rawObjectives ~= nil
        quest.objectives = {}
        for index, objective in ipairs(rawObjectives or {}) do
            quest.objectives[index] = {
                index = index,
                text = objective.text,
                type = objective.type,
                objectiveType = objective.objectiveType,
                finished = objective.finished,
                numFulfilled = objective.numFulfilled,
                numRequired = objective.numRequired,
            }
        end
    end
    return quest
end

-- 供其他 Lua 代码调用：WoWBridgeNS.QuestRoute.GetQuests({ ... })。
-- offset 为从 0 开始的偏移，limit 默认为 100；每次调用都重新读取角色当前日志。
function ns.GetQuests(args)
    if args == nil then args = {} end
    if type(args) ~= "table" then
        return InvalidArguments("args must be an object")
    end

    local offset = args.offset
    if offset == nil then offset = 0 end
    local limit = args.limit
    if limit == nil then limit = 100 end
    if type(offset) ~= "number" or offset < 0 or offset % 1 ~= 0 then
        return InvalidArguments("offset must be a non-negative integer")
    end
    if type(limit) ~= "number" or limit < 1 or limit > 100 or limit % 1 ~= 0 then
        return InvalidArguments("limit must be an integer from 1 to 100")
    end
    if args.includeObjectives ~= nil and type(args.includeObjectives) ~= "boolean" then
        return InvalidArguments("includeObjectives must be a boolean")
    end
    local includeObjectives = args.includeObjectives ~= false

    local numEntries, reportedTotal = C_QuestLog.GetNumQuestLogEntries()
    local all, category = {}, nil
    -- 本客户端的 GetInfo 可直接读取折叠分类下的任务，无需展开或修改用户界面。
    for logIndex = 1, numEntries do
        local info = C_QuestLog.GetInfo(logIndex)
        if info then
            if info.isHeader then
                category = info.title
            elseif info.questID and info.questID > 0 then
                all[#all + 1] = { info = info, category = category }
            end
        end
    end

    local quests = {}
    local lastIndex = math.min(#all, offset + limit)
    for index = offset + 1, lastIndex do
        local entry = all[index]
        quests[#quests + 1] = ReadQuest(entry.info, entry.category, includeObjectives)
    end

    local playerName = UnitName("player")
    if not canaccessvalue(playerName) then playerName = nil end
    local hasMore = offset + #quests < #all
    local result = {
        ok = true,
        schemaVersion = 1,
        scope = "active_quest_log",
        character = { name = playerName, realm = GetRealmName() },
        total = #all,
        reportedTotal = reportedTotal,
        logComplete = #all == reportedTotal,
        offset = offset,
        limit = limit,
        count = #quests,
        hasMore = hasMore,
        quests = quests,
    }
    if hasMore then result.nextOffset = offset + #quests end
    return result
end

local function ActiveQuestIndex()
    local byID, category = {}, nil
    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    for i = 1, numEntries do
        local info = C_QuestLog.GetInfo(i)
        if info then
            if info.isHeader then
                category = info.title
            elseif IsID(info.questID) then
                byID[info.questID] = { info = info, category = category }
            end
        end
    end
    return byID
end

function ns.GetPlayerContext(args)
    if args ~= nil and type(args) ~= "table" then return InvalidArguments("args must be an object") end
    local mapID = Accessible(C_Map.GetBestMapForUnit("player"))
    local mapInfo = IsID(mapID) and C_Map.GetMapInfo(mapID) or nil
    local position = mapInfo and C_Map.GetPlayerMapPosition(mapID, "player") or nil
    local x, y = position and Accessible(position.x), position and Accessible(position.y)
    local hasPosition = IsFinite(x) and IsFinite(y) and x >= 0 and x <= 1 and y >= 0 and y <= 1
    local xp, maxXP = Accessible(UnitXP("player")), Accessible(UnitXPMax("player"))
    local character = {
        name = Accessible(UnitName("player")), realm = GetRealmName(),
        level = Accessible(UnitLevel("player")), faction = Accessible(UnitFactionGroup("player")),
    }
    local result = {
        ok = true, schemaVersion = 1, apiRevision = ns.apiRevision, source = "client",
        character = character,
        experience = { current = xp, maximum = maxXP, rested = Accessible(GetXPExhaustion()) },
        location = {
            available = hasPosition, coordinateMapID = mapID, mapName = mapInfo and mapInfo.name,
            units = "normalized", source = "C_Map.GetPlayerMapPosition",
        },
    }
    if IsFinite(xp) and IsFinite(maxXP) and maxXP > 0 then result.experience.fraction = xp / maxXP end
    if hasPosition then
        result.location.x, result.location.y = x, y
        result.location.world = ToWorld(mapID, x, y)
    else
        result.location.reason = mapInfo and "position_unavailable" or "map_unavailable"
    end
    return result
end

-- 地图 POI 的 x/y 属于查询地图，不一定属于返回项的 mapID。
local function SamePOI(a, b)
    if a.questID ~= b.questID or a.isQuestStart ~= b.isQuestStart
        or a.isMeta ~= b.isMeta or a.isMapIndicatorQuest ~= b.isMapIndicatorQuest then return false end
    if a.world and b.world and a.world.continentID == b.world.continentID then
        local dx, dy = a.world.x - b.world.x, a.world.y - b.world.y
        return math.sqrt(dx * dx + dy * dy) <= 0.1
    end
    return a.coordinateMapID == b.coordinateMapID
        and a.reportedMapID == b.reportedMapID and a.x == b.x and a.y == b.y
end

local function CollectPOIs(args, active)
    local maps, seenMaps = {}, {}
    local scope = { kind = "single_map", mapID = args.mapID }
    if args.mapID then
        maps[1] = args.mapID
    else
        scope = { kind = "map_tree", rootMapID = 947, includesAllInstanceMaps = false }
        for _, info in ipairs(C_Map.GetMapChildrenInfo(947, nil, true) or {}) do
            if IsID(info.mapID) and not seenMaps[info.mapID] then
                maps[#maps + 1] = info.mapID
                seenMaps[info.mapID] = true
            end
        end
        table.sort(maps)
    end
    local raw, points, byQuest, rawCount, unusableCount = {}, {}, {}, 0, 0
    for _, queryMapID in ipairs(maps) do
        for _, poi in ipairs(C_QuestLog.GetQuestsOnMap(queryMapID) or {}) do
            if IsID(poi.questID) and active[poi.questID] and (not args.questID or poi.questID == args.questID) then
                rawCount = rawCount + 1
                if IsFinite(poi.x) and IsFinite(poi.y) and poi.x >= 0 and poi.x <= 1 and poi.y >= 0 and poi.y <= 1 then
                    local point = {
                        questID = poi.questID, coordinateMapID = queryMapID, reportedMapID = poi.mapID,
                        x = poi.x, y = poi.y, units = "normalized", precision = "quest_poi",
                        source = "C_QuestLog.GetQuestsOnMap", numObjectives = poi.numObjectives,
                        isQuestStart = poi.isQuestStart, inProgress = poi.inProgress,
                        isDaily = poi.isDaily, isMeta = poi.isMeta,
                        isCombatAllyQuest = poi.isCombatAllyQuest,
                        isMapIndicatorQuest = poi.isMapIndicatorQuest,
                        world = ToWorld(queryMapID, poi.x, poi.y),
                    }
                    point.worldAvailable = point.world ~= nil
                    if not point.worldAvailable then point.worldUnavailableReason = "conversion_unavailable" end
                    raw[#raw + 1] = point
                else
                    unusableCount = unusableCount + 1
                end
            end
        end
    end
    -- 先确定固定代表点，再去重；合并时不移动代表点，避免链式近邻误合并。
    table.sort(raw, function(a, b)
        if a.questID ~= b.questID then return a.questID < b.questID end
        local aNative, bNative = a.coordinateMapID == a.reportedMapID, b.coordinateMapID == b.reportedMapID
        if aNative ~= bNative then return aNative end
        if a.coordinateMapID ~= b.coordinateMapID then return a.coordinateMapID < b.coordinateMapID end
        if a.x ~= b.x then return a.x < b.x end
        return a.y < b.y
    end)
    for _, point in ipairs(raw) do
        local candidates = byQuest[point.questID] or {}
        local existing
        for _, candidate in ipairs(candidates) do
            if SamePOI(candidate, point) then existing = candidate; break end
        end
        if existing then
            existing.projectionCount = existing.projectionCount + 1
            existing.queryMapIDs[#existing.queryMapIDs + 1] = point.coordinateMapID
        else
            point.projectionCount, point.queryMapIDs = 1, { point.coordinateMapID }
            points[#points + 1] = point
            candidates[#candidates + 1] = point
            byQuest[point.questID] = candidates
        end
    end
    table.sort(points, function(a, b)
        if a.questID ~= b.questID then return a.questID < b.questID end
        if a.coordinateMapID ~= b.coordinateMapID then return a.coordinateMapID < b.coordinateMapID end
        if a.x ~= b.x then return a.x < b.x end
        return a.y < b.y
    end)
    scope.scannedMaps = #maps
    return points, { mapScope = scope, rawCount = rawCount, unusableCount = unusableCount }
end

function ns.GetQuestPOIs(args)
    if args == nil then args = {} end
    if type(args) ~= "table" then return InvalidArguments("args must be an object") end
    if args.mapID ~= nil and not IsID(args.mapID) then return InvalidArguments("mapID must be a positive integer") end
    if args.questID ~= nil and not IsID(args.questID) then return InvalidArguments("questID must be a positive integer") end
    local page, message = ParsePage(args)
    if not page then return InvalidArguments(message) end
    if args.mapID and not C_Map.GetMapInfo(args.mapID) then return InvalidArguments("mapID is not a client map") end
    local active = ActiveQuestIndex()
    local points, meta = CollectPOIs(args, active)
    local result = {
        ok = true, schemaVersion = 1, apiRevision = ns.apiRevision, source = "client",
        scope = "active_quest_log", mapScope = meta.mapScope,
        rawCount = meta.rawCount, unusableCount = meta.unusableCount,
    }
    if args.questID and not active[args.questID] then result.reason = "quest_not_in_log" end
    return AddPage(result, points, page, "pois")
end

function ns.GetQuestDetails(args)
    if type(args) ~= "table" or not IsID(args.questID) then return InvalidArguments("questID must be a positive integer") end
    if args.allowDatabase ~= nil and type(args.allowDatabase) ~= "boolean" then return InvalidArguments("allowDatabase must be a boolean") end
    if args.includePOIs ~= nil and type(args.includePOIs) ~= "boolean" then return InvalidArguments("includePOIs must be a boolean") end
    local page, message = ParsePage(args)
    if not page then return InvalidArguments(message) end
    local active = ActiveQuestIndex()
    local entry = active[args.questID]
    local official = { available = entry ~= nil, source = "client", inLog = entry ~= nil }
    if entry then official.quest = ReadQuest(entry.info, entry.category, true) else official.reason = "quest_not_in_log" end
    if args.includePOIs ~= false then
        local pois, meta = CollectPOIs({ questID = args.questID }, active)
        official.pois, official.poiCoverage = pois, meta.mapScope
        official.poiRawCount = meta.rawCount
    end
    local database
    if args.allowDatabase == false then
        database = { available = false, source = "QuestieDB", reason = "disabled_by_request" }
    else
        local db, info = GetDatabase()
        database = info
        if db then
            local ok, supplemental = pcall(ReadDatabaseQuest, db, info, args.questID, page)
            if ok then database = supplemental else
                database = { available = false, source = "QuestieDB", reason = "database_error", message = tostring(supplemental) }
            end
        end
    end
    return {
        ok = true, schemaVersion = 1, apiRevision = ns.apiRevision, questID = args.questID,
        policy = "client_first", official = official, database = database,
    }
end

ns.QuestData = { ReadQuest = ReadQuest, ActiveQuestIndex = ActiveQuestIndex, CollectPOIs = CollectPOIs }
