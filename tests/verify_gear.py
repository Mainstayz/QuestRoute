"""Offline checks for QuestRoute gear candidates. Does not connect to the game.

  python tests/verify_gear.py
"""
from __future__ import annotations

import json
from pathlib import Path

from lupa.lua51 import LuaRuntime, lua_type

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons" / "QuestRoute"
EXAMPLE = ADDON / "examples" / "gear-40-warrior-protection.json"

FIXTURE = r'''
local ns = ...
local function quest(id, side, minLevel, questLevel)
    return {
        kind = "quest", temporary = false, confidence = "server", questId = id, name = "任务"..id,
        url = "https://wuxianwow.com/quest/"..id, questLevel = questLevel, questLevelStatus = questLevel and "known" or "unknown",
        minLevel = minLevel, minLevelStatus = minLevel and "known" or "unknown", side = side,
        sideStatus = side and "server" or "unknown", reward = "固定",
        prerequisites = { status = "none_recorded", ids = {} }, questState = "not_checked",
    }
end
local function drop(instanceId, enterLevel)
    return {
        kind = "drop", temporary = true, confidence = "temporary", disclaimer = "临时",
        npc = "首领", npcId = 1, dropChancePercent = nil, dropChanceStatus = "unknown",
        instanceId = instanceId, instanceName = "副本", instanceUrl = "https://wuxianwow.com/instance/"..(instanceId or 0),
        enterLevel = enterLevel, enterLevelStatus = enterLevel and "recorded" or "unknown",
        suggestedGroup = {50, 60}, keys = {{ itemId = 1, name = "钥匙", temporary = true }}, accessComplete = false,
    }
end
local function item(row)
    row.classes = row.classes or {}
    row.stats = row.stats or {}
    row.effects = row.effects or {}
    row.uniqueStatus = "unknown"
    row.sources = row.sources or { drop(7, 20) }
    return row
end
local catalog = {
    meta = { learnAt = { ["板甲"] = 40, ["长柄武器"] = 20 }, complete = false, slots = {} },
    items = {
        item({ id = 1, name = "高甲盾", slot = "offhand", hands = 0, armorType = "盾牌", subtype = "盾牌", ilvl = 40,
            reqLevel = 40, reqLevelStatus = "known", stats = { armor = 1000 } }),
        item({ id = 2, name = "高耐盾", slot = "offhand", hands = 0, armorType = "盾牌", subtype = "盾牌", ilvl = 40,
            reqLevel = 40, reqLevelStatus = "known", stats = { armor = 100, stamina = 20 },
            effects = { "格挡时造成伤害" }, setName = "测试套装" }),
        item({ id = 3, name = "世界盾", slot = "offhand", hands = 0, armorType = "盾牌", subtype = "盾牌", ilvl = 50,
            reqLevel = 40, reqLevelStatus = "known", stats = { armor = 5000 }, appearanceSourceType = "世界掉落",
            sources = { { kind = "drop", instanceId = nil, temporary = true } } }),
        item({ id = 4, name = "副本盾", slot = "offhand", hands = 0, armorType = "盾牌", subtype = "盾牌", ilvl = 30,
            reqLevel = 20, reqLevelStatus = "known", stats = { armor = 10 }, appearanceSourceType = "世界掉落" }),
        item({ id = 5, name = "高任务盾", slot = "offhand", hands = 0, armorType = "盾牌", subtype = "盾牌", ilvl = 60,
            reqLevel = 1, reqLevelStatus = "known", stats = { armor = 9000 },
            sources = { quest(99, nil, 55, 60) } }),
        item({ id = 6, name = "未知等级剑", slot = "mainhand", hands = 1, subtype = "单手剑", ilvl = 20,
            reqLevel = nil, reqLevelStatus = "unknown", weapon = { dps = 10 }, sources = { quest(7, nil, nil, nil) } }),
        item({ id = 7, name = "估值过高", slot = "mainhand", hands = 1, subtype = "单手剑", ilvl = 55,
            reqLevel = nil, reqEstimate = 50, reqLevelStatus = "estimated", weapon = { dps = 80 } }),
        item({ id = 8, name = "估值可穿", slot = "mainhand", hands = 1, subtype = "单手剑", ilvl = 35,
            reqLevel = nil, reqEstimate = 30, reqLevelStatus = "estimated", weapon = { dps = 12 } }),
        item({ id = 9, name = "联盟剑", slot = "mainhand", hands = 1, subtype = "单手剑", ilvl = 40,
            reqLevel = 40, reqLevelStatus = "known", weapon = { dps = 15 }, sources = { quest(10, "联盟", 39, 42) } }),
        item({ id = 10, name = "板甲", slot = "chest", hands = 0, armorType = "板甲", subtype = "板甲", ilvl = 40,
            reqLevel = 1, reqLevelStatus = "known", stats = { armor = 300, stamina = 10 } }),
        item({ id = 11, name = "戒指甲", slot = "finger", hands = 0, subtype = "戒指", ilvl = 40,
            reqLevel = 40, reqLevelStatus = "known", stats = { stamina = 5 } }),
        item({ id = 12, name = "戒指乙", slot = "finger", hands = 0, subtype = "戒指", ilvl = 39,
            reqLevel = 40, reqLevelStatus = "known", stats = { stamina = 4 } }),
        item({ id = 13, name = "饰品甲", slot = "trinket", hands = 0, subtype = "饰品", ilvl = 40,
            reqLevel = 40, reqLevelStatus = "known", stats = { attackPower = 10 } }),
        item({ id = 14, name = "饰品乙", slot = "trinket", hands = 0, subtype = "饰品", ilvl = 39,
            reqLevel = 40, reqLevelStatus = "known", stats = { stamina = 3 } }),
        item({ id = 21, name = "锻造锤", slot = "trinket", hands = 0, subtype = "饰品", ilvl = 45,
            reqLevel = 40, reqLevelStatus = "known", effects = { "召唤锻造锤。" },
            sources = { (function() local row = quest(2765, nil, 40, 45); row.profession = "锻造"; return row end)() } }),
        item({ id = 15, name = "法师甲", slot = "chest", hands = 0, armorType = "布甲", subtype = "布甲", ilvl = 40,
            reqLevel = 1, reqLevelStatus = "known", classes = { "法师" }, stats = { stamina = 30 } }),
        item({ id = 16, name = "双手剑", slot = "twohand", hands = 2, subtype = "双手剑", ilvl = 60,
            reqLevel = 40, reqLevelStatus = "known", weapon = { dps = 40 } }),
        item({ id = 17, name = "弱单手", slot = "mainhand", hands = 1, subtype = "单手剑", ilvl = 40,
            reqLevel = 40, reqLevelStatus = "known", weapon = { dps = 10 } }),
        item({ id = 18, name = "远程弓", slot = "ranged", hands = 0, subtype = "弓", ilvl = 40,
            reqLevel = 40, reqLevelStatus = "known", weapon = { dps = 20 }, stats = { agility = 1 } }),
        item({ id = 19, name = "商人盾", slot = "offhand", hands = 0, armorType = "盾牌", subtype = "盾牌", ilvl = 40,
            reqLevel = 1, reqLevelStatus = "known", stats = { armor = 8000 }, sources = { { kind = "vendor" } } }),
        item({ id = 20, name = "高准入", slot = "head", hands = 0, subtype = "锁甲", ilvl = 40,
            reqLevel = 1, reqLevelStatus = "known", stats = { stamina = 20 },
            sources = { drop(8, 50) } }),
        item({ id = 22, name = "圣骑肩", slot = "shoulder", hands = 0, armorType = "板甲", subtype = "板甲", ilvl = 45,
            reqLevel = 40, reqLevelStatus = "known", stats = { strength = 20, stamina = 20 },
            sources = { (function() local row = quest(79970, "联盟", 35, 40); row.questClass = "圣骑士"; return row end)() } }),
    },
}
local base = { level = 40, class = "战士", spec = "防护", faction = "联盟" }
local function run(extra, data)
    local args = { level = base.level, class = base.class, spec = base.spec, faction = base.faction }
    for key, value in pairs(extra or {}) do args[key] = value end
    return ns.Gear.Recommend(args, data or catalog)
end
local function slot(result, id)
    for _, row in ipairs(result.slots) do if row.slot == id then return row end end
end
local function has(row, id)
    for _, candidate in ipairs(row.candidates) do if candidate.id == id then return candidate end end
end
local checks = 0
local function check(ok, message)
    assert(ok, message)
    checks = checks + 1
end

local missing = ns.Gear.Recommend({ level = 40, class = "战士", spec = "防护", faction = "联盟" }, nil)
check(missing.ok == false and missing.error.code == "no_dataset", "missing catalog is explicit")
local refused = run({ class = "法师", spec = "防护" })
check(refused.ok == false and refused.error.code == "unsupported" and refused.slots == nil and refused.profile == nil, "other classes are refused without prot weights")
local bad = run({ level = 0 })
check(bad.ok == false and bad.error.code == "invalid_arguments", "level zero is rejected")
check(run({ faction = "中立" }).ok == false, "unknown faction is rejected")

local result = run()
check(result.ok and result.profile.optimum == false and result.profile.scored and result.coverageComplete == false, "protection result is a non-optimal heuristic")
check(#result.slots == 17, "all combat slots are present")
local names = {}
for _, row in ipairs(result.slots) do names[row.slot] = true end
for _, id in ipairs({ "head","neck","shoulder","back","chest","wrist","hands","waist","legs","feet","finger1","finger2","trinket1","trinket2","mainhand","offhand","ranged" }) do
    check(names[id], "slot exists: "..id)
end
check(names.shirt == nil and names.tabard == nil, "shirt and tabard are not combat slots")
for _, row in ipairs(result.slots) do
    for _, candidate in ipairs(row.candidates) do
        check(candidate.provenUpgrade == false and candidate.relation == "candidate", "no current gear is not a proven upgrade")
    end
end
local offhand = slot(result, "offhand")
check(has(offhand, 2) and not has(offhand, 3) and not has(offhand, 5) and not has(offhand, 19), "world drops, vendors and high quest levels are excluded")
check(has(offhand, 4).appearanceSourceType == "世界掉落" and has(offhand, 4).sources[1].instanceId == 7, "dungeon drop labeled world drop is kept")
check(has(offhand, 4).conditions.accessComplete == false and has(offhand, 4).sources[1].suggestedGroup[1] == 50, "suggested difficulty and keys do not block")
local better = has(offhand, 2)
local proc, setBonus = false, false
for _, line in ipairs(better.unquantified) do
    local text = tostring(line)
    if text:find("特效", 1, true) then proc = true end
    if text:find("套装", 1, true) then setBonus = true end
end
check(proc and setBonus, "set and proc stay outside the leveling score")
local expected = 20 * 4 + 100 * 0.05
check(math.abs(better.score - expected) < 1e-6, "default score includes stamina at 4 and mild armor at 0.05")
local noArmor = run({ weights = { armor = 0 } })
local noArmorShield = has(slot(noArmor, "offhand"), 2)
local armorLeftOut = false
for _, line in ipairs(noArmorShield.unquantified) do
    if tostring(line):find("护甲", 1, true) and tostring(line):find("练级不计", 1, true) then armorLeftOut = true end
end
check(armorLeftOut and math.abs(noArmorShield.score - 80) < 1e-6, "zeroed armor weight is disclosed in unquantified")
local apTrinket = has(slot(result, "trinket1"), 13)
check(apTrinket and math.abs(apTrinket.score - 20) < 1e-6, "attackPower scores at 2 by default")
check(not has(slot(result, "shoulder"), 22) and slot(result, "shoulder").filtered.sourceReasons.quest_class == 1, "other-class quest rewards are excluded")
check(better.conditions.weaponSkill == "not_in_dataset" and better.conditions.questState == "not_checked" and better.conditions.obtainable == "not_confirmed", "unknown conditions stay unknown")
check(slot(result, "head").emptyReason == "no_allowed_source", "high dungeon entry is an explicit empty reason")
check(not has(slot(result, "mainhand"), 7) and has(slot(result, "mainhand"), 8).wearable == "estimated", "req estimate is not treated as level zero")
check(has(slot(result, "mainhand"), 6).wearable == "unknown" and has(slot(result, "mainhand"), 6).reqLevel == nil, "missing required level stays unknown")
local horde = run({ faction = "部落" })
check(has(slot(result, "mainhand"), 9) and not has(slot(horde, "mainhand"), 9), "alliance quest is hidden from horde")
local low = run({ level = 39 }, { meta = { learnAt = { ["板甲"] = 40 }, complete = false }, items = { catalog.items[10] } })
check(not has(slot(low, "chest"), 10) and slot(low, "chest").emptyReason == "armor_not_learned", "plate before learn_at is excluded")
check(has(slot(result, "chest"), 10) and not has(slot(result, "chest"), 15), "learned plate stays and other-class items do not")
check(slot(result, "finger1").highlight.id == 11 and slot(result, "finger2").highlight.id == 12, "rings are distinct")
check(slot(result, "trinket1").highlight.id ~= slot(result, "trinket2").highlight.id, "trinkets are distinct")
check(not has(slot(result, "trinket1"), 21) and not has(slot(result, "trinket2"), 21), "profession-category quests are excluded")
local only = run(nil, { meta = { learnAt = {}, complete = false }, items = { catalog.items[11] } })
check(slot(only, "finger2").highlight == nil and slot(only, "finger2").emptyReason == "no_distinct_item", "one ring cannot fill both slots")
local loosePair = run({ gear = { 11, 12, 16 } })
check(loosePair.ok and slot(loosePair, "finger1").current.id == 11 and slot(loosePair, "finger2").current.id == 12, "loose id array supports two rings")
check(slot(loosePair, "mainhand").current.id == 16 and slot(loosePair, "offhand").current.id == 16, "loose id array maps two-hander to mainhand and occupies offhand")
local singleRingKey = run({ gear = { finger = 11 } })
check(slot(singleRingKey, "finger1").current.id == 11 and slot(singleRingKey, "finger2").current == nil, "generic finger key binds only finger1")
check(slot(singleRingKey, "finger2").highlight and slot(singleRingKey, "finger2").highlight.id == 12, "finger2 avoids recommending ring already worn in finger1")
local same = run()
local again = run()
check(slot(same, "offhand").highlight.id == slot(again, "offhand").highlight.id and slot(same, "mainhand").candidates[1].id == slot(again, "mainhand").candidates[1].id, "sort is deterministic")
local worn = run({ gear = { offhand = 2 } })
check(slot(worn, "offhand").emptyReason == "no_upgrade", "current best item is not replaced")
for _, candidate in ipairs(slot(worn, "offhand").candidates) do
    check(candidate.provenUpgrade == false, "no candidate is pushed over a better current item")
end
local unknown = run({ gear = { offhand = 999 } })
check(slot(unknown, "offhand").current.known == false and slot(unknown, "offhand").highlight.provenUpgrade == false and slot(unknown, "offhand").highlight.diff == nil, "unknown current gear is not scored as zero")
local shirt = run({ gear = { shirt = 1, tabard = 2, offhand = 2 } })
check(#shirt.ignoredNonCombat == 2 and slot(shirt, "offhand").emptyReason == "no_upgrade", "shirt and tabard are ignored")
local ranged = has(slot(result, "ranged"), 18)
local rangedDamage = false
for _, line in ipairs(ranged.unquantified) do
    if tostring(line):find("武器伤害", 1, true) then rangedDamage = true end
end
check(ranged.score == 3 and rangedDamage, "agility scores at 3 and ranged damage stays out")
local heavy = run({ weights = { armor = 1 } })
check(slot(heavy, "offhand").highlight.id == 1 and slot(result, "offhand").highlight.id == 2, "weights are configurable and the default is stamina")
local empty = run(nil, { meta = { complete = false, slots = {} }, items = {} })
for _, row in ipairs(empty.slots) do
    check(#row.candidates == 0 and row.emptyReason == "dataset_has_no_item", "empty data is explicit for "..row.slot)
end
local generic = run({ spec = "狂暴" })
check(generic.ok and generic.profile.scored == false and generic.profile.weights == nil, "other warrior specs are not scored with prot weights")
check(slot(generic, "mainhand").highlight.id == 16 and slot(generic, "offhand").emptyReason == "occupied_by_twohand", "two-hand occupies the offhand in a generic loadout")
check(not has(slot(result, "mainhand"), 16) and not has(slot(result, "offhand"), 16), "protection loadout does not list a two-hander")
local occupied = run({ gear = { mainhand = 16 } })
check(slot(occupied, "mainhand").highlight.provenUpgrade == false and slot(occupied, "offhand").highlight.comparison == "occupied_by_twohand", "one-hand is not an upgrade over a two-hander by itself")
check(occupied.pair.comparison == "two_hand_occupies_both", "pair comparison stays on the pair")
local lose = run({ gear = { mainhand = 16 } }, {
    meta = { learnAt = {}, complete = false },
    items = {
        item({ id = 16, name = "强双手", slot = "twohand", hands = 2, ilvl = 40, reqLevel = 40, reqLevelStatus = "known", weapon = { dps = 100 } }),
        item({ id = 17, name = "弱单手", slot = "mainhand", hands = 1, ilvl = 40, reqLevel = 40, reqLevelStatus = "known", weapon = { dps = 10 } }),
        item({ id = 2, name = "高耐盾", slot = "offhand", hands = 0, armorType = "盾牌", ilvl = 40, reqLevel = 40, reqLevelStatus = "known", stats = { armor = 100, stamina = 20 } }),
    },
})
check(lose.pair.provenUpgrade == false and lose.pair.scoreDelta < 0, "pair score can lose to the equipped two-hander")
local tiny = run({ gear = { mainhand = 16 } }, {
    meta = { learnAt = {}, complete = false },
    items = {
        item({ id = 16, name = "慢双手", slot = "twohand", hands = 2, ilvl = 40, reqLevel = 40, reqLevelStatus = "known", weapon = { dps = 1 } }),
        item({ id = 17, name = "弱单手", slot = "mainhand", hands = 1, ilvl = 40, reqLevel = 40, reqLevelStatus = "known", weapon = { dps = 10 } }),
        item({ id = 2, name = "高耐盾", slot = "offhand", hands = 0, armorType = "盾牌", ilvl = 40, reqLevel = 40, reqLevelStatus = "known", stats = { armor = 100, stamina = 20 } }),
    },
})
check(tiny.pair.provenUpgrade and slot(tiny, "mainhand").highlight.provenUpgrade == false, "a better pair is marked on the pair, not on the weapon alone")
return checks
'''

