-- 角色窗口右侧的单槽前三名。只在玩家打开角色页时出现，数据仍用本地 GearCatalog。
local _, ns = ...

local INV = (ns.Gear and ns.Gear.INV_SLOTS) or {
    [1] = "head", [2] = "neck", [3] = "shoulder", [5] = "chest", [6] = "waist",
    [7] = "legs", [8] = "feet", [9] = "wrist", [10] = "hands", [11] = "finger1",
    [12] = "finger2", [13] = "trinket1", [14] = "trinket2", [15] = "back",
    [16] = "mainhand", [17] = "offhand", [18] = "ranged",
}
local STANDARD_SLOT_FRAMES = {
    head = "CharacterHeadSlot", neck = "CharacterNeckSlot", shoulder = "CharacterShoulderSlot",
    back = "CharacterBackSlot", chest = "CharacterChestSlot", wrist = "CharacterWristSlot",
    hands = "CharacterHandsSlot", waist = "CharacterWaistSlot", legs = "CharacterLegsSlot",
    feet = "CharacterFeetSlot", finger1 = "CharacterFinger0Slot", finger2 = "CharacterFinger1Slot",
    trinket1 = "CharacterTrinket0Slot", trinket2 = "CharacterTrinket1Slot",
    mainhand = "CharacterMainHandSlot", offhand = "CharacterSecondaryHandSlot", ranged = "CharacterRangedSlot",
}
local ORDER = {
    { id = "head", label = "头" }, { id = "neck", label = "颈" }, { id = "shoulder", label = "肩" },
    { id = "back", label = "背" }, { id = "chest", label = "胸" }, { id = "wrist", label = "腕" },
    { id = "hands", label = "手" }, { id = "waist", label = "腰" }, { id = "legs", label = "腿" },
    { id = "feet", label = "脚" }, { id = "finger1", label = "戒指1" }, { id = "finger2", label = "戒指2" },
    { id = "trinket1", label = "饰品1" }, { id = "trinket2", label = "饰品2" },
    { id = "mainhand", label = "主手" }, { id = "offhand", label = "副手" }, { id = "ranged", label = "远程" },
}
local PLAYSTYLES = { "防护", "武器", "狂暴" }

local PANEL_NAME = "QuestRouteGearSheetPanel"
local Sheet = { slot = "head" }
ns.GearSheet = Sheet

local cachedCatalog, cachedById

local function CurrentSheet()
    local root = WoWBridgeNS and WoWBridgeNS.QuestRoute
    return (root and root.GearSheet) or ns.GearSheet
end

local function GetManualSpec()
    if ns.Gear and type(ns.Gear.GetManualSpec) == "function" then
        return ns.Gear.GetManualSpec() or Sheet.manualSpec
    end
    return Sheet.manualSpec
end

local function SetManualSpec(spec)
    Sheet.manualSpec = spec
    if ns.Gear and type(ns.Gear.SetManualSpec) == "function" then
        ns.Gear.SetManualSpec(spec)
    end
end

local function Playstyle(classFile, specName, role)
    if classFile ~= "WARRIOR" then return nil end
    if ns.Gear and type(ns.Gear.DetectWarriorSpec) == "function" then
        return ns.Gear.DetectWarriorSpec(specName, role)
    end
    local name = type(specName) == "string" and specName or ""
    if role == "TANK" or name:find("防护") or name:find("Protection") then return "防护" end
    if name:find("狂") or name:find("Fury") then return "狂暴" end
    if name:find("武器") or name:find("Arms") then return "武器" end
end

local function ReadTalent()
    local api = C_SpecializationInfo
    if type(api) ~= "table" or type(api.GetSpecialization) ~= "function" or type(api.GetSpecializationInfo) ~= "function" then
        return
    end
    local ok, index = pcall(api.GetSpecialization, false, false)
    if not ok or type(index) ~= "number" then return end
    local read, _, name, _, _, role = pcall(api.GetSpecializationInfo, index, false, false)
    if read then return name, role end
end

