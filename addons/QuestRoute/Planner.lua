-- 候选选择、当前目标稳定与附近归组，生成两图共享的路线快照。
local _, ns = ...
local Util, QuestData, Navigation, Hotspots = ns.Util, ns.QuestData, ns.Navigation, ns.Hotspots
local InvalidArguments, IsID, DistanceSquared, RouteStepKey = Util.InvalidArguments, Util.IsID, Util.DistanceSquared, Util.RouteStepKey
local ReadQuest, ActiveQuestIndex, CollectPOIs = QuestData.ReadQuest, QuestData.ActiveQuestIndex, QuestData.CollectPOIs
local RouteSettings, RouteExclusion = ns.RouteOptions.Get, ns.RouteOptions.Exclusion
local GetDatabase = ns.Database.Get
local ReadObjectiveIdentities, ReadObjectiveLocations = ns.Objectives.ReadIdentities, ns.Objectives.ReadLocations
local ReadLevelingData, RewardReference, ApplyLevelingPriority = ns.Priority.Read, ns.Priority.Reference, ns.Priority.Apply
local difficultyBands, weightBounds = ns.Priority.difficultyBands, ns.Priority.weightBounds
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
    profession = "专业任务", target_above_level = "所需目标怪超过设置的等级上限，升级或调整设置后再做",
    spots_temporarily_avoided = "地点临时避开中", spot_data_unavailable = "地点数据暂缺",
    no_native_poi = "暂无任务位置", outside_current_map = "目标在其他地图",
    player_position_unavailable = "等待玩家位置", world_position_unavailable = "等待位置数据", player_map_unavailable = "等待玩家地图",
}

-- 快照里的难度权重直接来自 Priority 的客户端难度分档，避免两处改值漂移。
local difficultyWeights = {}
for code = 0, 4 do local band = difficultyBands[code]; difficultyWeights[band.name] = band.weight end

-- 单次重建失败后的统一重试间隔；失败不逐帧重试，也不打断既有路线。
local rebuildRetrySeconds = 5

-- 失败退避：nextRebuildRetry 到点之前，自动触发源（四类复查计时器、spot_avoidance_expired、map_notice_retry、
-- player_moved/player_map_changed/player_level_changed/player_position_recovered/work_protection_ended、
-- pickup_unit_changed、association_index_ready、quest_update 与各游戏事件合并出的重建）一律不再启动 BuildPlan，
-- 避免玩家持续移动时每 0.5 秒重复失败。被拦截的触发不丢意图：dirty 与各复查计时器保持不动，
-- 到点后由 rebuild_retry（或同一 tick 内先到的触发）统一重做；重试成功才清 nextRebuildRetry。
-- 放行集合是玩家或系统明确要求的重建：重试本身、启动、手动 Replan/API 读取、跳过/恢复/重置、设置变更、换热点。
local manualRebuildReasons = { rebuild_retry = true, startup = true, manual = true, requested = true,
    quest_skipped = true, quest_restored = true, skips_reset = true, options_changed = true, spot_changed = true }

-- 耗时只做观测：夹具或客户端缺少 debugprofilestop 时返回 nil，计时代码自身绝不抛错（否则会被误判为重建失败）。
local function ProfileClock()
    if type(debugprofilestop) ~= "function" then return nil end
    local ok, value = pcall(debugprofilestop)
    if ok and Util.IsFinite(value) then return value end
end

-- 重建计数写在 ns.route.stats（不进入 plan，也不触碰 sequence），静默路径与失败路径同样计数。
-- total = 实际执行 BuildPlan 的次数（含失败尝试；被失败退避拦截的不计，记入 suppressed）。
-- total = ok + failed + declined；quiet 是 ok 的子集（路线内容未变、沿用旧计划）；
-- declined 是 BuildPlan 有意返回的 ok=false（如所选热点已失效），不算故障。
local function RecordRebuild(reason, started, outcome, quiet)
    local stats = ns.route.stats
    if not stats then return end
    stats.total = (stats.total or 0) + 1
    stats[outcome] = (stats[outcome] or 0) + 1
    if quiet then stats.quiet = (stats.quiet or 0) + 1 end
    stats.byReason = stats.byReason or {}
    local key = tostring(reason or "unknown")
    stats.byReason[key] = (stats.byReason[key] or 0) + 1
    stats.lastAt = GetTime()
    local finished = started and ProfileClock()
    if finished and finished >= started then
        stats.lastMs = finished - started
        if not stats.maxMs or stats.lastMs > stats.maxMs then stats.maxMs = stats.lastMs end
    else
        stats.lastMs = nil
    end
