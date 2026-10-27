-- Food Trading development scenario. Source evidence: research/UI_APIS.md and
-- research/ENGINE_APIS.md. Separate gameplay context, synchronized requests only.
include("FDT_Distance")
local Distance = FDT_Distance
local TARGET_VERSION = "0.2.2"
local passes, failures, pending = 0, 0, 0
local logOwner = -1
local function log(tag, actual, expected, ok)
  if ok then passes = passes + 1 else failures = failures + 1 end
  print(string.format("[%s] turn=%d owner=%d actual=%s expected=%s %s", tag, Game.GetCurrentGameTurn(), logOwner, tostring(actual), tostring(expected), ok and "PASS" or "FAIL"))
end
local function waitForLook(tag, reason)
  pending = pending + 1; print("[" .. tag .. "] PENDING " .. reason)
end
local function summary() print(string.format("[SUMMARY] %d PASS, %d FAIL, %d PENDING", passes, failures, pending)) end
local function close(a,b) return math.abs(a-b) < 0.01 end
local function scenario() return Game:GetProperty("FDT_DevScenario") end
local function city(owner, id) return CityManager.GetCity(owner,id) end
local function read(c) return c:GetGrowth():GetFoodSurplus() end
local function setBuildings(c, value, prefix, bits)
  if value ~= math.floor(value) or math.abs(value) > 2^bits-1 then error("Unsupported calibration food: " .. tostring(value)) end
  local buildings, queue = c:GetBuildings(), c:GetBuildQueue()
  for _, sign in ipairs({"P", "N"}) do
    for i = 0, bits-1 do
      local power = 2^i
      local index = GameInfo.Buildings[prefix .. sign .. "_" .. string.format("%.0f",power)].Index
      local wanted = ((value > 0 and sign == "P") or (value < 0 and sign == "N")) and math.floor(math.abs(value)/power)%2 == 1
      if wanted and not buildings:HasBuilding(index) then queue:CreateIncompleteBuilding(index,100)
      elseif not wanted and buildings:HasBuilding(index) then buildings:RemoveBuilding(index); queue:RemoveBuilding(index) end
    end
  end
end
local function calibration(c, value) setBuildings(c,value,"BUILDING_FDT_DEV_FOOD_",6) end
local function ownSurplus(c)
  local value = read(c)
  for i=0,20 do
    local power=2^i
    for _, sign in ipairs({"P","N"}) do
      local building=GameInfo.Buildings["BUILDING_FDT_FOOD_"..sign.."_"..string.format("%.0f",power)]
      if building and c:GetBuildings():HasBuilding(building.Index) then value=value-(sign=="P" and power or -power) end
    end
  end
  return value
end
local function calibrate(c, target)
  calibration(c,0)
  local base = ownSurplus(c)
  local delta = math.floor(target-base + 0.5)
  calibration(c,delta)
  return ownSurplus(c),delta
end
local function snapshot(r)
  return {id=r.id,owner=r.owner,senderPlayer=r.senderPlayer,senderCity=r.senderCity,receiverPlayer=r.receiverPlayer,receiverCity=r.receiverCity,amount=r.pendingAmount or r.amount,createdTurn=r.createdTurn,startTurn=r.startTurn,zeroTurns=r.zeroTurns or 0,distanceUnits=r.distanceUnits}
