-- Screen-based target selection extracted from moderncam.lua (SlowCircuit).
local ffi = require('ffi')
local d3d8 = require('d3d8')
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
-- Candidates must lie this far inside the screen edge (in normalised screen units).
local SCREEN_EDGE = 0.975
-- Max yalms between the view matrix's eye and the camera object for the matrices to be trusted.
local EYE_TOLERANCE = 2
-- Last game camera matrices seen at present, as plain tables (cdata goes stale between frames).
local view_matrix, projection_matrix
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
local function copy_matrix(m)
    return {_11 = m._11, _12 = m._12, _13 = m._13, _14 = m._14, _21 = m._21, _22 = m._22, _23 = m._23, _24 = m._24,
        _31 = m._31, _32 = m._32, _33 = m._33, _34 = m._34, _41 = m._41, _42 = m._42, _43 = m._43, _44 = m._44}
end
-- FFXI uses a right-handed projection (_34 = -1); accept either handedness.
local function is_perspective(p)
    return p._11 > 0 and p._22 > 0 and math.abs(math.abs(p._34) - 1) < 1e-3 and math.abs(p._44) < 1e-3
end
local function is_rigid(v)
    for _, row in ipairs({{v._11, v._12, v._13}, {v._21, v._22, v._23}, {v._31, v._32, v._33}}) do
        if math.abs(row[1] * row[1] + row[2] * row[2] + row[3] * row[3] - 1) > 0.01 then return false end
    end
    return math.abs(v._14) < 1e-3 and math.abs(v._24) < 1e-3 and math.abs(v._34) < 1e-3 and math.abs(v._44 - 1) < 1e-3
end
-- Called at present, after the game has drawn the world; keeps the last valid camera pair.
function targeting.capture_view()
    local device = d3d8.get_device()
    if device == nil then return end
    local _, view = device:GetTransform(2) -- D3DTS_VIEW
    local _, projection = device:GetTransform(3) -- D3DTS_PROJECTION
    if view == nil or projection == nil then return end
    view, projection = copy_matrix(view), copy_matrix(projection)
    if is_rigid(view) and is_perspective(projection) then view_matrix, projection_matrix = view, projection end
end
-- Distance between the view matrix's eye (D3D world is X, elevation, Y) and the camera object.
local function eye_offset(camera)
    if view_matrix == nil then return nil end
    local v = view_matrix
    local tx, ty, tz = v._41, v._42, v._43
    local ex = -(tx * v._11 + ty * v._12 + tz * v._13)
    local ey = -(tx * v._21 + ty * v._22 + tz * v._23)
    local ez = -(tx * v._31 + ty * v._32 + tz * v._33)
    local dx, dy, dz = ex - camera.X, ey - camera.Z, ez - camera.Y
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
-- The matrices only describe the game camera when their eye matches it; otherwise they may be
-- stale or left over from other rendering, so callers fall back to the original angular box.
local function camera_matrices(camera)
    local offset = eye_offset(camera)
    if offset == nil or offset > EYE_TOLERANCE then return nil end
    return view_matrix, projection_matrix
end
-- Normalised screen coordinates of an entity position, or nil when it is behind the camera.
local function project(view, projection, x, y, z)
    local wx, wy, wz = x, z, y
    local vx = wx * view._11 + wy * view._21 + wz * view._31 + view._41
    local vy = wx * view._12 + wy * view._22 + wz * view._32 + view._42
    local vz = wx * view._13 + wy * view._23 + wz * view._33 + view._43
    local vw = wx * view._14 + wy * view._24 + wz * view._34 + view._44
    local cw = vx * projection._14 + vy * projection._24 + vz * projection._34 + vw * projection._44
    if cw <= 0.001 then return nil end
    local cx = vx * projection._11 + vy * projection._21 + vz * projection._31 + vw * projection._41
    local cy = vx * projection._12 + vy * projection._22 + vz * projection._32 + vw * projection._42
    return cx / cw, cy / cw
end
-- With the game's matrices the edges follow the real field of view and aspect ratio (widescreen,
-- the aspect addon, camera pitch); sx/sy are the original angular offsets used as the fallback.
local function on_screen(view, projection, x, y, z, sx, sy)
    if view ~= nil then
        local nx, ny = project(view, projection, x, y, z)
        return nx ~= nil and math.abs(nx) <= SCREEN_EDGE and math.abs(ny) <= SCREEN_EDGE
    end
    return sx >= -SCREEN_EDGE and sx <= SCREEN_EDGE and sy >= -SCREEN_EDGE and sy <= SCREEN_EDGE
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
-- Low words of the active party/alliance members' server ids (ClaimStatus keeps the claimer's in its low word).
local function party_claim_ids()
    local party, ids = AshitaCore:GetMemoryManager():GetParty(), {}
    for slot = 0, 17 do
        if party:GetMemberIsActive(slot) ~= 0 then ids[bit.band(party:GetMemberServerId(slot), 0xFFFF)] = true end
    end
    return ids
