# 装备候选

`get_gear_candidates` 按角色等级、职业、玩法、阵营和可选的当前装备，返回各战斗槽的候选、属性差、启发式分数和来源。它不改地图路线，也不读取角色身上的真实装备。

数据来自[无限图鉴](https://wuxianwow.com)公开 MCP `https://wuxianwow.com/mcp`，客户端 `1.60.1.71037`。本站非官方，版权和免责说明见 <https://wuxianwow.com/legal>。临时掉落来自 Spyglass，转述时保留“临时”。这不是游戏内验证。

## 调用

工坊：

```json
{"addon":"QuestRoute","name":"get_gear_candidates","args":{"level":40,"class":"战士","spec":"防护","faction":"联盟"}}
```

其他插件：

```lua
local result = WoWBridgeNS.QuestRoute.GetGearCandidates({
    level = 40, class = "战士", spec = "防护", faction = "联盟",
})
```

### 输入

| 字段 | 含义 |
| --- | --- |
| `level` | 1 到 60 的整数 |
| `class` | `战士` 或 `warrior`。其他职业返回 `unsupported`，不会套用防护权重 |
| `spec` | `防护` 使用下面的启发式。战士的其他玩法只返回过滤后的候选，分数为空 |
| `faction` | `联盟` 或 `部落` |
| `gear` | 可省略。槽位到物品 ID，或 `{slot=,id=}` 数组，或物品 ID 数组。衬衣、战袍只记在 `ignoredNonCombat` |
| `weights` | 只接受防护权重的数字覆盖。返回里会带回实际使用的整张表 |
| `questLevelWindow` | 任务等级允许高出角色多少，默认 5。这是路线窗口，不是游戏规则 |
| `limit` | 每槽返回条数，默认 8，最大 100 |
| `race` | 只原样回显。种族条件未收录，不过滤 |

`gear` 里查不到的物品放进 `unrecognizedGear`。这种现装不会被当成零属性，对应槽也不判断提升。

### 输出

成功时 `ok=true`。顶层还有 `claim`、`profile`、`slots`、`pair`、`attribution`、`coverageComplete`。`profile.optimum` 恒为 false。`coverageComplete` 恒为 false。

`profile.id=warrior-protection` 时带 `weights` 和 `weightNote`。其他战士玩法的 `profile.scored=false`，`weights` 为空。

`slots` 固定 17 个战斗槽：头、颈、肩、背、胸、腕、手、腰、腿、脚、两枚戒指、两个饰品、主手、副手、远程。没有衬衣和战袍。

每个槽：

| 字段 | 含义 |
| --- | --- |
| `candidates` | 本页候选。`total` 是过滤后的总数 |
| `highlight` | 建议先看的一件。没有合适候选时为空 |
| `emptyReason` / `emptyMessage` | 没有 highlight 的原因 |
| `current` | 现装。`known=false` 表示数据集里没有它 |
| `coverage.complete` | 恒为 false。`kept` 是这个部位采进数据集的件数，`truncated=true` 表示列表在明细前被截断 |
| `filtered` | 因职业、学习等级、需要等级或来源被排除的件数 |

每件候选：

| 字段 | 含义 |
| --- | --- |
| `relation` | `candidate`、`upgrade`、`not_upgrade` |
| `provenUpgrade` | 只有现装已知、而且分数确实更高时为 true |
| `score` / `scoreStatus` | 防护是 `heuristic`。未评分玩法为 `not_scored`，没有分数 |
| `terms` | 每一项属性、权重和得分 |
| `unquantified` | 特效、套装、未映射属性和远程伤害。它们不进分数 |
| `diff` | 现装已知时给出分数差和属性差。未知现装没有这个字段 |
| `wearable` | `known`、`estimated` 或 `unknown` |
| `sources` | 任务或副本掉落，以及下面的获取条件 |
| `conditions.obtainable` | 恒为 `not_confirmed`。能穿不等于现在拿得到 |
| `conditions.questState` | 恒为 `not_checked`。没有角色的完成或领奖状态 |
| `conditions.weaponSkill` / `race` | 恒为 `not_in_dataset` |
| `conditions.accessComplete` | 恒为 false。没写的进入条件不等于没有 |

没有现装时 `relation` 只是 `candidate`，不会写成已经证实的提升。现装更好时 `emptyReason=no_upgrade`，候选仍列出，但 `provenUpgrade=false`。

`pair` 只在防护玩法出现。它把主手和盾的分数相加。双手武器同时占主手和副手，单手或盾不会单独被标成提升；能不能换，只看 `pair.provenUpgrade`。

### 来源字段

任务来源有 `questId`、`name`、`url`、`questLevel`、`minLevel`、`side`、`reward`、`prerequisites`、`questState`。等级或阵营缺失时状态是 `unknown`，不会当成 0 级或双方可接。`prerequisites.status=none_recorded` 只表示记录里没写前置。`sideStatus=temporary` 或 `minLevelStatus=temporary` 时，`confidence=temporary`。

掉落来源有 `npc`、`instanceId`、`instanceName`、`instanceUrl`、`dropChancePercent`、`enterLevel`、`suggestedGroup`、`keys`。掉率缺失是 `unknown`，不是 0。`enterLevel` 是副本准入，高于角色才排除。`suggestedGroup` 是集合石建议，不排除。钥匙单独列出，不排除。`temporary=true`，并带 `disclaimer`。

`appearanceSourceType` 来自外观表。副本首领也可能被标成“世界掉落”，过滤不以它为准。

## 评分

默认权重只服务 40 级战士防护，偏向生存：

| 属性 | 权重 |
| --- | --- |
| 耐力 | 2 |
| 护甲 | 0.02 |
| 防御 | 1.5 |
| 躲闪、招架 | 1.2 |
| 格挡 | 1 |
| 格挡值 | 0.05 |
| 力量 | 0.4 |
| 敏捷 | 0.3 |
| 爆击 | 0.2 |
| 命中、攻击强度 | 0.15 |
| 主手或双手武器 DPS | 1.5 |

智力、精神和其他没列出的属性只出现在 `unquantified`。远程武器的伤害也不计。特效和套装同样不计。`weights` 可以覆盖其中任意一项，实际权重随结果返回。

无限图鉴的 `sort=value` 和战士防护 sim 是 60 级模拟，生存属性在那套模拟里没有被测量。这里不用那套分数。

## 过滤

- 需要等级已知且高于角色：排除。客户端字段为 0 时不当成 0 级；有装等则标 `estimated`（装等 − 5），估值高于角色才排除。
- 职业限制不包括当前职业：排除。空列表表示数据里没写限制。
- `learnAt` 来自无限图鉴这次返回的战士数据。等级低于记录值才排除，例如板甲 40、长柄武器 20。没有记录的武器技能不编造。
- 任务阵营不符，或任务分类属于专业，或可接等级高于角色，或任务等级高于角色加窗口：去掉这个来源。来源都没了，物品就不进候选。专业只看任务分类，不因为目标物品能被制造就排除。
- 掉落必须有副本编号。野外掉落、商人、专业、拍卖和来源不明的不收录。
- 两枚戒指、两个饰品不会是同一件物品。唯一装备分组本身未收录。
- 防护的主手只要单手，副手只要盾。双手武器不进这套搭配。

## 数据怎么来、覆盖到哪

插件只读已经写进 `GearData.lua` 的目录，查询时不再访问图鉴。原始响应在 `tools/gear/cache`，规范化结果在 `tools/gear/catalog.json`。

要按本地缓存重写 Lua：

```text
python tools/gear/refresh_gear.py
```

这条命令不访问网络。只有缓存缺记录、需要补数据时才加 `--fetch`，并且只请求缓存里没有的那几次。缺记录会退出并打印缺的工具和参数。脚本只用 `stats`、`gear_items`、`item_usage`、`quests`、`instances`、`npcs`。

采集范围是战士、需要等级不超过 40 的优秀到史诗装备。每个部位先按装等保留最多 18 条带任务或掉落描述的记录（饰品这次明细 12 条），再逐件核对。校验物品 7726、10767、10823、6802、279831、279908 会额外拉取。279831、279908 留在数据里，40 级查询会因为任务等级把它们排除。

这次一共 486 次只读 MCP 调用，客户端 `1.60.1.71037`，写入时间见 `catalog.json` 的 `fetchedAt`。最后一次重建使用缓存，没有新的网络请求。261 件留下任务或副本关联，3 件明细后仍对不上副本：层叠肩甲（274607）、拳节指环（274614）、破天投矛（287070）。

| 部位 | 列表 | 明细 | 留下 | 截断 |
| --- | --- | --- | --- | --- |
| 头 | 245 | 18 | 18 | 是 |
| 颈 | 89 | 18 | 18 | 是 |
| 肩 | 216 | 18 | 17 | 是 |
| 背 | 251 | 18 | 18 | 是 |
| 胸 | 298 | 18 | 18 | 是 |
| 腕 | 240 | 18 | 18 | 是 |
| 手 | 286 | 18 | 18 | 是 |
| 腰 | 307 | 18 | 18 | 是 |
| 腿 | 283 | 18 | 18 | 是 |
| 脚 | 320 | 18 | 18 | 是 |
| 戒指 | 184 | 18 | 17 | 是 |
| 饰品 | 41 | 12 | 12 | 否 |
| 盾 | 163 | 18 | 18 | 是 |
| 单手 | 272 | 18 | 18 | 是 |
| 远程 | 142 | 18 | 17 | 是 |

留下的件数不是 40 级、某一阵营过滤后的候选数。除饰品外，每个部位都还有没拉明细的记录，不能称为全量。有的临时掉落只带副本、没有 NPC 名。

## 测试和示例

```text
python tests/verify_gear.py
python tests/verify_quest_data.py
python tests/verify_associations.py
```

`verify_gear.py` 不连游戏。它检查等级、职业、护甲学习、任务阵营和前置未知、世界掉落与副本掉落、缺失等级、戒指饰品去重、单手加盾、现装不提升、空数据、排序，以及上面这份 40 级防护数据。通过时写出：

`addons/QuestRoute/examples/gear-40-warrior-protection.json`

这是联盟 40 级战士防护、没有现装、每槽最多 5 条的结果。没有现装，所以里面是候选，不是已证实提升。

新增 `GearData.lua`、`Gear.lua` 后要完整退出游戏再启动。热加载不能代替这次启动检查。
