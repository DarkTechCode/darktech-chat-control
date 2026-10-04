--[[
    DarkTech Chat Control — главное окно.

    Вкладки:
      1. Чёрный список — добавление/удаление, сроки, причина (ПКМ — меню);
      2. Друзья;
      3. Лог — поиск по тексту и игроку, фильтры по периоду и типу,
         действия над автором сообщения через ПКМ;
      4. Цензура — редактор списка слов, режим, авто-ЧС и срок.

    Внизу — поле отправки сообщения в мировой чат (.chat).

    Окно растягивается за уголок в правом нижнем углу (SetResizable +
    StartSizing("BOTTOMRIGHT")); число видимых строк списков и ширина
    последних колонок подстраиваются под размер (пул строк ROW_POOL),
    размер и положение сохраняются в настройках (winW/winH/winX/winY).

    Все выпадающие списки и контекстные меню — собственные (Widgets.lua),
    без UIDropDownMenu.
]]

local ROW_H = 24
local ROW_POOL = 32   -- пул строк списков: окно растягивается, видно больше 10

local WIN_MIN_W = 660 -- минимальный размер окна (= исходный фиксированный,
local WIN_MIN_H = 450 -- меньше него верхние панели вкладок не помещаются)

local window
local tabs = {}
local pages = {}
local currentTab = 1
local NUM_TABS = 4

--------------------------------------------------------------------------------
-- Общие помощники
--------------------------------------------------------------------------------

local widgetCounter = 0
local function NextName(prefix)
    widgetCounter = widgetCounter + 1
    return "DTCCWin_" .. prefix .. widgetCounter
end

local function MakeDropdown(parent, items, get, set, width, name, tooltip)
    return DTCC.UI.CreateDropdown(parent, items, get, set, width, name, tooltip)
end

local function MakeEdit(parent, width, onEnter, name)
    local eb = CreateFrame("EditBox", name or NextName("Edit"), parent, "InputBoxTemplate")
    eb:SetWidth(width or 120)
    eb:SetHeight(20)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        if onEnter then onEnter(self:GetText()) end
    end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return eb
end

local function MakeButton(parent, text, width, onClick, name)
    local b = CreateFrame("Button", name or NextName("Btn"), parent, "UIPanelButtonTemplate")
    b:SetText(text)
    b:SetWidth(width or 100)
    b:SetHeight(22)
    b:SetScript("OnClick", onClick)
    return b
end

local function MakeLabel(parent, text, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
    fs:SetText(text)
    return fs
end

-- Строка списка: подсветка при наведении + клики
local function MakeRow(parent, cols)
    -- cols: массив { x, width, template, justify }
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_H)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetAllPoints(row)
    hl:SetBlendMode("ADD")
    row.texts = {}
    for i, c in ipairs(cols) do
        local fs = row:CreateFontString(nil, "OVERLAY", c.template or "GameFontNormalSmall")
        fs:SetPoint("LEFT", c.x, 0)
        fs:SetWidth(c.width)
        fs:SetJustifyH(c.justify or "LEFT")
        row.texts[i] = fs
    end
    return row
end

-- Уместить текст в колонку: сначала грубо по числу символов, затем (если
-- фактическая ширина вылезает — кириллица шире латиницы) ужимаем дальше.
-- Меняет текст fontstring'а, добавляет «…» при усечении.
local function FitText(fs, text, budget)
    text = tostring(text or "")
    local t = DTCC.Truncate(text, budget)
    if #t < #text then t = t .. "…" end
    fs:SetText(t)
    while fs:GetStringWidth() > fs:GetWidth() and budget > 8 do
        budget = floor(budget * 0.85)
        t = DTCC.Truncate(text, budget)
        if #t < #text then t = t .. "…" end
        fs:SetText(t)
    end
end

-- Держать offset скролла в допустимых пределах. Число видимых строк меняется
-- с размером окна, а FauxScrollFrame_Update сам offset не подрезает.
local function ClampScroll(scroll, numItems, visible, lineH)
    local maxOff = max(0, numItems - visible)
    local off = FauxScrollFrame_GetOffset(scroll) or 0
    if off > maxOff then
        off = maxOff
        scroll.offset = off
        local sb = scroll:GetName() and _G[scroll:GetName() .. "ScrollBar"]
        if sb and sb.SetValue then sb:SetValue(off * lineH) end
    end
    return off
end

-- Сколько строк высотой lineH влезает в страницу высоты h
-- (topPad — верхний отступ списка + нижнее поле)
local function RowsForHeight(h, topPad, lineH, poolMax)
    local n = floor((h - topPad) / lineH)
    return min(max(n, 1), poolMax)
end

--------------------------------------------------------------------------------
-- Контекстное меню (общее для всех вкладок), своё всплывающее меню
--------------------------------------------------------------------------------

local menuCtx

