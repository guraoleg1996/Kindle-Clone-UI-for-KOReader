-- Окно «Настройки»: список настроек в стиле плагина.
--
-- Сразу открывается содержимое вкладки «Настройки» родного меню KOReader
-- (Подсветка, Ночной режим, Сеть, Экран и т. д.). Вложенные меню открываются
-- следующим списком, стрелка вверху ведёт на уровень назад (на первом уровне
-- закрывает окно). Стрелок у самих пунктов нет. Пункты не копируются и не
-- переписываются: окно вызывает их собственные функции KOReader.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local I18n = require("kcui/i18n")
local Common = require("kcui/common")
local _ = I18n.gettext
local T = require("ffi/util").template
local Screen = Device.screen
local Divider = Common.Divider
local Gray = Common.Gray
local U = Common.U

local ICONS = debug.getinfo(1, "S").source:match("^@(.*)/kcui/settings%.lua$") .. "/icons"

-- Названия вкладок родного меню (у самих вкладок есть только значок).
local TITLES = {
    ["appbar.filebrowser"] = _("Library"),
    ["appbar.navigation"] = _("Navigation"),
    ["appbar.typeset"] = _("Typeset"),
    ["appbar.settings"] = _("Config"),
    ["appbar.tools"] = _("Tools"),
    ["appbar.search"] = _("Exploration"),
    ["appbar.menu"] = _("Navigate"),
}

local MAX_LINES = 4 -- длиннее пункт не бывает; остальное обрезается многоточием

local Window = InputContainer:extend{
    name = "kcui_settings",
    covers_fullscreen = true,
    ui = nil,
}

-- Сообщение об ошибке вместо вылета KOReader.
local function report(err)
    logger.warn("KindleCloneUI settings:", err)
    UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 6 })
end

local function evaluate(fn, default)
    local ok, value = pcall(fn)
    if ok then return value end
    logger.warn("KindleCloneUI settings:", value)
    return default
end

local function itemText(item)
    local text = item.text
    if item.text_func then
        text = evaluate(item.text_func, item.text)
    end
    if type(text) ~= "string" then
        text = text ~= nil and tostring(text) or ""
    end
    -- тексты KOReader без его перевода берём из каталога плагина (если там есть)
    return I18n.native(text)
end

