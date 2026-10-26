-- Pure deterministic route rules. This module also runs outside Civ VI.
FDT_Core = {}
local M = FDT_Core
M.VERSION = "0.2.0"
M.MAX_FOOD = 2097151
local fields = {"id","owner","partner","senderPlayer","senderCity","receiverPlayer","receiverCity",
  "senderX","senderY","receiverX","receiverY","amount","flow","createdTurn","startTurn",
  "zeroTurns","switchedOff","pending","pendingAmount","pendingTurn","senderName","receiverName","distanceUnits"}
local function copy(route)
  local result = {}
  for _, key in ipairs(fields) do result[key] = route[key] end
  return result
end
local function ordered(routes)
  local result = {}
  for _, route in ipairs(routes) do result[#result+1] = copy(route) end
  table.sort(result,function(a,b)
    if a.createdTurn ~= b.createdTurn then return a.createdTurn < b.createdTurn end
    return a.id < b.id
  end)
  return result
end
function M.availableSurplus(foodSurplus,outgoing,incoming)
  return foodSurplus + outgoing - incoming
end
function M.cost(flow,distanceUnits)
  -- A missing optional distance preserves legacy pure callers. Gameplay always
  -- measures routes before charging, including saves created before version0.2.
  local numerator=math.max(0,flow)*math.max(20,distanceUnits or 20)
  return 1+math.floor((numerator+79)/80)
end
function M.allocate(routes,cities,turn)
  local result = ordered(routes)
  local remaining = {}
  for i,city in ipairs(cities) do remaining[i] = math.max(0,math.floor(city.available)) end
  for _,route in ipairs(result) do
    route.pending = (route.startTurn or 0) > turn
    route.switchedOff = false
    route.flow = 0
    if route.pendingAmount ~= nil and (route.pendingTurn or 0) <= turn then
      route.amount = route.pendingAmount
      route.pendingAmount = nil
      route.pendingTurn = nil
    end
    if not route.pending then
      for i,city in ipairs(cities) do
        if city.owner == route.senderPlayer and city.cityID == route.senderCity then
          route.flow = math.min(route.amount,remaining[i])
          remaining[i] = remaining[i] - route.flow
          break
        end
      end
    end
  end
  return result
end
function M.chooseAffordable(routes,treasury)
  local result = ordered(routes)
  local charge = 0
  for _,route in ipairs(result) do
    if not route.pending then charge = charge + M.cost(route.flow,route.distanceUnits) end
  end
  local budget = math.max(0,math.floor(treasury))
  for i=#result,1,-1 do
    if charge <= budget then break end
    local route = result[i]
    if not route.pending then
      charge = charge - M.cost(route.flow,route.distanceUnits)
      route.flow = 0
      route.switchedOff = true
    end
  end
  return result,charge
end
function M.advanceZeroTurns(routes)
  local kept,removed = {},{}
  for _,original in ipairs(routes) do
    local route = copy(original)
    if not route.pending then
      route.zeroTurns = route.flow == 0 and ((route.zeroTurns or 0)+1) or 0
    end
    if (route.zeroTurns or 0) >= 10 then removed[#removed+1] = route
    else kept[#kept+1] = route end
  end
  return kept,removed
end
return M
