-- 当前地图的任务关联与接取机会；静态坐标不表示实体当前存在。
local _, ns = ...
local Util = ns.Util
local Accessible, IsID, IsFinite = Util.Accessible, Util.IsID, Util.IsFinite
local GetDatabase, ReadLocations = ns.Database.Get, ns.Database.ReadLocations
local batchSize, cellSize = 64, 400
local battlegroundSorts = { [-25] = true, [2597] = true, [3277] = true, [3358] = true, [16603] = true, [16653] = true }
local holidaySorts = { [-404] = true, [-402] = true, [-378] = true, [-376] = true, [-375] = true,
    [-374] = true, [-370] = true, [-369] = true, [-366] = true, [-365] = true, [-364] = true,
    [-41] = true, [-22] = true, [-21] = true }
local cache, indexDB, questIDs

local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return Accessible(a), Accessible(b), Accessible(c) end
end

local function Table(value)
    value = Accessible(value)
    if type(value) == "table" then return value end
end

local function World(value)
    value = Table(value)
    if value and IsFinite(value.continentID) and IsFinite(value.x) and IsFinite(value.y) then
        return { continentID = value.continentID, x = value.x, y = value.y }
    end
end

local function Distance(a, b)
    local squared = a and b and Util.DistanceSquared(a, b)
    if IsFinite(squared) and squared >= 0 then return math.sqrt(squared) end
end

local function Key(kind, id)
    if (kind == "npc" or kind == "object" or kind == "item") and IsID(id) then return kind .. ":" .. id end
end

local function Point(point, shareable)
    point = Table(point)
    if not point then return end
    local world = World(point.world)
    if not world or not IsID(point.coordinateMapID) or not IsFinite(point.x) or not IsFinite(point.y)
        or point.x < 0 or point.x > 1 or point.y < 0 or point.y > 1 then return end
    local kind, id = Accessible(point.entityKind), Accessible(point.entityID)
    local key = Accessible(point.objectiveKey) or Accessible(point.key) or Key(kind, id) or "quest"
    if type(key) ~= "string" or (key ~= "quest" and not key:match("^[a-z]+:%d+$")) then return end
    return { key = key, world = world, coordinateMapID = point.coordinateMapID,
        reportedMapID = Accessible(point.reportedMapID), x = point.x, y = point.y,
        entityKind = kind, entityID = id, entityName = Accessible(point.entityName), shareable = shareable == true and key ~= "quest",
        relation = Accessible(point.relation),
        source = Accessible(point.source), precision = Accessible(point.precision),
        objectiveKey = Accessible(point.objectiveKey) }
end