end
local function distanceSpikes(owner, s)
  local function chain(water)
    return {count=41,neighbors=function(index)
      local result={};if index>0 then result[#result+1]=index-1 end;if index<40 then result[#result+1]=index+1 end;return result
    end,isWater=function(index)return water and index>0 and index<40 end}
  end
  local land=Distance.quote(0,40,chain(false),Distance.newCache())
  local sea=Distance.quote(0,40,chain(true),Distance.newCache())
  log("SPIKE S6 land 40 steps",land,80,land==80)
  log("SPIKE S6 sea 38 steps and 2 crossings",sea,46,sea==46)
  local crossing=Distance.quote(0,1,{count=2,neighbors=function(index)return {1-index} end,isWater=function(index)return index==1 end},Distance.newCache())
  log("SPIKE S6 single crossing total",crossing,4,crossing==4)
  if land and sea then
    local landFee=1+math.floor((5*math.max(20,land)+79)/80)
    local seaFee=1+math.floor((5*math.max(20,sea)+79)/80)
    log("SPIKE S6 land fee flow=5",landFee,6,landFee==6)
    log("SPIKE S6 sea fee flow=5",seaFee,4,seaFee==4)
  end
  local width,height=Map.GetGridSize()
  local adapter={count=width*height,neighbors=function(index)
    local p,result=Map.GetPlotByIndex(index),{}
    for direction=0,5 do local neighbor=Map.GetAdjacentPlot(p:GetX(),p:GetY(),direction);if neighbor then result[#result+1]=neighbor:GetIndex() end end
    return result
  end,isWater=function(index)return Map.GetPlotByIndex(index):IsWater() end}
  local sender,receiver=city(owner,s.cities[1]),city(owner,s.cities[2])
  local from=Map.GetPlot(sender:GetX(),sender:GetY()):GetIndex()
  local to=Map.GetPlot(receiver:GetX(),receiver:GetY()):GetIndex()
  local cache=Distance.newCache()
  local forward=Distance.quote(from,to,adapter,cache)
  local reverse=Distance.quote(to,from,adapter,cache)
  log("SPIKE S6 map symmetric city="..sender:GetID().."->"..receiver:GetID(),forward,reverse,forward~=nil and forward>0 and forward==reverse)
end
local function saveExpectations(s)
  local current = Game:GetProperty("FDT_State") or {routes={}}
  s.expectedRoutes = {}
  for _, r in ipairs(current.routes) do if r.owner == s.owner then s.expectedRoutes[#s.expectedRoutes+1]=snapshot(r) end end
  s.expectedSurpluses = {}
  for _, id in ipairs(s.cities) do local c=city(s.owner,id); if c then s.expectedSurpluses[#s.expectedSurpluses+1]={id=id,own=ownSurplus(c)} end end
  s.goldBefore = Players[s.owner]:GetTreasury():GetGoldBalance()
  s.expectTurn = Game.GetCurrentGameTurn()+1
end
local function setup(owner)
  local old = scenario()
  if old then log("SETUP", "scenario exists", "one setup per new game", false); return end
  local player=Players[owner]
  local anchor=nil
  for _, c in player:GetCities():Members() do anchor=c; break end
  if not anchor then for _, unit in player:GetUnits():Members() do anchor=unit; break end end
  if not anchor then error("No player city or starting unit is available as a scenario anchor") end
  local width,height=Map.GetGridSize()
  local candidates={}
  for index=0,width*height-1 do
    local p=Map.GetPlotByIndex(index)
    local distance=Map.GetPlotDistance(anchor:GetX(),anchor:GetY(),p:GetX(),p:GetY())
    if distance <= 20 and not p:IsWater() and not p:IsImpassable() and p:GetOwner()==-1 then candidates[#candidates+1]={plot=p,distance=distance,index=index} end
  end
  table.sort(candidates,function(a,b) if a.distance==b.distance then return a.index<b.index end; return a.distance<b.distance end)
  local cities={}
  for _, candidate in ipairs(candidates) do
    local p=candidate.plot
    local fits=true
    for _, other in ipairs(PlayerManager.GetAlive()) do
      for _, c in other:GetCities():Members() do if Map.GetPlotDistance(c:GetX(),c:GetY(),p:GetX(),p:GetY()) < 4 then fits=false end end
    end
    if fits then
      local c=player:GetCities():Create(p:GetX(),p:GetY())
      if c then cities[#cities+1]=c:GetID() end
      if #cities==3 then break end
    end
  end
  if #cities~=3 then error("Could not place three test cities within 20 hexes; start a larger land map") end
  local sender=city(owner,cities[1])
  local farmIndex=nil
  for direction=0,5 do
    local p=Map.GetAdjacentPlot(sender:GetX(),sender:GetY(),direction)
    if p and p:GetOwner()==owner and not p:IsWater() and not p:IsImpassable() then
      ImprovementBuilder.SetImprovementType(p,GameInfo.Improvements["IMPROVEMENT_FARM"].Index,owner)
      farmIndex=p:GetIndex(); break
    end
  end
  if not farmIndex then error("No adjacent test farm location") end
  local actual,delta=calibrate(sender,8)
  local treasury=player:GetTreasury()
  treasury:ChangeGoldBalance(100-treasury:GetGoldBalance())
  local s={owner=owner,cities=cities,farmIndex=farmIndex,generation=Game.GetCurrentGameTurn()+1,checker=true,calibration=delta,message="Scenario ready: Sender, Receiver, Third. Checker enabled."}
  saveExpectations(s); Game:SetProperty("FDT_DevScenario",s)
  log("SETUP food",actual,8,close(actual,8)); log("SETUP gold",treasury:GetGoldBalance(),100,close(treasury:GetGoldBalance(),100))
  summary()
end
local function spikes(owner)
  local s=scenario(); if not s or s.owner~=owner then error("Click Setup Food Scenario first") end
  local c=city(owner,s.cities[1]); if not c then error("Sender was lost") end
  local routes=(Game:GetProperty("FDT_State") or {}).routes or {}
  for _, r in ipairs(routes) do if r.senderCity==c:GetID() or r.receiverCity==c:GetID() then error("Run spikes before creating routes") end end
  local before=read(c); local yieldBefore=c:GetYield(YieldTypes.FOOD)
  local treasury=Players[owner]:GetTreasury(); local originalBalance=treasury:GetGoldBalance()
  local ok,err=pcall(function()
  log("SPIKE S1 control",before,before,true)
  for _, delta in ipairs({-3,5,-40,40,0}) do
    setBuildings(c,delta,"BUILDING_FDT_FOOD_",21)
    local after=read(c); local actualYield=c:GetYield(YieldTypes.FOOD)
    log("SPIKE S1 A food city="..c:GetID().." delta="..delta,actualYield,yieldBefore+delta,close(actualYield,yieldBefore+delta))
    log("SPIKE S2 surplus city="..c:GetID().." delta="..delta,after,before+delta,close(after,before+delta))
  end
  setBuildings(c,0,"BUILDING_FDT_FOOD_",21)
  log("SPIKE S1 cleanup",read(c),before,close(read(c),before))
  waitForLook("SPIKE S1 B","AttachModifierByID has no verified removal API; no permanent modifier attached")
  waitForLook("SPIKE S1 C","No verified reversible city property food effect")
  waitForLook("SPIKE S2 visual","Compare Sender food surplus in city panel with logged before="..before)
  local treasury=Players[owner]:GetTreasury(); local balance=treasury:GetGoldBalance()
  treasury:ChangeGoldBalance(-(balance+1))
  local negative=treasury:GetGoldBalance()
  log("SPIKE S3 overdraft",negative,-1,close(negative,-1))
  treasury:ChangeGoldBalance(balance-negative)
  log("SPIKE S3 restored",treasury:GetGoldBalance(),balance,close(treasury:GetGoldBalance(),balance))
  local resolved=city(owner,c:GetID())
  log("SPIKE S4 resolve owner",resolved and resolved:GetOwner(),owner,resolved and resolved:GetOwner()==owner)
  log("SPIKE S4 missing city",city(owner,2147483647)==nil,true,city(owner,2147483647)==nil)
  waitForLook("SPIKE S4 capture/flip/raze","Ownership resolver sourced; actual capture, loyalty flip and raze remain separate runtime cases")
  waitForLook("SPIKE S5","Food launch button and city shortcut should open the panel; verify city tooltip after creating a route")
  distanceSpikes(owner,s)
  end)
  local foodOK,foodError=pcall(function() setBuildings(c,0,"BUILDING_FDT_FOOD_",21) end)
  local goldOK,goldError=pcall(function() treasury:ChangeGoldBalance(originalBalance-treasury:GetGoldBalance()) end)
  log("SPIKE cleanup food",foodOK and read(c) or foodError,before,foodOK and close(read(c),before))
  log("SPIKE cleanup treasury",goldOK and treasury:GetGoldBalance() or goldError,originalBalance,goldOK and close(treasury:GetGoldBalance(),originalBalance))
  if not ok then log("SPIKE ERROR",err,"all spike steps complete",false) end
  saveExpectations(s); Game:SetProperty("FDT_DevScenario",s); summary()
end
local function action(owner,params)
  if not Players[owner] or not Players[owner]:IsHuman() or type(params)~="table" then return end
  logOwner=owner
  local ok,err=pcall(function()
    if params.action=="setup" then setup(owner)
    elseif params.action=="spikes" then spikes(owner)
    else
      local s=scenario(); if not s or s.owner~=owner then error("Click Setup Food Scenario first") end
      if params.action=="gold" then
        local t=Players[owner]:GetTreasury(); t:ChangeGoldBalance(-t:GetGoldBalance()); log("SET GOLD",t:GetGoldBalance(),0,close(t:GetGoldBalance(),0))
      elseif params.action=="pillage" then
        local c=city(owner,s.cities[1]); if not c then error("Sender was lost") end
        local before=ownSurplus(c)
        Map.GetImprovementBuilder().SetImprovementPillaged(Map.GetPlotByIndex(s.farmIndex),true)
        local natural=ownSurplus(c)
        -- Guarantee the shrink scenario even if the governor was not working the farm.
        local actual,delta=calibrate(c,2); s.calibration=delta
        print(string.format("[SETUP pillage] before=%.2f naturalAfter=%.2f calibratedAfter=%.2f",before,natural,actual))
        log("PILLAGE shrink setup",actual,2,close(actual,2))
      elseif params.action=="checker" then s.checker=not s.checker
      else error("Unknown dev action") end
      saveExpectations(s); Game:SetProperty("FDT_DevScenario",s); summary()
    end
  end)
  if not ok then log("DEV ERROR",err,"successful scenario action",false); summary() end
end
local function checker(turn)
  local s=scenario(); if not s or not s.checker then return end
  logOwner=s.owner
  local current=Game:GetProperty("FDT_State") or {routes={}}
  local budget=s.goldBefore or 0; local expected={}; local remaining={}
  local measurements=current.lastInputs or {}
  if measurements.turn~=turn then log("CHECK gameplay turn",measurements.turn,turn,false); summary(); return end
  local inputs=measurements.cities or {}
  for _, entry in ipairs(inputs) do if entry.owner==s.owner then remaining[entry.cityID]=math.max(0,math.floor(entry.available)) end end
  if #inputs==0 then
    for _, entry in ipairs(s.expectedSurpluses or {}) do remaining[entry.id]=math.max(0,math.floor(entry.own)) end
  end
  for _, entry in ipairs(current.lastCharges or {}) do if entry.owner==s.owner and entry.balanceBefore then budget=entry.balanceBefore end end
  local routeInputs={}
  for _, r in ipairs(measurements.routes or {}) do if r.owner==s.owner then routeInputs[#routeInputs+1]=snapshot(r) end end
  for _, r in ipairs(s.expectedRoutes or {}) do
    local sender,receiver=city(r.senderPlayer,r.senderCity),city(r.receiverPlayer,r.receiverCity)
    if not sender or not receiver then
      local exists=false; for _, actual in ipairs(current.routes) do if actual.id==r.id then exists=true end end
      log("CHECK lost route="..r.id,exists,false,not exists)
    end
  end
  for _, r in ipairs(routeInputs) do
    if r.startTurn<=turn then
      local flow=math.min(r.amount,remaining[r.senderCity] or 0)
      remaining[r.senderCity]=(remaining[r.senderCity] or 0)-flow
      if type(r.distanceUnits)~="number" or r.distanceUnits<0 or r.distanceUnits~=math.floor(r.distanceUnits) then log("CHECK route="..r.id.." distance",r.distanceUnits,"whole nonnegative half-hex units",false); summary(); return end
      local fee=1+math.floor((flow*math.max(20,r.distanceUnits)+79)/80)
      expected[#expected+1]={id=r.id,flow=flow,cost=fee,off=false,zeroTurns=r.zeroTurns,amount=r.amount,senderCity=r.senderCity,receiverCity=r.receiverCity,distanceUnits=r.distanceUnits}
    end
  end
  local charge=0; for _, r in ipairs(expected) do charge=charge+r.cost end
  for i=#expected,1,-1 do if charge>budget then local r=expected[i]; charge=charge-r.cost; r.cost=0; r.flow=0; r.off=true end end
  for _, e in ipairs(expected) do
    local actual=nil; for _, r in ipairs(current.routes) do if r.id==e.id then actual=r end end
    if e.flow==0 and e.zeroTurns>=9 then log("CHECK zero-flow removal route="..e.id,actual==nil,true,actual==nil)
    else log("CHECK route="..e.id.." food",actual and actual.flow,e.flow,actual and actual.flow==e.flow) end
    if actual then
      log("CHECK route="..e.id.." amount",actual.amount,e.amount,actual.amount==e.amount)
      log("CHECK route="..e.id.." switchedOff",actual.switchedOff,e.off,actual.switchedOff==e.off)
      log("CHECK route="..e.id.." distanceUnits",actual.distanceUnits,e.distanceUnits,actual.distanceUnits==e.distanceUnits)
      log("CHECK route="..e.id.." zeroTurns",actual.zeroTurns,e.flow==0 and e.zeroTurns+1 or 0,actual.zeroTurns==(e.flow==0 and e.zeroTurns+1 or 0))
      print(string.format("[CHECK] route=%d amount=%d flow=%d effectiveDistance=%.1f switchedOff=%s charge=%d",actual.id,actual.amount,actual.flow,e.distanceUnits/2,tostring(actual.switchedOff),e.cost))
    end
  end
  for _, id in ipairs(s.cities) do
    local c=city(s.owner,id)
    if c then
      local before=nil
      for _, input in ipairs(inputs) do if input.owner==s.owner and input.cityID==id then before=input.available end end
      if before then
        local expectedFood=before
        for _, e in ipairs(expected) do
          if not (e.flow==0 and e.zeroTurns>=9) then
            if e.senderCity==id then expectedFood=expectedFood-e.flow end
            if e.receiverCity==id then expectedFood=expectedFood+e.flow end
          end
        end
        log("CHECK city="..id.." food surplus",read(c),expectedFood,close(read(c),expectedFood))
      else print(string.format("[CHECK] city=%d foodYield=%.2f surplus=%.2f no active route",id,c:GetYield(YieldTypes.FOOD),read(c))) end
    end
  end
  local actualCharge=nil
  for _, entry in ipairs(current.lastCharges or {}) do if entry.owner==s.owner then actualCharge=entry.charge end end
  if actualCharge~=nil then log("CHECK charged",actualCharge,charge,close(actualCharge,charge))
  else print(string.format("[CHECK] expectedCharge=%d treasuryNow=%.2f (read gameplay charge log; engine income timing affects balance)",charge,Players[s.owner]:GetTreasury():GetGoldBalance())) end
  saveExpectations(s); Game:SetProperty("FDT_DevScenario",s); summary()
end
GameEvents.FDT_DevAction.Add(action)
GameEvents.OnGameTurnStarted.Add(checker)
local function routesChanged(owner)
  local s=scenario()
  if s and s.owner==owner then saveExpectations(s); Game:SetProperty("FDT_DevScenario",s) end
end
GameEvents.FDT_Create.Add(routesChanged)
GameEvents.FDT_Edit.Add(routesChanged)
GameEvents.FDT_Cancel.Add(routesChanged)
print("[FDT DEV] target "..TARGET_VERSION.." loaded; use DEV launch button, then Setup Food Scenario")
