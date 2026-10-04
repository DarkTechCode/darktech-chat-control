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

    Режим «канал»: если сервер доставляет сообщения каналом (CHAT_MSG_CHANNEL),
    укажите его имя в настройках («Источник мирового чата»).

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

function DTCC.LogAdd(name, msg, flags)
    local db = DTCC.db
    if not db or not db.settings.logEnabled then return end
    local log = db.log
    log[#log + 1] = { t = time(), p = name, m = msg, f = flags or 0 }
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

-- Поиск по логу. opts: { text, name, minT, flags } — флаги: совпадение
-- с любым из указанных битов. Возвращает (результат-новые-сверху, всего найдено).
function DTCC.LogSearch(opts)
    local db = DTCC.db
    if not db then return {}, 0 end
    opts = opts or {}

    local textF = opts.text and DTCC.utf8lower(strtrim(opts.text)) or ""
    local nameF = opts.name and DTCC.utf8lower(strtrim(opts.name)) or ""
    local minT = opts.minT or 0
    local needFlags = opts.flags or 0

    local res, total = {}, 0
    local log = db.log
    for i = #log, 1, -1 do
        local e = log[i]
        if e and (not e.t or e.t >= minT) then
            local ok = true
            if textF ~= "" then
                ok = string.find(DTCC.utf8lower(tostring(e.m or "")), textF, 1, true) ~= nil
            end
            if ok and nameF ~= "" then
                ok = string.find(DTCC.utf8lower(tostring(e.p or "")), nameF, 1, true) ~= nil
            end
            if ok and needFlags ~= 0 then
                ok = bit.band(e.f or 0, needFlags) ~= 0
            end
            if ok then
                total = total + 1
                if total <= 3000 then
                    res[#res + 1] = e
                end
            end
        end
    end
    return res, total
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

local function ProcessChatLine(self, name, bare, prefix)
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
    DTCC.LogAdd(name, bare, flags)

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
        return ProcessChatLine(self, name, bare, prefix)
    end

    -- Уровень 3 (сырой): строка со ссылкой на игрока, но нестандартного вида.
    -- Пишем в лог как есть (метка RAW) — БЕЗ цензуры, скрытия и авто-ЧС,
    -- чтобы необработанная строка не могла дать побочных эффектов.
    if type(text) == "string" and string.find(text, "|Hplayer:", 1, true) then
        local rawName = DTCC.CleanName(string.match(text, "|Hplayer:([^|]+)|h") or "")
        local rawMsg = strtrim(DTCC.StripAll(text))
        if rawName ~= "" and rawMsg ~= "" then
            DTCC.LogAdd(rawName, rawMsg, DTCC.FLAG_RAW)
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
-- Фильтр сообщений канала (режим «канал», включается именем канала в настройках)
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
    if s.worldChannel == "" then return end
    if DTCC.utf8lower(chanName) ~= DTCC.utf8lower(strtrim(s.worldChannel)) then return end

    local name = DTCC.CleanName(tostring(sender or ""))
    if name == "" then return end

    -- пересборка префикса в стиле мирового чата
    local prefix = "|cff20b2aa[" .. chanName .. "]|r |Hplayer:" .. name ..
        "|h|cffFFFFFF" .. name .. "|h|r: "
    return ProcessChatLine(self, name, tostring(msg or ""), prefix)
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", ChannelFilter)

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