local function Character()
    if type(UnitLevel) ~= "function" or type(UnitClass) ~= "function" or type(UnitFactionGroup) ~= "function" then
        return
    end
    local levelOk, level = pcall(UnitLevel, "player")
    local classOk, localized, classFile = pcall(UnitClass, "player")
    local factionOk, faction = pcall(UnitFactionGroup, "player")
    if not levelOk or type(level) ~= "number" or level < 1 or not classOk or type(classFile) ~= "string" or not factionOk then
        return
    end
    if faction == "Horde" then faction = "部落" elseif faction == "Alliance" then faction = "联盟" end
    if faction ~= "联盟" and faction ~= "部落" then return nil, "阵营还没读到。" end
    local spec, talentName, specNote
    if classFile == "WARRIOR" then
        if ns.Gear and type(ns.Gear.ReadWarriorSpec) == "function" then
            spec, talentName, specNote = ns.Gear.ReadWarriorSpec()
            if Sheet.manualSpec then spec = Sheet.manualSpec end
        else
            local role
            talentName, role = ReadTalent()
            spec = GetManualSpec() or Playstyle(classFile, talentName, role)
            if not spec then
                spec, specNote = "防护", "没有从天赋判断玩法，先按防护。"
            end
        end
    end
    return {
        level = level,
        className = classFile == "WARRIOR" and "战士" or localized,
        classFile = classFile,
        spec = spec,
        specLabel = talentName or spec,
        specNote = specNote,
        faction = faction,
    }
end

local function Worn(inv)
    if type(GetInventoryItemID) == "function" then
        local ok, id = pcall(GetInventoryItemID, "player", inv)
        if ok and type(id) == "number" and id > 0 then return id end
    end
    if type(GetInventoryItemLink) ~= "function" then return end
    local ok, link = pcall(GetInventoryItemLink, "player", inv)
    if ok and type(link) == "string" then return tonumber(link:match("item:(%d+)")) end
end

local function ReadAllWorn(includeSnapshots)
    if ns.Gear and type(ns.Gear.ReadWorn) == "function" then
        return ns.Gear.ReadWorn(includeSnapshots ~= false)
    end
    local gear = {}
    for inv, id in pairs(INV) do
        gear[id] = Worn(inv)
    end
    return gear, nil
end

