-- Engine signatures and remaining runtime checks: research/ENGINE_APIS.md
-- and research/DISTANCE_APIS.md.
include("FDT_Core")
include("FDT_Distance")
FDT = {}
local M,Core = FDT,FDT_Core
local STATE_KEY = "FDT_State"
local EPSILON = 0.001
local function currentTurn() return Game.GetCurrentGameTurn() end
function M.GetState()
  return Game:GetProperty(STATE_KEY) or {schemaVersion=2,nextRouteID=1,routes={},applied={},notices={},lastProcessedTurn=-1}
end
local function save(state) Game:SetProperty(STATE_KEY,state) end
local function findCity(owner,id,x,y)
  local city = CityManager.GetCity(owner,id)
  if city and city:GetOwner()==owner and (x==nil or (city:GetX()==x and city:GetY()==y)) then return city end
  return nil
end
local function mapAdapter()
  local width,height=Map.GetGridSize()
  return {
    count=width*height,
    isWater=function(index)
      local plot=Map.GetPlotByIndex(index)
      return plot and plot:IsWater()
    end,
    neighbors=function(index)
      local plot=Map.GetPlotByIndex(index)
      if not plot then return nil end
      local result={}
      for direction=0,DirectionTypes.NUM_DIRECTION_TYPES-1 do
        local adjacent=Map.GetAdjacentPlot(plot:GetX(),plot:GetY(),direction)
        if adjacent then result[#result+1]=adjacent:GetIndex() end
      end
      return result
    end
  }
end
local function measure(sender,receiver,adapter,cache)
  local a=Map.GetPlot(sender:GetX(),sender:GetY())
  local b=Map.GetPlot(receiver:GetX(),receiver:GetY())
  if not a or not b then return nil,"A route city has no map tile." end
  return FDT_Distance.quote(a:GetIndex(),b:GetIndex(),adapter,cache)
end
function M.MeasureDistance(sender,receiver)
  return measure(sender,receiver,mapAdapter(),FDT_Distance.newCache())
end
function M.ReadSurplus(city) return city:GetGrowth():GetFoodSurplus() end
local function integer(value)
  return type(value)=="number" and value==value and value~=math.huge and value~=-math.huge and value==math.floor(value)
end
local function isHuman(playerID)
  return integer(playerID) and playerID>=0 and Players[playerID] and Players[playerID]:IsHuman()
end
local function buildingName(sign,bit) return "BUILDING_FDT_FOOD_"..sign.."_"..string.format("%.0f",bit) end
local function supported(city)
  local buildings,queue = city:GetBuildings(),city:GetBuildQueue()
  return buildings and queue and buildings.HasBuilding and buildings.RemoveBuilding and
    queue.CreateIncompleteBuilding and queue.RemoveBuilding
end
function M.ReadAppliedFood(city)
  local amount=0
  local buildings=city:GetBuildings()
  for i=0,20 do
    local bit=2^i
    for _,sign in ipairs({"P","N"}) do
      local row=GameInfo.Buildings[buildingName(sign,bit)]
      if row and buildings:HasBuilding(row.Index) then amount=amount+(sign=="P" and bit or -bit) end
    end
  end
  return amount
end
function M.ApplyCityFood(city,delta)
  if not integer(delta) or math.abs(delta)>Core.MAX_FOOD then return false,"Food amount exceeds the supported aggregate." end
  if not supported(city) then return false,"Food Trade building methods are unavailable; run S1." end
  -- Check every data row before changing the first building.
  for i=0,20 do
    local bit = 2^i
    for _,sign in ipairs({"P","N"}) do
      if not GameInfo.Buildings[buildingName(sign,bit)] then return false,"Food Trade building data is missing." end
    end
  end
  local buildings,queue = city:GetBuildings(),city:GetBuildQueue()
  local magnitude = math.abs(delta)
  for i=0,20 do
    local bit = 2^i
    for _,sign in ipairs({"P","N"}) do
      local row = GameInfo.Buildings[buildingName(sign,bit)]
      local want = (delta>0 and sign=="P" or delta<0 and sign=="N") and math.floor(magnitude/bit)%2==1
      local has = buildings:HasBuilding(row.Index)
      if has and not want then buildings:RemoveBuilding(row.Index); queue:RemoveBuilding(row.Index)
      elseif want and not has then queue:CreateIncompleteBuilding(row.Index,100) end
    end
  end
  return true
end
function M.GetAvailableSurplus(city)
  -- Capture may destroy buildings. Use the contribution that physically exists.
  local applied=M.ReadAppliedFood(city)
  local outgoing,incoming = math.max(0,-applied),math.max(0,applied)
  return Core.availableSurplus(M.ReadSurplus(city),outgoing,incoming)
end
local function notice(state,owner,message)
  state.notices = state.notices or {}
  state.notices[#state.notices+1] = {owner=owner,turn=currentTurn(),message=message}
  if #state.notices>100 then table.remove(state.notices,1) end
  -- Generic notification is optional on engine versions; persisted notices remain visible.
  if NotificationManager and NotificationTypes and NotificationTypes.USER_DEFINED_1 then
    local data = {}
    data[ParameterTypes.MESSAGE]=message
    data[ParameterTypes.SUMMARY]="Food Trade"
    NotificationManager.SendNotification(owner,NotificationTypes.USER_DEFINED_1,data)
  end
end
local function reject(owner,message)
  print("[FDT] request rejected owner="..tostring(owner).." reason="..message)
  if isHuman(owner) then local state=M.GetState(); notice(state,owner,message); save(state) end
  return false,message
end
local function aggregate(routes)
  local result = {}
  local function add(owner,id,x,y,delta)
    for _,entry in ipairs(result) do
      if entry.x==x and entry.y==y then entry.delta=entry.delta+delta; return end
    end
    result[#result+1]={owner=owner,cityID=id,x=x,y=y,delta=delta}
  end
  for _,r in ipairs(routes) do
    if r.flow>0 then
      add(r.senderPlayer,r.senderCity,r.senderX,r.senderY,-r.flow)
      add(r.receiverPlayer,r.receiverCity,r.receiverX,r.receiverY,r.flow)
    end
  end
  table.sort(result,function(a,b) if a.y~=b.y then return a.y<b.y end return a.x<b.x end)
  return result
end
local function applyLedger(old,new)
  -- Preflight all city adapters and aggregate bounds before any mutation.
  for _,list in ipairs({old,new}) do
    for _,entry in ipairs(list) do
      local city=CityManager.GetCityAt(entry.x,entry.y)
      if city and (not supported(city) or math.abs(entry.delta)>Core.MAX_FOOD) then
        return false,"Food Trade effect adapter or amount is unsupported."
      end
    end
  end
  local touched={}
  local function remember(entry)
    for _,saved in ipairs(touched) do if saved.x==entry.x and saved.y==entry.y then return end end
    local city=CityManager.GetCityAt(entry.x,entry.y)
    if city then
      local previous=M.ReadAppliedFood(city)
      touched[#touched+1]={x=entry.x,y=entry.y,previous=previous,before=M.ReadSurplus(city)}
    end
  end
  for _,entry in ipairs(old) do remember(entry) end
  for _,entry in ipairs(new) do remember(entry) end
  local failure=nil
  for _,entry in ipairs(touched) do
    local target=0
    for _,nextEntry in ipairs(new) do if nextEntry.x==entry.x and nextEntry.y==entry.y then target=nextEntry.delta; break end end
    local city=CityManager.GetCityAt(entry.x,entry.y)
    local called,ok,reason,actual=pcall(function()
      local applied,message=M.ApplyCityFood(city,target)
      return applied,message,M.ReadSurplus(city)-entry.before
    end)
    if not called or not ok or math.abs(actual-(target-entry.previous))>EPSILON then
      failure=(not called and tostring(ok)) or reason or ("S1/S2 yield mismatch at "..entry.x..","..entry.y.." actual="..actual.." expected="..(target-entry.previous))
      break
    end
  end
  if failure then
    for _,entry in ipairs(touched) do
      local called,restored,reason=pcall(function() return M.ApplyCityFood(CityManager.GetCityAt(entry.x,entry.y),entry.previous) end)
      if not called or not restored then
        local detail=not called and tostring(restored) or tostring(reason)
        print("[FDT] rollback FAIL "..detail)
        failure=failure.."; rollback failed: "..detail
      end
    end
    return false,failure
  end
  return true
end
local function removeRoute(state,index,reason)
  local route=state.routes[index]
  local proposed={}
  for i,r in ipairs(state.routes) do if i~=index then proposed[#proposed+1]=r end end
  local ledger=aggregate(proposed)
  local ok,errorMessage=applyLedger(state.applied,ledger)
  if not ok then return reject(route.owner,errorMessage) end
  state.routes=proposed; state.applied=ledger
  notice(state,route.owner,"Food Trade route ended: "..reason)
  save(state)
  return true
end
function M.Create(playerID,params)
  if not isHuman(playerID) or type(params)~="table" then return false end
  if not integer(params.senderCity) or not integer(params.receiverCity) or params.senderCity<0 or params.receiverCity<0 or
    params.senderCity>2147483647 or params.receiverCity>2147483647 then
    return reject(playerID,"Choose two cities you own.")
  end
  local state=M.GetState()
  local sender=findCity(playerID,params.senderCity)
  local receiver=findCity(playerID,params.receiverCity)
  if not sender or not receiver or sender:GetID()==receiver:GetID() then return reject(playerID,"Choose two different cities you own.") end
  local amount=params.amount
  if not integer(amount) or amount<1 or amount>Core.MAX_FOOD or amount>math.floor(M.GetAvailableSurplus(sender)) then
    return reject(playerID,"Choose a whole food amount within the sender's own surplus.")
  end
  local incoming=amount
  for _,r in ipairs(state.routes) do
    if r.owner==playerID and r.senderCity==params.senderCity and r.receiverCity==params.receiverCity then
      return reject(playerID,"This city pair already has a route. Edit it instead.")
    end
    if r.receiverPlayer==playerID and r.receiverCity==params.receiverCity then incoming=incoming+math.max(r.amount,r.pendingAmount or 0) end
  end
  if incoming>Core.MAX_FOOD then return reject(playerID,"The receiving city's aggregate exceeds the supported amount.") end
  local called,distanceUnits,errorMessage=pcall(function() return M.MeasureDistance(sender,receiver) end)
  if not called or distanceUnits==nil then return reject(playerID,"Food Trade could not measure the route: "..tostring(called and errorMessage or distanceUnits)) end
  local now=currentTurn()
  state.routes[#state.routes+1]={id=state.nextRouteID,owner=playerID,partner=playerID,senderPlayer=playerID,
    senderCity=sender:GetID(),receiverPlayer=playerID,receiverCity=receiver:GetID(),senderX=sender:GetX(),senderY=sender:GetY(),
    receiverX=receiver:GetX(),receiverY=receiver:GetY(),senderName=sender:GetName(),receiverName=receiver:GetName(),
    amount=amount,flow=0,createdTurn=now,startTurn=now+1,zeroTurns=0,switchedOff=false,pending=true,distanceUnits=distanceUnits}
  state.nextRouteID=state.nextRouteID+1
  notice(state,playerID,"Food Trade route created. It starts next turn."); save(state)
  return true
end
function M.Cancel(playerID,params)
  if not isHuman(playerID) or type(params)~="table" then return false end
  if not integer(params.routeID) or params.routeID<1 then return reject(playerID,"Choose an existing route.") end
  local state=M.GetState()
  for i,r in ipairs(state.routes) do if r.id==params.routeID and r.owner==playerID then return removeRoute(state,i,"cancelled") end end
  return reject(playerID,"This route is no longer available.")
end
function M.Edit(playerID,params)
  if not isHuman(playerID) or type(params)~="table" then return false end
  if not integer(params.routeID) or params.routeID<1 then return reject(playerID,"Choose an existing route.") end
  if params.amount==0 then return M.Cancel(playerID,params) end
  local state=M.GetState()
  for _,r in ipairs(state.routes) do
    if r.id==params.routeID and r.owner==playerID then
      local sender=findCity(r.senderPlayer,r.senderCity,r.senderX,r.senderY)
      local receiver=findCity(r.receiverPlayer,r.receiverCity,r.receiverX,r.receiverY)
      if not sender or not receiver then return reject(playerID,"A route city was lost.") end
      if not integer(params.amount) or params.amount<1 or params.amount>Core.MAX_FOOD or params.amount>math.floor(M.GetAvailableSurplus(sender)) then
        return reject(playerID,"Choose a whole food amount within the sender's own surplus.")
      end
      local incoming=params.amount
      for _,other in ipairs(state.routes) do
        if other.id~=r.id and other.receiverPlayer==r.receiverPlayer and other.receiverCity==r.receiverCity then
          incoming=incoming+math.max(other.amount,other.pendingAmount or 0)
        end
      end
      if incoming>Core.MAX_FOOD then return reject(playerID,"The receiving city's aggregate exceeds the supported amount.") end
      r.pendingAmount=params.amount; r.pendingTurn=currentTurn()+1
      save(state); return true
    end
  end
  return reject(playerID,"This route is no longer available.")
end
function M.ProcessTurn(turn)
  turn=turn or currentTurn()
  local state=M.GetState()
  if state.lastProcessedTurn>=turn then return false end
  local valid,lost,cities,owners={},{},{},{}
  local adapter,cache=nil,FDT_Distance.newCache()
  for _,r in ipairs(state.routes) do
    local sender=findCity(r.senderPlayer,r.senderCity,r.senderX,r.senderY)
    local receiver=findCity(r.receiverPlayer,r.receiverCity,r.receiverX,r.receiverY)
    if not sender or not receiver then lost[#lost+1]=r
    else
      valid[#valid+1]=r
      local seen=false
      for _,city in ipairs({sender,receiver}) do
        seen=false
        for _,c in ipairs(cities) do if c.owner==city:GetOwner() and c.cityID==city:GetID() then seen=true end end
        if not seen then
          cities[#cities+1]={owner=city:GetOwner(),cityID=city:GetID(),available=M.GetAvailableSurplus(city),foodBefore=M.ReadSurplus(city)}
        end
      end
      seen=false
      for _,owner in ipairs(owners) do if owner==r.owner then seen=true end end
      if not seen then owners[#owners+1]=r.owner end
    end
  end
  table.sort(owners)
  local allocated=Core.allocate(valid,cities,turn)
  -- Refresh terrain every processing turn; all routes in this pass share one
  -- ephemeral geometry/source cache. Old records are measured before any fee.
  if #allocated>0 then
    local called,errorMessage=pcall(function()
      adapter=mapAdapter()
      for i,r in ipairs(allocated) do
        local sender=findCity(r.senderPlayer,r.senderCity,r.senderX,r.senderY)
        local receiver=findCity(r.receiverPlayer,r.receiverCity,r.receiverX,r.receiverY)
        local units,reason=measure(sender,receiver,adapter,cache)
        if units==nil then error(reason) end
        r.distanceUnits=units
      end
    end)
    if not called then
      state.lastError="Food Trade could not measure route distance: "..tostring(errorMessage)
      print("[FDT] turn="..turn.." FAIL "..state.lastError)
      save(state); return false
    end
  end
  -- Diagnostics retain pre-allocation route inputs with this turn's distances.
  for i,r in ipairs(valid) do
    for _,measured in ipairs(allocated) do if measured.id==r.id then
      local snapshot={}
      for _,key in ipairs({"id","owner","partner","senderPlayer","senderCity","receiverPlayer","receiverCity","senderX","senderY",
        "receiverX","receiverY","amount","flow","createdTurn","startTurn","zeroTurns","switchedOff","pending","pendingAmount","pendingTurn","senderName","receiverName"}) do
        snapshot[key]=r[key]
      end
      snapshot.distanceUnits=measured.distanceUnits
      valid[i]=snapshot
      break
    end end
  end
  local routes,charges,balances={},{},{}
  for _,owner in ipairs(owners) do
    local owned={}
    for _,r in ipairs(allocated) do if r.owner==owner then owned[#owned+1]=r end end
    local balanceBefore=Players[owner]:GetTreasury():GetGoldBalance()
    balances[#balances+1]={owner=owner,balanceBefore=balanceBefore}
    local affordable,charge=Core.chooseAffordable(owned,balanceBefore)
    charges[#charges+1]={owner=owner,charge=charge,balanceBefore=balanceBefore}
    for _,r in ipairs(affordable) do routes[#routes+1]=r end
  end
  table.sort(routes,function(a,b) return a.id<b.id end)
  local kept,expired=Core.advanceZeroTurns(routes)
  local ledger=aggregate(kept)
  local ok,errorMessage=applyLedger(state.applied,ledger)
  if not ok then
    print("[FDT] turn="..turn.." FAIL "..errorMessage)
    state.lastError=errorMessage; save(state); return false
  end
  for _,charge in ipairs(charges) do if charge.charge>0 then Players[charge.owner]:GetTreasury():ChangeGoldBalance(-charge.charge) end end
  for _,r in ipairs(lost) do notice(state,r.owner,"Food Trade route ended: a city was lost.") end
  for _,r in ipairs(expired) do notice(state,r.owner,"Food Trade route ended: 10 turns with no food flow.") end
  for _,r in ipairs(kept) do
    local prior=nil
    for _,old in ipairs(state.routes) do if old.id==r.id then prior=old; break end end
    if not r.pending and prior then
      if r.switchedOff and not prior.switchedOff then notice(state,r.owner,"Food Trade route switched off: not enough gold.")
      elseif not r.switchedOff then
        local wasReduced=not prior.pending and prior.flow<prior.amount and not prior.switchedOff
        if r.flow<r.amount and not wasReduced then notice(state,r.owner,"Food Trade route reduced: "..r.flow.." of "..r.amount.." food.")
        elseif r.flow==r.amount and (wasReduced or prior.switchedOff) then notice(state,r.owner,"Food Trade route restored.") end
      end
    end
  end
  state.schemaVersion=2
  state.routes=kept; state.applied=ledger; state.lastProcessedTurn=turn; state.lastError=nil
  state.lastCharges=charges
  state.lastInputs={turn=turn,cities=cities,owners=balances,routes=valid}
  save(state)
  print("[FDT] turn="..turn.." routes="..#kept.." processed")
  return true
end
GameEvents.FDT_Create.Add(M.Create)
GameEvents.FDT_Edit.Add(M.Edit)
GameEvents.FDT_Cancel.Add(M.Cancel)
GameEvents.OnGameTurnStarted.Add(M.ProcessTurn)
print("[FDT] Food Trade "..Core.VERSION.." loaded; S1-S5 runtime verification pending")
