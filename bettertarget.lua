addon.name = 'bettertarget'
addon.author = 'SlowCircuit, atom0s'
addon.version = '1.6.16'
addon.desc = 'Screen-based native target cycling and a configurable native-anchored target cursor.'

require('common')
local ffi = require('ffi')
if not pcall(ffi.typeof, 'bettertarget_xinput_state_t*') then
    ffi.cdef[[
        typedef struct bettertarget_xinput_gamepad_t {
            uint16_t wButtons;
            uint8_t bLeftTrigger;
            uint8_t bRightTrigger;
            int16_t sThumbLX;
            int16_t sThumbLY;
            int16_t sThumbRX;
            int16_t sThumbRY;
        } bettertarget_xinput_gamepad_t;
        typedef struct bettertarget_xinput_state_t {
            uint32_t dwPacketNumber;
            bettertarget_xinput_gamepad_t Gamepad;
        } bettertarget_xinput_state_t;
    ]]
end
local imgui = require('imgui')
local directory = debug.getinfo(1, 'S').source:sub(2):match('(.*[\\/])') or './'
local config = dofile(directory .. 'config.lua')
local targeting = dofile(directory .. 'targeting.lua')
local actions = dofile(directory .. 'native_actions.lua')
local cursor = dofile(directory .. 'targetcursor.lua')
local gamepad = dofile(directory .. 'gamepad.lua')
local modifiers = dofile(directory .. 'modifiers.lua')
local settings, loaded, ready = nil, false, false
local native_available = false
local function bumper_context()
    if not loaded or not ready or not targeting.can_cycle(settings, 'bumper') then return nil end
    local target=AshitaCore:GetMemoryManager():GetTarget()
    local switching=targeting.is_switching()
    local subtarget=target:GetIsSubTargetActive()~=0
    if subtarget and not switching and not native_available then return nil end
    if not subtarget and (target:GetIsMenuOpen()~=0 or target:GetActionCallback()~=0) then return nil end
    local player=GetPlayerEntity()
    return {player.TargetIndex, switching, target:GetIsSubTargetActive(), target:GetIsMenuOpen(),
        target:GetActionType(), target:GetSubTargetFlags(), target:GetActionCallback(),
        subtarget and target:GetTargetIndex(1) or 0}
end
local function sync_actions()
    actions.set_enabled(loaded and ready and targeting.can_cycle(settings, nil, modifiers.active(settings)), targeting.is_switching())
end
local menu_open = {false}
local channels = {'Red', 'Green', 'Blue', 'Alpha'}
local function color(prefix)
    return {settings[prefix .. 'Red'], settings[prefix .. 'Green'], settings[prefix .. 'Blue'], settings[prefix .. 'Alpha']}
end
local function color_picker(label, prefix)
    local value = color(prefix)
    if imgui.ColorEdit4(label, value, ImGuiColorEditFlags_AlphaBar) then
        for i, channel in ipairs(channels) do settings[prefix .. channel] = value[i] end
        config.save(settings)
    end
end

local function checkbox(label, key)
    local value = {settings[key]}
    if imgui.Checkbox(label, value) then
        settings[key] = value[1]; config.save(settings); sync_actions()
        if key=='enableBumperCycling' or key=='enableTargetCycling' then gamepad.clear_pending() end
    end
end
local function slider(label, key)
    local value, range = {settings[key]}, config.ranges[key]
    imgui.SetNextItemWidth(240)
    local format = key:lower():find('borderthickness', 1, true) and '%.1f' or '%.0f'
    if imgui.SliderFloat(label, value, range[1], range[2], format, ImGuiSliderFlags_AlwaysClamp) then
        settings[key] = value[1]
        if key:find('^bumper') then settings[key]=math.floor(value[1]);gamepad.clear_pending() end
    end
    if imgui.IsItemDeactivatedAfterEdit() then config.save(settings) end
end
local function appearance(prefix)
    local base = prefix == ''
    return {width = settings[base and 'cursorWidth' or prefix .. 'CursorWidth'],
        height = settings[base and 'cursorHeight' or prefix .. 'CursorHeight'],
        offset = settings[base and 'cursorOffset' or prefix .. 'CursorOffset'],
        markerColor = color(base and 'marker' or prefix .. 'Marker'),
        borderColor = color(base and 'border' or prefix .. 'Border'),
        borderThickness = settings[base and 'borderThickness' or prefix .. 'BorderThickness']}
