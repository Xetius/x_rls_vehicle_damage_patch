-- Lets a damaged car into RLS Part Customization, shows which parts are damaged, and keeps the
-- damage on every part that isn't replaced.
--
-- RLS blocks Part Customization once 3 or more parts are broken (integrity 0), in two places: the
-- garage computer greys the button out, and startShopping refuses with "Repair the vehicle before
-- changing parts." Both are lifted here.
--
-- The block also hid a problem: the shop's preview respawns the car without damage, then copies
-- its (healthy) part conditions into the record, and checkout clears the saved damage. Lifting the
-- block on its own would let any purchase repair the whole car for free. So this mod:
--   1. copies the car's part conditions and a damage snapshot when the shop opens,
--   2. at checkout, puts the old conditions back on every part that wasn't replaced (and on
--      removed parts going into the parts inventory),
--   3. after checkout, reloads the snapshot onto the car, skipping the replaced slots, with RLS's
--      own partial loader (overhaulDamageState.loadDamageData), then lets RLS capture it again,
--   4. on Cancel, keeps the pre-shop damage instead of letting RLS clear it.
-- Only parts the shop shows in red get their dents back, and none that sit inside a replaced part:
-- an old bent shape on a new parent pulls the new part apart.
--
-- Flat tyres are kept per wheel by RLS's tyre system, apart from part condition. The mod labels
-- them, starts the preview's wheels fresh when a new tyre is in the cart, and marks them fresh at
-- checkout; the old tyre keeps its own state.
--
-- Everything is done by wrapping RLS functions at runtime; no RLS file is copied or replaced.
--
-- Copyright (C) 2026 Xetius. This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later version. It is
-- distributed WITHOUT ANY WARRANTY; see the LICENSE file for details.

local M = {}

local TAG = "xRlsVehicleDamagePatch"
local SNAPSHOT_DIR = "/temp/x_rls_vehicle_damage_patch/"
local RLS_SESSION_DIR = "/temp/rls_career/damageSession/"
local RLS_SESSION_SUFFIX = "_damageState.json"

-- Integrity below this (but above 0) is shown as "Damaged". Small wear values are left unmarked.
M.DAMAGED_BELOW = 0.9
-- Seconds after checkout before the old damage is loaded back, and before RLS re-captures it.
M.RESTORE_DELAY = 0.5
M.CAPTURE_DELAY = 1.5

local warned = {}
local function warnOnce(message)
  if warned[message] then return end
  warned[message] = true
  log("W", TAG, message)
end

-- One part shop visit: {inv, conditions, file, replaced, cancelled}
local session

-- Helpers --------------------------------------------------------------------------------------

-- "/a/b/partName" -> "/a/b/". Part conditions use part paths; slots and damage snapshots use slots.
function M.slotOfPartPath(partPath)
  if type(partPath) ~= "string" then return nil end
  return partPath:match("^(.*/)[^/]*$")
end

local function integrityOf(condition)
  if type(condition) ~= "table" then return 1 end
  return tonumber(condition.integrityValue) or 1
end

-- "broken", "damaged" or nil, with the integrity value.
function M.damageLevel(condition)
  local integrity = integrityOf(condition)
  if integrity <= 0 then return "broken", integrity end
  if integrity < M.DAMAGED_BELOW then return "damaged", integrity end
  return nil, integrity
end

-- Invisible characters that tell the UI script (ui/modModules/xRlsVehicleDamagePatch) how to show a
-- name. Without the script the text still reads "Hood 0% broken" / "Body 2 damaged inside".
M.MARK_PART = "\xE2\x81\xA3"   -- U+2063: damaged part; the percentage follows, shown small in red
M.MARK_INSIDE = "\xE2\x81\xA2" -- U+2062: damaged parts inside; shown in yellow
M.MARK_HIDE = "\xE2\x81\xA4"   -- U+2064: the rest is only there for the slot search, and is hidden

-- Share of each slot's beams that are broken or bent, from a damage snapshot: {[slot] = 0..1}.
-- BeamNG scores a body part as 1 or 0 (any real damage makes it 0), so this is what tells a
-- scraped fender from a crushed one.
function M.beamDamageBySlot(snapshot)
  local shares = {}
  for slot, state in pairs(snapshot and snapshot.partStates or {}) do
    local total, damaged = 0, 0
    for _, beam in pairs(state.beams or {}) do
      if type(beam) == "table" then
        total = total + 1
        if beam.broken or beam.deformed then damaged = damaged + 1 end
      end
    end
    if total > 0 then shares[slot] = damaged / total end
  end
  return shares
