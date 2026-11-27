-- 升级阶段的战斗装备候选。战士防护按练级属性计分，不用团本生存模型。
local _, ns = ...

local SLOTS = {
    { id = "head", label = "头部", pool = "head" },
    { id = "neck", label = "颈部", pool = "neck" },
    { id = "shoulder", label = "肩部", pool = "shoulder" },
    { id = "back", label = "背部", pool = "back" },
    { id = "chest", label = "胸部", pool = "chest" },
    { id = "wrist", label = "手腕", pool = "wrist" },
    { id = "hands", label = "手", pool = "hands" },
    { id = "waist", label = "腰部", pool = "waist" },
    { id = "legs", label = "腿部", pool = "legs" },
    { id = "feet", label = "脚", pool = "feet" },
    { id = "finger1", label = "戒指", pool = "finger", pair = "finger" },
    { id = "finger2", label = "戒指", pool = "finger", pair = "finger" },
    { id = "trinket1", label = "饰品", pool = "trinket", pair = "trinket" },
    { id = "trinket2", label = "饰品", pool = "trinket", pair = "trinket" },
    { id = "mainhand", label = "主手", pool = "mainhand" },
    { id = "offhand", label = "副手", pool = "offhand" },
    { id = "ranged", label = "远程", pool = "ranged" },
}

local ORDER = {
    "stamina", "armor", "defense", "dodge", "parry", "block", "blockValue",
    "strength", "attackPower", "agility", "crit", "hit", "weaponDps",
}

local STAT_LABEL = {
    stamina = "耐力", armor = "护甲", defense = "防御", dodge = "躲闪", parry = "招架",
    block = "格挡", blockValue = "格挡值", strength = "力量", attackPower = "攻击强度",
    agility = "敏捷", crit = "爆击", hit = "命中", weaponDps = "武器DPS",
    intellect = "智力", spirit = "精神",
}

local INV_SLOTS = {
    [1] = "head", [2] = "neck", [3] = "shoulder", [5] = "chest", [6] = "waist",
    [7] = "legs", [8] = "feet", [9] = "wrist", [10] = "hands", [11] = "finger1",
    [12] = "finger2", [13] = "trinket1", [14] = "trinket2", [15] = "back",
    [16] = "mainhand", [17] = "offhand", [18] = "ranged",
}

local CLIENT_STAT_MAP = {
    ITEM_MOD_STRENGTH_SHORT = "strength",
    ITEM_MOD_STAMINA_SHORT = "stamina",
    ITEM_MOD_AGILITY_SHORT = "agility",
    ITEM_MOD_INTELLECT_SHORT = "intellect",
    ITEM_MOD_SPIRIT_SHORT = "spirit",
    ITEM_MOD_ATTACK_POWER_SHORT = "attackPower",
    ITEM_MOD_HIT_RATING_SHORT = "hit",
    ITEM_MOD_CRIT_RATING_SHORT = "crit",
    ITEM_MOD_DODGE_RATING_SHORT = "dodge",
    ITEM_MOD_PARRY_RATING_SHORT = "parry",
    ITEM_MOD_BLOCK_RATING_SHORT = "block",
    ITEM_MOD_BLOCK_VALUE_SHORT = "blockValue",
    ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = "defense",
    RESISTANCE0_NAME = "armor",
}

local EQUIP_LOC_SLOT = {
    INVTYPE_HEAD = "head", INVTYPE_NECK = "neck", INVTYPE_SHOULDER = "shoulder",
    INVTYPE_CLOAK = "back", INVTYPE_CHEST = "chest", INVTYPE_ROBE = "chest",
    INVTYPE_WRIST = "wrist", INVTYPE_HAND = "hands", INVTYPE_WAIST = "waist",
    INVTYPE_LEGS = "legs", INVTYPE_FEET = "feet", INVTYPE_FINGER = "finger",
    INVTYPE_TRINKET = "trinket", INVTYPE_WEAPON = "mainhand", INVTYPE_WEAPONMAINHAND = "mainhand",
    INVTYPE_2HWEAPON = "twohand", INVTYPE_SHIELD = "offhand", INVTYPE_HOLDABLE = "offhand",
    INVTYPE_WEAPONOFFHAND = "offhand", INVTYPE_RANGED = "ranged", INVTYPE_RANGEDRIGHT = "ranged",
    INVTYPE_THROWN = "ranged",
}

-- 练级权重。护甲、防御、攻强取温和系数，避免同级布/皮甲压过板/锁甲；仍可通过 weights 覆盖。武器每秒伤害只加在主手和双手上。
local DEFAULT_WEIGHTS = {
    strength = 5, stamina = 4, agility = 3,
    hit = 2.5, crit = 2, attackPower = 2,
    dodge = 1.5, parry = 1.5, block = 1.5,
    defense = 1, blockValue = 0.5, armor = 0.05,
    weaponDps = 1.5,
}

-- 数据驱动的专精配置表：后续扩展武器/狂暴或其他职业时只需补充条目，无需散落分支。
local PROFILES = {
    ["战士"] = {
        protection = {
            id = "warrior-protection",
            label = "战士·防护",
            bias = "leveling",
            scored = true,
            loadout = "1h_shield",
            weights = DEFAULT_WEIGHTS,
            weightNote = "练级：力量 5、耐力 4、敏捷 3、命中等级 2.5、爆击等级和攻强 2、躲闪/招架/格挡等级 1.5、防御等级 1、格挡值 0.5、护甲 0.05；主手和双手另计武器每秒伤害 1.5。不是 60 级团本模拟，也不是绝对最优。",
            aliases = {
                ["防护"] = true, ["防御"] = true, ["protection"] = true,
                ["warrior-protection"] = true, ["战士·防护"] = true,
            },
        },
    },
}

local NON_COMBAT = { shirt = true, tabard = true, ["衬衣"] = true, ["战袍"] = true }
local fallbackManualSpec

local function AccessibleValue(value)
    if ns.Util and ns.Util.Accessible then return ns.Util.Accessible(value) end
    if type(canaccessvalue) == "function" then
        local ok, allowed = pcall(canaccessvalue, value)
        if not ok or not allowed then return nil end
    end
    return value
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g = pcall(fn, ...)
    if not ok then return nil end
    return AccessibleValue(a), AccessibleValue(b), AccessibleValue(c), AccessibleValue(d),
        AccessibleValue(e), AccessibleValue(f), AccessibleValue(g)
end

local function Invalid(message)
    if ns.Util and ns.Util.InvalidArguments then return ns.Util.InvalidArguments(message) end
    return { ok = false, error = { code = "invalid_arguments", message = message } }
end

