# DarkTech Chat Control (DTCC) — инструкция для агента

Аддон для WoW 3.3.5a (PikaWoW): управление межфракционным чатом `.chat` —
чёрный список, друзья, цензура, лог, алерты. Эта папка — корень аддона и
репозитория. Читай этот файл целиком перед любой работой с проектом.
README.md — пользовательская документация (не забывай обновлять вместе с кодом).

## Быстрые факты

- Путь: `Z:\Games\World of Warcraft Lich King\Interface\AddOns\DarkTechChatControl\`
- Клиент: 3.3.5a ruRU, сервер PikaWoW.
- SavedVariables: `DarkTechCC_DB` (одна на аккаунт). Файл:
  `WTF\Account\DARK\SavedVariables\DarkTechChatControl.lua`, `.bak` — прошлая
  сессия. Это главная улика при разборе «что происходило в игре».
- Lua 5.1, строки байтовые: `strlower` НЕ умеет кириллицу — только
  `DTCC.utf8lower` / `DTCC.Truncate` (Core.lua).
- Версия — в `DarkTechChatControl.toc`. Тексты UI и комментарии — по-русски.
- Git: папка аддона — корень репозитория (ветка `main`, стартовый коммит
  `bc71768`, v1.3.0 от 2026-10-04). `.git`/`.gitignore`/`.gitattributes`
  клиентом WoW не читаются — на игру не влияют. `.gitattributes` (`* -text`)
  запрещает конвертацию концов строк (файлы байт-в-байт) — не удалять.
  Перед работой: `git status`/`git diff` (незакоммиченные правки = не
  отданные пользователю). После вех — коммит. При ручной упаковке папки
  для передачи исключать `.git`.

## Железные правила клиента 3.3.5 (нарушение = тихие баги)

1. **`.toc` кэшируется при старте клиента целиком.** Правки `.lua` →
   `/console reloadui` достаточно. ЛЮБАЯ правка `.toc` (версия, новый файл,
   SavedVariables) → только полный перезапуск игры. После правки `.toc` всегда
   предупреждай пользователя. В Core.lua есть self-check на незагруженный
   Widgets.lua — не убирай его.
2. **Чат-фильтры**: обработка останавливается на первом фильтре, вернувшем
   `true`. Подавить строку = `return true`; заменить = `self:AddMessage(новая)`
   и `return true`. Наши фильтры продвигаются в начало списка через
   `DTCC.PromoteFilterFirst` (Capture.lua) — не трогать без причины.
3. **`UIOptionsCheckButtonTemplate` НЕ существует** (CreateFrame молча создаст
   голый чекбокс без подписи). `InterfaceOptionsCheckButtonTemplate` существует,
   но глобальный `$parentText` не используем — подпись создаём сами
   (`DTCC.UI.Check` в Widgets.lua, `NewCheck` в Options.lua).
4. **`FontString:SetText(nil)` роняет клиент** — всегда `tostring(...)`/умолчания.
5. **Ловушка замыкания Lua 5.1**: `local x = f(..., function() x:Foo() end)` —
   замыкание видит ГЛОБАЛ `x` (nil). Пред-объявляй `local x` отдельной строкой
   (пример: wordsEdit в Options.lua).
6. **Свои дропдауны/меню (Widgets.lua) — единственный рабочий способ здесь.**
   Устроено в точности как `DragonUI/utils/menu.lua` («DragonUIMenu» — рабочее
   меню на этом клиенте; см. также Blizzard UIDropDownMenu и Gatherer
   Configator): меню — Frame, ребёнок UIParent, страта **TOOLTIP**,
   `EnableMouse(true)`, пункты — дочерние кнопки. **ПОЛНОЭКРАННЫЙ ЛОВЕЦ КЛИКОВ
   НЕ ИСПОЛЬЗОВАТЬ НИКОГДА** — четыре варианта (страта+уровни, toplevel,
   дочерний фрейм ловца, показ в разном порядке) на этом клиенте оставляли
   ловца поверх пунктов: меню видно, но ввод до пунктов не доходит, hover не
   срабатывает (пункты выглядят «как disabled»). Закрытие меню вместо ловца:
   OnUpdate-таймер — меню скрывается через 2 сек после ухода курсора с меню и
   с якоря; скрытие при пропаже якоря; ESC через UISpecialFrames;
   `hooksecurefunc("CloseDropDownMenus", CloseMenu)` — закрытие вместе с меню
   Blizzard. При открытии меню прятать `GameTooltip` (та же страта, накроет
   меню). Ширина пунктов — только `FontString:GetStringWidth()` (`strlen`
   удваивает кириллицу). Подсветку hover делать через `SetHighlightTexture`
   (текстуру создавать слоем BACKGROUND, не «HIGHLIGHT»). Исходники интерфейса
   3.3.5 (все FrameXML): https://github.com/wowgaming/3.3.5-interface-files.
7. **Хит-зона чекбокса — ровно по подписи**:
   `cb:SetHitRectInsets(0, -(label:GetStringWidth() + 10), 0, 0)`. Фиксированные
   −400/−460 создавали невидимые зоны, перекрывающие соседние контролы (клик по
   «Режим:» переключал «Цензура включена»).
8. **Пустой многострочный EditBox схлопывается до одной строки** (кликом не
   попасть) → сажать в контейнер фиксированного размера: фон/размер на нём,
   `EnableMouse(true)` + `OnMouseDown → editbox:SetFocus()` (редакторы слов в
   Window.lua и Options.lua).
9. **FauxScrollFrame**: строки не шире `RIGHT -30…-34` от страницы, иначе
   залезают под слайдер (скроллбар висит у правого края скролл-фрейма).
10. **Панель настроек**: `InterfaceOptions_AddCategory(panel)`,
    `InterfaceOptionsFrame_OpenToCategory` вызывать дважды. Ошибки внутри
    pcall-диспетчера событий НЕ видны Swatter'ом — только строкой в чат.
    Сборку каждой вкладки держать в pcall (уже сделано в Window.lua).
11. **Диагностика в игре**: `/console scriptErrors 1`; `/dtcc debug on`
    (печатает все системные/канальные строки с экранированными кодами цвета).

## Карта кода

| Файл | Ответственность / ключевые точки |
|---|---|
| Core.lua | неймспейс, цвета, UTF-8 (`utf8lower`, `Truncate`, `NameKey`, `CleanName`), время/сроки (`DTCC.DURATIONS`, `FormatRemaining`), шина событий, `DEFAULTS` + `CopyDefaults`, слэш `/dtcc` (`/dcc`), ADDON_LOADED/PLAYER_LOGIN |
| Widgets.lua | `DTCC.UI`: `PopupMenu`/`CloseMenu` (меню + ловец), `CreateDropdown(parent, items, get, set, width, name, tooltip)`, `Check`. Свои, не Blizzard |
| Lists.lua | ЧС: `Blacklist_Add/Remove/Get/MakePermanent/PurgeExpired/GetSorted(sortKey, sortDir)` (ключи `name\|added\|expires\|reason` × `asc\|desc`; `expires=nil` = math.huge — бессрочные в конце при возр.). Друзья: `Friends_*` |
| Censor.lua | слова: `Censor_SetWords/Add/Remove` (разделители `, ; \n`, нормализация), кэш, `CensorFind`, `CensorMask` (звёзды по СИМВОЛАМ, не байтам) |
| Capture.lua | 3-уровневый парсер (strict mod-world-chat → tolerant → RAW), `ParseWorldMessage`, `LogAdd/LogSearch/ClearLog`, `SendWorldMessage` (`.chat` через SAY), фильтры CHAT_MSG_SYSTEM/CHANNEL, конвейер `ProcessChatLine` |
| Alerts.lua | `DTCC.SOUNDS`, пул попапов, `FireProximityAlert`, детект (mouseover/target/focus/say/yell/emote) |
| Options.lua | панель Interface Options (`NewCheck/NewDropdown/NewButton/NewEdit/NewSection`, `Refresh` по SettingsChanged, StaticPopup-диалоги очистки лога/сброса) |
| Window.lua | окно: вкладки ЧС (сортировка по заголовкам + колонка «Добавлен»), Друзья, Лог, Цензура; контекстное меню `MenuDescriptor` (режимы `bl/friend/log`). Окно растягивается за грип `DTCCWindowResizeGrip` (`SetResizable` + `StartSizing("BOTTOMRIGHT")`, на время растягивания `SetClampedToScreen(false)`): по вкладкам тройка `XXLayout` (число видимых строк + ширина последней колонки) → `XXRender` (из кэша — вызывается на каждый `OnSizeChanged` во время растягивания, полные поиск/сортировка там нельзя — фризы) → `XXRefresh` (полный пересчёт). Пул строк `ROW_POOL` (32) / `CN_ROW_POOL` (24), offset подрезает `ClampScroll`, текст в колонки укладывает `FitText`. Размер/позиция — `settings.winW/winH/winX/winY` |
| Minimap.lua | кнопка миникарты (`RegisterForDrag`, защита от коллекторов DragonUI) |

Порядок конвейера в `ProcessChatLine` (менять осторожно): флаги списков →
цензура/авто-ЧС → лог (`LogAdd` — до скрытия, скрытое всегда в логе) →
скрытие ЧС (hideBlacklisted/заглушка) → скрытие цензуры (`censorMode=="HIDE"`)
→ пересборка строки (маскирование, время, `[ДРУГ]`).

События шины: `OnInitialized`, `OnPlayerLogin`, `SettingsChanged`,
`ListsChanged`, `BlacklistUpdated`, `LogChanged`, `MinimapSettingChanged`.
Флаги лога: HIDDEN 1, CENSORED 2, BLACKLIST 4, FRIEND 8, AUTOBL 16, RAW 32.

## Рецепты

- **Новая настройка**: `DEFAULTS.settings` в Core.lua → контрол в Options.lua
  (+ строка в `Refresh`) и/или на вкладке Window.lua → в обработчике
  `DTCC.db.settings.x = v` + `DTCC.FireEvent("SettingsChanged")`.
- **Пункт контекстного меню**: `MenuDescriptor` в Window.lua;
  формат `{ text=, func=, checked=, disabled= }`.
- **Колонка/сортировка ЧС**: `MakeSortHeader` в `BuildBLPage`, колонки в
  `MakeRow` + заполнение в `BLRefresh`, ключ в `Blacklist_GetSorted`
  (BL_SORT_KEYS в Lists.lua). Сортировка хранится в
  `settings.blSortKey/blSortDir`.
- **Новый дропдаун**: `DTCC.UI.CreateDropdown(parent, {{text=, value=}}, get,
  set, width, name, tooltip)`; 7-й аргумент — необязательный тултип.

## Тестирование (обязательно перед отдачей пользователю)

Стенд: `C:\Users\darks\AppData\Local\Temp\luacheck\` (fengari + luaparse;
папка временная — если стёрта: `npm i luaparse fengari`, файлы `run.js`,
`tests.lua`, `ui-run.js`, `ui-prelude.lua`, `ui-tests.lua` восстановить из
этой папки/репозитория/памяти агента).

- Синтаксис Lua 5.1: все `.lua` аддона через luaparse
  (prelude/тесты парсить как 5.3 — там есть `&`).
- Логика: `node run.js` — парсер, цензура, списки, фильтры.
- UI-дым: `node ui-run.js` — сборка всех окон, регистрация панели,
  прокликивание ВСЕХ обработчиков, меню/дропдауны/ловец, сортировка ЧС,
  подсветка пунктов, алерты.

Правила заглушек (`ui-prelude.lua`): моделируют реальный клиент —
`SetText(nil)` ошибка, шаблоны чекбоксов без Text, живые списки фильтров,
`SetFrameStrata/Level` и `SetTextColor` записываются (`__strata/__level/__color`)
и проверяются тестами. НЕ делать заглушки «удобнее» реального API —
фантом-API баги уже маскировались таким образом.

## Текущее состояние (обновляй при релизе)

- **v1.4.0 (2026-10-04)**: окно растягивается за уголок (правый нижний,
  `DTCCWindowResizeGrip`): число видимых строк списков и ширина последних
  колонок адаптируются (`Layout/Render/Refresh`-тройка на вкладку, пул строк),
  размер и позиция сохраняются (`winW/winH`), при загрузке ужимаются до экрана.
  UI-тесты: грип, OnSizeChanged, адаптивные строки, сохранение размера.
- **v1.3.0 (2026-10-04)**: исправлены все меню/дропдауны (паттерн DragonUI,
  см. п.6), хит-зоны чекбоксов, колонка «Добавлен» + сортировка ЧС по
  заголовкам, режим цензуры HIDE переименован в «Скрывать из чата» + тултипы,
  редакторы слов в контейнерах (клик-в-фокус), быстрый список слов сдвинут от
  скроллбара, подсветка пунктов меню при наведении. Ждёт плейтеста в игре.
- Открытый вопрос: реальный формат мирового чата PikaWoW ещё не подтверждён
  живьём. Если лог пуст при включённых настройках — просить `/dtcc debug on`
  и прислать строки из чата; парсер весь в Capture.lua (тир-2 толерантный +
  тир-3 RAW должны покрыть форки).
- Для плейтеста после правок `.toc` нужен полный перезапуск клиента.
