-- The same as xRlsVehicleDamagePatch, for cars in the business computer: the race team's fleet
-- and the tuning shop's customer cars.
--
-- RLS blocks business Part Customization while a car has any broken part
-- (lib/business/customizationAccess). The tuning shop also locks a customer car once its live
-- damage passes the shop's limit: Parts, Tuning, Put Away and Complete all stop, and the only way
-- on is to abandon the job. This lets the car into Parts and Tuning instead; Put Away and Complete
-- stay locked until the damage is back under the limit.
--
-- Business previews respawn the car from its saved config, which drops every dent, both while
-- browsing and when leaving without buying. So, as in the garage shop, the mod:
--   1. when Parts opens on a damaged car, snapshots its dents and live part conditions, and marks
--      the broken parts broken in the paid record (they were only on the live car),
--   2. labels damaged parts in the parts list,
--   3. records which slots each purchase replaced,
--   4. once the parts session ends and the car has been respawned, reloads the dents of the
--      damaged parts that weren't replaced (and of nothing inside a replaced part).
-- Personal cars driven into a business are left to RLS, which keeps refusing them while broken.
--
-- Everything is done by wrapping RLS functions at runtime; no RLS file is copied or replaced.
-- If any of the RLS internals this needs can't be found, the business blocks are left in place.
--
-- Copyright (C) 2026 Xetius. This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later version. It is
-- distributed WITHOUT ANY WARRANTY; see the LICENSE file for details.

local M = {}

local TAG = "xRlsVehicleDamagePatchBusiness"
local SNAPSHOT_DIR = "/temp/x_rls_vehicle_damage_patch/"
local ACCESS_MODULE = "overhaul/lib/business/customizationAccess"
local PARTS_TREE_EVENT = "businessComputer:onVehiclePartsTree"
M.POLL_INTERVAL = 0.25

-- Parts sessions on damaged business cars, by "businessId|vehicleId".
local records = {}
local visitCount = 0
local internals = {}
local installed = {}

local function core() return rawget(_G, "xRlsVehicleDamagePatch") end
local function sameId(a, b) return a ~= nil and b ~= nil and tostring(a) == tostring(b) end
local function keyFor(businessId, vehicleId) return tostring(businessId) .. "|" .. tostring(vehicleId) end
function M.isPersonalId(vehicleId) return tostring(vehicleId):sub(1, 9) == "personal_" end

local warned = {}
local function warnOnce(message)
  if warned[message] then return end
  warned[message] = true
  log("W", TAG, message)
end

-- RLS internals ------------------------------------------------------------------------------------

-- A local table captured by one of RLS's exported functions.
function M.findUpvalue(fns, name, accept)
  if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then return nil end
  for _, fn in pairs(fns or {}) do
    if type(fn) == "function" then
      for index = 1, 255 do
        local upName, value = debug.getupvalue(fn, index)
        if upName == nil then break end
        if upName == name and type(value) == "table" and (not accept or accept(value)) then return value end
      end
    end
  end
  return nil
end

-- partCustomization's shared state: runtime.currentSession is the open parts session.
local function partRuntime()
  if internals.runtime then return internals.runtime end
  local owner = rawget(_G, "overhaul_career_business_partCustomization")
  if type(owner) ~= "table" then return nil end
  internals.runtime = M.findUpvalue(owner, "runtime", function(t) return rawget(t, "pendingPowerRequests") ~= nil end)
  return internals.runtime
end

-- The business computer's vehicle helpers (damage locks), which its other parts call by field.
local function vehiclesApi()
  if internals.vehicles then return internals.vehicles end
  local computer = rawget(_G, "overhaul_career_business_computer")
  if type(computer) ~= "table" then return nil end
  internals.vehicles = M.findUpvalue(computer, "api", function(t)
    return type(rawget(t, "shouldPreventVehicleOperation")) == "function" and type(rawget(t, "isDamageLocked")) == "function"
  end)
  return internals.vehicles
end

local function currentSession()
  local runtime = partRuntime()
  return runtime and runtime.currentSession or nil
end

local function sessionFor(record)
  local session = currentSession()
  if session and sameId(session.businessId, record.businessId) and sameId(session.vehicleId, record.vehicleId) then
    return session
  end
  return nil
end

local function fleet() return rawget(_G, "overhaul_career_business_fleet") end

local function vehicleIdFor(businessId, vehicleId)
  local f = fleet()
  return f and f.getSpawnedVehicleId and f.getSpawnedVehicleId(businessId, vehicleId) or nil
end

