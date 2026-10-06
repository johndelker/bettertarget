-- Capture resolved native target-cycle actions, without reading control inputs.
-- The x86 bridge queues intent; Lua runs screen selection at the next scene start.
local ffi = require('ffi')
ffi.cdef[[int __stdcall FlushInstructionCache(void* process, const void* address, size_t size);]]
if not pcall(ffi.typeof, 'struct bettertarget_memory_region_t') then
    ffi.cdef[[struct bettertarget_memory_region_t {
        void* BaseAddress; void* AllocationBase; uint32_t AllocationProtect;
        size_t RegionSize; uint32_t State; uint32_t Protect; uint32_t Type;
    };]]
end
ffi.cdef[[size_t __stdcall VirtualQuery(const void* address, void* information, size_t length);]]
local kernel32 = ffi.load('kernel32')
local actions = {}
local pattern = '568BF18B4C2408578A465C33FFA80374228A465984C0751B8B86C400000085C075118BC148740C83E80474075FB0015EC204008D41FF83F81B0F87????????FF2485????????'
local owner_pattern = '8B0D????????83C40885C974??85C074??6A006A0150E8'
local allocation, sites, enabled, installed, owner_slot, dispatcher = nil, {}, false, false, nil, nil
local function same(p, expected)
    local actual = ashita.memory.read_array(p, #expected)
    if not actual then return false end
    for i,v in ipairs(expected) do if actual[i] ~= v then return false end end
    return true
end
local function write(p, bytes, executable)
    local ok, previous = ashita.memory.unprotect(p, #bytes)
    if not ok then return false end
    ashita.memory.write_array(p, bytes)
    local flushed = kernel32.FlushInstructionCache(ffi.cast('void*', -1), ffi.cast('const void*', p), #bytes)
    local protected = ashita.memory.protect(p, #bytes, executable and 0x40 or previous)
    return flushed ~= 0 and protected and same(p, bytes)
end
local function relative(opcode, source, destination)
    local bytes, value = {opcode}, (destination - source - 5) % 4294967296
    for _=1,4 do bytes[#bytes+1]=value%256; value=math.floor(value/256) end
    return bytes
end
local function make_bridge(address, destination, owner_slot, legacy)
    local bytes, branches = {}, {}
    local function emit(...) for _,v in ipairs({...}) do bytes[#bytes+1]=v end end
    local function u32(v)
        v=v%4294967296
        for _=1,4 do emit(v%256); v=math.floor(v/256) end
    end
    local function fallback(op)
        if legacy then emit(op,0);branches[#branches+1]=#bytes
        else emit(0x0F,op+0x10,0,0,0,0);branches[#branches+1]=#bytes-3 end
    end
    emit(0x9C,0x50,0x52)                         -- preserve flags, eax and edx
    emit(0x83,0x3D);u32(allocation);emit(0);fallback(0x74)
    emit(0xA1);u32(owner_slot)                   -- only the main target context
    emit(0x85,0xC0);fallback(0x74)
    emit(0x39,0xC1);fallback(0x75)
    if legacy then
        emit(0x80,0x79,0x52,0);fallback(0x75)    -- IsSubTargetActive
        emit(0x80,0x79,0x74,0);fallback(0x75)    -- IsMenuOpen
        emit(0x80,0x79,0x59,0);fallback(0x75)
        emit(0x83,0xB9,0xC4,0,0,0,0);fallback(0x75)
    else
        -- Compare the approved selection context captured by Lua. A menu/action
        -- transition before the next scene falls through to the native helper.
        for i, offset in ipairs({0x52,0x74,0x59,0x76}) do
            emit(0xA0);u32(allocation+268+(i-1)*4)
            emit(0x38,0x41,offset);fallback(0x75)
        end
        emit(0x8B,0x81,0xC4,0,0,0,0x3B,0x05);u32(allocation+284);fallback(0x75)
    end
    emit(0x8B,0x15);u32(allocation+8)            -- producer index
    emit(0x8B,0xC2,0x40,0x83,0xE0,31)           -- next index, modulo 32
    emit(0x3B,0x05);u32(allocation+4);fallback(0x74) -- full: native fallback
    emit(0x50,0x8B,0x44,0x24,20)                -- saved next index; native direction argument
    emit(0xD1,0xE0,0x48)                        -- 0 -> -1 (left), 1 -> +1 (right)
    if not legacy then emit(0x80,0x79,0x52,0,0x74,2,0xD1,0xE0) end -- +/-2 tags combat selection
    emit(0x89,0x04,0x95);u32(allocation+12)      -- publish direction before producer index
    emit(0x89,0x0C,0x95);u32(allocation+140)     -- retain originating target owner
    emit(0x58,0xA3);u32(allocation+8)
    emit(0x5A,0x58,0x9D,0x33,0xC0,0xC2,4,0)   -- consume action; no native target change
    local native=#bytes
    emit(0x5A,0x58,0x9D)
    for _,v in ipairs(relative(0xE9,address+#bytes,destination)) do emit(v) end
    for _,offset in ipairs(branches) do
        if legacy then
            assert(native-offset<128, 'native target bridge exceeds short branch')
            bytes[offset]=native-offset
        else
            local value=native-offset-3
            for n=0,3 do bytes[offset+n]=value%256;value=math.floor(value/256) end
        end
    end
    assert(#bytes<=(legacy and 192 or 256), 'native target bridge exceeds allocation')
    return bytes
end
local function unique(p)
    local first=ashita.memory.find('FFXiMain.dll',0,p,0,0)
    local second=ashita.memory.find('FFXiMain.dll',0,p,0,1)
    if first and first~=0 and (not second or second==0) then return first end
end
local function readable(address, length)
    local region = ffi.new('struct bettertarget_memory_region_t[1]')
    local finish = address + length
    while address < finish do
        if kernel32.VirtualQuery(ffi.cast('const void*', address), region, ffi.sizeof(region[0])) == 0 then return false end
        local protection = tonumber(region[0].Protect)
        if region[0].State ~= 0x1000 or protection % 256 == 0 or protection % 256 == 1
            or math.floor(protection / 256) % 2 ~= 0 then return false end
        local first = tonumber(ffi.cast('uintptr_t', region[0].BaseAddress))
        local last = first + tonumber(region[0].RegionSize)
        if address < first or last <= address then return false end
        address = last
    end
    return true
end
local function recover_bridges(found, entry)
    -- Automatic addon removal after a callback error may omit the unload event.
    -- Adopt only four exact copies of our bridge, including their owner and
    -- native fallback destinations. Unknown or partially modified hooks remain untouched.
    local first = found[1].destination
    if not readable(first, 192) or not same(first, {0x9C, 0x50, 0x52, 0x83, 0x3D}) then return false end
    local previous = ashita.memory.read_uint32(first + 5)
    if not previous or previous == 0 or not readable(previous, 1536) then return false end
    allocation = previous -- only used to reconstruct expected bytes until validation completes
    local legacy=first==previous+384
    local stride=legacy and 192 or 256
    for i, site in ipairs(found) do
        local cave = previous + stride * (i + 1)
        if site.destination ~= cave or not readable(cave, stride) then allocation=nil;return false end
        local original, old
        do
            local length = #make_bridge(cave, entry + 1, owner_slot, legacy)
            local destination = (cave + length + ashita.memory.read_uint32(cave + length - 4)) % 4294967296
            if destination > entry and destination <= entry + 0x1000
                and same(cave, make_bridge(cave, destination, owner_slot, legacy)) then original,old=destination,legacy end
        end
        if not original then allocation=nil;return false end
        site.legacy = old
        site.original = relative(0xE8, site.address, original)
        site.patch = relative(0xE8, site.address, cave)
        site.destination = original
    end
    if found[1].destination ~= found[2].destination or found[3].destination ~= found[4].destination
        or ashita.memory.read_uint32(previous) > 1 or ashita.memory.read_uint32(previous+4) >= 32
        or ashita.memory.read_uint32(previous+8) >= 32 then allocation=nil;return false end
    sites, installed = found, true
    actions.set_enabled(false) -- clear stale queued input before the new instance resumes
    for _,site in ipairs(found) do
        if site.legacy then actions.shutdown();return allocation==nil and actions.initialize() end
    end
    return true
end
function actions.initialize()
    if allocation then return installed end
    local entry = unique(pattern)
    if not entry then return false end
    dispatcher = entry
    local table_address=ashita.memory.read_uint32(entry+0x42)
    -- The client has several target command wrappers. They must all identify
    -- the same owner slot; differing references are an ambiguous locator.
    owner_slot=nil
    for usage=0,16 do
        local owner=ashita.memory.find('FFXiMain.dll',0,owner_pattern,0,usage)
        if not owner or owner==0 then break end
        if usage==16 then return false end
        local slot=ashita.memory.read_uint32(owner+2)
        if not slot or slot==0 or (owner_slot and owner_slot~=slot) then return false end
        owner_slot=slot
    end
    if not table_address or table_address==0 or not owner_slot or owner_slot==0 then return false end
    local found={}
    -- Left/right, then their wraparound counterparts. Other logical actions are untouched.
    for i,action in ipairs({3,4,15,16}) do
        local branch=ashita.memory.read_uint32(table_address+(action-1)*4)
        if not branch or branch<=entry or branch>entry+0x400 then return false end
        local argument=(i==2 or i==3) and 1 or 0
        if not same(branch,{0x6A,argument,0x8B,0xCE,0xE8})
            or not same(branch+9,{0x8B,0xF8}) then return false end
        local p=branch+4
        local destination=(p+5+ashita.memory.read_uint32(p+1))%4294967296
        found[i]={address=p, original=ashita.memory.read_array(p,5), destination=destination}
    end
    local native = true
    for _,site in ipairs(found) do
        if site.destination<=entry or site.destination>entry+0x1000 then native=false end
    end
    if not native then return recover_bridges(found, entry) end
    if found[1].destination~=found[2].destination or found[3].destination~=found[4].destination then return false end
    allocation=ashita.memory.alloc(1536)
    if not allocation or allocation==0 then allocation=nil; return false end
    sites=found
    ashita.memory.write_uint32(allocation,0)
    ashita.memory.write_uint32(allocation+4,0)
    ashita.memory.write_uint32(allocation+8,0)
    for i,site in ipairs(sites) do
        local cave=allocation+256*(i+1)
        site.patch=relative(0xE8,site.address,cave)
        if not write(cave,make_bridge(cave,site.destination,owner_slot),true) then actions.shutdown();return false end
    end
    for _,site in ipairs(sites) do
        if not same(site.address,site.original) or not write(site.address,site.patch) then actions.shutdown();return false end
    end
    installed=true
    return true
end
function actions.set_enabled(value, switching)
    if not allocation then return false end
    enabled=installed and value==true
    if enabled then
        local owner=ashita.memory.read_uint32(owner_slot)
        local offsets={0x52,0x74,0x59,0x76,0xC4}
        for i,offset in ipairs(offsets) do
            local expected=0
            if owner~=0 and (switching or offset==0x76) then
                expected=offset==0xC4 and ashita.memory.read_uint32(owner+offset) or ashita.memory.read_uint8(owner+offset)
            end
            local p=allocation+268+(i-1)*4
            if ashita.memory.read_uint32(p)~=expected then
                ashita.memory.write_uint32(allocation,0)
                ashita.memory.write_uint32(allocation+4,ashita.memory.read_uint32(allocation+8))
                ashita.memory.write_uint32(p,expected)
            end
        end
    end
    ashita.memory.write_uint32(allocation,enabled and 1 or 0)
    if not enabled then
        ashita.memory.write_uint32(allocation+4,ashita.memory.read_uint32(allocation+8))
    end
    return installed
end
local function dispatch_cycle(owner, direction)
    -- Invoke the resolved logical action, including its model-target selection.
    -- Temporarily bypass our bridge so this does not enqueue the same intent again.
    -- Preserve queued events and the previous enable flag (bumpers work independently).
    local previous = ashita.memory.read_uint32(allocation)
    ashita.memory.write_uint32(allocation, 0)
    local ok, message = pcall(function()
        local dispatch = ffi.cast('void (__thiscall*)(void*, uint32_t)', dispatcher)
        dispatch(ffi.cast('void*', owner), direction == 1 and 15 or 16)
    end)
    ashita.memory.write_uint32(allocation, previous)
    if not ok then error(message, 0) end
    return true
end
function actions.cycle_room(direction)
    if (direction ~= -1 and direction ~= 1) or not installed or not allocation or not dispatcher then return false end
    local owner = ashita.memory.read_uint32(owner_slot)
    if owner == nil or owner == 0 or ashita.memory.read_uint32(owner + 0xCC) == 0
        or ashita.memory.read_uint8(owner + 0x52) ~= 0
        or ashita.memory.read_uint8(owner + 0x74) ~= 0
        or ashita.memory.read_uint32(owner + 0xC4) ~= 0 then return false end
    return dispatch_cycle(owner, direction)
end
function actions.cycle_subtarget(direction)
    if (direction ~= -1 and direction ~= 1) or not installed or not allocation or not dispatcher then return false end
    local owner = ashita.memory.read_uint32(owner_slot)
    if owner == nil or owner == 0 or ashita.memory.read_uint8(owner + 0x52) == 0 then return false end
    return dispatch_cycle(owner, direction)
end
function actions.drain(callback)
    if not allocation or not enabled then return end
    -- Bounded drain: newly generated events wait until the following scene.
    local read_index=ashita.memory.read_uint32(allocation+4)
    local write_index=ashita.memory.read_uint32(allocation+8)
    if read_index>=32 or write_index>=32 then actions.set_enabled(false);return end
    while read_index~=write_index do
        local direction=ashita.memory.read_uint32(allocation+12+read_index*4)
        local owner=ashita.memory.read_uint32(allocation+140+read_index*4)
        read_index=(read_index+1)%32
        ashita.memory.write_uint32(allocation+4,read_index)
        local current_owner=ashita.memory.read_uint32(owner_slot)
        local context=owner~=0 and owner==current_owner
        if context then
            for i,offset in ipairs({0x52,0x74,0x59,0x76,0xC4}) do
                local actual=offset==0xC4 and ashita.memory.read_uint32(owner+offset) or ashita.memory.read_uint8(owner+offset)
                if actual~=ashita.memory.read_uint32(allocation+268+(i-1)*4) then context=false;break end
            end
        end
        local subtarget=context and ashita.memory.read_uint8(owner+0x52)~=0
        if context and ((subtarget and (direction==2 or direction==4294967294))
            or (not subtarget and (direction==1 or direction==4294967295))) then
            local decoded = (direction==1 or direction==2) and 1 or -1
            if decoded then
                local ok, message = pcall(callback, decoded)
                if not ok then actions.shutdown();error(message, 0) end
            end
        end
    end
end
function actions.shutdown()
    if not allocation then return end
    actions.set_enabled(false)
    installed=false
    local detached=true
    for _,site in ipairs(sites) do
        if same(site.address,site.original) then
            -- Initialization may have stopped before installing this call.
        elseif site.patch and same(site.address,site.patch) then
            if not write(site.address,site.original) then detached=false end
        else detached=false end -- never overwrite another addon's hook or free its bridge
    end
    if detached then ashita.memory.dealloc(allocation);allocation=nil;sites={} end
end
return actions
