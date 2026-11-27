-- 可靠 NPC 任务用途索引、只读单位查询与非交互姓名板标签。
local _, ns = ...
local InvalidArguments, IsFinite, IsID, Accessible = ns.Util.InvalidArguments, ns.Util.IsFinite, ns.Util.IsID, ns.Util.Accessible
local RouteSettings = ns.RouteOptions.Get

-- 姓名板只需要目标身份和直接掉落关系；缺少静态坐标不妨碍可靠身份关联。
local function ReadNPCGoals(db, quest, identities)
    if not identities.mappingComplete then return nil end
    local goals = {}
    for _, objective in ipairs(identities.objectives) do
        local ids = {}
        if objective.kind == "npc" then ids = { objective.id }
        elseif objective.kind == "item" then ids = db.Item.npcDrops(objective.id) end
        if type(ids) ~= "table" or #ids > 32 then return nil end
        local seen = {}
        for _, id in ipairs(ids) do
            if not IsID(id) then return nil end
            if not seen[id] then
                seen[id] = true
                goals[#goals + 1] = { npcID = id, questID = quest.questID, title = quest.title,
                    objectiveKey = objective.key, kind = objective.kind, id = objective.id, name = objective.name,
                    text = objective.text, finished = objective.finished,
                    numFulfilled = objective.numFulfilled, numRequired = objective.numRequired,
                    relation = objective.kind == "npc" and "kill" or "direct_item_drop",
                    mapping = objective.mapping, progressSource = "C_QuestLog.GetQuestObjectives", relationSource = "QuestieDB" }
            end
        end
    end
    return goals
end

