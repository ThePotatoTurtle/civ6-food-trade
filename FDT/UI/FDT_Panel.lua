-- Read-only UI. All mutations travel through the synchronized player operation.
-- API evidence: research/UI_APIS.md. No base UI replacement is installed.
include("InstanceManager")
local rowManager = InstanceManager:new("FDT_RouteRow", "Root", Controls.Routes)
local senderID, receiverID, editingID, amount = nil, nil, nil, 1
local launch, shortcut = nil, nil
local updatingSlider = false
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
local function available(id)
  local c = city(id)
  if not c then return 0 end
  local surplus = c:GetGrowth():GetFoodSurplus()
  local net = 0
  for i = 0, 20 do
    local power = 2^i
    for _, sign in ipairs({"P", "N"}) do
      local building = GameInfo.Buildings["BUILDING_FDT_FOOD_" .. sign .. "_" .. string.format("%.0f",power)]
      if building and c:GetBuildings():HasBuilding(building.Index) then net = net + (sign == "P" and power or -power) end
    end
  end
  return math.max(0, math.floor(surplus - net))
end
local function cost(flow) return 1 + math.ceil(flow / 4) end
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
  Controls.Confirm:SetDisabled(not valid)
  Controls.Confirm:SetText(editingID and "Confirm changes" or "Confirm route")
  local before = city(senderID) and city(senderID):GetGrowth():GetFoodSurplus() or 0
  local previous = 0
  for _, r in ipairs(state().routes or {}) do if r.id == editingID then previous = r.flow end end
  Controls.Confirmation:SetText(string.format("Sender surplus: %.1f before, %.1f after. Own surplus cap: %d. Planned cost: %d gold/turn. Starts next turn; older routes receive food first.", before, before + previous - amount, cap, amount == 0 and 0 or cost(amount)))
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
      row.Description:SetText(string.format("%s → %s[NEWLINE]Set %d | Flow %d | %s | %d gold/turn", name(route.senderCity), name(route.receiverCity), route.amount, route.flow, status, (pending or route.switchedOff) and 0 or cost(route.flow)))
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
Events.LocalPlayerChanged.Add(function() Controls.Panel:SetHide(true); senderID, receiverID, editingID = nil, nil, nil end)
ContextPtr:SetHide(false)
attach()
