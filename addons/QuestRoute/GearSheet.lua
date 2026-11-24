-- 角色窗口右侧的单槽前三名。只在玩家打开角色页时出现，数据仍用本地 GearCatalog。
local _, ns = ...

local INV = {
    [1] = "head", [2] = "neck", [3] = "shoulder", [5] = "chest", [6] = "waist",
    [7] = "legs", [8] = "feet", [9] = "wrist", [10] = "hands", [11] = "finger1",
    [12] = "finger2", [13] = "trinket1", [14] = "trinket2", [15] = "back",
    [16] = "mainhand", [17] = "offhand", [18] = "ranged",
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

local function Playstyle(classFile, specName, role)
    if classFile ~= "WARRIOR" then return nil end
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
    local talentName, role = ReadTalent()
    local spec = Sheet.manualSpec or Playstyle(classFile, talentName, role)
    local specNote
    if classFile == "WARRIOR" and not spec then
        spec, specNote = "防护", "没有从天赋判断玩法，先按防护。"
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

local function ReadAllWorn()
    local gear = {}
    for inv, id in pairs(INV) do
        gear[id] = Worn(inv)
    end
    return gear
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

local function CatalogItem(id)
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
    local index = 1
    for cursor, slot in ipairs(ORDER) do
        if slot.id == Sheet.slot then index = cursor end
    end
    local nextIndex = ((index - 1 + delta) % #ORDER) + 1
    Sheet.slot = ORDER[nextIndex].id
    Sheet.Refresh()
end

local function CyclePlaystyle()
    local character = Character()
    if not character or character.classFile ~= "WARRIOR" then return end
    local current = Sheet.manualSpec or character.spec or "防护"
    local nextIndex = 1
    for index, name in ipairs(PLAYSTYLES) do
        if name == current then nextIndex = index % #PLAYSTYLES + 1 end
    end
    Sheet.manualSpec = PLAYSTYLES[nextIndex]
    Sheet.Refresh()
end

local function Line(parent, template, width)
    local text = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    text:SetWidth(width or 210)
    return text
end

local function BindPanelHandlers(panel)
    panel.headerBtn:SetScript("OnClick", function() CyclePlaystyle() end)
    panel.prevSlot:SetScript("OnClick", function() StepSlot(-1) end)
    panel.nextSlot:SetScript("OnClick", function() StepSlot(1) end)
    for _, row in ipairs(panel.rows) do
        row:SetScript("OnClick", function()
            if not row.itemID then return end
            print(string.format("|cff31cee8QuestRoute|r %s %s", ItemLink(row.itemID, row.itemName), row.detail or ""))
        end)
    end
end

local function EnsurePanel(host)
    local anchor = _G.CharacterFrame or host
    local existing = Sheet.panel or _G[PANEL_NAME]
    if existing and existing.rows and existing.headerBtn and existing.prevSlot and existing.nextSlot then
        existing:ClearAllPoints()
        existing:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, -30)
        BindPanelHandlers(existing)
        Sheet.panel = existing
        return
    end
    if existing and type(existing.Hide) == "function" then
        pcall(existing.Hide, existing)
    end
    local panel = CreateFrame("Frame", PANEL_NAME, _G.UIParent or anchor)
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
    if Sheet.slot == slot and Sheet.panel and Sheet.panel:IsShown() then return end
    Sheet.slot = slot
    Sheet.Refresh()
end

local function CanHook(frame, script)
    if type(frame.HasScript) ~= "function" or type(frame.HookScript) ~= "function" then return false end
    local ok, yes = pcall(frame.HasScript, frame, script)
    return ok and yes
end

local function HookSlots(host, depth)
    if not host or depth > 4 or type(host.GetChildren) ~= "function" then return end
    for _, child in ipairs({ host:GetChildren() }) do
        local slot = child.GetID and INV[child:GetID()]
        if slot and CanHook(child, "OnEnter") then
            child.questRouteGearSlot = function() Sheet.Select(slot) end
            if not child.questRouteGearEnterHooked then
                local hooked = pcall(child.HookScript, child, "OnEnter", function(button)
                    if button.questRouteGearSlot then button.questRouteGearSlot() end
                end)
                child.questRouteGearEnterHooked = hooked
            end
        end
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
    if not host then return end
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
    local shownSpec = Sheet.manualSpec or character.spec or character.className
    panel.title:SetText(slot.label .. "  " .. character.level .. "  " .. shownSpec)
    if character.classFile == "WARRIOR" then panel.specHint:Show() else panel.specHint:Hide() end
    local gear = ReadAllWorn()
    local result = ns.GetGearCandidates({
        level = character.level, class = character.className, spec = character.spec or "防护",
        faction = character.faction, gear = gear, limit = 6,
    })
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
    local shown = {}
    for _, candidate in ipairs(found and found.candidates or {}) do
        if not candidate.blocked then shown[#shown + 1] = candidate end
        if #shown == 3 then break end
    end
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
            row.itemName = candidate.name
            row.detail = Sheet.GateText(candidate)
            row.title:SetText("|cffffd100" .. index .. "|r  " .. (candidate.name or "?") .. score .. worn)
            row.stats:SetText(Sheet.StatText(CatalogItem(candidate.id) or {}))
            row.where:SetText(where)
            row.gate:SetText(gate)
            row.itemID = candidate.id
            row:Show()
        end
    end
    panel:Show()
end

local function HostShown()
    local host = _G.PaperDollFrame or _G.CharacterFrame
    return host and type(host.IsShown) == "function" and host:IsShown()
end

function Sheet.Attach()
    local host = _G.PaperDollFrame or _G.CharacterFrame
    if not host or type(host.HookScript) ~= "function" then return end
    if not host.questRouteGearHostHooked then
        host.questRouteGearHostHooked = true
        host:HookScript("OnShow", function()
            if ns.GearSheet then ns.GearSheet.Refresh() end
        end)
        host:HookScript("OnHide", function()
            if ns.GearSheet and ns.GearSheet.panel then ns.GearSheet.panel:Hide() end
        end)
        if host ~= _G.CharacterFrame and _G.CharacterFrame and type(_G.CharacterFrame.HookScript) == "function" then
            _G.CharacterFrame:HookScript("OnHide", function()
                if ns.GearSheet and ns.GearSheet.panel then ns.GearSheet.panel:Hide() end
            end)
        end
    end
    HookSlots(host, 0)
    if host ~= _G.CharacterFrame and _G.CharacterFrame and type(_G.CharacterFrame.GetChildren) == "function" then
        HookSlots(_G.CharacterFrame, 0)
    end
    if HostShown() then Sheet.Refresh() end
end

function Sheet.Shutdown()
    if Sheet.panel then Sheet.panel:Hide() end
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
Sheet.watcher:SetScript("OnEvent", function(_, event)
    if event == "ADDON_LOADED" or event == "PLAYER_ENTERING_WORLD" then
        Sheet.Attach()
    elseif HostShown() then
        Sheet.Refresh()
    end
end)
