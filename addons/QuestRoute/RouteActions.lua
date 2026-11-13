-- 玩家主动修改路线的 API：跳过、换热点、避让和选项。
local _, ns = ...
local InvalidArguments, IsFinite, IsID, DistanceSquared = ns.Util.InvalidArguments, ns.Util.IsFinite, ns.Util.IsID, ns.Util.DistanceSquared
local ReadQuest, ActiveQuestIndex = ns.QuestData.ReadQuest, ns.QuestData.ActiveQuestIndex
local RouteSettings, RouteExclusion = ns.RouteOptions.Get, ns.RouteOptions.Exclusion
local GetDatabase, ReadObjectiveLocations = ns.Database.Get, ns.Objectives.ReadLocations
local BuildHotspots, SpotBlocked, spotRules = ns.Hotspots.Build, ns.Hotspots.Blocked, ns.Hotspots.spotRules
local RebuildRoute, WB = ns.Planner.Rebuild, ns.WB

function ns.SetQuestSkip(args)
    if type(args) ~= "table" or not IsID(args.questID) then return InvalidArguments("questID must be a positive integer") end
    if args.skipped ~= nil and type(args.skipped) ~= "boolean" then return InvalidArguments("skipped must be a boolean") end
    local settings = RouteSettings()
    local skipped = args.skipped ~= false
    settings.skipped[args.questID] = skipped or nil
    RebuildRoute(skipped and "quest_skipped" or "quest_restored")
    return { ok = true, questID = args.questID, skipped = skipped, count = ns.route.plan.count }
end

