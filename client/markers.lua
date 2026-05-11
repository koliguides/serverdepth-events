-- ============================================================
--  ServerDepth Events — client/markers.lua
--  Manages:
--    - 3D markers drawn near event objectives
--    - Prop spawning / despawning (cargo crate, stash prop)
--    - NPC/vehicle spawning for Armored Truck
--    - Checkpoint markers for Underground Race
--    - Proximity-based claim trigger for Cargo Drop and Hidden Stash
-- ============================================================

-- ─── State ───────────────────────────────────────────────────

-- Marker draw list: [event_id] = { coords, type, size, colour, ... }
local ActiveMarkers = {}

-- Spawned props:  [event_id] = entity handle
local SpawnedProps = {}

-- Cargo Drop active claim zones: [event_id] = { coords, radius, claimed }
local CargoClaimZones = {}

-- Hidden Stash claim zones: [event_id] = { coords, radius, claimed }
local StashClaimZones = {}

-- Armored Truck tracking: [event_id] = { vehicle, guards=[], damage_reported }
local TruckData = {}

-- Race state: [event_id] = { checkpoints, finish, progress_index, vehicle }
local RaceData = {}

-- ─── Marker Draw Thread ──────────────────────────────────────
-- Runs at 0ms; only draws when player is within range to reduce overhead.

Citizen.CreateThread(function()
    while true do
        local sleep    = 1000
        local ped      = PlayerPedId()
        local my_pos   = GetEntityCoords(ped)
        local drew_any = false

        for event_id, marker in pairs(ActiveMarkers) do
            local dist = #(my_pos - marker.coords)
            if dist < 80.0 then
                sleep = 0
                drew_any = true
                DrawMarker(
                    marker.marker_type or 1,
                    marker.coords.x, marker.coords.y, marker.coords.z,
                    0.0, 0.0, 0.0,    -- direction
                    0.0, 0.0, 0.0,    -- rotation
                    marker.sx or 1.5, marker.sy or 1.5, marker.sz or 0.5,
                    marker.r or 255, marker.g or 153, marker.b or 0, marker.a or 180,
                    false, false, 2, false, nil, nil, false
                )
            end
        end

        -- Checkpoint markers for races
        for event_id, race in pairs(RaceData) do
            if race.checkpoints and race.progress_index then
                local cp_idx = race.progress_index
                if cp_idx <= #race.checkpoints then
                    local cp = race.checkpoints[cp_idx]
                    local cp3 = vector3(cp.x, cp.y, cp.z)
                    local dist = #(my_pos - cp3)
                    if dist < 120.0 then
                        sleep = 0
                        drew_any = true
                        -- Checkpoint cylinder marker (type 1)
                        DrawMarker(
                            1,
                            cp3.x, cp3.y, cp3.z,
                            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                            8.0, 8.0, 2.0,
                            255, 220, 0, 150,
                            false, false, 2, false, nil, nil, false
                        )
                        -- Finish line gets a different colour
                        if cp_idx == #race.checkpoints then
                            DrawMarker(
                                1,
                                cp3.x, cp3.y, cp3.z,
                                0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                                12.0, 12.0, 2.5,
                                50, 255, 50, 160,
                                false, false, 2, false, nil, nil, false
                            )
                        end
                    end
                end
            end
        end

        if not drew_any then sleep = 500 end
        Wait(sleep)
    end
end)

-- ─── Cargo Drop: Spawn Crate ─────────────────────────────────

RegisterNetEvent('serverdepth_events:client:CargoDrop:Start', function(data)
    local event_id     = data.event_id
    local coords       = data.coords
    local crate_model  = data.crate_model or 'prop_mil_crate_01'
    local claim_radius = data.claim_radius or 3.0

    -- Only one client needs to own the prop (the one who spawns it first will network it).
    -- We attempt spawn on all clients but check if already spawned.
    if SpawnedProps[event_id] then return end

    -- Load model
    local model_hash = GetHashKey(crate_model)
    RequestModel(model_hash)
    local wait_count = 0
    while not HasModelLoaded(model_hash) and wait_count < 100 do
        Wait(100)
        wait_count = wait_count + 1
    end

    if not HasModelLoaded(model_hash) then
        print(('[^3ServerDepth Events^7] Could not load model: %s'):format(crate_model))
        return
    end

    local prop = CreateObject(model_hash, coords.x, coords.y, coords.z, true, true, false)
    PlaceObjectOnGroundProperly(prop)
    FreezeEntityPosition(prop, true)
    SetModelAsNoLongerNeeded(model_hash)

    SpawnedProps[event_id] = prop

    -- Register marker
    ActiveMarkers[event_id] = {
        coords      = GetEntityCoords(prop),
        marker_type = 1,
        sx = 1.5, sy = 1.5, sz = 0.5,
        r = 255, g = 153, b = 0, a = 200,
    }

    -- Register claim zone
    CargoClaimZones[event_id] = {
        coords  = GetEntityCoords(prop),
        radius  = claim_radius,
        claimed = false,
    }
end)

