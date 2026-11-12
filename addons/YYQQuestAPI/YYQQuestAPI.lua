-- YYQ 角色任务 API：实时读取当前角色已接取的任务，不改变任务日志或追踪设置。
local addonName, ns = ...
WoWBridgeNS = WoWBridgeNS or {}
WoWBridgeNS[addonName] = ns

local WB = WoWBridge and WoWBridge.Bind and WoWBridge.Bind(addonName) or {
    Emit = function() end,
    Expose = function() end,
    Request = function(_, _, _, callback)
        callback(nil, "unavailable")
    end,
}
ns.WB = WB

local function InvalidArguments(message)
    return { ok = false, error = { code = "invalid_arguments", message = message } }
end

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

-- 供其他 Lua 代码调用：WoWBridgeNS.YYQQuestAPI.GetQuests({ ... })。
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

WB:Expose("get_quests", ns.GetQuests,
    "只读获取当前角色所有已接取任务（含折叠分类、隐藏任务和已完成待交任务）。"
    .. "args: offset>=0（默认0），limit=1..100（默认100），includeObjectives=true/false（默认true）。"
    .. "返回角色、total、reportedTotal、logComplete、count、hasMore、nextOffset 和 quests；"
    .. "每项含 questID/title/category/status 及 objectives 目标进度。"
    .. "不包含已交付任务历史或尚未接取任务。")

SLASH_YYQQUESTAPI1 = "/yyqquestapi"
SlashCmdList["YYQQUESTAPI"] = function()
    local result = ns.GetQuests({ includeObjectives = false })
    print("|cffd8a85aYYQQuestAPI|r 当前任务：" .. result.total)
    for _, quest in ipairs(result.quests) do
        print("[" .. quest.questID .. "] " .. quest.title .. " (" .. quest.status .. ")")
    end
end

-- 数据层修订 2：客户端原生数据优先，QuestieDB 仅提供独立标注的补充。
-- 动态发现数据库：不在文件加载时持有它，未安装或尚未加载也能使用原生接口。
ns.apiRevision = 13

local function IsFinite(value)
    return canaccessvalue(value) and type(value) == "number"
        and value == value and value > -math.huge and value < math.huge
end

local function IsID(value)
    return IsFinite(value) and value > 0 and value % 1 == 0
end

local function Accessible(value)
    if canaccessvalue(value) then return value end
end

local function ParsePage(args)
    local offset = args.offset
    local limit = args.limit
    if offset == nil then offset = 0 end
    if limit == nil then limit = 50 end
    if not IsFinite(offset) or offset < 0 or offset % 1 ~= 0 then
        return nil, "offset must be a non-negative integer"
    end
    if not IsID(limit) or limit > 100 then
        return nil, "limit must be an integer from 1 to 100"
    end
    return { offset = offset, limit = limit }
end

local function AddPage(result, all, page, field)
    local out = {}
    for i = page.offset + 1, math.min(#all, page.offset + page.limit) do
        out[#out + 1] = all[i]
    end
    result.total = #all
    result.offset = page.offset
    result.limit = page.limit
    result.count = #out
    result.hasMore = page.offset + #out < #all
    if result.hasMore then result.nextOffset = page.offset + #out end
    result[field] = out
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

local function ToWorld(mapID, x, y)
    if not IsID(mapID) or not IsFinite(x) or not IsFinite(y) then return nil end
    local ok, continentID, position = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))
    if ok and position and IsFinite(continentID) and IsFinite(position.x) and IsFinite(position.y) then
        return { continentID = continentID, x = position.x, y = position.y }
    end
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

local function GetDatabase()
    local db = rawget(_G, "LibQuestieDB")
    if type(db) ~= "table" then return nil, { available = false, source = "QuestieDB", reason = "not_loaded" } end
    if type(db.RequireContract) ~= "function" then
        return nil, { available = false, source = "QuestieDB", reason = "unsupported_contract" }
    end
    local called, compatible = pcall(db.RequireContract, 4)
    if not called or not compatible then
        return nil, { available = false, source = "QuestieDB", reason = "unsupported_contract" }
    end
    local name = type(db.addonName) == "string" and db.addonName or "QuestieDB"
    local metadataOK, version = pcall(C_AddOns.GetAddOnMetadata, name, "Version")
    return db, {
        available = true, source = "QuestieDB", contract = db.contractVersion,
        version = metadataOK and version or nil,
    }
end

local cachedDB, cachedBase, cachedOverride, cachedMapping
local function AreaMapping(db)
    local support = db.Support and db.Support.Get and db.Support.Get("ZoneDB")
    local private = support and support.private or {}
    local base, override = private.areaIdToUiMapId, private.areaIdToUiMapIdOverride
    if cachedDB == db and cachedBase == base and cachedOverride == override then return cachedMapping end
    local mapping = {}
    for _, value in ipairs({ base or false, override or false }) do
        if type(value) == "string" then
            -- 只接受数字赋值行，不执行数据库中的字符串。
            for line in value:gmatch("[^\r\n]+") do
                local area, map = line:match("^%s*%[(%d+)%]%s*=%s*(%d+)")
                if area then mapping[tonumber(area)] = tonumber(map) end
            end
        elseif type(value) == "table" then
            for area, map in pairs(value) do
                if IsFinite(area) and IsFinite(map) then mapping[area] = map end
            end
        end
    end
    cachedDB, cachedBase, cachedOverride, cachedMapping = db, base, override, mapping
    return mapping
end

