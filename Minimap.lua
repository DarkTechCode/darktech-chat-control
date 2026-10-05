--[[
    DarkTech Chat Control — кнопка на миникарте.

    ЛКМ — открыть/закрыть окно аддона.
    ПКМ — настройки.
    Зажать и переместить — передвинуть кнопку по кругу миникарты.

    Совместимость с коллекторами кнопок (DragonUI и т.п.): перетаскивание
    включается только настоящим drag-жестом и только пока кнопка живёт на
    миникарте; из чужой панели клик работает как обычный клик.
]]

local button

local function OnMinimap()
    return button and button:GetParent() == Minimap
end

local function UpdateButtonPosition()
    if not button or not DTCC.db then return end
    if not OnMinimap() then return end
    local angle = math.rad(tonumber(DTCC.db.settings.minimapAngle) or -65)
    local x, y = math.cos(angle), math.sin(angle)
    local cx = x * 78
    local cy = y * 78
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", cx, cy)
end

local function BuildButton()
    button = CreateFrame("Button", "DTCCMinimapButton", Minimap)
    button:SetFrameStrata("MEDIUM")
    button:SetWidth(31)
    button:SetHeight(31)
    button:SetFrameLevel(8)
    button:RegisterForClicks("AnyUp")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetWidth(53)
    overlay:SetHeight(53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetWidth(20)
    background:SetHeight(20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(17)
    icon:SetHeight(17)
    -- «пузырь речи» из стандартного набора клиента (иконка заклинания
    -- Silence, есть с ванильных времён) — тематичнее шестерёнки для аддона
    -- про чат; запасные варианты: INV_Misc_Note_01 (записка)
    icon:SetTexture("Interface\\Icons\\Spell_Holy_Silence")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetPoint("TOPLEFT", 7, -6)
    button.icon = icon

    button:SetScript("OnClick", function(self, mouse)
        if mouse == "RightButton" then
            DTCC.OpenOptions()
        else
            DTCC.ToggleWindow()
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:SetText("|cff00e5ffDarkTech Chat Control|r")
        GameTooltip:AddLine("ЛКМ — окно аддона", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("ПКМ — настройки", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Перетащите, чтобы передвинуть кнопку", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)

    -- перетаскивание по кругу: только настоящий drag и только на миникарте
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function(self)
        if not OnMinimap() then return end
        self:SetScript("OnUpdate", function()
            if not DTCC.db or not OnMinimap() then return end
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            px, py = px / scale, py / scale
            DTCC.db.settings.minimapAngle = math.deg(math.atan2(py - my, px - mx))
            UpdateButtonPosition()
        end)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    UpdateButtonPosition()
    DTCC.minimapButton = button

    if DTCC.db and not DTCC.db.settings.minimapShow then
        button:Hide()
    end
end

DTCC.RegisterCallback("OnInitialized", function()
    BuildButton()
end)

DTCC.RegisterCallback("MinimapSettingChanged", function()
    if not button or not DTCC.db then return end
    if DTCC.db.settings.minimapShow then
        button:Show()
    else
        button:Hide()
    end
end)

-- сброс настроек тоже меняет состояние кнопки
DTCC.RegisterCallback("SettingsChanged", function()
    if not button or not DTCC.db then return end
    UpdateButtonPosition()
    if DTCC.db.settings.minimapShow then
        button:Show()
    else
        button:Hide()
    end
end)
