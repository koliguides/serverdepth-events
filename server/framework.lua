-- ============================================================
--  ServerDepth Events — server/framework.lua
--  Auto-detects Qbox or QBCore and exposes unified helper
--  functions used across all server-side modules.
--  Add additional framework bridges here if needed.
-- ============================================================

local Framework = {}
local _fw_name  = 'unknown'

-- ─── Detection ───────────────────────────────────────────────
-- Qbox exports its core as 'qbx_core'; QBCore exposes a global 'QBCore'.

local function DetectFramework()
    -- Try Qbox first (preferred)
    local ok, qbx = pcall(function()
        return exports['qbx_core']:GetCoreObject()
    end)
    if ok and qbx then
        _fw_name = 'qbox'
        Framework._core = qbx
        print('[^2ServerDepth Events^7] Framework detected: ^5Qbox^7')
        return
    end

    -- Fallback: QBCore
    if GetResourceState('qb-core') ~= 'missing' then
        local qb = exports['qb-core']:GetCoreObject()
        if qb then
            _fw_name = 'qbcore'
            Framework._core = qb
            print('[^2ServerDepth Events^7] Framework detected: ^5QBCore^7')
            return
        end
    end

    print('[^1ServerDepth Events^7] WARNING: No supported framework detected. '
        .. 'Cash rewards will be skipped. Install Qbox or QBCore.')
end

-- Run detection immediately at file load time so all subsequent
-- modules can call Framework helpers without waiting for a callback.
DetectFramework()

-- ─── GetFrameworkName ────────────────────────────────────────
--- Returns 'qbox', 'qbcore', or 'unknown'.
---@return string
function Framework.GetName()
    return _fw_name
end

-- ─── GetPlayer ───────────────────────────────────────────────
--- Returns the framework player object for a given server source.
---@param source number  Player server ID
---@return table|nil
function Framework.GetPlayer(source)
    if _fw_name == 'qbox' or _fw_name == 'qbcore' then
        return Framework._core.Functions.GetPlayer(source)
    end
    return nil
end

-- ─── GetPlayerByCitizenId ────────────────────────────────────
--- Returns the framework player object for a given citizenid.
---@param citizenid string
---@return table|nil
function Framework.GetPlayerByCitizenId(citizenid)
    if _fw_name == 'qbox' or _fw_name == 'qbcore' then
        return Framework._core.Functions.GetPlayerByCitizenId(citizenid)
    end
    return nil
end

-- ─── GetCitizenId ────────────────────────────────────────────
--- Returns the citizenid string for a player source.
---@param source number
---@return string|nil
function Framework.GetCitizenId(source)
    local player = Framework.GetPlayer(source)
    if not player then return nil end

    if _fw_name == 'qbox' then
        return player.citizenid
    elseif _fw_name == 'qbcore' then
        return player.PlayerData and player.PlayerData.citizenid
    end
    return nil
end

-- ─── GetPlayerName ───────────────────────────────────────────
--- Returns the character first+last name for a player source.
---@param source number
---@return string
function Framework.GetPlayerName(source)
    local player = Framework.GetPlayer(source)
    if not player then return ('Player %d'):format(source) end

    local firstname, lastname = '', ''

    if _fw_name == 'qbox' then
        firstname = player.charinfo and player.charinfo.firstname or ''
        lastname  = player.charinfo and player.charinfo.lastname  or ''
    elseif _fw_name == 'qbcore' then
        local pd  = player.PlayerData
        firstname = pd and pd.charinfo and pd.charinfo.firstname or ''
        lastname  = pd and pd.charinfo and pd.charinfo.lastname  or ''
    end

    local name = (('%s %s'):format(firstname, lastname)):match('^%s*(.-)%s*$')
    return (#name > 0) and name or ('Player %d'):format(source)
end

-- ─── AddMoney ────────────────────────────────────────────────
--- Add cash (dirty money) to a player. Falls back to bank if no cash account.
---@param source     number  Player server ID
---@param amount     number  Amount in dollars
---@param reason     string  Log reason
---@return boolean   true if money was added
function Framework.AddMoney(source, amount, reason)
    if amount <= 0 then return false end
    reason = reason or 'ServerDepth Events Reward'

    local player = Framework.GetPlayer(source)
    if not player then return false end

    local ok, err = pcall(function()
        if _fw_name == 'qbox' then
            -- Qbox uses exports directly
            exports['qbx_core']:AddMoney(source, 'cash', amount, reason)
        elseif _fw_name == 'qbcore' then
            player.Functions.AddMoney('cash', amount, reason)
        end
    end)

    if not ok then
        print(('[^1ServerDepth Events^7] AddMoney error for source %d: %s'):format(source, tostring(err)))
        return false
    end
    return true
end

-- ─── Notify ──────────────────────────────────────────────────
--- Send an ox_lib notification to a player.
---@param source   number  Server ID (0 = all players)
---@param message  string
---@param type     string  'success'|'error'|'info'|'warning'
---@param duration number  Milliseconds (default 5000)
function Framework.Notify(source, message, ntype, duration)
    ntype    = ntype    or 'info'
    duration = duration or 5000

    if source == 0 then
        -- Broadcast to all
        TriggerClientEvent('ox_lib:notify', -1, {
            type     = ntype,
            description = message,
            duration = duration,
        })
    else
        TriggerClientEvent('ox_lib:notify', source, {
            type        = ntype,
            description = message,
            duration    = duration,
        })
    end
end

-- ─── GetAllPlayers ───────────────────────────────────────────
--- Returns an array of all currently connected player source IDs.
---@return number[]
function Framework.GetAllPlayers()
    local sources = {}
    for _, source in ipairs(GetPlayers()) do
        sources[#sources + 1] = tonumber(source)
    end
    return sources
end

-- ─── HasAdminPermission ──────────────────────────────────────
--- Check if a player source has any of the configured admin ACE groups.
---@param source number
---@return boolean
function Framework.HasAdminPermission(source)
    if source == 0 then return true end  -- console is always admin
    for _, group in ipairs(Config.AdminGroups or {}) do
        if IsPlayerAceAllowed(tostring(source), group) then
            return true
        end
    end
    return false
end

-- ─── GetCoords ───────────────────────────────────────────────
--- Returns the current coords of a player (vector3).
---@param source number
---@return vector3|nil
function Framework.GetCoords(source)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

-- ─── FormatMoney ─────────────────────────────────────────────
--- Returns a formatted dollar string e.g. "$12,500"
---@param amount number
---@return string
function Framework.FormatMoney(amount)
    local s = tostring(math.floor(amount))
    local result = ''
    local len = #s
    for i = 1, len do
        if i > 1 and (len - i + 1) % 3 == 0 then
            result = result .. ','
        end
        result = result .. s:sub(i, i)
    end
    return '$' .. result
end

-- Expose as a global so all server modules can do Framework.XYZ
_G.Framework = Framework
