--[[
    DarkTech Chat Control (DTCC)

    Управление межфракционным чатом сервера (.chat):
      * отдельный чёрный список и список друзей;
      * цензура по списку слов + авто-ЧС на срок;
      * логирование чата с поиском и фильтрами;
      * алерты, когда игрок из ЧС появляется рядом.

    Ядро: пространство имён, база (SavedVariables), утилиты UTF-8,
    шина событий, слэш-команды.
]]

local ADDON_NAME = ...

DTCC = {}

DTCC.AddOnName = ADDON_NAME
DTCC.Version   = GetAddOnMetadata(ADDON_NAME, "Version") or "1.0.0"

-- Флаги записей лога (битовая маска)
DTCC.FLAG_HIDDEN    = 1    -- сообщение было скрыто (игрок в ЧС)
DTCC.FLAG_CENSORED  = 2    -- сообщение замаскировано/вырезано цензурой
DTCC.FLAG_BLACKLIST = 4    -- автор в ЧС (в момент сообщения)
DTCC.FLAG_FRIEND    = 8    -- автор в списке друзей
DTCC.FLAG_AUTOBL    = 16   -- автор добавлен в ЧС автоматически за это сообщение
DTCC.FLAG_RAW       = 32   -- строка нестандартного вида: записана как есть, без обработки

-- Все типовые флаги разом (галочка «Все»): полное совпадение трактуется
-- как «фильтра по типам нет» — видны и записи без пометок (f=0)
DTCC.FLAG_TYPE_ALL = DTCC.FLAG_HIDDEN + DTCC.FLAG_CENSORED + DTCC.FLAG_BLACKLIST
    + DTCC.FLAG_FRIEND + DTCC.FLAG_AUTOBL

DTCC.COLORS = {
    main   = "|cff00e5ff",
    red    = "|cffff4a4a",
    green  = "|cff3fd13f",
    grey   = "|cff909090",
    yellow = "|cffffd100",
    white  = "|cffffffff",
}

--------------------------------------------------------------------------------
-- Локальные чаты-источники лога (только логирование, без обработки).
-- src — ключ записи лога и настройки logShowSources; label — галочка и тег
-- [Метка] перед сообщением; color — цвет тега (близко к цветам чата игры).
--------------------------------------------------------------------------------

DTCC.LOCAL_SOURCES = {
    { src = "say",     label = "Общий",   color = "ffffff",
      events = { "SAY", "YELL" },
      tooltip = "Сообщения рядом: /say и крики." },
    { src = "party",   label = "Группа",  color = "80b3ff",
      events = { "PARTY", "PARTY_LEADER", "RAID", "RAID_LEADER" },
      tooltip = "Сообщения группы и рейда (включая лидерские)." },
    { src = "guild",   label = "Гильдия", color = "40d040",
      events = { "GUILD", "GUILD_OFFICER" },
      tooltip = "Сообщения гильдии и офицерского чата." },
    { src = "whisper", label = "Шёпот",   color = "bf6fef",
      events = { "WHISPER", "WHISPER_INFORM" },
      tooltip = "Приватные сообщения: входящие и исходящие\n(исходящие помечены стрелкой →)." },
}

DTCC.sourceBySrc = {}
for _, def in ipairs(DTCC.LOCAL_SOURCES) do
    DTCC.sourceBySrc[def.src] = def
end

--------------------------------------------------------------------------------
-- Вывод
--------------------------------------------------------------------------------

function DTCC.Print(msg, r, g, b)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(DTCC.COLORS.main .. "[DTCC]|r " .. msg, r, g, b)
    end
end

--------------------------------------------------------------------------------
-- Утилиты UTF-8 (клиент 3.3.5 = Lua 5.1, строковые функции побайтовые,
-- strlower не умеет кириллицу — поэтому свой вариант)
--------------------------------------------------------------------------------

-- Длина одного символа UTF-8 по ведущему байту
local function CharLen(b)
    if b >= 0xF0 then return 4 end
    if b >= 0xE0 then return 3 end
    if b >= 0xC0 then return 2 end
    return 1
end

