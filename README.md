# Better Target

Standalone Ashita screen-based native target cycling and replacement target arrow. Frame visibility is handled separately by hideparty or hudbegone.

Load with `/addon load bettertarget`; open its configuration window with `/bettertarget`. Settings save in `bettertarget.ini` through Ashita's configuration manager. Target cycling and the replacement cursor default to enabled.

Cursor width and height have independent sliders from 4 to 128 pixels, defaulting to width 24 and height 16. Old cursorSize settings migrate to both dimensions unless an explicit new dimension is already saved. Vertical offset ranges from 0 to 10 pixels and defaults to 4; positive values move the cursor up.

Marker Color and Border Color are RGBA pickers. Adjust each alpha channel for transparency (0 is transparent, 1 is opaque). Border Thickness ranges from 0 to 12 pixels; 0 hides the border. Defaults are an opaque white marker and an opaque black border, 2 pixels thick. The border uses an outline instead of a solid background triangle so marker transparency works correctly. Appearance settings save with the other bettertarget settings.

The configuration window has Target Cycling and Target Cursor tabs. Target Cycling contains cycling and bumper input settings. Target Cursor contains Replace Target Cursor and Standard, Locked-On and Switching appearance sections. Locked-On defaults to **Same as Standard**, inheriting every standard appearance setting as it changes. Turn it off to customize lock-on width, height, offset, marker/border RGBA colors and border thickness independently. Its custom default is a red-orange marker. Existing standard settings are preserved.

During the combat menu's **Switch Targets** selection, the regular cursor stays on the current enemy while a second cursor follows the candidate enemy's native subtarget arrow (`m_SubAnkX`/`m_SubAnkY`). The Switching section has independent dimensions, vertical offset, marker/border RGBA and border thickness; its defaults match Standard (24×16, offset 4, opaque white marker, opaque black border, thickness 2). The native candidate arrow is above the regular arrow when both point at the same enemy. Spell and ability subtargeting also show this cursor, including outside combat and selections started by macros. Those selections retain native cycling and valid-target rules. Closing, confirming or cancelling the selection removes it on the next presentation. Both cursors obey Replace Target Cursor and the existing cutscene/anchor checks.

The cursor tip follows the base game's main target icon anchor: `m_AnkX`/`m_AnkY` from `GetRawStructureWindow()`, matching the original hideparty copy.lua cursor. The anchor is in the game's menu (UI) resolution (boot config `0037`/`0038`) and is scaled to the window, so it stays aligned when the menu resolution differs from the window resolution. Width extends equally on either side; height extends upward. Offset shifts the tip vertically in pixels. Cutscene, live-target, native-window presence and screen-bound checks remain. Drawing does not require the confirmed target window to be loaded: initial Tab/D-pad selections and Enter/A selections both draw from the native anchor, including when the target HUD is hidden.

Commands:

- `/bettertarget cycling on|off`
- `/bettertarget bumpers on|off`
- `/bettertarget cursor on|off`
- `/bettertarget cursor width <4-128>`
- `/bettertarget cursor height <4-128>`
- `/bettertarget cursor size <4-128>` (compatibility shortcut setting both dimensions)
- `/bettertarget cursor offset <0-10>`
- `/bettertarget help`

If hideparty also draws a replacement arrow, use `/hideparty cursor off` to avoid overlapping cursors. The game's resolved previous/next target actions select the previous/next visible candidate, wrapping the list with the player last. Dead monsters are excluded even while their models remain visible. Hidden entities and entities marked non-targetable are excluded; monsters must also be rendered. Actor identity, targetability flags and monster HP are rechecked immediately before selection; a candidate that disappears or dies is skipped in the requested direction. An underground enemy becomes eligible again as soon as its flags allow targeting. Players and NPCs remain eligible regardless of HP. Existing keyboard and gamepad bindings continue to work, including remapped controls. With no eligible candidates, selection falls back to the player. Mouse selections and other target actions retain their normal behavior.

Install the Lua files in Ashita's addons directory. bettertarget uses Ashita button events for bumper input and does not use SDL; radgamepad owns SDL for camera movement. Unload moderncam before using its replacements. Requires Ashita's LuaJIT, common and imgui.

Native cycling uses validated client signatures to hook only the four left/right cycle branches (including wraparound). A small native queue forwards actions to Lua at the next backbuffer scene, avoiding Lua callbacks from native game code. Ordinary targeting and combat Switch Targets use the addon cycling when enabled. Switch Targets excludes the player and leaves the candidate unchanged if no eligible targets remain. Spell/ability selection, other modal contexts, disabled cycling, unavailable camera/player state and a full queue fall through to normal game cycling. Selection context is validated when capturing and consuming input; queued actions are discarded when that context changes. Turning cycling off clears pending actions. Unload restores the original calls. If signatures are missing or ambiguous, the cursor/configuration still work and native game cycling remains active with a warning.

After a callback error, reload can recover only an exact match for bettertarget's four orphaned native bridges. Unknown hooks remain untouched. Selection callback errors detach owned hooks before propagating the error. Saved appearance overrides are preserved when defaults change.



Bumpers Change Targets defaults to enabled. Left bumper selects the previous target; right bumper selects the next, once per physical press. Bumpers Change Targets works independently of Improved Target Cycling. Improved Target Cycling controls the game native next/previous target actions; Bumpers Change Targets controls the added bumper bindings. Bumpers use the same screen-based selection and combat Switch Targets player exclusion. During spell, ability or other subtarget selections, bumpers invoke the game's native next/previous target actions, preserving the selection's valid-target rules. Other game menus keep their original bumper bindings. A handled press and its release are consumed to avoid also activating the game binding. Native subtarget bumper cycling requires available native hooks; when unavailable, those presses retain their original game bindings.

Ordinary target cycling is disabled while locked on, both in and out of combat. Bumpers leave the current target and lock intact, including when Improved Target Cycling is off. Presses queued before lock-on are discarded. Unlock to resume cycling. Combat Switch Targets and spell/ability subtarget selection retain their existing behavior. The addon does not submit automatic attack-target commands or intercept FFXI's locked-action return.

Bumper Input defaults to Auto (Both), using Ashita xinput_button and dinput_button callbacks. Duplicate reports from both backends are combined into one press. XInput uses shoulder button IDs 8/9; DirectInput defaults to offsets 52/53 (button indices 4/5) and has configurable left/right offsets for other controller layouts. Select a specific backend if using independent controllers. Input is queued until the next scene and discarded on configuration, target-selection-context, or zone changes. Injected input and presses already blocked by another addon are ignored.



