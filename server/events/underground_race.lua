-- ============================================================
--  ServerDepth Events — server/events/underground_race.lua
--  Underground Race event module.
--
--  Flow:
--    1. Pick random circuit from config.
--    2. Open registration phase (Config.registration_duration seconds).
--    3. Players call /joinrace or NUI button.
--    4. After registration closes (or min_racers reached + timer):
--       - Teleport all registered players to start coords.
--       - Broadcast waypoint sequence.
--    5. Players report checkpoint crossings (server verifies proximity).
--    6. First to cross finish line wins.
--    7. Reward top 3.
-- ============================================================

local MODULE = 'underground_race'

-- ─── Reward Helper ───────────────────────────────────────────

---@param source     number
---@param citizenid  string
---@param tier       table   rewards.first / .second / .third
---@param tier_label string  '1st', '2nd', '3rd'
---@param event_type string
local function GrantRacerReward(source, citizenid, tier, tier_label, event_type)
    if not tier then return end

    if tier.cash and tier.cash > 0 then
        Framework.AddMoney(source, tier.cash, ('Underground Race - %s place'):format(tier_label))
        Framework.Notify(source,
            ('%s place! Payout: %s'):format(tier_label, Framework.FormatMoney(tier.cash)),
            'success', 10000
        )
    end

    if tier.items then
        for _, item in ipairs(tier.items) do
            if item.item and math.random() <= (item.chance or 1.0) then
                pcall(function()
                    exports.ox_inventory:AddItem(source, item.item, item.amount or 1)
                end)
            end
        end
    end

    if Config.IntegrateReputation and tier.criminal_rep and tier.criminal_rep > 0 then
        pcall(function()
            exports['serverdepth_reputation']:AddReputation(
                citizenid, 'criminal', tier.criminal_rep,
                ('Won underground race (%s)'):format(tier_label)
            )
        end)
    end
end

-- ─── Module: Start ───────────────────────────────────────────