local function CopyWeights(baseWeights, override)
    local weights = {}
    for key, value in pairs(baseWeights) do weights[key] = value end
    if override == nil then return weights end
    if type(override) ~= "table" then return nil, "weights 必须是表" end
    for key, value in pairs(override) do
        if weights[key] == nil or type(value) ~= "number" then
            return nil, "未知或非法权重: " .. tostring(key)
        end
        weights[key] = value
    end
    return weights
end

local function ResolveProfile(className, spec)
    local classProfiles = PROFILES[className]
    if not classProfiles then return "refuse", nil end
    for key, profile in pairs(classProfiles) do
        if profile.aliases and profile.aliases[spec] then
            return key, profile
        end
    end
    return "generic", nil
end

local function NormalizeQuery(args)
    if type(args) ~= "table" then return nil, Invalid("args 必须是表") end
    local level = args.level
    if type(level) ~= "number" or level ~= math.floor(level) or level < 1 or level > 60 then
        return nil, Invalid("level 必须是 1 到 60 的整数")
    end
    local className = args.class
    if className == 1 or className == "warrior" then className = "战士" end
    if type(className) ~= "string" then return nil, Invalid("class 必须是职业名") end
    local spec = args.spec
    if type(spec) ~= "string" then return nil, Invalid("spec 必须是玩法名") end
    local faction = args.faction
    if faction ~= "联盟" and faction ~= "部落" then return nil, Invalid("faction 必须是联盟或部落") end
    local window = args.questLevelWindow
    if window == nil then window = 5 end
    if type(window) ~= "number" or window < 0 then return nil, Invalid("questLevelWindow 必须是非负数") end
    local wearWindow = args.wearLevelWindow
    if wearWindow == nil then wearWindow = 0 end
    if type(wearWindow) ~= "number" or wearWindow < 0 then return nil, Invalid("wearLevelWindow 必须是非负数") end
    local excludeCompleted = args.excludeCompletedQuests
    if excludeCompleted ~= nil and type(excludeCompleted) ~= "boolean" then
        return nil, Invalid("excludeCompletedQuests 必须是布尔值")
    end
    local includePickup = args.includePickupInfo
    if includePickup ~= nil and type(includePickup) ~= "boolean" then
        return nil, Invalid("includePickupInfo 必须是布尔值")
    end
    local includeExplanation = args.includeExplanation
    if includeExplanation ~= nil and type(includeExplanation) ~= "boolean" then
        return nil, Invalid("includeExplanation 必须是布尔值")
    end
    local limit = args.limit
    if limit == nil then limit = 8 end
    if type(limit) ~= "number" or limit ~= math.floor(limit) or limit < 1 or limit > 100 then
        return nil, Invalid("limit 必须是 1 到 100 的整数")
    end
    local mode, profileDef = ResolveProfile(className, spec)
    local weights, weightError
    if profileDef and profileDef.scored then
        weights, weightError = CopyWeights(profileDef.weights, args.weights)
        if not weights then return nil, Invalid(weightError) end
    elseif args.weights ~= nil then
        return nil, Invalid("只有战士防护接受权重")
    end
    local hasQuestLogCheck = type(C_QuestLog) == "table" and type(C_QuestLog.IsQuestFlaggedCompleted) == "function"
    local shouldExcludeCompleted = excludeCompleted ~= false and hasQuestLogCheck
    local shouldIncludePickup = includePickup ~= false
    local shouldIncludeExplanation = includeExplanation ~= false
    return {
        level = level, wearLevel = math.min(60, level + wearWindow),
        className = className, spec = spec, faction = faction,
        window = window, wearWindow = wearWindow, limit = limit,
        excludeCompleted = shouldExcludeCompleted, includePickup = shouldIncludePickup,
        includeExplanation = shouldIncludeExplanation,
        mode = mode, profileDef = profileDef, weights = weights, race = args.race,
    }
end

local cachedCatalog, cachedCount, cachedById, cachedByPool
local function Index(catalog)
    local items = catalog.items or {}
    if cachedCatalog == catalog and cachedCount == #items and cachedById and cachedByPool then
        return cachedById, cachedByPool
    end
    local byId, byPool = {}, {}
    for _, item in ipairs(items) do
        byId[item.id] = item
        byPool[item.slot] = byPool[item.slot] or {}
        table.insert(byPool[item.slot], item)
    end
    cachedCatalog, cachedCount, cachedById, cachedByPool = catalog, #items, byId, byPool
    return byId, byPool
end

local function LearnLocked(item, catalog, level)
    local learn = catalog.meta and catalog.meta.learnAt or {}
    if item.armorType and learn[item.armorType] and level < learn[item.armorType] then return true end
    if item.subtype and learn[item.subtype] and level < learn[item.subtype] then return true end
    return false
end

local function ClassAllowed(item, className)
    if type(item.classes) ~= "table" or #item.classes == 0 then return true end
    for _, name in ipairs(item.classes) do
        if name == className then return true end
    end
    return false
end

local function Wearable(item, level)
    if item.reqLevelStatus == "known" then
        if item.reqLevel > level then return false, "known" end
        return true, "known"
    end
    if item.reqLevelStatus == "estimated" then
        if item.reqEstimate and item.reqEstimate > level then return false, "estimated" end
        return true, "estimated"
    end
    return true, "unknown"
end

local function IsQuestCompleted(questId)
    if type(questId) ~= "number" or questId <= 0 then return false end
    if type(C_QuestLog) ~= "table" or type(C_QuestLog.IsQuestFlaggedCompleted) ~= "function" then return false end
    return SafeCall(C_QuestLog.IsQuestFlaggedCompleted, questId) == true
end

local function IsQuestActive(questId)
    if type(questId) ~= "number" or questId <= 0 then return false end
    if type(C_QuestLog) ~= "table" or type(C_QuestLog.IsOnQuest) ~= "function" then return false end
    return SafeCall(C_QuestLog.IsOnQuest, questId) == true
end

local function ShallowCopy(tbl)
    local out = {}
    for k, v in pairs(tbl) do out[k] = v end
    return out
end