end

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
                local fallback = not point.objectiveKey and candidate.resolution and temporaryObjectiveReasons[candidate.resolution.reason]
                if (point.objectiveKey == first.objectiveKey or fallback) and shift and shift <= routeRules.poiTolerance ^ 2
                    and (not previousShift or shift < previousShift) then
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
            objectiveKey = previousPoint.objectiveKey, objectiveRevision = progress and progress.revision or 0,
            targetReason = candidate.resolution and candidate.resolution.reason }, origin, mapID, now, previous.navigation)
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
-- 这些重建是在等缓存。路线没变时不发 route.updated，并把下一次复查推到 30 秒，避免每 5 秒空转一次。
local quietRefreshReasons = { location_data_refresh = true, objective_data_refresh = true, reward_cache_refresh = true,
    association_data_refresh = true, QUEST_DATA_LOAD_RESULT = true, association_index_ready = true }

local function WeightKey(step)
    local weight = step.priorityWeight
    if type(weight) ~= "number" then return "" end
    return string.format("%.2f", weight)
end

local function WorldKey(world)
    if type(world) ~= "table" or type(world.x) ~= "number" or type(world.y) ~= "number" then return "" end
    return string.format("%s:%.1f:%.1f", tostring(world.continentID or ""), world.x, world.y)
end

