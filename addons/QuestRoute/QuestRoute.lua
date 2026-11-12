-- QuestRoute 入口：命令/API 注册、事件驱动及登录/热重载生命周期。
-- 业务模块按 QuestRoute.toc 顺序先加载；入口最后启动路线。
local _, ns = ...
local InvalidArguments, DistanceSquared = ns.Util.InvalidArguments, ns.Util.DistanceSquared
local RouteSettings, RebuildRoute, UpdateNavigation = ns.RouteOptions.Get, ns.Planner.Rebuild, ns.Navigation.Update
local ConfigureRoutePin, WB = ns.MapPins.Configure, ns.WB
local HideTaskMarkers, RenderTaskNameplates = ns.Nameplates.Hide, ns.Nameplates.Render
local RenderRouteMaps, RenderMinimapRoute = ns.WorldMap.Render, ns.Minimap.Render

local function RouteTick(_, elapsed)
    ns.route.elapsed = (ns.route.elapsed or 0) + elapsed
    if ns.route.elapsed < 0.1 then return end
    ns.route.elapsed = 0
    local now = GetTime()
    if ns.route.dirty and now >= (ns.route.due or 0) then RebuildRoute(ns.route.pendingReason or "quest_update") end
    if ns.route.nextRewardCheck and now >= ns.route.nextRewardCheck then RebuildRoute("reward_cache_refresh") end
    if ns.route.nextLocationCheck and now >= ns.route.nextLocationCheck then RebuildRoute("location_data_refresh") end
    if ns.route.nextObjectiveCheck and now >= ns.route.nextObjectiveCheck then RebuildRoute("objective_data_refresh") end
    if ns.route.nextSpotCheck and now >= ns.route.nextSpotCheck then RebuildRoute("spot_avoidance_expired") end
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
        if ns.route.playerLocation.coordinateMapID ~= ns.route.plan.mapID then
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
    RebuildRoute("startup")
    -- 复用图元时也更新回调，保证热加载后悬停说明使用本轮逻辑。
    for _, view in ipairs(ns.route.views) do
        for _, pin in pairs(view.pins) do ConfigureRoutePin(pin) end
        for _, pin in pairs(view.alternatives or {}) do ConfigureRoutePin(pin) end
    end
    if ns.route.minimapView then
        for _, pin in pairs(ns.route.minimapView.pins) do ConfigureRoutePin(pin) end
        for _, pin in pairs(ns.route.minimapView.alternatives or {}) do ConfigureRoutePin(pin) end
    end
    local driver = ns.route.driver or CreateFrame("Frame")
    ns.route.driver = driver
    driver:UnregisterAllEvents()
    driver:RegisterEvent("QUEST_LOG_UPDATE")
    driver:RegisterEvent("PLAYER_ENTERING_WORLD")
    driver:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    driver:RegisterEvent("QUEST_DATA_LOAD_RESULT")
    driver:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    driver:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    driver:SetScript("OnEvent", function(_, event, questID)
        if event == "NAME_PLATE_UNIT_ADDED" then RenderTaskNameplates(); return end
        if event == "NAME_PLATE_UNIT_REMOVED" then HideTaskMarkers(questID); return end
        HideTaskMarkers()
        if event == "QUEST_DATA_LOAD_RESULT" and not (ns.route.activeQuestIDs and ns.route.activeQuestIDs[questID]) then return end
        if not ns.route.dirty then ns.route.due = GetTime() + 0.5 end
        ns.route.dirty, ns.route.pendingReason = true, event
    end)
    driver:SetScript("OnUpdate", RouteTick)
    driver:Show()
    RenderTaskNameplates()
    RenderRouteMaps()
    RenderMinimapRoute()
end

SLASH_QUESTROUTEAPI1 = "/questrouteapi"
SlashCmdList["QUESTROUTEAPI"] = function()
    local result = ns.GetQuests({ includeObjectives = false })
    print("|cffd8a85aQuestRoute|r 当前任务：" .. result.total)
    for _, quest in ipairs(result.quests) do
        print("[" .. quest.questID .. "] " .. quest.title .. " (" .. quest.status .. ")")
    end
end

