-- Runs the mod against RLS's real partShopping.lua, with the game's globals stubbed.
-- Usage: luajit tools/test.lua <folder holding RLS's lua/ tree>

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

-- A value that absorbs any use: index, call, concatenation. Stands in for game systems.
local anything
anything = setmetatable({}, {
  __index = function() return anything end,
  __call = function() return anything end,
  __concat = function() return "" end,
})

-- BeamNG globals ---------------------------------------------------------------------------------
function deepcopy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local copy = {}
  seen[value] = copy
  for k, v in pairs(value) do copy[deepcopy(k, seen)] = deepcopy(v, seen) end
  return setmetatable(copy, getmetatable(value))
end
function tableMerge(a, b) for k, v in pairs(b or {}) do a[k] = v end return a end
function tableSize(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
function serialize(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local parts = {}
  for k, x in pairs(v) do parts[#parts + 1] = "[" .. serialize(k) .. "]=" .. serialize(x) end
  return "{" .. table.concat(parts, ",") .. "}"
end
function deserialize(s) return assert(loadstring("return " .. s))() end
-- Small JSON reader for a damage snapshot file.
function deserializeJson(path)
  local f = assert(io.open(path, "rb")); local text = f:read("*a"); f:close()
  local pos = 1
  local value
  local function skip() pos = text:find("%S", pos) or #text + 1 end
  local function str()
    local out, i = {}, pos + 1
    while true do
      local c = text:sub(i, i)
      if c == '"' then pos = i + 1 return table.concat(out) end
      if c == "\\" then
        local n = text:sub(i + 1, i + 1)
        local map = {n = "\n", t = "\t", r = "\r", b = "\b", f = "\f"}
        if n == "u" then out[#out + 1] = "?" i = i + 6 else out[#out + 1] = map[n] or n i = i + 2 end
      else out[#out + 1] = c i = i + 1 end
    end
  end
  value = function()
    skip()
    local c = text:sub(pos, pos)
    if c == "{" then
      local t = {} pos = pos + 1 skip()
      if text:sub(pos, pos) == "}" then pos = pos + 1 return t end
      while true do
        skip() local k = str() skip() pos = pos + 1
        t[k] = value() skip()
        local d = text:sub(pos, pos) pos = pos + 1
        if d == "}" then return t end
      end
    elseif c == "[" then
      local t = {} pos = pos + 1 skip()
      if text:sub(pos, pos) == "]" then pos = pos + 1 return t end
      while true do
        t[#t + 1] = value() skip()
        local d = text:sub(pos, pos) pos = pos + 1
        if d == "]" then return t end
      end
    elseif c == '"' then return str()
    elseif text:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
    elseif text:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
    elseif text:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
    else
      local num = text:match("^-?[%d%.eE+-]+", pos) pos = pos + #num return tonumber(num)
    end
  end
  return value()
end
function _tr(s) return s end
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
function readFile(p) return files[p] end
function writeFile(p, c) files[p] = c end
function jsonReadFile(p) return files[p] and deserialize(files[p]) end

local hookUpdates = {}
extensions = setmetatable({hookUpdate = function(name) hookUpdates[#hookUpdates + 1] = name end}, {__index = anything})
guihooks, core_vehicleBridge, overhaul_career_parts_partInventory = anything, anything, anything

local jobs = {}
core_jobsystem = {create = function(fn) jobs[#jobs + 1] = fn end}
local function runJobs()
  local pending = jobs
  jobs = {}
  for _, fn in ipairs(pending) do fn({sleep = function() end}) end
end

-- Vehicle 7: a car with three broken parts, spawned as object 1007.
local INV = 7
local DOOR = "/body/door_FL/"
local HOOD = "/body/hood/"
local BUMPER = "/body/bumper_F/"
local MIRROR = "/body/door_FL/mirror_L/"
local record = {
  id = INV,
  partConditions = {
    [DOOR .. "door_FL_a"] = {integrityValue = 0, odometer = 10},
    [HOOD .. "hood_a"] = {integrityValue = 0, odometer = 10},
    [BUMPER .. "bumper_a"] = {integrityValue = 0, odometer = 10},
    [MIRROR .. "mirror_a"] = {integrityValue = 0.5, odometer = 10},
    ["/body/body_a"] = {integrityValue = 1, odometer = 10},
  },
}
local vehicles = {[INV] = record}
local queued = {}
local vehicleObj = {queueLuaCommand = function(_, cmd) queued[#queued + 1] = cmd end}
be = {getObjectByID = function(_, id) return id == 1007 and vehicleObj or nil end}

overhaul_career_garage_inventory = setmetatable({
  getVehicles = function() return vehicles end,
  getVehicleIdFromInventoryId = function(id) return id == INV and 1007 or nil end,
  getCurrentVehicle = function() return INV end,
}, {__index = anything})

local needsRepairCalls = 0
overhaul_career_market_valueCalculator = setmetatable({
  partConditionsNeedRepair = function(conditions)
    needsRepairCalls = needsRepairCalls + 1
    local n = 0
    for _, c in pairs(conditions or {}) do if c.integrityValue == 0 then n = n + 1 end end
    return n >= 3
  end,
}, {__index = anything})

overhaul_career_garage_computer = {reasons = {
  needsRepair = {type = "needsRepair", label = "needs repair"},
  hasBoughtStarterVehicle = {type = "text", label = "starter"},
}}
overhaul_career_permissions = {getStatusForTag = function() return {allow = true, permission = "allowed"} end}

local savedDamage, clearedDamage = {}, {}
overhaul_career_repair_damageManager = setmetatable({
  saveDamageState = function(id) savedDamage[#savedDamage + 1] = id end,
  clearDamageState = function(id) clearedDamage[#clearedDamage + 1] = id end,
}, {__index = anything})

-- RLS's real part shop, with its own requires stubbed --------------------------------------------
local realRequire = require
require = function(name)
  if name == "xRlsVehicleDamagePatch" then return realRequire(name) end
  return anything
end
local partShopping = assert(loadfile(rlsRoot .. "/lua/ge/extensions/overhaul/career/parts/partShopping.lua"))()
require = realRequire
overhaul_career_parts_partShopping = partShopping

-- Real RLS behaviour first, so the test proves the block exists --------------------------------
local menuData = {
  computerFacility = {id = "garage1", functions = {partShop = true}},
  hasBoughtStarterVehicle = true,
  vehiclesInGarage = {{inventoryId = INV, needsRepair = true}},
}
local functions = {general = {}, vehicleSpecific = {[INV] = {}}}
partShopping.onOverhaulComputerAddFunctions(menuData, functions)
check("RLS greys the button out on a car needing repair", functions.vehicleSpecific[INV].partShop.disabled, true)

partShopping.startShopping(INV)
check("RLS refuses to open the shop", messages[#messages], "Repair the vehicle before changing parts.")

-- With the mod -----------------------------------------------------------------------------------
package.path = here .. "/lua/ge/extensions/?.lua;" .. package.path
local patch = require("xRlsVehicleDamagePatch")
xRlsVehicleDamagePatch = patch
patch._install()
check("hook cache refreshed", hookUpdates[1], "onOverhaulComputerAddFunctions")

functions = {general = {}, vehicleSpecific = {[INV] = {}}}
partShopping.onOverhaulComputerAddFunctions(menuData, functions)
local entry = functions.vehicleSpecific[INV].partShop
check("button enabled", entry.disabled, nil)
check("no repair reason", entry.reason, nil)
check("menu data left alone", menuData.vehiclesInGarage[1].needsRepair, true)

-- Same pass where RLS ran unwrapped, then the mod's own hook.
functions = {general = {}, vehicleSpecific = {[INV] = {}}}
local unwrapped = {disabled = true, reason = overhaul_career_garage_computer.reasons.needsRepair, callback = function() end}
functions.vehicleSpecific[INV].partShop = unwrapped
patch.onOverhaulComputerAddFunctions(menuData, functions)
check("fallback unblocks an unwrapped entry", unwrapped.disabled, nil)

-- A tutorial block stays.
local starterMenu = deepcopy(menuData)
starterMenu.hasBoughtStarterVehicle = false
functions = {general = {}, vehicleSpecific = {[INV] = {}}}
partShopping.onOverhaulComputerAddFunctions(starterMenu, functions)
check("tutorial block kept", functions.vehicleSpecific[INV].partShop.disabled, true)

-- Opening the shop.
local before = #messages
local checksBefore = needsRepairCalls
partShopping.startShopping(INV)
check("shop opens without the repair message", #messages, before)
check("repair check restored afterwards", overhaul_career_market_valueCalculator.partConditionsNeedRepair(record.partConditions), true)
check("repair check was bypassed, not skipped", needsRepairCalls > checksBefore, true)
check("snapshot requested from the car", (queued[1] or ""):find("saveDamageData", 1, true) ~= nil, true)
check("live conditions requested", (queued[2] or ""):find("partCondition.getConditions", 1, true) ~= nil, true)

-- The live car reports the hood more damaged than... it's already 0; the bumper as healthy (ignored).
patch.onLiveConditions(INV, serialize({[BUMPER .. "bumper_a"] = {integrityValue = 1}, ["/body/grille/grille_a"] = {integrityValue = 0}}))
local session = patch._getSession()
session_file_first = session.file
check("healthy live reply doesn't hide damage", session.conditions[BUMPER .. "bumper_a"].integrityValue, 0)
check("live-only broken part recorded", session.conditions["/body/grille/grille_a"].integrityValue, 0)

-- Labels.
local tree = {
  path = "/", chosenPartName = "body_root", slotNiceName = "Root",
  children = {
    body = {path = "/body/", chosenPartName = "body_a", slotNiceName = "Body", children = {
      door_FL = {path = DOOR, chosenPartName = "door_FL_a", slotNiceName = "Front Left Door", children = {
        mirror_L = {path = MIRROR, chosenPartName = "mirror_a", slotNiceName = "Left Mirror", children = {}},
      }},
      hood = {path = HOOD, chosenPartName = "hood_a", slotNiceName = "Hood", children = {}},
      bumper_F = {path = BUMPER, chosenPartName = "bumper_b", slotNiceName = "Front Bumper", children = {}},
    }},
  },
}
local data = {
  partTree = tree,
  slotsNiceName = {[DOOR] = "Front Left Door", [HOOD] = "Hood", [MIRROR] = "Left Mirror", ["/body/"] = "Body", [BUMPER] = "Front Bumper"},
  searchSlotList = {{path = HOOD, slotNiceName = "Hood"}},
  shoppingCart = {partsIn = {[BUMPER] = {containingSlot = BUMPER, name = "bumper_b"}}},
  vehicleSlotToPartMap = {[DOOR] = {location = INV}},
}
local decorated = patch.decorateShopData(deepcopy(data), patch._getSession().conditions)
local body = decorated.partTree.children.body
local P, I, H = patch.MARK_PART, patch.MARK_INSIDE, patch.MARK_HIDE
check("broken door with no beam data says broken", body.children.door_FL.slotNiceName, "Front Left Door " .. P .. "broken " .. H .. "broken")
check("damaged mirror marked with percent", body.children.door_FL.children.mirror_L.slotNiceName, "Left Mirror " .. P .. "50% damaged " .. H .. "damaged")
check("slot in cart not marked", body.children.bumper_F.slotNiceName, "Front Bumper")
check("healthy parent marked yellow", body.slotNiceName, "Body " .. I .. H .. "3 damaged inside")
check("search names marked", decorated.slotsNiceName[HOOD], "Hood " .. P .. "broken " .. H .. "broken")
check("search list marked", decorated.searchSlotList[1].slotNiceName, "Hood " .. P .. "broken " .. H .. "broken")
local shares = patch.beamDamageBySlot({partStates = {
  [HOOD] = {beams = {["1"] = {broken = true}, ["2"] = {deformed = 0.02}, ["3"] = {length = 1}, ["4"] = {length = 1}}},
  [DOOR] = {beams = {["5"] = {length = 1}}},
  ["/body/wheeldata/"] = {nodes = {}},
}})
check("beam share counts broken and bent beams", shares[HOOD], 0.5)
check("undamaged beams give 0", shares[DOOR], 0)
check("slot without beams has no share", shares["/body/wheeldata/"], nil)
local withBeams = patch.decorateShopData(deepcopy(data), patch._getSession().conditions, shares)
check("broken hood shows its beam damage", withBeams.partTree.children.body.children.hood.slotNiceName, "Hood " .. P .. "50% damaged " .. H .. "broken")
check("broken part with 0 beam damage says broken", withBeams.partTree.children.body.children.door_FL.slotNiceName, "Front Left Door " .. P .. "broken " .. H .. "broken")
check("tiny damage rounds up to 1%", patch.damageTag({integrityValue = 0}, 0.001):find("1% damaged", 1, true) ~= nil, true)
if arg[2] then
  local real = patch.beamDamageBySlot(deserializeJson(arg[2]))
  local count, inRange = 0, true
  for slot, share in pairs(real) do
    count = count + 1
    if share < 0 or share > 1 then inRange = false end
    if share > 0 then print(string.format("      %5.1f%%  %s", share * 100, slot)) end
  end
  check("real snapshot: slots read", count > 0, true)
  check("real snapshot: shares between 0 and 1", inRange, true)
end
check("search for 'broken' still matches", decorated.slotsNiceName[HOOD]:lower():find("broken", 1, true) ~= nil, true)
check("original data untouched", tree.children.body.slotNiceName, "Body")

-- Checkout: the door is replaced (new part, mirror carried over); the preview made everything healthy.
local preview = deepcopy(record)
for _, c in pairs(preview.partConditions) do c.integrityValue = 1 end
preview.partConditions[DOOR .. "door_FL_a"] = nil
preview.partConditions[DOOR .. "door_FL_b"] = {integrityValue = 1, odometer = 0}
vehicles[INV] = preview
local oldDoorRow = {partPath = DOOR .. "door_FL_a", containingSlot = DOOR, partCondition = {integrityValue = 1, odometer = 10}}
partShopping.getShoppingCart = function()
  return {partsIn = {[DOOR] = {containingSlot = DOOR, name = "door_FL_b"}}, partsOut = {[DOOR] = oldDoorRow}}
end
files[session.file] = serialize({format = "rls_v1", partStates = {
  [HOOD] = {beams = {["12"] = {broken = true}}},
  [DOOR] = {beams = {["30"] = {broken = true}}},
  ["/body/"] = {beams = {["1"] = {length = 1}}},
}})

patch.onOverhaulPartShoppingPartsInstalled(INV)
check("new door stays new", preview.partConditions[DOOR .. "door_FL_b"].integrityValue, 1)
check("hood stays broken", preview.partConditions[HOOD .. "hood_a"].integrityValue, 0)
check("bumper stays broken", preview.partConditions[BUMPER .. "bumper_a"].integrityValue, 0)
check("mirror keeps its damage", preview.partConditions[MIRROR .. "mirror_a"].integrityValue, 0.5)
check("healthy body untouched", preview.partConditions["/body/body_a"].integrityValue, 1)
check("removed door goes to inventory broken", oldDoorRow.partCondition.integrityValue, 0)
check("removed door keeps its odometer", oldDoorRow.partCondition.odometer, 10)

queued = {}
patch.onOverhaulPartShoppingTransactionComplete()
runJobs()
local load = queued[1] or ""
check("damage reloaded onto the car", load:find("loadDamageData", 1, true) ~= nil, true)
check("replaced door slot skipped", load:find(DOOR, 1, true) ~= nil, true)
check("hood not skipped", load:find(HOOD, 1, true) == nil, true)
check("bent body (counted as fine) skipped", load:find('"/body/"', 1, true) ~= nil, true)
check("RLS re-captures the damage", savedDamage[#savedDamage], INV)
check("session closed", patch._getSession(), nil)

-- A new body: the dented parts bolted to it keep their condition but not their dents.
local bodyConditions = {
  ["/covet_body/covet_body"] = {integrityValue = 0},
  ["/covet_body/covup_door_L/covup_door_L"] = {integrityValue = 0},
  ["/covet_body/covup_bed/covup_tailgate/covup_tailgate"] = {integrityValue = 0},
}
check("new body: nothing under it gets dents back", next(patch.slotsToRestore(bodyConditions, {["/covet_body/"] = {}})), nil)
local doorOnly = patch.slotsToRestore(bodyConditions, {["/covet_body/covup_door_L/"] = {}})
check("new door: the bed keeps its dents", doorOnly["/covet_body/covup_bed/covup_tailgate/"], true)
check("new door: the body keeps its dents", doorOnly["/covet_body/"], true)
check("new door: not the door", doorOnly["/covet_body/covup_door_L/"], nil)

-- Every broken part replaced: like the Covet, the body has a few bent beams and the engine is at
-- 99%, neither counted as damaged. Nothing is reloaded, so the car comes back repaired.
local ENGINE = "/body/engine/"
vehicles[INV] = {id = INV, partConditions = {
  [DOOR .. "door_FL_a"] = {integrityValue = 0},
  [ENGINE .. "engine_a"] = {integrityValue = 0.992},
  ["/body/body_a"] = {integrityValue = 1},
}}
partShopping.startShopping(INV)
session = patch._getSession()
local allFile = session.file
files[allFile] = serialize({format = "rls_v1", partStates = {
  [DOOR] = {beams = {["30"] = {broken = true}}},
  ["/body/"] = {beams = {["2"] = {deformed = 0.02}}},
  [ENGINE] = {beams = {["40"] = {broken = true}}},
}})
partShopping.getShoppingCart = function()
  return {partsIn = {[DOOR] = {containingSlot = DOOR, name = "door_FL_b"}}, partsOut = {[DOOR] = {partPath = DOOR .. "door_FL_a", containingSlot = DOOR}}}
end
patch.onOverhaulPartShoppingPartsInstalled(INV)
queued = {}
patch.onOverhaulPartShoppingTransactionComplete()
runJobs()
check("all broken parts replaced: no damage reloaded", #queued, 0)
check("all broken parts replaced: snapshot removed", files[allFile], nil)
check("each shop visit gets its own snapshot file", allFile ~= session_file_first, true)

-- Flat tyres: like the Covet, one front tyre part covers FL and FR, and only FL is flat.
local TYRE_F = "/body/suspension_F/hub_F/wheel_F/tire_F/"
local covetLike = {id = INV, partConditions = {[TYRE_F .. "tire_F_a"] = {integrityValue = 1}}, rlsTireLayout = {wheels = {
  {name = "FL", containingSlot = TYRE_F, partPath = TYRE_F .. "tire_F_a", flat = true},
  {name = "FR", containingSlot = TYRE_F, partPath = TYRE_F .. "tire_F_a", flat = false},
  {name = "RL", containingSlot = "/body/tire_R/", flat = false},
}}}
local flats = patch.flatTyresBySlot(covetLike)
check("flat FL found in the front tyre slot", flats[TYRE_F] and flats[TYRE_F][1], "FL")
check("only the flat wheel listed", #flats[TYRE_F], 1)
check("no flat on the rear", flats["/body/tire_R/"], nil)
local tyreData = {partTree = {path = "/", chosenPartName = "root", children = {
  tire = {path = TYRE_F, chosenPartName = "tire_F_a", slotNiceName = "Front Tires", children = {}},
}}, slotsNiceName = {}, searchSlotList = {}, shoppingCart = {partsIn = {}}}
local tyreShown = patch.decorateShopData(tyreData, covetLike.partConditions, {}, flats)
check("flat tyre shown red with the wheel", tyreShown.partTree.children.tire.slotNiceName, "Front Tires " .. P .. "flat (FL) " .. H .. "broken flat")

local tireCalls = {}
overhaul_career_maintenance_tireSystem = {
  forceFreshWheels = function(id, names) table.sort(names) tireCalls[#tireCalls + 1] = "fresh " .. id .. " " .. table.concat(names, ",") return true end,
  refreshLiveTires = function(id) tireCalls[#tireCalls + 1] = "refresh " .. id end,
}
vehicles[INV] = covetLike
patch.onOverhaulPartShoppingPartsInstalled(INV, {{name = "tire_F_a", containingSlot = TYRE_F, fromInventory = false}})
patch.onOverhaulPartShoppingTransactionComplete()
check("new front tyre: both front wheels made fresh", tireCalls[1], "fresh 7 FL,FR")
runJobs()
check("fresh again after the car settles", #tireCalls, 3)

tireCalls = {}
patch.onOverhaulPartShoppingPartsInstalled(INV, {{name = "tire_F_a", containingSlot = TYRE_F, fromInventory = true}})
patch.onOverhaulPartShoppingTransactionComplete()
check("used tyre from inventory keeps its own state", tireCalls[1], "refresh 7")
runJobs()

tireCalls = {}
patch.onOverhaulPartShoppingPartsInstalled(INV, {{name = "hood_b", containingSlot = HOOD, fromInventory = false}})
patch.onOverhaulPartShoppingTransactionComplete()
runJobs()
check("no tyre bought: tyres left alone", #tireCalls, 0)

-- Preview: a new front tyre in the cart starts FL fresh instead of popping; Cancel puts the flat back.
local oldFront = {location = INV, partPath = TYRE_F .. "tire_F_a", containingSlot = TYRE_F, name = "tire_F_a",
  rlsTireState = {schemaVersion = 1, wheels = {FL = {remaining = 0.6, flat = true}, FR = {remaining = 0.6, flat = false}}}}
local rear = {location = INV, partPath = "/body/tire_R/tire_R_a", containingSlot = "/body/tire_R/", name = "tire_R_a"}
local spare = {location = 0, partPath = TYRE_F .. "tire_F_a", containingSlot = TYRE_F, name = "tire_F_a"}
local partsInv = {[21] = oldFront, [22] = rear, [23] = spare}
overhaul_career_parts_partInventory = setmetatable({getInventory = function() return partsInv end}, {__index = anything})
covetLike.rlsTireLayout.wheels[1].remaining, covetLike.rlsTireLayout.wheels[2].remaining = 0.6, 0.6
covetLike.rlsTireLayout.wheels[3].partPath, covetLike.rlsTireLayout.wheels[3].remaining = "/body/tire_R/tire_R_a", 0.8
local captured = patch.captureTyres(INV, covetLike, partsInv)
check("front wheels captured on the fitted part, not the spare", captured.parts[21] and captured.parts[21].FL.flat, true)
check("spare in inventory not captured", captured.parts[23], nil)

vehicles[INV] = covetLike
partShopping.startShopping(INV)
local cart = {partsIn = {}}
partShopping.getShoppingCart = function() return cart end
tireCalls = {}
patch._freshenPreviewTyres()
check("empty cart: preview tyres left alone", #tireCalls, 0)

cart.partsIn[TYRE_F] = {name = "tire_F_a", containingSlot = TYRE_F, partPath = TYRE_F .. "tire_F_a"}
patch._freshenPreviewTyres()
check("new tyre in cart: preview starts FL inflated", oldFront.rlsTireState.wheels.FL.flat, false)
check("new tyre in cart: full tread", oldFront.rlsTireState.wheels.FL.remaining, 1)
check("mirrored into tags", oldFront.tags.rlsTireState.wheels.FL.flat, false)
check("live tyres refreshed", tireCalls[1], "refresh 7")
check("rear keeps its own wear", rear.rlsTireState.wheels.RL.remaining, 0.8)
check("flat still known for labels during the preview",
  patch.flatTyresBySlot({rlsTireLayout = patch._getSession().tyres.layout})[TYRE_F][1], "FL")

cart.partsIn[TYRE_F] = nil
patch._freshenPreviewTyres()
check("tyre taken out of the cart: flat back", oldFront.rlsTireState.wheels.FL.flat, true)
cart.partsIn[TYRE_F] = {name = "tire_F_b", containingSlot = TYRE_F, partPath = TYRE_F .. "tire_F_b"}
patch._freshenPreviewTyres()
patch.onOverhaulPartShoppingCancelled()
check("cancel: old tyre gets its flat back", oldFront.rlsTireState.wheels.FL.flat, true)
check("cancel: old tyre keeps its wear", oldFront.rlsTireState.wheels.FR.remaining, 0.6)
overhaul_career_repair_damageManager.clearDamageState(INV)

-- Checkout after the preview: the removed tyre goes to the inventory with its own flat.
partShopping.startShopping(INV)
patch._freshenPreviewTyres()
check("preview inflated again", oldFront.rlsTireState.wheels.FL.flat, false)
oldFront.location = 0
patch.onOverhaulPartShoppingPartsInstalled(INV, {{name = "tire_F_b", containingSlot = TYRE_F, fromInventory = false}})
check("removed tyre keeps its flat in the inventory", oldFront.rlsTireState.wheels.FL.flat, true)
patch.onOverhaulPartShoppingTransactionComplete()
runJobs()
overhaul_career_parts_partInventory = anything

-- Cancel keeps the pre-shop damage.
vehicles[INV] = record
partShopping.startShopping(INV)
session = patch._getSession()
files[session.file] = serialize({format = "rls_v1", partStates = {[HOOD] = {beams = {["12"] = {broken = true}}}}})
patch.onOverhaulPartShoppingCancelled()
local clearsBefore = #clearedDamage
overhaul_career_repair_damageManager.clearDamageState(INV)
check("cancel doesn't clear damage", #clearedDamage, clearsBefore)
check("pre-shop snapshot handed to RLS", files["/temp/rls_career/damageSession/7_damageState.json"] ~= nil, true)
overhaul_career_repair_damageManager.clearDamageState(INV)
check("later clears work as before", #clearedDamage, clearsBefore + 1)

-- An undamaged car's checkout does nothing extra.
vehicles[INV] = {id = INV, partConditions = {["/body/body_a"] = {integrityValue = 1}}}
partShopping.startShopping(INV)
patch.onOverhaulPartShoppingPartsInstalled(INV)
queued = {}
patch.onOverhaulPartShoppingTransactionComplete()
runJobs()
check("undamaged car: no reload", #queued, 0)

for _, line in ipairs(logged) do if line:sub(1, 1) ~= "I" then print("log   " .. line) end end
print(string.format("%d/%d checks passed", checks - failures, checks))
os.exit(failures == 0 and 0 or 1)