end

-- " <mark>23% damaged <hide>broken", or nil for a healthy part. The UI shows the text between the
-- marks in small red; a broken part with no beam data (wheel data, electrics) says "broken".
function M.damageTag(condition, beamShare)
  local level, integrity = M.damageLevel(condition)
  if not level then return nil end
  local amount
  if level == "broken" then
    if beamShare and beamShare > 0 then amount = beamShare end
  else
    amount = 1 - integrity
  end
  local shown = "broken"
  if amount then
    shown = string.format("%d%% damaged", math.min(100, math.max(1, math.floor(amount * 100 + 0.5))))
  end
  return string.format(" %s%s %s%s", M.MARK_PART, shown, M.MARK_HIDE, level)
end

-- A flat tyre is RLS tyre-system state on the wheel, not part damage, so it gets its own tag.
function M.flatTag(wheelNames)
  table.sort(wheelNames)
  return string.format(" %sflat (%s) %sbroken flat", M.MARK_PART, table.concat(wheelNames, ", "), M.MARK_HIDE)
end

-- {[tyre slot] = {"FL", ...}} for wheels RLS's tyre system has as flat.
function M.flatTyresBySlot(vehicle)
  local flats = {}
  local layout = vehicle and vehicle.rlsTireLayout
  for _, wheel in ipairs(type(layout) == "table" and layout.wheels or {}) do
    local slot = type(wheel) == "table" and wheel.flat == true and (wheel.containingSlot or M.slotOfPartPath(wheel.partPath))
    if slot then
      flats[slot] = flats[slot] or {}
      table.insert(flats[slot], tostring(wheel.name or "?"))
    end
  end
  return flats
end

function M.insideTag(count)
  return string.format(" %s%s%d damaged inside", M.MARK_INSIDE, M.MARK_HIDE, count)
end

local function inventory() return rawget(_G, "overhaul_career_garage_inventory") end

local function vehicleRecord(inventoryId)
  local inv = inventory()
  local vehicles = inv and inv.getVehicles and inv.getVehicles()
  return vehicles and vehicles[inventoryId]
end

local function vehicleObject(inventoryId)
  local inv = inventory()
  local vehId = inv and inv.getVehicleIdFromInventoryId and inv.getVehicleIdFromInventoryId(inventoryId)
  return vehId and be:getObjectByID(vehId) or nil
end

local function sameId(a, b) return a ~= nil and b ~= nil and tostring(a) == tostring(b) end

-- Tyres ----------------------------------------------------------------------------------------
-- RLS keeps each wheel's wear and flat on the tyre part (rlsTireState), and starts every spawned
-- car, the shop preview included, from the states of the parts fitted to it. A new tyre in the
-- cart isn't fitted yet, so the preview used to start from the old tyre's flat and pop.

local function partInventory()
  local parts = rawget(_G, "overhaul_career_parts_partInventory")
  local list = parts and type(parts.getInventory) == "function" and parts.getInventory()
  return type(list) == "table" and list or {}
end

-- The inventory part holding each wheel's tyre, with each wheel's state as the shop opened.
function M.captureTyres(inventoryId, vehicle, parts)
  local layout = vehicle and vehicle.rlsTireLayout
  if type(layout) ~= "table" or type(layout.wheels) ~= "table" then return nil end
  local byPart, any = {}, false
  for _, wheel in ipairs(layout.wheels) do
    if type(wheel) == "table" and wheel.name then
      local byPath, bySlot
      for id, part in pairs(parts) do
        if type(part) == "table" and sameId(part.location, inventoryId) then
          if wheel.partPath and part.partPath == wheel.partPath then byPath = id end
          if wheel.containingSlot and part.containingSlot == wheel.containingSlot then bySlot = id end
        end
      end
      local id = byPath or bySlot
      if id ~= nil then
        byPart[id] = byPart[id] or {}
        byPart[id][tostring(wheel.name)] = {remaining = tonumber(wheel.remaining) or 1, flat = wheel.flat == true}
        any = true
      end
    end
  end
  if not any then return nil end
  return {layout = deepcopy(layout), parts = byPart}
end