local function MenuDescriptor(ctx)
    local items = {}
    if not ctx then return items end
    local mode = ctx.mode

    if mode == "bl" then
        local e = ctx.entry
        items[#items + 1] = {
            text = "Убрать из ЧС",
            func = function()
                DTCC.Blacklist_Remove(e.name)
                DTCC.Print(DTCC.CleanName(e.name) .. " удалён из ЧС.")
            end,
        }
        if e.expires then
            items[#items + 1] = {
                text = "Сделать бессрочным",
                func = function()
                    DTCC.Blacklist_MakePermanent(e.name)
                    DTCC.Print(DTCC.CleanName(e.name) .. " — запись в ЧС теперь бессрочная.")
                end,
            }
        end
        items[#items + 1] = {
            text = "Добавить в друзья (убрать из ЧС)",
            func = function()
                DTCC.Blacklist_Remove(e.name)
                DTCC.Friends_Add(e.name)
                DTCC.Print(DTCC.CleanName(e.name) .. " перенесён из ЧС в друзья.")
            end,
        }
        if e.reason and e.reason ~= "" then
            items[#items + 1] = {
                text = "Причину — в чат",
                func = function()
                    DTCC.Print("Причина ЧС (" .. e.name .. "): «" .. e.reason .. "»")
                end,
            }
        end

    elseif mode == "friend" then
        local e = ctx.entry
        items[#items + 1] = {
            text = "Убрать из друзей",
            func = function()
                DTCC.Friends_Remove(e.name)
                DTCC.Print(DTCC.CleanName(e.name) .. " удалён из друзей.")
            end,
        }
        items[#items + 1] = {
            text = "Перенести в ЧС (навсегда)",
            func = function()
                DTCC.Friends_Remove(e.name)
                DTCC.Blacklist_Add(e.name, { duration = 0, source = "manual" })
                DTCC.Print(DTCC.CleanName(e.name) .. " перенесён из друзей в ЧС.")
            end,
        }

    elseif mode == "log" then
        local e = ctx.entry
        local name = e.p
        local inBL = DTCC.Blacklist_Get(name) and true or false
        local inFr = DTCC.Friends_Get(name) and true or false

        items[#items + 1] = {
            text = "Добавить в ЧС навсегда (за это сообщение)",
            func = function()
                DTCC.Blacklist_Add(name, {
                    display  = name,
                    reason   = e.m,
                    duration = 0,
                    source   = "manual",
                })
                DTCC.Print(DTCC.COLORS.red .. name .. "|r добавлен в ЧС (навсегда).")
            end,
        }
        items[#items + 1] = {
            text = "Добавить в ЧС на 1 день (за это сообщение)",
            func = function()
                DTCC.Blacklist_Add(name, {
                    display  = name,
                    reason   = e.m,
                    duration = 86400,
                    source   = "manual",
                })
                DTCC.Print(DTCC.COLORS.red .. name .. "|r добавлен в ЧС (1 день).")
            end,
        }
        items[#items + 1] = {
            text = "Добавить в друзей",
            func = function()
                DTCC.Friends_Add(name)
                DTCC.Print(DTCC.COLORS.green .. name .. "|r добавлен в друзья.")
            end,
        }
        if inBL then
            items[#items + 1] = {
                text = "Убрать из ЧС",
                func = function()
                    DTCC.Blacklist_Remove(name)
                    DTCC.Print(name .. " удалён из ЧС.")
                end,
            }
        end
        if inFr then
            items[#items + 1] = {
                text = "Убрать из друзей",
                func = function()
                    DTCC.Friends_Remove(name)
                    DTCC.Print(name .. " удалён из друзей.")
                end,
            }
        end
    end
    return items
end

local function ShowMenu(ctx)
    menuCtx = ctx
    DTCC.UI.PopupMenu(MenuDescriptor(ctx))
end

--------------------------------------------------------------------------------
-- Вкладка «Чёрный список»
--------------------------------------------------------------------------------

local blPage, blScroll, blRows, blItems, blDurationDD, blNameEdit, blCount
local blHeaders = {}
local blSortKey, blSortDir = "added", "desc"
local blVisible = 10  -- видимых строк (зависит от высоты окна)
local blBudget = 34   -- бюджет символов колонки «Причина» (от ширины окна)

