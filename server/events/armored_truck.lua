-- ============================================================
--  ServerDepth Events — server/events/armored_truck.lua
--  Armored Truck Heist event module.
--
--  Flow:
--    1. Tell clients to spawn the truck at route[1] and drive the route.
--    2. Clients track damage and guard kills via net events.
--    3. When the truck is destroyed OR all guards killed, the server
--       collects participant damage contributions and distributes rewards.
--    4. If police_alert is true, a police notification event fires.
-- ============================================================

local MODULE = 'armored_truck'

-- ─── Reward Helper ───────────────────────────────────────────

--- Grant cash and items to a single player, return log entry.
---@param source     number
---@param citizenid  string
---@param cash       number
---@param config     table  Event config (for items, rep, etc.)
---@return table
local function GrantTruckReward(source, citizenid, cash, config)
    local log = {}

    if cash > 0 then
        Framework.AddMoney(source, cash, 'Armored Truck Heist Reward')
        log[#log + 1] = { type = 'cash', amount = cash }
        Framework.Notify(source,
            ('Heist payout: %s'):format(Framework.FormatMoney(cash)),
            'success', 8000
        )
    end

    local rewards = config.rewards or {}

    if rewards.items then
        for _, item in ipairs(rewards.items) do
            if item.item and math.random() <= (item.chance or 1.0) then
                local ok = pcall(function()
                    exports.ox_inventory:AddItem(source, item.item, item.amount or 1)
                end)
                if ok then
                    log[#log + 1] = { item = item.item, amount = item.amount or 1 }
                end
            end
        end
    end

    if Config.IntegrateReputation and rewards.criminal_rep and rewards.criminal_rep > 0 then
        pcall(function()
            exports['serverdepth_reputation']:AddReputation(
                citizenid, 'criminal', rewards.criminal_rep, 'Armored Truck Heist'
            )
        end)
        log[#log + 1] = { type = 'criminal_rep', amount = rewards.criminal_rep }
    end

    return log
end

-- ─── Module: Start ───────────────────────────────────────────

---@param event_id string
---@param config   table
---@param event    table
local function Start(event_id, config, event)
    local route = config.route or {}
    if #route == 0 then
        print(('[^1ServerDepth Events/%s^7] No route configured for armored truck!'):format(MODULE))
        return
    end

    -- Store event state
    event.data.route           = route
    event.data.spawn_coords    = route[1]
    event.data.destroyed       = false
    event.data.guard_kills     = 0
    event.data.guards_required = config.guard_count or 4
    event.data.damage_log      = {}   -- [citizenid] = total_damage (reported by clients)
    event.data.defeated        = false

    -- Expose coords so main.lua can include them in the initial NewEvent broadcast
    config.spawn_label = config.spawn_label or 'Armored Truck Route'
    event.data.coords  = route[1]

    -- Tell a single "host" client (server-side NPC proxy via all clients)
    -- We broadcast to all; each client locally handles if it is the one who
    -- spawned the vehicle (first client present with network authority).
    TriggerClientEvent('serverdepth_events:client:ArmoredTruck:Start', -1, {
        event_id     = event_id,
        spawn_coords = route[1],
        route        = route,
        truck_model  = config.truck_model    or 'stockade',
        truck_health = config.truck_health   or 2000.0,
        guard_count  = config.guard_count    or 4,
        guard_model  = config.guard_model    or 's_m_y_swat_01',
        drive_speed  = config.drive_speed    or 18.0,
    })

    print(('[^2ServerDepth Events/%s^7] Truck spawned at route origin (event_id=%s)'):format(
        MODULE, event_id
    ))
end

-- ─── Module: End ─────────────────────────────────────────────

---@param event_id string
---@param event    table
local function End(event_id, event)
    TriggerClientEvent('serverdepth_events:client:ArmoredTruck:End', -1, { event_id = event_id })
end

-- ─── Net: Damage Report ──────────────────────────────────────
-- Clients report damage they dealt to the truck / guards.
-- Only tracked — actual defeat detection is below.

RegisterNetEvent('serverdepth_events:server:TruckDamage', function(event_id, damage)
    local source = source
    local event  = GetEvent(event_id)
    if not event or event.data.defeated then return end

    local cid = Framework.GetCitizenId(source)
    if not cid then return end

    AddParticipant(event_id, source)

    event.data.damage_log[cid] = (event.data.damage_log[cid] or 0) + (damage or 0)
end)

-- ─── Net: Guard Killed ────────────────────────────────────────

RegisterNetEvent('serverdepth_events:server:TruckGuardKilled', function(event_id)
    local source = source
    local event  = GetEvent(event_id)
    if not event or event.data.defeated then return end

    local cid = Framework.GetCitizenId(source)
    if cid then
        AddParticipant(event_id, source)
        -- Count guard kills towards defeat condition
        event.data.guard_kills = (event.data.guard_kills or 0) + 1
    end

    local required = event.data.guards_required or 4
    if event.data.guard_kills >= required then
        -- All guards down — check if truck is also defeated, or defeat it now
        DistributeTruckRewards(event_id)
    end
end)

-- ─── Net: Truck Destroyed ─────────────────────────────────────

RegisterNetEvent('serverdepth_events:server:TruckDestroyed', function(event_id)
    local event = GetEvent(event_id)
    if not event or event.data.defeated then return end
    DistributeTruckRewards(event_id)
end)

-- ─── Distribute Rewards ───────────────────────────────────────

--- Called when the truck is defeated (destroyed or all guards killed).
--- Splits the cash reward evenly between all participants who dealt damage.
---@param event_id string
function DistributeTruckRewards(event_id)
    local event = GetEvent(event_id)
    if not event or event.data.defeated then return end
    event.data.defeated = true

    local rewards  = event.config.rewards or {}
    local cash_cfg = rewards.cash or { min = 20000, max = 50000 }
    local total    = math.random(cash_cfg.min, cash_cfg.max)

    -- Build participant list from damage log + participants table
    local eligible = {}
    for cid, _ in pairs(event.data.damage_log) do
        eligible[#eligible + 1] = cid
    end
    -- Also include anyone in participants who registered but damage_log might be 0
    for cid, _ in pairs(event.participants) do
        local found = false
        for _, v in ipairs(eligible) do if v == cid then found = true break end end
        if not found then eligible[#eligible + 1] = cid end
    end

    if #eligible == 0 then
        print(('[^2ServerDepth Events/%s^7] No participants — no rewards distributed.'):format(MODULE))
        EndWorldEvent(event_id, nil)
        return
    end

    local share = math.floor(total / #eligible)
    local all_logs = {}

    for _, cid in ipairs(eligible) do
        local player = Framework.GetPlayerByCitizenId(cid)
        if player then
            local src = player.source or (player.PlayerData and player.PlayerData.source)
            if src then
                local log = GrantTruckReward(src, cid, share, event.config)
                for _, entry in ipairs(log) do all_logs[#all_logs + 1] = entry end
            end
        end
    end

    -- Police alert
    if rewards.police_alert then
        TriggerClientEvent('serverdepth_events:client:PoliceAlert', -1, {
            message = 'BOLO: Armored vehicle has been ambushed. All units respond.',
            coords  = event.data.spawn_coords,
        })
    end

    -- Global announcement
    if Config.Notifications.chat then
        TriggerClientEvent('chat:addMessage', -1, {
            color     = { 255, 100, 0 },
            multiline = true,
            args      = {
                '[Events]',
                ('The Armored Truck has been defeated! %d players shared %s.'):format(
                    #eligible, Framework.FormatMoney(total)
                ),
            },
        })
    end

    EndWorldEvent(event_id, eligible[1], all_logs)
end

-- ─── Register ────────────────────────────────────────────────

RegisterEventHandlers(MODULE, {
    Start = Start,
    End   = End,
})
