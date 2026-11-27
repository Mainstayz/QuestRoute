-- QuestieDB 发现、坐标转换与只读实体/任务补充；原生状态由 QuestData 提供。
local _, ns = ...
local Util = ns.Util
local InvalidArguments, IsFinite, IsID = Util.InvalidArguments, Util.IsFinite, Util.IsID
local ParsePage, AddPage, ToWorld = Util.ParsePage, Util.AddPage, Util.ToWorld

-- 动态发现数据库：不在文件加载时持有它，未安装或尚未加载也能使用原生接口。
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

local function ReadLocations(db, entity, id, onlyMapID, checkpoint)
    local mapping, locations = AreaMapping(db), {}
    local spawns = entity.spawns(id) or {}
    local areas = {}
    for area in pairs(spawns) do
        if IsFinite(area) and (not onlyMapID or mapping[area] == onlyMapID) then areas[#areas + 1] = area end
    end
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
            if checkpoint then checkpoint() end
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

ns.Database = { Get = GetDatabase, AreaMapping = AreaMapping, ReadLocations = ReadLocations, ReadQuest = ReadDatabaseQuest }
