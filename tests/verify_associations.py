"""Deterministic, offline association/lookahead checks in isolated Lua 5.1 runtimes.

Requires the existing lupa dependency; never connects to the game.
Run: python tests/verify_associations.py
Uses the same --addon directory/.toc/.lua resolution as verify_quest_data.py.
"""
import argparse
from pathlib import Path

from lupa.lua51 import LuaRuntime
from verify_quest_data import DEFAULT_ADDON, SETUP, execute_addon, read_addon_sources


FIXTURE = r'''
Fixture.worldScale=10000
Fixture.mapOrder={101}
Fixture.quests={}; Fixture.log={}; Fixture.status={}; Fixture.official={}
Fixture.completed={}; Fixture.historyUnknown={}; Fixture.bags={}; Fixture.items={}
Fixture.locations={npc={},object={}}; Fixture.offered={}
QUEST_MONSTERS_KILLED='%s: %d/%d'
QUEST_OBJECTS_FOUND='%s: %d/%d'
QUEST_ITEMS_NEEDED='%s: %d/%d'
function UnitClass() return 'Warrior','WARRIOR',1 end
function UnitRace() return 'Orc','Orc',2 end
C_QuestLog.GetNumQuestLogEntries=function() return #Fixture.log,#Fixture.log end
C_QuestLog.IsOnQuest=function(id)
    for _,activeID in ipairs(Fixture.log) do if activeID==id then return true end end
    return false
end
C_QuestLog.GetInfo=function(i)
    local id=Fixture.log[i]
    return {questID=id,title='Quest '..id,level=19,questLogIndex=i,isHeader=false}
end
C_QuestLog.GetQuestTagInfo=function() return nil end
C_QuestLog.GetQuestType=function() return 0 end
C_QuestLog.IsEliteQuest=function(id) return Fixture.quests[id] and Fixture.quests[id].elite==true or false end
C_QuestLog.IsFailed=function(id) return Fixture.status[id]=='failed' end
C_QuestLog.IsComplete=function(id)
    return Fixture.status[id]=='complete' or Fixture.status[id]=='ready_for_turn_in'
end
C_QuestLog.ReadyForTurnIn=function(id) return Fixture.status[id]=='ready_for_turn_in' end
C_QuestLog.IsQuestFlaggedCompleted=function(id)
    if Fixture.historyUnknown[id] then return nil end
    return Fixture.completed[id]==true
end
C_QuestLog.GetQuestObjectives=function(id)
    if Fixture.official[id] then return Fixture.official[id] end
    local out={}
    local groups=(Fixture.quests[id] or {}).objectives or {}
    for group,kind in ipairs({'npc','object','item'}) do
        for _,row in ipairs(groups[group] or {}) do
            out[#out+1]={text=kind..row[1]..': 0/1',type=group==1 and 'monster' or kind,
                finished=false,numFulfilled=0,numRequired=1}
        end
    end
    return out
end
C_GossipInfo={GetAvailableQuests=function() return Fixture.offered end}
C_Container={
    GetContainerNumSlots=function(bag) return bag==0 and #Fixture.bags or 0 end,
    GetContainerItemID=function(bag,slot) return bag==0 and Fixture.bags[slot] or nil end,
    GetContainerItemQuestInfo=function() return nil end,
}
FixtureDB.Quest={
    Exists=function(id) return Fixture.quests[id]~=nil end,
    Get=function(id,field) return (Fixture.quests[id] or {})[field] end,
    GetAllIds=function()
        local ids={}; for id in pairs(Fixture.quests) do ids[#ids+1]=id end
        table.sort(ids); return ids
    end,
}
for _,field in ipairs({'name','questLevel','requiredLevel','requiredSkill','objectivesText','objectives',
    'startedBy','finishedBy','preQuestSingle','preQuestGroup','childQuests','nextQuestInChain','exclusiveTo'}) do
    FixtureDB.Quest[field]=function(id) return FixtureDB.Quest.Get(id,field) end
end
for _,kind in ipairs({'npc','object'}) do
    local entityKind=kind
    local entity={
        Exists=function(id) return Fixture.locations[entityKind][id]~=nil end,
        name=function(id) return entityKind..id end,
        spawns=function(id) return Fixture.locations[entityKind][id] or {} end,
    }
    FixtureDB[kind=='npc' and 'Npc' or 'Object']=entity
end
FixtureDB.Item={
    Exists=function(id) return Fixture.items[id]~=nil end,
    name=function(id) return 'item'..id end,
    startQuest=function(id) return (Fixture.items[id] or {}).quest or 0 end,
}
for _,field in ipairs({'npcDrops','objectDrops','itemDrops','vendors'}) do
    FixtureDB.Item[field]=function(id) return (Fixture.items[id] or {})[field] or {} end
end
'''

