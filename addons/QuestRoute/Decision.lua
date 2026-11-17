-- 只搜索局部任务的短计划；预测的接取/完成状态不写回角色或正式任务目标。
local _, ns = ...
local DistanceSquared, IsFinite = ns.Util.DistanceSquared, ns.Util.IsFinite
-- shortcut: 只搜索当前地图的六步局部计划，真实长链收益不足时再扩大前瞻。
local rules = { depth = 6, width = 4, maxQuests = 18, maxFirstActions = 6, maxActions = 4,
    nearbyRadius = 400, areaRadius = 200, detour = 150, workCost = 180, interactionCost = 25,
    goalValue = 1000, deliveryValue = 300, minimumGain = 80 }

local distances
local function Distance(a, b)
    if not a or not b then return end
    local cached = distances and distances[a] and distances[a][b]
    if cached then return cached end
    local squared = DistanceSquared(a, b)
    local distance = squared and math.sqrt(squared)
    if distance and distances then
        distances[a] = distances[a] or {}
        distances[a][b] = distance
        distances[b] = distances[b] or {}
        distances[b][a] = distance
    end
    return distance
end

local function Copy(source)
    local out = {}
    for key, value in pairs(source or {}) do out[key] = value end
    return out
end

local function Nearest(points, origin)
    local best, distance
    for _, point in ipairs(points or {}) do
        local d = Distance(origin, point.world)
        if d and (not distance or d < distance) then best, distance = point, d end
    end
    return best, distance
end

local function ActionKey(action)
    return action.questID .. ":" .. action.action .. ":" .. (action.goalKey or "quest")
end