-- Writes the captured wheel states back onto the tyre parts; wheels named in fresh get a new
-- tyre's state (full tread, inflated) instead.
function M.setTyreStates(captured, parts, fresh)
  for id, wheels in pairs(captured and captured.parts or {}) do
    local part = parts[id]
    if type(part) == "table" then
      local state = part.rlsTireState
      if type(state) ~= "table" then state = type(part.tags) == "table" and part.tags.rlsTireState end
      if type(state) ~= "table" then state = {schemaVersion = 1} end
      state.wheels = type(state.wheels) == "table" and state.wheels or {}
      for name, saved in pairs(wheels) do
        local wheel = type(state.wheels[name]) == "table" and state.wheels[name] or {}
        if fresh and fresh[name] then
          wheel.remaining, wheel.flat = 1, false
        else
          wheel.remaining, wheel.flat = saved.remaining, saved.flat
        end
        state.wheels[name] = wheel
      end
      part.tags = type(part.tags) == "table" and part.tags or {}
      part.rlsTireState = state
      part.tags.rlsTireState = state
    end
  end
end

-- Slots the cart fills with a newly bought part (not one from the parts inventory).
function M.newCartSlots(cart)
  local slots = {}
  for slot, part in pairs(type(cart) == "table" and type(cart.partsIn) == "table" and cart.partsIn or {}) do
    if type(part) == "table" and part.partId == nil and not part.emptyPlaceholder then
      slots[part.containingSlot or slot] = true
    end
  end
  return slots
end

-- Session at shop start ------------------------------------------------------------------------

-- One file per shop visit, so a restore still running from the last checkout can't read the
-- snapshot of a visit opened straight after it.
local visitCount = 0
local function snapshotFile(inventoryId)
  visitCount = visitCount + 1
  return SNAPSHOT_DIR .. tostring(inventoryId) .. "_" .. visitCount .. "_snapshot.json"
end

-- Called by the car with its live part conditions. Only ever lowers integrity, so a reply that
-- arrives after the preview respawned (healthy) can't hide damage.
function M.onLiveConditions(inventoryId, serialized)
  if not session or not sameId(session.inv, inventoryId) or session.closed then return end
  local ok, live = pcall(deserialize, serialized)
  if not ok or type(live) ~= "table" then return end
  for partPath, condition in pairs(live) do
    if type(condition) == "table" and condition.integrityValue then
      local known = session.conditions[partPath]
      if not known then
        session.conditions[partPath] = deepcopy(condition)
      elseif integrityOf(condition) < integrityOf(known) then
        known.integrityValue = condition.integrityValue
        known.integrityState = deepcopy(condition.integrityState)
      end
    end
  end
  -- The car wrote its snapshot just before this reply, so the beam damage can be shown now.
  -- Only once RLS has published the shop: an earlier read would show it as unavailable.
  local partShopping = rawget(_G, "overhaul_career_parts_partShopping")
  if partShopping and partShopping.readShoppingDisplay and partShopping.readShoppingDisplay() ~= nil then
    guihooks.trigger("partShoppingData")
  end
end

-- Beam damage for the vehicle in this shop visit, read once the car has written its snapshot.
local function beamDamageFor(inventoryId)
  if not session or not sameId(session.inv, inventoryId) then return nil end
  if session.beamDamage then return session.beamDamage end
  if not FS:fileExists(session.file) then return nil end
  local snapshot = jsonReadFile(session.file)
  if not snapshot then return nil end
  session.beamDamage = M.beamDamageBySlot(snapshot)
  return session.beamDamage
end

local function beginSession(inventoryId)
  if inventoryId == nil then return end
  local record = vehicleRecord(inventoryId)
  session = {
    inv = inventoryId,
    conditions = deepcopy(record and record.partConditions or {}),
    file = snapshotFile(inventoryId),
  }
  local ok, tyres = pcall(M.captureTyres, inventoryId, record, partInventory())
  session.tyres = ok and tyres or nil

  local object = vehicleObject(inventoryId)
  if not object then return end
  FS:directoryCreate(SNAPSHOT_DIR, true)
  if FS:fileExists(session.file) then FS:removeFile(session.file) end
  -- Queued before RLS's own capture and before any preview respawn, so it sees the car as driven.
  object:queueLuaCommand(string.format(
    "extensions.load('overhaulDamageState'); if overhaulDamageState then overhaulDamageState.saveDamageData(%q) end", session.file))
  object:queueLuaCommand(string.format(
    "obj:queueGameEngineLua(string.format('xRlsVehicleDamagePatch.onLiveConditions(%%s, %%q)', %q, serialize(partCondition.getConditions())))",
    tostring(inventoryId)))
