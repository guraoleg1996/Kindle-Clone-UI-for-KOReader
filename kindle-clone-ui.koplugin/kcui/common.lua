local Blitbuffer = require("ffi/blitbuffer")
local CreDocument = require("document/credocument")
local DataStorage = require("datastorage")
local Font = require("ui/font")
local FontList = require("fontlist")
local LuaSettings = require("luasettings")
local Freetype = require("ffi/freetype")
local UIManager = require("ui/uimanager")
local bit = require("bit")
local datetime = require("datetime")
local ffi = require("ffi")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local sha2 = require("ffi/sha2")
local C_ = require("kcui/i18n").pgettext
local Device = require("device")
local Screen = Device.screen

local ROOT = debug.getinfo(1, "S").source:match("^@(.*)/kcui/common%.lua$")

local REFERENCE_SCALE = math.ceil(1264 / 600 * 10000) / 10000
local REFERENCE_DPI = 300

-- The layout is designed on a canvas whose short side is about 600 units wide
-- (a Kindle in portrait). Real screens are clamped so that the short side stays
-- between MIN_SHORT and MAX_SHORT units: phones get a slightly smaller UI so
-- nothing is cramped, big monitors get a bigger UI instead of a tiny one.
local MIN_SHORT = 400
-- In landscape a phone only has a few hundred units of height, so allow a
-- somewhat smaller UI there to keep more than two list rows on screen.
local MIN_SHORT_LANDSCAPE = 460
local MAX_SHORT = 640

local Units = {}

local cache_key, cache_scale

-- A page whose content is taller than a short screen can build and paint itself
-- at a reduced size: while `override` is set, every unit gets smaller by that factor.
local override = 1

local function scale()
    local dpi, w, h = Screen:getDPI(), Screen:getWidth(), Screen:getHeight()
    local key = dpi * 1e8 + w * 1e4 + h + override * 1e-3
    if key == cache_key then return cache_scale end
    local short = math.min(w, h)
    local physical = dpi * REFERENCE_SCALE / REFERENCE_DPI
    local min_short = w > h and MIN_SHORT_LANDSCAPE or MIN_SHORT
    local result = math.max(short / MAX_SHORT, math.min(physical, short / min_short)) * override
    cache_key, cache_scale = key, result
    return result
end

local function restored(previous, ok, ...)
    override = previous
    if not ok then error((...), 0) end
    return ...
end

-- Runs fn(...) with all units multiplied by `factor` (restored afterwards, even on errors).
function Units.withScale(factor, fn, ...)
    local previous = override
    override = factor
    return restored(previous, pcall(fn, ...))
end

function Units.scale()
    return scale()
end

function Units.ceil(units)
    return math.ceil(units * scale())
end

function Units.face(name, size)
    return Font:getFace(name, size * scale() * 10000 / Screen:scaleBySize(10000))
end

function Units.fit()
    return math.min(1, Screen:getWidth() / math.floor(600 * scale() + 0.5))
end

-- Single-line text that always fits `max_width`: the font shrinks down to
-- `min_ratio` of its size first, and only then is the text cut with an ellipsis.
-- opts: text, size (units), name (font, default "cfont"), bold, fgcolor, max_width, min_ratio
function Units.fitText(opts)
    local TextWidget = require("ui/widget/textwidget")
    local name = opts.name or "cfont"
    local function make(size, max_width)
        return TextWidget:new{
            text = opts.text,
            face = Units.face(name, size),
            bold = opts.bold,
            fgcolor = opts.fgcolor,
            max_width = max_width,
        }
    end
    local widget = make(opts.size)
    local max_w = opts.max_width
    if not max_w then return widget end
    local natural = widget:getSize().w
    if natural <= max_w then return widget end
    widget:free()
    local size = math.max(opts.size * (opts.min_ratio or require("kcui/i18n").minRatio()), opts.size * max_w / natural * 0.97)
    return make(size, max_w)
end

