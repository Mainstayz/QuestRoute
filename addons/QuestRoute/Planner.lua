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

local function ChooseCandidate(remaining, cursor, anchor, members)
    local bestIndex, bestPoint, bestDistance, bestScore
    for index, candidate in ipairs(remaining) do
        if not members or members[candidate.stepKey] == candidate.quest.status then
            for _, point in ipairs(candidate.points) do
                local localDistance = anchor and DistanceSquared(anchor, point.world)
                if not anchor or (localDistance and localDistance <= routeRules.groupRadius ^ 2) then
                    local distance = DistanceSquared(cursor, point.world)
                    local score = distance and distance / (candidate.priorityWeight * candidate.priorityWeight)
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

local function StableFirst(remaining, origin, mapID, reason, now)
    local bestIndex, bestPoint, bestDistance, bestScore = ChooseCandidate(remaining, origin)
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
        local score = distance / (candidate.priorityWeight * candidate.priorityWeight)
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
        local resolved
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
            end
        end
        TrackProgress(quest, now, options, mapID, origin.world)
        if why then
            if temporaryLocationReasons[why] or why == "spot_data_unavailable" then pendingLocations = pendingLocations + 1 end
            excluded[#excluded + 1] = { questID = id, title = quest.title, reason = why, source = source }
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
    for _, candidate in ipairs(remaining) do candidate.priorityWeight = weights[candidate.quest.questID] end
    -- 奖励缓存可独立于任务信息就绪；只在仍有暂缺数据时轻量重试，避免依赖单一事件。
    ns.route.nextRewardCheck = pendingRewards > 0 and now + 5 or nil
    ns.route.nextLocationCheck = pendingLocations > 0 and now + 5 or nil
    ns.route.nextObjectiveCheck = pendingObjectives > 0 and now + 5 or nil
    ns.route.activeQuestIDs = active
    for id in pairs(ns.route.progress) do if not active[id] then ns.route.progress[id] = nil end end
    ns.route.mobIndex = mobIndex
    local previousNavigation = ns.route.plan and ns.route.plan.navigation
    local firstIndex, firstPoint, firstDistance, firstScore, stability, firstAnchor =
        StableFirst(remaining, origin.world, mapID, reason, now)
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
                        firstScore = firstDistance / (candidate.priorityWeight ^ 2)
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
            bestIndex, bestPoint, bestDistance, bestScore = ChooseCandidate(remaining, cursor)
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
            displayTitle = quest.readyForTurnIn and (quest.title .. "（交任务）")
                or quest.isComplete and (quest.title .. "（等待确认交付）")
                or bestPoint.objective and (quest.title .. " — " .. bestPoint.objective.name) or quest.title,
            status = quest.status, action = quest.readyForTurnIn and "turn_in" or quest.isComplete and "completion_pending" or "quest_area",
            groupIndex = group.index, targetMapID = bestPoint.reportedMapID,
            coordinateMapID = bestPoint.coordinateMapID, x = bestPoint.x, y = bestPoint.y,
            world = bestPoint.world, source = bestPoint.source, precision = bestPoint.precision,
            objectiveKey = bestPoint.objectiveKey, objective = bestPoint.objective,
            hotspots = VisibleHotspots(selected.points, bestPoint),
            entityKind = bestPoint.entityKind, entityID = bestPoint.entityID, relation = bestPoint.relation,
            locationVersion = bestPoint.version, targetMode = selected.resolution and selected.resolution.mode or "native_poi",
            targetReason = selected.resolution and selected.resolution.reason,
            segmentDistance = distance, priorityWeight = selected.priorityWeight, weightedDistance = math.sqrt(bestScore),
            priority = selected.priority,
            objectiveRevision = (TargetProgress(quest.questID, bestPoint.objectiveKey) or {}).revision or 0,
            objectivesAvailable = quest.objectivesLoaded and #quest.objectives > 0,
            navigation = { phase = "queued", label = navigationLabels.queued, protected = false },
        }
        cursor = bestPoint.world
    end
    local taskStepCounts, turnInCount, completionPendingCount = {}, 0, 0
    for _, step in ipairs(steps) do
        taskStepCounts[step.questID] = (taskStepCounts[step.questID] or 0) + 1
        if step.action == "turn_in" then turnInCount = turnInCount + 1
        elseif step.action == "completion_pending" then completionPendingCount = completionPendingCount + 1 end
    end
    for _, step in ipairs(steps) do
        step.groupSize, step.groupQuestCount = groups[step.groupIndex].count, groups[step.groupIndex].questCount
        step.questStepCount = taskStepCounts[step.questID]
    end
    stability.questID, stability.objectiveKey = steps[1] and steps[1].questID, steps[1] and steps[1].objectiveKey
    ns.route.sequence = ns.route.sequence + 1
    ns.route.plan = {
        ok = true, schemaVersion = 1, apiRevision = ns.apiRevision, sequence = ns.route.sequence,
        policy = "stable_grouped_leveling_straight_line", scope = "current_player_map_active_quests",
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
            turnInMinimumExperienceWeight = 0.85 },
        origin = origin, count = #steps, questCount = eligibleQuestCount,
        objectiveStepCount = objectiveStepCount, nativeStepCount = nativeStepCount,
        turnInCount = turnInCount, completionPendingCount = completionPendingCount,
        stepUnit = "unfinished_objective_or_quest", steps = steps, excluded = excluded,
        pendingLocationCount = pendingLocations, locationRetrySeconds = 5,
        moveThreshold = settings.moveThreshold, enabled = settings.enabled, includeEliteQuests = settings.includeEliteQuests,
        totalStraightDistance = pathLength, reason = reason, plannedAt = now,
    }
    UpdateNavigation(ns.route.plan, origin, now, previousNavigation, reason == "manual" or requested ~= nil)
    ns.route.pendingSpotChange = nil
    ns.route.playerLocation, ns.route.lastOrigin = origin, origin.world
    ns.route.dirty, ns.route.pendingReason = false, nil
    WB:Emit("route.updated", { sequence = ns.route.sequence, mapID = mapID, count = #steps, questCount = eligibleQuestCount, reason = reason })
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

ns.Planner = { Rebuild = RebuildRoute }
