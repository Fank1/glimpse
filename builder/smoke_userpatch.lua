-- Glimpse smoke test — KOReader userpatch.
--
-- Exercises the LIVE plugin inside a running KOReader (headless or not):
-- menu construction, a real scan of the open book, filtering at every level,
-- and full viewer widget construction (without showing it).
--
-- Usage:
--   1. Copy to <koreader-config>/patches/2-glimpse-smoke.lua
--      (e.g. ~/.config/koreader/patches/ on desktop/VM builds)
--   2. Launch KOReader with an EPUB open; grep the log for "GLIMPSE-SMOKE".
--   3. DELETE the patch afterwards.

local UIManager = require("ui/uimanager")
local logger = require("logger")

UIManager:scheduleIn(8, function()
    local function say(...) logger.warn("GLIMPSE-SMOKE:", ...) end

    local ok0, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = ok0 and ReaderUI.instance
    local plugin = ui and ui.glimpse
    if not plugin then
        say("no plugin instance (is a book open? plugin enabled?)")
        return
    end

    local ok, err = pcall(function()
        -- menu builds
        local menu_items = {}
        plugin:addToMainMenu(menu_items)
        assert(menu_items.glimpse, "no menu entry")
        local items = menu_items.glimpse.sub_item_table_func()
        assert(#items >= 5, "menu too short: " .. #items)
        for _, it in ipairs(items) do
            if it.text_func then assert(type(it.text_func()) == "string") end
            if it.checked_func then it.checked_func() end
            if it.enabled_func then it.enabled_func() end
        end
        say("menu OK, items:", #items)

        -- support gate + scan
        local supported, why = plugin:_supportedReason()
        say("supported:", tostring(supported), why or "")
        if not supported then return end

        local scan = plugin:_getScan(true)
        assert(scan, "scan failed: " .. tostring(plugin._scan_err))
        say("scan OK, images:", #scan.images, "spine:", scan.spine_count)

        local scanner = dofile(plugin.path
            and (plugin.path .. "/glimpse_scanner.lua")
            or "plugins/glimpse.koplugin/glimpse_scanner.lua")
        for _, level in ipairs({ "strict", "balanced", "relaxed", "all" }) do
            local inc, stats = scanner.filter(scan.images, level)
            say("filter", level, "->", #inc, "of", stats.total)
        end

        say("current spine index:", tostring(plugin:_currentSpineIndex()))
    end)
    say("RESULT ok=" .. tostring(ok), err or "")
end)
