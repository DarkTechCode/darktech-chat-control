--[[
    DarkTech Chat Control — списки игроков.

    Чёрный список:
      * записи с ограниченным сроком автоматически удаляются по истечении;
      * хранится причина (сообщение, за которое игрок был добавлен);
      * источник: manual (вручную) / censor (авто по списку цензуры).

    Друзья: просто список имён для подсветки сообщений.
]]

--------------------------------------------------------------------------------
-- Чёрный список
--------------------------------------------------------------------------------

-- Добавить игрока в ЧС.
-- opts: { duration = сек (0/nil = навсегда), reason = "текст", source = "manual"|"censor", display = "Имя" }
-- Возвращает true при успехе.
function DTCC.Blacklist_Add(rawName, opts)
    if not DTCC.db then return false end
    opts = opts or {}
    local display = DTCC.CleanName(opts.display or rawName or "")
    if display == "" then return false end

    local key = DTCC.NameKey(display)
    if key == "" then return false end

    local duration = tonumber(opts.duration) or 0
    local entry = {
        name    = display,
        added   = time(),
        expires = (duration > 0) and (time() + duration) or nil,
        reason  = opts.reason,
        source  = opts.source or "manual",
    }

    local old = DTCC.db.blacklist[key]
    DTCC.db.blacklist[key] = entry

    DTCC.FireEvent("ListsChanged")
    DTCC.FireEvent("BlacklistUpdated", key, entry, old)
    return true
end

function DTCC.Blacklist_Remove(rawName)
    if not DTCC.db then return false end
    local key = DTCC.NameKey(rawName)
    if key ~= "" and DTCC.db.blacklist[key] then
        DTCC.db.blacklist[key] = nil
        DTCC.FireEvent("ListsChanged")
        return true
    end
    return false
end

-- Получить активную запись ЧС (с ленивой проверкой срока).
function DTCC.Blacklist_Get(rawName)
    if not DTCC.db then return nil end
    local key = DTCC.NameKey(rawName)
    local e = DTCC.db.blacklist[key]
    if not e then return nil end
    if e.expires and time() > e.expires then
        DTCC.db.blacklist[key] = nil
        DTCC.FireEvent("ListsChanged")
        return nil
    end
    return e
end

-- Снять ограничение срока (сделать навсегда)
function DTCC.Blacklist_MakePermanent(rawName)
    if not DTCC.db then return false end
    local key = DTCC.NameKey(rawName)
    local e = DTCC.db.blacklist[key]
    if not e then return false end
    e.expires = nil
    DTCC.FireEvent("ListsChanged")
    return true
end

-- Удалить все истёкшие записи; возвращает количество удалённых.
function DTCC.Blacklist_PurgeExpired()
    if not DTCC.db then return 0 end
    local now = time()
    local removed = 0
    for key, e in pairs(DTCC.db.blacklist) do
        if e.expires and now > e.expires then
            DTCC.db.blacklist[key] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        DTCC.FireEvent("ListsChanged")
    end
    return removed
end

-- Упорядоченный снимок для UI.
-- sortKey: "name" | "added" | "expires" | "reason"; sortDir: "asc" | "desc".
-- По умолчанию — свежие сверху (added, убывание). Бессрочные записи при
-- сортировке по сроку считаются «самыми долгими» (при возрастании — в конце).
-- Возвращает массив { key = ..., name = ..., added = ..., expires = ..., reason = ..., source = ... }
local BL_SORT_KEYS = { name = true, added = true, expires = true, reason = true }

function DTCC.Blacklist_GetSorted(sortKey, sortDir)
    if not DTCC.db then return {} end
    DTCC.Blacklist_PurgeExpired()
    local list = {}
    for key, e in pairs(DTCC.db.blacklist) do
        list[#list + 1] = {
            key     = key,
            name    = e.name or key,
            added   = e.added,
            expires = e.expires,
            reason  = e.reason,
            source  = e.source or "manual",
        }
    end
    if not (sortKey and BL_SORT_KEYS[sortKey]) then sortKey = "added" end
    local ascending = (sortDir == "asc")
    local function SortVal(e)
        if sortKey == "name" then
            return DTCC.utf8lower(e.name or "")
        elseif sortKey == "expires" then
            return e.expires or math.huge
        elseif sortKey == "reason" then
            return DTCC.utf8lower(e.reason or "")
        end
        return e.added or 0
    end
    table.sort(list, function(a, b)
        local va, vb = SortVal(a), SortVal(b)
        if va == vb then
            return DTCC.utf8lower(a.name or "") < DTCC.utf8lower(b.name or "")
        end
        if ascending then return va < vb end
        return va > vb
    end)
    return list
end

function DTCC.Blacklist_Count()
    if not DTCC.db then return 0 end
    return #DTCC.Blacklist_GetSorted()
end

--------------------------------------------------------------------------------
-- Друзья
--------------------------------------------------------------------------------

function DTCC.Friends_Add(rawName)
    if not DTCC.db then return false end
    local display = DTCC.CleanName(rawName or "")
    if display == "" then return false end
    local key = DTCC.NameKey(display)
    if key == "" then return false end

    DTCC.db.friends[key] = DTCC.db.friends[key] or {
        name  = display,
        added = time(),
    }
    DTCC.FireEvent("ListsChanged")
    return true
end

function DTCC.Friends_Remove(rawName)
    if not DTCC.db then return false end
    local key = DTCC.NameKey(rawName)
    if key ~= "" and DTCC.db.friends[key] then
        DTCC.db.friends[key] = nil
        DTCC.FireEvent("ListsChanged")
        return true
    end
    return false
end

function DTCC.Friends_Get(rawName)
    if not DTCC.db then return nil end
    return DTCC.db.friends[DTCC.NameKey(rawName)]
end

function DTCC.Friends_GetSorted()
    if not DTCC.db then return {} end
    local list = {}
    for key, e in pairs(DTCC.db.friends) do
        list[#list + 1] = {
            key   = key,
            name  = e.name or key,
            added = e.added,
        }
    end
    table.sort(list, function(a, b)
        if a.added and b.added and a.added ~= b.added then
            return a.added > b.added
        end
        return a.name < b.name
    end)
    return list
end

function DTCC.Friends_Count()
    if not DTCC.db then return 0 end
    local n = 0
    for _ in pairs(DTCC.db.friends) do n = n + 1 end
    return n
end
