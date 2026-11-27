-- 角色现有任务价值分析（只读）：评估任务链后续/最终奖励、装备提升、经验/距离与沉没成本，
-- 给出可解释的保留或放弃建议；绝不自动放弃任务，未知或未就绪数据不当作低价值。
local _, ns = ...
local Util = ns.Util
local InvalidArguments, IsFinite, IsID, Accessible = Util.InvalidArguments, Util.IsFinite, Util.IsID, Util.Accessible
local ParsePage, AddPage, DistanceSquared, FormatDistance = Util.ParsePage, Util.AddPage, Util.DistanceSquared, Util.FormatDistance
local GetDatabase, ReadLocations = ns.Database.Get, ns.Database.ReadLocations
local CollectPOIs = ns.QuestData.CollectPOIs
local RouteSettings, TargetAboveLevel = ns.RouteOptions.Get, ns.RouteOptions.TargetAboveLevel

local MAX_CHAIN_DEPTH = 12
local MAX_CHAIN_NODES = 24
local MAX_PRELOAD_PER_CALL = 20
local FAR_DISTANCE_YARDS = 2500

local CLASS_BITS = {
    WARRIOR = 1, PALADIN = 2, HUNTER = 4, ROGUE = 8, PRIEST = 16,
    DEATHKNIGHT = 32, SHAMAN = 64, MAGE = 128, WARLOCK = 256, MONK = 512, DRUID = 1024,
}
local CLASS_NAMES = {
    WARRIOR = "战士", PALADIN = "圣骑士", HUNTER = "猎人", ROGUE = "盗贼", PRIEST = "牧师",
    SHAMAN = "萨满祭司", MAGE = "法师", WARLOCK = "术士", DRUID = "德鲁伊",
}
-- 经典旧世种族位掩码（联盟与部落互斥检测，仅在掩码非 0 且明确只属于对立阵营时排除）
local ALLIANCE_RACE_BITS = { 1, 4, 8, 64, 1024 }
local HORDE_RACE_BITS = { 2, 16, 32, 128, 512 }

local INSTANCE_TAGS = { [62] = true, [81] = true, [85] = true, [88] = true, [89] = true, [98] = true, [288] = true }
local PROFESSION_CATEGORIES = {
    ["炼金术"] = true, ["锻造"] = true, ["附魔"] = true, ["工程学"] = true,
    ["草药学"] = true, ["制皮"] = true, ["采矿"] = true, ["剥皮"] = true,
    ["裁缝"] = true, ["钓鱼"] = true, ["烹饪"] = true, ["急救"] = true,
    ["珠宝加工"] = true, ["铭文"] = true, ["考古学"] = true,
}

local INV_SLOTS = {
    [1] = "head", [2] = "neck", [3] = "shoulder", [5] = "chest", [6] = "waist",
    [7] = "legs", [8] = "feet", [9] = "wrist", [10] = "hands", [11] = "finger1",
    [12] = "finger2", [13] = "trinket1", [14] = "trinket2", [15] = "back",
    [16] = "mainhand", [17] = "offhand", [18] = "ranged",
}

local QUALITY_LABELS = {
    [0] = "粗糙", [1] = "普通", [2] = "绿装", [3] = "蓝装", [4] = "紫装", [5] = "橙装",
}

local VERDICT_META = {
    recommend_drop = { label = "建议放弃", short = "建议弃", rank = 1, color = "ffff5252" },
    hold_or_drop = { label = "可考虑放弃", short = "可考虑", rank = 2, color = "ffffb74d" },
    uncertain = { label = "待确认", short = "待确认", rank = 3, color = "ffb0bec5" },
    keep = { label = "建议保留", short = "保留", rank = 4, color = "ff66bb6a" },
    keep_priority = { label = "优先保留", short = "优先留", rank = 5, color = "ffffd54f" },
}

local VALID_VERDICTS = {
    recommend_drop = true, hold_or_drop = true, uncertain = true, keep = true, keep_priority = true,
}

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g = pcall(fn, ...)
    if not ok then return nil end
    return Accessible(a), Accessible(b), Accessible(c), Accessible(d), Accessible(e), Accessible(f), Accessible(g)
end

local function HasBit(mask, bit)
    if not IsFinite(mask) or mask <= 0 or not IsFinite(bit) or bit <= 0 then return false end
    return math.floor(mask / bit) % 2 == 1
end

local function MaskAllowsClass(mask, classFile)
    if not IsFinite(mask) or mask <= 0 then return true end
    local bit = classFile and CLASS_BITS[classFile]
    if not bit then return true end
    return HasBit(mask, bit)
end

local function MaskIsSingleClass(mask, classFile)
    if not IsFinite(mask) or mask <= 0 then return false end
    local bit = classFile and CLASS_BITS[classFile]
    return bit ~= nil and mask == bit
end

local function MaskAllowsFaction(mask, faction)
    if not IsFinite(mask) or mask <= 0 then return true end
    if faction ~= "Alliance" and faction ~= "Horde" then return true end
    local ownBits = faction == "Alliance" and ALLIANCE_RACE_BITS or HORDE_RACE_BITS
    local otherBits = faction == "Alliance" and HORDE_RACE_BITS or ALLIANCE_RACE_BITS
    local hasOwn, hasOther = false, false
    for _, bit in ipairs(ownBits) do if HasBit(mask, bit) then hasOwn = true; break end end
    if hasOwn then return true end
    for _, bit in ipairs(otherBits) do if HasBit(mask, bit) then hasOther = true; break end end
    return not hasOther
end