local function Models(data, candidates, origin, baseline)
    local models, byID, relevant = {}, {}, {}
    for _, opportunity in ipairs(data.opportunities or {}) do relevant[opportunity.questID] = true end
    local active = {}
    for _, candidate in ipairs(candidates) do active[candidate.quest.questID] = true; relevant[candidate.quest.questID] = true end
    -- 直接后续即使暂缺前置也参与预测；只能通过模拟交付解除前置阻挡。
    for id, quest in pairs(data.quests or {}) do
        for _, list in ipairs({ quest.preAll or {}, quest.preAny or {} }) do
            for _, prereq in ipairs(list) do
                if active[prereq] then relevant[id] = true end
            end
        end
    end
    for id, quest in pairs(data.quests or {}) do
        if relevant[id] and (quest.active or quest.startItemID or #(quest.starters or {}) > 0)
            and (quest.eligibility == "eligible" or not quest.active and quest.conditionReason == "prerequisite") then
            local model = { questID = id, quest = quest, goals = {}, goalCount = 0, distance = math.huge }
            for _, target in ipairs(quest.targets or {}) do
                local key = target.key or target.objectiveKey
                if key and target.world then
                    local goal = model.goals[key]
                    if not goal then goal = { key = key, points = {} }; model.goals[key] = goal; model.goalCount = model.goalCount + 1 end
                    goal.points[#goal.points + 1] = target
                    local d = Distance(origin, target.world)
                    if d then model.distance = math.min(model.distance, d) end
                end
            end
            local _, starterDistance = Nearest(quest.starters, origin)
            if starterDistance then model.distance = math.min(model.distance, starterDistance) end
            model.weight = IsFinite(quest.rewardWeight) and math.max(0.4, math.min(1.25, quest.rewardWeight)) or 1
            byID[id] = model
            models[#models + 1] = model
        end
    end
    table.sort(models, function(a, b)
        local af, bf = baseline and a.questID == baseline.questID, baseline and b.questID == baseline.questID
        if af ~= bf then return af end
        if a.distance ~= b.distance then return a.distance < b.distance end
        return a.questID < b.questID
    end)
    while #models > rules.maxQuests do byID[table.remove(models).questID] = nil end
    return models, byID
end

local function Dependencies(quest, state, data)
    if quest.eligibility ~= "eligible" and quest.conditionReason ~= "prerequisite" then return false end
    for _, id in ipairs(quest.preAll or {}) do if not state.delivered[id] and data.completed[id] ~= true then return false end end
    local any = #(quest.preAny or {}) == 0
    for _, id in ipairs(quest.preAny or {}) do if state.delivered[id] or data.completed[id] == true then any = true end end
    if not any then return false end
    for _, id in ipairs(quest.exclusiveTo or {}) do
        if state.accepted[id] or state.delivered[id] or data.completed[id] == true then return false end
    end
    for id in pairs(state.accepted) do
        local other = data.quests[id]
        for _, excluded in ipairs(other and other.exclusiveTo or {}) do
            if excluded == quest.questID then return false end
        end
    end
    -- 在一次预测里接取/交付后也重新检查可见性约束。
    for _, id in ipairs({ quest.nextQuestInChain or 0, quest.availableUntilCompleted or 0, quest.breadcrumbForQuestId or 0 }) do
        if id > 0 and (state.delivered[id] or data.completed[id] == true
            or ((id == quest.nextQuestInChain or id == quest.breadcrumbForQuestId) and state.accepted[id])) then return false end
    end
    if quest.parentQuest and (not state.accepted[quest.parentQuest] or state.delivered[quest.parentQuest]) then return false end
    if quest.availableStartingWith and not (state.accepted[quest.availableStartingWith]
        or state.delivered[quest.availableStartingWith] or data.completed[quest.availableStartingWith] == true) then return false end
    if quest.disabledByQuest and state.accepted[quest.disabledByQuest] and not state.delivered[quest.disabledByQuest] then return false end
    return true
end

local function AllDone(model, state)
    if state.finished[model.questID] then return true end
    if model.goalCount == 0 or model.quest.targetsComplete ~= true then return false end
    for key in pairs(model.goals) do if not state.done[model.questID .. ":" .. key] then return false end end
    return true
end

local function Actions(models, state, data)
    local actions = {}
    for _, model in ipairs(models) do
        local id, quest = model.questID, model.quest
        if not state.delivered[id] then
            if state.accepted[id] then
                if AllDone(model, state) then
                    local point = Nearest(quest.finishers, state.cursor)
                    if point then actions[#actions + 1] = { action = "turn_in", questID = id, point = point } end
                else
                    for key, goal in pairs(model.goals) do
                        if not state.done[id .. ":" .. key] then
                            local point = Nearest(goal.points, state.cursor)
                            if point then actions[#actions + 1] = { action = "quest_area", questID = id, goalKey = key, point = point } end
                        end
                    end
                end
            elseif Dependencies(quest, state, data) then
                if quest.startItemID then
                    actions[#actions + 1] = { action = "start_item", questID = id, itemID = quest.startItemID,
                        point = { world = state.cursor }, certainty = "confirmed" }
                else
                    local point = Nearest(quest.starters, state.cursor)
                    if point then actions[#actions + 1] = { action = "pick_up", questID = id, point = point, certainty = quest.certainty or "estimated" } end
                end
            end
        end
    end
    table.sort(actions, function(a, b)
        local ac = (Distance(state.cursor, a.point.world) or math.huge) - (a.action == "turn_in" and rules.deliveryValue or 0)
        local bc = (Distance(state.cursor, b.point.world) or math.huge) - (b.action == "turn_in" and rules.deliveryValue or 0)
        if ac ~= bc then return ac < bc end
        return ActionKey(a) < ActionKey(b)
    end)
    return actions
end

local function Shares(a, b)
    if not a.shareable or not b.shareable then return false end
    local same = a.key == b.key or a.entityKind == "npc" and b.entityKind == "npc" and a.entityID == b.entityID
    local distance = same and Distance(a.world, b.world)
    return distance and distance <= rules.areaRadius
end

local function Advance(state, action, models, byID)
    local distance = Distance(state.cursor, action.point.world)
    if not distance then return end
    local nextState = { cursor = action.point.world, accepted = Copy(state.accepted), delivered = Copy(state.delivered),
        finished = Copy(state.finished), done = Copy(state.done), supported = Copy(state.supported),
        actions = Copy(state.actions), score = state.score - distance,
        distance = state.distance + distance, newQuestCount = state.newQuestCount, sharedGoals = state.sharedGoals }
    local model = byID[action.questID]
    local gain, affected, contributions = 0, 0, {}
    if action.action == "pick_up" or action.action == "start_item" then
        nextState.accepted[action.questID] = true
        nextState.newQuestCount = nextState.newQuestCount + 1
        nextState.score = nextState.score - rules.interactionCost
    elseif action.action == "turn_in" then
        nextState.delivered[action.questID] = true
        nextState.score = nextState.score + rules.deliveryValue * model.weight - rules.interactionCost
    else
        -- 同一片区的同怪/同来源只付一次工作成本；未接任务不会获得模拟进度。
        for _, other in ipairs(models) do
            if nextState.accepted[other.questID] and not nextState.delivered[other.questID] then
                for key, goal in pairs(other.goals) do
                    local fingerprint = other.questID .. ":" .. key
                    if not nextState.done[fingerprint] then
                        local match = other.questID == action.questID and key == action.goalKey
                        local shared
                        if not match then
                            for _, point in ipairs(goal.points) do if Shares(action.point, point) then shared = true; break end end
                            match = shared and key == action.goalKey
                        end
                        local value = rules.goalValue * other.weight / math.max(1, other.goalCount)
                        if match then
                            nextState.done[fingerprint] = true
                            gain, affected = gain + value * (nextState.supported[fingerprint] and 0.7 or 1), affected + 1
                            contributions[#contributions + 1] = { questID = other.questID, goalKey = key, complete = true }
                        elseif shared and not nextState.supported[fingerprint] then
                            -- 同怪的材料只计部分协同收益；未知掉率不能据此完成材料或解锁后续。
                            nextState.supported[fingerprint] = true
                            gain, affected = gain + value * 0.3, affected + 1
                            contributions[#contributions + 1] = { questID = other.questID, goalKey = key, complete = false }
                        end
                    end
                end
            end
        end
        nextState.score = nextState.score + gain - rules.workCost
        nextState.sharedGoals = nextState.sharedGoals + math.max(0, affected - 1)
    end
    nextState.actions[#nextState.actions + 1] = { action = action.action, questID = action.questID, goalKey = action.goalKey,
        point = action.point, itemID = action.itemID, certainty = action.certainty, sharedGoalCount = affected,
        contributions = contributions, predicted = true, executable = #state.actions == 0, key = ActionKey(action) }
    nextState.key = (state.key or "") .. "/" .. ActionKey(action)
    return nextState
end

local function Better(a, b)
    return not b or a.score > b.score or a.score == b.score and a.key < b.key
end

local function Search(first, initial, models, byID, data)
    local start = Advance(initial, first, models, byID)
    if not start then return end
    local beam, best = { start }, start
    for _ = 2, rules.depth do
        local nextBeam = {}
        for _, state in ipairs(beam) do
            for index, action in ipairs(Actions(models, state, data)) do
                if index > rules.maxActions then break end
                local child = Advance(state, action, models, byID)
                if child then nextBeam[#nextBeam + 1] = child; if Better(child, best) then best = child end end
            end
        end
        if #nextBeam == 0 then break end
        table.sort(nextBeam, function(a, b) return Better(a, b) end)
        beam = {}
        for index = 1, math.min(rules.width, #nextBeam) do beam[index] = nextBeam[index] end
    end
    return best
end

local function Evaluate(data, candidates, origin, baseline)
    distances = {}
    local result = { algorithm = "precedence_beam_insertion", depth = rules.depth, width = rules.width,
        available = data.available == true, building = data.building, predicted = {}, considered = 0,
        scope = "current_map_short_horizon", costUnit = "straight_line_yard_equivalent" }
    if not data.available or data.building or not origin then result.reason = data.reason or "position_unavailable"; return result end
    data.completed = data.completed or {}
    local models, byID = Models(data, candidates, origin, baseline)
    if #models == 0 then result.reason = "no_related_candidates"; return result end
    local initial = { cursor = origin, accepted = {}, delivered = {}, finished = {}, done = {}, supported = {}, actions = {},
        score = 0, distance = 0, newQuestCount = 0, sharedGoals = 0 }
    for id, quest in pairs(data.quests) do if quest.active then initial.accepted[id] = true end end
    for _, model in ipairs(models) do
        if model.quest.status == "ready_for_turn_in" then initial.finished[model.questID] = true end
    end
    local function ReachablePrerequisite(id)
        local parent = byID[id]
        return data.completed[id] == true or parent and parent.quest.active and #parent.quest.finishers > 0
            and (initial.finished[id] or parent.goalCount > 0 and parent.quest.targetsComplete == true)
    end
    local potential
    for _, model in ipairs(models) do
        local quest = model.quest
        if not quest.active and (quest.startItemID or #quest.starters > 0)
            and (quest.eligibility == "eligible" or quest.conditionReason == "prerequisite") then
            local all, any = true, #(quest.preAny or {}) == 0
            for _, id in ipairs(quest.preAll or {}) do if not ReachablePrerequisite(id) then all = false end end
            for _, id in ipairs(quest.preAny or {}) do if ReachablePrerequisite(id) then any = true end end
            if all and any then potential = true; break end
        end
    end
    local firsts, baselineAction = Actions(models, initial, data), nil
    for _, action in ipairs(firsts) do
        if baseline and action.questID == baseline.questID and action.action == baseline.action
            and (not baseline.objectiveKey or action.goalKey == baseline.objectiveKey) then
            action.point = baseline.point
            baselineAction = action
            break
        end
    end
    if baseline and not baselineAction then result.reason = "baseline_target_unresolved"; return result end
    if not potential then
        result.reason = "keep_current_route"
        if baseline then result.predicted = { { questID = baseline.questID, action = baseline.action,
            goalKey = baseline.objectiveKey, point = baseline.point, predicted = true, executable = true } } end
        return result
    end
    table.sort(firsts, function(a, b)
        if a == baselineAction or b == baselineAction then return a == baselineAction end
        local ad, bd = Distance(origin, a.point.world) or math.huge, Distance(origin, b.point.world) or math.huge
        if ad ~= bd then return ad < bd end
        return ActionKey(a) < ActionKey(b)
    end)
    local best, base
    for index, action in ipairs(firsts) do
        if index > rules.maxFirstActions then break end
        local state = Search(action, initial, models, byID, data)
        result.considered = result.considered + 1
        if action == baselineAction then base = state end
        if state and Better(state, best) then best = state end
    end
    if not best then result.reason = "no_executable_action"; return result end
    result.baselineScore, result.bestScore = base and base.score, best.score
    result.predicted, result.sharedGoalCount = best.actions, best.sharedGoals
    result.extraQuestCount, result.estimatedDistance = best.newQuestCount, best.distance
    local first = best.actions[1]
    local hasAssociation = best.newQuestCount > 0 or best.sharedGoals > 0
    local changed = not baselineAction or first.key ~= ActionKey(baselineAction)
    local worthwhile = base and best.score - base.score >= rules.minimumGain
        or not base and (best.score > 0 or first.action == "start_item")
    if hasAssociation and changed and worthwhile then
        result.recommendation, result.reason = first, "unlock_related_quests"
        if first.action == "pick_up" or first.action == "start_item" then result.reason = "collect_related_quests" end
    else result.reason = "keep_current_route" end
    return result
end

local reasonLabels = { same_target = "可合做目标", on_way = "沿途少绕路", same_area = "目标在下一站附近",
    nearby = "就在附近", gossip_available = "当前对话可接", item_in_bags = "物品已在背包", previous_notice = "先前提示的地点" }
local function OpportunityReason(item)
    local reasons = {}
    for _, reason in ipairs(item.reasons or {}) do reasons[reason] = true end
    for _, reason in ipairs({ "same_target", "on_way", "same_area", "nearby", "gossip_available", "item_in_bags", "previous_notice" }) do
        if reasons[reason] then return reasonLabels[reason] end
    end
end

local function DescribeOpportunity(item, applied)
    local action = item.action or "bring_item"
    local prefix = action == "bring_item" and "已取得：" or action == "start_item" and "背包物品可启动："
        or action == "pick_up" and (item.certainty == "confirmed" and (applied and "建议先接：" or "顺路可接：")
            or (applied and "建议先确认接取：" or "顺路确认接取："))
        or action == "possible_item_drop" and (item.questItem and "顺路取物：" or "物品任务来源：") or "关联路线，先做："
    local title = type(item.itemName) == "string" and item.itemName ~= "" and item.itemName or item.title
    local text = prefix .. title
    local reason = OpportunityReason(item)
    if action == "bring_item" then text = text .. " · 向NPC确认接取/交付"
    elseif reason then text = text .. " · " .. reason end
    if action ~= "start_item" then
        local location = ns.Util.FormatLocation(item.point)
        text = text .. (location and (" · " .. location) or " · 位置待确认")
    end
    return text
end

local function Notify(plan, previous, settings, now)
    if not settings.enabled or not settings.switchNotice or ns.route.pendingSpotChange then return false end
    if plan.reason == "manual" or plan.reason == "quest_skipped" or plan.reason == "options_changed" then return false end
    local decision, opportunity, acquired = plan.decision, nil, false
    local carried = {}
    for _, item in ipairs(previous and previous.discovery and previous.discovery.carriedItems or {}) do carried[item.questID] = true end
    for _, item in ipairs(plan.discovery.carriedItems or {}) do
        if not carried[item.questID] then opportunity, acquired = item, true; break end
    end
    if not opportunity and decision.applied then
        local first = plan.steps[1]
        opportunity = { questID = first.questID, title = first.title, action = first.action, certainty = first.certainty, point = first }
        for _, item in ipairs(plan.discovery.opportunities or {}) do
            if item.questID == first.questID and item.action == first.action then opportunity = item; break end
        end
    elseif not opportunity then
        for _, item in ipairs(plan.discovery.opportunities or {}) do
            if item.action == "start_item" or item.action == "possible_item_drop" or item.certainty == "confirmed" then
                opportunity = item
                break
            end
            for _, why in ipairs(item.reasons or {}) do
                if why == "nearby" or why == "on_way" then opportunity = opportunity or item end
            end
        end
    end
    if not opportunity then return false end
    local action = opportunity.action or "bring_item"
    local key = opportunity.questID .. ":" .. action .. ":" .. (opportunity.itemID or 0)
    local last = ns.route.associationNotice
    if last and (last.key == key or not acquired and now - last.at < 20) then return decision.applied == true end
    if not acquired and ns.route.lastNotice and now - ns.route.lastNotice.at < ns.Navigation.rules.noticeInterval then return true end
    ns.route.associationNotice, ns.route.lastNotice = { key = key, at = now }, { key = key, at = now }
    ns.Util.Notify("QuestRoute " .. DescribeOpportunity(opportunity, decision.applied and not acquired))
    if (action == "pick_up" or action == "possible_item_drop") and opportunity.point then
        local announced = ns.route.announcedOpportunities
        if not announced or announced.mapID ~= plan.mapID then
            announced = { mapID = plan.mapID, items = {} }
            ns.route.announcedOpportunities = announced
        end
        announced.items[key] = opportunity
    end
    ns.WB:Emit("route.association", { questID = opportunity.questID, action = action, applied = decision.applied == true and not acquired })
    return true
end

ns.Decision = { Evaluate = Evaluate, Notify = Notify, Reason = OpportunityReason, Describe = DescribeOpportunity, rules = rules }