local function fleetRecord(businessId, vehicleId)
  local f = fleet()
  return f and f.getVehicleById and f.getVehicleById(businessId, vehicleId) or nil
end

-- Conditions ---------------------------------------------------------------------------------------

-- Lowers integrity in `target` to the damaged values in `damaged`; returns whether anything changed.
function M.lowerConditions(target, damaged)
  if type(target) ~= "table" then return false end
  local changed = false
  for partPath, condition in pairs(damaged or {}) do
    local known = target[partPath]
    local integrity = tonumber(condition.integrityValue) or 1
    if type(known) == "table" and integrity < (tonumber(known.integrityValue) or 1) then
      known.integrityValue = condition.integrityValue
      known.integrityState = deepcopy(condition.integrityState)
      changed = true
    end
  end
  return changed
end

-- Only the damaged parts of a condition table.
function M.damagedOnly(conditions)
  local out = {}
  local lib = core()
  for partPath, condition in pairs(conditions or {}) do
    if type(condition) == "table" and lib and lib.damageLevel(condition) then out[partPath] = deepcopy(condition) end
  end
  return out
end

-- Writes the damage onto the paid fleet record, so the session, checkout and repair quote see it.
local function markRecordDamaged(record)
  local damaged = M.damagedOnly(record.conditions)
  local lib = core()
  for partPath in pairs(damaged) do
    if lib.underReplaced(lib.slotOfPartPath(partPath) or "", record.replaced) then damaged[partPath] = nil end
  end
  if not next(damaged) then return end
  local stored = fleetRecord(record.businessId, record.vehicleId)
  if stored and type(stored.partConditions) == "table" then
    local merged = deepcopy(stored.partConditions)
    for partPath, condition in pairs(damaged) do
      if not merged[partPath] then merged[partPath] = deepcopy(condition) end
    end
    M.lowerConditions(merged, damaged)
    local f = fleet()
    if f and f.updateVehicle then
      f.updateVehicle(record.businessId, record.vehicleId, {partConditions = merged})
    else
      stored.partConditions = merged
    end
  end
  local session = sessionFor(record)
  if session then
    M.lowerConditions(session.initial and session.initial.partConditions, damaged)
    M.lowerConditions(session.preview and session.preview.partConditions, damaged)
  end
end

-- Parts sessions -----------------------------------------------------------------------------------

local function beginRecord(businessId, vehicleId)
  if businessId == nil or vehicleId == nil or M.isPersonalId(vehicleId) then return nil end
  local key = keyFor(businessId, vehicleId)
  -- A purchase closes and reopens the session at once: keep the damage from the first opening.
  if records[key] then return records[key] end
  local vehId = vehicleIdFor(businessId, vehicleId)
  local object = vehId and getObjectByID(vehId)
  if not object then return nil end
  local stored = fleetRecord(businessId, vehicleId)
  local liveDamage = map and map.objects and map.objects[vehId] and map.objects[vehId].damage or 0
  local storedDamaged = next(M.damagedOnly(stored and stored.partConditions))
  if (tonumber(liveDamage) or 0) < 1 and not storedDamaged then return nil end

  visitCount = visitCount + 1
  local record = {
    key = key, businessId = businessId, vehicleId = vehicleId, vehId = vehId,
    conditions = deepcopy(stored and stored.partConditions or {}),
    file = SNAPSHOT_DIR .. "business_" .. visitCount .. "_snapshot.json",
    replaced = {},
  }
  records[key] = record
  FS:directoryCreate(SNAPSHOT_DIR, true)
  if FS:fileExists(record.file) then FS:removeFile(record.file) end
  object:queueLuaCommand(string.format(
    "extensions.load('overhaulDamageState'); if overhaulDamageState then overhaulDamageState.saveDamageData(%q) end", record.file))
  object:queueLuaCommand(string.format(
    "obj:queueGameEngineLua(string.format('xRlsVehicleDamagePatchBusiness.onLiveConditions(%%q, %%q)', %q, serialize(partCondition.getConditions())))",
    key))
  return record
end

-- The car's live conditions, sent back by beginRecord. The snapshot was written just before.
function M.onLiveConditions(key, serialized)
  local record = records[key]
  if not record then return end
  local ok, live = pcall(deserialize, serialized)
  if ok and type(live) == "table" then
    for partPath, condition in pairs(live) do
      if type(condition) == "table" and condition.integrityValue then
        if not record.conditions[partPath] then record.conditions[partPath] = deepcopy(condition) end
      end
    end
    M.lowerConditions(record.conditions, live)
  end
  local lib = core()
  local snapshot = FS:fileExists(record.file) and jsonReadFile(record.file) or nil
  record.beamDamage = lib and snapshot and lib.beamDamageBySlot(snapshot) or {}
  record.ready = true
  markRecordDamaged(record)
  -- The parts list may already be on screen without labels; ask for it again.
  if record.treeShown then
    local computer = rawget(_G, "overhaul_career_business_computer")
    if computer and computer.requestVehiclePartsTree then
      pcall(computer.requestVehiclePartsTree, record.businessId, record.vehicleId)
    end
  end
