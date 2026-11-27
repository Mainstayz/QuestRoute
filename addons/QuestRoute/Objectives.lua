-- 官方目标进度与 QuestieDB 身份精确匹配，补充可靠的静态地点。
local _, ns = ...
local Util, QuestData = ns.Util, ns.QuestData
local InvalidArguments, IsFinite, IsID, Accessible = Util.InvalidArguments, Util.IsFinite, Util.IsID, Util.Accessible
local ParsePage, AddPage = Util.ParsePage, Util.AddPage
local ReadQuest, ActiveQuestIndex, CollectPOIs = QuestData.ReadQuest, QuestData.ActiveQuestIndex, QuestData.CollectPOIs
local GetDatabase, ReadLocations = ns.Database.Get, ns.Database.ReadLocations

-- 官方finished/数量为准；只在任务内完整、唯一的精确文本对应后使用数据库静态点。
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

-- 刷新点展开结果的跨次缓存（key=kind:id，值=ReadLocations 返回的完整、未过滤的 locations，含外图点）。
-- 绑定数据库身份：db 对象或 info.version 变化即整体作废；固定容量，满后整体清空再写入；
-- OnUnload 通过 ResetLocationCache 清空。缓存内的 location/world 表只读，下游只读取字段。
local locationCacheLimit = 256

local function NewLocationCache(db, version)
    return { db = db, version = version, entries = {}, count = 0 }
end

local sharedLocationCache = NewLocationCache()

local function SharedLocationCache(db, info)
    if not db then return NewLocationCache() end
    local version = type(info) == "table" and info.version or nil
    if sharedLocationCache.db ~= db or sharedLocationCache.version ~= version then
        sharedLocationCache = NewLocationCache(db, version)
    end
    return sharedLocationCache
end

local function ResetLocationCache()
    sharedLocationCache = NewLocationCache()
end

-- 仅供测试/诊断：当前共享缓存的条目数与容量。
local function LocationCacheSize()
    return sharedLocationCache.count, locationCacheLimit
end

-- 只缓存「完整」结果：凡是稍后可能自行恢复的失败一律不缓存。
-- 判据（对应 Database.ReadLocations 的逐点分支）：
--   available 但 world 为 nil：C_Map.GetWorldPosFromMapPos 暂不可用，不缓存；
--   reason=unsupported_map：C_Map.GetMapInfo 暂返回 nil，不缓存；
--   reason=map_mapping_missing：区域→地图映射暂缺，保守不缓存；
--   空结果：spawns 暂缺，保守不缓存。
-- 其余（available 且有 world，或 instance_only/invalid_coordinates/map_suppressed 这类由静态数据决定的不可用）可缓存。
local function CacheableLocations(locations)
    if type(locations) ~= "table" or #locations == 0 then return false end
    for _, location in ipairs(locations) do
        if location.available then
            if not location.world then return false end
        elseif location.reason == "unsupported_map" or location.reason == "map_mapping_missing" then
            return false
        end
    end
    return true
end

local function StoreLocations(cache, key, locations)
    if not CacheableLocations(locations) then return end
    if cache.count >= locationCacheLimit then cache.entries, cache.count = {}, 0 end
    cache.entries[key] = locations
    cache.count = cache.count + 1
end

local function ResolveObjectiveLocations(db, info, quest, cache, identities, playerLevel)
    local result = identities or ReadObjectiveIdentities(db, info, quest)
    local combatLevels = {}
    local maxOffset = IsID(playerLevel) and ns.RouteOptions.Get().maxMonsterLevelOffset
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
            local uniqueSources, seenSources = {}, {}
            for _, source in ipairs(sources) do
                local key = source.kind .. ":" .. source.id
                if not seenSources[key] then
                    seenSources[key] = true
                    uniqueSources[#uniqueSources + 1] = source
                end
            end
            sources = uniqueSources
            if IsID(playerLevel) then
                local allowed = {}
                for _, source in ipairs(sources) do
                    if ns.RouteOptions.TargetAboveLevel(db, { entityKind = source.kind, entityID = source.id }, playerLevel, combatLevels, maxOffset) then
                        result.unsafeSourcesExcluded = true
                    else allowed[#allowed + 1] = source end
                end
                sources = allowed
                if #sources == 0 then return Fallback("target_above_level") end
            end
            local pointCount, token = 0, {}
            for _, source in ipairs(sources) do
                local key = source.kind .. ":" .. source.id
                local locations = cache.entries[key]
                if not locations then
                    local entity = source.kind == "npc" and db.Npc or db.Object
                    if not entity or not entity.Exists(source.id) then return Fallback("source_entity_missing") end
                    locations = ReadLocations(db, entity, source.id)
                    StoreLocations(cache, key, locations)
                end
                if token and cache.entries[key] == locations then
                    token[#token + 1] = locations
                else
                    token = nil
                end
                if #locations > 1200 then return Fallback("too_many_spawn_locations") end
                for _, location in ipairs(locations) do
                    if location.available and not location.world and (location.phase == nil or location.phase == 0) then
                        return Fallback("world_position_unavailable")
                    end
                    if location.available and location.world and (location.phase == nil or location.phase == 0) then
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
            if pointCount == 0 then return Fallback("objective_locations_unavailable") end
            if #result.points > 2400 then return Fallback("too_many_target_locations") end
            if token and #token > 0 then
                result.sourceTokens = result.sourceTokens or {}
                result.sourceTokens[objective.key] = token
            end
        end
    end
    if remaining == 0 then return Fallback("objectives_finished_waiting_quest_state") end
    result.mode, result.reason, result.remainingCount = "objective_locations", "exact_mapping_complete", remaining
    return result
end

local function ReadObjectiveLocations(db, info, quest, cache, identities, playerLevel)
    local ok, result = pcall(ResolveObjectiveLocations, db, info, quest, cache or NewLocationCache(), identities, playerLevel)
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

ns.Objectives = { ReadIdentities = ReadObjectiveIdentities, ReadLocations = ReadObjectiveLocations,
    SharedLocationCache = SharedLocationCache, ResetLocationCache = ResetLocationCache, LocationCacheSize = LocationCacheSize }
