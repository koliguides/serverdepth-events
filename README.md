# ServerDepth Events

A dynamic world events engine for FiveM RP servers. Four pre-built event types — Cargo Drop, Armored Truck Heist, Underground Race, and Hidden Stash — fire automatically on a configurable random schedule or on demand via admin commands. Players are notified through animated NUI banners, map blips, and chat messages, then race to participate and win cash, inventory items, and optional criminal reputation. The entire system is modular: admins can register additional custom event types from a single config file without touching engine code.

---

## Features

- **Cargo Drop** — A military crate is airdropped to a random map location. First player to reach it claims the loot.
- **Armored Truck Heist** — A guarded stockade drives a configurable route. Players must destroy the truck or eliminate guards to share the cash payout.
- **Underground Race** — A timed registration window opens, racers are teleported to a start line, and first across the finish line wins. Top 3 receive tiered rewards.
- **Hidden Stash** — A cryptic text clue is broadcast. After a configurable delay the blip reveals on the map. First player to the location claims the stash.
- **Modular event types** — Add custom events by adding a Config.EventTypes entry and a matching server/events/<name>.lua module.
- **Weighted random scheduling** — Each event type has a weight value. Higher weight = picked more often. Cooldowns prevent the same event from firing back-to-back.
- **Server-authoritative** — All reward claims are validated server-side with distance checks. No client can fake a claim.
- **Framework auto-detection** — Supports Qbox (primary) and QBCore (fallback) with unified helpers.
- **ox_inventory rewards** — Items are added directly via `exports.ox_inventory:AddItem`.
- **Optional reputation integration** — Wraps `exports['serverdepth_reputation']:AddReputation` in pcall so the resource works standalone.
- **Full DB logging** — Every event start, end, winner, and reward is recorded to `events_log`.
- **ox_lib UI** — Notifications use ox_lib's notify component. Progress bars use ox_lib where applicable.

---

## Installation

1. **Copy the resource** to your server's `resources/` directory.
   ```
   resources/[standalone]/serverdepth_events/
   ```

2. **Run the SQL script** against your database (optional — the resource also auto-creates the table):
   ```sql
   SOURCE resources/[standalone]/serverdepth_events/sql/install.sql;
   ```

3. **Add to server.cfg**:
   ```
   ensure serverdepth_events
   ```

4. **Configure** `config.lua` to match your server (see Configuration section below).

5. **Restart** the resource or restart your server.

**Dependencies that must be running first:**
- `oxmysql`
- `ox_lib`
- `ox_inventory`
- `qbx_core` (Qbox) **or** `qb-core` (QBCore)

---

## Configuration

All configuration lives in `config.lua`. No other files need to be edited for basic setup.

### `Config.Scheduler`

| Key | Type | Description |
|-----|------|-------------|
| `enabled` | bool | Set to `false` to disable automatic scheduling entirely. |
| `interval_min` | number | Minimum minutes between automatic events. |
| `interval_max` | number | Maximum minutes between automatic events. |
| `max_concurrent` | number | Maximum number of events that can run simultaneously. |

### `Config.Notifications`

| Key | Type | Description |
|-----|------|-------------|
| `chat` | bool | Announce event start/end in global chat. |
| `nui_banner` | bool | Show the animated slide-in banner at the top of the screen. |
| `map_blip` | bool | Add a flashing blip to the minimap. |
| `gps_waypoint` | bool | Automatically set a GPS waypoint (disable if your players find it intrusive). |

### `Config.AdminGroups`

Array of ACE permission strings. Players with any of these ACE groups can use `/trigger_event`, `/cancel_event`, `/event_cooldowns`, and `/clearcooldown`.

```lua
Config.AdminGroups = { 'group.admin', 'group.superadmin' }
```

### `Config.IntegrateReputation`

Set to `true` if you also have `serverdepth_reputation` installed. When true, criminal events call `exports['serverdepth_reputation']:AddReputation(citizenid, 'criminal', amount, reason)`. The call is always wrapped in `pcall` so the resource functions fully without that dependency.

### Event Types — Common Fields

Each entry in `Config.EventTypes` supports:

| Key | Description |
|-----|-------------|
| `enabled` | `true`/`false` — exclude from scheduler if false |
| `weight` | Integer. Higher = chosen more frequently by the scheduler. |
| `cooldown_minutes` | Minimum gap before this event fires again. |
| `timeout_minutes` | Auto-cancel the event after this many minutes with no winner. |
| `rewards` | Cash range, item list with chances, criminal_rep amount. |

