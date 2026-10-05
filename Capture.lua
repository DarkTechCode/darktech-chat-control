--[[
    DarkTech Chat Control — захват сообщений мирового чата.

    Сообщения ловятся из СИСТЕМНЫХ сообщений (CHAT_MSG_SYSTEM) — так их
    отправляет серверный модуль worldchat (команда .chat):

        [World][иконка][|cffЦВЕТ|Hplayer:Имя|hИмя|h|r]: |cffFFFFFFтекст|r

    Парсер трёхуровневый:
      1. строгий — точный разделитель «|h|r]: » вышестоящего формата;
      2. толерантный — любая ссылка игрока, за которой до двоеточия только
         декоративные символы (|r, |c…, скобки, пробелы). Ловит форки модуля
         с изменённым шаблоном строки;
      3. сырой — строка со ссылкой игрока, но нестандартного вида: пишется
         в лог КАК ЕСТЬ (метка RAW), без цензуры/скрытия/авто-ЧС.
    Дополнительно формат «[Тег] Имя: текст» (включается тегом в настройках).

    Режим «чаты»: настройка «Чаты» (через запятую) — это теги системных
    строк .chat (PikaWoW: [Solo], [Solo Progress] — строки приходят как
    CHAT_MSG_SYSTEM) и/или имена настоящих каналов (CHAT_MSG_CHANNEL).
    Сообщение с тегом/каналом из списка получает в логе собственную
    галочку-фильтр и тег [Чат] перед текстом; строки без тега остаются
    в «Мировом чате». Для строк без ссылки-игрока дополнительно распознаётся
    формат «[Тег] Имя: сообщение».

    Локальные чаты (say/крик, группа/рейд, гильдия, приват) ТОЛЬКО логируются
    (поле src, список источников DTCC.LOCAL_SOURCES в Core.lua): без цензуры,
    авто-ЧС и скрытия — сообщения группы/гильдии должны оставаться читаемыми.
    Флаги ЧС/друзей ставятся, чтобы типы-фильтры лога работали и по ним.

    Цвет автора: сервер красит имена в мировом чате по фракции (|cff… перед
    |Hplayer:). Цвет извлекается, пишется в запись лога и запоминается по
    игроку (db.factions) — сообщения каналов, которые цвет сами не передают,
    получают запомненный цвет того же игрока.

    Скрытие: фильтр возвращает true — строку покажет наш вариант (или не
    покажет никто). Замена: добавляем свою строку через self:AddMessage(...).
]]

--------------------------------------------------------------------------------
-- Экранирование служебных символов Lua-паттернов
--------------------------------------------------------------------------------