end
local function appearance_controls(prefix, label)
    local base = prefix == ''
    slider(label .. 'Cursor Width', base and 'cursorWidth' or prefix .. 'CursorWidth')
    slider(label .. 'Cursor Height', base and 'cursorHeight' or prefix .. 'CursorHeight')
    slider(label .. 'Vertical Offset', base and 'cursorOffset' or prefix .. 'CursorOffset')
    slider(label .. 'Border Thickness', base and 'borderThickness' or prefix .. 'BorderThickness')
    color_picker(label .. 'Cursor Color', base and 'marker' or prefix .. 'Marker')
    color_picker(label .. 'Border Color', base and 'border' or prefix .. 'Border')
end
local function draw_menu()
    imgui.SetNextWindowSize({540, 620}, ImGuiCond_Once)
    if imgui.Begin('Better Target', menu_open) then
        if imgui.BeginTabBar('BetterTargetSettings') then
            if imgui.BeginTabItem('Target Cycling') then
                checkbox('Improved Target Cycling', 'enableTargetCycling')
                checkbox('Bumpers Change Targets', 'enableBumperCycling')
                if settings.enableBumperCycling then
                    local labels={'Auto (Both)','XInput','DirectInput'}
                    if imgui.BeginCombo('Bumper Input',labels[settings.bumperInputMode+1]) then
                        for index,label in ipairs(labels) do
                            if imgui.Selectable(label,settings.bumperInputMode==index-1) then
                                settings.bumperInputMode=index-1;config.save(settings);gamepad.clear_pending()
                            end
                        end
                        imgui.EndCombo()
                    end
                    if settings.bumperInputMode~=1 then
                        slider('DirectInput Left Bumper', 'bumperLeftButton')
                        slider('DirectInput Right Bumper', 'bumperRightButton')
                    end
                end
                checkbox('Prioritize Enemies In Combat', 'prioritizeCombat')
                imgui.TextDisabled('Enemies claimed by you or your party/alliance come first.')
                checkbox('Skip Myself When Cycling', 'skipSelf')
                imgui.Spacing(); imgui.Text('Modifiers'); imgui.Separator()
                imgui.TextDisabled('Hold a binding while cycling. Most recently pressed held binding wins.')
                for _, item in ipairs({
                    {'enemies', 'Target Enemies'}, {'players', 'Target Players'},
                    {'npcs', 'Target NPCs/Objects'}, {'self', 'Target Self'},
                }) do
                    local category, label = item[1], item[2]
                    imgui.Text(label .. ': ' .. modifiers.label(settings, category))
                    if modifiers.binding() == category then imgui.TextDisabled('Press a gamepad button or analog trigger to bind...') end
                    if imgui.Button('Bind##modifier_' .. category) then
                        modifiers.begin_bind(category)
                        gamepad.clear_pending()
                    end
                    imgui.SameLine()
                    if imgui.Button('Clear##modifier_' .. category) then
                        settings['modifier' .. category:sub(1, 1):upper() .. category:sub(2) .. 'Source'] = 0
                        settings['modifier' .. category:sub(1, 1):upper() .. category:sub(2) .. 'Button'] = 0
                        modifiers.clear(); gamepad.clear_pending(); config.save(settings); sync_actions()
                    end
                end
                if not native_available then imgui.TextDisabled('Without native hooks, filters only apply to BetterTarget bumper cycling.') end
                imgui.EndTabItem()
            end
            if imgui.BeginTabItem('Target Cursor') then
                checkbox('Replace Target Cursor', 'cursorEnabled')
                imgui.TextDisabled('Custom cursor (works even when target frame is hidden)')
                imgui.Spacing();imgui.Text('Standard');imgui.Separator()
                appearance_controls('', '')
                imgui.Spacing();imgui.Text('Locked-On');imgui.Separator()
                checkbox('Same as Standard', 'lockedSameAsStandard')
                if not settings.lockedSameAsStandard then appearance_controls('locked', 'Locked-On ') end
                imgui.Spacing();imgui.Text('Switching / Spell and Ability Selection');imgui.Separator()
                appearance_controls('switch', 'Switching ')
                imgui.EndTabItem()
            end
            imgui.EndTabBar()
        end
    end
    imgui.End()
end
local function help()
    print('[bettertarget] /bettertarget: configuration window')
    print('[bettertarget] /bettertarget cycling on|off; bumpers on|off; cursor on|off; combat on|off; skipself on|off')
    print('[bettertarget] /bettertarget cursor width|height|size <4-128>; cursor offset <0-10>; help')
    print('[bettertarget] /bettertarget screencheck: show how on-screen targets are detected')
