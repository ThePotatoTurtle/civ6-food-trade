-- Fake engine used only by offline tests. Real mod scripts are loaded unchanged.
local properties, cities, notifications = {}, {}, {}
Game = {}
TEST = {turn=10, cities=cities, notifications=notifications, logs={}, effectBroken=false}
print = function(...) TEST.logs[#TEST.logs+1]=table.concat({...}," ") end
function Game.GetCurrentGameTurn() return TEST.turn end
function Game:GetProperty(key) return properties[key] end
function Game:SetProperty(key,value) properties[key]=value end
include = function() end -- The harness has already loaded the real FDT_Core.lua.

GameEvents = {}
for _,name in ipairs({"FDT_Create","FDT_Edit","FDT_Cancel","OnGameTurnStarted"}) do
  GameEvents[name]={Add=function(handler) GameEvents[name].handler=handler end}
end
NotificationTypes={USER_DEFINED_1=1}
ParameterTypes={MESSAGE=1,SUMMARY=2}
NotificationManager={SendNotification=function(owner,kind,data)
  notifications[#notifications+1]={owner=owner,kind=kind,message=data[1]}
end}

Players={}
function TEST.player(owner,human,gold)
  local player={owner=owner,human=human,gold=gold or 100,charged=0}
  function player:IsHuman() return self.human end
  function player:GetTreasury()
    return {
      GetGoldBalance=function() return player.gold end,
      ChangeGoldBalance=function(_,delta) player.gold=player.gold+delta; player.charged=player.charged-delta end
    }
  end
  Players[owner]=player
  return player
end

function TEST.city(owner,id,x,y,base)
  local city={owner=owner,id=id,x=x,y=y,base=base,buildings={},name="City "..id}
  function city:GetOwner() return self.owner end
  function city:GetID() return self.id end
  function city:GetX() return self.x end
  function city:GetY() return self.y end
  function city:GetName() return self.name end
  function city:GetGrowth()
    return {GetFoodSurplus=function()
      local food=city.base
      if not TEST.effectBroken then
        for _,row in ipairs(TEST.buildingRows) do if city.buildings[row.Index] then food=food+row.YieldChange end end
      end
      return food
    end}
  end
  function city:GetYield() return self:GetGrowth():GetFoodSurplus()+4 end
  function city:GetBuildings()
    return {
      HasBuilding=function(_,index) return city.buildings[index] or false end,
      RemoveBuilding=function(_,index) city.buildings[index]=nil end
    }
  end
  function city:GetBuildQueue()
    return {
      CreateIncompleteBuilding=function(_,index,percent)
        assert(percent==100,"production must complete dummy building")
        if city.throwOnCreate then error("simulated engine building exception") end
        city.buildings[index]=true
      end,
      RemoveBuilding=function(_,index) city.buildings[index]=nil end
    }
  end
  cities[#cities+1]=city
  return city
end

CityManager={}
function CityManager.GetCity(owner,id)
  if TEST.strictNativeIDs then
    assert(type(id)=="number" and id==id and id~=math.huge and id~=-math.huge and id==math.floor(id) and id>=0,"invalid ID reached native lookup")
  end
  for _,city in ipairs(cities) do if not city.removed and city.owner==owner and city.id==id then return city end end
end
function CityManager.GetCityAt(x,y)
  for _,city in ipairs(cities) do if not city.removed and city.x==x and city.y==y then return city end end
end
function TEST.advance()
  TEST.turn=TEST.turn+1
  return FDT.ProcessTurn(TEST.turn)
end
function TEST.food(city) return city:GetGrowth():GetFoodSurplus() end
function TEST.eq(actual,expected,context)
  assert(actual==expected,(context or "value")..": actual="..tostring(actual).." expected="..tostring(expected))
end
function TEST.countNotices(fragment)
  local count=0
  for _,entry in ipairs(notifications) do if string.find(entry.message,fragment,1,true) then count=count+1 end end
  return count
end
TEST.player(0,true,100)
TEST.player(1,true,100)
TEST.player(2,false,100)
TEST.sender=TEST.city(0,1,10,10,8)
TEST.receiver=TEST.city(0,2,12,10,1)
TEST.third=TEST.city(0,3,14,10,2)
TEST.foreign=TEST.city(1,4,16,10,8)