-- Перевод строки в нижний регистр (ASCII + кириллица)
function DTCC.utf8lower(s)
    if not s then return nil end
    s = tostring(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local b = string.byte(s, i)
        if b < 0x80 then
            -- ASCII: A-Z -> a-z
            if b >= 65 and b <= 90 then b = b + 32 end
            out[#out + 1] = string.char(b)
            i = i + 1
        elseif b == 0xD0 then
            local b2 = string.byte(s, i + 1) or 0
            if b2 >= 0x90 and b2 <= 0x9F then
                -- А-П -> а-п
                out[#out + 1] = string.char(0xD0, b2 + 0x20)
            elseif b2 >= 0xA0 and b2 <= 0xAF then
                -- Р-Я -> р-я
                out[#out + 1] = string.char(0xD1, b2 - 0x20)
            elseif b2 == 0x81 then
                -- Ё -> ё
                out[#out + 1] = string.char(0xD1, 0x91)
            else
                out[#out + 1] = string.sub(s, i, i + 1)
            end
            i = i + 2
        else
            -- прочие многобайтовые (в т.ч. уже строчная кириллица D1 xx)
            local len = CharLen(b)
            out[#out + 1] = string.sub(s, i, i + len - 1)
            i = i + len
        end
    end
    return table.concat(out)
end

-- Усечение строки до maxChars СИМВОЛОВ (не байт) без разрыва UTF-8
function DTCC.Truncate(s, maxChars)
    s = tostring(s or "")
    local out, cnt, i, n = {}, 0, 1, #s
    while i <= n and cnt < maxChars do
        local b = string.byte(s, i)
        local len = CharLen(b)
        cnt = cnt + 1
        out[#out + 1] = string.sub(s, i, i + len - 1)
        i = i + len
    end
    return table.concat(out)
end

-- Нормализованный ключ игрока: без пробелов, без -Реалм, в нижнем регистре
function DTCC.NameKey(name)
    if not name then return "" end
    local s = tostring(name)
    s = gsub(s, "%s", "")
    s = gsub(s, "-.*$", "")
    return DTCC.utf8lower(s)
end

-- Красивое имя для отображения: как ввели
function DTCC.CleanName(name)
    if not name then return "" end
    local s = tostring(name)
    s = gsub(s, "%s", "")
    s = gsub(s, "-.*$", "")
    return s
end

-- "RRGGBB" -> r, g, b (0..1); nil при некорректном коде
function DTCC.HexToRGB(hex)
    if type(hex) ~= "string" then return nil end
    local r, g, b = string.match(hex, "^(%x%x)(%x%x)(%x%x)$")
    if not r then return nil end
    return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
end

-- Список каналов из настройки «Каналы» (разделители: запятая/точка с запятой).
-- Возвращает массив имён как введены (для подписей галочек), без пустых.
function DTCC.SplitChannelList(text)
    local out = {}
    for name in string.gmatch(tostring(text or ""), "[^,;]+") do
        name = strtrim(name)
        if name ~= "" then out[#out + 1] = name end
    end
    return out
end

--------------------------------------------------------------------------------
-- Время
--------------------------------------------------------------------------------

function DTCC.IsToday(ts)
    return date("%Y%m%d", ts) == date("%Y%m%d")
end

-- "14:03" сегодня, "03.10 14:03" в другой день
function DTCC.FormatTimeShort(ts)
    if not ts then return "" end
    if DTCC.IsToday(ts) then
        return date("%H:%M", ts)
    end
    return date("%d.%m %H:%M", ts)
end

function DTCC.FormatDateFull(ts)
    if not ts then return "—" end
    return date("%d.%m.%Y %H:%M", ts)
end

-- Осталось до истечения срока записи ЧС
function DTCC.FormatRemaining(expires)
    if not expires then return "навсегда" end
    local d = expires - time()
    if d <= 0 then return "истёк" end
    local days  = floor(d / 86400)
    local hours = floor((d % 86400) / 3600)
    local mins  = floor((d % 3600) / 60)
    if days > 0 then
        return days .. " д " .. hours .. " ч"
    elseif hours > 0 then
        return hours .. " ч " .. mins .. " м"
    else
        return mins .. " м"
    end
end

--------------------------------------------------------------------------------
-- Сроки ЧС
--------------------------------------------------------------------------------

DTCC.DURATIONS = {
    { text = "1 день",    value = 86400    },
    { text = "3 дня",     value = 259200   },
    { text = "Неделя",    value = 604800   },
    { text = "Месяц",     value = 2592000  },
    { text = "Навсегда",  value = 0        },
}

function DTCC.DurationLabel(value)
    for _, d in ipairs(DTCC.DURATIONS) do
        if d.value == value then return d.text end
    end
    return tostring(value)
end

--------------------------------------------------------------------------------
-- Шина событий (простые колбэки)
--------------------------------------------------------------------------------

DTCC._listeners = {}

function DTCC.RegisterCallback(event, func)
    DTCC._listeners[event] = DTCC._listeners[event] or {}
    tinsert(DTCC._listeners[event], func)
end

function DTCC.FireEvent(event, ...)
    local list = DTCC._listeners[event]
    if list then
        for _, fn in ipairs(list) do
            local ok, err = pcall(fn, ...)
            if not ok then
                DTCC.Print(DTCC.COLORS.red .. "Ошибка в обработчике " .. event .. ": " .. tostring(err))
            end
        end
    end
end

--------------------------------------------------------------------------------
-- База / настройки
--------------------------------------------------------------------------------

local DEFAULTS = {
    settings = {
        enabled         = true,   -- главный выключатель обработки чата
        hideBlacklisted = true,   -- скрывать сообщения игроков из ЧС
        showPlaceholder = false,  -- показывать заглушку вместо скрытых
        showTimestamps  = false,  -- время у сообщений мирового чата
        friendsHighlight = true,  -- метка [ДРУГ] у сообщений друзей

        censorEnabled   = true,
        censorMode      = "HIDE", -- HIDE = скрывать сообщение (дефолт), MASK = маскировать ***
        censorWords     = {},     -- список слов (нормализуется при сохранении)
        autoBlacklist   = false,  -- авто-добавление в ЧС за слово из списка
        autoBLDuration  = 86400,  -- срок авто-ЧС (сек; 0 = навсегда)

        blSortKey       = "added", -- сортировка таблицы ЧС (клик по заголовку)
        blSortDir       = "desc",

        logEnabled      = true,
        logLimit        = 3000,
        logShowPlayers  = true,   -- фильтр вкладки «Лог»: сообщения мирового чата (.chat)
        logShowRaw      = false,  -- ... RAW-записи (системные строки с игроком)
        logShowSources  = {       -- ... локальные чаты (по умолчанию ВЫКЛЮЧЕНЫ:
            say = false,          --     по умолчанию виден только «Мировой чат»)
            party = false, guild = false, whisper = false,
        },
        logFilterFlags  = 0,      -- «только эти типы» (маска флагов; 0 = все типы)
        logChannelShow  = {},     -- ... каналы: [имя канала в нижнем регистре] = bool
                                  --     (виден ТОЛЬКО при явном true; nil = выключен)

        alertEnabled    = true,   -- алерты о ЧС рядом
        alertPopup      = true,   -- всплывающее окно (в стиле SilverDragon)
        alertRW         = false,  -- Raid Warning по центру
        alertChat       = true,   -- сообщение в чат
        alertErrors     = false,  -- красное сообщение по центру экрана
        alertSound      = "Sound\\Interface\\AlarmClockWarning3.wav",
        alertCooldown   = 60,     -- пауза между алертами об одном игроке, сек
        alertSayDetect  = true,   -- детект по /say /yell /эмоции рядом

        worldTag        = "",     -- тег для запасного формата ("" = авто, напр. "[Мир]")
        worldChannel    = "",     -- «Чаты»: через запятую теги системных строк .chat
                                  -- ([Solo], [Solo Progress]) и/или имена каналов
                                  -- ("" = всё в «Мировой чат» / только системные)

        minimapShow     = true,
        minimapAngle    = -65,

        debug           = false,

        winX            = nil,
        winY            = nil,
        winW            = 660,    -- размер главного окна (мин. 660x450,
        winH            = 450,    -- растягивается за нижний правый угол)
    },
    blacklist = {}, -- [ключ] = { name, added, expires|nil, reason|nil, source }
    friends   = {}, -- [ключ] = { name, added }
    factions  = {}, -- [ключ] = "RRGGBB" — цвет имени игрока из мирового чата
                    -- (сервер красит по фракции; каналы цвет не передают — берём отсюда)
    log       = {}, -- массив { t, p, m, f, c|nil, ch|nil, src|nil }
    dbVersion = 5,
}

local function CopyDefaults(defaults, db)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(db[k]) ~= "table" then db[k] = {} end
            CopyDefaults(v, db[k])
        else
            if db[k] == nil then db[k] = v end
        end
    end
end

function DTCC.InitDB()
    if type(DarkTechCC_DB) ~= "table" then DarkTechCC_DB = {} end
    local db = DarkTechCC_DB
    -- версию старой базы читаем ДО CopyDefaults (он проставит новую версию
    -- из DEFAULTS, и сигнал «база старая» пропадёт)
    local oldVersion = tonumber(db.dbVersion) or 1
    CopyDefaults(DEFAULTS, db)
    -- v2: настройка «Канал» (одно имя) стала списком каналов через запятую.
    -- Сохранённый одиночный «Solo» (PikaWoW) один раз дополняем «Solo Progress».
    if oldVersion < 2 then
        local wc = strtrim(tostring(db.settings.worldChannel or ""))
        if wc ~= "" and DTCC.utf8lower(wc) == "solo" then
            db.settings.worldChannel = "Solo, Solo Progress"
        end
    end
    -- v3: по умолчанию в логе виден только «Мировой чат» — локальные чаты,
    -- включённые дефолтом v1.7.0, гасим; каналы теперь тоже выключены по
    -- умолчанию (галочки включаются вручную, semantics: nil = выключен)
    if oldVersion < 3 then
        if type(db.settings.logShowSources) == "table" then
            for _, k in ipairs({ "say", "party", "guild", "whisper" }) do
                db.settings.logShowSources[k] = false
            end
        end
    end
    -- v4: «Чаты» — теперь и теги системных строк .chat. Существующей базе
    -- (не новой) с пустым списком один раз прописываем теги PikaWoW и
    -- включаем их галочки — это и есть её «мировый чат», разделённый по
    -- тегам (новые базы остаются нейтральными)
    if oldVersion < 4 then
        if oldVersion >= 2 and strtrim(tostring(db.settings.worldChannel or "")) == "" then
            db.settings.worldChannel = "Solo, Solo Progress"
            db.settings.logChannelShow = db.settings.logChannelShow or {}
            db.settings.logChannelShow["solo"] = true
            db.settings.logChannelShow["solo progress"] = true
        end
        db.dbVersion = 4
    end
    -- v5: режим цензуры по умолчанию — «Скрывать из чата» (бывший дефолт
    -- MASK никто не выбирал осознанно; переключается в настройках)
    if oldVersion < 5 then
        db.settings.censorMode = "HIDE"
        db.dbVersion = 5
    end
    DTCC.db = db
end

function DTCC.ResetSettings()
    wipe(DTCC.db.settings)
    CopyDefaults(DEFAULTS.settings, DTCC.db.settings)
    DTCC.FireEvent("SettingsChanged")
    DTCC.Print("настройки сброшены к значениям по умолчанию (списки и лог не тронуты).")
end

--------------------------------------------------------------------------------
-- Открытие окон (реализовано в Window.lua / Options.lua)
--------------------------------------------------------------------------------

function DTCC.OpenOptions()
    if DTCC.optionsPanel then
        -- двойной вызов — известный обходной приём, чтобы панель прокрутилась к нам
        InterfaceOptionsFrame_OpenToCategory(DTCC.optionsPanel)
        InterfaceOptionsFrame_OpenToCategory(DTCC.optionsPanel)
    end
end

--------------------------------------------------------------------------------
-- Слэш-команды
--------------------------------------------------------------------------------

local function ParseDurationArg(rest)
    rest = DTCC.utf8lower(strtrim(rest or ""))
    if rest == "" or rest == "навсегда" or rest == "forever" or rest == "0" then
        return 0
    end
    local n = tonumber(rest)
    if n and n >= 0 then return floor(n) * 86400 end
    return 0
end

SLASH_DTCC1 = "/dtcc"
SLASH_DTCC2 = "/dcc"
SlashCmdList["DTCC"] = function(input)
    local trimmed = strtrim(input or "")
    local cmd, rest = strsplit(" ", trimmed, 2)
    cmd = DTCC.utf8lower(cmd or "")
    rest = strtrim(rest or "")

    if cmd == "" or cmd == "window" or cmd == "окно" or cmd == "show" then
        DTCC.ToggleWindow()

    elseif cmd == "options" or cmd == "config" or cmd == "настройки" then
        DTCC.OpenOptions()

    elseif cmd == "bl" or cmd == "чс" or cmd == "blacklist" then
        DTCC.OpenWindow(1)

    elseif cmd == "friend" or cmd == "friendadd" or cmd == "друг" then
        local name = rest
        if name == "" then
            DTCC.Print("Использование: /dtcc friend Имя")
        elseif DTCC.Friends_Add(name) then
            DTCC.Print(DTCC.COLORS.green .. DTCC.CleanName(name) .. "|r добавлен в список друзей.")
        end

    elseif cmd == "unfriend" or cmd == "friendremove" then
        local name = rest
        if name == "" then
            DTCC.Print("Использование: /dtcc unfriend Имя")
        elseif DTCC.Friends_Remove(name) then
            DTCC.Print(DTCC.CleanName(name) .. " удалён из списка друзей.")
        else
            DTCC.Print(DTCC.CleanName(name) .. " не найден в списке друзей.")
        end

    elseif cmd == "friends" or cmd == "друзья" then
        DTCC.OpenWindow(2)

    elseif cmd == "log" or cmd == "лог" then
        DTCC.OpenWindow(3)

    elseif cmd == "words" or cmd == "censor" or cmd == "слова" or cmd == "цензура" then
        DTCC.OpenWindow(4)

    elseif cmd == "add" or cmd == "добавить" then
        local name, days = strsplit(" ", rest or "")
        name = strtrim(name or "")
        if name == "" then
            DTCC.Print("Использование: /dtcc add Имя [дней|навсегда]  (по умолчанию — навсегда)")
        else
            local dur = ParseDurationArg(days)
            if DTCC.Blacklist_Add(name, { duration = dur, source = "manual" }) then
                DTCC.Print(DTCC.COLORS.red .. DTCC.CleanName(name) .. "|r добавлен в ЧС (" ..
                    DTCC.DurationLabel(dur) .. ").")
            end
        end

    elseif cmd == "remove" or cmd == "удалить" then
        local name = rest
        if name == "" then
            DTCC.Print("Использование: /dtcc remove Имя")
        elseif DTCC.Blacklist_Remove(name) then
            DTCC.Print(DTCC.CleanName(name) .. " удалён из ЧС.")
        else
            DTCC.Print(DTCC.CleanName(name) .. " не найден в ЧС.")
        end

    elseif cmd == "send" or cmd == "s" or cmd == "сказать" then
        if rest == "" then
            DTCC.Print("Использование: /dtcc send сообщение — отправить в мировой чат (.chat)")
        else
            DTCC.SendWorldMessage(rest)
        end

    elseif cmd == "testalert" or cmd == "тест" then
        DTCC.TestAlert()

    elseif cmd == "debug" then
        local v = DTCC.utf8lower(rest)
        local on = true
        if v == "off" or v == "0" or v == "выкл" then on = false end
        DTCC.db.settings.debug = on
        if on then
            DTCC.Print("режим отладки |cff3fd13fвключён|r. Теперь напишите в мировой чат " ..
                "и пришлите автору строки, начинающиеся с |cff909090[debug]|r " ..
                "(коды цвета показаны как !cff…).")
        else
            DTCC.Print("режим отладки выключен.")
        end

    elseif cmd == "reset" then
        DTCC.ResetSettings()

    elseif cmd == "help" or cmd == "помощь" or cmd == "?" then
        DTCC.Print(DTCC.COLORS.yellow .. "Команды DarkTech Chat Control:")
        DTCC.Print("  /dtcc — открыть/закрыть окно аддона")
        DTCC.Print("  /dtcc options — настройки")
        DTCC.Print("  /dtcc add Имя [дней] — в ЧС (без числа — навсегда); /dtcc remove Имя — из ЧС")
        DTCC.Print("  /dtcc friend Имя / /dtcc unfriend Имя — список друзей")
        DTCC.Print("  /dtcc send текст — написать в мировой чат (.chat)")
        DTCC.Print("  /dtcc log — лог чата; /dtcc bl — чёрный список; /dtcc friends — друзья")
        DTCC.Print("  /dtcc words — вкладка цензуры (слова, авто-ЧС)")
        DTCC.Print("  /dtcc testalert — проверить алерт; /dtcc debug on|off — отладка захвата")
        DTCC.Print("  /dtcc reset — сброс настроек")

    else
        DTCC.Print("неизвестная команда. " .. DTCC.COLORS.grey .. "/dtcc help — список команд")
    end
end

--------------------------------------------------------------------------------
-- Инициализация
--------------------------------------------------------------------------------

local coreFrame = CreateFrame("Frame")
coreFrame:RegisterEvent("ADDON_LOADED")
coreFrame:RegisterEvent("PLAYER_LOGIN")
coreFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        DTCC.InitDB()
        DTCC.FireEvent("OnInitialized")

    elseif event == "PLAYER_LOGIN" then
        -- Состав файлов аддона (.toc) кэшируется при СТАРТЕ клиента.
        -- Если после обновления состав менялся, /reload новые файлы не подхватит.
        if not DTCC.UI then
            DTCC.Print(DTCC.COLORS.red ..
                "Не загружен Widgets.lua — состав .toc менялся после старта клиента. " ..
                "Нужен ПОЛНЫЙ перезапуск игры (/reload недостаточно).")
        end
        DTCC.RebuildCensorCache()
        local purged = DTCC.Blacklist_PurgeExpired()
        DTCC.FireEvent("OnPlayerLogin")
        local extra = ""
        if purged and purged > 0 then
            extra = DTCC.COLORS.grey .. " (истёкших записей ЧС удалено: " .. purged .. ")|r"
        end
        DTCC.Print("v" .. DTCC.Version .. " загружен. " ..
            DTCC.COLORS.grey .. "/dtcc — окно, /dtcc help — команды" .. extra)
    end
end)
