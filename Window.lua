--[[
    DarkTech Chat Control — главное окно.

    Вкладки:
      1. Чёрный список — добавление/удаление, сроки, причина (ПКМ — меню);
      2. Друзья;
      3. Лог — поиск по тексту и игроку, фильтры-галочки в две строки:
         источники (мировой чат / каналы Solo и Solo Progress / RAW, по
         умолчанию — мировой чат и каналы) и типы; имя автора — цвет фракции,
         сообщение на всю ширину с переносом строк и кликабельными ссылками
         предметов (SMF), действия над автором сообщения через ПКМ;
      4. Цензура — редактор списка слов на всю вкладку (сохранённые слова
         грузятся в поле при открытии, «Построчно»/«Через запятую»
         переформатируют, «Сохранить» записывает), режим, авто-ЧС и срок.

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
--
-- Фильтры — галочки в ОДИН ряд, перенос на следующую строку только когда
-- не помещаются (источники идут первыми: «Мировой чат», галочки каналов из
-- настройки «Каналы» (Solo, Solo Progress…, строятся динамически), «RAW»;
-- затем типы ЧС/скрытые/цензура/авто-ЧС/друзья — не отмечено ничего =
-- любой тип, несколько отмеченных складываются как «ИЛИ»). Шрифт записей —
-- как в игровом чате (крупнее мелкого UI-шрифта). Имя автора окрашено
-- цветом фракции, как в общем чате (цвет приходит из .chat и запоминается
-- по игроку; сообщения каналов получают запомненный цвет, перед текстом —
-- тег [Канал]). Сообщение занимает всю ширину окна и переносится на
-- несколько строк (без «…») — высота строки переменная, поэтому скролл
-- свой (Slider), не FauxScrollFrame. Текст сообщения лежит в
-- ScrollingMessageFrame: ссылки предметов работают как в чате — клик
-- открывает подсказку (тултип при НАВЕДЕНИИ клиент 3.3.5 не поддерживает,
-- обработчик подключён на случай более новых клиентов).
--------------------------------------------------------------------------------

local logPage, logRows, logItems
local logTextEdit, logNameEdit, logPeriodDD, logCountLabel
local logSlider
local logCheckboxes = {}   -- players / raw / bl / hidden / censor / autobl / friend
local logFlagChecks = {}   -- { { cb = .., flag = .. } } — маска «только эти типы»
local logChannelChecks = {} -- { { cb = .., key = .., label = .. } } — галочки каналов
                           -- (динамика по настройке «Каналы»; key = имя в нижнем
                           -- регистре, nil = галочка скрыта)
local logSourceChecks = {} -- { { cb = .., key = .. } } — локальные чаты
                           -- (Общий/Группа/Гильдия/Шёпот, DTCC.LOCAL_SOURCES)
local logPeriodValue = 0
local logTotal = 0
local logOff = 0           -- индекс первой видимой записи (0-based, сверху)
local logHeightCache = {}  -- [запись] = { w = ширина колонки, h = высота строки }
local logMeasure           -- скрытый fontstring: замер ширины слов/строк
local logLineH = 12        -- высота одной строки шрифта сообщения
local logSpaceW = 4        -- ширина пробела
local logWordWidths = {}   -- кэш ширин слов (от ширины колонки не зависит)
local logRendering = false -- защита от повторного входа через OnValueChanged

local LOG_TIME_W  = 76     -- колонка «Время»
local LOG_NAME_W  = 90     -- колонка «Игрок»
local LOG_MSG_X   = 178    -- X колонки «Сообщение» (в координатах строки)
local LOG_TOP_BASE = 98    -- верх списка при ОДНОЙ строке галочек: поиск
                           -- (−4…−26) + галочки 26px (−30…−56) + счётчик
                           -- (−60…−75) + заголовки (−78…−93); каждая
                           -- дополнительная строка галочек (перенос, когда
                           -- не влезают в ширину) опускает список на 28px
local LOG_BOTTOM  = 8

local logCheckRows  = 1            -- фактическое число строк галочек
local logTop        = LOG_TOP_BASE -- верх списка (зависит от строк галочек)
local logColHeaders = {}           -- { { fs = .., x = .. } } — заголовки колонок,
                                   -- перецепляются при переносе галочек
local logFontPath, logFontHeight = "Fonts\\FRIZQT__.TTF", 12
                                   -- шрифт записей: берём из игрового чата
                                   -- (BuildLogPage → LogChatFont)

local PERIODS = {
    { text = "Всё время",   value = 0     },
    { text = "Сегодня",     value = 1     },
    { text = "3 дня",       value = 3     },
    { text = "Неделя",      value = 7     },
    { text = "Месяц",       value = 30    },
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

-- Ширина слова тем же шрифтом, что сообщение (замер один раз, кэш)
local logWordN = 0
local function LogWordWidth(word)
    local w = logWordWidths[word]
    if w == nil then
        if logMeasure then
            logMeasure:SetText(word)
            w = logMeasure:GetStringWidth()
        else
            w = strlen(word) * 6
        end
        logWordN = logWordN + 1
        if logWordN > 8192 then
            wipe(logWordWidths) -- кэш не должен расти бесконечно на больших логах
            logWordN = 1
        end
        logWordWidths[word] = w
    end
    return w
end

-- Число строк при переносе текста по ширине lineW: слова переносятся по
-- пробелам, слишком длинное слово (ссылка) ломается по символам — как nonspacewrap
-- в игровом чате
local function LogCountLines(text, lineW)
    local n, x = 1, 0
    for word in string.gmatch(text, "%S+") do
        local w = LogWordWidth(word)
        if w > lineW then
            if x > 0 then n = n + 1 end
            local full = floor(w / lineW)
            n = n + full
            x = w - full * lineW
        elseif x == 0 then
            x = w
        elseif x + logSpaceW + w <= lineW then
            x = x + logSpaceW + w
        else
            n = n + 1
            x = w
        end
    end
    return n
end

-- Цветной тег источника перед сообщением: [Solo] (канал, бирюзовый) или
-- [Гильдия]/[Шёпот]/… (локальные чаты, цвет как в игровом чате)
local function LogEntryTag(e)
    if e.ch and e.ch ~= "" then
        return "|cff20b2aa[" .. e.ch .. "]|r "
    end
    if e.src and e.src ~= "world" then
        local def = DTCC.sourceBySrc[e.src]
        if def then return "|cff" .. def.color .. "[" .. def.label .. "]|r " end
    end
    return ""
end

-- Тот же тег без кодов цвета — для замера высоты строки
local function LogBareTag(e)
    if e.ch and e.ch ~= "" then
        return "[" .. e.ch .. "] "
    end
    if e.src and e.src ~= "world" then
        local def = DTCC.sourceBySrc[e.src]
        if def then return "[" .. def.label .. "] " end
    end
    return ""
end

-- «Голый» текст записи для замера высоты: тег канала + сообщение без кодов
local function LogBareText(e)
    return LogBareTag(e) .. DTCC.StripAll(e.m or "")
end

-- Высота строки лога: перенос сообщения в несколько строк + запас.
-- Возвращает (высота строки, высота блока текста для SMF — тем же шрифтом,
-- без запаса, чтобы текст не «уезжал» вниз внутри более высокой строки).
-- Кэшируется по записи; ширина колонки хранится в кэше (ресайз = перемер).
local function LogRowHeight(e, msgW)
    local c = logHeightCache[e]
    if c and c.w == msgW then return c.h, c.m end
    local lines = LogCountLines(LogBareText(e), msgW - 4)
    local textH = lines * logLineH
    local h = max(ROW_H, textH + 6)
    local m = textH + 4
    logHeightCache[e] = { w = msgW, h = h, m = m }
    return h, m
end

local LogRenderInner

local function LogRender()
    if logRendering then return end
    logRendering = true
    -- pcall: ошибка в середине рендера не должна навсегда оставить флаг
    local ok, err = pcall(LogRenderInner)
    logRendering = false
    if not ok then error(err, 0) end
end

LogRenderInner = function()
    if not logPage or not logRows then return end
    logItems = logItems or {}
    local n = #logItems
    local pageH = max(ROW_H, logPage:GetHeight() - logTop - LOG_BOTTOM)
    local msgW = max(60, logPage:GetWidth() - LOG_MSG_X - 36)

    -- максимальный офсет: последняя страница целиком видна (снизу вверх)
    local y, idx, shown = 0, n, 0
    while idx >= 1 do
        local h = LogRowHeight(logItems[idx], msgW)
        if y + h > pageH and shown > 0 then break end
        y = y + h
        shown = shown + 1
        idx = idx - 1
    end
    local maxOff = idx
    if logOff > maxOff then logOff = maxOff end
    if logOff < 0 then logOff = 0 end
    local off = logOff

    y = 0
    for i = 1, ROW_POOL do
        local row = logRows[i]
        local e = logItems[off + i]
        local h, msgH
        if e then h, msgH = LogRowHeight(e, msgW) end
        if e and h and (y + h <= pageH or i == 1) then
            row.entry = e
            y = y + h
            row:SetWidth(max(60, logPage:GetWidth() - 12))
            row:SetHeight(h)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", logPage, "TOPLEFT", 6, -(logTop + (y - h)))
            row.head.entry = e
            row.head.timeF:SetText(DTCC.FormatTimeShort(e.t))
            row.head.timeF:SetTextColor(0.55, 0.55, 0.55)
            FitText(row.head.nameF, e.p, floor(LOG_NAME_W / 6))
            -- цвет имени: ЧС/друг — свои (пометки пользователя важнее),
            -- иначе цвет фракции из записи/памяти (как в общем чате),
            -- иначе нейтральный
            if DTCC.Blacklist_Get(e.p) then
                row.head.nameF:SetTextColor(1, 0.35, 0.35)
            elseif DTCC.Friends_Get(e.p) then
                row.head.nameF:SetTextColor(0.4, 1, 0.4)
            else
                local r, g, b = DTCC.HexToRGB(e.c or DTCC.GetPlayerColor(e.p))
                if r then
                    row.head.nameF:SetTextColor(r, g, b)
                else
                    row.head.nameF:SetTextColor(0.85, 0.9, 1)
                end
            end
            -- сообщение в SMF: при смене записи/ширины перезаливаем
            -- (SetMaxLines(1) сам выталкивает старую строку, Clear в 3.3.5 не гарантирован)
            if row.smfEntry ~= e or row.smfW ~= msgW then
                row.smf:SetWidth(msgW)
                row.smfEntry, row.smfW = e, msgW
                pcall(row.smf.Clear, row.smf)
                row.smf:AddMessage(LogEntryTag(e) .. tostring(e.m or ""), 0.92, 0.92, 0.92)
            end
            row.smf:SetHeight(msgH)
            row:Show()
        else
            row.entry = nil
            row.head.entry = nil
            row:Hide()
        end
    end

    if logSlider then
        if maxOff > 0 then logSlider:Show() else logSlider:Hide() end
        logSlider:SetMinMaxValues(0, maxOff)
        local cur = floor((tonumber(logSlider:GetValue()) or 0) + 0.5)
        if cur ~= off then logSlider:SetValue(off) end
    end
end

local function SetLogOffset(v)
    if v < 0 then v = 0 end
    if v == logOff then return end
    logOff = v
    LogRender() -- верхнюю границу подрежет сам рендер
end

-- Текущее состояние фильтров из галочек: источники (мировой чат / каналы /
-- локальные чаты / RAW) и маска типов
local function LogFilterState()
    local players = logCheckboxes.players and logCheckboxes.players:GetChecked() and true or false
    local raw = logCheckboxes.raw and logCheckboxes.raw:GetChecked() and true or false
    local flags = 0
    for _, fc in ipairs(logFlagChecks) do
        if fc.cb:GetChecked() then flags = flags + fc.flag end
    end
    local channels = {}
    for _, cc in ipairs(logChannelChecks) do
        if cc.cb and cc.key then
            channels[cc.key] = cc.cb:GetChecked() and true or false
        end
    end
    local sources = { world = players }
    for _, sc in ipairs(logSourceChecks) do
        if sc.cb and sc.key then
            sources[sc.key] = sc.cb:GetChecked() and true or false
        end
    end
    return players, raw, flags, channels, sources
end

-- Параметры запроса к логу по текущему состоянию вкладки: галочки-источники,
-- типы, поиск и период. Используются и для показа, и для «Очистить лог» —
-- кнопка удаляет ровно то, что сейчас видно
local function BuildLogOpts()
    local _, raw, flags, channels, sources = LogFilterState()
    return {
        text = logTextEdit:GetText(),
        name = logNameEdit:GetText(),
        minT = ComputeMinT(logPeriodValue),
        flags = flags,
        channels = channels,
        sources = sources,
        includeRaw = raw,
    }
end

local function LogSearch()
    local res, total = DTCC.LogSearch(BuildLogOpts())
    logItems = res
    logTotal = total
    local anySource = false
    local _, raw, _, channels, sources = LogFilterState()
    if raw then anySource = true end
    for _, on in pairs(channels) do
        if on then anySource = true break end
    end
    for _, on in pairs(sources) do
        if on then anySource = true break end
    end
    return anySource
end

local function LogRefresh()
    if not window or not window:IsShown() or currentTab ~= 3 then return end
    if not logRows or not logTextEdit then return end
    local anySource = LogSearch()

    local inLog = (DTCC.db and DTCC.db.log) and #DTCC.db.log or 0
    if not anySource then
        logCountLabel:SetText("Все источники выключены — отметьте хотя бы один")
    elseif logTotal == 0 then
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

-- Смена фильтра/поиска/периода: показываем самые свежие записи (сверху),
-- прокрутка не остаётся где-то в глубине истории
local function LogFilterChanged()
    logOff = 0
    LogRefresh()
end

-- «Очистить лог» по текущим фильтрам: запрос запоминается до подтверждения,
-- диалог показывает, сколько записей подпадает
function DTCC.RequestClearLog()
    local opts = BuildLogOpts()
    local _, total = DTCC.LogSearch(opts)
    DTCC._clearQuery = DTCC.PrepareLogQuery(opts)
    local d = StaticPopupDialogs and StaticPopupDialogs["DTCC_CLEAR_LOG"]
    if d then
        d.text = "Удалить из лога записи по ТЕКУЩИМ фильтрам?\nПодходит: " .. total ..
            " из " .. ((DTCC.db and #DTCC.db.log) or 0) .. " записей лога."
    end
    StaticPopup_Show("DTCC_CLEAR_LOG")
end

local function LogTooltip(self)
    local e = self.entry
    if not e then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(e.p .. "  —  " .. DTCC.FormatDateFull(e.t), 0.85, 0.9, 1)
    if e.ch and e.ch ~= "" then
        GameTooltip:AddLine("Канал: " .. e.ch, 0.6, 0.8, 0.9)
    elseif e.src and e.src ~= "world" and DTCC.sourceBySrc[e.src] then
        GameTooltip:AddLine("Источник: " .. DTCC.sourceBySrc[e.src].label, 0.6, 0.8, 0.9)
    end
    local flags = e.f or 0
    local desc = {}
    if bit.band(flags, DTCC.FLAG_RAW) ~= 0 then tinsert(desc, "сырая системная строка (формат не распознан)") end
    if bit.band(flags, DTCC.FLAG_HIDDEN) ~= 0 then tinsert(desc, "скрыто (ЧС)") end
    if bit.band(flags, DTCC.FLAG_CENSORED) ~= 0 then tinsert(desc, "цензура") end
    if bit.band(flags, DTCC.FLAG_AUTOBL) ~= 0 then tinsert(desc, "авто-добавление в ЧС") end
    if bit.band(flags, DTCC.FLAG_FRIEND) ~= 0 then tinsert(desc, "друг") end
    if #desc > 0 then
        GameTooltip:AddLine(table.concat(desc, ", "), 0.7, 0.7, 0.7)
    end
    GameTooltip:AddLine("ПКМ — действия над игроком; клик по предмету — подсказка", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

-- Раскладка галочек фильтров: все в ОДИН ряд; на следующую строку галочка
-- уходит, только если не помещается по ширине вкладки (источники идут
-- первыми, поэтому перенос обычно режет между источниками и типами).
-- Под фактическое число строк сдвигает счётчик, заголовки колонок, слайдер
-- и верх списка (logTop). ВАЖНО: рамка чекбокса узкая (26px), подпись живёт
-- ЗА её пределами — позиции считаем вручную по фактической ширине подписей.
local function LogLayoutChecks()
    if not logPage then return end
    local ordered = {}
    local function add(cb)
        if cb then ordered[#ordered + 1] = cb end
    end
    add(logCheckboxes.players)
    for _, cc in ipairs(logChannelChecks) do
        if cc.key then add(cc.cb) end
    end
    for _, sc in ipairs(logSourceChecks) do
        add(sc.cb)
    end
    add(logCheckboxes.raw)
    for _, ckey in ipairs({ "friend", "bl", "hidden", "censor", "autobl" }) do
        add(logCheckboxes[ckey])
    end

    local pageW = logPage:GetWidth() - 8
    local x, y, row = 4, -30, 1
    for _, cb in ipairs(ordered) do
        local labelW = cb.label:GetStringWidth() or 0
        if x > 4 and (x + 30 + labelW) > pageW then
            x = 4
            y = y - 28
            row = row + 1
        end
        cb:SetPoint("TOPLEFT", logPage, "TOPLEFT", x, y)
        x = x + 30 + labelW + 14
    end
    logCheckRows = row
    logTop = LOG_TOP_BASE + (row - 1) * 28

    local counterY = -(30 + row * 28 + 2)
    if logCountLabel then
        logCountLabel:SetPoint("TOPLEFT", 6, counterY)
    end
    local headerY = counterY - 18
    for _, hh in ipairs(logColHeaders) do
        hh.fs:SetPoint("TOPLEFT", hh.x, headerY)
    end
    if logSlider then
        logSlider:ClearAllPoints()
        logSlider:SetPoint("TOPRIGHT", logPage, "TOPRIGHT", -10, -logTop)
        logSlider:SetPoint("BOTTOMRIGHT", logPage, "BOTTOMRIGHT", -10, LOG_BOTTOM)
    end
end

-- (Пере)строить галочки каналов по настройке «Каналы» (worldChannel):
-- подписи и ключи обновляются на месте, лишние галочки скрываются.
-- Вызывается при сборке вкладки и на SettingsChanged (список каналов
-- мог измениться в настройках).
local function LogRebuildChannelChecks()
    if not logPage then return end
    local names = (DTCC.db and DTCC.SplitChannelList(DTCC.db.settings.worldChannel)) or {}
    for i, name in ipairs(names) do
        local key = DTCC.utf8lower(name)
        local cc = logChannelChecks[i]
        if not cc then
            -- cc объявлен отдельной строкой выше — замыкание видит local
            cc = {}
            cc.cb = DTCC.UI.Check(logPage, name,
                "Показывать сообщения этого канала в логе.\n(источник — настройка «Каналы»)",
                function(v)
                    if DTCC.db and cc.key then
                        DTCC.db.settings.logChannelShow = DTCC.db.settings.logChannelShow or {}
                        DTCC.db.settings.logChannelShow[cc.key] = v
                    end
                    DTCC.FireEvent("SettingsChanged")
                    LogFilterChanged()
                end)
            logChannelChecks[i] = cc
        end
        if cc.label ~= name then
            cc.label = name
            cc.cb.label:SetText(name)
            -- хит-зона — ровно по новой подписи
            cc.cb:SetHitRectInsets(0, -(cc.cb.label:GetStringWidth() + 10), 0, 0)
        end
        cc.key = key
        cc.cb:Show()
        local show = true
        if DTCC.db and DTCC.db.settings.logChannelShow then
            show = DTCC.db.settings.logChannelShow[key] ~= false
        end
        cc.cb:SetChecked(show)
    end
    for i = #names + 1, #logChannelChecks do
        logChannelChecks[i].key = nil
        logChannelChecks[i].cb:Hide()
    end
    LogLayoutChecks()
end

-- Шрифт записей лога — как в игровом чате (крупнее мелкого UI-шрифта,
-- длинные сообщения читаются заметно легче). Берём прямо из
-- DEFAULT_CHAT_FRAME — учитывает и клиент, и настройки шрифта игрока;
-- при недоступности (нет фрейма/GetFont) — мелкий шрифт интерфейса.
local function LogChatFont()
    local ok, path, height = pcall(DEFAULT_CHAT_FRAME.GetFont, DEFAULT_CHAT_FRAME)
    if ok and type(path) == "string" and tonumber(height) then
        local h = tonumber(height)
        if h < 12 then h = 12 end
        return path, floor(h)
    end
    return GameFontNormalSmall:GetFont()
end

local function BuildLogPage(parent)
    logPage = CreateFrame("Frame", "DTCCWin_LogPage", parent)
    logPage:SetAllPoints()
    pages[3] = logPage

    -- строка 1: поиск по тексту/игроку, период, поиск; справа — очистка лога
    local lbl1 = MakeLabel(logPage, "Текст:", "GameFontNormalSmall")
    lbl1:SetPoint("TOPLEFT", 6, -6)
    logTextEdit = MakeEdit(logPage, 110, function() LogFilterChanged() end)
    logTextEdit:SetPoint("TOPLEFT", 52, -4)

    local lbl2 = MakeLabel(logPage, "Игрок:", "GameFontNormalSmall")
    lbl2:SetPoint("TOPLEFT", 172, -6)
    logNameEdit = MakeEdit(logPage, 90, function() LogFilterChanged() end)
    logNameEdit:SetPoint("TOPLEFT", 220, -4)

    logPeriodDD = MakeDropdown(logPage, PERIODS,
        function() return logPeriodValue end,
        function(v)
            logPeriodValue = v
            LogFilterChanged()
        end,
        100, "DTCCWin_LogPeriod")
    logPeriodDD:SetPoint("TOPLEFT", 318, -6)

    local searchBtn = MakeButton(logPage, "Искать", 62, function() LogRefresh() end)
    searchBtn:SetPoint("TOPLEFT", 428, -4)

    local clearBtn = MakeButton(logPage, "Очистить лог", 100, function()
        DTCC.RequestClearLog()
    end, "DTCCWin_LogClear")
    clearBtn:SetPoint("TOPRIGHT", logPage, "TOPRIGHT", -8, -4)
    clearBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Очистить лог (по фильтрам)", 0.95, 0.95, 0.95)
        GameTooltip:AddLine("Удаляет только записи, видимые при текущих фильтрах\n(галочки источников, поиск, период). Остальное сохраняется.", nil, nil, nil, 1)
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- фильтры-галочки: создаются без позиций — раскладку (одна строка,
    -- перенос при нехватке ширины) делает LogLayoutChecks, когда готовы все
    local function SourceCheck(settingKey, ckey, labelText, tooltip)
        local cb = DTCC.UI.Check(logPage, labelText, tooltip, function(v)
            if DTCC.db then DTCC.db.settings[settingKey] = v end
            DTCC.FireEvent("SettingsChanged")
            LogFilterChanged()
        end)
        if DTCC.db then cb:SetChecked(DTCC.db.settings[settingKey]) end
        logCheckboxes[ckey] = cb
        return cb
    end

    SourceCheck("logShowPlayers", "players", "Мировой чат",
        "Сообщения мирового чата (.chat), приходящие системными строками.\nПо умолчанию включено — системный мусор не показывается.")
    SourceCheck("logShowRaw", "raw", "RAW",
        "RAW-записи: системные строки со ссылкой игрока (входы, достижения,\nлут и другой мусор в нестандартном формате), записанные как есть.")

    -- локальные чаты: Общий/Группа/Гильдия/Шёпот (только логируются)
    for _, def in ipairs(DTCC.LOCAL_SOURCES) do
        local src = def.src
        local cb = DTCC.UI.Check(logPage, def.label, def.tooltip, function(v)
            if DTCC.db then
                DTCC.db.settings.logShowSources = DTCC.db.settings.logShowSources or {}
                DTCC.db.settings.logShowSources[src] = v
            end
            DTCC.FireEvent("SettingsChanged")
            LogFilterChanged()
        end)
        if DTCC.db then
            cb:SetChecked(DTCC.db.settings.logShowSources[src] ~= false)
        end
        logSourceChecks[#logSourceChecks + 1] = { cb = cb, key = src }
    end

    local function FlagCheck(key, flag, labelText, tooltip)
        local cb = DTCC.UI.Check(logPage, labelText, tooltip, function()
            local _, _, mask = LogFilterState()
            if DTCC.db then DTCC.db.settings.logFilterFlags = mask end
            DTCC.FireEvent("SettingsChanged")
            LogFilterChanged()
        end)
        if DTCC.db then
            cb:SetChecked(bit.band(tonumber(DTCC.db.settings.logFilterFlags) or 0, flag) ~= 0)
        end
        logCheckboxes[key] = cb
        logFlagChecks[#logFlagChecks + 1] = { cb = cb, flag = flag }
        return cb
    end

    FlagCheck("friend", DTCC.FLAG_FRIEND, "Друзья",
        "Только сообщения игроков из списка друзей.")
    FlagCheck("bl", DTCC.FLAG_BLACKLIST, "ЧС",
        "Только сообщения игроков из чёрного списка.")
    FlagCheck("hidden", DTCC.FLAG_HIDDEN, "Скрытые",
        "Только сообщения, скрытые из чата (ЧС или цензура «Скрывать из чата»).")
    FlagCheck("censor", DTCC.FLAG_CENSORED, "Цензура",
        "Только сообщения с запрещёнными словами.")
    FlagCheck("autobl", DTCC.FLAG_AUTOBL, "Авто-ЧС",
        "Только сообщения, за которые игрок попал в ЧС автоматически.\nНесколько типов-галочек складываются как «ИЛИ».")

    logCountLabel = MakeLabel(logPage, "", "GameFontNormalSmall")
    logCountLabel:SetTextColor(0.6, 0.6, 0.6)

    -- заголовки колонок (позиции выставляет LogLayoutChecks — сдвигаются
    -- вместе со счётчиком при переносе галочек на вторую строку)
    logColHeaders = {
        { fs = MakeLabel(logPage, "Время"),     x = 10 },
        { fs = MakeLabel(logPage, "Игрок"),     x = 84 },
        { fs = MakeLabel(logPage, "Сообщение"), x = LOG_MSG_X },
    }
    for _, hh in ipairs(logColHeaders) do
        hh.fs:SetTextColor(0.5, 0.5, 0.5)
    end

    -- шрифт записей — как в игровом чате; замер переноса (logMeasure) должен
    -- использовать ТОТ ЖЕ шрифт, иначе высоты строк не сойдутся с рендером
    logFontPath, logFontHeight = LogChatFont()
    logMeasure = logPage:CreateFontString(nil, "BACKGROUND", "GameFontNormalSmall")
    logMeasure:Hide()
    logMeasure:SetFont(logFontPath, logFontHeight)
    logMeasure:SetText("n n")
    local withSpace = logMeasure:GetStringWidth()
    logMeasure:SetText("nn")
    logSpaceW = max(1, withSpace - logMeasure:GetStringWidth())
    logMeasure:SetText("Йё")
    logLineH = max(8, logMeasure:GetStringHeight())

    -- свой скроллбар: высоты строк переменные, FauxScrollFrame (фикс. линия) не подходит.
    -- ВАЖНО (грабли 3.3.5): шаблон UIPanelScrollBarTemplate при создании уже вешает
    -- OnValueChanged, который зовёт parent:SetVerticalScroll (родитель у него —
    -- ScrollFrame, у нас обычный Frame), а его стрелки шагают на пол-высоты слайдера
    -- В ПИКСЕЛЯХ. Поэтому наш OnValueChanged ставим ДО любых SetMinMaxValues/SetValue
    -- (иначе первый же SetValue уронит шаблонный обработчик), стартовое SetValue(0)
    -- не делаем вовсе, а клики стрелок переопределяем на шаг записями.
    logSlider = CreateFrame("Slider", "DTCCWin_LogScroll", logPage, "UIPanelScrollBarTemplate")
    logSlider:SetOrientation("VERTICAL")
    logSlider:SetWidth(16)
    logSlider:SetPoint("TOPRIGHT", logPage, "TOPRIGHT", -10, -logTop)
    logSlider:SetPoint("BOTTOMRIGHT", logPage, "BOTTOMRIGHT", -10, LOG_BOTTOM)
    logSlider:SetScript("OnValueChanged", function(self, value)
        SetLogOffset(floor((tonumber(value) or 0) + 0.5))
    end)
    logSlider:SetValueStep(1)
    logSlider:SetMinMaxValues(0, 0)
    logSlider:Hide()

    local upBtn = _G["DTCCWin_LogScrollScrollUpButton"]
    local downBtn = _G["DTCCWin_LogScrollScrollDownButton"]
    if upBtn then
        upBtn:SetScript("OnClick", function()
            SetLogOffset(logOff - 3)
            PlaySound("UChatScrollButton")
        end)
    end
    if downBtn then
        downBtn:SetScript("OnClick", function()
            SetLogOffset(logOff + 3)
            PlaySound("UChatScrollButton")
        end)
    end

    -- галочки каналов по настройке + первая раскладка всех галочек/шапки
    -- (после неё LogLayoutChecks знает и слайдер, и счётчик, и заголовки)
    LogRebuildChannelChecks()

    logPage:SetScript("OnMouseWheel", function(_, delta)
        SetLogOffset(logOff - (delta > 0 and 2 or -2))
    end)

    logRows = {}
    for i = 1, ROW_POOL do
        local row = CreateFrame("Frame", nil, logPage)
        row:SetHeight(ROW_H)

        -- левая часть строки (время + игрок): кнопка с подсветкой, тултипом и ПКМ-меню
        local head = CreateFrame("Button", nil, row)
        head:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        head:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        head:SetWidth(LOG_MSG_X - 4)
        head:RegisterForClicks("RightButtonUp")
        local hl = head:CreateTexture(nil, "HIGHLIGHT")
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetAllPoints(head)
        hl:SetBlendMode("ADD")
        head.timeF = head:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        head.timeF:SetFont(logFontPath, logFontHeight)
        head.timeF:SetPoint("TOPLEFT", head, "TOPLEFT", 4, -4)
        head.timeF:SetWidth(LOG_TIME_W)
        head.timeF:SetJustifyH("LEFT")
        head.nameF = head:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        head.nameF:SetFont(logFontPath, logFontHeight)
        head.nameF:SetPoint("TOPLEFT", head, "TOPLEFT", LOG_TIME_W + 8, -4)
        head.nameF:SetWidth(LOG_NAME_W)
        head.nameF:SetJustifyH("LEFT")
        head:SetScript("OnEnter", LogTooltip)
        head:SetScript("OnLeave", function() GameTooltip:Hide() end)
        head:SetScript("OnClick", function(self, mouse)
            if mouse == "RightButton" and self.entry then
                ShowMenu({ mode = "log", entry = self.entry })
            end
        end)
        row.head = head

        -- сообщение: ScrollingMessageFrame — ссылки предметов кликабельны,
        -- длинный текст переносится по ширине колонки
        local smf = CreateFrame("ScrollingMessageFrame", nil, row)
        smf:SetPoint("TOPLEFT", row, "TOPLEFT", LOG_MSG_X, 0)
        smf:SetWidth(200)
        smf:SetHeight(ROW_H)
        smf:EnableMouse(true)
        smf:SetFading(false)
        smf:SetMaxLines(1) -- одна запись на строку: AddMessage замещает прежнюю
        smf:SetJustifyH("LEFT")
        smf:SetFont(logFontPath, logFontHeight) -- шрифт игрового чата, как у колонок
        smf:SetScript("OnHyperlinkClick", function(self, link, text, button)
            SetItemRef(link, text, button, self)
        end)
        -- тултип при наведении на предмет: OnHyperlinkEnter появился после 3.3.5,
        -- подключаем через pcall — старый клиент просто не будет его звать
        pcall(smf.SetScript, smf, "OnHyperlinkEnter", function(self, link)
            local kind = strsplit(":", tostring(link or ""))
            if kind == "item" or kind == "enchant" or kind == "spell" or kind == "quest" then
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetHyperlink(link)
                GameTooltip:Show()
            end
        end)
        pcall(smf.SetScript, smf, "OnHyperlinkLeave", function() GameTooltip:Hide() end)
        smf:SetScript("OnMouseUp", function(self, button)
            if button == "RightButton" and row.entry then
                ShowMenu({ mode = "log", entry = row.entry })
            end
        end)
        row.smf = smf

        -- тонкая линия-разделитель внизу строки (многострочные записи читаются легче)
        local sep = row:CreateTexture(nil, "BACKGROUND")
        sep:SetTexture(0.25, 0.3, 0.35, 0.35)
        sep:SetHeight(1)
        sep:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 4, 0)
        sep:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -28, 0)

        row:Hide()
        logRows[i] = row
    end
end

--------------------------------------------------------------------------------
-- Вкладка «Цензура»
--------------------------------------------------------------------------------

local cnPage, cnWordsEdit, cnWordsInfo, cnModeDD, cnDurDD, cnAutoBLCheck, cnEnabledCheck
local cnFieldDirty   -- пользователь правил поле: не перезатирать при открытии вкладки
local cnFilling      -- программный SetText тоже дёргает OnTextChanged — правкой не считать

-- Заполнить поле программно (не помечает его изменённым пользователем).
local function CNFillField(text)
    cnFilling = true
    cnWordsEdit:SetText(text)
    cnFilling = false
end

-- Поле слов занимает всю вкладку под верхними контролами.
-- -46: рамка (10 + 6 слева, 6 + 24 справа под скроллбар); -108: шапка (-90),
-- нижняя кромка рамки и внутренние отступы скролл-фрейма.
local function CNLayout()
    if not cnPage or not cnWordsEdit then return end
    cnWordsEdit:SetWidth(max(120, cnPage:GetWidth() - 46))
    cnWordsEdit:SetHeight(max(80, cnPage:GetHeight() - 108))
end

-- refill=true — перечитать сохранённые слова в поле (открытие вкладки,
-- сохранение); false — обновить только контролы (смена настроек — не затирать
-- недопечатанный список).
local function CNRefresh(refill)
    if not cnEnabledCheck or not DTCC.db then return end
    local s = DTCC.db.settings
    cnEnabledCheck:SetChecked(s.censorEnabled)
    cnAutoBLCheck:SetChecked(s.autoBlacklist)
    cnModeDD.RefreshText()
    cnDurDD.RefreshText()
    cnWordsInfo:SetText("В списке слов: " .. #(s.censorWords or {}))
    if refill and not cnFieldDirty then
        CNFillField(DTCC.Censor_GetWordsAsString())
    end
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

    ------------------------------------------------------------------ редактор слов (вся вкладка)
    -- Метка и кнопки в одну строку, под ними — поле на всю ширину и высоту.
    local wordsLabel = MakeLabel(cnPage, "Слова:", "GameFontNormalSmall")
    wordsLabel:SetPoint("TOPLEFT", 10, -68)

    -- Тултип кнопки (свой GameTooltip, как у грипа ресайза окна)
    local function BtnTip(btn, title, text)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
            GameTooltip:SetText(title, 0.95, 0.95, 0.95)
            GameTooltip:AddLine(text, nil, nil, nil, 1)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local saveBtn = MakeButton(cnPage, "Сохранить", 100, function()
        local n = DTCC.Censor_SetWords({ cnWordsEdit:GetText() })
        cnFieldDirty = false
        cnWordsInfo:SetText("В списке слов: " .. n)
        DTCC.Print("список слов цензуры сохранён (" .. n .. " шт.).")
        CNFillField(DTCC.Censor_GetWordsAsString())
    end, "DTCCWin_WordsSave")
    saveBtn:SetPoint("TOPLEFT", 62, -66)
    BtnTip(saveBtn, "Сохранить список слов",
        "Разделители: новая строка, запятая или точка с запятой.\n" ..
        "Регистр не важен (кириллица тоже), повторы убираются, список сортируется.")

    local linesBtn = MakeButton(cnPage, "Построчно", 95, function()
        CNFillField(table.concat(DTCC.Censor_NormalizeList({ cnWordsEdit:GetText() }), "\n"))
    end, "DTCCWin_WordsLines")
    linesBtn:SetPoint("LEFT", saveBtn, "RIGHT", 6, 0)
    BtnTip(linesBtn, "Формат: по одному слову на строку",
        "Переформатировать содержимое поля: по алфавиту, без повторов.\n" ..
        "Список не меняется, пока не нажать «Сохранить».")

    local commaBtn = MakeButton(cnPage, "Через запятую", 115, function()
        CNFillField(table.concat(DTCC.Censor_NormalizeList({ cnWordsEdit:GetText() }), ", "))
    end, "DTCCWin_WordsComma")
    commaBtn:SetPoint("LEFT", linesBtn, "RIGHT", 6, 0)
    BtnTip(commaBtn, "Формат: слова через запятую",
        "Переформатировать содержимое поля: по алфавиту, без повторов.\n" ..
        "Список не меняется, пока не нажать «Сохранить».")

    cnWordsInfo = MakeLabel(cnPage, "", "GameFontNormalSmall")
    cnWordsInfo:SetTextColor(0.6, 0.6, 0.6)
    cnWordsInfo:SetPoint("LEFT", commaBtn, "RIGHT", 12, 0)

    -- Рамка-контейнер на всю вкладку. У многострочного EditBox в 3.3.5 видимая
    -- высота пляшет от содержимого (пустой — одна строка, кликом по «пустому
    -- месту» не попасть), поэтому фон и клик-в-фокус держит контейнер.
    local wordsBox = CreateFrame("Frame", nil, cnPage)
    wordsBox:SetPoint("TOPLEFT", 10, -90)
    wordsBox:SetPoint("BOTTOMRIGHT", -6, 6)
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
    wordsBox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:SetText("Слова цензуры", 0.95, 0.95, 0.95)
        GameTooltip:AddLine("Совпадения ищутся подстрокой, без учёта регистра " ..
            "(кириллица и Ё/ё учитываются): слово «нос» найдётся и внутри других слов.",
            nil, nil, nil, 1)
        GameTooltip:Show()
    end)
    wordsBox:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local wordsScroll = CreateFrame("ScrollFrame", "DTCCWin_WordsScroll", wordsBox, "UIPanelScrollFrameTemplate")
    wordsScroll:SetPoint("TOPLEFT", 6, -6)
    wordsScroll:SetPoint("BOTTOMRIGHT", -24, 6)

    cnWordsEdit = CreateFrame("EditBox", "DTCCWin_WordsEdit", wordsScroll)
    cnWordsEdit:SetMultiLine(true)
    cnWordsEdit:SetAutoFocus(false)
    cnWordsEdit:SetFontObject("GameFontHighlightSmall")
    cnWordsEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- правка поля пользователем: до «Сохранить» открытие вкладки поле не затирает
    cnWordsEdit:SetScript("OnTextChanged", function()
        if not cnFilling then cnFieldDirty = true end
    end)
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

    CNLayout()      -- первичный размер поля под текущую вкладку
    CNRefresh(true) -- сохранённые слова грузятся в поле сразу
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
    if id == 4 then CNRefresh(true) end
end
DTCC.SelectTab = SelectTab

-- Пересчёт всех вкладок под текущий размер окна. Скрытые страницы тоже:
-- раскладка по якорям работает и у скрытых фреймов, а при переключении
-- вкладки рефреш уже попадёт на готовую раскладку.
local function LayoutAllPages()
    BLLayout()
    FRLayout()
    LogLayoutChecks() -- перенос галочек зависит от ширины; сдвигает шапку/слайдер
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
    -- растягивания давал бы фризы). Вкладке цензуры перерисовка из кэша не
    -- нужна — её поле растягивает CNLayout через LayoutAllPages.
    window:SetScript("OnSizeChanged", function(self, w, h)
        LayoutAllPages()
        if currentTab == 1 then
            BLRender()
        elseif currentTab == 2 then
            FRRender()
        elseif currentTab == 3 then
            LogRender()
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
    -- записей могло стать меньше (очистка по фильтрам) — кэш высот держит
    -- ссылки на удалённые записи, сбрасываем и перемеряем лениво
    wipe(logHeightCache)
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
    end
end)

DTCC.RegisterCallback("SettingsChanged", function()
    -- список каналов в настройке мог измениться — перестраиваем галочки лога
    LogRebuildChannelChecks()
    if window and window:IsShown() and currentTab == 4 then
        CNRefresh()
    end
end)
