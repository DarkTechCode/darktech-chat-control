--[[
    DarkTech Chat Control — алерты о близости игроков из ЧС.

    Детект (как в SilverDragon 2.x для 3.3.5, где нет API неймплейтов):
      * наведение курсора (mouseover);
      * цель / фокус;
      * игрок что-то сказал/крикнул/сэмитировал рядом (/say, /yell, эмоции).

    Вывод: всплывающее окно (по клику — /target), Raid Warning, сообщение
    в чат, красная строка по центру экрана, звук.

    Встроенной версии SilverDragon (2.3.4 для WotLK) popup-API не имеет,
    поэтому алерт собственный, в том же стиле.
]]

local alertTimes = {}   -- [ключ игрока] = время последнего алерта
local lastGlobal = 0    -- общий троттлинг, чтобы не выдавать очереди алертов

DTCC.SOUNDS = {
    { text = "Нет",                        value = "" },
    { text = "Будильник",                  value = "Sound\\Interface\\AlarmClockWarning3.wav" },
    { text = "Сигнал (огры)",              value = "Sound\\Spells\\SimonGame_Visual_GameStart.wav" },
    { text = "Колокол (Альянс)",           value = "Sound\\Doodad\\BellTollAlliance.wav" },
    { text = "Колокол (Орда)",             value = "Sound\\Doodad\\BellTollHorde.wav" },
    { text = "Звук интерфейса (меню)",     value = "SOUND:igMainMenuOpen" },
}

function DTCC.PlayAlertSound(path)
    if not path or path == "" then return end
    if strsub(path, 1, 6) == "SOUND:" then
        PlaySound(strsub(path, 7))
    else
        PlaySoundFile(path)
    end
end

--------------------------------------------------------------------------------
-- Всплывающие окна (пул из трёх, новые стеком)
--------------------------------------------------------------------------------

local POPUP_COUNT = 3
local popups = {}

local function Popup_OnClick(self, mouse)
    if mouse == "LeftButton" and self.player and not self.isTest then
        RunMacroText("/target " .. self.player)
    end
    self:Hide()
    self.inUse = false
end

local function Popup_OnUpdate(self, dt)
    self.elapsed = self.elapsed + dt
    local e = self.elapsed
    if e < 0.15 then
        -- появление: масштаб и прозрачность
        local k = e / 0.15
        self:SetAlpha(0.3 + 0.7 * k)
        self:SetScale(0.7 + 0.3 * k)
    elseif e < 3.6 then
        self:SetAlpha(1)
        self:SetScale(1)
    elseif e < 4.2 then
        -- затухание
        self:SetAlpha(1 - (e - 3.6) / 0.6)
    else
        self:Hide()
        self.inUse = false
    end
end

local function CreatePopup(i)
    local f = CreateFrame("Button", "DTCCAlertPopup" .. i, UIParent)
    f:SetWidth(360)
    f:SetHeight(64)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetScript("OnClick", Popup_OnClick)
    f:SetScript("OnUpdate", Popup_OnUpdate)
    f:Hide()

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(36)
    icon:SetHeight(36)
    icon:SetPoint("LEFT", 18, 0)
    icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8") -- череп
    f.icon = icon

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -2)
    title:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    title:SetJustifyH("LEFT")
    title:SetText("ИГРОК ИЗ ЧС РЯДОМ")
    title:SetTextColor(1, 0.25, 0.25)
    f.title = title

    local name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    name:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    name:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    name:SetJustifyH("LEFT")
    name:SetTextColor(1, 1, 1)
    f.name = name

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -1)
    sub:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    sub:SetJustifyH("LEFT")
    sub:SetTextColor(0.6, 0.6, 0.6)
    f.sub = sub

    return f
end

local function ShowPopup(player, how, subText)
    local popup
    for i = 1, POPUP_COUNT do
        local p = popups[i]
        if not p.inUse then
            popup = p
            break
        end
    end
    if not popup then
        -- все заняты — заменяем самое старое окно
        popup = popups[1]
        for i = 2, POPUP_COUNT do
            if popups[i].elapsed > popup.elapsed then
                popup = popups[i]
            end
        end
    end

    popup.player  = player
    popup.isTest  = false
    popup.elapsed = 0
    popup.name:SetText(player)
    popup.sub:SetText(how .. (subText and (" — " .. subText) or ""))
    popup:SetScale(0.7)
    popup:SetAlpha(0.3)
    popup:Show()
    popup.inUse = true
end

--------------------------------------------------------------------------------
-- Основной алерт
--------------------------------------------------------------------------------

