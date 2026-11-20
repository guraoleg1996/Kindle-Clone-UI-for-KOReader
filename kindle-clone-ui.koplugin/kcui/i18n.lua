-- Self-contained localization for Kindle Clone UI.
--
-- Every text of the plugin is translated by its own catalogs in kcui/l10n/<language>.lua
-- (one file per KOReader interface language), so the plugin looks right even when
-- KOReader's own translation files do not know its strings. Whatever a catalog does
-- not contain falls back to KOReader's gettext and finally to the English original.
--
-- Besides the texts, a catalog carries the data needed to write a date in that
-- language: __months (full names, in the form used inside a date), __months_short
-- and __date / __date_short (patterns with {d} {month} {Y} placeholders).

local gettext = require("gettext")

local I18n = {}

local catalogs = {}   -- language code -> catalog table (false when there is none)

-- Catalogs are read by path, so this module also works where the plugin folder
-- is not on package.path yet (for example while KOReader reads _meta.lua).
local ROOT = debug.getinfo(1, "S").source:match("^@(.*)/kcui/i18n%.lua$")

local function load(code)
    if catalogs[code] ~= nil then return catalogs[code] end
    local ok, catalog
    if ROOT then
        ok, catalog = pcall(dofile, ROOT .. "/kcui/l10n/" .. code .. ".lua")
    else
        ok, catalog = pcall(require, "kcui/l10n/" .. code)
    end
    catalogs[code] = ok and type(catalog) == "table" and catalog or false
    return catalogs[code]
end

-- The code of the language KOReader currently uses ("C" is English).
function I18n.lang()
    return gettext.current_lang or "C"
end

-- Catalog of the current language; "ru_RU" also tries "ru".
local function catalog()
    local code = I18n.lang()
    if code == "C" or code == "en" then return nil end
    return load(code) or load(code:match("^(%a+)_") or code) or nil
end

local function translate(ctx, msgid)
    local cat = catalog()
    if cat then
        local key = ctx and (ctx .. "\004" .. msgid) or msgid
        local text = cat[key]
        if text and text ~= "" then return text end
    end
    if ctx then return gettext.pgettext(ctx, msgid) end
    return gettext(msgid)
end