### Cargo Drop

```lua
cargo_drop = {
    spawn_zones = {
        { coords = vector3(...), label = 'Sandy Shores Desert' },
    },
    claim_radius = 3.0,          -- metres player must be within
    crate_prop   = 'prop_mil_crate_01',
    rewards = {
        cash         = { min = 5000, max = 15000 },
        criminal_rep = 15,
        items = {
            { item = 'lockpick', amount = 5, chance = 1.0 },
        },
    },
}
```

### Armored Truck

```lua
armored_truck = {
    truck_model  = 'stockade',
    truck_health = 2000.0,
    guard_count  = 4,
    route = { vector3(...), vector3(...) },   -- waypoints in order
    drive_speed  = 18.0,    -- m/s
    rewards = {
        cash = { min = 20000, max = 50000 },
        police_alert = true,
    },
}
```

Set `police_alert = true` to broadcast a police dispatch notification to on-duty officers.

### Underground Race

```lua
underground_race = {
    registration_duration = 300,   -- seconds
    min_racers = 2,
    max_racers = 12,
    police_alert_threshold = 6,    -- alert if >= N register
    circuits = {
        {
            label        = 'Storm Drain Loop',
            start_coords = vector4(x, y, z, heading),
            finish_coords = vector3(x, y, z),
            checkpoints  = { vector3(...), vector3(...) },
        },
    },
    rewards = {
        first  = { cash = 25000, criminal_rep = 20 },
        second = { cash = 10000 },
        third  = { cash = 5000 },
    },
}
```

### Hidden Stash

```lua
hidden_stash = {
    clue_delay_seconds = 120,   -- blip appears after this many seconds
    claim_radius       = 2.0,
    locations = {
        { coords = vector3(...), heading = 0.0, clue = 'Your cryptic hint here.' },
    },
    loot_table = {
        { item = 'lockpick', amount = 3, chance = 1.0 },
        { item = 'money',    amount = 3500, chance = 1.0 },   -- 'money' is paid as cash
    },
}
```

Note: Items with `item = 'money'` are treated as cash and paid via `Framework.AddMoney`, not ox_inventory.

---

## How to Add a Custom Event Type

### Step 1 — Add to config.lua

```lua
Config.EventTypes['my_custom_event'] = {
    enabled          = true,
    weight           = 20,
    cooldown_minutes = 30,
    timeout_minutes  = 15,
    spawn_zones = {
        { coords = vector3(0.0, 0.0, 0.0), label = 'Example Location' },
    },
    rewards = {
        cash = { min = 1000, max = 5000 },
    },
}
```

### Step 2 — Create server/events/my_custom_event.lua

```lua
-- server/events/my_custom_event.lua

local MODULE = 'my_custom_event'

--- Called when the scheduler (or admin) fires this event.
---@param event_id  string  Unique event ID
---@param config    table   Your Config.EventTypes entry
---@param event     table   Live event record (event.data is your scratch space)
local function Start(event_id, config, event)
    -- Pick a spawn zone
    local zones = config.spawn_zones or {}
    local zone  = zones[math.random(1, #zones)]

    -- Store coords so the initial blip is placed correctly
    event.data.coords    = zone.coords
    event.data.claimed   = false
    config.spawn_label   = zone.label

    -- Notify clients to draw a marker / spawn props
    TriggerClientEvent('my_custom_event:client:Start', -1, {
        event_id = event_id,
        coords   = zone.coords,
    })
end

--- Called when the event is ended (timeout, claim, or admin cancel).
---@param event_id string
---@param event    table
local function End(event_id, event)
    TriggerClientEvent('my_custom_event:client:End', -1, { event_id = event_id })
end

-- Handle the claim from clients
RegisterNetEvent('my_custom_event:server:Claim', function(event_id)
    local source = source
    local event  = GetEvent(event_id)
    if not event or event.data.claimed then return end
    event.data.claimed = true

    local cid = Framework.GetCitizenId(source)
    Framework.AddMoney(source, math.random(
        event.config.rewards.cash.min,
        event.config.rewards.cash.max
    ), 'Custom Event Reward')

    EndWorldEvent(event_id, cid, {})
end)

-- Register with the engine
RegisterEventHandlers(MODULE, { Start = Start, End = End })
```

### Step 3 — Add to fxmanifest.lua

```lua
server_scripts {
    -- existing entries ...
    'server/events/my_custom_event.lua',
}
```

That is it. The scheduler will now include your event in the weighted pool.

---

## Exports

All exports are on the server side.