local function FormatCoords(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    return string.format("(%d,%d)", math.floor(x + 0.5), math.floor(y + 0.5))
end

local function ReadCachedLocations(db, entity, kind, id, locCache)
    if ns.Objectives and type(ns.Objectives.SharedLocationCache) == "function" then
        local cache = ns.Objectives.SharedLocationCache(db)
        local key = kind .. ":" .. id
        local cached = cache.entries[key]
        if not cached then
            cached = ns.Database.ReadLocations(db, entity, id)
            if type(cached) == "table" and #cached > 0 then
                local cacheable = true
                for _, loc in ipairs(cached) do
                    if loc.available and not loc.world then cacheable = false; break end
                    if not loc.available and (loc.reason == "unsupported_map" or loc.reason == "map_mapping_missing") then
                        cacheable = false; break
                    end
                end
                if cacheable then
                    if cache.count >= 256 then cache.entries, cache.count = {}, 0 end
                    cache.entries[key] = cached
                    cache.count = cache.count + 1
                end
            end
        end
        return cached
    end
    local key = kind .. ":" .. id
    if locCache and locCache[key] then return locCache[key] end
    local locs = ns.Database.ReadLocations(db, entity, id)
    if locCache and type(locs) == "table" then locCache[key] = locs end
    return locs
end

local function PickStarterEntity(db, ids, entity, kind, locCache)
    if type(ids) ~= "table" or not entity or type(entity.Exists) ~= "function" then return nil end
    local fallback
    for _, id in ipairs(ids) do
        if type(id) == "number" and id > 0 and SafeCall(entity.Exists, id) == true then
            local name = SafeCall(entity.name, id)
            local info = {
                giverKind = kind,
                giverId = id,
                giverName = type(name) == "string" and name or nil,
            }
            if kind == "npc" or kind == "object" then
                if ns.Database and type(ns.Database.ReadLocations) == "function" then
                    local locs = ReadCachedLocations(db, entity, kind, id, locCache)
                    for _, loc in ipairs(locs or {}) do
                        if loc.available then
                            info.mapID = loc.coordinateMapID
                            info.mapName = loc.mapName
                            info.x = loc.originalX
                            info.y = loc.originalY
                            return info
                        elseif loc.reason == "instance_only" then
                            info.instanceOnly = true
                        end
                    end
                end
            elseif kind == "item" and db.Item then
                local npcDrops = SafeCall(db.Item.npcDrops, id)
                if type(npcDrops) == "table" and #npcDrops > 0 and db.Npc then
                    local dropLoc = PickStarterEntity(db, npcDrops, db.Npc, "npc", locCache)
                    if dropLoc then
                        info.mapID = dropLoc.mapID
                        info.mapName = dropLoc.mapName
                        info.x = dropLoc.x
                        info.y = dropLoc.y
                        info.dropperName = dropLoc.giverName
                        info.instanceOnly = dropLoc.instanceOnly
                    end
                end
            end
            if not fallback then fallback = info end
        end
    end
    return fallback
end

local function FindUnfinishedPrerequisite(questId, db, fallbackPreIds)
    if db and db.Quest and SafeCall(db.Quest.Exists, questId) == true then
        local preGroup = SafeCall(db.Quest.preQuestGroup, questId)
        if type(preGroup) == "table" and #preGroup > 0 then
            local activeId, pendingId
            for _, pid in ipairs(preGroup) do
                if type(pid) == "number" and pid > 0 and not IsQuestCompleted(pid) then
                    if IsQuestActive(pid) then activeId = activeId or pid
                    else pendingId = pendingId or pid end
                end
            end
            if activeId then return activeId, "prereq_in_progress" end
            if pendingId then return pendingId, "prereq_needed" end
        end
        local preSingle = SafeCall(db.Quest.preQuestSingle, questId)
        if type(preSingle) == "table" and #preSingle > 0 then
            local satisfied = false
            local activeId, pendingId
            for _, pid in ipairs(preSingle) do
                if type(pid) == "number" and pid > 0 then
                    if IsQuestCompleted(pid) then
                        satisfied = true
                        break
                    elseif IsQuestActive(pid) then
                        activeId = activeId or pid
                    elseif not pendingId then
                        pendingId = pid
                    end
                end
            end
            if not satisfied then
                if activeId then return activeId, "prereq_in_progress" end
                if pendingId then return pendingId, "prereq_needed" end
            end
        end
        return nil, nil
    end
    if type(fallbackPreIds) == "table" and #fallbackPreIds > 0 then
        local activeId, pendingId
        for _, pid in ipairs(fallbackPreIds) do
            if type(pid) == "number" and pid > 0 then
                if IsQuestCompleted(pid) then return nil, nil end
                if IsQuestActive(pid) then activeId = activeId or pid
                elseif not pendingId then pendingId = pid end
            end
        end
        if activeId then return activeId, "prereq_in_progress" end
        if pendingId then return pendingId, "prereq_needed" end
    end
    return nil, nil
end

local function FormatPickupText(pickup)
    if not pickup then return nil end
    if pickup.status == "completed" then return "任务已完成" end
    if pickup.status == "in_progress" then return "任务进行中" end
    if pickup.status == "prereq_in_progress" then
        return "前置「" .. (pickup.questName or ("任务" .. tostring(pickup.questId))) .. "」进行中"
    end
    local prefix = pickup.isPrerequisite and "先去" or "去"
    local coords = FormatCoords(pickup.x, pickup.y)
    local place
    if pickup.mapName then
        place = coords and (pickup.mapName .. coords) or pickup.mapName
    elseif pickup.instanceOnly then
        place = "副本内"
    end
    local action
    if pickup.giverKind == "npc" and pickup.giverName then
        action = "找" .. pickup.giverName
    elseif pickup.giverKind == "object" and pickup.giverName then
        action = "调查「" .. pickup.giverName .. "」"
    elseif pickup.giverKind == "item" and pickup.giverName then
        local from = pickup.dropperName and ("（" .. pickup.dropperName .. "掉落）") or ""
        action = "用物品「" .. pickup.giverName .. "」" .. from
    end
    local target = pickup.isPrerequisite
        and ("接前置「" .. (pickup.questName or ("任务" .. tostring(pickup.questId))) .. "」")
        or "接任务"
    if place and action then
        return prefix .. place .. action .. target
    elseif action then
        return (pickup.isPrerequisite and "先" or "") .. action .. target
    elseif place then
        return prefix .. place .. target
    end
    return nil
end

local function ResolveQuestPickup(source, pickupCache, locCache)
    if type(source) ~= "table" or source.kind ~= "quest" then return nil end
    local questId = source.questId
    if type(questId) ~= "number" or questId <= 0 then return nil end
    if pickupCache and pickupCache[questId] ~= nil then
        local cached = pickupCache[questId]
        return cached ~= false and cached or nil
    end
    local function Remember(value)
        if pickupCache then pickupCache[questId] = value or false end
        return value
    end
    local hasQuestLog = type(C_QuestLog) == "table" and type(C_QuestLog.IsQuestFlaggedCompleted) == "function"
    local db = ns.Database and type(ns.Database.Get) == "function" and ns.Database.Get() or nil
    if not hasQuestLog and not db then return Remember(nil) end
    if IsQuestCompleted(questId) then
        local p = { status = "completed", questId = questId, questName = source.name }
        p.text = FormatPickupText(p)
        return Remember(p)
    end
    if IsQuestActive(questId) then
        local p = { status = "in_progress", questId = questId, questName = source.name }
        p.text = FormatPickupText(p)
        return Remember(p)
    end
    local fallbackPreIds = source.prerequisites and source.prerequisites.ids or nil
    local entryId, status = questId, "available"
    if hasQuestLog then
        local visited = { [questId] = true }
        for _ = 1, 12 do
            local preId, preStatus = FindUnfinishedPrerequisite(entryId, db, entryId == questId and fallbackPreIds or nil)
            if not preId then break end
            if preStatus == "prereq_in_progress" then
                entryId, status = preId, "prereq_in_progress"
                break
            end
            if visited[preId] then break end
            visited[preId] = true
            entryId, status = preId, "prereq_needed"
        end
    end
    local isPrereq = entryId ~= questId
    local entryName = (not isPrereq and source.name) or nil
    if not entryName and db and db.Quest and SafeCall(db.Quest.Exists, entryId) == true then
        local qName = SafeCall(db.Quest.name, entryId)
        if type(qName) == "string" and qName ~= "" then entryName = qName end
    end
    if not entryName and isPrereq and source.previousName and source.previousName ~= source.name then
        entryName = source.previousName
    end

    local starter
    if status ~= "prereq_in_progress" and db and db.Quest and SafeCall(db.Quest.Exists, entryId) == true then
        local startedBy = SafeCall(db.Quest.startedBy, entryId)
        if type(startedBy) == "table" then
            starter = PickStarterEntity(db, startedBy[1], db.Npc, "npc", locCache)
                or PickStarterEntity(db, startedBy[2], db.Object, "object", locCache)
                or PickStarterEntity(db, startedBy[3], db.Item, "item", locCache)
        end
    end

    if not starter and status == "available" and not source.zone then
        return Remember(nil)
    end

    local pickup = {
        status = status,
        questId = entryId,
        questName = entryName,
        isPrerequisite = isPrereq,
        giverKind = starter and starter.giverKind or nil,
        giverId = starter and starter.giverId or nil,
        giverName = starter and starter.giverName or nil,
        dropperName = starter and starter.dropperName or nil,
        mapID = starter and starter.mapID or nil,
        mapName = (starter and starter.mapName) or (not isPrereq and source.zone) or nil,
        x = starter and starter.x or nil,
        y = starter and starter.y or nil,
        instanceOnly = starter and starter.instanceOnly or nil,
    }
    pickup.text = FormatPickupText(pickup)
    -- 既无 QuestieDB 接取人，也没有明确前置/进行中状态时，避免凭静态 zone 伪造接取人信息
    if not starter and status == "available" then return Remember(nil) end
    return Remember(pickup)
end

local function SourceAllowed(source, query)
    if source.kind == "quest" then
        if query.excludeCompleted and IsQuestCompleted(source.questId) then
            return false, "quest_completed"
        end
        if source.profession then return false, "profession" end
        if source.questClass and source.questClass ~= query.className then
            return false, "quest_class"
        end
        if source.side and source.sideStatus ~= "unknown" and source.side ~= query.faction then
            return false, "faction"
        end
        if source.minLevel and (source.minLevelStatus == "known" or source.minLevelStatus == "temporary")
            and source.minLevel > query.wearLevel then
            return false, "quest_min_level"
        end
        if source.questLevelStatus == "known" and source.questLevel
            and source.questLevel > query.level + query.window then
            return false, "quest_level_window"
        end
        return true
    end
    if source.kind == "drop" then
        if not source.instanceId then return false, "no_instance" end
        if source.enterLevelStatus == "recorded" and source.enterLevel and source.enterLevel > query.wearLevel then
            return false, "instance_enter"
        end
        return true
    end
    return false, "source"
end

local function UsableSources(item, query)
    local kept = {}
    local rejected = {
        quest_completed = 0, profession = 0, quest_class = 0, faction = 0,
        quest_min_level = 0, quest_level_window = 0,
        no_instance = 0, instance_enter = 0, source = 0,
    }
    for _, source in ipairs(item.sources or {}) do
        local ok, reason = SourceAllowed(source, query)
        if ok then
            table.insert(kept, source)
        else
            rejected[reason] = (rejected[reason] or 0) + 1
        end
    end
    return kept, rejected
end

local function EnrichCandidatePickups(candidate, pickupCache, locCache, enrichedSet)
    if not candidate or (enrichedSet and enrichedSet[candidate]) then return end
    if enrichedSet then enrichedSet[candidate] = true end
    local sources = candidate.sources
    if type(sources) ~= "table" then return end
    local updated
    for i, source in ipairs(sources) do
        if source.kind == "quest" and not source.pickup then
            local pickup = ResolveQuestPickup(source, pickupCache, locCache)
            if pickup then
                if not updated then
                    updated = {}
                    for j = 1, #sources do updated[j] = sources[j] end
                end
                local enriched = ShallowCopy(source)
                enriched.pickup = pickup
                updated[i] = enriched
            end
        end
    end
    if updated then candidate.sources = updated end
end

local function Counts(weight)
    return type(weight) == "number" and weight ~= 0
end

local function Score(item, weights)
    local terms, unquantified, total = {}, {}, 0
    local stats = item.stats or {}
    for _, key in ipairs(ORDER) do
        if key ~= "weaponDps" and stats[key] ~= nil and Counts(weights[key]) then
            local points = stats[key] * weights[key]
            total = total + points
            table.insert(terms, { stat = key, label = STAT_LABEL[key], value = stats[key], weight = weights[key], points = points })
        end
    end
    local seenOrder = {}
    for _, key in ipairs(ORDER) do
        seenOrder[key] = true
        if key ~= "weaponDps" and stats[key] ~= nil and not Counts(weights[key]) then
            local reason = weights[key] == 0 and "练级不计" or "未计入"
            table.insert(unquantified, (STAT_LABEL[key] or key) .. " " .. tostring(stats[key]) .. " " .. reason)
        end
    end
    local extraKeys = {}
    for key in pairs(stats) do
        if not seenOrder[key] and not Counts(weights[key]) then
            extraKeys[#extraKeys + 1] = key
        end
    end
    table.sort(extraKeys)
    for _, key in ipairs(extraKeys) do
        local reason = weights[key] == 0 and "练级不计" or "未计入"
        table.insert(unquantified, (STAT_LABEL[key] or key) .. " " .. tostring(stats[key]) .. " " .. reason)
    end
    for _, row in ipairs(item.unmappedStats or {}) do
        table.insert(unquantified, tostring(row.stat) .. " 未映射，未计入")
    end
    if item.weapon and item.weapon.dps then
        if (item.hands == 1 or item.hands == 2) and Counts(weights.weaponDps) then
            local points = item.weapon.dps * weights.weaponDps
            total = total + points
            table.insert(terms, { stat = "weaponDps", label = STAT_LABEL.weaponDps, value = item.weapon.dps, weight = weights.weaponDps, points = points })
        else
            table.insert(unquantified, "武器伤害未计入")
        end
    end
    for _, effect in ipairs(item.effects or {}) do
        table.insert(unquantified, "特效未计入：" .. effect)
    end
    if item.setName then table.insert(unquantified, "套装未计入：" .. item.setName) end
    return total, terms, unquantified
end

local function Explain(terms, unquantified, scored)
    if not scored then return "未配置这个玩法的权重，不套用防护权重，因此没有分数。" end
    local parts = {}
    for _, term in ipairs(terms) do
        table.insert(parts, string.format("%s%g×%g", term.label, term.value, term.weight))
    end
    local text = "练级属性：" .. (#parts > 0 and table.concat(parts, " + ") or "没有可计属性")
    if #unquantified > 0 then
        text = text .. "。" .. table.concat(unquantified, "；")
    else
        text = text .. "。没有写入的特效或套装。"
    end
    return text
end

local function StatDiff(candidate, current)
    local diff, seen = {}, {}
    for _, key in ipairs(ORDER) do
        local left = (candidate.stats or {})[key] or 0
        local right = (current.stats or {})[key] or 0
        if key == "weaponDps" then
            left = candidate.weapon and (candidate.hands == 1 or candidate.hands == 2) and candidate.weapon.dps or 0
            right = current.weapon and (current.hands == 1 or current.hands == 2) and current.weapon.dps or 0
        end
        if left ~= right then diff[key] = left - right end
        seen[key] = true
    end
    return diff
end

local function Candidate(item, sources, query, current, reservedIds)
    local scored = query.profileDef and query.profileDef.scored == true
    local score, terms, unquantified
    if scored then score, terms, unquantified = Score(item, query.weights) end
    local wearableStatus
    _, wearableStatus = Wearable(item, query.wearLevel)
    local relation, proven, diff = "candidate", false, nil
    local comparison = current and "known" or "no_current_gear"
    if current and current.occupied then
        comparison = "occupied_by_twohand"
    elseif current and current.known == false then
        comparison = "current_unknown"
    elseif current and current.item then
        if current.item.hands == 2 and (item.slot == "mainhand" or item.hands == 1) then
            comparison = "needs_pair"
        elseif scored then
            diff = { score = score - current.score, stats = StatDiff(item, current.item) }
            if diff.score > 1e-6 then relation, proven = "upgrade", true else relation = "not_upgrade" end
        end
    end
    local blocked = reservedIds and reservedIds[item.id] and "duplicate_item" or nil
    if blocked then proven = false end
    return {
        id = item.id, name = item.name, url = item.url, slot = item.slot, hands = item.hands, subtype = item.subtype,
        ilvl = item.ilvl, reqLevel = item.reqLevel, reqEstimate = item.reqEstimate,
        reqLevelStatus = item.reqLevelStatus, wearable = wearableStatus,
        score = score, scoreStatus = scored and "heuristic" or "not_scored",
        terms = terms, unquantified = unquantified,
        explanation = query.includeExplanation and Explain(terms or {}, unquantified or {}, scored) or nil,
        relation = relation, provenUpgrade = proven, diff = diff, comparison = comparison,
        blocked = blocked, sources = sources, appearanceSourceType = item.appearanceSourceType,
        conditions = {
            obtainable = "not_confirmed",
            questState = query.excludeCompleted and "checked" or "not_checked",
            weaponSkill = "not_in_dataset",
            race = "not_in_dataset",
            accessComplete = false,
            unique = item.uniqueStatus,
        },
    }
end

local function SortCandidates(list)
    table.sort(list, function(a, b)
        local aUpgrade = a.provenUpgrade and 1 or 0
        local bUpgrade = b.provenUpgrade and 1 or 0
        if aUpgrade ~= bUpgrade then return aUpgrade > bUpgrade end
        if a.score ~= b.score then
            if a.score == nil then return false end
            if b.score == nil then return true end
            return a.score > b.score
        end
        if (a.ilvl or -1) ~= (b.ilvl or -1) then return (a.ilvl or -1) > (b.ilvl or -1) end
        return a.id < b.id
    end)
end

local function EmptyReason(counts, listed)
    if listed == 0 then return "dataset_has_no_item", "这个部位没有采到任务或副本来源，不表示游戏里没有。" end
    if counts.class > 0 and counts.level == 0 and counts.armor == 0 and counts.source == 0 and counts.listed == counts.class then
        return "wrong_class", "这些候选的职业限制不包括当前职业。"
    end
    if counts.armor > 0 and counts.level == 0 and counts.class == 0 and counts.source == 0 then
        return "armor_not_learned", "护甲或武器尚未到职业可学等级。"
    end
    if counts.source > 0 and counts.level == 0 then
        local sr = counts.sourceReasons or {}
        if (sr.quest_completed or 0) > 0
            and (sr.profession or 0) == 0 and (sr.quest_class or 0) == 0 and (sr.faction or 0) == 0
            and (sr.quest_min_level or 0) == 0 and (sr.quest_level_window or 0) == 0
            and (sr.no_instance or 0) == 0 and (sr.instance_enter or 0) == 0 and (sr.source or 0) == 0 then
            return "quests_completed", "这个部位的已知任务奖励都已完成，暂无其他可用候选。"
        end
        return "no_allowed_source", "候选都被来源条件排除：阵营、专业分类、任务等级、副本准入，或没有关联到副本。"
    end
    if counts.level > 0 then return "above_level", "需要等级或估值高于角色等级。" end
    return "no_match", "没有同时满足等级、职业和来源的候选。"
end

local function Fits(item, spec, mode)
    if mode == "protection" then
        if spec.pool == "mainhand" then return item.slot == "mainhand" and item.hands == 1 end
        if spec.pool == "offhand" then return item.slot == "offhand" end
        return item.slot == spec.pool
    end
    if spec.pool == "mainhand" then return item.slot == "mainhand" or item.slot == "twohand" end
    return item.slot == spec.pool
end

local function BuildSlot(spec, pool, query, byId, currentEntry, reservedIds, catalog, pickupCache, locCache, enrichedSet)
    local counts = { listed = 0, level = 0, class = 0, armor = 0, source = 0, sourceReasons = {} }
    local candidates = {}
    for _, item in ipairs(pool) do
        if Fits(item, spec, query.mode) then
            counts.listed = counts.listed + 1
            if not ClassAllowed(item, query.className) then
                counts.class = counts.class + 1
            elseif LearnLocked(item, catalog, query.wearLevel) then
                counts.armor = counts.armor + 1
            else
                local wearable = Wearable(item, query.wearLevel)
                if not wearable then
                    counts.level = counts.level + 1
                else
                    local sources, rejected = UsableSources(item, query)
                    if #sources == 0 then
                        counts.source = counts.source + 1
                        for reason, n in pairs(rejected or {}) do
                            if n > 0 then
                                counts.sourceReasons[reason] = (counts.sourceReasons[reason] or 0) + n
                            end
                        end
                    else
                        table.insert(candidates, Candidate(item, sources, query, currentEntry, reservedIds))
                    end
                end
            end
        end
    end
    SortCandidates(candidates)
    local highlight
    for _, candidate in ipairs(candidates) do
        if not candidate.blocked and candidate.relation ~= "not_upgrade" then highlight = candidate break end
    end
    local shown = {}
    for index = 1, math.min(query.limit, #candidates) do shown[index] = candidates[index] end
    if query.includePickup then
        for _, candidate in ipairs(shown) do
            EnrichCandidatePickups(candidate, pickupCache, locCache, enrichedSet)
        end
        if highlight then
            EnrichCandidatePickups(highlight, pickupCache, locCache, enrichedSet)
        end
    end
    local reason, message
    if not highlight then
        local usable = false
        for _, candidate in ipairs(candidates) do
            if not candidate.blocked then usable = true end
        end
        if #candidates > 0 and not usable then
            reason, message = "no_distinct_item", "配对槽不能再装备同一件物品。"
        elseif #candidates > 0 then
            reason, message = "no_upgrade", "没有高于现装的候选。"
        else
            reason, message = EmptyReason(counts, counts.listed)
        end
    end
    local coverage = catalog.meta and catalog.meta.slots and catalog.meta.slots[spec.pool]
    return {
        slot = spec.id, label = spec.label, pool = spec.pool,
        total = #candidates, count = #shown, candidates = shown, highlight = highlight,
        emptyReason = highlight and nil or reason, emptyMessage = highlight and nil or message,
        filtered = counts, current = currentEntry and {
            id = currentEntry.id, known = currentEntry.known, name = currentEntry.item and currentEntry.item.name or nil,
            score = currentEntry.score, reason = currentEntry.reason,
        } or nil,
        coverage = coverage and { kept = coverage.kept, truncated = coverage.truncated, complete = false } or { complete = false },
    }
end

local function HasReadableStats(snapshot)
    if type(snapshot) ~= "table" then return false end
    if type(snapshot.stats) == "table" then
        for _, value in pairs(snapshot.stats) do
            if type(value) == "number" and value ~= 0 then return true end
        end
    end
    if type(snapshot.weapon) == "table" and type(snapshot.weapon.dps) == "number" and snapshot.weapon.dps > 0 then
        return true
    end
    return false
end

local function ResolveCurrentItem(entry, slotId, byId, gearStats)
    local item = byId[entry]
    if item then return item, "catalog" end
    if type(gearStats) == "table" then
        local snap = gearStats[slotId] or gearStats[entry]
        if HasReadableStats(snap) and (snap.id == nil or snap.id == entry) then
            return {
                id = entry,
                name = snap.name,
                slot = snap.slot or slotId,
                hands = snap.hands or 0,
                ilvl = snap.ilvl,
                stats = snap.stats or {},
                weapon = snap.weapon,
                effects = snap.effects or {},
                setName = snap.setName,
            }, "client_stats"
        end
    end
    return nil, nil
end

local function CurrentFor(spec, gear, byId, query, gearStats)
    local entry = spec.pair and gear[spec.id] or (gear[spec.id] or gear[spec.pool])
    if not entry then return nil end
    local item, source = ResolveCurrentItem(entry, spec.id, byId, gearStats)
    if not item then
        return { id = entry, known = false, reason = "当前装备不在已采集数据里，不能把缺失属性当零，也不判断提升。" }
    end
    local known = { id = entry, known = true, item = item, source = source }
    if query.profileDef and query.profileDef.scored then known.score = Score(item, query.weights) end
    return known
end

local function ParseGear(gear)
    local mapped, ignored, ambiguous = {}, {}, false
    if gear == nil then return mapped, ignored, false end
    if type(gear) ~= "table" then return nil, nil, true end
    local function assign(slot, id)
        if NON_COMBAT[slot] then table.insert(ignored, slot) return end
        if type(id) ~= "number" then ambiguous = true return end
        if mapped[slot] and mapped[slot] ~= id then ambiguous = true return end
        mapped[slot] = id
    end
    local count = #gear
    if count > 0 then
        for _, entry in ipairs(gear) do
            if type(entry) == "number" then
                table.insert(mapped, entry)
            elseif type(entry) == "table" and entry.slot and entry.id then
                assign(entry.slot, entry.id)
            else
                ambiguous = true
            end
        end
    end
    for key, value in pairs(gear) do
        if type(key) == "string" then assign(key, value) end
    end
    return mapped, ignored, ambiguous
end

local function AssignPaired(mapped, base, id)
    local first, second = base .. "1", base .. "2"
    if not mapped[first] then mapped[first] = id return true end
    if not mapped[second] then mapped[second] = id return true end
    return false
end

local function ResolveLooseIds(mapped, byId)
    if mapped.twohand then
        if mapped.mainhand and mapped.mainhand ~= mapped.twohand then return false end
        mapped.mainhand = mapped.twohand
        mapped.twohand = nil
    end
    for _, pair in ipairs({ "finger", "trinket" }) do
        if mapped[pair] then
            local id = mapped[pair]
            mapped[pair] = nil
            if not AssignPaired(mapped, pair, id) then return false end
        end
    end
    local loose = {}
    for _, id in ipairs(mapped) do table.insert(loose, id) end
    for index = #mapped, 1, -1 do mapped[index] = nil end
    for _, id in ipairs(loose) do
        local item = byId[id]
        if not item then mapped["unknown:" .. id] = id
        else
            local slot = item.slot
            if slot == "twohand" then slot = "mainhand" end
            if slot == "finger" or slot == "trinket" then
                if not AssignPaired(mapped, slot, id) then return false end
            else
                if mapped[slot] then return false end
                mapped[slot] = id
            end
        end
    end
    return true
end

local Gear = {
    INV_SLOTS = INV_SLOTS,
    EQUIP_LOC_SLOT = EQUIP_LOC_SLOT,
    ResolveQuestPickup = ResolveQuestPickup,
}
ns.Gear = Gear

function Gear.CatalogItem(id, catalog)
    catalog = catalog or ns.GearCatalog
    if type(catalog) ~= "table" or type(catalog.items) ~= "table" then return nil end
    local byId = Index(catalog)
    return byId[id]
end

function Gear.GetManualSpec()
    if ns.RouteOptions and type(ns.RouteOptions.Get) == "function" then
        local ok, settings = pcall(ns.RouteOptions.Get)
        if ok and type(settings) == "table" and type(settings.gearSpec) == "string" then
            return settings.gearSpec
        end
    end
    return fallbackManualSpec
end

function Gear.SetManualSpec(spec)
    fallbackManualSpec = spec
    if ns.RouteOptions and type(ns.RouteOptions.Get) == "function" then
        local ok, settings = pcall(ns.RouteOptions.Get)
        if ok and type(settings) == "table" then
            settings.gearSpec = spec
        end
    end
end

function Gear.DetectWarriorSpec(specName, role)
    local name = type(specName) == "string" and specName or ""
    if role == "TANK" or name:find("防护") or name:find("Protection") then return "防护" end
    if name:find("狂") or name:find("Fury") then return "狂暴" end
    if name:find("武器") or name:find("Arms") then return "武器" end
    return nil
end

function Gear.ReadWarriorSpec()
    local talentName, role
    local api = C_SpecializationInfo
    if type(api) == "table" and type(api.GetSpecialization) == "function" and type(api.GetSpecializationInfo) == "function" then
        local index = SafeCall(api.GetSpecialization, false, false)
        if type(index) == "number" then
            local _, name, _, _, specRole = SafeCall(api.GetSpecializationInfo, index, false, false)
            talentName, role = name, specRole
        end
    end
    local manual = Gear.GetManualSpec()
    local spec = manual or Gear.DetectWarriorSpec(talentName, role)
    local note
    if not spec then
        spec, note = "防护", "没有从天赋判断玩法，先按防护。"
    end
    return spec, talentName, note
end

function Gear.ReadItemLevel(itemOrLink)
    if not itemOrLink then return nil end
    if type(C_Item) == "table" and type(C_Item.GetDetailedItemLevelInfo) == "function" then
        local ilvl = SafeCall(C_Item.GetDetailedItemLevelInfo, itemOrLink)
        if type(ilvl) == "number" and ilvl > 0 then return ilvl end
    end
    if type(GetDetailedItemLevelInfo) == "function" then
        local ilvl = SafeCall(GetDetailedItemLevelInfo, itemOrLink)
        if type(ilvl) == "number" and ilvl > 0 then return ilvl end
    end
    if type(C_Item) == "table" and type(C_Item.GetItemInfo) == "function" then
        local _, _, _, ilvl = SafeCall(C_Item.GetItemInfo, itemOrLink)
        if type(ilvl) == "number" and ilvl > 0 then return ilvl end
    end
    return nil
end

local function ReadClientItemSnapshot(id, link, slotId)
    local source = link or id
    if not source then return nil end
    local rawStats
    if type(C_Item) == "table" and type(C_Item.GetItemStats) == "function" then
        rawStats = SafeCall(C_Item.GetItemStats, source)
    elseif type(GetItemStats) == "function" then
        rawStats = SafeCall(GetItemStats, source)
    end
    local stats, weapon = {}, nil
    if type(rawStats) == "table" then
        for statKey, value in pairs(rawStats) do
            if type(value) == "number" and value ~= 0 then
                local mapped = CLIENT_STAT_MAP[statKey]
                if mapped then
                    stats[mapped] = (stats[mapped] or 0) + value
                elseif statKey == "ITEM_MOD_DAMAGE_PER_SECOND_SHORT" and value > 0 then
                    weapon = { dps = value }
                end
            end
        end
    end
    local hands = 0
    local equipLoc
    if type(C_Item) == "table" and type(C_Item.GetItemInfoInstant) == "function" then
        local _, _, _, loc = SafeCall(C_Item.GetItemInfoInstant, source)
        equipLoc = loc
    end
    if equipLoc == "INVTYPE_2HWEAPON" then
        hands = 2
    elseif equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONMAINHAND" or equipLoc == "INVTYPE_WEAPONOFFHAND" then
        hands = 1
    end
    local ilvl = Gear.ReadItemLevel(source)
    local name
    if type(C_Item) == "table" and type(C_Item.GetItemInfo) == "function" then
        name = SafeCall(C_Item.GetItemInfo, source)
    end
    local snapshot = {
        id = id, name = name, slot = slotId, hands = hands,
        ilvl = ilvl, stats = stats, weapon = weapon,
    }
    return snapshot
end

function Gear.ReadWorn(includeSnapshots)
    local ids = {}
    local snapshots = includeSnapshots and {} or nil
    local ilvls = includeSnapshots and {} or nil
    for inv, slotId in pairs(INV_SLOTS) do
        local id = SafeCall(GetInventoryItemID, "player", inv)
        local link = SafeCall(GetInventoryItemLink, "player", inv)
        if (type(id) ~= "number" or id <= 0) and type(link) == "string" then
            id = tonumber(link:match("item:(%d+)"))
        end
        if type(id) == "number" and id > 0 then
            ids[slotId] = id
            if includeSnapshots then
                local snap = ReadClientItemSnapshot(id, link, slotId)
                if snap then
                    if HasReadableStats(snap) then snapshots[slotId] = snap end
                    if type(snap.ilvl) == "number" and snap.ilvl > 0 then ilvls[slotId] = snap.ilvl end
                end
            end
        end
    end
    return ids, snapshots, ilvls
end

function Gear.Recommend(args, catalog)
    local query, failure = NormalizeQuery(args)
    if not query then return failure end
    if query.mode == "refuse" then
        return {
            ok = false,
            error = {
                code = "unsupported",
                message = "只收录了战士的任务和副本候选，不能把防护权重套到其他职业。",
            },
        }
    end
    catalog = catalog or ns.GearCatalog
    if type(catalog) ~= "table" or type(catalog.items) ~= "table" then
        return { ok = false, error = { code = "no_dataset", message = "没有装备数据集。" } }
    end
    local byId, byPool = Index(catalog)
    local gear, ignored, gearError = ParseGear(args.gear)
    if gearError then return Invalid("gear 必须是槽位到物品 ID 的表，或物品 ID 数组") end
    if not ResolveLooseIds(gear, byId) then return Invalid("同一槽位给了两件现装") end
    local gearStats = type(args.gearStats) == "table" and args.gearStats or nil
    local unrecognized = {}
    for key, id in pairs(gear) do
        if type(key) == "string" and key:find("^unknown:") then unrecognized[#unrecognized + 1] = id end
    end
    local slots, reserved, currentBySlot = {}, {}, {}
    local pickupCache, locCache, enrichedSet = {}, {}, {}
    local mainWeapon = gear.mainhand and ResolveCurrentItem(gear.mainhand, "mainhand", byId, gearStats)
    for _, spec in ipairs(SLOTS) do
        local current = CurrentFor(spec, gear, byId, query, gearStats)
        if spec.pool == "offhand" and mainWeapon and mainWeapon.hands == 2 then
            current = {
                id = mainWeapon.id, known = true, item = mainWeapon, occupied = true,
                score = query.profileDef and query.profileDef.scored and Score(mainWeapon, query.weights) or nil,
                reason = "双手武器同时占用副手。",
            }
        end
        currentBySlot[spec.id] = current
        local pool = byPool[spec.pool] or {}
        if query.mode ~= "protection" and spec.pool == "mainhand" then
            pool = {}
            for _, item in ipairs(byPool.mainhand or {}) do table.insert(pool, item) end
            for _, item in ipairs(byPool.twohand or {}) do table.insert(pool, item) end
        end
        local reservedIds
        if spec.pair then
            reservedIds = {}
            if reserved[spec.pair] then reservedIds[reserved[spec.pair]] = true end
            local sibling = spec.id == (spec.pair .. "1") and (spec.pair .. "2") or (spec.pair .. "1")
            local siblingId = gear[sibling]
            if siblingId and siblingId ~= gear[spec.id] then reservedIds[siblingId] = true end
        end
        local built = BuildSlot(spec, pool, query, byId, current, reservedIds, catalog, pickupCache, locCache, enrichedSet)
        if spec.pair and built.highlight then reserved[spec.pair] = built.highlight.id end
        table.insert(slots, built)
    end
    if query.mode ~= "protection" then
        local mainhand
        for _, slot in ipairs(slots) do
            if slot.slot == "mainhand" then mainhand = slot end
        end
        local highlighted = mainhand and mainhand.highlight and byId[mainhand.highlight.id]
        if highlighted and highlighted.hands == 2 then
            for _, slot in ipairs(slots) do
                if slot.slot == "offhand" then
                    slot.highlight = nil
                    slot.emptyReason = "occupied_by_twohand"
                    slot.emptyMessage = "双手武器已经占用副手。"
                    for _, candidate in ipairs(slot.candidates) do
                        candidate.blocked = "two_hand"
                        candidate.provenUpgrade = false
                    end
                end
            end
        end
    end
    local profile
    if query.profileDef then
        local def = query.profileDef
        profile = {
            id = def.id, label = def.label, bias = def.bias, scored = def.scored, optimum = false,
            loadout = def.loadout, weights = query.weights, questLevelWindow = query.window,
            weightNote = def.weightNote,
        }
    else
        profile = {
            id = "generic", label = query.className .. "·" .. query.spec, bias = nil, scored = false, optimum = false,
            loadout = nil, weights = nil, questLevelWindow = query.window,
            weightNote = "这个玩法没有独立权重，结果只是过滤后的候选，不套用防护权重。",
        }
    end
    local pair
    if query.profileDef and query.profileDef.loadout == "1h_shield" then
        local mainhand, offhand
        for _, slot in ipairs(slots) do
            if slot.slot == "mainhand" then mainhand = slot end
            if slot.slot == "offhand" then offhand = slot end
        end
        local currentMain = currentBySlot.mainhand
        local currentOff = currentBySlot.offhand
        pair = {
            rule = "1h_shield",
            mainhand = mainhand and mainhand.highlight and mainhand.highlight.id or nil,
            offhand = offhand and offhand.highlight and offhand.highlight.id or nil,
            provenUpgrade = false,
            note = "主手和盾的分数相加只用于这一套练级计分。双手武器会同时占两个槽，不能拿单手单独说成提升。",
        }
        if mainhand and mainhand.highlight and mainhand.highlight.score and offhand and offhand.highlight and offhand.highlight.score then
            pair.score = mainhand.highlight.score + offhand.highlight.score
        end
        if mainWeapon and mainWeapon.hands == 2 then
            pair.comparison = "two_hand_occupies_both"
            if pair.score then
                local weaponScore = Score(mainWeapon, query.weights)
                pair.scoreDelta = pair.score - weaponScore
                pair.provenUpgrade = pair.scoreDelta > 1e-6
            end
        elseif currentMain and currentMain.known and currentMain.score
            and currentOff and currentOff.known and currentOff.score then
            local mhUpgrade = mainhand and mainhand.highlight and mainhand.highlight.provenUpgrade
            local ohUpgrade = offhand and offhand.highlight and offhand.highlight.provenUpgrade
            local bestMhId = mhUpgrade and mainhand.highlight.id or currentMain.id
            local bestOhId = ohUpgrade and offhand.highlight.id or currentOff.id
            local bestMhScore = mhUpgrade and mainhand.highlight.score or currentMain.score
            local bestOhScore = ohUpgrade and offhand.highlight.score or currentOff.score
            pair.mainhand = bestMhId
            pair.offhand = bestOhId
            pair.score = bestMhScore + bestOhScore
            pair.scoreDelta = pair.score - (currentMain.score + currentOff.score)
            pair.provenUpgrade = pair.scoreDelta > 1e-6
        elseif mainhand and mainhand.highlight and offhand and offhand.highlight
            and mainhand.highlight.provenUpgrade and offhand.highlight.provenUpgrade then
            pair.provenUpgrade = true
        end
    end
    return {
        ok = true,
        claim = "启发式候选，不是模拟绝对最优。",
        query = {
            level = query.level, class = query.className, spec = query.spec, faction = query.faction,
            race = query.race, raceStatus = "not_in_dataset",
        },
        profile = profile,
        ignoredNonCombat = ignored,
        unrecognizedGear = unrecognized,
        slots = slots,
        pair = pair,
        attribution = catalog.meta and {
            name = catalog.meta.sourceName, url = catalog.meta.sourceUrl, legal = catalog.meta.legal,
            clientBuild = catalog.meta.clientBuild, fetchedAt = catalog.meta.fetchedAt,
        } or nil,
        coverageComplete = false,
    }
end

function ns.GetGearCandidates(args)
    return Gear.Recommend(args)
end
