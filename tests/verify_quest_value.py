"""Offline checks for QuestRoute quest value analysis and quest log side panel.

  python tests/verify_quest_value.py
"""
from __future__ import annotations

from pathlib import Path
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons" / "QuestRoute"

HARNESS = r'''
canaccessvalue = function() return true end
GetTime = function() return 1000 end
IsLoggedIn = function() return true end
UnitName = function() return "擎天" end
GetRealmName = function() return "测试服" end
UnitLevel = function() return 40 end
UnitFactionGroup = function() return "Horde" end
UnitClass = function() return "战士", "WARRIOR" end
UnitXP = function() return 5000 end
UnitXPMax = function() return 90700 end
GetXPExhaustion = function() return 0 end
GetInventoryItemID = function(_, inv)
    local worn = { [16] = 5001, [17] = 5002, [5] = 5003 }
    return worn[inv]
end
GetInventoryItemLink = function() return nil end
CreateVector2D = function(x, y) return { x = x, y = y } end

local printed = {}
print = function(msg) printed[#printed + 1] = tostring(msg) end

C_SpecializationInfo = {
    GetSpecialization = function() return 3 end,
    GetSpecializationInfo = function() return 73, "防护", "", 0, "TANK" end,
}

C_Item = {
    GetItemInfoInstant = function(id)
        if id == 6099 then return id, "护甲", "布甲", "INVTYPE_CHEST", 0, 4, 1 end
        if id == 6098 then return id, "护甲", "布甲", "INVTYPE_CLOAK", 0, 4, 1 end
        if id == 6010 then return id, "护甲", "板甲", "INVTYPE_CHEST", 0, 4, 4 end
        if id == 6001 then return id, "护甲", "盾牌", "INVTYPE_SHIELD", 0, 4, 6 end
        if id == 6976 then return id, "武器", "双手锤", "INVTYPE_2HWEAPON", 0, 2, 5 end
        return nil
    end,
}

local MAPS = {
    [1424] = { name = "希尔斯布莱德丘陵", continent = 0, ox = 0, oy = 0, scale = 2000 },
    [1416] = { name = "奥特兰克山脉", continent = 0, ox = 600, oy = 0, scale = 2000 },
    [1434] = { name = "荆棘谷", continent = 0, ox = 12000, oy = 0, scale = 2000 },
    [1441] = { name = "千针石林", continent = 1, ox = 1000, oy = 1000, scale = 2000 },
    [1443] = { name = "凄凉之地", continent = 1, ox = 5000, oy = 1000, scale = 2000 },
}

C_Map = {
    GetBestMapForUnit = function() return 1424 end,
    GetMapInfo = function(id)
        local m = MAPS[id]
        return m and { mapID = id, name = m.name } or nil
    end,
    GetPlayerMapPosition = function() return { x = 0.5, y = 0.5 } end,
    GetWorldPosFromMapPos = function(id, pos)
        local m = MAPS[id]
        if not m then return nil end
        return m.continent, { x = m.ox + pos.x * m.scale, y = m.oy + pos.y * m.scale }
    end,
    GetMapChildrenInfo = function()
        local out = {}
        for id in pairs(MAPS) do out[#out + 1] = { mapID = id } end
        return out
    end,
}

-- 构造测试任务日志（覆盖全部核心与边界场景）
local ACTIVE_QUESTS = {
    -- 1. 职业任务、灰了、仅120经验，但已可交且后续出旋风蓝装 -> keep_priority
    { questID = 1791, title = "捕风者", category = "战士", level = 30, readyForTurnIn = true, isComplete = true,
      diff = 0, trivial = true, xp = 120, money = 0, objectives = {}, mapID = 1416 },
    -- 2. 系列任务链：当前步在远图、纯经验、0进度，但终点出 GearCatalog 确认提升装 -> keep_priority
    { questID = 503, title = "高迪尔", category = "希尔斯布莱德丘陵", level = 36,
      diff = 1, trivial = false, xp = 1500, money = 0, mapID = 1434,
      objectives = { { text = "0/1 锈铁钥匙", type = "item", finished = false, numFulfilled = 0, numRequired = 1 } } },
    -- 3. 单一独立任务 + 跨大陆 + 孤立 + 纯经验 + 0进度 -> recommend_drop
    { questID = 1107, title = "坚硬的尾鳍", category = "千针石林", level = 35, tag = { id = 1, name = "精英", isElite = true },
      diff = 1, trivial = false, xp = 2000, money = 0, mapID = 1441,
      objectives = { { text = "0/10 坚硬的尾鳍", type = "item", finished = false, numFulfilled = 0, numRequired = 10 } } },
    -- 4. 灰色无后续 + 高沉没进度 (8/10) -> hold_or_drop（受沉没进度保护，不直接 recommend_drop）
    { questID = 556, title = "石雕", category = "希尔斯布莱德丘陵", level = 33,
      diff = 0, trivial = true, xp = 1600, money = 3500, mapID = 1424,
      objectives = { { text = "8/10 用旧的石雕", type = "item", finished = false, numFulfilled = 8, numRequired = 10 } } },
    -- 5. 灰色无后续 + 0进度 -> recommend_drop
    { questID = 95697, title = "口味的变迁", category = "挖掘场：湿地", level = 31, tag = { id = 81, name = "地下城" },
      diff = 0, trivial = true, xp = 1200, money = 0, mapID = 1424,
      objectives = { { text = "0/4 迅猛龙肉", type = "item", finished = false, numFulfilled = 0, numRequired = 4 } } },
    -- 6. 副本中性测试：36级副本，高经验 + 蓝装 -> keep_priority，带副本标签
    { questID = 6521, title = "邪恶的盟友", category = "剃刀高地", level = 36, tag = { id = 81, name = "地下城" },
      diff = 1, trivial = false, xp = 7350, money = 2000, mapID = 1441,
      choices = { { name = "高地蓝盾", quality = 3, usable = true, itemID = 6001, itemLevel = 40 } },
      objectives = { { text = "0/1 玛克林大使的头颅", type = "item", finished = false, numFulfilled = 0, numRequired = 1 } } },
    -- 7. 精英中性测试：本图适级精英，有不错经验 -> keep（不因精英判弃）
    { questID = 518, title = "意志之冠", category = "希尔斯布莱德丘陵", level = 39, tag = { id = 1, name = "精英", isElite = true },
      diff = 2, trivial = false, xp = 4500, money = 0, mapID = 1424,
      objectives = { { text = "0/14 破碎岭虐待者", type = "monster", finished = false, numFulfilled = 0, numRequired = 14 } } },
    -- 8. 奖励未就绪（后续链待加载）-> uncertain 且触发 RequestLoadQuestByID
    { questID = 8001, title = "神秘信函", category = "凄凉之地", level = 38,
      diff = 2, trivial = false, xp = 2500, money = 0, mapID = 1443,
      objectives = { { text = "0/1 送达信函", type = "item", finished = false, numFulfilled = 0, numRequired = 1 } } },
    -- 9. 失败任务 -> recommend_drop
    { questID = 8002, title = "护送失败", category = "希尔斯布莱德丘陵", level = 38, isFailed = true,
      diff = 2, trivial = false, xp = 3500, money = 0, mapID = 1424,
      objectives = { { text = "护送目标", type = "event", finished = false, numFulfilled = 0, numRequired = 1 } } },
    -- 10. 不可放弃任务 -> keep_priority
    { questID = 8003, title = "核心主线", category = "希尔斯布莱德丘陵", level = 30, canAbandon = false,
      diff = 0, trivial = true, xp = 100, money = 0, mapID = 1424,
      objectives = { { text = "0/1 对话", type = "event", finished = false, numFulfilled = 0, numRequired = 1 } } },
    -- 11. 含购买/制造卡点物品的任务
    { questID = 515, title = "苦楚药剂", category = "希尔斯布莱德丘陵", level = 38,
      diff = 2, trivial = false, xp = 3600, money = 0, mapID = 1424,
      objectives = {
          { text = "0/1 次级巨魔之血药剂", type = "item", finished = false, numFulfilled = 0, numRequired = 1 },
          { text = "5/5 鳞片", type = "item", finished = true, numFulfilled = 5, numRequired = 5 },
      } },
    -- 12. 物品触发独立远图低经验任务：验证 reaccept.cost == "hard"
    { questID = 8004, title = "失落的日记", category = "凄凉之地", level = 36,
      diff = 1, trivial = false, xp = 1800, money = 0, mapID = 1443,
      objectives = { { text = "0/1 交给学者", type = "item", finished = false, numFulfilled = 0, numRequired = 1 } } },
    -- 13. 布甲绿装独立远图（40级战士穿布甲不算有效装备，应视同纯经验）
    { questID = 8005, title = "法系布袍", category = "千针石林", level = 38,
      diff = 1, trivial = false, xp = 2000, money = 0, mapID = 1441,
      choices = { { name = "雾彩褶裙", quality = 2, usable = true, itemID = 6099, itemLevel = 40 } },
      objectives = { { text = "0/5 羽毛", type = "item", finished = false, numFulfilled = 0, numRequired = 5 } } },
    -- 14. 高单次经验（7.7%本级）独立远图 -> hold_or_drop 而非直接 recommend_drop
    { questID = 8006, title = "奥达曼宝物", category = "荆棘谷", level = 42, tag = { id = 81, name = "地下城" },
      diff = 2, trivial = false, xp = 7000, money = 0, mapID = 1434,
      objectives = { { text = "0/1 宝物", type = "item", finished = false, numFulfilled = 0, numRequired = 1 } } },
}

local BY_ID = {}
for i, q in ipairs(ACTIVE_QUESTS) do
    q.logIndex = i
    BY_ID[q.questID] = q
end

-- 未来未接任务（用于链追踪）
local FUTURE_REWARDS = {
    [1712] = { ready = true, xp = 2350, money = 0 },
    [1792] = { ready = true, xp = 3900, money = 0,
        choices = { { name = "旋风之锤", quality = 3, usable = true, itemID = 6976, itemLevel = 40 } } },
    [506] = { ready = true, xp = 2100, money = 3000 },
    [508] = { ready = true, xp = 3900, money = 0,
        choices = { { name = "塔蕾莎之板甲", quality = 2, usable = true, itemID = 6010, itemLevel = 40 } } },
    [8011] = { ready = false }, -- 未缓存
}

local requestedLoads = {}
local abandonCalled = false

HaveQuestData = function(id)
    if BY_ID[id] then return BY_ID[id].rewardReady ~= false end
    local f = FUTURE_REWARDS[id]
    return f ~= nil and f.ready == true
end
HaveQuestRewardData = HaveQuestData
GetQuestLogRewardXP = function(id)
    local q = BY_ID[id] or FUTURE_REWARDS[id]
    return q and q.xp or 0
end
GetQuestLogRewardMoney = function(id)
    local q = BY_ID[id] or FUTURE_REWARDS[id]
    return q and q.money or 0
end
GetNumQuestLogRewards = function(id)
    local q = BY_ID[id] or FUTURE_REWARDS[id]
    return q and q.rewards and #q.rewards or 0
end
GetQuestLogRewardInfo = function(idx, id)
    local q = BY_ID[id] or FUTURE_REWARDS[id]
    local r = q and q.rewards and q.rewards[idx]
    if not r then return nil end
    return r.name, 0, 1, r.quality, r.usable, r.itemID, r.itemLevel
end
GetNumQuestLogChoices = function(id)
    local q = BY_ID[id] or FUTURE_REWARDS[id]
    return q and q.choices and #q.choices or 0
end
GetQuestLogChoiceInfo = function(idx, id)
    local q = BY_ID[id] or FUTURE_REWARDS[id]
    local r = q and q.choices and q.choices[idx]
    if not r then return nil end
    return r.name, 0, 1, r.quality, r.usable, r.itemID, r.itemLevel
end

C_PlayerInfo = {
    GetContentDifficultyQuestForPlayer = function(id)
        local q = BY_ID[id]
        return q and q.diff or 2
    end,
}

C_QuestInfoSystem = {
    GetQuestRewardSpells = function() return {} end,
}

C_QuestLog = {
    GetNumQuestLogEntries = function() return #ACTIVE_QUESTS, #ACTIVE_QUESTS end,
    GetInfo = function(i)
        local q = ACTIVE_QUESTS[i]
        if not q then return nil end
        return { questID = q.questID, title = q.title, questLogIndex = i, level = q.level, suggestedGroup = 0, frequency = 0, questClassification = 7 }
    end,
    IsComplete = function(id) return BY_ID[id] and BY_ID[id].isComplete == true or false end,
    IsFailed = function(id) return BY_ID[id] and BY_ID[id].isFailed == true or false end,
    ReadyForTurnIn = function(id) return BY_ID[id] and BY_ID[id].readyForTurnIn == true or false end,
    GetQuestTagInfo = function(id) local t = BY_ID[id] and BY_ID[id].tag; return t and { tagID = t.id, tagName = t.name, isElite = t.isElite } or nil end,
    GetQuestObjectives = function(id) return BY_ID[id] and BY_ID[id].objectives or {} end,
    GetQuestType = function(id) local t = BY_ID[id] and BY_ID[id].tag; return t and t.id or 0 end,
    IsEliteQuest = function(id) local t = BY_ID[id] and BY_ID[id].tag; return t and t.isElite == true or false end,
    IsQuestTrivial = function(id) return BY_ID[id] and BY_ID[id].trivial == true or false end,
    IsQuestFlaggedCompleted = function() return false end,
    CanAbandonQuest = function(id) local q = BY_ID[id]; return not q or q.canAbandon ~= false end,
    GetMaxNumQuestsCanAccept = function() return 40 end,
    RequestLoadQuestByID = function(id) requestedLoads[id] = true end,
    AbandonQuest = function() abandonCalled = true end,
    GetQuestsOnMap = function(mapID)
        local out = {}
        for _, q in ipairs(ACTIVE_QUESTS) do
            if q.mapID == mapID then
                out[#out + 1] = { questID = q.questID, mapID = mapID, x = 0.5, y = 0.5 }
            end
        end
        return out
    end,
}

-- Mock QuestieDB (contract 4)
local DB_QUESTS = {
    [1791] = { name = "捕风者", level = 30, nextQ = 1712, reqCls = 1, startedBy = { { 101 }, {}, {} } },
    [1712] = { name = "塞克隆尼亚", level = 40, nextQ = 1792, reqCls = 1 },
    [1792] = { name = "旋风武器", level = 40, nextQ = 0, reqCls = 1 },
    [503]  = { name = "高迪尔", level = 36, nextQ = 506, startedBy = { { 101 }, {}, {} } },
    [506]  = { name = "布莱克摩尔的余孽", level = 38, nextQ = 0 },
    [508]  = { name = "塔蕾莎的礼物", level = 40, nextQ = 0, preSingle = { 506 } }, -- 通过反向 preSingle 连接！
    [1107] = { name = "坚硬的尾鳍", level = 35, nextQ = 0, startedBy = { { 101 }, {}, {} } },
    [556]  = { name = "石雕", level = 33, nextQ = 0, startedBy = { { 101 }, {}, {} } },
    [95697]= { name = "口味的变迁", level = 31, nextQ = 0, startedBy = { { 101 }, {}, {} } },
    [6521] = { name = "邪恶的盟友", level = 36, nextQ = 0, startedBy = { { 101 }, {}, {} } },
    [518]  = { name = "意志之冠", level = 39, nextQ = 0, startedBy = { { 101 }, {}, {} } },
    [8001] = { name = "神秘信函", level = 38, nextQ = 8011, startedBy = { { 101 }, {}, {} } },
    [8011] = { name = "神秘回信", level = 40, nextQ = 0 },
    [8002] = { name = "护送失败", level = 38, nextQ = 0, startedBy = { { 101 }, {}, {} } },
    [8003] = { name = "核心主线", level = 30, nextQ = 0, startedBy = { { 101 }, {}, {} } },
    [515]  = { name = "苦楚药剂", level = 38, nextQ = 0, startedBy = { { 101 }, {}, {} },
               objectives = { {}, {}, { { 3388, "次级巨魔之血药剂" }, { 3389, "鳞片" } } } },
    [8004] = { name = "失落的日记", level = 36, nextQ = 0, startedBy = { {}, {}, { 9901 } } },
    [8005] = { name = "法系布袍", level = 38, nextQ = 0, startedBy = { { 101 }, {}, {} } },
    [8006] = { name = "奥达曼宝物", level = 42, nextQ = 0, startedBy = { { 101 }, {}, {} } },
}
local DB_ITEMS = {
    [3388] = { name = "次级巨魔之血药剂", npcDrops = {}, objectDrops = {} }, -- 制造/购买品
    [3389] = { name = "鳞片", npcDrops = { 201 }, objectDrops = {} },
}
local DB_NPCS = {
    [101] = { name = "营地指挥官", spawns = { [267] = { { 50, 50 } } } },
}

C_AddOns = { GetAddOnMetadata = function() return "1.1.5" end }
LibQuestieDB = {
    addonName = "QuestieDB",
    contractVersion = 4,
    RequireContract = function(v) return v == 4 end,
    Support = { Get = function() return { private = { areaIdToUiMapId = { [267] = 1424 } } } end },
    Quest = {
        Exists = function(id) return DB_QUESTS[id] ~= nil end,
        GetAllIds = function() local ids = {}; for id in pairs(DB_QUESTS) do ids[#ids+1] = id end; return ids end,
        name = function(id) return DB_QUESTS[id] and DB_QUESTS[id].name end,
        questLevel = function(id) return DB_QUESTS[id] and DB_QUESTS[id].level end,
        nextQuestInChain = function(id) return DB_QUESTS[id] and DB_QUESTS[id].nextQ or 0 end,
        preQuestSingle = function(id) return DB_QUESTS[id] and DB_QUESTS[id].preSingle or {} end,
        preQuestGroup = function() return {} end,
        childQuests = function() return {} end,
        requiredClasses = function(id) return DB_QUESTS[id] and DB_QUESTS[id].reqCls or 0 end,
        requiredRaces = function() return 0 end,
        requiredSkill = function() return nil end,
        reputationReward = function() return nil end,
        startedBy = function(id) return DB_QUESTS[id] and DB_QUESTS[id].startedBy or { {}, {}, {} } end,
        finishedBy = function() return { {}, {} } end,
        objectives = function(id) return DB_QUESTS[id] and DB_QUESTS[id].objectives or { {}, {}, {} } end,
    },
    Item = {
        Exists = function(id) return DB_ITEMS[id] ~= nil end,
        name = function(id) return DB_ITEMS[id] and DB_ITEMS[id].name end,
        npcDrops = function(id) return DB_ITEMS[id] and DB_ITEMS[id].npcDrops or {} end,
        objectDrops = function(id) return DB_ITEMS[id] and DB_ITEMS[id].objectDrops or {} end,
    },
    Npc = {
        Exists = function(id) return DB_NPCS[id] ~= nil end,
        name = function(id) return DB_NPCS[id] and DB_NPCS[id].name end,
        spawns = function(id) return DB_NPCS[id] and DB_NPCS[id].spawns or {} end,
        maxLevel = function() return 38 end,
        minLevel = function() return 36 end,
    },
    Object = { Exists = function() return false end },
}

-- Minimal UI mocks for QuestValueSheet
local function MakeFrame(kind, name, parent)
    local f = { kind = kind, name = name, parent = parent, shown = false, scripts = {}, events = {}, enabled = true }
    if name then _G[name] = f end
    function f:SetSize() end
    function f:SetPoint() end
    function f:ClearAllPoints() end
    function f:SetAllPoints() end
    function f:SetClampedToScreen() end
    function f:SetFrameStrata() end
    function f:Show() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
    function f:Hide() self.shown = false; if self.scripts.OnHide then self.scripts.OnHide(self) end end
    function f:IsShown() return self.shown end
    function f:IsVisible() return self.shown and (not self.parent or self.parent:IsVisible()) end
    function f:Enable() self.enabled = true end
    function f:Disable() self.enabled = false end
    function f:RegisterEvent(e) self.events[e] = true end
    function f:UnregisterAllEvents() self.events = {} end
    function f:SetScript(ev, fn) self.scripts[ev] = fn end
    function f:HookScript(ev, fn)
        local prev = self.scripts[ev]
        self.scripts[ev] = function(...)
            if prev then prev(...) end
            fn(...)
        end
    end
    function f:CreateTexture()
        return { SetAllPoints = function() end, SetPoint = function() end, SetColorTexture = function() end, SetSize = function() end }
    end
    function f:CreateFontString()
        local fs = { text = "" }
        function fs:SetJustifyH() end
        function fs:SetJustifyV() end
        function fs:SetWidth() end
        function fs:SetHeight() end
        function fs:SetPoint() end
        function fs:ClearAllPoints() end
        function fs:SetAllPoints() end
        function fs:SetWordWrap() end
        function fs:SetMaxLines() end
        function fs:SetText(t) self.text = t end
        function fs:GetText() return self.text end
        function fs:Show() self.shown = true end
        function fs:Hide() self.shown = false end
        return fs
    end
    return f
end
CreateFrame = MakeFrame
UIParent = MakeFrame("Frame", "UIParent", nil); UIParent.shown = true
WorldMapFrame = MakeFrame("Frame", "WorldMapFrame", UIParent)
QuestMapFrame = MakeFrame("Frame", "QuestMapFrame", WorldMapFrame); QuestMapFrame.shown = true
GameTooltip = {
    lines = {},
    SetOwner = function() end,
    ClearLines = function(self) self.lines = {} end,
    AddLine = function(self, text) self.lines[#self.lines + 1] = text end,
    Show = function(self) self.shown = true end,
    Hide = function(self) self.shown = false end,
}

return {
    requestedLoads = requestedLoads,
    printed = printed,
    wasAbandonCalled = function() return abandonCalled end,
}
'''

