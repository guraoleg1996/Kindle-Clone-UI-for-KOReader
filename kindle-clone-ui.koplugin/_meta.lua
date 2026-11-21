local root = debug.getinfo(1, "S").source:match("^@(.*)/_meta%.lua$")
local ok, I18n = pcall(dofile, (root or ".") .. "/kcui/i18n.lua")
local _ = ok and I18n.gettext or require("gettext")
return {
    fullname = _("Kindle Clone UI"),
    description = _([[Makes KOReader look and act like a Kindle. Different plugin than KindleUI, KindleCloneUI tries to be exactly like Kindle with minor changes.]]),
    version = "1.3.7",
}
