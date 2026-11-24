-- 升级阶段的战斗装备候选。数据来自生成的 GearCatalog，评分只在战士防护上使用。
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

-- 40 级防护的默认倾向：先生存，力量和攻强只表示仇恨。不是模拟最优。
local DEFAULT_WEIGHTS = {
    stamina = 2, armor = 0.02, defense = 1.5, dodge = 1.2, parry = 1.2,
    block = 1, blockValue = 0.05, strength = 0.4, attackPower = 0.15,
    agility = 0.3, crit = 0.2, hit = 0.15, weaponDps = 1.5,
}

local NON_COMBAT = { shirt = true, tabard = true, ["衬衣"] = true, ["战袍"] = true }

local function Invalid(message)
    if ns.Util and ns.Util.InvalidArguments then return ns.Util.InvalidArguments(message) end
    return { ok = false, error = { code = "invalid_arguments", message = message } }
end

local function CopyWeights(override)
    local weights = {}
    for key, value in pairs(DEFAULT_WEIGHTS) do weights[key] = value end
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
    local limit = args.limit
    if limit == nil then limit = 8 end
    if type(limit) ~= "number" or limit ~= math.floor(limit) or limit < 1 or limit > 100 then
        return nil, Invalid("limit 必须是 1 到 100 的整数")
    end
    local mode = "refuse"
    if className == "战士" then
        if spec == "防护" or spec == "防御" or spec == "protection" or spec == "warrior-protection" or spec == "战士·防护" then
            mode = "protection"
        else
            mode = "generic"
        end
    end
    local weights, weightError
    if mode == "protection" then
        weights, weightError = CopyWeights(args.weights)
        if not weights then return nil, Invalid(weightError) end
    elseif args.weights ~= nil then
        return nil, Invalid("只有战士防护接受权重")
    end
    return {
        level = level, className = className, spec = spec, faction = faction,
        window = window, limit = limit, mode = mode, weights = weights, race = args.race,
    }
end

local function Index(catalog)
    local byId, byPool = {}, {}
    for _, item in ipairs(catalog.items or {}) do
        byId[item.id] = item
        byPool[item.slot] = byPool[item.slot] or {}
        table.insert(byPool[item.slot], item)
    end
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

local function SourceAllowed(source, query)
    if source.kind == "quest" then
        if source.profession then return false, "profession" end
        if source.side and source.sideStatus ~= "unknown" and source.side ~= query.faction then
            return false, "faction"
        end
        if source.minLevel and (source.minLevelStatus == "known" or source.minLevelStatus == "temporary")
            and source.minLevel > query.level then
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
        if source.enterLevelStatus == "recorded" and source.enterLevel and source.enterLevel > query.level then
            return false, "instance_enter"
        end
        return true
    end
    return false, "source"
end

local function UsableSources(item, query)
    local kept, rejected = {}, { faction = 0, quest_min_level = 0, quest_level_window = 0, no_instance = 0, instance_enter = 0, source = 0 }
    for _, source in ipairs(item.sources or {}) do
        local ok, reason = SourceAllowed(source, query)
        if ok then table.insert(kept, source) else rejected[reason] = (rejected[reason] or 0) + 1 end
    end
    return kept, rejected
end