RegisterNetEvent('serverdepth_events:client:CargoDrop:End', function(data)
    local event_id = data.event_id
    ActiveMarkers[event_id]   = nil
    CargoClaimZones[event_id] = nil

    local prop = SpawnedProps[event_id]
    if prop and DoesEntityExist(prop) then
        DeleteObject(prop)
    end
    SpawnedProps[event_id] = nil
end)

-- ─── Cargo Drop: Proximity Claim Thread ──────────────────────

Citizen.CreateThread(function()
    while true do
        Wait(500)
        local ped    = PlayerPedId()
        local my_pos = GetEntityCoords(ped)

        for event_id, zone in pairs(CargoClaimZones) do
            if not zone.claimed then
                local dist = #(my_pos - zone.coords)
                if dist <= zone.radius then
                    zone.claimed = true   -- prevent repeated triggers
                    TriggerServerEvent('serverdepth_events:server:ClaimCargoDrop', event_id)
                end
            end
        end
    end
end)

-- ─── Hidden Stash ────────────────────────────────────────────

-- When clue arrives, just show a floating 3D text / NUI notification.
-- (NUI side handled in nui.lua — here we wait for reveal to place marker.)

RegisterNetEvent('serverdepth_events:client:HiddenStash:Clue', function(data)
    -- NUI handles the banner; nothing to draw yet (no coords).
end)

RegisterNetEvent('serverdepth_events:client:HiddenStash:RevealBlip', function(data)
    local event_id = data.event_id
    local coords   = data.coords

    if not coords then return end

    -- Place a ground marker at the stash
    ActiveMarkers[event_id] = {
        coords      = coords,
        marker_type = 2,   -- cylinder ring
        sx = 1.0, sy = 1.0, sz = 0.3,
        r = 100, g = 220, b = 100, a = 200,
    }

    -- Register claim zone (2m radius)
    StashClaimZones[event_id] = {
        coords  = coords,
        radius  = 2.0,
        claimed = false,
    }
end)

RegisterNetEvent('serverdepth_events:client:HiddenStash:End', function(data)
    local event_id = data.event_id
    ActiveMarkers[event_id]   = nil
    StashClaimZones[event_id] = nil

    local prop = SpawnedProps[event_id]
    if prop and DoesEntityExist(prop) then
        DeleteObject(prop)
    end
    SpawnedProps[event_id] = nil
end)

-- ─── Hidden Stash: Proximity Claim Thread ────────────────────

Citizen.CreateThread(function()
    while true do
        Wait(500)
        local ped    = PlayerPedId()
        local my_pos = GetEntityCoords(ped)

        for event_id, zone in pairs(StashClaimZones) do
            if not zone.claimed then
                local dist = #(my_pos - zone.coords)
                if dist <= zone.radius then
                    zone.claimed = true
                    TriggerServerEvent('serverdepth_events:server:ClaimHiddenStash', event_id)
                end
            end
        end
    end
end)

-- ─── Armored Truck: Spawn Vehicle + Guards ───────────────────

