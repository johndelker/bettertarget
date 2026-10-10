-- Ashita input events only. Events enqueue intent; scene callbacks select targets.
local gamepad = {}
local held, pending = {}, {}
local function same(a,b)
    if not a or not b then return false end
    for i=1,#a do if a[i]~=b[i] then return false end end
    return #a==#b
end
function gamepad.handle(settings, source, e, allowed, context, modifier)
    if e.injected then return end
    local key=source..':'..tostring(e.button)
    local previous=held[key]
    local down=e.state==(source=='xinput' and 1 or 128)
    if not down then
        if previous then
            held[key]=nil
        end
        return
    end
    if e.blocked then return end
    if previous then return end
    local direction
    if source=='xinput' then
        direction=e.button==8 and -1 or (e.button==9 and 1 or nil)
    else
        direction=e.button==settings.bumperLeftButton and -1
            or (e.button==settings.bumperRightButton and 1 or nil)
    end
    if not direction then return end
    local mode=settings.bumperInputMode or 0
    local source_enabled=mode==0 or (mode==1 and source=='xinput') or (mode==2 and source=='dinput')
    if not source_enabled then return end
    local record={direction=direction,queued=false}
    -- XInput and DirectInput may report the same physical button. Queue only
    -- the first edge until both backend reports are released; input stays unblocked.
    local duplicate=false
    for _,entry in pairs(held) do
        if entry.direction==direction then
            duplicate=true
            record.queued=record.queued or entry.queued
        end
    end
    held[key]=record
    if not duplicate and allowed and settings.enableBumperCycling and #pending<32 then
        record.queued=true
        pending[#pending+1]={direction=direction,context=context,modifier=modifier}
    end
end
function gamepad.drain(context, callback)
    local queue=pending;pending={}
    for _,entry in ipairs(queue) do
        if same(entry.context,context) then callback(entry.direction,entry.modifier) end
    end
end
function gamepad.clear_pending() pending={} end
function gamepad.shutdown() held={};pending={} end
return gamepad