HELPERS = r'''
local ns=...
local checks=0
local function check(value,label)
    assert(value,'FAIL: '..label)
    checks=checks+1
end
local function has(values,value)
    for _,item in ipairs(values or {}) do if item==value then return true end end
    return false
end
local function action(actions,id,kind)
    for index,item in ipairs(actions or {}) do
        if item.questID==id and item.action==kind then return item,index end
    end
end
local function point(id,x,y,key)
    return {key=key or 'npc:'..id,objectiveKey=key or 'npc:'..id,
        world={continentID=1,x=x,y=y or 0},coordinateMapID=101,reportedMapID=101,
        x=x/10000,y=(y or 0)/10000,entityKind='npc',entityID=id,shareable=true}
end
local function model(id,active,x,key)
    return {questID=id,title='Quest '..id,active=active==true,
        status=active and 'in_progress' or 'not_accepted',eligibility='eligible',rewardWeight=1,
        targets={point(501,x or 1000,0,key)},targetsComplete=true,
        starters={point(10000+id,100)},finishers={point(20000+id,x or 1000)}}
end
local function evaluate(quests,baselineID,completed)
    local data={available=true,quests=quests,completed=completed or {},opportunities={}}
    local candidates={}
    for id,quest in pairs(quests) do
        if quest.active then candidates[#candidates+1]={quest=quest}
        else data.opportunities[#data.opportunities+1]={questID=id,action='pick_up'} end
    end
    local baseline
    if baselineID then
        local quest=quests[baselineID]
        local delivery=quest.status=='ready_for_turn_in'
        baseline={questID=baselineID,action=delivery and 'turn_in' or 'quest_area',
            point=delivery and quest.finishers[1] or quest.targets[1],
            objectiveKey=not delivery and quest.targets[1].key or nil}
    end
    return ns.Decision.Evaluate(data,candidates,point(1,0).world,baseline)
end
local function place(kind,id,x,y)
    Fixture.locations[kind][id]={[17]={{x/100,(y or 0)/100}}}
end
local function record(id,x,fields)
    local row={name='Quest '..id,questLevel=19,requiredLevel=1,
        startedBy={[1]={10000+id}},finishedBy={[1]={20000+id}},
        objectives={[1]={{501,nil,0}}},preQuestSingle={},preQuestGroup={},exclusiveTo={},childQuests={}}
    for key,value in pairs(fields or {}) do row[key]=value end
    Fixture.quests[id]=row
    place('npc',10000+id,x or 100); place('npc',20000+id,1000)
    if not Fixture.locations.npc[501] then place('npc',501,1000) end
    return row
end
local function candidates()
    local out={}
    for id,entry in pairs(ns.QuestData.ActiveQuestIndex()) do
        local quest=ns.QuestData.ReadQuest(entry.info,entry.category,false)
        quest.objectives=C_QuestLog.GetQuestObjectives(id); quest.objectivesLoaded=true
        local resolution=ns.Objectives.ReadLocations(FixtureDB,{version='fixture',contract=4},quest)
        out[#out+1]={quest=quest,points=resolution.points,resolution=resolution,priorityWeight=1}
    end
    return out
end
local function finishIndex()
    for _=1,10000 do if ns.Discovery.Pump() then return end end
    error('fixture index failed to finish')
end
local function collect(items)
    local context,active=ns.GetPlayerContext({}),ns.QuestData.ActiveQuestIndex()
    local data=ns.Discovery.Collect(context,active,items or candidates(),ns.RouteOptions.Get())
    check(data.available,'fixture database is available')
    if data.building then finishIndex() end
    data=ns.Discovery.Collect(context,active,items or candidates(),ns.RouteOptions.Get())
    check(not data.building and data.scanned==data.total,'bounded local index build completes')
    return data
end
local function plan()
    ns.RouteOptions.Get().switchNotice=false
    local first=ns.Replan({})
    check(first.ok,'initial plan succeeds')
    if first.discovery.building then finishIndex() end
    local result=ns.Replan({})
    check(result.ok,'indexed plan succeeds')
    return result
end
'''

