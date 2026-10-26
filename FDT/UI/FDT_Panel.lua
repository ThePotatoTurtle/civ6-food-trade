-- Read-only UI. All mutations travel through the synchronized player operation.
-- API evidence: research/UI_APIS.md. No base UI replacement is installed.
include("InstanceManager")
include("FDT_Distance")
local Distance = FDT_Distance
local rowManager = InstanceManager:new("FDT_RouteRow", "Root", Controls.Routes)
local senderID, receiverID, editingID, amount = nil, nil, nil, 1
local launch, shortcut = nil, nil
local updatingSlider = false
local distanceCache = Distance.newCache()
local distanceAdapter = nil
local selectionQuote = nil
local foodSnapshots = {}
local refresh, refreshEditor
local function feedback(message)
  Controls.Feedback:SetText(message)
  Controls.Feedback:SetToolTipString(message)
end

local function state()
  return Game:GetProperty("FDT_State") or { routes = {} }
end
local function city(id)
  local p = Players[Game.GetLocalPlayer()]
  return p and id and p:GetCities():FindID(id) or nil
end
local function name(id)
  local c = city(id)
  return c and Locale.Lookup(c:GetName()) or "Lost city"
end
local function ownFood(id)
  local c = city(id)
  if not c then return 0 end
  if foodSnapshots[id] ~= nil then return foodSnapshots[id] end
  local surplus = c:GetGrowth():GetFoodSurplus()
  local net = 0
  for i = 0, 20 do
    local power = 2^i
    for _, sign in ipairs({"P", "N"}) do
      local building = GameInfo.Buildings["BUILDING_FDT_FOOD_" .. sign .. "_" .. string.format("%.0f",power)]
      if building and c:GetBuildings():HasBuilding(building.Index) then net = net + (sign == "P" and power or -power) end
    end
  end
  foodSnapshots[id] = surplus - net
  return foodSnapshots[id]
end
local function available(id) return math.max(0, math.floor(ownFood(id))) end
local function matchingRouteCity(id, x, y)
  local current = city(id)
  return current and current:GetX() == x and current:GetY() == y
