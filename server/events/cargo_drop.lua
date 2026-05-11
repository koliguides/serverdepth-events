-- ============================================================
--  ServerDepth Events — server/events/cargo_drop.lua
--  Cargo Drop event module.
--
--  Flow:
--    1. Pick a random spawn zone from config.
--    2. Notify all clients to spawn the crate prop and draw marker.
--    3. First player within claim_radius triggers ClaimCargoDrop.
--    4. Server validates distance, grants rewards, ends event.
-- ============================================================

local MODULE = 'cargo_drop'

-- ─── Reward Helper ───────────────────────────────────────────

--- Roll an item from a reward table entry and add it to ox_inventory.
---@param source  number  Player server ID
---@param item    table   { item, amount, chance }
---@param log     table   Mutable reward log table
local function TryGrantItem(source, item, log)
    if not item or not item.item then return end
    local chance = item.chance or 1.0
    if math.random() > chance then return end

    local amount = item.amount or 1

    local ok, err = pcall(function()
        exports.ox_inventory:AddItem(source, item.item, amount)
    end)

    if ok then
        log[#log + 1] = { item = item.item, amount = amount }
    else
        print(('[^1ServerDepth Events/%s^7] ox_inventory error adding %s: %s'):format(
            MODULE, item.item, tostring(err)
        ))
    end
end

--- Distribute all rewards defined in the event config to a player.
---@param source      number  Player server ID
---@param citizenid   string
---@param rewards     table   Config rewards table
---@param event_type  string  Used for reputation log text
---@return table              Reward log for DB
local function GrantRewards(source, citizenid, rewards, event_type)
    local log = {}

    -- Cash reward (random between min/max)
    if rewards.cash then
        local amount = math.random(rewards.cash.min, rewards.cash.max)
        if Framework.AddMoney(source, amount, 'Cargo Drop Event Reward') then
            log[#log + 1] = { type = 'cash', amount = amount }
            Framework.Notify(source,
                ('You claimed the cargo drop! Reward: %s cash.'):format(Framework.FormatMoney(amount)),
                'success', 8000
            )
        end
    end

    -- Item rewards
    if rewards.items then
        for _, item in ipairs(rewards.items) do
            TryGrantItem(source, item, log)
        end
    end

    -- Optional reputation integration
    if Config.IntegrateReputation and rewards.criminal_rep and rewards.criminal_rep > 0 then
        pcall(function()
            exports['serverdepth_reputation']:AddReputation(
                citizenid, 'criminal', rewards.criminal_rep,
                'Won ' .. event_type
            )
        end)
        log[#log + 1] = { type = 'criminal_rep', amount = rewards.criminal_rep }
    end

    return log
end

-- ─── Module: Start ───────────────────────────────────────────

--- Start the cargo drop event.
---@param event_id  string   Unique event identifier
---@param config    table    Merged config + registry definition
---@param event     table    Live event record (data scratch space)
local function Start(event_id, config, event)
    -- Pick a random spawn zone
    local zones    = config.spawn_zones or {}
    local zone_idx = math.random(1, math.max(1, #zones))
    local zone     = zones[zone_idx] or { coords = vector3(0, 0, 0), label = 'Unknown' }

    -- Persist spawn data onto the event so the server can validate claims
    event.data.coords      = zone.coords
    event.data.label       = zone.label
    event.data.claimed     = false
    event.data.claim_radius = config.claim_radius or 3.0

    -- Override the event label for the initial notification (sent from main.lua)
    config.spawn_label = zone.label

    print(('[^2ServerDepth Events/%s^7] Spawning at %s (event_id=%s)'):format(
        MODULE, zone.label, event_id
    ))

    -- Tell all clients to spawn the crate, draw the marker, and enable claim checks
    TriggerClientEvent('serverdepth_events:client:CargoDrop:Start', -1, {
        event_id     = event_id,
        coords       = zone.coords,
        label        = zone.label,
        crate_model  = config.crate_prop or 'prop_mil_crate_01',
        claim_radius = event.data.claim_radius,
    })
end

-- ─── Module: End ─────────────────────────────────────────────

--- Clean up the cargo drop event.
---@param event_id string
---@param event    table
local function End(event_id, event)
    -- Tell all clients to despawn the crate and remove the marker
    TriggerClientEvent('serverdepth_events:client:CargoDrop:End', -1, { event_id = event_id })
end

-- ─── Claim Handler ───────────────────────────────────────────

--- Net event: A client believes they are within range and attempts to claim the cargo.
RegisterNetEvent('serverdepth_events:server:ClaimCargoDrop', function(event_id)
    local source = source

    local event = GetEvent(event_id)
    if not event then
        Framework.Notify(source, 'This event no longer exists.', 'error')
        return
    end
    if event.data.claimed then
        Framework.Notify(source, 'The cargo has already been claimed!', 'error')
        return
    end

    -- Server-side distance validation (anti-cheat)
    local player_coords = Framework.GetCoords(source)
    local drop_coords   = event.data.coords

    if not player_coords or not drop_coords then
        Framework.Notify(source, 'Could not verify your position.', 'error')
        return
    end

    local dist = #(player_coords - drop_coords)
    local max_dist = (event.data.claim_radius or 3.0) + 2.0   -- small server-side tolerance

    if dist > max_dist then
        Framework.Notify(source, 'You are not close enough to the cargo.', 'error')
        return
    end

    -- Mark as claimed to prevent race conditions
    event.data.claimed = true

    local citizenid = Framework.GetCitizenId(source)
    if not citizenid then
        Framework.Notify(source, 'Player data not found.', 'error')
        event.data.claimed = false
        return
    end

    -- Record as participant
    AddParticipant(event_id, source)

    -- Grant rewards
    local cfg_rewards = event.config.rewards or {}
    local reward_log  = GrantRewards(source, citizenid, cfg_rewards, MODULE)

    -- Announce to all players
    if Config.Notifications.chat then
        local player_name = Framework.GetPlayerName(source)
        TriggerClientEvent('chat:addMessage', -1, {
            color   = { 255, 153, 0 },
            multiline = true,
            args    = {
                '[Events]',
                ('%s claimed the Cargo Drop at %s!'):format(player_name, event.data.label),
            },
        })
    end

    -- End the event
    EndWorldEvent(event_id, citizenid, reward_log)
end)

-- ─── Register ────────────────────────────────────────────────

RegisterEventHandlers(MODULE, {
    Start = Start,
    End   = End,
})