CASES = (
    ("Decision: deliver prerequisite before collecting shared work", r'''
local a,b,c=model(101,true),model(201,true),model(301,false)
a.status='ready_for_turn_in'; a.targets={}; a.finishers={point(601,100)}
c.eligibility='blocked'; c.conditionReason='prerequisite'; c.preAll={101}
local result=evaluate({[101]=a,[201]=b,[301]=c},201)
check(result.recommendation and result.recommendation.questID==101
    and result.recommendation.action=='turn_in','deliver prerequisite first')
local _,delivery=action(result.predicted,101,'turn_in')
local _,pickup=action(result.predicted,301,'pick_up')
local _,work=action(result.predicted,201,'quest_area')
check(delivery and pickup and work and delivery<pickup and pickup<work,'delivery then pickup then shared work')
check(c.active==false and c.eligibility=='blocked' and a.status=='ready_for_turn_in','simulation leaves source state unchanged')
'''),
    ("Decision: profitable pickup precedes clearing the same monster", r'''
local a,b=model(201,true),model(301,false)
local result=evaluate({[201]=a,[301]=b},201)
check(result.recommendation and result.recommendation.action=='pick_up'
    and result.recommendation.questID==301,'collect before clearing')
check(result.baselineScore and result.bestScore-result.baselineScore>=80,'beats a separately searched baseline')
local workCount=0
for index,step in ipairs(result.predicted) do
    if step.action=='quest_area' then workCount=workCount+1; check(step.sharedGoalCount==2,'same key completes both accepted goals') end
    check(step.predicted and step.executable==(index==1),'all simulation is predicted and only first action is currently executable')
end
check(workCount==1,'same key pays work once')
check(not b.active and b.status=='not_accepted','predicted acceptance is not written back')
'''),
    ("Decision: distant pickup does not replace a better original route", r'''
local a,b=model(201,true),model(301,false)
b.starters={point(603,5000)}
local result=evaluate({[201]=a,[301]=b},201)
check(not result.recommendation and result.reason=='keep_current_route','unprofitable pickup keeps baseline')
check(result.baselineScore==result.bestScore,'baseline branch remains competitive')
'''),
    ("Decision: AND requires all delivered prerequisites, OR requires one", r'''
local a,b=model(201,true),model(301,false)
b.eligibility='blocked'; b.conditionReason='prerequisite'; b.preAll={401,402}
local all=evaluate({[201]=a,[301]=b},201,{[401]=true,[402]=false})
check(not action(all.predicted,301,'pick_up'),'one delivered prerequisite cannot satisfy AND')
b.preAll={}; b.preAny={401,402}
local any=evaluate({[201]=a,[301]=b},201,{[401]=true,[402]=false})
check(action(any.predicted,301,'pick_up'),'one delivered prerequisite satisfies OR')
b.preAny={401,402}
local none=evaluate({[201]=a,[301]=b},201,{[401]=false,[402]=false})
check(not action(none.predicted,301,'pick_up'),'no delivered prerequisite cannot satisfy OR')
b.preAll={403}
check(not action(evaluate({[201]=a,[301]=b},201,{[401]=true}).predicted,301,'pick_up'),
    'satisfied OR cannot bypass a missing AND prerequisite')
check(not action(evaluate({[201]=a,[301]=b},201,{[403]=true}).predicted,301,'pick_up'),
    'satisfied AND cannot bypass a missing OR prerequisite')
check(action(evaluate({[201]=a,[301]=b},201,{[401]=true,[403]=true}).predicted,301,'pick_up'),
    'combined AND and OR require both expressions')
'''),
    ("Decision: complete or accepted is not delivered", r'''
local a,b,c=model(101,true),model(201,true),model(301,false)
a.status='complete'; a.targets={}; a.finishers={point(601,0)}
c.eligibility='blocked'; c.conditionReason='prerequisite'; c.preAny={101}
local result=evaluate({[101]=a,[201]=b,[301]=c},201)
check(not action(result.predicted,101,'turn_in'),'complete without ready does not fabricate delivery')
check(not action(result.predicted,301,'pick_up'),'accepted or complete prerequisite does not unlock followup')
'''),
    ("Decision: different item keys on one NPC do not complete each other", r'''
local a,b=model(201,true),model(202,false,1000,'item:601')
local result=evaluate({[201]=a,[202]=b},201)
local _,first=action(result.predicted,201,'quest_area')
local _,second=action(result.predicted,202,'quest_area')
check(first and second,'both distinct goals still need work')
for _,id in ipairs({201,202}) do
    local _,work=action(result.predicted,id,'quest_area')
    local _,delivery=action(result.predicted,id,'turn_in')
    check(delivery and work<delivery,'partial same-NPC synergy cannot fabricate completed material')
end
'''),
    ("Decision: uncertain target coverage cannot unlock a followup", r'''
local a,b=model(201,true),model(301,false)
a.targetsComplete=false; a.targets[1].shareable=false
b.preAll={201}; b.eligibility='blocked'; b.conditionReason='prerequisite'
local result=evaluate({[201]=a,[301]=b},201)
check(action(result.predicted,201,'quest_area'),'known area remains usable')
check(not action(result.predicted,201,'turn_in') and not action(result.predicted,301,'pick_up'),
    'incomplete or special target coverage cannot simulate delivery')
'''),
    ("Decision: hard restrictions and exclusivity survive prediction", r'''
local a,b=model(201,true),model(301,false)
for _,reason in ipairs({'level_too_low','class_restricted','profession','conditions_unavailable'}) do
    b.eligibility=reason=='conditions_unavailable' and 'unknown' or 'blocked'; b.conditionReason=reason
    check(not action(evaluate({[201]=a,[301]=b},201).predicted,301,'pick_up'),'cannot bypass '..reason)
end
b.eligibility='eligible'; b.conditionReason=nil; b.exclusiveTo={201}
check(not action(evaluate({[201]=a,[301]=b},201).predicted,301,'pick_up'),'active exclusive quest blocks pickup')
b.exclusiveTo={401}
check(not action(evaluate({[201]=a,[301]=b},201,{[401]=true}).predicted,301,'pick_up'),
    'delivered exclusive quest blocks pickup')
local c=model(302,false)
b.exclusiveTo={302}; c.exclusiveTo={301}
local result=evaluate({[201]=a,[301]=b,[302]=c},201)
check(action(result.predicted,301,'pick_up') or action(result.predicted,302,'pick_up'),'one exclusive branch can be accepted')
check(not (action(result.predicted,301,'pick_up') and action(result.predicted,302,'pick_up')),
    'simulated acceptance cannot take both exclusive branches')
'''),
    ("Decision: unavailable data and unresolved baseline preserve fallback", r'''
local result=ns.Decision.Evaluate({available=false,reason='not_loaded'},{},point(1,0).world,nil)
check(not result.recommendation and #result.predicted==0 and result.reason=='not_loaded','missing data is explicit')
local a=model(201,true)
result=ns.Decision.Evaluate({available=true,quests={[201]=a},completed={},opportunities={}},
    {{quest=a}},point(1,0).world,{questID=999,action='quest_area',point=point(501,1000)})
check(not result.recommendation and result.reason=='baseline_target_unresolved','cannot replace an unresolved baseline')
'''),
    ("Decision: bounded first-action search always retains baseline", r'''
local quests={[201]=model(201,true)}
for id=301,314 do quests[id]=model(id,false); quests[id].starters={point(10000+id,id-300)} end
local result=evaluate(quests,201)
check(result.baselineScore~=nil and result.considered<=10,'baseline survives first-action cap')
check(#result.predicted<=6,'lookahead remains bounded')
'''),
    ("Discovery: incremental 64-quest index and no premature offers", r'''
for id=1001,1129 do record(id,100,{objectives={}}) end
local context=ns.GetPlayerContext({})
local function read() return ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get()) end
local data=read()
check(data.available and data.building and data.scanned==0 and data.total==129,'index starts without synchronous full scan')
check(#data.opportunities==0,'building index emits no premature opportunities')
ns.Discovery.Pump(); data=read()
check(data.building and data.scanned<=64 and #data.opportunities==0,'first pump respects task and inner work caps')
local first=data.scanned
ns.Discovery.Pump(); data=read()
check(data.building and data.scanned>=first and data.scanned-first<=64,'second pump remains bounded')
finishIndex(); data=read()
check(not data.building and data.scanned==129 and #data.opportunities==129,'final batch publishes complete offers')
'''),
    ("Discovery: nearby starters include the 400-yard boundary", r'''
record(301,400,{objectives={}}); record(302,401,{objectives={}})
local data=collect()
local offer=action(data.opportunities,301,'pick_up')
check(offer and offer.distance==400 and has(offer.reasons,'nearby'),'nearby boundary is included')
check(offer.certainty=='estimated','static starter does not claim observed availability')
check(not action(data.opportunities,302,'pick_up'),'outside nearby radius stays excluded without a destination')
'''),
    ("Discovery: on-way and destination starters catch missed pickups", r'''
record(201); Fixture.log={201}
record(301,600,{objectives={}}); record(302,1200,{objectives={}})
record(303,500,{objectives={}}); place('npc',10303,500,280)
record(304,500,{objectives={}}); place('npc',10304,500,300)
local data=collect()
local onWay=action(data.opportunities,301,'pick_up')
local destination=action(data.opportunities,302,'pick_up')
local detour=action(data.opportunities,303,'pick_up')
check(onWay and onWay.distance>400 and onWay.extraDistance==0 and has(onWay.reasons,'on_way'),'starter midway along route is found')
check(destination and has(destination.reasons,'same_area'),'destination 200-yard boundary is included')
check(detour and detour.extraDistance<=150 and has(detour.reasons,'on_way'),'short detour is admitted')
check(not action(data.opportunities,304,'pick_up'),'detour over 150 yards is excluded')
'''),
    ("Discovery: level class race profession and exclusive filters", r'''
record(201); Fixture.log={201}
record(301,100,{requiredLevel=20}); record(302,100,{requiredClasses=128})
record(303,100,{exclusiveTo={201}}); record(304,100,{requiredClasses=1})
record(305,100,{requiredMaxLevel=18}); record(306,100); Fixture.completed[306]=true
record(307,100,{requiredRaces=1}); record(308,100,{requiredSkill={356,1}})
local data=collect()
for id,reason in pairs({[301]='level_too_low',[302]='class_restricted',[303]='exclusive_quest',
    [305]='level_too_high',[306]='already_completed',[307]='race_restricted',[308]='profession'}) do
    check(data.quests[id] and data.quests[id].eligibility=='blocked'
        and data.quests[id].conditionReason==reason,'blocked with reason '..reason)
    check(not action(data.opportunities,id,'pick_up'),'filtered quest is never offered')
end
check(action(data.opportunities,304,'pick_up'),'matching player class remains eligible')
'''),
    ("Discovery: AND OR and official delivery history", r'''
record(401,100,{objectives={}}); record(402,100,{objectives={}}); Fixture.log={401,402}
Fixture.status[401]='ready_for_turn_in'; Fixture.status[402]='complete'
record(301,100,{preQuestGroup={401,402}}); record(302,100,{preQuestSingle={401,402}})
local data=collect()
check(data.completed[401]==false and data.completed[402]==false,'ready and complete do not become delivery history')
check(not action(data.opportunities,301,'pick_up') and not action(data.opportunities,302,'pick_up'),'neither prerequisite expression is satisfied')
Fixture.completed[401]=true; Fixture.log={402}; data=collect()
check(not action(data.opportunities,301,'pick_up'),'AND still needs the second delivery')
check(action(data.opportunities,302,'pick_up'),'OR accepts one official historical delivery')
Fixture.completed[402]=true; Fixture.log={}; data=collect()
check(action(data.opportunities,301,'pick_up'),'AND accepts both historical deliveries')
'''),
    ("Discovery: unknown completion and malformed conditions do not offer pickups", r'''
record(301,100,{preQuestGroup={401}}); Fixture.historyUnknown[401]=true
record(302,100,{requiredLevel='nineteen'})
local data=collect()
for _,id in ipairs({301,302}) do
    check(data.quests[id].eligibility=='unknown','uncertain condition remains unknown')
    check(not action(data.opportunities,id,'pick_up'),'uncertain condition cannot become an executable offer')
end
'''),
    ("Discovery: bag item is executable, an unheld drop is only a relation", r'''
record(301,100,{startedBy={[3]={601}}})
Fixture.items[601]={quest=301,npcDrops={502}}; place('npc',502,200)
Fixture.items[602]={quest=0}; Fixture.bags={602}
local data=collect()
local drop=action(data.opportunities,301,'possible_item_drop')
check(drop and drop.itemID==601 and drop.certainty=='possible','unheld item records a possible source')
check(not data.quests[301].startItemID and not action(data.opportunities,301,'start_item'),'drop relation cannot claim inventory ownership')
local result=ns.Decision.Evaluate(data,{},point(1,0).world,nil)
check(not action(result.predicted,301,'start_item'),'unheld starting item cannot execute')
Fixture.bags={601,602}; data=collect()
local start=action(data.opportunities,301,'start_item')
check(start and start.itemID==601 and start.certainty=='confirmed','held bag item creates a confirmed start')
check(data.quests[301].startItemID==601,'Decision model carries actual held item ID')
check(not action(data.opportunities,301,'possible_item_drop'),'held item no longer needs a speculative drop')
check(data.quests[0]==nil,'Item.startQuest zero does not create quest zero')
result=ns.Decision.Evaluate(data,{},point(1,0).world,nil)
check(result.recommendation and result.recommendation.action=='start_item'
    and result.recommendation.itemID==601,'held item is executable by Decision')
'''),
    ("Discovery: simple shared targets retain completion and identity", r'''
record(201); record(301); Fixture.log={201}
local items=candidates(); local data=collect(items)
for _,id in ipairs({201,301}) do
    local quest=data.quests[id]
    check(quest.targetsComplete==true,'fully resolved ordinary goals allow simulated delivery')
    check(#quest.targets==1 and quest.targets[1].key=='npc:501' and quest.targets[1].shareable,
        'active and unaccepted ordinary goals preserve the same shareable identity')
end
local result=ns.Decision.Evaluate(data,items,point(1,0).world,
    {questID=201,action='quest_area',objectiveKey='npc:501',point=point(501,1000)})
local workCount=0
for _,step in ipairs(result.predicted) do if step.action=='quest_area' then workCount=workCount+1 end end
check(result.recommendation and result.recommendation.action=='pick_up' and workCount==1,
    'real Discovery data lets Decision share work after pickup')
'''),
    ("Discovery: special objectives never become ordinary shared kills", r'''
record(301,100,{objectives={[1]={{501,nil,1}}}})
record(302,100,{objectives={[1]={{501,nil,0}},[4]={{72,100}}}})
record(303,100,{objectives={[1]={{501,nil,0}},[5]={{{501},501}}}})
record(304,100,{objectives={[1]={{501,nil,0}},[6]={{501,123}}}})
record(305,100,{extraObjectives={{nil,nil,nil,nil,{{'monster',501}}}}})
local data=collect()
for id=301,305 do
    local quest=data.quests[id]
    check(quest and quest.targetsComplete~=true,'special objective cannot certify full simulated completion')
    for _,target in ipairs(quest.targets) do check(not target.shareable,'special relation is not an ordinary shared kill') end
end
'''),
    ("Discovery to Decision: delivered prerequisite unlocks a shared followup", r'''
record(101,100,{objectives={}}); Fixture.status[101]='ready_for_turn_in'
place('npc',20101,100)
record(201); record(301,100,{preQuestGroup={101}}); Fixture.log={101,201}
local items=candidates(); local data=collect(items)
local first=point(501,1000)
local result=ns.Decision.Evaluate(data,items,point(1,0).world,
    {questID=201,action='quest_area',objectiveKey='npc:501',point=first})
local _,delivery=action(result.predicted,101,'turn_in')
local _,pickup=action(result.predicted,301,'pick_up')
check(result.recommendation and result.recommendation.action=='turn_in'
    and delivery and pickup and delivery<pickup,'Discovery prerequisite state is searchable after simulated delivery')
check(data.completed[101]==false,'predicted delivery never changes official history')
'''),
    ("Planner: pickup navigation and predicted work stay separate", r'''
record(201); record(301,100); Fixture.log={201}
local result=plan()
check(result.decision.applied and result.steps[1].questID==301 and result.steps[1].action=='pick_up','related pickup is first formal step')
check(result.pickupCount==1 and result.activeQuestCount==1 and result.questCount==2 and result.count==2,'plan distinguishes active quests and pickup count')
check(result.navigation.phase=='pick_up' and not result.navigation.protected,'pickup navigation never enters working')
local forecast=false
for _,step in ipairs(result.decision.predicted) do
    for _,goal in ipairs(step.contributions or {}) do if goal.questID==301 then forecast=true end end
end
check(forecast,'unaccepted work is represented in predicted shared contributions')
check(not action(result.steps,301,'quest_area') and action(result.steps,201,'quest_area'),'only active work enters formal steps')
check(ns.GetPlan({})==result and result.discovery.available,'existing get_plan exposes discovery and decision')
Fixture.playerX=.01; Fixture.time=1
result=ns.Planner.Rebuild('moved')
check(result.navigation.phase=='pick_up' and not result.navigation.protected,'arrival at starter still awaits actual acceptance')
Fixture.log={201,301}; result=ns.Replan({})
check(not action(result.steps,301,'pick_up') and action(result.steps,301,'quest_area'),'actual acceptance promotes work into formal steps')
check(result.activeQuestCount==2 and result.pickupCount==0,'counts follow official log acceptance')
'''),
    ("Planner: held starting item uses start_item navigation", r'''
record(201); record(301,100,{startedBy={[3]={601}}}); Fixture.log={201}
Fixture.items[601]={quest=301}; Fixture.bags={601}
local result=plan()
check(result.decision.applied and result.steps[1].action=='start_item'
    and result.steps[1].questID==301 and result.steps[1].itemID==601,'Planner applies a held starting item')
check(result.navigation.phase=='start_item' and not result.navigation.protected,'item start awaits actual acceptance at player position')
check(result.pickupCount==1 and not action(result.steps,301,'quest_area'),'item pickup never adds predicted work to formal route')
'''),
    ("Planner: protected working target defers a real recommendation", r'''
record(201); record(301,50); place('npc',501,100); Fixture.log={201}
ns.RouteOptions.Get().switchNotice=false
local original=ns.Replan({})
check(original.navigation.phase=='working' and original.navigation.protected,'work is protected before index becomes ready')
if original.discovery.building then finishIndex() end
local result=ns.Planner.Rebuild('quest_update')
check(result.decision.recommendation~=nil,'fixture supplies a profitable competing pickup')
check(result.navigation.phase=='working' and result.navigation.protected,'active nearby work remains protected')
check(not result.decision.applied and result.decision.deferred=='working_target_protected','association explicitly defers to work protection')
check(result.steps[1].questID==201 and result.pickupCount==0,'protected work is not overwritten')
'''),
    ("Planner: manual spot change defers a real recommendation", r'''
record(201); record(301,100); Fixture.log={201}; ns.RouteOptions.Get().skipped[301]=true
Fixture.locations.npc[501]={[17]={{10,0},{40,0}}}
local original=plan()
check(original.steps[1].questID==201 and original.steps[1].world.x==1000,'initial exact objective uses nearer hotspot')
ns.RouteOptions.Get().skipped[301]=nil
local changed=ns.ChangeQuestSpot({questID=201,objectiveKey='npc:501'})
check(changed.ok and changed.selected.questID==201 and changed.selected.world.x==4000,'manual change commits the other hotspot')
local result=ns.GetPlan({})
check(result.decision.recommendation~=nil,'fixture still offers a competing association')
check(not result.decision.applied and result.decision.deferred=='manual_spot_change','association explicitly defers to manual selection')
check(result.steps[1].world.x==4000 and not ns.route.pendingSpotChange,'manual result survives route rebuild and request is consumed')
'''),
    ("Planner: missing database preserves native route", r'''
record(201); Fixture.log={201}; Fixture.pois={[101]={NewPOI(101,.1,201)}}
local original=plan(); LibQuestieDB=nil
local result=ns.Replan({})
check(result.ok and result.count==1 and result.steps[1].questID==original.steps[1].questID
    and result.steps[1].world.x==original.steps[1].world.x,'native POI keeps the original quest and destination usable')
check(not result.discovery.available and not result.decision.recommendation,'missing database disables association only')
check(result.steps[1].targetMode=='native_poi','fallback actually uses native data')
'''),
    ("Planner: unready or missing ID index preserves native route and recovers", r'''
record(201); Fixture.log={201}; Fixture.pois={[101]={NewPOI(101,.1,201)}}
local getter=FixtureDB.Quest.GetAllIds
FixtureDB.Quest.GetAllIds=function() return nil end
local result=ns.Replan({})
check(result.ok and result.count==1 and not result.discovery.available
    and result.discovery.reason=='id_index_not_ready','unready IDs preserve active route')
FixtureDB.Quest.GetAllIds=nil; result=ns.Replan({})
check(result.ok and result.count==1 and result.discovery.reason=='id_index_unavailable','missing ID method is isolated')
FixtureDB.Quest.GetAllIds=getter; result=plan()
check(result.discovery.available and not result.discovery.building and result.count==1,'late-ready ID index recovers')
'''),
    ("Discovery: material identity survives NPC source expansion", r'''
record(201,100,{objectives={[3]={{601,nil,0}}}})
record(301,100,{objectives={[3]={{602,nil,0}}}}); Fixture.log={201}
Fixture.items[601]={npcDrops={501}}; Fixture.items[602]={npcDrops={501}}
local data=collect()
check(data.quests[201].targets[1].key=='item:601' and data.quests[301].targets[1].key=='item:602',
    'different materials retain distinct goal identities on one NPC')
check(data.quests[201].targets[1].entityID==501 and data.quests[301].targets[1].entityID==501,
    'source entity remains available for partial synergy')
check(data.quests[201].targetsComplete and data.quests[301].targetsComplete,'ordinary material coverage is complete')
'''),
    ("Discovery: foreign unfinished goals prevent simulated delivery", r'''
FixtureDB.Support.Get=function() return {private={areaIdToUiMapId={[17]=101,[18]=102}}} end
record(201,100,{objectives={[1]={{501,nil,0},{502,nil,0}}}})
record(301,100,{objectives={[1]={{501,nil,0},{502,nil,0}}}}); Fixture.log={201}
Fixture.locations.npc[502]={[18]={{10,0}}}
local data=collect()
check(not data.quests[201].targetsComplete and not data.quests[301].targetsComplete,
    'one local goal cannot hide another unfinished goal on a different map')
check(#data.quests[201].targets==1 and #data.quests[301].targets==1,'search stays on the current map')
'''),
    ("Discovery: ready delivery uses the actual native point", r'''
record(201); Fixture.log={201}; Fixture.status[201]='ready_for_turn_in'
local entry=ns.QuestData.ActiveQuestIndex()[201]
local quest=ns.QuestData.ReadQuest(entry.info,entry.category,false)
local actual=point(501,2300)
local data=collect({{quest=quest,points={actual},priorityWeight=1}})
check(#data.quests[201].targets==0,'ready quest never adds work targets')
check(data.quests[201].finishers[1].world.x==2300,'delivery simulation matches the native baseline point')
'''),
    ("Planner: uncached quest metadata waits and candidate events recover", r'''
record(201); record(301,100); Fixture.log={201}
local loaded,requests=false,0
HaveQuestData=function(id) return id~=301 or loaded end
C_QuestLog.RequestLoadQuestByID=function(id) if id==301 then requests=requests+1 end end
C_QuestLog.GetQuestType=function(id) return id==301 and loaded and 81 or 0 end
local result=plan()
check(requests==1 and result.discovery.pendingCount==1,'uncached candidate is requested once')
check(not action(result.discovery.opportunities,301,'pick_up') and result.pickupCount==0,
    'uncached ordinary default cannot create a pickup')
Fixture.loggedIn=true; ns.StartRoute()
local sequence=ns.GetPlan({}).sequence
loaded=true
ns.route.driver:GetScript('OnEvent')(ns.route.driver,'QUEST_DATA_LOAD_RESULT',301,true)
Fixture.time=1; ns.route.driver:GetScript('OnUpdate')(ns.route.driver,.2)
result=ns.GetPlan({})
check(result.sequence>sequence and result.discovery.pendingCount==0,'candidate metadata event replans and stops retry')
local excluded=false
for _,item in ipairs(result.discovery.blocked) do if item.questID==301 and item.reason=='instance' then excluded=true end end
check(excluded and result.pickupCount==0,'loaded dungeon classification is filtered')
'''),
    ("Decision: no unlock opportunity does not run a search", r'''
local quests={[201]=model(201,true)}
for id=202,220 do quests[id]=model(id,true,id*10,'npc:'..id) end
local result=evaluate(quests,201)
check(result.considered==0 and not result.recommendation,'active-only route does not waste beam expansion')
check(result.predicted[1].questID==201,'current executable action remains visible')
'''),
    ("Discovery: index pump respects the per-frame work budget", r'''
for id=301,430 do record(id,100) end
local data=ns.Discovery.Collect(ns.GetPlayerContext({}),{}, {},ns.RouteOptions.Get())
local clock=0
debugprofilestop=function() clock=clock+2; return clock end
ns.Discovery.Pump()
data=ns.Discovery.Collect(ns.GetPlayerContext({}),{}, {},ns.RouteOptions.Get())
check(data.building and data.scanned<64,'time budget yields before the fixed task cap')
debugprofilestop=nil
finishIndex()
check(not ns.Discovery.Collect(ns.GetPlayerContext({}),{}, {},ns.RouteOptions.Get()).building,'yielded build resumes without losing records')
'''),
    ("Discovery: log membership and breadcrumb constraints stay authoritative", r'''
record(301,100); record(302,100,{breadcrumbForQuestId=401})
C_QuestLog.IsOnQuest=function(id) return id==301 end
Fixture.completed[401]=true
local data=collect()
check(data.quests[301].conditionReason=='already_accepted','incomplete enumeration cannot recommend an already accepted quest')
check(data.quests[302].eligibility=='blocked','completed breadcrumb destination suppresses its breadcrumb')
C_QuestLog.IsOnQuest=function() return nil end; data=collect()
check(data.quests[301].eligibility=='unknown' and not action(data.opportunities,301,'pick_up'),'unknown membership is not treated as unaccepted')
'''),
    ("Discovery and Decision: one-sided exclusivity still blocks both orders", r'''
record(301,100,{exclusiveTo={302}}); record(302,100); Fixture.completed[301]=true
local data=collect()
check(data.quests[302].eligibility=='blocked' and data.quests[302].conditionReason=='exclusive_quest',
    'reverse exclusive relation respects delivered history')
local a,b,c=model(201,true),model(301,false),model(302,false)
b.exclusiveTo={302}
local result=evaluate({[201]=a,[301]=b,[302]=c},201)
check(not (action(result.predicted,301,'pick_up') and action(result.predicted,302,'pick_up')),
    'one-sided exclusive relation cannot be bypassed by changing order')
'''),
    ("Decision: partial delivery preserves an active parent", r'''
local a,b,c=model(101,true),model(201,true),model(301,false)
a.status='ready_for_turn_in'; a.targets={}; a.finishers={point(601,1100)}
c.preAll={101}; c.parentQuest=201; c.eligibility='blocked'; c.conditionReason='prerequisite'
c.starters={point(603,1000)}
local result=evaluate({[101]=a,[201]=b,[301]=c},201)
check(result.considered>0 and result.recommendation and result.recommendation.questID==101,
    'search keeps legal plan that delivers prerequisite but keeps parent active')
local _,delivery=action(result.predicted,101,'turn_in')
local _,pickup=action(result.predicted,301,'pick_up')
local _,parentDelivery=action(result.predicted,201,'turn_in')
check(delivery and pickup and delivery<pickup and (not parentDelivery or pickup<parentDelivery),
    'parent visibility is checked in each branch instead of a hypothetical all-delivered state')
'''),
    ("Planner: small motion does not flip a valid pickup", r'''
record(201); record(301); record(302); Fixture.log={201}
place('npc',10301,100,90); place('npc',10302,100,110)
Fixture.playerY=.0099
local first=plan()
check(first.steps[1].action=='pick_up','fixture selected a pickup')
local selected=first.steps[1].questID
Fixture.playerY=.0101
local nextPlan=ns.Planner.Rebuild('BAG_UPDATE_DELAYED')
check(nextPlan.steps[1].questID==selected and nextPlan.steps[1].action=='pick_up',
    'two-yard change cannot replace an equally valuable pickup')
check(nextPlan.decision.retainedPickup and nextPlan.decision.baselineScore,
    'pickup is evaluated as its own stable baseline')
Fixture.completed[selected]=true
nextPlan=ns.Planner.Rebuild('QUEST_LOG_UPDATE')
check(nextPlan.steps[1].questID~=selected,'invalidated pickup is immediately released')
'''),
    ("Discovery: one large spawn list can yield and resume", r'''
record(301,100,{objectives={}})
local points={}
for i=1,10000 do points[i]={i/200,0} end
Fixture.locations.npc[10301]={[17]=points}
local converted=0
local convert=C_Map.GetWorldPosFromMapPos
C_Map.GetWorldPosFromMapPos=function(...) converted=converted+1; return convert(...) end
local context=ns.GetPlayerContext({})
ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
converted=0
ns.Discovery.Pump()
check(converted>0 and converted<=128,'single record yields inside its coordinate conversion loop')
finishIndex()
local result=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(not result.building and result.quests[301] and #result.quests[301].starters==10000,
    'resuming the single-record cursor preserves every location')
'''),
    ("Planner: large discovery summaries remain bounded", r'''
for id=1001,1750 do record(id,100,{objectives={}}) end
local result=plan()
check(result.discovery.opportunityTotal==750 and #result.discovery.opportunities<=26,
    'public summary keeps totals without returning the entire opportunity index')
check(result.discovery.summaryLimit==25,'public summary publishes its limit')
check(result.count==0,'unknown goal benefit does not invent a forced pickup route')
'''),
    ("Map pins: pickups use exclamation labels and compact status", r'''
record(201); record(301,100); Fixture.log={201}
local result=plan()
local pin=ns.MapPins.New({overlay=CreateFrame('Frame')})
pin.step=result.steps[1]
ns.MapPins.Appearance(pin,pin.step,1)
check(pin.text.text=='1!','pickup has an explicit map exclamation label')
GameTooltip={lines={}}
function GameTooltip:SetOwner() end
function GameTooltip:SetText(text) self.lines={text} end
function GameTooltip:AddLine(text) self.lines[#self.lines+1]=text end
function GameTooltip:Show() end
function GameTooltip:Hide() end
pin:GetScript('OnEnter')(pin)
check(#GameTooltip.lines<=4 and GameTooltip.lines[2]:find('预计可接任务',1,true),
    'pickup hover preserves the compact estimated-availability status')
check(GameTooltip.lines[2]:find('静态接取位置',1,true),'pickup does not claim a monster work area')
'''),
    ("Planner: malformed database records preserve native route", r'''
record(201); record(301,100); Fixture.log={201}; Fixture.pois={[101]={NewPOI(101,.1,201)}}
local getter=FixtureDB.Quest.Get
FixtureDB.Quest.Get=function(id,field)
    if field=='objectives' then error('fixture malformed objectives') end
    return getter(id,field)
end
local result=plan()
check(result.count==1 and result.steps[1].questID==201 and result.steps[1].targetMode=='native_poi',
    'bad DB record leaves the native route usable')
check(not result.decision.recommendation and result.pickupCount==0,'bad record cannot invent a pickup')
'''),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--addon", type=Path, default=DEFAULT_ADDON,
                        help="addon directory, .toc manifest, or .lua file")
    args = parser.parse_args()
    try:
        sources = read_addon_sources(args.addon)
    except (OSError, ValueError) as error:
        parser.error(str(error))

    failures = []
    passed = 0
    for label, source in CASES:
        runtime = LuaRuntime(unpack_returned_tuples=True)
        try:
            runtime.execute(SETUP)
            runtime.execute(FIXTURE)
            namespace = runtime.table()
            execute_addon(runtime, sources, namespace)
            passed += runtime.execute(HELPERS + source + "\nreturn checks", namespace, name=label)
            print(f"PASS: {label}")
        except Exception as error:
            failures.append(label)
            print(f"FAIL: {label}\n{error}")
    print(f"{'FAIL' if failures else 'PASS'}: {len(CASES) - len(failures)}/{len(CASES)} scenarios; "
          f"{passed} checks in passing scenarios; isolated Lua 5.1; {len(sources)} Lua file(s)")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