RegisterNetEvent('serverdepth_events:client:ArmoredTruck:Start', function(data)
    local event_id    = data.event_id
    local spawn_coords = data.spawn_coords
    local route       = data.route
    local truck_model = data.truck_model  or 'stockade'
    local truck_hp    = data.truck_health or 2000.0
    local guard_count = data.guard_count  or 4
    local guard_model = data.guard_model  or 's_m_y_swat_01'
    local drive_speed = data.drive_speed  or 18.0

    -- Only the player with the lowest session time / closest to spawn should own this.
    -- We use a simple "only spawn if no one else has" approach via a short stagger.
    -- All clients attempt after 0–2s random delay; first to succeed becomes owner.
    local stagger_ms = math.random(0, 2000)
    Wait(stagger_ms)

    -- Check if already spawned (another client got there first, entity network synced)
    if TruckData[event_id] then return end

    -- Load truck model
    local t_hash = GetHashKey(truck_model)
    RequestModel(t_hash)
    local wc = 0
    while not HasModelLoaded(t_hash) and wc < 150 do Wait(100); wc = wc + 1 end
    if not HasModelLoaded(t_hash) then return end

    local truck = CreateVehicle(
        t_hash,
        spawn_coords.x, spawn_coords.y, spawn_coords.z,
        spawn_coords.w or 0.0,
        true, false
    )
    SetVehicleEngineOn(truck, true, true, false)
    SetEntityInvincible(truck, false)
    SetVehicleBodyHealth(truck, truck_hp)
    SetVehicleEngineHealth(truck, truck_hp)
    SetVehicleMaxSpeed(truck, drive_speed)
    SetModelAsNoLongerNeeded(t_hash)

    -- Load guard model
    local g_hash = GetHashKey(guard_model)
    RequestModel(g_hash)
    wc = 0
    while not HasModelLoaded(g_hash) and wc < 100 do Wait(100); wc = wc + 1 end

    local guards = {}
    for i = 1, guard_count do
        local guard = CreatePed(4, g_hash, spawn_coords.x, spawn_coords.y, spawn_coords.z, 0.0, true, false)
        SetPedIntoVehicle(guard, truck, i - 1)   -- seat 0 = driver, 1+ = passengers
        SetPedAsCop(guard, true)
        SetPedRelationshipGroupHash(guard, GetHashKey('COP'))
        GiveWeaponToPed(guard, GetHashKey('WEAPON_COMBATPISTOL'), 120, false, true)
        SetPedDropsWeaponsOnDeath(guard, false)
        guards[i] = guard
    end

    SetModelAsNoLongerNeeded(g_hash)

    TruckData[event_id] = {
        vehicle          = truck,
        guards           = guards,
        guard_count      = guard_count,
        guards_killed    = 0,
        damage_reported  = 0.0,
        destroyed        = false,
        route            = route,
        route_idx        = 2,   -- start driving towards waypoint 2
    }

    -- Register marker at current position (moves in thread below)
    ActiveMarkers[event_id] = {
        coords      = GetEntityCoords(truck),
        marker_type = 1,
        sx = 2.5, sy = 2.5, sz = 1.0,
        r = 255, g = 80, b = 80, a = 160,
    }

    -- Task truck to drive the route
    if route and #route >= 2 then
        local wp = route[2]
        TaskVehicleDriveToCoord(
            GetPedInVehicleSeat(truck, -1),  -- driver ped
            truck,
            wp.x, wp.y, wp.z,
            drive_speed,
            0,
            GetHashKey(truck_model),
            786603,   -- driving style: normal roads + avoid hazards
            2.0,
            1.0
        )
    end
end)

RegisterNetEvent('serverdepth_events:client:ArmoredTruck:End', function(data)
    local event_id = data.event_id
    ActiveMarkers[event_id] = nil

    local td = TruckData[event_id]
    if td then
        if td.vehicle and DoesEntityExist(td.vehicle) then
            DeleteVehicle(td.vehicle)
        end
        for _, guard in ipairs(td.guards or {}) do
            if DoesEntityExist(guard) then DeletePed(guard) end
        end
        TruckData[event_id] = nil
    end
end)

-- ─── Armored Truck: Damage + Guard Kill Tracking ─────────────