---@param event_id string
---@param config   table
---@param event    table
local function Start(event_id, config, event)
    -- Pick random circuit
    local circuits = config.circuits or {}
    if #circuits == 0 then
        print(('[^1ServerDepth Events/%s^7] No circuits configured!'):format(MODULE))
        return
    end
    local circuit = circuits[math.random(1, #circuits)]

    -- Store race state
    event.data.circuit         = circuit
    event.data.registrants     = {}    -- [citizenid] = source
    event.data.registration_open = true
    event.data.started         = false
    event.data.finished        = {}    -- ordered list of citizenids who finished
    event.data.checkpoint_progress = {} -- [citizenid] = next checkpoint index

    event.data.coords = circuit.start_coords  -- for map blip

    config.spawn_label = circuit.label

    local reg_dur = config.registration_duration or 300

    print(('[^2ServerDepth Events/%s^7] Registration open for "%s" (%d sec, event_id=%s)'):format(
        MODULE, circuit.label, reg_dur, event_id
    ))

    -- Open registration on all clients
    TriggerClientEvent('serverdepth_events:client:Race:RegistrationOpen', -1, {
        event_id   = event_id,
        label      = circuit.label,
        duration   = reg_dur,
        max_racers = config.max_racers or 12,
    })

    -- After registration window closes, start the race (or cancel if too few)
    SetTimeout(reg_dur * 1000, function()
        if not GetEvent(event_id) then return end   -- event already ended
        event.data.registration_open = false
        TriggerClientEvent('serverdepth_events:client:Race:RegistrationClosed', -1, { event_id = event_id })

        local reg_count = 0
        for _ in pairs(event.data.registrants) do reg_count = reg_count + 1 end

        local min_racers = config.min_racers or 2
        if reg_count < min_racers then
            -- Not enough racers — cancel
            if Config.Notifications.chat then
                TriggerClientEvent('chat:addMessage', -1, {
                    color = { 200, 80, 80 },
                    multiline = true,
                    args = { '[Events]', ('Underground race cancelled — not enough participants (%d/%d).'):format(reg_count, min_racers) },
                })
            end
            EndWorldEvent(event_id, nil)
            return
        end

        -- Police alert if too many racers
        local alert_threshold = config.police_alert_threshold or 6
        if reg_count >= alert_threshold then
            TriggerClientEvent('serverdepth_events:client:PoliceAlert', -1, {
                message = 'Reports of an organised illegal street race. Units respond to ' .. circuit.label,
                coords  = circuit.start_coords,
            })
        end

        -- Teleport registered racers to start line and begin race
        event.data.started = true

        for cid, src in pairs(event.data.registrants) do
            event.data.checkpoint_progress[cid] = 1
            TriggerClientEvent('serverdepth_events:client:Race:Start', src, {
                event_id     = event_id,
                start_coords = circuit.start_coords,
                checkpoints  = circuit.checkpoints,
                finish_coords = circuit.finish_coords,
            })
        end

        if Config.Notifications.chat then
            TriggerClientEvent('chat:addMessage', -1, {
                color = { 255, 153, 0 },
                multiline = true,
                args = {
                    '[Events]',
                    ('Underground race starting at %s with %d racers!'):format(circuit.label, reg_count),
                },
            })
        end
    end)
end

-- ─── Module: End ─────────────────────────────────────────────

---@param event_id string
local function End(event_id, event)
    TriggerClientEvent('serverdepth_events:client:Race:End', -1, { event_id = event_id })
end

-- ─── Net: Join Race ──────────────────────────────────────────

RegisterNetEvent('serverdepth_events:server:JoinRace', function(event_id)
    local source = source
    local event  = GetEvent(event_id)

    if not event or event.type ~= MODULE then
        Framework.Notify(source, 'No active race to join.', 'error')
        return
    end
    if not event.data.registration_open then
        Framework.Notify(source, 'Registration has closed.', 'error')
        return
    end

    local max_racers = event.config.max_racers or 12
    local count = 0
    for _ in pairs(event.data.registrants) do count = count + 1 end
    if count >= max_racers then
        Framework.Notify(source, 'Race is full!', 'error')
        return
    end

    local cid = Framework.GetCitizenId(source)
    if not cid then return end
    if event.data.registrants[cid] then
        Framework.Notify(source, 'You are already registered.', 'info')
        return
    end

    event.data.registrants[cid] = source
    AddParticipant(event_id, source)
    Framework.Notify(source, 'Registered for the underground race! Good luck.', 'success')

    -- Update registration count for all
    local new_count = count + 1
    TriggerClientEvent('serverdepth_events:client:Race:RegistrantUpdate', -1, {
        event_id = event_id,
        count    = new_count,
    })
end)

-- ─── Net: Checkpoint Crossed ─────────────────────────────────

RegisterNetEvent('serverdepth_events:server:CheckpointCrossed', function(event_id, checkpoint_index)
    local source = source
    local event  = GetEvent(event_id)
    if not event or not event.data.started then return end

    local cid = Framework.GetCitizenId(source)
    if not cid then return end
    if not event.data.registrants[cid] then return end

    local expected = event.data.checkpoint_progress[cid] or 1
    if checkpoint_index ~= expected then return end   -- out-of-order cheat prevention

    local checkpoints = event.data.circuit.checkpoints or {}

    -- Server-side proximity check
    local player_coords = Framework.GetCoords(source)
    if player_coords and checkpoints[checkpoint_index] then
        local cp_vec = checkpoints[checkpoint_index]
        -- cp_vec may be vector3 or vector4; extract xyz
        local cp3 = vector3(cp_vec.x, cp_vec.y, cp_vec.z)
        local dist = #(player_coords - cp3)
        if dist > 30.0 then
            -- Too far from checkpoint — ignore
            return
        end
    end

    event.data.checkpoint_progress[cid] = expected + 1

    -- Was that the last checkpoint? (finish line)
    if expected >= #checkpoints then
        -- Racer finished
        local already_finished = false
        for _, finished_cid in ipairs(event.data.finished) do
            if finished_cid == cid then already_finished = true break end
        end

        if not already_finished then
            event.data.finished[#event.data.finished + 1] = cid
            local position = #event.data.finished

            local tier_labels = { '1st', '2nd', '3rd' }
            local tier_keys   = { 'first', 'second', 'third' }
            local tier        = event.config.rewards and event.config.rewards[tier_keys[position]]
            local tier_label  = tier_labels[position] or (tostring(position) .. 'th')

            if position <= 3 then
                GrantRacerReward(source, cid, tier, tier_label, MODULE)
            end

            -- Announce finish position
            local player_name = Framework.GetPlayerName(source)
            if Config.Notifications.chat then
                TriggerClientEvent('chat:addMessage', -1, {
                    color = { 255, 200, 0 },
                    multiline = true,
                    args = {
                        '[Events]',
                        ('%s finished the race in %s place!'):format(player_name, tier_label),
                    },
                })
            end

            -- End race after all registered racers finish OR after 1st place finishes
            -- (server ends automatically once 1st-place crosses the line)
            if position == 1 then
                -- Wait 60 sec for others to finish before closing
                SetTimeout(60000, function()
                    if GetEvent(event_id) then
                        EndWorldEvent(event_id, cid, {})
                    end
                end)
            end
        end
    end
end)

-- ─── Register ────────────────────────────────────────────────

RegisterEventHandlers(MODULE, {
    Start = Start,
    End   = End,
})
