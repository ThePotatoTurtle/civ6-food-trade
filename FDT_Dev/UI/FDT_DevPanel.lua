-- Synced developer requests; no direct gameplay state writes from UI.
local launch, focused, renamed = nil, nil, {}
local function request(action)
  local owner = Game.GetLocalPlayer()
  if owner < 0 then return end
  UI.RequestPlayerOperation(owner, PlayerOperations.EXECUTE_SCRIPT, {OnStart = "FDT_DevAction", action = action})
  Controls.Status:SetText("Sent " .. action .. ". Results are recorded in Lua.log.")
end
local function published()
  local s = Game:GetProperty("FDT_DevScenario")
  if not s or s.owner ~= Game.GetLocalPlayer() then return end
  local player = Players[s.owner]
  for i, id in ipairs(s.cities or {}) do
    local c = player:GetCities():FindID(id)
    local label = ({"Sender", "Receiver", "Third"})[i]
    if c and c:GetOwner()==s.owner and not renamed[id] then
      renamed[id] = true
      local params = {}; params[CityCommandTypes.PARAM_NAME] = label
      CityManager.RequestCommand(c, CityCommandTypes.NAME_CITY, params)
    end
  end
  if focused ~= s.generation then
    local c = player:GetCities():FindID(s.cities[1])
    if c then UI.LookAtPlot(c:GetX(), c:GetY()); UI.SelectCity(c); focused = s.generation end
  end
  Controls.Status:SetText(s.message or "Scenario ready. Checker writes actual and expected values each turn.")
end
local function attach()
  if launch then return end
  local stack = ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")
  if not stack then return end
  launch = {}; ContextPtr:BuildInstanceForControl("FDT_DevLaunch", launch, stack)
  launch.Button:RegisterCallback(Mouse.eLClick, function() Controls.Panel:SetHide(not Controls.Panel:IsHidden()) end)
  stack:CalculateSize(); local w = stack:GetSizeX()
  ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBacking"):SetSizeX(w + 116)
  ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBackingTile"):SetSizeX(w - 20)
  LuaEvents.LaunchBar_Resize(w)
end
Controls.Close:RegisterCallback(Mouse.eLClick, function() Controls.Panel:SetHide(true) end)
Controls.Setup:RegisterCallback(Mouse.eLClick, function() request("setup") end)
Controls.Spikes:RegisterCallback(Mouse.eLClick, function() request("spikes") end)
Controls.Pillage:RegisterCallback(Mouse.eLClick, function() request("pillage") end)
Controls.Gold:RegisterCallback(Mouse.eLClick, function() request("gold") end)
Controls.Checker:RegisterCallback(Mouse.eLClick, function() request("checker") end)
Events.LoadGameViewStateDone.Add(attach)
Events.GameCoreEventPublishComplete.Add(published)
Events.LocalPlayerChanged.Add(function() Controls.Panel:SetHide(true); focused = nil; renamed = {} end)
ContextPtr:SetHide(false)
attach()
