-- 任务日志右侧的价值分析侧边栏：仅在原生任务日志（QuestMapFrame）可见时显示，
-- 展示任务链后续/最终奖励、独立远图纯经验筛选和清理建议；只读参考，绝不自动放弃任务。
local _, ns = ...

local PANEL_NAME = "QuestRouteValueSheetPanel"
local PAGE_SIZE = 6
local MODES = {
    { id = "all_drop", label = "全部·清理优先", hint = "[全部]" },
    { id = "drop_only", label = "仅建议/可考虑", hint = "[可弃]" },
    { id = "value_first", label = "全部·高价值优先", hint = "[高价值]" },
}

local Sheet = {
    modeIndex = 1,
    page = 1,
    items = {},
}
ns.QuestValueSheet = Sheet

local function CurrentSheet()
    local root = WoWBridgeNS and WoWBridgeNS.QuestRoute
    return (root and root.QuestValueSheet) or ns.QuestValueSheet
end

local function Line(parent, font, width)
    local text = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetWidth(width)
    return text
end

local function HostVisible()
    local host = _G.QuestMapFrame
    if not host then return false end
    if type(host.IsVisible) == "function" then
        local ok, vis = pcall(host.IsVisible, host)
        return ok and vis == true
    end
    if type(host.IsShown) == "function" then
        local ok, shown = pcall(host.IsShown, host)
        return ok and shown == true
    end
    return false
end

