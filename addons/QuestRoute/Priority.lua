-- 客户端原生难度与奖励经验，仅校准直线距离的排序权重。
local _, ns = ...
local IsFinite = ns.Util.IsFinite
local difficultyBands = {
    [0] = { name = "trivial", weight = 0.4 }, [1] = { name = "easy", weight = 1.25 },
    [2] = { name = "fair", weight = 1 }, [3] = { name = "difficult", weight = 0.65 },
    [4] = { name = "impossible", weight = 0.4 },
}
local priorityLabels = {
    easy_with_reward = "难度较低，已有经验奖励", easy_experience_unknown = "难度较低，奖励经验未知",
    appropriate = "难度适中", difficulty_unknown = "难度未知，按距离安排",
    difficult = "难度较高，适当靠后", very_difficult = "难度很高，适当靠后",
    trivial_on_the_way = "任务已属琐碎，适合顺路完成", low_reward_on_the_way = "奖励经验较低，适合顺路完成",
    below_typical_reward = "奖励经验偏低", turn_in = "任务已完成，可安排交付",
    turn_in_on_the_way = "低收益任务，适合顺路交付", completion_pending = "任务已完成，等待确认交付信息",
}

local function SafePriorityRead(func, questID)
    if type(func) ~= "function" then return nil, "api_unavailable" end
    local ok, value = pcall(func, questID)
    if not ok then return nil, "read_error" end
    if not canaccessvalue(value) then return nil, "restricted" end
    if value == nil then return nil, "data_unavailable" end
    return value
end

local function ReadLevelingData(quest)
    local id = quest.questID
    local cached, cacheReason = SafePriorityRead(HaveQuestData, id)
    local data = {
        difficulty = { available = false, name = "unknown", source = "C_PlayerInfo.GetContentDifficultyQuestForPlayer" },
        experience = { available = false, source = "GetQuestLogRewardXP" },
    }
    if cached == false then
        data.difficulty.reason, data.experience.reason = "quest_data_not_ready", "quest_data_not_ready"
        return data
    end
    local code, difficultyReason = SafePriorityRead(C_PlayerInfo and C_PlayerInfo.GetContentDifficultyQuestForPlayer, id)
    local trivial = SafePriorityRead(C_QuestLog.IsQuestTrivial, id)
    if type(trivial) == "boolean" then data.difficulty.isTrivial = trivial end
    if trivial == true then code = 0; data.difficulty.source = "C_QuestLog.IsQuestTrivial" end
    if IsFinite(code) and difficultyBands[code] then
        data.difficulty.available, data.difficulty.code, data.difficulty.name = true, code, difficultyBands[code].name
    else
        data.difficulty.reason = difficultyReason or "invalid_difficulty"
    end
    -- 这三个旧读取函数已在本客户端实测：显式questID，不切换选中任务。
    -- 任务信息就绪不代表奖励就绪；缺少缓存证明时不把0经验当成真实收益。
    local rewards, rewardReason = SafePriorityRead(HaveQuestRewardData, id)
    if cached ~= true or rewards ~= true then
        data.experience.reason = cached ~= true and (cacheReason or "quest_cache_unknown")
            or rewardReason or "reward_data_not_ready"
        return data
    end
    local xp, xpReason = SafePriorityRead(GetQuestLogRewardXP, id)
    if IsFinite(xp) and xp >= 0 then
        data.experience.available, data.experience.value = true, xp
    else
        data.experience.reason = xpReason or "invalid_experience"
    end
    return data
end

local function RewardReference(candidates, levelXPMaximum)
    local values = {}
    for _, candidate in ipairs(candidates) do
        local data = candidate.priority
        local code = data.difficulty.code
        if (code == 1 or code == 2) and data.experience.available and data.experience.value > 0 then
            values[#values + 1] = data.experience.value
        end
    end
    table.sort(values)
    local reference = { sampleCount = #values, minimumSamples = 3, available = #values >= 3,
        scope = "current_map_eligible_easy_fair", method = "median_positive_native_reward",
        levelXPMaximum = IsFinite(levelXPMaximum) and levelXPMaximum > 0 and levelXPMaximum or nil }
    if reference.available then
        local middle = math.floor((#values + 1) / 2)
        reference.value = #values % 2 == 1 and values[middle] or values[middle] / 2 + values[middle + 1] / 2
    end
    return reference
end

local function ApplyLevelingPriority(candidate, reference)
    local data, quest = candidate.priority, candidate.quest
    local band = difficultyBands[data.difficulty.code]
    local completed = quest.readyForTurnIn or quest.isComplete
    data.difficultyWeight = completed and 1 or band and band.weight or 1
    local xp = data.experience
    local rewardWeight = 1
    if xp.available then
        if reference.available then xp.relativeToReference = xp.value / reference.value end
        if reference.levelXPMaximum then xp.fractionOfLevel = xp.value / reference.levelXPMaximum end
        if xp.value == 0 then rewardWeight = 0.5
        elseif (xp.relativeToReference and xp.relativeToReference < 0.25)
            or (xp.fractionOfLevel and xp.fractionOfLevel < 0.005) then rewardWeight = 0.55
        elseif (xp.relativeToReference and xp.relativeToReference < 0.5)
            or (xp.fractionOfLevel and xp.fractionOfLevel < 0.01) then rewardWeight = 0.8 end
    end
    data.lowReward = xp.available and (xp.value == 0
        or (xp.relativeToReference ~= nil and xp.relativeToReference < 0.25)
        or (xp.fractionOfLevel ~= nil and xp.fractionOfLevel < 0.005))
    data.experienceWeight = completed and math.max(0.85, rewardWeight) or rewardWeight
    if quest.isComplete and not quest.readyForTurnIn then data.reason = "completion_pending"
    elseif completed then
        data.reason = (data.lowReward or data.difficulty.code == 0) and "turn_in_on_the_way" or "turn_in"
    elseif data.difficulty.code == 0 then data.reason = "trivial_on_the_way"
    elseif data.lowReward then data.reason = "low_reward_on_the_way"
    elseif data.difficulty.code == 4 then data.reason = "very_difficult"
    elseif data.difficulty.code == 3 then data.reason = "difficult"
    elseif rewardWeight < 1 then data.reason = "below_typical_reward"
    elseif data.difficulty.code == 1 then data.reason = xp.available and "easy_with_reward" or "easy_experience_unknown"
    else data.reason = data.difficulty.available and "appropriate" or "difficulty_unknown" end
    data.weight = data.difficultyWeight * data.experienceWeight
    candidate.priorityWeight = data.weight
end

ns.Priority = { Read = ReadLevelingData, Reference = RewardReference, Apply = ApplyLevelingPriority, labels = priorityLabels }
