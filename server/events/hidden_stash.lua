-- ============================================================
--  ServerDepth Events — server/events/hidden_stash.lua
--  Hidden Stash event module.
--
--  Flow:
--    1. Pick random stash location + clue text from config.
--    2. Broadcast cryptic clue hint to all players (chat + NUI).
--    3. After clue_delay_seconds, reveal the map blip.
--    4. First player within claim_radius (server validated) claims it.
--    5. Roll loot table, grant items + cash + rep.
-- ============================================================

local MODULE = 'hidden_stash'

-- ─── Reward Helper ───────────────────────────────────────────

--- Roll loot table and grant to player. Returns reward log.
---@param source     number
---@param citizenid  string
---@param config     table   Event config
---@return table
local function GrantStashRewards(source, citizenid, config)
    local log      = {}
    local loot     = config.loot_table or {}
    local rewards  = config.rewards    or {}

    for _, entry in ipairs(loot) do
        if entry.item and math.random() <= (entry.chance or 1.0) then
            local amount = entry.amount or 1

            -- 'money' is handled as cash, not an inventory item
            if entry.item == 'money' then
                if Framework.AddMoney(source, amount, 'Hidden Stash Reward') then
                    log[#log + 1] = { type = 'cash', amount = amount }
                    Framework.Notify(source,
                        ('Hidden stash: found %s in cash!'):format(Framework.FormatMoney(amount)),
                        'success', 7000
                    )
                end
            else
                local ok = pcall(function()
                    exports.ox_inventory:AddItem(source, entry.item, amount)
                end)
                if ok then
                    log[#log + 1] = { item = entry.item, amount = amount }
                end
            end
        end
    end

    -- Notify with summary
    local item_count = 0
    for _, l in ipairs(log) do if l.item then item_count = item_count + 1 end end
    if item_count > 0 then
        Framework.Notify(source,
            ('You found the hidden stash! Looted %d item(s).'):format(item_count),
            'success', 7000
        )
    end

    -- Reputation integration
    if Config.IntegrateReputation and rewards.criminal_rep and rewards.criminal_rep > 0 then
        pcall(function()
            exports['serverdepth_reputation']:AddReputation(
                citizenid, 'criminal', rewards.criminal_rep, 'Found Hidden Stash'
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
    local locations = config.locations or {}
    if #locations == 0 then
        print(('[^1ServerDepth Events/%s^7] No stash locations configured!'):format(MODULE))
        return
    end

    local location = locations[math.random(1, #locations)]

    event.data.coords       = location.coords
    event.data.heading      = location.heading or 0.0
    event.data.clue         = location.clue
    event.data.claimed      = false
    event.data.blip_revealed = false
    event.data.claim_radius  = config.claim_radius or 2.0

    config.spawn_label = 'Somewhere on the map…'   -- cryptic until revealed

    print(('[^2ServerDepth Events/%s^7] Stash placed (event_id=%s, blip in %ds)'):format(
        MODULE, event_id, config.clue_delay_seconds or 120
    ))

    -- Send cryptic clue to all players (no coords)
    TriggerClientEvent('serverdepth_events:client:HiddenStash:Clue', -1, {
        event_id = event_id,
        clue     = location.clue,
    })

    if Config.Notifications.chat then
        TriggerClientEvent('chat:addMessage', -1, {
            color     = { 100, 200, 100 },
            multiline = true,
            args      = {
                '[Events — Hidden Stash]',
                ('A stash has been hidden: "%s"'):format(location.clue),
            },
        })
    end

    -- After clue_delay_seconds reveal blip
    local delay_ms = (config.clue_delay_seconds or 120) * 1000
    SetTimeout(delay_ms, function()
        if not GetEvent(event_id) then return end
        event.data.blip_revealed = true
        TriggerClientEvent('serverdepth_events:client:HiddenStash:RevealBlip', -1, {
            event_id = event_id,
            coords   = location.coords,
            blip     = Config.Blips and Config.Blips[MODULE],
        })

        if Config.Notifications.chat then
            TriggerClientEvent('chat:addMessage', -1, {
                color     = { 100, 200, 100 },
                multiline = true,
                args      = {
                    '[Events — Hidden Stash]',
                    'Still not found. A blip has appeared on the map!',
                },
            })
        end
    end)
end

-- ─── Module: End ─────────────────────────────────────────────

---@param event_id string
local function End(event_id, event)
    TriggerClientEvent('serverdepth_events:client:HiddenStash:End', -1, { event_id = event_id })
end

-- ─── Net: Claim Stash ────────────────────────────────────────

RegisterNetEvent('serverdepth_events:server:ClaimHiddenStash', function(event_id)
    local source = source
    local event  = GetEvent(event_id)

    if not event or event.type ~= MODULE then
        Framework.Notify(source, 'That stash no longer exists.', 'error')
        return
    end
    if event.data.claimed then
        Framework.Notify(source, 'Someone already found the stash!', 'error')
        return
    end

    -- Server-side distance check
    local player_coords = Framework.GetCoords(source)
    local stash_coords  = event.data.coords

    if not player_coords or not stash_coords then
        Framework.Notify(source, 'Cannot verify position.', 'error')
        return
    end

    local dist = #(player_coords - stash_coords)
    local max_dist = (event.data.claim_radius or 2.0) + 3.0  -- tolerance

    if dist > max_dist then
        Framework.Notify(source, 'You are not close enough to the stash.', 'error')
        return
    end

    event.data.claimed = true

    local citizenid = Framework.GetCitizenId(source)
    if not citizenid then
        event.data.claimed = false
        return
    end

    AddParticipant(event_id, source)
    local reward_log = GrantStashRewards(source, citizenid, event.config)

    -- Announce
    local player_name = Framework.GetPlayerName(source)
    if Config.Notifications.chat then
        TriggerClientEvent('chat:addMessage', -1, {
            color     = { 100, 200, 100 },
            multiline = true,
            args      = {
                '[Events]',
                ('%s found the hidden stash!'):format(player_name),
            },
        })
    end

    EndWorldEvent(event_id, citizenid, reward_log)
end)

-- ─── Register ────────────────────────────────────────────────

RegisterEventHandlers(MODULE, {
    Start = Start,
    End   = End,
})
