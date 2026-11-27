-- 按角色保存路线偏好，以及路线/姓名板共用的任务过滤。
local _, ns = ...
local IsID, IsFinite, Accessible = ns.Util.IsID, ns.Util.IsFinite, ns.Util.Accessible
local instanceTags = { [62] = true, [81] = true, [85] = true, [88] = true, [89] = true, [98] = true, [288] = true }
local professionCategories = {
    ["炼金术"] = true, ["锻造"] = true, ["附魔"] = true, ["工程学"] = true,
    ["草药学"] = true, ["制皮"] = true, ["采矿"] = true, ["剥皮"] = true,
    ["裁缝"] = true, ["钓鱼"] = true, ["烹饪"] = true, ["急救"] = true,
    ["珠宝加工"] = true, ["铭文"] = true, ["考古学"] = true,
}

local cachedName, cachedRealm, cachedKey

local function RouteSettings()
    local name = Accessible(UnitName("player"))
    local settings
    if not name then
        ns.route.temporary = ns.route.temporary or { skipped = {}, moveThreshold = 100, enabled = true }
        settings = ns.route.temporary
    else
        QuestRouteDB = QuestRouteDB or {}
        QuestRouteDB.routes = QuestRouteDB.routes or {}
        local realm = GetRealmName()
        if name ~= cachedName or realm ~= cachedRealm then
            cachedName, cachedRealm, cachedKey = name, realm, realm .. ":" .. name
        end
        settings = QuestRouteDB.routes[cachedKey]
        if not settings then
            settings = { skipped = {}, moveThreshold = 100, enabled = true }
            QuestRouteDB.routes[cachedKey] = settings
        end
    end
    if settings.nameplatesEnabled == nil then settings.nameplatesEnabled = true end
    if settings.includeEliteQuests == nil then settings.includeEliteQuests = false end
    if settings.switchNotice == nil then settings.switchNotice = true end
    -- 任务联想默认关闭：缺字段与非 boolean 脏值一律纠正为 false，升级后需玩家手动开启。
    if type(settings.associationEnabled) ~= "boolean" then settings.associationEnabled = false end
    local offset = settings.maxMonsterLevelOffset
    if not IsFinite(offset) or offset % 1 ~= 0 or offset < 0 or offset > 5 then settings.maxMonsterLevelOffset = 2 end
    local minimum = settings.minPickupLevel
    if not IsFinite(minimum) or minimum % 1 ~= 0 or minimum < 0 or minimum > 60 then settings.minPickupLevel = 15 end
    return settings
end

local function TargetAboveLevel(db, point, playerLevel, levels, maxOffset)
    if type(point) ~= "table" or point.entityKind ~= "npc" or not IsID(point.entityID) then return false end
    local id, npc = point.entityID, db and db.Npc
    local level = levels and levels[id]
    if level == nil then
        for _, field in ipairs({ "maxLevel", "minLevel" }) do
            local getter = type(npc) == "table" and npc[field]
            local ok, value
            if type(getter) == "function" then ok, value = pcall(getter, id) end
            if ok and IsID(value) then level = value; break end
        end
        if levels then levels[id] = level or false end
    end
    maxOffset = maxOffset or RouteSettings().maxMonsterLevelOffset
    return IsID(level) and IsID(playerLevel) and level > playerLevel + maxOffset, level
end

local function RouteExclusion(quest, db, settings)
    if settings.skipped[quest.questID] then return "skipped", "player" end
    if quest.isFailed then return "failed", "client" end
    -- 难度/类型过滤针对做任务；目标已完成后只安排交付，仍遵守手动跳过和地图归属。
    if quest.readyForTurnIn or quest.isComplete then return end
    local tag = quest.tag
    local questType = C_QuestLog.GetQuestType(quest.questID)
    if instanceTags[questType] or (tag and instanceTags[tag.id]) then return "instance", "client" end
    if not settings.includeEliteQuests and (C_QuestLog.IsEliteQuest(quest.questID) or (tag and tag.isElite)) then
        return "elite", "client"
    end
    if (tag and IsID(tag.tradeskillLineID)) or professionCategories[quest.category] then
        return "profession", "client"
    end
    if db and db.Quest and type(db.Quest.requiredSkill) == "function" then
        local ok, skill = pcall(db.Quest.requiredSkill, quest.questID)
        if ok and type(skill) == "table" and IsID(skill[1]) then return "profession", "QuestieDB" end
    end
end

ns.RouteOptions = { Get = RouteSettings, Exclusion = RouteExclusion, TargetAboveLevel = TargetAboveLevel }
