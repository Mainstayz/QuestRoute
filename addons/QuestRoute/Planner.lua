-- 候选选择、当前目标稳定与附近归组，生成两图共享的路线快照。
local _, ns = ...
local Util, QuestData, Navigation, Hotspots = ns.Util, ns.QuestData, ns.Navigation, ns.Hotspots
local InvalidArguments, IsID, DistanceSquared, RouteStepKey = Util.InvalidArguments, Util.IsID, Util.DistanceSquared, Util.RouteStepKey
local ReadQuest, ActiveQuestIndex, CollectPOIs = QuestData.ReadQuest, QuestData.ActiveQuestIndex, QuestData.CollectPOIs
local RouteSettings, RouteExclusion = ns.RouteOptions.Get, ns.RouteOptions.Exclusion
local GetDatabase = ns.Database.Get
local ReadObjectiveIdentities, ReadObjectiveLocations = ns.Objectives.ReadIdentities, ns.Objectives.ReadLocations
local ReadLevelingData, RewardReference, ApplyLevelingPriority = ns.Priority.Read, ns.Priority.Reference, ns.Priority.Apply
local routeRules, navigationLabels = Navigation.rules, Navigation.labels
local temporaryLocationReasons, temporaryObjectiveReasons = Navigation.temporaryLocationReasons, Navigation.temporaryObjectiveReasons
local TrackProgress, TargetProgress, NavigationForStep, UpdateNavigation = Navigation.TrackProgress, Navigation.TargetProgress, Navigation.ForStep, Navigation.Update
local hotspotRules, spotRules = Hotspots.rules, Hotspots.spotRules
local BuildHotspots, VisibleHotspots, SpotBlocked = Hotspots.Build, Hotspots.Visible, Hotspots.Blocked
local QuestHasAvoidance, RetireFinishedAvoidances, PruneSpotAvoidances = Hotspots.HasAvoidance, Hotspots.RetireFinished, Hotspots.Prune
local AddNPCGoals, WB = ns.Nameplates.AddGoals, ns.WB
local WorkFactor, FormatDistance, Accessible = ns.Priority.WorkFactor, Util.FormatDistance, Util.Accessible
local Discovery, Decision = ns.Discovery, ns.Decision

local exclusionLabels = {
    skipped = "已手动跳过", failed = "任务已失败", instance = "副本任务", elite = "精英任务（设置中可放开）",
    profession = "专业任务", spots_temporarily_avoided = "地点临时避开中", spot_data_unavailable = "地点数据暂缺",
    no_native_poi = "暂无任务位置", outside_current_map = "目标在其他地图",
    player_position_unavailable = "等待玩家位置", world_position_unavailable = "等待位置数据", player_map_unavailable = "等待玩家地图",
}

