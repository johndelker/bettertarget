local config = {}
config.defaults = {
    enableTargetCycling = true,
    enableBumperCycling = true, bumperInputMode = 0, bumperLeftButton = 52, bumperRightButton = 53,
    cursorEnabled = true, cursorWidth = 24, cursorHeight = 16, cursorOffset = 4,
    markerRed = 1, markerGreen = 1, markerBlue = 1, markerAlpha = 1,
    borderRed = 0, borderGreen = 0, borderBlue = 0, borderAlpha = 1,
    borderThickness = 2,
}
config.ranges = {cursorWidth = {4, 128}, cursorHeight = {4, 128}, cursorOffset = {0, 10}}
config.ranges.borderThickness = {0, 12}
config.ranges.bumperInputMode = {0, 2}
config.ranges.bumperLeftButton = {48, 175}
config.ranges.bumperRightButton = {48, 175}
for _, prefix in ipairs({'marker', 'border'}) do
    for _, channel in ipairs({'Red', 'Green', 'Blue', 'Alpha'}) do config.ranges[prefix .. channel] = {0, 1} end
end
config.defaults.lockedSameAsStandard = true
for _, prefix in ipairs({'locked', 'switch'}) do
    for _, field in ipairs({'CursorWidth', 'CursorHeight'}) do
        local standard_key = field:gsub('^Cursor', 'cursor')
        config.defaults[prefix .. field] = prefix == 'switch' and config.defaults[standard_key] or 24
        config.ranges[prefix .. field] = {4, 128}
    end
    config.defaults[prefix .. 'CursorOffset'] = config.defaults.cursorOffset; config.ranges[prefix .. 'CursorOffset'] = {0, 10}
    config.defaults[prefix .. 'BorderThickness'] = config.defaults.borderThickness; config.ranges[prefix .. 'BorderThickness'] = {0, 12}
    local marker = prefix == 'locked' and {1, 0.3, 0.2, 1}
        or {config.defaults.markerRed, config.defaults.markerGreen, config.defaults.markerBlue, config.defaults.markerAlpha}
    for i, channel in ipairs({'Red', 'Green', 'Blue', 'Alpha'}) do
        config.defaults[prefix .. 'Marker' .. channel] = marker[i]
        config.defaults[prefix .. 'Border' .. channel] = prefix == 'switch' and config.defaults['border' .. channel]
            or (i == 4 and 1 or 0.1)
        config.ranges[prefix .. 'Marker' .. channel] = {0, 1}
        config.ranges[prefix .. 'Border' .. channel] = {0, 1}
    end
end
local function normalize(key, value)
    local default = config.defaults[key]
    if type(default) == 'boolean' then
        if type(value) == 'boolean' then return value end
        return default
    end
    if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then return default end
    local range = config.ranges[key]
    value=math.max(range[1], math.min(range[2], value))
    if key:find('^bumper') then value=math.floor(value) end
    return value
end
function config.load()
    local manager = AshitaCore:GetConfigurationManager()
    local loaded = manager:Load('bettertarget', 'bettertarget.ini')
    -- Old square sizes seed both dimensions; explicit dimensions win.
    local legacy_size
    if loaded then
        local saved = manager:GetFloat('bettertarget', 'default', 'cursorSize', 0)
        if type(saved) == 'number' and saved >= 4 then legacy_size = normalize('cursorWidth', saved) end
    end
    local settings = {}
    for key, default in pairs(config.defaults) do
        local value = default
        if loaded then
            if type(default) == 'boolean' then value = manager:GetBool('bettertarget', 'default', key, default)
            else
                local fallback = (key == 'cursorWidth' or key == 'cursorHeight') and legacy_size or default
                value = manager:GetFloat('bettertarget', 'default', key, fallback)
            end
        end
        settings[key] = normalize(key, value)
    end
    return settings
end
function config.save(settings)
    local manager = AshitaCore:GetConfigurationManager()
    manager:Delete('bettertarget', 'bettertarget.ini')
    for key in pairs(config.defaults) do
        settings[key] = normalize(key, settings[key])
        manager:SetValue('bettertarget', 'default', key, tostring(settings[key]))
    end
    manager:Save('bettertarget', 'bettertarget.ini')
end
return config
