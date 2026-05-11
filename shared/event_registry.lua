-- ============================================================
--  ServerDepth Events — shared/event_registry.lua
--  Central registry for event type definitions.
--  Shared between server and client so both sides can query
--  metadata (labels, blip info, etc.) without extra round-trips.
-- ============================================================

EventRegistry = EventRegistry or {}

-- Internal storage
local _registry  = {}       -- [name] = definition table
local _cooldowns = {}       -- [name] = unix timestamp when cooldown expires (server only)

-- ─── RegisterEventType ───────────────────────────────────────
--- Register a named event type with its definition.
--- Called automatically by each event module on load.
---@param name       string  Unique event type identifier (snake_case)
---@param definition table   Merged from Config.EventTypes[name] + module defaults
function EventRegistry.RegisterEventType(name, definition)
    assert(type(name)       == 'string', 'EventRegistry.RegisterEventType: name must be a string')
    assert(type(definition) == 'table',  'EventRegistry.RegisterEventType: definition must be a table')

    definition.name = name
    _registry[name] = definition

    if Config.Debug then
        print(('[^2ServerDepth Events^7] Registered event type: %s (weight=%d, enabled=%s)'):format(
            name,
            definition.weight   or 0,
            tostring(definition.enabled ~= false)
        ))
    end
end

-- ─── GetEventType ────────────────────────────────────────────
--- Retrieve a single event type definition by name.
---@param name string
---@return table|nil
function EventRegistry.GetEventType(name)
    return _registry[name]
end

-- ─── GetAllEvents ────────────────────────────────────────────
--- Return a shallow copy of all registered event definitions.
---@return table
function EventRegistry.GetAllEvents()
    local result = {}
    for k, v in pairs(_registry) do
        result[k] = v
    end
    return result
end

-- ─── GetEnabledEvents ────────────────────────────────────────
--- Return a list (array) of event definitions that are enabled.
---@return table[]
function EventRegistry.GetEnabledEvents()
    local result = {}
    for _, def in pairs(_registry) do
        if def.enabled ~= false then
            result[#result + 1] = def
        end
    end
    return result
end

-- ─── SetCooldown ─────────────────────────────────────────────
--- Mark an event type as on cooldown for cooldown_minutes.
--- Server-side only; silently ignored on client.
---@param name string
function EventRegistry.SetCooldown(name)
    if IsDuplicityVersion then   -- server check
        local def = _registry[name]
        if def and def.cooldown_minutes then
            _cooldowns[name] = os.time() + (def.cooldown_minutes * 60)
        end
    end
end

-- ─── IsOnCooldown ────────────────────────────────────────────
--- Check whether an event type is currently on cooldown.
--- Returns false on client (client has no authoritative cooldown data).
---@param name string
---@return boolean
function EventRegistry.IsOnCooldown(name)
    if not IsDuplicityVersion then return false end
    local expires = _cooldowns[name]
    if not expires then return false end
    return os.time() < expires
end

-- ─── GetCooldownRemaining ────────────────────────────────────
--- Returns remaining cooldown seconds for display, or 0 if not on cooldown.
---@param name string
---@return number
function EventRegistry.GetCooldownRemaining(name)
    if not IsDuplicityVersion then return 0 end
    local expires = _cooldowns[name]
    if not expires then return 0 end
    local remaining = expires - os.time()
    return math.max(0, remaining)
end

-- ─── ClearCooldown ───────────────────────────────────────────
--- Manually remove a cooldown (admin use).
---@param name string
function EventRegistry.ClearCooldown(name)
    _cooldowns[name] = nil
end

-- ─── PickWeightedEvent ───────────────────────────────────────
--- Select a random enabled, non-cooldown event type respecting weights.
--- Uses the weighted-reservoir / cumulative-weight algorithm so that
--- events with higher weight values are picked proportionally more often.
---@return table|nil  The chosen event definition, or nil if none eligible
function EventRegistry.PickWeightedEvent()
    local eligible = {}
    local total_weight = 0

    for _, def in pairs(_registry) do
        if def.enabled ~= false and not EventRegistry.IsOnCooldown(def.name) then
            eligible[#eligible + 1] = def
            total_weight = total_weight + (def.weight or 1)
        end
    end

    if #eligible == 0 or total_weight == 0 then
        return nil
    end

    local roll = math.random() * total_weight
    local cumulative = 0

    for _, def in ipairs(eligible) do
        cumulative = cumulative + (def.weight or 1)
        if roll <= cumulative then
            return def
        end
    end

    -- Fallback: return last eligible (handles floating-point edge cases)
    return eligible[#eligible]
end

-- ─── Bootstrap from Config ───────────────────────────────────
-- Auto-register every event type defined in Config.EventTypes on load.
-- Individual server-side event modules may call RegisterEventType again
-- to attach handler references (Start/End functions).
if Config and Config.EventTypes then
    for name, def in pairs(Config.EventTypes) do
        -- Merge the config table into the registry;
        -- modules will overwrite with their enriched definition.
        local entry = {}
        for k, v in pairs(def) do entry[k] = v end
        entry.name = name
        _registry[name] = entry
    end
end