end
ashita.events.register('load', 'bettertarget_load', function()
    settings = config.load()
    targeting.initialize(actions.cycle_room, actions.cycle_subtarget, modifiers.matches)
    native_available = actions.initialize()
    if not native_available then print('[bettertarget] Native target action hook unavailable; using normal game targeting.') end
    loaded, ready = true, true
    sync_actions()
end)
ashita.events.register('command', 'bettertarget_command', function(e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/bettertarget' then return end
    e.blocked = true
    if #args == 1 then menu_open[1] = not menu_open[1]; return end
    for i = 2, #args do args[i] = args[i]:lower() end
    if #args == 2 and args[2] == 'help' then help(); return end
    if not loaded then return end
    if #args == 2 and args[2] == 'screencheck' then
        for _, line in ipairs(targeting.screen_report(settings)) do print('[bettertarget] ' .. line) end
        return
    end
    if #args == 3 then
        local key = ({cursor = 'cursorEnabled', cycling = 'enableTargetCycling', bumpers = 'enableBumperCycling',
            combat = 'prioritizeCombat', skipself = 'skipSelf'})[args[2]]
        if key and (args[3] == 'on' or args[3] == 'off') then
            settings[key] = args[3] == 'on'; config.save(settings); sync_actions()
            if key=='enableBumperCycling' or key=='enableTargetCycling' then gamepad.clear_pending() end
            return
        end
    end
    if #args == 4 and args[2] == 'cursor' then
        local key = ({width = 'cursorWidth', height = 'cursorHeight', size = 'cursorWidth', offset = 'cursorOffset'})[args[3]]
        local value = tonumber(args[4])
        if key and value and value == value then
            local range = config.ranges[key]
            if value >= range[1] and value <= range[2] then
                settings[key] = value
                if args[3] == 'size' then settings.cursorHeight = value end
                config.save(settings); return
            end
        end
    end
    print('[bettertarget] Invalid command.'); help()
end)
for _,source in ipairs({'xinput','dinput'}) do
    local backend=source
    ashita.events.register(backend..'_button','bettertarget_'..backend..'_bumpers',function(e)
        if not loaded then return end
        local consumed, captured = modifiers.handle(settings, backend, e, config.save)
        if captured then
            sync_actions()
            return
        end
        local context=bumper_context()
        gamepad.handle(settings,backend,e,context~=nil,context,modifiers.active(settings))
        if consumed then
            sync_actions()
        end
    end)
end
ashita.events.register('xinput_state', 'bettertarget_xinput_triggers', function(e)
    if not loaded or not e.state then return end
    local ok, state = pcall(function() return ffi.cast('bettertarget_xinput_state_t*', e.state) end)
    if not ok or state == nil then return end
    local left, right
    ok = pcall(function()
        left, right = tonumber(state.Gamepad.bLeftTrigger), tonumber(state.Gamepad.bRightTrigger)
    end)
    if not ok or left == nil or right == nil then return end

    local _, _, left_changed = modifiers.handle_trigger(settings, 'xinput', 'left', left, config.save)
    local _, _, right_changed = modifiers.handle_trigger(settings, 'xinput', 'right', right, config.save)
    if left_changed or right_changed then sync_actions() end
end)
ashita.events.register('d3d_beginscene', 'bettertarget_native_actions', function(is_backbuffer)
    if not is_backbuffer or not loaded then return end
    sync_actions()
    gamepad.drain(bumper_context(),function(direction, modifier)
        local ok,message=pcall(targeting.cycle,settings,direction,'bumper',modifier)
        if not ok then actions.shutdown();error(message,0) end
    end)
    actions.drain(function(direction) targeting.cycle(settings, direction, nil, modifiers.active(settings)) end)
end)
ashita.events.register('d3d_present', 'bettertarget_present', function()
    if not loaded then return end
    targeting.capture_view()
    if ready and GetPlayerEntity() ~= nil then
        local style = appearance('')
        style.enabled, style.lockedSameAsStandard = settings.cursorEnabled, settings.lockedSameAsStandard
        style.lockedStyle, style.switchStyle = appearance('locked'), appearance('switch')
        cursor.draw(style)
    end
    if menu_open[1] then draw_menu() end
end)
ashita.events.register('packet_in', 'bettertarget_packet_in', function(e)
    if e.id == 0x00A then ready = loaded; targeting.zone_in();gamepad.clear_pending();modifiers.clear()
    elseif e.id == 0x00B then ready = false; targeting.logout();gamepad.clear_pending();modifiers.clear() end -- Zone Out; 0x04B is Delivery Box.
    if loaded then sync_actions() end
end)
ashita.events.register('unload', 'bettertarget_unload', function()
    loaded, ready = false, false
    targeting.logout()
    gamepad.shutdown()
    modifiers.clear()
    actions.shutdown()
    if settings then config.save(settings) end
end)
