local modifiers = dofile('modifiers.lua')
local settings = {
    modifierEnemiesSource = 1, modifierEnemiesButton = 1,
    modifierPlayersSource = 1, modifierPlayersButton = 2,
    modifierNpcsSource = 2, modifierNpcsButton = 52,
    modifierSelfSource = 0, modifierSelfButton = 0,
}
local function event(source, button, down)
    return {button = button, state = source == 'xinput' and (down and 1 or 0) or (down and 128 or 0), blocked = false}
end
local function press(source, button)
    local e = event(source, button, true)
    local consumed, captured = modifiers.handle(settings, source, e)
    return e, captured, consumed
end
local function release(source, button)
    local e = event(source, button, false)
    local consumed = modifiers.handle(settings, source, e)
    return e, consumed
end

-- Most recently pressed held modifier wins, and releasing it restores the prior one.
press('xinput', 1)
assert(modifiers.active(settings) == 'enemies')
press('xinput', 2)
assert(modifiers.active(settings) == 'players')
release('xinput', 2)
assert(modifiers.active(settings) == 'enemies')
release('xinput', 1)
assert(modifiers.active(settings) == nil)

-- Analog XInput triggers are captured from state values with press/release hysteresis.
modifiers.begin_bind('players')
local trigger_captured = modifiers.handle_trigger(settings, 'xinput', 'left', 40, false)
assert(trigger_captured and settings.modifierPlayersSource == 1 and settings.modifierPlayersButton == 256)
assert(modifiers.active(settings) == nil)
modifiers.handle_trigger(settings, 'xinput', 'left', 10, false)
assert(modifiers.active(settings) == nil)
local trigger_consumed, _, trigger_changed = modifiers.handle_trigger(settings, 'xinput', 'left', 35, false)
assert(trigger_consumed and trigger_changed)
assert(modifiers.active(settings) == 'players')
modifiers.handle_trigger(settings, 'xinput', 'left', 10, false)
assert(modifiers.active(settings) == nil)

-- Binding capture stores the backend/button, consumes the bind press and does not activate it.
modifiers.begin_bind('npcs')
local bind, captured = press('dinput', 52)
assert(not bind.blocked and captured and settings.modifierNpcsSource == 2 and settings.modifierNpcsButton == 52)
assert(modifiers.active(settings) == nil)

-- Modifier bindings observe events even when another addon has already handled them.
modifiers.begin_bind('self')
local blocked_trigger = event('xinput', 16, true)
blocked_trigger.blocked = true
local _, blocked_capture = modifiers.handle(settings, 'xinput', blocked_trigger)
assert(blocked_capture and settings.modifierSelfSource == 1 and settings.modifierSelfButton == 16)
modifiers.handle(settings, 'xinput', {button = 16, state = 0})

-- Ashita reports physical analog trigger buttons as XInput state 255.
modifiers.begin_bind('players')
local _, pressure_capture = modifiers.handle(settings, 'xinput', {button = 16, state = 255})
assert(pressure_capture and settings.modifierPlayersSource == 1 and settings.modifierPlayersButton == 16)
local pressure_release = modifiers.handle(settings, 'xinput', {button = 16, state = 0})
assert(pressure_release)

-- The classifier separates enemy mobs, other players, NPCs/objects, and self.
local kinds = {[10] = {type = 0, flags = 0}, [11] = {type = 1, flags = 0x10},
    [12] = {type = 0, flags = 0}, [13] = {type = 2, flags = 0}, [14] = {type = 3, flags = 0}}
local entity = {
    GetType = function(_, index) return kinds[index] and kinds[index].type end,
    GetSpawnFlags = function(_, index) return kinds[index] and kinds[index].flags end,
}
assert(modifiers.matches(entity, 11, 10, 'enemies'))
assert(not modifiers.matches(entity, 11, 10, 'npcs'))
assert(modifiers.matches(entity, 12, 10, 'players'))
assert(not modifiers.matches(entity, 10, 10, 'players'))
assert(modifiers.matches(entity, 13, 10, 'npcs'))
assert(modifiers.matches(entity, 14, 10, 'npcs'))
assert(modifiers.matches(entity, 10, 10, 'self'))
assert(not modifiers.matches(entity, 10, 10, 'enemies'))
release('dinput', 52)
press('dinput', 52)
assert(modifiers.active(settings) == 'npcs')
release('dinput', 52)
assert(modifiers.active(settings) == nil)

-- Rebinding a button removes an older modifier bound to the same physical input.
modifiers.begin_bind('self')
local _, rebound = press('xinput', 1)
assert(rebound and settings.modifierSelfSource == 1 and settings.modifierSelfButton == 1)
assert(settings.modifierEnemiesSource == 0 and settings.modifierEnemiesButton == 0)
release('xinput', 1)

-- A bumper press carries the active modifier snapshot to the deferred cycle callback.
local gamepad = dofile('gamepad.lua')
local bumper_settings = {bumperInputMode = 1, enableBumperCycling = true}
local bumper = event('xinput', 8, true)
gamepad.handle(bumper_settings, 'xinput', bumper, true, {1, false}, 'players')
assert(not bumper.blocked)
local direction, modifier
gamepad.drain({1, false}, function(d, m) direction, modifier = d, m end)
assert(direction == -1 and modifier == 'players')
gamepad.shutdown()

print('modifier tests passed')