-- Перерисовать строки из кэша blItems (без сортировки). Вызывается и во
-- время растягивания окна: сортировка/поиск там не нужны — только скорость.
local function BLRender()
    if not blScroll or not blRows then return end
    blItems = blItems or {}
    local off = ClampScroll(blScroll, #blItems, blVisible, ROW_H)
    for i = 1, ROW_POOL do
        local row = blRows[i]
        local item = (i <= blVisible) and blItems[off + i] or nil
        if item then
            row.entry = item
            row:Show()
            row.texts[1]:SetText(item.name)
            row.texts[1]:SetTextColor(1, 0.35, 0.35)
            row.texts[2]:SetText(DTCC.FormatTimeShort(item.added))
            row.texts[2]:SetTextColor(0.6, 0.6, 0.6)
            if item.expires then
                local left = item.expires - time()
                if left <= 0 then
                    row.texts[3]:SetText("истёк")
                    row.texts[3]:SetTextColor(0.5, 0.5, 0.5)
                else
                    row.texts[3]:SetText(DTCC.FormatRemaining(item.expires))
                    row.texts[3]:SetTextColor(1, 0.8, 0.3)
                end
            else
                row.texts[3]:SetText("навсегда")
                row.texts[3]:SetTextColor(0.6, 0.6, 0.6)
            end
            local reason = item.reason or ""
            if reason == "" then
                row.texts[4]:SetText("—")
                row.texts[4]:SetTextColor(0.45, 0.45, 0.45)
            else
                FitText(row.texts[4], reason, blBudget)
                row.texts[4]:SetTextColor(0.75, 0.75, 0.75)
            end
        else
            row.entry = nil
            row:Hide()
        end
    end
    FauxScrollFrame_Update(blScroll, #blItems, blVisible, ROW_H)
end

local function BLRefresh()
    if not window or not window:IsShown() or currentTab ~= 1 then return end
    if not blScroll or not blRows then return end
    blItems = DTCC.Blacklist_GetSorted(blSortKey, blSortDir)
    blCount:SetText("Записей: " .. #blItems)
    BLRender()
end

-- Подгонка под размер окна: сколько строк видно + ширина последней колонки
-- («Причина») и её заголовка. Работает и для скрытой страницы — якоря живут.
local function BLLayout()
    if not blPage or not blRows or not blHeaders[4] then return end
    blVisible = RowsForHeight(blPage:GetHeight(), 72, ROW_H, ROW_POOL)
    local w = blPage:GetWidth()
    local lastW = max(80, w - 312 - 46)
    blBudget = max(10, floor(lastW / 6))
    blHeaders[4]:SetWidth(max(80, w - 320 - 40))
    for i = 1, ROW_POOL do
        blRows[i].texts[4]:SetWidth(lastW)
    end
end

-- Перерисовать заголовки таблицы: у активного столбца — стрелка направления
local function BLApplySortHeader()
    for _, h in ipairs(blHeaders) do
        local t = h.baseText
        if h.sortKey == blSortKey then
            t = t .. (blSortDir == "asc" and " |cff00e5ff▲|r" or " |cff00e5ff▼|r")
        end
        h.text:SetText(t)
    end
end

local function BLSortClick(key)
    if blSortKey == key then
        blSortDir = (blSortDir == "asc") and "desc" or "asc"
    else
        blSortKey = key
        blSortDir = (key == "added" or key == "expires") and "desc" or "asc"
    end
    if DTCC.db then
        DTCC.db.settings.blSortKey = blSortKey
        DTCC.db.settings.blSortDir = blSortDir
    end
    BLApplySortHeader()
    BLRefresh()
end

-- Заголовок-кнопка столбца: клик сортирует таблицу
local function MakeSortHeader(parent, text, key, x, width)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(16)
    btn:SetWidth(width)
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetAllPoints(btn)
    hl:SetBlendMode("ADD")
    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetAllPoints(btn)
    fs:SetJustifyH("LEFT")
    fs:SetTextColor(0.55, 0.55, 0.55)
    btn.baseText = text
    btn.sortKey = key
    btn.text = fs
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -46)
    btn:SetScript("OnClick", function() BLSortClick(key) end)
    return btn
end

local function BLTooltip(row)
    local e = row.entry
    if not e then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(e.name, 1, 0.4, 0.4)
    GameTooltip:AddLine("Добавлен: " .. DTCC.FormatDateFull(e.added), 0.8, 0.8, 0.8)
    if e.expires then
        GameTooltip:AddLine("Истекает: " .. DTCC.FormatDateFull(e.expires) ..
            " (осталось " .. DTCC.FormatRemaining(e.expires) .. ")", 1, 0.8, 0.3)
    else
        GameTooltip:AddLine("Срок: навсегда", 0.7, 0.7, 0.7)
    end
    GameTooltip:AddLine("Источник: " .. (e.source == "censor" and "авто (цензура)" or "вручную"), 0.8, 0.8, 0.8)
    if e.reason and e.reason ~= "" then
        GameTooltip:AddLine("Причина:", 0.9, 0.9, 0.9)
        GameTooltip:AddLine(e.reason, 1, 1, 1, 1)
    end
    GameTooltip:AddLine("ПКМ — меню действий; клик по заголовку столбца — сортировка", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local blDurationValue = 0

local function BuildBLPage(parent)
    blPage = CreateFrame("Frame", "DTCCWin_BLPage", parent)
    blPage:SetAllPoints()
    pages[1] = blPage

    local lbl = MakeLabel(blPage, "Имя:", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", 8, -6)

    blNameEdit = MakeEdit(blPage, 140, nil)
    blNameEdit:SetPoint("TOPLEFT", 46, -4)

    local addBL = MakeButton(blPage, "В ЧС", 66, function()
        local name = strtrim(blNameEdit:GetText() or "")
        if name == "" then return end
        local dur = blDurationValue
        if DTCC.Blacklist_Add(name, { duration = dur, source = "manual" }) then
            DTCC.Print(DTCC.COLORS.red .. DTCC.CleanName(name) .. "|r добавлен в ЧС (" ..
                DTCC.DurationLabel(dur) .. ").")
            blNameEdit:SetText("")
            BLRefresh()
        end
    end)
    addBL:SetPoint("TOPLEFT", 192, -2)

    local addFriend = MakeButton(blPage, "В друзья", 84, function()
        local name = strtrim(blNameEdit:GetText() or "")
        if name == "" then return end
        if DTCC.Friends_Add(name) then
            DTCC.Print(DTCC.COLORS.green .. DTCC.CleanName(name) .. "|r добавлен в друзья.")
            blNameEdit:SetText("")
            BLRefresh()
        end
    end)
    addFriend:SetPoint("LEFT", addBL, "RIGHT", 6, 0)

    blDurationDD = MakeDropdown(blPage, DTCC.DURATIONS,
        function() return blDurationValue end,
        function(v) blDurationValue = v end,
        110, "DTCCWin_BLDD")

    local durHint = MakeLabel(blPage, "Срок добавления", "GameFontNormalSmall")
    durHint:SetTextColor(0.5, 0.5, 0.5)
    durHint:SetPoint("BOTTOMLEFT", blDurationDD, "TOPLEFT", 2, 3)

    blCount = MakeLabel(blPage, "", "GameFontNormalSmall")
    blCount:SetTextColor(0.6, 0.6, 0.6)
    blCount:SetPoint("TOPRIGHT", blPage, "TOPRIGHT", -8, -10)

    -- заголовки-кнопки: клик сортирует столбец, повторный клик меняет направление
    blHeaders = {
        MakeSortHeader(blPage, "Игрок",               "name",    16,  114),
        MakeSortHeader(blPage, "Добавлен",            "added",   138, 94),
        MakeSortHeader(blPage, "Срок",                "expires", 238, 76),
        MakeSortHeader(blPage, "Причина (сообщение)", "reason",  320, 272),
    }

    blScroll = CreateFrame("ScrollFrame", "DTCCWinBLScroll", blPage, "FauxScrollFrameTemplate")
    blScroll:SetPoint("TOPLEFT", 6, -64)
    blScroll:SetPoint("BOTTOMRIGHT", -28, 8)
    blScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, BLRefresh)
    end)

    blRows = {}
    for i = 1, ROW_POOL do
        local row = MakeRow(blPage, {
            { x = 8,   width = 114 },
            { x = 130, width = 94  },
            { x = 230, width = 76  },
            { x = 312, width = 272 },
        })
        row:SetPoint("TOPLEFT", blPage, "TOPLEFT", 8, -64 - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", blPage, "RIGHT", -30)
        row:SetScript("OnEnter", BLTooltip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self, mouse)
            if mouse == "RightButton" and self.entry then
                ShowMenu({ mode = "bl", entry = self.entry })
            end
        end)
        blRows[i] = row
    end

    blDurationDD:SetPoint("TOPLEFT", 356, -12)

    -- восстановление сохранённой сортировки
    if DTCC.db then
        local k = DTCC.db.settings.blSortKey
        if k == "name" or k == "added" or k == "expires" or k == "reason" then
            blSortKey = k
        end
        local d = DTCC.db.settings.blSortDir
        if d == "asc" or d == "desc" then
            blSortDir = d
        end
    end
    BLApplySortHeader()
end

--------------------------------------------------------------------------------
-- Вкладка «Друзья»
--------------------------------------------------------------------------------

local frPage, frScroll, frRows, frItems, frNameEdit
local frVisible = 10

local function FRRender()
    if not frScroll or not frRows then return end
    frItems = frItems or {}
    local off = ClampScroll(frScroll, #frItems, frVisible, ROW_H)
    for i = 1, ROW_POOL do
        local row = frRows[i]
        local item = (i <= frVisible) and frItems[off + i] or nil
        if item then
            row.entry = item
            row:Show()
            row.texts[1]:SetText(item.name)
            row.texts[1]:SetTextColor(0.4, 1, 0.4)
            row.texts[2]:SetText(DTCC.FormatDateFull(item.added))
            row.texts[2]:SetTextColor(0.6, 0.6, 0.6)
        else
            row.entry = nil
            row:Hide()
        end
    end
    FauxScrollFrame_Update(frScroll, #frItems, frVisible, ROW_H)
end

local function FRRefresh()
    if not window or not window:IsShown() or currentTab ~= 2 then return end
    if not frScroll or not frRows then return end
    frItems = DTCC.Friends_GetSorted()
    FRRender()
end

local function FRLayout()
    if not frPage or not frRows then return end
    frVisible = RowsForHeight(frPage:GetHeight(), 72, ROW_H, ROW_POOL)
end

local function BuildFriendsPage(parent)
    frPage = CreateFrame("Frame", "DTCCWin_FRPage", parent)
    frPage:SetAllPoints()
    pages[2] = frPage

    local lbl = MakeLabel(frPage, "Имя:", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", 8, -6)

    frNameEdit = MakeEdit(frPage, 140, nil)
    frNameEdit:SetPoint("TOPLEFT", 46, -4)

    local addBtn = MakeButton(frPage, "Добавить", 100, function()
        local name = strtrim(frNameEdit:GetText() or "")
        if name == "" then return end
        if DTCC.Friends_Add(name) then
            DTCC.Print(DTCC.COLORS.green .. DTCC.CleanName(name) .. "|r добавлен в друзья.")
            frNameEdit:SetText("")
            FRRefresh()
        end
    end)
    addBtn:SetPoint("TOPLEFT", 200, -2)

    local hint = MakeLabel(frPage, "Друзья: метка [ДРУГ] в чате, авто-ЧС не применяется")
    hint:SetTextColor(0.5, 0.5, 0.5)
    hint:SetPoint("TOPLEFT", 320, -8)

    local h1 = MakeLabel(frPage, "Игрок");     h1:SetTextColor(0.5, 0.5, 0.5); h1:SetPoint("TOPLEFT", 8, -48)
    local h2 = MakeLabel(frPage, "Добавлен");  h2:SetTextColor(0.5, 0.5, 0.5); h2:SetPoint("TOPLEFT", 165, -48)

    frScroll = CreateFrame("ScrollFrame", "DTCCWinFRScroll", frPage, "FauxScrollFrameTemplate")
    frScroll:SetPoint("TOPLEFT", 6, -64)
    frScroll:SetPoint("BOTTOMRIGHT", -28, 8)
    frScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, FRRefresh)
    end)

    frRows = {}
    for i = 1, ROW_POOL do
        local row = MakeRow(frPage, {
            { x = 8,   width = 150 },
            { x = 165, width = 220 },
        })
        row:SetPoint("TOPLEFT", frPage, "TOPLEFT", 8, -64 - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", frPage, "RIGHT", -30)
        row:SetScript("OnClick", function(self, mouse)
            if mouse == "RightButton" and self.entry then
                ShowMenu({ mode = "friend", entry = self.entry })
            end
        end)
        frRows[i] = row
    end
end

--------------------------------------------------------------------------------
-- Вкладка «Лог»
--------------------------------------------------------------------------------

local logPage, logScroll, logRows, logItems
local logTextEdit, logNameEdit, logPeriodDD, logTypeDD, logCountLabel
local logPeriodValue, logTypeValue = 0, 0
local logTotal = 0
local logVisible = 10  -- видимых строк (зависит от высоты окна)
local logBudget = 44   -- бюджет символов колонки «Сообщение» (от ширины)

local PERIODS = {
    { text = "Всё время",   value = 0     },
    { text = "Сегодня",     value = 1     },
    { text = "3 дня",       value = 3     },
    { text = "Неделя",      value = 7     },
    { text = "Месяц",       value = 30    },
}

local LOG_TYPES = {
    { text = "Все",          value = 0 },
    { text = "ЧС",           value = DTCC.FLAG_BLACKLIST },
    { text = "Скрытые",      value = DTCC.FLAG_HIDDEN },
    { text = "Цензура",      value = DTCC.FLAG_CENSORED },
    { text = "Авто-ЧС",      value = DTCC.FLAG_AUTOBL },
    { text = "Друзья",       value = DTCC.FLAG_FRIEND },
    { text = "RAW (сырые)",  value = DTCC.FLAG_RAW },
}

local function ComputeMinT(days)
    if not days or days == 0 then return 0 end
    if days == 1 then
        local t = date("*t")
        t.hour, t.min, t.sec = 0, 0, 0
        return time(t)
    end
    return time() - days * 86400
end

local function LogTags(flags)
    local tags = {}
    if bit.band(flags, DTCC.FLAG_RAW) ~= 0 then
        tags[#tags + 1] = "|cff00e5ffRAW|r"
    end
    if bit.band(flags, DTCC.FLAG_AUTOBL) ~= 0 then
        tags[#tags + 1] = "|cffff8c00АВТО|r"
    end
    if bit.band(flags, DTCC.FLAG_BLACKLIST) ~= 0 then
        tags[#tags + 1] = "|cffff4a4aЧС|r"
    end
    if bit.band(flags, DTCC.FLAG_HIDDEN) ~= 0 then
        tags[#tags + 1] = "|cff909090СКР|r"
    end
    if bit.band(flags, DTCC.FLAG_CENSORED) ~= 0 then
        tags[#tags + 1] = "|cffffd100ЦЕНЗ|r"
    end
    if bit.band(flags, DTCC.FLAG_FRIEND) ~= 0 then
        tags[#tags + 1] = "|cff3fd13fДРУГ|r"
    end
    return table.concat(tags, " ")
end

local function LogSearch()
    local res, total = DTCC.LogSearch({
        text = logTextEdit:GetText(),
        name = logNameEdit:GetText(),
        minT = ComputeMinT(logPeriodValue),
        flags = logTypeValue,
    })
    logItems = res
    logTotal = total
end

-- Перерисовать строки из кэша logItems (без поиска по всему логу — поиск
-- тяжёлый и во время растягивания окна вызывал бы фризы)
local function LogRender()
    if not logScroll or not logRows then return end
    logItems = logItems or {}
    local off = ClampScroll(logScroll, #logItems, logVisible, ROW_H)
    for i = 1, ROW_POOL do
        local row = logRows[i]
        local e = (i <= logVisible) and logItems[off + i] or nil
        if e then
            row.entry = e
            row:Show()
            row.texts[1]:SetText(DTCC.FormatTimeShort(e.t))
            row.texts[1]:SetTextColor(0.55, 0.55, 0.55)
            row.texts[2]:SetText(e.p)
            if DTCC.Blacklist_Get(e.p) then
                row.texts[2]:SetTextColor(1, 0.35, 0.35)
            elseif DTCC.Friends_Get(e.p) then
                row.texts[2]:SetTextColor(0.4, 1, 0.4)
            else
                row.texts[2]:SetTextColor(0.85, 0.9, 1)
            end
            row.texts[3]:SetText(LogTags(e.f or 0))
            FitText(row.texts[4], e.m, logBudget)
            row.texts[4]:SetTextColor(0.9, 0.9, 0.9)
        else
            row.entry = nil
            row:Hide()
        end
    end
    FauxScrollFrame_Update(logScroll, #logItems, logVisible, ROW_H)
end

local function LogRefresh()
    if not window or not window:IsShown() or currentTab ~= 3 then return end
    if not logScroll or not logRows or not logTextEdit then return end
    LogSearch()

    local inLog = (DTCC.db and DTCC.db.log) and #DTCC.db.log or 0
    if logTotal == 0 then
        if inLog == 0 then
            logCountLabel:SetText("Найдено: 0 / в логе: 0   |cff909090(если сообщения не попадают в лог — /dtcc debug on и напишите в чат)|r")
        else
            logCountLabel:SetText("Найдено: 0 / в логе: " .. inLog .. " — измените фильтры")
        end
    else
        logCountLabel:SetText("Найдено: " .. logTotal .. " / в логе: " .. inLog)
    end

    LogRender()
end

local function LogLayout()
    if not logPage or not logRows then return end
    logVisible = RowsForHeight(logPage:GetHeight(), 72, ROW_H, ROW_POOL)
    local lastW = max(80, logPage:GetWidth() - 344 - 46)
    logBudget = max(10, floor(lastW / 6))
    for i = 1, ROW_POOL do
        logRows[i].texts[4]:SetWidth(lastW)
    end
end

local function LogTooltip(row)
    local e = row.entry
    if not e then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(e.p .. "  —  " .. DTCC.FormatDateFull(e.t), 0.85, 0.9, 1)
    GameTooltip:AddLine(e.m or "", 1, 1, 1, 1)
    local flags = e.f or 0
    local desc = {}
    if bit.band(flags, DTCC.FLAG_RAW) ~= 0 then tinsert(desc, "сырая запись: формат строки не распознан") end
    if bit.band(flags, DTCC.FLAG_HIDDEN) ~= 0 then tinsert(desc, "скрыто (ЧС)") end
    if bit.band(flags, DTCC.FLAG_CENSORED) ~= 0 then tinsert(desc, "цензура") end
    if bit.band(flags, DTCC.FLAG_AUTOBL) ~= 0 then tinsert(desc, "авто-добавление в ЧС") end
    if bit.band(flags, DTCC.FLAG_FRIEND) ~= 0 then tinsert(desc, "друг") end
    if #desc > 0 then
        GameTooltip:AddLine(table.concat(desc, ", "), 0.7, 0.7, 0.7)
    end
    GameTooltip:AddLine("ПКМ — действия над игроком", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function BuildLogPage(parent)
    logPage = CreateFrame("Frame", "DTCCWin_LogPage", parent)
    logPage:SetAllPoints()
    pages[3] = logPage

    local lbl1 = MakeLabel(logPage, "Текст:", "GameFontNormalSmall")
    lbl1:SetPoint("TOPLEFT", 6, -6)
    logTextEdit = MakeEdit(logPage, 110, function() LogRefresh() end)
    logTextEdit:SetPoint("TOPLEFT", 52, -4)

    local lbl2 = MakeLabel(logPage, "Игрок:", "GameFontNormalSmall")
    lbl2:SetPoint("TOPLEFT", 172, -6)
    logNameEdit = MakeEdit(logPage, 90, function() LogRefresh() end)
    logNameEdit:SetPoint("TOPLEFT", 220, -4)

    logPeriodDD = MakeDropdown(logPage, PERIODS,
        function() return logPeriodValue end,
        function(v) logPeriodValue = v end,
        100, "DTCCWin_LogPeriod")
    logPeriodDD:SetPoint("TOPLEFT", 318, -6)

    logTypeDD = MakeDropdown(logPage, LOG_TYPES,
        function() return logTypeValue end,
        function(v) logTypeValue = v end,
        100, "DTCCWin_LogType")
    logTypeDD:SetPoint("TOPLEFT", 432, -6)

    local searchBtn = MakeButton(logPage, "Искать", 62, function() LogRefresh() end)
    searchBtn:SetPoint("TOPLEFT", 546, -4)

    logCountLabel = MakeLabel(logPage, "", "GameFontNormalSmall")
    logCountLabel:SetTextColor(0.6, 0.6, 0.6)
    logCountLabel:SetPoint("TOPLEFT", 6, -28)

    local h1 = MakeLabel(logPage, "Время");   h1:SetTextColor(0.5, 0.5, 0.5); h1:SetPoint("TOPLEFT", 4, -48)
    local h2 = MakeLabel(logPage, "Игрок");   h2:SetTextColor(0.5, 0.5, 0.5); h2:SetPoint("TOPLEFT", 90, -48)
    local h3 = MakeLabel(logPage, "Отметки"); h3:SetTextColor(0.5, 0.5, 0.5); h3:SetPoint("TOPLEFT", 216, -48)
    local h4 = MakeLabel(logPage, "Сообщение")
    h4:SetTextColor(0.5, 0.5, 0.5); h4:SetPoint("TOPLEFT", 344, -48)

    logScroll = CreateFrame("ScrollFrame", "DTCCWinLogScroll", logPage, "FauxScrollFrameTemplate")
    logScroll:SetPoint("TOPLEFT", 6, -64)
    logScroll:SetPoint("BOTTOMRIGHT", -28, 8)
    logScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, LogRefresh)
    end)

    logRows = {}
    for i = 1, ROW_POOL do
        local row = MakeRow(logPage, {
            { x = 4,   width = 80  },
            { x = 90,  width = 120 },
            { x = 216, width = 120 },
            { x = 344, width = 246 },
        })
        row:SetPoint("TOPLEFT", logPage, "TOPLEFT", 6, -64 - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", logPage, "RIGHT", -30)
        row:SetScript("OnEnter", LogTooltip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self, mouse)
            if mouse == "RightButton" and self.entry then
                ShowMenu({ mode = "log", entry = self.entry })
            end
        end)
        logRows[i] = row
    end
end

--------------------------------------------------------------------------------
-- Вкладка «Цензура»
--------------------------------------------------------------------------------

local cnPage, cnWordsEdit, cnWordsInfo, cnModeDD, cnDurDD, cnAutoBLCheck, cnEnabledCheck
local cnQuickEdit, cnWordScroll, cnWordRows
local cnWords           -- кэш списка слов (перерисовка при растягивании)
local cnVisible = 8     -- видимых строк списка слов

local CN_ROW_POOL = 24  -- пул строк списка слов (правая колонка)
local CN_ROW_H = 18

local function CNWordRender()
    if not cnWordScroll or not cnWordRows or not DTCC.db then return end
    cnWords = cnWords or {}
    local off = ClampScroll(cnWordScroll, #cnWords, cnVisible, CN_ROW_H)
    for i = 1, CN_ROW_POOL do
        local row = cnWordRows[i]
        local w = (i <= cnVisible) and cnWords[off + i] or nil
        if w then
            row.word = w
            row:Show()
            row.texts[1]:SetText(w)
        else
            row.word = nil
            row:Hide()
        end
    end
    FauxScrollFrame_Update(cnWordScroll, #cnWords, cnVisible, CN_ROW_H)
end

local function CNRefreshWords()
    if not cnWordScroll or not cnWordRows or not DTCC.db then return end
    cnWords = DTCC.Censor_GetWords()
    CNWordRender()
end

local function CNLayout()
    if not cnPage or not cnWordRows then return end
    cnVisible = RowsForHeight(cnPage:GetHeight(), 150, CN_ROW_H, CN_ROW_POOL)
    local w = max(120, cnPage:GetWidth() - 404 - 40)
    for i = 1, CN_ROW_POOL do
        cnWordRows[i].texts[1]:SetWidth(w)
    end
end

local function CNRefresh()
    if not cnEnabledCheck or not DTCC.db then return end
    local s = DTCC.db.settings
    cnEnabledCheck:SetChecked(s.censorEnabled)
    cnAutoBLCheck:SetChecked(s.autoBlacklist)
    cnModeDD.RefreshText()
    cnDurDD.RefreshText()
    cnWordsInfo:SetText("В списке слов: " .. #(s.censorWords or {}))
    CNRefreshWords()
end

local function BuildCensorPage(parent)
    cnPage = CreateFrame("Frame", "DTCCWin_CNPage", parent)
    cnPage:SetAllPoints()
    pages[4] = cnPage

    cnEnabledCheck = DTCC.UI.Check(cnPage, "Цензура включена",
        "Слова ищутся подстрокой (без учёта регистра, кириллица поддерживается).",
        function(v)
            DTCC.db.settings.censorEnabled = v
            DTCC.FireEvent("SettingsChanged")
        end)
    cnEnabledCheck:SetPoint("TOPLEFT", 10, -6)

    local modeLbl = MakeLabel(cnPage, "Режим:", "GameFontNormalSmall")
    modeLbl:SetPoint("TOPLEFT", 240, -8)
    cnModeDD = MakeDropdown(cnPage,
        {
            { text = "Маскировать (***)", value = "MASK" },
            { text = "Скрывать из чата", value = "HIDE" },
        },
        function() return DTCC.db.settings.censorMode end,
        function(v)
            DTCC.db.settings.censorMode = v
            DTCC.FireEvent("SettingsChanged")
        end,
        150, "DTCCWin_CensorMode",
        "Маскировать: запрещённые слова в сообщении заменяются на ***.\n" ..
        "Скрывать из чата: сообщение с запрещённым словом не показывается вообще " ..
        "(в логе остаётся).")
    cnModeDD:SetPoint("TOPLEFT", 288, -10)

    cnAutoBLCheck = DTCC.UI.Check(cnPage, "Авто-ЧС за запрещённое слово",
        "Написал запрещённое слово — автоматически в ЧС на выбранный срок. Сообщение сохранится как причина.",
        function(v)
            DTCC.db.settings.autoBlacklist = v
            DTCC.FireEvent("SettingsChanged")
        end)
    cnAutoBLCheck:SetPoint("TOPLEFT", 10, -34)

    local durLbl = MakeLabel(cnPage, "Срок авто-ЧС:", "GameFontNormalSmall")
    durLbl:SetPoint("TOPLEFT", 268, -36)
    cnDurDD = MakeDropdown(cnPage, DTCC.DURATIONS,
        function() return DTCC.db.settings.autoBLDuration end,
        function(v)
            DTCC.db.settings.autoBLDuration = v
            DTCC.FireEvent("SettingsChanged")
        end,
        130, "DTCCWin_CensorDur")
    cnDurDD:SetPoint("TOPLEFT", 342, -38)

    ------------------------------------------------------------------ левая колонка: редактор
    local wordsLabel = MakeLabel(cnPage, "Слова (по одному на строку или через запятую):", "GameFontNormalSmall")
    wordsLabel:SetPoint("TOPLEFT", 10, -66)

    -- Рамка-контейнер фиксированного размера. У многострочного EditBox в 3.3.5
    -- видимая высота пляшет от содержимого (пустой — одна строка, кликом по
    -- «пустому месту» не попасть), поэтому фон и клик-в-фокус держит контейнер.
    local wordsBox = CreateFrame("Frame", nil, cnPage)
    wordsBox:SetWidth(380)
    wordsBox:SetHeight(150)
    wordsBox:SetPoint("TOPLEFT", 10, -82)
    wordsBox:EnableMouse(true)
    wordsBox:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    wordsBox:SetBackdropColor(0, 0, 0, 0.6)
    wordsBox:SetScript("OnMouseDown", function()
        if cnWordsEdit then cnWordsEdit:SetFocus() end
    end)

    local wordsScroll = CreateFrame("ScrollFrame", "DTCCWin_WordsScroll", wordsBox, "UIPanelScrollFrameTemplate")
    wordsScroll:SetPoint("TOPLEFT", 6, -6)
    wordsScroll:SetPoint("BOTTOMRIGHT", -24, 6)

    cnWordsEdit = CreateFrame("EditBox", "DTCCWin_WordsEdit", wordsScroll)
    cnWordsEdit:SetMultiLine(true)
    cnWordsEdit:SetWidth(344)
    cnWordsEdit:SetHeight(138)
    cnWordsEdit:SetAutoFocus(false)
    cnWordsEdit:SetFontObject("GameFontHighlightSmall")
    cnWordsEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    wordsScroll:SetScrollChild(cnWordsEdit)
    -- прокрутка редактора за курсором (иначе длинные списки печатаются «вслепую»)
    cnWordsEdit:SetScript("OnCursorChanged", function(self, x, y, w, h)
        local scrollbar = _G["DTCCWin_WordsScrollScrollBar"]
        if not scrollbar then return end
        local offset = scrollbar:GetValue()
        if y < offset + 10 then
            scrollbar:SetValue(y - 10)
        elseif y + h + 10 > offset + wordsScroll:GetHeight() then
            scrollbar:SetValue(y + h + 10 - wordsScroll:GetHeight())
        end
    end)

    local applyBtn = MakeButton(cnPage, "Применить", 110, function()
        local lines = { strsplit("\n", cnWordsEdit:GetText()) }
        local n = DTCC.Censor_SetWords(lines)
        cnWordsInfo:SetText("В списке слов: " .. n)
        DTCC.Print("список слов цензуры сохранён (" .. n .. " шт.).")
        CNRefresh()
    end, "DTCCWin_WordsApply")
    applyBtn:SetPoint("TOPLEFT", 10, -244)

    local reloadBtn = MakeButton(cnPage, "Обновить поле", 120, function()
        cnWordsEdit:SetText(DTCC.Censor_GetWordsAsString())
        CNRefresh()
    end)
    reloadBtn:SetPoint("LEFT", applyBtn, "RIGHT", 8, 0)

    cnWordsInfo = MakeLabel(cnPage, "", "GameFontNormalSmall")
    cnWordsInfo:SetTextColor(0.6, 0.6, 0.6)
    cnWordsInfo:SetPoint("LEFT", reloadBtn, "RIGHT", 12, 0)

    local hint = MakeLabel(cnPage, "Совпадения ищутся подстрокой, без учёта регистра (кириллица и Ё/ё учитываются).", "GameFontNormalSmall")
    hint:SetTextColor(0.5, 0.5, 0.5)
    hint:SetPoint("TOPLEFT", 10, -276)
    hint:SetWidth(380)
    hint:SetJustifyH("LEFT")

    ------------------------------------------------------------------ правая колонка: быстрое управление
    local function QuickAddWord()
        local raw = strtrim(cnQuickEdit:GetText() or "")
        if raw == "" then return end
        if DTCC.CensorWords_Add(raw) then
            cnQuickEdit:SetText("")
            DTCC.Print("слово добавлено в список цензуры.")
        else
            DTCC.Print(DTCC.COLORS.yellow .. "не добавлено: пусто или уже есть в списке.")
        end
        CNRefresh()
    end

    local qLabel = MakeLabel(cnPage, "Быстрое добавление:", "GameFontNormalSmall")
    qLabel:SetPoint("TOPLEFT", 404, -66)

    cnQuickEdit = MakeEdit(cnPage, 140, function() QuickAddWord() end, "DTCCWin_WordQuickEdit")
    cnQuickEdit:SetPoint("TOPLEFT", 404, -80)

    local qAddBtn = MakeButton(cnPage, "Добавить", 80, QuickAddWord, "DTCCWin_WordQuickAdd")
    qAddBtn:SetPoint("TOPLEFT", 548, -82)

    local listLabel = MakeLabel(cnPage, "Слова в списке (клик — удалить):", "GameFontNormalSmall")
    listLabel:SetPoint("TOPLEFT", 404, -126)

    -- список сдвинут вниз (не залезает под поле быстрого добавления и скроллбар
    -- с его стрелками), строки укорочены, чтобы не уходили под скроллбар
    cnWordScroll = CreateFrame("ScrollFrame", "DTCCWin_CWordsScroll", cnPage, "FauxScrollFrameTemplate")
    cnWordScroll:SetPoint("TOPLEFT", 398, -144)
    cnWordScroll:SetPoint("BOTTOMRIGHT", -6, 6)
    cnWordScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, 18, CNRefreshWords)
    end)

    cnWordRows = {}
    for i = 1, CN_ROW_POOL do
        local row = MakeRow(cnPage, { { x = 6, width = 182 } })
        row:SetHeight(18)
        row:SetPoint("TOPLEFT", cnPage, "TOPLEFT", 404, -144 - (i - 1) * 18)
        row:SetPoint("RIGHT", cnPage, "RIGHT", -34)
        row:SetScript("OnClick", function(self, mouse)
            if self.word then
                DTCC.UI.PopupMenu({
                    {
                        text = "Удалить слово «" .. self.word .. "»",
                        func = function()
                            if DTCC.CensorWords_Remove(self.word) then
                                DTCC.Print("слово удалено из списка цензуры.")
                            end
                            CNRefresh()
                        end,
                    },
                }, self)
            end
        end)
        cnWordRows[i] = row
    end
end

--------------------------------------------------------------------------------
-- Сборка окна
--------------------------------------------------------------------------------

local function SelectTab(id)
    currentTab = id
    for i = 1, NUM_TABS do
        local tab = tabs[i]
        local page = pages[i]
        if tab then
            if i == id then
                tab:SetBackdropColor(0.05, 0.18, 0.24, 1)
                tab.text:SetTextColor(0, 0.9, 1)
            else
                tab:SetBackdropColor(0, 0, 0, 0.55)
                tab.text:SetTextColor(0.7, 0.75, 0.8)
            end
        end
        if page then
            if i == id then page:Show() else page:Hide() end
        end
    end
    if id == 1 then BLRefresh() end
    if id == 2 then FRRefresh() end
    if id == 3 then LogRefresh() end
    if id == 4 then CNRefresh() end
end
DTCC.SelectTab = SelectTab

local function UpdateStatus()
    if not window then return end
    local bl = DTCC.Blacklist_Count and DTCC.Blacklist_Count() or 0
    local fr = DTCC.Friends_Count and DTCC.Friends_Count() or 0
    local lg = (DTCC.db and DTCC.db.log) and #DTCC.db.log or 0
    window.status:SetText(string.format("ЧС: %d   •   Друзей: %d   •   Записей в логе: %d", bl, fr, lg))
end

-- Пересчёт всех вкладок под текущий размер окна. Скрытые страницы тоже:
-- раскладка по якорям работает и у скрытых фреймов, а при переключении
-- вкладки рефреш уже попадёт на готовую раскладку.
local function LayoutAllPages()
    BLLayout()
    FRLayout()
    LogLayout()
    CNLayout()
end

local function BuildWindow()
    window = CreateFrame("Frame", "DTCCWindow", UIParent)
    DTCC.mainWindow = window
    window:SetWidth(WIN_MIN_W)
    window:SetHeight(WIN_MIN_H)
    window:SetMovable(true)
    window:SetResizable(true)
    window:EnableMouse(true)
    window:SetClampedToScreen(true)
    window:SetFrameStrata("HIGH")
    window:SetMinResize(WIN_MIN_W, WIN_MIN_H)
    window:SetMaxResize(UIParent:GetWidth(), UIParent:GetHeight())
    tinsert(UISpecialFrames, "DTCCWindow")
    window:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    window:SetPoint("CENTER")

    local function SaveWindowGeometry()
        if not DTCC.db then return end
        DTCC.db.settings.winX = window:GetLeft()
        DTCC.db.settings.winY = window:GetTop()
        DTCC.db.settings.winW = window:GetWidth()
        DTCC.db.settings.winH = window:GetHeight()
    end

    window:SetScript("OnMouseDown", function(self) self:StartMoving() end)
    window:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        SaveWindowGeometry()
    end)
    -- окно спрятали (ESC) в момент перетаскивания/растягивания — остановить
    -- и вернуть прижатие к экрану (грип выключает его на время растягивания)
    window:SetScript("OnHide", function(self)
        self:StopMovingOrSizing()
        self:SetClampedToScreen(true)
    end)

    local title = window:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -16)
    title:SetText("|cff00e5ffDarkTech|r Chat Control")

    local version = window:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    version:SetPoint("LEFT", title, "RIGHT", 10, 0)
    version:SetTextColor(0.5, 0.5, 0.5)
    version:SetText("v" .. DTCC.Version)

    local closeBtn = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -8, -8)

    -- уголок растягивания: тянуть за нижний правый угол окна
    local grip = CreateFrame("Button", "DTCCWindowResizeGrip", window)
    grip:SetWidth(16)
    grip:SetHeight(16)
    grip:SetPoint("BOTTOMRIGHT", -5, 5)
    -- фон под грипом: даже если текстура уголка не подгрузится, он остаётся
    -- видимым и кликабельным
    grip:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        tile = true, tileSize = 16,
    })
    grip:SetBackdropColor(0, 0, 0, 0.6)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0, 0.45, 0.55, 0.8)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Изменить размер окна", 0.95, 0.95, 0.95)
        GameTooltip:AddLine("Потяните за угол и отпустите. Размер и положение окна сохраняются.", nil, nil, nil, 1)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0, 0, 0, 0.6)
        GameTooltip:Hide()
    end)
    grip:SetScript("OnMouseDown", function()
        -- прижатие к экрану выключаем на время растягивания: вместе со
        -- StartSizing клиент «дребезжит» окно у краёв экрана
        window:SetClampedToScreen(false)
        window:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        window:StopMovingOrSizing()
        window:SetClampedToScreen(true)
        SaveWindowGeometry()
        -- полный пересчёт активной вкладки: во время растягивания строки
        -- перерисовывались из кэша (без поиска/сортировки)
        SelectTab(currentTab)
    end)

    -- контейнер страниц
    local content = CreateFrame("Frame", nil, window)
    content:SetPoint("TOPLEFT", 14, -66)
    content:SetPoint("BOTTOMRIGHT", -14, 26)

    -- каждая вкладка строится в своём pcall: одна ошибка не должна
    -- ломать всё окно (и ошибку видно с номером вкладки)
    local pageBuilders = {
        [1] = BuildBLPage,
        [2] = BuildFriendsPage,
        [3] = BuildLogPage,
        [4] = BuildCensorPage,
    }
    local pageNames = { "Чёрный список", "Друзья", "Лог", "Цензура" }
    for i = 1, NUM_TABS do
        local ok, err = pcall(pageBuilders[i], content)
        if not ok then
            DTCC.Print(DTCC.COLORS.red .. "Не удалось собрать вкладку «" ..
                pageNames[i] .. "»: " .. tostring(err))
        end
    end

    -- вкладки
    local tabDefs = { "Чёрный список", "Друзья", "Лог чата", "Цензура" }
    for i = 1, NUM_TABS do
        local tab = CreateFrame("Button", nil, window)
        tab:SetWidth(150)
        tab:SetHeight(26)
        tab:SetPoint("TOPLEFT", window, "TOPLEFT", 14 + (i - 1) * 156, -40)
        tab:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        tab:SetBackdropColor(0, 0, 0, 0.55)
        tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tab.text:SetPoint("CENTER")
        tab.text:SetText(tabDefs[i])
        tab:SetScript("OnClick", function() SelectTab(i) end)
        tab:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        tabs[i] = tab
    end

    window.status = window:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    -- отступ справа больше обычного: не залезать под уголок растягивания
    window.status:SetPoint("BOTTOMRIGHT", -24, 6)
    window.status:SetTextColor(0.55, 0.55, 0.55)

    -- размер и позиция из сохранённых настроек
    if DTCC.db then
        local s = DTCC.db.settings
        local w = tonumber(s.winW) or WIN_MIN_W
        local h = tonumber(s.winH) or WIN_MIN_H
        -- на меньшем экране (другое разрешение/масштаб) окно не должно
        -- оказаться больше экрана
        w = min(max(w, WIN_MIN_W), UIParent:GetWidth())
        h = min(max(h, WIN_MIN_H), UIParent:GetHeight())
        window:SetWidth(w)
        window:SetHeight(h)
        if s.winX and s.winY then
            window:ClearAllPoints()
            window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", s.winX, s.winY)
        end
    end

    -- реакция на изменение размера: раскладка вкладок и перерисовка строк
    -- АКТИВНОЙ вкладки из кэша (поиск по всему логу на каждый пиксель
    -- растягивания давал бы фризы)
    window:SetScript("OnSizeChanged", function(self, w, h)
        LayoutAllPages()
        if currentTab == 1 then
            BLRender()
        elseif currentTab == 2 then
            FRRender()
        elseif currentTab == 3 then
            LogRender()
        elseif currentTab == 4 then
            CNWordRender()
        end
    end)

    -- первичная раскладка под восстановленный размер
    LayoutAllPages()

    SelectTab(1)
    window:Hide()
end

--------------------------------------------------------------------------------
-- Публичные функции
--------------------------------------------------------------------------------

function DTCC.OpenWindow(tab)
    if not window then return end
    window:Show()
    if tab then SelectTab(tab) end
    BLRefresh()
    FRRefresh()
    LogRefresh()
    UpdateStatus()
end

function DTCC.ToggleWindow()
    if not window then return end
    if window:IsShown() then
        window:Hide()
    else
        DTCC.OpenWindow(currentTab)
    end
end

--------------------------------------------------------------------------------
-- Обновление данных
--------------------------------------------------------------------------------

DTCC.RegisterCallback("OnInitialized", BuildWindow)

local lastLogRefresh = 0
DTCC.RegisterCallback("LogChanged", function()
    -- обновляем вкладку лога не чаще раза в секунду и только когда она открыта
    if window and window:IsShown() and currentTab == 3 then
        local now = GetTime()
        if now - lastLogRefresh >= 1 then
            lastLogRefresh = now
            LogRefresh()
        end
    end
end)

DTCC.RegisterCallback("ListsChanged", function()
    if window and window:IsShown() then
        BLRefresh()
        FRRefresh()
        UpdateStatus()
    end
end)

DTCC.RegisterCallback("SettingsChanged", function()
    if window and window:IsShown() and currentTab == 4 then
        CNRefresh()
    end
end)