end

-- Slots a purchase replaces: parts that differ from the paid build, plus same-part replacements.
function M.replacedSlots(session)
  local slots = {}
  local before = session and session.initial and session.initial.partList or {}
  local after = session and session.preview and session.preview.partList or {}
  for slot, name in pairs(before) do
    if after[slot] ~= name then slots[slot] = true end
  end
  for slot, name in pairs(after) do
    if before[slot] ~= name then slots[slot] = true end
  end
  for _, part in ipairs(session and session.replacementParts or {}) do
    if type(part) == "table" and part.slotPath then slots[part.slotPath] = true end
  end
  return slots
end

local function restoreRecord(record)
  local lib = core()
  if not lib then return end
  local restoreSlots = lib.slotsToRestore(record.conditions, record.replaced)
  if not next(restoreSlots) then
    if FS:fileExists(record.file) then FS:removeFile(record.file) end
    return
  end
  core_jobsystem.create(function(job)
    job.sleep(lib.RESTORE_DELAY)
    local snapshot = FS:fileExists(record.file) and jsonReadFile(record.file)
    local damaged = lib.snapshotDamagedSlots(snapshot, restoreSlots)
    local vehId = vehicleIdFor(record.businessId, record.vehicleId)
    local object = vehId and getObjectByID(vehId)
    if object and next(damaged) then
      object:queueLuaCommand(string.format(
        "extensions.load('overhaulDamageState'); overhaulDamageState.loadDamageData(%q, %s, nil)",
        record.file, serialize(lib.slotsToSkip(snapshot, damaged))))
      log("I", TAG, string.format("Reloaded damage on business vehicle %s", tostring(record.vehicleId)))
    end
    -- Unreplaced parts stay broken in the paid record too.
    local kept = {}
    for partPath, condition in pairs(M.damagedOnly(record.conditions)) do
      if restoreSlots[lib.slotOfPartPath(partPath) or ""] then kept[partPath] = condition end
    end
    job.sleep(lib.CAPTURE_DELAY)
    local stored = fleetRecord(record.businessId, record.vehicleId)
    if stored and type(stored.partConditions) == "table" then
      local merged = deepcopy(stored.partConditions)
      if M.lowerConditions(merged, kept) then
        local f = fleet()
        if f and f.updateVehicle then f.updateVehicle(record.businessId, record.vehicleId, {partConditions = merged})
        else stored.partConditions = merged end
      end
    end
    if FS:fileExists(record.file) then FS:removeFile(record.file) end
  end)
end

-- Ends records whose parts session is over. The dents only go back if the car was respawned
-- meanwhile (a session with no changes leaves the dented car as it was).
function M.pollRecords()
  for key, record in pairs(records) do
    if not sessionFor(record) then
      records[key] = nil
      local vehId = vehicleIdFor(record.businessId, record.vehicleId)
      if vehId ~= record.vehId then record.respawned = true end
      if record.ready and record.respawned then
        restoreRecord(record)
      elseif FS:fileExists(record.file) then
        FS:removeFile(record.file)
      end
    end
  end
end

local pollTimer, installTimer = 0, 0
local install
function M.onUpdate(dtReal)
  -- RLS loads its business modules with the career; keep trying until they're there.
  if not installed.done then
    installTimer = installTimer + (tonumber(dtReal) or 0)
    if installTimer >= 2 then installTimer = 0 install() end
  end
  if not next(records) then return end
  pollTimer = pollTimer + (tonumber(dtReal) or 0)
  if pollTimer < M.POLL_INTERVAL then return end
  pollTimer = 0
  M.pollRecords()
end

function M.onVehicleSpawned(vehId)
  for _, record in pairs(records) do
    if sameId(record.vehId, vehId) then record.respawned = true end
  end
end

-- Labels -------------------------------------------------------------------------------------------

-- Slots not to label: replaced by a purchase in this visit, changed in the preview, or inside one.
local function labelSkips(record, tree)
  local skip = {}
  local replaced = deepcopy(record.replaced)
  local session = sessionFor(record)
  if session then for slot in pairs(M.replacedSlots(session)) do replaced[slot] = true end end
  local lib = core()
  local function walk(node)
    if type(node) ~= "table" then return end
    if type(node.path) == "string" and lib.underReplaced(node.path, replaced) then skip[node.path] = true end
    for _, child in pairs(node.children or {}) do walk(child) end
  end
  walk(tree)
  return skip
