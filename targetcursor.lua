local imgui = require('imgui')
local cursor = {}

local function live_target(memory, target, slot)
    local index = target:GetTargetIndex(slot)
    -- The Mog House exit is a native model target with no entity-table index.
    -- Require its active entry and room callback; index zero alone means no target.
    if slot == 0 and index == 0 then
        local callback = target:GetMyroomCallback()
        if callback == nil or callback == 0 or target:GetIsActive(slot) ~= 1 then return false end
        local actor = target:GetActorPointer(slot)
        return actor ~= nil and actor ~= 0
    end
    if not index or index <= 0 or index >= memory:GetEntity():GetEntityMapSize() then return false end
    local actor = memory:GetEntity():GetActorPointer(index)
    return actor ~= nil and actor ~= 0
end
local menu_width, menu_height
local function menu_size()
    if menu_width == nil then
        local manager = AshitaCore:GetConfigurationManager()
        menu_width = tonumber(manager:GetFloat('boot', 'ffxi.registry', '0037', 0)) or 0
        menu_height = tonumber(manager:GetFloat('boot', 'ffxi.registry', '0038', 0)) or 0
    end
    return menu_width, menu_height
end
local function draw_at(style, x, y)
    x, y = tonumber(x), tonumber(y)
    if not x or not y or x ~= x or y ~= y then return end
    local display = imgui.GetIO().DisplaySize
    -- Native anchors are in menu (UI) resolution, which the game scales to the window.
    local menu_w, menu_h = menu_size()
    if menu_w > 0 and menu_h > 0 then x, y = x * display.x / menu_w, y * display.y / menu_h end
    if x < 0 or y < 0 or x >= display.x or y >= display.y then return end
    y = y - (style.offset or 0)
    local width, height = style.width or 18, style.height or 18
    local p1, p2, p3 = {x - width * 0.5, y - height}, {x + width * 0.5, y - height}, {x, y}
    local draw = imgui.GetBackgroundDrawList()
    local marker = imgui.ColorConvertFloat4ToU32(style.markerColor or {1, 1, 1, 1})
    local border = imgui.ColorConvertFloat4ToU32(style.borderColor or {0, 0, 0, 1})
    local thickness = style.borderThickness
    if thickness == nil then thickness = 2 end
    draw:AddTriangleFilled(p1, p2, p3, marker)
    if thickness > 0 then draw:AddTriangle(p1, p2, p3, border, thickness) end
end
function cursor.draw(settings)
    if not settings.enabled then return end
    local player = GetPlayerEntity()
    if not player or player.StatusServer == 4 then return end
    local memory = AshitaCore:GetMemoryManager()
    local target = memory:GetTarget()
    local window = target:GetRawStructureWindow()
    if window == nil then return end
    -- Confirmed target windows may be unloaded for valid Tab/D-pad selections.
    -- In subtargeting, slot 1 retains the current target; slot 0 is the candidate.
    local subtarget = target:GetIsSubTargetActive() ~= 0
    local current_slot = subtarget and 1 or 0
    local style = settings
    if bit.band(target:GetLockedOnFlags(), 1) ~= 0
        and settings.lockedSameAsStandard == false and settings.lockedStyle then
        style = settings.lockedStyle
    end
    if live_target(memory, target, current_slot) then draw_at(style, window.m_AnkX, window.m_AnkY) end
    -- The candidate arrow is shared by Switch Targets and spell/ability selection.
    if subtarget and settings.switchStyle
        and window.m_Sub ~= nil and window.m_Sub ~= 0
        and live_target(memory, target, 0) then
        draw_at(settings.switchStyle, window.m_SubAnkX, window.m_SubAnkY)
    end
end
return cursor
