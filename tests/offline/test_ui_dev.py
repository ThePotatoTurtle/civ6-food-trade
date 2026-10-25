"""Run actual Food Trade UI/dev Lua with small independent engine doubles.

These tests prove UI request behavior and safe spike cleanup, not Civ VI APIs.
"""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]

UI_ENGINE = r'''
function control()
 local c={hidden=false,step=0,text='',callbacks={}}
 function c:SetText(v) self.text=v end
 function c:SetHide(v) self.hidden=v end
 function c:IsHidden() return self.hidden end
 function c:SetDisabled(v) self.disabled=v end
 function c:SetNumSteps(v) self.steps=v end
 function c:SetStep(v) self.step=v end
 function c:GetStep() return self.step end
 function c:GetButton() return self end
 function c:SetVoid1(v) self.void=v end
 function c:RegisterCallback(k,v) self.callbacks[k]=v end
 function c:RegisterSliderCallback(v) self.slider=v end
 function c:RegisterSelectionCallback(v) self.selection=v end
 function c:ClearEntries() end
 function c:BuildEntry(n,e) e.Button=control() end
 function c:CalculateInternals() end
 function c:CalculateSize() end
 function c:CalculateInternalSize() end
 function c:SetToolTipString(v) self.tooltip=v end
 function c:GetToolTipString() return self.tooltip end
 return c
end
Controls=setmetatable({},{__index=function(t,k) local c=control();rawset(t,k,c);return c end})
Controls.Panel:SetHide(true)
Mouse={eLClick=1}; Locale={Lookup=function(s)return s end}; PlayerOperations={EXECUTE_SCRIPT=99}
GameInfo={Buildings={}}; local nextIndex=1
for _, sign in ipairs({'P','N'}) do for i=0,20 do
 local name='BUILDING_FDT_FOOD_'..sign..'_'..string.format('%.0f',2^i)
 GameInfo.Buildings[name]={Index=nextIndex}; nextIndex=nextIndex+1
end end
CITIES={}; CITY_FOOD={8,2}; CITY_BITS={{},{}}
for i=1,2 do
 local id=i
 CITIES[i]={GetID=function()return id end,GetOwner=function()return 0 end,
  GetName=function()return 'City'..id end,
  GetGrowth=function()return {GetFoodSurplus=function()return CITY_FOOD[id] end} end,
  GetBuildings=function()return {HasBuilding=function(self,index)return CITY_BITS[id][index] or false end} end,
  GetYieldToolTip=function()return 'Native yield' end}
end
Players={[0]={GetCities=function()return {
 FindID=function(self,id)return CITIES[id] end,
 Members=function()local i=0;return function()i=i+1;if CITIES[i]then return i,CITIES[i]end end end}end}}
TURN=1; STATE={routes={}}; SELECTED=nil; PATH_CONTROLS={}
Game={GetLocalPlayer=function()return 0 end,GetCurrentGameTurn=function()return TURN end,GetProperty=function()return STATE end}
UI={GetHeadSelectedCity=function()return SELECTED end,
 RequestPlayerOperation=function(p,o,args) REQUEST=args; REQUEST_OWNER=p; REQUEST_OPERATION=o end}
Events=setmetatable({},{__index=function(t,k)local e={Add=function(fn)t[k..'_fn']=fn end};rawset(t,k,e);return e end})
ContextPtr={SetHide=function()end,LookUpControl=function(self,path)return PATH_CONTROLS[path] end}
LuaEvents={}; YieldTypes={FOOD=0}; function include()end
InstanceManager={new=function()
 ROWMANAGER={ResetInstances=function(self)self.instances={}end,
 GetInstance=function(self)
  local i={Description=control(),Edit=control(),Cancel=control()}
  self.instances=self.instances or {};table.insert(self.instances,i);return i
 end};return ROWMANAGER
end}
function existingRoute(pending)
 STATE.routes={{id=1,owner=0,senderPlayer=0,senderCity=1,receiverPlayer=0,receiverCity=2,
  amount=5,flow=pending and 0 or 5,startTurn=pending and 2 or 1,switchedOff=false}}
 if not pending then
  CITY_FOOD[1]=3;CITY_FOOD[2]=7
  CITY_BITS[1][GameInfo.Buildings.BUILDING_FDT_FOOD_N_1.Index]=true
  CITY_BITS[1][GameInfo.Buildings.BUILDING_FDT_FOOD_N_4.Index]=true
  CITY_BITS[2][GameInfo.Buildings.BUILDING_FDT_FOOD_P_1.Index]=true
  CITY_BITS[2][GameInfo.Buildings.BUILDING_FDT_FOOD_P_4.Index]=true
 end
 Controls.Panel:SetHide(false);Events.GameCoreEventPublishComplete_fn()
end
'''