-- Width of `text` in a face, used to pick one common font size for a row of labels.
function Units.textWidth(text, name, size, bold)
    local TextWidget = require("ui/widget/textwidget")
    local widget = TextWidget:new{ text = text, face = Units.face(name or "cfont", size), bold = bold }
    local w = widget:getSize().w
    widget:free()
    return w
end

-- Width / height of the current screen measured in layout units.
function Units.canvas()
    local k = scale()
    return Screen:getWidth() / k, Screen:getHeight() / k
end

-- Short canvases (landscape phones) get proportionally lower list rows so that
-- more than two of them fit; every normal screen keeps the reference height.
function Units.rowScale()
    local _, h = Units.canvas()
    return math.max(0.7, math.min(1, h / 560))
end

-- "compact" = phone-like portrait canvas, "wide" = landscape / desktop canvas.
function Units.compact()
    return (Screen:getWidth() / scale()) < 520
end

function Units.wide()
    return (Screen:getWidth() / scale()) > 760
end

setmetatable(Units, {
    __call = function(_self, units)
        return math.floor(units * scale() + 0.5)
    end,
})

local Paint = {
    NOTCH = 9,
}

function Paint.fill(bb, x, y, w, h, color)
    if Blitbuffer.isColor8(color) then
        bb:paintRect(x, y, w, h, color)
    else
        bb:paintRectRGB32(x, y, w, h, Screen.night_mode and color:invert() or color)
    end
end

function Paint.disc(bb, cx, cy, r, color)
    bb:paintCircle(cx, cy, r, color)
    bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_DARK_GRAY, Units.ceil(1))
end

function Paint.notch(bb, cx, edge_y, above, size, border)
    for i = 0, size do
        local half = size - i
        local y = above and edge_y + i or edge_y - i
        bb:paintRect(cx - half, y, 2 * half + 1, 1, Blitbuffer.COLOR_BLACK)
        if half > border then
            bb:paintRect(cx - half + border, y, 2 * (half - border) + 1, 1, Blitbuffer.COLOR_WHITE)
        end
    end
end

local KindleFonts = {
    UI_FAMILY = "Amazon Ember",
    BOOK_FAMILY = "Bookerly",
    DIR = ROOT .. "/fonts",
    found = {},
}

local function addPluginFonts()
    FontList:getFontList()
    local mark = {}
    FontList:_readList(KindleFonts.DIR, mark)
    local cre = CreDocument:engineInit()
    for path in pairs(mark) do
        if path ~= "cache_dirty" then
            for _i, info in ipairs(FontList.fontinfo[path] or {}) do
                local names = FontList.fontnames[info.name] or {}
                FontList.fontnames[info.name] = names
                table.insert(names, info)
            end
            pcall(cre.registerFont, path)
        end
    end
    table.sort(FontList.fontlist)
end

local function styleName(path, index)
    local ok, ftsize = pcall(Freetype.newFaceSize, path, 12, index)
    if not ok then return end
    local style = ffi.string(ftsize.face.style_name)
    ftsize:done()
    return style
end

local function findFace(family, bold, style, strict, italic)
    local wanted_style = style or (bold and "Bold" or "Regular")
    local fallback
    for _i, path in ipairs(FontList:getFontList()) do
        for _i, info in ipairs(FontList.fontinfo[path] or {}) do
            if info.name == family and (info.italic or false) == (italic or false) and info.bold == bold then
                if styleName(path, info.index) == wanted_style then
                    return path
                end
                fallback = fallback or path
            end
        end
    end
    if not strict then return fallback end
end

local function retarget(face, path)
    local ok, ftsize = pcall(Freetype.newFaceSize, path, face.size)
    if not ok then
        logger.warn("KindleFonts: cannot load", path, ftsize)
        return
    end
    face.ftsize = ftsize
    face.realname = path
    face.is_real_bold = Font:isRealBoldFont(path)
    face.embolden_half_strength = nil
    face.hash = path .. face.size
    Font.faces[face.hash] = face
end