Citizen.CreateThread(function()
    while true do
        Wait(1000)
        local ped    = PlayerPedId()
        local my_pos = GetEntityCoords(ped)

        for event_id, td in pairs(TruckData) do
            if DoesEntityExist(td.vehicle) and not td.destroyed then
                -- Update marker position
                local truck_coords = GetEntityCoords(td.vehicle)
                if ActiveMarkers[event_id] then
                    ActiveMarkers[event_id].coords = truck_coords
                end

                -- Check truck destruction
                if IsEntityDead(td.vehicle) and not td.destroyed then
                    td.destroyed = true
                    TriggerServerEvent('serverdepth_events:server:TruckDestroyed', event_id)
                end

                -- Report damage dealt if player is nearby (within 60m)
                local dist = #(my_pos - truck_coords)
                if dist < 60.0 then
                    local cur_hp = GetVehicleBodyHealth(td.vehicle)
                    local delta  = td.last_hp and (td.last_hp - cur_hp) or 0
                    if delta > 5 then
                        TriggerServerEvent('serverdepth_events:server:TruckDamage', event_id, delta)
                    end
                    td.last_hp = cur_hp
                end

                -- Check guard kills
                for i, guard in ipairs(td.guards) do
                    if DoesEntityExist(guard) and IsEntityDead(guard) and not td.guard_dead_flags then
                        td.guard_dead_flags = td.guard_dead_flags or {}
                        if not td.guard_dead_flags[i] then
                            td.guard_dead_flags[i] = true
                            td.guards_killed = (td.guards_killed or 0) + 1
                            TriggerServerEvent('serverdepth_events:server:TruckGuardKilled', event_id)
                        end
                    end
                end

                -- Route progression
                if td.route and td.route_idx <= #td.route then
                    local wp    = td.route[td.route_idx]
                    local wp3   = vector3(wp.x, wp.y, wp.z)
                    local t_dist = #(truck_coords - wp3)
                    if t_dist < 15.0 then
                        td.route_idx = td.route_idx + 1
                        if td.route_idx <= #td.route then
                            local next_wp = td.route[td.route_idx]
                            local driver  = GetPedInVehicleSeat(td.vehicle, -1)
                            if driver and driver ~= 0 then
                                TaskVehicleDriveToCoord(
                                    driver, td.vehicle,
                                    next_wp.x, next_wp.y, next_wp.z,
                                    td.drive_speed or 18.0,
                                    0,
                                    GetHashKey('stockade'),
                                    786603, 2.0, 1.0
                                )
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- ─── Underground Race: Start ─────────────────────────────────

RegisterNetEvent('serverdepth_events:client:Race:Start', function(data)
    local event_id    = data.event_id
    local start_pos   = data.start_coords
    local checkpoints = data.checkpoints
    local finish      = data.finish_coords

    -- Teleport player to start line
    local ped = PlayerPedId()
    SetEntityCoords(ped, start_pos.x, start_pos.y, start_pos.z, false, false, false, true)
    SetEntityHeading(ped, start_pos.w or 0.0)

    RaceData[event_id] = {
        checkpoints    = checkpoints,
        finish         = finish,
        progress_index = 1,
    }

    lib.notify({
        title       = 'Race Starting!',
        description = 'Follow the checkpoints to the finish line.',
        type        = 'inform',
        duration    = 8000,
        icon        = 'flag-checkered',
    })
end)

-- ─── Race: Checkpoint proximity thread ───────────────────────

Citizen.CreateThread(function()
    while true do
        Wait(300)
        local ped    = PlayerPedId()
        local my_pos = GetEntityCoords(ped)

        for event_id, race in pairs(RaceData) do
            local idx = race.progress_index
            if idx and race.checkpoints and idx <= #race.checkpoints then
                local cp  = race.checkpoints[idx]
                local cp3 = vector3(cp.x, cp.y, cp.z)
                local dist = #(my_pos - cp3)

                -- Trigger checkpoint when within 10m
                if dist <= 10.0 then
                    race.progress_index = idx + 1
                    TriggerServerEvent('serverdepth_events:server:CheckpointCrossed', event_id, idx)

                    lib.notify({
                        description = ('Checkpoint %d/%d!'):format(idx, #race.checkpoints),
                        type        = 'success',
                        duration    = 2000,
                    })

                    -- Set next checkpoint as GPS waypoint
                    local next_cp = race.checkpoints[race.progress_index]
                    if next_cp then
                        SetNewWaypoint(next_cp.x, next_cp.y)
                    end
                end
            end
        end
    end
end)

RegisterNetEvent('serverdepth_events:client:Race:End', function(data)
    local event_id = data.event_id
    RaceData[event_id] = nil
    ActiveMarkers[event_id] = nil
end)

-- ─── Race: Registration UI helpers ───────────────────────────

RegisterNetEvent('serverdepth_events:client:Race:RegistrantUpdate', function(data)
    -- Update NUI panel registrant count
    SendNUIMessage({
        action   = 'raceRegistrantUpdate',
        event_id = data.event_id,
        count    = data.count,
    })
end)

RegisterNetEvent('serverdepth_events:client:Race:RegistrationOpen', function(data)
    SendNUIMessage({
        action     = 'raceRegistrationOpen',
        event_id   = data.event_id,
        label      = data.label,
        duration   = data.duration,
        max_racers = data.max_racers,
    })
end)

RegisterNetEvent('serverdepth_events:client:Race:RegistrationClosed', function(data)
    SendNUIMessage({ action = 'raceRegistrationClosed', event_id = data.event_id })
end)
