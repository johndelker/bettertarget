-- Screen-based target selection extracted from moderncam.lua (SlowCircuit).
local ffi = require('ffi')
if not pcall(ffi.typeof, 'struct bettertarget_camera_t') then
    ffi.cdef[[
        struct bettertarget_camera_t {
            uint8_t Unknown0000[0x44];
            float X, Z, Y;
            float FocalX, FocalZ, FocalY;
        };
    ]]
end
local targeting = {}
local base_camera, connected, follow, room_cycle, subtarget_cycle
local ready = false
local room_state
function targeting.initialize(native_room_cycle, native_subtarget_cycle)
    local signature = ashita.memory.find('FFXiMain.dll', 0, '83C40485C974118B116A01FF5218C705', 0, 0)
    if not signature or signature == 0 then error('[bettertarget] Missing camera signature.') end
    local slot = ashita.memory.read_uint32(signature + 0x10)
    if not slot or slot == 0 then error('[bettertarget] Missing camera pointer.') end
    local connection_signature = ashita.memory.find('FFXiMain.dll', 0, '80A0B2000000FBC605????????00', 0x09, 0)
    if not connection_signature or connection_signature == 0 then error('[bettertarget] Missing camera connection signature.') end
    local connection = ashita.memory.read_uint32(connection_signature)
    if not connection or connection == 0 then error('[bettertarget] Missing camera connection pointer.') end
    base_camera, connected = ffi.cast('uint32_t*', slot), ffi.cast('bool*', connection)
    follow = AshitaCore:GetMemoryManager():GetAutoFollow()
    room_cycle = native_room_cycle
    subtarget_cycle = native_subtarget_cycle
    room_state = nil
    ready = true
end
local function get_camera()
    if not ready or not base_camera or not connected or not connected[0]
        or follow:GetIsFirstPersonCamera() ~= 0 then return nil end
    local address = base_camera[0]
    if not address or address == 0 then return nil end
    return ffi.cast('struct bettertarget_camera_t*', address)
end
local function candidate_actor(entity, index, expected_actor)
    if index <= 0 or index >= entity:GetEntityMapSize() then return nil end
    local actor, entity_type = entity:GetActorPointer(index), entity:GetType(index)
    if actor == nil or actor == 0 or entity_type == nil or entity_type > 3
        or (expected_actor and actor ~= expected_actor) then return nil end
    local render_flags = entity:GetRenderFlags0(index)
    local name_flags = entity:GetRenderFlags2(index)
    -- Native cycling rejects Render.Flags2 bit 0x10 even while the actor exists.
    if render_flags == nil or name_flags == nil
        or bit.band(render_flags, 0x4000) ~= 0
        or bit.band(name_flags, 0x10) ~= 0 then return nil end
    -- A defeated monster may retain its actor/position until its corpse despawns.
    -- HP is not an eligibility gate for players, NPCs or objects.
    if bit.band(entity:GetSpawnFlags(index), 0x10) ~= 0 then
        if bit.band(render_flags, 0x200) == 0 then return nil end
        local hp = entity:GetHPPercent(index)
        if hp == nil or hp <= 0 then return nil end
    end
    if entity:GetActorPointer(index) ~= actor then return nil end
    return actor
