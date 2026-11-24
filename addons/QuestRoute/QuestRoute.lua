-- QuestRoute 入口：命令/API 注册、事件驱动及登录/热重载生命周期。
-- 业务模块按 QuestRoute.toc 顺序先加载；入口最后启动路线。
local _, ns = ...
local InvalidArguments, DistanceSquared, IsFinite = ns.Util.InvalidArguments, ns.Util.DistanceSquared, ns.Util.IsFinite
local RouteSettings, RebuildRoute, UpdateNavigation = ns.RouteOptions.Get, ns.Planner.Rebuild, ns.Navigation.Update
local ConfigureRoutePin, WB = ns.MapPins.Configure, ns.WB
local HideTaskMarkers, RenderTaskNameplates = ns.Nameplates.Hide, ns.Nameplates.Render
local RenderRouteMaps, RenderMinimapRoute = ns.WorldMap.Render, ns.Minimap.Render

local function RouteTick(_, elapsed)
    ns.route.elapsed = (ns.route.elapsed or 0) + elapsed
    if ns.route.elapsed < 0.1 then return end
    ns.route.elapsed = 0
    local now = GetTime()
    if ns.Discovery.Pump() then
        ns.route.dirty, ns.route.due, ns.route.pendingReason = true, now, "association_index_ready"
    end
    if ns.route.dirty and now >= (ns.route.due or 0) then
        RebuildRoute(ns.route.pendingReason or "quest_update")
        if ns.QuestValueSheet then ns.QuestValueSheet.RefreshIfShown() end
    end
    if ns.route.valueSheetDirty and now >= (ns.route.valueSheetDue or 0) then
        ns.route.valueSheetDirty = false
        if ns.QuestValueSheet then ns.QuestValueSheet.RefreshIfShown() end
    end
    if ns.route.nextRewardCheck and now >= ns.route.nextRewardCheck then RebuildRoute("reward_cache_refresh") end
    if ns.route.nextLocationCheck and now >= ns.route.nextLocationCheck then RebuildRoute("location_data_refresh") end
    if ns.route.nextObjectiveCheck and now >= ns.route.nextObjectiveCheck then RebuildRoute("objective_data_refresh") end
    if ns.route.nextAssociationCheck and now >= ns.route.nextAssociationCheck then RebuildRoute("association_data_refresh") end
    if ns.route.nextSpotCheck and now >= ns.route.nextSpotCheck then RebuildRoute("spot_avoidance_expired") end
    if ns.route.nextMapNoticeAt and now >= ns.route.nextMapNoticeAt then RebuildRoute("map_notice_retry") end
    if now >= (ns.route.nextNameplateCheck or 0) then
        ns.route.nextNameplateCheck = now + 0.5
        RenderTaskNameplates()
    end
    if now >= (ns.route.nextPositionCheck or 0) then
        ns.route.nextPositionCheck = now + 0.5
        local context = ns.GetPlayerContext({})
        ns.route.playerLocation = context.location
        local current = ns.route.playerLocation.world
        local distance = DistanceSquared(current, ns.route.lastOrigin)
        local threshold = RouteSettings().moveThreshold
        if ns.Discovery.ObserveUnits() then
            RebuildRoute("pickup_unit_changed")
        elseif ns.route.playerLocation.coordinateMapID ~= ns.route.plan.mapID then
            RebuildRoute("player_map_changed")
        elseif context.character.level ~= ns.route.plan.levelPriority.referenceLevel then
            RebuildRoute("player_level_changed")
        elseif current and (not ns.route.lastOrigin or not distance or distance >= threshold * threshold) then
            RebuildRoute("player_moved")
        else
            local previous = ns.route.plan.navigation
            if UpdateNavigation(ns.route.plan, context.location, now, previous) then
                RebuildRoute(previous and previous.phase == "unavailable" and "player_position_recovered" or "work_protection_ended")
            end
        end
    end
    RenderRouteMaps()
    RenderMinimapRoute()
    if ns.route.hoveredPin and now >= (ns.route.nextTooltipUpdate or 0) then
        ns.route.nextTooltipUpdate = now + 0.5
        local pin = ns.route.hoveredPin
        if pin.step and pin:IsVisible() then pin:GetScript("OnEnter")(pin)
        else ns.route.hoveredPin = nil; GameTooltip:Hide() end
    end
