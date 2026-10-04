--[[
    DarkTech Chat Control — собственные виджеты.

    Зачем: выпадающие списки Blizzard (UIDropDownMenu) внутри кастомных окон
    на 3.3.5 ведут себя непредсказуемо (масштаб/слой списка ломаются, особенно
    в связке с аддонами, перекрашивающими интерфейс). Здесь — свой простой
    дропдаун и своё всплывающее меню, которые мы полностью контролируем.
]]

DTCC.UI = {}

--------------------------------------------------------------------------------
-- Общее всплывающее меню (используется и дропдаунами, и контекстными меню)
-- items: { { text = "текст", func = function() end, checked = bool, disabled = bool } }
--
-- Устроено в точности как рабочие меню этого клиента (DragonUI/utils/menu.lua
-- «DragonUIMenu», Blizzard UIDropDownMenu, Gatherer Configator):
-- БЕЗ полноэкранного ловца кликов. Ловец во всех вариантах (страты, уровни,
-- toplevel, дочерний фрейм) оказывался поверх пунктов и съедал ввод —
-- меню видно, но не кликается. Вместо ловца меню закрывается:
--   * через HIDE_DELAY секунд после того, как курсор ушёл с меню и с якоря;
--   * при скрытии якоря (смена вкладки и т.п.);
--   * по ESC (UISpecialFrames) и вместе с меню Blizzard (CloseDropDownMenus).
--------------------------------------------------------------------------------

local popup
local itemPool = {}
local MAX_MENU_ITEMS = 20
local HIDE_DELAY = 2

local anchorFrame   -- якорь-фрейм (меню под ним) либо nil (меню у курсора)

local function CloseMenu()
    if popup then
        popup:Hide()
    end
end

DTCC.CloseMenu = CloseMenu

local function EnsureMenu()
    if popup then return end

    popup = CreateFrame("Frame", "DTCCPopupMenu", UIParent)
    popup:SetFrameStrata("TOOLTIP")
    popup:SetClampedToScreen(true)
    popup:EnableMouse(true)
    popup:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    popup:SetBackdropColor(0, 0, 0, 0.92)
    popup.idle = 0
    popup:SetScript("OnUpdate", function(self, elapsed)
        if anchorFrame and not anchorFrame:IsVisible() then
            self:Hide()
            return
        end
        if self:IsMouseOver() or (anchorFrame and anchorFrame:IsMouseOver()) then
            self.idle = 0
            return
        end
        self.idle = self.idle + elapsed
        if self.idle >= HIDE_DELAY then self:Hide() end
    end)
    popup:SetScript("OnHide", function(self)
        anchorFrame = nil
        self.idle = 0
        for _, btn in ipairs(itemPool) do
            btn:Hide()
        end
    end)
    popup:Hide()
    tinsert(UISpecialFrames, "DTCCPopupMenu")
    -- Blizzard закрывает свои дропдауны по большинству кликов вокруг панелей —
    -- наше закрываем вместе с ними (как делает DragonUI)
    hooksecurefunc("CloseDropDownMenus", CloseMenu)
end

local function AcquireItem(i)
    if not itemPool[i] then
        local btn = CreateFrame("Button", "DTCCPopupItem" .. i, popup)
        btn:SetHeight(18)
        -- подсветка при наведении — как в DragonUI: текстура через
        -- SetHighlightTexture (кнопка сама показывает её на hover)
        local hl = btn:CreateTexture(nil, "BACKGROUND")
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAllPoints(btn)
        btn:SetHighlightTexture(hl)
        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", 6, 0)
        fs:SetJustifyH("LEFT")
        btn.text = fs
        -- подсветка пункта при наведении: фон даёт HIGHLIGHT-текстура,
        -- текст немного светлеет (у недоступных пунктов не трогаем)
        btn:SetScript("OnEnter", function(self)
            if self:IsEnabled() then
                self.text:SetTextColor(1, 1, 1)
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if self:IsEnabled() then
                self.text:SetTextColor(1, 0.9, 0.6)
            else
                self.text:SetTextColor(0.5, 0.5, 0.5)
            end
        end)
        itemPool[i] = btn
    end
    return itemPool[i]
end