end

-- A parts-tree payload with damaged slots labelled like the garage shop's.
function M.decoratePartsTree(payload, record)
  local lib = core()
  if not lib or type(payload) ~= "table" or type(payload.partTreeHierarchy) ~= "table" then return payload end
  local data = {
    partTree = deepcopy(payload.partTreeHierarchy),
    slotsNiceName = {},
    searchSlotList = {},
    shoppingCart = {partsIn = labelSkips(record, payload.partTreeHierarchy)},
  }
  local decorated, total = lib.decorateShopData(data, record.conditions, record.beamDamage)
  if total == 0 then return payload end
  local out = {}
  for k, v in pairs(payload) do out[k] = v end
  out.partTreeHierarchy = decorated.partTree
  if type(payload.partsTree) == "table" then
    out.partsTree = {}
    for i, entry in ipairs(payload.partsTree) do
      local name = type(entry) == "table" and decorated.slotsNiceName[entry.path]
      if name then
        local copy = {}
        for k, v in pairs(entry) do copy[k] = v end
        copy.slotNiceName = name
        out.partsTree[i] = copy
      else
        out.partsTree[i] = entry
      end
    end
  end
  return out
end

-- Tuning shop lock ---------------------------------------------------------------------------------

local function unlockRow(row)
  if type(row) ~= "table" or row.damageLocked ~= true then return row end
  local copy = {}
  for k, v in pairs(row) do copy[k] = v end
  copy.damageLocked = false
  copy.xDamageLocked = true
  return copy
end

local function unlockList(list)
  if type(list) ~= "table" then return list end
  local out, changed = {}, false
  for i, row in ipairs(list) do
    out[i] = unlockRow(row)
    if out[i] ~= row then changed = true end
  end
  return changed and out or list
end

-- The UI greys out Parts and Tuning, and offers only Abandon, while a car is damage locked. The
-- copy it gets says unlocked; RLS still refuses Put Away, Pull Out and (through this mod) Complete.
function M.unlockPayload(payload, depth)
  depth = depth or 0
  if type(payload) ~= "table" or depth > 2 then return payload end
  local out
  local function set(k, v)
    if payload[k] == v then return end
    if not out then out = {} for key, value in pairs(payload) do out[key] = value end end
    out[k] = v
  end
  if payload.vehicleDamageLocked == true then set("vehicleDamageLocked", false) end
  for _, name in ipairs({"pulledOutVehicles", "vehicles", "formattedPulledOutVehicles"}) do
    set(name, unlockList(payload[name]))
  end
  set("pulledOutVehicle", unlockRow(payload.pulledOutVehicle))
  for _, name in ipairs({"data", "businessData", "vehiclesData"}) do
    if type(payload[name]) == "table" then set(name, M.unlockPayload(payload[name], depth + 1)) end
  end
  return out or payload
end

-- Installing ---------------------------------------------------------------------------------------

local function wrapAccess(access)
  local original = access.getRepairReason
  if type(original) ~= "function" then return false end
  access.getRepairReason = function(businessId, vehicleId, ...)
    local reason = original(businessId, vehicleId, ...)
    local computer = rawget(_G, "overhaul_career_garage_computer")
    local needsRepair = computer and computer.reasons and computer.reasons.needsRepair
    -- Only while a parts session holds this car's damage; kits and personal cars keep the block.
    if reason and (reason == needsRepair or (needsRepair and reason.label == needsRepair.label))
      and records[keyFor(businessId, vehicleId)] then
      return nil
    end
    return reason
  end
  return true
end

local function wrapPartCustomization(owner)
  local initialize = owner.initializePreviewVehicle
  local commit = owner.commitSessionInitialFromPreview
  if type(initialize) ~= "function" or type(commit) ~= "function" then return false end
  owner.initializePreviewVehicle = function(businessId, vehicleId, ...)
    local existed = records[keyFor(businessId, vehicleId)]
    local record = beginRecord(businessId, vehicleId)
    local ok = initialize(businessId, vehicleId, ...)
    if not ok and record and not existed then
      records[record.key] = nil
      if FS:fileExists(record.file) then FS:removeFile(record.file) end
    end
    return ok
  end
  owner.commitSessionInitialFromPreview = function(businessId, vehicleId, ...)
    local session = currentSession()
    local record = records[keyFor(businessId, vehicleId or (session and session.vehicleId))]
    if record and session then
      for slot in pairs(M.replacedSlots(session)) do record.replaced[slot] = true end
    end
    return commit(businessId, vehicleId, ...)
  end
  return true