end

function ns.StartRoute()
    if not IsLoggedIn() then return end
    ns.RegisterSettings()
    if ns.route.running then return end
    ns.route.running = true
    -- 工作时间只属于当前UI；热加载也不沿用旧版本未完成的导航计时。
    if ns.route.plan then ns.route.plan.navigation = nil end
    ns.route.lastNavigationEvent, ns.route.workSession, ns.route.suspendedObjectiveSession = nil, nil, nil
    ns.Discovery.ObserveUnits()
    RebuildRoute("startup")
    -- 复用图元时也更新回调，保证热加载后悬停说明使用本轮逻辑。
    for _, view in ipairs(ns.route.views) do
        for _, pin in pairs(view.pins) do ConfigureRoutePin(pin) end
        for _, pin in pairs(view.alternatives or {}) do ConfigureRoutePin(pin) end
        for _, pin in pairs(view.opportunities or {}) do ConfigureRoutePin(pin) end
    end
    if ns.route.minimapView then
        for _, pin in pairs(ns.route.minimapView.pins) do ConfigureRoutePin(pin) end
        for _, pin in pairs(ns.route.minimapView.alternatives or {}) do ConfigureRoutePin(pin) end
        for _, pin in pairs(ns.route.minimapView.opportunities or {}) do ConfigureRoutePin(pin) end
    end
    local driver = ns.route.driver or CreateFrame("Frame")
    ns.route.driver = driver
    driver:UnregisterAllEvents()
    driver:RegisterEvent("QUEST_LOG_UPDATE")
    driver:RegisterEvent("PLAYER_ENTERING_WORLD")
    driver:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    driver:RegisterEvent("QUEST_DATA_LOAD_RESULT")
    driver:RegisterEvent("QUEST_TURNED_IN")
    driver:RegisterEvent("QUEST_ACCEPTED")
    driver:RegisterEvent("QUEST_REMOVED")
    driver:RegisterEvent("PLAYER_LEVEL_UP")
    driver:RegisterEvent("BAG_UPDATE_DELAYED")
    driver:RegisterEvent("GOSSIP_SHOW")
    driver:RegisterEvent("GOSSIP_CLOSED")
    driver:RegisterEvent("GOSSIP_OPTIONS_REFRESHED")
    driver:RegisterEvent("QUEST_GREETING")
    driver:RegisterEvent("QUEST_DETAIL")
    driver:RegisterEvent("QUEST_FINISHED")
    driver:RegisterEvent("UPDATE_FACTION")
    driver:RegisterEvent("SKILL_LINES_CHANGED")
    driver:RegisterEvent("SPELLS_CHANGED")
    driver:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    driver:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    driver:SetScript("OnEvent", function(_, event, questID)
        if event == "NAME_PLATE_UNIT_ADDED" then RenderTaskNameplates(); return end
        if event == "NAME_PLATE_UNIT_REMOVED" then HideTaskMarkers(questID); return end
        if event == "QUEST_DATA_LOAD_RESULT" and ns.route.valuePendingQuestIDs and ns.route.valuePendingQuestIDs[questID] then
            if not ns.route.valueSheetDirty then ns.route.valueSheetDue = GetTime() + 0.4 end
            ns.route.valueSheetDirty = true
        end
        ns.Discovery.ObserveInteraction(event)
        HideTaskMarkers()
        if event == "QUEST_DATA_LOAD_RESULT" and not ((ns.route.activeQuestIDs and ns.route.activeQuestIDs[questID])
            or (ns.route.associationQuestIDs and ns.route.associationQuestIDs[questID])) then return end
        if not ns.route.dirty then ns.route.due = GetTime() + 0.5 end
        ns.route.dirty, ns.route.pendingReason = true, event
    end)
    driver:SetScript("OnUpdate", RouteTick)
    driver:Show()
    RenderTaskNameplates()
    RenderRouteMaps()
    RenderMinimapRoute()
    if ns.GearSheet then ns.GearSheet.Attach() end
    if ns.QuestValueSheet then ns.QuestValueSheet.Attach() end
end