function Sheet.FilterAndOrder(quests, modeId)
    local out = {}
    for _, item in ipairs(quests or {}) do
        if modeId ~= "drop_only"
            or item.verdict == "recommend_drop"
            or item.verdict == "hold_or_drop"
            or item.verdict == "uncertain" then
            out[#out + 1] = item
        end
    end
    if modeId == "value_first" then
        table.sort(out, function(a, b)
            if a.verdictRank ~= b.verdictRank then return a.verdictRank > b.verdictRank end
            local aw, bw = a.valueWeight or 0, b.valueWeight or 0
            if aw ~= bw then return aw > bw end
            if a.dropPriority ~= b.dropPriority then return a.dropPriority < b.dropPriority end
            return a.questID < b.questID
        end)
    else
        table.sort(out, function(a, b)
            if a.verdictRank ~= b.verdictRank then return a.verdictRank < b.verdictRank end
            if a.dropPriority ~= b.dropPriority then return a.dropPriority > b.dropPriority end
            local aw, bw = a.valueWeight or 0, b.valueWeight or 0
            if aw ~= bw then return aw < bw end
            return a.questID < b.questID
        end)
    end
    return out
end

function Sheet.CardLines(item)
    local tagStr = item.tags and #item.tags > 0 and (" |cff90caf9" .. table.concat(item.tags, "·") .. "|r") or ""
    local levelStr = item.level and ("|cffaaaaaa" .. item.level .. "|r ") or ""
    local titleLine = string.format("|c%s[%s]|r %s%s%s",
        item.verdictColor or "ffffffff", item.verdictShort or "?", levelStr, item.title or "?", tagStr)
    local rewardColor = item.hasExcellentGear and "|cffffe082" or "|cffe0e0e0"
    local rewardLine = rewardColor .. (item.rewardLine or "") .. "|r"
    local contextLine = "|cffb0b0b0" .. (item.contextLine or "") .. "|r"
    return titleLine, rewardLine, contextLine
end

local function ShowTooltip(row)
    local item = row.item
    if not item or not _G.GameTooltip then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(string.format("|c%s[%s]|r %s（%s级 · #%d）",
        item.verdictColor or "ffffffff", item.verdictLabel or "?", item.title or "?",
        tostring(item.level or "?"), item.questID or 0), 1, 1, 1, true)
    if item.hasExcellentGear then
        local scopeLabel = item.bestGearSource == "direct" and "本步奖励优秀装备"
            or (item.bestGearSource == "chain_terminal" and "任务链终点奖励优秀装备" or "任务链后续奖励优秀装备")
        GameTooltip:AddLine("优先权重：" .. scopeLabel .. "（最高权重）", 1, 0.85, 0.35, true)
    end
    if item.tags and #item.tags > 0 then
        GameTooltip:AddLine("标签：" .. table.concat(item.tags, " / "), 0.6, 0.8, 1, true)
    end
    GameTooltip:AddLine("奖励与链：" .. (item.rewardLine or "-"), 1, 0.9, 0.55, true)
    GameTooltip:AddLine("地点进度：" .. (item.contextLine or "-"), 0.85, 0.85, 0.85, true)
    if item.reasons and #item.reasons > 0 then
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine("判断依据：", 0.95, 0.82, 0.35)
        for i, reason in ipairs(item.reasons) do
            if i > 8 then break end
            GameTooltip:AddLine("· " .. reason, 0.9, 0.9, 0.9, true)
        end
    end
    if item.chain and item.chain.hasFuture and #item.chain.futureQuests > 0 then
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine("后续任务链（共" .. item.chain.remainingSteps .. "步）：", 0.4, 0.85, 1)
        for i, node in ipairs(item.chain.futureQuests) do
            if i > 6 then
                GameTooltip:AddLine("…其余步骤略", 0.7, 0.7, 0.7)
                break
            end
            local rewardNote = node.bestGear and ((node.bestGear.qualityLabel or "装备") .. "「" .. node.bestGear.name .. "」")
                or (node.xp and ("经验" .. node.xp) or "奖励加载中")
            GameTooltip:AddLine(string.format("%d. %s（%s级）— %s",
                node.depth, node.title or "?", tostring(node.level or "?"), rewardNote), 0.85, 0.92, 1, true)
        end
    end
    GameTooltip:AddLine(" ", 1, 1, 1)
    GameTooltip:AddLine("点击输出详情到聊天框 · 不会自动放弃任务", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function RenderPage()
    local panel = Sheet.panel
    if not panel then return end
    local items = Sheet.items or {}
    local total = #items
    local totalPages = math.max(1, math.ceil(total / PAGE_SIZE))
    if Sheet.page > totalPages then Sheet.page = totalPages end
    if Sheet.page < 1 then Sheet.page = 1 end

    local startIndex = (Sheet.page - 1) * PAGE_SIZE
    if total == 0 then
        panel.note:SetText(Sheet.emptyText or "当前筛选下没有任务。")
        panel.note:Show()
    else
        panel.note:Hide()
    end

    for i = 1, PAGE_SIZE do
        local row = panel.rows[i]
        local item = items[startIndex + i]
        if item then
            local line1, line2, line3 = Sheet.CardLines(item)
            row.item = item
            row.title:SetText(line1)
            row.reward:SetText(line2)
            row.context:SetText(line3)
            row:Show()
        else
            row.item = nil
            row:Hide()
        end
    end

    panel.pageLabel:SetText(string.format("%d / %d（共%d）", Sheet.page, totalPages, total))
    if Sheet.page <= 1 then panel.prevBtn:Disable() else panel.prevBtn:Enable() end
    if Sheet.page >= totalPages then panel.nextBtn:Disable() else panel.nextBtn:Enable() end
end
Sheet.RenderPage = RenderPage

local function OpenNativeQuestDetail(questID)
    if type(questID) ~= "number" or questID <= 0 then return end
    if type(InCombatLockdown) == "function" then
        local ok, locked = pcall(InCombatLockdown)
        if ok and locked then return end
    end
    if type(_G.QuestMapFrame_OpenToQuestDetails) == "function" then
        pcall(_G.QuestMapFrame_OpenToQuestDetails, questID)
    end
end

local function BindHandlers(panel)
    panel.modeBtn:SetScript("OnClick", function()
        local current = CurrentSheet()
        if not current then return end
        current.modeIndex = (current.modeIndex % #MODES) + 1
        current.page = 1
        current.Refresh(false)
    end)
    panel.refreshBtn:SetScript("OnClick", function()
        local current = CurrentSheet()
        if current then current.Refresh(true) end
    end)
    panel.prevBtn:SetScript("OnClick", function()
        local current = CurrentSheet()
        if not current or current.page <= 1 then return end
        current.page = current.page - 1
        if type(current.RenderPage) == "function" then current.RenderPage() end
    end)
    panel.nextBtn:SetScript("OnClick", function()
        local current = CurrentSheet()
        if not current then return end
        local maxPage = math.max(1, math.ceil(#(current.items or {}) / PAGE_SIZE))
        if current.page >= maxPage then return end
        current.page = current.page + 1
        if type(current.RenderPage) == "function" then current.RenderPage() end
    end)
    for _, row in ipairs(panel.rows) do
        row:SetScript("OnEnter", function(self) ShowTooltip(self) end)
        row:SetScript("OnLeave", function()
            if _G.GameTooltip then GameTooltip:Hide() end
        end)
        row:SetScript("OnClick", function(self)
            local current = CurrentSheet()
            if not current or not self.item then return end
            OpenNativeQuestDetail(self.item.questID)
            local root = WoWBridgeNS and WoWBridgeNS.QuestRoute
            local qv = (root and root.QuestValue) or ns.QuestValue
            if not qv then return end
            for _, line in ipairs(qv.FormatQuestDetailLines(self.item)) do
                print(line)
            end
        end)
    end
end

local function EnsurePanel(anchor)
    if Sheet.panel then
        Sheet.panel:ClearAllPoints()
        Sheet.panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
        return
    end
    local existing = _G[PANEL_NAME]
    if existing and type(existing.Hide) == "function" then
        pcall(existing.Hide, existing)
    end

    local panel = CreateFrame("Frame", PANEL_NAME, _G.UIParent or anchor)
    panel:SetSize(336, 488)
    panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
    panel:SetClampedToScreen(true)
    if panel.SetFrameStrata then panel:SetFrameStrata("HIGH") end

    local border = panel:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    border:SetColorTexture(0.72, 0.58, 0.22, 0.95)
    local bg = panel:CreateTexture(nil, "BORDER")
    bg:SetPoint("TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", -1, 1)
    bg:SetColorTexture(0.05, 0.04, 0.03, 0.94)

    panel.title = Line(panel, "GameFontNormal", 190)
    panel.title:SetPoint("TOPLEFT", 10, -8)

    panel.modeBtn = CreateFrame("Button", nil, panel)
    panel.modeBtn:SetSize(64, 18)
    panel.modeBtn:SetPoint("TOPRIGHT", -56, -7)
    panel.modeBtn.label = Line(panel.modeBtn, nil, 64)
    panel.modeBtn.label:SetAllPoints()
    panel.modeBtn.label:SetJustifyH("RIGHT")

    panel.refreshBtn = CreateFrame("Button", nil, panel)
    panel.refreshBtn:SetSize(44, 18)
    panel.refreshBtn:SetPoint("TOPRIGHT", -8, -7)
    panel.refreshBtn.label = Line(panel.refreshBtn, nil, 44)
    panel.refreshBtn.label:SetAllPoints()
    panel.refreshBtn.label:SetJustifyH("RIGHT")
    panel.refreshBtn.label:SetText("|cff31cee8[刷新]|r")

    panel.summary = Line(panel, nil, 316)
    panel.summary:SetPoint("TOPLEFT", 10, -28)
    panel.summary:SetHeight(16)
    panel.summary:SetWordWrap(false)

    panel.rows = {}
    for index = 1, PAGE_SIZE do
        local row = CreateFrame("Button", nil, panel)
        row:SetSize(320, 64)
        row:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -48 - (index - 1) * 68)

        local rule = row:CreateTexture(nil, "ARTWORK")
        rule:SetColorTexture(0.72, 0.58, 0.22, 0.38)
        rule:SetSize(320, 1)
        rule:SetPoint("TOPLEFT")

        local function place(text, y)
            text:ClearAllPoints()
            text:SetPoint("TOPLEFT", row, "TOPLEFT", 4, y)
            text:SetHeight(16)
            text:SetWordWrap(false)
            if text.SetMaxLines then text:SetMaxLines(1) end
        end

        row.title = Line(row, "GameFontNormalSmall", 312)
        place(row.title, -7)
        row.reward = Line(row, nil, 312)
        place(row.reward, -25)
        row.context = Line(row, nil, 312)
        place(row.context, -43)
        panel.rows[index] = row
    end

    panel.note = Line(panel, nil, 312)
    panel.note:SetPoint("TOPLEFT", 12, -56)
    panel.note:SetWordWrap(true)

    panel.prevBtn = CreateFrame("Button", nil, panel)
    panel.prevBtn:SetSize(84, 20)
    panel.prevBtn:SetPoint("BOTTOMLEFT", 10, 6)
    panel.prevBtn.label = Line(panel.prevBtn, nil, 84)
    panel.prevBtn.label:SetAllPoints()
    panel.prevBtn.label:SetText("< 上一页")

    panel.pageLabel = Line(panel, nil, 130)
    panel.pageLabel:SetPoint("BOTTOM", 0, 9)
    panel.pageLabel:SetJustifyH("CENTER")

    panel.nextBtn = CreateFrame("Button", nil, panel)
    panel.nextBtn:SetSize(84, 20)
    panel.nextBtn:SetPoint("BOTTOMRIGHT", -10, 6)
    panel.nextBtn.label = Line(panel.nextBtn, nil, 84)
    panel.nextBtn.label:SetAllPoints()
    panel.nextBtn.label:SetJustifyH("RIGHT")
    panel.nextBtn.label:SetText("下一页 >")

    BindHandlers(panel)
    Sheet.panel = panel
end

function Sheet.Invalidate()
    Sheet.lastResult = nil
    Sheet.lastRefreshAt = nil
end

local function ApplyResult(result)
    local panel = Sheet.panel
    if not panel then return end
    local mode = MODES[Sheet.modeIndex] or MODES[1]
    panel.modeBtn.label:SetText("|cffffd100" .. mode.hint .. "|r")

    if not result or not result.ok then
        panel.title:SetText("任务价值分析")
        panel.summary:SetText("|cffff6666无法读取任务日志|r")
        Sheet.items = {}
        Sheet.emptyText = result and result.error and result.error.message or "暂无数据。"
        RenderPage()
        panel:Show()
        return
    end

    local log = result.log
    local capColor = log.pressure == "critical" and "ffff5252"
        or log.pressure == "high" and "ffffb74d" or "ffffd54f"
    panel.title:SetText(string.format("任务价值  |c%s%d/%d|r", capColor, log.count or 0, log.maxCanAccept or 0))

    local s = result.summary
    local pendingNote = s.pendingRewardCount > 0 and ("  |cff90caf9载入中" .. s.pendingRewardCount .. "|r") or ""
    panel.summary:SetText(string.format(
        "|cffff5252弃%d|r · |cffffb74d酌%d|r · |cff66bb6a留%d|r · |cffffd54f优%d|r%s",
        s.recommendDrop or 0, s.holdOrDrop or 0, s.keep or 0, s.keepPriority or 0, pendingNote
    ))

    Sheet.items = Sheet.FilterAndOrder(result.quests, mode.id)
    Sheet.emptyText = mode.id == "drop_only" and "当前没有建议放弃或可考虑放弃的任务。" or "当前任务日志为空。"
    RenderPage()
    panel:Show()
end

function Sheet.Refresh(force)
    local host = _G.QuestMapFrame
    if not host then return end
    if not HostVisible() then
        if Sheet.panel then Sheet.panel:Hide() end
        return
    end
    EnsurePanel(host)
    if not force and Sheet.lastResult and Sheet.lastResult.ok
        and ((Sheet.lastResult.summary and Sheet.lastResult.summary.pendingRewardCount or 0) == 0) then
        ApplyResult(Sheet.lastResult)
        return
    end

    local result = ns.AnalyzeQuests and ns.AnalyzeQuests({ requestLoad = true }) or nil
    if result and result.ok then
        Sheet.lastResult = result
        Sheet.lastRefreshAt = type(GetTime) == "function" and GetTime() or nil
    else
        Sheet.lastResult = nil
    end
    ApplyResult(result)
end

function Sheet.RefreshIfShown()
    if HostVisible() then
        Sheet.Refresh()
    elseif Sheet.panel and Sheet.panel:IsShown() then
        Sheet.panel:Hide()
    end
end

function Sheet.Hide()
    if Sheet.panel then Sheet.panel:Hide() end
end

local function SyncVisibility()
    local current = CurrentSheet()
    if not current then return end
    if HostVisible() then
        local now = type(GetTime) == "function" and GetTime() or nil
        if current.panel and current.panel:IsShown() and current.lastResult
            and current.lastRefreshAt and now and current.lastRefreshAt == now then
            return
        end
        current.Refresh()
    else
        current.Hide()
    end
end

function Sheet.Attach()
    local host = _G.QuestMapFrame
    if not host or type(host.HookScript) ~= "function" then return end
    if not host.questRouteValueHostHooked then
        host.questRouteValueHostHooked = true
        host:HookScript("OnShow", SyncVisibility)
        host:HookScript("OnHide", SyncVisibility)
    end
    local worldMap = _G.WorldMapFrame
    if worldMap and worldMap ~= host and type(worldMap.HookScript) == "function" and not worldMap.questRouteValueMapHooked then
        worldMap.questRouteValueMapHooked = true
        worldMap:HookScript("OnShow", SyncVisibility)
        worldMap:HookScript("OnHide", SyncVisibility)
    end
    SyncVisibility()
end

function Sheet.Shutdown()
    Sheet.Invalidate()
    Sheet.Hide()
    if Sheet.watcher then
        Sheet.watcher:UnregisterAllEvents()
        Sheet.watcher:SetScript("OnEvent", nil)
    end
end

-- 只监听装备、专精、等级与跨图变化；任务日志变化由 QuestRoute.lua 唯一主 driver 转发，避免增加额外驱动框体。
Sheet.watcher = CreateFrame("Frame")
Sheet.watcher:RegisterEvent("ADDON_LOADED")
Sheet.watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
Sheet.watcher:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
Sheet.watcher:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
Sheet.watcher:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
Sheet.watcher:RegisterEvent("PLAYER_LEVEL_UP")
Sheet.watcher:RegisterEvent("ZONE_CHANGED_NEW_AREA")
Sheet.watcher:SetScript("OnEvent", function(_, event)
    if event == "ADDON_LOADED" or event == "PLAYER_ENTERING_WORLD" then
        Sheet.Attach()
    else
        Sheet.Invalidate()
        Sheet.RefreshIfShown()
    end
end)