end
-- 0 for monsters claimed by you or your party/alliance when prioritising combat, otherwise 1.
local function combat_tier(entity, index, claim_ids)
    if claim_ids == nil or bit.band(entity:GetSpawnFlags(index), 0x10) == 0 then return 1 end
    local claimer = bit.band(entity:GetClaimStatus(index), 0xFFFF)
    return (claimer ~= 0 and claim_ids[claimer]) and 0 or 1
end
local function candidates(camera, player, switching, settings, angular_only)
    local result = {}
    local entity = AshitaCore:GetMemoryManager():GetEntity()
    local fx, fy, fz = camera.FocalX - camera.X, camera.FocalY - camera.Y, camera.FocalZ - camera.Z
    local length = math.sqrt(fx * fx + fy * fy + fz * fz)
    if length <= 0 or length ~= length then return result end
    fx, fy, fz = fx / length, fy / length, fz / length
    local rx, ry = -fy, fx
    local view, projection
    if not angular_only then view, projection = camera_matrices(camera) end
    local exclude_player = switching or (settings ~= nil and settings.skipSelf)
    local claim_ids = settings ~= nil and settings.prioritizeCombat and party_claim_ids() or nil
    for index = 1, entity:GetEntityMapSize() - 1 do
        local actor = candidate_actor(entity, index)
        if actor and (not exclude_player or index ~= player.TargetIndex) then
            local x, y, z = entity:GetLocalPositionX(index), entity:GetLocalPositionY(index), entity:GetLocalPositionZ(index)
            local dx, dy, dz = x - camera.X, y - camera.Y, z - camera.Z
            local depth = dx * fx + dy * fy + dz * fz
            -- Reject behind-camera points before division (including zero depth).
            if depth > 0 then
                local sx, sy = -(dx * rx + dy * ry) / depth, -dz / depth
                if on_screen(view, projection, x, y, z, sx, sy) then
                    local target_priority = (depth / 100) + sx + sy + 2
                    local name = entity:GetName(index) or 'Unknown'
                    --print(name .. ", depth=" .. depth .. ", sx=" .. sx .. ", sy=" .. sy .. ", priority=" .. target_priority)
                    if index == player.TargetIndex then
                        target_priority = 1000000
                    end
                    result[#result + 1] = {index = index, actor = actor, x = sx, y = sy, priority = target_priority,
                        tier = combat_tier(entity, index, claim_ids)}
                end
            end
        end
    end
    -- In-combat enemies (tier 0) ahead of everything else, each tier in the original screen order.
    table.sort(result, function(a, b)
        if a.tier ~= b.tier then return a.tier < b.tier end
        return a.priority < b.priority
    end)
    return result
end
local function select_target(direction, camera, player, switching, settings)
    local target = AshitaCore:GetMemoryManager():GetTarget()
    local list = candidates(camera, player, switching, settings)
    -- With nothing selectable, fall back to the player unless switching or the player is skipped.
    local function fallback() if not switching and not settings.skipSelf then target:SetTarget(player.TargetIndex, true) end end
    if #list == 0 then fallback(); return end
    local current, current_order, closest, closest_tier, closest_distance = target:GetTargetIndex(0), 0, 0, 0, 0
    for i, candidate in ipairs(list) do
        if candidate.index == current then current_order = i end
        -- Keep the original center preference (screen center is y = -0.5), within the best tier.
        local distance = math.sqrt((math.abs(candidate.x) + 1) ^ 2 + (math.abs(candidate.y + 0.5) + 1) ^ 3)
        if candidate.index ~= player.TargetIndex and (closest == 0 or candidate.tier < closest_tier
            or (candidate.tier == closest_tier and distance < closest_distance)) then
            closest, closest_tier, closest_distance = i, candidate.tier, distance
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
        -- Native room cycling already omits the player.
        if settings.skipSelf then room_state = nil; return room_cycle ~= nil and room_cycle(direction) == true end
        return cycle_room_with_player(target, player, direction, callback)
    end
    room_state = nil
    select_target(direction, camera, player, targeting.is_switching(), settings)
    return true
end
-- Lines for /bettertarget screencheck: which on-screen test is active and what it changes.
function targeting.screen_report(settings)
    local camera, player = get_camera(), GetPlayerEntity()
    if camera == nil or player == nil then return {'Camera unavailable (first person, zoning or not logged in).'} end
    local lines = {}
    local offset = eye_offset(camera)
    if offset == nil then
        lines[1] = 'Screen edges: original fixed box (no valid game camera matrices captured yet).'
    else
        lines[1] = string.format('Screen edges: %s (view eye %.2f yalms from camera; trusted within %d).',
            offset <= EYE_TOLERANCE and 'game camera matrices' or 'original fixed box', offset, EYE_TOLERANCE)
        lines[2] = string.format('View extent (tan of half-angle): %.3f wide, %.3f tall; original fixed box: %.3f.',
            1 / projection_matrix._11, 1 / projection_matrix._22, SCREEN_EDGE)
    end
    lines[#lines + 1] = string.format('On-screen candidates: %d (original fixed box: %d).',
        #candidates(camera, player, false, settings), #candidates(camera, player, false, settings, true))
    return lines
end
function targeting.zone_in() ready = base_camera ~= nil; room_state = nil end
function targeting.logout() ready = false; room_state = nil end
return targeting
