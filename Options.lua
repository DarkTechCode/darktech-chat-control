--[[
    DarkTech Chat Control — страница настроек (Interface Options).

    Все изменения применяются сразу и сохраняются в SavedVariables при выходе.
]]

local panel

--------------------------------------------------------------------------------
-- Диалоги подтверждения
--------------------------------------------------------------------------------

StaticPopupDialogs["DTCC_CLEAR_LOG"] = {
    text = "Очистить весь лог мирового чата?",
    button1 = "Очистить",
    button2 = "Отмена",
    OnAccept = function() DTCC.ClearLog() end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

StaticPopupDialogs["DTCC_RESET_SETTINGS"] = {
    text = "Сбросить все НАСТРОЙКИ к значениям по умолчанию?\nЧёрный список, друзья и лог не будут тронуты.",
    button1 = "Сбросить",
    button2 = "Отмена",
    OnAccept = function() DTCC.ResetSettings() end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

--------------------------------------------------------------------------------
-- Помощники создания виджетов
--------------------------------------------------------------------------------

local widgetCounter = 0
local function NextName(prefix)
    widgetCounter = widgetCounter + 1
    return "DTCCOpt_" .. prefix .. widgetCounter
end

local function NewCheck(parent, label, tooltip, onClick)
    local name = NextName("Check")
    -- подпись своя: в 3.3.5 у шаблона нет гарантированного «$parentText»
    local cb = CreateFrame("CheckButton", name, parent, "InterfaceOptionsCheckButtonTemplate")
    local text = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetText(label)
    text:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    text:SetJustifyH("LEFT")
    -- кликабельная зона — ровно по подписи (плюс запас), чтобы невидимый
    -- прямоугольник не перекрывал соседние контролы (дропдауны, кнопки)
    cb:SetHitRectInsets(0, -(text:GetStringWidth() + 10), 0, 0)
    if tooltip then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label, 1, 0.9, 0.3)
            GameTooltip:AddLine(tooltip, nil, nil, nil, 1)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
    end
    if onClick then
        cb:SetScript("OnClick", function(self)
            local checked = self:GetChecked() and true or false
            onClick(checked)
            DTCC.FireEvent("SettingsChanged")
            PlaySound(self:GetChecked() and "igMainMenuOptionCheckBoxOn" or "igMainMenuOptionCheckBoxOff")
        end)
    end
    return cb
end

-- items: { { text = .., value = .. }, ... }
local function NewDropdown(parent, label, items, get, set, width, tooltip)
    local dd = DTCC.UI.CreateDropdown(parent, items, get, function(value)
        set(value)
        DTCC.FireEvent("SettingsChanged")
    end, width, nil, tooltip)
    -- подпись сверху
    if label then
        local lbl = dd:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("BOTTOMLEFT", dd, "TOPLEFT", 2, 3)
        lbl:SetText(label)
    end
    return dd
end

local function RefreshDropdown(dd)
    if dd.RefreshText then
        dd.RefreshText()
    end
end

local function NewButton(parent, text, width, onClick)
    local b = CreateFrame("Button", NextName("Button"), parent, "UIPanelButtonTemplate")
    b:SetText(text)
    b:SetWidth(width or 110)
    b:SetHeight(22)
    b:SetScript("OnClick", onClick)
    return b
end

local function NewEdit(parent, width, onApply)
    local eb = CreateFrame("EditBox", NextName("Edit"), parent, "InputBoxTemplate")
    eb:SetWidth(width or 140)
    eb:SetHeight(20)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        if onApply then onApply(self:GetText()) end
    end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return eb
end

local function NewSection(parent, title)
    widgetCounter = widgetCounter + 1
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetText("|cff00e5ff" .. title .. "|r")
    return fs
end

--------------------------------------------------------------------------------
-- Сборка панели
--------------------------------------------------------------------------------

local function BuildPanel()
    panel = CreateFrame("Frame", "DTCCOptionsPanel", UIParent)
    panel.name = "DarkTech Chat Control"
    panel:SetWidth(588)
    panel:SetHeight(455)
    DTCC.optionsPanel = panel

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("DarkTech Chat Control")

    local version = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    version:SetPoint("LEFT", title, "RIGHT", 8, 0)
    version:SetTextColor(0.6, 0.6, 0.6)
    version:SetText("v" .. DTCC.Version)

    local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    hint:SetTextColor(0.8, 0.8, 0.8)
    hint:SetText("Главное окно аддона: /dtcc  •  Команды: /dtcc help")

    local scroll = CreateFrame("ScrollFrame", "DTCCOptionsScroll", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -48)
    scroll:SetPoint("BOTTOMRIGHT", -28, 10)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(540)
    scroll:SetScrollChild(content)

    local s -- = DTCC.db.settings (в Refresh)

    local CY = -10
    local function Advance(dy) CY = CY - dy end

    ---------------------------------------------------------------- Основное
    local secMain = NewSection(content, "Основное")
    secMain:SetPoint("TOPLEFT", 0, CY)
    Advance(24)

    local cbEnabled = NewCheck(content, "Обрабатывать сообщения мирового чата",
        "Главный выключатель: фильтрация ЧС, цензура, логирование.",
        function(v) DTCC.db.settings.enabled = v end)

    local cbHideBL = NewCheck(content, "Скрывать сообщения игроков из чёрного списка",
        "Сообщения игроков, добавленных в ЧС, не показываются в чате (остаются в логе).",
        function(v) DTCC.db.settings.hideBlacklisted = v end)

    local cbPlaceholder = NewCheck(content, "Показывать заглушку вместо скрытых сообщений",
        "Вместо скрытого сообщения будет серая строка «[DTCC] Имя: сообщение скрыто (ЧС)».",
        function(v) DTCC.db.settings.showPlaceholder = v end)

    local cbStamps = NewCheck(content, "Показывать время сообщений мирового чата",
        "Каждое сообщение получит префикс [ЧЧ:ММ].",
        function(v) DTCC.db.settings.showTimestamps = v end)

    local cbFriendsHL = NewCheck(content, "Подсвечивать сообщения друзей",
        "Перед сообщением друга будет зелёная метка [ДРУГ].",
        function(v) DTCC.db.settings.friendsHighlight = v end)

    for _, cb in ipairs({ cbEnabled, cbHideBL, cbPlaceholder, cbStamps, cbFriendsHL }) do
        cb:SetPoint("TOPLEFT", 10, CY)
        Advance(24)
    end
    Advance(6)

    ---------------------------------------------------------------- Цензура
    local secCensor = NewSection(content, "Цензура и авто-ЧС")
    secCensor:SetPoint("TOPLEFT", 0, CY)
    Advance(24)

    local cbCensor = NewCheck(content, "Включить цензуру по списку слов",
        "Слова ищутся подстрокой (без учёта регистра, кириллица поддерживается).",
        function(v) DTCC.db.settings.censorEnabled = v end)
    cbCensor:SetPoint("TOPLEFT", 10, CY)
    Advance(38)

    local ddMode = NewDropdown(content, "Режим цензуры",
        {
            { text = "Маскировать (***)", value = "MASK" },
            { text = "Скрывать из чата", value = "HIDE" },
        },
        function() return DTCC.db.settings.censorMode end,
        function(v) DTCC.db.settings.censorMode = v end,
        150,
        "Маскировать: запрещённые слова заменяются на ***.\n" ..
        "Скрывать из чата: сообщение с запрещённым словом не показывается вообще (в логе остаётся).")
    ddMode:SetPoint("TOPLEFT", 10, CY)
    Advance(50)

    local cbAutoBL = NewCheck(content, "Автоматически добавлять в ЧС за слово из списка",
        "Если игрок написал сообщение с запрещённым словом — он автоматически попадёт в ЧС на выбранный срок. Сообщение сохранится как причина.",
        function(v) DTCC.db.settings.autoBlacklist = v end)
    cbAutoBL:SetPoint("TOPLEFT", 10, CY)
    Advance(38)

    local ddBLDuration = NewDropdown(content, "Срок авто-ЧС",
        DTCC.DURATIONS,
        function() return DTCC.db.settings.autoBLDuration end,
        function(v) DTCC.db.settings.autoBLDuration = v end,
        150)
    ddBLDuration:SetPoint("TOPLEFT", 10, CY)
    Advance(56)

    -- редактор списка слов
    local wordsLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    wordsLabel:SetPoint("TOPLEFT", 10, CY)
    wordsLabel:SetText("Список слов цензуры (по одному на строку или через запятую):")
    Advance(16)

    -- редактор списка слов; wordsEdit предобъявлен: замыкание контейнера должно
    -- захватить local, а не глобал (ловушка Lua 5.1)
    local wordsEdit

    -- контейнер фиксированного размера: у пустого многострочного EditBox в 3.3.5
    -- высота схлопывается до одной строки, клик по «пустому месту» не попадает;
    -- фон и клик-в-фокус держит контейнер
    local wordsBox = CreateFrame("Frame", nil, content)
    wordsBox:SetWidth(500)
    wordsBox:SetHeight(110)
    wordsBox:SetPoint("TOPLEFT", 10, CY)
    wordsBox:EnableMouse(true)
    wordsBox:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    wordsBox:SetBackdropColor(0, 0, 0, 0.6)
    wordsBox:SetScript("OnMouseDown", function()
        if wordsEdit then wordsEdit:SetFocus() end
    end)

    local wordsScroll = CreateFrame("ScrollFrame", "DTCCOptWordsScroll", wordsBox, "UIPanelScrollFrameTemplate")
    wordsScroll:SetPoint("TOPLEFT", 6, -6)
    wordsScroll:SetPoint("BOTTOMRIGHT", -24, 6)

    wordsEdit = CreateFrame("EditBox", "DTCCOptWordsEdit", wordsScroll)
    wordsEdit:SetMultiLine(true)
    wordsEdit:SetWidth(464)
    wordsEdit:SetHeight(98)
    wordsEdit:SetAutoFocus(false)
    wordsEdit:SetFontObject("GameFontHighlightSmall")
    wordsEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    wordsScroll:SetScrollChild(wordsEdit)
    wordsEdit:SetScript("OnCursorChanged", function(self, x, y, w, h)
        local scrollbar = _G["DTCCOptWordsScrollScrollBar"]
        if not scrollbar then return end
        local offset = scrollbar:GetValue()
        if y < offset + 10 then
            scrollbar:SetValue(y - 10)
        elseif y + h + 10 > offset + wordsScroll:GetHeight() then
            scrollbar:SetValue(y + h + 10 - wordsScroll:GetHeight())
        end
    end)
    Advance(116)

    local wordsInfo = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    wordsInfo:SetPoint("TOPLEFT", 10, CY)
    wordsInfo:SetTextColor(0.6, 0.6, 0.6)
    Advance(18)

    local btnApplyWords = NewButton(content, "Применить слова", 140, function()
        local lines = { strsplit("\n", wordsEdit:GetText()) }
        local n = DTCC.Censor_SetWords(lines)
        wordsInfo:SetText("Сохранено слов: " .. n)
        DTCC.Print("список слов цензуры сохранён (" .. n .. " шт.).")
    end)
    btnApplyWords:SetPoint("TOPLEFT", 10, CY)

    local btnReloadWords = NewButton(content, "Обновить поле", 110, function()
        wordsEdit:SetText(DTCC.Censor_GetWordsAsString())
        wordsInfo:SetText("")
    end)
    btnReloadWords:SetPoint("LEFT", btnApplyWords, "RIGHT", 8, 0)
    Advance(32)
    Advance(6)

    ---------------------------------------------------------------- Лог
    local secLog = NewSection(content, "Лог чата")
    secLog:SetPoint("TOPLEFT", 0, CY)
    Advance(24)

    local cbLog = NewCheck(content, "Вести лог сообщений мирового чата",
        "Лог хранится в SavedVariables и доступен между сеансами игры. Поиск и фильтры — в окне аддона (/dtcc).",
        function(v) DTCC.db.settings.logEnabled = v end)
    cbLog:SetPoint("TOPLEFT", 10, CY)
    Advance(38)

    local ddLogLimit = NewDropdown(content, "Максимальный размер лога",
        {
            { text = "1 000 сообщений",  value = 1000 },
            { text = "3 000 сообщений",  value = 3000 },
            { text = "5 000 сообщений",  value = 5000 },
            { text = "10 000 сообщений", value = 10000 },
        },
        function() return DTCC.db.settings.logLimit end,
        function(v) DTCC.db.settings.logLimit = v end,
        150)
    ddLogLimit:SetPoint("TOPLEFT", 10, CY)
    Advance(56)

    local btnOpenLog = NewButton(content, "Открыть лог", 110, function()
        DTCC.OpenWindow(3)
    end)
    btnOpenLog:SetPoint("TOPLEFT", 10, CY)

    local btnClearLog = NewButton(content, "Очистить лог", 110, function()
        StaticPopup_Show("DTCC_CLEAR_LOG")
    end)
    btnClearLog:SetPoint("LEFT", btnOpenLog, "RIGHT", 8, 0)
    Advance(32)
    Advance(6)

    ---------------------------------------------------------------- Алерты
    local secAlerts = NewSection(content, "Алерты: игрок из ЧС рядом")
    secAlerts:SetPoint("TOPLEFT", 0, CY)
    Advance(24)

    local cbAlert = NewCheck(content, "Включить алерты",
        "Срабатывает при наведении курсора, взятии в цель/фокус и когда игрок из ЧС говорит рядом (/say, крик, эмоции).",
        function(v) DTCC.db.settings.alertEnabled = v end)
    cbAlert:SetPoint("TOPLEFT", 10, CY)
    Advance(24)

    local cbAlertPopup = NewCheck(content, "Всплывающее окно (как SilverDragon)",
        "Окно вверху экрана: имя игрока и причина ЧС. ЛКМ — взять в цель, ПКМ — закрыть.",
        function(v) DTCC.db.settings.alertPopup = v end)
    cbAlertPopup:SetPoint("TOPLEFT", 10, CY)
    Advance(24)

    local cbAlertRW = NewCheck(content, "Raid Warning по центру",
        nil,
        function(v) DTCC.db.settings.alertRW = v end)
    cbAlertRW:SetPoint("TOPLEFT", 10, CY)
    Advance(24)

    local cbAlertChat = NewCheck(content, "Сообщение в чат",
        nil,
        function(v) DTCC.db.settings.alertChat = v end)
    cbAlertChat:SetPoint("TOPLEFT", 10, CY)
    Advance(24)

    local cbAlertErr = NewCheck(content, "Красная строка по центру экрана",
        nil,
        function(v) DTCC.db.settings.alertErrors = v end)
    cbAlertErr:SetPoint("TOPLEFT", 10, CY)
    Advance(24)

    local cbAlertSay = NewCheck(content, "Реагировать на /say, крики и эмоции рядом",
        "Дополнительный способ обнаружения: игрок из ЧС что-то сказал поблизости.",
        function(v) DTCC.db.settings.alertSayDetect = v end)
    cbAlertSay:SetPoint("TOPLEFT", 10, CY)
    Advance(38)

    local ddSound = NewDropdown(content, "Звук алерта",
        DTCC.SOUNDS,
        function() return DTCC.db.settings.alertSound end,
        function(v) DTCC.db.settings.alertSound = v end,
        180)
    ddSound:SetPoint("TOPLEFT", 10, CY)
    Advance(56)

    local slider = CreateFrame("Slider", "DTCCOptCooldown", content, "OptionsSliderTemplate")
    slider:SetWidth(240)
    slider:SetMinMaxValues(5, 300)
    slider:SetValueStep(5)
    -- у OptionsSliderTemplate в 3.3.5 подписи есть, но полагаться на глобальные
    -- имена не будем — при их отсутствии рисуем свои
    local sliderLabel = _G["DTCCOptCooldownText"]
    if sliderLabel then
        sliderLabel:SetText("Пауза между алертами об одном игроке (сек)")
    else
        sliderLabel = slider:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        sliderLabel:SetPoint("BOTTOM", slider, "TOP", 0, 6)
        sliderLabel:SetText("Пауза между алертами об одном игроке (сек)")
    end
    local lowLabel = _G["DTCCOptCooldownLow"]
    if lowLabel then lowLabel:SetText("5") end
    local highLabel = _G["DTCCOptCooldownHigh"]
    if highLabel then highLabel:SetText("300") end
    slider:SetPoint("TOPLEFT", 10, CY)
    slider:SetScript("OnValueChanged", function(self, value)
        DTCC.db.settings.alertCooldown = floor(value + 0.5)
    end)
    Advance(48)

    local btnTest = NewButton(content, "Тест алерта", 110, function()
        DTCC.TestAlert()
    end)
    btnTest:SetPoint("TOPLEFT", 10, CY)
    Advance(32)
    Advance(6)

    ---------------------------------------------------------------- Источник
    local secSource = NewSection(content, "Источник мирового чата")
    secSource:SetPoint("TOPLEFT", 0, CY)
    Advance(24)

    local tagLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tagLabel:SetPoint("TOPLEFT", 10, CY)
    tagLabel:SetText("Тег мирового чата в начале строки:")
    Advance(16)

    local tagEdit = NewEdit(content, 160, function(text)
        DTCC.db.settings.worldTag = strtrim(text or "")
        DTCC.Print("тег мирового чата: " ..
            (DTCC.db.settings.worldTag ~= "" and DTCC.db.settings.worldTag or "автоопределение"))
    end)
    tagEdit:SetPoint("TOPLEFT", 10, CY)
    tagEdit:SetText(DTCC.db.settings.worldTag or "")
    Advance(28)

    local tagHint = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tagHint:SetPoint("TOPLEFT", 10, CY)
    tagHint:SetWidth(510)
    tagHint:SetJustifyH("LEFT")
    tagHint:SetTextColor(0.6, 0.6, 0.6)
    tagHint:SetText("Пусто — автоопределение по формату [Тег][фракция][ссылка игрока].\n" ..
        "Если сообщения не перехватываются: /dtcc debug on, пришлите строку из чата автору.")
    Advance(36)

    local chanLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chanLabel:SetPoint("TOPLEFT", 10, CY)
    chanLabel:SetText("Каналы через запятую (если сервер доставляет чат каналами, а не системными):")
    Advance(16)

    local chanEdit = NewEdit(content, 240, function(text)
        DTCC.db.settings.worldChannel = strtrim(text or "")
        DTCC.Print("каналы мирового чата: " ..
            (DTCC.db.settings.worldChannel ~= "" and DTCC.db.settings.worldChannel or "выкл (системные сообщения)"))
    end)
    chanEdit:SetPoint("TOPLEFT", 10, CY)
    Advance(28)

    local chanHint = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chanHint:SetPoint("TOPLEFT", 10, CY)
    chanHint:SetWidth(510)
    chanHint:SetJustifyH("LEFT")
    chanHint:SetTextColor(0.6, 0.6, 0.6)
    chanHint:SetText("Например: Solo, Solo Progress. Для каждого канала на вкладке «Лог» появится своя галочка-фильтр.")
    Advance(20)

    local cbDebug = NewCheck(content, "Режим отладки (печатать все системные сообщения с игроками)",
        nil,
        function(v) DTCC.db.settings.debug = v end)
    cbDebug:SetPoint("TOPLEFT", 10, CY)
    Advance(24)
    Advance(6)

    ---------------------------------------------------------------- Прочее
    local secOther = NewSection(content, "Прочее")
    secOther:SetPoint("TOPLEFT", 0, CY)
    Advance(24)

    local cbMinimap = NewCheck(content, "Кнопка на миникарте",
        nil,
        function(v)
            DTCC.db.settings.minimapShow = v
            DTCC.FireEvent("MinimapSettingChanged")
        end)
    cbMinimap:SetPoint("TOPLEFT", 10, CY)
    Advance(24)

    local btnWindow = NewButton(content, "Открыть окно аддона", 160, function()
        DTCC.ToggleWindow()
    end)
    btnWindow:SetPoint("TOPLEFT", 10, CY)

    local btnReset = NewButton(content, "Сбросить настройки", 140, function()
        StaticPopup_Show("DTCC_RESET_SETTINGS")
    end)
    btnReset:SetPoint("LEFT", btnWindow, "RIGHT", 8, 0)
    Advance(32)

    content:SetHeight(-CY + 20)

    ---------------------------------------------------------------- синхронизация
    local function Refresh()
        if not DTCC.db then return end
        s = DTCC.db.settings
        cbEnabled:SetChecked(s.enabled)
        cbHideBL:SetChecked(s.hideBlacklisted)
        cbPlaceholder:SetChecked(s.showPlaceholder)
        cbStamps:SetChecked(s.showTimestamps)
        cbFriendsHL:SetChecked(s.friendsHighlight)
        cbCensor:SetChecked(s.censorEnabled)
        cbAutoBL:SetChecked(s.autoBlacklist)
        RefreshDropdown(ddMode)
        RefreshDropdown(ddBLDuration)
        RefreshDropdown(ddLogLimit)
        cbLog:SetChecked(s.logEnabled)
        cbAlert:SetChecked(s.alertEnabled)
        cbAlertPopup:SetChecked(s.alertPopup)
        cbAlertRW:SetChecked(s.alertRW)
        cbAlertChat:SetChecked(s.alertChat)
        cbAlertErr:SetChecked(s.alertErrors)
        cbAlertSay:SetChecked(s.alertSayDetect)
        RefreshDropdown(ddSound)
        slider:SetValue(tonumber(s.alertCooldown) or 60)
        tagEdit:SetText(s.worldTag or "")
        chanEdit:SetText(s.worldChannel or "")
        cbDebug:SetChecked(s.debug)
        cbMinimap:SetChecked(s.minimapShow)
        wordsInfo:SetText("В списке слов: " .. #(DTCC.db.settings.censorWords or {}))
    end

    panel:SetScript("OnShow", function()
        Refresh()
        -- при первом открытии заполняем редактор слов текущим списком
        if not panel.wordsLoaded then
            panel.wordsLoaded = true
            wordsEdit:SetText(DTCC.Censor_GetWordsAsString())
        end
    end)

    DTCC.RegisterCallback("SettingsChanged", Refresh)
    InterfaceOptions_AddCategory(panel)
end

DTCC.RegisterCallback("OnInitialized", BuildPanel)
