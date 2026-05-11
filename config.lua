-- ============================================================
--  ServerDepth Events — config.lua
--  Central configuration for all event types, scheduling,
--  notifications, admin groups, and integrations.
--  Edit this file to customise behaviour without touching logic.
-- ============================================================

Config = {}

-- ─── Scheduler ──────────────────────────────────────────────
-- Controls how often the engine automatically fires a new event.

Config.Scheduler = {
    enabled       = true,   -- false to disable automatic scheduling entirely
    interval_min  = 20,     -- minimum minutes between automatic events
    interval_max  = 40,     -- maximum minutes between automatic events
    max_concurrent = 2,     -- how many events may run at the same time
}

-- ─── Notifications ──────────────────────────────────────────
-- Toggle each notification channel independently.

Config.Notifications = {
    chat       = true,      -- announce in global chat
    nui_banner = true,      -- slide-in NUI banner at top of screen
    map_blip   = true,      -- add blip to minimap for event location
    gps_waypoint = false,   -- automatically set GPS waypoint (can be annoying)
}

-- ─── Admin Groups ────────────────────────────────────────────
-- ACE permission groups allowed to use admin-only commands.

Config.AdminGroups = {
    'group.admin',
    'group.superadmin',
    'serverdepth.events.admin',
}

-- ─── Optional Integration ────────────────────────────────────
-- When true, criminal events call exports['serverdepth_reputation']:AddReputation.
-- The call is always wrapped in pcall so this resource works standalone.

Config.IntegrateReputation = false

-- ─── Blip Settings ───────────────────────────────────────────
Config.Blips = {
    cargo_drop      = { sprite = 522, colour = 5,  scale = 0.9 },  -- parachute
    armored_truck   = { sprite = 726, colour = 3,  scale = 1.0 },  -- truck
    underground_race = { sprite = 56,  colour = 2,  scale = 0.9 },  -- race flag
    hidden_stash    = { sprite = 605, colour = 2,  scale = 0.8 },  -- pickup
}

-- ─── Event Types ─────────────────────────────────────────────
-- Each key must match a server/events/<key>.lua module.
-- weight  : relative probability (higher = chosen more often)
-- cooldown_minutes : minimum gap before this event fires again