local function WornSignature(gear)
    local parts = {}
    for _, slot in ipairs(ORDER) do
        parts[#parts + 1] = tostring(gear[slot.id] or 0)
    end
    return table.concat(parts, ",")
end

function Sheet.InvalidateCache()
    Sheet.cachedKey = nil
    Sheet.cachedResult = nil
    Sheet.cachedGear = nil
    Sheet.pickupCache = nil
end

local function QuestProgress(questId)
    if type(questId) ~= "number" then return nil end
    local api = C_QuestLog
    if type(api) ~= "table" then return nil end
    if type(api.IsQuestFlaggedCompleted) == "function" then
        local ok, done = pcall(api.IsQuestFlaggedCompleted, questId)
        if ok and done == true then return "已完成" end
    end
    if type(api.IsOnQuest) == "function" then
        local ok, active = pcall(api.IsOnQuest, questId)
        if ok and active == true then return "进行中" end
    end
    return nil
end

local STATS = {
    { "strength", "力量" }, { "hit", "命中" }, { "crit", "爆击" }, { "stamina", "耐力" },
    { "agility", "敏捷" }, { "attackPower", "攻强" }, { "dodge", "躲闪" }, { "parry", "招架" },
    { "block", "格挡" }, { "defense", "防御" }, { "blockValue", "格挡值" }, { "armor", "护甲" },
}
local EXTRA_LABEL = { intellect = "智力", spirit = "精神" }

local function NumberText(value)
    if value == math.floor(value) then return tostring(value) end
    return string.format("%.1f", value)
end

function Sheet.StatText(item)
    local stats = item.stats or {}
    local parts, seen = {}, {}
    for _, row in ipairs(STATS) do
        local value = stats[row[1]]
        if type(value) == "number" and value ~= 0 then
            parts[#parts + 1] = row[2] .. NumberText(value)
            seen[row[1]] = true
        end
    end
    if item.weapon and type(item.weapon.dps) == "number" and (item.hands == 1 or item.hands == 2) then
        parts[#parts + 1] = string.format("每秒伤害%.1f", item.weapon.dps)
    end
    local extra = {}
    for key, value in pairs(stats) do
        if not seen[key] and type(value) == "number" and value ~= 0 then
            extra[#extra + 1] = (EXTRA_LABEL[key] or key) .. NumberText(value)
        end
    end
    table.sort(extra)
    for _, text in ipairs(extra) do parts[#parts + 1] = text end
    if #parts == 0 then
        local effects = item.effects
        if type(effects) == "table" and type(effects[1]) == "string" and effects[1] ~= "" then
            return "特效：" .. effects[1]
        end
        return "没有记录到属性"
    end
    return table.concat(parts, "  ")
end

local function SourcePickup(source)
    if type(source) ~= "table" or source.kind ~= "quest" then return nil end
    if type(source.pickup) == "table" then return source.pickup end
    if ns.Gear and type(ns.Gear.ResolveQuestPickup) == "function" then
        return ns.Gear.ResolveQuestPickup(source, Sheet.pickupCache)
    end
    return nil
end

local function FormatPickupPlace(pickup, fallbackZone)
    local coords
    if type(pickup.x) == "number" and type(pickup.y) == "number" then
        coords = string.format("(%d,%d)", math.floor(pickup.x + 0.5), math.floor(pickup.y + 0.5))
    end
    if pickup.mapName then
        return coords and (pickup.mapName .. coords) or pickup.mapName
    end
    if pickup.instanceOnly then return "副本内" end
    return fallbackZone or "地图未知"
end

local function FormatPickupGiver(pickup)
    if pickup.giverKind == "npc" and pickup.giverName then
        return "找" .. pickup.giverName
    elseif pickup.giverKind == "object" and pickup.giverName then
        return "调查「" .. pickup.giverName .. "」"
    elseif pickup.giverKind == "item" and pickup.giverName then
        return "物品「" .. pickup.giverName .. "」"
    end
    return nil
end

local function FormatSingleSource(source)
    if source.kind == "quest" then
        local place = source.zone or "接取地图未知"
        if source.zoneStatus == "temporary" then place = place .. "（临时）" end
        local chain = "是否任务链未知"
        if source.chainKind == "standalone" then
            chain = "独立任务"
        elseif source.chainKind == "chain" then
            if source.chainPosition and source.chainLength then
                chain = string.format("任务链 第%d/%d步", source.chainPosition, source.chainLength)
            else
                chain = "任务链"
            end
            if source.previousName and source.previousName ~= source.name then
                chain = chain .. " · 前置 " .. source.previousName
            end
        end
        local gate = source.minLevel and ("可接 " .. source.minLevel) or "可接等级未知"
        local pickup = SourcePickup(source)
        if pickup and pickup.text and (pickup.status == "available" or pickup.status == "prereq_needed" or pickup.status == "prereq_in_progress") then
            return string.format("%s · %s · %s · %s", source.name or "任务", pickup.text, chain, gate)
        end
        local progress = QuestProgress(source.questId)
        local tail = progress and (" · " .. progress) or ""
        return string.format("%s · %s接 · %s · %s%s", source.name or "任务", place, chain, gate, tail)
    end
    local boss = source.npc or "掉落者未记录"
    local temp = source.temporary and "（临时）" or ""
    return string.format("%s · %s%s", source.instanceName or "副本", boss, temp)
end

function Sheet.GateText(candidate)
    local sources = candidate.sources
    if type(sources) ~= "table" or #sources == 0 then return "来源未知" end
    local parts = {}
    local cap = math.min(#sources, 3)
    for index = 1, cap do
        parts[#parts + 1] = FormatSingleSource(sources[index])
    end
    if #sources > cap then
        parts[#parts + 1] = string.format("另有%d个来源", #sources - cap)
    end
    return table.concat(parts, "；")
end

function Sheet.GateLines(candidate)
    local sources = candidate.sources
    local source = type(sources) == "table" and sources[1] or nil
    if not source then return "来源未知", "" end
    local more = (#sources > 1) and (" · +" .. (#sources - 1) .. "来源") or ""
    if source.kind == "quest" then
        local chain = "链未知"
        if source.chainKind == "standalone" then
            chain = "独立"
        elseif source.chainKind == "chain" then
            if source.chainPosition and source.chainLength then
                chain = string.format("链%d/%d", source.chainPosition, source.chainLength)
            else
                chain = "任务链"
            end
        end
        local level = source.minLevel and ("可接" .. source.minLevel) or "可接未知"
        local pickup = SourcePickup(source)
        if pickup and (pickup.status == "available" or pickup.status == "prereq_needed") then
            local giver = FormatPickupGiver(pickup)
            if giver then
                local place = FormatPickupPlace(pickup, source.zone)
                if pickup.isPrerequisite then
                    local preName = pickup.questName or "前置任务"
                    return "先去 " .. place .. " " .. giver, "接前置「" .. preName .. "」· " .. chain .. more
                end
                return "去 " .. place .. " " .. giver, (source.name or "任务") .. " · " .. level .. more
            end
        elseif pickup and pickup.status == "prereq_in_progress" then
            local preName = pickup.questName or "前置任务"
            return (source.name or "任务") .. " · 前置进行中", "先做「" .. preName .. "」· " .. chain .. more
        end
        local progress = QuestProgress(source.questId)
        local tag = progress and (" · " .. progress) or ""
        return (source.name or "任务") .. " · " .. (source.zone or "地图未知"), chain .. " · " .. level .. tag .. more
    end
    local base = source.temporary and "临时" or ""
    if more ~= "" then
        base = base ~= "" and (base .. more) or ("+" .. (#sources - 1) .. "来源")
    end
    return (source.instanceName or "副本") .. " · " .. (source.npc or "首领未记录"), base
end

local function AllSourcesCompletedQuest(candidate)
    local sources = candidate and candidate.sources
    if type(sources) ~= "table" or #sources == 0 then return false end
    for _, source in ipairs(sources) do
        if source.kind ~= "quest" or QuestProgress(source.questId) ~= "已完成" then
            return false
        end
    end
    return true
end

function Sheet.PickTopCandidates(candidates, wornId, maxCount)
    maxCount = maxCount or 3
    local shown = {}
    for _, candidate in ipairs(candidates or {}) do
        if not candidate.blocked and not AllSourcesCompletedQuest(candidate) then
            shown[#shown + 1] = candidate
            if #shown == maxCount then return shown end
        end
    end
    return shown
end

local function CatalogItem(id)
    if ns.Gear and type(ns.Gear.CatalogItem) == "function" then
        return ns.Gear.CatalogItem(id)
    end
    local catalog = ns.GearCatalog
    if type(catalog) ~= "table" then return nil end
    if cachedCatalog ~= catalog then
        cachedCatalog = catalog
        cachedById = {}
        for _, item in ipairs(catalog.items or {}) do
            cachedById[item.id] = item
        end
    end
    return cachedById[id]
end

local function ItemLink(id, name)
    local api = C_Item
    if type(api) == "table" and type(api.GetItemInfo) == "function" then
        local ok, _, link = pcall(api.GetItemInfo, id)
        if ok and type(link) == "string" then return link end
    end
    return string.format("|cff0070dd|Hitem:%d::::::::|h[%s]|h|r", id, name or "装备")
end

local function SlotMeta(id)
    for _, slot in ipairs(ORDER) do
        if slot.id == id then return slot end
    end
end

local function StepSlot(delta)
    local current = CurrentSheet()
    if not current then return end
    local index = 1
    for cursor, slot in ipairs(ORDER) do
        if slot.id == current.slot then index = cursor end
    end
    local nextIndex = ((index - 1 + delta) % #ORDER) + 1
    current.slot = ORDER[nextIndex].id
    current.Refresh()
end

local function CyclePlaystyle()
    local current = CurrentSheet()
    if not current then return end
    local character = Character()
    if not character or character.classFile ~= "WARRIOR" then return end
    local currentSpec = GetManualSpec() or character.spec or "防护"
    local nextIndex = 1
    for index, name in ipairs(PLAYSTYLES) do
        if name == currentSpec then nextIndex = index % #PLAYSTYLES + 1 end
    end
    SetManualSpec(PLAYSTYLES[nextIndex])
    current.InvalidateCache()
    current.Refresh()
    if ns.QuestValueSheet and type(ns.QuestValueSheet.RefreshIfShown) == "function" then
        ns.QuestValueSheet.RefreshIfShown()
    end
end

local function Line(parent, template, width)
    local text = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    text:SetWidth(width or 210)
    return text
end

local function ShowRowTooltip(row)
    if not row.itemID or not _G.GameTooltip then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(row.titleText or row.itemName or "装备", 1, 0.85, 0.25, true)
    if row.statsText and row.statsText ~= "" then
        GameTooltip:AddLine(row.statsText, 0.9, 0.9, 0.9, true)
    end
    if row.detail and row.detail ~= "" then
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine("获取方式：", 0.4, 0.85, 1)
        for part in row.detail:gmatch("[^；]+") do
            GameTooltip:AddLine("· " .. part, 0.95, 0.95, 0.95, true)
        end
    end
    GameTooltip:AddLine(" ", 1, 1, 1)
    GameTooltip:AddLine("点击输出物品链接与获取方式到聊天框", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function HideRowTooltip(panel)
    if not _G.GameTooltip or type(_G.GameTooltip.GetOwner) ~= "function" then return end
    local ok, owner = pcall(_G.GameTooltip.GetOwner, _G.GameTooltip)
    if not ok or not owner or not panel or not panel.rows then return end
    for _, row in ipairs(panel.rows) do
        if owner == row then
            pcall(_G.GameTooltip.Hide, _G.GameTooltip)
            return
        end
    end
end

local function HidePanel(sheet)
    local target = sheet or Sheet
    local panel = (target and target.panel) or _G[PANEL_NAME]
    if panel then
        HideRowTooltip(panel)
        if type(panel.Hide) == "function" then
            pcall(panel.Hide, panel)
        end
    end
end

local function FrameVisible(frame)
    if not frame then return false end
    if type(frame.IsVisible) == "function" then
        local ok, visible = pcall(frame.IsVisible, frame)
        if ok then return visible == true end
    end
    if type(frame.IsShown) == "function" then
        local ok, shown = pcall(frame.IsShown, frame)
        if ok then return shown == true end
    end
    return false
end

local function HostVisible()
    local paperDoll = _G.PaperDollFrame
    local charFrame = _G.CharacterFrame
    if paperDoll then
        if not FrameVisible(paperDoll) then return false end
        if charFrame and not FrameVisible(charFrame) then return false end
        return true
    end
    return FrameVisible(charFrame)
end

local function BindPanelHandlers(panel)
    if type(panel.SetScript) == "function" then
        panel:SetScript("OnHide", function(self) HideRowTooltip(self) end)
    end
    panel.headerBtn:SetScript("OnClick", function() CyclePlaystyle() end)
    panel.prevSlot:SetScript("OnClick", function() StepSlot(-1) end)
    panel.nextSlot:SetScript("OnClick", function() StepSlot(1) end)
    for _, row in ipairs(panel.rows) do
        row:SetScript("OnEnter", function(self) ShowRowTooltip(self) end)
        row:SetScript("OnLeave", function()
            if _G.GameTooltip then GameTooltip:Hide() end
        end)
        row:SetScript("OnClick", function(self)
            if not self.itemID then return end
            print(string.format("|cff31cee8QuestRoute|r %s %s", ItemLink(self.itemID, self.itemName), self.detail or ""))
        end)
    end
end

local function EnsurePanel(host)
    local anchor = _G.CharacterFrame or host
    local parent = host or _G.UIParent
    local existing = Sheet.panel or _G[PANEL_NAME]
    if existing and existing.rows and existing.headerBtn and existing.prevSlot and existing.nextSlot then
        if parent and type(existing.SetParent) == "function" then
            local ok, currentParent = type(existing.GetParent) == "function" and pcall(existing.GetParent, existing) or false
            if not ok or currentParent ~= parent then
                pcall(existing.SetParent, existing, parent)
            end
        end
        existing:ClearAllPoints()
        existing:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, -30)
        if existing.SetFrameStrata then existing:SetFrameStrata("HIGH") end
        BindPanelHandlers(existing)
        Sheet.panel = existing
        return
    end
    if existing and type(existing.Hide) == "function" then
        pcall(existing.Hide, existing)
    end
    local panel = CreateFrame("Frame", PANEL_NAME, parent)
    panel:SetSize(330, 352)
    panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, -30)
    panel:SetClampedToScreen(true)
    if panel.SetFrameStrata then panel:SetFrameStrata("HIGH") end
    local border = panel:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    border:SetColorTexture(0.72, 0.58, 0.22, 0.95)
    local background = panel:CreateTexture(nil, "BORDER")
    background:SetPoint("TOPLEFT", 1, -1)
    background:SetPoint("BOTTOMRIGHT", -1, 1)
    background:SetColorTexture(0.05, 0.04, 0.03, 0.94)
    panel.headerBtn = CreateFrame("Button", nil, panel)
    panel.headerBtn:SetSize(314, 22)
    panel.headerBtn:SetPoint("TOPLEFT", 8, -5)
    panel.title = Line(panel.headerBtn, "GameFontNormal", 256)
    panel.title:SetPoint("LEFT", 0, 0)
    panel.specHint = Line(panel.headerBtn, nil, 56)
    panel.specHint:SetPoint("RIGHT", 0, 0)
    panel.specHint:SetJustifyH("RIGHT")
    panel.specHint:SetText("|cffffd100[换玩法]|r")
    panel.rows = {}
    for index = 1, 3 do
        local row = CreateFrame("Button", nil, panel)
        row:SetSize(314, 86)
        row:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -36 - (index - 1) * 96)
        local rule = row:CreateTexture(nil, "ARTWORK")
        rule:SetColorTexture(0.72, 0.58, 0.22, 0.45)
        rule:SetSize(314, 1)
        rule:SetPoint("TOPLEFT")
        local function place(text, y)
            text:ClearAllPoints()
            text:SetPoint("TOPLEFT", row, "TOPLEFT", 4, y)
            text:SetHeight(16)
            text:SetWordWrap(false)
            if text.SetMaxLines then text:SetMaxLines(1) end
        end
        row.title = Line(row, "GameFontNormal", 306)
        place(row.title, -10)
        row.stats = Line(row, nil, 306)
        place(row.stats, -28)
        row.where = Line(row, nil, 306)
        place(row.where, -46)
        row.gate = Line(row, nil, 306)
        place(row.gate, -64)
        panel.rows[index] = row
    end
    panel.note = Line(panel, nil, 306)
    panel.note:SetPoint("TOPLEFT", 8, -36)
    panel.note:SetWordWrap(true)
    panel.prevSlot = CreateFrame("Button", nil, panel)
    panel.prevSlot:SetSize(90, 18)
    panel.prevSlot:SetPoint("BOTTOMLEFT", 8, 5)
    panel.prevSlot.label = Line(panel.prevSlot, nil, 90)
    panel.prevSlot.label:SetAllPoints()
    panel.prevSlot.label:SetText("< 上一部位")
    panel.nextSlot = CreateFrame("Button", nil, panel)
    panel.nextSlot:SetSize(90, 18)
    panel.nextSlot:SetPoint("BOTTOMRIGHT", -8, 5)
    panel.nextSlot.label = Line(panel.nextSlot, nil, 90)
    panel.nextSlot.label:SetAllPoints()
    panel.nextSlot.label:SetJustifyH("RIGHT")
    panel.nextSlot.label:SetText("下一部位 >")
    BindPanelHandlers(panel)
    Sheet.panel = panel
end

function Sheet.Select(slot)
    if not SlotMeta(slot) then return end
    if not HostVisible() then
        HidePanel(Sheet)
        return
    end
    if Sheet.slot == slot and Sheet.panel and FrameVisible(Sheet.panel) then return end
    Sheet.slot = slot
    Sheet.Refresh()
end

local function CanHook(frame, script)
    if type(frame.HasScript) ~= "function" or type(frame.HookScript) ~= "function" then return false end
    local ok, yes = pcall(frame.HasScript, frame, script)
    return ok and yes
end

local function HookSingleSlot(button, slot)
    if not button or not CanHook(button, "OnEnter") then return false end
    button.questRouteGearSlot = function()
        local current = CurrentSheet()
        if current then current.Select(slot) end
    end
    if not button.questRouteGearEnterHooked then
        local hooked = pcall(button.HookScript, button, "OnEnter", function(self)
            if self.questRouteGearSlot then self.questRouteGearSlot() end
        end)
        button.questRouteGearEnterHooked = hooked
    end
    return button.questRouteGearEnterHooked == true
end

local function HookStandardSlots()
    local count = 0
    for slot, frameName in pairs(STANDARD_SLOT_FRAMES) do
        if HookSingleSlot(_G[frameName], slot) then
            count = count + 1
        end
    end
    return count
end

local function HookSlots(host, depth)
    if not host or depth > 4 or type(host.GetChildren) ~= "function" then return end
    for _, child in ipairs({ host:GetChildren() }) do
        local slot = child.GetID and INV[child:GetID()]
        if slot then HookSingleSlot(child, slot) end
        HookSlots(child, depth + 1)
    end
end

local function DiffBadge(candidate)
    if not candidate.diff or type(candidate.diff.score) ~= "number" then return "" end
    local delta = candidate.diff.score
    if delta > 0.05 then
        return "  |cff40ff40+" .. NumberText(delta) .. "|r"
    elseif delta < -0.05 then
        return "  |cff999999" .. NumberText(delta) .. "|r"
    end
    return ""
end

function Sheet.Refresh()
    local host = _G.PaperDollFrame or _G.CharacterFrame
    if not host or not HostVisible() then
        HidePanel(Sheet)
        return
    end
    EnsurePanel(host)
    local panel = Sheet.panel
    local slot = SlotMeta(Sheet.slot) or ORDER[1]
    Sheet.slot = slot.id
    local character, problem = Character()
    local heading = slot.label .. " · 前三名"
    if not character then
        panel.title:SetText(heading)
        panel.specHint:Hide()
        panel.note:SetText(problem or "角色信息还不可用。")
        panel.note:Show()
        for _, row in ipairs(panel.rows) do row:Hide() end
        panel:Show()
        return
    end
    local shownSpec = GetManualSpec() or character.spec or character.className
    panel.title:SetText(slot.label .. "  " .. character.level .. "  " .. shownSpec)
    if character.classFile == "WARRIOR" then panel.specHint:Show() else panel.specHint:Hide() end
    local gear = ReadAllWorn(false)
    local cacheKey = table.concat({
        tostring(character.level), tostring(character.className), tostring(character.spec or "防护"),
        tostring(character.faction), WornSignature(gear), tostring(ns.GearCatalog),
    }, "|")
    local result
    if Sheet.cachedKey == cacheKey and Sheet.cachedResult then
        result = Sheet.cachedResult
    else
        local _, gearStats = ReadAllWorn(true)
        result = ns.GetGearCandidates({
            level = character.level, class = character.className, spec = character.spec or "防护",
            faction = character.faction, gear = gear, gearStats = gearStats,
            excludeCompletedQuests = true, includePickupInfo = false, includeExplanation = false, limit = 12,
        })
        Sheet.cachedKey = cacheKey
        Sheet.cachedResult = result
        Sheet.cachedGear = gear
        Sheet.pickupCache = {}
    end
    Sheet.pickupCache = Sheet.pickupCache or {}
    for _, row in ipairs(panel.rows) do row:Hide(); row.itemID = nil end
    if not result.ok then
        panel.note:SetText(result.error and result.error.message or "没有候选。")
        panel.note:Show()
        panel:Show()
        return
    end
    local found
    for _, entry in ipairs(result.slots) do
        if entry.slot == slot.id then found = entry end
    end
    local shown = Sheet.PickTopCandidates(found and found.candidates or {}, gear[slot.id], 3)
    if #shown == 0 then
        panel.note:SetText(found and found.emptyMessage or "这个部位没有候选。")
        panel.note:Show()
    else
        panel.note:Hide()
        for index, candidate in ipairs(shown) do
            local row = panel.rows[index]
            local score = ""
            if candidate.score then
                score = "  " .. NumberText(candidate.score)
            end
            local worn = gear[slot.id] == candidate.id and "  |cff31cee8当前|r" or DiffBadge(candidate)
            local where, gate = Sheet.GateLines(candidate)
            local statsText = Sheet.StatText(CatalogItem(candidate.id) or {})
            local titleText = "|cffffd100" .. index .. "|r  " .. (candidate.name or "?") .. score .. worn
            row.itemName = candidate.name
            row.titleText = titleText
            row.statsText = statsText
            row.detail = Sheet.GateText(candidate)
            row.title:SetText(titleText)
            row.stats:SetText(statsText)
            row.where:SetText(where)
            row.gate:SetText(gate)
            row.itemID = candidate.id
            row:Show()
        end
    end
    panel:Show()
end

local function SyncVisibility()
    local current = CurrentSheet()
    if not current then return end
    if HostVisible() then
        current.Refresh()
    else
        HidePanel(current)
    end
end

local function HookHost(frame)
    if not frame or type(frame.HookScript) ~= "function" then return end
    if not frame.questRouteGearShowHooked then
        if pcall(frame.HookScript, frame, "OnShow", SyncVisibility) then
            frame.questRouteGearShowHooked = true
        end
    end
    if not frame.questRouteGearHideHooked then
        if pcall(frame.HookScript, frame, "OnHide", function()
            local current = CurrentSheet()
            if current then HidePanel(current) end
        end) then
            frame.questRouteGearHideHooked = true
        end
    end
end

function Sheet.Attach()
    local paperDoll = _G.PaperDollFrame
    local charFrame = _G.CharacterFrame
    local host = paperDoll or charFrame
    if not host or type(host.HookScript) ~= "function" then return end
    HookHost(paperDoll)
    if charFrame and charFrame ~= paperDoll then
        HookHost(charFrame)
    end
    if HookStandardSlots() == 0 then
        HookSlots(host, 0)
        if charFrame and charFrame ~= host and type(charFrame.GetChildren) == "function" then
            HookSlots(charFrame, 0)
        end
    end
    SyncVisibility()
end

function Sheet.Shutdown()
    Sheet.InvalidateCache()
    HidePanel(Sheet)
    if Sheet.watcher then
        Sheet.watcher:UnregisterAllEvents()
        Sheet.watcher:SetScript("OnEvent", nil)
    end
end

Sheet.watcher = CreateFrame("Frame")
Sheet.watcher:RegisterEvent("ADDON_LOADED")
Sheet.watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
Sheet.watcher:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
Sheet.watcher:RegisterEvent("PLAYER_LEVEL_UP")
Sheet.watcher:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
Sheet.watcher:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
Sheet.watcher:RegisterEvent("QUEST_TURNED_IN")
Sheet.watcher:RegisterEvent("QUEST_ACCEPTED")
Sheet.watcher:RegisterEvent("QUEST_REMOVED")
Sheet.watcher:SetScript("OnEvent", function(_, event)
    if event == "ADDON_LOADED" or event == "PLAYER_ENTERING_WORLD" then
        Sheet.Attach()
    else
        Sheet.InvalidateCache()
        if HostVisible() then
            Sheet.Refresh()
        else
            HidePanel(Sheet)
        end
    end
end)