SLASH_QUESTROUTE1 = "/questroute"
SlashCmdList["QUESTROUTE"] = function(text)
    local command, value = (text or ""):match("^(%S*)%s*(.-)%s*$")
    local result
    if command == "skip" then result = ns.SetQuestSkip({ questID = tonumber(value) })
    elseif command == "unskip" then
        result = value == "all" and ns.ResetQuestSkips({}) or ns.SetQuestSkip({ questID = tonumber(value), skipped = false })
    elseif command == "distance" then result = ns.SetRouteOptions({ moveThreshold = tonumber(value) or false })
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
        print("Shift+右键换地点 · nextspot [ID] · resetspots [ID/all] · nameplates on/off")
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
WB:Expose("get_plan", ns.GetPlan, "获取当前地图升级与交付路线。已完成任务按原生位置每项一交付步，不因副本/精英/专业类型排除，手动跳过/失败/外图仍排除；turnInCount和completionPendingCount给交付及等待确认数。navigation给travel/working/turn_in/completion_pending/idle/unavailable，每0.5秒更新，到点不代表交付成功。保留难度/奖励、热点、归组及稳定。args:{}。")
WB:Expose("replan", ns.Replan, "主动按当前位置重新选1号并归组，绕过目标保持。采用原生难度/奖励校准的直线距离，不放弃或选择任务。args:{}。")
WB:Expose("set_quest_skip", ns.SetQuestSkip, "标注自己的路线跳过任务，不放弃任务。args:questID，skipped默认true；false恢复。按角色保存。")
WB:Expose("reset_quest_skips", ns.ResetQuestSkips, "恢复当前角色所有手动跳过的任务。args:{}。")
WB:Expose("set_route_options", ns.SetRouteOptions, "自己的路线选项。args:可选moveThreshold=10..5000（默认100码）；enabled同时控制地图/标识、nameplatesEnabled单独控制任务姓名板（默认true）、includeEliteQuests允许未完成精英任务参与规划（默认false），后三项为boolean。按角色保存，立即重排；精英开关不影响已完成任务交付及其他过滤。")
WB:Expose("change_quest_spot", ns.ChangeQuestSpot, "换同一未完目标的本图热点。args:questID可选默认1号；objectiveKey可选需questID。hotspotID可选需同时带questID/objectiveKey，取get_plan.steps[].hotspots[].id以指定备选；省略选其他最近热点。旧点150码内避开600秒，无备选保留路线/跳过。")
WB:Expose("clear_spot_avoidances", ns.ClearSpotAvoidances, "清理本UI临时地点避让并主动重排；args:可选questID，不给则清全部。不改变任务跳过。")
WB:Expose("get_unit_tasks", ns.GetUnitTasks, "只读当前可访问单位的任务用途。args:unit=target/mouseover/nameplateN，默认target。官方进度+唯一核验数据库身份/直接NPC掉落，needed优先；未知/无已知匹配不等于确定无关。战斗身份不可访问时unknown，不延用旧ID。")

function ns.OnUnload()
    HideTaskMarkers()
    if ns.settingsUI and ns.settingsUI.owner == ns then ns.settingsUI.applyElite = nil end
    if ns.route.hoveredPin then ns.route.hoveredPin = nil; GameTooltip:Hide() end
    ns.route.running = false
    if ns.route.driver then ns.route.driver:UnregisterAllEvents(); ns.route.driver:SetScript("OnUpdate", nil); ns.route.driver:SetScript("OnEvent", nil) end
    if ns.loginFrame then ns.loginFrame:UnregisterAllEvents() end
    for _, view in ipairs(ns.route.views) do
        view.overlay:Hide()
        view.sequence = nil
        for _, pin in pairs(view.pins) do pin:Hide(); pin.step = nil end
        for _, pin in pairs(view.alternatives or {}) do pin:Hide(); pin.step, pin.hotspot = nil, nil end
        for _, line in pairs(view.lines) do line:Hide() end
        for _, leader in pairs(view.leaders or {}) do leader:Hide() end
    end
    if ns.route.minimapView then
        local view = ns.route.minimapView
        view.overlay:Hide()
        for _, pin in pairs(view.pins) do pin:Hide(); pin.step = nil end
        for _, pin in pairs(view.alternatives or {}) do pin:Hide(); pin.step, pin.hotspot = nil, nil end
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
