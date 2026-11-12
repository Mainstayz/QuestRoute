-- 任务进度历史、工作会话与赶路/工作/交付状态。
local _, ns = ...
local IsFinite, IsID, Accessible = ns.Util.IsFinite, ns.Util.IsID, ns.Util.Accessible
local DistanceSquared, WB = ns.Util.DistanceSquared, ns.WB
local routeRules = {
    groupRadius = 200, arrivalRadius = 120, departureRadius = 180, progressRadius = 300, progressWindow = 90,
    idleTimeout = 180, switchRatio = 0.7, minSaving = 50, poiTolerance = 100,
}
ns.route.progress = ns.route.progress or {}

local function NearbyActivityPoints(points, origin, key)
    local anchors = {}
    for _, point in ipairs(points or {}) do
        local distance = DistanceSquared(origin, point.world)
        if (not key or point.objectiveKey == key) and distance and distance <= routeRules.progressRadius ^ 2 then
            anchors[#anchors + 1] = point.world
        end
    end
    return anchors
end

local function TrackProgress(quest, now, points, mapID, origin)
    local previous = ns.route.progress[quest.questID]
    if quest.status ~= "in_progress" then
        ns.route.progress[quest.questID] = { status = quest.status }
        return
    end
    -- 暂未返回目标数据时保留上次快照，不把重新加载数据当成首次进度。
    if not quest.objectivesLoaded or #quest.objectives == 0 then return end
    local oldKeys = previous and previous.keyed or {}
    local snapshot = { status = quest.status, objectives = {}, revision = previous and previous.revision or 0,
        keyed = not quest.resolvedObjectives and quest.preserveObjectiveHistory and oldKeys or {} }
    for i, objective in ipairs(quest.objectives) do
        local label = Accessible(objective.text)
        if type(label) == "string" then label = label:gsub("%d+%s*/%s*%d+", "#/#") else label = nil end
        snapshot.objectives[i] = {
            label = label, kind = Accessible(objective.type), required = IsFinite(objective.numRequired) and objective.numRequired or nil,
            value = IsFinite(objective.numFulfilled) and objective.numFulfilled or nil,
            finished = Accessible(objective.finished),
            key = quest.resolvedObjectives and quest.resolvedObjectives[i].key,
        }
        local current = snapshot.objectives[i]
        if current.key then
            local prior = oldKeys[current.key]
            current.revision = prior and prior.revision or 0
            if prior and current.kind == prior.kind and current.required == prior.required and current.label == prior.label
                and not (current.value and prior.value and current.value < prior.value)
                and not (current.finished == false and prior.finished == true) then
                local grew = current.value and prior.value and current.value > prior.value
                    or current.finished == true and prior.finished == false
                current.lastProgressAt = grew and now or prior.lastProgressAt
                current.activityMapID = grew and mapID or prior.activityMapID
                current.activityPoints = grew and NearbyActivityPoints(points, origin, current.key) or prior.activityPoints
            elseif prior then current.revision = current.revision + 1 end
            snapshot.keyed[current.key] = current
        end
    end
    local old = previous and previous.status == quest.status and previous.objectives
    if old and #old == #snapshot.objectives then
        local compatible, increased, regressed = true, false, false
        for i, current in ipairs(snapshot.objectives) do
            local prior = old[i]
            if current.kind ~= prior.kind or current.required ~= prior.required or current.label ~= prior.label or current.key ~= prior.key then compatible = false end
            if current.value and prior.value then
                if current.value > prior.value then increased = true end
                if current.value < prior.value then regressed = true end
            end
            if current.finished == true and prior.finished == false then increased = true end
            if current.finished == false and prior.finished == true then regressed = true end
        end
        if compatible and not regressed then
            snapshot.lastProgressAt = increased and now or previous.lastProgressAt
            snapshot.activityMapID = increased and mapID or previous.activityMapID
            snapshot.activityPoints = previous.activityPoints
            if increased then snapshot.activityPoints = NearbyActivityPoints(points, origin) end
        else snapshot.revision = snapshot.revision + 1 end
    elseif old then
        snapshot.revision = snapshot.revision + 1
    end
    ns.route.progress[quest.questID] = snapshot
end

local function TargetProgress(questID, key)
    local progress = ns.route.progress[questID]
    return key and progress and progress.keyed and progress.keyed[key] or (not key and progress or nil)
end

local navigationLabels = {
    travel = "赶路中：前往任务区域", working = "在这一带完成任务目标",
    turn_in = "前往交付任务", completion_pending = "任务已完成，等待确认交付信息",
    queued = "后续任务", idle = "当前地图暂无可规划任务", unavailable = "等待任务或玩家位置更新",
}
local temporaryLocationReasons = { no_native_poi = true, player_position_unavailable = true,
    world_position_unavailable = true, player_map_unavailable = true, spot_data_unavailable = true }
local temporaryObjectiveReasons = { objectives_unavailable = true, objective_state_unavailable = true,
    entity_name_unavailable = true, database_read_error = true }

local function SameWorkTarget(previous, step, mapID)
    local shift = previous and step and DistanceSquared(previous.targetWorld, step.world)
    return previous and step and previous.questID == step.questID and previous.questStatus == step.status
        and previous.mapID == mapID and previous.objectiveKey == step.objectiveKey
        and previous.objectiveRevision == (step.objectiveRevision or 0)
        and shift and shift <= routeRules.poiTolerance ^ 2
end

local function NavigationForStep(step, origin, mapID, now, previous, reset)
    local nav = { phase = "idle", reason = "no_eligible_tasks", observedAt = now, protected = false, mapID = mapID }
    if step then
        nav.questID, nav.questStatus, nav.targetWorld = step.questID, step.status, step.world
        nav.objectiveKey, nav.objective = step.objectiveKey, step.objective
        nav.objectiveRevision = step.objectiveRevision or 0
        nav.objectivesAvailable = step.objectivesAvailable
    end
    local squared = step and DistanceSquared(origin, step.world)
    local same = not reset and SameWorkTarget(previous, step, mapID)
    if not same and not reset and SameWorkTarget(ns.route.workSession, step, mapID) then
        previous, same = ns.route.workSession, true
    end
    if not same and not reset and SameWorkTarget(ns.route.suspendedObjectiveSession, step, mapID) then
        previous, same = ns.route.suspendedObjectiveSession, true
    end
    if not same and not reset and step and not step.objectiveKey and temporaryObjectiveReasons[step.targetReason] then
        local saved = ns.route.suspendedObjectiveSession
        local shift = saved and DistanceSquared(saved.targetWorld, step.world)
        if saved and saved.questID == step.questID and saved.questStatus == step.status and saved.mapID == mapID
            and shift and shift <= routeRules.poiTolerance ^ 2 then previous, same = saved, true end
    end
    if not IsID(mapID) or not origin or (step and not squared) then
        nav.phase, nav.reason = "unavailable", "player_position_unavailable"
        if same then nav.workStartedAt, nav.lastProgressAt = previous.workStartedAt, previous.lastProgressAt end
    elseif step and step.status == "ready_for_turn_in" then
        nav.phase, nav.reason = "turn_in", "official_ready_for_turn_in"
        nav.locationPrecision, nav.deliveryLocationConfirmed = "quest_poi", false
    elseif step and step.status == "complete" then
        nav.phase, nav.reason = "completion_pending", "official_complete_not_ready"
    elseif step then
        local progress = TargetProgress(step.questID, step.objectiveKey)
        local last = progress and progress.lastProgressAt
        if not IsFinite(last) or last > now then last = nil end
        local anchored
        if progress and progress.activityMapID == mapID then
            for _, point in ipairs(progress.activityPoints or {}) do
                local shift = DistanceSquared(point, step.world)
                if shift and shift <= routeRules.poiTolerance ^ 2 then anchored = true; break end
            end
        end
        local recent = anchored and last and now - last <= routeRules.progressWindow
        if not anchored then last = nil end
        local wasWorking = same and (previous.phase == "working"
            or (previous.phase == "unavailable" and IsFinite(previous.workStartedAt)))
        nav.phase, nav.reason = "travel", wasWorking and "left_work_area_or_progress_expired" or "towards_objective_area"
        if squared <= routeRules.arrivalRadius ^ 2 then
            nav.phase, nav.reason = "working", "at_objective_area"
        elseif wasWorking and squared <= routeRules.departureRadius ^ 2 then
            nav.phase, nav.reason = "working", "within_work_area"
        elseif squared <= routeRules.progressRadius ^ 2 and recent then
            nav.phase, nav.reason = "working", "recent_objective_progress"
        end
        nav.lastProgressAt = last
        if nav.phase == "working" then
            nav.workStartedAt = wasWorking and previous.workStartedAt or now
            if not IsFinite(nav.workStartedAt) or nav.workStartedAt > now then nav.workStartedAt = now end
            nav.idleFor = now - math.max(nav.workStartedAt, last or nav.workStartedAt)
            nav.stale = nav.idleFor >= routeRules.idleTimeout - 0.000001
            nav.protected = not nav.stale
            if nav.stale then nav.reason = "no_progress_timeout" end
        end
    end
    if squared then
        nav.distance = math.sqrt(squared)
        nav.atReference = squared <= routeRules.arrivalRadius ^ 2
    end
    nav.label = navigationLabels[nav.phase]
    nav.since = same and previous.phase == nav.phase and previous.since or now
    return nav
end

local function UpdateNavigation(plan, location, now, previous, reset)
    local first = plan.steps[1]
    local temporaryFallback = first and first.targetMode == "native_poi" and temporaryObjectiveReasons[first.targetReason]
    local saved = ns.route.suspendedObjectiveSession
    if reset then ns.route.suspendedObjectiveSession = nil
    elseif temporaryFallback and previous and previous.objectiveKey and previous.workStartedAt
        and previous.questID == first.questID and previous.questStatus == first.status and previous.mapID == location.coordinateMapID then
        ns.route.suspendedObjectiveSession = previous
    elseif saved and (not first or first.questID ~= saved.questID or first.status ~= saved.questStatus
        or location.coordinateMapID ~= saved.mapID) then ns.route.suspendedObjectiveSession = nil end
    local nav = NavigationForStep(first, location.world, location.coordinateMapID, now, previous, reset)
    if not first and (plan.pendingLocationCount or 0) > 0 and nav.phase == "idle" then
        nav.phase, nav.reason, nav.label = "unavailable", "quest_location_unavailable", navigationLabels.unavailable
    end
    local suspended = ns.route.workSession
    local canResume = not first and suspended and suspended.mapID == location.coordinateMapID
        and ns.route.activeQuestIDs and ns.route.activeQuestIDs[suspended.questID]
    if canResume then
        canResume = false
        for _, excluded in ipairs(plan.excluded) do
            if excluded.questID == suspended.questID and temporaryLocationReasons[excluded.reason] then canResume = true; break end
        end
    end
    if nav.workStartedAt then ns.route.workSession = nav
    elseif not canResume or reset then ns.route.workSession = nil end
    if not temporaryFallback then ns.route.suspendedObjectiveSession = nil end
    plan.navigation = nav
    if first then first.navigation = nav end
    local released = previous and nav.phase ~= "unavailable"
        and (previous.phase == "unavailable" or (previous.questID == nav.questID
            and ((previous.protected and not nav.protected) or (previous.phase == "working" and nav.phase == "travel"))))
    local emitted = ns.route.lastNavigationEvent
    if not emitted or emitted.questID ~= nav.questID or emitted.objectiveKey ~= nav.objectiveKey or emitted.phase ~= nav.phase
        or emitted.protected ~= nav.protected or emitted.stale ~= nav.stale then
        WB:Emit("route.navigation_changed", { questID = nav.questID, objectiveKey = nav.objectiveKey, phase = nav.phase, reason = nav.reason,
            protected = nav.protected, stale = nav.stale, distance = nav.distance, mapID = nav.mapID })
        ns.route.lastNavigationEvent = { questID = nav.questID, objectiveKey = nav.objectiveKey, phase = nav.phase, protected = nav.protected, stale = nav.stale }
    end
    return released
end

ns.Navigation = {
    rules = routeRules, labels = navigationLabels,
    temporaryLocationReasons = temporaryLocationReasons, temporaryObjectiveReasons = temporaryObjectiveReasons,
    TrackProgress = TrackProgress, TargetProgress = TargetProgress, ForStep = NavigationForStep, Update = UpdateNavigation,
}