local function paginate(rows, room)
    local pages, current, used = {}, {}, 0
    for index, row in ipairs(rows) do
        if used + row.h > room and #current > 0 then
            pages[#pages + 1] = current
            current, used = {}, 0
        end
        current[#current + 1] = index
        used = used + row.h
    end
    if #current > 0 or #pages == 0 then
        pages[#pages + 1] = current
    end
    return pages
end

-- Размеры и шапка под текущий экран (вызывается и при открытии, и при изменении размера окна).
function Window:layout()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if not self.dimen then
        self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    else
        -- тот же объект: жесты ссылаются на него
        self.dimen.w, self.dimen.h = sw, sh
    end
    -- список занимает всю ширину окна
    self.x0, self.cw = 0, sw
    self.rtl = Common.Mirror.active()
    self.pad = U(21.27)
    self.min_row = math.max(U(40), math.floor(U(54) * U.rowScale()))
    self.v_pad = U(12)
    self.face = U.face("cfont", 17)
    self.pager_h = U(52)
    self.line = Divider.height

    local Panel = require("kcui/panel")
    if self.top and self.top.onCloseWidget then self.top:onCloseWidget() end
    self.top = Panel.TopBar.new(self.ui, function() return self end, false)
    self.top_h = self.top.dimen.h
end

function Window:init()
    self:layout()

    self.ges_events = {
        TapSettings = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldSettings = { GestureRange:new{ ges = "hold", range = self.dimen } },
        SwipeSettings = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.key_events = {}
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
        self.key_events.PageForward = { { Device.input.group.PgFwd } }
        self.key_events.PageBack = { { Device.input.group.PgBack } }
    end

    self.stack = { { title = _("Settings"), items = self:rootItems() } }
    self.page = 1
    self:rebuild(1)
    self.built = true
end

-- Первый уровень: сразу содержимое вкладки «Настройки» родного меню KOReader
-- (без промежуточного списка вкладок). Если такой вкладки вдруг нет —
-- запасной вариант: список всех вкладок.
-- Порядок разделов первого уровня. У KOReader «Яркость» и «Ночной режим» лежат отдельно от
-- «Экрана», а разделы идут вперемешку («Сеть» рядом с «Экраном»). Здесь «Яркость» и «Ночной
-- режим» переехали внутрь «Экрана», а разделы стоят по смыслу: экран, управление, чтение,
-- затем сеть, язык и устройство.
local ROOT_ORDER = { "screen", "taps_and_gestures", "navigation", "document", "network", "language", "device" }
local SCREEN_ITEMS = { "frontlight", "night_mode" }

local function copyItem(item)
    -- копия: список KOReader остаётся как был (его же показывает стандартное меню)
    local copy = {}
    for key, value in pairs(item) do copy[key] = value end
    copy.separator = nil
    return copy
end

local function arrange(items)
    local by_id, listed = {}, {}
    for _i, item in ipairs(items) do
        if type(item) == "table" and item.id and not by_id[item.id] then by_id[item.id] = item end
    end
    local moved = {}
    for _i, id in ipairs(SCREEN_ITEMS) do
        if by_id[id] then
            table.insert(moved, copyItem(by_id[id]))
            listed[by_id[id]] = true
        end
    end
    local result = {}
    for _i, id in ipairs(ROOT_ORDER) do
        local item = by_id[id]
        if item then
            listed[item] = true
            local entry = copyItem(item)
            if id == "screen" and #moved > 0 then
                -- «Яркость» и «Ночной режим» идут в начале раздела «Экран»
                local original, extra = item, moved
                entry.sub_item_table = nil
                entry.sub_item_table_func = function()
                    local list = {}
                    for _j, moved_item in ipairs(extra) do table.insert(list, moved_item) end
                    local rest = original.sub_item_table
                    if original.sub_item_table_func then rest = original.sub_item_table_func() end
                    for _j, rest_item in ipairs(rest or {}) do table.insert(list, rest_item) end
                    return list
                end
                moved = {}
            end
            table.insert(result, entry)
        end
    end
    -- нет раздела «Экран» (на таком устройстве его не бывает): пункты остаются сверху
    for index = #moved, 1, -1 do table.insert(result, 1, moved[index]) end
    -- пункты, которых здесь нет (их добавили другие плагины), остаются в конце, в прежнем порядке
    for _i, item in ipairs(items) do
        if type(item) == "table" and not listed[item] then table.insert(result, copyItem(item)) end
    end
    return result
end

function Window:rootItems()
    local menu = self.ui and self.ui.menu
    local tabs = menu and menu.tab_item_table
    local items = {}
    if type(tabs) ~= "table" then return items end
    for _i, tab in ipairs(tabs) do
        if tab.icon == "appbar.settings" then
            local sub = tab.sub_item_table or tab
            if type(sub) == "table" and #sub > 0 then
                return arrange(sub)
            end
        end
    end
    for _i, tab in ipairs(tabs) do
        local sub = tab.sub_item_table or tab
        if type(sub) == "table" and #sub > 0 then
            table.insert(items, {
                text = TITLES[tab.icon] or tab.title or tab.text or "…",
                sub_item_table = sub,
            })
        end
    end
    return items
end

function Window:current()
    return self.stack[#self.stack]
end

-- Объект, который KOReader передаёт пунктам меню как «touchmenu_instance».
function Window:proxy()
    if self._proxy then return self._proxy end
    local window = self
    local proxy = { show_parent = window, ui = window.ui, kcui_window = window }
    function proxy:updateItems() window:updateItems() end
    function proxy:closeMenu() window:close() end
    function proxy:backToUpperMenu(no_close) window:back(no_close) end
    setmetatable(proxy, {
        __index = function(_t, key)
            if key == "item_table" then
                local level = window:current()
                return level and level.items
            end
        end,
        __newindex = function(t, key, value)
            if key == "item_table" and type(value) == "table" then
                window:current().items = value
                window:updateItems()
            else
                rawset(t, key, value)
            end
        end,
    })
    self._proxy = proxy
    return proxy
end

function Window:freeRows()
    local level = self:current()
    local rows = level and level.rows
    if not rows then return end
    for _i, row in ipairs(rows) do
        for _j, widget in ipairs(row.widgets) do
            if widget.free then widget:free() end
        end
    end
    level.rows = nil
end

function Window:makeRow(item)
    local text = itemText(item)
    if text == "" then return nil end
    -- «Подсветка» открывает окно с ползунком «Яркость»: называем пункт так же,
    -- как у Kindle и как ползунок внутри («Яркость»), чтобы слова не расходились.
    if text == require("gettext")("Frontlight") then
        text = _("Brightness")
    end
    local row = { item = item, text = text, widgets = {} }
    local enabled = item.enabled
    if item.enabled_func then
        enabled = evaluate(item.enabled_func, true)
    end
    row.enabled = enabled ~= false
    row.sub = item.sub_item_table ~= nil or item.sub_item_table_func ~= nil
    local checked = item.checked
    if item.checked_func then
        checked = evaluate(item.checked_func, false)
    end
    row.checkable = item.checked_func ~= nil or item.checked ~= nil
    row.checked = checked and true or false

    local function image(file, w, h)
        local widget = ImageWidget:new{ original_in_nightmode = false, file = file, width = w, height = h, alpha = true }
        table.insert(row.widgets, widget)
        return widget
    end

    local gap = U(14)
    local left = 0
    if item.kcui_icon then
        row.icon = image(ICONS .. "/" .. item.kcui_icon .. ".svg", U(22), U(22))
        left = left + row.icon:getSize().w + U(16)
    end
    if row.checkable then
        row.box = image(ICONS .. (row.checked and "/checkbox-selected.svg" or "/checkbox-unselected.svg"), U(18), U(18))
        left = left + row.box:getSize().w + gap
    end
    local right = 0 -- стрелок у пунктов со вложенными списками нет
    row.left = left
    row.text_w = math.max(U(60), self.cw - 2 * self.pad - left - right)

    local color = row.enabled and Blitbuffer.COLOR_BLACK or Gray.inactive
    local function box(height)
        local widget = TextBoxWidget:new{
            text = text,
            face = self.face,
            width = row.text_w,
            alignment = self.rtl and "right" or "left",
            fgcolor = color,
            height = height,
            height_adjust = height and true or nil,
            height_overflow_show_ellipsis = height and true or nil,
        }
        return widget
    end
    local widget = box()
    local one_line = TextWidget:new{ text = "Ag", face = self.face }
    local line_h = one_line:getSize().h
    one_line:free()
    if widget:getSize().h > line_h * MAX_LINES * 1.4 then
        widget:free()
        widget = box(math.floor(line_h * MAX_LINES * 1.3))
    end
    row.text_widget = widget
    table.insert(row.widgets, widget)
    row.text_h = widget:getSize().h
    row.h = math.max(self.min_row, row.text_h + 2 * self.v_pad)
    -- все разделительные линии одинаковые: пометки «separator» из KOReader не используются
    row.separator = false
    return row
end

-- Строит заново заголовок, строки и страницы текущего уровня.
function Window:rebuild(page)
    self:freeRows()
    local Toolbar = require("kcui/toolbar")
    if self.header then pcall(function() self.header:free() end) end
    local level = self:current()
    -- стрелка слева есть всегда: на первом уровне она закрывает окно
    self.header = Toolbar.titleHeader(self.cw, level.title, nil, function() end)
    self.header_h = self.header:getSize().h
    self.body_y = self.top_h + self.header_h

    local rows = {}
    for _i, item in ipairs(level.items) do
        local row = self:makeRow(item)
        if row then rows[#rows + 1] = row end
    end
    level.rows = rows
    local room = self.dimen.h - self.body_y
    level.pages = paginate(rows, room)
    if #level.pages > 1 then
        level.pages = paginate(rows, room - self.pager_h)
    end
    self.page = math.max(1, math.min(page or 1, #level.pages))
    if self.built then self:refresh() end
end

function Window:refresh()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function Window:updateItems()
    if self.closed then return end
    self:rebuild(self.page)
end

function Window:setPage(page)
    local level = self:current()
    page = math.max(1, math.min(page, #level.pages))
    if page == self.page then return end
    self.page = page
    self:refresh()
end

function Window:push(title, items)
    local level = self:current()
    level.page = self.page
    self:freeRows()
    table.insert(self.stack, { title = title, items = items })
    self:rebuild(1)
end

function Window:back(no_close)
    if #self.stack <= 1 then
        if not no_close then self:close() end
        return
    end
    self:freeRows()
    table.remove(self.stack)
    local level = self:current()
    if level.items.needs_refresh then
        level.items.needs_refresh = nil
        if level.items.refresh_func then
            evaluate(level.items.refresh_func)
        end
    end
    self:rebuild(level.page or 1)
end

function Window:close()
    if self.closed then return end
    self.closed = true
    UIManager:close(self)
end

function Window:onCloseWidget()
    self.closed = true
    self:freeRows()
    if self.header then pcall(function() self.header:free() end) end
    if self.top and self.top.onCloseWidget then self.top:onCloseWidget() end
    UIManager:setDirty("all", function() return "ui", self.dimen end)
    if Window.instance == self then Window.instance = nil end
end

function Window:onResume()
    if self.top then self.top:handleEvent(Event:new("Resume")) end
end

-- Окно изменили в размере (или повернули экран): тот же список, тот же уровень и страница.
Common.Resize.rebuild(Window, function(self)
    if self.closed then return end
    self:layout()
    self:rebuild(self.page)
end)

-- ───────────── Рисование ─────────────

function Window:paintRow(bb, row, y)
    local x0, cw, pad = self.x0, self.cw, self.pad
    local function place(offset, width)
        return self.rtl and (x0 + cw - offset - width) or (x0 + offset)
    end
    local content_h = row.h - (row.separator and U(8) or 0)
    local cy = y + math.floor(content_h / 2)
    local left = pad
    if row.icon then
        local size = row.icon:getSize()
        row.icon:paintTo(bb, place(left, size.w), cy - math.floor(size.h / 2))
        left = left + size.w + U(16)
    end
    if row.box then
        local size = row.box:getSize()
        row.box:paintTo(bb, place(left, size.w), cy - math.floor(size.h / 2))
        left = left + size.w + U(14)
    end
    local text_size = row.text_widget:getSize()
    row.text_widget:paintTo(bb, place(left, row.text_w), cy - math.floor(text_size.h / 2))
    local line_y = y + row.h - self.line
    if row.separator then
        bb:paintRect(x0 + pad, line_y - U(3), cw - 2 * pad, math.max(1, U.ceil(1.5)), Gray.outline)
    else
        bb:paintRect(x0 + pad, line_y, cw - 2 * pad, self.line, Gray.divider)
    end
end

function Window:paintPager(bb)
    local level = self:current()
    local total = #level.pages
    if total <= 1 then return end
    local x0, cw, pad = self.x0, self.cw, self.pad
    local y = self.dimen.h - self.pager_h
    Divider.paint(bb, x0, y, cw)
    local label = TextWidget:new{
        text = T(_("Page %1 of %2"), self.page, total),
        face = U.face("cfont", 15),
        fgcolor = Gray.secondary,
    }
    local size = label:getSize()
    label:paintTo(bb, x0 + math.floor((cw - size.w) / 2), y + math.floor((self.pager_h - size.h) / 2))
    label:free()
    local icon_size = U(22)
    local function arrow(file, x)
        local image = ImageWidget:new{ original_in_nightmode = false, file = file, width = icon_size, height = icon_size, alpha = true }
        image:paintTo(bb, x, y + math.floor((self.pager_h - icon_size) / 2))
        image:free()
    end
    local left_x, right_x = x0 + pad, x0 + cw - pad - icon_size
    local back_x, forward_x = left_x, right_x
    if self.rtl then back_x, forward_x = right_x, left_x end
    if self.page > 1 then arrow(ICONS .. (self.rtl and "/chevron-right.svg" or "/chevron-left.svg"), back_x) end
    if self.page < total then arrow(ICONS .. (self.rtl and "/chevron-left.svg" or "/chevron-right.svg"), forward_x) end
end

function Window:paintTo(bb, x, y)
    local W, H = self.dimen.w, self.dimen.h
    bb:paintRect(0, 0, W, H, Blitbuffer.COLOR_WHITE)
    self.top:paintTo(bb, 0, 0)
    self.header:paintTo(bb, self.x0, self.top_h)
    local level = self:current()
    local page = level.pages[self.page] or {}
    local cy = self.body_y
    self.visible = {}
    for _i, index in ipairs(page) do
        local row = level.rows[index]
        self:paintRow(bb, row, cy)
        table.insert(self.visible, { row = row, top = cy, bottom = cy + row.h })
        cy = cy + row.h
    end
    self:paintPager(bb)
end

-- ───────────── Нажатия ─────────────

function Window:rowAt(y)
    for _i, entry in ipairs(self.visible or {}) do
        if y >= entry.top and y < entry.bottom then return entry.row end
    end
end

-- Какие окна уже были на экране до нажатия (чтобы заметить новые).
function Window:snapshot()
    local known = {}
    for _i, entry in ipairs(UIManager._window_stack) do
        known[entry.widget] = true
    end
    return known
end

-- Новые окна, которые открыл пункт (яркость, ввод числа и т. п.): когда такое окно
-- закроется, список настроек обновится (галочки, значения), но сам останется открытым.
function Window:watchDialogs(known)
    local window = self
    for _i, entry in ipairs(UIManager._window_stack) do
        local widget = entry.widget
        if widget and widget ~= self and not known[widget] and not widget.kcui_watched then
            widget.kcui_watched = true
            local previous = widget.onCloseWidget
            widget.onCloseWidget = function(this, ...)
                local result
                if previous then result = previous(this, ...) end
                UIManager:nextTick(function()
                    if not window.closed then window:updateItems() end
                end)
                return result
            end
        end
    end
end

function Window:watchLater(known)
    self:watchDialogs(known)
    -- окна, которые пункт показывает с небольшой задержкой
    UIManager:scheduleIn(0.4, function()
        if not self.closed then self:watchDialogs(known) end
    end)
end

-- Окно ввода текста или числа для пунктов с tap_input / hold_input (как в родном меню).
function Window:onInput(input, cancel_callback)
    local window = self
    local ok, err = pcall(function()
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        local function close()
            if dialog then
                UIManager:close(dialog)
                dialog = nil
            end
        end
        dialog = InputDialog:new{
            title = input.title or "",
            input = input.input_func and input.input_func() or input.input,
            input_type = input.type or "number",
            input_hint = input.hint_func and input.hint_func() or input.hint or "",
            buttons = { {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        close()
                        if cancel_callback then cancel_callback() end
                    end,
                },
                {
                    text = _("OK"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog and dialog:getInputText()
                        close()
                        if input.callback then
                            local done, problem = pcall(input.callback, text)
                            if not done then report(problem) end
                        end
                        if not window.closed then window:updateItems() end
                    end,
                },
            } },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end)
    if not ok then report(err) end
    return true
end

-- Нажатие на пункт. Окно «Настройки» после этого НЕ закрывается: человек остаётся
-- в настройках (закрыть его можно стрелкой вверху или самим пунктом, если он этого хочет).
function Window:select(row)
    local item = row.item
    if not row.enabled then return end
    if item.tap_input or item.tap_input_func then
        self:onInput(item.tap_input or item.tap_input_func())
        return
    end
    local sub = item.sub_item_table
    if item.sub_item_table_func then
        sub = evaluate(item.sub_item_table_func, nil)
    end
    if sub then
        if #sub > 0 then self:push(row.text, sub) end
        return
    end
    local callback = item.callback
    if item.callback_func then
        callback = evaluate(item.callback_func, nil)
    end
    if callback then
        local known = self:snapshot()
        local ok, err = pcall(callback, self:proxy())
        if not ok then report(err) end
        if self.closed then return end
        if not (item.check_callback_updates_menu or item.check_callback_closes_menu) then
            self:updateItems()
        end
        self:watchLater(known)
    end
end

function Window:hold(row)
    local item = row.item
    if item.hold_input or item.hold_input_func then
        self:onInput(item.hold_input or item.hold_input_func())
        return
    end
    local callback = item.hold_callback_func and evaluate(item.hold_callback_func, nil) or item.hold_callback
    if callback then
        local known = self:snapshot()
        local ok, err = pcall(callback, self:proxy(), item)
        if not ok then report(err) end
        if not self.closed then self:watchLater(known) end
        return
    end
    local help = item.help_text_func and evaluate(function() return item.help_text_func(self:proxy()) end, nil) or item.help_text
    if help then
        UIManager:show(InfoMessage:new{ text = help })
    end
end

function Window:onTapSettings(_ev, ges)
    local pos = ges.pos
    if pos.x < self.x0 or pos.x >= self.x0 + self.cw then return true end
    if pos.y < self.top_h then
        -- Нажатие по верхней панели / шеврону → открыть шторку с кнопками и яркостью
        require("kcui/panel").openDrawer(self.ui)
        return true
    end
    if pos.y < self.body_y then
        self:back()
        return true
    end
    local level = self:current()
    if #level.pages > 1 and pos.y >= self.dimen.h - self.pager_h then
        local third = self.cw / 3
        local rel = pos.x - self.x0
        if self.rtl then rel = self.cw - rel end
        if rel < third then
            self:setPage(self.page - 1)
        elseif rel > 2 * third then
            self:setPage(self.page + 1)
        end
        return true
    end
    local row = self:rowAt(pos.y)
    if row then self:select(row) end
    return true
end

function Window:onHoldSettings(_ev, ges)
    local pos = ges.pos
    if pos.x < self.x0 or pos.x >= self.x0 + self.cw then return true end
    local row = self:rowAt(pos.y)
    if row then self:hold(row) end
    return true
end

function Window:onSwipeSettings(_ev, ges)
    local direction = ges.direction
    if direction == "south" then
        -- Свайп вниз → открыть верхнюю шторку (быстрые настройки с яркойстью)
        require("kcui/panel").openDrawer(self.ui)
        return true
    elseif direction == "west" then
        self:setPage(self.page + (self.rtl and -1 or 1))
    elseif direction == "east" then
        self:setPage(self.page + (self.rtl and 1 or -1))
    end
    return true
end

function Window:onBack()
    self:back()
    return true
end

function Window:onPageForward()
    self:setPage(self.page + 1)
    return true
end

function Window:onPageBack()
    self:setPage(self.page - 1)
    return true
end

-- ───────────── Вход ─────────────

local Settings = {}

function Settings.show(ui)
    if Window.instance and not Window.instance.closed and UIManager:isWidgetShown(Window.instance) then
        return Window.instance
    end
    local ok, result = pcall(function()
        local menu = ui and ui.menu
        if not menu then error("KOReader menu is not available", 0) end
        if menu.tab_item_table == nil and type(menu.setUpdateItemTable) == "function" then
            menu:setUpdateItemTable()
        end
        local window = Window:new{ ui = ui }
        Window.instance = window
        UIManager:show(window, "ui")
        return window
    end)
    if not ok then
        report(result)
        return nil
    end
    return result
end

return Settings