local function AddNPCGoals(index, db, quest, identities)
    if quest.status ~= "in_progress" then return end
    local ok, goals = pcall(ReadNPCGoals, db, quest, identities)
    if not ok or not goals then index.unresolvedQuestCount = index.unresolvedQuestCount + 1; return end
    for _, goal in ipairs(goals) do
        index.byNPC[goal.npcID] = index.byNPC[goal.npcID] or {}
        local bucket = index.byNPC[goal.npcID]
        bucket[#bucket + 1] = goal
    end
end

-- 只读当前可见单位身份；每次刷新重新读取，不延用受限前的NPC ID。
local function UnitRead(func, ...)
    if type(func) ~= "function" then return nil, "api_unavailable" end
    local ok, value = pcall(func, ...)
    if not ok then return nil, "unit_read_error" end
    if not canaccessvalue(value) then return nil, "restricted_identity" end
    return value
end

function ns.GetUnitTasks(args)
    if args == nil then args = {} end
    if type(args) ~= "table" then return InvalidArguments("args must be an object") end
    local unit = args.unit
    if unit == nil then unit = "target" end
    if type(unit) ~= "string" or not (unit == "target" or unit == "mouseover" or unit:match("^nameplate%d+$")) then
        return InvalidArguments("unit must be target, mouseover or nameplateN")
    end
    local index = ns.route.mobIndex or { byNPC = {}, unresolvedQuestCount = 1 }
    local result = { ok = true, schemaVersion = 1, apiRevision = ns.apiRevision, unit = unit,
        state = "unknown", needed = false, tasks = {}, unresolvedQuestCount = index.unresolvedQuestCount,
        observedAt = GetTime(), progressObservedAt = index.observedAt,
        policy = "client_progress_verified_database_identity", progressSource = "C_QuestLog.GetQuestObjectives",
        relationSource = "QuestieDB" }
    if ns.route.dirty then result.reason = "quest_data_updating"; return result end
    local exists, why = UnitRead(UnitExists, unit)
    if exists ~= true then result.reason = why or "unit_unavailable"; return result end
    local player, playerWhy = UnitRead(UnitIsPlayer, unit)
    local attack, attackWhy = UnitRead(UnitCanAttack, "player", unit)
    local dead, deadWhy = UnitRead(UnitIsDeadOrGhost, unit)
    if player == nil or attack == nil or dead == nil then
        result.reason = playerWhy or attackWhy or deadWhy or "unit_state_unavailable"; return result
    end
    if player or not attack or dead then result.state, result.reason = "not_eligible", "not_live_attackable_npc"; return result end
    local id, idWhy = UnitRead(UnitCreatureID, unit)
    if not IsID(id) then result.reason = idWhy or "creature_identity_unavailable"; return result end
    result.npcID = id
    local current = ns.route.plan and ns.route.plan.steps[1]
    local known, pending = 0, {}
    for _, task in ipairs(index.byNPC[id] or {}) do
        known = known + 1
        result.tasks[#result.tasks + 1] = task
        if task.finished == false then
            pending[#pending + 1] = task
            if current and task.questID == current.questID and task.objectiveKey == current.objectiveKey then result.currentTarget = true end
        end
    end
    result.knownGoalCount, result.neededCount = known, #pending
    if #pending > 0 then
        result.state, result.reason, result.needed = "needed", "verified_unfinished_goal", true
        local labels = {}
        for i = 1, math.min(2, #pending) do
            local task = pending[i]
            local count = IsFinite(task.numFulfilled) and IsFinite(task.numRequired)
                and (" " .. task.numFulfilled .. "/" .. task.numRequired) or ""
            labels[#labels + 1] = (task.relation == "kill" and "击杀" or "材料") .. count
        end
        result.label = table.concat(labels, " · ") .. (#pending > 2 and (" +" .. (#pending - 2)) or "")
    elseif index.unresolvedQuestCount > 0 then result.reason = "some_task_relations_unknown"
    elseif known > 0 then result.state, result.reason = "no_remaining_known_goals", "known_goals_finished"
    else result.state, result.reason = "no_known_match", "no_verified_task_relation" end
    return result
end

-- 轻量级姓名板检查：先查单位存在性与 NPC 目标索引，命中后再检查存活/敌对与构造标签。
local function InspectUnitForMarker(unit)
    local index = ns.route.mobIndex
    if not index or not index.byNPC or ns.route.dirty then return false end
    local exists = UnitRead(UnitExists, unit)
    if exists ~= true then return false end
    local id = UnitRead(UnitCreatureID, unit)
    if not IsID(id) then return false end
    local goals = index.byNPC[id]
    if not goals then return false end
    local player = UnitRead(UnitIsPlayer, unit)
    local attack = UnitRead(UnitCanAttack, "player", unit)
    local dead = UnitRead(UnitIsDeadOrGhost, unit)
    if player == nil or attack == nil or dead == nil or player or not attack or dead then return false end
    local current = ns.route.plan and ns.route.plan.steps[1]
    local currentTarget, label1, label2, pendingCount = false, nil, nil, 0
    for _, task in ipairs(goals) do
        if task.finished == false then
            pendingCount = pendingCount + 1
            if current and task.questID == current.questID and task.objectiveKey == current.objectiveKey then
                currentTarget = true
            end
            if pendingCount <= 2 then
                local count = IsFinite(task.numFulfilled) and IsFinite(task.numRequired)
                    and (" " .. task.numFulfilled .. "/" .. task.numRequired) or ""
                local piece = (task.relation == "kill" and "击杀" or "材料") .. count
                if pendingCount == 1 then label1 = piece else label2 = piece end
            end
        end
    end
    if pendingCount == 0 then return false end
    local label = pendingCount == 1 and label1
        or pendingCount == 2 and (label1 .. " · " .. label2)
        or (label1 .. " · " .. label2 .. " +" .. (pendingCount - 2))
    return true, label, currentTarget, id
end

ns.route.nameplateView = ns.route.nameplateView or { markers = {} }

local function HideMarker(marker)
    marker:Hide()
    marker.unit, marker.info, marker.lastLabel, marker.lastCurrent = nil, nil, nil, nil
end

local function HideTaskMarkers(unit)
    if unit then
        for _, marker in pairs(ns.route.nameplateView.markers) do
            if marker.unit == unit then HideMarker(marker) end
        end
        return
    end
    ns.route.nameplateView.hasVisible = false
    for _, marker in pairs(ns.route.nameplateView.markers) do
        HideMarker(marker)
    end
end

local function PlateAllowed(plate)
    if not plate then return false end
    if plate.IsForbidden then
        local ok, forbidden = pcall(plate.IsForbidden, plate)
        if not ok or not canaccessvalue(forbidden) or forbidden then return false end
    end
    return true
end

local function PlateUnit(plate)
    local frame = Accessible(plate.UnitFrame)
    local unit = Accessible(plate.namePlateUnitToken) or frame and Accessible(frame.unit)
    if type(unit) == "string" and unit:match("^nameplate%d+$") then return unit end
end

local function UpdatePlateMarker(plate, unit)
    local needed, label, currentTarget, npcID = InspectUnitForMarker(unit)
    local marker = ns.route.nameplateView.markers[plate]
    if needed then
        if not marker then
            marker = CreateFrame("Frame", nil, plate)
            marker:SetSize(180, 18)
            marker:EnableMouse(false)
            marker:SetPoint("BOTTOM", plate, "TOP", 0, 2)
            marker.text = marker:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            marker.text:SetAllPoints(marker)
            ns.route.nameplateView.markers[plate] = marker
        end
        marker.unit = unit
        marker.info = { needed = true, label = label, currentTarget = currentTarget, npcID = npcID }
        if marker.lastLabel ~= label then
            marker.lastLabel = label
            marker.text:SetText("! " .. label)
        end
        if marker.lastCurrent ~= currentTarget then
            marker.lastCurrent = currentTarget
            marker.text:SetTextColor(1, currentTarget and 0.55 or 0.85, currentTarget and 0.1 or 0.25)
        end
        if not marker.IsShown or not marker:IsShown() then marker:Show() end
        ns.route.nameplateView.hasVisible = true
    elseif marker then
        HideMarker(marker)
    end
end

local function HasMobGoals()
    local index = ns.route.mobIndex
    return index and index.byNPC and next(index.byNPC) ~= nil
end

local function RenderUnit(unit)
    if type(unit) ~= "string" or not unit:match("^nameplate%d+$") then return end
    local settings = RouteSettings()
    if not ns.route.running or not settings.enabled or settings.nameplatesEnabled == false or ns.route.dirty
        or not HasMobGoals() or not C_NamePlate then return end
    if type(C_NamePlate.GetNamePlateForUnit) == "function" then
        local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
        if ok and PlateAllowed(plate) then UpdatePlateMarker(plate, unit) end
        return
    end
    if type(C_NamePlate.GetNamePlates) ~= "function" then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        if PlateAllowed(plate) and PlateUnit(plate) == unit then
            UpdatePlateMarker(plate, unit)
            return
        end
    end
end

local function RenderTaskNameplates()
    local settings = RouteSettings()
    if not ns.route.running or not settings.enabled or settings.nameplatesEnabled == false or ns.route.dirty
        or not HasMobGoals() or not C_NamePlate or type(C_NamePlate.GetNamePlates) ~= "function" then
        if ns.route.nameplateView.hasVisible then HideTaskMarkers() end
        return
    end
    local seenPlates = {}
    local anyVisible = false
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        if PlateAllowed(plate) then
            local unit = PlateUnit(plate)
            if unit then
                seenPlates[plate] = true
                UpdatePlateMarker(plate, unit)
                local marker = ns.route.nameplateView.markers[plate]
                if marker and marker.unit then anyVisible = true end
            end
        end
    end
    for plate, marker in pairs(ns.route.nameplateView.markers) do
        if not seenPlates[plate] then HideMarker(marker) end
    end
    ns.route.nameplateView.hasVisible = anyVisible
end

ns.Nameplates = { AddGoals = AddNPCGoals, Hide = HideTaskMarkers, Render = RenderTaskNameplates, RenderUnit = RenderUnit }