### `TriggerEvent(event_type, admin_source, triggered_by)`
Manually trigger an event.
```lua
local event_id, err = exports['serverdepth_events']:TriggerEvent('cargo_drop', source, 'admin')
```

### `EndEvent(event_id, winner_citizenid, rewards_given)`
Forcefully end a running event.
```lua
exports['serverdepth_events']:EndEvent('evt_cargo_drop_1234_5678', 'ABC123', {})
```

### `GetActiveEvents()`
Returns an array of all currently active event summaries.
```lua
local events = exports['serverdepth_events']:GetActiveEvents()
for _, ev in ipairs(events) do
    print(ev.event_id, ev.event_type, ev.label)
end
```

### `IsEventOnCooldown(event_type)`
Returns `true` if the named event type is on cooldown.
```lua
if exports['serverdepth_events']:IsEventOnCooldown('armored_truck') then
    print('Armored truck is cooling down')
end
```

### `AddParticipant(event_id, source)`
Register a player as a participant in an event. Called automatically on claim, but useful for custom events.
```lua
exports['serverdepth_events']:AddParticipant(event_id, source)
```

---

## Integration with serverdepth_reputation

If you run `serverdepth_reputation` on the same server, enable the integration by setting:

```lua
Config.IntegrateReputation = true
```

When a player wins an event that has a `criminal_rep` value in its rewards table, the engine calls:

```lua
exports['serverdepth_reputation']:AddReputation(citizenid, 'criminal', amount, 'Won ' .. event_type)
```

This call is always wrapped in `pcall`, so if `serverdepth_reputation` is not installed or throws an error, `serverdepth_events` continues functioning normally with no impact on gameplay. No additional configuration is required on the reputation side — the event engine uses its public export API directly.

---

## Commands

| Command | Access | Description |
|---------|--------|-------------|
| `/events` | Everyone | List all currently active events. |
| `/joinrace` | Everyone | Join an open underground race registration. |
| `/trigger_event [type]` | Admin | Manually fire a named event type. |
| `/cancel_event [event_id]` | Admin | Immediately end a running event. |
| `/event_cooldowns` | Admin | View remaining cooldown time for all event types. |
| `/clearcooldown [type]` | Admin | Clear the cooldown for a specific event type. |

Admin access is controlled by `Config.AdminGroups` (ACE permissions).

---

## Troubleshooting

**Events are not firing automatically.**
- Check that `Config.Scheduler.enabled` is `true`.
- Confirm that at least one event type is `enabled = true` in `Config.EventTypes`.
- Check the server console for cooldown messages — all events may be on cooldown simultaneously.
- Use `/event_cooldowns` to see remaining timers.

**"No handler registered for event type" error.**
- Ensure the corresponding `server/events/<type>.lua` file is listed in `fxmanifest.lua` under `server_scripts`.
- Check for Lua syntax errors in the module file.

**Items are not being given.**
- Confirm `ox_inventory` is listed in `dependencies` in `fxmanifest.lua` and is running before this resource.
- Check the item name matches exactly what is registered in ox_inventory's items data.

**"Could not load model" warning for props/vehicles.**
- The model string in config must match a valid GTA V model name (lowercase, no spaces).
- For custom add-on vehicles, ensure the vehicle resource is loaded before this one.

**Armored truck doesn't drive.**
- The driver NPC needs network ownership. If the server has many players spread across the map, consider a "host player" approach or use server-side NPC control via a dedicated resource.
- Verify the route coordinates are on driveable roads at the correct Z (ground level) height.

**Race has 0 registrants and always cancels.**
- Ensure players are using `/joinrace` or clicking the NUI "Join Race" button during the registration window.
- Verify `min_racers` in config is not set higher than your typical concurrent player count.

**NUI banner doesn't appear.**
- Confirm `Config.Notifications.nui_banner = true`.
- Check browser DevTools console (F8 in FiveM) for JavaScript errors.
- Ensure `ui_page 'html/index.html'` is present in `fxmanifest.lua`.

---

## Changelog

**1.0.0** — Initial release with 4 event types: Cargo Drop, Armored Truck, Underground Race, Hidden Stash.

---

## License

Copyright (c) 2024 ServerDepth. All rights reserved.

This resource is sold under a single-server license. You may not redistribute, resell, leak, or share the source code. Modification for personal use on your licensed server is permitted. Resale of modified versions is prohibited.

---

## Support

**Email:** support@serverdepth.io

Please include your server framework (Qbox/QBCore), resource version, and the relevant server console output when submitting a support request.