-- Plural texts. A catalog lists the forms of a text in __plurals[singular]; with a
-- single form that form is used for every number (e.g. "Items: %1"), otherwise the
-- form is picked with KOReader's plural rule of the current language.
local function plural(msgid, msgid_plural, n)
    local cat = catalog()
    local forms = cat and cat.__plurals and cat.__plurals[msgid]
    if forms and #forms > 0 then
        local index = #forms == 1 and 1 or ((gettext.getPlural(n) or 0) + 1)
        local text = forms[index] or forms[#forms]
        if text and text ~= "" then return text end
    end
    return gettext.ngettext(msgid, msgid_plural, n)
end

I18n.gettext = setmetatable({
    pgettext = function(ctx, msgid) return translate(ctx, msgid) end,
    ngettext = plural,
}, {
    __call = function(_self, msgid) return translate(nil, msgid) end,
})

function I18n.pgettext(ctx, msgid)
    return translate(ctx, msgid)
end

-- Тексты самого KOReader (меню «Строка состояния» и т.п.), которых нет в его переводе
-- на этот язык и которые поэтому остаются английскими: ищем их в каталоге плагина.
-- Работает и для текстов с подставленными значениями: «Font size: 36» находится
-- по шаблону «Font size: %1», а в переводе значение ставится на место %1.
-- Если у KOReader перевод есть, текст уже не английский, ничего не находится и он остаётся как был.
local native_templates = {} -- код языка -> список шаблонов

local function templatesOf(cat, code)
    local list = native_templates[code]
    if list then return list end
    list = {}
    for key, value in pairs(cat) do
        if type(key) == "string" and type(value) == "string" and value ~= ""
                and key:find("%%%d") and not key:find("\004", 1, true) then
            local order = {}
            local escaped = key:gsub("[%^%$%(%)%.%[%]%*%+%-%?%%]", "%%%0")
            local pattern = "^" .. escaped:gsub("%%%%(%d)", function(n)
                order[#order + 1] = tonumber(n)
                return "(.-)"
            end) .. "$"
            list[#list + 1] = { pattern = pattern, order = order, text = value, size = #key,
                leading = key:find("^%%%d") ~= nil }
        end
    end
    table.sort(list, function(a, b) return a.size > b.size end)
    native_templates[code] = list
    return list
end

-- Украшения, которые KOReader дописывает к тексту пункта: галочка «✓», многоточие,
-- пробелы и невидимые метки направления письма. Перевод ищется для самого текста
-- без них, а потом они возвращаются на место («Reading  ✓» -> «Читаю  ✓»).
local DECOR = {
    "\226\156\147",                                   -- ✓
    "\226\128\166", "...",                            -- … и ...
    "\226\128\142", "\226\128\143",                  -- LRM, RLM
    "\226\128\170", "\226\128\171", "\226\128\172", "\226\128\173", "\226\128\174",
    "\226\129\166", "\226\129\167", "\226\129\168", "\226\129\169",
    "\194\160", " ", "\t",
}

local function peelDecor(text)
    local lead, trail = "", ""
    local changed = true
    while changed and #text > 0 do
        changed = false
        for _i, token in ipairs(DECOR) do
            local n = #token
            if #text > n and text:sub(1, n) == token then
                lead = lead .. token
                text = text:sub(n + 1)
                changed = true
            end
            if #text > n and text:sub(-n) == token then
                trail = token .. trail
                text = text:sub(1, #text - n)
                changed = true
            end
        end
    end
    return lead, text, trail
end

function I18n.native(text, _decor_done)
    if type(text) ~= "string" or text == "" then return text end
    local cat = catalog()
    if not cat then return text end
    local direct = cat[text]
    if type(direct) == "string" and direct ~= "" then return direct end
    if not _decor_done then
        local lead, core, trail = peelDecor(text)
        if core ~= text and core ~= "" then
            local translated = I18n.native(core, true)
            if translated ~= core then return lead .. translated .. trail end
        end
    end
    for _i, template in ipairs(templatesOf(cat, I18n.lang())) do
        local found = { text:match(template.pattern) }
        -- Шаблон, который начинается с подстановки («%1 selected»), подходит только к короткому
        -- значению без пробелов (число, «Dot»): иначе он ломает длинные английские фразы.
        if #found > 0 and template.leading and (found[1] == "" or found[1]:find("%s")) then found = {} end
        if #found > 0 then
            return (template.text:gsub("%%(%d)", function(n)
                for index, number in ipairs(template.order) do
                    -- подставляемое значение тоже переводим («Dot (·)» в «Item separator: %1»)
                    if number == tonumber(n) then return I18n.native(found[index]) end
                end
            end))
        end
    end
    return text
end

-- Languages written right to left (the interface is mirrored for them).
function I18n.rtl()
    local ok, BD = pcall(require, "ui/bidi")
    return ok and BD.mirroredUILayout() or false
end

-- Scripts that stay readable only at larger sizes: text in them may shrink less.
local SMALLEST_RATIO = {
    ja = 0.86, zh_CN = 0.86, zh_TW = 0.86, ko_KR = 0.86,
    ar = 0.82, fa = 0.82, he = 0.84, hi = 0.84, ka = 0.84, el = 0.8,
}

-- How far a single line of text may shrink (fraction of its normal size) before
-- it is shortened with an ellipsis or wrapped instead.
function I18n.minRatio()
    return SMALLEST_RATIO[I18n.lang()] or SMALLEST_RATIO[(I18n.lang():match("^(%a+)_") or "")] or 0.72
end

-- English fallbacks for dates.
local EN_MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }
local EN_SHORT = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- "November 11, 2026" in the current language; short = abbreviated month.
function I18n.date(seconds, short)
    local t = os.date("*t", seconds)
    local cat = catalog()
    local months = cat and (short and cat.__months_short or cat.__months) or (short and EN_SHORT or EN_MONTHS)
    local pattern = cat and (short and cat.__date_short or cat.__date) or "{month} {d}, {Y}"
    local text = pattern
        :gsub("{month}", function() return months[t.month] end)
        :gsub("{d}", function() return tostring(t.day) end)
        :gsub("{Y}", function() return tostring(t.year) end)
    return text
end

return I18n