local function ListKey(items, first, second, third)
    local parts = {}
    for _, item in ipairs(items or {}) do
        parts[#parts + 1] = tostring(item[first] or "") .. ":" .. tostring(item[second] or "")
            .. ":" .. tostring(third and item[third] or "")
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function StepsSame(previous, plan)
    if previous.mapID ~= plan.mapID or (previous.pendingLocationCount or 0) ~= (plan.pendingLocationCount or 0)
        or (previous.pendingObjectiveCount or 0) ~= (plan.pendingObjectiveCount or 0) then return false end
    local oldRewards = previous.levelingPriority and previous.levelingPriority.pendingRewardCount or 0
    local newRewards = plan.levelingPriority and plan.levelingPriority.pendingRewardCount or 0
    if oldRewards ~= newRewards then return false end
    local oldHint = previous.nextMapHint and previous.nextMapHint.mapID or nil
    local newHint = plan.nextMapHint and plan.nextMapHint.mapID or nil
    if oldHint ~= newHint or #previous.steps ~= #plan.steps or #(previous.excluded or {}) ~= #(plan.excluded or {}) then return false end
    for index, step in ipairs(plan.steps) do
        local old = previous.steps[index]
        local oldReason = old.priority and old.priority.reason
        local newReason = step.priority and step.priority.reason
        if old.questID ~= step.questID or old.action ~= step.action or old.objectiveKey ~= step.objectiveKey
            or old.status ~= step.status or (old.objectiveRevision or 0) ~= (step.objectiveRevision or 0)
            or oldReason ~= newReason or WeightKey(old) ~= WeightKey(step)
            or WorldKey(old.world) ~= WorldKey(step.world) then return false end
    end
    for index, item in ipairs(plan.excluded or {}) do
        local old = previous.excluded[index]
        if old.questID ~= item.questID or old.reason ~= item.reason then return false end
    end
    return true
end

local function RouteSame(previous, plan)
    if not StepsSame(previous, plan) then return false end
    local oldDiscovery, newDiscovery = previous.discovery or {}, plan.discovery or {}
    if (oldDiscovery.pendingCount or 0) ~= (newDiscovery.pendingCount or 0)
        or (oldDiscovery.pendingLocationCount or 0) ~= (newDiscovery.pendingLocationCount or 0)
        or (oldDiscovery.building == true) ~= (newDiscovery.building == true) then return false end
    if ListKey(oldDiscovery.opportunities, "questID", "action") ~= ListKey(newDiscovery.opportunities, "questID", "action")
        or ListKey(oldDiscovery.blocked, "questID", "reason") ~= ListKey(newDiscovery.blocked, "questID", "reason")
        or ListKey(oldDiscovery.carriedItems, "questID", "itemID", "action") ~= ListKey(newDiscovery.carriedItems, "questID", "itemID", "action")
        or ListKey(oldDiscovery.announcedOpportunities, "questID", "action") ~= ListKey(newDiscovery.announcedOpportunities, "questID", "action") then
        return false
    end
    return true
end

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
        if not hint or ((previousPlan.count or 0) == 0 and previousPlan.nextMapHint and not ns.route.nextMapNoticeAt) then return end
        key = "map:" .. hint.mapID
        text = "QuestRoute 当前地图已无可做任务，可前往：" .. (hint.mapName or ("地图" .. hint.mapID))
            .. (hint.title and ("（" .. hint.title .. "）") or "")
    end
    local last = ns.route.lastNotice
    if last and last.key == key then ns.route.nextMapNoticeAt = nil; return end
    if last and now - last.at < routeRules.noticeInterval then
        if not first then ns.route.nextMapNoticeAt = last.at + routeRules.noticeInterval end
        return
    end
    ns.route.nextMapNoticeAt = nil
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

local function BuildPlan(reason)
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
    -- 刷新点展开结果跨次缓存（绑定 db 身份，见 Objectives.SharedLocationCache）；不再每次重建新建。
    local objectiveResolution, locationCache = {}, ns.Objectives.SharedLocationCache(db, dbInfo)
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
            resolved = ReadObjectiveLocations(db, dbInfo, quest, locationCache, identities, context.character.level)
            if db and temporaryObjectiveReasons[resolved.reason] then pendingObjectives = pendingObjectives + 1 end
            quest.resolvedObjectives = resolved.mode == "objective_locations" and resolved.objectives or nil
            quest.preserveObjectiveHistory = temporaryObjectiveReasons[resolved.reason]
            objectiveResolution[#objectiveResolution + 1] = { questID = id, mode = resolved.mode, reason = resolved.reason,
                remainingCount = resolved.remainingCount, pointCount = #resolved.points, version = resolved.version }
            local sourcePoints = resolved.mode == "objective_locations" and resolved.points or byQuest[id] or {}
            if resolved.mode ~= "objective_locations" and resolved.unsafeSourcesExcluded then
                sourcePoints = {}
                why, source = temporaryObjectiveReasons[resolved.reason] and "world_position_unavailable" or "target_above_level", "QuestieDB"
            end
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
    local requested = ns.route.pendingSpotChange or reason ~= "manual" and ns.route.manualSpot
    local requestedFound
    ns.route.manualSpot = nil
    if requested and (not requested.mapID or requested.mapID == mapID)
        and (not requested.expiresAt or now < requested.expiresAt) then
        for index, candidate in ipairs(remaining) do
            if candidate.quest.questID == requested.questID and candidate.quest.status == "in_progress" then
                for _, point in ipairs(candidate.points) do
                    local shift = DistanceSquared(point.world, requested.world)
                    local fallback = not point.objectiveKey and candidate.resolution and temporaryObjectiveReasons[candidate.resolution.reason]
                    if shift and (point.objectiveKey == requested.objectiveKey and shift < 0.000001
                        or fallback and shift <= routeRules.poiTolerance ^ 2) then
                        requestedFound = true
                        firstIndex, firstPoint = index, point
                        firstDistance = DistanceSquared(origin.world, point.world)
                        local requestedWeight = GroupWeight(remaining, candidate, point, grid)
                        firstScore = firstDistance / (requestedWeight * requestedWeight)
                        stability = { retained = not ns.route.pendingSpotChange,
                            reason = ns.route.pendingSpotChange and "manual_spot_change" or "manual_spot_retained", questID = requested.questID }
                        firstAnchor = nil
                    end
                end
            end
        end
    end
    if requestedFound then
        ns.route.manualSpot = { questID = requested.questID, objectiveKey = requested.objectiveKey, world = requested.world,
            mapID = mapID, expiresAt = requested.expiresAt }
    elseif ns.route.pendingSpotChange then
        return { ok = false, error = { code = "target_changed", message = "所选热点已不可用，原路线保留。" } }
    end
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
        and previousFirst.questID == baseline.questID
        and NavigationForStep({ questID = baseline.questID,
        status = remaining[firstIndex].quest.status, objectiveKey = baseline.objectiveKey, world = firstPoint.world,
        targetReason = remaining[firstIndex].resolution and remaining[firstIndex].resolution.reason,
        objectiveRevision = (TargetProgress(baseline.questID, baseline.objectiveKey) or {}).revision or 0 },
        origin.world, mapID, now, previousNavigation).protected
    if recommendation and not requestedFound and not protected then
        local index, point
        if recommendation.action == "pick_up" or recommendation.action == "start_item" then
            local quest = discovery.quests[recommendation.questID]
            point = recommendation.point
            if quest and quest.eligibility == "eligible" and point and point.world then
                local target = {}
                for key, value in pairs(point) do target[key] = value end
                target.coordinateMapID, target.reportedMapID = mapID, mapID
                target.source = point.source or "QuestieDB"
                target.precision = recommendation.action == "start_item" and "inventory_item"
                    or point.precision == "static_spawn" and "static_starter" or point.precision
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
    elseif recommendation then
        decision.deferred = protected and "working_target_protected"
            or ns.route.pendingSpotChange and "manual_spot_change" or "manual_spot_retained"
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
            displayTitle = selected.action == "pick_up" and (quest.title .. (selected.certainty == "confirmed" and "（接任务）" or "（确认接取）"))
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
            entityKind = bestPoint.entityKind, entityID = bestPoint.entityID, entityName = bestPoint.entityName, relation = bestPoint.relation,
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
        and not discovery.building and (discovery.pendingCount or 0) == 0 and (discovery.pendingLocationCount or 0) == 0 then
        local bestDistance
        for _, item in ipairs(excluded) do
            if item.reason == "outside_current_map" and IsID(item.otherMapID)
                and (not nextMapHint or (item.otherDistance and (not bestDistance or item.otherDistance < bestDistance))) then
                nextMapHint = { questID = item.questID, title = item.title, mapID = item.otherMapID, mapName = item.otherMapName }
                bestDistance = item.otherDistance or bestDistance
            end
        end
    end
    local plan = {
        ok = true, schemaVersion = 1, apiRevision = ns.apiRevision, sequence = ns.route.sequence,
        policy = "stable_grouped_precedence_lookahead", scope = "current_player_map_active_and_available_quests",
        discovery = { available = discovery.available, source = "QuestieDB", reason = discovery.reason,
            building = discovery.building, scanned = discovery.scanned, total = discovery.total, pendingCount = discovery.pendingCount,
            pendingLocationCount = discovery.pendingLocationCount,
            opportunityTotal = #(discovery.opportunities or {}), blockedTotal = #(discovery.blocked or {}), summaryLimit = 25,
            opportunities = AssociationSummary(discovery.opportunities, steps[1]), blocked = AssociationSummary(discovery.blocked),
            carriedItems = AssociationSummary(discovery.carriedItems), itemGate = discovery.itemGate,
            announcedOpportunities = discovery.announcedOpportunities }, decision = decision,
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
        levelPriority = { referenceLevel = context.character.level, perLevelBonus = 0, maxWeight = weightBounds.maximum,
            method = "client_difficulty_and_reward" },
        levelingPriority = { source = "client", reference = rewardReference,
            difficultyWeights = difficultyWeights,
            rewardThresholds = { veryLowRatio = 0.25, lowRatio = 0.5, veryLowLevelFraction = 0.005, lowLevelFraction = 0.01 },
            pendingRewardCount = pendingRewards, rewardRetrySeconds = 5, unknownWeight = 1,
            turnInMinimumExperienceWeight = 0.85, maxLevelOffset = settings.maxMonsterLevelOffset,
            workFactorBands = ns.Priority.workBands, groupBonus = routeRules.groupBonus, groupBonusCap = routeRules.groupBonusCap },
        nextMapHint = nextMapHint, switchNotice = settings.switchNotice,
        origin = origin, count = #steps, questCount = routeQuestCount, activeQuestCount = eligibleQuestCount, pickupCount = pickupCount,
        objectiveStepCount = objectiveStepCount, nativeStepCount = nativeStepCount,
        turnInCount = turnInCount, completionPendingCount = completionPendingCount,
        stepUnit = pickupCount > 0 and "unfinished_objective_quest_or_pickup" or "unfinished_objective_or_quest", steps = steps, excluded = excluded,
        pendingLocationCount = pendingLocations, locationRetrySeconds = 5,
        moveThreshold = settings.moveThreshold, enabled = settings.enabled, includeEliteQuests = settings.includeEliteQuests,
        maxMonsterLevelOffset = settings.maxMonsterLevelOffset, minPickupLevel = settings.minPickupLevel,
        totalStraightDistance = pathLength, reason = reason, plannedAt = now,
    }
    if previousPlan and previousPlan.ok and quietRefreshReasons[reason] and RouteSame(previousPlan, plan) then
        local later = now + 30
        if ns.route.nextRewardCheck and ns.route.nextRewardCheck < later then ns.route.nextRewardCheck = later end
        if ns.route.nextLocationCheck and ns.route.nextLocationCheck < later then ns.route.nextLocationCheck = later end
        if ns.route.nextObjectiveCheck and ns.route.nextObjectiveCheck < later then ns.route.nextObjectiveCheck = later end
        if ns.route.nextAssociationCheck and ns.route.nextAssociationCheck < later then ns.route.nextAssociationCheck = later end
        Decision.Notify(plan, previousPlan, settings, now)
        ns.route.pendingSpotChange = nil
        ns.route.dirty, ns.route.pendingReason = false, nil
        return previousPlan
    end
    ns.route.sequence = ns.route.sequence + 1
    plan.sequence = ns.route.sequence
    ns.route.plan = plan
    UpdateNavigation(ns.route.plan, origin, now, previousNavigation, reason == "manual" or ns.route.pendingSpotChange ~= nil)
    if #steps > 0 or not nextMapHint or not previousPlan or previousPlan.mapID ~= mapID
        or quietNoticeReasons[reason] or not settings.switchNotice then ns.route.nextMapNoticeAt = nil end
    local mapFinished = nextMapHint and previousPlan and previousPlan.mapID == mapID
        and ((previousPlan.count or 0) > 0 or not previousPlan.nextMapHint or ns.route.nextMapNoticeAt)
    if mapFinished or not Decision.Notify(ns.route.plan, previousPlan, settings, now) then
        NotifyChange(previousPlan, ns.route.plan, reason, stability, settings, now)
    end
    ns.route.pendingSpotChange = nil
    ns.route.playerLocation, ns.route.lastOrigin = origin, origin.world
    ns.route.dirty, ns.route.pendingReason = false, nil
    -- 帧码只在路线内容变化时出现。背包、技能、走动后步骤未变时不送事件，避免左上角色块反复重画。
    if not (previousPlan and previousPlan.ok and StepsSame(previousPlan, plan)) then
        WB:Emit("route.updated", { sequence = ns.route.sequence, mapID = mapID, count = #steps, questCount = routeQuestCount,
            pickupCount = pickupCount, reason = reason })
    end
    return ns.route.plan
end

local function PlanUnavailable()
    return { ok = false, error = { code = "plan_unavailable",
        message = "路线暂时不可用：位置或任务数据读取失败，已保留原路线并稍后自动重试。" } }
end

-- 单次读取抛错（客户端 API 或第三方数据）不能刷屏或清空路线：保留旧计划与计时，稍后统一重试。
-- BuildPlan 返回 ok=false 表是有意的"不换路线"结果（如热点已失效），按结果透传，不算故障。
local lastRebuildNoticeAt
local function RebuildRoute(reason)
    local retryAt = ns.route.nextRebuildRetry
    if retryAt and not manualRebuildReasons[reason] and GetTime() < retryAt then
        local stats = ns.route.stats
        if stats then stats.suppressed = (stats.suppressed or 0) + 1 end
        return nil
    end
    local sequence, started = ns.route.sequence, ProfileClock()
    local ok, plan = pcall(BuildPlan, reason)
    if not ok then
        RecordRebuild(reason, started, "failed")
        ns.route.dirty, ns.route.pendingReason = false, nil
        local now = GetTime()
        ns.route.nextRebuildRetry = now + rebuildRetrySeconds
        if not lastRebuildNoticeAt or now - lastRebuildNoticeAt >= rebuildRetrySeconds then
            lastRebuildNoticeAt = now
            print("|cff31cee8QuestRoute|r 路线重建暂时失败，已保留原路线，" .. rebuildRetrySeconds .. " 秒后自动重试。")
        end
        return nil
    end
    if plan and plan.ok then
        RecordRebuild(reason, started, "ok", ns.route.sequence == sequence)
        ns.route.nextRebuildRetry = nil
    else
        RecordRebuild(reason, started, "declined")
    end
    return plan
end

function ns.GetPlan(args)
    if args ~= nil and type(args) ~= "table" then return InvalidArguments("args must be an object") end
    local plan = ns.route.plan or RebuildRoute("requested")
    if plan then return plan end
    return PlanUnavailable()
end

function ns.Replan(args)
    if args ~= nil and type(args) ~= "table" then return InvalidArguments("args must be an object") end
    local plan = RebuildRoute("manual")
    if plan then return plan end
    return PlanUnavailable()
end

ns.Planner = { Rebuild = RebuildRoute, exclusionLabels = exclusionLabels }