end

-- Runs fn with RLS's "needs repair" check answering no, so startShopping lets a damaged car in.
local function withRepairCheckLifted(inventoryId, fn, ...)
  beginSession(inventoryId)
  local calculator = rawget(_G, "overhaul_career_market_valueCalculator")
  local original = calculator and calculator.partConditionsNeedRepair
  if original then calculator.partConditionsNeedRepair = function() return false end end
  local results = {pcall(fn, ...)}
  if original then calculator.partConditionsNeedRepair = original end
  if not results[1] then
    log("E", TAG, "Part shop failed to open: " .. tostring(results[2]))
    return
  end
  return unpack(results, 2)
end

-- Garage computer ------------------------------------------------------------------------------

local function wrapShopCallback(entry, inventoryId)
  if not entry or entry.xDamagePatchWrapped or type(entry.callback) ~= "function" then return end
  local callback = entry.callback
  entry.callback = function(...) return withRepairCheckLifted(inventoryId, callback, ...) end
  entry.xDamagePatchWrapped = true
end

local function partBuyingAllowed(inventoryId)
  local permissions = rawget(_G, "overhaul_career_permissions")
  if not (permissions and permissions.getStatusForTag) then return true end
  local status = permissions.getStatusForTag({"partBuying", "vehicleModification"}, {inventoryId = inventoryId})
  return not status or status.allow ~= false
end

-- Un-greys Part Customization where "needs repair" was the only reason, and wraps its callback.
function M.unblockShopEntries(computerFunctions)
  local computer = rawget(_G, "overhaul_career_garage_computer")
  local needsRepairReason = computer and computer.reasons and computer.reasons.needsRepair
  for inventoryId, functions in pairs(computerFunctions and computerFunctions.vehicleSpecific or {}) do
    local entry = functions.partShop
    if entry then
      local blockedForRepair = entry.reason ~= nil and entry.reason == needsRepairReason
      if blockedForRepair and partBuyingAllowed(inventoryId) then
        entry.disabled = nil
        entry.reason = nil
      end
      wrapShopCallback(entry, inventoryId)
    end
  end
end

-- RLS's own hook, run with "needs repair" hidden from it.
local function wrapComputerHook(partShopping)
  local original = partShopping.onOverhaulComputerAddFunctions
  if type(original) ~= "function" then
    warnOnce("RLS part shop computer hook not found; the garage button stays blocked")
    return false
  end
  partShopping.onOverhaulComputerAddFunctions = function(menuData, computerFunctions)
    local view = menuData
    if type(menuData) == "table" and type(menuData.vehiclesInGarage) == "table" then
      view = setmetatable({vehiclesInGarage = {}}, {__index = menuData})
      for i, vehicleData in ipairs(menuData.vehiclesInGarage) do
        local copy = setmetatable({needsRepair = false}, {__index = vehicleData})
        view.vehiclesInGarage[i] = copy
      end
    end
    local result = original(view, computerFunctions)
    M.unblockShopEntries(computerFunctions)
    return result
  end
  return true
end

-- Labels in the part shop ----------------------------------------------------------------------

local function shopVehicleId(data)
  for _, part in pairs(data.vehicleSlotToPartMap or {}) do
    if type(part) == "table" and part.location and part.location ~= 0 then return part.location end
  end
end

local function conditionsFor(inventoryId)
  local record = vehicleRecord(inventoryId)
  local conditions = deepcopy(record and record.partConditions or {})
  if session and sameId(session.inv, inventoryId) then
    for partPath, condition in pairs(session.conditions) do
      if integrityOf(condition) < integrityOf(conditions[partPath]) then conditions[partPath] = condition end
    end
  end
  return conditions
end