function DTCC.PatternEscape(s)
    return (gsub(tostring(s or ""), "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- Для debug-вывода: показать коды цвета/ссылок вместо их срабатывания
function DTCC.DebugEscape(s)
    s = gsub(tostring(s or ""), "|", "!")
    return DTCC.Truncate(s, 200)
end

-- Убрать стартовую/концевую обёртку цвета у текста сообщения (|cffFFFFFF…|r)
local function StripColorWrap(msg)
    local bare = msg
    local wrapped = string.match(bare, "^|c%x%x%x%x%x%x%x%x")
    if wrapped then bare = strsub(bare, strlen(wrapped) + 1) end
    if strsub(bare, -2) == "|r" then bare = strsub(bare, 1, -3) end
    return bare
end

-- Убрать ВСЁ оформление (цвета, ссылки, иконки) — для сырых записей лога
function DTCC.StripAll(text)
    text = tostring(text or "")
    text = gsub(text, "|H[^|]*|h", "")     -- сами ссылки (останется текст и |h)
    text = gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = gsub(text, "|r", "")
    text = gsub(text, "|T[^|]*|t", "")
    text = gsub(text, "|h", "")
    return text
end

-- Цвет имени автора из строки мирового чата: |cffAARRGGBB, обёртывающий ссылку
-- игрока (|cff…|Hplayer:). Сервер красит имена по фракции — этот же цвет
-- показываем в логе. Возвращает "RRGGBB" либо nil.
function DTCC.ExtractPlayerColor(text)
    local argb = string.match(tostring(text or ""), "|c(%x%x%x%x%x%x%x%x)|Hplayer:")
    if not argb then return nil end
    return strsub(argb, 3)
end

-- Тег в начале строки ([Solo], [Solo Progress]…), без скобок; nil, если тега
-- нет (строка может начинаться с цветового кода перед тегом — учитываем)
function DTCC.ExtractLeadingTag(text)
    text = tostring(text or "")
    local tag = string.match(text, "^%s*%[([^%]]+)%]")
    if not tag then
        local stripped = gsub(text, "^%s*|c%x%x%x%x%x%x%x%x%s*", "")
        tag = string.match(stripped, "^%[([^%]]+)%]")
    end
    tag = tag and strtrim(tag) or nil
    if tag == "" then return nil end
    return tag
end

-- Тег строки, если он есть в настройке «Чаты» (регистр не важен).
-- Возвращает тег как он написан в самой строке — это имя «чата» в логе
function DTCC.MatchChatTag(text, worldChannel)
    local tag = DTCC.ExtractLeadingTag(text)
    if not tag then return nil end
    local tagLow = DTCC.utf8lower(tag)
    for _, ch in ipairs(DTCC.SplitChannelList(worldChannel)) do
        if DTCC.utf8lower(ch) == tagLow then return tag end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Разбор строки мирового чата
--------------------------------------------------------------------------------

-- Возвращает name, bareMessage, prefix либо nil.
-- prefix — всё до текста сообщения включительно (используется при пересборке).

-- Уровень 1: точный формат модуля worldchat для AzerothCore.
local function ParseStrict(text)
    local sep = string.find(text, "|h|r]: ", 1, true)
    if not sep then return nil end
    local linkStart = string.find(text, "|Hplayer:", 1, true)
    if not linkStart or linkStart >= sep then return nil end
    local name = string.match(text, "|Hplayer:([^|]+)|h")
    if not name or name == "" then return nil end
    name = DTCC.CleanName(name)
    if name == "" then return nil end
    local prefixEnd = sep + strlen("|h|r]: ") - 1
    local msg = StripColorWrap(strsub(text, prefixEnd + 1))
    if msg == "" then return nil end
    return name, msg, strsub(text, 1, prefixEnd)
end

-- Уровень 2: ссылка игрока + до двоеточия только декоративные символы.
-- Проверяет каждую ссылку игрока в строке до первого успеха.
local function TryLinkColon(text, linkStart)
    local nameStart = linkStart + strlen("|Hplayer:")
    local firstH = string.find(text, "|h", nameStart, true)     -- |h после имени ссылки
    if not firstH then return nil end
    local closeH = string.find(text, "|h", firstH + 2, true)    -- закрывающее |h
    if not closeH then return nil end

    local pos = closeH + 2
    local n = #text
    local scanned = 0
    while pos <= n and scanned < 24 do
        local one = strsub(text, pos, pos)
        if one == ":" then
            local name = string.match(strsub(text, linkStart, pos), "|Hplayer:([^|]+)|h")
            name = DTCC.CleanName(name or "")
            if name == "" then return nil end
            local msgStart = pos + 1
            if strsub(text, msgStart, msgStart) == " " then msgStart = msgStart + 1 end
            local msg = StripColorWrap(strsub(text, msgStart))
            if msg == "" then return nil end
            return name, msg, strsub(text, 1, msgStart - 1)
        elseif one == "|" then
            local two = strsub(text, pos, pos + 1)
            if two == "|r" then
                pos = pos + 2; scanned = scanned + 2
            elseif two == "|c" then
                pos = pos + 10; scanned = scanned + 10
            else
                return nil -- иконка или другой код — не наш формат
            end
        elseif one == "]" or one == "[" or one == ")" or one == "("
            or one == " " or one == "*" then
            pos = pos + 1; scanned = scanned + 1
        else
            return nil -- между именем и двоеточием обычный текст — не чат
        end
    end
    return nil
end

local function ParseTolerant(text)
    local init = 1
    while true do
        local linkStart = string.find(text, "|Hplayer:", init, true)
        if not linkStart then return nil end
        local name, msg, prefix = TryLinkColon(text, linkStart)
        if name then return name, msg, prefix end
        init = linkStart + 1
    end
end

function DTCC.ParseWorldMessage(text, tag)
    if type(text) ~= "string" or text == "" then return nil end

    if tag and tag ~= "" then
        if strsub(text, 1, strlen(tag)) ~= tag then return nil end
    end

    local name, msg, prefix = ParseStrict(text)
    if not name then
        name, msg, prefix = ParseTolerant(text)
    end
    if name then return name, msg, prefix end

    -- запасной формат: "[Тег] Имя: сообщение" (только при явном теге)
    if tag and tag ~= "" then
        local esc = DTCC.PatternEscape(tag)
        local fname, fmsg = string.match(text, "^" .. esc .. "%s*([^:|]+)%s*:%s*(.-)$")
        if fname and fmsg and fname ~= "" then
            fname = DTCC.CleanName(fname)
            if fname ~= "" then
                return fname, fmsg, tag .. " " .. fname .. ": "
            end
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- Лог
--------------------------------------------------------------------------------

-- Запомнить цвет имени игрока из мирового чата (.chat): сообщения каналов
-- (Solo и т.п.) приходят без цвета — цвет автора берём из этой памяти.
function DTCC.RememberPlayerColor(name, color)
    local db = DTCC.db
    if not db or not color or color == "" then return end
    db.factions = db.factions or {}
    local key = DTCC.NameKey(name)
    if key == "" or db.factions[key] == color then return end
    if db.factions[key] == nil then
        -- не даём таблице расти бесконечно; считаем только при новом ключе
        local n = 0
        for _ in pairs(db.factions) do n = n + 1 end
        if n >= 5000 then wipe(db.factions) end
    end
    db.factions[key] = color
end

function DTCC.GetPlayerColor(name)
    local db = DTCC.db
    if not db or not db.factions then return nil end
    return db.factions[DTCC.NameKey(name)]
end

-- meta: { c = "RRGGBB" цвет имени (фракция), ch = имя канала,
--         src = ключ источника ("world" по умолчанию; say/party/guild/whisper) }
function DTCC.LogAdd(name, msg, flags, meta)
    meta = meta or {}
    local db = DTCC.db
    if not db or not db.settings.logEnabled then return end
    local log = db.log
    log[#log + 1] = { t = time(), p = name, m = msg, f = flags or 0,
        c = meta.c, ch = meta.ch, src = meta.src }
    -- подрезаем с запасом, чтобы не копировать массив на каждом сообщении
    local limit = tonumber(db.settings.logLimit) or 3000
    if limit > 0 and #log > limit + 50 then
        local keep = {}
        for i = #log - limit + 1, #log do
            keep[#keep + 1] = log[i]
        end
        db.log = keep
    end
    DTCC.FireEvent("LogChanged")
end

function DTCC.ClearLog()
    if DTCC.db then
        wipe(DTCC.db.log)
    end
    DTCC.FireEvent("LogChanged")
end

-- Подготовка запроса к логу (общая для поиска и удаления по фильтрам).
-- opts: { text, name, minT, flags, channels, sources, includeRaw }.
--   channels — «ключ канала (lower) -> bool»: записи каналов видны ТОЛЬКО
--     при явном true (nil/false = выключен; nil целиком = каналы не фильтровать);
--   sources — «ключ источника -> bool» (world/say/party/guild/whisper):
--     nil = источники не фильтровать;
--   includeRaw — RAW-записи (nil = включены);
--   flags — совпадение с любым из битов (0 = любой тип; RAW не касается);
--   text/name — подстрока (без учёта регистра), minT — минимум по времени.
function DTCC.PrepareLogQuery(opts)
    opts = opts or {}
    local q = {}
    q.text = opts.text and DTCC.utf8lower(strtrim(opts.text)) or ""
    q.name = opts.name and DTCC.utf8lower(strtrim(opts.name)) or ""
    q.minT = opts.minT or 0
    q.flags = opts.flags or 0
    -- «отмечены все типы» (галочка «Все») = фильтра по типам нет: записи
    -- без пометок (f=0) тоже подходят — иначе чистка «по всем типам»
    -- оставляла бы их в логе невидимыми
    if q.flags == DTCC.FLAG_TYPE_ALL then q.flags = 0 end
    q.channels = opts.channels
    q.sources = opts.sources
    q.includeRaw = opts.includeRaw
    if q.includeRaw == nil then q.includeRaw = true end
    return q
end

-- Подходит ли запись под подготовленный запрос (q из PrepareLogQuery)
function DTCC.LogEntryMatches(e, q)
    if not e then return false end
    if e.t and q.minT > 0 and e.t < q.minT then return false end
    local isRaw = bit.band(e.f or 0, DTCC.FLAG_RAW) ~= 0
    local ok
    if isRaw then
        ok = q.includeRaw
    elseif e.ch and q.channels ~= nil then
        ok = q.channels[DTCC.utf8lower(e.ch)] == true
    else
        ok = q.sources == nil or q.sources[e.src or "world"] ~= false
    end
    if ok and not isRaw and q.flags ~= 0 then
        ok = bit.band(e.f or 0, q.flags) ~= 0
    end
    if ok and q.text ~= "" then
        ok = string.find(DTCC.utf8lower(tostring(e.m or "")), q.text, 1, true) ~= nil
    end
    if ok and q.name ~= "" then
        ok = string.find(DTCC.utf8lower(tostring(e.p or "")), q.name, 1, true) ~= nil
    end
    return ok
end

-- Поиск по логу: возвращает (результат-новые-сверху, всего найдено)
function DTCC.LogSearch(opts)
    local db = DTCC.db
    if not db then return {}, 0 end
    local q = DTCC.PrepareLogQuery(opts)
    local res, total = {}, 0
    local log = db.log
    for i = #log, 1, -1 do
        if DTCC.LogEntryMatches(log[i], q) then
            total = total + 1
            if total <= 3000 then res[#res + 1] = log[i] end
        end
    end
    return res, total
end

-- Удалить записи, подходящие под запрос (кнопка «Очистить лог» работает
-- по текущим фильтрам). Возвращает число удалённых.
function DTCC.RemoveLogEntries(opts)
    local db = DTCC.db
    if not db then return 0 end
    local q = DTCC.PrepareLogQuery(opts)
    local keep, removed = {}, 0
    for _, e in ipairs(db.log) do
        if DTCC.LogEntryMatches(e, q) then
            removed = removed + 1
        else
            keep[#keep + 1] = e
        end
    end
    if removed > 0 then db.log = keep end
    DTCC.FireEvent("LogChanged")
    return removed
end

--------------------------------------------------------------------------------
-- Отправка в мировой чат
--------------------------------------------------------------------------------

function DTCC.SendWorldMessage(text)
    text = strtrim(tostring(text or ""))
    if text == "" then return end
    if strlen(text) > 200 then
        text = DTCC.Truncate(text, 200)
        DTCC.Print(DTCC.COLORS.yellow .. "Сообщение обрезано до 200 символов (лимит команды .chat).")
    end
    SendChatMessage(".chat " .. text, "SAY")
end

--------------------------------------------------------------------------------
-- Общий конвейер обработки сообщения мирового чата
--------------------------------------------------------------------------------

-- color/ch/src пробрасываются в лог через meta (см. LogAdd)
local function ProcessChatLine(self, name, bare, prefix, meta)
    local db = DTCC.db
    if not db then return end
    local s = db.settings

    ------------------------------------------------------------------ списки
    local flags = 0
    local friendEntry = DTCC.Friends_Get(name)
    local blEntry = DTCC.Blacklist_Get(name)
    if friendEntry then flags = flags + DTCC.FLAG_FRIEND end
    if blEntry then flags = flags + DTCC.FLAG_BLACKLIST end

    ------------------------------------------------------------------ цензура
    local censored = false
    if s.censorEnabled then
        local low = DTCC.utf8lower(bare)
        if DTCC.CensorFind(low) then
            censored = true
            flags = flags + DTCC.FLAG_CENSORED

            if s.autoBlacklist and not friendEntry and not blEntry then
                DTCC.Blacklist_Add(name, {
                    display  = name,
                    reason   = bare,
                    duration = tonumber(s.autoBLDuration) or 0,
                    source   = "censor",
                })
                blEntry = true
                flags = flags + DTCC.FLAG_BLACKLIST + DTCC.FLAG_AUTOBL
                DTCC.Print(DTCC.COLORS.red .. name .. "|r автоматически добавлен в ЧС (" ..
                    DTCC.DurationLabel(s.autoBLDuration) .. "): «" ..
                    DTCC.Truncate(bare, 50) .. "»")
            end
        end
    end

    ------------------------------------------------------------------ лог
    -- «Скрытые» = сообщение НЕ попадает в чат (ЧС или цензура «Скрывать»):
    -- помечаем ДО записи — по этому флагу работает галочка «Скрытые» на
    -- вкладке «Лог» (типы-галочки складываются как «ИЛИ»)
    if (blEntry and s.hideBlacklisted)
        or (censored and s.censorMode == "HIDE") then
        flags = flags + DTCC.FLAG_HIDDEN
    end
    DTCC.LogAdd(name, bare, flags, meta)

    ------------------------------------------------------------------ ЧС: скрыть
    if blEntry and s.hideBlacklisted then
        if s.showPlaceholder then
            self:AddMessage(DTCC.COLORS.grey .. "[DTCC] " .. name ..
                ": сообщение скрыто (ЧС)|r", 0.55, 0.55, 0.55)
        end
        return true
    end

    ------------------------------------------------------------------ цензура: скрыть
    if censored and s.censorMode == "HIDE" then
        return true
    end

    ------------------------------------------------------------------ пересборка строки
    local needRebuild = censored
        or s.showTimestamps
        or (friendEntry and s.friendsHighlight)
    if not needRebuild then
        return nil -- показать как есть
    end

    local displayText = bare
    if censored then
        displayText = DTCC.CensorMask(bare)
    end

    local parts = {}
    if s.showTimestamps then
        parts[#parts + 1] = "|cff909090[" .. date("%H:%M") .. "]|r "
    end
    if friendEntry and s.friendsHighlight then
        parts[#parts + 1] = "|cff3fd13f[ДРУГ]|r "
    end
    parts[#parts + 1] = prefix
    parts[#parts + 1] = "|cffFFFFFF"
    parts[#parts + 1] = displayText
    parts[#parts + 1] = "|r"

    self:AddMessage(table.concat(parts))
    return true
end

--------------------------------------------------------------------------------
-- Фильтр системных сообщений
--------------------------------------------------------------------------------

local formatRecognized = false

local function SystemFilter(self, event, text)
    local db = DTCC.db
    if not db then return end
    local s = db.settings

    if s.debug then
        DTCC.Print(DTCC.COLORS.grey .. "[debug] СИСТ: " .. DTCC.DebugEscape(text))
    end

    if not s.enabled then return end

    local name, bare, prefix = DTCC.ParseWorldMessage(text, s.worldTag)
    if name then
        if not formatRecognized then
            formatRecognized = true
            DTCC.Print(DTCC.COLORS.green .. "формат мирового чата распознан — сообщения пишутся в лог|r " ..
                DTCC.COLORS.grey .. "(/dtcc log)")
        end
        -- цвет имени (фракция) из самой строки: запоминаем по игроку — чаты
        -- без ссылки-игрока цвет не передают и берут его из памяти
        local color = DTCC.ExtractPlayerColor(text)
        if color then DTCC.RememberPlayerColor(name, color) end
        -- тег строки ([Solo], [Solo Progress]…): если он в настройке «Чаты»,
        -- запись получает собственную галочку-фильтр и тег в логе
        return ProcessChatLine(self, name, bare, prefix,
            { c = color, ch = DTCC.MatchChatTag(text, s.worldChannel) })
    end

    -- Запасной формат для чатов из настройки: «[Тег] Имя: сообщение» без
    -- ссылки-игрока (PikaWoW так присылает, например, Solo Progress)
    if type(text) == "string" then
        local tag = DTCC.MatchChatTag(text, s.worldChannel)
        if tag then
            local esc = DTCC.PatternEscape(tag)
            local fname, fmsg = string.match(text,
                "^%s*%[" .. esc .. "%]%s*([^:|%[]+)%s*:%s*(.-)$")
            fname = fname and DTCC.CleanName(fname) or ""
            if fname ~= "" and fmsg and fmsg ~= "" then
                return ProcessChatLine(self, fname, fmsg,
                    "[" .. tag .. "] " .. fname .. ": ",
                    { c = DTCC.GetPlayerColor(fname), ch = tag })
            end
        end
    end

    -- Уровень 3 (сырой): строка со ссылкой на игрока, но нестандартного вида.
    -- Пишем в лог как есть (метка RAW) — БЕЗ цензуры, скрытия и авто-ЧС,
    -- чтобы необработанная строка не могла дать побочных эффектов.
    if type(text) == "string" and string.find(text, "|Hplayer:", 1, true) then
        local rawName = DTCC.CleanName(string.match(text, "|Hplayer:([^|]+)|h") or "")
        local rawMsg = strtrim(DTCC.StripAll(text))
        if rawName ~= "" and rawMsg ~= "" then
            local rawColor = DTCC.ExtractPlayerColor(text)
            if rawColor then DTCC.RememberPlayerColor(rawName, rawColor) end
            DTCC.LogAdd(rawName, rawMsg, DTCC.FLAG_RAW, { c = rawColor })
            if s.debug then
                DTCC.Print(DTCC.COLORS.yellow .. "[debug] формат не распознан, " ..
                    "записано в лог как RAW: " .. DTCC.DebugEscape(text))
            end
        end
    end

    return nil
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", SystemFilter)

--------------------------------------------------------------------------------
-- Фильтр сообщений каналов (режим «каналы»: список имён в настройке,
-- сообщения каждого канала проходят полный конвейер и помечаются в логе)
--------------------------------------------------------------------------------

local function ChannelFilter(self, event, msg, sender, lang, chanWithNumber)
    local db = DTCC.db
    if not db then return end
    local s = db.settings

    local chanName = tostring(chanWithNumber or "")
    chanName = gsub(chanName, "^%d+%.%s*", "")

    if s.debug then
        DTCC.Print(DTCC.COLORS.grey .. "[debug] КАНАЛ [" .. chanName .. "] " ..
            tostring(sender or "?") .. ": " .. DTCC.DebugEscape(msg))
    end

    if not s.enabled then return end

    -- источник «Каналы»: список имён через запятую/точку с запятой
    local chanList = DTCC.SplitChannelList(s.worldChannel)
    if #chanList == 0 then return end
    local chanLow = DTCC.utf8lower(chanName)
    local matched = false
    for _, ch in ipairs(chanList) do
        if DTCC.utf8lower(ch) == chanLow then
            matched = true
            break
        end
    end
    if not matched then return end

    local name = DTCC.CleanName(tostring(sender or ""))
    if name == "" then return end

    -- пересборка префикса в стиле мирового чата
    local prefix = "|cff20b2aa[" .. chanName .. "]|r |Hplayer:" .. name ..
        "|h|cffFFFFFF" .. name .. "|h|r: "
    -- цвет автора каналы не передают: берём запомненный из мирового чата (.chat)
    return ProcessChatLine(self, name, tostring(msg or ""), prefix,
        { c = DTCC.GetPlayerColor(name), ch = chanName })
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", ChannelFilter)

--------------------------------------------------------------------------------
-- Локальные чаты (say/крик, группа/рейд, гильдия, приват): ТОЛЬКО логирование.
-- Без цензуры/авто-ЧС/скрытия — сообщения группы и гильдии обязаны оставаться
-- читаемыми; флаги ЧС/друзей ставим, чтобы типы-фильтры лога работали и тут.
--------------------------------------------------------------------------------

local localChatByEvent = {}
for _, def in ipairs(DTCC.LOCAL_SOURCES) do
    for _, ev in ipairs(def.events) do
        localChatByEvent["CHAT_MSG_" .. ev] = def
    end
end

local function LocalChatFilter(self, event, msg, sender)
    local db = DTCC.db
    if not db then return end
    local s = db.settings
    local def = localChatByEvent[event]
    if not def then return end

    if s.debug then
        DTCC.Print(DTCC.COLORS.grey .. "[debug] ЛОКАЛЬНЫЙ [" .. def.label .. "] " ..
            tostring(sender or "?") .. ": " .. DTCC.DebugEscape(msg))
    end

    if not s.enabled or not s.logEnabled then return end

    local name = DTCC.CleanName(tostring(sender or ""))
    if name == "" then return end

    local flags = 0
    if DTCC.Friends_Get(name) then flags = flags + DTCC.FLAG_FRIEND end
    if DTCC.Blacklist_Get(name) then flags = flags + DTCC.FLAG_BLACKLIST end

    local text = tostring(msg or "")
    if event == "CHAT_MSG_WHISPER_INFORM" then
        text = "→ " .. text -- исходящий приват: стрелка отличает его от входящего
    end

    DTCC.LogAdd(name, text, flags, { c = DTCC.GetPlayerColor(name), src = def.src })
    return nil -- отображение в чате не трогаем никогда
end

for _, def in ipairs(DTCC.LOCAL_SOURCES) do
    for _, ev in ipairs(def.events) do
        ChatFrame_AddMessageEventFilter("CHAT_MSG_" .. ev, LocalChatFilter)
    end
end

-- Фильтры чата в 3.3.5 останавливаются на первом вернувшем true: переносим
-- наши фильтры в начало списка, чтобы никакой аддон не перехватил событие раньше.
function DTCC.PromoteFilterFirst(event, filter)
    if type(ChatFrame_GetMessageEventFilters) ~= "function" then return end
    local ok, list = pcall(ChatFrame_GetMessageEventFilters, event)
    if not ok or type(list) ~= "table" then return end
    for i, f in ipairs(list) do
        if f == filter then
            tremove(list, i)
            tinsert(list, 1, filter)
            return
        end
    end
end

DTCC.PromoteFilterFirst("CHAT_MSG_SYSTEM", SystemFilter)
DTCC.PromoteFilterFirst("CHAT_MSG_CHANNEL", ChannelFilter)

--------------------------------------------------------------------------------
-- Периодическая уборка: раз в минуту выбрасываем истёкшие записи ЧС,
-- чтобы окно и подрезка лога не зависели от перезахода в игру.
--------------------------------------------------------------------------------

local housekeeping = CreateFrame("Frame")
local elapsed = 0
housekeeping:SetScript("OnUpdate", function(self, dt)
    elapsed = elapsed + dt
    if elapsed < 60 then return end
    elapsed = 0
    if DTCC.db then
        DTCC.Blacklist_PurgeExpired()
    end
end)