local function FormatMoney(copper)
    if not IsFinite(copper) or copper <= 0 then return nil end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = math.floor(copper % 100)
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "金" end
    if s > 0 then parts[#parts + 1] = s .. "银" end
    if c > 0 and g == 0 then parts[#parts + 1] = c .. "铜" end
    return #parts > 0 and table.concat(parts) or nil
end

local function ReadWornGear()
    if ns.Gear and type(ns.Gear.ReadWorn) == "function" then
        return ns.Gear.ReadWorn(true)
    end
    local gear = {}
    for inv, slotId in pairs(INV_SLOTS) do
        local id = SafeCall(GetInventoryItemID, "player", inv)
        if not IsID(id) then
            local link = SafeCall(GetInventoryItemLink, "player", inv)
            if type(link) == "string" then id = tonumber(link:match("item:(%d+)")) end
        end
        if IsID(id) then gear[slotId] = id end
    end
    return gear, nil, nil
end

local function ReadCharacterProfile(overrideGear)
    local context = ns.GetPlayerContext({})
    local char = context and context.character or {}
    local localizedClass, classFile = SafeCall(UnitClass, "player")
    local faction = char.faction
    local factionCN = faction == "Horde" and "部落" or (faction == "Alliance" and "联盟" or nil)
    local spec
    if classFile == "WARRIOR" then
        if ns.Gear and type(ns.Gear.ReadWarriorSpec) == "function" then
            spec = ns.Gear.ReadWarriorSpec()
        elseif C_SpecializationInfo and type(C_SpecializationInfo.GetSpecialization) == "function"
            and type(C_SpecializationInfo.GetSpecializationInfo) == "function" then
            local idx = SafeCall(C_SpecializationInfo.GetSpecialization, false, false)
            if IsID(idx) then
                local _, name, _, _, role = SafeCall(C_SpecializationInfo.GetSpecializationInfo, idx, false, false)
                if role == "TANK" or (type(name) == "string" and (name:find("防护") or name:find("Protection"))) then
                    spec = "防护"
                elseif type(name) == "string" and (name:find("狂") or name:find("Fury")) then
                    spec = "狂暴"
                elseif type(name) == "string" and (name:find("武器") or name:find("Arms")) then
                    spec = "武器"
                end
            end
        end
        spec = spec or "防护"
    end
    local level = IsID(char.level) and char.level or nil
    local maxXP = context and context.experience and IsFinite(context.experience.maximum) and context.experience.maximum > 0
        and context.experience.maximum or nil
    local worn, wornStats, wornIlvls
    if type(overrideGear) == "table" then
        worn = overrideGear
    else
        worn, wornStats, wornIlvls = ReadWornGear()
    end
    return {
        name = char.name,
        realm = char.realm,
        level = level,
        faction = faction,
        factionCN = factionCN,
        classFile = classFile,
        className = classFile and CLASS_NAMES[classFile] or localizedClass,
        spec = spec,
        maxXP = maxXP,
        location = context and context.location or nil,
        worn = worn,
        wornStats = wornStats,
        wornIlvls = wornIlvls,
    }
end

-- 分帧/按需构建 QuestieDB 反向后续边（preQuestSingle / preQuestGroup / nextQuestInChain），按 db 实例缓存。
local reverseIndexState

local function AddReverseEdge(reverse, fromID, toID)
    if not IsID(fromID) or not IsID(toID) or fromID == toID then return end
    local list = reverse[fromID]
    if not list then
        reverse[fromID] = { toID }
        return
    end
    for _, existing in ipairs(list) do
        if existing == toID then return end
    end
    list[#list + 1] = toID
end

local function EnsureReverseState(db)
    if not db or type(db.Quest) ~= "table" then return nil end
    if reverseIndexState and reverseIndexState.db == db then return reverseIndexState end
    local ids = SafeCall(db.Quest.GetAllIds)
    reverseIndexState = {
        db = db,
        ids = type(ids) == "table" and ids or {},
        cursor = 1,
        done = false,
        map = {},
    }
    if #reverseIndexState.ids == 0 then reverseIndexState.done = true end
    return reverseIndexState
end

local function StepReverseIndex(state, maxQuests, budgetMs)
    if not state or state.done then return true end
    local db, ids, reverse = state.db, state.ids, state.map
    local limit = maxQuests and math.min(#ids, state.cursor + maxQuests - 1) or #ids
    local started = (budgetMs and type(debugprofilestop) == "function") and debugprofilestop() or nil
    local lastProcessed = state.cursor - 1
    for i = state.cursor, limit do
        local qid = ids[i]
        if IsID(qid) then
            local nxt = SafeCall(db.Quest.nextQuestInChain, qid)
            if IsID(nxt) then AddReverseEdge(reverse, qid, nxt) end
            local preSingle = SafeCall(db.Quest.preQuestSingle, qid)
            if type(preSingle) == "table" then
                for _, pre in ipairs(preSingle) do AddReverseEdge(reverse, pre, qid) end
            end
            local preGroup = SafeCall(db.Quest.preQuestGroup, qid)
            if type(preGroup) == "table" then
                for _, pre in ipairs(preGroup) do AddReverseEdge(reverse, pre, qid) end
            end
        end
        lastProcessed = i
        if started and (i - state.cursor) % 16 == 15 and i < limit then
            if debugprofilestop() - started >= budgetMs then break end
        end
    end
    state.cursor = lastProcessed + 1
    if state.cursor > #ids then state.done = true end
    return state.done
end

local function PumpReverseIndex(maxQuests, budgetMs)
    if reverseIndexState and reverseIndexState.done and reverseIndexState.db == rawget(_G, "LibQuestieDB") then
        return false
    end
    local db = GetDatabase()
    if not db then return false end
    local state = EnsureReverseState(db)
    if not state or state.done then return false end
    return StepReverseIndex(state, maxQuests or 128, budgetMs)
end

local function GetReverseNextIndex(db)
    local state = EnsureReverseState(db)
    if not state then return nil end
    if not state.done then StepReverseIndex(state, nil) end
    return state.map
end

-- 缓存本地 GearCatalog 的 questId -> 物品列表索引，即使客户端未缓存后续奖励也能提前识别已知装备。
local cachedCatalogRef, cachedCatalogByQuest, cachedCatalogByItem
local function GetCatalogIndex()
    local catalog = ns.GearCatalog
    if type(catalog) ~= "table" or type(catalog.items) ~= "table" then return nil, nil end
    if cachedCatalogRef == catalog and cachedCatalogByQuest then
        return cachedCatalogByQuest, cachedCatalogByItem
    end
    local byQuest, byItem = {}, {}
    for _, item in ipairs(catalog.items) do
        if IsID(item.id) then
            byItem[item.id] = item
            for _, src in ipairs(item.sources or {}) do
                if src.kind == "quest" and IsID(src.questId) then
                    local list = byQuest[src.questId]
                    if not list then
                        list = {}
                        byQuest[src.questId] = list
                    end
                    list[#list + 1] = item
                end
            end
        end
    end
    cachedCatalogRef, cachedCatalogByQuest, cachedCatalogByItem = catalog, byQuest, byItem
    return byQuest, byItem
end

local function BuildGearEvaluation(profile, allowGear)
    if allowGear == false then return { enabled = false, byItem = {}, byQuest = {} } end
    local byQuest, byItemCatalog = GetCatalogIndex()
    local eval = {
        enabled = true,
        scored = false,
        byItem = {},
        byQuest = byQuest or {},
        catalogByItem = byItemCatalog or {},
    }
    if not profile.level or not profile.factionCN or not profile.className or type(ns.GetGearCandidates) ~= "function"
        or type(ns.GearCatalog) ~= "table" then
        return eval
    end
    if profile.classFile ~= "WARRIOR" and profile.className ~= "战士" then
        return eval
    end
    -- 放宽 questLevelWindow 与穿戴等级窗口，以便对整条任务链的未来奖励也能给出评分与提升对比。
    local queryLevel = math.min(60, math.max(profile.level, 1))
    local res = ns.GetGearCandidates({
        level = queryLevel,
        class = "战士",
        spec = profile.spec or "防护",
        faction = profile.factionCN,
        gear = profile.worn,
        gearStats = profile.wornStats,
        questLevelWindow = 20,
        wearLevelWindow = 15,
        includePickupInfo = false,
        includeExplanation = false,
        limit = 100,
    })
    if not res or not res.ok then return eval end
    eval.scored = res.profile and res.profile.scored == true
    for _, slot in ipairs(res.slots or {}) do
        for _, cand in ipairs(slot.candidates or {}) do
            local existing = eval.byItem[cand.id]
            local delta = cand.diff and IsFinite(cand.diff.score) and cand.diff.score or nil
            local better = not existing
                or (cand.provenUpgrade and not existing.provenUpgrade)
                or (delta and (not existing.scoreDelta or delta > existing.scoreDelta))
            if better then
                eval.byItem[cand.id] = {
                    id = cand.id,
                    name = cand.name,
                    slot = slot.slot,
                    slotLabel = slot.label,
                    provenUpgrade = cand.provenUpgrade == true,
                    relation = cand.relation,
                    score = cand.score,
                    scoreDelta = delta,
                    blocked = cand.blocked ~= nil and cand.blocked ~= false,
                    quality = cand.quality,
                    ilvl = cand.ilvl,
                }
            end
        end
    end
    return eval
end

local GEAR_TIER_RANK = {
    none = 0,
    gear_low = 1,
    uncommon_current = 2,
    rare_usable = 3,
    epic_usable = 4,
    proven_upgrade = 5,
}

local function ArmorMatchesClass(itemID, profile)
    if not IsID(itemID) or not C_Item or type(C_Item.GetItemInfoInstant) ~= "function" then return true end
    local _, _, _, equipLoc, _, classID, subClassID = SafeCall(C_Item.GetItemInfoInstant, itemID)
    if classID ~= 4 then return true end
    -- 披风在客户端中 subClassID 常为 1（布甲），所有职业都可穿戴，不得过滤。
    if equipLoc == "INVTYPE_CLOAK" or equipLoc == "INVTYPE_NECK" or equipLoc == "INVTYPE_FINGER"
        or equipLoc == "INVTYPE_TRINKET" or equipLoc == "INVTYPE_SHIELD" or equipLoc == "INVTYPE_HOLDABLE" then
        return true
    end
    if subClassID ~= 1 and subClassID ~= 2 and subClassID ~= 3 and subClassID ~= 4 then return true end
    local cls = profile.classFile
    local lvl = profile.level or 1
    if cls == "WARRIOR" or cls == "PALADIN" then
        if lvl >= 40 then return subClassID >= 3 end
        return subClassID >= 2
    elseif cls == "HUNTER" or cls == "SHAMAN" then
        if lvl >= 40 then return subClassID >= 3 end
        return subClassID >= 2
    elseif cls == "ROGUE" or cls == "DRUID" or cls == "MONK" then
        return subClassID >= 2
    end
    return true
end

local function WornIlvlForItem(itemID, profile)
    if not IsID(itemID) or type(profile.wornIlvls) ~= "table" then return nil end
    if not C_Item or type(C_Item.GetItemInfoInstant) ~= "function" then return nil end
    local _, _, _, equipLoc = SafeCall(C_Item.GetItemInfoInstant, itemID)
    local map = ns.Gear and ns.Gear.EQUIP_LOC_SLOT
    local pool = equipLoc and map and map[equipLoc] or nil
    if not pool then return nil end
    if pool == "twohand" then pool = "mainhand" end
    if pool == "finger" or pool == "trinket" then
        local a, b = profile.wornIlvls[pool .. "1"], profile.wornIlvls[pool .. "2"]
        if IsFinite(a) and IsFinite(b) then return math.min(a, b) end
        return a or b
    end
    return profile.wornIlvls[pool]
end

local function EvaluateRewardItem(item, profile, gearEval)
    local id = item.itemID
    local quality = IsFinite(item.quality) and item.quality or 0
    local ilvl = IsFinite(item.itemLevel) and item.itemLevel or nil
    local usable = item.isUsable
    local catalogEval = id and gearEval and gearEval.byItem and gearEval.byItem[id] or nil
    local catalogRaw = id and gearEval and gearEval.catalogByItem and gearEval.catalogByItem[id] or nil
    if not ilvl and catalogRaw and IsFinite(catalogRaw.ilvl) then ilvl = catalogRaw.ilvl end
    if quality == 0 and catalogRaw and IsFinite(catalogRaw.quality) then quality = catalogRaw.quality end
    local armorFits = ArmorMatchesClass(id, profile)
    local wornIlvl = WornIlvlForItem(id, profile)
    local ilvlDelta = (IsFinite(ilvl) and IsFinite(wornIlvl)) and (ilvl - wornIlvl) or nil

    local tier = "none"
    local upgrade, scoreDelta, slotLabel = false, nil, nil
    if catalogEval then
        slotLabel = catalogEval.slotLabel
        scoreDelta = catalogEval.scoreDelta
        if catalogEval.provenUpgrade then
            tier = "proven_upgrade"
            upgrade = true
        elseif not catalogEval.blocked and armorFits and quality >= 4 then
            tier = "epic_usable"
        elseif not catalogEval.blocked and armorFits and quality >= 3 then
            tier = "rare_usable"
        elseif not catalogEval.blocked and armorFits and quality >= 2 and profile.level and ilvl and ilvl >= profile.level - 3 then
            tier = "uncommon_current"
        elseif quality >= 2 then
            tier = "gear_low"
        end
    else
        local isWearableCandidate = usable ~= false and armorFits
        if quality >= 4 and isWearableCandidate then
            tier = "epic_usable"
        elseif quality == 3 and isWearableCandidate then
            tier = "rare_usable"
        elseif quality == 2 and usable == true and armorFits and ilvl then
            local meetsIlvl = (ilvlDelta ~= nil and ilvlDelta >= 3)
                or (ilvlDelta == nil and profile.level and ilvl >= profile.level - 3)
                or (ilvlDelta ~= nil and ilvlDelta >= -3 and profile.level and ilvl >= profile.level - 3)
            tier = meetsIlvl and "uncommon_current" or "gear_low"
        elseif quality >= 2 then
            tier = "gear_low"
        end
    end
    return {
        itemID = id,
        name = item.name or (catalogRaw and catalogRaw.name) or ("物品" .. tostring(id or "?")),
        kind = item.kind,
        quality = quality,
        qualityLabel = QUALITY_LABELS[quality] or "物品",
        itemLevel = ilvl,
        ilvlDelta = ilvlDelta,
        isUsable = usable,
        armorFits = armorFits,
        tier = tier,
        tierRank = GEAR_TIER_RANK[tier] or 0,
        provenUpgrade = upgrade,
        scoreDelta = scoreDelta,
        slotLabel = slotLabel,
        source = item.source or "client",
    }
end

local function BetterGear(a, b)
    if not a then return b end
    if not b then return a end
    if a.tierRank ~= b.tierRank then return a.tierRank > b.tierRank and a or b end
    local ad = IsFinite(a.scoreDelta) and a.scoreDelta or -1e9
    local bd = IsFinite(b.scoreDelta) and b.scoreDelta or -1e9
    if ad ~= bd then return ad > bd and a or b end
    if (a.quality or 0) ~= (b.quality or 0) then return (a.quality or 0) > (b.quality or 0) and a or b end
    return (a.itemLevel or 0) >= (b.itemLevel or 0) and a or b
end

local function ReadQuestReward(questID, db, profile, gearEval, preloadState)
    local cached = SafeCall(HaveQuestData, questID)
    local rewardsCached = SafeCall(HaveQuestRewardData, questID)
    local ready = cached == true and rewardsCached == true
    local items, seenItemIDs = {}, {}

    local xp, money, spells = nil, nil, {}
    if ready then
        local rawXP = SafeCall(GetQuestLogRewardXP, questID)
        if IsFinite(rawXP) and rawXP >= 0 then xp = rawXP end
        local rawMoney = SafeCall(GetQuestLogRewardMoney, questID)
        if IsFinite(rawMoney) and rawMoney >= 0 then money = rawMoney end

        local rawSpells = C_QuestInfoSystem and SafeCall(C_QuestInfoSystem.GetQuestRewardSpells, questID)
        if type(rawSpells) == "table" then
            for _, spellID in ipairs(rawSpells) do
                if IsID(spellID) then spells[#spells + 1] = spellID end
            end
        end

        local numRewards = SafeCall(GetNumQuestLogRewards, questID) or 0
        for i = 1, math.min(numRewards, 20) do
            local name, _, count, quality, usable, itemID, itemLevel = SafeCall(GetQuestLogRewardInfo, i, questID)
            if name or IsID(itemID) then
                local eval = EvaluateRewardItem({
                    itemID = itemID, name = name, count = count, quality = quality,
                    isUsable = usable, itemLevel = itemLevel, kind = "fixed", source = "client",
                }, profile, gearEval)
                items[#items + 1] = eval
                if IsID(itemID) then seenItemIDs[itemID] = true end
            end
        end

        local numChoices = SafeCall(GetNumQuestLogChoices, questID, true) or 0
        for i = 1, math.min(numChoices, 20) do
            local name, _, count, quality, usable, itemID, itemLevel = SafeCall(GetQuestLogChoiceInfo, i, questID)
            if name or IsID(itemID) then
                local eval = EvaluateRewardItem({
                    itemID = itemID, name = name, count = count, quality = quality,
                    isUsable = usable, itemLevel = itemLevel, kind = "choice", source = "client",
                }, profile, gearEval)
                items[#items + 1] = eval
                if IsID(itemID) then seenItemIDs[itemID] = true end
            end
        end
    elseif preloadState and preloadState.enabled and not preloadState.requested[questID]
        and preloadState.count < MAX_PRELOAD_PER_CALL
        and C_QuestLog and type(C_QuestLog.RequestLoadQuestByID) == "function" then
        preloadState.requested[questID] = true
        preloadState.count = preloadState.count + 1
        pcall(C_QuestLog.RequestLoadQuestByID, questID)
    end

    -- 补充本地 GearCatalog 中已知由该任务产出的装备（尤其在客户端尚未缓存后续任务奖励时提前兜底）
    if gearEval and gearEval.byQuest and gearEval.byQuest[questID] then
        for _, catItem in ipairs(gearEval.byQuest[questID]) do
            if not seenItemIDs[catItem.id] then
                local eval = EvaluateRewardItem({
                    itemID = catItem.id, name = catItem.name, quality = catItem.quality or 2,
                    itemLevel = catItem.ilvl, isUsable = true, kind = "catalog", source = "GearCatalog",
                }, profile, gearEval)
                items[#items + 1] = eval
                seenItemIDs[catItem.id] = true
            end
        end
    end

    local rep
    if db and db.Quest and db.Quest.Exists(questID) and type(db.Quest.reputationReward) == "function" then
        local rawRep = SafeCall(db.Quest.reputationReward, questID)
        if type(rawRep) == "table" and #rawRep > 0 then rep = rawRep end
    end

    local bestGear
    for _, item in ipairs(items) do
        if item.tierRank > 0 then bestGear = BetterGear(bestGear, item) end
    end

    local xpFraction = (xp and profile.maxXP and profile.maxXP > 0) and (xp / profile.maxXP) or nil
    local hasNotableGear = bestGear ~= nil and bestGear.tierRank >= GEAR_TIER_RANK.uncommon_current
    local hasStrongGear = bestGear ~= nil and bestGear.tierRank >= GEAR_TIER_RANK.rare_usable
    local hasSpells = #spells > 0
    local notableMoney = math.max(10000, (profile.level or 40) * 1000)
    local isPureXP = ready and not hasNotableGear and not hasSpells and (not money or money < notableMoney)

    return {
        ready = ready,
        xp = xp,
        xpFraction = xpFraction,
        money = money,
        moneyText = FormatMoney(money),
        spells = spells,
        hasSpells = hasSpells,
        items = items,
        bestGear = bestGear,
        hasNotableGear = hasNotableGear,
        hasStrongGear = hasStrongGear,
        hasReputation = rep ~= nil,
        reputation = rep,
        isPureXP = isPureXP,
    }
end

local function TraceChain(questID, db, reverseNext, profile, gearEval, preloadState, activeByID)
    if not db or type(db.Quest) ~= "table" or not SafeCall(db.Quest.Exists, questID) then
        return {
            status = "unknown",
            kind = "unknown",
            hasPrevious = false,
            remainingSteps = 0,
            maxDepth = 0,
            futureQuests = {},
            terminalQuests = {},
            totalFutureXP = 0,
            totalFutureMoney = 0,
            pendingRewardCount = 0,
            pendingQuestIDs = {},
            hasFutureSpell = false,
            hasFutureRichReward = false,
        }
    end

    local preSingle = SafeCall(db.Quest.preQuestSingle, questID)
    local preGroup = SafeCall(db.Quest.preQuestGroup, questID)
    local hasPrevious = (type(preSingle) == "table" and #preSingle > 0)
        or (type(preGroup) == "table" and #preGroup > 0)

    local function NextCandidates(id)
        local list, seen = {}, {}
        local function Push(nxt)
            if not IsID(nxt) or nxt == id or seen[nxt] then return end
            seen[nxt] = true
            list[#list + 1] = nxt
        end
        Push(SafeCall(db.Quest.nextQuestInChain, id))
        local children = SafeCall(db.Quest.childQuests, id)
        if type(children) == "table" then
            for _, c in ipairs(children) do Push(c) end
        end
        if reverseNext and reverseNext[id] then
            for _, nxt in ipairs(reverseNext[id]) do Push(nxt) end
        end
        table.sort(list)
        return list
    end

    local visited = { [questID] = true }
    local queue = { { id = questID, depth = 0 } }
    local head = 1
    local futureQuests, terminalQuests = {}, {}
    local edges, nodeByID = {}, {}
    local pendingQuestIDs, pendingSeen = {}, {}
    local totalFutureMoney, maxDepth, highestLevel = 0, 0, nil
    local bestFutureGear, bestFutureGearStep
    local hasFutureSpell = false

    while head <= #queue and #futureQuests < MAX_CHAIN_NODES do
        local current = queue[head]
        head = head + 1
        local validChildren = 0
        if current.depth < MAX_CHAIN_DEPTH then
            for _, nxt in ipairs(NextCandidates(current.id)) do
                if #futureQuests >= MAX_CHAIN_NODES then break end
                if not visited[nxt] and not (activeByID and activeByID[nxt]) and SafeCall(db.Quest.Exists, nxt) then
                    local reqClasses = SafeCall(db.Quest.requiredClasses, nxt)
                    local reqRaces = SafeCall(db.Quest.requiredRaces, nxt)
                    local completed = C_QuestLog and SafeCall(C_QuestLog.IsQuestFlaggedCompleted, nxt) == true
                    if not completed and MaskAllowsClass(reqClasses, profile.classFile)
                        and MaskAllowsFaction(reqRaces, profile.faction) then
                        visited[nxt] = true
                        validChildren = validChildren + 1
                        local depth = current.depth + 1
                        if depth > maxDepth then maxDepth = depth end
                        local qLevel = SafeCall(db.Quest.questLevel, nxt)
                        if IsID(qLevel) and (not highestLevel or qLevel > highestLevel) then highestLevel = qLevel end
                        local reward = ReadQuestReward(nxt, db, profile, gearEval, preloadState)
                        local node = {
                            questID = nxt,
                            title = SafeCall(db.Quest.name, nxt) or ("任务" .. nxt),
                            level = IsID(qLevel) and qLevel or nil,
                            depth = depth,
                            rewardReady = reward.ready,
                            xp = reward.xp,
                            money = reward.money,
                            bestGear = reward.bestGear,
                            hasSpells = reward.hasSpells,
                            itemCount = #reward.items,
                        }
                        futureQuests[#futureQuests + 1] = node
                        nodeByID[nxt] = node
                        edges[current.id] = edges[current.id] or {}
                        edges[current.id][#edges[current.id] + 1] = nxt
                        if reward.ready then
                            if reward.money then totalFutureMoney = totalFutureMoney + reward.money end
                        elseif not pendingSeen[nxt] then
                            pendingSeen[nxt] = true
                            pendingQuestIDs[#pendingQuestIDs + 1] = nxt
                        end
                        if reward.hasSpells then hasFutureSpell = true end
                        if reward.bestGear then
                            local better = BetterGear(bestFutureGear, reward.bestGear)
                            if better == reward.bestGear and better ~= bestFutureGear then
                                bestFutureGear = reward.bestGear
                                bestFutureGearStep = {
                                    questID = nxt,
                                    title = node.title,
                                    depth = depth,
                                    level = node.level,
                                    item = reward.bestGear,
                                }
                            end
                        end
                        queue[#queue + 1] = { id = nxt, depth = depth, node = node }
                    end
                end
            end
        end
        if current.node and validChildren == 0 then
            terminalQuests[#terminalQuests + 1] = current.node
        end
    end

    local terminalByID = {}
    local bestTerminalGear, bestTerminalGearStep
    for _, node in ipairs(terminalQuests) do
        terminalByID[node.questID] = true
        if node.bestGear then
            local better = BetterGear(bestTerminalGear, node.bestGear)
            if better == node.bestGear and better ~= bestTerminalGear then
                bestTerminalGear = node.bestGear
                bestTerminalGearStep = {
                    questID = node.questID,
                    title = node.title,
                    depth = node.depth,
                    level = node.level,
                    item = node.bestGear,
                    isTerminal = true,
                }
            end
        end
    end
    if bestFutureGearStep then
        bestFutureGearStep.isTerminal = terminalByID[bestFutureGearStep.questID] == true
        -- 若终点装备与中间步同档且不弱于中间步，优先展示终点奖励
        if not bestFutureGearStep.isTerminal and bestTerminalGearStep
            and bestTerminalGearStep.item.tierRank >= bestFutureGearStep.item.tierRank
            and BetterGear(bestTerminalGearStep.item, bestFutureGearStep.item) == bestTerminalGearStep.item then
            bestFutureGear = bestTerminalGearStep.item
            bestFutureGearStep = bestTerminalGearStep
        end
    end

    -- 对分叉任务链按最长单路径汇总后续经验，避免互斥分支被重复叠加虚高。
    local xpMemo, inStack = {}, {}
    local function MaxPathXP(id)
        if xpMemo[id] ~= nil then return xpMemo[id] end
        if inStack[id] then return 0 end
        inStack[id] = true
        local bestChild = 0
        for _, childID in ipairs(edges[id] or {}) do
            local childNode = nodeByID[childID]
            local childOwn = (childNode and childNode.rewardReady and childNode.xp) or 0
            local sub = childOwn + MaxPathXP(childID)
            if sub > bestChild then bestChild = sub end
        end
        inStack[id] = nil
        xpMemo[id] = bestChild
        return bestChild
    end
    local totalFutureXP = MaxPathXP(questID)

    local totalFutureXPFraction = (profile.maxXP and profile.maxXP > 0) and (totalFutureXP / profile.maxXP) or nil
    local futureGearRank = bestFutureGear and bestFutureGear.tierRank or 0
    local richReason
    if futureGearRank >= GEAR_TIER_RANK.proven_upgrade then
        richReason = "future_gear_upgrade"
    elseif futureGearRank >= GEAR_TIER_RANK.rare_usable then
        richReason = "future_rare_gear"
    elseif hasFutureSpell then
        richReason = "future_spell_reward"
    elseif totalFutureXPFraction and totalFutureXPFraction >= 0.12 then
        richReason = "future_high_xp"
    elseif totalFutureXPFraction and totalFutureXPFraction >= 0.08 and #futureQuests >= 2
        and highestLevel and profile.level and highestLevel >= profile.level - 3 then
        richReason = "future_multi_step_xp"
    end

    local kind = (#futureQuests > 0 or hasPrevious) and "chain" or "standalone"
    return {
        status = "known",
        kind = kind,
        hasPrevious = hasPrevious,
        hasFuture = #futureQuests > 0,
        remainingSteps = #futureQuests,
        maxDepth = maxDepth,
        highestFutureLevel = highestLevel,
        futureQuests = futureQuests,
        terminalQuests = terminalQuests,
        totalFutureXP = totalFutureXP,
        totalFutureXPFraction = totalFutureXPFraction,
        totalFutureMoney = totalFutureMoney,
        totalFutureMoneyText = FormatMoney(totalFutureMoney),
        bestFutureGear = bestFutureGearStep,
        bestTerminalGear = bestTerminalGearStep,
        hasFutureSpell = hasFutureSpell,
        hasFutureRichReward = richReason ~= nil,
        richRewardReason = richReason,
        pendingRewardCount = #pendingQuestIDs,
        pendingQuestIDs = pendingQuestIDs,
    }
end

local function CachedReadLocations(db, dbInfo, entity, kind, id, localCache)
    if ns.Objectives and type(ns.Objectives.SharedLocationCache) == "function" then
        local cache = ns.Objectives.SharedLocationCache(db, dbInfo)
        local key = kind .. ":" .. id
        local cached = cache.entries[key]
        if not cached then
            cached = ReadLocations(db, entity, id)
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
        local usable = 0
        for _, loc in ipairs(cached or {}) do
            if loc.available then usable = usable + 1 end
        end
        return cached, usable
    end
    local key = kind .. ":" .. id
    local entry = localCache and localCache[key]
    if entry then return entry.locs, entry.usable end
    local locs, usable = ReadLocations(db, entity, id)
    if localCache and type(locs) == "table" then
        localCache[key] = { locs = locs, usable = usable }
    end
    return locs, usable
end

local function ReadReacceptInfo(questID, db, hasPrevious, dbInfo, locCache)
    if not db or type(db.Quest) ~= "table" or not SafeCall(db.Quest.Exists, questID) then
        return { cost = "unknown", label = "重接方式未知" }
    end
    local startedBy = SafeCall(db.Quest.startedBy, questID)
    if type(startedBy) ~= "table" then return { cost = "unknown", label = "重接方式未知" } end
    local npcs = type(startedBy[1]) == "table" and startedBy[1] or {}
    local objects = type(startedBy[2]) == "table" and startedBy[2] or {}
    local items = type(startedBy[3]) == "table" and startedBy[3] or {}

    if #npcs == 0 and #objects == 0 and #items > 0 then
        return { cost = "hard", kind = "item_drop", label = "物品触发，重接麻烦" }
    end
    local instanceOnly = true
    local hasUsableNpc = false
    for _, npcID in ipairs(npcs) do
        if IsID(npcID) and db.Npc and SafeCall(db.Npc.Exists, npcID) then
            local locs, usable = CachedReadLocations(db, dbInfo, db.Npc, "npc", npcID, locCache)
            if usable > 0 then
                hasUsableNpc = true
                instanceOnly = false
                break
            elseif #locs == 0 then
                instanceOnly = false
            end
        end
    end
    if #npcs > 0 and instanceOnly then
        return { cost = "hard", kind = "instance_npc", label = "副本内接取，重接麻烦" }
    end
    if hasUsableNpc then
        if hasPrevious then
            return { cost = "medium", kind = "chain_npc", label = "任务链中段，可回NPC重接" }
        end
        return { cost = "easy", kind = "npc", label = "营地NPC易重接" }
    end
    if #objects > 0 then
        return { cost = "medium", kind = "object", label = "物件触发，可再接" }
    end
    return { cost = "unknown", label = "重接方式未知" }
end

local function ComputeProgress(quest, db)
    local objs = quest.objectives or {}
    if quest.readyForTurnIn or quest.isComplete then
        return {
            fraction = 1,
            completedObjectives = #objs,
            totalObjectives = #objs,
            summary = "已完成",
            hasProgress = true,
            highSunkCost = true,
            hasCraftOrBuyItem = false,
            craftOrBuyItems = {},
        }
    end
    if #objs == 0 then
        return {
            fraction = 0,
            completedObjectives = 0,
            totalObjectives = 0,
            summary = "0%",
            hasProgress = false,
            highSunkCost = false,
            hasCraftOrBuyItem = false,
            craftOrBuyItems = {},
        }
    end

    local sumFraction, doneCount = 0, 0
    local singleText
    for _, obj in ipairs(objs) do
        local f = 0
        if obj.finished == true then
            f = 1
            doneCount = doneCount + 1
        elseif IsFinite(obj.numRequired) and obj.numRequired > 0 and IsFinite(obj.numFulfilled) then
            f = math.max(0, math.min(1, obj.numFulfilled / obj.numRequired))
        end
        sumFraction = sumFraction + f
        if #objs == 1 and IsFinite(obj.numRequired) and obj.numRequired > 0 and IsFinite(obj.numFulfilled) then
            singleText = obj.numFulfilled .. "/" .. obj.numRequired
        end
    end
    local fraction = sumFraction / #objs

    -- 检测是否有“既无怪掉也无物件拾取”的购买/专业物品卡点（例如药剂、假人）
    local craftItems = {}
    if db and db.Quest and db.Item and SafeCall(db.Quest.Exists, quest.questID) then
        local dbObjs = SafeCall(db.Quest.objectives, quest.questID)
        local itemRows = type(dbObjs) == "table" and dbObjs[3] or nil
        if type(itemRows) == "table" then
            for _, row in ipairs(itemRows) do
                local itemID = type(row) == "table" and row[1] or nil
                if IsID(itemID) and SafeCall(db.Item.Exists, itemID) then
                    local npcDrops = SafeCall(db.Item.npcDrops, itemID)
                    local objDrops = SafeCall(db.Item.objectDrops, itemID)
                    local noWorldDrop = (type(npcDrops) ~= "table" or #npcDrops == 0)
                        and (type(objDrops) ~= "table" or #objDrops == 0)
                    if noWorldDrop then
                        local itemName = SafeCall(db.Item.name, itemID) or ("物品" .. itemID)
                        -- 若该物品目标仍未完成，才视为当前卡点
                        local unfinished = true
                        for _, obj in ipairs(objs) do
                            if obj.finished == true and type(obj.text) == "string" and obj.text:find(itemName, 1, true) then
                                unfinished = false
                                break
                            end
                        end
                        if unfinished then craftItems[#craftItems + 1] = itemName end
                    end
                end
            end
        end
    end

    local summary = singleText or string.format("%d%%（%d/%d项）", math.floor(fraction * 100 + 0.5), doneCount, #objs)
    return {
        fraction = fraction,
        completedObjectives = doneCount,
        totalObjectives = #objs,
        summary = summary,
        hasProgress = fraction > 0,
        highSunkCost = fraction >= 0.6,
        hasCraftOrBuyItem = #craftItems > 0,
        craftOrBuyItems = craftItems,
    }
end

local function QuestGeography(quest, poisByQuest, db, playerLoc, dbInfo, locCache)
    local playerMapID = playerLoc and playerLoc.coordinateMapID or nil
    local playerWorld = playerLoc and playerLoc.world or nil
    local best = nil

    local function ConsiderPoint(mapID, world, source)
        if not IsID(mapID) then return end
        local mapInfo = C_Map and SafeCall(C_Map.GetMapInfo, mapID)
        local mapName = mapInfo and Accessible(mapInfo.name) or nil
        local sameMap = playerMapID ~= nil and mapID == playerMapID
        local sameContinent = playerWorld and world and playerWorld.continentID == world.continentID
        local distSq = sameContinent and DistanceSquared(playerWorld, world) or nil
        local dist = distSq and math.sqrt(distSq) or nil
        local scope
        if sameMap then
            scope = "current_map"
        elseif sameContinent and dist then
            scope = dist <= FAR_DISTANCE_YARDS and "same_continent_near" or "same_continent_far"
        elseif playerWorld and world and playerWorld.continentID ~= world.continentID then
            scope = "other_continent"
        else
            scope = "other_map"
        end
        local rank = scope == "current_map" and 1
            or scope == "same_continent_near" and 2
            or scope == "same_continent_far" and 3
            or scope == "other_map" and 4 or 5
        if not best or rank < best.rank or (rank == best.rank and dist and (not best.distance or dist < best.distance)) then
            best = {
                scope = scope,
                rank = rank,
                mapID = mapID,
                mapName = mapName or quest.category,
                distance = dist,
                source = source,
            }
        end
    end

    for _, poi in ipairs(poisByQuest[quest.questID] or {}) do
        ConsiderPoint(poi.reportedMapID or poi.coordinateMapID, poi.world, "client_poi")
    end

    -- 无原生 POI 时，用 QuestieDB 交付/目标 NPC 位置作参考（不用于精确导航，仅作远近判断）
    if not best and db and db.Quest and SafeCall(db.Quest.Exists, quest.questID) then
        local function ScanEntities(ids, entity, kind)
            if type(ids) ~= "table" or not entity then return end
            for _, id in ipairs(ids) do
                if IsID(id) and SafeCall(entity.Exists, id) then
                    local locs = CachedReadLocations(db, dbInfo, entity, kind, id, locCache)
                    for _, loc in ipairs(locs or {}) do
                        if loc.available then
                            ConsiderPoint(loc.coordinateMapID, loc.world, "QuestieDB")
                            if best and best.rank == 1 then return end
                        end
                    end
                end
            end
        end
        local finishedBy = SafeCall(db.Quest.finishedBy, quest.questID)
        if type(finishedBy) == "table" then
            ScanEntities(finishedBy[1], db.Npc, "npc")
            if not best then ScanEntities(finishedBy[2], db.Object, "object") end
        end
        if not best then
            local dbObjs = SafeCall(db.Quest.objectives, quest.questID)
            if type(dbObjs) == "table" then
                local npcIds = {}
                for _, row in ipairs(dbObjs[1] or {}) do if type(row) == "table" then npcIds[#npcIds + 1] = row[1] end end
                ScanEntities(npcIds, db.Npc, "npc")
            end
        end
    end

    if not best then
        return {
            scope = "unknown",
            mapID = nil,
            mapName = quest.category,
            distance = nil,
            isFar = false,
            label = quest.category or "位置未知",
        }
    end

    local isFar = best.scope == "other_continent" or best.scope == "same_continent_far"
    local label
    if best.scope == "current_map" then
        label = "当前地图" .. (best.distance and (" " .. FormatDistance(best.distance) .. "码") or "")
    elseif best.scope == "same_continent_near" then
        label = (best.mapName or "邻图") .. (best.distance and (" " .. FormatDistance(best.distance) .. "码") or "")
    elseif best.scope == "same_continent_far" then
        label = (best.mapName or "远图") .. (best.distance and (" " .. FormatDistance(best.distance) .. "码") or " · 较远")
    elseif best.scope == "other_continent" then
        label = "跨大陆 · " .. (best.mapName or "外图")
    else
        label = best.mapName or "外图"
    end
    best.isFar = isFar
    best.label = label
    return best
end

local function CheckTargetAboveLevel(quest, db, playerLevel, maxOffset, npcLevelCache)
    if not db or not db.Quest or not IsID(playerLevel) or not SafeCall(db.Quest.Exists, quest.questID) then
        return false, nil
    end
    local dbObjs = SafeCall(db.Quest.objectives, quest.questID)
    if type(dbObjs) ~= "table" then return false, nil end
    local highestOver
    for _, row in ipairs(dbObjs[1] or {}) do
        local npcID = type(row) == "table" and row[1] or nil
        if IsID(npcID) then
            local over, lvl = TargetAboveLevel(db, { entityKind = "npc", entityID = npcID }, playerLevel, npcLevelCache, maxOffset)
            if over and (not highestOver or (lvl and lvl > highestOver)) then highestOver = lvl end
        end
    end
    return highestOver ~= nil, highestOver
end

local function BuildQuestFlags(quest, db, profile, settings, npcLevelCache)
    local tag = quest.tag
    local questType = C_QuestLog and SafeCall(C_QuestLog.GetQuestType, quest.questID)
    local isInstance = INSTANCE_TAGS[questType] == true or (tag and INSTANCE_TAGS[tag.id] == true)
    local isElite = (C_QuestLog and SafeCall(C_QuestLog.IsEliteQuest, quest.questID) == true)
        or (tag and tag.isElite == true) or false
    local isProfession = (tag and IsID(tag.tradeskillLineID)) or PROFESSION_CATEGORIES[quest.category] == true
    if not isProfession and db and db.Quest and SafeCall(db.Quest.Exists, quest.questID) then
        local skill = SafeCall(db.Quest.requiredSkill, quest.questID)
        if type(skill) == "table" and IsID(skill[1]) then isProfession = true end
    end

    local isClassQuest = profile.className ~= nil and quest.category == profile.className
    if not isClassQuest and db and db.Quest and SafeCall(db.Quest.Exists, quest.questID) then
        local reqClasses = SafeCall(db.Quest.requiredClasses, quest.questID)
        if MaskIsSingleClass(reqClasses, profile.classFile) then isClassQuest = true end
    end

    local canAbandon = true
    if C_QuestLog and type(C_QuestLog.CanAbandonQuest) == "function" then
        local ca = SafeCall(C_QuestLog.CanAbandonQuest, quest.questID)
        if type(ca) == "boolean" then canAbandon = ca end
    end

    local aboveLevel, overLevel = CheckTargetAboveLevel(quest, db, profile.level, settings.maxMonsterLevelOffset, npcLevelCache)
    return {
        isInstance = isInstance,
        isElite = isElite,
        isProfession = isProfession,
        isClassQuest = isClassQuest,
        canAbandon = canAbandon,
        targetAboveLevel = aboveLevel,
        targetOverLevel = overLevel,
    }
end

local function DescribeGear(gear)
    if not gear then return nil end
    if gear.provenUpgrade then
        local delta = IsFinite(gear.scoreDelta) and string.format("(+%.1f分)", gear.scoreDelta) or "(提升)"
        return (gear.slotLabel or "装备") .. "提升：" .. gear.name .. delta
    end
    return (gear.qualityLabel or "装备") .. "「" .. gear.name .. "」"
end

local function IsExcellentGear(gear)
    return gear ~= nil and (gear.tierRank or 0) >= GEAR_TIER_RANK.rare_usable
end

local function GearItemWeight(gear, isChain, stepDepth, isTerminal)
    if not gear or (gear.tierRank or 0) <= GEAR_TIER_RANK.gear_low then
        return 0
    end
    local rank = gear.tierRank
    local base = 0
    if rank >= GEAR_TIER_RANK.proven_upgrade then
        -- 实测确认提升装：最高权重（直接 136..160，任务链 127..156）
        base = isChain and 130 or 136
        local deltaBonus = IsFinite(gear.scoreDelta) and math.min(18, math.max(0, gear.scoreDelta * 0.4)) or 0
        local qualityBonus = (gear.quality or 0) >= 4 and 6 or ((gear.quality or 0) >= 3 and 3 or 0)
        base = base + deltaBonus + qualityBonus
    elseif rank >= GEAR_TIER_RANK.epic_usable then
        -- 可穿戴紫装（直接 122，任务链 115..120）
        base = isChain and 118 or 122
    elseif rank >= GEAR_TIER_RANK.rare_usable then
        -- 可穿戴蓝装（直接 108..112，任务链 101..110）
        base = isChain and 104 or 108
        if IsFinite(gear.ilvlDelta) and gear.ilvlDelta > 0 then
            base = base + math.min(4, gear.ilvlDelta * 0.4)
        end
    elseif rank >= GEAR_TIER_RANK.uncommon_current then
        -- 适级可穿戴绿装（常规保留档内高于纯经验）
        base = isChain and 40 or 44
        if IsFinite(gear.ilvlDelta) and gear.ilvlDelta > 0 then
            base = base + math.min(6, gear.ilvlDelta * 0.6)
        end
    end
    if isChain and base > 0 then
        if isTerminal then base = base + 2 end
        local depthPenalty = math.min(3, math.max(0, ((stepDepth or 1) - 1) * 0.5))
        base = base - depthPenalty
    end
    return base
end

local function ResolveBestGearHighlight(reward, chain)
    local direct = reward and reward.bestGear or nil
    local futureStep = chain and chain.bestFutureGear or nil
    local future = futureStep and futureStep.item or nil
    local directW = GearItemWeight(direct, false, 0, false)
    local futureW = futureStep and GearItemWeight(future, true, futureStep.depth, futureStep.isTerminal) or 0
    if directW <= 0 and futureW <= 0 then
        return nil, nil, 0, nil
    end
    if directW >= futureW then
        return direct, "direct", directW, nil
    end
    local scope = futureStep.isTerminal and "chain_terminal" or "chain_step"
    return future, scope, futureW, futureStep
end

local function GearTagLabel(gear, sourceScope)
    if not IsExcellentGear(gear) then return nil end
    local isChain = sourceScope == "chain_terminal" or sourceScope == "chain_step"
    if gear.provenUpgrade then
        return isChain and "链提升" or "装提升"
    elseif (gear.tierRank or 0) >= GEAR_TIER_RANK.epic_usable then
        return isChain and "链紫装" or "紫装"
    else
        return isChain and "链蓝装" or "蓝装"
    end
end

local function ComputeValueWeight(q, reward, chain, progress, geo, flags, verdict, dropPriority, ctx, bestGear, gearSource, gearWeight)
    local hasExcellent = IsExcellentGear(bestGear)
    local weight
    if hasExcellent then
        -- 优秀装备（本步或任务链终点/后续）权重最高，严格高于一切非装备保护项（>= 101）
        weight = gearWeight
        local extra = 0
        if q.readyForTurnIn or q.isComplete then extra = extra + 1 end
        if flags.isClassQuest then extra = extra + 0.5 end
        if reward.hasSpells or chain.hasFutureSpell then extra = extra + 0.5 end
        weight = weight + math.min(2, extra)
    elseif verdict == "keep_priority" then
        -- 非装备类保护项严格低于优秀装备（上限 88）
        local candidates = {}
        if reward.hasSpells then candidates[#candidates + 1] = 76 end
        if chain.hasFutureSpell then candidates[#candidates + 1] = 72 end
        if flags.isClassQuest then candidates[#candidates + 1] = 68 end
        if q.readyForTurnIn or q.isComplete then candidates[#candidates + 1] = 64 end
        if chain.hasFutureRichReward then candidates[#candidates + 1] = 60 end
        if not flags.canAbandon then candidates[#candidates + 1] = 55 end
        table.sort(candidates, function(a, b) return a > b end)
        weight = candidates[1] or 55
        if #candidates > 1 then
            weight = math.min(88, weight + (#candidates - 1) * 2)
        end
    elseif verdict == "keep" then
        if gearWeight > 0 then
            weight = math.min(52, gearWeight)
        else
            weight = 26
            if ctx.highXP then weight = weight + 5 end
            if chain.hasFuture then weight = weight + 3 end
            if geo.scope == "current_map" then weight = weight + 2 end
            if progress.highSunkCost then weight = weight + 2 end
            weight = math.min(37, weight)
        end
    elseif verdict == "uncertain" then
        weight = gearWeight > 0 and math.min(24, 20 + math.floor(gearWeight * 0.08)) or 20
    elseif verdict == "hold_or_drop" then
        weight = math.max(8, math.min(19, 18 - (dropPriority or 0) * 0.1))
        if gearWeight > 0 then weight = math.min(22, weight + 3) end
    else
        weight = q.isFailed and 0 or math.max(1, math.min(7, 8 - (dropPriority or 0) * 0.08))
    end
    return math.floor(weight * 10 + 0.5) / 10
end

local function BuildQuestTags(q, flags, chain, bestGear, gearSource)
    local tags = {}
    -- 中性标签（副本/精英只作标签提示，绝不因此压低价值）
    if q.readyForTurnIn then tags[#tags + 1] = "可交"
    elseif q.isComplete then tags[#tags + 1] = "已完成"
    elseif q.isFailed then tags[#tags + 1] = "已失败" end
    local gearTag = GearTagLabel(bestGear, gearSource)
    if gearTag then tags[#tags + 1] = gearTag end
    if flags.isClassQuest then tags[#tags + 1] = "职业" end
    if flags.isInstance then tags[#tags + 1] = "副本" end
    if flags.isElite then tags[#tags + 1] = "精英" end
    if flags.isProfession then tags[#tags + 1] = "专业" end
    if chain.status == "known" then
        if chain.hasFuture then
            tags[#tags + 1] = "链+" .. chain.remainingSteps .. "步"
        elseif chain.kind == "standalone" then
            tags[#tags + 1] = "独立"
        else
            tags[#tags + 1] = "链尾"
        end
    end
    return tags
end

local function CollectProtections(q, reward, chain, flags, reasons)
    local protections = {}
    -- 一票保护红线检查：本步或任务链终点/后续奖励优秀装备排在最前（最高权重）
    if reward.bestGear and reward.bestGear.provenUpgrade then
        protections[#protections + 1] = "gear_upgrade"
        reasons[#reasons + 1] = "本步" .. DescribeGear(reward.bestGear)
    elseif reward.hasStrongGear then
        protections[#protections + 1] = "strong_gear"
        reasons[#reasons + 1] = "本步奖励" .. DescribeGear(reward.bestGear)
    end
    local futureExcellentGear = chain.hasFutureRichReward and chain.bestFutureGear and IsExcellentGear(chain.bestFutureGear.item)
    if futureExcellentGear then
        protections[#protections + 1] = "rich_chain_reward"
        local step = chain.bestFutureGear
        local prefix = step.isTerminal and "任务链终点" or ("后续第" .. step.depth .. "步")
        reasons[#reasons + 1] = string.format("%s「%s」出%s", prefix, step.title, DescribeGear(step.item))
    end
    if reward.hasSpells then
        protections[#protections + 1] = "spell_reward"
        reasons[#reasons + 1] = "奖励法术/技能"
    end
    if flags.isClassQuest then
        protections[#protections + 1] = "class_quest"
        reasons[#reasons + 1] = "职业专属任务"
    end
    if q.readyForTurnIn or q.isComplete then
        protections[#protections + 1] = "completed"
        reasons[#reasons + 1] = q.readyForTurnIn and "已完成可交，顺路交掉即可腾格子" or "已完成，等待确认交付"
    end
    if chain.hasFutureRichReward and not futureExcellentGear then
        protections[#protections + 1] = "rich_chain_reward"
        if chain.hasFutureSpell then
            reasons[#reasons + 1] = string.format("任务链后续(%d步)含法术奖励", chain.remainingSteps)
        elseif chain.totalFutureXP > 0 then
            local pct = chain.totalFutureXPFraction and string.format("（约%.0f%%本级）", chain.totalFutureXPFraction * 100) or ""
            reasons[#reasons + 1] = string.format("任务链后续%d步总经验%d%s", chain.remainingSteps, chain.totalFutureXP, pct)
        end
    end
    if not flags.canAbandon then
        protections[#protections + 1] = "cannot_abandon"
        reasons[#reasons + 1] = "系统限制不可放弃"
    end
    return protections
end

local function ClassifyVerdict(q, reward, chain, progress, geo, flags, reaccept, protections, reasons, ctx)
    -- 结论判定（遵守：副本/精英中性处理，不因副本/精英身份自动判放弃）
    if #protections > 0 then
        return "keep_priority", 5
    end
    if q.isFailed then
        reasons[#reasons + 1] = "任务已失败，需放弃重接"
        return "recommend_drop", 98
    end
    if (not reward.ready) or (chain.pendingRewardCount > 0) then
        -- 未知不当低价值：只要本任务或后续链奖励尚未加载完，且没确定是无后续灰任务，就保留待确认
        if ctx.isTrivial and chain.status == "known" and not chain.hasFuture and not progress.hasProgress and reward.ready then
            return "recommend_drop", 85
        end
        if chain.pendingRewardCount > 0 then
            reasons[#reasons + 1] = "后续" .. chain.pendingRewardCount .. "步奖励加载中，暂不判放弃"
        end
        return "uncertain", 45
    end

    local isNoFuture = chain.status == "known" and not chain.hasFuture
    local isStandalone = chain.status == "known" and chain.kind == "standalone"
    local isIsolated = ctx.clusterCount <= 2
    local lowProgress = progress.fraction < 0.3
    local zeroProgress = not progress.hasProgress
    local hasFutureNotableGear = chain.bestFutureGear ~= nil and (chain.bestFutureGear.item.tierRank or 0) >= GEAR_TIER_RANK.uncommon_current
    local dropPriority = 0

    -- 计算“清理优先度”（仅用于同类排序，不覆盖红线）
    if isStandalone then dropPriority = dropPriority + 22
    elseif isNoFuture then dropPriority = dropPriority + 12
    elseif chain.hasFuture then dropPriority = dropPriority - 12 end
    if reward.hasNotableGear then dropPriority = dropPriority - 16
    elseif hasFutureNotableGear then dropPriority = dropPriority - 12
    elseif reward.isPureXP then dropPriority = dropPriority + 18 end
    if ctx.isTrivial then dropPriority = dropPriority + 24 end
    if ctx.lowXP then dropPriority = dropPriority + 14 elseif ctx.modestXP then dropPriority = dropPriority + 6 end
    if geo.scope == "other_continent" then dropPriority = dropPriority + 20
    elseif geo.scope == "same_continent_far" then dropPriority = dropPriority + 14
    elseif geo.scope == "current_map" then dropPriority = dropPriority - 10 end
    if isIsolated then dropPriority = dropPriority + 10 end
    if zeroProgress then dropPriority = dropPriority + 8
    elseif progress.highSunkCost then dropPriority = dropPriority - 22
    else dropPriority = dropPriority - 8 end
    if reaccept.cost == "easy" then dropPriority = dropPriority + 6
    elseif reaccept.cost == "hard" then dropPriority = dropPriority - 12 end
    if ctx.isImpossible or flags.targetAboveLevel then dropPriority = dropPriority + 8 end
    if ctx.logRatio and ctx.logRatio >= 0.85 then dropPriority = dropPriority + 4 end

    -- 核心分档：突出“无后续/独立 + 远距离 + 纯经验”与“已灰无后续”，高额单次经验或适级可用装备降档保护
    local verdict
    if ctx.isTrivial and isNoFuture and not reward.hasNotableGear and not progress.highSunkCost and (zeroProgress or isStandalone or geo.isFar) then
        verdict = "recommend_drop"
    elseif isStandalone and reward.isPureXP and geo.isFar and lowProgress and not ctx.highXP and (isIsolated or ctx.modestXP or ctx.isImpossible) then
        verdict = "recommend_drop"
    elseif isNoFuture and reward.isPureXP and geo.isFar and lowProgress and not ctx.highXP and (isIsolated or ctx.lowXP) then
        verdict = "recommend_drop"
    elseif isNoFuture and reward.isPureXP and zeroProgress and ctx.lowXP and (geo.isFar or isIsolated) then
        verdict = "recommend_drop"
    elseif (ctx.isTrivial and (progress.highSunkCost or not isNoFuture or reward.hasNotableGear))
        or (isNoFuture and reward.isPureXP and geo.isFar and lowProgress)
        or (isStandalone and reward.isPureXP and (geo.isFar or ctx.lowXP))
        or (isNoFuture and reward.isPureXP and zeroProgress and (isIsolated or ctx.lowXP))
        or ((ctx.isImpossible or flags.targetAboveLevel) and zeroProgress and reaccept.cost == "easy") then
        verdict = "hold_or_drop"
    else
        verdict = "keep"
    end
    return verdict, dropPriority
end

local function BuildSummaryLines(q, reward, chain, progress, geo, reaccept, clusterCount, verdict, bestGear, gearSource, bestStep)
    local rewardLine
    if IsExcellentGear(bestGear) then
        if gearSource == "direct" then
            local chainSuffix = chain.hasFuture and (" · 链+" .. chain.remainingSteps .. "步") or ""
            rewardLine = "本步出" .. DescribeGear(bestGear) .. chainSuffix
        elseif bestStep then
            local where = bestStep.isTerminal and "终点" or ("第" .. bestStep.depth .. "步")
            rewardLine = string.format("链+%d步 · %s「%s」出%s", chain.remainingSteps, where, bestStep.title, DescribeGear(bestStep.item))
        end
    elseif chain.bestFutureGear and (chain.bestFutureGear.item.tierRank or 0) >= GEAR_TIER_RANK.uncommon_current then
        local step = chain.bestFutureGear
        local where = step.isTerminal and "终点" or ("第" .. step.depth .. "步")
        rewardLine = string.format("链+%d步 · %s「%s」出%s", chain.remainingSteps, where, step.title, DescribeGear(step.item))
    elseif chain.hasFuture then
        local xpPart = chain.totalFutureXP > 0 and ("后续总经验" .. chain.totalFutureXP) or "后续待加载"
        local tail = chain.terminalQuests[1] and (" · 终点「" .. chain.terminalQuests[1].title .. "」") or ""
        rewardLine = string.format("链+%d步 · %s%s", chain.remainingSteps, xpPart, tail)
    elseif not reward.ready then
        rewardLine = "奖励加载中…"
    elseif reward.isPureXP then
        local pct = reward.xpFraction and string.format("(%.1f%%)", reward.xpFraction * 100) or ""
        local prefix = chain.kind == "standalone" and "独立纯经验" or "链尾纯经验"
        rewardLine = string.format("%s %s%s · 无后续", prefix, tostring(reward.xp or 0), pct)
    elseif reward.bestGear then
        rewardLine = "无后续 · " .. DescribeGear(reward.bestGear)
    else
        rewardLine = "无后续" .. (reward.xp and (" · 经验" .. reward.xp) or "") .. (reward.moneyText and (" · " .. reward.moneyText) or "")
    end

    local contextParts = {}
    if geo.label then contextParts[#contextParts + 1] = geo.label end
    if clusterCount <= 2 and geo.scope ~= "current_map" and geo.scope ~= "unknown" then
        contextParts[#contextParts + 1] = "孤立"
    end
    if not (q.readyForTurnIn or q.isComplete) then
        contextParts[#contextParts + 1] = "进度" .. progress.summary
    else
        contextParts[#contextParts + 1] = q.readyForTurnIn and "可交付" or "待确认交付"
    end
    if reaccept.cost == "easy" and (verdict == "recommend_drop" or verdict == "hold_or_drop") then
        contextParts[#contextParts + 1] = "易重接"
    elseif reaccept.cost == "hard" then
        contextParts[#contextParts + 1] = "难重接"
    end
    return rewardLine, table.concat(contextParts, " · ")
end

local function EvaluateSingleQuest(entry, medianXP, clusterCount, logRatio)
    local q, reward, chain, progress = entry.quest, entry.reward, entry.chain, entry.progress
    local geo, flags, reaccept, diff = entry.geography, entry.flags, entry.reaccept, entry.difficulty
    local isTrivial = diff.code == 0 or diff.isTrivial == true
    local isImpossible = diff.code == 4
    local reasons = {}
    local bestGear, gearSource, gearWeight, bestStep = ResolveBestGearHighlight(reward, chain)
    local hasExcellentGear = IsExcellentGear(bestGear)
    local tags = BuildQuestTags(q, flags, chain, bestGear, gearSource)
    local protections = CollectProtections(q, reward, chain, flags, reasons)

    -- 补充客观信息理由
    local xpRelMedian = (reward.xp and medianXP and medianXP > 0) and (reward.xp / medianXP) or nil
    local highXP = reward.ready and (
        (reward.xpFraction ~= nil and reward.xpFraction >= 0.06)
        or (xpRelMedian ~= nil and xpRelMedian >= 1.6)
    )
    local lowXP = reward.ready and (
        (reward.xp == 0)
        or (reward.xpFraction ~= nil and reward.xpFraction < 0.025)
        or (xpRelMedian ~= nil and xpRelMedian < 0.45)
    )
    local modestXP = reward.ready and not highXP and (
        lowXP
        or (reward.xpFraction ~= nil and reward.xpFraction < 0.045)
        or (xpRelMedian ~= nil and xpRelMedian < 0.75)
    )

    if chain.status == "known" then
        if chain.kind == "standalone" then
            reasons[#reasons + 1] = "独立任务，无后续任务链"
        elseif not chain.hasFuture then
            reasons[#reasons + 1] = "已是任务链末步，无更多后续"
        elseif not chain.hasFutureRichReward then
            reasons[#reasons + 1] = string.format("任务链还有%d步后续", chain.remainingSteps)
        end
    elseif chain.status == "unknown" then
        reasons[#reasons + 1] = "未查到任务链数据（按未知处理）"
    end

    if reward.ready then
        if reward.isPureXP then
            local pct = reward.xpFraction and string.format("%.1f%%本级", reward.xpFraction * 100) or nil
            reasons[#reasons + 1] = "纯经验奖励" .. (reward.xp and (" " .. reward.xp .. (pct and ("（" .. pct .. "）") or "")) or "")
        elseif reward.bestGear and not (reward.bestGear.provenUpgrade or reward.hasStrongGear) then
            reasons[#reasons + 1] = "奖励" .. DescribeGear(reward.bestGear)
        elseif reward.moneyText then
            reasons[#reasons + 1] = "奖励金钱 " .. reward.moneyText
        end
    else
        reasons[#reasons + 1] = "任务奖励缓存加载中"
    end

    if isTrivial and not (q.readyForTurnIn or q.isComplete) then
        reasons[#reasons + 1] = "任务已变灰（经验衰减）"
    elseif isImpossible then
        reasons[#reasons + 1] = "任务难度过高（过早接取）"
    elseif flags.targetAboveLevel then
        reasons[#reasons + 1] = "目标怪超等（" .. tostring(flags.targetOverLevel) .. "级）"
    end

    if geo.scope ~= "unknown" then
        local clusterNote = clusterCount <= 2 and "·孤立" or ("·同区" .. clusterCount .. "个任务")
        reasons[#reasons + 1] = geo.label .. clusterNote
    end

    if progress.hasProgress and not (q.readyForTurnIn or q.isComplete) then
        reasons[#reasons + 1] = "已做 " .. progress.summary
    end
    if progress.hasCraftOrBuyItem then
        reasons[#reasons + 1] = "缺购买/制造物品：" .. table.concat(progress.craftOrBuyItems, "、")
    end
    if reaccept.cost == "hard" then
        reasons[#reasons + 1] = reaccept.label
    end

    local verdictCtx = {
        isTrivial = isTrivial, isImpossible = isImpossible,
        highXP = highXP, lowXP = lowXP, modestXP = modestXP,
        clusterCount = clusterCount, logRatio = logRatio,
    }
    local verdict, dropPriority = ClassifyVerdict(q, reward, chain, progress, geo, flags, reaccept, protections, reasons, verdictCtx)
    local valueWeight = ComputeValueWeight(q, reward, chain, progress, geo, flags, verdict, dropPriority, verdictCtx, bestGear, gearSource, gearWeight)
    if verdict == "keep_priority" then
        -- 优先保留档内按 valueWeight 反向映射清理优先度：优秀装备（直接或任务链终点）数值最小，最不被清理
        dropPriority = math.max(0, math.floor((165 - valueWeight) * 10 + 0.5) / 100)
    end
    local meta = VERDICT_META[verdict] or VERDICT_META.keep
    local rewardLine, contextLine = BuildSummaryLines(q, reward, chain, progress, geo, reaccept, clusterCount, verdict, bestGear, gearSource, bestStep)

    return {
        questID = q.questID,
        title = q.title,
        category = q.category,
        level = q.level,
        status = q.status,
        verdict = verdict,
        verdictLabel = meta.label,
        verdictShort = meta.short,
        verdictRank = meta.rank,
        verdictColor = meta.color,
        dropPriority = dropPriority,
        valueWeight = valueWeight,
        hasExcellentGear = hasExcellentGear,
        bestGearSource = gearSource,
        protections = protections,
        reasons = reasons,
        tags = tags,
        rewardLine = rewardLine,
        contextLine = contextLine,
        difficulty = diff,
        reward = reward,
        chain = chain,
        progress = progress,
        geography = geo,
        clusterCount = clusterCount,
        reaccept = reaccept,
        flags = flags,
    }
end

local function Analyze(args)
    if args == nil then args = {} end
    if type(args) ~= "table" then return InvalidArguments("args must be an object") end
    if args.includeChain ~= nil and type(args.includeChain) ~= "boolean" then
        return InvalidArguments("includeChain must be a boolean")
    end
    if args.includeGear ~= nil and type(args.includeGear) ~= "boolean" then
        return InvalidArguments("includeGear must be a boolean")
    end
    if args.requestLoad ~= nil and type(args.requestLoad) ~= "boolean" then
        return InvalidArguments("requestLoad must be a boolean")
    end
    if args.verdict ~= nil and not VALID_VERDICTS[args.verdict] then
        return InvalidArguments("verdict must be recommend_drop, hold_or_drop, uncertain, keep or keep_priority")
    end
    if args.questID ~= nil and not IsID(args.questID) then
        return InvalidArguments("questID must be a positive integer")
    end
    local pageArgs = { offset = args.offset or 0, limit = args.limit or 100 }
    local page, message = ParsePage(pageArgs)
    if not page then return InvalidArguments(message) end

    local includeChain = args.includeChain ~= false
    local includeGear = args.includeGear ~= false
    local requestLoad = args.requestLoad ~= false

    local questList = ns.GetQuests({ offset = 0, limit = 100, includeObjectives = true })
    if not questList or not questList.ok then
        return { ok = false, error = { code = "quest_log_unavailable", message = "无法读取角色任务日志" } }
    end

    local profile = ReadCharacterProfile(args.gear)
    local settings = RouteSettings()
    local db, dbInfo = GetDatabase()
    local reverseNext = (includeChain and db) and GetReverseNextIndex(db) or nil
    local gearEval = BuildGearEvaluation(profile, includeGear)

    local activeByID, statuses = {}, {}
    for _, q in ipairs(questList.quests or {}) do
        activeByID[q.questID] = true
        statuses[q.questID] = q.status
    end
    local poisByQuest = {}
    if ns.QuestData and type(ns.QuestData.CollectPlanPOIs) == "function" then
        local mapID = profile.location and profile.location.coordinateMapID or nil
        poisByQuest = ns.QuestData.CollectPlanPOIs(activeByID, mapID, activeByID, statuses, false)
    else
        local pois = CollectPOIs({}, activeByID)
        for _, poi in ipairs(pois or {}) do
            local list = poisByQuest[poi.questID]
            if not list then list = {}; poisByQuest[poi.questID] = list end
            list[#list + 1] = poi
        end
    end

    local preloadState = { enabled = requestLoad, requested = {}, count = 0 }
    local noPreload = { enabled = false, requested = {}, count = 0 }
    local npcLevelCache, locCache = {}, {}
    local rawEntries = {}
    local clusterCounts = {}
    local xpSamples = {}

    -- 先对全日志统计经验中位数与区域聚集度，避免单任务查询（args.questID）破坏参照系。
    for _, q in ipairs(questList.quests or {}) do
        local isTarget = (not args.questID) or (q.questID == args.questID)
        local pData = ns.Priority.Read(q)
        local diff = pData and pData.difficulty or { available = false, name = "unknown" }
        local reward = ReadQuestReward(q.questID, db, profile, gearEval, isTarget and preloadState or noPreload)
        if reward.ready and reward.xp and reward.xp > 0 and (diff.code == 1 or diff.code == 2) then
            xpSamples[#xpSamples + 1] = reward.xp
        end
        local geo = QuestGeography(q, poisByQuest, db, profile.location, dbInfo, locCache)
        local clusterKey = geo.mapID and ("map:" .. geo.mapID) or ("cat:" .. tostring(q.category or "?"))
        clusterCounts[clusterKey] = (clusterCounts[clusterKey] or 0) + 1
        if isTarget then
            local chain = includeChain and TraceChain(q.questID, db, reverseNext, profile, gearEval, preloadState, activeByID) or {
                status = "disabled", kind = "unknown", hasPrevious = false, hasFuture = false,
                remainingSteps = 0, maxDepth = 0, futureQuests = {}, terminalQuests = {},
                totalFutureXP = 0, totalFutureMoney = 0, pendingRewardCount = 0, pendingQuestIDs = {},
                hasFutureSpell = false, hasFutureRichReward = false,
            }
            local progress = ComputeProgress(q, db)
            local flags = BuildQuestFlags(q, db, profile, settings, npcLevelCache)
            local reaccept = ReadReacceptInfo(q.questID, db, chain.hasPrevious, dbInfo, locCache)
            rawEntries[#rawEntries + 1] = {
                quest = q, difficulty = diff, reward = reward, chain = chain,
                progress = progress, geography = geo, flags = flags, reaccept = reaccept,
                clusterKey = clusterKey,
            }
        end
    end

    table.sort(xpSamples)
    local medianXP
    if #xpSamples >= 3 then
        local mid = math.floor((#xpSamples + 1) / 2)
        medianXP = #xpSamples % 2 == 1 and xpSamples[mid] or (xpSamples[mid] + xpSamples[mid + 1]) / 2
    end

    local maxCanAccept = C_QuestLog and SafeCall(C_QuestLog.GetMaxNumQuestsCanAccept) or nil
    if not IsID(maxCanAccept) then maxCanAccept = 25 end
    local logCount = questList.total or #rawEntries
    local logRatio = maxCanAccept > 0 and (logCount / maxCanAccept) or nil
    local pressure = logRatio and (logRatio >= 0.9 and "critical" or logRatio >= 0.75 and "high" or "normal") or "unknown"

    local summary = {
        recommendDrop = 0, holdOrDrop = 0, uncertain = 0, keep = 0, keepPriority = 0,
        pendingRewardCount = 0,
    }
    local pendingMap, pendingList = {}, {}
    local evaluated = {}

    for _, entry in ipairs(rawEntries) do
        local item = EvaluateSingleQuest(entry, medianXP, clusterCounts[entry.clusterKey] or 1, logRatio)
        if item.verdict == "recommend_drop" then summary.recommendDrop = summary.recommendDrop + 1
        elseif item.verdict == "hold_or_drop" then summary.holdOrDrop = summary.holdOrDrop + 1
        elseif item.verdict == "uncertain" then summary.uncertain = summary.uncertain + 1
        elseif item.verdict == "keep_priority" then summary.keepPriority = summary.keepPriority + 1
        else summary.keep = summary.keep + 1 end

        if not item.reward.ready and not pendingMap[item.questID] then
            pendingMap[item.questID] = true
            pendingList[#pendingList + 1] = item.questID
        end
        for _, pid in ipairs(item.chain.pendingQuestIDs or {}) do
            if not pendingMap[pid] then
                pendingMap[pid] = true
                pendingList[#pendingList + 1] = pid
            end
        end

        if not args.verdict or item.verdict == args.verdict then
            evaluated[#evaluated + 1] = item
        end
    end
    summary.pendingRewardCount = #pendingList

    -- 仅在全量日志分析时更新待缓存追踪集合，避免单任务查询覆盖全日志状态。
    if not args.questID then
        ns.route.valuePendingQuestIDs = #pendingList > 0 and pendingMap or nil
    end

    table.sort(evaluated, function(a, b)
        if a.verdictRank ~= b.verdictRank then return a.verdictRank < b.verdictRank end
        if a.dropPriority ~= b.dropPriority then return a.dropPriority > b.dropPriority end
        local aw, bw = a.valueWeight or 0, b.valueWeight or 0
        if aw ~= bw then return aw < bw end
        return a.questID < b.questID
    end)

    local result = {
        ok = true,
        schemaVersion = 1,
        apiRevision = ns.apiRevision,
        policy = "advisory_only_never_auto_abandon",
        groupQuestPolicy = "neutral_tag_only",
        database = dbInfo,
        gearEvaluation = { enabled = gearEval.enabled, scored = gearEval.scored },
        character = {
            name = profile.name, realm = profile.realm, level = profile.level,
            className = profile.className, spec = profile.spec, faction = profile.faction,
        },
        log = {
            count = logCount,
            maxCanAccept = maxCanAccept,
            ratio = logRatio,
            pressure = pressure,
        },
        reference = { medianXP = medianXP, sampleCount = #xpSamples, levelXPMaximum = profile.maxXP },
        summary = summary,
        pendingQuestIDs = pendingList,
    }
    return AddPage(result, evaluated, page, "quests")
end

local function FormatQuestDetailLines(item)
    local lines = {}
    local tagStr = #item.tags > 0 and (" [" .. table.concat(item.tags, "/") .. "]") or ""
    lines[#lines + 1] = string.format("|c%s[%s]|r [%d] %s（%s级）%s",
        item.verdictColor, item.verdictLabel, item.questID, item.title or "?",
        tostring(item.level or "?"), tagStr)
    lines[#lines + 1] = "  奖励与链：" .. item.rewardLine
    lines[#lines + 1] = "  地点进度：" .. item.contextLine
    if #item.reasons > 0 then
        lines[#lines + 1] = "  判断依据：" .. table.concat(item.reasons, "；")
    end
    if item.chain and item.chain.hasFuture and #item.chain.futureQuests > 0 then
        local steps = {}
        for i, node in ipairs(item.chain.futureQuests) do
            if i > 6 then steps[#steps + 1] = "…等" .. #item.chain.futureQuests .. "步"; break end
            local extra = node.bestGear and ("[" .. DescribeGear(node.bestGear) .. "]")
                or (node.xp and (node.xp .. "经验") or "奖励待加载")
            steps[#steps + 1] = string.format("第%d步[%d]%s(%s)", node.depth, node.questID, node.title, extra)
        end
        lines[#lines + 1] = "  后续链条：" .. table.concat(steps, " → ")
    end
    lines[#lines + 1] = "  提示：本分析仅供决策参考，如需放弃请在原生任务日志中手动操作。"
    return lines
end

local function FormatAuditLines(result, showAll)
    local lines = {}
    if not result or not result.ok then
        lines[1] = "|cff31cee8QuestRoute|r 无法分析任务：" .. (result and result.error and result.error.message or "未知错误")
        return lines
    end
    local s = result.summary
    lines[#lines + 1] = string.format(
        "|cff31cee8QuestRoute|r 任务价值分析（日志 %d/%d）：建议放弃 %d · 可考虑 %d · 待确认 %d · 保留 %d · 优先留 %d",
        result.log.count, result.log.maxCanAccept,
        s.recommendDrop, s.holdOrDrop, s.uncertain, s.keep, s.keepPriority
    )
    local shown = 0
    for _, item in ipairs(result.quests or {}) do
        if showAll or item.verdict == "recommend_drop" or item.verdict == "hold_or_drop" or item.verdict == "uncertain" then
            shown = shown + 1
            if not showAll and shown > 12 then
                lines[#lines + 1] = "…另有更多条目，输入 /questroute audit all 或打开任务日志侧边栏查看。"
                break
            end
            local tagStr = #item.tags > 0 and (" [" .. table.concat(item.tags, "/") .. "]") or ""
            lines[#lines + 1] = string.format("|c%s[%s]|r [%d] %s%s — %s | %s",
                item.verdictColor, item.verdictShort, item.questID, item.title or "?",
                tagStr, item.rewardLine, item.contextLine)
        end
    end
    if shown == 0 then
        lines[#lines + 1] = "当前没有明显建议放弃的任务。输入 /questroute audit all 查看全部，或 /questroute audit <任务ID> 看详情。"
    end
    if s.pendingRewardCount > 0 then
        lines[#lines + 1] = "注：有 " .. s.pendingRewardCount .. " 个任务（含后续链）奖励刚请求加载，几秒后重查更准确。"
    end
    return lines
end

function ns.AnalyzeQuests(args)
    return Analyze(args)
end

ns.QuestValue = {
    Analyze = Analyze,
    PumpIndex = PumpReverseIndex,
    FormatAuditLines = FormatAuditLines,
    FormatQuestDetailLines = FormatQuestDetailLines,
    ReadWornGear = ReadWornGear,
    verdictMeta = VERDICT_META,
}
