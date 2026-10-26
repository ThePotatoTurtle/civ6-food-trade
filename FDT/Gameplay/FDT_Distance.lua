-- Pure weighted distance. Adapters supply ordered hex neighbors and water flags.
-- Units are half a land hex: land-land=2, water-water=1, mixed=4 total.
FDT_Distance = {}
local M = FDT_Distance
local function integer(value)
  return type(value)=="number" and value==value and value~=math.huge and value~=-math.huge and value==math.floor(value)
end
function M.newCache() return {nodes={},sources={}} end
function M.edgeCost(aWater,bWater)
  if aWater~=bWater then return 4 end
  return aWater and 1 or 2
end
local function less(a,b)
  if a.cost~=b.cost then return a.cost<b.cost end
  return a.index<b.index
end
local function push(heap,item)
  local index=#heap+1
  heap[index]=item
  while index>1 do
    local parent=math.floor(index/2)
    if not less(heap[index],heap[parent]) then break end
    heap[index],heap[parent]=heap[parent],heap[index]
    index=parent
  end
end
local function pop(heap)
  local first,last=heap[1],heap[#heap]
  heap[#heap]=nil
  if #heap==0 then return first end
  heap[1]=last
  local index=1
  while index*2<=#heap do
    local child=index*2
    if child<#heap and less(heap[child+1],heap[child]) then child=child+1 end
    if not less(heap[child],heap[index]) then break end
    heap[index],heap[child]=heap[child],heap[index]
    index=child
  end
  return first
end
local function node(adapter,cache,index)
  local entry=cache.nodes[index+1]
  if entry then return entry end
  local water=adapter.isWater(index)
  if type(water)~="boolean" then return nil,"A map tile could not be classified." end
  local adjacent=adapter.neighbors(index)
  if type(adjacent)~="table" then return nil,"Map neighbors are unavailable." end
  entry={water=water,neighbors={}}
  for _,neighbor in ipairs(adjacent) do
    if not integer(neighbor) or neighbor<0 or neighbor>=adapter.count then
      return nil,"A map neighbor has an invalid plot index."
    end
    entry.neighbors[#entry.neighbors+1]=neighbor
  end
  cache.nodes[index+1]=entry
  return entry
end
function M.quote(source,target,adapter,cache)
  if type(adapter)~="table" or not integer(adapter.count) or adapter.count<1 or
    type(adapter.neighbors)~="function" or type(adapter.isWater)~="function" then
    return nil,"Map distance data is unavailable."
  end
  if not integer(source) or not integer(target) or source<0 or target<0 or
    source>=adapter.count or target>=adapter.count then return nil,"A route endpoint has an invalid plot index." end
  cache=cache or M.newCache()
  -- A cache belongs to one adapter snapshot only. Callers create it per turn/quote.
  if cache.adapter~=adapter then
    cache.nodes,cache.sources,cache.adapter={},{},adapter
  end
  local distances=cache.sources[source+1]
  if not distances then
    distances={}
    distances[source+1]=0
    local heap={}
    push(heap,{index=source,cost=0})
    while #heap>0 do
      local current=pop(heap)
      if current.cost==distances[current.index+1] then
        local currentNode,reason=node(adapter,cache,current.index)
        if not currentNode then return nil,reason end
        for _,neighbor in ipairs(currentNode.neighbors) do
          local nextNode,errorMessage=node(adapter,cache,neighbor)
          if not nextNode then return nil,errorMessage end
          local cost=current.cost+M.edgeCost(currentNode.water,nextNode.water)
          local previous=distances[neighbor+1]
          if previous==nil or cost<previous then
            distances[neighbor+1]=cost
            push(heap,{index=neighbor,cost=cost})
          end
        end
      end
    end
    cache.sources[source+1]=distances
  end
  local result=distances[target+1]
  if result==nil then return nil,"No abstract map path could be measured." end
  return result
end
return M