DEV_ENGINE = r'''
properties={}; Game={GetCurrentGameTurn=function()return 1 end,
 GetProperty=function(self,k)return properties[k]end,
 SetProperty=function(self,k,v)properties[k]=v end}
GameInfo={Buildings={}}; local deltas={}; local nextIndex=1
for _,prefix in ipairs({'BUILDING_FDT_FOOD_','BUILDING_FDT_DEV_FOOD_'})do
 for _,sign in ipairs({'P','N'})do
  for i=0,(prefix=='BUILDING_FDT_FOOD_' and 20 or 5)do
   local power=2^i;local name=prefix..sign..'_'..string.format('%.0f',power)
   GameInfo.Buildings[name]={Index=nextIndex};deltas[nextIndex]=(sign=='P'and power or -power)
   nextIndex=nextIndex+1
  end
 end
end
CITIES={}
for id=1,3 do
 local cityID=id;local built={}; local c={}
 local function food()local f=8;for index in pairs(built)do f=f+deltas[index] end;return f end
 local buildings={HasBuilding=function(self,index)return built[index]end,
  RemoveBuilding=function(self,index)built[index]=nil end}
 local queue={RemoveBuilding=function()end,
  CreateIncompleteBuilding=function(self,index,pct)
   if INJECT_FOOD and deltas[index]==8 then INJECT_FOOD=false;error('injected creation failure')end
   built[index]=true
  end}
 function c:GetBuildings()return buildings end;function c:GetBuildQueue()return queue end
 function c:GetOwner()return 0 end;function c:GetID()return cityID end
 function c:GetGrowth()return {GetFoodSurplus=food}end;function c:GetYield()return food()end
 CITIES[id]=c
end
BALANCE=100
local treasury={GetGoldBalance=function()return BALANCE end,
 ChangeGoldBalance=function(self,delta)
  BALANCE=BALANCE+delta
  if INJECT_GOLD and BALANCE<0 then INJECT_GOLD=false;error('injected treasury failure')end
 end}
Players={[0]={IsHuman=function()return true end,GetTreasury=function()return treasury end}}
CityManager={GetCity=function(owner,id)if owner==0 then return CITIES[id]end end}
properties.FDT_State={routes={}};properties.FDT_DevScenario={owner=0,cities={1,2,3},checker=true}
GameEvents=setmetatable({},{__index=function(t,k)local e={Add=function(fn)t[k..'_fn']=fn end};rawset(t,k,e);return e end})
YieldTypes={FOOD=0}
function assertRestored()
 assert(CITIES[1]:GetGrowth():GetFoodSurplus()==8,'leftover temporary food')
 assert(BALANCE==100,'leftover treasury change')
end
'''