-- Adds damage tags to slot names in a copy of the shop's UI data. The UI script colours them;
-- the hidden words still let a search for "broken" or "damaged" list those slots.
function M.decorateShopData(data, conditions, beamDamage, flats)
  beamDamage = beamDamage or {}
  flats = flats or {}
  local inCart = {}
  for slot in pairs(data.shoppingCart and data.shoppingCart.partsIn or {}) do inCart[slot] = true end

  local tags = {}
  local function walk(node)
    if type(node) ~= "table" then return 0 end
    local below = 0
    for _, child in pairs(node.children or {}) do below = below + walk(child) end

    local own = 0
    local path, partName = node.path, node.chosenPartName
    if type(path) == "string" and type(partName) == "string" and partName ~= "" and not inCart[path] then
      local tag = M.damageTag(conditions[path .. partName], beamDamage[path])
      if flats[path] then tag = M.flatTag(flats[path]) end
      if tag then
        own = 1
        tags[path] = true
        node.slotNiceName = (node.slotNiceName or node.slotName or partName) .. tag
      end
    end
    -- A damaged part stays red; only a healthy parent of damaged parts goes yellow.
    if own == 0 and below > 0 and type(path) == "string" then
      node.slotNiceName = (node.slotNiceName or node.slotName or "") .. M.insideTag(below)
      tags[path] = true
    end
    return own + below
  end
  local total = walk(data.partTree)

  if data.slotsNiceName then
    for path in pairs(tags) do
      local node = nil
      -- slotsNiceName mirrors node.slotNiceName; take the decorated text from the tree.
      local function find(n)
        if type(n) ~= "table" then return end
        if n.path == path then node = n return end
        for _, child in pairs(n.children or {}) do
          if node then return end
          find(child)
        end
      end
      find(data.partTree)
      if node then data.slotsNiceName[path] = node.slotNiceName end
    end
  end
  for _, entry in pairs(data.searchSlotList or {}) do
    if type(entry) == "table" and tags[entry.path] and data.slotsNiceName and data.slotsNiceName[entry.path] then
      entry.slotNiceName = data.slotsNiceName[entry.path]
    end
  end
  return data, total
end

local function wrapShopDisplay(partShopping)
  local original = partShopping.readShoppingDisplayForUI
  if type(original) ~= "function" then
    warnOnce("RLS part shop display not found; damaged parts won't be labelled")
    return
  end
  partShopping.readShoppingDisplayForUI = function(...)
    local data = original(...)
    if type(data) ~= "table" or type(data.partTree) ~= "table" then return data end
    local ok, decorated = pcall(function()
      local inventoryId = shopVehicleId(data)
      if not inventoryId then return data end
      -- The preview's wheels overwrite the live layout, so a session shows the flats it opened with.
      local tyres = session and sameId(session.inv, inventoryId) and session.tyres
      local flatSource = tyres and {rlsTireLayout = tyres.layout} or vehicleRecord(inventoryId)
      return (M.decorateShopData(deepcopy(data), conditionsFor(inventoryId), beamDamageFor(inventoryId),
        M.flatTyresBySlot(flatSource)))
    end)
    if not ok then
      warnOnce("Couldn't label damaged parts: " .. tostring(decorated))
      return data
    end
    return decorated
  end
end

local function wrapStartShopping(partShopping)
  local original = partShopping.startShopping
  if type(original) ~= "function" then return end
  partShopping.startShopping = function(inventoryId, ...)
    local inv = inventory()
    local target = inventoryId or (inv and inv.getCurrentVehicle and inv.getCurrentVehicle())
    return withRepairCheckLifted(target, original, inventoryId, ...)
  end
end

-- Runs after each preview respawn: wheels with a new tyre in the cart start fresh, the others
-- (including a tyre taken back out of the cart) get their state from when the shop opened.
local function freshenPreviewTyres()
  local current = session
  if not current or current.closed or not current.tyres then return end
  local partShopping = rawget(_G, "overhaul_career_parts_partShopping")
  local cart = partShopping and partShopping.getShoppingCart and partShopping.getShoppingCart()
  local names = M.wheelsInSlots({rlsTireLayout = current.tyres.layout}, M.newCartSlots(cart))
  table.sort(names)
  local key = table.concat(names, ",")
  if key == "" and (current.previewTyres or "") == "" then return end
  current.previewTyres = key
  current.tyresTouched = true
  local fresh = {}
  for _, name in ipairs(names) do fresh[name] = true end
  M.setTyreStates(current.tyres, partInventory(), fresh)
  local tires = rawget(_G, "overhaul_career_maintenance_tireSystem")
  if tires and tires.refreshLiveTires then pcall(tires.refreshLiveTires, tonumber(current.inv)) end
end

