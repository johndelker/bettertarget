-- Held, pass-through Ashita input modifiers for target cycling filters.
local modifiers = {}
local categories = {'enemies', 'players', 'npcs', 'self'}
local source_ids = {xinput = 1, dinput = 2}
local held, binding, sequence = {}, nil, 0
local trigger_held = {left = false, right = false}

local function keys(category)
    local title = category:sub(1, 1):upper() .. category:sub(2)
    return 'modifier' .. title .. 'Source', 'modifier' .. title .. 'Button'
end

local function valid_category(category)
    for _, value in ipairs(categories) do if value == category then return true end end
    return false
end

function modifiers.begin_bind(category)
    if not valid_category(category) then return false end
    held, sequence, binding = {}, 0, category
    return true
end

function modifiers.cancel_bind()
    binding = nil
end

function modifiers.binding()
    return binding
end

function modifiers.clear()
    held, sequence, binding = {}, 0, nil
    trigger_held.left, trigger_held.right = false, false
end

function modifiers.handle(settings, source, event, save)
    local source_id = source_ids[source]
    if source_id == nil then return false, false end
    local key = source .. ':' .. tostring(event.button)
    -- Ashita reports XInput trigger buttons with analog pressure as state 0..255;
    -- ordinary XInput buttons use 0/1. Treat 255 as a press as well.
    local down = source == 'xinput' and (event.state == 1 or event.state == 255)
        or source == 'dinput' and event.state == 128
    local previous = held[key]
    if not down then
        if previous ~= nil then
            held[key] = nil
            return previous.consumed, false
        end
        return false, false
    end
    if previous ~= nil then return previous.consumed, false end

    if binding ~= nil then
        local category = binding
        binding = nil
        local source_key, button_key = keys(category)
        for _, other in ipairs(categories) do
            if other ~= category then
                local other_source, other_button = keys(other)
                if settings[other_source] == source_id and settings[other_button] == event.button then
                    settings[other_source], settings[other_button] = 0, 0
                end
            end
        end
        settings[source_key], settings[button_key] = source_id, event.button
        held[key] = {consumed = true, captured = true}
        if save then save(settings) end
        return true, true
    end

    local matched = {}
    for _, category in ipairs(categories) do
        local source_key, button_key = keys(category)
        if settings[source_key] == source_id and settings[button_key] == event.button then
            matched[#matched + 1] = category
        end
    end
    if #matched == 0 then return false, false end

    sequence = sequence + 1
    held[key] = {categories = matched, sequence = sequence, consumed = true}
    return true, false
end

-- XInput analog triggers are reported in xinput_state, not xinput_button.
-- Hysteresis avoids generating repeated press/release edges around the threshold.
function modifiers.handle_trigger(settings, source, side, value, save)
    if source ~= 'xinput' or (side ~= 'left' and side ~= 'right') then return false, false, false end
    local was_down = trigger_held[side]
    local is_down = was_down and value > 15 or value >= 30
    if is_down == was_down then return false, false, false end
    trigger_held[side] = is_down
    local button = side == 'left' and 256 or 257
    local consumed, captured = modifiers.handle(settings, source,
        {button = button, state = is_down and 1 or 0}, save)
    return consumed, captured, true
end

function modifiers.active(settings)
    local active, newest = nil, -1
    for _, record in pairs(held) do
        if record.categories and record.sequence >= newest then
            newest = record.sequence
            for _, category in ipairs(record.categories) do
                local source_key, button_key = keys(category)
                if settings[source_key] ~= 0 and settings[button_key] ~= 0 then active = category end
            end
        end
    end
    return active
end

function modifiers.label(settings, category)
    local source_key, button_key = keys(category)
    local source, button = settings[source_key], settings[button_key]
    if source == 1 and (button == 16 or button == 256) then return 'XInput left trigger' end
    if source == 1 and (button == 17 or button == 257) then return 'XInput right trigger' end
    if source == 1 and button ~= 0 then return 'XInput button ' .. tostring(button) end
    if source == 2 and button ~= 0 then return 'DirectInput button ' .. tostring(button) end
    return 'Unbound'
end

function modifiers.matches(entity, index, player_index, category)
    if category == nil then return true end
    if category == 'self' then return index == player_index end
    if index == player_index then return false end
    local entity_type = entity:GetType(index)
    if entity_type == nil then return false end
    local flags = entity:GetSpawnFlags(index) or 0
    local enemy = math.floor(flags / 16) % 2 == 1
    if category == 'enemies' then return enemy end
    if category == 'players' then return entity_type == 0 end
    if category == 'npcs' then return entity_type > 0 and entity_type <= 3 and not enemy end
    return false
end

return modifiers