class UIDevTests(unittest.TestCase):
    def ui(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(UI_ENGINE)
        lua.execute((ROOT / "FDT/UI/FDT_Panel.lua").read_text(encoding="utf-8-sig"))
        return lua

    def dev(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        logs = []
        lua.globals().print = lambda *values: logs.append(" ".join(map(str, values)))
        lua.execute(DEV_ENGINE)
        lua.execute((ROOT / "FDT_Dev/Gameplay/FDT_Dev.lua").read_text(encoding="utf-8-sig"))
        return lua, logs

    def test_ui_blocks_empty_selection_and_sends_flat_create(self):
        lua = self.ui()
        lua.execute(r'''
Controls.New.callbacks[1]()
assert(Controls.Confirm.disabled)
Controls.Sender.selection(1);Controls.Receiver.selection(1)
assert(Controls.Confirm.disabled,'same city must be blocked')
Controls.Receiver.selection(2)
Controls.AmountSlider.step=5;Controls.AmountSlider.slider()
assert(not Controls.Confirm.disabled)
Controls.Confirm.callbacks[1]()
assert(REQUEST_OWNER==0 and REQUEST_OPERATION==99)
assert(REQUEST.OnStart=='FDT_Create' and REQUEST.senderCity==1 and REQUEST.receiverCity==2 and REQUEST.amount==5)
for _,value in pairs(REQUEST)do assert(type(value)=='number' or type(value)=='string')end
assert(string.find(Controls.Confirmation.text,'8.0 before, 3.0 after',1,true))
''')

    def test_ui_pending_cost_and_edit_preserve_current_flow(self):
        lua = self.ui()
        lua.execute(r'''
existingRoute(true)
assert(string.find(ROWMANAGER.instances[1].Description.text,'Pending | 0 gold/turn',1,true))
existingRoute(false)
STATE.routes[1].pendingAmount=7
Events.GameCoreEventPublishComplete_fn()
assert(string.find(ROWMANAGER.instances[1].Description.text,'Flow 5',1,true))
assert(string.find(ROWMANAGER.instances[1].Description.text,'edit to 7 next turn',1,true))
ROWMANAGER.instances[1].Edit.callbacks[1]()
assert(Controls.AmountSlider.step==7,'edit should select pending requested amount')
assert(string.find(Controls.Confirmation.text,'3.0 before, 1.0 after',1,true))
Controls.AmountSlider.step=0;Controls.AmountSlider.slider();Controls.Confirm.callbacks[1]()
assert(REQUEST.OnStart=='FDT_Edit' and REQUEST.routeID==1 and REQUEST.amount==0)
''')

    def test_ui_food_tooltip_preserves_native_text_without_duplication(self):
        lua = self.ui()
        lua.execute(r'''
existingRoute(false)
SELECTED=CITIES[1];local grid=control();grid.tooltip='Focus header[NEWLINE]Native yield'
PATH_CONTROLS['/InGame/CityPanel/FoodGrid']=grid
Events.GameCoreEventPublishComplete_fn();Events.GameCoreEventPublishComplete_fn()
assert(string.sub(grid.tooltip,1,12)=='Focus header')
local _,count=string.gsub(grid.tooltip,'Food Trade routes:','')
assert(count==1,'repeated refresh must not duplicate appended routes')
assert(string.find(grid.tooltip,'Food Trade: -5 to City2',1,true))
STATE.routes={};Events.GameCoreEventPublishComplete_fn()
assert(grid.tooltip=='Focus header[NEWLINE]Native yield','removal must restore native tooltip')
''')

    def test_dev_normal_spikes_restore_city_food_and_treasury(self):
        lua, logs = self.dev()
        lua.execute("GameEvents.FDT_DevAction_fn(0,{action='spikes'});assertRestored()")
        self.assertFalse(any(line.endswith(" FAIL") for line in logs), "\n".join(logs))
        self.assertTrue(any("SPIKE S1 A food" in line and "delta=-40" in line for line in logs))
        self.assertTrue(any("SPIKE S3 overdraft" in line and "actual=-1" in line for line in logs))
        self.assertTrue(any("SPIKE S4 capture/flip/raze" in line and "PENDING" in line for line in logs))

    def test_dev_building_failure_always_cleans_up_partial_food_changes(self):
        lua, logs = self.dev()
        lua.execute("INJECT_FOOD=true;GameEvents.FDT_DevAction_fn(0,{action='spikes'});assertRestored()")
        self.assertTrue(any("SPIKE ERROR" in line and "injected creation failure" in line for line in logs))
        self.assertTrue(any("SPIKE cleanup food" in line and " PASS" in line for line in logs))
        self.assertFalse(any("SPIKE cleanup" in line and " FAIL" in line for line in logs))

    def test_dev_treasury_failure_after_mutation_always_restores_balance(self):
        lua, logs = self.dev()
        lua.execute("INJECT_GOLD=true;GameEvents.FDT_DevAction_fn(0,{action='spikes'});assertRestored()")
        self.assertTrue(any("SPIKE ERROR" in line and "injected treasury failure" in line for line in logs))
        self.assertTrue(any("SPIKE cleanup treasury" in line and " PASS" in line for line in logs))
        self.assertFalse(any("SPIKE cleanup" in line and " FAIL" in line for line in logs))


if __name__ == "__main__":
    unittest.main()
