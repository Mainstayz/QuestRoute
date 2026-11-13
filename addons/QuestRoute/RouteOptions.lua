-- 按角色保存路线偏好，以及路线/姓名板共用的任务过滤。
local _, ns = ...
local IsID, Accessible = ns.Util.IsID, ns.Util.Accessible
local instanceTags = { [62] = true, [81] = true, [85] = true, [88] = true, [89] = true, [98] = true, [288] = true }
local professionCategories = {
    ["炼金术"] = true, ["锻造"] = true, ["附魔"] = true, ["工程学"] = true,
    ["草药学"] = true, ["制皮"] = true, ["采矿"] = true, ["剥皮"] = true,
    ["裁缝"] = true, ["钓鱼"] = true, ["烹饪"] = true, ["急救"] = true,
    ["珠宝加工"] = true, ["铭文"] = true, ["考古学"] = true,
}

local function RouteSettings()
    local name = Accessible(UnitName("player"))
    local settings
    if not name then
        ns.route.temporary = ns.route.temporary or { skipped = {}, moveThreshold = 100, enabled = true }
        settings = ns.route.temporary
    else
        QuestRouteDB = QuestRouteDB or {}
        QuestRouteDB.routes = QuestRouteDB.routes or {}
        local key = GetRealmName() .. ":" .. name
        settings = QuestRouteDB.routes[key]
        if not settings then
            settings = { skipped = {}, moveThreshold = 100, enabled = true }
            QuestRouteDB.routes[key] = settings
        end
    end
    if settings.nameplatesEnabled == nil then settings.nameplatesEnabled = true end
    if settings.includeEliteQuests == nil then settings.includeEliteQuests = false end
    if settings.switchNotice == nil then settings.switchNotice = true end
    return settings
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

ns.RouteOptions = { Get = RouteSettings, Exclusion = RouteExclusion }
