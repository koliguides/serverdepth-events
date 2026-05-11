-- ============================================================
--  ServerDepth Events — server/main.lua
--  Core event manager: scheduler, lifecycle, DB logging,
--  and exported API surface.
-- ============================================================

-- ─── State ───────────────────────────────────────────────────

--- Keyed by event_id (string UUID-style). Each entry:
---   type          string
---   config        table        (copy of config + module definition)
---   started_at    number       os.time()
---   source        number|nil   admin source if manually triggered
---   triggered_by  string       'schedule'|'admin'|'test'
---   participants  table        { [citizenid] = { source, joined_at } }
---   data          table        module-specific scratch space
local ActiveEvents = {}

--- Timer used by the scheduler to track next automatic event time (os.time epoch).
local NextScheduledEvent = 0

--- Whether the scheduler is currently paused (e.g. during tests).
local SchedulerPaused = false

-- ─── Utilities ───────────────────────────────────────────────

--- Generate a short unique event ID: "evt_<type>_<timestamp>_<rand>"
---@param event_type string
---@return string
local function GenerateEventId(event_type)
    return ('evt_%s_%d_%04d'):format(event_type, os.time(), math.random(1000, 9999))
end

--- Compute a random scheduler interval in seconds from Config.
---@return number seconds
local function RandomInterval()
    local min_s = (Config.Scheduler.interval_min or 20) * 60
    local max_s = (Config.Scheduler.interval_max or 40) * 60
    return math.random(min_s, max_s)
end

--- Count currently active (non-ended) events.
---@return number
local function ActiveEventCount()
    local count = 0
    for _ in pairs(ActiveEvents) do count = count + 1 end
    return count
end

-- ─── DB Helpers ──────────────────────────────────────────────

