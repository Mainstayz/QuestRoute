-- 原生选项页使用客户端自己的控件，不向地图添加焦点或交互入口。
local _, ns = ...
local Accessible, RouteSettings = ns.Util.Accessible, ns.RouteOptions.Get

function ns.RegisterSettings()
    if not IsLoggedIn() or not Accessible(UnitName("player")) then return false end
    if not Settings or type(Settings.RegisterVerticalLayoutCategory) ~= "function"
        or type(Settings.RegisterAddOnSetting) ~= "function" or type(Settings.CreateCheckbox) ~= "function"
        or type(Settings.RegisterAddOnCategory) ~= "function" then return false end
    local ui = ns.settingsUI or {}
    ns.settingsUI = ui
    ui.owner = ns
    -- 手柄用户尽量少操作，能在原生设置页改的选项就不要只留命令。
    ui.applyElite = function(value) ns.SetRouteOptions({ includeEliteQuests = value }) end
    ui.applySwitchNotice = function(value) ns.SetRouteOptions({ switchNotice = value }) end
    ui.applyNameplates = function(value) ns.SetRouteOptions({ nameplatesEnabled = value }) end
    ui.applyAssociation = function(value)
        if not ns.route.plan or ns.route.plan.associationEnabled ~= value then
            ns.SetRouteOptions({ associationEnabled = value })
        end
    end
    ui.applyMonsterLevel = function(value)
        if not ns.route.plan or ns.route.plan.maxMonsterLevelOffset ~= value then
            ns.SetRouteOptions({ maxMonsterLevelOffset = value })
        end
    end
    ui.applyPickupLevel = function(value)
        if not ns.route.plan or ns.route.plan.minPickupLevel ~= value then
            ns.SetRouteOptions({ minPickupLevel = value })
        end
    end
    -- 每个设置项单独判断：热加载时 category 会被保留，整体判断会让后来新增的项永远注册不上。
    if not ui.category then ui.category = Settings.RegisterVerticalLayoutCategory("QuestRoute") end
    local function AddCheckbox(key, variable, name, defaultValue, help, apply)
        local field = key .. "Setting"
        if ui[field] then return end
        ui[field] = Settings.RegisterAddOnSetting(ui.category, "QuestRoute_" .. variable,
            variable, RouteSettings(), "boolean", name, defaultValue)
        -- 原生SetValueChangedCallback追加监听而非覆盖；只注册一次，分发给当前加载实例。
        ui[field]:SetValueChangedCallback(function(_, value) if ui[apply] then ui[apply](value) end end)
        Settings.CreateCheckbox(ui.category, ui[field], help)
    end
    AddCheckbox("elite", "includeEliteQuests", "将精英任务加入路线规划", false,
        "开启后，未完成的精英任务也会参与当前地区的路线规划，切换后立即生效。\n"
        .. "副本、专业任务和手动跳过的任务仍按原规则过滤；已完成任务始终可安排交付。\n此设置仅对当前角色生效。",
        "applyElite")
    AddCheckbox("notice", "switchNotice", "目标变化时显示屏幕提示", true,
        "开启后，1 号目标自动改变或本图做完时，屏幕上方显示一行提示。\n"
        .. "启动、手动重排/换点/跳过及两次提示间隔过短时不提示。\n此设置仅对当前角色生效。",
        "applySwitchNotice")
    AddCheckbox("nameplate", "nameplatesEnabled", "在任务怪姓名板上显示提示", true,
        "开启后，你自行打开的敌方姓名板上会标出相关任务怪（当前目标为橙色）。\n"
        .. "关闭不影响地图路线，也不会自动打开姓名板。\n此设置仅对当前角色生效。",
        "applyNameplates")
    AddCheckbox("association", "associationEnabled", "启用任务联想（可接任务发现与前瞻）", false,
        "开启后，程序会建立任务关联索引，在地图上标出沿途/附近可接的任务，并把顺路接取纳入路线前瞻。\n"
        .. "默认关闭；关闭时不建索引、不显示接取机会，已接任务的路线、交付与外图提示不受影响。\n此设置仅对当前角色生效，切换后立即重排。",
        "applyAssociation")
    if not ui.monsterLevelSetting and type(Settings.CreateSliderOptions) == "function" and type(Settings.CreateSlider) == "function" then
        ui.monsterLevelSetting = Settings.RegisterAddOnSetting(ui.category, "QuestRoute_maxMonsterLevelOffset",
            "maxMonsterLevelOffset", RouteSettings(), "number", "怪物最多高出角色几级", 2)
        ui.monsterLevelSetting:SetValueChangedCallback(function(_, value)
            if ui.applyMonsterLevel then ui.applyMonsterLevel(value) end
        end)
        local options = Settings.CreateSliderOptions(0, 5, 1)
        if MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
            options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
                return value == 0 and "同级及以下" or ("+" .. value .. "级")
            end)
        end
        Settings.CreateSlider(ui.category, ui.monsterLevelSetting, options,
            "只比较任务目标怪物的等级，不按任务等级过滤。\n0：不高于自身；1：允许高1级；默认2。\n"
            .. "同时影响路线、材料怪来源、关联前瞻和换热点；已完成交付不受限制。\n此设置仅对当前角色生效，修改后立即重排。")
    end
    if not ui.pickupLevelSetting and type(Settings.CreateSliderOptions) == "function" and type(Settings.CreateSlider) == "function" then
        ui.pickupLevelSetting = Settings.RegisterAddOnSetting(ui.category, "QuestRoute_minPickupLevel",
            "minPickupLevel", RouteSettings(), "number", "接取建议最低任务等级", 15)
        ui.pickupLevelSetting:SetValueChangedCallback(function(_, value)
            if ui.applyPickupLevel then ui.applyPickupLevel(value) end
        end)
        local options = Settings.CreateSliderOptions(0, 60, 1)
        if MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
            options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
                return value == 0 and "不限制" or (value .. "级")
            end)
        end
        Settings.CreateSlider(ui.category, ui.pickupLevelSetting, options,
            "低于此任务等级的未接任务不显示接取标记、建议或前瞻；默认15级，0表示关闭等级过滤。\n"
            .. "已接任务的导航和交付不受影响，任务等级未知时保留。\n此设置仅对当前角色生效，修改后立即重排。")
    end
    if not ui.registered then
        Settings.RegisterAddOnCategory(ui.category)
        ui.registered = true
    end
    return true
end
