-- ============================================================
--  ServerDepth Events — client/nui.lua
--  NUI ↔ Lua bridge layer.
--  Handles all NUI callbacks from the HTML frontend.
-- ============================================================

-- ─── Join Race (NUI button) ──────────────────────────────────

--- Called when the player clicks "Join Race" inside the NUI panel.
RegisterNUICallback('joinRace', function(data, cb)
    local event_id = data and data.event_id
    if not event_id then
        cb({ ok = false, error = 'No event_id provided' })
        return
    end
    TriggerServerEvent('serverdepth_events:server:JoinRace', event_id)
    cb({ ok = true })
end)

-- ─── Set Waypoint (NUI button) ────────────────────────────────

RegisterNUICallback('setWaypoint', function(data, cb)
    if data and data.coords then
        local c = data.coords
        SetNewWaypoint(c.x, c.y)
        lib.notify({ description = 'GPS waypoint set.', type = 'info', duration = 3000 })
        cb({ ok = true })
    else
        cb({ ok = false, error = 'No coords' })
    end
end)

-- ─── Close NUI panel ─────────────────────────────────────────

RegisterNUICallback('closePanel', function(data, cb)
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'togglePanel', open = false })
    cb({ ok = true })
end)

-- ─── Refresh Events List ─────────────────────────────────────

RegisterNUICallback('refreshEvents', function(data, cb)
    TriggerServerEvent('serverdepth_events:server:GetActiveEvents')
    cb({ ok = true })
end)