local function CopyProgressData(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = CopyProgressData(item) end
    return copy
end

function ns.ChangeQuestSpot(args)
    if args == nil then args = {} end
    if type(args) ~= "table" or (args.questID ~= nil and not IsID(args.questID)) then
        return InvalidArguments("questID must be a positive integer when supplied")
    end
    if args.objectiveKey ~= nil and (not args.questID or type(args.objectiveKey) ~= "string"
        or not args.objectiveKey:match("^[a-z]+:%d+$")) then
        return InvalidArguments("objectiveKey requires questID and an entity key such as npc:3260")
    end
    if args.hotspotID ~= nil and (not args.questID or not args.objectiveKey
        or type(args.hotspotID) ~= "string" or #args.hotspotID > 96 or #args.hotspotID == 0) then
        return InvalidArguments("hotspotID requires questID and objectiveKey and a nonempty ID from get_plan")
    end
    local plan, step = ns.GetPlan({}), nil
    for _, candidate in ipairs(plan.steps) do
        if (args.questID == nil or candidate.questID == args.questID)
            and (args.objectiveKey == nil or candidate.objectiveKey == args.objectiveKey) then step = candidate; break end
    end
    local function Failed(code, message)
        return { ok = false, error = { code = code, message = message } }
    end
    if not step or not step.objectiveKey or step.targetMode ~= "objective_locations" or step.action ~= "quest_area" then
        return Failed("precise_target_required", "此步骤没有可更换的具体未完目标地点；任务不会被跳过。")
    end
    local context, active = ns.GetPlayerContext({}), ActiveQuestIndex()
    local location, entry = context.location, active[step.questID]
    if location.coordinateMapID ~= plan.mapID or not location.world or not entry then
        return Failed("target_unavailable", "玩家位置或任务已变化，请先重新规划。")
    end
    local db, info = GetDatabase()
    local quest = ReadQuest(entry.info, entry.category, false)
    local objectivesOK, objectives = pcall(C_QuestLog.GetQuestObjectives, step.questID)
    quest.objectivesLoaded = objectivesOK and type(objectives) == "table"
    quest.objectives = quest.objectivesLoaded and objectives or {}
    if RouteExclusion(quest, db, RouteSettings()) then return Failed("task_excluded", "此任务已被过滤或跳过。") end
    local resolved = ReadObjectiveLocations(db, info, quest)
    if resolved.mode ~= "objective_locations" then return Failed("target_unavailable", "目标位置暂不可用，原路线保留。") end
    local now = GetTime()
    local avoid = { questID = step.questID, objectiveKey = step.objectiveKey, mapID = plan.mapID,
        world = step.world, expiresAt = now + spotRules.duration }
    local sourcePoints = {}
    for _, point in ipairs(resolved.points) do
        if point.objectiveKey == step.objectiveKey and point.reportedMapID == plan.mapID
            and point.world and point.world.continentID == location.world.continentID then sourcePoints[#sourcePoints + 1] = point end
    end
    local choices = BuildHotspots(sourcePoints, step.stepKey .. ":" .. plan.mapID)
    local best, bestDistance
    for _, point in ipairs(choices) do
        if (args.hotspotID == nil or point.hotspot.id == args.hotspotID)
            and not SpotBlocked(point, step.questID, plan.mapID, now, avoid) then
            local distance = DistanceSquared(location.world, point.world)
            if distance and (not bestDistance or distance < bestDistance) then best, bestDistance = point, distance end
        end
    end
    if not best then return Failed("no_alternative_spot", "同一未完目标在当前地图没有其他可用地点，原路线保留。") end
    -- 所有模块动态读取 ns.route；重建失败时统一丢弃草稿，恢复原路线和计时。
    local original, draft = ns.route, {}
    for key, value in pairs(original) do draft[key] = value end
    draft.progress, draft.spotAvoidances = CopyProgressData(original.progress), CopyProgressData(original.spotAvoidances)
    ns.route = draft
    if #ns.route.spotAvoidances >= spotRules.maximum then table.remove(ns.route.spotAvoidances, 1) end
    ns.route.spotAvoidances[#ns.route.spotAvoidances + 1] = avoid
    ns.route.pendingSpotChange = { questID = step.questID, objectiveKey = step.objectiveKey, world = best.world }
    local called, updated = pcall(RebuildRoute, "spot_changed")
    ns.route = original
    if not called or not updated.ok then
        return not called and Failed("target_unavailable", "热点刷新未成功，原路线保留。") or updated
    end
    for key in pairs(original) do if draft[key] == nil then original[key] = nil end end
    for key, value in pairs(draft) do original[key] = value end
    WB:Emit("route.spot_changed", { questID = step.questID, objectiveKey = step.objectiveKey,
        mapID = plan.mapID, expiresAt = avoid.expiresAt })
    return { ok = true, questID = step.questID, objectiveKey = step.objectiveKey, expiresAt = avoid.expiresAt,
        avoidedRadius = spotRules.radius, duration = spotRules.duration, selected = updated.steps[1] }
end

function ns.ClearSpotAvoidances(args)
    if args == nil then args = {} end
    if type(args) ~= "table" or (args.questID ~= nil and not IsID(args.questID)) then
        return InvalidArguments("questID must be a positive integer when supplied")
    end
    local kept = {}
    for _, avoid in ipairs(ns.route.spotAvoidances) do if args.questID and avoid.questID ~= args.questID then kept[#kept + 1] = avoid end end
    ns.route.spotAvoidances = kept
    return RebuildRoute("manual")
end

function ns.ResetQuestSkips(args)
    if args ~= nil and type(args) ~= "table" then return InvalidArguments("args must be an object") end
    RouteSettings().skipped = {}
    return RebuildRoute("skips_reset")
end

function ns.SetRouteOptions(args)
    if type(args) ~= "table" then return InvalidArguments("args must be an object") end
    if args.enabled ~= nil and type(args.enabled) ~= "boolean" then return InvalidArguments("enabled must be a boolean") end
    if args.nameplatesEnabled ~= nil and type(args.nameplatesEnabled) ~= "boolean" then return InvalidArguments("nameplatesEnabled must be a boolean") end
    if args.includeEliteQuests ~= nil and type(args.includeEliteQuests) ~= "boolean" then return InvalidArguments("includeEliteQuests must be a boolean") end
    if args.switchNotice ~= nil and type(args.switchNotice) ~= "boolean" then return InvalidArguments("switchNotice must be a boolean") end
    if args.moveThreshold ~= nil and (not IsFinite(args.moveThreshold) or args.moveThreshold < 10 or args.moveThreshold > 5000) then
        return InvalidArguments("moveThreshold must be from 10 to 5000")
    end
    local settings = RouteSettings()
    if args.enabled ~= nil then settings.enabled = args.enabled end
    if args.nameplatesEnabled ~= nil then settings.nameplatesEnabled = args.nameplatesEnabled end
    if args.includeEliteQuests ~= nil then settings.includeEliteQuests = args.includeEliteQuests end
    if args.switchNotice ~= nil then settings.switchNotice = args.switchNotice end
    if args.moveThreshold ~= nil then settings.moveThreshold = args.moveThreshold end
    return RebuildRoute("options_changed")
end