-- 格宽取邻域半径的两倍，避免浮点舍入把边界内的点隔开两格；网格只在本轮规划内复用。
local function GroupGrid(remaining)
    if routeRules.groupBonus == 0 then return end
    local grid, size = {}, routeRules.groupRadius * 2
    for _, candidate in ipairs(remaining) do
        for _, point in ipairs(candidate.points) do
            local x, y = math.floor(point.world.x / size), math.floor(point.world.y / size)
            grid[x] = grid[x] or {}
            grid[x][y] = grid[x][y] or {}
            local cell = grid[x][y]
            cell[#cell + 1] = { candidate = candidate, world = point.world }
        end
    end
    return grid
end

-- 邻域查询缩小扫描范围；仍按剩余步骤顺序各计一次，保持原得分与并列选择规则。
local function GroupWeight(remaining, candidate, point, grid)
    local own, bonus, radius = candidate.priorityWeight, 0, routeRules.groupRadius ^ 2
    if not grid or #remaining < 2 then return own end
    local size = routeRules.groupRadius * 2
    local x, y = math.floor(point.world.x / size), math.floor(point.world.y / size)
    local nearby = {}
    for dx = -1, 1 do
        local column = grid[x + dx]
        if column then
            for dy = -1, 1 do
                for _, entry in ipairs(column[y + dy] or {}) do
                    if entry.candidate ~= candidate and not nearby[entry.candidate] then
                        local distance = DistanceSquared(point.world, entry.world)
                        if distance and distance <= radius then nearby[entry.candidate] = true end
                    end
                end
            end
        end
    end
    for _, other in ipairs(remaining) do
        if nearby[other] then bonus = bonus + other.priorityWeight end
    end
    return math.min(own + routeRules.groupBonus * bonus, own * routeRules.groupBonusCap)
end

local function ChooseCandidate(remaining, cursor, anchor, members, grid)
    local bestIndex, bestPoint, bestDistance, bestScore
    for index, candidate in ipairs(remaining) do
        if not members or members[candidate.stepKey] == candidate.quest.status then
            for _, point in ipairs(candidate.points) do
                local localDistance = anchor and DistanceSquared(anchor, point.world)
                if not anchor or (localDistance and localDistance <= routeRules.groupRadius ^ 2) then
                    local distance = DistanceSquared(cursor, point.world)
                    local weight = anchor and candidate.priorityWeight or GroupWeight(remaining, candidate, point, grid)
                    local score = distance and distance / (weight * weight)
                    local prior = bestIndex and remaining[bestIndex]
                    local earlier = prior and (candidate.quest.questID < prior.quest.questID
                        or (candidate.quest.questID == prior.quest.questID and candidate.stepKey < prior.stepKey))
                    if score and (not bestScore or score < bestScore
                        or (score == bestScore and (distance < bestDistance or (distance == bestDistance and earlier)))) then
                        bestIndex, bestPoint, bestDistance, bestScore = index, point, distance, score
                    end
                end
            end
        end
    end
    return bestIndex, bestPoint, bestDistance, bestScore
end

local function StableFirst(remaining, origin, mapID, reason, now, grid)
    local bestIndex, bestPoint, bestDistance, bestScore = ChooseCandidate(remaining, origin, nil, nil, grid)
    local previous = ns.route.plan
    local first = previous and previous.steps[1]
    local decision = { retained = false, reason = reason == "manual" and "manual_replan" or "nearest_weighted" }
    decision.previousQuestID = first and first.questID
    decision.previousObjectiveKey = first and first.objectiveKey
    if not bestIndex or reason == "manual" or not first or previous.mapID ~= mapID then
        return bestIndex, bestPoint, bestDistance, bestScore, decision
    end
    local group = previous.groups and previous.groups[first.groupIndex]
    local previousIndex, previousPoint, previousShift
    for index, candidate in ipairs(remaining) do
        if candidate.quest.questID == first.questID and candidate.quest.status == first.status then
            for _, point in ipairs(candidate.points) do
                local shift = DistanceSquared(first.world, point.world)
                if point.objectiveKey == first.objectiveKey and shift and shift <= routeRules.poiTolerance ^ 2 and (not previousShift or shift < previousShift) then
                    previousIndex, previousPoint, previousShift = index, point, shift
                end
            end
        end
    end
    if previousIndex then
        local candidate = remaining[previousIndex]
        local distance = DistanceSquared(origin, previousPoint.world)
        local previousWeight = GroupWeight(remaining, candidate, previousPoint, grid)
        local score = distance / (previousWeight * previousWeight)
        local oldWeighted, newWeighted = math.sqrt(score), math.sqrt(bestScore)
        local progress = TargetProgress(first.questID, previousPoint.objectiveKey)
        local nav = NavigationForStep({ questID = first.questID, status = candidate.quest.status, world = previousPoint.world,
            objectiveKey = previousPoint.objectiveKey, objectiveRevision = progress and progress.revision or 0 }, origin, mapID, now, previous.navigation)
        local keepReason
        if nav.phase == "working" and nav.protected then
            keepReason = nav.reason
        elseif bestIndex == previousIndex and bestPoint == previousPoint then
            keepReason = "same_target"
        elseif newWeighted > oldWeighted * routeRules.switchRatio + 0.000001
            or oldWeighted - newWeighted < routeRules.minSaving - 0.000001 then
            keepReason = "avoid_small_switch"
        end
        if keepReason then
            decision.retained, decision.reason = true, keepReason
            decision.lastProgressAt = progress and progress.lastProgressAt
            local anchor = group and DistanceSquared(group.anchor, previousPoint.world)
            return previousIndex, previousPoint, distance, score, decision,
                anchor and anchor <= routeRules.groupRadius ^ 2 and group.anchor or nil
        end
        decision.reason = "clearly_better_candidate"
    elseif group then
        -- 原任务交付/完成/消失后，在仍身处原区域时接着做这一批剩余任务。
        local nearby = DistanceSquared(origin, group.anchor)
        if nearby and nearby <= routeRules.progressRadius ^ 2 then
            local members = {}
            local firstKey = RouteStepKey(first.questID, first.objectiveKey)
            for _, step in ipairs(previous.steps) do
                local key = RouteStepKey(step.questID, step.objectiveKey)
                if step.groupIndex == first.groupIndex and key ~= firstKey then members[key] = step.status end
            end
            -- 旧版每任务只有一步时补回未显示的兄弟目标；新版只延续实际属于原组的步骤。
            if first.objectiveKey and not first.stepKey then
                for _, candidate in ipairs(remaining) do
                    if candidate.quest.questID == first.questID and candidate.quest.status == first.status
                        and candidate.objectiveKey and candidate.objectiveKey ~= first.objectiveKey then
                        members[candidate.stepKey] = first.status
                    end
                end
            end
            local index, point, distance, score = ChooseCandidate(remaining, origin, group.anchor, members)
            if index then
                decision.reason = "continue_nearby_group"
                return index, point, distance, score, decision, group.anchor
            end
        end
        decision.reason = "previous_target_changed"
    else
        decision.reason = "previous_target_changed"
    end
    return bestIndex, bestPoint, bestDistance, bestScore, decision
end

local function MapName(mapID)
    local ok, info = pcall(C_Map.GetMapInfo, mapID)
    local name = ok and type(info) == "table" and Accessible(info.name)
    return type(name) == "string" and name or nil
end

-- 任务只有其他地图的位置时，取离玩家最近（同大陆）的一个，仅用于"下一张图"提示，不参与规划。
local function NearestForeignPoint(points, mapID, origin)
    local best
    for _, point in ipairs(points) do
        if IsID(point.reportedMapID) and point.reportedMapID ~= mapID then
            local distance = DistanceSquared(origin, point.world)
            if not best or (distance and (not best.squared or distance < best.squared)) then
                best = { mapID = point.reportedMapID, squared = distance }
            end
        end
    end
    if best then
        best.mapName = MapName(best.mapID)
        best.distance = best.squared and math.sqrt(best.squared) or nil
    end
    return best
end

-- 只在 1 号自动变化（更优候选、原目标完成/消失后的下一站）或当前地图做完时给一行提示；
-- 启动、手动操作、跨图和保护期内保持不提示，同一目标不重复，两次之间有最小间隔。
local noticePrefixes = { clearly_better_candidate = "已改为：", previous_target_changed = "下一站：", continue_nearby_group = "下一站：" }
local quietNoticeReasons = { startup = true, manual = true, quest_skipped = true, quest_restored = true,
    skips_reset = true, options_changed = true, spot_changed = true }

local function NotifyChange(previousPlan, plan, reason, stability, settings, now)
    local first, previousFirst = plan.steps[1], previousPlan and previousPlan.steps[1]
    local previousTarget = ns.route.noticeTarget or previousFirst
    -- 回退期间保留最后一个已知目标，恢复时才能区分同一目标与真正完成后的下一站。
    if first and not first.objectiveKey and previousTarget and previousPlan and previousPlan.mapID == plan.mapID
        and previousTarget.questID == first.questID and previousTarget.action == first.action then
        ns.route.noticeTarget = previousTarget
    else
        ns.route.noticeTarget = first
    end
    if not settings.switchNotice or quietNoticeReasons[reason] then return end
    if not previousPlan or previousPlan.mapID ~= plan.mapID then return end
    local key, text
    if first then
        local prefix = noticePrefixes[stability.reason]
        if not prefix or not previousFirst then return end
        if previousTarget.questID == first.questID and previousTarget.action == first.action
            and (previousTarget.objectiveKey == first.objectiveKey or not previousTarget.objectiveKey or not first.objectiveKey) then return end
        key = first.stepKey .. ":" .. first.action
        local distance = FormatDistance(first.segmentDistance)
        text = "QuestRoute " .. prefix .. first.displayTitle .. (distance and ("（约" .. distance .. "码）") or "")
    else
        local hint = plan.nextMapHint
        if not hint or ((previousPlan.count or 0) == 0 and previousPlan.nextMapHint) then return end
        key = "map:" .. hint.mapID
        text = "QuestRoute 当前地图已无可做任务，可前往：" .. (hint.mapName or ("地图" .. hint.mapID))
            .. (hint.title and ("（" .. hint.title .. "）") or "")
    end
    local last = ns.route.lastNotice
    if last and (last.key == key or now - last.at < routeRules.noticeInterval) then return end
    ns.route.lastNotice = { key = key, at = now }
    Util.Notify(text)
end

local function AssociationSummary(items, selected)
    local summary = {}
    for index, item in ipairs(items or {}) do
        if index <= 25 or selected and selected.questID == item.questID and selected.action == item.action then
            summary[#summary + 1] = item
        end
    end
    return summary
end

local function RebuildRoute(reason)
    local settings = RouteSettings()
    local context = ns.GetPlayerContext({})
    local origin = context.location
    local mapID = origin.coordinateMapID
    local now = GetTime()
    local active = ActiveQuestIndex()
    PruneSpotAvoidances(active, mapID, now)
    local mobIndex = { byNPC = {}, unresolvedQuestCount = 0, observedAt = now }
    local pois = CollectPOIs({}, active)
    local db, dbInfo = GetDatabase()
    local byQuest, excluded, remaining = {}, {}, {}
    local objectiveResolution, locationCache = {}, {}
    local pendingLocations, pendingObjectives = 0, 0
    for _, poi in ipairs(pois) do
        byQuest[poi.questID] = byQuest[poi.questID] or {}
        byQuest[poi.questID][#byQuest[poi.questID] + 1] = poi
    end
    local ids = {}
    for id in pairs(active) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local entry = active[id]
        local quest = ReadQuest(entry.info, entry.category, false)
        local objectivesOK, objectives = pcall(C_QuestLog.GetQuestObjectives, id)
        quest.objectivesLoaded = objectivesOK and type(objectives) == "table"
        quest.objectives = quest.objectivesLoaded and objectives or {}
        local why, source = RouteExclusion(quest, db, settings)
        local options, allLocalPoints, hasLocalPoint, avoidedCount = {}, {}, false, 0
        local resolved, foreign
        if not why then
            local identities = ReadObjectiveIdentities(db, dbInfo, quest)
            AddNPCGoals(mobIndex, db, quest, identities)
            RetireFinishedAvoidances(quest, identities)
            resolved = ReadObjectiveLocations(db, dbInfo, quest, locationCache, identities)
            if db and temporaryObjectiveReasons[resolved.reason] then pendingObjectives = pendingObjectives + 1 end
            quest.resolvedObjectives = resolved.mode == "objective_locations" and resolved.objectives or nil
            quest.preserveObjectiveHistory = temporaryObjectiveReasons[resolved.reason]
            objectiveResolution[#objectiveResolution + 1] = { questID = id, mode = resolved.mode, reason = resolved.reason,
                remainingCount = resolved.remainingCount, pointCount = #resolved.points, version = resolved.version }
            local sourcePoints = resolved.mode == "objective_locations" and resolved.points or byQuest[id] or {}
            if resolved.mode ~= "objective_locations" and quest.status == "in_progress" and QuestHasAvoidance(id, mapID, now) then
                sourcePoints = {}
                why, source = "spot_data_unavailable", "player"
            end
            for _, point in ipairs(sourcePoints) do
                -- 邻图也会返回本图内的投影，归属必须看reportedMapID，不能看坐标边界或查询图。
                if IsID(mapID) and point.reportedMapID == mapID then
                    hasLocalPoint = true
                    if origin.world and point.world and origin.world.continentID == point.world.continentID then
                        allLocalPoints[#allLocalPoints + 1] = point
                        if SpotBlocked(point, id, mapID, now) then avoidedCount = avoidedCount + 1
                        else options[#options + 1] = point end
                    end
                end
            end
            if #options == 0 then
                why = why or avoidedCount > 0 and "spots_temporarily_avoided"
                    or not IsID(mapID) and "player_map_unavailable"
                    or (resolved.mode ~= "objective_locations" and not byQuest[id]) and "no_native_poi"
                    or not hasLocalPoint and "outside_current_map"
                    or not origin.world and "player_position_unavailable" or "world_position_unavailable"
                source = source or "client"
                if why == "outside_current_map" then foreign = NearestForeignPoint(sourcePoints, mapID, origin.world) end
            end
        end
        TrackProgress(quest, now, options, mapID, origin.world)
        if why then
            if temporaryLocationReasons[why] or why == "spot_data_unavailable" then pendingLocations = pendingLocations + 1 end
            local entry = { questID = id, title = quest.title, reason = why, source = source }
            if foreign then
                entry.otherMapID, entry.otherMapName, entry.otherDistance = foreign.mapID, foreign.mapName, foreign.distance
            end
            excluded[#excluded + 1] = entry
        else
            remaining[#remaining + 1] = {
                quest = quest, points = options, allPoints = allLocalPoints, priority = ReadLevelingData(quest), resolution = resolved,
            }
        end
    end
    local taskCandidates = remaining
    -- 经验参照和读取仍按任务各一次；路线改为每个未完目标一个候选，不能因目标多而重复计算奖励。
    local eligibleQuestCount, objectiveStepCount, nativeStepCount = #remaining, 0, 0
    local objectiveCandidates = {}
    for _, candidate in ipairs(remaining) do
        local buckets = {}
        for _, point in ipairs(candidate.allPoints) do
            local key = RouteStepKey(candidate.quest.questID, point.objectiveKey)
            local target = buckets[key]
            if not target then
                target = { quest = candidate.quest, points = {}, priority = candidate.priority,
                    priorityWeight = candidate.priorityWeight, resolution = candidate.resolution,
                    objectiveKey = point.objectiveKey, stepKey = key }
                buckets[key] = target
                objectiveCandidates[#objectiveCandidates + 1] = target
            end
            target.points[#target.points + 1] = point
        end
    end
    remaining = {}
    local eligibleIDs = {}
    for _, candidate in ipairs(objectiveCandidates) do
        local choices = candidate.objectiveKey and BuildHotspots(candidate.points, candidate.stepKey .. ":" .. mapID) or candidate.points
        candidate.points = {}
        for _, point in ipairs(choices) do
            if not SpotBlocked(point, candidate.quest.questID, mapID, now) then candidate.points[#candidate.points + 1] = point end
        end
        if #candidate.points > 0 then
            remaining[#remaining + 1] = candidate
            eligibleIDs[candidate.quest.questID] = true
            if candidate.objectiveKey then objectiveStepCount = objectiveStepCount + 1
            else nativeStepCount = nativeStepCount + 1 end
        end
    end
    eligibleQuestCount = 0
    for _ in pairs(eligibleIDs) do eligibleQuestCount = eligibleQuestCount + 1 end
    local noHotspots = {}
    for _, candidate in ipairs(objectiveCandidates) do
        local id = candidate.quest.questID
        if not eligibleIDs[id] and not noHotspots[id] then
            excluded[#excluded + 1] = { questID = id, title = candidate.quest.title, reason = "spots_temporarily_avoided", source = "player" }
            noHotspots[id] = true
        end
    end
    local eligibleTasks = {}
    for _, candidate in ipairs(taskCandidates) do
        if eligibleIDs[candidate.quest.questID] then eligibleTasks[#eligibleTasks + 1] = candidate end
    end
    local rewardReference, weights = RewardReference(eligibleTasks, context.experience.maximum), {}
    local pendingRewards = 0
    for _, candidate in ipairs(eligibleTasks) do
        ApplyLevelingPriority(candidate, rewardReference)
        weights[candidate.quest.questID] = candidate.priorityWeight
        local why = candidate.priority.experience.reason
        if why == "reward_data_not_ready" or why == "quest_data_not_ready" or why == "read_error" or why == "data_unavailable" then
            pendingRewards = pendingRewards + 1
        end
    end
    -- 剩余工作量只对有键的未完目标做小幅修正；任务级权重和经验参照保持不变。
    for _, candidate in ipairs(remaining) do
        local factor, left = WorkFactor(candidate.quest, candidate.objectiveKey)
        candidate.workFactor, candidate.remainingWork = factor, left
        candidate.priorityWeight = weights[candidate.quest.questID] * factor
    end
    -- 奖励缓存可独立于任务信息就绪；只在仍有暂缺数据时轻量重试，避免依赖单一事件。
    ns.route.nextRewardCheck = pendingRewards > 0 and now + 5 or nil
    ns.route.nextLocationCheck = pendingLocations > 0 and now + 5 or nil
    ns.route.nextObjectiveCheck = pendingObjectives > 0 and now + 5 or nil
    ns.route.activeQuestIDs = active
    for id in pairs(ns.route.progress) do if not active[id] then ns.route.progress[id] = nil end end
    ns.route.mobIndex = mobIndex
    local previousPlan = ns.route.plan
    local previousNavigation = previousPlan and previousPlan.navigation
    local grid = GroupGrid(remaining)
    local firstIndex, firstPoint, firstDistance, firstScore, stability, firstAnchor =
        StableFirst(remaining, origin.world, mapID, reason, now, grid)
    local discovery = Discovery.Collect(context, active, remaining, settings)
    ns.route.associationQuestIDs = discovery.pendingQuestIDs
    ns.route.nextAssociationCheck = (discovery.pendingCount or 0) > 0 and now + 5 or nil
    local baseline = firstIndex and { questID = remaining[firstIndex].quest.questID,
        objectiveKey = firstPoint.objectiveKey, point = firstPoint,
        action = remaining[firstIndex].quest.readyForTurnIn and "turn_in"
            or remaining[firstIndex].quest.isComplete and "completion_pending" or "quest_area" }
    local previousFirst = previousPlan and previousPlan.steps[1]
    local retainedPickup
    if previousFirst and previousPlan.mapID == mapID and reason ~= "manual"
        and (previousFirst.action == "pick_up" or previousFirst.action == "start_item") then
        local quest = discovery.quests[previousFirst.questID]
        if quest and quest.eligibility == "eligible" and not quest.active then
            local point, shift
            if previousFirst.action == "start_item" and quest.startItemID == previousFirst.itemID then point = origin
            elseif previousFirst.action == "pick_up" then
                for _, candidate in ipairs(quest.starters) do
                    local squared = DistanceSquared(previousFirst.world, candidate.world)
                    if squared and squared <= routeRules.poiTolerance ^ 2 and (not shift or squared < shift) then point, shift = candidate, squared end
                end
            end
            if point then
                retainedPickup = { questID = quest.questID, action = previousFirst.action, point = point,
                    itemID = quest.startItemID, certainty = quest.certainty }
                baseline = retainedPickup
            end
        end
    end
    local decision = Decision.Evaluate(discovery, remaining, origin.world, baseline)
    local recommendation = decision.recommendation
    if not recommendation and retainedPickup and decision.reason ~= "baseline_target_unresolved" then
        recommendation, decision.retainedPickup = retainedPickup, true
    end
    local protected = reason ~= "manual" and firstIndex and previousFirst and previousFirst.action == "quest_area"
        and previousFirst.questID == baseline.questID and previousFirst.objectiveKey == baseline.objectiveKey
        and NavigationForStep({ questID = baseline.questID,
        status = remaining[firstIndex].quest.status, objectiveKey = baseline.objectiveKey, world = firstPoint.world,
        objectiveRevision = (TargetProgress(baseline.questID, baseline.objectiveKey) or {}).revision or 0 },
        origin.world, mapID, now, previousNavigation).protected
    if recommendation and not ns.route.pendingSpotChange and not protected then
        local index, point
        if recommendation.action == "pick_up" or recommendation.action == "start_item" then
            local quest = discovery.quests[recommendation.questID]
            point = recommendation.point
            if quest and quest.eligibility == "eligible" and point and point.world then
                local target = {}
                for key, value in pairs(point) do target[key] = value end
                target.coordinateMapID, target.reportedMapID = mapID, mapID
                target.source, target.precision = "QuestieDB", recommendation.action == "start_item" and "inventory_item" or "static_starter"
                target.x, target.y = target.x or origin.x, target.y or origin.y
                point = target
                remaining[#remaining + 1] = { quest = { questID = quest.questID, title = quest.title, level = quest.level,
                    status = "available", objectives = {}, objectivesLoaded = false },
                    action = recommendation.action, points = { point }, priorityWeight = 1, workFactor = 1,
                    stepKey = quest.questID .. ":" .. recommendation.action, certainty = recommendation.certainty,
                    itemID = recommendation.itemID, opportunityReason = decision.reason }
                index = #remaining
            end
        else
            for i, candidate in ipairs(remaining) do
                if candidate.quest.questID == recommendation.questID
                    and (not recommendation.goalKey or candidate.objectiveKey == recommendation.goalKey) then
                    index, point = i, recommendation.point
                    break
                end
            end
        end
        if index and point then
            firstIndex, firstPoint, firstAnchor = index, point, nil
            firstDistance = DistanceSquared(origin.world, point.world)
            firstScore = firstDistance / remaining[index].priorityWeight ^ 2
            stability = { retained = false, reason = "related_quest_plan" }
            decision.applied = true
        end
    elseif recommendation then decision.deferred = protected and "working_target_protected" or "manual_spot_change" end
    local requested = ns.route.pendingSpotChange
    local requestedFound
    if requested then
        for index, candidate in ipairs(remaining) do
            if candidate.quest.questID == requested.questID then
                for _, point in ipairs(candidate.points) do
                    local shift = DistanceSquared(point.world, requested.world)
                    if point.objectiveKey == requested.objectiveKey and shift and shift < 0.000001 then
                        requestedFound = true
                        firstIndex, firstPoint = index, point
                        firstDistance = DistanceSquared(origin.world, point.world)
                        local requestedWeight = GroupWeight(remaining, candidate, point, grid)
                        firstScore = firstDistance / (requestedWeight * requestedWeight)
                        stability = { retained = false, reason = "manual_spot_change", questID = requested.questID }
                        firstAnchor = nil
                    end
                end
            end
        end
    end
    if requested and not requestedFound then
        return { ok = false, error = { code = "target_changed", message = "所选热点已不可用，原路线保留。" } }
    end
    local cursor, steps, groups, pathLength = origin.world, {}, {}, 0
    local group
    while cursor and #remaining > 0 do
        local bestIndex, bestPoint, bestDistance, bestScore
        if #steps == 0 then
            bestIndex, bestPoint, bestDistance, bestScore = firstIndex, firstPoint, firstDistance, firstScore
        elseif group then
            bestIndex, bestPoint, bestDistance, bestScore = ChooseCandidate(remaining, cursor, group.anchor)
        end
        if not bestIndex then
            bestIndex, bestPoint, bestDistance, bestScore = ChooseCandidate(remaining, cursor, nil, nil, grid)
            group = nil
        end
        if not bestIndex then break end
        if not group then
            group = { index = #groups + 1, anchor = #steps == 0 and firstAnchor or bestPoint.world,
                questIDs = {}, count = 0, questCount = 0 }
            if not group.anchor then group.anchor = bestPoint.world end
            groups[#groups + 1] = group
        end
        local selected = table.remove(remaining, bestIndex)
        local quest = selected.quest
        local distance = math.sqrt(bestDistance)
        pathLength = pathLength + distance
        group.count = group.count + 1
        local listed
        for _, id in ipairs(group.questIDs) do if id == quest.questID then listed = true; break end end
        if not listed then group.questIDs[#group.questIDs + 1] = quest.questID; group.questCount = group.questCount + 1 end
        steps[#steps + 1] = {
            index = #steps + 1, stepKey = selected.stepKey, questID = quest.questID, title = quest.title, level = quest.level,
            displayTitle = selected.action == "pick_up" and (quest.title .. "（接任务）")
                or selected.action == "start_item" and (quest.title .. "（使用物品接任务）")
                or quest.readyForTurnIn and (quest.title .. "（交任务）")
                or quest.isComplete and (quest.title .. "（等待确认交付）")
                or bestPoint.objective and (quest.title .. " — " .. bestPoint.objective.name) or quest.title,
            status = quest.status, action = selected.action or (quest.readyForTurnIn and "turn_in" or quest.isComplete and "completion_pending" or "quest_area"),
            certainty = selected.certainty, itemID = selected.itemID, opportunityReason = selected.opportunityReason,
            groupIndex = group.index, targetMapID = bestPoint.reportedMapID,
            coordinateMapID = bestPoint.coordinateMapID, x = bestPoint.x, y = bestPoint.y,
            world = bestPoint.world, source = bestPoint.source, precision = bestPoint.precision,
            objectiveKey = bestPoint.objectiveKey, objective = bestPoint.objective,
            hotspots = VisibleHotspots(selected.points, bestPoint),
            entityKind = bestPoint.entityKind, entityID = bestPoint.entityID, relation = bestPoint.relation,
            locationVersion = bestPoint.version, targetMode = selected.resolution and selected.resolution.mode or "native_poi",
            targetReason = selected.resolution and selected.resolution.reason,
            segmentDistance = distance, priorityWeight = selected.priorityWeight, weightedDistance = math.sqrt(bestScore),
            workFactor = selected.workFactor, remainingWork = selected.remainingWork,
            priority = selected.priority,
            objectiveRevision = (TargetProgress(quest.questID, bestPoint.objectiveKey) or {}).revision or 0,
            objectivesAvailable = quest.objectivesLoaded and #quest.objectives > 0,
            navigation = { phase = "queued", label = navigationLabels.queued, protected = false },
        }
        cursor = bestPoint.world
    end
    local taskStepCounts, turnInCount, completionPendingCount, pickupCount, routeQuestCount = {}, 0, 0, 0, 0
    for _, step in ipairs(steps) do
        taskStepCounts[step.questID] = (taskStepCounts[step.questID] or 0) + 1
        if step.action == "pick_up" or step.action == "start_item" then pickupCount = pickupCount + 1
        elseif step.action == "turn_in" then turnInCount = turnInCount + 1
        elseif step.action == "completion_pending" then completionPendingCount = completionPendingCount + 1 end
    end
    for _ in pairs(taskStepCounts) do routeQuestCount = routeQuestCount + 1 end
    for _, step in ipairs(steps) do
        step.groupSize, step.groupQuestCount = groups[step.groupIndex].count, groups[step.groupIndex].questCount
        step.questStepCount = taskStepCounts[step.questID]
    end
    stability.questID, stability.objectiveKey = steps[1] and steps[1].questID, steps[1] and steps[1].objectiveKey
    -- 暂缺位置或目标数据不能证明本图已做完，等待恢复后再给外图建议。
    local nextMapHint
    if #steps == 0 and origin.world and pendingLocations == 0 and pendingObjectives == 0
        and not discovery.building and (discovery.pendingCount or 0) == 0 then
        local bestDistance
        for _, item in ipairs(excluded) do
            if item.reason == "outside_current_map" and IsID(item.otherMapID)
                and (not nextMapHint or (item.otherDistance and (not bestDistance or item.otherDistance < bestDistance))) then
                nextMapHint = { questID = item.questID, title = item.title, mapID = item.otherMapID, mapName = item.otherMapName }
                bestDistance = item.otherDistance or bestDistance
            end
        end
    end
    ns.route.sequence = ns.route.sequence + 1
    ns.route.plan = {
        ok = true, schemaVersion = 1, apiRevision = ns.apiRevision, sequence = ns.route.sequence,
        policy = "stable_grouped_precedence_lookahead", scope = "current_player_map_active_and_available_quests",
        discovery = { available = discovery.available, source = "QuestieDB", reason = discovery.reason,
            building = discovery.building, scanned = discovery.scanned, total = discovery.total, pendingCount = discovery.pendingCount,
            opportunityTotal = #(discovery.opportunities or {}), blockedTotal = #(discovery.blocked or {}), summaryLimit = 25,
            opportunities = AssociationSummary(discovery.opportunities, steps[1]), blocked = AssociationSummary(discovery.blocked) }, decision = decision,
        groups = groups, groupRadius = routeRules.groupRadius, stability = stability,
        spotRules = { radius = spotRules.radius, duration = spotRules.duration }, avoidedSpots = ns.route.spotAvoidances,
        hotspotRules = { radius = hotspotRules.radius, separation = hotspotRules.separation, maxDisplayed = hotspotRules.maxDisplayed,
            deduplicateRadius = hotspotRules.deduplicateRadius, algorithm = hotspotRules.algorithm, alternativesJoinRoute = false },
        nameplates = { enabled = settings.enabled and settings.nameplatesEnabled ~= false,
            unresolvedQuestCount = mobIndex.unresolvedQuestCount, source = "client_progress_QuestieDB_relations" },
        objectiveResolution = objectiveResolution, pendingObjectiveCount = pendingObjectives, objectiveRetrySeconds = 5,
        navigationRules = { arrivalRadius = routeRules.arrivalRadius, departureRadius = routeRules.departureRadius,
            progressRadius = routeRules.progressRadius, progressWindow = routeRules.progressWindow, idleTimeout = routeRules.idleTimeout },
        mapID = mapID, mapName = origin.mapName,
        levelPriority = { referenceLevel = context.character.level, perLevelBonus = 0, maxWeight = 1.25,
            method = "client_difficulty_and_reward" },
        levelingPriority = { source = "client", reference = rewardReference,
            difficultyWeights = { trivial = 0.4, easy = 1.25, fair = 1, difficult = 0.65, impossible = 0.4 },
            rewardThresholds = { veryLowRatio = 0.25, lowRatio = 0.5, veryLowLevelFraction = 0.005, lowLevelFraction = 0.01 },
            pendingRewardCount = pendingRewards, rewardRetrySeconds = 5, unknownWeight = 1,
            turnInMinimumExperienceWeight = 0.85,
            workFactorBands = ns.Priority.workBands, groupBonus = routeRules.groupBonus, groupBonusCap = routeRules.groupBonusCap },
        nextMapHint = nextMapHint, switchNotice = settings.switchNotice,
        origin = origin, count = #steps, questCount = routeQuestCount, activeQuestCount = eligibleQuestCount, pickupCount = pickupCount,
        objectiveStepCount = objectiveStepCount, nativeStepCount = nativeStepCount,
        turnInCount = turnInCount, completionPendingCount = completionPendingCount,
        stepUnit = pickupCount > 0 and "unfinished_objective_quest_or_pickup" or "unfinished_objective_or_quest", steps = steps, excluded = excluded,
        pendingLocationCount = pendingLocations, locationRetrySeconds = 5,
        moveThreshold = settings.moveThreshold, enabled = settings.enabled, includeEliteQuests = settings.includeEliteQuests,
        totalStraightDistance = pathLength, reason = reason, plannedAt = now,
    }
    UpdateNavigation(ns.route.plan, origin, now, previousNavigation, reason == "manual" or requested ~= nil)
    if not Decision.Notify(ns.route.plan, previousPlan, settings, now) then
        NotifyChange(previousPlan, ns.route.plan, reason, stability, settings, now)
    end
    ns.route.pendingSpotChange = nil
    ns.route.playerLocation, ns.route.lastOrigin = origin, origin.world
    ns.route.dirty, ns.route.pendingReason = false, nil
    WB:Emit("route.updated", { sequence = ns.route.sequence, mapID = mapID, count = #steps, questCount = routeQuestCount,
        pickupCount = pickupCount, reason = reason })
    return ns.route.plan
end

function ns.GetPlan(args)
    if args ~= nil and type(args) ~= "table" then return InvalidArguments("args must be an object") end
    return ns.route.plan or RebuildRoute("requested")
end

function ns.Replan(args)
    if args ~= nil and type(args) ~= "table" then return InvalidArguments("args must be an object") end
    return RebuildRoute("manual")
end

ns.Planner = { Rebuild = RebuildRoute, exclusionLabels = exclusionLabels }