end
local function projectFood()
  local ordered, remaining = {}, {}
  local turn = Game.GetCurrentGameTurn() + 1
  for _, route in ipairs(state().routes or {}) do
    if route.owner == Game.GetLocalPlayer() and route.startTurn <= turn and matchingRouteCity(route.senderCity, route.senderX, route.senderY) and matchingRouteCity(route.receiverCity, route.receiverX, route.receiverY) then ordered[#ordered + 1] = route end
  end
  table.sort(ordered, function(a,b)
    local ac, bc = a.createdTurn or 0, b.createdTurn or 0
    if ac ~= bc then return ac < bc end
    return a.id < b.id
  end)
  local outgoing, incoming, projected = 0, 0, 0
  for _, route in ipairs(ordered) do
    local requested = route.amount
    if route.pendingAmount ~= nil and (route.pendingTurn or turn) <= turn then requested = route.pendingAmount end
    if route.id == editingID then requested = amount end
    if remaining[route.senderCity] == nil then remaining[route.senderCity] = available(route.senderCity) end
    local flow = math.min(requested, remaining[route.senderCity])
    remaining[route.senderCity] = remaining[route.senderCity] - flow
    if route.senderCity == senderID then outgoing = outgoing + flow end
    if route.receiverCity == senderID then incoming = incoming + flow end
    if route.id == editingID then projected = flow end
  end
  if not editingID and senderID and receiverID and senderID ~= receiverID then
    projected = math.min(amount, remaining[senderID] or available(senderID))
    outgoing = outgoing + projected
  end
  return projected, ownFood(senderID) + incoming - outgoing
end
local function cost(flow, distanceUnits)
  return 1 + math.floor((flow * math.max(20, distanceUnits) + 79) / 80)
end
local function mapAdapter()
  local width, height = Map.GetGridSize()
  return {
    count = width * height,
    neighbors = function(index)
      local plot, result = Map.GetPlotByIndex(index), {}
      for direction = 0, 5 do
        local neighbor = Map.GetAdjacentPlot(plot:GetX(), plot:GetY(), direction)
        if neighbor then result[#result + 1] = neighbor:GetIndex() end
      end
      return result
    end,
    isWater = function(index) return Map.GetPlotByIndex(index):IsWater() end
  }
end
local function quoteSelection()
  local sender, receiver = city(senderID), city(receiverID)
  if not sender or not receiver or senderID == receiverID then return nil end
  if selectionQuote and selectionQuote.sender == senderID and selectionQuote.receiver == receiverID then
    return selectionQuote.units, selectionQuote.error
  end
  local from = Map.GetPlot(sender:GetX(), sender:GetY())
  local to = Map.GetPlot(receiver:GetX(), receiver:GetY())
  distanceAdapter = distanceAdapter or mapAdapter()
  local units, errorMessage = Distance.quote(from:GetIndex(), to:GetIndex(), distanceAdapter, distanceCache)
  selectionQuote = {sender = senderID, receiver = receiverID, units = units, error = errorMessage}
  return units, errorMessage
end
local function invalidateQuotes()
  distanceCache, distanceAdapter, selectionQuote = Distance.newCache(), nil, nil
  foodSnapshots = {}
end
local function request(handler, params)
  local playerID = Game.GetLocalPlayer()
  if playerID < 0 then return end
  params.OnStart = handler
  UI.RequestPlayerOperation(playerID, PlayerOperations.EXECUTE_SCRIPT, params)
  feedback("Request sent. The game validates ownership and available food.")
end
local function populate(pulldown, selected, callback)
  pulldown:ClearEntries()
  local p = Players[Game.GetLocalPlayer()]
  if p then
    for _, c in p:GetCities():Members() do
      local entry = {}
      pulldown:BuildEntry("FDT_CityEntry", entry)
      entry.Button:SetText(Locale.Lookup(c:GetName()))
      entry.Button:SetVoid1(c:GetID())
    end
  end
  pulldown:CalculateInternals()
  pulldown:GetButton():SetText(selected and name(selected) or "Choose a city")
  pulldown:RegisterSelectionCallback(callback)
end
refreshEditor = function()
  local cap = available(senderID)
  amount = math.max(0, math.min(amount, cap))
  updatingSlider = true
  Controls.AmountSlider:SetNumSteps(math.max(1, cap))
  Controls.AmountSlider:SetStep(amount)
  updatingSlider = false
  Controls.Amount:SetText(string.format("Food per turn: %d / %d", amount, cap))
  Controls.EditorTitle:SetText(editingID and "Edit route (0 ends it)" or "New route")
  local valid = senderID and receiverID and senderID ~= receiverID and (amount >= 1 or editingID)
  local distanceUnits, quoteError = quoteSelection()
  valid = valid and (distanceUnits ~= nil or (editingID and amount == 0))
  Controls.Confirm:SetDisabled(not valid)
  Controls.Confirm:SetText(editingID and "Confirm changes" or "Confirm route")
  local before = city(senderID) and city(senderID):GetGrowth():GetFoodSurplus() or 0
  local projectedFlow, after = projectFood()
  local detail = distanceUnits and string.format("Effective distance %.1f; maximum cost %d gold/turn.", distanceUnits / 2, amount == 0 and 0 or cost(amount, distanceUnits)) or (quoteError and ("Distance unavailable: " .. quoteError) or "Choose two cities for a quote.")
  local confirmation = string.format("Sender surplus: %.1f before, %.1f projected after. Flow: %d of %d before gold limits.[NEWLINE]%s Starts next turn; oldest routes fill first.", before, after, projectedFlow, amount, detail)
  Controls.Confirmation:SetText(confirmation)
  Controls.Confirmation:SetToolTipString(confirmation .. "[NEWLINE]Own surplus cap: " .. cap .. ". Projection uses current city food and next-turn route requests. Gold shortages can reduce flow.")
end
local function pickSender(id) senderID = id; Controls.Sender:GetButton():SetText(name(id)); refreshEditor() end
local function pickReceiver(id) receiverID = id; Controls.Receiver:GetButton():SetText(name(id)); refreshEditor() end
local function reset()
  editingID, amount = nil, 1
  local selected = UI.GetHeadSelectedCity()
  senderID = selected and selected:GetOwner() == Game.GetLocalPlayer() and selected:GetID() or senderID
  feedback("")
  populate(Controls.Sender, senderID, pickSender)
  populate(Controls.Receiver, receiverID, pickReceiver)
  Controls.Sender:SetDisabled(false); Controls.Receiver:SetDisabled(false)
  refreshEditor()
end
refresh = function()
  if editingID then
    local exists = false
    for _, route in ipairs(state().routes or {}) do if route.id == editingID and route.owner == Game.GetLocalPlayer() then exists = true; break end end
    if not exists then reset() end
  end
  rowManager:ResetInstances()
  local count = 0
  for _, r in ipairs(state().routes or {}) do
    if r.owner == Game.GetLocalPlayer() then
      count = count + 1
      local row, route = rowManager:GetInstance(), r
      row.Edit:SetHide(false); row.Cancel:SetHide(false)
      local pending = route.startTurn > Game.GetCurrentGameTurn()
      local status = route.switchedOff and "Switched off" or (pending and "Pending" or (route.flow < route.amount and "Reduced" or "Active"))
      if route.pendingAmount ~= nil then status = status .. " (edit to " .. route.pendingAmount .. " next turn)" end
      local units = route.distanceUnits
      local price = (pending or route.switchedOff) and 0 or (units and cost(route.flow, units) or nil)
      row.Description:SetText(string.format("%s → %s[NEWLINE]Set %d | Flow %d | %s | %s gold/turn[NEWLINE]Effective distance: %s (sea steps count half)", name(route.senderCity), name(route.receiverCity), route.amount, route.flow, status, price and tostring(price) or "?", units and string.format("%.1f", units / 2) or "pending quote"))
      row.Edit:RegisterCallback(Mouse.eLClick, function()
        editingID, senderID, receiverID, amount = route.id, route.senderCity, route.receiverCity, route.pendingAmount or route.amount
        populate(Controls.Sender, senderID, pickSender); populate(Controls.Receiver, receiverID, pickReceiver)
        Controls.Sender:SetDisabled(true); Controls.Receiver:SetDisabled(true)
        refreshEditor()
      end)
      row.Cancel:RegisterCallback(Mouse.eLClick, function() request("FDT_Cancel", {routeID = route.id}) end)
    end
  end
  if count == 0 then
    local row = rowManager:GetInstance()
    row.Description:SetText("No food routes. Choose two of your cities below.")
    row.Edit:SetHide(true); row.Cancel:SetHide(true)
  end
  Controls.Routes:CalculateSize(); Controls.RouteScroll:CalculateInternalSize()
  local snapshot = state()
  if snapshot.lastError then feedback("Food Trade could not update: " .. snapshot.lastError)
  else
    for i = #(snapshot.notices or {}), 1, -1 do
      local notice = snapshot.notices[i]
      if notice.owner == Game.GetLocalPlayer() then feedback(notice.message); break end
    end
  end
  refreshEditor()
end
local function open()
  Controls.Panel:SetHide(false); reset(); refresh()
end
local function attach()
  if not launch then
    local stack = ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")
    if stack then
      launch = {}; ContextPtr:BuildInstanceForControl("FDT_LaunchButton", launch, stack)
      launch.Button:RegisterCallback(Mouse.eLClick, function() if Controls.Panel:IsHidden() then open() else Controls.Panel:SetHide(true) end end)
      stack:CalculateSize()
      local w = stack:GetSizeX()
      ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBacking"):SetSizeX(w + 116)
      ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBackingTile"):SetSizeX(w - 20)
      LuaEvents.LaunchBar_Resize(w)
    end
  end
  if not shortcut then
    local actions = ContextPtr:LookUpControl("/InGame/CityPanel/ActionStack")
    if actions then
      shortcut = {}; ContextPtr:BuildInstanceForControl("FDT_CityShortcut", shortcut, actions)
      shortcut.Button:RegisterCallback(Mouse.eLClick, open)
      actions:CalculateSize(); actions:ReprocessAnchoring()
    end
  end
end
local function foodTooltip()
  local selected = UI.GetHeadSelectedCity()
  if not selected or selected:GetOwner() ~= Game.GetLocalPlayer() then return end
  local food = ContextPtr:LookUpControl("/InGame/CityPanel/FoodGrid")
  if not food then return end
  local lines = {}
  for _, r in ipairs(state().routes or {}) do
    if r.owner == Game.GetLocalPlayer() and r.flow > 0 then
      if r.senderCity == selected:GetID() then lines[#lines + 1] = string.format("Food Trade: -%d to %s", r.flow, name(r.receiverCity)) end
      if r.receiverCity == selected:GetID() then lines[#lines + 1] = string.format("Food Trade: +%d from %s", r.flow, name(r.senderCity)) end
    end
  end
  local marker = "[NEWLINE]Food Trade routes:[NEWLINE]"
  local base = food:GetToolTipString() or selected:GetYieldToolTip(YieldTypes.FOOD)
  local position = string.find(base, marker, 1, true)
  if position then base = string.sub(base, 1, position - 1) end
  food:SetToolTipString(base .. (#lines > 0 and marker .. table.concat(lines, "[NEWLINE]") or ""))
end
local function published()
  invalidateQuotes()
  foodTooltip()
  if not Controls.Panel:IsHidden() then refresh() end
end
Controls.Close:RegisterCallback(Mouse.eLClick, function() Controls.Panel:SetHide(true) end)
Controls.New:RegisterCallback(Mouse.eLClick, reset)
Controls.AmountSlider:RegisterSliderCallback(function() if not updatingSlider then amount = Controls.AmountSlider:GetStep(); refreshEditor() end end)
Controls.Confirm:RegisterCallback(Mouse.eLClick, function()
  if editingID then request("FDT_Edit", {routeID = editingID, amount = amount})
  else request("FDT_Create", {senderCity = senderID, receiverCity = receiverID, amount = amount}) end
end)
Events.LoadGameViewStateDone.Add(attach)
Events.GameCoreEventPublishComplete.Add(published)
Events.CitySelectionChanged.Add(foodTooltip)
Events.LocalPlayerChanged.Add(function() Controls.Panel:SetHide(true); senderID, receiverID, editingID = nil, nil, nil; invalidateQuotes() end)
ContextPtr:SetHide(false)
attach()
