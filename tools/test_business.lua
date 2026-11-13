-- Tests the business side (race team, tuning shop) against RLS's real customizationAccess.lua,
-- with stand-ins for the business computer, fleet and part session.
-- Usage: luajit tools/test_business.lua <folder holding RLS's lua/ tree>

local rlsRoot = assert(arg[1], "pass the folder holding RLS's lua/ tree")
local here = (arg[0]:match("^(.*)[/\\]tools[/\\]") or ".")

local failures, checks = 0, 0
local function check(name, actual, expected)
  checks = checks + 1
  if actual == expected then
    print("ok    " .. name)
  else
    failures = failures + 1
    print("FAIL  " .. name .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected))
  end
end

-- BeamNG globals ---------------------------------------------------------------------------------
function deepcopy(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for k, v in pairs(value) do copy[deepcopy(k)] = deepcopy(v) end
  return copy
end
function serialize(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local parts = {}
  for k, x in pairs(v) do parts[#parts + 1] = "[" .. serialize(k) .. "]=" .. serialize(x) end
  return "{" .. table.concat(parts, ",") .. "}"
end
function deserialize(s) return assert(loadstring("return " .. s))() end
local logged = {}
function log(level, tag, message) logged[#logged + 1] = level .. " " .. tostring(message) end
local messages = {}
function ui_message(msg) messages[#messages + 1] = msg end
local files = {}
FS = {
  directoryCreate = function() end,
  fileExists = function(_, p) return files[p] ~= nil end,
  removeFile = function(_, p) files[p] = nil end,
}
function jsonReadFile(p) return files[p] and deserialize(files[p]) end
extensions = {hookUpdate = function() end}
local jobs = {}
core_jobsystem = {create = function(fn) jobs[#jobs + 1] = fn end}
local function runJobs()
  local pending = jobs
  jobs = {}
  for _, fn in ipairs(pending) do fn({sleep = function() end}) end
end
local toasts = {}
local shown = {}
guihooks = {trigger = function(name, payload)
  if name == "toastrMsg" then toasts[#toasts + 1] = payload.msg end
  shown[name] = payload
end}

-- A race team car (business 3, vehicle 5, spawned as 2001) with a broken hood and a bent door.
local B, V, VEH = 3, 5, 2001
local HOOD, DOOR, BODY = "/body/hood/", "/body/door_L/", "/"
local fleetVehicle = {
  vehicleId = V,
  partList = {[BODY] = "body", [HOOD] = "hood_a", [DOOR] = "door_a"},
  partConditions = {
    ["/body"] = {integrityValue = 1},
    [HOOD .. "hood_a"] = {integrityValue = 0},
    [DOOR .. "door_a"] = {integrityValue = 1},
  },
}
overhaul_career_business_fleet = {
  getSpawnedVehicleId = function(b, v) return tostring(v) == tostring(V) and VEH or nil end,
  getVehicleById = function(b, v) return tostring(v) == tostring(V) and fleetVehicle or nil end,
  updateVehicle = function(b, v, data) for k, x in pairs(data) do fleetVehicle[k] = x end end,
}
local queued = {}
local carObject = {queueLuaCommand = function(_, cmd) queued[#queued + 1] = cmd end}
function getObjectByID(id) return id == VEH and carObject or nil end
map = {objects = {[VEH] = {damage = 4000}}}

overhaul_career_garage_computer = {reasons = {needsRepair = {type = "needsRepair", label = "Needs repair"}}}
overhaul_career_market_valueCalculator = {getNumberOfBrokenParts = function(conditions)
  local n = 0
  for _, c in pairs(conditions or {}) do if (c.integrityValue or 1) <= 0 then n = n + 1 end end
  return n
end}

-- RLS's real customizationAccess.lua.
local ACCESS = "overhaul/lib/business/customizationAccess"
local access = assert(loadfile(rlsRoot .. "/lua/ge/extensions/" .. ACCESS .. ".lua"))()
package.loaded[ACCESS] = access

-- Stand-in for partCustomization: its session lives in a local called runtime, like RLS's.
local runtime = {currentSession = nil, pendingPowerRequests = {}}
local owner = {}
owner.initializePreviewVehicle = function(businessId, vehicleId)
  if not access.allow(businessId, vehicleId) then return false end
  if runtime.currentSession then return true end
  runtime.currentSession = {
    businessId = businessId, vehicleId = vehicleId, replacementParts = {},
    initial = {partList = deepcopy(fleetVehicle.partList), partConditions = deepcopy(fleetVehicle.partConditions)},
    preview = {partList = deepcopy(fleetVehicle.partList), partConditions = deepcopy(fleetVehicle.partConditions)},
  }
  return true
end
owner.commitSessionInitialFromPreview = function()
  local session = runtime.currentSession
  session.initial.partList = deepcopy(session.preview.partList)
  session.initial.partConditions = deepcopy(session.preview.partConditions)
  session.replacementParts = {}
  fleetVehicle.partConditions = deepcopy(session.initial.partConditions)
  return true
end
owner.onOverhaulFuelSystemPersisted = function() return runtime.currentSession end
overhaul_career_business_partCustomization = owner

-- Stand-in for the business computer: its vehicle helpers live in a local called api.
local racingTeam = true
local api = {}
function api.isRacingTeamBusinessId() return racingTeam end
function api.isDamageLocked(businessId, vehicleId)
  local damage = map.objects[VEH].damage
  return {locked = damage >= 1500, damage = damage, threshold = 1500}
end
function api.getDamageLockedVehicleInfo(businessId)
  local info = api.isDamageLocked(businessId, V)
  return info.locked and info or nil
end
function api.notifyDamageLocked(lockInfo) messages[#messages + 1] = "RLS lock message" end
function api.shouldPreventVehicleOperation(businessId, vehicleId)
  if api.isRacingTeamBusinessId(businessId) then return false end
  local info = api.isDamageLocked(businessId, vehicleId)
  if info.locked then api.notifyDamageLocked(info) return true end
  return false
end
local treeRequests = 0
local computer = {}
computer.getBusinessComputerUIData = function(businessId)
  local info = api.isDamageLocked(businessId, V)
  return {vehicleDamageLocked = info.locked, pulledOutVehicles = {{vehicleId = V, damageLocked = info.locked}}}
end
computer.getVehiclesOnly = function() return {vehicles = {}, pulledOutVehicles = {{vehicleId = V, damageLocked = true}}} end
computer.completeJob = function() return "completed" end
computer.requestVehiclePartsTree = function() treeRequests = treeRequests + 1 end
computer.helper = function(...) return api.shouldPreventVehicleOperation(...) end
overhaul_career_business_computer = computer

-- Before the mod -----------------------------------------------------------------------------------
check("RLS refuses Parts on a car with a broken part", owner.initializePreviewVehicle(B, V), false)

-- With the mod -----------------------------------------------------------------------------------
package.path = here .. "/lua/ge/extensions/?.lua;" .. package.path
xRlsVehicleDamagePatch = require("xRlsVehicleDamagePatch")
local business = require("xRlsVehicleDamagePatchBusiness")
xRlsVehicleDamagePatchBusiness = business
business._install()
local active = false
for _, line in ipairs(logged) do if line:find("Business hooks active", 1, true) then active = true end end
check("hooks installed", active, true)

check("kits and other callers keep the block (no parts session)", access.getRepairReason(B, V) ~= nil, true)
check("personal cars keep the block", access.getRepairReason(B, "personal_9") ~= nil, true)

-- Race team: open Parts on the damaged car.
check("Parts opens on the damaged car", owner.initializePreviewVehicle(B, V), true)
local key = B .. "|" .. V
local record = business._records()[key]
check("damage recorded for the session", record ~= nil, true)
check("snapshot queued on the car", (queued[1] or ""):find("saveDamageData", 1, true) ~= nil, true)
check("live conditions requested", (queued[2] or ""):find("onLiveConditions", 1, true) ~= nil, true)

-- The car answers: the hood is broken, the door is bent (0.5) though the record said healthy.
files[record.file] = serialize({format = "rls_v1", partStates = {
  [HOOD] = {beams = {["1"] = {broken = true}, ["2"] = {}}},
  [DOOR] = {beams = {["3"] = {deformed = true}}},
  [BODY] = {beams = {["4"] = {}}},
}})
business.onLiveConditions(key, serialize({
  ["/body"] = {integrityValue = 1},
  [HOOD .. "hood_a"] = {integrityValue = 0},
  [DOOR .. "door_a"] = {integrityValue = 0.5},
}))
check("paid record now shows the bent door", fleetVehicle.partConditions[DOOR .. "door_a"].integrityValue, 0.5)
check("open session sees the bent door", runtime.currentSession.initial.partConditions[DOOR .. "door_a"].integrityValue, 0.5)
check("beam damage read from the snapshot", record.beamDamage[HOOD], 0.5)

-- Labels on the business parts list.
local P = xRlsVehicleDamagePatch.MARK_PART
local tree = {path = "/", chosenPartName = "body", slotNiceName = "Body", children = {
  hood = {path = HOOD, chosenPartName = "hood_a", slotNiceName = "Hood", children = {}},
  door = {path = DOOR, chosenPartName = "door_a", slotNiceName = "Left Door", children = {}},
}}
guihooks.trigger("businessComputer:onVehiclePartsTree", {success = true, businessId = B, vehicleId = V,
  partTreeHierarchy = tree, partsTree = {{path = HOOD, slotNiceName = "Hood"}, {path = "/x/", slotNiceName = "X"}}})
local sent = shown["businessComputer:onVehiclePartsTree"]
check("hood labelled in the tree", sent.partTreeHierarchy.children.hood.slotNiceName:find(P, 1, true) ~= nil, true)
check("hood labelled with its beam damage", sent.partTreeHierarchy.children.hood.slotNiceName:find("50% damaged", 1, true) ~= nil, true)
check("bent door labelled", sent.partTreeHierarchy.children.door.slotNiceName:find(P, 1, true) ~= nil, true)
check("hood labelled in the slot list", sent.partsTree[1].slotNiceName:find(P, 1, true) ~= nil, true)
check("other slots untouched", sent.partsTree[2].slotNiceName, "X")
check("RLS's tree left as it was", tree.children.hood.slotNiceName, "Hood")

-- Buy a new hood (same part) and check out; RLS reopens the session straight away.
runtime.currentSession.replacementParts = {{slotPath = HOOD, partName = "hood_a"}}
runtime.currentSession.preview.partConditions[HOOD .. "hood_a"] = {integrityValue = 1}
owner.commitSessionInitialFromPreview(B, V)
check("purchase records the replaced hood", record.replaced[HOOD], true)
business.onVehicleSpawned(VEH)
runtime.currentSession = nil
owner.initializePreviewVehicle(B, V)
check("reopened session keeps the same damage record", business._records()[key], record)
check("new hood stays new in the paid record", fleetVehicle.partConditions[HOOD .. "hood_a"].integrityValue, 1)

-- Leaving Parts: the respawned car gets the door's dents back, not the hood's.
queued = {}
runtime.currentSession = nil
business.pollRecords()
check("record closed with the session", business._records()[key], nil)
runJobs()
local load = queued[1] or ""
check("dents reloaded", load:find("loadDamageData", 1, true) ~= nil, true)
check("replaced hood skipped", load:find(HOOD, 1, true) ~= nil, true)
check("door not skipped", load:find(DOOR, 1, true) == nil, true)
check("door stays bent in the paid record", fleetVehicle.partConditions[DOOR .. "door_a"].integrityValue, 0.5)
check("snapshot removed", files[record.file], nil)

-- Parts opened and closed with no change: the car was never respawned, nothing reloaded.
queued = {}
owner.initializePreviewVehicle(B, V)
local second = business._records()[key]
files[second.file] = serialize({format = "rls_v1", partStates = {[DOOR] = {beams = {["3"] = {deformed = true}}}}})
business.onLiveConditions(key, serialize({[DOOR .. "door_a"] = {integrityValue = 0.5}}))
runtime.currentSession = nil
business.pollRecords()
runJobs()
local reloaded = false
for _, cmd in ipairs(queued) do if cmd:find("loadDamageData", 1, true) then reloaded = true end end
check("no respawn: dents not loaded twice", reloaded, false)
check("unused snapshot removed", files[second.file], nil)

-- A clean car: no record, RLS's own behaviour.
map.objects[VEH].damage = 0
fleetVehicle.partConditions[DOOR .. "door_a"].integrityValue = 1
owner.initializePreviewVehicle(B, V)
check("clean car: no damage record", business._records()[key], nil)
runtime.currentSession = nil

-- Tuning shop: the damage lock.
racingTeam = false
map.objects[VEH].damage = 4000
check("Parts and Tuning allowed while damage locked", computer.helper(B, V), false)
local ui = computer.getBusinessComputerUIData(B)
check("UI told the car isn't locked", ui.vehicleDamageLocked, false)
check("row unlocked", ui.pulledOutVehicles[1].damageLocked, false)
check("row still marked damaged for the mod", ui.pulledOutVehicles[1].xDamageLocked, true)
check("vehicle list unlocked", computer.getVehiclesOnly().pulledOutVehicles[1].damageLocked, false)
guihooks.trigger("businessComputer:onVehiclesUpdated", {pulledOutVehicles = {{damageLocked = true}}})
check("UI events unlocked too", shown["businessComputer:onVehiclesUpdated"].pulledOutVehicles[1].damageLocked, false)
messages = {}
check("Complete refused while over the limit", computer.completeJob(B, 1), false)
check("message says to replace the parts", (messages[1] or ""):find("Replace the broken parts", 1, true) ~= nil, true)
map.objects[VEH].damage = 100
check("Complete works once under the limit", computer.completeJob(B, 1), "completed")
racingTeam = true
map.objects[VEH].damage = 4000
check("race team sells without the tuning shop's limit", computer.completeJob(B, 1), "completed")

for _, line in ipairs(logged) do if line:sub(1, 1) ~= "I" then print("log   " .. line) end end
print(string.format("%d/%d checks passed", checks - failures, checks))
os.exit(failures == 0 and 0 or 1)
