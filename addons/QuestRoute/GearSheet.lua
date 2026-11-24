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

local STATS = {
    { "strength", "力量" }, { "hit", "命中" }, { "crit", "爆击" }, { "stamina", "耐力" },
    { "agility", "敏捷" }, { "dodge", "躲闪" }, { "parry", "招架" }, { "block", "格挡" },
    { "armor", "护甲" }, { "defense", "防御" }, { "blockValue", "格挡值" }, { "attackPower", "攻强" },
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
    if #parts == 0 then return "没有记录到属性" end
    return table.concat(parts, "  ")
end

function Sheet.GateText(candidate)
    local source = candidate.sources and candidate.sources[1]
    if not source then return "来源未知" end
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
        return string.format("%s · %s接 · %s · %s", source.name or "任务", place, chain, gate)
    end
    local boss = source.npc or "掉落者未记录"
    local temp = source.temporary and "（临时）" or ""
    return string.format("%s · %s%s", source.instanceName or "副本", boss, temp)
end

function Sheet.GateLines(candidate)
    local source = candidate.sources and candidate.sources[1]
    if not source then return "来源未知", "" end
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
        return (source.name or "任务") .. " · " .. (source.zone or "地图未知"), chain .. " · " .. level
    end
    return (source.instanceName or "副本") .. " · " .. (source.npc or "首领未记录"), source.temporary and "临时" or ""
end

local function CatalogItem(id)
    local catalog = ns.GearCatalog
    if not catalog then return end
    for _, item in ipairs(catalog.items or {}) do
        if item.id == id then return item end
    end
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

local function Line(parent, template, width)
    local text = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    text:SetWidth(width or 210)
    return text
end

local function Bury(frame)
    if not frame or frame == Sheet.panel then return end
    pcall(function()
        frame:SetAlpha(0)
        frame:Hide()
        frame:SetParent(nil)
        frame.Show = function() end
    end)
end

local function RegionText(region)
    if type(region) ~= "table" or type(region.GetText) ~= "function" then return end
    local ok, text = pcall(function()
        local value = region:GetText()
        if type(value) ~= "string" then return nil end
        return value
    end)
    if ok then return text end
end

local function TextMarksGear(text)
    local ok, matched = pcall(function()
        if type(text) ~= "string" then return false end
        return text == "下一部位" or text == "换玩法"
            or text:find("前三名", 1, true) ~= nil
            or text:find("没有从天赋", 1, true) ~= nil
            or text:find("准入", 1, true) ~= nil
    end)
    return ok and matched or false
end

local function FrameSaysGear(frame)
    if type(frame) ~= "table" or type(frame.GetRegions) ~= "function" then return false end
    local ok, regions = pcall(function() return { frame:GetRegions() } end)
    if not ok or not regions then return false end
    for _, region in ipairs(regions) do
        if TextMarksGear(RegionText(region)) then return true end
    end
    return false
end

local function IsGearPanel(frame)
    if frame == Sheet.panel then return false end
    if type(frame) ~= "table" then return false end
    if frame.questRouteGearPanel then return true end
    if FrameSaysGear(frame) then return true end
    if type(frame.GetChildren) ~= "function" then return false end
    local ok, children = pcall(function() return { frame:GetChildren() } end)
    if not ok or not children then return false end
    for _, child in ipairs(children) do
        if FrameSaysGear(child) then return true end
    end
    return false
end

local function BuryStale()
    local parents = { _G.UIParent, _G.PaperDollFrame, _G.CharacterFrame }
    for _, parent in ipairs(parents) do
        if parent and type(parent.GetChildren) == "function" then
            local ok, children = pcall(function() return { parent:GetChildren() } end)
            if ok and children then
                for _, child in ipairs(children) do
                    if IsGearPanel(child) then Bury(child) end
                end
            end
        end
    end
    if type(EnumerateFrames) ~= "function" then return end
    local frame = EnumerateFrames()
    local guard = 0
    while frame and guard < 12000 do
        guard = guard + 1
        local shown, named = false, true
        pcall(function() shown = frame:IsShown() and true or false end)
        pcall(function() named = frame:GetName() ~= nil end)
        if shown and not named then
            local ok, gear = pcall(IsGearPanel, frame)
            if ok and gear then Bury(frame) end
        end
        frame = EnumerateFrames(frame)
    end
end

local function EnsurePanel(host)
    if Sheet.panel then return end
    local anchor = _G.CharacterFrame or host
    local panel = CreateFrame("Frame", nil, _G.UIParent or anchor)
    panel.questRouteGearPanel = true
    panel:SetSize(330, 348)
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
    panel.title = Line(panel, "GameFontNormal", 250)
    panel.title:SetPoint("TOPLEFT", 8, -7)
    panel.spec = CreateFrame("Button", nil, panel)
    panel.spec:SetSize(28, 16)
    panel.spec:SetPoint("TOPRIGHT", -6, -6)
    panel.spec.label = Line(panel.spec, nil, 28)
    panel.spec.label:SetAllPoints()
    panel.spec.label:SetJustifyH("RIGHT")
    panel.spec.label:SetText("|cffffd100换|r")
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
        row.title = Line(row, "GameFontNormal", 300)
        place(row.title, -10)
        row.stats = Line(row, nil, 300)
        place(row.stats, -28)
        row.where = Line(row, nil, 300)
        place(row.where, -46)
        row.gate = Line(row, nil, 300)
        place(row.gate, -64)
        row:SetScript("OnClick", function()
            if not row.itemID then return end
            print(string.format("|cff31cee8QuestRoute|r %s %s", ItemLink(row.itemID, row.itemName), row.detail or ""))
        end)
        panel.rows[index] = row
    end
    panel.note = Line(panel, nil, 306)
    panel.note:SetPoint("TOPLEFT", 8, -32)
    panel.note:SetWordWrap(true)
    panel.nextSlot = CreateFrame("Button", nil, panel)
    panel.nextSlot:SetSize(88, 16)
    panel.nextSlot:SetPoint("BOTTOMLEFT", 8, 5)
    panel.nextSlot.label = Line(panel.nextSlot, nil, 88)
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

local function CanClick(frame)
    if type(frame.HasScript) ~= "function" or type(frame.HookScript) ~= "function" then return false end
    local ok, yes = pcall(frame.HasScript, frame, "OnClick")
    return ok and yes
end

local function HookSlots(host, depth)
    if not host or depth > 4 or type(host.GetChildren) ~= "function" then return end
    for _, child in ipairs({ host:GetChildren() }) do
        local slot = child.GetID and INV[child:GetID()]
        if slot and CanClick(child) then
            child.questRouteGear = function() Sheet.Select(slot) end
            if not child.questRouteGearHooked then
                local hooked = pcall(child.HookScript, child, "OnClick", function(button)
                    if button.questRouteGear then button.questRouteGear() end
                end)
                child.questRouteGearHooked = hooked
            end
        end
        HookSlots(child, depth + 1)
    end
end

function Sheet.Refresh()
    local host = _G.PaperDollFrame or _G.CharacterFrame
    if not host then return end
    Sheet.sweeps = 1
    BuryStale()
    EnsurePanel(host)
    local panel = Sheet.panel
    local slot = SlotMeta(Sheet.slot) or ORDER[1]
    Sheet.slot = slot.id
    local character, problem = Character()
    local heading = slot.label .. " · 前三名"
    if not character then
        panel.title:SetText(heading)
        panel.spec:Hide()
        panel.note:SetText(problem or "角色信息还不可用。")
        panel.note:Show()
        for _, row in ipairs(panel.rows) do row:Hide() end
        panel:Show()
        return
    end
    local shownSpec = Sheet.manualSpec or character.spec or character.className
    panel.title:SetText(slot.label .. "  " .. character.level .. "  " .. shownSpec)
    if character.classFile == "WARRIOR" then panel.spec:Show() else panel.spec:Hide() end
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
            local score = ""
            if candidate.score then
                score = candidate.score == math.floor(candidate.score) and ("  " .. candidate.score) or string.format("  %.1f", candidate.score)
            end
            local worn = gear[slot.id] == candidate.id and "  当前" or ""
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

function Sheet.Attach()
    local host = _G.PaperDollFrame or _G.CharacterFrame
    if not host or type(host.HookScript) ~= "function" then return end
    BuryStale()
    if not Sheet.hooked then
        Sheet.hooked = true
        host:HookScript("OnShow", function() Sheet.Refresh() end)
        host:HookScript("OnHide", function() if Sheet.panel then Sheet.panel:Hide() end end)
        if host ~= _G.CharacterFrame and _G.CharacterFrame and type(_G.CharacterFrame.HookScript) == "function" then
            _G.CharacterFrame:HookScript("OnHide", function() if Sheet.panel then Sheet.panel:Hide() end end)
        end
        HookSlots(host, 0)
        if host ~= _G.CharacterFrame and _G.CharacterFrame and type(_G.CharacterFrame.GetChildren) == "function" then
            HookSlots(_G.CharacterFrame, 0)
        end
    end
    if host:IsShown() then Sheet.Refresh() end
    Sheet.sweeps = 1
end

function Sheet.Shutdown()
    if Sheet.panel then Sheet.panel:Hide() end
    Sheet.sweeps = 0
    if Sheet.watcher then
        Sheet.watcher:UnregisterAllEvents()
        Sheet.watcher:SetScript("OnEvent", nil)
        Sheet.watcher:SetScript("OnUpdate", nil)
    end
    Sheet.hooked = nil
end

Sheet.watcher = CreateFrame("Frame")
Sheet.watcher:RegisterEvent("ADDON_LOADED")
Sheet.watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
Sheet.watcher:SetScript("OnEvent", function() Sheet.Attach() end)
Sheet.watcher:SetScript("OnUpdate", function()
    local window = _G.CharacterFrame or _G.PaperDollFrame
    if Sheet.panel and window and not window:IsShown() then Sheet.panel:Hide() end
    if not Sheet.sweeps or Sheet.sweeps <= 0 then return end
    Sheet.sweeps = Sheet.sweeps - 1
    BuryStale()
end)