local function Score(item, weights)
    local terms, unquantified, total = {}, {}, 0
    local stats = item.stats or {}
    for _, key in ipairs(ORDER) do
        if key ~= "weaponDps" and stats[key] ~= nil and weights[key] ~= nil then
            local points = stats[key] * weights[key]
            total = total + points
            table.insert(terms, { stat = key, label = STAT_LABEL[key], value = stats[key], weight = weights[key], points = points })
        end
    end
    for key, value in pairs(stats) do
        if not weights[key] then
            table.insert(unquantified, (STAT_LABEL[key] or key) .. " " .. tostring(value) .. " 没有防护权重，未计入")
        end
    end
    for _, row in ipairs(item.unmappedStats or {}) do
        table.insert(unquantified, tostring(row.stat) .. " 未映射，未计入")
    end
    if item.weapon and item.weapon.dps then
        if item.hands == 1 or item.hands == 2 then
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
    local text = "生存启发式：" .. (#parts > 0 and table.concat(parts, " + ") or "没有可计属性")
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

local function Candidate(item, sources, query, current, reservedId)
    local scored = query.mode == "protection"
    local score, terms, unquantified
    if scored then score, terms, unquantified = Score(item, query.weights) end
    local wearableStatus
    _, wearableStatus = Wearable(item, query.level)
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
    local blocked = reservedId and item.id == reservedId and "duplicate_item" or nil
    if blocked then proven = false end
    return {
        id = item.id, name = item.name, url = item.url, slot = item.slot, hands = item.hands, subtype = item.subtype,
        ilvl = item.ilvl, reqLevel = item.reqLevel, reqEstimate = item.reqEstimate,
        reqLevelStatus = item.reqLevelStatus, wearable = wearableStatus,
        score = score, scoreStatus = scored and "heuristic" or "not_scored",
        terms = terms, unquantified = unquantified, explanation = Explain(terms or {}, unquantified or {}, scored),
        relation = relation, provenUpgrade = proven, diff = diff, comparison = comparison,
        blocked = blocked, sources = sources, appearanceSourceType = item.appearanceSourceType,
        conditions = {
            obtainable = "not_confirmed",
            questState = "not_checked",
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

local function BuildSlot(spec, pool, query, byId, currentEntry, reservedId, catalog)
    local counts = { listed = 0, level = 0, class = 0, armor = 0, source = 0 }
    local candidates = {}
    for _, item in ipairs(pool) do
        if Fits(item, spec, query.mode) then
            counts.listed = counts.listed + 1
            if not ClassAllowed(item, query.className) then
                counts.class = counts.class + 1
            elseif LearnLocked(item, catalog, query.level) then
                counts.armor = counts.armor + 1
            else
                local wearable = Wearable(item, query.level)
                if not wearable then
                    counts.level = counts.level + 1
                else
                    local sources = UsableSources(item, query)
                    if #sources == 0 then counts.source = counts.source + 1
                    else table.insert(candidates, Candidate(item, sources, query, currentEntry, reservedId)) end
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

local function CurrentFor(spec, gear, byId, query)
    local entry = gear[spec.id] or gear[spec.pool]
    if not entry then return nil end
    local item = byId[entry]
    if not item then
        return { id = entry, known = false, reason = "当前装备不在已采集数据里，不能把缺失属性当零，也不判断提升。" }
    end
    local known = { id = entry, known = true, item = item }
    if query.mode == "protection" then known.score = Score(item, query.weights) end
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

local function ResolveLooseIds(mapped, byId)
    local loose = {}
    for _, id in ipairs(mapped) do table.insert(loose, id) end
    for index = #mapped, 1, -1 do mapped[index] = nil end
    for _, id in ipairs(loose) do
        local item = byId[id]
        if not item then mapped["unknown:" .. id] = id
        else
            local slot = item.slot
            if mapped[slot] then return false end
            mapped[slot] = id
        end
    end
    return true
end

local Gear = {}
ns.Gear = Gear

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
    local unrecognized = {}
    for key, id in pairs(gear) do
        if type(key) == "string" and key:find("^unknown:") then unrecognized[#unrecognized + 1] = id end
    end
    local slots, reserved = {}, {}
    local mainWeapon = gear.mainhand and byId[gear.mainhand]
    for _, spec in ipairs(SLOTS) do
        local current = CurrentFor(spec, gear, byId, query)
        if spec.pool == "offhand" and mainWeapon and mainWeapon.hands == 2 then
            current = {
                id = mainWeapon.id, known = true, item = mainWeapon, occupied = true,
                score = query.mode == "protection" and Score(mainWeapon, query.weights) or nil,
                reason = "双手武器同时占用副手。",
            }
        end
        local pool = byPool[spec.pool] or {}
        if query.mode ~= "protection" and spec.pool == "mainhand" then
            pool = {}
            for _, item in ipairs(byPool.mainhand or {}) do table.insert(pool, item) end
            for _, item in ipairs(byPool.twohand or {}) do table.insert(pool, item) end
        end
        local built = BuildSlot(spec, pool, query, byId, current, spec.pair and reserved[spec.pair] or nil, catalog)
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
    if query.mode == "protection" then
        profile = {
            id = "warrior-protection", label = "战士·防护", bias = "survival", scored = true, optimum = false,
            loadout = "1h_shield", weights = query.weights, questLevelWindow = query.window,
            weightNote = "默认偏生存：耐力高于护甲和防御，力量与攻强只作仇恨。武器伤害只计主手。特效和套装不计入。不是 60 级模拟，也不是绝对最优。",
        }
    else
        profile = {
            id = "generic", label = query.className .. "·" .. query.spec, bias = nil, scored = false, optimum = false,
            loadout = nil, weights = nil, questLevelWindow = query.window,
            weightNote = "这个玩法没有独立权重，结果只是过滤后的候选，不套用防护权重。",
        }
    end
    local pair
    if query.mode == "protection" then
        local mainhand, offhand
        for _, slot in ipairs(slots) do
            if slot.slot == "mainhand" then mainhand = slot end
            if slot.slot == "offhand" then offhand = slot end
        end
        local currentWeapon = gear.mainhand and byId[gear.mainhand]
        pair = {
            rule = "1h_shield",
            mainhand = mainhand and mainhand.highlight and mainhand.highlight.id or nil,
            offhand = offhand and offhand.highlight and offhand.highlight.id or nil,
            provenUpgrade = false,
            note = "主手和盾的分数相加只用于这一套防护启发式。双手武器会同时占两个槽，不能拿单手单独说成提升。",
        }
        if mainhand and mainhand.highlight and mainhand.highlight.score and offhand and offhand.highlight and offhand.highlight.score then
            pair.score = mainhand.highlight.score + offhand.highlight.score
        end
        if currentWeapon and currentWeapon.hands == 2 then
            pair.comparison = "two_hand_occupies_both"
            if pair.score and query.mode == "protection" then
                local weaponScore = Score(currentWeapon, query.weights)
                pair.scoreDelta = pair.score - weaponScore
                pair.provenUpgrade = pair.scoreDelta > 1e-6
            end
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
