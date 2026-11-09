RLS Vehicle Damage Patch 1.0.0

Lets you replace damaged parts in RLS Career Overhaul's Part Customization without repairing the
whole car first (written against RLS 2.8.0.2-beta).

Install: close BeamNG.drive, put x_rls_vehicle_damage_patch_1.0.0.zip (unextracted) in
  %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\
and start the game. RLS Career Overhaul must be installed too. Remove any older copy of this mod
first (including a _dev zip), or both load. To uninstall, delete the zip; saves are left as they
are.

What it changes:

1. The garage computer no longer greys out Part Customization when a car needs repair, and the
   shop no longer refuses with "Repair the vehicle before changing parts." Other blocks (tutorial,
   permissions) still apply.

2. In Part Customization, a slot holding a damaged part is shown in red with how badly it's
   damaged in small text after it ("Hood 9% damaged"). BeamNG scores a body part as either fine or
   broken (integrity 0, what RLS counts towards "needs repair"), so for a broken part the figure is
   the share of its beams that are broken or bent, read from the damage snapshot taken when the
   shop opens. A broken part with no beams of its own (wheel data, electrics) just says "broken".
   Parts that wear rather than break, like engines, show 100% minus their condition once below 90%.
   A healthy slot with damaged parts somewhere inside it is shown in yellow, so you can find them
   in the collapsed tree.
   Type "broken" or "damaged" into the slot search to list them.

   The colours come from a small UI script (ui/modModules/xRlsVehicleDamagePatch), which only
   loads when the game's UI starts. Without it the names read "Hood 9% damaged broken" and
   "Body 2 damaged inside" instead.

3. Buy a new part for the slot as usual (the same part, or another one). The new part is fresh.

4. Parts you don't replace keep their damage. RLS's preview respawns the car without damage and
   then saves those healthy conditions, which would otherwise repair the whole car for free. The
   mod copies the car's part conditions and a damage snapshot when the shop opens, puts the old
   conditions back at checkout, and reloads the snapshot onto the car (skipping the replaced
   slots) using RLS's own partial damage loader. A removed broken part goes into your parts
   inventory still broken.

   Only parts still shown in red get their dents back. Small bends in parts RLS counts as fine
   (a body shell with a few bent beams, a 99% engine) are dropped at checkout: putting back the
   old shape of the body would bend the new parts bolted to it and break them straight away. So
   once every red part is replaced, the car comes back fully repaired.

   Parts inside a part you replace don't get their dents back either. Buy a new body and the
   doors, bed and suspension on it come back straight (they still count as broken, so they stay
   red in the shop and you still pay to replace or repair them). Putting their old bent shape back
   onto a fresh body pulls it apart.

5. Flat tyres. RLS tracks flats per wheel (FL, FR, ...) separately from part condition, so a flat
   tyre reads 100% healthy. The mod shows the tyre slot in red with the flat wheel instead
   ("Front Tires flat (FL)"); search "flat" to find it. RLS only clears that flag on a full
   insurance repair, so without this mod a new tyre bought in the shop picks up the old flat and
   pops straight away. The mod starts the preview's wheels inflated with full tread when a new
   tyre for them is in the cart, and marks them fresh again at checkout (and once more after the
   car has settled). The old tyre keeps its own flat and wear:
   it goes to your parts inventory with them, and Cancel puts them back on the car. A used tyre
   fitted from your inventory keeps its own state after checkout (the preview still shows the old
   tyre's state for it).

6. Cancel (or Save for later) brings the car back with its damage, instead of healed.

Limits:
- If a purchase changes the car's shape (for example bigger wheels or a different suspension),
  the old dents are put back at their old positions, the same as RLS's own partial repair. Check
  the car after checkout.
- If the damage snapshot couldn't be taken (the car wasn't spawned), part conditions are still
  kept, but the dents aren't put back. The log says so.

Changes:
  1.0.0  First release.

How it works: the mod wraps RLS functions at runtime and ships no RLS code, so it doesn't overwrite
RLS files. If a later RLS version renames these functions, the mod logs a warning under
"xRlsVehicleDamagePatch" and leaves that part of RLS alone. Look for "Part shop hooks active" and
"Damage manager hook active" in beamng.log.

Test, from the folder holding the mod's files (unzip the release), with RLS's lua/ tree extracted
to <rls folder>:
  luajit tools/test.lua <rls folder> [a damage snapshot .json to check against]

Build: python tools/build.py (your own _dev zip) or python tools/build.py --release

Release: set version_string in mod_info/x_rls_vehicle_damage_patch/info.json, add the version to
"Changes" above, commit, then push a tag of the same version without a "v" (git tag 1.0.1 and
git push origin 1.0.1). GitHub Actions builds the zip and publishes it as a release.

Licence: GNU AGPL 3.0 (see LICENSE). This mod is for BeamNG.drive and runs alongside RLS Career
Overhaul (https://github.com/RLS-Modding/rls_career_overhaul), which has its own licence. This mod
is not made or endorsed by RLS Modding.
