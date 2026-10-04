--[[
    DarkTech Chat Control — цензура.

    Список слов хранится в настройках (db.settings.censorWords), нормализуется
    при сохранении: тримминг, нижний регистр (кириллица учитывается), дубликаты
    удаляются. Сопоставление — подстрокой (слово найдётся и внутри слова).

    Режимы:
      MASK — совпадения заменяются звёздочками (по одной на символ);
      HIDE — сообщение целиком не показывается.
]]

local wordCache = {}   -- нормализованные слова
local wordSet   = {}   -- [слово] = true, для быстрой дедупликации

-- Пересобрать кэш из настроек.
function DTCC.RebuildCensorCache()
    wipe(wordCache)
    wipe(wordSet)
    if not DTCC.db then return end
    local words = DTCC.db.settings.censorWords
    if type(words) ~= "table" then return end
    for _, raw in ipairs(words) do
        local w = DTCC.utf8lower(strtrim(tostring(raw or "")))
        if w ~= "" and not wordSet[w] then
            wordSet[w] = true
            tinsert(wordCache, w)
        end
    end
end

-- Разбивает произвольный ввод (строки, запятые, точки с запятой) на слова.
local function SplitWords(list)
    local out = {}
    for _, raw in ipairs(list or {}) do
        for w in string.gmatch(tostring(raw or "") .. "\n", "[^,;\n]+") do
            out[#out + 1] = w
        end
    end
    return out
end

-- Сохранить новый список слов (массив строк, разделители: строка, запятая,
-- точка с запятой). Возвращает количество слов.
function DTCC.Censor_SetWords(list)
    if not DTCC.db then return 0 end
    local clean, seen = {}, {}
    for _, raw in ipairs(SplitWords(list)) do
        local w = DTCC.utf8lower(strtrim(raw))
        if w ~= "" and not seen[w] then
            seen[w] = true
            clean[#clean + 1] = w
        end
    end
    table.sort(clean)
    DTCC.db.settings.censorWords = clean
    DTCC.RebuildCensorCache()
    return #clean
end

-- Быстрое добавление слов (без перезаписи всего списка). true — что-то добавлено.
function DTCC.CensorWords_Add(raw)
    if not DTCC.db then return false end
    local words = DTCC.db.settings.censorWords
    if type(words) ~= "table" then words = {} end
    local added = false
    for _, raw2 in ipairs(SplitWords({ raw })) do
        local w = DTCC.utf8lower(strtrim(raw2))
        if w ~= "" then
            local exists = false
            for _, ex in ipairs(words) do
                if ex == w then exists = true break end
            end
            if not exists then
                tinsert(words, w)
                added = true
            end
        end
    end
    if added then
        table.sort(words)
        DTCC.db.settings.censorWords = words
        DTCC.RebuildCensorCache()
    end
    return added
end

-- Удалить слово (точное совпадение без учёта регистра). true — удалено.
function DTCC.CensorWords_Remove(word)
    if not DTCC.db then return false end
    local words = DTCC.db.settings.censorWords
    if type(words) ~= "table" then return false end
    local target = DTCC.utf8lower(strtrim(tostring(word or "")))
    for i, w in ipairs(words) do
        if w == target then
            tremove(words, i)
            DTCC.RebuildCensorCache()
            return true
        end
    end
    return false
end

-- Отсортированный список слов для UI.
function DTCC.Censor_GetWords()
    if not DTCC.db or type(DTCC.db.settings.censorWords) ~= "table" then
        return {}
    end
    return DTCC.db.settings.censorWords
end

-- Список слов, как строка для редактора (одно слово на строку).
function DTCC.Censor_GetWordsAsString()
    if not DTCC.db then return "" end
    local words = DTCC.db.settings.censorWords
    if type(words) ~= "table" or #words == 0 then return "" end
    return table.concat(words, "\n")
end

-- Есть ли в тексте (уже в нижнем регистре!) слово из списка.
-- Возвращает первое найденное слово либо nil.
function DTCC.CensorFind(textLower)
    for _, w in ipairs(wordCache) do
        if string.find(textLower, w, 1, true) then
            return w
        end
    end
    return nil
end

-- Длина одного символа UTF-8 по ведущему байту
local function CharLen(b)
    if b >= 0xF0 then return 4 end
    if b >= 0xE0 then return 3 end
    if b >= 0xC0 then return 2 end
    return 1
end

-- Замаскировать все вхождения слов из списка.
-- Возвращает (замаскированный текст, найдено-ли-хоть-одно-слово).
function DTCC.CensorMask(text)
    if #wordCache == 0 or not text or text == "" then
        return text, false
    end

    local low = DTCC.utf8lower(text)

    -- собираем все диапазоны совпадений (в байтах)
    local ranges = {}
    for _, w in ipairs(wordCache) do
        local init = 1
        while true do
            local s, e = string.find(low, w, init, true)
            if not s then break end
            ranges[#ranges + 1] = { s, e }
            init = e + 1
        end
    end
    if #ranges == 0 then
        return text, false
    end

    -- сортируем и сливаем пересечения
    table.sort(ranges, function(a, b) return a[1] < b[1] end)
    local merged = {}
    for _, r in ipairs(ranges) do
        local last = merged[#merged]
        if last and r[1] <= last[2] + 1 then
            if r[2] > last[2] then last[2] = r[2] end
        else
            merged[#merged + 1] = { r[1], r[2] }
        end
    end

    -- собираем результат: звёздочка на каждый символ UTF-8
    local out = {}
    local pos = 1
    for _, r in ipairs(merged) do
        if r[1] > pos then
            out[#out + 1] = string.sub(text, pos, r[1] - 1)
        end
        local cnt, i = 0, r[1]
        while i <= r[2] do
            cnt = cnt + 1
            i = i + CharLen(string.byte(text, i))
        end
        out[#out + 1] = string.rep("*", cnt)
        pos = r[2] + 1
    end
    if pos <= #text then
        out[#out + 1] = string.sub(text, pos)
    end

    return table.concat(out), true
end
