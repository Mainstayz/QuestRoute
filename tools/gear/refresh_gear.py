# -*- coding: utf-8 -*-
"""用无限图鉴公开 MCP 重建 QuestRoute 的战士防护候选数据。

只调用 https://wuxianwow.com/mcp 的只读工具：stats、gear_items、item_usage、
quests、instances、npcs。不调用 report_issue，不猜站点私有接口。

  python tools/gear/refresh_gear.py
  python tools/gear/refresh_gear.py --fetch

默认只读 tools/gear/cache，不访问网络。--fetch 只补缓存里没有的调用。缺记录时退出并写出缺的工具和参数。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / "tools" / "gear" / "cache"
CATALOG_JSON = ROOT / "tools" / "gear" / "catalog.json"
LUA_PATH = ROOT / "addons" / "QuestRoute" / "GearData.lua"
MCP_URL = "https://wuxianwow.com/mcp"
ALLOWED = {"stats", "gear_items", "item_usage", "quests", "instances", "npcs"}
FORCE_IDS = (7726, 10767, 10823, 6802, 279831, 279908)
SLOT_NAMES = (
    ("head", ("头部",)),
    ("neck", ("颈部", "项链")),
    ("shoulder", ("肩部", "肩膀")),
    ("back", ("背部", "披风")),
    ("chest", ("胸部", "胸甲")),
    ("wrist", ("手腕",)),
    ("hands", ("手", "手套", "手部")),
    ("waist", ("腰部", "腰带")),
    ("legs", ("腿部", "腿")),
    ("feet", ("脚", "脚部")),
    ("finger", ("戒指", "手指")),
    ("trinket", ("饰品",)),
    ("offhand", ("盾牌",)),
    ("mainhand", ("单手",)),
    ("ranged", ("远程",)),
)
POOL_BY_SLOT = {
    "头部": "head", "颈部": "neck", "肩部": "shoulder", "背部": "back", "胸部": "chest",
    "手腕": "wrist", "手": "hands", "手部": "hands", "腰部": "waist", "腿部": "legs",
    "脚": "feet", "手指": "finger", "戒指": "finger", "饰品": "trinket",
    "副手盾": "offhand", "盾牌": "offhand", "单手": "mainhand", "主手": "mainhand",
    "双手": "twohand", "远程": "ranged", "远程武器": "ranged",
}
STAT_KEYS = {
    "耐力": "stamina", "力量": "strength", "敏捷": "agility", "智力": "intellect",
    "精神": "spirit", "攻击强度": "attackPower", "防御等级": "defense",
    "躲闪等级": "dodge", "招架等级": "parry", "格挡等级": "block", "格挡值": "blockValue",
    "爆击等级": "crit", "命中等级": "hit", "躲闪": "dodge", "招架": "parry", "格挡": "block",
}
DETAIL_CAP = 18
SLEEP_SECONDS = 0.2


class CatalogError(RuntimeError):
    pass


def cache_path(tool: str, arguments: dict) -> Path:
    digest = hashlib.sha1(
        json.dumps({"tool": tool, "arguments": arguments}, ensure_ascii=False, sort_keys=True).encode("utf-8")
    ).hexdigest()[:16]
    return CACHE / tool / f"{digest}.json"


def call_mcp(tool: str, arguments: dict, from_cache: bool, stats: dict) -> dict:
    if tool not in ALLOWED:
        raise CatalogError(f"拒绝调用未允许的工具: {tool}")
    path = cache_path(tool, arguments)
    if path.is_file():
        stats["cacheHits"] = stats.get("cacheHits", 0) + 1
        return json.loads(path.read_text(encoding="utf-8"))["response"]
    if from_cache:
        raise CatalogError(
            "缓存缺少这次只读调用，需要补导出后重跑：\n"
            + json.dumps({"tool": tool, "arguments": arguments}, ensure_ascii=False)
        )
    body = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": arguments}}
    ).encode("utf-8")
    request = urllib.request.Request(
        MCP_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "User-Agent": "Mozilla/5.0",
            "MCP-Protocol-Version": "2025-03-26",
        },
    )
    last_error = None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                payload = json.loads(response.read().decode("utf-8"))
            break
        except urllib.error.HTTPError as error:
            last_error = error
            if error.code not in (429, 500, 502, 503, 504) or attempt == 3:
                raise CatalogError(f"{tool} HTTP {error.code}: {error.read()[:300]!r}") from error
            time.sleep(2 + attempt)
        except urllib.error.URLError as error:
            last_error = error
            if attempt == 3:
                raise CatalogError(f"{tool} 网络失败: {error}") from error
            time.sleep(2 + attempt)
    else:
        raise CatalogError(str(last_error))
    if "error" in payload:
        raise CatalogError(f"{tool} RPC 错误: {payload['error']}")
    content = payload.get("result", {}).get("content") or []
    if not content or content[0].get("type") != "text":
        raise CatalogError(f"{tool} 没有文本结果")
    parsed = json.loads(content[0]["text"])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps({"tool": tool, "arguments": arguments, "response": parsed}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    stats["requests"] += 1
    time.sleep(SLEEP_SECONDS)
    return parsed


def skip_row(row: dict) -> bool:
    if row.get("crafted"):
        return True
    source = row.get("source_type") or ""
    obtain = row.get("obtain") or ""
    if source in ("商人", "专业") or any(word in obtain for word in ("商人", "军需官", "专业", "拍卖")):
        return True
    if "任务" in obtain or source == "任务":
        return False
    if "掉落" in obtain or "各处" in obtain:
        return False
    return True


def list_slot(slot_name: str, quality: str, from_cache: bool, stats: dict):
    offset = 0
    rows = []
    first = None
    while offset <= 160:
        page = call_mcp(
            "gear_items",
            {
                "class": "战士",
                "slot": slot_name,
                "max_req": 40,
                "quality": quality,
                "sort": "ilvl",
                "limit": 40,
                "offset": offset,
            },
            from_cache,
            stats,
        )
        first = first or page
        if page.get("outcome") != "ok":
            return page, rows
        rows.extend(page.get("results") or [])
        if not page.get("has_more"):
            break
        offset += page.get("limit") or 40
    return first, rows


def positive(value):
    return value if isinstance(value, int) and value > 0 else None


def side_of(reward: dict, quest: dict | None):
    if reward.get("side") in ("联盟", "部落"):
        return reward["side"], "server"
    if quest and quest.get("side") in ("联盟", "部落"):
        return quest["side"], "server"
    if quest and quest.get("temporary_side") in ("联盟", "部落"):
        return quest["temporary_side"], "temporary"
    return None, "unknown"


def profession_category(quest: dict | None):
    if not quest:
        return None
    for link in quest.get("profession_links") or []:
        if link.get("kind") == "category" and link.get("profession"):
            return link["profession"]
    return None


def level_status(value, temporary=False):
    number = positive(value) if isinstance(value, int) else None
    if number is None:
        return None, "unknown"
    return number, "temporary" if temporary else "known"


def prerequisite_ids(quest: dict | None):
    if not quest or not isinstance(quest.get("previous_quests"), list):
        return {"status": "unknown", "ids": []}
    found = []
    for entry in quest["previous_quests"]:
        if isinstance(entry, int):
            found.append(entry)
        elif isinstance(entry, dict):
            number = entry.get("quest_id") or entry.get("id")
            if isinstance(number, int):
                found.append(number)
    if not found and not quest["previous_quests"]:
        return {"status": "none_recorded", "ids": []}
    if not found:
        return {"status": "unknown", "ids": []}
    return {"status": "recorded", "ids": found}


def pool_of(equipment: dict):
    slot = equipment.get("slot") or ""
    weapon = equipment.get("weapon_type") or ""
    armor = equipment.get("armor_type") or ""
    if "双手" in weapon or slot == "双手":
        return "twohand", 2, armor or weapon
    pool = POOL_BY_SLOT.get(slot)
    if pool == "offhand" and armor not in ("", "盾牌"):
        return "held", 0, armor or weapon
    if pool == "mainhand":
        return "mainhand", 1, weapon or armor
    if pool == "offhand":
        return "offhand", 0, armor or "盾牌"
    return pool or "unknown", 0, armor or weapon


def build_item(detail: dict, listed: dict | None) -> dict:
    equipment = detail.get("equipment") or {}
    pool, hands, subtype = pool_of(equipment)
    stats = {}
    unmapped = []
    if isinstance(equipment.get("armor"), (int, float)):
        stats["armor"] = equipment["armor"]
    for row in equipment.get("stats") or []:
        key = STAT_KEYS.get(row.get("stat"))
        if key:
            stats[key] = row.get("value")
        elif row.get("stat"):
            unmapped.append({"stat": row.get("stat"), "value": row.get("value")})
    listed = listed or {}
    req = detail.get("req_level")
    if not isinstance(req, int):
        req = equipment.get("req_level")
    ilvl = detail.get("ilvl") if isinstance(detail.get("ilvl"), int) else equipment.get("ilvl")
    if isinstance(req, int) and req > 0:
        req_level, req_status, estimate = req, "known", None
    else:
        estimate = listed.get("req_estimate")
        if not isinstance(estimate, int) and isinstance(ilvl, int):
            estimate = ilvl - 5
        req_level, req_status = None, "estimated" if isinstance(estimate, int) else "unknown"
    damage = equipment.get("damage") if isinstance(equipment.get("damage"), dict) else None
    weapon = None
    if damage and isinstance(damage.get("dps"), (int, float)):
        weapon = {
            "dps": damage.get("dps"),
            "min": damage.get("min"),
            "max": damage.get("max"),
            "speed": damage.get("speed"),
        }
    set_name = None
    if isinstance(listed.get("set"), dict):
        set_name = listed["set"].get("name") or listed["set"].get("title")
    elif isinstance(listed.get("set"), str):
        set_name = listed["set"]
    return {
        "id": detail.get("item_id"),
        "name": detail.get("title"),
        "url": detail.get("url"),
        "quality": detail.get("quality"),
        "ilvl": ilvl,
        "slot": pool,
        "subtype": subtype,
        "armorType": equipment.get("armor_type"),
        "hands": hands,
        "reqLevel": req_level,
        "reqEstimate": estimate,
        "reqLevelStatus": req_status,
        "classes": listed.get("classes") or [],
        "uniqueStatus": "unknown",
        "setName": set_name,
        "stats": stats,
        "unmappedStats": unmapped,
        "statsSource": equipment.get("stats_source"),
        "weapon": weapon,
        "effects": [row.get("text") for row in (detail.get("effects") or []) if row.get("text")],
        "appearanceSourceType": detail.get("source_type"),
        "sources": [],
        "_detail": detail,
    }


def npc_id_of(drop: dict):
    fetch = drop.get("fetch_id") or ""
    if isinstance(fetch, str) and fetch.startswith("npc:"):
        number = fetch.split(":", 1)[1]
        if number.isdigit():
            return int(number)
    number = drop.get("npc_id")
    if isinstance(number, int) and number >= 900000:
        return number
    return None


def instance_from_npc(record: dict):
    instance = record.get("instance") if isinstance(record.get("instance"), dict) else {}
    encounter = record.get("encounter") if isinstance(record.get("encounter"), dict) else {}
    encounter_instance = encounter.get("instance") if isinstance(encounter.get("instance"), dict) else {}
    instance_id = instance.get("id") or instance.get("instance_id") or encounter_instance.get("instance_id")
    if not isinstance(instance_id, int):
        return None
    return {
        "instance_id": instance_id,
        "url": instance.get("url") or encounter_instance.get("url"),
        "name": instance.get("name") or record.get("dungeon"),
    }


def attach_sources(item: dict, quests: dict, instances: dict, npcs: dict) -> list[str]:
    detail = item.pop("_detail")
    reasons = []
    for reward in detail.get("quest_rewards") or []:
        quest = quests.get(reward.get("quest_id"))
        quest_level, quest_level_status = level_status(quest.get("level") if quest else reward.get("level"))
        if quest_level is None:
            quest_level, quest_level_status = level_status(reward.get("level"))
        min_level, min_status = (None, "unknown")
        if quest:
            min_level, min_status = level_status(quest.get("min_level"))
            if min_status == "unknown":
                min_level, min_status = level_status(quest.get("temporary_min_level"), temporary=True)
        faction, faction_status = side_of(reward, quest)
        item["sources"].append(
            {
                "kind": "quest",
                "temporary": faction_status == "temporary" or min_status == "temporary",
                "confidence": "temporary" if faction_status == "temporary" or min_status == "temporary" else "server",
                "questId": reward.get("quest_id"),
                "name": (quest or {}).get("title") or reward.get("name"),
                "url": reward.get("url"),
                "questLevel": quest_level,
                "questLevelStatus": quest_level_status,
                "minLevel": min_level,
                "minLevelStatus": min_status,
                "side": faction,
                "sideStatus": "unknown" if faction_status == "unknown" else faction_status,
                "reward": reward.get("reward"),
                "prerequisites": prerequisite_ids(quest),
                "questState": "not_checked",
                "profession": profession_category(quest),
            }
        )
    drops = ((detail.get("temporary_sources") or {}).get("drops")) or []
    for drop in drops:
        instance = drop.get("instance") if isinstance(drop.get("instance"), dict) else {}
        instance_id = instance.get("instance_id") if isinstance(instance.get("instance_id"), int) else None
        link = "drop"
        if instance_id is None:
            npc_key = npc_id_of(drop)
            linked = instance_from_npc(npcs.get(npc_key) or {}) if npc_key else None
            if not linked:
                reasons.append(f"掉落没有副本编号: {drop.get('name')}")
                continue
            instance = linked
            instance_id = linked["instance_id"]
            link = "npc"
        record = instances.get(instance_id)
        level = (record or {}).get("level") if isinstance((record or {}).get("level"), dict) else {}
        enter = level.get("min") if isinstance(level.get("min"), int) else None
        group = level.get("group") if isinstance(level.get("group"), list) else None
        keys = []
        for entry in (record or {}).get("access") or []:
            key_item = entry.get("item") or {}
            if entry.get("kind") == "key" and key_item.get("name"):
                keys.append(
                    {
                        "itemId": key_item.get("item_id"),
                        "name": key_item.get("name"),
                        "temporary": bool(entry.get("drops_from")),
                    }
                )
        chance = drop.get("drop_chance_percent")
        item["sources"].append(
            {
                "kind": "drop",
                "temporary": True,
                "confidence": "temporary",
                "disclaimer": "临时掉落，来自 Spyglass，不是客户端掉落表",
                "npc": drop.get("name"),
                "npcId": drop.get("npc_id"),
                "dropChancePercent": chance if isinstance(chance, (int, float)) else None,
                "dropChanceStatus": "temporary" if isinstance(chance, (int, float)) else "unknown",
                "instanceId": instance_id,
                "instanceName": (record or {}).get("title") or drop.get("zone"),
                "instanceUrl": instance.get("url") or f"https://wuxianwow.com/instance/{instance_id}",
                "instanceLink": link,
                "enterLevel": enter,
                "enterLevelStatus": "recorded" if isinstance(enter, int) else "unknown",
                "suggestedGroup": group,
                "keys": keys,
                "accessComplete": False,
            }
        )
    if not item["sources"]:
        reasons.append("没有任务奖励，也没有关联到副本的掉落")
    return reasons


def lua_literal(value, indent=0) -> str:
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, float):
        text = f"{value:.4f}".rstrip("0").rstrip(".")
        return text or "0"
    if isinstance(value, str):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "\\r").replace("\n", "\\n")
        return f'"{escaped}"'
    pad = "  " * indent
    inner = "  " * (indent + 1)
    if isinstance(value, list):
        if not value:
            return "{}"
        rows = [lua_literal(entry, indent + 1) for entry in value]
        return "{\n" + ",\n".join(inner + row for row in rows) + "\n" + pad + "}"
    if isinstance(value, dict):
        if not value:
            return "{}"
        rows = []
        for key in sorted(value):
            rows.append(f"{inner}[{lua_literal(str(key))}] = {lua_literal(value[key], indent + 1)}")
        return "{\n" + ",\n".join(rows) + "\n" + pad + "}"
    raise CatalogError(f"不能写成 Lua: {type(value)}")


def choose_rows(rows: list[dict]) -> list[dict]:
    ordered = []
    seen = set()
    for row in rows:
        number = int(str(row.get("id", "")).split(":")[-1])
        if number in seen or skip_row(row):
            continue
        ordered.append(row)
        seen.add(number)
        if len(ordered) >= DETAIL_CAP:
            break
    return ordered


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fetch", action="store_true", help="缓存没有的记录才访问图鉴")
    parser.add_argument("--from-cache", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    from_cache = not args.fetch
    stats = {"requests": 0}
    try:
        info = call_mcp("stats", {}, from_cache, stats)
    except CatalogError as error:
        print(error, file=sys.stderr)
        return 1
    learn_at = {}
    coverage = {}
    listed_by_id = {}
    selected = {}
    try:
        for pool, names in SLOT_NAMES:
            page = None
            rows = []
            used = None
            for name in names:
                page, rows = list_slot(name, "精良,史诗", from_cache, stats)
                if page.get("outcome") == "ok":
                    used = name
                    break
            uncommon_rows = []
            if used:
                _, uncommon_rows = list_slot(used, "优秀", from_cache, stats)
            if page and page.get("outcome") == "ok":
                matched = ((page.get("matched") or {}).get("class") or {}).get("learn_at") or {}
                learn_at.update(matched)
            picked = choose_rows(rows + uncommon_rows)
            coverage[pool] = {
                "query": used,
                "listed": len(rows) + len(uncommon_rows),
                "detailed": len(picked),
                "truncated": len([row for row in rows + uncommon_rows if not skip_row(row)]) > len(picked),
                "kept": 0,
            }
            if page and page.get("outcome") != "ok":
                coverage[pool]["error"] = page.get("outcome")
            for row in rows + uncommon_rows:
                listed_by_id[int(str(row["id"]).split(":")[-1])] = row
            for row in picked:
                selected[int(str(row["id"]).split(":")[-1])] = pool
            print(f"{pool}: listed={coverage[pool]['listed']} detailed={coverage[pool]['detailed']}", flush=True)
        for number in FORCE_IDS:
            selected.setdefault(number, None)
        details = {}
        for number in sorted(selected):
            detail = call_mcp("item_usage", {"item": number}, from_cache, stats)
            if detail.get("outcome") != "ok":
                print(f"item {number}: {detail.get('outcome')}", flush=True)
                continue
            details[number] = detail
        quest_ids = set()
        instance_ids = set()
        npc_ids = set()
        for detail in details.values():
            for reward in detail.get("quest_rewards") or []:
                if isinstance(reward.get("quest_id"), int):
                    quest_ids.add(reward["quest_id"])
            for drop in ((detail.get("temporary_sources") or {}).get("drops")) or []:
                instance = drop.get("instance") if isinstance(drop.get("instance"), dict) else {}
                if isinstance(instance.get("instance_id"), int):
                    instance_ids.add(instance["instance_id"])
                else:
                    npc_key = npc_id_of(drop)
                    if npc_key:
                        npc_ids.add(npc_key)
        print(f"npc lookups {len(npc_ids)}", flush=True)
        npcs = {}
        for index, npc_id in enumerate(sorted(npc_ids), start=1):
            record = call_mcp("npcs", {"id": npc_id}, from_cache, stats)
            if record.get("outcome") == "ok":
                npcs[npc_id] = record
                linked = instance_from_npc(record)
                if linked:
                    instance_ids.add(linked["instance_id"])
            if index % 25 == 0:
                print(f"npcs {index}/{len(npc_ids)}", flush=True)
        quests = {}
        for quest_id in sorted(quest_ids):
            record = call_mcp("quests", {"id": quest_id}, from_cache, stats)
            if record.get("outcome") == "ok":
                quests[quest_id] = record
        instances = {}
        for instance_id in sorted(instance_ids):
            record = call_mcp("instances", {"id": instance_id}, from_cache, stats)
            if record.get("outcome") == "ok":
                instances[instance_id] = record
    except CatalogError as error:
        print(error, file=sys.stderr)
        return 1

    items = []
    rejected = []
    for number, detail in sorted(details.items()):
        item = build_item(detail, listed_by_id.get(number))
        if item["slot"] == "unknown" and selected.get(number) in POOL_BY_SLOT.values():
            item["slot"] = selected[number]
        reasons = attach_sources(item, quests, instances, npcs)
        if not item["sources"]:
            rejected.append({"id": number, "name": item["name"], "reasons": reasons})
            continue
        items.append(item)
        pool = item["slot"]
        if pool in coverage:
            coverage[pool]["kept"] += 1
    for pool in coverage:
        coverage[pool]["complete"] = False
    catalog = {
        "meta": {
            "sourceName": "无限图鉴 wuxianwow.com",
            "sourceUrl": "https://wuxianwow.com",
            "legal": info.get("legal", {}).get("url") or "https://wuxianwow.com/legal",
            "clientBuild": info.get("build"),
            "dataWritten": (info.get("server") or {}).get("written"),
            "fetchedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "mcp": MCP_URL,
            "requestCount": stats["requests"] + stats.get("cacheHits", 0),
            "lastRunNetworkRequests": stats["requests"],
            "complete": False,
            "note": "只保留任务奖励和能关联到副本的掉落。每个部位都不是全量。评分不在这份数据里。",
            "learnAt": learn_at,
            "slots": coverage,
            "rejected": rejected,
        },
        "items": items,
    }
    CATALOG_JSON.write_text(json.dumps(catalog, ensure_ascii=False, indent=2), encoding="utf-8")
    lua = (
        "-- 由 tools/gear/refresh_gear.py 生成，不要手改。\n"
        "local _, ns = ...\n"
        "ns.GearCatalog = "
        + lua_literal(catalog)
        + "\n"
    )
    LUA_PATH.write_text(lua, encoding="utf-8")
    print(f"items={len(items)} rejected={len(rejected)} network_requests={stats['requests']}")
    print(f"wrote {CATALOG_JSON}")
    print(f"wrote {LUA_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