REAL = r'''
local ns = ...
local function slot(result, id)
    for _, row in ipairs(result.slots) do if row.slot == id then return row end end
end
local function find(result, id)
    for _, row in ipairs(result.slots) do
        for _, candidate in ipairs(row.candidates) do
            if candidate.id == id then return candidate, row end
        end
    end
end
local function catalogItem(id)
    for _, item in ipairs(ns.GearCatalog.items) do if item.id == id then return item end end
end
local checks = 0
local function check(ok, message)
    assert(ok, message)
    checks = checks + 1
end
local args = { level = 40, class = "战士", spec = "防护", faction = "联盟", limit = 100 }
local alliance = ns.GetGearCandidates(args)
local horde = ns.GetGearCandidates({ level = 40, class = "战士", spec = "防护", faction = "部落", limit = 100 })
check(alliance.ok and alliance.attribution.legal == "https://wuxianwow.com/legal", "real result cites the dataset")
check(alliance.coverageComplete == false and ns.GearCatalog.meta.complete == false, "coverage is not claimed complete")
check(catalogItem(1204) == nil, "unnamed world-drop shield is not in the dataset")
check(catalogItem(7726) and catalogItem(10767) and catalogItem(10823) and catalogItem(6802), "validation items were collected")
check(catalogItem(279831) and catalogItem(279908), "high-level counterexamples were collected")
local shield = find(alliance, 7726)
check(shield and shield.appearanceSourceType == "世界掉落" and shield.sources[1].instanceId ~= nil and shield.sources[1].temporary, "verified dungeon shield survives the world-drop label")
check(shield.reqLevel == 39 and shield.reqLevelStatus == "known", "shield requirement stays 39")
local effect = false
for _, line in ipairs(shield.unquantified) do if tostring(line):find("神圣", 1, true) then effect = true end end
check(effect, "shield proc is disclosed and not silently dropped")
local total = 0
for _, term in ipairs(shield.terms) do total = total + term.points end
check(math.abs(total - shield.score) < 1e-6, "disclosed terms add up to the score")
check(find(alliance, 10767) and find(alliance, 10767).sources[1].instanceId == 129, "boar shield is linked to Razorfen Downs")
local whitemane = false
for _, source in ipairs(shield.sources) do
    if source.npc and tostring(source.npc):find("怀特迈恩", 1, true) then
        whitemane = source.instanceId == 189 and source.dropChancePercent == nil and source.dropChanceStatus == "unknown"
    end
end
check(whitemane, "Whitemane stays on the dungeon and a missing drop rate is not zero")
local sword = find(alliance, 10823)
check(sword and sword.reqLevelStatus == "estimated" and sword.reqLevel == nil, "zero required level stays estimated")
local sawAlliance, sawHorde = false, false
for _, source in ipairs(sword.sources) do
    if source.questId == 3636 then sawAlliance = source.minLevel == 39 and source.side == "联盟" end
    if source.questId == 3341 then sawHorde = true end
end
check(sawAlliance and not sawHorde, "alliance sword keeps only the alliance quest")
local hordeSword = find(horde, 10823)
sawAlliance, sawHorde = false, false
for _, source in ipairs(hordeSword.sources) do
    if source.questId == 3341 then sawHorde = source.side == "部落" end
    if source.questId == 3636 then sawAlliance = true end
end
check(sawHorde and not sawAlliance, "horde sword keeps only the horde quest")
check(find(horde, 6802) and not find(alliance, 6802), "omen sword stays horde-only")
check(not find(alliance, 279831) and not find(alliance, 279908) and not find(horde, 279831) and not find(horde, 279908), "low wear requirements do not bypass high quest levels")
check(alliance.profile.id == "warrior-protection" and alliance.profile.optimum == false, "real example does not claim an optimum")
local sawPlace = false
for _, item in ipairs(ns.GearCatalog.items) do
    for _, source in ipairs(item.sources or {}) do
        if source.kind == "quest" and source.zone and (source.chainKind == "standalone" or source.chainKind == "chain") then
            sawPlace = true
        end
    end
end
check(sawPlace, "quest sources keep the pickup zone and whether they are a chain")
local sawUnique, sawTwoHand = false, false
for _, item in ipairs(ns.GearCatalog.items) do
    if item.uniqueStatus == "unique_equipped" then sawUnique = true end
    if item.slot == "twohand" then sawTwoHand = true end
end
check(sawUnique, "unique_equipped items from MCP are preserved")
check(sawTwoHand, "two-handed weapons are collected in the catalog")
local fury = ns.GetGearCandidates({ level = 40, class = "战士", spec = "狂暴", faction = "联盟", limit = 100 })
check(fury.ok and slot(fury, "mainhand").highlight and slot(fury, "mainhand").highlight.hands == 2, "fury spec sees two-handed weapons")
check(not find(alliance, 277236) and not find(alliance, 277205) and not find(alliance, 280696), "paladin and shaman class quest rewards are excluded from warrior")
for _, row in ipairs(alliance.slots) do
    check(row.coverage.complete == false, "slot coverage stays incomplete: "..row.slot)
end
return checks, alliance
'''