local function applyUIFont()
    local regular = findFace(KindleFonts.UI_FAMILY, false)
    if not regular then return end
    local bold = findFace(KindleFonts.UI_FAMILY, true)
    KindleFonts.found.ui_regular, KindleFonts.found.ui_bold = regular, bold
    KindleFonts.found.ui_medium = findFace(KindleFonts.UI_FAMILY, false, "Medium", true)
    KindleFonts.found.ui_heavy = findFace(KindleFonts.UI_FAMILY, true, "Heavy", true)
        or findFace(KindleFonts.UI_FAMILY, false, "Heavy", true)
    KindleFonts.found.ui_light = findFace(KindleFonts.UI_FAMILY, false, "Light", true)
    KindleFonts.found.ui_heavy = findFace(KindleFonts.UI_FAMILY, false, "Heavy", true)
    KindleFonts.found.ui_italic = findFace(KindleFonts.UI_FAMILY, false, "Italic", true, true)

    if bold then
        Font.bold_font_variant[regular] = bold
        Font.regular_font_variant[bold] = regular
    end
    local replacement = {
        ["NotoSans-Regular.ttf"] = regular,
        ["NotoSans-Bold.ttf"] = bold or regular,
    }

    for name, file in pairs(Font.fontmap) do
        if replacement[file] then
            Font.fontmap[name] = replacement[file]
        end
    end
    local faces = {}
    for _i, face in pairs(Font.faces) do
        if replacement[face.realname] then
            faces[face] = true
        end
    end
    for face in pairs(faces) do
        retarget(face, replacement[face.realname])
    end
    CreDocument.header_font = KindleFonts.UI_FAMILY
end

local function applyBookFont()
    local path = findFace(KindleFonts.BOOK_FAMILY, false)
    if not path then return end
    KindleFonts.found.book = path
    KindleFonts.found.book_bold = findFace(KindleFonts.BOOK_FAMILY, true)
    CreDocument.default_font = KindleFonts.BOOK_FAMILY
end

function KindleFonts.apply()
    if KindleFonts.applied then return end
    KindleFonts.applied = true
    addPluginFonts()
    applyUIFont()
    applyBookFont()
    logger.info("KindleFonts: UI =", KindleFonts.found.ui_regular or "default",
        "| bold =", KindleFonts.found.ui_bold or "default",
        "| book =", KindleFonts.found.book or "default")
end

local GRAYS = {
    light = { secondary = 0x77, inactive = 0x77, outline = 0x99, divider = 0xBB, selected = 0xDD },
    dark = { secondary = 0x77, inactive = 0x77, outline = 0x88, divider = 0x99, selected = 0xBB },
}

local Progress = {
    FILL = Blitbuffer.Color8(0x40),
    TRACK = Blitbuffer.Color8(0xCC),
}

local Gray = setmetatable({}, {
    __index = function(_gray, name)
        local value = GRAYS[Screen.night_mode and "dark" or "light"][name]
        return value and Blitbuffer.Color8(value)
    end,
})

local Divider = {
    height = Units(1.75),
}

function Divider.paint(bb, x, y, w)
    bb:paintRect(x, y, w, Divider.height, Gray.divider)
end

local Dates = {}

-- A date in the current interface language: abbreviated month by default
-- ("Nov 11, 2026"), the full month name when `full` is true.
function Dates.day(seconds, full)
    return require("kcui/i18n").date(seconds, not full)
end

function Dates.time(seconds)
    return datetime.secondsToHour(seconds, G_reader_settings:isTrue("twelve_hour_clock"))
end

function Dates.history(seconds)
    if G_reader_settings:isTrue("history_datetime_short") then
        return os.date(C_("Date string", "%y-%m-%d"), seconds)
    end
    return Dates.day(seconds) .. " · " .. Dates.time(seconds)
end

function Dates.fromStamp(stamp)
    local year, month, day, hour, min, sec = (stamp or ""):match("^(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)$")
    if not year then return end
    return os.time{ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec) }
end

function Dates.stamp(stamp)
    local seconds = Dates.fromStamp(stamp)
    return seconds and Dates.history(seconds) or stamp
end

