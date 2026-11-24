-- 角色信息面板右侧的单槽前三名。只在玩家打开角色页时出现，数据仍用本地 GearCatalog。
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

local Sheet = { slot = "head" }
ns.GearSheet = Sheet

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

function Sheet.GateText(candidate)
    local source = candidate.sources and candidate.sources[1]
    if not source then return "来源未知" end
    if source.kind == "quest" then
        local gate = source.minLevel and ("可接" .. source.minLevel) or "可接等级未知"
        return (source.name or "任务") .. " · " .. gate
    end
    local gate = source.enterLevel and ("准入" .. source.enterLevel) or "准入未知"
    local where = source.instanceName or "副本"
    if source.temporary then where = where .. "（临时）" end
    return where .. " · " .. gate
end

local function SlotMeta(id)
    for _, slot in ipairs(ORDER) do
        if slot.id == id then return slot end
    end
end

local function Line(parent, template)
    local text = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    text:SetJustifyH("LEFT")
    text:SetWordWrap(true)
    text:SetWidth(188)
    return text
end

local function EnsurePanel(host)
    if Sheet.panel then return end
    local panel = CreateFrame("Frame", nil, host)
    panel:SetSize(206, 176)
    panel:SetPoint("TOPLEFT", host, "TOPRIGHT", 2, -12)
    panel:SetClampedToScreen(true)
    local background = panel:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0, 0, 0, 0.82)
    panel.title = Line(panel, "GameFontNormal")
    panel.title:SetPoint("TOPLEFT", 8, -8)
    panel.spec = CreateFrame("Button", nil, panel)
    panel.spec:SetSize(190, 16)
    panel.spec:SetPoint("TOPLEFT", 8, -28)
    panel.spec.label = Line(panel.spec)
    panel.spec.label:SetAllPoints()
    panel.spec:SetScript("OnClick", function()
        local character = Character()
        if not character or character.classFile ~= "WARRIOR" then return end
        local current = Sheet.manualSpec or character.spec or "防护"
        local nextIndex = 1
        for index, name in ipairs(PLAYSTYLES) do
            if name == current then nextIndex = index % #PLAYSTYLES + 1 end
        end
        Sheet.manualSpec = PLAYSTYLES[nextIndex]
        Sheet.Refresh()
    end)
    panel.rows = {}
    for index = 1, 3 do
        local row = CreateFrame("Button", nil, panel)
        row:SetSize(190, 34)
        row:SetPoint("TOPLEFT", 8, -46 - (index - 1) * 36)
        row.title = Line(row)
        row.title:SetPoint("TOPLEFT")
        row.gate = Line(row)
        row.gate:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -1)
        row:SetScript("OnClick", function()
            if not row.itemID then return end
            print(string.format("|cff31cee8QuestRoute|r %s — %s", row.title:GetText() or "", row.gate:GetText() or ""))
        end)
        panel.rows[index] = row
    end
    panel.note = Line(panel)
    panel.note:SetPoint("TOPLEFT", 8, -50)
    panel.nextSlot = CreateFrame("Button", nil, panel)
    panel.nextSlot:SetSize(70, 16)
    panel.nextSlot:SetPoint("BOTTOMLEFT", 8, 6)
    panel.nextSlot.label = Line(panel.nextSlot)
    panel.nextSlot.label:SetAllPoints()
    panel.nextSlot.label:SetText("下一部位")
    panel.nextSlot:SetScript("OnClick", function()
        local index = 1
        for cursor, slot in ipairs(ORDER) do
            if slot.id == Sheet.slot then index = cursor end
        end
        Sheet.slot = ORDER[index % #ORDER + 1].id
        Sheet.Refresh()
    end)
    Sheet.panel = panel
end

function Sheet.Select(slot)
    if not SlotMeta(slot) then return end
    Sheet.slot = slot
    Sheet.Refresh()
end

local function HookSlots(host, depth)
    if not host or depth > 4 or type(host.GetChildren) ~= "function" then return end
    for _, child in ipairs({ host:GetChildren() }) do
        local slot = child.GetID and INV[child:GetID()]
        if slot and type(child.HookScript) == "function" then
            child.questRouteGear = function() Sheet.Select(slot) end
            if not child.questRouteGearHooked then
                child.questRouteGearHooked = true
                child:HookScript("OnClick", function(button) if button.questRouteGear then button.questRouteGear() end end)
            end
        end
        HookSlots(child, depth + 1)
    end
end

function Sheet.Refresh()
    local host = _G.PaperDollFrame or _G.CharacterFrame
    if not host then return end
    EnsurePanel(host)
    local panel = Sheet.panel
    local slot = SlotMeta(Sheet.slot) or ORDER[1]
    Sheet.slot = slot.id
    local character, problem = Character()
    panel.title:SetText(slot.label .. " · 前三名")
    if not character then
        panel.spec.label:SetText(problem or "角色信息还不可用。")
        panel.note:SetText("")
        panel.note:Hide()
        for _, row in ipairs(panel.rows) do row:Hide() end
        panel:Show()
        return
    end
    local specText = character.level .. "级 " .. character.className
    local shownSpec = Sheet.manualSpec or character.specLabel or character.spec
    if shownSpec then specText = specText .. " · " .. shownSpec end
    if character.classFile == "WARRIOR" then specText = specText .. "  点此换玩法" end
    if character.specNote and not Sheet.manualSpec then specText = specText .. " " .. character.specNote end
    panel.spec.label:SetText(specText)
    local gear = {}
    for inv, id in pairs(INV) do
        if id == slot.id then gear[id] = Worn(inv) end
    end
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
            local score = candidate.score and string.format(" · %.1f", candidate.score) or ""
            local worn = ""
            if gear[slot.id] == candidate.id then worn = " · 当前" end
            row.title:SetText(index .. "  " .. (candidate.name or "?") .. score .. worn)
            row.gate:SetText(Sheet.GateText(candidate))
            row.itemID = candidate.id
            row:Show()
        end
    end
    panel:Show()
end

function Sheet.Attach()
    local host = _G.PaperDollFrame or _G.CharacterFrame
    if not host or type(host.HookScript) ~= "function" then return end
    if not Sheet.hooked then
        Sheet.hooked = true
        host:HookScript("OnShow", function() Sheet.Refresh() end)
        host:HookScript("OnHide", function() if Sheet.panel then Sheet.panel:Hide() end end)
        HookSlots(host, 0)
        if host ~= _G.CharacterFrame and _G.CharacterFrame and type(_G.CharacterFrame.GetChildren) == "function" then
            HookSlots(_G.CharacterFrame, 0)
        end
    end
    if host:IsShown() then Sheet.Refresh() end
end

function Sheet.Shutdown()
    if Sheet.panel then Sheet.panel:Hide() end
    if Sheet.watcher then
        Sheet.watcher:UnregisterAllEvents()
        Sheet.watcher:SetScript("OnEvent", nil)
    end
    Sheet.hooked = nil
end

Sheet.watcher = CreateFrame("Frame")
Sheet.watcher:RegisterEvent("ADDON_LOADED")
Sheet.watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
Sheet.watcher:SetScript("OnEvent", function() Sheet.Attach() end)