SLASH_QUESTROUTEAPI1 = "/questrouteapi"
SlashCmdList["QUESTROUTEAPI"] = function()
    local result = ns.GetQuests({ includeObjectives = false })
    print("|cffd8a85aQuestRoute|r 当前任务：" .. result.total)
    for _, quest in ipairs(result.quests) do
        print("[" .. quest.questID .. "] " .. quest.title .. " (" .. quest.status .. ")")
    end
end

-- 前三步给出得分构成，让玩家自己看懂"为什么这步在前"；只重排已有字段，不参与规划。
local function PrintStepScores(plan)
    for _, step in ipairs(plan.steps) do
        if step.index > 3 then break end
        local own, effective = step.priorityWeight, nil
        if IsFinite(step.segmentDistance) and IsFinite(step.weightedDistance) and step.weightedDistance > 0 then
            -- 规划得分是“距离÷权重”；weightedDistance 存的是已除过的距离，除回去就是有效权重。
            effective = step.segmentDistance / step.weightedDistance
        end
        local parts = {}
        if effective then parts[#parts + 1] = string.format("有效权重 %.2f", effective) end
        -- 剩余工作量系数已计入权重，单独列出才能看出它是否生效。
        if IsFinite(step.workFactor) and step.workFactor ~= 1 then
            parts[#parts + 1] = string.format("剩余×%.2f", step.workFactor)
        end
        if effective and own and effective > own + 0.001 then parts[#parts + 1] = "含同组加成" end
        local score = IsFinite(step.segmentDistance) and string.format("距离 %.0f 码", step.segmentDistance) or "距离未知"
        local line = step.index .. ". " .. (step.displayTitle or step.title or "?") .. " — " .. score
        if #parts > 0 then line = line .. "（" .. table.concat(parts, "，") .. "）" end
        print(line)
    end
end

-- 玩家主动查询才输出：哪些任务没有上路线及原因，以及当前地图做完后的去向。
local function PrintWhy()
    local plan = ns.GetPlan({})
    local labels, prefix = ns.Planner.exclusionLabels, "|cff31cee8QuestRoute|r "
    print(prefix .. plan.count .. " 步路线；" .. #plan.excluded .. " 个任务未上路线。")
    PrintStepScores(plan)
    for index, item in ipairs(plan.excluded) do
        if index > 8 then print("…另有 " .. (#plan.excluded - 8) .. " 项"); break end
        local why = labels[item.reason] or item.reason
        if item.reason == "outside_current_map" and item.otherMapName then why = why .. "：" .. item.otherMapName end
        print("[" .. item.questID .. "] " .. (item.title or "?") .. " — " .. why)
    end
    local discovery = plan.discovery
    if discovery then
        if discovery.building then print("任务关联索引建立中：" .. (discovery.scanned or 0) .. "/" .. (discovery.total or 0)) end
        for _, field in ipairs({ "opportunities", "announcedOpportunities", "carriedItems" }) do
            for index, item in ipairs(discovery[field] or {}) do
                if index > 5 then break end
                print("关联 [" .. item.questID .. "] " .. ns.Decision.Describe(item, false))
            end
        end
    end
    for _, item in ipairs(discovery and discovery.blocked or {}) do
        local status = ns.Discovery.rejectionLabels[item.reason]
        if status then
            local location = ns.Util.FormatLocation(item.point)
            print("接取核验 [" .. item.questID .. "] " .. item.title .. " — " .. status .. "，接取条件待确认" .. (location and (" · " .. location) or ""))
        end
    end
    local decision = plan.decision
    if decision and decision.applied then print("已采用关联前瞻：先接/先交，再合并同区目标；预测步骤将在实际接取后重算。") end
    local hint = plan.nextMapHint
    if hint then
        print("当前地图已无可做任务，可前往：" .. (hint.mapName or ("地图" .. hint.mapID)) .. (hint.title and ("（" .. hint.title .. "）") or ""))
    end
end

local function PrintAudit(arg)
    if not ns.AnalyzeQuests or not ns.QuestValue then
        print("|cff31cee8QuestRoute|r 任务价值分析模块未加载。")
        return
    end
    local qid = tonumber(arg)
    if qid then
        local result = ns.AnalyzeQuests({ questID = qid })
        if not result.ok then print(result.error and result.error.message or "查询失败"); return end
        local item = result.quests and result.quests[1]
        if not item then
            print("|cff31cee8QuestRoute|r 当前任务日志中未找到任务 [" .. qid .. "]。")
            return
        end
        for _, line in ipairs(ns.QuestValue.FormatQuestDetailLines(item)) do print(line) end
        return
    end
    local showAll = arg == "all"
    local result = ns.AnalyzeQuests({})
    for _, line in ipairs(ns.QuestValue.FormatAuditLines(result, showAll)) do print(line) end
end

SLASH_QUESTROUTE1 = "/questroute"
SlashCmdList["QUESTROUTE"] = function(text)
    local command, value = (text or ""):match("^(%S*)%s*(.-)%s*$")
    local result
    if command == "why" then PrintWhy(); return
    elseif command == "audit" then PrintAudit(value); return
    elseif command == "notice" then
        result = (value == "on" or value == "off") and ns.SetRouteOptions({ switchNotice = value == "on" })
            or InvalidArguments("用法：/questroute notice on/off")
    elseif command == "skip" then result = ns.SetQuestSkip({ questID = tonumber(value) })
    elseif command == "unskip" then
        result = value == "all" and ns.ResetQuestSkips({}) or ns.SetQuestSkip({ questID = tonumber(value), skipped = false })
    elseif command == "distance" then result = ns.SetRouteOptions({ moveThreshold = tonumber(value) or false })
    elseif command == "monsterlevel" then result = ns.SetRouteOptions({ maxMonsterLevelOffset = tonumber(value) or false })
    elseif command == "minlevel" then result = ns.SetRouteOptions({ minPickupLevel = tonumber(value) or false })
    elseif command == "on" or command == "off" then result = ns.SetRouteOptions({ enabled = command == "on" })
    elseif command == "replan" then result = ns.Replan({})
    elseif command == "nextspot" then
        local id
        if value ~= "" then id = tonumber(value) or false end
        result = ns.ChangeQuestSpot({ questID = id })
    elseif command == "resetspots" then
        local id
        if value ~= "" and value ~= "all" then id = tonumber(value) or false end
        result = ns.ClearSpotAvoidances({ questID = id })
    elseif command == "nameplates" then
        result = (value == "on" or value == "off") and ns.SetRouteOptions({ nameplatesEnabled = value == "on" })
            or InvalidArguments("用法：/questroute nameplates on/off")
    else
        local plan = ns.GetPlan({})
        print("|cff31cee8QuestRoute|r " .. plan.count .. " 个目标/交付点（" .. plan.questCount .. " 个任务），移动 " .. plan.moveThreshold .. " 码重排。")
        print("/questroute skip ID · unskip ID/all · distance 100 · replan · on/off")
        print("Shift+右键换地点 · nextspot [ID] · resetspots [ID/all] · nameplates on/off · notice on/off · monsterlevel 0..5 · minlevel 0..60 · why · audit [all|ID]")
        return
    end
    if result.ok then print("|cff31cee8QuestRoute|r " .. (command == "nextspot" and "已换地点，旧点附近避开10分钟。" or "已更新路线。")) else print(result.error.message) end
end

WB:Expose("get_quests", ns.GetQuests,
    "只读获取当前角色所有已接取任务（含折叠分类、隐藏任务和已完成待交任务）。"
    .. "args: offset>=0（默认0），limit=1..100（默认100），includeObjectives=true/false（默认true）。"
    .. "返回角色、total、reportedTotal、logComplete、count、hasMore、nextOffset 和 quests；"
    .. "每项含 questID/title/category/status 及 objectives 目标进度。"
    .. "不包含已交付任务历史或尚未接取任务。")
WB:Expose("get_player_context", ns.GetPlayerContext,
    "只读获取原生玩家等级、经验、地图位置和世界坐标。args:{}。不可用的位置给出reason；不读取生命/能量。")
WB:Expose("get_quest_pois", ns.GetQuestPOIs,
    "只读查询已接任务原生POI。args:可选mapID（只查该图）、questID、offset>=0、limit=1..100（默认50）。"
    .. "未给mapID时扫描艾泽拉斯地图树，去除同任务同位置的投影重复，保留coordinateMapID/reportedMapID和projectionCount；不保证副本覆盖。")
WB:Expose("get_quest_details", ns.GetQuestDetails,
    "原生任务状态、目标和POI为主，QuestieDB元数据/接交关系/任务链独立补充。args:questID必填，"
    .. "allowDatabase=true/false（默认true），includePOIs=true/false（默认true），offset/limit对数据库references分页（默认50/max100）。不推断逐目标序号对应或击杀行为。")
WB:Expose("get_database_entity", ns.GetDatabaseEntity,
    "只读查询QuestieDB实体。args:kind=npc/object/item、id，offset/limit（默认50/max100）。"
    .. "NPC/物件返回locations，物品返回掉落/容器/商人relations；坐标统一0..1，保留AreaID和百分比原值；副本哨兵/无效地图明确不可导航。数据库缺失时available=false。")
WB:Expose("get_quest_targets", ns.GetQuestTargets,
    "只读解析未完成目标位置：官方进度为准，任务内按客户端格式与数据库完整名称精确唯一匹配后补QuestieDB静态点；未知回原生POI。"
    .. "args:questID必填，mapID可选，allowDatabase默认true，offset/limit默认0/50最大100；targets分页，objectives含完成状态与映射依据。")
WB:Expose("get_plan", ns.GetPlan, "获取当前地图任务关联、接取、升级与交付路线。discovery含附近/目的地相关任务和启动物品机会；decision含有限前瞻预测及采用原因；未接目标只在预测中，实际接取后重排。steps.action新增pick_up/start_item，pickupCount给接取步数，activeQuestCount仅统计日志任务。已完成任务按原生位置每项一交付步，不因副本/精英/专业类型排除，手动跳过/失败/外图仍排除；turnInCount和completionPendingCount给交付及等待确认数。navigation给travel/working/turn_in/completion_pending/idle/unavailable，每0.5秒更新，到点不代表交付成功。保留难度/奖励、热点、归组及稳定；自由选点时同组其他步骤计入加成，steps[].workFactor/remainingWork给剩余工作量修正；当前地图无步骤时nextMapHint给最近外图任务提示，excluded[].otherMapID/otherMapName给外图任务所在地图。args:{}。")
WB:Expose("replan", ns.Replan, "主动按当前位置重新选1号并归组，绕过目标保持。采用原生难度/奖励校准的直线距离，不放弃或选择任务。args:{}。")
WB:Expose("set_quest_skip", ns.SetQuestSkip, "标注自己的路线跳过任务，不放弃任务。args:questID，skipped默认true；false恢复。按角色保存。")
WB:Expose("reset_quest_skips", ns.ResetQuestSkips, "恢复当前角色所有手动跳过的任务。args:{}。")
WB:Expose("set_route_options", ns.SetRouteOptions, "自己的路线选项。args:可选moveThreshold=10..5000（默认100码）、maxMonsterLevelOffset=0..5整数（默认2，仅限制任务怪物高出角色的等级）；minPickupLevel=0..60整数（默认15，0关闭，仅过滤低于阈值的未接任务）；enabled同时控制地图/标识、nameplatesEnabled单独控制任务姓名板（默认true）、includeEliteQuests允许未完成精英任务参与规划（默认false）、switchNotice控制1号自动变化/本图做完时的屏幕与聊天提示（默认true），后四项为boolean。按角色保存，立即重排；已完成交付不受怪物等级限制。")
WB:Expose("change_quest_spot", ns.ChangeQuestSpot, "换同一未完目标的本图热点。args:questID可选默认1号；objectiveKey可选需questID。hotspotID可选需同时带questID/objectiveKey，取get_plan.steps[].hotspots[].id以指定备选；省略选其他最近热点。旧点150码内避开600秒，无备选保留路线/跳过。")
WB:Expose("clear_spot_avoidances", ns.ClearSpotAvoidances, "清理本UI临时地点避让并主动重排；args:可选questID，不给则清全部。不改变任务跳过。")
WB:Expose("get_unit_tasks", ns.GetUnitTasks, "只读当前可访问单位的任务用途。args:unit=target/mouseover/nameplateN，默认target。官方进度+唯一核验数据库身份/直接NPC掉落，needed优先；未知/无已知匹配不等于确定无关。战斗身份不可访问时unknown，不延用旧ID。")
WB:Expose("get_gear_candidates", ns.GetGearCandidates,
    "只读查询升级路线里的战斗装备候选。args:level=1..60，class，spec，faction=联盟/部落，可选gear、weights、questLevelWindow、limit=1..100、race。"
    .. "只对战士防护打生存/仇恨启发式分数，其他战士玩法只给未评分候选，其他职业直接拒绝。不使用60级模拟，不把特效和套装算进分数。"
    .. "没有现装时只称候选；现装不在数据集里不比较。衬衣和战袍不参与。数据覆盖和来源限制见 GEAR.md。")
WB:Expose("analyze_quests", ns.AnalyzeQuests,
    "只读分析角色当前任务日志价值，判断哪些任务值得保留或可考虑放弃；绝不自动放弃任务。"
    .. "结合任务链后续与终点奖励、装备与现装对比、经验占比、跨图距离、区域聚集度、完成进度与重接成本给出五档建议"
    .. "（keep_priority/keep/hold_or_drop/recommend_drop/uncertain）。副本与精英仅作中性标签不自动判弃；奖励缓存未就绪时标待确认并触发异步加载。"
    .. "args:可选questID、verdict、includeChain(默认true)、includeGear(默认true)、requestLoad(默认true)、gear、offset、limit。")

function ns.OnUnload()
    if ns.GearSheet then ns.GearSheet.Shutdown() end
    if ns.QuestValueSheet then ns.QuestValueSheet.Shutdown() end
    ns.route.valuePendingQuestIDs = nil
    ns.route.valueSheetDirty = nil
    HideTaskMarkers()
    if ns.settingsUI and ns.settingsUI.owner == ns then
        ns.settingsUI.applyElite, ns.settingsUI.applySwitchNotice, ns.settingsUI.applyNameplates, ns.settingsUI.applyMonsterLevel = nil, nil, nil, nil
        ns.settingsUI.applyPickupLevel = nil
    end
    if ns.route.hoveredPin then ns.route.hoveredPin = nil; GameTooltip:Hide() end
    ns.route.running = false
    if ns.route.driver then ns.route.driver:UnregisterAllEvents(); ns.route.driver:SetScript("OnUpdate", nil); ns.route.driver:SetScript("OnEvent", nil) end
    if ns.loginFrame then ns.loginFrame:UnregisterAllEvents() end
    for _, view in ipairs(ns.route.views) do
        view.overlay:Hide()
        view.sequence = nil
        for _, pin in pairs(view.pins) do pin:Hide(); pin.step = nil end
        for _, pin in pairs(view.alternatives or {}) do pin:Hide(); pin.step, pin.hotspot = nil, nil end
        for _, pin in pairs(view.opportunities or {}) do pin:Hide(); pin.step = nil end
        for _, line in pairs(view.lines) do line:Hide() end
        for _, leader in pairs(view.leaders or {}) do leader:Hide() end
    end
    if ns.route.minimapView then
        local view = ns.route.minimapView
        view.overlay:Hide()
        for _, pin in pairs(view.pins) do pin:Hide(); pin.step = nil end
        for _, pin in pairs(view.alternatives or {}) do pin:Hide(); pin.step, pin.hotspot = nil, nil end
        for _, pin in pairs(view.opportunities or {}) do pin:Hide(); pin.step = nil end
        for _, line in pairs(view.lines) do line:Hide() end
        for _, leader in pairs(view.leaders or {}) do leader:Hide() end
    end
end

function ns.OnReload()
    ns.StartRoute()
    WB:Emit("api.ready", { schemaVersion = 1, apiRevision = ns.apiRevision })
end

-- 正常登录与热加载共用初始化，不依赖在热加载中重发登录事件。
ns.loginFrame = ns.loginFrame or CreateFrame("Frame")
ns.loginFrame:UnregisterAllEvents()
ns.loginFrame:RegisterEvent("PLAYER_LOGIN")
ns.loginFrame:RegisterEvent("ADDON_LOADED")
ns.loginFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then ns.StartRoute()
    elseif IsLoggedIn() then ns.RegisterSettings() end
end)
if IsLoggedIn() then ns.StartRoute() end