local function CopyList(list)
    local out = {}
    for _, value in ipairs(list or {}) do out[#out + 1] = value end
    return out
end

local function IDs(value, record)
    local out, seen = {}, {}
    if value == nil then return out end
    if type(value) ~= "table" then record.invalidConditions = true; return out end
    local count = 0
    for index, id in pairs(value) do
        count = count + 1
        if not IsID(index) or index > #value or not IsID(id) then record.invalidConditions = true
        elseif not seen[id] then out[#out + 1], seen[id] = id, true end
    end
    if count ~= #value then record.invalidConditions = true end
    table.sort(out)
    return out
end

local function Field(db, key, id, record)
    local quest = db.Quest
    if type(quest[key]) == "function" then return quest[key](id) end
    if type(quest.Get) == "function" then return quest.Get(id, key) end
    if record then record.conditionsKnown = false end
end

local function Checkpoint(state)
    local now = Call(debugprofilestop)
    state.operations = (state.operations or 0) + 1
    if state.operations >= 128 or now and state.started and now - state.started >= 3 then coroutine.yield() end
end

local function Locations(state, kind, id, record)
    local key = Key(kind, id)
    if not key then return {} end
    local cached = state.locations[key]
    if cached and (not cached.retryAt or GetTime() < cached.retryAt) then
        if cached.retryAt then record.locationsPending = true end
        return cached
    end
    local out, pending = cached or {}, {}
    local entity = kind == "npc" and state.db.Npc or kind == "object" and state.db.Object
    local entityName = entity and Call(entity.name, id)
    -- 保留已转换的点；仅重试本图地图信息或 world 暂缺。
    local locations = cached and cached.pending
        or entity and ReadLocations(state.db, entity, id, state.mapID, function() Checkpoint(state) end)
    for _, location in ipairs(Table(locations) or {}) do
        if type(location) == "table" and location.reason == "unsupported_map"
            and location.coordinateMapID == state.mapID and (location.phase == nil or location.phase == 0) then
            if Table(Call(C_Map.GetMapInfo, state.mapID)) then
                location.available, location.x, location.y = true, location.originalX / 100, location.originalY / 100
                location.reason = nil
            else pending[#pending + 1] = location end
        end
        if type(location) == "table" and location.available == true
            and location.coordinateMapID == state.mapID and (location.phase == nil or location.phase == 0) then
            if cached or not location.world then location.world = Util.ToWorld(state.mapID, location.x, location.y) end
            local point = Point({ world = location.world, coordinateMapID = state.mapID, reportedMapID = state.mapID,
                x = location.x, y = location.y, entityKind = kind, entityID = id, entityName = entityName,
                source = "QuestieDB", precision = "static_spawn" }, false)
            if point then out[#out + 1] = point
            elseif not World(location.world) then pending[#pending + 1] = location end
        end
        Checkpoint(state)
    end
    out.pending = #pending > 0 and pending or nil
    out.retryAt = out.pending and GetTime() + 5 or nil
    if out.retryAt then record.locationsPending = true end
    state.locations[key] = out
    return out
end

local function ItemSources(state, itemID, add, record)
    local item = state.db.Item
    if type(item) ~= "table" or not IsID(itemID) then return end
    for _, pair in ipairs({ { "npcDrops", "npc" }, { "objectDrops", "object" } }) do
        for _, id in ipairs(Table(Call(item[pair[1]], itemID)) or {}) do
            if IsID(id) then
                for _, point in ipairs(Locations(state, pair[2], id, record)) do add(point); Checkpoint(state) end
            end
            Checkpoint(state)
        end
    end
end

local conditionFields = { "requiredLevel", "requiredMaxLevel", "requiredRaces", "requiredClasses", "requiredSkill",
    "requiredMinRep", "requiredMaxRep", "requiredSpell", "requiredRanks", "requiredSpecialization",
    "parentQuest", "nextQuestInChain", "availableStartingWith", "availableUntilCompleted", "disabledByQuest", "breadcrumbForQuestId" }

local function ReadRecord(state, id)
    local db = state.db
    if type(db.Quest.Exists) == "function" and db.Quest.Exists(id) ~= true then return end
    local record = { questID = id, conditionsKnown = true, starters = {}, finishers = {}, targets = {},
        items = {}, drops = {}, questItems = {}, defaultKeys = {}, conditions = {} }
    record.title, record.level = Field(db, "name", id), Field(db, "questLevel", id)
    record.specialFlags, record.zoneOrSort = Field(db, "specialFlags", id), Accessible(Field(db, "zoneOrSort", id))
    record.preAll = IDs(Field(db, "preQuestGroup", id, record), record)
    record.preAny = IDs(Field(db, "preQuestSingle", id, record), record)
    record.exclusiveTo = IDs(Field(db, "exclusiveTo", id, record), record)
    record.children = IDs(Field(db, "childQuests", id), record)
    for _, field in ipairs(conditionFields) do record.conditions[field] = Field(db, field, id, record) end
    local starters, finishers = Field(db, "startedBy", id), Field(db, "finishedBy", id)
    local groups, objectItems = Field(db, "objectives", id), {}
    local item = Table(db.Item) or {}
    -- 唯一直接来源的物件只收集任务物品，不代表已接取任务。
    for _, row in ipairs(type(groups) == "table" and groups[3] or {}) do
        local itemID = type(row) == "table" and row[1]
        if IsID(itemID) and Call(item.startQuest, itemID) == 0 then
            local sources = Table(Call(item.objectDrops, itemID))
            if sources and #sources == 1 and IsID(sources[1]) and not next(Table(Call(item.npcDrops, itemID)) or {}) then
                for _, objectID in ipairs(type(starters) == "table" and starters[2] or {}) do
                    if objectID == sources[1] then
                        record.questItems[itemID] = true
                        objectItems[objectID] = objectItems[objectID] or {}
                        objectItems[objectID][#objectItems[objectID] + 1] = itemID
                    end
                    Checkpoint(state)
                end
            end
        end
        Checkpoint(state)
    end
    for group, kind in ipairs({ "npc", "object" }) do
        for _, pair in ipairs({ { starters, record.starters }, { finishers, record.finishers } }) do
            for _, entityID in ipairs(type(pair[1]) == "table" and pair[1][group] or {}) do
                local collecting = kind == "object" and pair[2] == record.starters and objectItems[entityID]
                for _, point in ipairs(Locations(state, kind, entityID, record)) do
                    if collecting then
                        for _, itemID in ipairs(collecting) do
                            record.drops[#record.drops + 1] = { point = point, itemID = itemID }
                            Checkpoint(state)
                        end
                    else pair[2][#pair[2] + 1] = point end
                end
            end
        end
    end
    if next(record.questItems) and type(db.Npc) == "table" then
        -- shortcut: 外图 NPC 坐标暂缺时等待索引重建，需要原地恢复提示时再加外图重试。
        for _, entities in ipairs({ type(starters) == "table" and starters[1] or {}, type(finishers) == "table" and finishers[1] or {} }) do
            for _, entityID in ipairs(entities) do
                local locations = IsID(entityID) and ReadLocations(db, db.Npc, entityID, nil, function() Checkpoint(state) end)
                for _, location in ipairs(locations or {}) do
                    if location.available and (location.phase == nil or location.phase == 0) then
                        record.carriedPoint = Point({ world = location.world,
                            coordinateMapID = location.coordinateMapID, reportedMapID = location.coordinateMapID,
                            x = location.x, y = location.y, entityKind = "npc", entityID = entityID,
                            entityName = Call(db.Npc.name, entityID), source = "QuestieDB", precision = "static_spawn" }, false)
                        if record.carriedPoint then break end
                    end
                    Checkpoint(state)
                end
                if record.carriedPoint then break end
            end
            if record.carriedPoint then break end
        end
    end
    record.items = IDs(type(starters) == "table" and starters[3] or nil, record)
    for _, itemID in ipairs(record.items) do
        ItemSources(state, itemID, function(point) record.drops[#record.drops + 1] = { point = point, itemID = itemID } end, record)
    end
    local extra, trigger = Field(db, "extraObjectives", id), Field(db, "triggerEnd", id)
    local simple = type(groups) == "table" and (type(db.Quest.extraObjectives) == "function" or type(db.Quest.Get) == "function")
        and (extra == nil or (type(extra) == "table" and next(extra) == nil))
    for group = 4, 6 do
        if type(groups) == "table" and groups[group] ~= nil
            and (type(groups[group]) ~= "table" or next(groups[group]) ~= nil) then simple = false end
    end
    local seen, goalCount, covered = {}, 0, true
    local function Reference(kind, entityID, shareable)
        if not IsID(entityID) then covered = false; return end
        local objectiveKey, count = Key(kind, entityID), 0
        local function Add(raw)
            local point = Point(raw, shareable)
            if not point then return end
            point.key, point.objectiveKey = objectiveKey, objectiveKey
            point.relation = kind == "item" and "direct_drop" or "objective_entity"
            count = count + 1
            local key = objectiveKey .. ":" .. point.entityKind .. ":" .. point.entityID .. ":" .. point.x .. ":" .. point.y
            if not seen[key] then record.targets[#record.targets + 1], seen[key] = point, true end
        end
        if kind == "item" then ItemSources(state, entityID, Add, record)
        else for _, point in ipairs(Locations(state, kind, entityID, record)) do Add(point); Checkpoint(state) end end
        if count == 0 then covered = false end
    end
    for group, kind in ipairs({ "npc", "object", "item" }) do
        for _, row in ipairs(type(groups) == "table" and groups[group] or {}) do
            goalCount = goalCount + 1
            if type(row) == "table" and IsID(row[1]) then
                local normal = simple and (row[3] == nil or row[3] == 0)
                Reference(kind, row[1], normal)
                if normal then record.defaultKeys[Key(kind, row[1])] = true else covered = false end
            else covered = false end
        end
    end
    record.targetsComplete = simple and covered and goalCount > 0
        and (type(db.Quest.triggerEnd) == "function" or type(db.Quest.Get) == "function")
        and (trigger == nil or type(trigger) == "table" and next(trigger) == nil)
    for _, row in ipairs(type(groups) == "table" and groups[5] or {}) do
        if type(row) == "table" then
            for _, entityID in ipairs(type(row[1]) == "table" and row[1] or {}) do Reference("npc", entityID) end
            Reference("npc", row[2])
        end
    end
    for _, row in ipairs(type(extra) == "table" and extra or {}) do
        for _, ref in ipairs(type(row) == "table" and row[5] or {}) do
            if type(ref) == "table" then Reference(ref[1] == "monster" and "npc" or ref[1], ref[2]) end
        end
    end
    record.localData = #record.starters + #record.finishers + #record.targets + #record.drops > 0
    return record
end

local function Link(state, from, to)
    if not IsID(from) or not IsID(to) or from == to then return end
    state.children[from] = state.children[from] or {}
    state.children[from][to] = true
end

local function IndexPoint(grid, id, point, indexed, action, itemID)
    local key = (action or "target") .. ":" .. (itemID or 0) .. ":" .. point.key .. ":"
        .. point.entityKind .. ":" .. point.entityID .. ":" .. point.x .. ":" .. point.y
    if indexed[key] then return end
    local world = point.world
    local continent, x, y = world.continentID, math.floor(world.x / cellSize), math.floor(world.y / cellSize)
    grid[continent] = grid[continent] or {}
    grid[continent][x] = grid[continent][x] or {}
    local column = grid[continent][x]
    column[y] = column[y] or {}
    column[y][#column[y] + 1] = { questID = id, point = point, action = action, itemID = itemID }
    indexed[key] = true
    return true
end

local function Store(state, record)
    local id = record.questID
    local previous = state.records[id]
    record.indexed = previous and previous.indexed or {}
    if previous then
        for _, field in ipairs({ "starters", "finishers", "targets", "drops" }) do
            if #record[field] ~= #previous[field] then state.changed = true end
        end
    end
    for _, child in ipairs(record.children) do Link(state, id, child) end
    for _, list in ipairs({ record.preAll, record.preAny }) do
        for _, parent in ipairs(list) do Link(state, parent, id) end
    end
    for _, other in ipairs(record.exclusiveTo) do
        state.exclusive[other] = state.exclusive[other] or {}
        state.exclusive[other][id] = true
    end
    for _, point in ipairs(record.starters) do IndexPoint(state.starts, id, point, record.indexed, "pick_up"); Checkpoint(state) end
    for _, drop in ipairs(record.drops) do IndexPoint(state.starts, id, drop.point, record.indexed, "possible_item_drop", drop.itemID); Checkpoint(state) end
    for _, point in ipairs(record.targets) do
        if IndexPoint(state.targets, id, point, record.indexed) then
            state.byKey[point.key] = state.byKey[point.key] or {}
            state.byKey[point.key][id] = true
            local entityKey = Key(point.entityKind, point.entityID)
            if entityKey then
                state.byKey[entityKey] = state.byKey[entityKey] or {}
                state.byKey[entityKey][id] = true
            end
        end
        Checkpoint(state)
    end
    for _, itemID in ipairs(record.items) do
        state.byItem[itemID] = state.byItem[itemID] or {}
        state.byItem[itemID][id] = true
    end
    for itemID in pairs(record.questItems) do
        state.byItem[itemID] = state.byItem[itemID] or {}
        state.byItem[itemID][id] = true
    end
    state.records[id] = record
    if record.locationsPending then state.pendingRecords[#state.pendingRecords + 1] = id end
end

local function Pump()
    local state = cache
    if not state then return false end
    if not state.queue then
        if not state.retryAt or GetTime() < state.retryAt then return false end
        state.queue, state.cursor, state.pendingRecords = state.pendingRecords, 0, {}
    end
    if Call(GetDatabase) ~= state.db then cache = nil; return false end
    local last = math.min(state.cursor + batchSize, #state.queue)
    state.started, state.operations = Call(debugprofilestop), 0
    while state.cursor < last do
        local id = state.queue[state.cursor + 1]
        if not state.worker then
            state.worker = coroutine.create(function()
                if IsID(id) then
                    local record = ReadRecord(state, id)
                    if record then Store(state, record) end
                end
            end)
        end
        local ok = coroutine.resume(state.worker)
        if not ok then
            if state.building then state.records[id] = { questID = id, readError = true }
            else state.pendingRecords[#state.pendingRecords + 1] = id end
        end
        if ok and coroutine.status(state.worker) ~= "dead" then break end
        state.worker, state.cursor = nil, state.cursor + 1
        if state.building then state.scanned = state.cursor end
        local now = Call(debugprofilestop)
        if now and state.started and now - state.started >= 3 then break end
    end
    local plan = ns.route.plan
    if plan and plan.mapID == state.mapID and plan.discovery then plan.discovery.scanned = state.scanned end
    if state.cursor == #state.queue then
        local changed = state.building or state.changed
        state.queue, state.building, state.changed = nil, false, nil
        state.retryAt = #state.pendingRecords > 0 and GetTime() + 5 or nil
        return changed == true
    end
    return false
end

local function Initialize(db, mapID)
    if indexDB ~= db then
        indexDB, questIDs, cache = db, nil, nil
    end
    if not questIDs then
        local quest = Table(db.Quest)
        if not quest or type(quest.GetAllIds) ~= "function" then return nil, "id_index_unavailable" end
        questIDs = Table(Call(quest.GetAllIds))
        if not questIDs then return nil, "id_index_not_ready" end
    end
    if not cache or cache.db ~= db or cache.mapID ~= mapID then
        cache = { db = db, mapID = mapID, scanned = 0, building = true, records = {}, locations = {},
            queue = questIDs, cursor = 0, pendingRecords = {},
            children = {}, starts = {}, targets = {}, byKey = {}, byItem = {}, exclusive = {} }
    end
    return cache
end

local function Query(grid, world, minX, maxX, minY, maxY, visit)
    local continent = world and grid[world.continentID]
    if not continent then return end
    for x = math.floor(minX / cellSize), math.floor(maxX / cellSize) do
        local column = continent[x]
        if column then
            for y = math.floor(minY / cellSize), math.floor(maxY / cellSize) do
                for _, entry in ipairs(column[y] or {}) do visit(entry) end
            end
        end
    end
end

local function Around(grid, world, radius, visit)
    if not world then return end
    Query(grid, world, world.x - radius, world.x + radius, world.y - radius, world.y + radius, function(entry)
        local distance = Distance(world, entry.point.world)
        if distance and distance <= radius then visit(entry) end
    end)
end

local function Inventory(db)
    local held, quests = {}, {}
    local api = Table(C_Container) or {}
    for bag = 0, 4 do
        local slots = Call(api.GetContainerNumSlots, bag)
        if IsFinite(slots) and slots >= 0 and slots % 1 == 0 then
            for slot = 1, slots do
                local itemID = Call(api.GetContainerItemID, bag, slot)
                if IsID(itemID) then
                    held[itemID] = true
                    local item = Table(db.Item)
                    local questID = item and Call(item.startQuest, itemID)
                    local info = Table(Call(api.GetContainerItemQuestInfo, bag, slot))
                    if not IsID(questID) and info and Accessible(info.isActive) == false then questID = Accessible(info.questID) end
                    if IsID(questID) then quests[questID] = itemID end
                end
            end
        end
    end
    return held, quests
end

local function Character(context, db)
    local _, _, raceID = Call(UnitRace, "player")
    local _, className, classID = Call(UnitClass, "player")
    local enum = Table(db.Enum) or {}
    local races, classes = Table(enum.raceMaskById), Table(enum.classKeys)
    local race = IsID(raceID) and races and races[raceID]
    if not races and IsID(raceID) and raceID <= 11 then race = 2 ^ (raceID - 1) end
    local class = type(className) == "string" and classes and classes[className == "DEATHKNIGHT" and "DEATH_KNIGHT" or className]
    if not classes and IsID(classID) and classID <= 11 then class = 2 ^ (classID - 1) end
    return { level = Accessible((Table(context.character) or {}).level), race = race, class = class }
end

local function MaskAllows(mask, own)
    if mask == nil or mask == 0 then return true end
    if not IsID(mask) or mask >= 2 ^ 53 or not IsID(own) or own >= 2 ^ 53 then return end
    return math.floor(mask / own) % 2 == 1
end

local function Eligibility(record, quest, active, settings, character, completed, db)
    local id, missing, seen = quest.questID, {}, {}
    if settings.skipped[id] then return "blocked", "skipped", missing end
    if quest.status == "failed" then return "blocked", "failed", missing end
    local exclusion = ns.RouteOptions.Exclusion
    local filterOK, why = false, nil
    if type(exclusion) == "function" then filterOK, why = pcall(exclusion, quest, db, settings) end
    why = Accessible(why)
    if filterOK and type(why) == "string" then return "blocked", why, missing end
    if active[id] then
        if not filterOK or quest.status == "unknown" then return "unknown", "official_state_unavailable", missing end
        return "eligible", "active", missing
    end
    if completed(id) == true then return "blocked", "already_completed", missing end
    if not record or record.readError then return "unknown", "database_read_error", missing end
    local hard, unknown, prerequisite
    local function Check(value, reason)
        if value == false then hard = hard or reason elseif value ~= true then unknown = unknown or reason end
    end
    if completed(id) == nil then unknown = "completion_unknown" end
    if not filterOK or not record.conditionsKnown or record.invalidConditions then unknown = unknown or "conditions_unavailable" end
    local api = Table(C_QuestLog) or {}
    -- 本客户端原生重复标志可能为 false；QuestieDB specialFlags 最低位补齐。
    if Call(api.IsRepeatableQuest, id) == true or IsID(record.specialFlags) and record.specialFlags % 2 == 1 then
        return "blocked", "repeatable", missing
    end
    local questType = Call(api.GetQuestType, id)
    if questType == 41 or IsFinite(record.zoneOrSort) and battlegroundSorts[record.zoneOrSort] then
        return "blocked", "battleground", missing
    end
    if IsFinite(record.zoneOrSort) and holidaySorts[record.zoneOrSort] then return "blocked", "holiday", missing end
    local title = Accessible(record.title)
    if type(title) == "string" then
        if title:match("^捐献") or title:match("^贡献") then return "blocked", "donation", missing end
        -- shortcut: 仅过滤纯 ASCII 英文标题，遇到带重音或特殊标点的漏网标题时再扩展。
        if title:find("[A-Za-z]") and not title:find("[\128-\255]") then return "blocked", "unlocalized", missing end
    end
    if IsID(record.level) and record.level < settings.minPickupLevel then return "blocked", "quest_below_minimum", missing end
    local onQuest = Call(api.IsOnQuest, id)
    if onQuest == true then return "blocked", "already_accepted", missing end
    if onQuest ~= false then unknown = unknown or "quest_log_membership_unknown" end
    if not IsFinite(questType) then unknown = unknown or "quest_type_unknown" end
    if not settings.includeEliteQuests and type(Call(api.IsEliteQuest, id)) ~= "boolean" then unknown = unknown or "elite_state_unknown" end
    local c = record.conditions
    for _, field in ipairs({ "requiredLevel", "requiredMaxLevel" }) do
        local value = c[field]
        if value ~= nil and value ~= 0 then
            if not IsFinite(value) or value < 0 or not IsFinite(character.level) then Check(nil, "level_unknown")
            else Check(field == "requiredLevel" and character.level >= value or field == "requiredMaxLevel" and character.level <= value,
                field == "requiredLevel" and "level_too_low" or "level_too_high") end
        end
    end
    Check(MaskAllows(c.requiredRaces, character.race), "race_restricted")
    Check(MaskAllows(c.requiredClasses, character.class), "class_restricted")
    local function Missing(qid)
        if not seen[qid] then missing[#missing + 1], seen[qid] = qid, true end
    end
    for _, qid in ipairs(record.preAll) do
        local done = completed(qid)
        if done ~= true then Missing(qid) end
        if done == false then prerequisite = true elseif done == nil then unknown = unknown or "prerequisite_completion_unknown" end
    end
    if #record.preAny > 0 then
        local satisfied, uncertain = false, false
        for _, qid in ipairs(record.preAny) do
            local done = completed(qid)
            if done == true then satisfied = true elseif done == nil then uncertain = true end
        end
        if not satisfied then
            for _, qid in ipairs(record.preAny) do Missing(qid) end
            if uncertain then unknown = unknown or "prerequisite_completion_unknown" else prerequisite = true end
        end
    end
    for _, qid in ipairs(record.exclusiveTo) do
        if active[qid] then Check(false, "exclusive_quest")
        else
            local done = completed(qid)
            if done == nil then Check(nil, "exclusive_completion_unknown") else Check(not done, "exclusive_quest") end
        end
    end
    for _, field in ipairs({ "parentQuest", "nextQuestInChain", "availableStartingWith", "availableUntilCompleted", "disabledByQuest", "breadcrumbForQuestId" }) do
        local qid = c[field]
        if qid ~= nil and qid ~= 0 then
            if not IsID(qid) then Check(nil, "invalid_quest_condition")
            elseif field == "parentQuest" then Check(active[qid] ~= nil, "parent_not_active")
            elseif field == "disabledByQuest" then Check(active[qid] == nil, "disabled_by_active_quest")
            elseif field == "availableStartingWith" then
                if not active[qid] then Check(completed(qid), "starting_quest_required") end
            elseif (field == "nextQuestInChain" or field == "breadcrumbForQuestId") and active[qid] then Check(false, "chain_successor_active")
            else
                local done = completed(qid)
                if done == nil then Check(nil, "availability_completion_unknown") else Check(not done, "availability_ended") end
            end
        end
    end
    for _, field in ipairs({ "requiredMinRep", "requiredMaxRep" }) do
        local pair = c[field]
        if pair ~= nil then
            if type(pair) ~= "table" or not IsID(pair[1]) or not IsFinite(pair[2]) then Check(nil, "reputation_requirement_unknown")
            else
                local rep = Table(C_Reputation) or {}
                local data = Table(Call(rep.GetFactionDataByID, pair[1]))
                local standing = data and Accessible(data.currentStanding)
                if not IsFinite(standing) then Check(nil, "reputation_unknown")
                else Check(field == "requiredMinRep" and standing >= pair[2] or field == "requiredMaxRep" and standing < pair[2], "reputation_restricted") end
            end
        end
    end
    if c.requiredSkill ~= nil then
        if type(c.requiredSkill) == "table" and IsID(c.requiredSkill[1]) then Check(false, "profession")
        else Check(nil, "skill_requirement_unknown") end
    end
    if c.requiredSpell ~= nil and c.requiredSpell ~= 0 then
        local spells = Table(C_SpellBook) or {}
        local known
        if IsID(c.requiredSpell) then known = Call(spells.IsSpellKnown, c.requiredSpell) end
        if type(known) == "boolean" then Check(known, "required_spell_missing") else Check(nil, "required_spell_unknown") end
    end
    -- shortcut: 未核实本客户端的专业等级/专精 API，核实前保持 unknown。
    if c.requiredSpecialization ~= nil and c.requiredSpecialization ~= 0 then Check(nil, "specialization_unknown") end
    if c.requiredRanks ~= nil and (type(c.requiredRanks) ~= "table" or next(c.requiredRanks) ~= nil) then Check(nil, "skill_ranks_unknown") end
    if hard then return "blocked", hard, missing end
    if unknown then return "unknown", unknown, missing end
    if prerequisite then return "blocked", "prerequisite", missing end
    return "eligible", "conditions_met", missing
end

local function ActiveData(id, entry, supplied)
    local source = supplied or Table(Call(ns.QuestData.ReadQuest, entry.info, entry.category, false)) or Table(entry.info) or {}
    local api = Table(C_QuestLog) or {}
    local failed, complete, ready = Accessible(source.isFailed), Accessible(source.isComplete), Accessible(source.readyForTurnIn)
    if type(failed) ~= "boolean" then failed = Call(api.IsFailed, id) end
    if type(complete) ~= "boolean" then complete = Call(api.IsComplete, id) end
    if type(ready) ~= "boolean" then ready = Call(api.ReadyForTurnIn, id) end
    local status = "unknown"
    if failed == true then status = "failed"
    elseif failed == false and ready == true then status = "ready_for_turn_in"
    elseif failed == false and ready == false and complete == true then status = "complete"
    elseif failed == false and ready == false and complete == false then status = "in_progress" end
    return { questID = id, title = Accessible(source.title), level = Accessible(source.level),
        category = Accessible(source.category) or Accessible(entry.category), tag = Table(source.tag),
        isFailed = failed, isComplete = complete, readyForTurnIn = ready, status = status }
end

local function Collect(context, active, candidates, settings)
    local result = { available = false, building = false, scanned = 0, total = 0,
        quests = {}, opportunities = {}, announcedOpportunities = {}, carriedItems = {}, blocked = {}, completed = {} }
    context, active, candidates = Table(context) or {}, Table(active) or {}, Table(candidates) or {}
    local location = Table(context.location) or {}
    local mapID = Accessible(location.coordinateMapID)
    local announced = ns.route.announcedOpportunities
    if announced and IsID(mapID) and announced.mapID ~= mapID then
        ns.route.announcedOpportunities, announced = nil, nil
    end
    local db, info = Call(GetDatabase)
    db = Table(db)
    if not db then cache = nil; result.reason = (Table(info) or {}).reason or "database_unavailable"; return result end
    if not IsID(mapID) then cache = nil; result.reason = "map_unavailable"; return result end
    local state, reason = Initialize(db, mapID)
    if not state then result.reason = reason; return result end
    result.available, result.building, result.scanned, result.total = true, state.building, state.scanned, #questIDs
    result.reason = state.building and "building" or "ready"
    result.pendingLocationCount = #state.pendingRecords + (not state.building and state.queue and (#state.queue - state.cursor) or 0)
    settings = Table(settings) or Table(Call(ns.RouteOptions.Get)) or {}
    settings = { skipped = Table(settings.skipped) or {}, includeEliteQuests = Accessible(settings.includeEliteQuests) == true,
        minPickupLevel = settings.minPickupLevel or ns.RouteOptions.Get().minPickupLevel,
        maxMonsterLevelOffset = settings.maxMonsterLevelOffset or ns.RouteOptions.Get().maxMonsterLevelOffset }
    state.requests = state.requests or {}
    local requestCount = 0
    result.pendingQuestIDs, result.pendingCount = {}, 0
    local origin, native, activeTargets, activeKeys, coverage, weights, deliveries = World(location.world), {}, {}, {}, {}, {}, {}
    local combatLevels, playerLevel = {}, (Table(context.character) or {}).level
    local function TargetAboveLevel(point)
        return ns.RouteOptions.TargetAboveLevel(db, point, playerLevel, combatLevels, settings.maxMonsterLevelOffset)
    end
    local nextPoint, nextID, bestScore, retainedPoint, retainedID, retainedShift
    local plan = ns.route and ns.route.plan
    local previous = plan and plan.mapID == mapID and plan.steps and plan.steps[1]
    for _, candidate in ipairs(candidates) do
        local quest = Table(candidate.quest)
        local id = quest and Accessible(quest.questID)
        if IsID(id) and active[id] then
            native[id] = native[id] or ActiveData(id, active[id], quest)
            local record = state.records[id]
            local resolution = Table(candidate.resolution)
            local reliable = resolution and Accessible(resolution.mappingComplete) == true
            if not reliable and Table(quest.objectives) then
                resolution = Table(Call(ns.Objectives.ReadIdentities, db, Table(info) or {}, quest))
                reliable = resolution and Accessible(resolution.mappingComplete) == true
            end
            coverage[id] = coverage[id] or { complete = true, required = {} }
            if reliable then
                for _, objective in ipairs(resolution.objectives or {}) do
                    if objective.finished == false and type(objective.key) == "string" then coverage[id].required[objective.key] = true
                    elseif objective.finished ~= true then coverage[id].complete = false end
                end
            else coverage[id].complete = false end
            weights[id] = candidate.priorityWeight or 1
            for _, raw in ipairs(Table(candidate.points) or {}) do
                if Accessible(raw.reportedMapID) == mapID then
                    local objectiveKey = Accessible(raw.objectiveKey) or Accessible(candidate.objectiveKey)
                    local point = Point(raw, reliable and record and record.defaultKeys and record.defaultKeys[objectiveKey])
                    if point and (native[id].status ~= "in_progress" or not TargetAboveLevel(point)) then
                        point.objectiveKey = objectiveKey
                        local distance = Distance(origin, point.world)
                        local weight = Accessible(candidate.priorityWeight)
                        if not IsFinite(weight) or weight <= 0 then weight = 1 end
                        local score = distance and distance / weight
                        if score and (not bestScore or score < bestScore) then nextPoint, nextID, bestScore = point, id, score end
                        if previous and previous.questID == id and previous.objectiveKey == objectiveKey and previous.status == native[id].status then
                            local shift = Distance(World(previous.world), point.world)
                            if shift and (not retainedShift or shift < retainedShift) then retainedPoint, retainedID, retainedShift = point, id, shift end
                        end
                        if native[id].status == "ready_for_turn_in" then
                            deliveries[id] = deliveries[id] or {}
                            deliveries[id][#deliveries[id] + 1] = point
                        end
                        if native[id].status == "in_progress" then
                            activeTargets[id] = activeTargets[id] or {}
                            activeTargets[id][#activeTargets[id] + 1] = point
                            for _, key in ipairs({ point.key, Key(point.entityKind, point.entityID) }) do
                                activeKeys[key] = activeKeys[key] or {}
                                activeKeys[key][id] = true
                            end
                        end
                    end
                end
            end
        end
    end
    nextPoint, nextID = retainedPoint or nextPoint, retainedID or nextID
    local destination = nextPoint and nextPoint.world
    local direct = Distance(origin, destination)
    local seeds, hints, proposals = {}, {}, {}
    local function Hint(id, why, related)
        seeds[id] = true
        hints[id] = hints[id] or { reasons = {}, related = {} }
        hints[id].reasons[why] = true
        if IsID(related) and related ~= id then hints[id].related[related] = true end
    end
    local function Propose(id, point, action, itemID)
        if action == "possible_item_drop" and TargetAboveLevel(point) then return end
        local distance = Distance(origin, point.world)
        if not distance then return end
        local extra = direct and Distance(point.world, destination)
        extra = extra and math.max(0, distance + extra - direct)
        local key = id .. ":" .. action .. ":" .. (itemID or 0)
        local old = proposals[key]
        local score = extra or distance
        if not old or score < old.score or (score == old.score and distance < old.distance) then
            proposals[key] = { questID = id, point = point, action = action, itemID = itemID,
                distance = distance, extraDistance = extra, score = score }
        end
    end
    Around(state.starts, origin, 400, function(entry)
        Hint(entry.questID, "nearby"); Propose(entry.questID, entry.point, entry.action, entry.itemID)
    end)
    Around(state.starts, destination, 200, function(entry)
        Hint(entry.questID, "same_area", nextID); Propose(entry.questID, entry.point, entry.action, entry.itemID)
    end)
    if direct then
        local margin = math.sqrt(150 * (2 * direct + 150)) / 2
        Query(state.starts, origin, math.min(origin.x, destination.x) - margin, math.max(origin.x, destination.x) + margin,
            math.min(origin.y, destination.y) - margin, math.max(origin.y, destination.y) + margin, function(entry)
                local a, b = Distance(origin, entry.point.world), Distance(entry.point.world, destination)
                if a and b and a + b - direct <= 150 then
                    Hint(entry.questID, "on_way", nextID); Propose(entry.questID, entry.point, entry.action, entry.itemID)
                end
            end)
    end
    Around(state.targets, destination, 200, function(entry) Hint(entry.questID, "same_area", nextID) end)
    for key, related in pairs(activeKeys) do
        for id in pairs(state.byKey[key] or {}) do
            for activeID in pairs(related) do Hint(id, "same_target", activeID) end
        end
    end
    for id, hint in pairs(hints) do
        if hint.reasons.same_target or hint.reasons.same_area then
            local record = state.records[id]
            for _, point in ipairs(record and record.starters or {}) do Propose(id, point, "pick_up") end
            for _, drop in ipairs(record and record.drops or {}) do Propose(id, drop.point, "possible_item_drop", drop.itemID) end
        end
    end
    local held, bagQuests = Inventory(db)
    local carriedQuests = {}
    for itemID in pairs(held) do
        for id in pairs(state.byItem[itemID] or {}) do
            if state.records[id].questItems[itemID] then
                carriedQuests[id] = true
                if bagQuests[id] == itemID then bagQuests[id] = nil end
                Hint(id, "item_in_bags")
            else bagQuests[id] = itemID end
        end
    end
    local offered, gossip = {}, Table(C_GossipInfo) or {}
    for _, row in ipairs(Table(Call(gossip.GetAvailableQuests)) or {}) do
        local id = (Table(row) or {}).questID
        if IsID(id) then offered[id] = true; Hint(id, "gossip_available") end
    end
    local originPoint = origin and Point({ world = origin, coordinateMapID = mapID, reportedMapID = mapID,
        x = Accessible(location.x), y = Accessible(location.y), source = "client", precision = "player_position" }, false)
    for id, itemID in pairs(bagQuests) do
        Hint(id, "item_in_bags")
        if originPoint then Propose(id, originPoint, "start_item", itemID) end
    end
    for id in pairs(offered) do
        if originPoint then
            proposals[id .. ":pick_up:0"] = nil
            Propose(id, originPoint, "pick_up")
        end
    end
    for id in pairs(active) do if IsID(id) then seeds[id] = true end end
    local initial = {}
    for id in pairs(seeds) do initial[#initial + 1] = id end
    -- 仅扩一跳；后续搜索自行限制前瞻，不在移动时展开长链。
    for _, id in ipairs(initial) do
        for child in pairs(state.children[id] or {}) do seeds[child] = true end
        local record = state.records[id]
        for _, list in ipairs({ record and record.preAll or {}, record and record.preAny or {} }) do
            for _, parent in ipairs(list) do seeds[parent] = true end
        end
    end
    for _, item in pairs(announced and announced.items or {}) do seeds[item.questID] = true end
    local completionSeen = {}
    local function Completed(id)
        if not completionSeen[id] then
            completionSeen[id] = true
            local api = Table(C_QuestLog) or {}
            local value = Call(api.IsQuestFlaggedCompleted, id)
            if type(value) == "boolean" then result.completed[id] = value end
        end
        return result.completed[id]
    end
    local character = Character(context, db)
    local ordered = {}
    for id in pairs(seeds) do ordered[#ordered + 1] = id end
    table.sort(ordered)
    for _, id in ipairs(ordered) do
        local record, entry = state.records[id], active[id]
        if entry or (record and (record.localData or bagQuests[id] or carriedQuests[id] or offered[id])) then
            local quest = native[id]
            if not quest and entry then quest = ActiveData(id, entry) end
            quest = quest or { questID = id, title = record and record.title, level = record and record.level,
                status = entry and "unknown" or "not_accepted" }
            local eligibility, why, missing = Eligibility(record, quest, active, settings, character, Completed, db)
            if not entry then
                for other in pairs(state.exclusive[id] or {}) do
                    local done = Completed(other)
                    if active[other] or done == true then eligibility, why = "blocked", "exclusive_quest"; break end
                    if done == nil and (eligibility == "eligible" or why == "prerequisite") then
                        eligibility, why = "unknown", "exclusive_completion_unknown"
                    end
                end
            end
            -- 未缓存任务的类型会假报普通；请求后才采用原生副本/精英分类。
            local needsMetadata = eligibility == "eligible" or why == "prerequisite" or why == "quest_type_unknown" or why == "elite_state_unknown"
            if not entry and needsMetadata and Call(HaveQuestData, id) ~= true then
                eligibility, why = "unknown", "quest_data_not_ready"
                result.pendingQuestIDs[id], result.pendingCount = true, result.pendingCount + 1
                local now = GetTime()
                if not state.building and requestCount < 8 and (not state.requests[id] or now - state.requests[id] >= 5) then
                    local api = Table(C_QuestLog) or {}
                    if type(api.RequestLoadQuestByID) == "function" then
                        Call(api.RequestLoadQuestByID, id)
                        state.requests[id], requestCount = now, requestCount + 1
                    end
                end
            else state.requests[id] = nil end
            local title = Accessible(quest.title)
            if type(title) ~= "string" or title == "" then title = "任务" .. id end
            local out = { questID = id, title = title, level = Accessible(quest.level), active = entry ~= nil,
                status = Accessible(quest.status) or "unknown", eligibility = eligibility, conditionReason = why,
                startItemID = bagQuests[id], certainty = offered[id] and "confirmed" or "estimated",
                missingPrerequisites = missing, preAll = CopyList(record and record.preAll), preAny = CopyList(record and record.preAny),
                exclusiveTo = CopyList(record and record.exclusiveTo), targets = {}, starters = {}, finishers = {}, childQuests = {},
                rewardWeight = weights[id] or 1, targetsComplete = not entry and record and record.targetsComplete == true }
            Completed(id)
            if not entry and result.completed[id] == true then out.status = "completed" end
            for child in pairs(state.children[id] or {}) do out.childQuests[#out.childQuests + 1] = child end
            table.sort(out.childQuests)
            for _, list in ipairs({ out.preAll, out.preAny, out.exclusiveTo }) do for _, qid in ipairs(list) do Completed(qid) end end
            for _, field in ipairs({ "parentQuest", "nextQuestInChain", "availableStartingWith", "availableUntilCompleted", "disabledByQuest", "breadcrumbForQuestId" }) do
                local qid = record and record.conditions and record.conditions[field]
                if IsID(qid) then out[field] = qid; Completed(qid) end
            end
            for _, field in ipairs({ "starters", "finishers" }) do
                for _, point in ipairs(record and record[field] or {}) do out[field][#out[field] + 1] = Point(point, false) end
            end
            if offered[id] and originPoint then out.starters = { Point(originPoint, false) } end
            if deliveries[id] then out.finishers = deliveries[id] end
            local targets
            if entry then
                if quest.status == "in_progress" then targets = activeTargets[id] end
            elseif bagQuests[id] or #out.starters > 0 then targets = record and record.targets
            else out.targetsComplete = false end
            local present, unsafe = {}, {}
            for _, point in ipairs(targets or {}) do
                local copied = Point(point, point.shareable)
                if copied then
                    if TargetAboveLevel(copied) then unsafe[copied.key] = true
                    else out.targets[#out.targets + 1] = copied; present[copied.key] = true end
                end
            end
            for key in pairs(unsafe) do
                if not present[key] then
                    out.targetsComplete = false
                    if not entry and (eligibility == "eligible" or why == "prerequisite") then
                        eligibility, why = "blocked", "target_above_level"
                        out.eligibility, out.conditionReason = eligibility, why
                    end
                end
            end
            if entry and coverage[id] then
                local full = coverage[id].complete and next(coverage[id].required) ~= nil
                for key in pairs(coverage[id].required) do if not present[key] then full = false end end
                out.targetsComplete = full
            end
            result.quests[id] = out
            if not state.building and not entry and eligibility == "eligible" and carriedQuests[id] and record.carriedPoint then
                for itemID in pairs(record.questItems) do
                    if held[itemID] then
                        result.carriedItems[#result.carriedItems + 1] = { questID = id, title = title,
                            itemID = itemID, itemName = Call(db.Item.name, itemID), point = Point(record.carriedPoint, false),
                            reasons = { "item_in_bags" } }
                    end
                end
            end
            if eligibility ~= "eligible" then result.blocked[#result.blocked + 1] = {
                questID = id, title = out.title, eligibility = eligibility, reason = why, missingPrerequisites = CopyList(missing) } end
        end
    end
    if not state.building then
        for _, proposal in pairs(proposals) do
            local id, quest = proposal.questID, result.quests[proposal.questID]
            if quest and not quest.active and quest.eligibility == "eligible"
                and not (proposal.action == "possible_item_drop" and held[proposal.itemID]) then
                local reasons, related = {}, {}
                for why in pairs(hints[id].reasons) do reasons[#reasons + 1] = why end
                for qid in pairs(hints[id].related) do related[#related + 1] = qid end
                table.sort(reasons); table.sort(related)
                result.opportunities[#result.opportunities + 1] = { questID = id, title = quest.title, action = proposal.action,
                    point = Point(proposal.point, false), itemID = proposal.itemID,
                    questItem = proposal.action == "possible_item_drop" and state.records[id].questItems[proposal.itemID] or nil,
                    reasons = reasons, relatedQuestIDs = related,
                    certainty = proposal.action == "possible_item_drop" and "possible"
                        or (proposal.action == "start_item" or offered[id]) and "confirmed" or "estimated",
                    distance = proposal.distance, extraDistance = proposal.extraDistance }
            end
        end
        table.sort(result.opportunities, function(a, b)
            if a.questID ~= b.questID then return a.questID < b.questID end
            if a.action ~= b.action then return a.action < b.action end
            return (a.itemID or 0) < (b.itemID or 0)
        end)
    end
    -- 已提示地点只保留为地图参考，重新校验资格，不重新加入决策候选。
    local current = {}
    for _, item in ipairs(result.opportunities) do
        current[item.questID .. ":" .. item.action .. ":" .. (item.itemID or 0)] = true
    end
    for key, item in pairs(announced and announced.items or {}) do
        local quest = result.quests[item.questID]
        if active[item.questID] or item.itemID and held[item.itemID]
            or item.action == "possible_item_drop" and TargetAboveLevel(item.point)
            or quest and (quest.active or quest.eligibility == "blocked") then
            announced.items[key] = nil
        elseif not state.building and quest and quest.eligibility == "eligible" and not current[key] then
            local point = Point(item.point, false)
            if point and point.coordinateMapID == mapID then
                result.announcedOpportunities[#result.announcedOpportunities + 1] = {
                    questID = quest.questID, title = quest.title, action = item.action, itemID = item.itemID,
                    questItem = item.questItem, point = point, reasons = { "previous_notice" },
                    certainty = item.action == "possible_item_drop" and "possible" or quest.certainty }
            end
        end
    end
    table.sort(result.announcedOpportunities, function(a, b)
        if a.questID ~= b.questID then return a.questID < b.questID end
        if a.action ~= b.action then return a.action < b.action end
        return (a.itemID or 0) < (b.itemID or 0)
    end)
    if not origin then result.reason = "player_position_unavailable" end
    return result
end

ns.Discovery = { Collect = Collect, Pump = Pump }
