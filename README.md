# QuestRoute

《魔兽世界：无限》任务规划与地图导航插件。根据当前已接任务，在原生大地图和小地图上显示路线、未完成目标及可切换热点，并为相关任务怪提供姓名板提示。

## 安装

将仓库中的 `addons/YYQQuestAPI` 文件夹复制到游戏的 `Interface/AddOns/` 目录，然后启动游戏。QuestRoute 当前保留 `YYQQuestAPI` 插件目录名、接口名及存档变量，以兼容已有配置。

原生客户端数据决定任务状态与进度；可选安装 QuestieDB 补充目标实体和静态刷新点。插件可以独立运行，无限工坊用于开发调试与 API 调用。

## 使用

- 大地图和小地图显示编号路线，橙色 1 号表示下一步。
- 地图标记右键跳过整项任务，Shift + 右键切换目标地点。
- `/yyqroute on`、`/yyqroute off`：开启或关闭路线。
- `/yyqroute replan`：立即重新规划。
- `/yyqroute unskip all`：恢复所有已跳过任务。

完整功能与 API 说明见 [插件 README](addons/YYQQuestAPI/README.md)，开发状态见 [开发进度](开发进度.md)。

## 离线验证

安装 Python 与 `lupa` 后，在仓库根目录执行：

```powershell
python -m pip install lupa
python tests/verify_quest_data.py --addon addons/YYQQuestAPI/YYQQuestAPI.lua
```

验证在隔离的 Lua 5.1 环境运行，不连接或修改游戏。

## 目录

- `addons/YYQQuestAPI/`：插件源码、加载清单和 API 文档。
- `tests/`：离线验证脚本。
- 根目录中文文档：方案、调研、开发进度和待办。
- `backups/`：既有阶段备份及校验记录。
