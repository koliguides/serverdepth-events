-- ============================================================
--  ServerDepth Events — server/commands.lua
--  Admin and player-facing chat commands.
--
--  Commands:
--    /events                 — list active events (anyone)
--    /trigger_event [type]   — fire an event manually (admin)
--    /cancel_event [event_id]— cancel a running event (admin)
--    /event_cooldowns        — list all cooldown timers (admin)
--    /joinrace               — join an open race (any player)
--    /clearcooldown [type]   — clear a specific cooldown (admin)
-- ============================================================

-- ─── Helpers ─────────────────────────────────────────────────

--- Seconds-to-readable-string helper  e.g. 125 -> "2m 5s"
---@param seconds number
---@return string
local function FormatSeconds(seconds)
    seconds = math.max(0, math.floor(seconds))
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    if m > 0 then
        return ('%dm %ds'):format(m, s)
    end
    return ('%ds'):format(s)
end

--- Send a coloured server-side console / chat reply.
---@param source  number  Player source (0 = console)
---@param msg     string
---@param colour  table   RGB table {r,g,b}
local function Reply(source, msg, colour)
    colour = colour or { 255, 200, 100 }
    if source == 0 then
        print('[ServerDepth Events] ' .. msg)
    else
        TriggerClientEvent('chat:addMessage', source, {
            color     = colour,
            multiline = true,
            args      = { '[Events]', msg },
        })
    end
end

-- ─── /events ─────────────────────────────────────────────────
-- List all currently active events. Available to everyone.

