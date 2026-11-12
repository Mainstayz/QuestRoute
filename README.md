# QuestRoute

《魔兽世界：无限》任务规划与地图导航插件。根据当前已接任务，在原生大地图和小地图上显示路线、未完成目标及可切换热点，并为相关任务怪提供姓名板提示。

## 安装

1. 完整退出游戏，先禁用或移走旧 `Interface/AddOns/YYQQuestAPI` 目录，避免两版同时运行。
2. 将仓库中的 `addons/QuestRoute` 文件夹复制到游戏的 `Interface/AddOns/` 目录，最终为 `Interface/AddOns/QuestRoute/`，其中应包含 `QuestRoute.lua` 和 `QuestRoute.toc`，插件 Title 为 `QuestRoute`。
3. 需要沿用旧配置时，先按下方步骤迁移，再启动游戏；在插件列表中确认仅启用 QuestRoute。

插件目录改名、增加新文件或修改 `.toc` 后，必须完整退出并重新启动游戏，`/reload` 不够。本次重命名尚未同步到游戏安装，也未在新名称下完成实机验证。

原生客户端数据决定任务状态与进度；可选安装 QuestieDB 补充目标实体和静态刷新点。插件可以独立运行，无限工坊用于开发调试与 API 调用。

## 旧配置迁移

新 SavedVariables 为 `QuestRouteDB`。存档文件名已改变，游戏不会自动跨文件读取旧存档；需要手动迁移，否则会从新配置开始。

1. 完整退出游戏，在 `WTF/Account/<账号>/SavedVariables/` 中备份旧 `YYQQuestAPI.lua`。
2. 将旧文件复制为 `QuestRoute.lua`。如果已有 `QuestRoute.lua`，先单独备份并确认要沿用哪份配置，再迁移，避免直接覆盖已有配置。
3. 只把新副本中顶层赋值的变量名 `YYQQuestAPIDB` 改为 `QuestRouteDB`，其余内容保持原样。完整保留 `routes`，包括各服务器/角色的 `skipped`、`moveThreshold`、`enabled`、`nameplatesEnabled`。
4. 保存后启动游戏。旧文件及备份保留，便于需要时恢复。

## 使用

- 大地图和小地图显示编号路线，橙色 1 号表示下一步。
- 地图标记右键跳过整项任务，Shift + 右键切换目标地点。
- `/questroute on`、`/questroute off`：开启或关闭路线。
- `/questroute replan`：立即重新规划。
- `/questroute unskip all`：恢复所有已跳过任务。
- `/questrouteapi`：只读显示当前任务列表。

路线命令注册为 `SlashCmdList.QUESTROUTE`，Lua API 命名空间为 `WoWBridgeNS.QuestRoute`，无限工坊 `call` 使用 `addon="QuestRoute"`。重命名后不提供旧名称的运行时别名。

完整地图规划与任务数据 API 说明见 [插件 README](addons/QuestRoute/README.md)，开发状态见 [开发进度](开发进度.md)。

## 设置

安装后，在游戏中打开 **选项 → 插件 → QuestRoute**，勾选或取消“将精英任务加入路线规划”。设置页使用游戏原生勾选框，本次没有新增地图按钮或地图焦点操作。

- 默认关闭，旧配置也沿用关闭状态；开启后，未完成的精英任务可参与当前地图规划。
- 切换后立即重排，按服务器与角色保存，正常退出或重载界面时由游戏写盘。
- 副本、专业、失败、手动跳过、外图及无可靠位置的过滤继续生效；已完成的精英任务不受此开关影响，仍可顺路交付。

当前仓库 apiRevision=14，659项离线检查及插件静态检查通过。游戏离线，安装同步、设置页实际显示与手柄焦点尚待实机验证。

## 离线验证

安装 Python 与 `lupa` 后，在仓库根目录执行：

```powershell
python -m pip install lupa
python tests/verify_quest_data.py --addon addons/QuestRoute/QuestRoute.lua
```

验证在隔离的 Lua 5.1 环境运行，不连接或修改游戏。

## 目录

- `addons/QuestRoute/`：插件源码、加载清单和 API 文档。
- `tests/`：离线验证脚本。
- 根目录中文文档：方案、调研、开发进度和待办。
- `backups/`：既有阶段备份及校验记录；历史 `YYQQuestAPI-r*.zip` 保留真实文件名。
