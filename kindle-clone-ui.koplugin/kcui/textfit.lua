-- Перенос короткого текста пункта меню на несколько строк (вместо обрезки многоточием).
--
-- Модуль ничего не знает про KOReader: ширину текста ему даёт функция measure(строка),
-- поэтому его можно проверять отдельно (см. тест в отчёте). Работает с UTF-8:
--  * обычный текст переносится по пробелам;
--  * китайский / японский / корейский (между словами нет пробелов) — по знакам;
--  * слово, которое само длиннее строки, режется по буквам.

local TextFit = {}

-- Разбивает строку на символы UTF-8.
local function chars(text)
    local out = {}
    for ch in text:gmatch("[\1-\127\194-\244][\128-\191]*") do
        out[#out + 1] = ch
    end
    return out
end

local function codepoint(ch)
    local b1, b2, b3 = ch:byte(1, 3)
    if not b1 then return 0 end
    if b1 < 0x80 then return b1 end
    if b1 < 0xE0 then return (b1 - 0xC0) * 64 + ((b2 or 0x80) - 0x80) end
    if b1 < 0xF0 then return (b1 - 0xE0) * 4096 + ((b2 or 0x80) - 0x80) * 64 + ((b3 or 0x80) - 0x80) end
    return 0x10000
end

-- Знаки, после каждого из которых можно перенести строку (пробелов между словами нет).
local function breakable(cp)
    return (cp >= 0x2E80 and cp <= 0x9FFF)   -- иероглифы, кана, знаки CJK
        or (cp >= 0xAC00 and cp <= 0xD7AF)   -- корейский
        or (cp >= 0xF900 and cp <= 0xFAFF)
        or (cp >= 0xFF00 and cp <= 0xFFEF)   -- полноширинные знаки
        or cp >= 0x20000
end

-- Знаки, которые нельзя оставлять в начале новой строки (точка, запятая, закрывающая скобка).
local CLOSING = {
    [0x3001] = true, [0x3002] = true, [0x300D] = true, [0x300F] = true, [0x3011] = true,
    [0xFF01] = true, [0xFF09] = true, [0xFF0C] = true, [0xFF0E] = true, [0xFF1A] = true,
    [0xFF1B] = true, [0xFF1F] = true,
}

-- Список «кусочков»: слово с пробелом после него, либо один знак CJK.
function TextFit.tokens(text)
    local tokens, cur = {}, ""
    for _i, ch in ipairs(chars(text)) do
        local cp = codepoint(ch)
        if ch == " " then
            tokens[#tokens + 1] = cur .. ch
            cur = ""
        elseif breakable(cp) then
            if CLOSING[cp] then
                if cur ~= "" then
                    cur = cur .. ch
                elseif #tokens > 0 then
                    tokens[#tokens] = tokens[#tokens] .. ch
                else
                    cur = ch
                end
            else
                if cur ~= "" then
                    tokens[#tokens + 1] = cur
                    cur = ""
                end
                tokens[#tokens + 1] = ch
            end
        else
            cur = cur .. ch
        end
    end
    if cur ~= "" then tokens[#tokens + 1] = cur end
    return tokens
end

local function trim(s)
    return (s:gsub("%s+$", ""))
end

-- Делит text на строки шириной не больше cap (ширину считает measure).
-- Строк не больше max_lines: всё, что не поместилось, остаётся в последней строке.
-- Возвращает список строк и признак truncated — последняя строка всё ещё шире cap
-- (тогда её придётся обрезать).
function TextFit.wrap(text, measure, cap, max_lines)
    local tokens = TextFit.tokens(text)
    local lines, line = {}, ""
    local i = 1
    while i <= #tokens do
        local token = tokens[i]
        if measure(trim(line .. token)) <= cap then
            line = line .. token
            i = i + 1
        elseif #lines >= max_lines - 1 then
            break -- последняя разрешённая строка: остаток уйдёт в неё целиком
        elseif line ~= "" then
            lines[#lines + 1] = trim(line)
            line = ""
        else
            -- одно слово длиннее строки: режем по буквам
            local cs, piece, used = chars(token), "", 0
            for k, ch in ipairs(cs) do
                if piece == "" or measure(piece .. ch) <= cap then
                    piece = piece .. ch
                    used = k
                else
                    break
                end
            end
            lines[#lines + 1] = piece
            tokens[i] = table.concat(cs, "", used + 1)
            if tokens[i] == "" then i = i + 1 end
        end
    end
    local last = trim(line .. table.concat(tokens, "", i))
    if last ~= "" or #lines == 0 then
        lines[#lines + 1] = last
    end
    return lines, measure(lines[#lines]) > cap
end

return TextFit