RegisterCommand('events', function(source, args, rawCommand)
    local active = GetActiveEvents()

    if #active == 0 then
        Reply(source, 'No events are currently active.', { 200, 200, 200 })
        return
    end

    Reply(source, ('Active events (%d):'):format(#active), { 255, 200, 50 })
    for _, ev in ipairs(active) do
        local elapsed = math.floor(os.time() - ev.started_at)
        Reply(source,
            ('  [%s] Type: %s | Location: %s | Running for: %s'):format(
                ev.event_id, ev.event_type, ev.label, FormatSeconds(elapsed)
            ),
            { 200, 200, 200 }
        )
    end
end, false)

-- ─── /trigger_event ──────────────────────────────────────────
-- Admin command to manually fire a named event type.

RegisterCommand('trigger_event', function(source, args, rawCommand)
    if not Framework.HasAdminPermission(source) then
        Reply(source, 'You do not have permission to use this command.', { 220, 60, 60 })
        return
    end

    local event_type = args[1]
    if not event_type or event_type == '' then
        -- List available event types
        local types = {}
        for name, def in pairs(Config.EventTypes or {}) do
            if def.enabled ~= false then
                types[#types + 1] = name
            end
        end
        table.sort(types)
        Reply(source, 'Usage: /trigger_event [type]', { 255, 200, 50 })
        Reply(source, 'Available types: ' .. table.concat(types, ', '), { 200, 200, 200 })
        return
    end

    -- Bypass cooldown for admin triggers? We skip the cooldown check intentionally.
    -- Clear the cooldown first so admins can force-trigger.
    EventRegistry.ClearCooldown(event_type)

    local event_id, err = TriggerWorldEvent(event_type, source, 'admin')
    if event_id then
        Reply(source, ('Event "%s" triggered! ID: %s'):format(event_type, event_id), { 100, 220, 100 })
    else
        Reply(source, ('Failed to trigger event: %s'):format(tostring(err)), { 220, 60, 60 })
    end
end, false)

-- ─── /cancel_event ───────────────────────────────────────────
-- Admin command to immediately end a running event.

RegisterCommand('cancel_event', function(source, args, rawCommand)
    if not Framework.HasAdminPermission(source) then
        Reply(source, 'You do not have permission to use this command.', { 220, 60, 60 })
        return
    end

    local event_id = args[1]
    if not event_id or event_id == '' then
        Reply(source, 'Usage: /cancel_event [event_id]', { 255, 200, 50 })
        -- Show active event IDs
        local active = GetActiveEvents()
        for _, ev in ipairs(active) do
            Reply(source, ('  %s (%s)'):format(ev.event_id, ev.event_type), { 200, 200, 200 })
        end
        return
    end

    local event = GetEvent(event_id)
    if not event then
        Reply(source, ('No active event with ID: %s'):format(event_id), { 220, 60, 60 })
        return
    end

    EndWorldEvent(event_id, nil, {})
    Reply(source, ('Event %s (%s) cancelled.'):format(event_id, event.type), { 255, 200, 50 })

    -- Notify all players
    TriggerClientEvent('chat:addMessage', -1, {
        color     = { 180, 100, 100 },
        multiline = true,
        args      = {
            '[Events]',
            ('Event "%s" was cancelled by an admin.'):format(event.type),
        },
    })
end, false)

-- ─── /event_cooldowns ────────────────────────────────────────
-- Admin command to view all cooldown timers.

RegisterCommand('event_cooldowns', function(source, args, rawCommand)
    if not Framework.HasAdminPermission(source) then
        Reply(source, 'You do not have permission to use this command.', { 220, 60, 60 })
        return
    end

    Reply(source, 'Event Cooldown Status:', { 255, 200, 50 })

    for name, def in pairs(Config.EventTypes or {}) do
        local remaining = EventRegistry.GetCooldownRemaining(name)
        local status
        if remaining > 0 then
            status = ('ON COOLDOWN — %s remaining'):format(FormatSeconds(remaining))
        elseif def.enabled == false then
            status = 'DISABLED'
        else
            status = 'READY'
        end
        Reply(source, ('  %-25s %s'):format(name, status), { 200, 200, 200 })
    end
end, false)

-- ─── /joinrace ───────────────────────────────────────────────
-- Allow any player to join an open race registration.

RegisterCommand('joinrace', function(source, args, rawCommand)
    -- Find the first open race registration
    local active = GetActiveEvents()
    local race_event_id = nil

    for _, ev in ipairs(active) do
        if ev.event_type == 'underground_race' then
            local event = GetEvent(ev.event_id)
            if event and event.data and event.data.registration_open then
                race_event_id = ev.event_id
                break
            end
        end
    end

    if not race_event_id then
        Reply(source, 'No underground race is currently accepting registrations.', { 200, 200, 200 })
        return
    end

    -- Fire the same net event handler as the NUI button
    TriggerEvent('serverdepth_events:server:JoinRace', race_event_id)
    -- Note: TriggerEvent will run with source = 0 (server), so we delegate properly:
    TriggerNetEvent('serverdepth_events:server:JoinRace', race_event_id)
    -- Actually call the handler directly with source context:
    -- The cleanest approach is to re-use the same RegisterNetEvent handler by
    -- emitting from the client side; but since this is a server command,
    -- we call the internal join logic directly.
    local event = GetEvent(race_event_id)
    if not event then
        Reply(source, 'Race event no longer active.', { 220, 60, 60 })
        return
    end

    if not event.data.registration_open then
        Reply(source, 'Registration is closed.', { 220, 60, 60 })
        return
    end

    local max_racers = event.config.max_racers or 12
    local count = 0
    for _ in pairs(event.data.registrants) do count = count + 1 end
    if count >= max_racers then
        Reply(source, 'Race is full!', { 220, 60, 60 })
        return
    end

    local cid = Framework.GetCitizenId(source)
    if not cid then
        Reply(source, 'Character data not found.', { 220, 60, 60 })
        return
    end

    if event.data.registrants[cid] then
        Reply(source, 'You are already registered for the race.', { 200, 200, 200 })
        return
    end

    event.data.registrants[cid] = source
    AddParticipant(race_event_id, source)
    Reply(source, ('Registered for the underground race at %s!'):format(event.data.circuit and event.data.circuit.label or '?'), { 100, 220, 100 })

    -- Update count for all
    TriggerClientEvent('serverdepth_events:client:Race:RegistrantUpdate', -1, {
        event_id = race_event_id,
        count    = count + 1,
    })
end, false)

-- ─── /clearcooldown ──────────────────────────────────────────
-- Admin command to manually clear a specific event type's cooldown.

RegisterCommand('clearcooldown', function(source, args, rawCommand)
    if not Framework.HasAdminPermission(source) then
        Reply(source, 'You do not have permission to use this command.', { 220, 60, 60 })
        return
    end

    local event_type = args[1]
    if not event_type then
        Reply(source, 'Usage: /clearcooldown [event_type]', { 255, 200, 50 })
        return
    end

    if not Config.EventTypes[event_type] then
        Reply(source, ('Unknown event type: %s'):format(event_type), { 220, 60, 60 })
        return
    end

    EventRegistry.ClearCooldown(event_type)
    Reply(source, ('Cooldown cleared for: %s'):format(event_type), { 100, 220, 100 })
end, false)

-- ─── Register chat suggestions ───────────────────────────────
-- Provides command auto-complete hints in the FiveM chat UI.

TriggerEvent('chat:addSuggestion', '/events', 'List all active world events.')
TriggerEvent('chat:addSuggestion', '/joinrace', 'Join an open underground race registration.')
TriggerEvent('chat:addSuggestion', '/trigger_event', 'Admin: Manually trigger a world event.', {
    { name = 'type', help = 'cargo_drop | armored_truck | underground_race | hidden_stash' },
})
TriggerEvent('chat:addSuggestion', '/cancel_event', 'Admin: Cancel a running event by ID.', {
    { name = 'event_id', help = 'Event ID (use /events to list)' },
})
TriggerEvent('chat:addSuggestion', '/event_cooldowns', 'Admin: View all event cooldown timers.')
TriggerEvent('chat:addSuggestion', '/clearcooldown', 'Admin: Clear a specific event type cooldown.', {
    { name = 'type', help = 'Event type name' },
})