local Airplane = {}

function Airplane.isOn()
    local utils = package.loaded["utils/flight_utilities"]
    if type(utils) ~= "table" or not utils.getFlightStatus then return false end
    local ok, on = pcall(utils.getFlightStatus, utils)
    return ok and on == true
end

local Navigation = {}

function Navigation.home()
    if filemanagerutil.getHomeFolder then
        return filemanagerutil.getHomeFolder()
    end
    return G_reader_settings:readSetting("home_dir") or Device.home_dir or "."
end

function Navigation.toLibrary(ui, after)
    local home = Navigation.home()
    UIManager:nextTick(function()
        ui:onClose()
        ui:showFileManager(home .. "/")
        local fm = require("apps/filemanager/filemanager").instance
        if fm then
            fm.file_chooser:onGotoPage(1)
            if after then
                after(fm)
            end
        end
    end)
end

function Navigation.toBrowser(ui)
    local file = ui.document and ui.document.file
    UIManager:nextTick(function()
        ui:onClose()
        ui:showFileManager(file)
    end)
end

local Highlights = {}

function Highlights.colors(highlight)
    local colors = {}
    for i, color in ipairs(highlight:getHighlightColorList()) do
        if type(color) == "table" then
            table.insert(colors, color)
        else
            local named = highlight.highlight_colors and highlight.highlight_colors[i]
            if named then
                table.insert(colors, { named[1], named[2], color })
            end
        end
    end
    return colors
end

local Rotation = {}

local last_portrait

local function isPortrait(mode)
    return mode % 2 == 0
end

function Rotation.portrait()
    local current = Screen:getRotationMode()
    if isPortrait(current) then
        return current
    end
    return last_portrait or Screen.DEVICE_ROTATED_UPRIGHT
end

function Rotation.install()
    if Rotation.installed then return end
    Rotation.installed = true
    local FileManager = require("apps/filemanager/filemanager")
    local setRotationMode = FileManager.setRotationMode
    FileManager.setRotationMode = function(fm)
        local preferred = G_reader_settings:readSetting("fm_rotation_mode")
        if G_reader_settings:isTrue("lock_rotation") or (preferred and not isPortrait(preferred)) then
            return setRotationMode(fm)
        end
        local current = Screen:getRotationMode()
        if isPortrait(current) then
            last_portrait = current
        else
            fm:onSetRotationMode(last_portrait or preferred or Screen.DEVICE_ROTATED_UPRIGHT)
        end
    end
    local ReaderView = require("apps/reader/modules/readerview")
    local onReadSettings = ReaderView.onReadSettings
    ReaderView.onReadSettings = function(view, config)
        local current = Screen:getRotationMode()
        if isPortrait(current) then
            last_portrait = current
        end
        if last_portrait and G_reader_settings:nilOrFalse("lock_rotation") then
            local name = view.ui.paging and "kopt_rotation_mode" or "copt_rotation_mode"
            local saved = config:readSetting(name) or G_reader_settings:readSetting(name)
                or Screen.DEVICE_ROTATED_UPRIGHT
            if isPortrait(saved) and saved ~= last_portrait then
                config:saveSetting(name, last_portrait)
            end
        end
        return onReadSettings(view, config)
    end
end

local State = {}

local SEAL = "kcui/9d41f7c2"
local CHECK = 8

local function noBackup()
    return false
end

function State.open(path)
    local settings = LuaSettings:open(path)
    settings.backup = noBackup
    return settings
end

local function statePaths()
    if os.getenv("KCUI_HOME") then
        local dir = DataStorage:getDataDir()
        return dir .. "/kcui.bin", dir .. "/kcui-state.lua"
    end
    return ROOT .. "/data/kcui.bin", ROOT .. "/state.lua"
end

local function scramble(text)
    local out, block, index = {}, "", 0
    for i = 1, #text do
        local offset = (i - 1) % 16
        if offset == 0 then
            block = sha2.hex_to_bin(sha2.md5(SEAL .. index))
            index = index + 1
        end
        out[i] = string.char(bit.bxor(text:byte(i), block:byte(offset + 1)))
    end
    return table.concat(out)