--- Ensure the events_log table exists (also done by install.sql, but this
--- provides a safety net for servers that skip the SQL step).
local function EnsureDBTables()
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS `events_log` (
          `id`              INT           NOT NULL AUTO_INCREMENT,
          `event_id`        VARCHAR(50)   NOT NULL UNIQUE,
          `event_type`      VARCHAR(50)   NOT NULL,
          `started_at`      TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
          `ended_at`        TIMESTAMP     NULL,
          `winner_citizenid` VARCHAR(50)  NULL,
          `participants`    JSON          NULL,
          `rewards_given`   JSON          NULL,
          `triggered_by`    ENUM('schedule','admin','test') NOT NULL DEFAULT 'schedule',
          PRIMARY KEY (`id`),
          INDEX `idx_event_type` (`event_type`),
          INDEX `idx_started_at` (`started_at`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
end

--- Insert a new row for a started event.
---@param event_id    string
---@param event_type  string
---@param triggered_by string
local function DBInsertEvent(event_id, event_type, triggered_by)
    MySQL.insert(
        'INSERT INTO events_log (event_id, event_type, triggered_by) VALUES (?, ?, ?)',
        { event_id, event_type, triggered_by }
    )
end

--- Update the row when an event ends.
---@param event_id          string
---@param winner_citizenid  string|nil
---@param participants      table
---@param rewards_given     table
local function DBEndEvent(event_id, winner_citizenid, participants, rewards_given)
    MySQL.update(
        [[UPDATE events_log
          SET ended_at = NOW(),
              winner_citizenid = ?,
              participants = ?,
              rewards_given = ?
          WHERE event_id = ?]],
        {
            winner_citizenid,
            json.encode(participants or {}),
            json.encode(rewards_given or {}),
            event_id,
        }
    )
end

-- ─── Event Modules ───────────────────────────────────────────
-- Modules self-register via EventRegistry.RegisterEventType.
-- We store handler references in a local table after all files load.

local EventHandlers = {}   -- [event_type] = { Start=fn, End=fn }

--- Register a handler pair from an event module.
---@param event_type string
---@param handlers   table  { Start=fn, End=fn }
function RegisterEventHandlers(event_type, handlers)
    assert(type(handlers.Start) == 'function', 'RegisterEventHandlers: Start must be a function')
    assert(type(handlers.End)   == 'function', 'RegisterEventHandlers: End must be a function')
    EventHandlers[event_type] = handlers
end

-- ─── Core API ────────────────────────────────────────────────

--- Trigger (start) a new event of the given type.
---@param event_type    string            Config.EventTypes key
---@param admin_source  number|nil        Server ID of triggering admin (nil = scheduler)
---@param triggered_by  string|nil        'schedule'|'admin'|'test'
---@return string|nil   event_id, or nil + error string on failure
function TriggerWorldEvent(event_type, admin_source, triggered_by)
    triggered_by = triggered_by or (admin_source and 'admin' or 'schedule')

    -- Validation
    local def = EventRegistry.GetEventType(event_type)
    if not def then
        return nil, ('Unknown event type: %s'):format(event_type)
    end
    if def.enabled == false then
        return nil, ('Event type disabled: %s'):format(event_type)
    end
    if EventRegistry.IsOnCooldown(event_type) then
        local remaining = math.ceil(EventRegistry.GetCooldownRemaining(event_type) / 60)
        return nil, ('Event %s is on cooldown (%d min remaining)'):format(event_type, remaining)
    end

    local max_concurrent = Config.Scheduler.max_concurrent or 2
    if ActiveEventCount() >= max_concurrent then
        return nil, ('Max concurrent events (%d) already running'):format(max_concurrent)
    end

    local handlers = EventHandlers[event_type]
    if not handlers then
        return nil, ('No handler registered for event type: %s'):format(event_type)
    end

    -- Create the event record
    local event_id = GenerateEventId(event_type)
    local now      = os.time()

    ActiveEvents[event_id] = {
        id            = event_id,
        type          = event_type,
        config        = def,
        started_at    = now,
        source        = admin_source,
        triggered_by  = triggered_by,
        participants  = {},
        rewards_given = {},
        data          = {},
    }

    -- Put the event type on cooldown immediately to prevent duplicate triggers
    EventRegistry.SetCooldown(event_type)

    -- Persist to DB
    DBInsertEvent(event_id, event_type, triggered_by)

    -- Log
    print(('[^2ServerDepth Events^7] Starting event ^5%s^7 (id=%s, by=%s)'):format(
        event_type, event_id, triggered_by
    ))

    -- Hand off to the module
    local ok, err = pcall(handlers.Start, event_id, def, ActiveEvents[event_id])
    if not ok then
        print(('[^1ServerDepth Events^7] Error starting %s: %s'):format(event_type, tostring(err)))
        ActiveEvents[event_id] = nil
        return nil, err
    end

    -- Schedule automatic timeout if defined
    if def.timeout_minutes and def.timeout_minutes > 0 then
        local timeout_ms = def.timeout_minutes * 60 * 1000
        SetTimeout(timeout_ms, function()
            if ActiveEvents[event_id] then
                print(('[^2ServerDepth Events^7] Event %s timed out.'):format(event_id))
                EndWorldEvent(event_id, nil)
            end
        end)
    end

    -- Notify all players
    TriggerClientEvent('serverdepth_events:client:NewEvent', -1, {
        event_id   = event_id,
        event_type = event_type,
        label      = def.spawn_label or def.name or event_type,
        coords     = ActiveEvents[event_id].data.coords,  -- set by module Start if applicable
        blip       = Config.Blips and Config.Blips[event_type],
    })

    return event_id
end

--- End an active event, distribute nothing extra (modules handle rewards themselves).
---@param event_id          string
---@param winner_citizenid  string|nil
---@param rewards_given     table|nil  Serialisable reward log
function EndWorldEvent(event_id, winner_citizenid, rewards_given)
    local event = ActiveEvents[event_id]
    if not event then return end

    local handlers = EventHandlers[event.type]
    if handlers then
        pcall(handlers.End, event_id, event)
    end

    -- Persist end record
    DBEndEvent(event_id, winner_citizenid, event.participants, rewards_given or event.rewards_given)

    -- Notify clients to clean up blip/markers
    TriggerClientEvent('serverdepth_events:client:EventEnded', -1, {
        event_id          = event_id,
        winner_citizenid  = winner_citizenid,
    })

    print(('[^2ServerDepth Events^7] Event %s ended. Winner: %s'):format(
        event_id, winner_citizenid or 'none'
    ))

    ActiveEvents[event_id] = nil
end

--- Return a sanitised copy of active events (safe for client export / command output).
---@return table[]
function GetActiveEvents()
    local result = {}
    for id, ev in pairs(ActiveEvents) do
        result[#result + 1] = {
            event_id   = id,
            event_type = ev.type,
            started_at = ev.started_at,
            label      = (ev.config.spawn_label or ev.type),
            coords     = ev.data.coords,
        }
    end
    return result
end

--- Check if a given event type is currently on cooldown.
---@param event_type string
---@return boolean
function IsEventOnCooldown(event_type)
    return EventRegistry.IsOnCooldown(event_type)
end

--- Add a participant to a running event.
---@param event_id   string
---@param source     number  Player server ID
---@return boolean   false if event not found
function AddParticipant(event_id, source)
    local event = ActiveEvents[event_id]
    if not event then return false end
    local cid = Framework.GetCitizenId(source)
    if not cid then return false end
    if not event.participants[cid] then
        event.participants[cid] = { source = source, joined_at = os.time() }
    end
    return true
end

--- Retrieve a running event record (direct reference — do not store persistently).
---@param event_id string
---@return table|nil
function GetEvent(event_id)
    return ActiveEvents[event_id]
end

-- ─── Exports ─────────────────────────────────────────────────

exports('TriggerEvent',     TriggerWorldEvent)
exports('EndEvent',         EndWorldEvent)
exports('GetActiveEvents',  GetActiveEvents)
exports('IsEventOnCooldown', IsEventOnCooldown)
exports('AddParticipant',   AddParticipant)

-- ─── Scheduler Thread ────────────────────────────────────────

Citizen.CreateThread(function()
    -- Wait a moment for all modules to register their handlers
    Wait(5000)
    EnsureDBTables()

    -- Set the first event to fire randomly between interval_min and interval_max
    NextScheduledEvent = os.time() + RandomInterval()
    print(('[^2ServerDepth Events^7] Scheduler started. Next event in ~%d minutes.'):format(
        math.floor((NextScheduledEvent - os.time()) / 60)
    ))

    while true do
        Wait(30000)   -- check every 30 seconds

        if not SchedulerPaused and Config.Scheduler.enabled then
            local now = os.time()
            if now >= NextScheduledEvent then
                -- Attempt to pick and fire an event
                local def = EventRegistry.PickWeightedEvent()
                if def then
                    local event_id, err = TriggerWorldEvent(def.name, nil, 'schedule')
                    if not event_id then
                        print(('[^1ServerDepth Events^7] Scheduler failed to start event: %s'):format(tostring(err)))
                    end
                else
                    print('[^3ServerDepth Events^7] Scheduler: no eligible events (all on cooldown?)')
                end
                -- Always advance the timer regardless of success to avoid spin-loops
                NextScheduledEvent = now + RandomInterval()
            end
        end
    end
end)

-- ─── Network: client requests active event list ──────────────

RegisterNetEvent('serverdepth_events:server:GetActiveEvents', function()
    local source = source
    TriggerClientEvent('serverdepth_events:client:ActiveEventsList', source, GetActiveEvents())
end)

-- ─── Network: client sets GPS waypoint (just ACK) ────────────
-- No server action needed; the client handles its own waypoint.

-- ─── Resource Stop Cleanup ───────────────────────────────────

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    -- End all active events gracefully so DB rows are closed
    for event_id, event in pairs(ActiveEvents) do
        DBEndEvent(event_id, nil, event.participants, event.rewards_given)
    end
    print('[^3ServerDepth Events^7] Resource stopped — all active events closed in DB.')
end)
