-- ============================================================
--  ServerDepth Events — client/main.lua
--  Client-side event manager.
--  Handles incoming event broadcasts, map blips, GPS waypoints,
--  and the active events panel keybind (F8).
-- ============================================================

-- ─── State ───────────────────────────────────────────────────

--- [event_id] = { event_type, label, coords, blip_handle, started_at }
local ActiveEventBlips = {}

local PanelOpen = false

-- ─── Utilities ───────────────────────────────────────────────

--- Add a blip to the minimap for an event.
---@param event_id   string
---@param coords     vector3|table
---@param blip_cfg   table|nil   { sprite, colour, scale }
---@param label      string
---@return number  blip handle
local function AddEventBlip(event_id, coords, blip_cfg, label)
    if not Config.Notifications.map_blip then return -1 end
    if not coords then return -1 end

    local sprite = blip_cfg and blip_cfg.sprite or 522
    local colour = blip_cfg and blip_cfg.colour or 5
    local scale  = blip_cfg and blip_cfg.scale  or 0.9

    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, sprite)
    SetBlipColour(blip, colour)
    SetBlipScale(blip, scale)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(label or event_id)
    EndTextCommandSetBlipName(blip)
    ShowNumberOnBlip(blip, -1)   -- remove number badge
    SetBlipFlashes(blip, true)   -- flash to stand out

    return blip
end

--- Remove a blip if it is valid.
---@param handle number
local function RemoveEventBlip(handle)
    if handle and handle ~= -1 and DoesBlipExist(handle) then
        RemoveBlip(handle)
    end
end

--- Set the GPS waypoint for a player (respects Config.Notifications.gps_waypoint).
---@param coords vector3|table
local function SetGPSWaypoint(coords)
    if not Config.Notifications.gps_waypoint then return end
    if not coords then return end
    SetNewWaypoint(coords.x, coords.y)
end

-- ─── New Event Received ──────────────────────────────────────

RegisterNetEvent('serverdepth_events:client:NewEvent', function(data)
    if not data or not data.event_id then return end

    local event_id   = data.event_id
    local event_type = data.event_type or 'unknown'
    local label      = data.label      or event_type
    local coords     = data.coords
    local blip_cfg   = data.blip

    -- Add blip
    local blip_handle = AddEventBlip(event_id, coords, blip_cfg, label)

    -- Store locally
    ActiveEventBlips[event_id] = {
        event_id   = event_id,
        event_type = event_type,
        label      = label,
        coords     = coords,
        blip       = blip_handle,
        started_at = GetGameTimer(),
    }

    -- Optional GPS waypoint
    SetGPSWaypoint(coords)

    -- NUI banner notification
    if Config.Notifications.nui_banner then
        SendNUIMessage({
            action     = 'showBanner',
            event_type = event_type,
            label      = label,
            coords     = coords,
            event_id   = event_id,
        })
    end

    -- Chat notification (rendered by server; client only gets NUI/blip)
    -- (Server already triggers chat:addMessage for all players)
end)

-- ─── Event Ended ─────────────────────────────────────────────

RegisterNetEvent('serverdepth_events:client:EventEnded', function(data)
    if not data or not data.event_id then return end

    local event_id = data.event_id
    local entry    = ActiveEventBlips[event_id]

    if entry then
        RemoveEventBlip(entry.blip)
        ActiveEventBlips[event_id] = nil
    end

    -- Remove from NUI panel
    SendNUIMessage({
        action   = 'removeEvent',
        event_id = event_id,
    })
end)

-- ─── Active Events List (from server) ────────────────────────

RegisterNetEvent('serverdepth_events:client:ActiveEventsList', function(events)
    SendNUIMessage({
        action = 'updateEventsList',
        events = events,
    })
end)

-- ─── Police Alert ────────────────────────────────────────────
-- Police-side clients receive this if they are on duty as a cop.
-- Non-cop players safely ignore it (or could show a discrete notification).

RegisterNetEvent('serverdepth_events:client:PoliceAlert', function(data)
    -- Determine if this player is a cop via job check
    local is_police = false
    local ok = pcall(function()
        if GetResourceState('qbx_core') ~= 'missing' then
            local player = exports['qbx_core']:GetPlayerData()
            if player and player.job and (player.job.name == 'police' or player.job.name == 'sheriff') then
                is_police = true
            end
        elseif GetResourceState('qb-core') ~= 'missing' then
            local QBCore  = exports['qb-core']:GetCoreObject()
            local player  = QBCore.Functions.GetPlayerData()
            if player and player.job and (player.job.name == 'police' or player.job.name == 'sheriff') then
                is_police = true
            end
        end
    end)

    if not ok or not is_police then return end

    -- Notify cop via ox_lib
    lib.notify({
        title       = 'Police Dispatch',
        description = data.message or 'Criminal activity reported.',
        type        = 'error',
        duration    = 10000,
        icon        = 'shield',
    })

    -- Optionally waypoint
    if data.coords then
        SetGPSWaypoint(data.coords)
    end
end)

-- ─── F8 Toggle Panel ─────────────────────────────────────────

RegisterKeyMapping('sd_events_panel', 'Toggle Events Panel', 'keyboard', 'F8')

RegisterCommand('sd_events_panel', function()
    PanelOpen = not PanelOpen
    SendNUIMessage({ action = 'togglePanel', open = PanelOpen })
    SetNuiFocus(PanelOpen, PanelOpen)

    -- If opening, request fresh event list
    if PanelOpen then
        TriggerServerEvent('serverdepth_events:server:GetActiveEvents')
    end
end, false)

-- ─── NUI: Close panel ────────────────────────────────────────

RegisterNUICallback('closePanel', function(data, cb)
    PanelOpen = false
    SendNUIMessage({ action = 'togglePanel', open = false })
    SetNuiFocus(false, false)
    cb({ ok = true })
end)

-- ─── NUI: Set GPS Waypoint ────────────────────────────────────

RegisterNUICallback('setWaypoint', function(data, cb)
    if data and data.coords then
        SetNewWaypoint(data.coords.x, data.coords.y)
        lib.notify({ description = 'GPS waypoint set.', type = 'info', duration = 3000 })
    end
    cb({ ok = true })
end)

-- ─── NUI: Request event list refresh ─────────────────────────

RegisterNUICallback('refreshEvents', function(data, cb)
    TriggerServerEvent('serverdepth_events:server:GetActiveEvents')
    cb({ ok = true })
end)

-- ─── Escape to close ─────────────────────────────────────────
-- Handled in app.js as well, but we also handle it natively.

Citizen.CreateThread(function()
    while true do
        Wait(0)
        if PanelOpen and IsControlJustPressed(0, 200) then  -- ESCAPE = 200
            PanelOpen = false
            SendNUIMessage({ action = 'togglePanel', open = false })
            SetNuiFocus(false, false)
        end
    end
end)