-- anchor: фрейм (меню под ним) либо nil (меню у курсора)
function DTCC.UI.PopupMenu(items, anchor)
    EnsureMenu()
    CloseMenu()
    -- тултип строки рисуется в той же страте TOOLTIP поверх меню — прячем
    if GameTooltip then GameTooltip:Hide() end

    anchorFrame = (type(anchor) == "table") and anchor or nil
    popup.idle = 0

    local n = 0
    local maxW = 140
    for i, item in ipairs(items) do
        if i > MAX_MENU_ITEMS then break end
        local btn = AcquireItem(i)
        btn.text:SetText((item.checked and "|cff00e5ff•|r " or "  ") .. item.text)
        -- ширину меряем по фактическому тексту (кириллица — 2 байта на букву,
        -- strlen давал двойной запас) и делаем все пункты одной ширины
        local w = btn.text:GetStringWidth() + 34
        if w > maxW then maxW = w end
        if item.disabled then
            btn.text:SetTextColor(0.5, 0.5, 0.5)
            btn:Disable()
        else
            btn.text:SetTextColor(1, 0.9, 0.6)
            btn:Enable()
        end
        btn:SetScript("OnClick", function()
            CloseMenu()
            if item.func then item.func() end
        end)
        btn:ClearAllPoints()
        if i == 1 then
            btn:SetPoint("TOPLEFT", popup, "TOPLEFT", 4, -4)
        else
            btn:SetPoint("TOPLEFT", itemPool[i - 1], "BOTTOMLEFT")
        end
        btn:Show()
        n = n + 1
    end

    if n == 0 then return end

    for i = 1, n do
        itemPool[i]:SetWidth(maxW)
    end
    popup:SetHeight(n * 18 + 8)
    popup:SetWidth(maxW + 8)
    popup:ClearAllPoints()
    if anchorFrame then
        popup:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, -2)
    else
        local cx, cy = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        popup:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", cx / scale, cy / scale)
    end
    popup:Show()
end

--------------------------------------------------------------------------------
-- Дропдаун
-- items: { { text = .., value = .. } }, get() -> текущее значение, set(value)
--------------------------------------------------------------------------------

local function UpdateDDText(dd)
    local current = dd.GetDDValue()
    for _, it in ipairs(dd.items) do
        if it.value == current then
            dd.label:SetText(it.text)
            return
        end
    end
    dd.label:SetText("—")
end

function DTCC.UI.CreateDropdown(parent, items, get, set, width, name, tooltip)
    local dd = CreateFrame("Button", name, parent)
    dd:SetWidth(width or 120)
    dd:SetHeight(22)
    dd:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    dd:SetBackdropColor(0, 0, 0, 0.7)
    dd:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    dd.items = items
    dd.GetDDValue = get
    dd.SetDDValue = function(value)
        set(value)
        UpdateDDText(dd)
    end
    dd.RefreshText = function() UpdateDDText(dd) end

    dd.label = dd:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dd.label:SetPoint("LEFT", 8, 0)
    dd.label:SetJustifyH("LEFT")

    local arrow = dd:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetTextColor(0.5, 0.8, 0.9)
    arrow:SetText("▼")

    if tooltip then
        dd:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(tooltip, 0.95, 0.95, 0.95, 1)
            GameTooltip:Show()
        end)
        dd:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
    end

    dd:SetScript("OnClick", function(self)
        local menuItems = {}
        local current = get()
        for _, it in ipairs(items) do
            menuItems[#menuItems + 1] = {
                text = it.text,
                checked = (it.value == current) or nil,
                func = function() dd.SetDDValue(it.value) end,
            }
        end
        DTCC.UI.PopupMenu(menuItems, self)
    end)

    UpdateDDText(dd)
    return dd
end

--------------------------------------------------------------------------------
-- Чекбокс (для вкладок окна)
--
-- Подпись создаём сами: у шаблонов чекбоксов в 3.3.5 нет гарантии, что
-- глобальный «$parentText» вообще существует (старый UIOptionsCheckButtonTemplate
-- в 3.3.5 отсутствует, и CreateFrame молча создаёт голый чекбокс без подписи).
--------------------------------------------------------------------------------

local checkCounter = 0

function DTCC.UI.Check(parent, labelText, tooltip, onClick)
    checkCounter = checkCounter + 1
    local name = "DTCCUICheck" .. checkCounter
    local cb = CreateFrame("CheckButton", name, parent, "InterfaceOptionsCheckButtonTemplate")
    local text = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetText(labelText)
    text:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    -- Кликом должна быть ровно зона галочки и подписи. Раньше хит-зона уходила
    -- на 400px вправо от чекбокса и перекрывала соседние дропдауны: клик по
    -- «Режим» на вкладке цензуры переключал «Цензура включена».
    cb:SetHitRectInsets(0, -(text:GetStringWidth() + 10), 0, 0)
    cb.label = text
    if tooltip then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(labelText, 1, 0.9, 0.3)
            GameTooltip:AddLine(tooltip, nil, nil, nil, 1)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
    end
    if onClick then
        cb:SetScript("OnClick", function(self)
            local checked = self:GetChecked() and true or false
            onClick(checked)
            PlaySound(self:GetChecked() and "igMainMenuOptionCheckBoxOn" or "igMainMenuOptionCheckBoxOff")
        end)
    end
    return cb
end