def to_py(value):
    if lua_type(value) != "table":
        if isinstance(value, float) and value.is_integer():
            return int(value)
        if isinstance(value, float):
            return round(value, 4)
        return value
    keys = list(value.keys())

    def index(key):
        if isinstance(key, int):
            return key
        if isinstance(key, float) and key.is_integer():
            return int(key)
        return None

    indexes = [index(key) for key in keys]
    if indexes and all(number is not None for number in indexes) and min(indexes) == 1 and max(indexes) == len(indexes):
        return [to_py(value[index]) for index in range(1, len(indexes) + 1)]
    return {str(key): to_py(value[key]) for key in keys}


def load(runtime, *names):
    namespace = runtime.table()
    for name in names:
        source = (ADDON / name).read_text(encoding="utf-8-sig")
        runtime.execute(source, "QuestRoute", namespace, name=f"@{name}")
    return namespace


SHEET = r'''
local ns = ...
local checks = 0
local function check(ok, message)
    assert(ok, message)
    checks = checks + 1
end
local chain = ns.GearSheet.GateText({ sources = {{
    kind = "quest", name = "琥珀酒", zone = "西部荒野", zoneStatus = "known",
    chainKind = "chain", chainPosition = 2, chainLength = 3, previousName = "雷酒", minLevel = 40,
}}})
check(chain:find("琥珀酒", 1, true) and chain:find("西部荒野接", 1, true) and chain:find("任务链 第2/3步", 1, true) and chain:find("前置 雷酒", 1, true) and chain:find("可接 40", 1, true), "quest chain names the map and the previous quest")
local alone = ns.GearSheet.GateText({ sources = {{ kind = "quest", name = "侏儒的手艺", zone = "铁炉堡", chainKind = "standalone", minLevel = 28 }}})
check(alone:find("独立任务", 1, true) and alone:find("铁炉堡接", 1, true), "a quest with no previous step stays standalone")
local unknown = ns.GearSheet.GateText({ sources = {{ kind = "quest", name = "未知", chainKind = "unknown" }}})
check(unknown:find("接取地图未知", 1, true) and unknown:find("是否任务链未知", 1, true) and unknown:find("可接等级未知", 1, true), "missing quest place is not called standalone")
local drop = ns.GearSheet.GateText({ sources = {{ kind = "drop", instanceName = "血色修道院", npc = "莫格莱尼", enterLevel = 39, temporary = true }}})
check(drop == "血色修道院 · 莫格莱尼（临时）" and not drop:find("准入", 1, true), "dungeon line names the boss and skips the enter level")
local missing = ns.GearSheet.GateText({ sources = {{ kind = "drop", instanceName = "血色修道院", temporary = true }}})
check(missing:find("掉落者未记录", 1, true) and not missing:find("准入", 1, true), "a drop without a boss does not invent one or an enter level")
local stats = ns.GearSheet.StatText({ stats = { strength = 11, stamina = 6, armor = 1287, intellect = 3 }, hands = 1, weapon = { dps = 12.5 } })
check(stats:find("力量11", 1, true) and stats:find("耐力6", 1, true) and stats:find("护甲1287", 1, true) and stats:find("智力3", 1, true) and stats:find("每秒伤害12.5", 1, true), "the row lists the item stats")
local where, gate = ns.GearSheet.GateLines({ sources = {{ kind = "drop", instanceName = "血色修道院", npc = "莫格莱尼", enterLevel = 39, temporary = true }}})
check(where == "血色修道院 · 莫格莱尼" and gate == "临时" and not where:find("准入", 1, true), "panel dungeon line names the place and not the enter level")
local questWhere, questGate = ns.GearSheet.GateLines({ sources = {{ kind = "quest", name = "琥珀酒", zone = "西部荒野", chainKind = "chain", chainPosition = 2, chainLength = 3, minLevel = 40 }}})
check(questWhere == "琥珀酒 · 西部荒野" and questGate == "链2/3 · 可接40", "panel quest line stays on two short rows")
local trinketText = ns.GearSheet.StatText({ stats = {}, effects = { "提高格挡值。" } })
check(trinketText == "特效：提高格挡值。", "effect-only items show their effect instead of empty stats")
local multi = ns.GearSheet.GateText({ sources = {
    { kind = "drop", instanceName = "血色修道院", npc = "莫格莱尼", temporary = true },
    { kind = "drop", instanceName = "血色修道院", npc = "怀特迈恩", temporary = true },
}})
check(multi:find("莫格莱尼", 1, true) and multi:find("怀特迈恩", 1, true), "multi-source detail lists more than one source")
local _, multiGate = ns.GearSheet.GateLines({ sources = {
    { kind = "drop", instanceName = "血色修道院", npc = "莫格莱尼", temporary = true },
    { kind = "drop", instanceName = "血色修道院", npc = "怀特迈恩", temporary = true },
}})
check(multiGate:find("+1来源", 1, true), "panel line indicates extra sources")
C_QuestLog = { IsQuestFlaggedCompleted = function(id) return id == 53 end }
local _, doneGate = ns.GearSheet.GateLines({ sources = {{ kind = "quest", questId = 53, name = "琥珀酒", zone = "西部荒野", chainKind = "standalone", minLevel = 40 }}})
check(doneGate:find("已完成", 1, true), "completed quest is marked on panel")
C_QuestLog = nil
return checks
'''


def main() -> None:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    namespace = load(runtime, "Gear.lua")
    fixture_checks = runtime.execute(FIXTURE, namespace)
    data = LuaRuntime(unpack_returned_tuples=True)
    loaded = load(data, "GearData.lua", "Gear.lua")
    real_checks, alliance = data.execute(REAL, loaded)
    EXAMPLE.parent.mkdir(parents=True, exist_ok=True)
    preview = data.execute(
        'local ns=...; return ns.GetGearCandidates({level=40,class="战士",spec="防护",faction="联盟",limit=5})',
        loaded,
    )
    EXAMPLE.write_text(json.dumps(to_py(preview), ensure_ascii=False, indent=2), encoding="utf-8")
    sheet = LuaRuntime(unpack_returned_tuples=True)
    sheet.execute(
        "function CreateFrame() local f = {} function f:RegisterEvent() end function f:SetScript() end return f end"
    )
    sheet_checks = sheet.execute(SHEET, load(sheet, "GearSheet.lua"))
    print(f"PASS: {fixture_checks + real_checks + sheet_checks} gear checks; example={EXAMPLE}")


if __name__ == "__main__":
    main()