end
local function candidates(camera, player, switching)
    local result = {}
    local entity = AshitaCore:GetMemoryManager():GetEntity()
    local fx, fy, fz = camera.FocalX - camera.X, camera.FocalY - camera.Y, camera.FocalZ - camera.Z
    local length = math.sqrt(fx * fx + fy * fy + fz * fz)
    if length <= 0 or length ~= length then return result end
    fx, fy, fz = fx / length, fy / length, fz / length
    local rx, ry = -fy, fx
    for index = 1, entity:GetEntityMapSize() - 1 do
        local actor = candidate_actor(entity, index)
        if actor and (not switching or index ~= player.TargetIndex) then
            local x, y, z = entity:GetLocalPositionX(index), entity:GetLocalPositionY(index), entity:GetLocalPositionZ(index)
            local dx, dy, dz = x - camera.X, y - camera.Y, z - camera.Z
            local depth = dx * fx + dy * fy + dz * fz
            -- Reject behind-camera points before division (including zero depth).
            if depth > 0 then
                local sx, sy = -(dx * rx + dy * ry) / depth, -dz / depth
                if sx >= -0.975 and sx <= 0.975 and sy >= -0.975 and sy <= 0.975 then
                    local target_priority = (depth / 100) + sx + sy + 2
                    local name = entity:GetName(index) or 'Unknown'
                    --print(name .. ", depth=" .. depth .. ", sx=" .. sx .. ", sy=" .. sy .. ", priority=" .. target_priority)
                    if index == player.TargetIndex then
                        target_priority = 1000000
                    end
                    result[#result + 1] = {index = index, actor = actor, x = sx, y = sy, priority = target_priority}
                end
            end
        end
    end
    table.sort(result, function(a, b) return a.priority < b.priority end)
    return result
end
local function select_target(direction, camera, player, switching)
    local target = AshitaCore:GetMemoryManager():GetTarget()
    local list = candidates(camera, player, switching)
    local function fallback() if not switching then target:SetTarget(player.TargetIndex, true) end end
    if #list == 0 then fallback(); return end
    local current, current_order, closest, closest_distance = target:GetTargetIndex(0), 0, 0, 0
    for i, candidate in ipairs(list) do
        if candidate.index == current then current_order = i end
        -- Keep the original center preference (screen center is y = -0.5).
        local distance = math.sqrt((math.abs(candidate.x) + 1) ^ 2 + (math.abs(candidate.y + 0.5) + 1) ^ 3)
        if candidate.index ~= player.TargetIndex and (closest == 0 or distance < closest_distance) then 
            closest, closest_distance = i, distance 
        end
    end
    local next_order = closest
    if current_order > 0 then
        next_order = current_order + direction
        if next_order < 1 then next_order = #list
        elseif next_order > #list then next_order = 1 end
    end
    if next_order == 0 then fallback(); return end
    local entity = AshitaCore:GetMemoryManager():GetEntity()
    for _ = 1, #list do
        local candidate = list[next_order]
        if candidate_actor(entity, candidate.index, candidate.actor) then
            target:SetTarget(candidate.index, true)
            return
        end
        next_order = ((next_order - 1 + direction) % #list) + 1
    end
    fallback()
end
function targeting.is_switching()
    local player = GetPlayerEntity()
    local target = AshitaCore:GetMemoryManager():GetTarget()
    return player ~= nil and player.StatusServer == 1 and target:GetIsSubTargetActive() ~= 0
        and target:GetIsMenuOpen() ~= 0 and target:GetActionType() == 0
        and bit.band(target:GetSubTargetFlags(), 0x10) ~= 0
end
function targeting.can_cycle(settings, source)
    local player = GetPlayerEntity()
    local target = AshitaCore:GetMemoryManager():GetTarget()
    -- Preserve native lock-on: ordinary cycling must not select a new target.
    -- Subtarget selection (including Switch Targets) keeps its existing rules.
    if target:GetIsSubTargetActive() == 0 and bit.band(target:GetLockedOnFlags(), 1) ~= 0 then return false end
    local enabled=(source=='bumper' and settings.enableBumperCycling)
        or (source~='bumper' and settings.enableTargetCycling)
    return enabled and player ~= nil and player.StatusServer ~= 4 and get_camera() ~= nil
        and (target:GetIsSubTargetActive() == 0 or targeting.is_switching()
            or (source == 'bumper' and subtarget_cycle ~= nil))
end
local function room_target_key(target, entity)
    local index = target:GetTargetIndex(0)
    if index == 0 then
        local actor = target:GetActorPointer(0)
        if target:GetIsActive(0) == 1 and actor ~= nil and actor ~= 0 then return 'model:' .. actor end
    elseif index and index > 0 and index < entity:GetEntityMapSize() then
        local actor = entity:GetActorPointer(index)
        if actor ~= nil and actor ~= 0 then return 'entity:' .. index .. ':' .. actor end
    end
end
local function cycle_room_with_player(target, player, direction, callback)
    local entity = AshitaCore:GetMemoryManager():GetEntity()
    local current = room_target_key(target, entity)
    if not room_state or room_state.direction ~= direction or room_state.callback ~= callback
        or room_state.player ~= player.TargetIndex or room_state.last ~= current then
        room_state = {direction = direction, callback = callback, player = player.TargetIndex, seen = {}}
        if current and target:GetTargetIndex(0) ~= player.TargetIndex then room_state.seen[current] = true end
    end
    if not room_cycle or room_cycle(direction) ~= true then room_state = nil; return false end
    local next_key = room_target_key(target, entity)
    -- Native room cycling includes model doors but omits the player. Insert the
    -- player when the native sequence wraps, without retaining stale target pointers.
    if (not next_key or room_state.seen[next_key]) and candidate_actor(entity, player.TargetIndex) then
        target:SetTarget(player.TargetIndex, true)
        room_state = nil
    else
        if next_key then room_state.seen[next_key] = true end
        room_state.last = next_key
    end
    return true
end
function targeting.cycle(settings, direction, source)
    if direction ~= -1 and direction ~= 1 then return false end
    if not targeting.can_cycle(settings, source) then return false end
    local player, camera = GetPlayerEntity(), get_camera()
    if player == nil or player.StatusServer == 4 or camera == nil then return false end
    -- Room doors are model targets, not entity indices accepted by SetTarget.
    -- Use the client's model-aware cycle instead of silently dropping the door.
    local target = AshitaCore:GetMemoryManager():GetTarget()
    if target:GetIsSubTargetActive() ~= 0 and not targeting.is_switching() then
        -- The client applies each spell/ability's valid-target rules.
        return source == 'bumper' and subtarget_cycle ~= nil and subtarget_cycle(direction) == true
    end
    local callback = target:GetMyroomCallback()
    if callback ~= nil and callback ~= 0 and not targeting.is_switching() then
        return cycle_room_with_player(target, player, direction, callback)
    end
    room_state = nil
    select_target(direction, camera, player, targeting.is_switching())
    return true
end
function targeting.zone_in() ready = base_camera ~= nil; room_state = nil end
function targeting.logout() ready = false; room_state = nil end
return targeting