TESTS = r'''
local checks = 0
local function check(ok, msg)
    assert(ok, msg)
    checks = checks + 1
end

-- 构造最小 GearCatalog：现装 5003 较弱，任务 508 产出的 6010 为明确提升装
ns.GearCatalog = {
    meta = { learnAt = { ["板甲"] = 40 }, complete = false, slots = {} },
    items = {
        { id = 5001, name = "旧单手", slot = "mainhand", hands = 1, subtype = "单手剑", ilvl = 30, reqLevel = 30, reqLevelStatus = "known",
          weapon = { dps = 15 }, classes = {}, stats = { strength = 3 }, effects = {}, uniqueStatus = "unknown",
          sources = { { kind = "quest", questId = 1, name = "旧", side = "部落", sideStatus = "server", questLevel = 30, questLevelStatus = "known", minLevel = 25, minLevelStatus = "known", prerequisites = { status = "none_recorded", ids = {} }, questState = "not_checked" } } },
        { id = 5002, name = "旧盾牌", slot = "offhand", hands = 0, armorType = "盾牌", subtype = "盾牌", ilvl = 30, reqLevel = 30, reqLevelStatus = "known",
          classes = {}, stats = { armor = 500, stamina = 3 }, effects = {}, uniqueStatus = "unknown",
          sources = { { kind = "quest", questId = 2, name = "旧", side = "部落", sideStatus = "server", questLevel = 30, questLevelStatus = "known", minLevel = 25, minLevelStatus = "known", prerequisites = { status = "none_recorded", ids = {} }, questState = "not_checked" } } },
        { id = 5003, name = "旧胸甲", slot = "chest", hands = 0, armorType = "锁甲", subtype = "锁甲", ilvl = 28, reqLevel = 28, reqLevelStatus = "known",
          classes = {}, stats = { armor = 180, stamina = 4 }, effects = {}, uniqueStatus = "unknown",
          sources = { { kind = "quest", questId = 3, name = "旧", side = "部落", sideStatus = "server", questLevel = 28, questLevelStatus = "known", minLevel = 24, minLevelStatus = "known", prerequisites = { status = "none_recorded", ids = {} }, questState = "not_checked" } } },
        { id = 6010, name = "塔蕾莎之板甲", slot = "chest", hands = 0, armorType = "板甲", subtype = "板甲", ilvl = 40, quality = 2, reqLevel = 40, reqLevelStatus = "known",
          classes = {}, stats = { armor = 520, strength = 14, stamina = 16 }, effects = {}, uniqueStatus = "unknown",
          sources = { { kind = "quest", questId = 508, name = "塔蕾莎的礼物", side = "部落", sideStatus = "server", questLevel = 40, questLevelStatus = "known", minLevel = 35, minLevelStatus = "known", prerequisites = { status = "none_recorded", ids = {} }, questState = "not_checked" } } },
    },
}

local res = ns.AnalyzeQuests({})
check(res.ok == true, "analyze_quests returns ok=true")
check(res.policy == "advisory_only_never_auto_abandon", "policy states advisory only")
check(res.groupQuestPolicy == "neutral_tag_only", "groupQuestPolicy is neutral_tag_only")
check(res.log.count == 14 and res.log.maxCanAccept == 40, "reads log count and cap")
check(res.gearEvaluation.enabled and res.gearEvaluation.scored, "gear evaluation enabled and scored for prot warrior")

local byID = {}
for _, item in ipairs(res.quests) do byID[item.questID] = item end

-- 1. 职业 + 可交 + 后续蓝装 -> keep_priority
local q1791 = byID[1791]
check(q1791.verdict == "keep_priority", "class + turn-in quest is keep_priority despite trivial/120xp")
check(q1791.chain.remainingSteps == 2 and q1791.chain.hasFutureRichReward, "1791 traces 2 future steps with rich blue reward")
check(q1791.chain.bestFutureGear and q1791.chain.bestFutureGear.item.name == "旋风之锤", "1791 identifies terminal blue weapon")

-- 2. 反向 preQuestSingle 任务链终点出确认提升装 -> keep_priority（哪怕本步远图纯经验）
local q503 = byID[503]
check(q503.verdict == "keep_priority", "503 chain with terminal gear upgrade is keep_priority")
check(q503.chain.remainingSteps == 2, "503 traces both nextQuestInChain(506) and reverse preQuestSingle(508)")
check(q503.chain.bestFutureGear and q503.chain.bestFutureGear.item.provenUpgrade == true, "508 reward proven upgrade vs worn chest 5003")

-- 3. 单一独立 + 跨大陆 + 孤立 + 纯经验 + 0进度 -> recommend_drop
local q1107 = byID[1107]
check(q1107.verdict == "recommend_drop", "standalone far pure-xp isolated 0-progress quest recommends drop")
check(q1107.chain.kind == "standalone", "1107 identified as standalone")
check(q1107.geography.scope == "other_continent", "1107 identified as other_continent")
check(q1107.flags.isElite == true, "1107 carries neutral elite tag")

-- 4. 灰无后续但 8/10 高沉没进度 -> hold_or_drop（不武断 recommend_drop）
local q556 = byID[556]
check(q556.verdict == "hold_or_drop", "trivial quest with 80% progress protected as hold_or_drop")
check(q556.progress.highSunkCost == true, "556 marked highSunkCost")

-- 5. 灰无后续 + 0进度 -> recommend_drop
local q95697 = byID[95697]
check(q95697.verdict == "recommend_drop", "trivial no-future 0-progress quest recommends drop")

-- 6. 副本中性：36级副本高经验+蓝装 -> keep_priority
local q6521 = byID[6521]
check(q6521.verdict == "keep_priority", "dungeon quest with blue reward is keep_priority")
check(q6521.flags.isInstance == true, "6521 has neutral instance flag")

-- 7. 精英中性：本图适级精英正常经验 -> keep（不因精英判弃）
local q518 = byID[518]
check(q518.verdict == "keep", "appropriate current-map elite quest stays keep under neutral policy")

-- 8. 后续链奖励未缓存 -> uncertain 且触发 RequestLoadQuestByID
local q8001 = byID[8001]
check(q8001.verdict == "uncertain", "quest with uncached future chain reward stays uncertain")
check(env.requestedLoads[8011] == true, "uncached future quest triggers RequestLoadQuestByID")
check(ns.route.valuePendingQuestIDs and ns.route.valuePendingQuestIDs[8011] == true, "pending quest recorded for refresh")

-- 9. 失败任务 -> recommend_drop
check(byID[8002].verdict == "recommend_drop", "failed quest recommends drop")

-- 10. 不可放弃 -> keep_priority
check(byID[8003].verdict == "keep_priority", "non-abandonable quest protected as keep_priority")

-- 11. 购买/专业制造卡点物品识别
check(byID[515].progress.hasCraftOrBuyItem == true and byID[515].progress.craftOrBuyItems[1] == "次级巨魔之血药剂",
      "detects craft/buy item bottleneck")

-- 12. 物品触发任务重接成本标 hard
check(byID[8004].reaccept.cost == "hard", "item-started quest marked hard reaccept")
check(byID[1107].reaccept.cost == "easy", "npc-started quest marked easy reaccept")

-- 12b. 40级战士过滤布甲绿装 & 高单次经验独立远图降档 hold_or_drop
check(byID[8005].reward.hasNotableGear == false and byID[8005].verdict == "recommend_drop", "cloth green ignored for lvl40 warrior")
check(byID[8006].verdict == "hold_or_drop", "high single-quest XP (7.7%) far standalone is hold_or_drop not recommend_drop")

-- 13. 排序：recommend_drop 排在最前，keep_priority 排在最后
check(res.quests[1].verdict == "recommend_drop", "recommend_drop sorted first")
check(res.quests[#res.quests].verdict == "keep_priority", "keep_priority sorted last")

-- 14. 过滤与参数验证
local onlyDrop = ns.AnalyzeQuests({ verdict = "recommend_drop" })
check(onlyDrop.ok and #onlyDrop.quests == res.summary.recommendDrop, "verdict filter works")
local single = ns.AnalyzeQuests({ questID = 503 })
check(single.ok and #single.quests == 1 and single.quests[1].questID == 503, "questID filter works")
local bad = ns.AnalyzeQuests({ verdict = "invalid_verdict" })
check(bad.ok == false and bad.error.code == "invalid_arguments", "invalid verdict rejected")

-- 15. 格式化输出
local auditLines = ns.QuestValue.FormatAuditLines(res, false)
check(#auditLines >= 2 and auditLines[1]:find("14/40", 1, true) ~= nil, "FormatAuditLines includes capacity summary")
local detailLines = ns.QuestValue.FormatQuestDetailLines(q503)
check(table.concat(detailLines, "\n"):find("塔蕾莎的礼物", 1, true) ~= nil, "FormatQuestDetailLines shows future chain step")

-- 16. QuestValueSheet 侧边栏行为
ns.QuestValueSheet.Attach()
check(ns.QuestValueSheet.panel == nil or not ns.QuestValueSheet.panel:IsShown(), "panel hidden while WorldMapFrame hidden")
WorldMapFrame:Show()
check(ns.QuestValueSheet.panel ~= nil and ns.QuestValueSheet.panel:IsShown(), "panel shows when QuestMapFrame becomes visible")
check(ns.QuestValueSheet.panel.rows[1].item ~= nil, "first card populated")
-- 模拟点击第一张卡片：只打印详情，绝不放弃任务
local beforePrint = #env.printed
ns.QuestValueSheet.panel.rows[1].scripts.OnClick(ns.QuestValueSheet.panel.rows[1])
check(#env.printed > beforePrint, "clicking card prints quest detail to chat")
check(env.wasAbandonCalled() == false, "never calls AbandonQuest")
-- 模拟悬停
ns.QuestValueSheet.panel.rows[1].scripts.OnEnter(ns.QuestValueSheet.panel.rows[1])
check(GameTooltip.shown == true and #GameTooltip.lines >= 4, "hovering card populates tooltip")
-- 切换模式到高价值优先
ns.QuestValueSheet.panel.modeBtn.scripts.OnClick()
ns.QuestValueSheet.panel.modeBtn.scripts.OnClick()
check(ns.QuestValueSheet.items[1].verdict == "keep_priority", "value_first mode puts keep_priority first")
-- 翻页
ns.QuestValueSheet.panel.nextBtn.scripts.OnClick()
check(ns.QuestValueSheet.page == 2, "next page advances page")
-- 关闭大地图时侧边栏同步隐藏
WorldMapFrame:Hide()
check(not ns.QuestValueSheet.panel:IsShown(), "panel hides when WorldMapFrame hides")
-- 卸载清理
ns.QuestValueSheet.Shutdown()
check(next(ns.QuestValueSheet.watcher.events) == nil, "Shutdown unregisters watcher events")

return checks
'''


def main() -> None:
    lua = LuaRuntime(unpack_returned_tuples=True)
    env = lua.execute(HARNESS)
    ns = lua.table()
    # 按依赖顺序加载核心、数据、过滤、优先级、装备与任务价值分析模块
    files = [
        "Core.lua",
        "Database.lua",
        "QuestData.lua",
        "RouteOptions.lua",
        "Priority.lua",
        "Gear.lua",
        "QuestValue.lua",
        "QuestValueSheet.lua",
    ]
    for name in files:
        code = (ADDON / name).read_text(encoding="utf-8")
        lua.eval(f"function(...) {code}\nend")("QuestRoute", ns)
    checks = lua.eval(f"function(ns, env)\n{TESTS}\nend")(ns, env)
    print(f"verify_quest_value: OK ({checks} checks)")


if __name__ == "__main__":
    main()
