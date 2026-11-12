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
    ui.applyElite = function(value) ns.SetRouteOptions({ includeEliteQuests = value }) end
    if not ui.category then
        ui.category = Settings.RegisterVerticalLayoutCategory("QuestRoute")
        ui.eliteSetting = Settings.RegisterAddOnSetting(ui.category, "QuestRoute_includeEliteQuests",
            "includeEliteQuests", RouteSettings(), "boolean", "将精英任务加入路线规划", false)
        -- 原生SetValueChangedCallback追加监听而非覆盖；只注册一次，分发给当前加载实例。
        ui.eliteSetting:SetValueChangedCallback(function(_, value)
            if ui.applyElite then ui.applyElite(value) end
        end)
        Settings.CreateCheckbox(ui.category, ui.eliteSetting,
            "开启后，未完成的精英任务也会参与当前地区的路线规划，切换后立即生效。\n"
            .. "副本、专业任务和手动跳过的任务仍按原规则过滤；已完成任务始终可安排交付。\n此设置仅对当前角色生效。")
        Settings.RegisterAddOnCategory(ui.category)
    end
    return true
end