local function ReadLocations(db, entity, id)
    local mapping, locations = AreaMapping(db), {}
    local spawns = entity.spawns(id) or {}
    local areas = {}
    for area in pairs(spawns) do if IsFinite(area) then areas[#areas + 1] = area end end
    table.sort(areas)
    local usable = 0
    for _, area in ipairs(areas) do
        for index, position in ipairs(spawns[area]) do
            local x, y = position[1], position[2]
            local mapID = mapping[area]
            local mapInfo = IsID(mapID) and C_Map.GetMapInfo(mapID) or nil
            local location = {
                areaID = area, spawnIndex = index, coordinateMapID = mapID,
                originalX = x, originalY = y, originalUnits = "percent",
                phase = position[3], source = "QuestieDB", available = false,
            }
            if x == -1 and y == -1 then
                location.reason, location.precision = "instance_only", "instance_area"
            elseif not IsFinite(x) or not IsFinite(y) or x < 0 or y < 0 or x > 100 or y > 100 then
                location.reason = "invalid_coordinates"
            elseif not mapID then
                location.reason = "map_mapping_missing"
            elseif mapID == 0 then
                location.reason = "map_suppressed"
            elseif not mapInfo then
                location.reason = "unsupported_map"
            else
                location.available, location.precision = true, "static_spawn"
                location.x, location.y, location.units = x / 100, y / 100, "normalized"
                location.mapName = mapInfo.name
                location.world = ToWorld(mapID, location.x, location.y)
                usable = usable + 1
            end
            locations[#locations + 1] = location
        end
    end
    return locations, usable
end

local function ReadDatabaseEntity(db, info, args, page)
    local entity = args.kind == "npc" and db.Npc or args.kind == "object" and db.Object or db.Item
    if not entity or not entity.Exists(args.id) then
        return { ok = true, schemaVersion = 1, available = false, source = "QuestieDB", reason = "entity_not_found", kind = args.kind, id = args.id }
    end
    local result = {
        ok = true, schemaVersion = 1, apiRevision = ns.apiRevision, available = true,
        source = "QuestieDB", version = info.version, contract = info.contract,
        kind = args.kind, id = args.id, name = entity.name(args.id),
    }
    if args.kind == "item" then
        local relations = {}
        local fields = {
            { "npcDrops", "npc", "drop" }, { "objectDrops", "object", "drop" },
            { "itemDrops", "item", "container" }, { "vendors", "npc", "vendor" },
        }
        for _, field in ipairs(fields) do
            for _, id in ipairs(entity[field[1]](args.id) or {}) do
                relations[#relations + 1] = { kind = field[2], id = id, relation = field[3] }
            end
        end
        result.startQuest = entity.startQuest(args.id)
        return AddPage(result, relations, page, "relations")
    end
    local locations, usable = ReadLocations(db, entity, args.id)
    result.usableLocationTotal = usable
    result.locationAvailability = #locations == 0 and "missing" or usable > 0 and "available" or "unusable"
    result.locationsOwner = db.GetProvenance and db.GetProvenance(args.kind == "npc" and "Npc" or "Object", args.id, "spawns")
    return AddPage(result, locations, page, "locations")
end

function ns.GetDatabaseEntity(args)
    if type(args) ~= "table" then return InvalidArguments("args must be an object") end
    if args.kind ~= "npc" and args.kind ~= "object" and args.kind ~= "item" then
        return InvalidArguments("kind must be npc, object or item")
    end
    if not IsID(args.id) then return InvalidArguments("id must be a positive integer") end
    local page, message = ParsePage(args)
    if not page then return InvalidArguments(message) end
    local db, info = GetDatabase()
    if not db then
        info.ok, info.schemaVersion = true, 1
        return info
    end
    local ok, result = pcall(ReadDatabaseEntity, db, info, args, page)
    if not ok then return { ok = false, error = { code = "database_error", message = tostring(result) } } end
    return result
end

local function ReadDatabaseQuest(db, info, questID, page)
    if not db.Quest.Exists(questID) then
        return { available = false, source = "QuestieDB", reason = "quest_not_found", version = info.version }
    end
    local references = {}
    local function AddReferences(groups, role, kinds)
        for index, kind in ipairs(kinds) do
            for _, id in ipairs(groups[index] or {}) do
                references[#references + 1] = { role = role, kind = kind, id = id }
            end
        end
    end
    AddReferences(db.Quest.startedBy(questID) or {}, "quest_start", { "npc", "object", "item" })
    AddReferences(db.Quest.finishedBy(questID) or {}, "quest_turn_in", { "npc", "object" })
    local objectives = db.Quest.objectives(questID) or {}
    for group, kind in ipairs({ "npc", "object", "item" }) do
        for index, row in ipairs(objectives[group] or {}) do
            references[#references + 1] = {
                role = "objective_reference", kind = kind, id = row[1],
                databaseGroup = group, databaseIndex = index,
                text = row[2], databaseExtra = row[3],
            }
        end
    end
    local result = {
        available = true, source = "QuestieDB", version = info.version, contract = info.contract,
        name = db.Quest.name(questID), questLevel = db.Quest.questLevel(questID),
        requiredLevel = db.Quest.requiredLevel(questID),
        objectivesText = db.Quest.objectivesText(questID),
        specialObjectiveRelations = {
            reputation = objectives[4], killCredit = objectives[5], spell = objectives[6],
        },
        chain = {
            preQuestSingle = db.Quest.preQuestSingle(questID), preQuestGroup = db.Quest.preQuestGroup(questID),
            childQuests = db.Quest.childQuests(questID), nextQuestInChain = db.Quest.nextQuestInChain(questID),
            exclusiveTo = db.Quest.exclusiveTo(questID),
        },
        objectiveIndexMapping = "not_inferred",
    }
    return AddPage(result, references, page, "references")
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

WB:Expose("get_player_context", ns.GetPlayerContext,
    "只读获取原生玩家等级、经验、地图位置和世界坐标。args:{}。不可用的位置给出reason；不读取生命/能量。")
WB:Expose("get_quest_pois", ns.GetQuestPOIs,
    "只读查询已接任务原生POI。args:可选mapID（只查该图）、questID、offset>=0、limit=1..100（默认50）。"
    .. "未给mapID时扫描艾泽拉斯地图树，去除同任务同位置的投影重复，保留coordinateMapID/reportedMapID和projectionCount；不保证副本覆盖。")
WB:Expose("get_quest_details", ns.GetQuestDetails,
    "原生任务状态、目标和POI为主，QuestieDB元数据/接交关系/任务链独立补充。args:questID必填，"
    .. "allowDatabase=true/false（默认true），includePOIs=true/false（默认true），offset/limit对数据库references分页（默认50/max100）。不推断逐目标序号对应或击杀行为。")
WB:Expose("get_database_entity", ns.GetDatabaseEntity,
    "只读查询QuestieDB实体。args:kind=npc/object/item、id，offset/limit（默认50/max100）。"
    .. "NPC/物件返回locations，物品返回掉落/容器/商人relations；坐标统一0..1，保留AreaID和百分比原值；副本哨兵/无效地图明确不可导航。数据库缺失时available=false。")

-- 逐目标补充：官方finished/数量为准；只在任务内完整、唯一的精确文本对应后使用数据库静态点。
local function ObjectiveText(template, name, objective)
    if type(template) ~= "string" or type(name) ~= "string" or name == ""
        or not IsFinite(objective.numFulfilled) or not IsFinite(objective.numRequired) then return nil end
    local values = { name, tostring(objective.numFulfilled), tostring(objective.numRequired) }
    local nextIndex, valid = 0, true
    local result = template:gsub("%%(%d*)%$?([sd])", function(position, kind)
        local index = tonumber(position)
        if not index then nextIndex = nextIndex + 1; index = nextIndex end
        if not values[index] or (kind == "s" and index ~= 1) or (kind == "d" and index == 1) then valid = false; return "" end
        return values[index]
    end)
    return valid and result or nil
end

local function ResolveObjectiveIdentities(db, info, quest)
    local result = { mode = "native_poi", reason = "database_unavailable", source = "QuestieDB",
        progressSource = "C_QuestLog.GetQuestObjectives", objectives = {}, points = {}, mappingComplete = false }
    if quest.status ~= "in_progress" then result.reason = "official_completion_state"; return result end
    if not quest.objectivesLoaded or #quest.objectives == 0 then result.reason = "objectives_unavailable"; return result end
    if not db then return result end
    result.version, result.contract = info.version, info.contract
    local function Fallback(reason)
        result.mode, result.reason, result.points = "native_poi", reason, {}
        return result
    end
    if not db.Quest.Exists(quest.questID) then return Fallback("quest_not_found") end
    local groups = db.Quest.objectives(quest.questID)
    if type(groups) ~= "table" then return Fallback("database_objectives_missing") end
    for index = 4, 6 do
        if groups[index] and next(groups[index]) then return Fallback("special_objective_relation") end
    end
    local refs, keys = {}, {}
    for group, kind in ipairs({ "npc", "object", "item" }) do
        local entity = group == 1 and db.Npc or group == 2 and db.Object or db.Item
        for _, row in ipairs(groups[group] or {}) do
            if type(row) ~= "table" or not IsID(row[1]) or (row[3] ~= nil and row[3] ~= 0) then return Fallback("unsupported_reference") end
            local key = kind .. ":" .. row[1]
            if keys[key] then return Fallback("duplicate_reference") end
            if not entity or not entity.Exists(row[1]) then return Fallback("entity_not_found") end
            keys[key] = true
            local name = entity.name(row[1])
            if type(name) ~= "string" or name == "" then return Fallback("entity_name_unavailable") end
            refs[#refs + 1] = { key = key, kind = kind, id = row[1], name = name,
                label = row[2], objectiveType = group == 1 and "monster" or kind }
        end
    end
    if #refs ~= #quest.objectives or #refs > 32 then return Fallback("objective_count_mismatch") end
    local templates = { monster = rawget(_G, "QUEST_MONSTERS_KILLED"), object = rawget(_G, "QUEST_OBJECTS_FOUND"),
        item = rawget(_G, "QUEST_ITEMS_NEEDED") }
    local used = {}
    for index, objective in ipairs(quest.objectives) do
        if not canaccessvalue(objective.finished) or type(objective.finished) ~= "boolean" then return Fallback("objective_state_unavailable") end
        local match
        for refIndex, ref in ipairs(refs) do
            if Accessible(objective.type) == ref.objectiveType then
                local expected = ObjectiveText(templates[ref.objectiveType], ref.name, objective)
                if expected and expected == Accessible(objective.text) then
                    if match then return Fallback("ambiguous_objective") end
                    match = refIndex
                end
            end
        end
        if not match then return Fallback("objective_identity_unmatched") end
        if used[match] then return Fallback("non_unique_objective_mapping") end
        used[match] = true
        local ref = refs[match]
        result.objectives[#result.objectives + 1] = { index = index, key = ref.key, kind = ref.kind, id = ref.id,
            name = ref.name, text = objective.text, finished = objective.finished,
            numFulfilled = objective.numFulfilled, numRequired = objective.numRequired,
            mapping = "task_scoped_exact_localized_text" }
    end
    result.mappingComplete, result.mode, result.reason = true, "objective_identities", "exact_mapping_complete"
    return result
end

local function ReadObjectiveIdentities(db, info, quest)
    local ok, result = pcall(ResolveObjectiveIdentities, db, info, quest)
    if ok then return result end
    return { mode = "native_poi", reason = "database_read_error", source = "QuestieDB",
        objectives = {}, points = {}, mappingComplete = false, message = tostring(result) }
end

local function ResolveObjectiveLocations(db, info, quest, cache, identities)
    local result = identities or ReadObjectiveIdentities(db, info, quest)
    if not result.mappingComplete then return result end
    local function Fallback(reason)
        result.mode, result.reason, result.points = "native_poi", reason, {}
        return result
    end
    local remaining = 0
    for _, objective in ipairs(result.objectives) do
        if not objective.finished then
            remaining = remaining + 1
            local sources = {}
            if objective.kind == "item" then
                for _, pair in ipairs({ { "npcDrops", "npc" }, { "objectDrops", "object" } }) do
                    for _, id in ipairs(db.Item[pair[1]](objective.id) or {}) do
                        if not IsID(id) then return Fallback("invalid_source_relation") end
                        sources[#sources + 1] = { kind = pair[2], id = id, relation = "direct_drop" }
                    end
                end
            else sources[1] = { kind = objective.kind, id = objective.id, relation = "objective_entity" } end
            if #sources == 0 then return Fallback("direct_location_source_missing") end
            if #sources > 32 then return Fallback("too_many_location_sources") end
            local pointCount, seen = 0, {}
            for _, source in ipairs(sources) do
                local key = source.kind .. ":" .. source.id
                local locations = cache[key]
                if not locations then
                    local entity = source.kind == "npc" and db.Npc or db.Object
                    if not entity or not entity.Exists(source.id) then return Fallback("source_entity_missing") end
                    locations = ReadLocations(db, entity, source.id)
                    cache[key] = locations
                end
                if #locations > 1200 then return Fallback("too_many_spawn_locations") end
                for _, location in ipairs(locations) do
                    if location.available and location.world and (location.phase == nil or location.phase == 0) then
                        local fingerprint = key .. ":" .. location.areaID .. ":" .. location.spawnIndex
                        if not seen[fingerprint] then
                            seen[fingerprint] = true
                            pointCount = pointCount + 1
                            result.points[#result.points + 1] = { questID = quest.questID, objective = objective,
                                objectiveKey = objective.key, source = "QuestieDB", precision = "static_spawn",
                                coordinateMapID = location.coordinateMapID, reportedMapID = location.coordinateMapID,
                                x = location.x, y = location.y, world = location.world, units = "normalized",
                                entityKind = source.kind, entityID = source.id, relation = source.relation,
                                areaID = location.areaID, spawnIndex = location.spawnIndex, version = info.version }
                        end
                    end
                end
            end
            if pointCount == 0 then return Fallback("objective_locations_unavailable") end
            if #result.points > 2400 then return Fallback("too_many_target_locations") end
        end
    end
    if remaining == 0 then return Fallback("objectives_finished_waiting_quest_state") end
    result.mode, result.reason, result.remainingCount = "objective_locations", "exact_mapping_complete", remaining
    return result
end

local function ReadObjectiveLocations(db, info, quest, cache, identities)
    local ok, result = pcall(ResolveObjectiveLocations, db, info, quest, cache or {}, identities)
    if ok then return result end
    return { mode = "native_poi", reason = "database_read_error", source = "QuestieDB",
        objectives = {}, points = {}, message = tostring(result) }
end

function ns.GetQuestTargets(args)
    if type(args) ~= "table" or not IsID(args.questID) then return InvalidArguments("questID must be a positive integer") end
    if args.mapID ~= nil and not IsID(args.mapID) then return InvalidArguments("mapID must be a positive integer") end
    if args.mapID and not C_Map.GetMapInfo(args.mapID) then return InvalidArguments("mapID is not a client map") end
    if args.allowDatabase ~= nil and type(args.allowDatabase) ~= "boolean" then return InvalidArguments("allowDatabase must be a boolean") end
    local page, message = ParsePage(args)
    if not page then return InvalidArguments(message) end
    local active = ActiveQuestIndex()
    local entry = active[args.questID]
    local result = { ok = true, schemaVersion = 1, apiRevision = ns.apiRevision, questID = args.questID,
        policy = "client_progress_database_static_locations", available = entry ~= nil }
    if not entry then result.reason = "quest_not_in_log"; return AddPage(result, {}, page, "targets") end
    local quest = ReadQuest(entry.info, entry.category, false)
    local called, objectives = pcall(C_QuestLog.GetQuestObjectives, args.questID)
    quest.objectivesLoaded = called and type(objectives) == "table"
    quest.objectives = quest.objectivesLoaded and objectives or {}
    local db, info
    if args.allowDatabase ~= false then db, info = GetDatabase() end
    local resolved = ReadObjectiveLocations(db, info or {}, quest)
    if args.allowDatabase == false then resolved.reason = "disabled_by_request" end
    result.mode, result.reason = resolved.mode, resolved.reason
    result.objectivesLoaded, result.mappingComplete = quest.objectivesLoaded, resolved.mappingComplete == true
    result.objectives = {}
    for index, objective in ipairs(quest.objectives) do
        local mapped
        if result.mappingComplete then mapped = resolved.objectives[index] end
        result.objectives[index] = { index = index, text = Accessible(objective.text), type = Accessible(objective.type),
            objectiveType = Accessible(objective.objectiveType), finished = Accessible(objective.finished),
            numFulfilled = Accessible(objective.numFulfilled), numRequired = Accessible(objective.numRequired),
            key = mapped and mapped.key, kind = mapped and mapped.kind, id = mapped and mapped.id,
            name = mapped and mapped.name, mapping = mapped and mapped.mapping }
    end
    result.progressSource, result.locationSource, result.databaseVersion = "C_QuestLog.GetQuestObjectives", "QuestieDB", resolved.version
    result.remainingCount = resolved.remainingCount
    local points = resolved.points
    if resolved.mode ~= "objective_locations" then
        points = CollectPOIs({ questID = args.questID }, active)
        result.locationSource = "C_QuestLog.GetQuestsOnMap"
    end
    if args.mapID then
        local filtered = {}
        for _, point in ipairs(points) do if point.reportedMapID == args.mapID then filtered[#filtered + 1] = point end end
        points = filtered
    end
    return AddPage(result, points, page, "targets")
end
WB:Expose("get_quest_targets", ns.GetQuestTargets,
    "只读解析未完成目标位置：官方进度为准，任务内按客户端格式与数据库完整名称精确唯一匹配后补QuestieDB静态点；未知回原生POI。"
    .. "args:questID必填，mapID可选，allowDatabase默认true，offset/limit默认0/50最大100；targets分页，objectives含完成状态与映射依据。")

-- 简易升级路线：当前地图内按原生难度/奖励校准直线距离；只画自有地图图层。
local route = ns.route or { views = {}, sequence = 0 }
ns.route = route
local instanceTags = { [62] = true, [81] = true, [85] = true, [88] = true, [89] = true, [98] = true, [288] = true }
local professionCategories = {
    ["炼金术"] = true, ["锻造"] = true, ["附魔"] = true, ["工程学"] = true,
    ["草药学"] = true, ["制皮"] = true, ["采矿"] = true, ["剥皮"] = true,
    ["裁缝"] = true, ["钓鱼"] = true, ["烹饪"] = true, ["急救"] = true,
    ["珠宝加工"] = true, ["铭文"] = true, ["考古学"] = true,
}

local function RouteSettings()
    local name = Accessible(UnitName("player"))
    if not name then
        route.temporary = route.temporary or { skipped = {}, moveThreshold = 100, enabled = true }
        return route.temporary
    end
    YYQQuestAPIDB = YYQQuestAPIDB or {}
    YYQQuestAPIDB.routes = YYQQuestAPIDB.routes or {}
    local key = GetRealmName() .. ":" .. name
    local settings = YYQQuestAPIDB.routes[key]
    if not settings then
        settings = { skipped = {}, moveThreshold = 100, enabled = true }
        YYQQuestAPIDB.routes[key] = settings
    end
    if settings.nameplatesEnabled == nil then settings.nameplatesEnabled = true end
    return settings
end

local function DistanceSquared(a, b)
    if not a or not b or a.continentID ~= b.continentID then return nil end
    return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2
end

local function RouteExclusion(quest, db, settings)
    if settings.skipped[quest.questID] then return "skipped", "player" end
    if quest.isFailed then return "failed", "client" end
    -- 难度/类型过滤针对做任务；目标已完成后只安排交付，仍遵守手动跳过和地图归属。
    if quest.readyForTurnIn or quest.isComplete then return end
    local tag = quest.tag
    local questType = C_QuestLog.GetQuestType(quest.questID)
    if instanceTags[questType] or (tag and instanceTags[tag.id]) then return "instance", "client" end
    if C_QuestLog.IsEliteQuest(quest.questID) or (tag and tag.isElite) then return "elite", "client" end
    if (tag and IsID(tag.tradeskillLineID)) or professionCategories[quest.category] then
        return "profession", "client"
    end
    if db and db.Quest and type(db.Quest.requiredSkill) == "function" then
        local ok, skill = pcall(db.Quest.requiredSkill, quest.questID)
        if ok and type(skill) == "table" and IsID(skill[1]) then return "profession", "QuestieDB" end
    end
end

local difficultyBands = {
    [0] = { name = "trivial", weight = 0.4 }, [1] = { name = "easy", weight = 1.25 },
    [2] = { name = "fair", weight = 1 }, [3] = { name = "difficult", weight = 0.65 },
    [4] = { name = "impossible", weight = 0.4 },
}
local priorityLabels = {
    easy_with_reward = "难度较低，已有经验奖励", easy_experience_unknown = "难度较低，奖励经验未知",
    appropriate = "难度适中", difficulty_unknown = "难度未知，按距离安排",
    difficult = "难度较高，适当靠后", very_difficult = "难度很高，适当靠后",
    trivial_on_the_way = "任务已属琐碎，适合顺路完成", low_reward_on_the_way = "奖励经验较低，适合顺路完成",
    below_typical_reward = "奖励经验偏低", turn_in = "任务已完成，可安排交付",
    turn_in_on_the_way = "低收益任务，适合顺路交付", completion_pending = "任务已完成，等待确认交付信息",
}

local function SafePriorityRead(func, questID)
    if type(func) ~= "function" then return nil, "api_unavailable" end
    local ok, value = pcall(func, questID)
    if not ok then return nil, "read_error" end
    if not canaccessvalue(value) then return nil, "restricted" end
    if value == nil then return nil, "data_unavailable" end
    return value
end

local function ReadLevelingData(quest)
    local id = quest.questID
    local cached, cacheReason = SafePriorityRead(HaveQuestData, id)
    local data = {
        difficulty = { available = false, name = "unknown", source = "C_PlayerInfo.GetContentDifficultyQuestForPlayer" },
        experience = { available = false, source = "GetQuestLogRewardXP" },
    }
    if cached == false then
        data.difficulty.reason, data.experience.reason = "quest_data_not_ready", "quest_data_not_ready"
        return data
    end
    local code, difficultyReason = SafePriorityRead(C_PlayerInfo and C_PlayerInfo.GetContentDifficultyQuestForPlayer, id)
    local trivial = SafePriorityRead(C_QuestLog.IsQuestTrivial, id)
    if type(trivial) == "boolean" then data.difficulty.isTrivial = trivial end
    if trivial == true then code = 0; data.difficulty.source = "C_QuestLog.IsQuestTrivial" end
    if IsFinite(code) and difficultyBands[code] then
        data.difficulty.available, data.difficulty.code, data.difficulty.name = true, code, difficultyBands[code].name
    else
        data.difficulty.reason = difficultyReason or "invalid_difficulty"
    end
    -- 这三个旧读取函数已在本客户端实测：显式questID，不切换选中任务。
    -- 任务信息就绪不代表奖励就绪；缺少缓存证明时不把0经验当成真实收益。
    local rewards, rewardReason = SafePriorityRead(HaveQuestRewardData, id)
    if cached ~= true or rewards ~= true then
        data.experience.reason = cached ~= true and (cacheReason or "quest_cache_unknown")
            or rewardReason or "reward_data_not_ready"
        return data
    end
    local xp, xpReason = SafePriorityRead(GetQuestLogRewardXP, id)
    if IsFinite(xp) and xp >= 0 then
        data.experience.available, data.experience.value = true, xp
    else
        data.experience.reason = xpReason or "invalid_experience"
    end
    return data
end

local function RewardReference(candidates, levelXPMaximum)
    local values = {}
    for _, candidate in ipairs(candidates) do
        local data = candidate.priority
        local code = data.difficulty.code
        if (code == 1 or code == 2) and data.experience.available and data.experience.value > 0 then
            values[#values + 1] = data.experience.value
        end
    end
    table.sort(values)
    local reference = { sampleCount = #values, minimumSamples = 3, available = #values >= 3,
        scope = "current_map_eligible_easy_fair", method = "median_positive_native_reward",
        levelXPMaximum = IsFinite(levelXPMaximum) and levelXPMaximum > 0 and levelXPMaximum or nil }
    if reference.available then
        local middle = math.floor((#values + 1) / 2)
        reference.value = #values % 2 == 1 and values[middle] or values[middle] / 2 + values[middle + 1] / 2
    end
    return reference
end

local function ApplyLevelingPriority(candidate, reference)
    local data, quest = candidate.priority, candidate.quest
    local band = difficultyBands[data.difficulty.code]
    local completed = quest.readyForTurnIn or quest.isComplete
    data.difficultyWeight = completed and 1 or band and band.weight or 1
    local xp = data.experience
    local rewardWeight = 1
    if xp.available then
        if reference.available then xp.relativeToReference = xp.value / reference.value end
        if reference.levelXPMaximum then xp.fractionOfLevel = xp.value / reference.levelXPMaximum end
        if xp.value == 0 then rewardWeight = 0.5
        elseif (xp.relativeToReference and xp.relativeToReference < 0.25)
            or (xp.fractionOfLevel and xp.fractionOfLevel < 0.005) then rewardWeight = 0.55
        elseif (xp.relativeToReference and xp.relativeToReference < 0.5)
            or (xp.fractionOfLevel and xp.fractionOfLevel < 0.01) then rewardWeight = 0.8 end
    end
    data.lowReward = xp.available and (xp.value == 0
        or (xp.relativeToReference ~= nil and xp.relativeToReference < 0.25)
        or (xp.fractionOfLevel ~= nil and xp.fractionOfLevel < 0.005))
    data.experienceWeight = completed and math.max(0.85, rewardWeight) or rewardWeight
    if quest.isComplete and not quest.readyForTurnIn then data.reason = "completion_pending"
    elseif completed then
        data.reason = (data.lowReward or data.difficulty.code == 0) and "turn_in_on_the_way" or "turn_in"
    elseif data.difficulty.code == 0 then data.reason = "trivial_on_the_way"
    elseif data.lowReward then data.reason = "low_reward_on_the_way"
    elseif data.difficulty.code == 4 then data.reason = "very_difficult"
    elseif data.difficulty.code == 3 then data.reason = "difficult"
    elseif rewardWeight < 1 then data.reason = "below_typical_reward"
    elseif data.difficulty.code == 1 then data.reason = xp.available and "easy_with_reward" or "easy_experience_unknown"
    else data.reason = data.difficulty.available and "appropriate" or "difficulty_unknown" end
    data.weight = data.difficultyWeight * data.experienceWeight
    candidate.priorityWeight = data.weight
end

local routeRules = {
    groupRadius = 200, arrivalRadius = 120, departureRadius = 180, progressRadius = 300, progressWindow = 90,
    idleTimeout = 180, switchRatio = 0.7, minSaving = 50, poiTolerance = 100,
}
route.progress = route.progress or {}

local function NearbyActivityPoints(points, origin, key)
    local anchors = {}
    for _, point in ipairs(points or {}) do
        local distance = DistanceSquared(origin, point.world)
        if (not key or point.objectiveKey == key) and distance and distance <= routeRules.progressRadius ^ 2 then
            anchors[#anchors + 1] = point.world
        end
    end
    return anchors
end

local function TrackProgress(quest, now, points, mapID, origin)
    local previous = route.progress[quest.questID]
    if quest.status ~= "in_progress" then
        route.progress[quest.questID] = { status = quest.status }
        return
    end
    -- 暂未返回目标数据时保留上次快照，不把重新加载数据当成首次进度。
    if not quest.objectivesLoaded or #quest.objectives == 0 then return end
    local oldKeys = previous and previous.keyed or {}
    local snapshot = { status = quest.status, objectives = {}, revision = previous and previous.revision or 0,
        keyed = not quest.resolvedObjectives and quest.preserveObjectiveHistory and oldKeys or {} }
    for i, objective in ipairs(quest.objectives) do
        local label = Accessible(objective.text)
        if type(label) == "string" then label = label:gsub("%d+%s*/%s*%d+", "#/#") else label = nil end
        snapshot.objectives[i] = {
            label = label, kind = Accessible(objective.type), required = IsFinite(objective.numRequired) and objective.numRequired or nil,
            value = IsFinite(objective.numFulfilled) and objective.numFulfilled or nil,
            finished = Accessible(objective.finished),
            key = quest.resolvedObjectives and quest.resolvedObjectives[i].key,
        }
        local current = snapshot.objectives[i]
        if current.key then
            local prior = oldKeys[current.key]
            current.revision = prior and prior.revision or 0
            if prior and current.kind == prior.kind and current.required == prior.required and current.label == prior.label
                and not (current.value and prior.value and current.value < prior.value)
                and not (current.finished == false and prior.finished == true) then
                local grew = current.value and prior.value and current.value > prior.value
                    or current.finished == true and prior.finished == false
                current.lastProgressAt = grew and now or prior.lastProgressAt
                current.activityMapID = grew and mapID or prior.activityMapID
                current.activityPoints = grew and NearbyActivityPoints(points, origin, current.key) or prior.activityPoints
            elseif prior then current.revision = current.revision + 1 end
            snapshot.keyed[current.key] = current
        end
    end
    local old = previous and previous.status == quest.status and previous.objectives
    if old and #old == #snapshot.objectives then
        local compatible, increased, regressed = true, false, false
        for i, current in ipairs(snapshot.objectives) do
            local prior = old[i]
            if current.kind ~= prior.kind or current.required ~= prior.required or current.label ~= prior.label or current.key ~= prior.key then compatible = false end
            if current.value and prior.value then
                if current.value > prior.value then increased = true end
                if current.value < prior.value then regressed = true end
            end
            if current.finished == true and prior.finished == false then increased = true end
            if current.finished == false and prior.finished == true then regressed = true end
        end
        if compatible and not regressed then
            snapshot.lastProgressAt = increased and now or previous.lastProgressAt
            snapshot.activityMapID = increased and mapID or previous.activityMapID
            snapshot.activityPoints = previous.activityPoints
            if increased then snapshot.activityPoints = NearbyActivityPoints(points, origin) end
        else snapshot.revision = snapshot.revision + 1 end
    elseif old then
        snapshot.revision = snapshot.revision + 1
    end
    route.progress[quest.questID] = snapshot
end

local function TargetProgress(questID, key)
    local progress = route.progress[questID]
    return key and progress and progress.keyed and progress.keyed[key] or (not key and progress or nil)
end

local navigationLabels = {
    travel = "赶路中：前往任务区域", working = "在这一带完成任务目标",
    turn_in = "前往交付任务", completion_pending = "任务已完成，等待确认交付信息",
    queued = "后续任务", idle = "当前地图暂无可规划任务", unavailable = "等待任务或玩家位置更新",
}
local temporaryLocationReasons = { no_native_poi = true, player_position_unavailable = true,
    world_position_unavailable = true, player_map_unavailable = true, spot_data_unavailable = true }
local temporaryObjectiveReasons = { objectives_unavailable = true, objective_state_unavailable = true,
    entity_name_unavailable = true, database_read_error = true }

local function SameWorkTarget(previous, step, mapID)
    local shift = previous and step and DistanceSquared(previous.targetWorld, step.world)
    return previous and step and previous.questID == step.questID and previous.questStatus == step.status
        and previous.mapID == mapID and previous.objectiveKey == step.objectiveKey
        and previous.objectiveRevision == (step.objectiveRevision or 0)
        and shift and shift <= routeRules.poiTolerance ^ 2
end

local function NavigationForStep(step, origin, mapID, now, previous, reset)
    local nav = { phase = "idle", reason = "no_eligible_tasks", observedAt = now, protected = false, mapID = mapID }
    if step then
        nav.questID, nav.questStatus, nav.targetWorld = step.questID, step.status, step.world
        nav.objectiveKey, nav.objective = step.objectiveKey, step.objective
        nav.objectiveRevision = step.objectiveRevision or 0
        nav.objectivesAvailable = step.objectivesAvailable
    end
    local squared = step and DistanceSquared(origin, step.world)
    local same = not reset and SameWorkTarget(previous, step, mapID)
    if not same and not reset and SameWorkTarget(route.workSession, step, mapID) then
        previous, same = route.workSession, true
    end
    if not same and not reset and SameWorkTarget(route.suspendedObjectiveSession, step, mapID) then
        previous, same = route.suspendedObjectiveSession, true
    end
    if not same and not reset and step and not step.objectiveKey and temporaryObjectiveReasons[step.targetReason] then
        local saved = route.suspendedObjectiveSession
        local shift = saved and DistanceSquared(saved.targetWorld, step.world)
        if saved and saved.questID == step.questID and saved.questStatus == step.status and saved.mapID == mapID
            and shift and shift <= routeRules.poiTolerance ^ 2 then previous, same = saved, true end
    end
    if not IsID(mapID) or not origin or (step and not squared) then
        nav.phase, nav.reason = "unavailable", "player_position_unavailable"
        if same then nav.workStartedAt, nav.lastProgressAt = previous.workStartedAt, previous.lastProgressAt end
    elseif step and step.status == "ready_for_turn_in" then
        nav.phase, nav.reason = "turn_in", "official_ready_for_turn_in"
        nav.locationPrecision, nav.deliveryLocationConfirmed = "quest_poi", false
    elseif step and step.status == "complete" then
        nav.phase, nav.reason = "completion_pending", "official_complete_not_ready"
    elseif step then
        local progress = TargetProgress(step.questID, step.objectiveKey)
        local last = progress and progress.lastProgressAt
        if not IsFinite(last) or last > now then last = nil end
        local anchored
        if progress and progress.activityMapID == mapID then
            for _, point in ipairs(progress.activityPoints or {}) do
                local shift = DistanceSquared(point, step.world)
                if shift and shift <= routeRules.poiTolerance ^ 2 then anchored = true; break end
            end
        end
        local recent = anchored and last and now - last <= routeRules.progressWindow
        if not anchored then last = nil end
        local wasWorking = same and (previous.phase == "working"
            or (previous.phase == "unavailable" and IsFinite(previous.workStartedAt)))
        nav.phase, nav.reason = "travel", wasWorking and "left_work_area_or_progress_expired" or "towards_objective_area"
        if squared <= routeRules.arrivalRadius ^ 2 then
            nav.phase, nav.reason = "working", "at_objective_area"
        elseif wasWorking and squared <= routeRules.departureRadius ^ 2 then
            nav.phase, nav.reason = "working", "within_work_area"
        elseif squared <= routeRules.progressRadius ^ 2 and recent then
            nav.phase, nav.reason = "working", "recent_objective_progress"
        end
        nav.lastProgressAt = last
        if nav.phase == "working" then
            nav.workStartedAt = wasWorking and previous.workStartedAt or now
            if not IsFinite(nav.workStartedAt) or nav.workStartedAt > now then nav.workStartedAt = now end
            nav.idleFor = now - math.max(nav.workStartedAt, last or nav.workStartedAt)
            nav.stale = nav.idleFor >= routeRules.idleTimeout - 0.000001
            nav.protected = not nav.stale
            if nav.stale then nav.reason = "no_progress_timeout" end
        end
    end
    if squared then
        nav.distance = math.sqrt(squared)
        nav.atReference = squared <= routeRules.arrivalRadius ^ 2
    end
    nav.label = navigationLabels[nav.phase]
    nav.since = same and previous.phase == nav.phase and previous.since or now
    return nav
end

local function UpdateNavigation(plan, location, now, previous, reset)
    local first = plan.steps[1]
    local temporaryFallback = first and first.targetMode == "native_poi" and temporaryObjectiveReasons[first.targetReason]
    local saved = route.suspendedObjectiveSession
    if reset then route.suspendedObjectiveSession = nil
    elseif temporaryFallback and previous and previous.objectiveKey and previous.workStartedAt
        and previous.questID == first.questID and previous.questStatus == first.status and previous.mapID == location.coordinateMapID then
        route.suspendedObjectiveSession = previous
    elseif saved and (not first or first.questID ~= saved.questID or first.status ~= saved.questStatus
        or location.coordinateMapID ~= saved.mapID) then route.suspendedObjectiveSession = nil end
    local nav = NavigationForStep(first, location.world, location.coordinateMapID, now, previous, reset)
    if not first and (plan.pendingLocationCount or 0) > 0 and nav.phase == "idle" then
        nav.phase, nav.reason, nav.label = "unavailable", "quest_location_unavailable", navigationLabels.unavailable
    end
    local suspended = route.workSession
    local canResume = not first and suspended and suspended.mapID == location.coordinateMapID
        and route.activeQuestIDs and route.activeQuestIDs[suspended.questID]
    if canResume then
        canResume = false
        for _, excluded in ipairs(plan.excluded) do
            if excluded.questID == suspended.questID and temporaryLocationReasons[excluded.reason] then canResume = true; break end
        end
    end
    if nav.workStartedAt then route.workSession = nav
    elseif not canResume or reset then route.workSession = nil end
    if not temporaryFallback then route.suspendedObjectiveSession = nil end
    plan.navigation = nav
    if first then first.navigation = nav end
    local released = previous and nav.phase ~= "unavailable"
        and (previous.phase == "unavailable" or (previous.questID == nav.questID
            and ((previous.protected and not nav.protected) or (previous.phase == "working" and nav.phase == "travel"))))
    local emitted = route.lastNavigationEvent
    if not emitted or emitted.questID ~= nav.questID or emitted.objectiveKey ~= nav.objectiveKey or emitted.phase ~= nav.phase
        or emitted.protected ~= nav.protected or emitted.stale ~= nav.stale then
        WB:Emit("route.navigation_changed", { questID = nav.questID, objectiveKey = nav.objectiveKey, phase = nav.phase, reason = nav.reason,
            protected = nav.protected, stale = nav.stale, distance = nav.distance, mapID = nav.mapID })
        route.lastNavigationEvent = { questID = nav.questID, objectiveKey = nav.objectiveKey, phase = nav.phase, protected = nav.protected, stale = nav.stale }
    end
    return released
end

local function RouteStepKey(questID, objectiveKey)
    return questID .. ":" .. (objectiveKey or "quest")
end

-- 固定半径密度峰值：中心始终是真实刷新点，不用跨区域均值或单链扩张。
local hotspotRules = { radius = 150, separation = 300, maxDisplayed = 3, deduplicateRadius = 3,
    algorithm = "fixed_radius_density_real_spawn", cacheLimit = 64 }
route.hotspotCache, route.hotspotCacheOrder = {}, {}
route.hotspotCacheHits, route.hotspotCacheMisses = 0, 0

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
    local cached = route.hotspotCache[cacheKey]
    if cached and cached.signature == signature then route.hotspotCacheHits = route.hotspotCacheHits + 1
    else
        route.hotspotCacheMisses = route.hotspotCacheMisses + 1
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
            if #route.hotspotCacheOrder >= hotspotRules.cacheLimit then
                route.hotspotCache[table.remove(route.hotspotCacheOrder, 1)] = nil
            end
            route.hotspotCacheOrder[#route.hotspotCacheOrder + 1] = cacheKey
        end
        cached = { signature = signature, centres = centres }
        route.hotspotCache[cacheKey] = cached
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

local function ChooseCandidate(remaining, cursor, anchor, members)
    local bestIndex, bestPoint, bestDistance, bestScore
    for index, candidate in ipairs(remaining) do
        if not members or members[candidate.stepKey] == candidate.quest.status then
            for _, point in ipairs(candidate.points) do
                local localDistance = anchor and DistanceSquared(anchor, point.world)
                if not anchor or (localDistance and localDistance <= routeRules.groupRadius ^ 2) then
                    local distance = DistanceSquared(cursor, point.world)
                    local score = distance and distance / (candidate.priorityWeight * candidate.priorityWeight)
                    local prior = bestIndex and remaining[bestIndex]
                    local earlier = prior and (candidate.quest.questID < prior.quest.questID
                        or (candidate.quest.questID == prior.quest.questID and candidate.stepKey < prior.stepKey))
                    if score and (not bestScore or score < bestScore
                        or (score == bestScore and (distance < bestDistance or (distance == bestDistance and earlier)))) then
                        bestIndex, bestPoint, bestDistance, bestScore = index, point, distance, score
                    end
                end
            end
        end
    end
    return bestIndex, bestPoint, bestDistance, bestScore
end

local function StableFirst(remaining, origin, mapID, reason, now)
    local bestIndex, bestPoint, bestDistance, bestScore = ChooseCandidate(remaining, origin)
    local previous = route.plan
    local first = previous and previous.steps[1]
    local decision = { retained = false, reason = reason == "manual" and "manual_replan" or "nearest_weighted" }
    decision.previousQuestID = first and first.questID
    decision.previousObjectiveKey = first and first.objectiveKey
    if not bestIndex or reason == "manual" or not first or previous.mapID ~= mapID then
        return bestIndex, bestPoint, bestDistance, bestScore, decision
    end
    local group = previous.groups and previous.groups[first.groupIndex]
    local previousIndex, previousPoint, previousShift
    for index, candidate in ipairs(remaining) do
        if candidate.quest.questID == first.questID and candidate.quest.status == first.status then
            for _, point in ipairs(candidate.points) do
                local shift = DistanceSquared(first.world, point.world)
                if point.objectiveKey == first.objectiveKey and shift and shift <= routeRules.poiTolerance ^ 2 and (not previousShift or shift < previousShift) then
                    previousIndex, previousPoint, previousShift = index, point, shift
                end
            end
        end
    end
    if previousIndex then
        local candidate = remaining[previousIndex]
        local distance = DistanceSquared(origin, previousPoint.world)
        local score = distance / (candidate.priorityWeight * candidate.priorityWeight)
        local oldWeighted, newWeighted = math.sqrt(score), math.sqrt(bestScore)
        local progress = TargetProgress(first.questID, previousPoint.objectiveKey)
        local nav = NavigationForStep({ questID = first.questID, status = candidate.quest.status, world = previousPoint.world,
            objectiveKey = previousPoint.objectiveKey, objectiveRevision = progress and progress.revision or 0 }, origin, mapID, now, previous.navigation)
        local keepReason
        if nav.phase == "working" and nav.protected then
            keepReason = nav.reason
        elseif bestIndex == previousIndex and bestPoint == previousPoint then
            keepReason = "same_target"
        elseif newWeighted > oldWeighted * routeRules.switchRatio + 0.000001
            or oldWeighted - newWeighted < routeRules.minSaving - 0.000001 then
            keepReason = "avoid_small_switch"
        end
        if keepReason then
            decision.retained, decision.reason = true, keepReason
            decision.lastProgressAt = progress and progress.lastProgressAt
            local anchor = group and DistanceSquared(group.anchor, previousPoint.world)
            return previousIndex, previousPoint, distance, score, decision,
                anchor and anchor <= routeRules.groupRadius ^ 2 and group.anchor or nil
        end
        decision.reason = "clearly_better_candidate"
    elseif group then
        -- 原任务交付/完成/消失后，在仍身处原区域时接着做这一批剩余任务。
        local nearby = DistanceSquared(origin, group.anchor)
        if nearby and nearby <= routeRules.progressRadius ^ 2 then
            local members = {}
            local firstKey = RouteStepKey(first.questID, first.objectiveKey)
            for _, step in ipairs(previous.steps) do
                local key = RouteStepKey(step.questID, step.objectiveKey)
                if step.groupIndex == first.groupIndex and key ~= firstKey then members[key] = step.status end
            end
            -- 旧版每任务只有一步时补回未显示的兄弟目标；新版只延续实际属于原组的步骤。
            if first.objectiveKey and not first.stepKey then
                for _, candidate in ipairs(remaining) do
                    if candidate.quest.questID == first.questID and candidate.quest.status == first.status
                        and candidate.objectiveKey and candidate.objectiveKey ~= first.objectiveKey then
                        members[candidate.stepKey] = first.status
                    end
                end
            end
            local index, point, distance, score = ChooseCandidate(remaining, origin, group.anchor, members)
            if index then
                decision.reason = "continue_nearby_group"
                return index, point, distance, score, decision, group.anchor
            end
        end
        decision.reason = "previous_target_changed"
    else
        decision.reason = "previous_target_changed"
    end
    return bestIndex, bestPoint, bestDistance, bestScore, decision
end

-- 临时地点避让按任务/子目标隔离，不写入角色存档中的时间戳。
local spotRules = { radius = 150, duration = 600, maximum = 64 }
route.spotAvoidances = route.spotAvoidances or {}

local function SpotBlocked(point, questID, mapID, now, extra)
    local function Matches(avoid)
        local distance = DistanceSquared(point.world, avoid.world)
        return avoid.questID == questID and avoid.objectiveKey == point.objectiveKey and avoid.mapID == mapID
            and avoid.expiresAt > now and distance and distance <= spotRules.radius ^ 2
    end
    if extra and Matches(extra) then return true end
    for _, avoid in ipairs(route.spotAvoidances) do if Matches(avoid) then return true end end
    return false
end

local function QuestHasAvoidance(questID, mapID, now)
    for _, avoid in ipairs(route.spotAvoidances) do
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
    for _, avoid in ipairs(route.spotAvoidances) do
        if avoid.questID ~= quest.questID or pending[avoid.objectiveKey] then kept[#kept + 1] = avoid end
    end
    route.spotAvoidances = kept
end

local function PruneSpotAvoidances(active, mapID, now)
    local kept, nextCheck = {}, nil
    for _, avoid in ipairs(route.spotAvoidances) do
        if active[avoid.questID] and avoid.mapID == mapID and avoid.expiresAt > now then
            kept[#kept + 1] = avoid
            nextCheck = not nextCheck and avoid.expiresAt or math.min(nextCheck, avoid.expiresAt)
        end
    end
    route.spotAvoidances, route.nextSpotCheck = kept, nextCheck
end

-- 姓名板只需要目标身份和直接掉落关系；缺少静态坐标不妨碍可靠身份关联。
local function ReadNPCGoals(db, quest, identities)
    if not identities.mappingComplete then return nil end
    local goals = {}
    for _, objective in ipairs(identities.objectives) do
        local ids = {}
        if objective.kind == "npc" then ids = { objective.id }
        elseif objective.kind == "item" then ids = db.Item.npcDrops(objective.id) end
        if type(ids) ~= "table" or #ids > 32 then return nil end
        local seen = {}
        for _, id in ipairs(ids) do
            if not IsID(id) then return nil end
            if not seen[id] then
                seen[id] = true
                goals[#goals + 1] = { npcID = id, questID = quest.questID, title = quest.title,
                    objectiveKey = objective.key, kind = objective.kind, id = objective.id, name = objective.name,
                    text = objective.text, finished = objective.finished,
                    numFulfilled = objective.numFulfilled, numRequired = objective.numRequired,
                    relation = objective.kind == "npc" and "kill" or "direct_item_drop",
                    mapping = objective.mapping, progressSource = "C_QuestLog.GetQuestObjectives", relationSource = "QuestieDB" }
            end
        end
    end
    return goals
end

local function AddNPCGoals(index, db, quest, identities)
    if quest.status ~= "in_progress" then return end
    local ok, goals = pcall(ReadNPCGoals, db, quest, identities)
    if not ok or not goals then index.unresolvedQuestCount = index.unresolvedQuestCount + 1; return end
    for _, goal in ipairs(goals) do
        index.byNPC[goal.npcID] = index.byNPC[goal.npcID] or {}
        local bucket = index.byNPC[goal.npcID]
        bucket[#bucket + 1] = goal
    end
end

local function RebuildRoute(reason)
    local settings = RouteSettings()
    local context = ns.GetPlayerContext({})
    local origin = context.location
    local mapID = origin.coordinateMapID
    local now = GetTime()
    local active = ActiveQuestIndex()
    PruneSpotAvoidances(active, mapID, now)
    local mobIndex = { byNPC = {}, unresolvedQuestCount = 0, observedAt = now }
    local pois = CollectPOIs({}, active)
    local db, dbInfo = GetDatabase()
    local byQuest, excluded, remaining = {}, {}, {}
    local objectiveResolution, locationCache = {}, {}
    local pendingLocations, pendingObjectives = 0, 0
    for _, poi in ipairs(pois) do
        byQuest[poi.questID] = byQuest[poi.questID] or {}
        byQuest[poi.questID][#byQuest[poi.questID] + 1] = poi
    end
    local ids = {}
    for id in pairs(active) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local entry = active[id]
        local quest = ReadQuest(entry.info, entry.category, false)
        local objectivesOK, objectives = pcall(C_QuestLog.GetQuestObjectives, id)
        quest.objectivesLoaded = objectivesOK and type(objectives) == "table"
        quest.objectives = quest.objectivesLoaded and objectives or {}
        local why, source = RouteExclusion(quest, db, settings)
        local options, allLocalPoints, hasLocalPoint, avoidedCount = {}, {}, false, 0
        local resolved
        if not why then
            local identities = ReadObjectiveIdentities(db, dbInfo, quest)
            AddNPCGoals(mobIndex, db, quest, identities)
            RetireFinishedAvoidances(quest, identities)
            resolved = ReadObjectiveLocations(db, dbInfo, quest, locationCache, identities)
            if db and temporaryObjectiveReasons[resolved.reason] then pendingObjectives = pendingObjectives + 1 end
            quest.resolvedObjectives = resolved.mode == "objective_locations" and resolved.objectives or nil
            quest.preserveObjectiveHistory = temporaryObjectiveReasons[resolved.reason]
            objectiveResolution[#objectiveResolution + 1] = { questID = id, mode = resolved.mode, reason = resolved.reason,
                remainingCount = resolved.remainingCount, pointCount = #resolved.points, version = resolved.version }
            local sourcePoints = resolved.mode == "objective_locations" and resolved.points or byQuest[id] or {}
            if resolved.mode ~= "objective_locations" and quest.status == "in_progress" and QuestHasAvoidance(id, mapID, now) then
                sourcePoints = {}
                why, source = "spot_data_unavailable", "player"
            end
            for _, point in ipairs(sourcePoints) do
                -- 邻图也会返回本图内的投影，归属必须看reportedMapID，不能看坐标边界或查询图。
                if IsID(mapID) and point.reportedMapID == mapID then
                    hasLocalPoint = true
                    if origin.world and point.world and origin.world.continentID == point.world.continentID then
                        allLocalPoints[#allLocalPoints + 1] = point
                        if SpotBlocked(point, id, mapID, now) then avoidedCount = avoidedCount + 1
                        else options[#options + 1] = point end
                    end
                end
            end
            if #options == 0 then
                why = why or avoidedCount > 0 and "spots_temporarily_avoided"
                    or not IsID(mapID) and "player_map_unavailable"
                    or (resolved.mode ~= "objective_locations" and not byQuest[id]) and "no_native_poi"
                    or not hasLocalPoint and "outside_current_map"
                    or not origin.world and "player_position_unavailable" or "world_position_unavailable"
                source = source or "client"
            end
        end
        TrackProgress(quest, now, options, mapID, origin.world)
        if why then
            if temporaryLocationReasons[why] or why == "spot_data_unavailable" then pendingLocations = pendingLocations + 1 end
            excluded[#excluded + 1] = { questID = id, title = quest.title, reason = why, source = source }
        else
            remaining[#remaining + 1] = {
                quest = quest, points = options, allPoints = allLocalPoints, priority = ReadLevelingData(quest), resolution = resolved,
            }
        end
    end
    local taskCandidates = remaining
    -- 经验参照和读取仍按任务各一次；路线改为每个未完目标一个候选，不能因目标多而重复计算奖励。
    local eligibleQuestCount, objectiveStepCount, nativeStepCount = #remaining, 0, 0
    local objectiveCandidates = {}
    for _, candidate in ipairs(remaining) do
        local buckets = {}
        for _, point in ipairs(candidate.allPoints) do
            local key = RouteStepKey(candidate.quest.questID, point.objectiveKey)
            local target = buckets[key]
            if not target then
                target = { quest = candidate.quest, points = {}, priority = candidate.priority,
                    priorityWeight = candidate.priorityWeight, resolution = candidate.resolution,
                    objectiveKey = point.objectiveKey, stepKey = key }
                buckets[key] = target
                objectiveCandidates[#objectiveCandidates + 1] = target
            end
            target.points[#target.points + 1] = point
        end
    end
    remaining = {}
    local eligibleIDs = {}
    for _, candidate in ipairs(objectiveCandidates) do
        local choices = candidate.objectiveKey and BuildHotspots(candidate.points, candidate.stepKey .. ":" .. mapID) or candidate.points
        candidate.points = {}
        for _, point in ipairs(choices) do
            if not SpotBlocked(point, candidate.quest.questID, mapID, now) then candidate.points[#candidate.points + 1] = point end
        end
        if #candidate.points > 0 then
            remaining[#remaining + 1] = candidate
            eligibleIDs[candidate.quest.questID] = true
            if candidate.objectiveKey then objectiveStepCount = objectiveStepCount + 1
            else nativeStepCount = nativeStepCount + 1 end
        end
    end
    eligibleQuestCount = 0
    for _ in pairs(eligibleIDs) do eligibleQuestCount = eligibleQuestCount + 1 end
    local noHotspots = {}
    for _, candidate in ipairs(objectiveCandidates) do
        local id = candidate.quest.questID
        if not eligibleIDs[id] and not noHotspots[id] then
            excluded[#excluded + 1] = { questID = id, title = candidate.quest.title, reason = "spots_temporarily_avoided", source = "player" }
            noHotspots[id] = true
        end
    end
    local eligibleTasks = {}
    for _, candidate in ipairs(taskCandidates) do
        if eligibleIDs[candidate.quest.questID] then eligibleTasks[#eligibleTasks + 1] = candidate end
    end
    local rewardReference, weights = RewardReference(eligibleTasks, context.experience.maximum), {}
    local pendingRewards = 0
    for _, candidate in ipairs(eligibleTasks) do
        ApplyLevelingPriority(candidate, rewardReference)
        weights[candidate.quest.questID] = candidate.priorityWeight
        local why = candidate.priority.experience.reason
        if why == "reward_data_not_ready" or why == "quest_data_not_ready" or why == "read_error" or why == "data_unavailable" then
            pendingRewards = pendingRewards + 1
        end
    end
    for _, candidate in ipairs(remaining) do candidate.priorityWeight = weights[candidate.quest.questID] end
    -- 奖励缓存可独立于任务信息就绪；只在仍有暂缺数据时轻量重试，避免依赖单一事件。
    route.nextRewardCheck = pendingRewards > 0 and now + 5 or nil
    route.nextLocationCheck = pendingLocations > 0 and now + 5 or nil
    route.nextObjectiveCheck = pendingObjectives > 0 and now + 5 or nil
    route.activeQuestIDs = active
    for id in pairs(route.progress) do if not active[id] then route.progress[id] = nil end end
    route.mobIndex = mobIndex
    local previousNavigation = route.plan and route.plan.navigation
    local firstIndex, firstPoint, firstDistance, firstScore, stability, firstAnchor =
        StableFirst(remaining, origin.world, mapID, reason, now)
    local requested = route.pendingSpotChange
    local requestedFound
    if requested then
        for index, candidate in ipairs(remaining) do
            if candidate.quest.questID == requested.questID then
                for _, point in ipairs(candidate.points) do
                    local shift = DistanceSquared(point.world, requested.world)
                    if point.objectiveKey == requested.objectiveKey and shift and shift < 0.000001 then
                        requestedFound = true
                        firstIndex, firstPoint = index, point
                        firstDistance = DistanceSquared(origin.world, point.world)
                        firstScore = firstDistance / (candidate.priorityWeight ^ 2)
                        stability = { retained = false, reason = "manual_spot_change", questID = requested.questID }
                        firstAnchor = nil
                    end
                end
            end
        end
    end
    if requested and not requestedFound then
        return { ok = false, error = { code = "target_changed", message = "所选热点已不可用，原路线保留。" } }
    end
    local cursor, steps, groups, pathLength = origin.world, {}, {}, 0
    local group
    while cursor and #remaining > 0 do
        local bestIndex, bestPoint, bestDistance, bestScore
        if #steps == 0 then
            bestIndex, bestPoint, bestDistance, bestScore = firstIndex, firstPoint, firstDistance, firstScore
        elseif group then
            bestIndex, bestPoint, bestDistance, bestScore = ChooseCandidate(remaining, cursor, group.anchor)
        end
        if not bestIndex then
            bestIndex, bestPoint, bestDistance, bestScore = ChooseCandidate(remaining, cursor)
            group = nil
        end
        if not bestIndex then break end
        if not group then
            group = { index = #groups + 1, anchor = #steps == 0 and firstAnchor or bestPoint.world,
                questIDs = {}, count = 0, questCount = 0 }
            if not group.anchor then group.anchor = bestPoint.world end
            groups[#groups + 1] = group
        end
        local selected = table.remove(remaining, bestIndex)
        local quest = selected.quest
        local distance = math.sqrt(bestDistance)
        pathLength = pathLength + distance
        group.count = group.count + 1
        local listed
        for _, id in ipairs(group.questIDs) do if id == quest.questID then listed = true; break end end
        if not listed then group.questIDs[#group.questIDs + 1] = quest.questID; group.questCount = group.questCount + 1 end
        steps[#steps + 1] = {
            index = #steps + 1, stepKey = selected.stepKey, questID = quest.questID, title = quest.title, level = quest.level,
            displayTitle = quest.readyForTurnIn and (quest.title .. "（交任务）")
                or quest.isComplete and (quest.title .. "（等待确认交付）")
                or bestPoint.objective and (quest.title .. " — " .. bestPoint.objective.name) or quest.title,
            status = quest.status, action = quest.readyForTurnIn and "turn_in" or quest.isComplete and "completion_pending" or "quest_area",
            groupIndex = group.index, targetMapID = bestPoint.reportedMapID,
            coordinateMapID = bestPoint.coordinateMapID, x = bestPoint.x, y = bestPoint.y,
            world = bestPoint.world, source = bestPoint.source, precision = bestPoint.precision,
            objectiveKey = bestPoint.objectiveKey, objective = bestPoint.objective,
            hotspots = VisibleHotspots(selected.points, bestPoint),
            entityKind = bestPoint.entityKind, entityID = bestPoint.entityID, relation = bestPoint.relation,
            locationVersion = bestPoint.version, targetMode = selected.resolution and selected.resolution.mode or "native_poi",
            targetReason = selected.resolution and selected.resolution.reason,
            segmentDistance = distance, priorityWeight = selected.priorityWeight, weightedDistance = math.sqrt(bestScore),
            priority = selected.priority,
            objectiveRevision = (TargetProgress(quest.questID, bestPoint.objectiveKey) or {}).revision or 0,
            objectivesAvailable = quest.objectivesLoaded and #quest.objectives > 0,
            navigation = { phase = "queued", label = navigationLabels.queued, protected = false },
        }
        cursor = bestPoint.world
    end
    local taskStepCounts, turnInCount, completionPendingCount = {}, 0, 0
    for _, step in ipairs(steps) do
        taskStepCounts[step.questID] = (taskStepCounts[step.questID] or 0) + 1
        if step.action == "turn_in" then turnInCount = turnInCount + 1
        elseif step.action == "completion_pending" then completionPendingCount = completionPendingCount + 1 end
    end
    for _, step in ipairs(steps) do
        step.groupSize, step.groupQuestCount = groups[step.groupIndex].count, groups[step.groupIndex].questCount
        step.questStepCount = taskStepCounts[step.questID]
    end
    stability.questID, stability.objectiveKey = steps[1] and steps[1].questID, steps[1] and steps[1].objectiveKey
    route.sequence = route.sequence + 1
    route.plan = {
        ok = true, schemaVersion = 1, apiRevision = ns.apiRevision, sequence = route.sequence,
        policy = "stable_grouped_leveling_straight_line", scope = "current_player_map_active_quests",
        groups = groups, groupRadius = routeRules.groupRadius, stability = stability,
        spotRules = { radius = spotRules.radius, duration = spotRules.duration }, avoidedSpots = route.spotAvoidances,
        hotspotRules = { radius = hotspotRules.radius, separation = hotspotRules.separation, maxDisplayed = hotspotRules.maxDisplayed,
            deduplicateRadius = hotspotRules.deduplicateRadius, algorithm = hotspotRules.algorithm, alternativesJoinRoute = false },
        nameplates = { enabled = settings.enabled and settings.nameplatesEnabled ~= false,
            unresolvedQuestCount = mobIndex.unresolvedQuestCount, source = "client_progress_QuestieDB_relations" },
        objectiveResolution = objectiveResolution, pendingObjectiveCount = pendingObjectives, objectiveRetrySeconds = 5,
        navigationRules = { arrivalRadius = routeRules.arrivalRadius, departureRadius = routeRules.departureRadius,
            progressRadius = routeRules.progressRadius, progressWindow = routeRules.progressWindow, idleTimeout = routeRules.idleTimeout },
        mapID = mapID, mapName = origin.mapName,
        levelPriority = { referenceLevel = context.character.level, perLevelBonus = 0, maxWeight = 1.25,
            method = "client_difficulty_and_reward" },
        levelingPriority = { source = "client", reference = rewardReference,
            difficultyWeights = { trivial = 0.4, easy = 1.25, fair = 1, difficult = 0.65, impossible = 0.4 },
            rewardThresholds = { veryLowRatio = 0.25, lowRatio = 0.5, veryLowLevelFraction = 0.005, lowLevelFraction = 0.01 },
            pendingRewardCount = pendingRewards, rewardRetrySeconds = 5, unknownWeight = 1,
            turnInMinimumExperienceWeight = 0.85 },
        origin = origin, count = #steps, questCount = eligibleQuestCount,
        objectiveStepCount = objectiveStepCount, nativeStepCount = nativeStepCount,
        turnInCount = turnInCount, completionPendingCount = completionPendingCount,
        stepUnit = "unfinished_objective_or_quest", steps = steps, excluded = excluded,
        pendingLocationCount = pendingLocations, locationRetrySeconds = 5,
        moveThreshold = settings.moveThreshold, enabled = settings.enabled,
        totalStraightDistance = pathLength, reason = reason, plannedAt = now,
    }
    UpdateNavigation(route.plan, origin, now, previousNavigation, reason == "manual" or requested ~= nil)
    route.pendingSpotChange = nil
    route.playerLocation, route.lastOrigin = origin, origin.world
    route.dirty, route.pendingReason = false, nil
    WB:Emit("route.updated", { sequence = route.sequence, mapID = mapID, count = #steps, questCount = eligibleQuestCount, reason = reason })
    return route.plan
end

function ns.GetPlan(args)
    if args ~= nil and type(args) ~= "table" then return InvalidArguments("args must be an object") end
    return route.plan or RebuildRoute("requested")
end

function ns.Replan(args)
    if args ~= nil and type(args) ~= "table" then return InvalidArguments("args must be an object") end
    return RebuildRoute("manual")
end

function ns.SetQuestSkip(args)
    if type(args) ~= "table" or not IsID(args.questID) then return InvalidArguments("questID must be a positive integer") end
    if args.skipped ~= nil and type(args.skipped) ~= "boolean" then return InvalidArguments("skipped must be a boolean") end
    local settings = RouteSettings()
    local skipped = args.skipped ~= false
    settings.skipped[args.questID] = skipped or nil
    RebuildRoute(skipped and "quest_skipped" or "quest_restored")
    return { ok = true, questID = args.questID, skipped = skipped, count = route.plan.count }
end

local function CopyProgressData(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = CopyProgressData(item) end
    return copy
end

function ns.ChangeQuestSpot(args)
    if args == nil then args = {} end
    if type(args) ~= "table" or (args.questID ~= nil and not IsID(args.questID)) then
        return InvalidArguments("questID must be a positive integer when supplied")
    end
    if args.objectiveKey ~= nil and (not args.questID or type(args.objectiveKey) ~= "string"
        or not args.objectiveKey:match("^[a-z]+:%d+$")) then
        return InvalidArguments("objectiveKey requires questID and an entity key such as npc:3260")
    end
    if args.hotspotID ~= nil and (not args.questID or not args.objectiveKey
        or type(args.hotspotID) ~= "string" or #args.hotspotID > 96 or #args.hotspotID == 0) then
        return InvalidArguments("hotspotID requires questID and objectiveKey and a nonempty ID from get_plan")
    end
    local plan, step = ns.GetPlan({}), nil
    for _, candidate in ipairs(plan.steps) do
        if (args.questID == nil or candidate.questID == args.questID)
            and (args.objectiveKey == nil or candidate.objectiveKey == args.objectiveKey) then step = candidate; break end
    end
    local function Failed(code, message)
        return { ok = false, error = { code = code, message = message } }
    end
    if not step or not step.objectiveKey or step.targetMode ~= "objective_locations" or step.action ~= "quest_area" then
        return Failed("precise_target_required", "此步骤没有可更换的具体未完目标地点；任务不会被跳过。")
    end
    local context, active = ns.GetPlayerContext({}), ActiveQuestIndex()
    local location, entry = context.location, active[step.questID]
    if location.coordinateMapID ~= plan.mapID or not location.world or not entry then
        return Failed("target_unavailable", "玩家位置或任务已变化，请先重新规划。")
    end
    local db, info = GetDatabase()
    local quest = ReadQuest(entry.info, entry.category, false)
    local objectivesOK, objectives = pcall(C_QuestLog.GetQuestObjectives, step.questID)
    quest.objectivesLoaded = objectivesOK and type(objectives) == "table"
    quest.objectives = quest.objectivesLoaded and objectives or {}
    if RouteExclusion(quest, db, RouteSettings()) then return Failed("task_excluded", "此任务已被过滤或跳过。") end
    local resolved = ReadObjectiveLocations(db, info, quest)
    if resolved.mode ~= "objective_locations" then return Failed("target_unavailable", "目标位置暂不可用，原路线保留。") end
    local now = GetTime()
    local avoid = { questID = step.questID, objectiveKey = step.objectiveKey, mapID = plan.mapID,
        world = step.world, expiresAt = now + spotRules.duration }
    local sourcePoints = {}
    for _, point in ipairs(resolved.points) do
        if point.objectiveKey == step.objectiveKey and point.reportedMapID == plan.mapID
            and point.world and point.world.continentID == location.world.continentID then sourcePoints[#sourcePoints + 1] = point end
    end
    local choices = BuildHotspots(sourcePoints, step.stepKey .. ":" .. plan.mapID)
    local best, bestDistance
    for _, point in ipairs(choices) do
        if (args.hotspotID == nil or point.hotspot.id == args.hotspotID)
            and not SpotBlocked(point, step.questID, plan.mapID, now, avoid) then
            local distance = DistanceSquared(location.world, point.world)
            if distance and (not bestDistance or distance < bestDistance) then best, bestDistance = point, distance end
        end
    end
    if not best then return Failed("no_alternative_spot", "同一未完目标在当前地图没有其他可用地点，原路线保留。") end
    -- 重建期间若缓存/任务再次变化，丢弃草稿，原路线/计时/避让和事件保持不变。
    local original, draft = route, {}
    for key, value in pairs(original) do draft[key] = value end
    draft.progress, draft.spotAvoidances = CopyProgressData(original.progress), CopyProgressData(original.spotAvoidances)
    route = draft
    if #route.spotAvoidances >= spotRules.maximum then table.remove(route.spotAvoidances, 1) end
    route.spotAvoidances[#route.spotAvoidances + 1] = avoid
    route.pendingSpotChange = { questID = step.questID, objectiveKey = step.objectiveKey, world = best.world }
    local called, updated = pcall(RebuildRoute, "spot_changed")
    route = original
    if not called or not updated.ok then
        return not called and Failed("target_unavailable", "热点刷新未成功，原路线保留。") or updated
    end
    for key in pairs(original) do if draft[key] == nil then original[key] = nil end end
    for key, value in pairs(draft) do original[key] = value end
    WB:Emit("route.spot_changed", { questID = step.questID, objectiveKey = step.objectiveKey,
        mapID = plan.mapID, expiresAt = avoid.expiresAt })
    return { ok = true, questID = step.questID, objectiveKey = step.objectiveKey, expiresAt = avoid.expiresAt,
        avoidedRadius = spotRules.radius, duration = spotRules.duration, selected = updated.steps[1] }
end

function ns.ClearSpotAvoidances(args)
    if args == nil then args = {} end
    if type(args) ~= "table" or (args.questID ~= nil and not IsID(args.questID)) then
        return InvalidArguments("questID must be a positive integer when supplied")
    end
    local kept = {}
    for _, avoid in ipairs(route.spotAvoidances) do if args.questID and avoid.questID ~= args.questID then kept[#kept + 1] = avoid end end
    route.spotAvoidances = kept
    return RebuildRoute("manual")
end

function ns.ResetQuestSkips(args)
    if args ~= nil and type(args) ~= "table" then return InvalidArguments("args must be an object") end
    RouteSettings().skipped = {}
    return RebuildRoute("skips_reset")
end

function ns.SetRouteOptions(args)
    if type(args) ~= "table" then return InvalidArguments("args must be an object") end
    if args.enabled ~= nil and type(args.enabled) ~= "boolean" then return InvalidArguments("enabled must be a boolean") end
    if args.nameplatesEnabled ~= nil and type(args.nameplatesEnabled) ~= "boolean" then return InvalidArguments("nameplatesEnabled must be a boolean") end
    if args.moveThreshold ~= nil and (not IsFinite(args.moveThreshold) or args.moveThreshold < 10 or args.moveThreshold > 5000) then
        return InvalidArguments("moveThreshold must be from 10 to 5000")
    end
    local settings = RouteSettings()
    if args.enabled ~= nil then settings.enabled = args.enabled end
    if args.nameplatesEnabled ~= nil then settings.nameplatesEnabled = args.nameplatesEnabled end
    if args.moveThreshold ~= nil then settings.moveThreshold = args.moveThreshold end
    return RebuildRoute("options_changed")
end

-- 纯几何裁剪，不把地图外的线段连成一条虚假的地图内路线。
local function ClipSegment(ax, ay, bx, by)
    local dx, dy, low, high = bx - ax, by - ay, 0, 1
    local p, q = { -dx, dx, -dy, dy }, { ax, 1 - ax, ay, 1 - ay }
    for i = 1, 4 do
        if p[i] == 0 then
            if q[i] < 0 then return nil end
        else
            local value = q[i] / p[i]
            if p[i] < 0 then low = math.max(low, value) else high = math.min(high, value) end
            if low > high then return nil end
        end
    end
    return ax + low * dx, ay + low * dy, ax + high * dx, ay + high * dy
end

local function ProjectWorld(world, mapID)
    if not world then return nil end
    local ok, actualMap, point = pcall(C_Map.GetMapPosFromWorldPos,
        world.continentID, CreateVector2D(world.x, world.y), mapID)
    if ok and actualMap == mapID and point and IsFinite(point.x) and IsFinite(point.y) then
        return { x = point.x, y = point.y }
    end
end

local function NewMapView(map, canvas)
    local overlay = CreateFrame("Frame", nil, canvas)
    overlay:SetAllPoints(canvas)
    overlay:SetFrameLevel(canvas:GetFrameLevel() + 3000)
    overlay:EnableMouse(false)
    local view = { map = map, canvas = canvas, overlay = overlay, pins = {}, lines = {} }
    route.views[#route.views + 1] = view
    return view
end

local function ConfigureRoutePin(pin)
    pin:SetScript("OnClick", function(self)
        if self.step then
            local shift = Accessible(IsShiftKeyDown())
            if shift then
                local result = ns.ChangeQuestSpot({ questID = self.step.questID, objectiveKey = self.step.objectiveKey,
                    hotspotID = self.hotspot and self.hotspot.id })
                print("|cff31cee8YYQ升级路线|r " .. (result.ok and "已更换地点，旧点附近临时避开10分钟。" or result.error.message))
            else ns.SetQuestSkip({ questID = self.step.questID }) end
            route.hoveredPin = nil
            GameTooltip:Hide()
        end
    end)
    pin:SetScript("OnEnter", function(self)
        if not self.step then return end
        route.hoveredPin = self
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText((self.hotspot and (self.step.index .. self.hotspotLabel .. " 备选热点：") or (self.step.index .. ". "))
            .. (self.step.displayTitle or self.step.title))
        if self.hotspot then
            GameTooltip:AddLine(self.step.objective.text, 0.7, 1, 0.8)
            GameTooltip:AddLine("此处是备选区域，尚未接入主路线", 0.65, 0.8, 1)
            GameTooltip:AddLine("周围150码，数据库记录 " .. self.hotspot.pointCount .. " 处不同刷新位置", 0.7, 0.9, 1)
            GameTooltip:AddLine("静态分布不代表当前怪物数量或掉落概率", 0.7, 0.8, 0.9)
            GameTooltip:AddLine("Shift+右键：切换到这个热点", 1, 0.85, 0.3)
            GameTooltip:AddLine("右键：跳过整项任务", 0.6, 0.9, 1)
            GameTooltip:Show()
            return
        end
        if self.step.objective then
            GameTooltip:AddLine("当前目标：" .. self.step.objective.text, 0.7, 1, 0.8)
            GameTooltip:AddLine("位置来源：QuestieDB静态刷新点（可能出现的位置）", 0.65, 0.85, 1)
            local hotspot = self.step.hotspots and self.step.hotspots[1]
            if hotspot then
                GameTooltip:AddLine("热点周围150码记录 " .. hotspot.pointCount .. " 处不同刷新位置，另有 "
                    .. (#self.step.hotspots - 1) .. " 个地图备选", 0.7, 0.9, 1)
            end
        else
            GameTooltip:AddLine("位置：原生任务参考点", 0.65, 0.85, 1)
        end
        local navigation = self.step.navigation
        GameTooltip:AddLine(navigation and navigation.phase ~= "queued" and navigation.label
            or self.step.action == "turn_in" and "后续：前往交付任务"
            or self.step.action == "completion_pending" and "任务已完成，请确认交付信息" or "后续：前往任务区域", 1, 0.85, 0.3)
        if self.step.action == "turn_in" then
            GameTooltip:AddLine("日志已标记可交付；此处仍是原生任务参考点，交付位置以游戏提示为准", 0.75, 0.85, 1, true)
        end
        if navigation and navigation.phase == "working" then
            GameTooltip:AddLine("参考点只表示任务区域；目标完成以任务日志为准", 0.7, 0.85, 1)
            if navigation.stale then
                GameTooltip:AddLine("一段时间没有进展，已允许重新比较附近任务；也可主动 replan", 1, 0.75, 0.3)
            elseif navigation.reason == "recent_objective_progress" then
                GameTooltip:AddLine("最近有任务进展，继续完成这一带的目标", 0.6, 1, 0.7)
            end
            if navigation.objectivesAvailable == false then GameTooltip:AddLine("目标进度暂缺，等待客户端更新", 0.8, 0.85, 1) end
        end
        local priority = self.step.priority
        if priority then
            GameTooltip:AddLine(priorityLabels[priority.reason] or "按距离安排", 0.8, 0.9, 0.7)
            GameTooltip:AddLine(priority.experience.available and ("客户端奖励经验：" .. priority.experience.value)
                or "奖励经验尚未知", 0.75, 0.85, 1)
        end
        if self.step.groupSize and self.step.groupSize > 1 then
            GameTooltip:AddLine("同一区域，附近还有 " .. (self.step.groupSize - 1) .. " 个目标/交付点", 0.5, 1, 0.75)
            local shown = 0
            for _, step in ipairs(route.plan.steps) do
                if step.groupIndex == self.step.groupIndex and step.index ~= self.step.index then
                    GameTooltip:AddLine(step.index .. ". " .. (step.displayTitle or step.title), 0.75, 0.9, 0.85)
                    shown = shown + 1
                    if shown == 3 then break end
                end
            end
        end
        if self.step.index == 1 and route.plan.stability and route.plan.stability.retained then
            GameTooltip:AddLine("继续当前目标；可用 /yyqroute replan 重新选择", 0.7, 0.85, 1)
        end
        if self.shifted then GameTooltip:AddLine("编号为防重叠略作偏移，细线连接实际位置", 0.7, 0.85, 1) end
        if self.onEdge then GameTooltip:AddLine("目标在小地图视野外，边缘编号指示方向", 1, 0.7, 0.2) end
        if self.step.objectiveKey then GameTooltip:AddLine("Shift+右键换同目标地点（旧点150码内避开10分钟）", 1, 0.85, 0.3) end
        GameTooltip:AddLine("右键跳过整项任务 · /yyqroute unskip " .. self.step.questID .. " 恢复", 0.6, 0.9, 1)
        GameTooltip:Show()
    end)
    pin:SetScript("OnLeave", function(self)
        if route.hoveredPin == self then route.hoveredPin = nil end
        GameTooltip:Hide()
    end)
end

local function NewRoutePin(view)
    local pin = CreateFrame("Button", nil, view.overlay)
    pin:SetSize(24, 24)
    pin:RegisterForClicks("RightButtonUp")
    pin.background = pin:CreateTexture(nil, "BACKGROUND")
    pin.background:SetAllPoints(pin)
    pin.background:SetColorTexture(0.08, 0.12, 0.15, 0.95)
    pin.color = pin:CreateTexture(nil, "ARTWORK")
    pin.color:SetPoint("TOPLEFT", pin, "TOPLEFT", 2, -2)
    pin.color:SetPoint("BOTTOMRIGHT", pin, "BOTTOMRIGHT", -2, 2)
    pin.text = pin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pin.text:SetAllPoints(pin)
    pin.text:SetTextColor(1, 1, 1)
    ConfigureRoutePin(pin)
    return pin
end

local function SetRoutePinAppearance(pin, step, index)
    local delivery = step.action == "turn_in"
    if index == 1 then pin.color:SetColorTexture(0.95, 0.55, 0.05, 0.95)
    elseif delivery then pin.color:SetColorTexture(0.85, 0.65, 0.05, 0.95)
    else pin.color:SetColorTexture(0.05, 0.6, 0.75, 0.95) end
    pin.text:SetText(index .. (delivery and "?" or step.action == "completion_pending" and "~" or ""))
end

-- 多个未完目标可能共用同一刷新点，只错开编号，路线坐标和选点保持原值。
local function SeparatePin(placed, x, y, width, height, circular)
    local function Free(px, py)
        for _, point in ipairs(placed) do
            if math.abs(px - point.x) < 23 and math.abs(py - point.y) < 23 then return false end
        end
        return true
    end
    local px, py = x, y
    if not Free(x, y) then
        local found
        for ring = 1, 3 do
            for dx = -ring, ring do
                for dy = -ring, ring do
                    if math.abs(dx) == ring or math.abs(dy) == ring then
                        local cx, cy = x + dx * 24, y + dy * 24
                        local inside = circular and ((cx / (width / 2)) ^ 2 + (cy / (height / 2)) ^ 2 <= 0.9 ^ 2)
                            or not circular and cx >= 0 and cx <= width and cy >= 0 and cy <= height
                        if inside and Free(cx, cy) then px, py, found = cx, cy, true; break end
                    end
                end
                if found then break end
            end
            if found then break end
        end
    end
    placed[#placed + 1] = { x = px, y = py }
    return px, py, px ~= x or py ~= y
end

local function PinLeader(view, index, anchor, x, y, px, py, scale)
    view.leaders = view.leaders or {}
    local line = view.leaders[index]
    if math.abs(x - px) > 0.001 or math.abs(y - py) > 0.001 then
        if not line then line = view.overlay:CreateLine(nil, "ARTWORK"); view.leaders[index] = line end
        line:SetColorTexture(0.7, 0.9, 1, 0.85)
        line:SetThickness(1 / scale)
        line:SetStartPoint(anchor, view.overlay, x, y)
        line:SetEndPoint(anchor, view.overlay, px, py)
        line:Show()
    elseif line then line:Hide() end
end

local RenderAlternativePins

local function RenderMap(view, plan, player)
    if not view.map:IsShown() or not plan.enabled then view.overlay:Hide(); return end
    local mapID = view.map.GetMapID and view.map:GetMapID()
    local width, height = view.canvas:GetWidth(), view.canvas:GetHeight()
    if not IsID(mapID) or mapID ~= plan.mapID or not IsFinite(width) or not IsFinite(height) or width <= 0 or height <= 0 then
        view.overlay:Hide(); return
    end
    if view.sequence ~= plan.sequence or view.mapID ~= mapID then
        view.positions, view.alternativePositions = {}, {}
        for index, step in ipairs(plan.steps) do view.positions[index] = ProjectWorld(step.world, mapID) end
        view.sequence, view.mapID = plan.sequence, mapID
    end
    view.overlay:SetFrameLevel(view.canvas:GetFrameLevel() + 3000)
    view.overlay:Show()
    local scale = view.canvas:GetScale()
    if not IsFinite(scale) or scale <= 0 then scale = 1 end
    local previous = player and ProjectWorld(player.world, mapID)
    local placed = {}
    for _, leader in pairs(view.leaders or {}) do leader:Hide() end
    for index, step in ipairs(plan.steps) do
        local position = view.positions[index]
        local pin = view.pins[index]
        if position and position.x >= 0 and position.x <= 1 and position.y >= 0 and position.y <= 1 then
            if not pin then pin = NewRoutePin(view); view.pins[index] = pin end
            pin.step = step
            pin:SetScale(1 / scale)
            pin:ClearAllPoints()
            -- 偏移量按逆缩放后的编号解释；单独细线连接未改变的真实地图点。
            local x, y = position.x * width * scale, position.y * height * scale
            local px, py, shifted = SeparatePin(placed, x, y, width * scale, height * scale)
            pin.shifted = shifted
            pin:SetPoint("CENTER", view.overlay, "TOPLEFT", px, -py)
            PinLeader(view, index, "TOPLEFT", x / scale, -y / scale, px / scale, -py / scale, scale)
            SetRoutePinAppearance(pin, step, index)
            pin:Show()
        elseif pin then pin:Hide() end
        local line = view.lines[index]
        local ax, ay, bx, by
        if previous and position then ax, ay, bx, by = ClipSegment(previous.x, previous.y, position.x, position.y) end
        if ax then
            if not line then
                line = view.overlay:CreateLine(nil, "ARTWORK")
                line:SetColorTexture(0.1, 0.85, 1, 0.8)
                view.lines[index] = line
            end
            line:SetThickness(2 / scale)
            line:SetStartPoint("TOPLEFT", view.overlay, ax * width, -ay * height)
            line:SetEndPoint("TOPLEFT", view.overlay, bx * width, -by * height)
            line:Show()
        elseif line then line:Hide() end
        previous = position
    end
    for i, pin in pairs(view.pins) do if i > #plan.steps then pin:Hide() end end
    for i, line in pairs(view.lines) do if i > #plan.steps then line:Hide() end end
    RenderAlternativePins(view, plan, placed, width, height, scale, mapID)
end

local function RenderRouteMaps()
    local plan = route.plan
    if not plan then return end
    for _, map in pairs({ WorldMapFrame = WorldMapFrame, BattlefieldMapFrame = BattlefieldMapFrame }) do
        if map and map.GetCanvas and map.GetMapID then
            local canvas = map:GetCanvas()
            if canvas then
                local found
                for _, view in ipairs(route.views) do if view.map == map and view.canvas == canvas then found = view; break end end
                if not found then found = NewMapView(map, canvas) end
                RenderMap(found, plan, route.playerLocation)
            end
        end
    end
end

-- 小地图以玩家为中心，世界x向北、y向西；视野半径直接取客户端API。
local function MinimapPosition(world, origin, radius, cosine, sine)
    if not world or world.continentID ~= origin.continentID then return nil end
    local east, north = (origin.y - world.y) / radius, (world.x - origin.x) / radius
    return { x = east * cosine + north * sine, y = north * cosine - east * sine }
end

RenderAlternativePins = function(view, plan, placed, width, height, scale, mapID, origin, radius, cosine, sine)
    view.alternatives = view.alternatives or {}
    for _, pin in pairs(view.alternatives) do pin:Hide(); pin.step, pin.hotspot = nil, nil end
    local circular, serial = origin ~= nil, 0
    for _, step in ipairs(plan.steps) do
        for slot = 2, #(step.hotspots or {}) do
            local hotspot = step.hotspots[slot]
            local position
            if circular then position = MinimapPosition(hotspot.world, origin, radius, cosine, sine)
            else
                local key = step.stepKey .. ":" .. hotspot.id
                position = view.alternativePositions[key]
                if position == nil then
                    position = ProjectWorld(hotspot.world, mapID) or false
                    view.alternativePositions[key] = position
                end
            end
            local visible = position and (circular and position.x ^ 2 + position.y ^ 2 <= 0.84 ^ 2
                or not circular and position.x >= 0 and position.x <= 1 and position.y >= 0 and position.y <= 1)
            if visible then
                serial = serial + 1
                local pin = view.alternatives[serial]
                if not pin then pin = NewRoutePin(view); pin:SetSize(20, 20); view.alternatives[serial] = pin end
                pin.step, pin.hotspot, pin.hotspotLabel, pin.onEdge = step, hotspot, slot == 2 and "b" or "c", false
                pin:SetScale(1 / scale)
                local x, y = position.x * width * scale, position.y * height * scale
                if circular then x, y = position.x * width / 2, position.y * height / 2 end
                local px, py, shifted = SeparatePin(placed, x, y, width * scale, height * scale, circular)
                pin.shifted = shifted
                pin:ClearAllPoints()
                pin:SetPoint("CENTER", view.overlay, circular and "CENTER" or "TOPLEFT", px, circular and py or -py)
                PinLeader(view, #plan.steps + serial, circular and "CENTER" or "TOPLEFT",
                    x / scale, (circular and y or -y) / scale, px / scale, (circular and py or -py) / scale, scale)
                pin.color:SetColorTexture(0.28, 0.27, 0.6, 0.85)
                pin.text:SetText(step.index .. pin.hotspotLabel)
                pin:Show()
            end
        end
    end
end

local function ClipMinimapSegment(ax, ay, bx, by, radius)
    local dx, dy = bx - ax, by - ay
    local a = dx * dx + dy * dy
    if a == 0 then return nil end
    local b, c = ax * dx + ay * dy, ax * ax + ay * ay - radius * radius
    local discriminant = b * b - a * c
    if discriminant < 0 then return nil end
    local root = math.sqrt(discriminant)
    local low, high = math.max(0, (-b - root) / a), math.min(1, (-b + root) / a)
    if low >= high then return nil end
    return ax + low * dx, ay + low * dy, ax + high * dx, ay + high * dy
end

local function RenderMinimapRoute()
    if not Minimap then return end
    local view = route.minimapView
    local plan, player = route.plan, route.playerLocation
    if not plan or not plan.enabled or not Minimap:IsVisible() or not player or not player.world
        or player.coordinateMapID ~= plan.mapID or #plan.steps == 0 then
        if view then view.overlay:Hide() end
        return
    end
    local radius = C_Minimap.GetViewRadius()
    local width, height = Minimap:GetWidth(), Minimap:GetHeight()
    local rotating, ignored = C_CVar.GetCVarBool("rotateMinimap"), C_Minimap.IsRotateMinimapIgnored()
    local cosine, sine = 1, 0
    if canaccessvalue(rotating) and rotating and canaccessvalue(ignored) and not ignored then
        local facing = GetPlayerFacing()
        if not IsFinite(facing) then if view then view.overlay:Hide() end; return end
        cosine, sine = math.cos(facing), math.sin(facing)
    end
    if not IsFinite(radius) or radius <= 0 or not IsFinite(width) or not IsFinite(height) or width <= 0 or height <= 0 then
        if view then view.overlay:Hide() end
        return
    end
    if not view then
        local overlay = CreateFrame("Frame", nil, Minimap)
        overlay:SetAllPoints(Minimap)
        overlay:EnableMouse(false)
        view = { overlay = overlay, pins = {}, lines = {} }
        route.minimapView = view
    end
    view.overlay:SetFrameLevel(Minimap:GetFrameLevel() + 5)
    view.overlay:Show()
    for _, pin in pairs(view.pins) do pin:Hide() end
    for _, line in pairs(view.lines) do line:Hide() end
    for _, leader in pairs(view.leaders or {}) do leader:Hide() end
    local placed = {}
    local previous = { x = 0, y = 0 }
    for index, step in ipairs(plan.steps) do
        local position = MinimapPosition(step.world, player.world, radius, cosine, sine)
        if position then
            local length = math.sqrt(position.x * position.x + position.y * position.y)
            local onEdge = length > 0.84
            if not onEdge or index == 1 then
                local x, y = position.x, position.y
                if onEdge then x, y = x * 0.84 / length, y * 0.84 / length end
                local pin = view.pins[index]
                if not pin then pin = NewRoutePin(view); pin:SetSize(20, 20); view.pins[index] = pin end
                pin.step, pin.onEdge = step, onEdge
                pin:ClearAllPoints()
                local px, py, shifted = SeparatePin(placed, x * width / 2, y * height / 2, width, height, true)
                pin.shifted = shifted
                pin:SetPoint("CENTER", view.overlay, "CENTER", px, py)
                PinLeader(view, index, "CENTER", x * width / 2, y * height / 2, px, py, 1)
                SetRoutePinAppearance(pin, step, index)
                pin:Show()
            end
        end
        -- 裁剪实际端点，不连接边缘方向标记，以免画出不真实的后续路线。
        if previous and position then
            local ax, ay, bx, by = ClipMinimapSegment(previous.x, previous.y, position.x, position.y, 0.9)
            if ax then
                -- 第一段在玩家箭头旁留空，保留中心角色标记可见性。
                if index == 1 then
                    local length = math.sqrt(bx * bx + by * by)
                    if length > 0.07 then ax, ay = bx * 0.07 / length, by * 0.07 / length else ax = nil end
                end
                if ax then
                    local line = view.lines[index]
                    if not line then line = view.overlay:CreateLine(nil, "ARTWORK"); view.lines[index] = line end
                    line:SetColorTexture(index == 1 and 1 or 0.1, index == 1 and 0.65 or 0.85, index == 1 and 0.1 or 1, 0.9)
                    line:SetThickness(2.5)
                    line:SetStartPoint("CENTER", view.overlay, ax * width / 2, ay * height / 2)
                    line:SetEndPoint("CENTER", view.overlay, bx * width / 2, by * height / 2)
                    line:Show()
                end
            end
        end
        previous = position
    end
    RenderAlternativePins(view, plan, placed, width, height, 1, plan.mapID, player.world, radius, cosine, sine)
end

-- 只读当前可见单位身份；每次刷新重新读取，不延用受限前的NPC ID。
local function UnitRead(func, ...)
    if type(func) ~= "function" then return nil, "api_unavailable" end
    local ok, value = pcall(func, ...)
    if not ok then return nil, "unit_read_error" end
    if not canaccessvalue(value) then return nil, "restricted_identity" end
    return value
end

function ns.GetUnitTasks(args)
    if args == nil then args = {} end
    if type(args) ~= "table" then return InvalidArguments("args must be an object") end
    local unit = args.unit
    if unit == nil then unit = "target" end
    if type(unit) ~= "string" or not (unit == "target" or unit == "mouseover" or unit:match("^nameplate%d+$")) then
        return InvalidArguments("unit must be target, mouseover or nameplateN")
    end
    local index = route.mobIndex or { byNPC = {}, unresolvedQuestCount = 1 }
    local result = { ok = true, schemaVersion = 1, apiRevision = ns.apiRevision, unit = unit,
        state = "unknown", needed = false, tasks = {}, unresolvedQuestCount = index.unresolvedQuestCount,
        observedAt = GetTime(), progressObservedAt = index.observedAt,
        policy = "client_progress_verified_database_identity", progressSource = "C_QuestLog.GetQuestObjectives",
        relationSource = "QuestieDB" }
    if route.dirty then result.reason = "quest_data_updating"; return result end
    local exists, why = UnitRead(UnitExists, unit)
    if exists ~= true then result.reason = why or "unit_unavailable"; return result end
    local player, playerWhy = UnitRead(UnitIsPlayer, unit)
    local attack, attackWhy = UnitRead(UnitCanAttack, "player", unit)
    local dead, deadWhy = UnitRead(UnitIsDeadOrGhost, unit)
    if player == nil or attack == nil or dead == nil then
        result.reason = playerWhy or attackWhy or deadWhy or "unit_state_unavailable"; return result
    end
    if player or not attack or dead then result.state, result.reason = "not_eligible", "not_live_attackable_npc"; return result end
    local id, idWhy = UnitRead(UnitCreatureID, unit)
    if not IsID(id) then result.reason = idWhy or "creature_identity_unavailable"; return result end
    result.npcID = id
    local current = route.plan and route.plan.steps[1]
    local known, pending = 0, {}
    for _, task in ipairs(index.byNPC[id] or {}) do
        known = known + 1
        result.tasks[#result.tasks + 1] = task
        if task.finished == false then
            pending[#pending + 1] = task
            if current and task.questID == current.questID and task.objectiveKey == current.objectiveKey then result.currentTarget = true end
        end
    end
    result.knownGoalCount, result.neededCount = known, #pending
    if #pending > 0 then
        result.state, result.reason, result.needed = "needed", "verified_unfinished_goal", true
        local labels = {}
        for i = 1, math.min(2, #pending) do
            local task = pending[i]
            local count = IsFinite(task.numFulfilled) and IsFinite(task.numRequired)
                and (" " .. task.numFulfilled .. "/" .. task.numRequired) or ""
            labels[#labels + 1] = (task.relation == "kill" and "击杀" or "材料") .. count
        end
        result.label = table.concat(labels, " · ") .. (#pending > 2 and (" +" .. (#pending - 2)) or "")
    elseif index.unresolvedQuestCount > 0 then result.reason = "some_task_relations_unknown"
    elseif known > 0 then result.state, result.reason = "no_remaining_known_goals", "known_goals_finished"
    else result.state, result.reason = "no_known_match", "no_verified_task_relation" end
    return result
end

route.nameplateView = route.nameplateView or { markers = {} }

local function HideTaskMarkers(unit)
    for _, marker in pairs(route.nameplateView.markers) do
        if not unit or marker.unit == unit then marker:Hide(); marker.unit, marker.info = nil, nil end
    end
end

local function PlateAllowed(plate)
    if not plate then return false end
    if plate.IsForbidden then
        local ok, forbidden = pcall(plate.IsForbidden, plate)
        if not ok or not canaccessvalue(forbidden) or forbidden then return false end
    end
    return true
end

local function RenderTaskNameplates()
    HideTaskMarkers()
    local settings = RouteSettings()
    if not route.running or not settings.enabled or settings.nameplatesEnabled == false or route.dirty
        or not C_NamePlate or type(C_NamePlate.GetNamePlates) ~= "function" then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        if PlateAllowed(plate) then
            local frame = Accessible(plate.UnitFrame)
            local unit = Accessible(plate.namePlateUnitToken) or frame and Accessible(frame.unit)
            if type(unit) == "string" and unit:match("^nameplate%d+$") then
                local info = ns.GetUnitTasks({ unit = unit })
                if info.needed then
                    local marker = route.nameplateView.markers[plate]
                    if not marker then
                        marker = CreateFrame("Frame", nil, plate)
                        marker:SetSize(180, 18)
                        marker:EnableMouse(false)
                        marker:SetPoint("BOTTOM", plate, "TOP", 0, 2)
                        marker.text = marker:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                        marker.text:SetAllPoints(marker)
                        route.nameplateView.markers[plate] = marker
                    end
                    marker.unit, marker.info = unit, info
                    marker.text:SetText("! " .. info.label)
                    marker.text:SetTextColor(1, info.currentTarget and 0.55 or 0.85, info.currentTarget and 0.1 or 0.25)
                    marker:Show()
                end
            end
        end
    end
end

local function RouteTick(_, elapsed)
    route.elapsed = (route.elapsed or 0) + elapsed
    if route.elapsed < 0.1 then return end
    route.elapsed = 0
    local now = GetTime()
    if route.dirty and now >= (route.due or 0) then RebuildRoute(route.pendingReason or "quest_update") end
    if route.nextRewardCheck and now >= route.nextRewardCheck then RebuildRoute("reward_cache_refresh") end
    if route.nextLocationCheck and now >= route.nextLocationCheck then RebuildRoute("location_data_refresh") end
    if route.nextObjectiveCheck and now >= route.nextObjectiveCheck then RebuildRoute("objective_data_refresh") end
    if route.nextSpotCheck and now >= route.nextSpotCheck then RebuildRoute("spot_avoidance_expired") end
    if now >= (route.nextNameplateCheck or 0) then
        route.nextNameplateCheck = now + 0.5
        RenderTaskNameplates()
    end
    if now >= (route.nextPositionCheck or 0) then
        route.nextPositionCheck = now + 0.5
        local context = ns.GetPlayerContext({})
        route.playerLocation = context.location
        local current = route.playerLocation.world
        local distance = DistanceSquared(current, route.lastOrigin)
        local threshold = RouteSettings().moveThreshold
        if route.playerLocation.coordinateMapID ~= route.plan.mapID then
            RebuildRoute("player_map_changed")
        elseif context.character.level ~= route.plan.levelPriority.referenceLevel then
            RebuildRoute("player_level_changed")
        elseif current and (not route.lastOrigin or not distance or distance >= threshold * threshold) then
            RebuildRoute("player_moved")
        else
            local previous = route.plan.navigation
            if UpdateNavigation(route.plan, context.location, now, previous) then
                RebuildRoute(previous and previous.phase == "unavailable" and "player_position_recovered" or "work_protection_ended")
            end
        end
    end
    RenderRouteMaps()
    RenderMinimapRoute()
    if route.hoveredPin and now >= (route.nextTooltipUpdate or 0) then
        route.nextTooltipUpdate = now + 0.5
        local pin = route.hoveredPin
        if pin.step and pin:IsVisible() then pin:GetScript("OnEnter")(pin)
        else route.hoveredPin = nil; GameTooltip:Hide() end
    end
end

function ns.StartRoute()
    if not IsLoggedIn() or route.running then return end
    route.running = true
    -- 工作时间只属于当前UI；热加载也不沿用旧版本未完成的导航计时。
    if route.plan then route.plan.navigation = nil end
    route.lastNavigationEvent, route.workSession, route.suspendedObjectiveSession = nil, nil, nil
    RebuildRoute("startup")
    -- 复用图元时也更新回调，保证热加载后悬停说明使用本轮逻辑。
    for _, view in ipairs(route.views) do
        for _, pin in pairs(view.pins) do ConfigureRoutePin(pin) end
        for _, pin in pairs(view.alternatives or {}) do ConfigureRoutePin(pin) end
    end
    if route.minimapView then
        for _, pin in pairs(route.minimapView.pins) do ConfigureRoutePin(pin) end
        for _, pin in pairs(route.minimapView.alternatives or {}) do ConfigureRoutePin(pin) end
    end
    local driver = route.driver or CreateFrame("Frame")
    route.driver = driver
    driver:UnregisterAllEvents()
    driver:RegisterEvent("QUEST_LOG_UPDATE")
    driver:RegisterEvent("PLAYER_ENTERING_WORLD")
    driver:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    driver:RegisterEvent("QUEST_DATA_LOAD_RESULT")
    driver:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    driver:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    driver:SetScript("OnEvent", function(_, event, questID)
        if event == "NAME_PLATE_UNIT_ADDED" then RenderTaskNameplates(); return end
        if event == "NAME_PLATE_UNIT_REMOVED" then HideTaskMarkers(questID); return end
        HideTaskMarkers()
        if event == "QUEST_DATA_LOAD_RESULT" and not (route.activeQuestIDs and route.activeQuestIDs[questID]) then return end
        if not route.dirty then route.due = GetTime() + 0.5 end
        route.dirty, route.pendingReason = true, event
    end)
    driver:SetScript("OnUpdate", RouteTick)
    driver:Show()
    RenderTaskNameplates()
    RenderRouteMaps()
    RenderMinimapRoute()
end

SLASH_YYQROUTE1 = "/yyqroute"
SlashCmdList["YYQROUTE"] = function(text)
    local command, value = (text or ""):match("^(%S*)%s*(.-)%s*$")
    local result
    if command == "skip" then result = ns.SetQuestSkip({ questID = tonumber(value) })
    elseif command == "unskip" then
        result = value == "all" and ns.ResetQuestSkips({}) or ns.SetQuestSkip({ questID = tonumber(value), skipped = false })
    elseif command == "distance" then result = ns.SetRouteOptions({ moveThreshold = tonumber(value) or false })
    elseif command == "on" or command == "off" then result = ns.SetRouteOptions({ enabled = command == "on" })
    elseif command == "replan" then result = ns.Replan({})
    elseif command == "nextspot" then
        local id
        if value ~= "" then id = tonumber(value) or false end
        result = ns.ChangeQuestSpot({ questID = id })
    elseif command == "resetspots" then
        local id
        if value ~= "" and value ~= "all" then id = tonumber(value) or false end
        result = ns.ClearSpotAvoidances({ questID = id })
    elseif command == "nameplates" then
        result = (value == "on" or value == "off") and ns.SetRouteOptions({ nameplatesEnabled = value == "on" })
            or InvalidArguments("用法：/yyqroute nameplates on/off")
    else
        local plan = ns.GetPlan({})
        print("|cff31cee8YYQ升级路线|r " .. plan.count .. " 个目标/交付点（" .. plan.questCount .. " 个任务），移动 " .. plan.moveThreshold .. " 码重排。")
        print("/yyqroute skip ID · unskip ID/all · distance 100 · replan · on/off")
        print("Shift+右键换地点 · nextspot [ID] · resetspots [ID/all] · nameplates on/off")
        return
    end
    if result.ok then print("|cff31cee8YYQ升级路线|r " .. (command == "nextspot" and "已换地点，旧点附近避开10分钟。" or "已更新路线。")) else print(result.error.message) end
end

WB:Expose("get_plan", ns.GetPlan, "获取当前地图升级与交付路线。已完成任务按原生位置每项一交付步，不因副本/精英/专业类型排除，手动跳过/失败/外图仍排除；turnInCount和completionPendingCount给交付及等待确认数。navigation给travel/working/turn_in/completion_pending/idle/unavailable，每0.5秒更新，到点不代表交付成功。保留难度/奖励、热点、归组及稳定。args:{}。")
WB:Expose("replan", ns.Replan, "主动按当前位置重新选1号并归组，绕过目标保持。采用原生难度/奖励校准的直线距离，不放弃或选择任务。args:{}。")
WB:Expose("set_quest_skip", ns.SetQuestSkip, "标注自己的路线跳过任务，不放弃任务。args:questID，skipped默认true；false恢复。按角色保存。")
WB:Expose("reset_quest_skips", ns.ResetQuestSkips, "恢复当前角色所有手动跳过的任务。args:{}。")
WB:Expose("set_route_options", ns.SetRouteOptions, "自己的路线选项。args:可选moveThreshold=10..5000（默认100码）、enabled同时控制地图/标识、nameplatesEnabled单独控制任务姓名板（默认true），均为boolean。")
WB:Expose("change_quest_spot", ns.ChangeQuestSpot, "换同一未完目标的本图热点。args:questID可选默认1号；objectiveKey可选需questID。hotspotID可选需同时带questID/objectiveKey，取get_plan.steps[].hotspots[].id以指定备选；省略选其他最近热点。旧点150码内避开600秒，无备选保留路线/跳过。")
WB:Expose("clear_spot_avoidances", ns.ClearSpotAvoidances, "清理本UI临时地点避让并主动重排；args:可选questID，不给则清全部。不改变任务跳过。")
WB:Expose("get_unit_tasks", ns.GetUnitTasks, "只读当前可访问单位的任务用途。args:unit=target/mouseover/nameplateN，默认target。官方进度+唯一核验数据库身份/直接NPC掉落，needed优先；未知/无已知匹配不等于确定无关。战斗身份不可访问时unknown，不延用旧ID。")

function ns.OnUnload()
    HideTaskMarkers()
    if route.hoveredPin then route.hoveredPin = nil; GameTooltip:Hide() end
    route.running = false
    if route.driver then route.driver:UnregisterAllEvents(); route.driver:SetScript("OnUpdate", nil); route.driver:SetScript("OnEvent", nil) end
    if ns.loginFrame then ns.loginFrame:UnregisterAllEvents() end
    for _, view in ipairs(route.views) do
        view.overlay:Hide()
        view.sequence = nil
        for _, pin in pairs(view.pins) do pin:Hide(); pin.step = nil end
        for _, pin in pairs(view.alternatives or {}) do pin:Hide(); pin.step, pin.hotspot = nil, nil end
        for _, line in pairs(view.lines) do line:Hide() end
        for _, leader in pairs(view.leaders or {}) do leader:Hide() end
    end
    if route.minimapView then
        local view = route.minimapView
        view.overlay:Hide()
        for _, pin in pairs(view.pins) do pin:Hide(); pin.step = nil end
        for _, pin in pairs(view.alternatives or {}) do pin:Hide(); pin.step, pin.hotspot = nil, nil end
        for _, line in pairs(view.lines) do line:Hide() end
        for _, leader in pairs(view.leaders or {}) do leader:Hide() end
    end
end

function ns.OnReload()
    ns.StartRoute()
    WB:Emit("api.ready", { schemaVersion = 1, apiRevision = ns.apiRevision })
end

-- 正常登录与热加载共用初始化，不依赖在热加载中重发登录事件。
ns.loginFrame = ns.loginFrame or CreateFrame("Frame")
ns.loginFrame:UnregisterAllEvents()
ns.loginFrame:RegisterEvent("PLAYER_LOGIN")
ns.loginFrame:SetScript("OnEvent", function() ns.StartRoute() end)
if IsLoggedIn() then ns.StartRoute() end