-- The preview's live wheels report back onto the old tyre part; put its own state back.
local function restoreTyreStates(current)
  if current and current.tyresTouched and current.tyres then
    M.setTyreStates(current.tyres, partInventory(), nil)
    current.tyresTouched = nil
  end
end

local function wrapPreviewUpdate(partShopping)
  local original = partShopping.updatePreviewVehicle
  if type(original) ~= "function" then
    warnOnce("RLS shop preview not found; a new tyre may show the old flat until checkout")
    return
  end
  partShopping.updatePreviewVehicle = function(...)
    local results = {original(...)}
    local ok, err = pcall(freshenPreviewTyres)
    if not ok then warnOnce("Couldn't refresh the preview's tyres: " .. tostring(err)) end
    return unpack(results)
  end
end

-- Checkout -------------------------------------------------------------------------------------

-- Old conditions back on unreplaced parts, and on parts going into the inventory.
-- Returns how many parts kept their damage.
function M.keepDamageOnUnreplacedParts(vehicle, initialConditions, cart)
  local replaced = {}
  for slot, part in pairs(cart and cart.partsIn or {}) do
    replaced[slot] = true
    if type(part) == "table" and part.containingSlot then replaced[part.containingSlot] = true end
  end
  for slot, part in pairs(cart and cart.partsOut or {}) do
    replaced[slot] = true
    if type(part) == "table" and part.containingSlot then replaced[part.containingSlot] = true end
  end

  local kept = 0
  local conditions = vehicle and vehicle.partConditions
  for partPath, initial in pairs(initialConditions or {}) do
    if integrityOf(initial) < 1 and not replaced[M.slotOfPartPath(partPath)] and conditions then
      local current = conditions[partPath]
      if current and integrityOf(current) > integrityOf(initial) then
        current.integrityValue = initial.integrityValue
        current.integrityState = deepcopy(initial.integrityState)
        kept = kept + 1
      end
    end
  end

  for _, part in pairs(cart and cart.partsOut or {}) do
    local initial = type(part) == "table" and initialConditions and initialConditions[part.partPath]
    if initial and integrityOf(initial) < integrityOf(part.partCondition) then
      part.partCondition = part.partCondition and deepcopy(part.partCondition) or {odometer = initial.odometer or 0, visualValue = initial.visualValue or 1}
      part.partCondition.integrityValue = initial.integrityValue
      part.partCondition.integrityState = deepcopy(initial.integrityState)
    end
  end
  return kept, replaced
end

