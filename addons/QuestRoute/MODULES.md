# QuestRoute 模块说明

插件按 `QuestRoute.toc` 顺序执行全部 Lua 文件；不使用 `require`、`loadfile` 或额外加载框架。每个文件通过 `local _, ns = ...` 取得同一份插件命名空间。业务模块只定义功能，最后的 `QuestRoute.lua` 注册命令、桥接 API 和事件，并启动路线。

当前 `apiRevision=15`、`schemaVersion=1`，SavedVariables 为 `QuestRouteDB`，提供 14 个工坊入口及对应 Lua 公开函数。接口契约见[插件 README](README.md)，验证与部署状态统一见[开发进度](../../开发进度.md)。

## 职责与加载顺序

| 文件 | 职责 | 内部接口 |
| --- | --- | --- |
| `Core.lua` | 命名空间、WoWBridge 空壳、共用验证/分页/坐标/距离格式化/屏幕提示工具、路线状态初始化 | `ns.Util`、`ns.WB`、`ns.route` |
| `Database.lua` | 动态发现 QuestieDB、AreaID 映射、实体坐标和任务补充 | `ns.Database` |
| `QuestData.lua` | 原生任务日志、玩家上下文、POI 去重、客户端优先的任务详情 | `ns.QuestData` |
| `Objectives.lua` | 官方进度与数据库实体精确匹配、未完目标地点与原生回退 | `ns.Objectives` |
| `RouteOptions.lua` | 按角色取配置、默认值、规划与姓名板共用的任务过滤 | `ns.RouteOptions` |
| `Priority.lua` | 难度/奖励读取、经验参照、剩余工作量系数与直线距离权重 | `ns.Priority` |
| `Navigation.lua` | 逐目标进度历史、工作会话、状态转换及保护规则 | `ns.Navigation` |
| `Hotspots.lua` | 密度热点、几何缓存、主备摘要、临时避让与清理 | `ns.Hotspots` |
| `Nameplates.lua` | NPC 用途索引、单位任务查询、姓名板图元与清理 | `ns.Nameplates` |
| `Planner.lua` | 候选选择（含任务群加成）、当前目标保持、归组、切换提示、下一张地图提示和路线快照 | `ns.Planner` |
| `RouteActions.lua` | 跳过/恢复、换热点草稿提交、清避让、更新选项 | 既有 `ns.SetQuestSkip` 等公开 API |
| `Settings.lua` | 原生设置页和单次原生回调分发 | `ns.RegisterSettings` |
| `MapPins.lua` | 两图共用投影、编号、悬停/点击、防重叠和备选图元 | `ns.MapPins` |
| `WorldMap.lua` | 大地图/战场地图图层、矩形裁剪 | `ns.WorldMap` |
| `Minimap.lua` | 小地图朝向、圆形裁剪和视野外下一步指示 | `ns.Minimap` |
| `QuestRoute.lua` | 事件/计时驱动、命令、桥接入口、登录/热加载生命周期 | `ns.StartRoute`、`ns.OnUnload`、`ns.OnReload` |

规划依赖任务数据、目标解析、权重、导航、热点和 NPC 用途索引；绘图消费同一份路线快照。地图共用图元不依赖具体地图模块，大地图与小地图各自负责几何裁剪。所有初始化依赖都排在使用者之前。

## 状态与接口约定

- 跨文件只共享必要的函数、规则及标签，放在对应 `ns.*` 模块表；文件内部的实现继续使用 `local`。外部调用沿用原有 `ns.GetPlan` 等公开函数，模块表属于内部实现。
- 路线运行状态只存于 `ns.route`。跨文件函数直接读取 `ns.route`，不要在文件顶层用 `local route = ns.route` 保存引用。换热点期间 `RouteActions` 会将它暂时切换成草稿，调用规划及导航/热点模块，失败恢复原表，成功提交回原表。
- 任务状态和进度继续来自客户端；数据库连接按调用动态发现，QuestieDB 未安装不影响原生功能。
- `Settings.lua` 保留原生设置页和单个追加式回调，热加载只更换当前实例的分发函数。驱动框体及图元池按原规则复用，卸载清理仍集中于入口。

## 修改与验证

修改对应职责文件后，热加载或 watch 的目标使用整个插件目录：

```json
{"target":"QuestRoute"}
```

模块会在加载时取得其他模块的函数引用，因此修改一个模块后也应按清单重载整个插件，使所有消费者取得新函数。不要仅热加载某个 Lua 文件。未安装到游戏时可用仓库绝对目录做离线 `check`。

离线回归在仓库根目录执行：

```powershell
python tests/verify_quest_data.py
```

`--addon` 接受插件目录、`.toc` 或旧入口 `.lua` 路径；入口存在同目录清单时会加载全部文件。测试在隔离 Lua 5.1 中运行，覆盖业务行为与清单加载，并真正重执行整个插件验证同命名空间重载、旧状态补全和新命名空间启动。

新增目录、文件或修改 `.toc` 后，完整退出并重启游戏（本机 `AddOns/QuestRoute` 为指向仓库的目录联接，无需复制）。安装和实机验收进度见[开发进度](../../开发进度.md)，不要用仓库离线结果代替实际启动验证。