end

local function wrapComputer(computer, vehicles)
  local original = vehicles.shouldPreventVehicleOperation
  vehicles.shouldPreventVehicleOperation = function(businessId, vehicleId, ...)
    -- Its only reason is the damage lock; Parts and Tuning are how the damage gets fixed.
    if businessId and vehicleId and not M.isPersonalId(vehicleId) then return false end
    return original(businessId, vehicleId, ...)
  end
  local notify = vehicles.notifyDamageLocked
  vehicles.notifyDamageLocked = function(lockInfo, ...)
    if type(lockInfo) ~= "table" or not lockInfo.locked then return notify(lockInfo, ...) end
    ui_message(string.format(
      "Vehicle damage (%.0f) is over the %d limit. Replace the broken parts in Parts, or abandon the job.",
      lockInfo.damage or 0, lockInfo.threshold or 1500), 6, "Business Computer", "error")
  end
  for _, name in ipairs({"getBusinessComputerUIData", "getVehiclesOnly"}) do
    local fn = computer[name]
    if type(fn) == "function" then
      computer[name] = function(...) return M.unlockPayload(fn(...)) end
    end
  end
  local complete = computer.completeJob
  if type(complete) == "function" then
    computer.completeJob = function(businessId, jobId, ...)
      if not vehicles.isRacingTeamBusinessId(businessId) then
        local lockInfo = vehicles.getDamageLockedVehicleInfo(businessId)
        if lockInfo then
          vehicles.notifyDamageLocked(lockInfo)
          return false
        end
      end
      return complete(businessId, jobId, ...)
    end
  end
end

local function wrapGuiHooks()
  if type(guihooks) ~= "table" or rawget(guihooks, "xDamagePatchBusinessHooked") then return end
  local trigger = guihooks.trigger
  if type(trigger) ~= "function" then return end
  guihooks.xDamagePatchBusinessHooked = true
  guihooks.trigger = function(name, payload, ...)
    if type(name) == "string" and type(payload) == "table" and name:sub(1, 17) == "businessComputer:" then
      local ok, changed = pcall(function()
        local out = M.unlockPayload(payload)
        if name == PARTS_TREE_EVENT and out.success then
          local record = records[keyFor(out.businessId, out.vehicleId)]
          if record then
            record.treeShown = true
            if record.ready then out = M.decoratePartsTree(out, record) end
          end
        end
        return out
      end)
      if ok then payload = changed else warnOnce("Couldn't adjust business UI data: " .. tostring(changed)) end
    end
    return trigger(name, payload, ...)
  end
end

function install()
  if not core() then return end
  local owner = rawget(_G, "overhaul_career_business_partCustomization")
  local computer = rawget(_G, "overhaul_career_business_computer")
  if type(owner) ~= "table" or type(computer) ~= "table" then return end
  if installed.done and rawget(owner, "xDamagePatchHooked") and rawget(computer, "xDamagePatchHooked") then return end
  -- A reloaded RLS module is a new table with new internals.
  internals.runtime, internals.vehicles = nil, nil
  local runtime, vehicles = partRuntime(), vehiclesApi()
  local ok, access = pcall(require, ACCESS_MODULE)
  if not runtime or not vehicles or not ok or type(access) ~= "table" then
    warnOnce("RLS business internals not found; business cars keep RLS's repair block")
    return
  end
  -- Order matters: the protections go in before the block is lifted.
  if not rawget(owner, "xDamagePatchHooked") then
    if not wrapPartCustomization(owner) then
      warnOnce("RLS business part session not found; business cars keep RLS's repair block")
      return
    end
    owner.xDamagePatchHooked = true
  end
  wrapGuiHooks()
  if not rawget(computer, "xDamagePatchHooked") then
    computer.xDamagePatchHooked = true
    wrapComputer(computer, vehicles)
  end
  if not rawget(access, "xDamagePatchHooked") then
    access.xDamagePatchHooked = wrapAccess(access)
  end
  installed.done = true
  log("I", TAG, "Business hooks active")
end

M.onExtensionLoaded = install
M.onOverhaulActive = install
M.onOverhaulComputerMenuOpened = install
M.onOverhaulComputerAddFunctions = function() install() end
M.onClientStartMission = install

-- For the test script.
M._records = function() return records end
M._install = install
M._reset = function() records, internals, installed, warned = {}, {}, {}, {} end
M._beginRecord = beginRecord

return M