-- Slots whose dents are put back after checkout: parts still marked broken or damaged (the red
-- ones in the shop) that weren't replaced. Only these. Reloading the old shape of a part that
-- RLS counts as fine, such as a body shell with a few bent beams, bends the new parts bolted to
-- it and breaks them again on the spot. So once every red part is replaced, nothing is reloaded
-- and the car comes back repaired.
-- True when the slot, or a slot it sits inside, got a new part.
function M.underReplaced(slot, replaced)
  for replacedSlot in pairs(replaced or {}) do
    if type(replacedSlot) == "string" and slot:sub(1, #replacedSlot) == replacedSlot then return true end
  end
  return false
end

-- A part inside a replaced one is bolted to a fresh, undented parent: putting its old bent shape
-- back pulls the new parent apart (a new body under dented doors and bed made the car explode).
-- Those parts keep their condition but not their dents.
function M.slotsToRestore(initialConditions, replaced)
  local slots = {}
  for partPath, initial in pairs(initialConditions or {}) do
    local slot = M.slotOfPartPath(partPath)
    if slot and M.damageLevel(initial) and not M.underReplaced(slot, replaced) then slots[slot] = true end
  end
  return slots
end

-- Of those slots, the ones the snapshot holds broken or bent beams for.
function M.snapshotDamagedSlots(snapshot, restoreSlots)
  local damaged = {}
  for slot, state in pairs(snapshot and snapshot.partStates or {}) do
    if restoreSlots[slot] then
      for _, beam in pairs(state.beams or {}) do
        if type(beam) == "table" and (beam.broken or beam.deformed) then
          damaged[slot] = true
          break
        end
      end
    end
  end
  return damaged
end

-- Every slot in the snapshot except the ones to restore: RLS's loader leaves these as spawned.
function M.slotsToSkip(snapshot, damaged)
  local skip = {}
  for slot in pairs(snapshot and snapshot.partStates or {}) do
    if not damaged[slot] then skip[slot] = true end
  end
  return skip
end

-- Tyres -----------------------------------------------------------------------------------------
-- RLS keeps a flat per wheel (FL, FR...) in its tyre system. After a purchase nothing re-inflates
-- the live wheel, so RLS's next read of the car stores "flat" onto the brand-new tyre, and only a
-- full insurance repair clears it. A newly bought tyre now gets RLS's own fresh-tyre treatment
-- (forceFreshWheels, as used by roadside repair) for the wheels it covers.

local pendingTyres

-- Wheel names whose tyre sits in one of the slots, from a vehicle's RLS tyre layout.
function M.wheelsInSlots(vehicle, slots)
  local names = {}
  local layout = vehicle and vehicle.rlsTireLayout
  for _, wheel in ipairs(type(layout) == "table" and layout.wheels or {}) do
    if type(wheel) == "table" and wheel.name then
      local slot = wheel.containingSlot or M.slotOfPartPath(wheel.partPath)
      if slot and slots[slot] then names[#names + 1] = tostring(wheel.name) end
    end
  end
  return names
end

local function freshenNewTyres(pending)
  local tires = rawget(_G, "overhaul_career_maintenance_tireSystem")
  if not tires then return end
  local vehicle = vehicleRecord(pending.inv)
  local fresh = M.wheelsInSlots(vehicle, pending.newSlots)
  if next(fresh) and tires.forceFreshWheels then
    pcall(tires.forceFreshWheels, pending.inv, fresh)
  elseif next(M.wheelsInSlots(vehicle, pending.usedSlots)) and tires.refreshLiveTires then
    -- A used tyre from the inventory keeps its own wear and flat; push that to the live wheel.
    pcall(tires.refreshLiveTires, tonumber(pending.inv))
  end
end

function M.onOverhaulPartShoppingPartsInstalled(inventoryId, installedParts)
  local newSlots, usedSlots = {}, {}
  for _, part in ipairs(type(installedParts) == "table" and installedParts or {}) do
    if type(part) == "table" and part.containingSlot then
      if part.fromInventory then usedSlots[part.containingSlot] = true else newSlots[part.containingSlot] = true end
    end
  end
  pendingTyres = {inv = inventoryId, newSlots = newSlots, usedSlots = usedSlots}

  if not session or not sameId(session.inv, inventoryId) then return end
  pcall(restoreTyreStates, session)
  local partShopping = rawget(_G, "overhaul_career_parts_partShopping")
  local cart = partShopping and partShopping.getShoppingCart and partShopping.getShoppingCart()
  local ok, kept, replaced = pcall(M.keepDamageOnUnreplacedParts, vehicleRecord(inventoryId), session.conditions, cart)
  if not ok then
    log("E", TAG, "Couldn't keep part conditions: " .. tostring(kept))
    return
  end
  session.replaced = replaced
  session.kept = kept
  log("I", TAG, string.format("Checkout on vehicle %s: %d unreplaced damaged parts kept their condition", tostring(inventoryId), kept))
end

local function reapplyConditions(inventoryId, initialConditions, replaced)
  local vehicle = vehicleRecord(inventoryId)
  M.keepDamageOnUnreplacedParts(vehicle, initialConditions, {partsIn = replaced})
end

local function restorePhysicalDamage(current)
  local inventoryId, replaced = current.inv, current.replaced
  -- With every damaged part replaced (or none to begin with) RLS's normal checkout is right: the
  -- car comes back without damage.
  local restoreSlots = M.slotsToRestore(current.conditions, replaced)
  if not next(restoreSlots) then
    if FS:fileExists(current.file) then FS:removeFile(current.file) end
    return
  end
  core_jobsystem.create(function(job)
    job.sleep(M.RESTORE_DELAY)
    local snapshot = FS:fileExists(current.file) and jsonReadFile(current.file)
    local damaged = M.snapshotDamagedSlots(snapshot, restoreSlots)
    local object = vehicleObject(inventoryId)
    if object and next(damaged) then
      local skip = M.slotsToSkip(snapshot, damaged)
      object:queueLuaCommand(string.format(
        "extensions.load('overhaulDamageState'); overhaulDamageState.loadDamageData(%q, %s, nil)",
        current.file, serialize(skip)))
      local count = 0
      for _ in pairs(damaged) do count = count + 1 end
      log("I", TAG, string.format("Reloaded damage on %d unreplaced parts of vehicle %s", count, tostring(inventoryId)))
      job.sleep(M.CAPTURE_DELAY)
      local damageManager = rawget(_G, "overhaul_career_repair_damageManager")
      if damageManager and damageManager.saveDamageState then pcall(damageManager.saveDamageState, inventoryId) end
    elseif not snapshot and (current.kept or 0) > 0 then
      warnOnce("No damage snapshot was taken; part conditions were kept but the car's dents were not")
    end
    -- With autosave off RLS re-reads conditions from the car, which can land after checkout.
    job.sleep(M.CAPTURE_DELAY)
    reapplyConditions(inventoryId, current.conditions, replaced)
    if FS:fileExists(current.file) then FS:removeFile(current.file) end
  end)
end

function M.onOverhaulPartShoppingTransactionComplete()
  local tyres = pendingTyres
  pendingTyres = nil
  if tyres then
    freshenNewTyres(tyres)
    -- Again once the car has settled: a read of the live car queued before the re-inflate would
    -- otherwise store the old flat back onto the new tyre.
    core_jobsystem.create(function(job)
      job.sleep(M.CAPTURE_DELAY)
      freshenNewTyres(tyres)
      job.sleep(M.CAPTURE_DELAY * 2)
      freshenNewTyres(tyres)
    end)
  end

  local current = session
  session = nil
  if not current or not current.replaced then return end
  current.closed = true
  restorePhysicalDamage(current)
end

-- Cancel ---------------------------------------------------------------------------------------

function M.onOverhaulPartShoppingCancelled()
  if session then
    session.cancelled = true
    session.closed = true
    pcall(restoreTyreStates, session)
  end
end

-- RLS clears the saved damage when a changed cart is cancelled, so the car came back healthy.
-- For a car this mod let in, the pre-shop snapshot is kept instead.
local function wrapClearDamage(damageManager)
  local original = damageManager.clearDamageState
  if type(original) ~= "function" then
    warnOnce("RLS damage manager not found; Cancel may still heal the car")
    return
  end
  damageManager.clearDamageState = function(inventoryId, ...)
    local current = session
    if current and current.cancelled and sameId(current.inv, inventoryId) and FS:fileExists(current.file) then
      session = nil
      local content = readFile(current.file)
      if content then
        FS:directoryCreate(RLS_SESSION_DIR, true)
        writeFile(RLS_SESSION_DIR .. tostring(inventoryId) .. RLS_SESSION_SUFFIX, content)
      end
      log("I", TAG, "Kept pre-shop damage on cancelled vehicle " .. tostring(inventoryId))
      return
    end
    return original(inventoryId, ...)
  end
end

-- Installing -----------------------------------------------------------------------------------

local function install()
  local partShopping = rawget(_G, "overhaul_career_parts_partShopping")
  if partShopping and not rawget(partShopping, "xDamagePatchHooked") then
    partShopping.xDamagePatchHooked = true
    local hooked = wrapComputerHook(partShopping)
    wrapStartShopping(partShopping)
    wrapShopDisplay(partShopping)
    wrapPreviewUpdate(partShopping)
    -- BeamNG caches hook functions; drop the cached copy of the unwrapped one.
    if hooked and extensions.hookUpdate then extensions.hookUpdate("onOverhaulComputerAddFunctions") end
    log("I", TAG, "Part shop hooks active")
  end

  local damageManager = rawget(_G, "overhaul_career_repair_damageManager")
  if damageManager and not rawget(damageManager, "xDamagePatchHooked") then
    damageManager.xDamagePatchHooked = true
    wrapClearDamage(damageManager)
    log("I", TAG, "Damage manager hook active")
  end
end

-- Runs in the same pass as RLS's hook, in either order; covers a pass where RLS's ran unwrapped.
function M.onOverhaulComputerAddFunctions(menuData, computerFunctions)
  M.unblockShopEntries(computerFunctions)
  install()
end

M.onExtensionLoaded = install
M.onOverhaulActive = install
M.onOverhaulComputerMenuOpened = install
M.onOverhaulPartShoppingStarted = install

-- For the test script.
M._getSession = function() return session end
M._beginSession = beginSession
M._install = install
M._freshenPreviewTyres = function() return freshenPreviewTyres() end

return M
