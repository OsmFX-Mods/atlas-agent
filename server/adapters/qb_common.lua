-- QB family: helpers shared by the Qbox and QBCore adapters, which keep characters in the same players table layout.

local common = AtlasLib.common

local Q = {}
Atlas.qb = Q

--- Name: a character's first and last name from PlayerData.charinfo, or nil.
function Q.charName(pd)
    local ci = type(pd) == 'table' and pd.charinfo
    if type(ci) == 'table' and type(ci.firstname) == 'string' then
        return ('%s %s'):format(ci.firstname, type(ci.lastname) == 'string' and ci.lastname or '')
    end
end

--- Account characters: citizenid to name for every character of a player's account; nil when the database cannot tell.
--- @param tableName string the configured characters table
--- @param p table player record
function Q.accountChars(tableName, p)
    local t = common.sqlName(tableName)
    if not t or not p or not Atlas.db.available() then return nil end
    local rows = Atlas.db.query(([[SELECT citizenid, CONCAT_WS(' ', JSON_UNQUOTE(JSON_EXTRACT(charinfo, '$.firstname')),
        JSON_UNQUOTE(JSON_EXTRACT(charinfo, '$.lastname'))) AS n FROM %s WHERE license = ? OR license = ?]]):format(t),
        { p.ids.license2 or '', p.ids.license or '' })
    if type(rows) ~= 'table' then return nil end
    local set = {}
    for i = 1, #rows do
        if rows[i].citizenid then set[tostring(rows[i].citizenid)] = rows[i].n or '' end
    end
    return set
end

--- Gone: true once a character's row has left the characters table, false while it is there, nil after a database error.
function Q.gone(tableName, citizenId)
    local t = common.sqlName(tableName)
    if not t then return nil end
    -- Error: a failed query also returns nil, which must not be read as "row is gone"
    local exists, err = Atlas.db.scalar(('SELECT 1 FROM %s WHERE citizenid = ?'):format(t), { citizenId })
    if err ~= nil then return nil end
    return exists == nil
end