function DTCC.FireProximityAlert(name, how)
    local db = DTCC.db
    if not db then return end
    local s = db.settings
    if not s.alertEnabled then return end

    local entry = DTCC.Blacklist_Get(name)
    if not entry then return end

    local key = DTCC.NameKey(name)
    local now = time()
    if (alertTimes[key] or 0) + (tonumber(s.alertCooldown) or 60) > now then return end
    if lastGlobal + 1 > now then return end
    alertTimes[key] = now
    lastGlobal = now

    local reasonText = nil
    if entry.reason and entry.reason ~= "" then
        reasonText = "за «" .. DTCC.Truncate(entry.reason, 24) .. "»"
    end

    DTCC.PlayAlertSound(s.alertSound)

    if s.alertPopup then
        ShowPopup(name, how, reasonText)
    end
    if s.alertRW then
        RaidNotice_AddMessage(RaidWarningFrame,
            "[DTCC] ЧС рядом: " .. name .. " (" .. how .. ")",
            { r = 1, g = 0.3, b = 0.3 })
    end
    if s.alertChat then
        DTCC.Print(DTCC.COLORS.red .. "ЧС рядом: " .. name .. "|r (" .. how .. ")" ..
            (reasonText and (" — " .. reasonText) or ""))
    end
    if s.alertErrors then
        UIErrorsFrame:AddMessage("[DTCC] ЧС рядом: " .. name, 1, 0.2, 0.2, 1, 4)
    end
end

function DTCC.TestAlert()
    local db = DTCC.db
    if not db then return end
    local s = db.settings

    local name = UnitName("player") or "ТестовыйИгрок"

    DTCC.PlayAlertSound(s.alertSound)

    if s.alertPopup then
        local popup = popups[1]
        popup.player = nil
        popup.isTest = true
        popup.elapsed = 0
        popup.name:SetText(name)
        popup.sub:SetText("тест алерта — ЛКМ/ПКМ: закрыть")
        popup:SetScale(0.7)
        popup:SetAlpha(0.3)
        popup:Show()
        popup.inUse = true
    end
    if s.alertRW then
        RaidNotice_AddMessage(RaidWarningFrame, "[DTCC] тест алерта", { r = 1, g = 0.8, b = 0.2 })
    end
    if s.alertChat then
        DTCC.Print(DTCC.COLORS.yellow .. "Тест алерта выполнен.")
    end
    if s.alertErrors then
        UIErrorsFrame:AddMessage("[DTCC] тест алерта", 1, 0.6, 0.2, 1, 4)
    end
end

--------------------------------------------------------------------------------
-- Детект
--------------------------------------------------------------------------------

local function CheckUnit(unit, how)
    if not UnitExists(unit) then return end
    if not UnitIsPlayer(unit) then return end
    local name = UnitName(unit)
    if name and name ~= "" and DTCC.Blacklist_Get(name) then
        DTCC.FireProximityAlert(name, how)
    end
end

local function CheckSpeaker(sender, how)
    if not sender or sender == "" then return end
    sender = DTCC.CleanName(sender)
    if sender == "" then return end
    local me = UnitName("player")
    if me and DTCC.NameKey(sender) == DTCC.NameKey(me) then return end
    if DTCC.Blacklist_Get(sender) then
        DTCC.FireProximityAlert(sender, how)
    end
end

local alertFrame = CreateFrame("Frame")
alertFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
alertFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
alertFrame:RegisterEvent("PLAYER_FOCUS_CHANGED")
alertFrame:RegisterEvent("CHAT_MSG_SAY")
alertFrame:RegisterEvent("CHAT_MSG_YELL")
alertFrame:RegisterEvent("CHAT_MSG_EMOTE")
alertFrame:RegisterEvent("CHAT_MSG_TEXT_EMOTE")
alertFrame:SetScript("OnEvent", function(self, event, msg, sender)
    if not DTCC.db or not DTCC.db.settings.alertEnabled then return end
    if event == "UPDATE_MOUSEOVER_UNIT" then
        CheckUnit("mouseover", "под курсором")
    elseif event == "PLAYER_TARGET_CHANGED" then
        CheckUnit("target", "в цели")
    elseif event == "PLAYER_FOCUS_CHANGED" then
        CheckUnit("focus", "в фокусе")
    elseif event == "CHAT_MSG_SAY" then
        if DTCC.db.settings.alertSayDetect then
            CheckSpeaker(sender, "сказал рядом")
        end
    elseif event == "CHAT_MSG_YELL" then
        if DTCC.db.settings.alertSayDetect then
            CheckSpeaker(sender, "крикнул рядом")
        end
    elseif event == "CHAT_MSG_EMOTE" or event == "CHAT_MSG_TEXT_EMOTE" then
        if DTCC.db.settings.alertSayDetect then
            CheckSpeaker(sender, "эмоция рядом")
        end
    end
end)

-- инициализация пула попапов
for i = 1, POPUP_COUNT do
    popups[i] = CreatePopup(i)
    popups[i]:SetPoint("TOP", UIParent, "TOP", 0, -130 - (i - 1) * 74)
end