Config.EventTypes = {

    -- ── Cargo Drop ───────────────────────────────────────────
    cargo_drop = {
        enabled          = true,
        weight           = 30,
        cooldown_minutes = 45,
        timeout_minutes  = 20,

        -- Possible spawn zones – one is chosen at random each trigger.
        spawn_zones = {
            {
                coords = vector3(2046.47, 4796.95, 41.07),
                label  = 'Sandy Shores Desert',
                heading = 0.0,
            },
            {
                coords = vector3(-446.41, 5505.34, 79.91),
                label  = 'Mount Chiliad Plateau',
                heading = 0.0,
            },
            {
                coords = vector3(-892.60, 5154.50, 21.68),
                label  = 'Paleto Forest Clearing',
                heading = 0.0,
            },
            {
                coords = vector3(1136.12, -2045.84, 31.37),
                label  = 'Los Santos Airport Perimeter',
                heading = 0.0,
            },
            {
                coords = vector3(493.78, 5596.01, 85.63),
                label  = 'Grapeseed Airfield',
                heading = 0.0,
            },
        },

        claim_radius = 3.0,   -- metres player must be within to claim

        rewards = {
            cash         = { min = 5000,  max = 15000 },
            criminal_rep = 15,
            items = {
                { item = 'weapon_pistol',  amount = 1, chance = 0.30 },
                { item = 'lockpick',       amount = 5, chance = 1.00 },
                { item = 'radio',          amount = 1, chance = 0.50 },
                { item = 'bandage',        amount = 3, chance = 0.80 },
                { item = 'phone',          amount = 1, chance = 0.20 },
            },
        },

        -- Prop model spawned at the drop site
        crate_prop = 'prop_mil_crate_01',
    },

    -- ── Armored Truck ─────────────────────────────────────────
    armored_truck = {
        enabled          = true,
        weight           = 20,
        cooldown_minutes = 60,
        timeout_minutes  = 15,

        truck_model  = 'stockade',
        truck_health = 2000.0,
        guard_count  = 4,
        guard_model  = 's_m_y_swat_01',

        -- Route waypoints – truck drives between these in order
        route = {
            vector3(375.43, -1612.46, 29.30),   -- LSIA cargo gate
            vector3(75.21,  -1941.01, 20.77),   -- Port of LS south
            vector3(362.11, -2168.62, 5.69),    -- port warehouse
            vector3(700.79, -2097.34, 14.05),   -- container yard
            vector3(955.44, -1757.54, 30.67),   -- east vinewood blvd
        },

        drive_speed = 18.0,   -- m/s (≈ 65 km/h)

        rewards = {
            cash         = { min = 20000, max = 50000 },
            criminal_rep = 25,
            police_alert = true,
            items = {
                { item = 'goldbar',     amount = 2, chance = 0.40 },
                { item = 'weapon_pistol', amount = 1, chance = 0.60 },
                { item = 'lockpick',    amount = 3, chance = 1.00 },
            },
        },

        -- Broadcast label for notifications
        spawn_label = 'Port of Los Santos',
    },

    -- ── Underground Race ──────────────────────────────────────
    underground_race = {
        enabled          = true,
        weight           = 25,
        cooldown_minutes = 30,
        timeout_minutes  = 25,

        registration_duration = 300,  -- seconds players can join (5 min)
        min_racers            = 2,    -- cancel if fewer join
        max_racers            = 12,

        police_alert_threshold = 6,   -- alert if >= N racers registered

        -- Available race circuits – one is chosen at random
        circuits = {
            {
                label = 'Los Santos Storm Drain',
                start_coords  = vector4(277.34, -731.90, 29.31, 316.0),
                finish_coords = vector3(194.29, -1150.70, 23.38),
                checkpoints = {
                    vector3(211.70, -820.10, 30.50),
                    vector3(180.50, -940.80, 28.00),
                    vector3(194.29, -1150.70, 23.38),
                },
            },
            {
                label = 'Del Perro Freeway Loop',
                start_coords  = vector4(-1400.17, -472.78, 33.43, 85.0),
                finish_coords = vector3(-1079.13, -440.70, 36.69),
                checkpoints = {
                    vector3(-1200.20, -440.00, 35.50),
                    vector3(-1079.13, -440.70, 36.69),
                },
            },
            {
                label = 'Sandy Shores Dirttrack',
                start_coords  = vector4(1830.74, 3685.75, 34.28, 90.0),
                finish_coords = vector3(2185.61, 3678.86, 32.99),
                checkpoints = {
                    vector3(1970.00, 3700.50, 33.50),
                    vector3(2100.00, 3690.00, 33.10),
                    vector3(2185.61, 3678.86, 32.99),
                },
            },
        },

        rewards = {
            first  = { cash = 25000, criminal_rep = 20, items = { { item = 'trophy', amount = 1, chance = 1.0 } } },
            second = { cash = 10000, criminal_rep = 10 },
            third  = { cash = 5000,  criminal_rep = 5  },
        },
    },

    -- ── Hidden Stash ──────────────────────────────────────────
    hidden_stash = {
        enabled          = true,
        weight           = 25,
        cooldown_minutes = 20,
        timeout_minutes  = 30,

        clue_delay_seconds = 120,  -- show map blip after this many seconds
        claim_radius       = 2.0,  -- metres

        -- Stash locations with cryptic hints
        locations = {
            {
                coords  = vector3(1234.55, -3290.10, 5.90),
                heading = 0.0,
                clue    = 'Hidden near a rusted anchor by the industrial docks south of the city.',
            },
            {
                coords  = vector3(-222.09, 6241.47, 31.47),
                heading = 0.0,
                clue    = 'Tucked behind a fuel drum at the edge of the northern airstrip.',
            },
            {
                coords  = vector3(2692.95, 3281.72, 55.24),
                heading = 0.0,
                clue    = 'Stashed under a wooden pallet near the wind farm on the ridge.',
            },
            {
                coords  = vector3(-1043.70, -2745.64, 13.85),
                heading = 0.0,
                clue    = 'Buried beneath the graffiti wall on the south side of the scrap yard.',
            },
            {
                coords  = vector3(1737.27, 6412.16, 34.96),
                heading = 0.0,
                clue    = 'Concealed inside a dumpster at the Alamo Sea trailer park.',
            },
            {
                coords  = vector3(-426.61, 1127.79, 325.86),
                heading = 0.0,
                clue    = 'Left on a ledge halfway up the Vinewood Hills radio tower trail.',
            },
        },

        -- Random loot table: all items with matching chance are rolled independently
        loot_table = {
            { item = 'lockpick',           amount = 3,  chance = 1.00 },
            { item = 'money',              amount = 3500, chance = 1.00 },
            { item = 'weapon_pistol',      amount = 1,  chance = 0.25 },
            { item = 'weapon_switchblade', amount = 1,  chance = 0.40 },
            { item = 'armour_vest',        amount = 1,  chance = 0.35 },
            { item = 'bandage',            amount = 5,  chance = 0.80 },
            { item = 'goldbar',            amount = 1,  chance = 0.15 },
            { item = 'radio',              amount = 1,  chance = 0.50 },
            { item = 'phone',              amount = 1,  chance = 0.20 },
        },

        rewards = {
            criminal_rep = 10,
        },
    },
}