end

local function encode(applied)
    local keys = {}
    for key, value in pairs(applied) do
        if value == true or type(value) == "number" then
            table.insert(keys, key)
        end
    end
    table.sort(keys)
    local lines = {}
    for i, key in ipairs(keys) do
        lines[i] = applied[key] == true and key or key .. "=" .. applied[key]
    end
    local text = table.concat(lines, "\n")
    return sha2.bin_to_base64(scramble(sha2.md5(text):sub(1, CHECK) .. text))
end

local function decode(blob)
    local ok, raw = pcall(sha2.base64_to_bin, blob or "")
    if not (ok and raw and #raw >= CHECK) then return end
    local plain = scramble(raw)
    local text = plain:sub(CHECK + 1)
    if sha2.md5(text):sub(1, CHECK) ~= plain:sub(1, CHECK) then return end
    local applied = {}
    for line in text:gmatch("[^\n]+") do
        local key, value = line:match("^(.-)=(.*)$")
        if key then
            applied[key] = tonumber(value)
        else
            applied[line] = true
        end
    end
    return applied
end

local function writeState(path, applied)
    local temp = path .. ".tmp"
    local file = io.open(temp, "wb")
    if not file then
        logger.warn("State: cannot write", path)
        return false
    end
    file:write(encode(applied))
    file:close()
    return os.rename(temp, path)
end

local function readState()
    local path, legacy = statePaths()
    local file = io.open(path, "rb")
    if file then
        local applied = decode(file:read("*a"))
        file:close()
        return applied or {}
    end
    if lfs.attributes(legacy, "mode") ~= "file" then
        return {}
    end
    local applied = LuaSettings:open(legacy):readSetting("applied") or {}
    if writeState(path, applied) then
        os.remove(legacy)
    end
    return applied
end

local applied_cache

function State.applied()
    applied_cache = applied_cache or readState()
    return applied_cache
end

function State.saveApplied(applied)
    applied_cache = applied
    writeState((statePaths()), applied)
end

-- Right-to-left languages. The overlays below are painted by hand, so KOReader
-- cannot mirror them on its own: the layout is drawn left-to-right into a spare
-- buffer, the buffer is flipped, and then the texts and ordinary icons are
-- painted again, unflipped, at their mirrored places (so no letter is reversed).
local Mirror = {}

local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ImageWidget = require("ui/widget/imagewidget")

function Mirror.active()
    local ok, BD = pcall(require, "ui/bidi")
    return ok and BD.mirroredUILayout() or false
end

-- Arrows and chevrons must point the other way in a mirrored layout, so they are
-- flipped together with it; every other icon keeps its own orientation.
local function flipsWithLayout(widget)
    local file = widget.file
    return type(file) == "string" and (file:find("chevron", 1, true) or file:find("arrow", 1, true)) ~= nil
end

-- `rect` ({x, y, w, h} in the coordinates of `bb`) is the area the overlay owns; only
-- it is mirrored, so whatever lies around it (the book page) stays untouched.
function Mirror.paint(bb, paint, rect)
    local w, h = bb:getWidth(), bb:getHeight()
    local rx, ry = rect and rect.x or 0, rect and rect.y or 0
    local rw, rh = rect and rect.w or w, rect and rect.h or h
    rx, ry = math.max(0, rx), math.max(0, ry)
    rw, rh = math.min(rw, w - rx), math.min(rh, h - ry)
    local off = Blitbuffer.new(w, h, bb:getType())
    off:blitFrom(bb, 0, 0, 0, 0, w, h)
    local recorded = {}
    local original = {
        text = TextWidget.paintTo,
        box = TextBoxWidget.paintTo,
        image = ImageWidget.paintTo,
    }
    local function recording(paint_original, always)
        return function(widget, target, x, y)
            if target == off and (always or not flipsWithLayout(widget)) then
                table.insert(recorded, { widget = widget, x = x, y = y, paint = paint_original })
                return
            end
            return paint_original(widget, target, x, y)
        end
    end
    TextWidget.paintTo = recording(original.text, true)
    TextBoxWidget.paintTo = recording(original.box, true)
    ImageWidget.paintTo = recording(original.image, false)
    local ok, err = pcall(paint, off)
    TextWidget.paintTo, TextBoxWidget.paintTo, ImageWidget.paintTo = original.text, original.box, original.image
    if not ok then
        off:free()
        error(err, 0)
    end
    local copy = Blitbuffer.new(rw, rh, bb:getType())
    copy:blitFrom(off, 0, 0, rx, ry, rw, rh)
    for x = 0, rw - 1 do
        bb:blitFrom(copy, rx + rw - 1 - x, ry, x, 0, 1, rh)
    end
    copy:free()
    off:free()
    for _i, item in ipairs(recorded) do
        local size = item.widget:getSize()
        item.paint(item.widget, bb, rx + rw - (item.x - rx) - size.w, item.y)
    end
end

-- Overlays (Aa sheet, Go To, ...) keep a comfortable maximum width on wide
-- screens and are centred, instead of being stretched over a whole monitor.
local Column = {}

local COLUMN_MAX_UNITS = 800

-- x offset and width of the centred column for the current screen.
function Column.span(max_units)
    local sw = Screen:getWidth()
    local cw = math.min(sw, Units(max_units or COLUMN_MAX_UNITS))
    return math.floor((sw - cw) / 2), cw
end

local function shifted(self, ges, mirror)
    local x0, cw = self.x0 or 0, self.cw
    local flip = mirror and Mirror.active()
    if not (ges and ges.pos) or (x0 <= 0 and not flip) then return ges end
    local copy = {}
    for k, v in pairs(ges) do copy[k] = v end
    local pos = ges.pos
    local outside = pos.x < x0 or pos.x >= x0 + cw
    copy.pos = pos:copy()
    copy.pos.x = pos.x - x0
    if flip then
        local rect = self.mirrorRect and self:mirrorRect()
        local rx, rw = rect and rect.x or 0, rect and rect.w or cw
        copy.pos.x = rx + rw - 1 - (copy.pos.x - rx)
    end
    if outside then
        -- a tap beside the column counts as a tap outside the overlay
        copy.pos.x = -1
        copy.pos.y = -1
    end
    return copy
end

-- Makes `class` paint into the centred column and shifts its gestures into the
-- column's own coordinate system. `self.x0` / `self.cw` are set by the widget.
-- With `mirror`, right-to-left languages get a mirrored overlay.
function Column.install(class, handlers, mirror)
    local paint = class.paintTo
    class.paintTo = function(self, bb, x, y)
        local x0 = self.x0 or 0
        -- The view is one pixel wider than the column: KOReader's blitbuffer fills a
        -- rectangle that is exactly as wide as its buffer in one go, ignoring the row
        -- stride of a view, and that would spill into the neighbouring rows.
        local target = x0 > 0 and bb:viewport(x0, 0, math.min(self.cw + 1, bb:getWidth() - x0), bb:getHeight()) or bb
        local px, py = x0 > 0 and 0 or x, x0 > 0 and 0 or y
        if mirror and Mirror.active() then
            local rect = self.mirrorRect and self:mirrorRect()
            return Mirror.paint(target, function(off) return paint(self, off, px, py) end, rect)
        end
        return paint(self, target, px, py)
    end
    for _i, name in ipairs(handlers) do
        local handler = class[name]
        if handler then
            class[name] = function(self, ev, ges)
                return handler(self, ev, shifted(self, ges, mirror))
            end
        end
    end
end

return {
    Column = Column,
    Mirror = Mirror,
    State = State,
    U = Units,
    Paint = Paint,
    Fonts = KindleFonts,
    Divider = Divider,
    Gray = Gray,
    Progress = Progress,
    Dates = Dates,
    Airplane = Airplane,
    Navigation = Navigation,
    Rotation = Rotation,
    Highlights = Highlights,
}
