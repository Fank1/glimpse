--[[--
Glimpse: peek at maps, family trees and other reference images from anywhere
in the book, without losing your reading position.

EPUB-only (crengine): the book's HTML is parsed directly (see
glimpse_scanner.lua), which gives real pixel dimensions plus captions/alt
text for filtering out ornaments and icons.
]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageViewer = require("ui/widget/imageviewer")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local LuaSettings = require("luasettings")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Notification = require("ui/widget/notification")
local OverlapGroup = require("ui/widget/overlapgroup")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

-- Plugin-local module (package.path for plugins is not guaranteed while our
-- own plugin is being loaded, and "scanner" would be a collision-prone name).
local _PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("@?(.*)/[^/]*$") or "."
local scanner
do
    local ok, mod = pcall(dofile, _PLUGIN_DIR .. "/glimpse_scanner.lua")
    if ok then scanner = mod end
end

local SCOPE_KEY = "glimpse_scope"    -- "read_so_far" | "whole_book"
-- "all" = filtering off; anything else = the built-in "balanced" scanner
-- level. (The scanner still knows strict/relaxed internally, but they are
-- not exposed: corpus analysis showed strict silently drops real figures
-- and the level choice mostly created confusion.)
local FILTER_KEY = "glimpse_filter"
-- Invert images while night mode is on (global setting).
local INVERT_KEY = "glimpse_invert_night"
local NAV_BUTTONS_KEY = "glimpse_nav_buttons" -- prev/next buttons, off by default
local CAPTIONS_KEY = "glimpse_captions"        -- caption overlay, ON by default (nilOrTrue)

-- ── overlay chrome: dot pill and ⋯ button (from the Figma design) ──────────

-- Anti-aliased filled circle blending fg over bg by edge coverage
-- (paintCircle is hard-edged and looks jagged at dot sizes). All chrome is
-- drawn black-on-white; night mode inverts the framebuffer for free, which
-- yields the design's dark variant (outlined pill, white dialog ring).
local function paint_dot(bb, cx, cy, r, fg, bg)
    for dy = -r - 1, r + 1 do
        for dx = -r - 1, r + 1 do
            local cov = r - math.sqrt(dx * dx + dy * dy) + 0.5
            if cov > 0 then
                if cov > 1 then cov = 1 end
                local v = math.floor(bg + cov * (fg - bg) + 0.5)
                bb:paintRect(cx + dx, cy + dy, 1, 1, Blitbuffer.Color8(v))
            end
        end
    end
end

-- One dot per image, drawn on the pill's black background: current one
-- white, the others 40% white (per the design SVG — same size, dimmed).
-- `pitch` is set by the caller from the space actually available between
-- the chrome buttons (so more images stay dots before the "n / N"
-- fallback kicks in).
local GlimpseDots = Widget:extend{
    nb = 1,
    cur = 1,
    dot_r = Screen:scaleBySize(3),
    pitch = Screen:scaleBySize(11),
    height = Screen:scaleBySize(10),
}

function GlimpseDots:getSize()
    return Geom:new{
        w = (self.nb - 1) * self.pitch + 2 * self.dot_r,
        h = self.height,
    }
end

function GlimpseDots:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self:getSize().w, h = self.height }
    local cy = y + math.floor(self.height / 2)
    local x0 = x + self.dot_r
    for i = 1, self.nb do
        local cx = x0 + (i - 1) * self.pitch
        paint_dot(bb, cx, cy, self.dot_r, i == self.cur and 0xFF or 0x66, 0x00)
    end
end

-- The ⋯ icon for the more button, drawn as three dots (font-independent).
local GlimpseEllipsis = Widget:extend{
    size = Screen:scaleBySize(18),
}

function GlimpseEllipsis:getSize()
    return Geom:new{ w = self.size, h = self.size }
end

function GlimpseEllipsis:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.size, h = self.size }
    local r = math.max(2, math.floor(self.size / 9))
    local cx = x + math.floor(self.size / 2)
    local cy = y + math.floor(self.size / 2)
    paint_dot(bb, cx - 3 * r, cy, r, 0x00, 0xFF)
    paint_dot(bb, cx, cy, r, 0x00, 0xFF)
    paint_dot(bb, cx + 3 * r, cy, r, 0x00, 0xFF)
end

-- Per-pixel-alpha BBRGB32 stencil of a rounded rectangle with an
-- anti-aliased `stroke`-wide outline; `fill` and `outline` are 0–255
-- grays. Alpha-blitting this paints smooth rounded shapes over any
-- background — FrameContainer radii are hard-edged and look jagged at
-- chrome sizes. r = h/2 gives a stadium.
local function make_rounded_stencil(w, h, r, stroke, fill, outline)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    for py = 0, h - 1 do
        for px = 0, w - 1 do
            local sx = math.min(math.max(px + 0.5, r), w - r)
            local sy = math.min(math.max(py + 0.5, r), h - r)
            local dx, dy = px + 0.5 - sx, py + 0.5 - sy
            local d = math.sqrt(dx * dx + dy * dy)
            local cov = math.min(math.max(r - d + 0.5, 0), 1)
            if cov > 0 then
                local t_in = math.min(math.max((r - stroke) - d + 0.5, 0), 1)
                local g = math.floor(outline + t_in * (fill - outline) + 0.5)
                bb:setPixel(px, py,
                    Blitbuffer.ColorRGB32(g, g, g, math.floor(cov * 255 + 0.5)))
            end
        end
    end
    return bb
end

-- The stadium-shaped pill behind the dots / "n / N" counter. Default is
-- the design's black fill + 2px white stroke (keeps the dots legible over
-- dark images). `inverted` flips it to a white fill + black stroke: used
-- for the "n / N" text fallback, which as a solid black block with white
-- text drew far more attention than the light dots pill it replaces.
local GlimpsePill = WidgetContainer:extend{
    inner = nil, -- content, centered
    padding_h = Screen:scaleBySize(9),
    height = Screen:scaleBySize(21),
    stroke = Screen:scaleBySize(2),
    inverted = nil,
}

function GlimpsePill:init()
    self[1] = self.inner
end

function GlimpsePill:getSize()
    local inner = self.inner:getSize()
    return Geom:new{
        w = inner.w + 2 * self.padding_h,
        h = math.max(self.height, inner.h),
    }
end

function GlimpsePill:paintTo(bb, x, y)
    local size = self:getSize()
    local w, h = size.w, size.h
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
    if not self._bg_bb or self._bg_w ~= w or self._bg_h ~= h then
        if self._bg_bb then self._bg_bb:free() end
        local fill = self.inverted and 0xFF or 0x00
        local outline = self.inverted and 0x00 or 0xFF
        self._bg_bb = make_rounded_stencil(w, h, h / 2, self.stroke, fill, outline)
        self._bg_w, self._bg_h = w, h
    end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, w, h)
    local inner_size = self.inner:getSize()
    self.inner:paintTo(bb,
        x + math.floor((w - inner_size.w) / 2),
        y + math.floor((h - inner_size.h) / 2))
end

function GlimpsePill:free(...)
    if self._bg_bb then
        self._bg_bb:free()
        self._bg_bb = nil
    end
    WidgetContainer.free(self, ...)
end

-- The ⋯ button: solid white rounded square with an anti-aliased 2px black
-- border, so it stays visible over any image. `disabled` grays the border
-- and icon (used by prev/next at the ends of the image list); `inverted`
-- is the pressed state.
local GlimpseMoreButton = Widget:extend{
    size = Screen:scaleBySize(40),
    radius = Screen:scaleBySize(8),
    stroke = Screen:scaleBySize(2),
    icon = nil,                          -- SVG path; nil draws the ⋯ glyph
    icon_size = Screen:scaleBySize(18),
    disabled = nil,
    disabled_gray = 0xB4,                -- border/icon gray when disabled
}

function GlimpseMoreButton:getSize()
    return Geom:new{ w = self.size, h = self.size }
end

function GlimpseMoreButton:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.size, h = self.size }
    if not self._bg_bb then
        self._bg_bb = make_rounded_stencil(self.size, self.size,
            self.radius, self.stroke, 0xFF,
            self.disabled and self.disabled_gray or 0x00)
    end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, self.size, self.size)
    -- icon: an SVG (chevrons for prev/next) or the default ⋯ glyph
    if self.icon and not self._icon_bb then
        local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
            self.icon, self.icon_size, self.icon_size)
        if ok and ibb then
            if self.disabled then
                -- lift the black strokes to gray, keeping the AA alpha
                local g = self.disabled_gray
                for yy = 0, ibb:getHeight() - 1 do
                    for xx = 0, ibb:getWidth() - 1 do
                        local c = ibb:getPixel(xx, yy):getColorRGB32()
                        if c.alpha > 0 then
                            ibb:setPixel(xx, yy,
                                Blitbuffer.ColorRGB32(g, g, g, c.alpha))
                        end
                    end
                end
            end
            self._icon_bb = ibb
        end
    end
    if self._icon_bb then
        bb:alphablitFrom(self._icon_bb,
            x + math.floor((self.size - self.icon_size) / 2),
            y + math.floor((self.size - self.icon_size) / 2),
            0, 0, self._icon_bb:getWidth(), self._icon_bb:getHeight())
    else
        if not self._icon then
            self._icon = GlimpseEllipsis:new{}
        end
        local isz = self._icon:getSize()
        self._icon:paintTo(bb,
            x + math.floor((self.size - isz.w) / 2),
            y + math.floor((self.size - isz.h) / 2))
    end
    if self.inverted then
        -- pressed state: invert the rendered button, but only within its
        -- rounded silhouette (the stencil's alpha) — a square invertRect
        -- would flip the image corners outside the radius too
        for yy = 0, self.size - 1 do
            for xx = 0, self.size - 1 do
                local a = self._bg_bb:getPixel(xx, yy):getColorRGB32().alpha
                if a > 127 then
                    bb:setPixel(x + xx, y + yy,
                        bb:getPixel(x + xx, y + yy):getColorRGB32():invert())
                end
            end
        end
    end
end

function GlimpseMoreButton:free()
    if self._bg_bb then
        self._bg_bb:free()
        self._bg_bb = nil
    end
    if self._icon_bb then
        self._icon_bb:free()
        self._icon_bb = nil
    end
end

-- Caption overlay: white text with a 2px black outline (offset copies of
-- the text in black under a white copy), so it stays readable over any
-- image. Painted in day polarity — night mode's inversion turns it into
-- black text with a white outline, per the design. Truncates to max_width.
local GlimpseCaption = Widget:extend{
    text = "",
    max_width = 0,
    outline = 2,
}

function GlimpseCaption:init()
    local face = Font:getFace("cfont", 14)
    self._black = TextWidget:new{
        text = self.text, face = face, bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK, max_width = self.max_width,
    }
    self._white = TextWidget:new{
        text = self.text, face = face, bold = true,
        fgcolor = Blitbuffer.COLOR_WHITE, max_width = self.max_width,
    }
end

function GlimpseCaption:getSize()
    local s = self._white:getSize()
    return Geom:new{ w = s.w + 2 * self.outline, h = s.h + 2 * self.outline }
end

function GlimpseCaption:paintTo(bb, x, y)
    local o = self.outline
    self.dimen = self:getSize()
    self.dimen.x, self.dimen.y = x, y
    -- step 1 (not o): every offset within the radius, so a 2px outline
    -- has no gaps at the ±1 ring
    for dy = -o, o do
        for dx = -o, o do
            if dx ~= 0 or dy ~= 0 then
                self._black:paintTo(bb, x + o + dx, y + o + dy)
            end
        end
    end
    self._white:paintTo(bb, x + o, y + o)
end

function GlimpseCaption:free()
    self._black:free()
    self._white:free()
end

-- A pill-shaped text button in the SAME style as the ⋯ button: solid white
-- rounded rectangle, anti-aliased 2px black border, black text — and the
-- same height, so the two read as one control set. An optional black-line
-- SVG icon sits to the left of the text. Width fits its contents.
local GlimpseTextButton = Widget:extend{
    text = "",
    bold = false,
    icon = nil,                          -- absolute path to an SVG, or nil
    icon_size = Screen:scaleBySize(16),
    icon_gap = Screen:scaleBySize(7),
    height = Screen:scaleBySize(40),
    radius = Screen:scaleBySize(8),
    stroke = Screen:scaleBySize(2),
    padding_h = Screen:scaleBySize(14),
    inverted = nil,                      -- pressed state, see paintTo
}

function GlimpseTextButton:init()
    self._text_wg = TextWidget:new{
        text = self.text,
        face = Font:getFace("cfont", 15),
        bold = self.bold,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local content_w = self._text_wg:getSize().w
    if self.icon then
        -- render once; a black-line SVG on transparent, alpha-blitted so
        -- it inherits the white button (and night-mode inversion) like text
        local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
            self.icon, self.icon_size, self.icon_size)
        if ok and ibb then
            self._icon_bb = ibb
            content_w = content_w + self.icon_size + self.icon_gap
        end
    end
    self._w = content_w + 2 * self.padding_h
end

function GlimpseTextButton:getSize()
    return Geom:new{ w = self._w, h = self.height }
end

function GlimpseTextButton:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self._w, h = self.height }
    if not self._bg_bb then
        self._bg_bb = make_rounded_stencil(self._w, self.height,
            self.radius, self.stroke, 0xFF, 0x00)
    end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, self._w, self.height)
    local tsz = self._text_wg:getSize()
    local icon_w = self._icon_bb and (self.icon_size + self.icon_gap) or 0
    local cx = x + math.floor((self._w - icon_w - tsz.w) / 2)
    if self._icon_bb then
        bb:alphablitFrom(self._icon_bb, cx,
            y + math.floor((self.height - self.icon_size) / 2),
            0, 0, self._icon_bb:getWidth(), self._icon_bb:getHeight())
        cx = cx + self.icon_size + self.icon_gap
    end
    self._text_wg:paintTo(bb, cx, y + math.floor((self.height - tsz.h) / 2))
    if self.inverted then
        -- pressed state: invert within the rounded silhouette only (the
        -- stencil's alpha), same trick as GlimpseMoreButton
        for yy = 0, self.height - 1 do
            for xx = 0, self._w - 1 do
                local a = self._bg_bb:getPixel(xx, yy):getColorRGB32().alpha
                if a > 127 then
                    bb:setPixel(x + xx, y + yy,
                        bb:getPixel(x + xx, y + yy):getColorRGB32():invert())
                end
            end
        end
    end
end

function GlimpseTextButton:free()
    if self._bg_bb then
        self._bg_bb:free()
        self._bg_bb = nil
    end
    if self._icon_bb then
        self._icon_bb:free()
        self._icon_bb = nil
    end
    if self._text_wg then
        self._text_wg:free()
    end
end

-- One row of the ⋯ popup: an optional left icon (black-line SVG on
-- transparent, alpha-blitted so it inherits the white row and night-mode
-- inversion like the text) then the label, both left-aligned. The icon
-- column is reserved for every row when ANY row has an icon, so labels
-- line up whether or not their row carries one. Painting-only; the parent
-- menu does hit-testing off self.dimen.
local GlimpseMenuRow = Widget:extend{
    text = "",
    icon_bb = nil,      -- pre-rendered icon blitbuffer, or nil
    lead_wg = nil,      -- widget drawn in the icon column instead (checkbox)
    width = 0,          -- shared row width (set by the menu)
    height = Screen:scaleBySize(44),
    icon_col = 0,       -- reserved icon+gap width (0 if no row has an icon)
    icon_size = Screen:scaleBySize(18),
    pad_left = Screen:scaleBySize(16),
}

function GlimpseMenuRow:init()
    self._text_wg = TextWidget:new{
        text = self.text,
        face = Font:getFace("cfont", 15),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
end

function GlimpseMenuRow:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function GlimpseMenuRow:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    -- icon column: an SVG icon, or a lead widget (checkbox glyph), centred
    if self.icon_bb then
        bb:alphablitFrom(self.icon_bb,
            x + self.pad_left + math.floor((self.icon_size - self.icon_bb:getWidth()) / 2),
            y + math.floor((self.height - self.icon_bb:getHeight()) / 2),
            0, 0, self.icon_bb:getWidth(), self.icon_bb:getHeight())
    elseif self.lead_wg then
        local lsz = self.lead_wg:getSize()
        self.lead_wg:paintTo(bb,
            x + self.pad_left + math.floor((self.icon_size - lsz.w) / 2),
            y + math.floor((self.height - lsz.h) / 2))
    end
    local tsz = self._text_wg:getSize()
    self._text_wg:paintTo(bb,
        x + self.pad_left + self.icon_col,
        y + math.floor((self.height - tsz.h) / 2))
end

function GlimpseMenuRow:free()
    if self._text_wg then self._text_wg:free() end
    if self.lead_wg then self.lead_wg:free() end
end

-- A small popup menu of icon+text rows, anchored to a widget (the ⋯
-- button). White rounded card with a thin border, gray separators between
-- rows; tap a row to fire its callback, tap outside to dismiss. Built in
-- our own style instead of ButtonDialog because a ButtonDialog button
-- shows an icon OR text, never both.
local GlimpsePopupMenu = InputContainer:extend{
    items = nil,    -- { {text=, icon=<svg path or nil>, callback=}, ... }
    anchor = nil,   -- function -> Geom (like MovableContainer's anchor)
    pad_left = Screen:scaleBySize(16),
    pad_right = Screen:scaleBySize(16),
    icon_size = Screen:scaleBySize(18),
    icon_gap = Screen:scaleBySize(12),
    row_h = Screen:scaleBySize(44),
}

function GlimpsePopupMenu:init()
    self._icon_bbs = {}
    local any_lead = false
    for _, it in ipairs(self.items) do
        if it.icon or it.check ~= nil then any_lead = true break end
    end
    local icon_col = any_lead and (self.icon_size + self.icon_gap) or 0

    -- widest label decides the shared row width
    local max_text_w = 0
    local probes = {}
    for i, it in ipairs(self.items) do
        local wg = TextWidget:new{
            text = it.text, face = Font:getFace("cfont", 15), bold = true,
        }
        probes[i] = wg
        max_text_w = math.max(max_text_w, wg:getSize().w)
    end
    for _, wg in ipairs(probes) do wg:free() end
    local row_w = self.pad_left + icon_col + max_text_w + self.pad_right

    self._rows = {}
    local vg = VerticalGroup:new{ align = "left" }
    for i, it in ipairs(self.items) do
        local icon_bb, lead_wg
        if it.icon then
            local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
                it.icon, self.icon_size, self.icon_size)
            if ok and ibb then
                icon_bb = ibb
                self._icon_bbs[#self._icon_bbs + 1] = ibb
            end
        elseif it.check ~= nil then
            -- checkbox glyph, a bit larger than the label, drawn in the
            -- icon column so it aligns with the other rows' icons
            lead_wg = TextWidget:new{
                text = it.check and "☑" or "☐",
                face = Font:getFace("cfont", 22),
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
        end
        local row = GlimpseMenuRow:new{
            text = it.text, icon_bb = icon_bb, lead_wg = lead_wg, width = row_w,
            height = self.row_h, icon_col = icon_col,
            icon_size = self.icon_size, pad_left = self.pad_left,
        }
        row._callback = it.callback
        self._rows[#self._rows + 1] = row
        table.insert(vg, row)
        if i < #self.items then
            table.insert(vg, LineWidget:new{
                background = Blitbuffer.COLOR_GRAY,
                dimen = Geom:new{ w = row_w, h = Screen:scaleBySize(1) },
            })
        end
    end

    self.movable = MovableContainer:new{
        anchor = self.anchor,
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Screen:scaleBySize(2),
            radius = Screen:scaleBySize(9),
            padding = 0,
            margin = 0,
            vg,
        },
    }
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.movable,
    }
    if Device:isTouchDevice() then
        self.ges_events.Tap = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0,
                    w = Screen:getWidth(), h = Screen:getHeight() },
            },
        }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
end

-- The widget's own dimen is the full screen (CenterContainer), so default
-- show/close refreshes would flash the whole drawer; refresh only the
-- anchored menu rectangle instead (known after MovableContainer paints).
function GlimpsePopupMenu:dismiss()
    local region = self.movable.dimen
    if region and self._restore_region then
        region = region:combine(self._restore_region)
    end
    UIManager:close(self, "ui", region)
end

function GlimpsePopupMenu:onTap(_, ges)
    for _, row in ipairs(self._rows) do
        if row.dimen and ges.pos:intersectWith(row.dimen) then
            local cb = row._callback
            self:dismiss()
            if cb then cb() end
            return true
        end
    end
    -- tapped a separator or outside: dismiss
    self:dismiss()
    return true
end

function GlimpsePopupMenu:onClose()
    self:dismiss()
    return true
end

function GlimpsePopupMenu:onCloseWidget()
    for _, ibb in ipairs(self._icon_bbs) do ibb:free() end
    self._icon_bbs = {}
    if self.on_dismiss then self.on_dismiss() end
end

-- ── viewer ──────────────────────────────────────────────────────────────────
-- ImageViewer already provides pan/zoom/rotate, multi-image lists with lazy
-- per-image render functions, captions and resource cleanup. We add:
--   * horizontal swipe switches images while in fit-to-screen mode
--     (when zoomed in, swipe keeps panning, as upstream)
--   * a dot indicator instead of the progress bar (as many dots as fit
--     between the chrome buttons; an "n / N" counter beyond that)
--   * a ⋯ overlay button with remove/rotate/invert actions
-- Layout (Figma "New Design", drawn at 630×730): a full-height drawer
-- anchored to the LEFT screen edge, ~80% of the screen wide, with a strip
-- of the page visible on the right. Square on the left (flush with the
-- edge), rounded on the right, 2px black border, and a soft black gradient
-- shadow cast to the right. The drawer is painted from a stencil in
-- _paintPanel (FrameContainer can't do per-corner radii).

local GlimpseViewer = ImageViewer:extend{
    image_metas = nil,     -- parallel to the image list: scanner records
    gallery_hidden_count = 0, -- images the chapter scope holds back (heading)
    on_image_shown = nil,  -- function(meta, index)
    on_hide = nil,         -- function(meta)
    on_show_in_book = nil, -- function(meta): jump the reader to the image
    on_rotate = nil,       -- function(rotation): re-layout + reopen
    get_pref = nil,        -- function(meta) -> per-image prefs {rotation=}
    set_pref = nil,        -- function(meta, key, value)
    -- gallery masonry (⋯ → Gallery): fixed-width columns, variable heights
    gallery_cols = 3,
    -- No title bar and no button row: everything is image. Position comes
    -- from the dot pill, actions from the ⋯ button, closing from
    -- tap-outside, multiswipe or Back.
    with_title_bar = false,
    -- Drawer metrics from the design (design px == px at the reference DPI)
    panel_ratio = 505 / 630,               -- of screen width
    panel_vgap = 0,                        -- full height, border included
    panel_border = Screen:scaleBySize(2),
    panel_radius = Screen:scaleBySize(24), -- right corners only
    -- gradient shadow: 50% black at its (covered) start, fading rightwards;
    -- the visible part beyond the panel edge starts around 25%
    shadow_width = Screen:scaleBySize(131),
    shadow_overlap = Screen:scaleBySize(66), -- part hidden under the panel
    -- gap between the image area and the panel's rounded right edge
    image_right_gap = Screen:scaleBySize(12),
    image_padding = Screen:scaleBySize(2),
    -- Numeric alpha in (0,1) makes UIManager:setDirty flag every window
    -- below us dirty too, so the translucent shadow always blends against a
    -- freshly painted page instead of accumulating over its own output.
    alpha = 0.25,
    -- Double-tap (toggle fit ↔ 2×) is detected manually from plain Tap
    -- events (see onTap/_checkDoubleTap): enabling the input layer's
    -- double-tap would delay EVERY tap ~300ms for disambiguation, making
    -- tap-outside-to-close and image switching feel sluggish — and it
    -- zoomed on double-taps outside the drawer. Must be an explicit true,
    -- not nil: UIManager restores the flag from the topmost widget with a
    -- non-nil field whenever a window above us closes, and if the user
    -- has double tap enabled reader-wide, ReaderUI's false would win and
    -- silently swallow our tap pairs into unhandled double_tap gestures.
    disable_double_tap = true,
}

function GlimpseViewer:init()
    self._cur_rotation = self:_prefFor(1).rotation or 0
    ImageViewer.init(self)
    self:_buildMoreButton()
    self:update()
end

-- Upstream ImageViewer:onShow() unconditionally queues its OWN "full"
-- flashing refresh of the whole widget — UIManager:show() fires the
-- Show event (which reaches this) immediately after enqueuing whatever
-- refresh WE explicitly asked for, so every open queued both: our
-- careful "ui" refresh (see showViewer) AND upstream's forced "full"
-- one, and the queue promotes the merged region to the more aggressive
-- "full" — flashing on every single open regardless of what we asked
-- for (2026-07-21, reported worst in Night Mode). No-op this instead;
-- showViewer already enqueues the one refresh we actually want.
function GlimpseViewer:onShow()
    return true
end

function GlimpseViewer:_prefFor(i)
    local meta = self.image_metas and self.image_metas[i]
    if meta and self.get_pref then
        return self.get_pref(meta) or {}
    end
    return {}
end

-- Forked from ImageViewer:update() (verified against current upstream):
-- same lifecycle, but the widget is a left-anchored drawer sized from
-- panel_ratio, and the dot pill and ⋯ button are OVERLAID on the image
-- instead of stacked below it.
function GlimpseViewer:update()
    self:_clean_image_wg()
    local orig_dimen = self.main_frame.dimen

    self._panel_w = math.floor(Screen:getWidth() * self.panel_ratio)
    self._panel_h = Screen:getHeight() - 2 * self.panel_vgap
    -- content area inside the drawer's border (top/right/bottom only — the
    -- left edge is borderless and flush with the screen); self.width/height
    -- are what the inherited zoom/pan code sizes the image against
    self.width = self._panel_w - self.panel_border
    self.height = self._panel_h - 2 * self.panel_border

    while table.remove(self.frame_elements) do end
    self.frame_elements:resetLayout()

    self.img_container_h = self.height
    if self._gallery_mode then
        self:_buildGallery()
    else
        self._gallery_cells = nil
        self:_new_image_wg()
    end
    self:_buildPill()

    local overlay = OverlapGroup:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        self.image_container,
    }
    -- chrome is centered/aligned on the image area (content minus the gap
    -- that keeps it clear of the rounded right edge), like the design
    local image_area_w = self.width - self.image_right_gap
    local btn_inset = Screen:scaleBySize(16)
    local btn_gap = Screen:scaleBySize(10)
    -- optional prev/next buttons: always shown while the toggle is on
    -- (zoomed too — switching lands the next image at fit); at the ends
    -- of the list the dead-end button stays visible but grayed out, so
    -- the layout never jumps. Next sits at the right edge; ⋯ moves left
    -- of it whenever the buttons are enabled.
    if self._nav_prev_frame then self._nav_prev_frame:free() end
    if self._nav_next_frame then self._nav_next_frame:free() end
    self._nav_prev_frame, self._nav_next_frame = nil, nil
    local nav = G_reader_settings:isTrue(NAV_BUTTONS_KEY)
        and self._images_list and (self._images_list_nb or 1) > 1
    local cur = self._images_list_cur or 1
    local nb = self._images_list_nb or 1
    if self._gallery_mode then
        -- gallery: the arrows page the grid and are its primary
        -- affordance, so they show regardless of the setting (hidden
        -- when everything fits on one page)
        nav = self:_galleryPages() > 1
        cur = self._gallery_page or 1
        nb = self:_galleryPages()
    end
    if self._close_frame then
        self._close_frame:free()
        self._close_frame = nil
    end
    if nav then
        self._nav_prev_frame = GlimpseMoreButton:new{
            icon = _PLUGIN_DIR .. "/assets/prev.svg",
            disabled = cur <= 1 or nil,
        }
        self._nav_prev_frame.overlap_offset = {
            Screen:scaleBySize(16),
            self.height - self._nav_prev_frame.size - btn_inset,
        }
        table.insert(overlay, self._nav_prev_frame)
        self._nav_next_frame = GlimpseMoreButton:new{
            icon = _PLUGIN_DIR .. "/assets/next.svg",
            disabled = cur >= nb or nil,
        }
        self._nav_next_frame.overlap_offset = {
            image_area_w - self._nav_next_frame.size,
            self.height - self._nav_next_frame.size - btn_inset,
        }
        table.insert(overlay, self._nav_next_frame)
    end
    -- ⋯ (single-image) / Back (gallery) both live at the BOTTOM row, just
    -- left of the next/page-forward button (or in that same slot when
    -- nav buttons are off) — kept out of the top strip entirely so it
    -- never competes with KOReader's own top-of-screen menu gesture.
    if self._gallery_mode then
        self._close_frame = GlimpseTextButton:new{
            text = _("Back"),
            bold = true,
            icon = _PLUGIN_DIR .. "/assets/back.svg",
        }
        local size = self._close_frame:getSize()
        local x = self._nav_next_frame
            and (self._nav_next_frame.overlap_offset[1] - btn_gap - size.w)
            or (image_area_w - size.w)
        self._close_frame.overlap_offset = {
            x,
            self.height - size.h - btn_inset,
        }
        table.insert(overlay, self._close_frame)
    elseif self._more_frame then
        local more_size = self._more_frame:getSize()
        local more_x = self._nav_next_frame
            and (self._nav_next_frame.overlap_offset[1] - btn_gap - more_size.w)
            or (image_area_w - more_size.w)
        self._more_frame.overlap_offset = {
            more_x,
            self.height - more_size.h - btn_inset,
        }
        table.insert(overlay, self._more_frame)
    end
    if self._pill_frame then
        local pill_size = self._pill_frame:getSize()
        -- the revert button is the same height as the ⋯ button, so share
        -- its bottom inset to sit on the same baseline; the shorter dots
        -- pill uses a larger inset so its centre still lines up
        local bottom_inset = self:_isOverFit()
            and btn_inset or Screen:scaleBySize(25)
        -- centre the pill in the span between whatever sits on its left
        -- (the Prev button, or the left inset) and the nearest right-side
        -- chrome (⋯ / Back / Next), so a wide dot row expands to fill that
        -- gap without ever overlapping a button
        local left_bound = Screen:scaleBySize(16)
        if self._nav_prev_frame and self._nav_prev_frame.overlap_offset then
            left_bound = self._nav_prev_frame.overlap_offset[1]
                + self._nav_prev_frame.size
        end
        local right_bound = image_area_w
        for _, f in ipairs({ self._more_frame, self._close_frame,
                self._nav_next_frame }) do
            if f and f.overlap_offset then
                right_bound = math.min(right_bound, f.overlap_offset[1])
            end
        end
        self._pill_frame.overlap_offset = {
            math.floor(left_bound + (right_bound - left_bound - pill_size.w) / 2),
            self.height - pill_size.h - bottom_inset,
        }
        table.insert(overlay, self._pill_frame)
    end
    -- caption overlay, top-left on the image (toggleable, on by default)
    if self._caption_wg then
        self._caption_wg:free()
        self._caption_wg = nil
    end
    if G_reader_settings:nilOrTrue(CAPTIONS_KEY) and not self._gallery_mode then
        local meta = self.image_metas
            and self.image_metas[self._images_list_cur or 1]
        local caption = meta and meta.caption
        if caption and caption ~= "" then
            -- the top-right corner is clear now that ⋯ lives at the
            -- bottom, so the caption only needs its own side margins
            self._caption_wg = GlimpseCaption:new{
                text = caption,
                max_width = image_area_w - 2 * Screen:scaleBySize(16),
            }
            self._caption_wg.overlap_offset = {
                Screen:scaleBySize(16), Screen:scaleBySize(12),
            }
            table.insert(overlay, self._caption_wg)
        end
    end
    table.insert(self.frame_elements, overlay)
    self.frame_elements:resetLayout()

    -- main_frame is a transparent full-height column at the left screen
    -- edge; the drawer body (white, black border, rounded right corners)
    -- and its gradient shadow are painted by the _paintPanel hook, since
    -- FrameContainer supports neither per-corner radii nor translucency.
    self.main_frame.background = nil
    self.main_frame.radius = nil
    self.main_frame.bordersize = 0
    self.main_frame.padding = 0
    self.main_frame.padding_left = 0
    self.main_frame.padding_right = self.panel_border
    self.main_frame.padding_top = self.panel_vgap + self.panel_border
    self.main_frame.padding_bottom = self.panel_vgap + self.panel_border
    if not self._panel_paint_hooked then
        self._panel_paint_hooked = true
        local orig_paintTo = self.main_frame.paintTo
        local viewer = self
        self.main_frame.paintTo = function(frame, bb, x, y)
            viewer:_paintPanel(bb, x, y)
            orig_paintTo(frame, bb, x, y)
            viewer:_restoreCorners(bb, x, y)
        end
        -- anchor the drawer to the left edge instead of centering
        self[1].align = nil
    end

    -- Refresh policy (e-ink speed): the gradient shadow right of the panel
    -- only changes on open/close — and those paths refresh the full band
    -- themselves (showViewer/onCloseWidget) — so updates only refresh the
    -- drawer itself. Zoom/pan steps additionally skip dithering: dithered
    -- refreshes are slow and mid-gesture frames don't need the quality;
    -- stable content (open, image switch, back-to-fit) stays dithered.
    local wfm_mode = Device:hasKaleidoWfm() and "partial" or "ui"
    local fast = self._fast_refresh
    self._fast_refresh = nil
    self.dithered = not fast
    if self._suppress_refresh then
        -- showViewer builds the full initial state (remembered image,
        -- restored zoom) before showing, then refreshes once
        return
    end
    -- Interior update: neither the shadow nor the page below changes, so
    -- skip both the below-repaint (the numeric alpha makes setDirty flag
    -- every window under us dirty — repainting the whole book page for a
    -- zoom step) and the shadow re-blend (blending over its own previous
    -- output would accumulate darkness). The two must always travel
    -- together: whenever the shadow DOES re-blend, the page below must
    -- have been repainted first.
    self._skip_shadow_paint = true
    local alpha = self.alpha
    -- false, not nil: alpha is a CLASS field, and nil'ing the instance
    -- slot would just fall back to the class default via the metatable
    self.alpha = false
    UIManager:setDirty(self, function()
        return wfm_mode, self.main_frame.dimen:combine(orig_dimen), not fast
    end)
    self.alpha = alpha
end

-- 8x8 Bayer ordered-dither matrix (values 0..63), used to turn the
-- shadow's continuous falloff curve into a binary dot pattern (see
-- _paintPanel below): e-ink panels have few native gray levels and
-- crush a true alpha gradient into visible bands no matter what dither
-- hint accompanies the refresh; a pattern that's only ever pure
-- black/white (dot DENSITY encoding the darkness, not per-pixel alpha)
-- leaves nothing for the hardware to quantize.
local SHADOW_BAYER8 = {
    { 0, 32,  8, 40,  2, 34, 10, 42},
    {48, 16, 56, 24, 50, 18, 58, 26},
    {12, 44,  4, 36, 14, 46,  6, 38},
    {60, 28, 52, 20, 62, 30, 54, 22},
    { 3, 35, 11, 43,  1, 33,  9, 41},
    {51, 19, 59, 27, 49, 17, 57, 25},
    {15, 47,  7, 39, 13, 45,  5, 37},
    {63, 31, 55, 23, 61, 29, 53, 21},
}

-- Paints the drawer at (x, y): first the dithered dot-pattern shadow
-- (pure black stipple fading rightwards, blended over the live page),
-- then the panel body from a cached stencil — opaque white with a
-- black border, anti-aliased rounded corners on the right side only,
-- transparent corner notches. Blending is safe against accumulation
-- because self.alpha makes UIManager repaint the windows below us
-- first (see the class comment).
function GlimpseViewer:_paintPanel(bb, x, y)
    local w, h = self._panel_w, self._panel_h
    local py = y + self.panel_vgap
    -- Night mode comes in two flavors:
    --   * HW invert (real e-ink panels mostly): the fb flag stays 0 and
    --     the panel inverts its output — paint the LOGICAL (day-polarity)
    --     colors and the hardware turns them into the night look.
    --   * SW invert (emulator, some devices): the fb's inverse flag is
    --     set, which makes every mismatched-flag blit fall back to the
    --     per-pixel Lua blitter (crushingly slow for our full-height
    --     stencils) AND write pre-inverted. So in that case paint the
    --     stencils with the final night colors raw and setInverse(1) on
    --     them: with matching flags the C blitter runs and copies them
    --     as-is — same pixels on screen, at C speed.
    -- Night design in both: black card, white hairline edge, dark shadow
    -- (stronger/wider than day so it reads on black).
    local night = G_reader_settings:isTrue("night_mode")
    local inv = bb.getInverse and bb:getInverse() == 1
    local skey = tostring(night) .. tostring(inv)

    -- shadow: cached DOT-PATTERN stencil (ordered/Bayer dithering, not a
    -- true alpha gradient — see SHADOW_BAYER8 above), density peak → 0
    -- across shadow_width, starting shadow_overlap left of the panel edge
    -- (that part only shows through the rounded corner notches); full
    -- screen height.
    local shadow_h = h + 2 * self.panel_vgap
    -- logical shadow color is white in night (inverts to dark); with the
    -- SW-invert flag set we store the final dark value directly instead
    local sv = inv and 0x00 or (night and 0xFF or 0x00)
    local speak = night and 1.0 or 0.5
    -- night mode gets a wider gradient so it reaches further onto the page
    -- (user tuning 2026-07-22: 2x read as reaching too far, 1.25x as too
    -- narrow — splitting the difference)
    local swidth = night and math.floor(self.shadow_width * 1.5 + 0.5) or self.shadow_width
    if not self._shadow_bb or self._shadow_bb:getHeight() ~= shadow_h
            or self._shadow_night ~= skey then
        if self._shadow_bb then self._shadow_bb:free() end
        self._shadow_night = skey
        self._shadow_bb = Blitbuffer.new(swidth, shadow_h,
            Blitbuffer.TYPE_BBRGB32)
        local function origFrac(tt)
            if night then
                -- night: hold most of the darkness through the left half
                -- (a strong contact band that reads as "above the page"),
                -- then fall off quadratically so the right half is much
                -- lighter than a straight ramp; continuous at t = 0.5
                return tt < 0.5 and (1 - 0.8 * tt)
                    or 0.6 * (1 - (tt - 0.5) * 2) ^ 2
            else
                return 1 - tt
            end
        end
        -- BOOSTED NEAR-EDGE ZONE (2026-07-22, corrected twice same day):
        -- the first `shadow_overlap` columns (t < vis0) are painted OVER
        -- by the panel body along every straight edge — only the small
        -- rounded-corner notches ever expose them — so a boost anchored
        -- to t=0 (1st attempt) was invisible for ~95% of the panel's
        -- height. Anchoring to vis0 instead (2nd attempt) fixed
        -- visibility but introduced a real seam: it jumped straight to
        -- `peak_level` AT vis0, discontinuous with whatever origFrac(t)
        -- was doing just below vis0 — invisible along a straight edge
        -- (the panel itself covers t < vis0 there) but the corner's
        -- notch exposes BOTH sides of that jump within one small curved
        -- area, so it read as a hard block breaking the curve instead of
        -- following it ("the dithering missed the rounding of the
        -- corner"). Fixed by boosting with a smooth bump added ON TOP OF
        -- the untouched curve — continuous everywhere, including t <
        -- vis0, so whatever the corner exposes always tapers smoothly,
        -- no matter how much of the buffer that turns out to be.
        local vis0 = self.shadow_overlap / swidth
        local peak_level = night and 1.0 or 0.62
        -- how far the boost tapers back to the plain curve on the VISIBLE
        -- (page) side of the panel edge
        local bump_width = 0.18
        for i = 0, swidth - 1 do
            local t = (i + 0.5) / swidth
            local orig_level = speak * origFrac(t)
            -- boost = a bump peaking at peak_level right at the panel edge
            -- (vis0). LEFT of the edge (t <= vis0) it stays FLAT at the peak:
            -- that region is hidden under the opaque panel along straight
            -- edges and only ever shows through the rounded-corner notches,
            -- where a solid dark band that runs back under the panel reads
            -- as the shadow continuing UNDER the overlay (the illusion the
            -- user wanted). RIGHT of the edge it tapers to the plain curve
            -- over bump_width via a raised cosine. Both pieces meet at vis0
            -- at exactly peak_level with slope ~0, so the whole curve is
            -- seamless — a discontinuity here is what broke the corner in
            -- v0.1.13 (the notch exposes both sides of the edge at once).
            local bump
            if t <= vis0 then
                bump = 1
            else
                local dist = (t - vis0) / bump_width
                bump = dist < 1 and 0.5 * (1 + math.cos(math.pi * dist)) or 0
            end
            -- desired LOCAL darkness at this column, 0..255 — compared
            -- against the tiled Bayer matrix per-pixel below rather than
            -- written as a per-pixel alpha, so the result is always fully
            -- opaque or fully transparent (a dot, or no dot)
            local level = (orig_level + bump * (peak_level - orig_level)) * 255
            local col = (i % 8) + 1
            for j = 0, shadow_h - 1 do
                local threshold = (SHADOW_BAYER8[col][(j % 8) + 1] + 0.5) * 4
                local a = level > threshold and 255 or 0
                self._shadow_bb:setPixel(i, j, Blitbuffer.ColorRGB32(sv, sv, sv, a))
            end
        end
        self._shadow_bb:setInverse(inv and 1 or 0)
    end
    -- consumed by interior updates (see update()): the page under the
    -- shadow wasn't repainted, so blending again would accumulate
    local skip_shadow = self._skip_shadow_paint
    self._skip_shadow_paint = nil
    if not skip_shadow then
        bb:alphablitFrom(self._shadow_bb, x + w - self.shadow_overlap, y,
            0, 0, swidth, shadow_h)
    end

    -- Under-corner snapshots: the panel stencil's arc pixels carry
    -- partial alpha (anti-aliasing), so unlike the opaque body they are
    -- NOT idempotent to re-blend. On a full paint (below just painted,
    -- shadow just blended) save the pristine background under the two
    -- corner squares; on skip-paints restore it first, so every interior
    -- repaint blends the arcs over the same pixels instead of slowly
    -- eating the AA against the page.
    local cr = self.panel_radius
    local cpy = y + self.panel_vgap
    if not self._under_corner_bbs then
        self._under_corner_bbs = {
            Blitbuffer.new(cr, cr, Blitbuffer.TYPE_BBRGB32),
            Blitbuffer.new(cr, cr, Blitbuffer.TYPE_BBRGB32),
        }
    end
    local ucb = self._under_corner_bbs
    if skip_shadow then
        bb:blitFrom(ucb[1], x + w - cr, cpy, 0, 0, cr, cr)
        bb:blitFrom(ucb[2], x + w - cr, cpy + h - cr, 0, 0, cr, cr)
    else
        -- match the fb's inverse flag so these copies run on the C blitter
        ucb[1]:setInverse(inv and 1 or 0)
        ucb[2]:setInverse(inv and 1 or 0)
        ucb[1]:blitFrom(bb, 0, 0, x + w - cr, cpy, cr, cr)
        ucb[2]:blitFrom(bb, 0, 0, x + w - cr, cpy + h - cr, cr, cr)
    end

    if not self._panel_bb or self._panel_bb:getWidth() ~= w
            or self._panel_bb:getHeight() ~= h or self._panel_night ~= skey then
        if self._panel_bb then
            self._panel_bb:free()
        end
        self._panel_night = skey
        self._panel_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
        -- Logical colors: white body, black edge — the night inversion
        -- (HW panel or SW flag) turns them into a black card with a white
        -- hairline edge. With the SW-invert flag set we store the final
        -- values raw instead (flag-matched below for the C blitter).
        -- NB: screen:shot()/getPixel un-invert reads, so night shots show
        -- LOGICAL values, not the displayed ones.
        local body = inv and 0x00 or 0xFF     -- card background
        local edge = inv and 0xFF or 0x00     -- border
        local c_body = Blitbuffer.ColorRGB32(body, body, body, 0xFF)
        local c_edge = Blitbuffer.ColorRGB32(edge, edge, edge, 0xFF)
        -- night edge is a hairline: thinner than the day border but at
        -- least 2px so it doesn't vanish on high-dpi devices; the layout
        -- keeps panel_border so the image doesn't shift
        local bw = night and math.max(2, Screen:scaleBySize(1))
            or self.panel_border
        local r = self.panel_radius
        -- border on top/right/bottom only: the left edge is flush with the
        -- screen edge and borderless
        self._panel_bb:paintRectRGB32(0, 0, w, h, c_body)
        self._panel_bb:paintRectRGB32(0, 0, w, bw, c_edge)
        self._panel_bb:paintRectRGB32(0, h - bw, w, bw, c_edge)
        self._panel_bb:paintRectRGB32(w - bw, 0, bw, h, c_edge)
        -- right corners: AA arcs — body inside, border ring, transparent
        -- outside (the page shows in the notches)
        for cy_top = 0, 1 do
            local ccx, ccy = w - r, cy_top == 0 and r or h - r
            for px = w - r, w - 1 do
                for qy = 0, r - 1 do
                    local pyy = cy_top == 0 and qy or h - 1 - qy
                    local fx, fy = px + 0.5, pyy + 0.5
                    if fx >= ccx and (cy_top == 0 and fy <= ccy or cy_top == 1 and fy >= ccy) then
                        local d = math.sqrt((fx - ccx) ^ 2 + (fy - ccy) ^ 2)
                        local cov = math.min(math.max(r - d + 0.5, 0), 1)
                        local t_in = math.min(math.max((r - bw) - d + 0.5, 0), 1)
                        local g = math.floor(edge + t_in * (body - edge) + 0.5)
                        self._panel_bb:setPixel(px, pyy,
                            Blitbuffer.ColorRGB32(g, g, g, math.floor(cov * 255 + 0.5)))
                    end
                end
            end
        end
        self._panel_bb:setInverse(inv and 1 or 0)
    end
    bb:alphablitFrom(self._panel_bb, x, py, 0, 0, w, h)
    self:_saveCorners(bb, x, py)
end

-- The image is allowed to reach the panel border, so a zoomed image would
-- paint square corners over the rounded right ones. Right after the panel
-- is painted (page in the notches, border arc, white interior), the two
-- corner squares are copied aside with per-pixel alpha = "outside the
-- interior" (notch + border ring + an image_padding-wide white ring
-- opaque, interior transparent), and re-blended on top after the children
-- have painted — the image's corners end up rounded, with the same white
-- gap against the border as along the straight edges.
function GlimpseViewer:_saveCorners(bb, x, py)
    local w, h = self._panel_w, self._panel_h
    local r, bw = self.panel_radius, self.panel_border
    if not self._corner_bbs then
        self._corner_bbs = {
            Blitbuffer.new(r, r, Blitbuffer.TYPE_BBRGB32),
            Blitbuffer.new(r, r, Blitbuffer.TYPE_BBRGB32),
        }
    end
    self._corner_bbs[1]:blitFrom(bb, 0, 0, x + w - r, py, r, r)
    self._corner_bbs[2]:blitFrom(bb, 0, 0, x + w - r, py + h - r, r, r)
    for k = 1, 2 do
        local cbb = self._corner_bbs[k]
        -- circle center in corner-local coords: (0, r) for the top-right
        -- corner square, (0, 0) for the bottom-right one
        local ccy = k == 1 and r or 0
        local keep_r = r - bw - self.image_padding
        for pyy = 0, r - 1 do
            for pxx = 0, r - 1 do
                local d = math.sqrt((pxx + 0.5) ^ 2 + (pyy + 0.5 - ccy) ^ 2)
                local t_in = math.min(math.max(keep_r - d + 0.5, 0), 1)
                if t_in > 0 then
                    local c = cbb:getPixel(pxx, pyy):getColorRGB32()
                    cbb:setPixel(pxx, pyy, Blitbuffer.ColorRGB32(
                        c.r, c.g, c.b, math.floor((1 - t_in) * 255 + 0.5)))
                end
            end
        end
    end
end

function GlimpseViewer:_restoreCorners(bb, x, y)
    if not self._corner_bbs then return end
    local w, h = self._panel_w, self._panel_h
    local py = y + self.panel_vgap
    local r = self.panel_radius
    bb:alphablitFrom(self._corner_bbs[1], x + w - r, py, 0, 0, r, r)
    bb:alphablitFrom(self._corner_bbs[2], x + w - r, py + h - r, 0, 0, r, r)
end

-- The G-sensor's SetRotationMode event is delivered to the topmost widget
-- only, so an open drawer would silently block auto-rotation. Do what
-- Menu does: close, let the reader re-layout, and reopen — zoom/pan
-- persistence makes the reopened drawer land where the user was.
function GlimpseViewer:onSetRotationMode(rotation)
    if rotation ~= nil and rotation ~= Screen:getRotationMode() then
        UIManager:close(self)
        if self.on_rotate then
            self.on_rotate(rotation)
        end
    end
    return true
end

function GlimpseViewer:onCloseWidget()
    if self._shadow_bb then
        self._shadow_bb:free()
        self._shadow_bb = nil
    end
    if self._panel_bb then
        self._panel_bb:free()
        self._panel_bb = nil
    end
    if self._corner_bbs then
        self._corner_bbs[1]:free()
        self._corner_bbs[2]:free()
        self._corner_bbs = nil
    end
    if self._under_corner_bbs then
        self._under_corner_bbs[1]:free()
        self._under_corner_bbs[2]:free()
        self._under_corner_bbs = nil
    end
    if self._more_frame then
        self._more_frame:free()
    end
    if self._nav_prev_frame then self._nav_prev_frame:free() end
    if self._nav_next_frame then self._nav_next_frame:free() end
    if self._close_frame then self._close_frame:free() end
    if self._gallery_heading then
        self._gallery_heading:free()
        self._gallery_heading = nil
    end
    if self._caption_wg then
        self._caption_wg:free()
        self._caption_wg = nil
    end
    if self._thumb_bbs then
        for _, t in pairs(self._thumb_bbs) do
            if t.bb then t.bb:free() end
        end
        self._thumb_bbs = nil
    end
    -- ImageViewer.onCloseWidget() does necessary cleanup (frees self.image,
    -- title_bar, button_container, etc.) but ALSO unconditionally queues
    -- its OWN "flashui" refresh of main_frame.dimen at the very end (see
    -- imageviewer.lua ~886-889) — the exact same pattern as the onShow()
    -- bug fixed earlier this session, just on the close side instead:
    -- "flashui" outranks our own "ui" request (refresh_modes: flashui=7 >
    -- ui=3, see uimanager.lua ~1060), so it silently wins whenever the two
    -- deferred refresh callbacks get merged, no matter what we ask for.
    -- Confirmed via a headless refresh-queue trace (2026-07-21): closing
    -- was NOT triggering KOReader's normal partial-refresh-count flash
    -- promotion (measured zero "partial" ticks across several open/close
    -- cycles) — it's this direct, unconditional "flashui" request, every
    -- single time. Pop the just-queued upstream callback off the refresh
    -- func stack before pushing our own, keeping the cleanup but dropping
    -- the forced flash.
    ImageViewer.onCloseWidget(self)
    table.remove(UIManager._refresh_func_stack)
    -- "ui" (non-flashing): the drawer covers most of the page, but KOReader's
    -- own menus close the same way and rely on the normal partial-refresh
    -- promotion cadence to mop up any ghosting, rather than forcing a flash
    -- on every single close — matches that convention instead of "full"
    -- (2026-07-21: was flashing here on every close, worst at night; if
    -- ghosting turns out to be visible on device, "flashui" is the next
    -- step up — see uimanager.lua's refreshtype docs).
    -- Dither hint (2026-07-21): the open refresh always passed one, this
    -- one never did — the gradient shadow being erased here banded into a
    -- handful of distinct grays without it (very visible in Day mode's
    -- black-on-light shadow; the same banding was there in Night mode too,
    -- just far less visible against an already-dark background).
    UIManager:setDirty(nil, function()
        local d = self.main_frame.dimen:copy()
        -- cover the shadow at its widest (night mode = 2× shadow_width)
        d.w = math.min(Screen:getWidth() - d.x,
            d.w + 2 * self.shadow_width - self.shadow_overlap + 1)
        return "ui", d, true
    end)
end

-- Forked from ImageViewer:_new_image_wg(): constant image inset (no
-- title-bar/buttons dependence) and per-image 0/90/180/270 rotation.
function GlimpseViewer:_new_image_wg()
    -- the image gets the whole content area (a zoomed image must reach the
    -- panel border on all sides); image_right_gap only aligns the chrome
    local avail_w = self.width
    local max_image_h = self.img_container_h - self.image_padding * 2
    local max_image_w = avail_w - self.image_padding * 2
    -- Logical fit mode (scale_factor 0) stays 0 for the viewer (dot pill,
    -- nav state, double-tap all key off it), but an image SMALLER than
    -- the content box renders at OUR capped fit (see
    -- _computeFitScaleFactor: up to 150% of native size, never more than
    -- what fits) instead of the widget's own best-fit, which would blow
    -- it up all the way to fill the box with no cap at all.
    local wg_scale = self.scale_factor
    if wg_scale == 0 then
        local fit = self:_computeFitScaleFactor()
        if fit and fit >= 1 then
            wg_scale = fit
        end
    end
    self._image_wg = ImageWidget:new{
        image = self.image,
        image_disposable = false, -- we may reuse self.image
        alpha = true,
        width = max_image_w,
        height = max_image_h,
        rotation_angle = self._cur_rotation or 0,
        scale_factor = wg_scale,
        center_x_ratio = self._center_x_ratio,
        center_y_ratio = self._center_y_ratio,
        -- ImageWidget's default night handling invertRects its FULL rect
        -- (widget size, not the scaled image), which flips the drawer's
        -- letterbox areas around the image back to white in night mode.
        -- Opt out; the render closure implements our own global
        -- "Invert in Night Mode" setting instead.
        original_in_nightmode = false,
    }
    -- Night (SW invert): the fb's inverse flag would push the image blit
    -- onto the per-pixel Lua blitter on EVERY paint (mismatched flags —
    -- same story as the panel stencils in _paintPanel). The render
    -- closure already bakes the final raw night values into the DECODED
    -- bitmap once (see showViewer), so every re-scaled copy only needs
    -- its inverse flag set to match the fb — a free flag toggle instead
    -- of the full-bitmap invertRect this hook used to do per zoom step
    -- (which doubled night zoom cost vs day). Flag-only is also safe on
    -- the shared source bitmap at 1:1 scale: no content is mutated.
    local wg = self._image_wg
    local orig_render = wg._render
    wg._render = function(w_)
        orig_render(w_)
        if w_._bb and Screen.bb.getInverse and Screen.bb:getInverse() == 1
           and w_._bb:getInverse() == 0 then
            w_._bb:invert()
        end
    end
    self.image_container = CenterContainer:new{
        dimen = Geom:new{ w = avail_w, h = self.img_container_h },
        self._image_wg,
    }
end

-- Pill: as many dots as fit between the chrome buttons, "n / N" beyond. Rebuilt on
-- every update (position/count/text all change together).
function GlimpseViewer:_buildPill()
    if self._pill_frame then
        self._pill_frame:free()
        self._pill_frame = nil
    end
    self._pill_dots = nil -- only set back below when dots are actually built
    if self._gallery_mode then
        -- gallery: explicit "Page X of Y" — dots here would read as the
        -- single-view image indicator and confuse the two states. Inverted
        -- (light pill, dark text), same as the "n / N" fallback below.
        local pages = self:_galleryPages()
        if pages <= 1 then return end
        self._pill_frame = GlimpsePill:new{ inverted = true, inner = TextWidget:new{
            text = T(_("Page %1 of %2"), self._gallery_page or 1, pages),
            face = Font:getFace("cfont", 12),
            fgcolor = Blitbuffer.COLOR_BLACK,
        } }
        return
    end
    if self:_isOverFit() then
        -- genuinely spilling past fit: image switching is disabled, and
        -- the indicator becomes a tappable "back to fit" button, styled
        -- to match the ⋯ button (see onTap)
        self._pill_frame = GlimpseTextButton:new{
            text = _("Fit"),
            bold = true,
            icon = _PLUGIN_DIR .. "/assets/zoom.svg",
        }
        return
    end
    if not (self._images_list and self._images_list_nb > 1) then return end
    local nb = self._images_list_nb
    -- Fit as many dots as the space between the chrome buttons allows,
    -- compressing the pitch down toward the dots' own diameter before
    -- giving up. Only when even that won't fit do we fall back to "n / N".
    local dot_r = GlimpseDots.dot_r
    local natural_pitch = GlimpseDots.pitch
    local min_pitch = 2 * dot_r + Screen:scaleBySize(2)
    local budget = self:_pillAvailWidth() - 2 * GlimpsePill.padding_h
    local pitch = natural_pitch
    if nb > 1 then
        -- pitch that would exactly fill the budget; keep small counts
        -- compact by never exceeding the natural pitch
        pitch = math.min(natural_pitch, (budget - 2 * dot_r) / (nb - 1))
    end
    if pitch >= min_pitch then
        local inner = GlimpseDots:new{
            nb = nb,
            cur = self._images_list_cur or 1,
            pitch = math.floor(pitch),
        }
        self._pill_dots = inner
        self._pill_frame = GlimpsePill:new{ inner = inner }
    else
        -- truly too many to fit even compressed: "n / N" counter, INVERTED
        -- (light pill + dark text). As a solid black block with white text
        -- it drew far more attention than the dots pill it stands in for.
        self._pill_frame = GlimpsePill:new{
            inverted = true,
            inner = TextWidget:new{
                text = string.format("%d / %d", self._images_list_cur or 1, nb),
                face = Font:getFace("cfont", 12),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        }
    end
end

-- Horizontal room the dot pill has between the bottom-row chrome buttons:
-- from the Prev button's right edge (or the left inset when nav buttons
-- are off) to the ⋯/more button's left edge, less a gap on each side.
-- Mirrors the button geometry in update() so it can run before layout.
function GlimpseViewer:_pillAvailWidth()
    local image_area_w = self.width - self.image_right_gap
    local btn_inset = Screen:scaleBySize(16)
    local btn_gap = Screen:scaleBySize(10)
    local btn_size = GlimpseMoreButton.size
    local nav = G_reader_settings:isTrue(NAV_BUTTONS_KEY)
        and self._images_list and (self._images_list_nb or 1) > 1
    local more_left = nav
        and (image_area_w - 2 * btn_size - btn_gap)
        or (image_area_w - btn_size)
    local left_bound = nav and (btn_inset + btn_size) or btn_inset
    return more_left - left_bound - 2 * btn_gap
end

function GlimpseViewer:_buildMoreButton()
    self._more_frame = GlimpseMoreButton:new{}
end

-- ── gallery (⋯ → Gallery): a paged masonry grid in the drawer ───────────────
-- Same window, same chrome: the grid replaces the image area, the pill
-- shows "Page X of Y", the ‹ › buttons page (always shown here — they
-- are the pagination affordance — hidden on a single page), swipes and
-- physical page keys page too. Tapping a thumbnail leaves the gallery
-- and opens that image in the normal viewer. Thumbnails are laid out
-- Pinterest-style: fixed-width columns, each image at its own aspect
-- ratio, placed into the currently shortest column — a page is full
-- when the next image doesn't fit any column.

function GlimpseViewer:_enterGallery()
    self._gallery_mode = true
    local layout = self:_galleryLayout()
    self._gallery_page = layout.page_of[self._images_list_cur or 1] or 1
    -- the gallery browses from the fit state; a zoomed view has been
    -- left behind anyway once the user goes looking for another image
    self.scale_factor = 0
    self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
    self:update()
end

function GlimpseViewer:_exitGallery(idx)
    self._gallery_mode = false
    if idx and idx ~= (self._images_list_cur or 1) then
        self:switchToImageNum(idx) -- runs update()
    else
        self:update()
    end
end

function GlimpseViewer:_galleryPages()
    return #self:_galleryLayout().pages
end

-- Masonry layout for ALL images, computed once per viewer (the image
-- list and drawer size are fixed while it is open) from the scanner's
-- header-sniffed dimensions — no decoding. Returns { pages = {
-- {cell,...}, ... }, page_of = {idx -> page} }; cell = {idx,x,y,w,h}
-- relative to the drawer content origin (the onTap hit-test space).
function GlimpseViewer:_galleryLayout()
    if self._gallery_layout then return self._gallery_layout end
    local m = self:_galleryMetrics()
    local cols = self.gallery_cols
    local col_w = math.floor(
        (m.area_w - 2 * m.pad - (cols - 1) * m.gap) / cols)
    local thumb_w = col_w - 2 * m.inset
    local layout = { pages = {}, page_of = {} }
    local page, heights = {}, {}
    for c = 1, cols do heights[c] = 0 end
    local function flush()
        if #page > 0 then
            layout.pages[#layout.pages + 1] = page
            page = {}
            for c = 1, cols do heights[c] = 0 end
        end
    end
    for i = 1, self._images_list_nb or 1 do
        local meta = self.image_metas and self.image_metas[i]
        local iw = meta and (meta.width or meta.attr_width)
        local ih = meta and (meta.height or meta.attr_height)
        if not (iw and ih and iw > 0 and ih > 0) then iw, ih = 1, 1 end
        local th = math.floor(thumb_w * ih / iw + 0.5)
        -- clamp: never taller than a full column, never too small to tap
        th = math.min(th, m.grid_h - 2 * m.inset)
        th = math.max(th, Screen:scaleBySize(24))
        local cell_h = th + 2 * m.inset
        -- shortest column (leftmost on ties, so pages fill left to right)
        local best = 1
        for c = 2, cols do
            if heights[c] < heights[best] then best = c end
        end
        local y = heights[best] > 0 and heights[best] + m.gap or 0
        if y + cell_h > m.grid_h and #page > 0 then
            flush()
            best, y = 1, 0
        end
        page[#page + 1] = {
            idx = i,
            x = m.pad + (best - 1) * (col_w + m.gap),
            y = m.top + y,
            w = col_w,
            h = math.min(cell_h, m.grid_h),
        }
        heights[best] = y + cell_h
        layout.page_of[i] = #layout.pages + 1
    end
    flush()
    if #layout.pages == 0 then layout.pages[1] = {} end
    self._gallery_layout = layout
    return layout
end

-- Shared gallery geometry: the band above the grid holds the heading and
-- the Close button, the band below holds the page pill and ‹ › buttons.
-- area_w is the FULL content width (unlike the single-image view, the
-- grid has no chrome that needs to dodge the rounded right corner — the
-- top/bottom bands already keep clear of it vertically) so the grid's
-- right margin (pad) matches its left margin exactly.
function GlimpseViewer:_galleryMetrics()
    return {
        area_w = self.width,
        pad = Screen:scaleBySize(16),
        top = Screen:scaleBySize(16 + 40 + 10),
        bottom = Screen:scaleBySize(60),
        gap = Screen:scaleBySize(10),
        inset = Screen:scaleBySize(4),
        grid_h = self.img_container_h - Screen:scaleBySize(16 + 40 + 10)
            - Screen:scaleBySize(60),
    }
end

function GlimpseViewer:_galleryGo(delta)
    local p = math.min(math.max((self._gallery_page or 1) + delta, 1),
        self:_galleryPages())
    if p ~= self._gallery_page then
        self._gallery_page = p
        self:update()
    end
end

-- Thumbnail for image i, fitted inside w×h, cached for the lifetime of
-- the drawer (revisiting a page is instant; the current image usually
-- hits the plugin's decoded-bitmap cache too). The source comes from the
-- render closure, so night baking is already in the pixels — the cache
-- can't go stale on us because night mode can't change while the drawer
-- is open; the cache is freed with the viewer.
function GlimpseViewer:_thumb(i, w, h)
    self._thumb_bbs = self._thumb_bbs or {}
    local t = self._thumb_bbs[i]
    if t and t.w == w and t.h == h then
        return t.bb
    end
    if t and t.bb then
        t.bb:free()
        self._thumb_bbs[i] = nil
    end
    local src = self._images_list and self._images_list[i]
    local own = false
    if type(src) == "function" then
        src = src()
        own = true -- the closure hands us a fresh bitmap: ours to free
    end
    if not src then return nil end
    local bw, bh = src:getWidth(), src:getHeight()
    local s = math.min(w / bw, h / bh, 1)
    local bb
    if s < 1 then
        bb = RenderImage:scaleBlitBuffer(src,
            math.max(1, math.floor(bw * s + 0.5)),
            math.max(1, math.floor(bh * s + 0.5)), own)
    else
        bb = own and src or src:copy()
    end
    if bb and Screen.bb.getInverse and Screen.bb:getInverse() == 1
       and bb:getInverse() == 0 then
        bb:invert() -- flag-match the fb (content already night-baked)
    end
    self._thumb_bbs[i] = { bb = bb, w = w, h = h }
    return bb
end

-- Builds the masonry page as self.image_container (update() slots it
-- into the overlay in place of the image). Cell rects are recorded
-- relative to the drawer content origin for onTap hit-testing.
function GlimpseViewer:_buildGallery()
    local layout = self:_galleryLayout()
    local pages = #layout.pages
    self._gallery_page = math.min(math.max(self._gallery_page or 1, 1), pages)
    local m = self:_galleryMetrics()
    local grid = OverlapGroup:new{
        dimen = Geom:new{ w = self.width, h = self.img_container_h },
    }
    -- heading, top-left: how much there is to browse, and how much the
    -- chapter scope is holding back. The Back button now lives at the
    -- bottom, so the whole top band is free of chrome to dodge.
    if self._gallery_heading then
        self._gallery_heading:free()
        self._gallery_heading = nil
    end
    local nb = self._images_list_nb or 1
    local hidden = self.gallery_hidden_count or 0
    local heading_text
    if hidden > 0 then
        heading_text = T(_("%1 images in book this far, %2 hidden"),
            nb, hidden)
    else
        heading_text = T(_("%1 images in book"), nb)
    end
    self._gallery_heading = TextWidget:new{
        text = heading_text,
        face = Font:getFace("cfont", 16),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = m.area_w - 2 * m.pad,
    }
    local hh = self._gallery_heading:getSize().h
    self._gallery_heading.overlap_offset = {
        m.pad,
        Screen:scaleBySize(16)
            + math.floor((Screen:scaleBySize(40) - hh) / 2),
    }
    table.insert(grid, self._gallery_heading)
    self._gallery_cells = {}
    for _, c in ipairs(layout.pages[self._gallery_page] or {}) do
        local bb = self:_thumb(c.idx,
            c.w - 2 * m.inset, c.h - 2 * m.inset)
        if bb then
            -- every thumbnail gets a subtle rounded outline so adjacent
            -- images (which otherwise butt edge to edge) stay visually
            -- distinct; the current image gets a heavier black one on
            -- top of that, same as before
            local is_cur = c.idx == (self._images_list_cur or 1)
            local cell = CenterContainer:new{
                dimen = Geom:new{ w = c.w, h = c.h },
                FrameContainer:new{
                    bordersize = is_cur
                        and Screen:scaleBySize(2) or Screen:scaleBySize(1),
                    color = is_cur and Blitbuffer.COLOR_BLACK
                        or Blitbuffer.COLOR_GRAY,
                    radius = Screen:scaleBySize(3),
                    padding = Screen:scaleBySize(2),
                    ImageWidget:new{
                        image = bb,
                        image_disposable = false, -- cached in _thumb_bbs
                        alpha = true,
                        original_in_nightmode = false,
                        scale_factor = 1,
                    },
                },
            }
            cell.overlap_offset = { c.x, c.y }
            table.insert(grid, cell)
            table.insert(self._gallery_cells,
                { x = c.x, y = c.y, w = c.w, h = c.h, idx = c.idx })
        end
    end
    self.image_container = grid
end

-- The ⋯ menu (from the design): gallery, remove from collection, rotate
-- 90° (remembered per image, plus a reset once rotated), show in book,
-- invert in night mode (the global setting, also in the plugin menu).
-- The gallery has no ⋯ button (it shows a Close button instead), so this
-- only ever runs on the single-image view.
function GlimpseViewer:_showMoreMenu()
    local items = {
        {
            text = _("Gallery"),
            icon = _PLUGIN_DIR .. "/assets/gallery.svg",
            callback = function() self:_enterGallery() end,
        },
        {
            text = _("Hide Image"),
            icon = _PLUGIN_DIR .. "/assets/hide.svg",
            callback = function() self:_hideCurrentImage() end,
        },
        {
            text = _("Rotate 90°"),
            icon = _PLUGIN_DIR .. "/assets/rotate.svg",
            callback = function() self:_rotateCurrent() end,
        },
    }
    if (self._cur_rotation or 0) ~= 0 then
        items[#items + 1] = {
            text = _("Reset Rotation"),
            icon = _PLUGIN_DIR .. "/assets/reset-rotation.svg",
            callback = function() self:_setRotation(0) end,
        }
    end
    items[#items + 1] = {
        text = _("Show in Book"),
        icon = _PLUGIN_DIR .. "/assets/goto.svg",
        callback = function() self:_showInBook() end,
    }
    items[#items + 1] = {
        -- checkbox drawn in the icon column (see GlimpseMenuRow),
        -- so it lines up with the icons above it
        text = _("Invert in Night Mode"),
        check = G_reader_settings:isTrue(INVERT_KEY),
        callback = function() self:_toggleInvert() end,
    }
    local menu
    menu = GlimpsePopupMenu:new{
        items = items,
        -- anchor to the ⋯ button (bottom row): right edge aligned to the
        -- button's right edge (MovableContainer left-aligns on the anchor,
        -- so shift left by our own width, known by the time ensureAnchor
        -- calls this). The button sits near the screen bottom, so the menu
        -- has no room below and pops UP — its bottom lands at the anchor's
        -- y. Lifting y by `gap` above the button top puts a real margin
        -- OUTSIDE the popup, between it and the button (an earlier attempt
        -- put padding INSIDE, under the last row, which was wrong).
        anchor = function()
            local d = self._more_frame and self._more_frame.dimen
            if not d then return end
            local mov = menu.movable
            local w = mov and mov.dimen and mov.dimen.w or 0
            local gap = Screen:scaleBySize(10)
            return Geom:new{ x = d.x + d.w - w, y = d.y - gap,
                w = 0, h = d.h }, true
        end,
    }
    -- when the menu closes, also repaint the ⋯ button so its pressed
    -- (inverted) state clears
    menu._restore_region = self._more_frame and self._more_frame.dimen
        and self._more_frame.dimen:copy()
    menu.on_dismiss = function()
        if self._more_frame then self._more_frame.inverted = nil end
    end
    -- region function: the anchored rect is only known after the
    -- MovableContainer paints, and a full-screen refresh flashes the map
    UIManager:show(menu, function()
        return "ui", menu.movable.dimen
    end)
end

-- ⋯ menu "Show in Book": close the drawer and jump the reader to the
-- chapter the current image lives in (the plugin hook does the jump and
-- pushes the previous location so Back returns to the reading position).
function GlimpseViewer:_showInBook()
    local meta = self.image_metas and self.image_metas[self._images_list_cur or 1]
    if meta and self.on_show_in_book then
        self:onClose()
        self.on_show_in_book(meta)
    end
end

-- Each press turns the image a quarter-turn CLOCKWISE on screen (matching
-- the rotate icon's arrow); ImageWidget's rotation_angle is
-- counter-clockwise, so step by -90.
function GlimpseViewer:_rotateCurrent()
    self:_setRotation(((self._cur_rotation or 0) - 90) % 360)
end

function GlimpseViewer:_setRotation(rotation)
    self._cur_rotation = rotation
    self._fit_scale_factor = nil -- rotated image, different fit
    self._scale_factor_0 = nil
    local meta = self.image_metas and self.image_metas[self._images_list_cur]
    if meta and self.set_pref then
        self.set_pref(meta, "rotation",
            self._cur_rotation ~= 0 and self._cur_rotation or nil)
    end
    self:update()
end

function GlimpseViewer:_toggleInvert()
    local cur = self._images_list_cur or 1
    G_reader_settings:saveSetting(INVERT_KEY,
        not G_reader_settings:isTrue(INVERT_KEY))
    -- cached gallery thumbnails have the OLD polarity baked into their
    -- pixels — drop them so the gallery re-renders with the new setting
    if self._thumb_bbs then
        for _, t in pairs(self._thumb_bbs) do
            if t.bb then t.bb:free() end
        end
        self._thumb_bbs = nil
    end
    -- re-render so the change is visible immediately (the render closure
    -- reads prefs and night mode live)
    if self.image and self.image_disposable and self.image.free then
        self.image:free()
    end
    self.image = self._images_list[cur]
    if type(self.image) == "function" then
        self.image = self.image()
    end
    self:update()
end

-- Manual double-tap detection from instant Tap events: a second tap close
-- in time and position counts as a double-tap. Only consulted where the
-- single tap would do nothing (middle area at fit, anywhere while zoomed),
-- so no single-tap action ever has to be delayed or undone.
function GlimpseViewer:_checkDoubleTap(ges)
    local now = time.now()
    local slop = Screen:scaleBySize(50)
    local lt = self._last_tap
    self._last_tap = { time = now, x = ges.pos.x, y = ges.pos.y }
    if lt and now - lt.time < time.ms(350)
       and math.abs(ges.pos.x - lt.x) <= slop
       and math.abs(ges.pos.y - lt.y) <= slop then
        self._last_tap = nil
        self:onGlimpseDoubleTap(nil, ges)
    end
end

-- Double-tap: photo-app convention — back to fit when zoomed, zoom in
-- when at fit, always to 2× whatever fit resolves to. Small images
-- already open boosted (up to 150% of native size, see
-- _computeFitScaleFactor), so this naturally lands them around 300% —
-- a further, deliberate step for inspecting detail, on top of the
-- bigger-by-default resting view.
function GlimpseViewer:onGlimpseDoubleTap(_, ges)
    if self.scale_factor == 0 then
        local wg = self._image_wg
        if wg then
            wg:getSize() -- pan math needs a rendered bb
            local d = wg.dimen
            local cx = d and (d.x + d.w / 2) or Screen:getWidth() / 2
            local cy = d and (d.y + d.h / 2) or Screen:getHeight() / 2
            self._center_x_ratio, self._center_y_ratio =
                wg:getPanByCenterRatio(ges.pos.x - cx, ges.pos.y - cy)
        end
        self:_refreshScaleFactor() -- resolve fit into a number
        self:_applyNewScaleFactor(self.scale_factor * 2)
    else
        self.scale_factor = 0
        self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
        self:update()
    end
    return true
end

-- Press feedback for the nav buttons: paint the button inverted, then —
-- like upstream Button:onTapSelectButton — DRAIN the refresh queue and
-- yield to the EPDC before running the action. Just queueing the flash
-- refresh doesn't work: the action's own refresh follows milliseconds
-- later and supersedes it before the panel ever shows the flash. The
-- rebuilt button from the switch's update() clears the pressed state.
-- Disabled buttons consume the tap without flashing or acting.
function GlimpseViewer:_flashButton(frame, action)
    if frame.disabled then return end
    local d = frame.dimen
    frame.inverted = true
    UIManager:widgetRepaint(frame, d.x, d.y)
    UIManager:setDirty(nil, "fast", d)
    UIManager:forceRePaint()
    UIManager:yieldToEPDC()
    action()
end

-- Tap: outside closes; on the ⋯ button opens the menu. Image switching is
-- swipe-only (or the optional buttons), which leaves the whole image as a
-- double-tap zoom surface.
function GlimpseViewer:onTap(_, ges)
    if ges.pos:notIntersectWith(self.main_frame.dimen) then
        self:onClose()
        return true
    end
    if self._gallery_mode and self._close_frame and self._close_frame.dimen
       and ges.pos:intersectWith(self._close_frame.dimen) then
        self:_flashButton(self._close_frame, function()
            self:_exitGallery()
        end)
        return true
    end
    -- gate on not-gallery: _more_frame keeps its stale dimen (same rect
    -- the Close button now occupies) from the last single-image paint
    if not self._gallery_mode and self._more_frame and self._more_frame.dimen
       and ges.pos:intersectWith(self._more_frame.dimen) then
        -- press feedback: repaint the button inverted (rounded, via its
        -- stencil mask); it stays inverted while the menu is open and
        -- repaints normal on dismiss, whose region covers the button
        local d = self._more_frame.dimen
        self._more_frame.inverted = true
        UIManager:widgetRepaint(self._more_frame, d.x, d.y)
        UIManager:setDirty(nil, "fast", d)
        self:_showMoreMenu()
        return true
    end
    if self._nav_prev_frame and self._nav_prev_frame.dimen
       and ges.pos:intersectWith(self._nav_prev_frame.dimen) then
        self:_flashButton(self._nav_prev_frame, function()
            if self._gallery_mode then self:_galleryGo(-1)
            else self:onShowPrevImage() end
        end)
        return true
    end
    if self._nav_next_frame and self._nav_next_frame.dimen
       and ges.pos:intersectWith(self._nav_next_frame.dimen) then
        self:_flashButton(self._nav_next_frame, function()
            if self._gallery_mode then self:_galleryGo(1)
            else self:onShowNextImage() end
        end)
        return true
    end
    if self._gallery_mode then
        -- thumbnail hit-test: cell rects are relative to the drawer
        -- content origin (same space as the overlap offsets)
        if self._gallery_cells then
            local mf = self.main_frame.dimen
            local ox = mf.x
            local oy = mf.y + self.panel_vgap + self.panel_border
            for _, c in ipairs(self._gallery_cells) do
                if ges.pos:intersectWith(Geom:new{
                    x = ox + c.x, y = oy + c.y, w = c.w, h = c.h }) then
                    self:_exitGallery(c.idx)
                    return true
                end
            end
        end
        return true -- no zoom surface in the gallery
    end
    -- dot indicator: tappable as a quick "jump near here" — precisely
    -- hitting an individual dot isn't the point, so the hitbox is padded
    -- well beyond the dots' own tiny paint area
    if self._pill_dots and self._pill_frame and self._pill_frame.dimen then
        local d = self._pill_frame.dimen
        local pad = Screen:scaleBySize(20)
        local hit = Geom:new{
            x = d.x - pad, y = d.y - pad,
            w = d.w + 2 * pad, h = d.h + 2 * pad,
        }
        if ges.pos:intersectWith(hit) then
            local dots = self._pill_dots
            local dd = dots.dimen or d
            local rel = ges.pos.x - dd.x - dots.dot_r
            local idx = math.floor(rel / dots.pitch + 0.5) + 1
            idx = math.min(math.max(idx, 1), dots.nb)
            if idx ~= (self._images_list_cur or 1) then
                self:switchToImageNum(idx)
            end
            return true
        end
    end
    if self.scale_factor ~= 0 then
        -- zoomed: the pill is a "Revert to 100%" button; single taps
        -- elsewhere do nothing (no image switching while zoomed), but a
        -- double-tap goes back to fit
        if self._pill_frame and self._pill_frame.dimen
           and ges.pos:intersectWith(self._pill_frame.dimen) then
            self.scale_factor = 0
            self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
            self:update()
        else
            self:_checkDoubleTap(ges)
        end
        return true
    end
    self:_checkDoubleTap(ges)
    return true
end

-- Physical page-turn keys (upstream maps PgFwd/PgBack to these when the
-- image is a list): in the gallery they flip grid pages instead.
function GlimpseViewer:onShowNextImage()
    if self._gallery_mode then
        self:_galleryGo(1)
        return true
    end
    return ImageViewer.onShowNextImage(self)
end

function GlimpseViewer:onShowPrevImage()
    if self._gallery_mode then
        self:_galleryGo(-1)
        return true
    end
    return ImageViewer.onShowPrevImage(self)
end

function GlimpseViewer:switchToImageNum(image_num)
    if not self._images_list
       or image_num < 1 or image_num > self._images_list_nb then
        return
    end
    self._cur_rotation = self:_prefFor(image_num).rotation or 0
    self._fit_scale_factor = nil -- different image, different fit
    self._scale_factor_0 = nil
    ImageViewer.switchToImageNum(self, image_num)
    local meta = self.image_metas and self.image_metas[image_num]
    if meta and self.on_image_shown then
        self.on_image_shown(meta, image_num)
    end
end

-- In fit-to-screen mode panning is a no-op, so horizontal swipes act as
-- prev/next (feels like page turns) and other directions are swallowed —
-- upstream would close the viewer on swipe-south at fit, too easy to hit
-- accidentally now that switching is swipe-only (closing stays on
-- tap-outside). Zoomed in, delegate to upstream so swipes keep panning.
function GlimpseViewer:onSwipe(arg, ges)
    if self._gallery_mode then
        local d = ges.direction
        if d == "west" or d == "east" then
            local forward = d == "west"
            if BD.mirroredUILayout() then forward = not forward end
            self:_galleryGo(forward and 1 or -1)
        end
        return true
    end
    if self.scale_factor == 0 then
        local d = ges.direction
        if self._images_list and (d == "west" or d == "east") then
            local forward = d == "west"
            if BD.mirroredUILayout() then forward = not forward end
            if forward then
                self:onShowNextImage()
            else
                self:onShowPrevImage()
            end
        end
        return true
    end
    return ImageViewer.onSwipe(self, arg, ges)
end

-- On the SDL emulator, mouse wheel / two-finger trackpad scroll arrives as
-- a fake pan gesture tagged mousewheel_direction (real devices never send
-- it): treat it as zoom, so pinch can be tested without a touchscreen.
-- Safe with the follow-up pan_release: upstream's onPanRelease only acts
-- when a real pan set _panning.
function GlimpseViewer:onPan(arg, ges)
    if ges and ges.mousewheel_direction and ges.mousewheel_direction ~= 0 then
        if ges.mousewheel_direction > 0 then
            self:onZoomIn(0.2)
        else
            self:onZoomOut(0.2)
        end
        return true
    end
    return ImageViewer.onPan(self, arg, ges)
end

-- Zoom-out floor: never below best-fit. The fit factor is captured while
-- we're still in fit mode (scale_factor == 0 means "fit" upstream, and
-- _refreshScaleFactor is what resolves it to a number in every zoom path);
-- reaching it snaps back to fit mode proper, which recenters the image
-- and re-enables swipe navigation.
-- True only when the image is actually spilling past its fit size —
-- scale_factor ~= 0 alone isn't enough: a restored view can carry a
-- scale_factor equal to fit. Chrome (the "Fit" pill button) should only
-- appear when there's somewhere to revert TO.
function GlimpseViewer:_isOverFit()
    if self.scale_factor == 0 then return false end
    local fit = self._fit_scale_factor or self:_computeFitScaleFactor() or 1
    return self.scale_factor > fit + 0.001
end

-- Best-fit factor for the current image, computed from its dimensions the
-- same way the widget's render resolves scale 0. Used when the fit factor
-- is needed before the viewer has ever been in fit mode (e.g. a restored
-- zoomed view) or before the first render.
function GlimpseViewer:_computeFitScaleFactor()
    local iw = self.image and self.image.getWidth and self.image:getWidth()
    local ih = self.image and self.image.getHeight and self.image:getHeight()
    if iw and ih and iw > 0 and ih > 0 then
        if self._cur_rotation == 90 or self._cur_rotation == 270 then
            iw, ih = ih, iw
        end
        -- capped at 1.5: an image smaller than the content box shows a
        -- bit larger than its native pixel size instead of being blown
        -- up all the way to fill the box (the old cap of exactly 1 read
        -- as needlessly tiny for genuinely small images) — but never
        -- more than what actually fits without spilling over the edges,
        -- so an image with less than 50% headroom just fills the box
        -- instead. This is also the zoom-out floor: such an image can't
        -- be zoomed below this boosted size either.
        return math.min(1.5,
            (self.width - self.image_padding * 2) / iw,
            (self.img_container_h - self.image_padding * 2) / ih)
    end
end

function GlimpseViewer:_refreshScaleFactor()
    if self._gallery_mode then
        -- no zoom in the gallery; also keeps upstream from resolving
        -- scale_factor 0 into a number while no image widget exists
        return
    end
    if self.scale_factor == 0 then
        if self._image_wg then
            self._image_wg:getSize() -- force a render: resolves 0 → fit
        end
        local fit = self._image_wg and self._image_wg:getScaleFactor()
        if not fit or fit <= 0 then
            -- the widget only resolves 0 → fit on its first render; when a
            -- zoom arrives before that (e.g. wheel events in one UI tick),
            -- compute best-fit the same way its render does
            fit = self:_computeFitScaleFactor()
        end
        if fit and fit > 0 then
            self._fit_scale_factor = fit
            self._scale_factor_0 = fit -- lets upstream resolve 0 pre-render
        end
    end
    ImageViewer._refreshScaleFactor(self)
end

function GlimpseViewer:_applyNewScaleFactor(new_factor)
    if self._gallery_mode then return end
    self._fast_refresh = true -- mid-gesture zoom step: skip dithering
    if self._image_wg then
        -- upstream reads the widget's extrema, which need a rendered bb
        self._image_wg:getSize()
    end
    local fit = self._fit_scale_factor
    if not fit then
        -- a restored view opens already zoomed, never passing through fit
        -- mode where the floor is normally captured — compute it now so
        -- zooming out can't escape below best-fit
        fit = self:_computeFitScaleFactor()
        self._fit_scale_factor = fit
    end
    if fit and new_factor <= fit then
        if self.scale_factor ~= 0 then
            self.scale_factor = 0
            self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
            self:update()
        end
        return
    end
    ImageViewer._applyNewScaleFactor(self, new_factor)
end

-- Forked from ImageWidget:panBy — the same crop-offset math on the
-- already rendered bitmap, minus its UIManager:setDirty("all", ...):
-- "all" marks every window dirty, so each pan step repainted the whole
-- book page below the drawer (a full-screen per-pixel Lua blit on
-- SW-invert night devices) and re-blended the shadow. Panning changes
-- nothing outside the image, so repaint the drawer only, undithered.
function GlimpseViewer:panBy(x, y)
    local wg = self._image_wg
    if not wg or not wg._bb then return end
    local cx = (x + wg._offset_x + wg.width / 2) / wg._bb_w
    local cy = (y + wg._offset_y + wg.height / 2) / wg._bb_h
    cx = math.min(math.max(cx, 0.5 - wg._max_off_center_x_ratio),
        0.5 + wg._max_off_center_x_ratio)
    cy = math.min(math.max(cy, 0.5 - wg._max_off_center_y_ratio),
        0.5 + wg._max_off_center_y_ratio)
    local ox = math.floor(cx * wg._bb_w - wg.width / 2)
    local oy = math.floor(cy * wg._bb_h - wg.height / 2)
    if ox == wg._offset_x and oy == wg._offset_y then return end
    wg._offset_x, wg._offset_y = ox, oy
    wg.center_x_ratio, wg.center_y_ratio = cx, cy
    -- keep the viewer's ratios in sync (zoom math and the saved view
    -- state read these, like upstream panBy does)
    self._center_x_ratio, self._center_y_ratio = cx, cy
    self._skip_shadow_paint = true
    self.dithered = false -- mid-gesture step: skip dithering
    local alpha = self.alpha
    self.alpha = false -- see update(): nil would fall back to the class 0.25
    UIManager:setDirty(self, function()
        return "ui", wg.dimen or self.main_frame.dimen, false
    end)
    self.alpha = alpha
end

function GlimpseViewer:_hideCurrentImage()
    local cur = self._images_list_cur
    local meta = self.image_metas and self.image_metas[cur]
    if meta and self.on_hide then
        self.on_hide(meta)
    end
    table.remove(self._images_list, cur)
    if self.image_metas then
        table.remove(self.image_metas, cur)
    end
    local nb = self._images_list_nb - 1
    self._images_list_nb = nb
    if nb < 1 then
        self:onClose()
        UIManager:show(Notification:new{
            text = _("Image hidden. Restore it via the Glimpse menu."),
        })
        return
    end
    if self.image and self.image_disposable and self.image.free then
        self.image:free()
        self.image = nil
    end
    local new_cur = math.min(cur, nb)
    self._cur_rotation = self:_prefFor(new_cur).rotation or 0
    self.image = self._images_list[new_cur]
    if type(self.image) == "function" then
        self.image = self.image()
    end
    self._images_list_cur = new_cur
    self:update()
    UIManager:show(Notification:new{
        text = _("Image hidden. Restore it via the Glimpse menu."),
    })
    local meta2 = self.image_metas and self.image_metas[new_cur]
    if meta2 and self.on_image_shown then
        self.on_image_shown(meta2, new_cur)
    end
end

-- ── plugin ──────────────────────────────────────────────────────────────────

local Glimpse = WidgetContainer:extend{
    name = "glimpse",
    -- also load in the file manager, so the Tools menu entry (and Check
    -- for updates) is always there; book-dependent actions answer with
    -- "No book is open." via _supportedReason
    is_doc_only = false,
    -- GitHub repo the in-plugin updater checks (class field so tests can
    -- point it at a repo with known releases)
    github_repo = "Fank1/glimpse",
}

function Glimpse:onDispatcherRegisterActions()
    Dispatcher:registerAction("glimpse_show", {
        category = "none",
        event = "GlimpseShow",
        title = _("Glimpse: book images"),
        reader = true,
    })
end

function Glimpse:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Glimpse:onGlimpseShow()
    self:showViewer()
    return true
end

function Glimpse:onCloseDocument()
    -- the decoded-bitmap cache slot (see showViewer) is per book
    if self._bb_cache then
        if self._bb_cache.bb then self._bb_cache.bb:free() end
        self._bb_cache = nil
    end
end

-- ── settings ────────────────────────────────────────────────────────────────

function Glimpse:getScope()
    return G_reader_settings:readSetting(SCOPE_KEY) or "read_so_far"
end

function Glimpse:getFilterLevel()
    return G_reader_settings:readSetting(FILTER_KEY) == "all"
        and "all" or "balanced"
end

function Glimpse:_hiddenPaths()
    return (self.ui.doc_settings and
            self.ui.doc_settings:readSetting("glimpse_hidden")) or {}
end

-- Per-image, per-book viewer preferences: { [path] = {rotation=90} }
function Glimpse:_imgPrefs()
    return (self.ui.doc_settings and
            self.ui.doc_settings:readSetting("glimpse_img_prefs")) or {}
end

function Glimpse:_setImgPref(path, key, value)
    local all = self:_imgPrefs()
    local p = all[path] or {}
    p[key] = value
    local has = false
    for _ in pairs(p) do has = true break end
    all[path] = has and p or nil
    self.ui.doc_settings:saveSetting("glimpse_img_prefs", all)
end

function Glimpse:_hiddenCount()
    local n = 0
    for _ in pairs(self:_hiddenPaths()) do n = n + 1 end
    return n
end

-- ── document access ─────────────────────────────────────────────────────────

function Glimpse:_supportedReason()
    local doc = self.ui and self.ui.document
    if not doc or not doc.file then
        return false, _("No book is open.")
    end
    if not scanner then
        return false, _("Glimpse failed to load its scanner module. Try reinstalling the plugin.")
    end
    -- crengine documents expose getDocumentFileContent; paged formats
    -- (PDF/DjVu) do not, and their APIs must not be touched at all
    if type(doc.getDocumentFileContent) ~= "function" then
        return false, _("Glimpse works with EPUB books only (this document format is not supported).")
    end
    return true
end

-- Returns read_file(path) -> data|nil, plus a close() for the fallback
-- archive handle. Primary path is crengine's own archive access; libarchive
-- is the fallback for entries crengine won't hand over.
function Glimpse:_makeReader()
    local doc = self.ui.document
    local arc
    local function read_file(path)
        local ok, data = pcall(doc.getDocumentFileContent, doc, path)
        if ok and type(data) == "string" and #data > 0 then
            return data
        end
        if arc == nil then
            local ok2, Archiver = pcall(require, "ffi/archiver")
            if ok2 and Archiver and Archiver.Reader then
                local r = Archiver.Reader:new()
                arc = r:open(doc.file) and r or false
            else
                arc = false
            end
        end
        if arc then
            local ok3, d = pcall(arc.extractToMemory, arc, path)
            if ok3 and type(d) == "string" and #d > 0 then
                return d
            end
        end
        return nil
    end
    local function close()
        if arc then pcall(arc.close, arc) end
        arc = nil
    end
    return read_file, close
end

-- 1-based spine position of the reading position, from the xpointer's
-- DocFragment index (crengine maps spine items to DocFragments in order).
-- Chapter granularity is deliberate: an image in the chapter you are
-- currently reading should be visible.
function Glimpse:_currentSpineIndex()
    local doc = self.ui.document
    if type(doc.getXPointer) ~= "function" then return nil end
    local ok, xp = pcall(doc.getXPointer, doc)
    if ok and type(xp) == "string" then
        local n = xp:match("DocFragment%[(%d+)%]")
        if n then return tonumber(n) end
    end
    return nil
end

-- ── scan + sidecar cache ────────────────────────────────────────────────────

function Glimpse:_cachePath()
    local dir = DataStorage:getDataDir() .. "/glimpse"
    lfs.mkdir(dir)
    local key = self.ui.document.file:gsub("[/\\]", "_"):gsub("[^%w%-%._]", "_")
    if #key > 180 then key = key:sub(-180) end
    return dir .. "/" .. key .. ".lua"
end

function Glimpse:_getScan(force)
    if self._scan and not force then
        return self._scan
    end
    local doc = self.ui.document
    local a = lfs.attributes(doc.file)
    -- record mtime as read here and compare by equality later (never compare
    -- against the cache file's own mtime: clock skew on shared mounts)
    local mtime = a and a.modification or 0
    local size = a and a.size or 0
    local cache = LuaSettings:open(self:_cachePath())

    if not force then
        local c = cache:readSetting("scan")
        if c and c.version == scanner.VERSION
           and cache:readSetting("mtime") == mtime
           and cache:readSetting("size") == size then
            self._scan = c
            return c
        end
    end

    local read_file, close = self:_makeReader()
    local ok, result, err = pcall(scanner.scan, read_file)
    close()
    if not ok then
        logger.warn("Glimpse: scan failed:", result)
        self._scan_err = "error"
        return nil
    end
    if not result then
        self._scan_err = err or "error"
        return nil
    end
    self._scan = result
    self._scan_err = nil
    cache:saveSetting("mtime", mtime)
    cache:saveSetting("size", size)
    cache:saveSetting("scan", result)
    cache:flush()
    return result
end

-- ── rendering ───────────────────────────────────────────────────────────────

function Glimpse:_render(read_file, im)
    local data = read_file(im.path)
    if not data and im.raw_path and im.raw_path ~= im.path then
        data = read_file(im.raw_path)
    end
    local bb
    if data then
        if im.format == "svg" or im.is_svg_doc then
            local ok, res = pcall(RenderImage.renderSVGImageDataWithCRengine,
                                  RenderImage, data, #data)
            if ok then bb = res end
        end
        if not bb then
            local ok, res = pcall(RenderImage.renderImageData,
                                  RenderImage, data, #data)
            if ok then bb = res end
        end
    end
    if not bb then
        logger.warn("Glimpse: could not render image", im.path)
        bb = RenderImage:renderCheckerboard(
            math.floor(Screen:getWidth() / 2),
            math.floor(Screen:getHeight() / 2),
            Screen.bb:getType())
    end
    return bb
end

-- ── the viewer flow ─────────────────────────────────────────────────────────

-- whole_book_once: bypass the read-so-far scope for this one opening
-- (the empty state's "Search whole book" offer) without touching the
-- user's scope setting.
function Glimpse:showViewer(whole_book_once)
    -- a second trigger while the drawer is open (the same gesture again,
    -- or the menu entry) toggles it closed instead of stacking viewers
    if self._viewer then
        self._viewer:onClose()
        return
    end
    local ok, msg = self:_supportedReason()
    if not ok then
        UIManager:show(InfoMessage:new{ text = msg })
        return
    end

    local scan = self._scan
    if not scan then
        local info = InfoMessage:new{ text = _("Scanning book for images…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        scan = self:_getScan()
        UIManager:close(info)
        -- repaint the page below NOW: the viewer is translucent (shadow,
        -- corner notches), and without this the message's outline stays
        -- visible through those areas until the next full repaint
        UIManager:forceRePaint()
    end
    if not scan then
        local why
        if self._scan_err == "no_container" or self._scan_err == "no_opf" then
            why = _("Glimpse works with EPUB books only.")
        else
            why = _("Could not scan this book for images.")
        end
        UIManager:show(InfoMessage:new{ text = why })
        return
    end

    local level = self:getFilterLevel()
    local imgs = scanner.filter(scan.images, level)

    -- per-book hidden images (before scope, so the gallery heading can
    -- count what the chapter scope holds back without counting these)
    local hidden = self:_hiddenPaths()
    do
        local kept = {}
        for _, im in ipairs(imgs) do
            if not hidden[im.path] then
                kept[#kept + 1] = im
            end
        end
        imgs = kept
    end

    -- scope: drop images beyond the reading position
    local scope_hidden = 0
    if self:getScope() == "read_so_far" and not whole_book_once then
        local cur = self:_currentSpineIndex()
        if cur then
            local kept = {}
            for _, im in ipairs(imgs) do
                if im.spine_index <= cur then
                    kept[#kept + 1] = im
                end
            end
            scope_hidden = #imgs - #kept
            imgs = kept
        end
    end

    if #imgs == 0 then
        if self:getScope() == "read_so_far" and not whole_book_once then
            -- "yet" hints that more may unlock as you read; offer a
            -- one-time whole-book look without changing the setting
            UIManager:show(ConfirmBox:new{
                text = _("No images to show yet."),
                ok_text = _("Search whole book"),
                ok_callback = function()
                    self:showViewer(true)
                end,
            })
        else
            UIManager:show(InfoMessage:new{ text = _("No images to show.") })
        end
        return
    end

    -- lazy render functions: one image decoded at a time, freed on switch;
    -- "invert in night mode" (a global setting) is applied here so
    -- re-renders pick up setting and night-mode changes live.
    -- Night comes in two flavors (see _paintPanel for the long story):
    --   * SW-invert fb (inverse flag set): the scaled copies are blitted
    --     flag-matched and RAW (see _new_image_wg), so the decoded bitmap
    --     must hold the FINAL raw values — the negative when the checkbox
    --     is CHECKED, untouched when unchecked. Baking this here, once
    --     per decode, replaces the invertRect the render hook used to run
    --     on every re-scaled copy (it doubled night zoom cost vs day).
    --   * HW-invert panel (flag 0): the display inverts everything, so
    --     bake the OPPOSITE — inverted when UNCHECKED, so the double
    --     inversion restores the original look.
    local read_file, close_reader = self:_makeReader()
    local images_list = { image_disposable = true }
    -- Cap decoded bitmaps at 2× the drawer's content box (one C-speed,
    -- aspect-preserving downscale at load): ImageWidget rescales from the
    -- source bitmap on EVERY zoom/pan render, so multi-megapixel originals
    -- make each pinch step (and the night-mode image blit) proportionally
    -- slower. Fit and double zoom stay 1:1 sharp; only zooming beyond 2×
    -- upscales slightly.
    local cap_w = 2 * math.floor(Screen:getWidth() * GlimpseViewer.panel_ratio)
    local cap_h = 2 * Screen:getHeight()
    for i, im in ipairs(imgs) do
        images_list[i] = function()
            local night = G_reader_settings:isTrue("night_mode")
            local sw = Screen.bb.getInverse and Screen.bb:getInverse() == 1
            local checked = G_reader_settings:isTrue(INVERT_KEY)
            -- single-slot decoded-bitmap cache: reopening on the image
            -- you left (the common "peek at the map again" flow) skips
            -- the decode and cap-scale — on device that is most of the
            -- open time. The key bakes in everything baked into pixels.
            local key = im.path .. "|" .. tostring(night)
                .. tostring(checked) .. tostring(sw)
            local slot = self._bb_cache
            if slot and slot.key == key and slot.bb then
                -- hand out a copy: the viewer owns and frees what we return
                return slot.bb:copy()
            end
            local bb = self:_render(read_file, im)
            if bb then
                local w, h = bb:getWidth(), bb:getHeight()
                local s = math.min(1, cap_w / w, cap_h / h)
                if s < 1 then
                    local scaled = RenderImage:scaleBlitBuffer(bb,
                        math.floor(w * s + 0.5), math.floor(h * s + 0.5), true)
                    if scaled then bb = scaled end
                end
            end
            if bb and night and (sw and checked or not sw and not checked) then
                pcall(bb.invertRect, bb, 0, 0, bb:getWidth(), bb:getHeight())
            end
            if bb then
                if slot and slot.bb then slot.bb:free() end
                self._bb_cache = { key = key, bb = bb:copy() }
            end
            return bb
        end
    end

    -- reopen on the image viewed last time (per book), if still in the list
    local start = 1
    local last = self.ui.doc_settings:readSetting("glimpse_last")
    if last then
        for i, im in ipairs(imgs) do
            if im.path == last then
                start = i
                break
            end
        end
    end

    local viewer
    viewer = GlimpseViewer:new{
        image = images_list,
        image_metas = imgs,
        -- for the gallery heading: images the chapter scope holds back
        gallery_hidden_count = scope_hidden,
        images_keep_pan_and_zoom = false,
        -- hold refreshes until the initial state is fully built (see below)
        _suppress_refresh = true,
        on_image_shown = function(meta)
            self.ui.doc_settings:saveSetting("glimpse_last", meta.path)
        end,
        on_hide = function(meta)
            local h = self:_hiddenPaths()
            h[meta.path] = true
            self.ui.doc_settings:saveSetting("glimpse_hidden", h)
        end,
        get_pref = function(meta)
            return self:_imgPrefs()[meta.path] or {}
        end,
        set_pref = function(meta, key, value)
            self:_setImgPref(meta.path, key, value)
        end,
        on_show_in_book = function(meta)
            if not meta.spine_index or not self.ui.rolling then return end
            if self.ui.link then
                self.ui.link:addCurrentLocationToStack()
            end
            self.ui.rolling:onGotoXPointer(
                string.format("/body/DocFragment[%d]", meta.spine_index))
        end,
        -- the viewer closed itself on a G-sensor rotation: re-layout the
        -- reader, then reopen (zoom/pan persistence restores the view)
        on_rotate = function(rotation)
            self.ui.view:onSetRotationMode(rotation)
            self:showViewer(whole_book_once)
        end,
    }
    self._viewer = viewer
    -- release the fallback archive handle together with the viewer; also
    -- remember the view as it was left (zoom level and pan position of
    -- the image on display) so reopening puts the user right back there.
    -- At fit the entry is cleared — the image itself is already restored
    -- via glimpse_last.
    local orig_close_widget = viewer.onCloseWidget
    viewer.onCloseWidget = function(v)
        local meta = v.image_metas and v.image_metas[v._images_list_cur or 1]
        local view
        if meta and v.scale_factor ~= 0 then
            view = {
                path = meta.path,
                scale = v.scale_factor,
                cx = v._center_x_ratio,
                cy = v._center_y_ratio,
            }
        end
        self.ui.doc_settings:saveSetting("glimpse_view", view)
        self._viewer = nil
        close_reader()
        return orig_close_widget(v)
    end

    -- Build the complete initial state (remembered image, restored zoom)
    -- BEFORE showing: every update() is otherwise its own e-ink refresh,
    -- making the drawer visibly repaint up to three times on open.
    if start > 1 then
        viewer:switchToImageNum(start)
    end
    self.ui.doc_settings:saveSetting("glimpse_last", imgs[start].path)
    local view = self.ui.doc_settings:readSetting("glimpse_view")
    if view and view.path == imgs[start].path
            and type(view.scale) == "number" and view.scale ~= 0 then
        viewer.scale_factor = view.scale
        viewer._center_x_ratio = view.cx or 0.5
        viewer._center_y_ratio = view.cy or 0.5
        viewer:update()
    end
    viewer._suppress_refresh = nil
    -- The framebuffer already shows the page exactly as-is, so skip the
    -- numeric-alpha below-repaint on open (a full crengine redraw — and
    -- a full-screen per-pixel Lua blit on SW-invert night devices): the
    -- shadow blends over the live fb instead. If a below repaint IS
    -- already queued (menu close, rotation, ConfirmBox), stack order
    -- still paints it before us, so the blend stays accumulation-free.
    -- false, not nil: nil falls back to the class alpha via the metatable.
    viewer.alpha = false
    -- one dithered refresh covering the drawer and its gradient shadow
    UIManager:show(viewer, Device:hasKaleidoWfm() and "partial" or "ui",
        Geom:new{
            x = 0, y = 0,
            w = math.min(Screen:getWidth(), viewer._panel_w
                + 2 * viewer.shadow_width - viewer.shadow_overlap + 1),
            h = Screen:getHeight(),
        }, nil, nil, true)
    viewer.alpha = nil -- back to the class default for later paths
end

-- ── GitHub auto-update ──────────────────────────────────────────────────────
-- Ported from Footcream. Checks the repo's releases, downloads the attached
-- .zip and installs it over this plugin folder (with backup + rollback).
-- Additions over Footcream:
--   * optional GitHub token (GH_TOKEN_KEY): lets the updater read a PRIVATE
--     repo — release info via the API, assets via the API asset URL with
--     Accept: application/octet-stream. The Authorization header is only
--     ever sent to api.github.com — GitHub's CDN rejects requests that
--     carry both auth and the signed redirect URL.
--   * pre-release channel (PRERELEASE_KEY): /releases/latest NEVER returns
--     releases marked "pre-release", so those form a test channel invisible
--     to normal update checks; the toggle opts this device in.
local GH_TOKEN_KEY = "glimpse_github_token"
local PRERELEASE_KEY = "glimpse_update_prerelease"

local function _installed_version()
    local ok, meta = pcall(dofile, _PLUGIN_DIR .. "/_meta.lua")
    if ok and type(meta) == "table" and meta.version then
        return tostring(meta.version)
    end
    return "0"
end

-- "v1.2" / "1.2.0" → {1,2,(0)}; numeric, dot-separated, leading v optional.
local function _parse_ver(s)
    local t = {}
    for n in tostring(s):gsub("^[vV]", ""):gmatch("%d+") do
        t[#t + 1] = tonumber(n)
    end
    return t
end

local function _ver_gt(a, b) -- is version a strictly newer than b?
    local va, vb = _parse_ver(a), _parse_ver(b)
    for i = 1, math.max(#va, #vb) do
        local x, y = va[i] or 0, vb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

local function _json_decode(s)
    local ok, rj = pcall(require, "rapidjson")
    if ok and rj and rj.decode then
        local ok2, t = pcall(rj.decode, s)
        if ok2 then return t end
    end
    local ok3, J = pcall(require, "json") -- fallback if rapidjson is missing
    if ok3 and J and J.decode then
        local ok4, t = pcall(J.decode, s)
        if ok4 then return t end
    end
    return nil
end

local function _file_exists(path)
    local f = io.open(path)
    if f then f:close() return true end
    return false
end

-- HTTPS GET. With dest_path, streams the body to that file (for the zip);
-- otherwise returns the body string. Follows redirects manually (GitHub
-- asset URLs 302 to a CDN host, which luasec won't re-handshake for).
local function _http_fetch(url, dest_path, accept, depth)
    depth = depth or 0
    if depth > 6 then return nil, "too many redirects" end
    local ltn12      = require("ltn12")
    local socketutil = require("socketutil")
    local socket_url = require("socket.url")
    local requester  = url:match("^https:") and require("ssl.https")
                                             or require("socket.http")

    local body, fh, sink = {}, nil, nil
    if dest_path then
        fh = io.open(dest_path, "wb")
        if not fh then return nil, "cannot write " .. dest_path end
        sink = ltn12.sink.file(fh)
    else
        sink = ltn12.sink.table(body)
    end

    local headers = { ["User-Agent"] = "glimpse-updater" }
    if accept then headers["Accept"] = accept end
    local token = G_reader_settings:readSetting(GH_TOKEN_KEY)
    if token and token ~= "" and url:match("^https://api%.github%.com/") then
        headers["Authorization"] = "token " .. token
    end

    -- KOReader's standard short timeouts (10s/op, 30s total): socketutil
    -- has globally overridden socket.tcp, so these bound connect/read.
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT,
        socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, resp_headers = requester.request{
        url      = url,
        method   = "GET",
        headers  = headers,
        sink     = sink,
        redirect = false, -- handled below
    }
    socketutil:reset_timeout()

    if not ok then
        local msg = tostring(code)
        if msg:find("host or service", 1, true)
           or msg:find("not known", 1, true) then
            msg = "couldn't reach GitHub (network/DNS) — check WiFi and try again"
        end
        return nil, "network error: " .. msg
    end
    code = tonumber(code)
    if code and code >= 300 and code < 400 then
        local loc = resp_headers and (resp_headers.location or resp_headers.Location)
        if not loc then return nil, "redirect without Location" end
        return _http_fetch(socket_url.absolute(url, loc), dest_path, accept, depth + 1)
    end
    if not code or code >= 400 then return nil, "HTTP " .. tostring(code) end
    if dest_path then return true end
    return table.concat(body)
end

-- After unzipping, find the directory that holds both main.lua and
-- _meta.lua, wherever it sits in the archive (asset-zip root,
-- "glimpse.koplugin/", or a source zip's "<repo>-<tag>/plugin/").
local function _find_plugin_root(dir)
    local p = io.popen('find "' .. dir .. '" -name main.lua 2>/dev/null')
    if not p then return nil end
    for line in p:lines() do
        local d = line:match("^(.*)/[^/]*$")
        local mf = d and io.open(d .. "/_meta.lua")
        if mf then mf:close() p:close() return d end
    end
    p:close()
    return nil
end

function Glimpse._confirm(text, ok_text, ok_callback, cancel_text)
    -- Headless test driver: accept every confirmation without showing the
    -- dialog. Set only by VM verification runs — never exists on a device.
    if os.getenv("GLIMPSE_AUTOCONFIRM") == "1" then
        logger.info("Glimpse: auto-confirmed — " .. (ok_text or "?"))
        ok_callback()
        return
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title       = text,
        title_align = "left",
        buttons = {{
            {
                text = cancel_text or _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = ok_text,
                callback = function()
                    UIManager:close(dialog)
                    ok_callback()
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

-- Entry point (menu callback): ensure we're online, then check releases.
-- Wrapped in Trapper so the network wait shows a dismissable spinner.
function Glimpse:_checkForUpdate()
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function() self:_runUpdateCheck(Trapper) end)
    end)
end

function Glimpse:_runUpdateCheck(Trapper)
    local pre = G_reader_settings:isTrue(PRERELEASE_KEY)
    local api = "https://api.github.com/repos/" .. self.github_repo
        .. (pre and "/releases?per_page=10" or "/releases/latest")
    -- fetch in a subprocess so the UI stays responsive and dismissable
    local completed, body = Trapper:dismissableRunInSubprocess(function()
        local b, err = _http_fetch(api)
        return b or ("ERR:" .. tostring(err))
    end, _("Checking for updates…"), true)
    if not completed then return end -- dismissed by the user
    if not body or body:match("^ERR:") then
        UIManager:show(InfoMessage:new{
            text = _("Update check failed:") .. "\n"
                .. ((body or "no response"):gsub("^ERR:", "")) })
        return
    end
    local rel
    if pre then
        -- the release LIST includes pre-releases; take the newest non-draft
        local list = _json_decode(body)
        if type(list) == "table" then
            for _, r in ipairs(list) do
                if type(r) == "table" and not r.draft then
                    rel = r
                    break
                end
            end
        end
    else
        rel = _json_decode(body)
    end
    if not rel or not rel.tag_name then
        UIManager:show(InfoMessage:new{
            text = _("Could not read the latest release info.") })
        return
    end
    local installed = _installed_version()
    if not _ver_gt(rel.tag_name, installed) then
        UIManager:show(InfoMessage:new{
            text = T(_("You're up to date (v%1)."), installed) })
        return
    end
    -- prefer an attached .zip asset; private repos must download it through
    -- the API asset URL (browser_download_url needs a browser session)
    local browser_url, api_asset_url
    for _, a in ipairs(rel.assets or {}) do
        if a.name and a.name:match("%.zip$") then
            browser_url = a.browser_download_url
            api_asset_url = a.url
            break
        end
    end
    local token = G_reader_settings:readSetting(GH_TOKEN_KEY)
    local dl_url, dl_accept
    if api_asset_url and token and token ~= "" then
        dl_url, dl_accept = api_asset_url, "application/octet-stream"
    else
        dl_url = browser_url or rel.zipball_url
    end
    if not dl_url then
        UIManager:show(InfoMessage:new{
            text = _("No downloadable release package found.") })
        return
    end
    local label = rel.tag_name .. (rel.prerelease and " (pre-release)" or "")
    Glimpse._confirm(
        T(_("Update available: %1\n(installed: v%2)\n\nDownload and install now?"),
            label, installed),
        _("Update"), function()
            local Trapper2 = require("ui/trapper")
            Trapper2:wrap(function()
                self:_installUpdate(Trapper2, dl_url, dl_accept, rel.tag_name)
            end)
        end)
end

function Glimpse:_installUpdate(Trapper, dl_url, dl_accept, tag)
    local base = DataStorage:getDataDir() .. "/glimpse"
    lfs.mkdir(base)
    local tmp_zip    = base .. "/update.zip"
    local tmp_dir    = base .. "/update"
    local plugin_dir = _PLUGIN_DIR
    local backup     = plugin_dir .. ".bak"

    -- download → unzip → install in ONE subprocess so the UI never freezes
    -- and the message stays dismissable; returns "OK" or "ERR:<reason>".
    -- (No UIManager use inside — not allowed in the subprocess.)
    local completed, result = Trapper:dismissableRunInSubprocess(function()
        os.execute('rm -rf "' .. tmp_dir .. '" "' .. tmp_zip .. '" "' .. backup .. '"')
        local ok, err = _http_fetch(dl_url, tmp_zip, dl_accept)
        if not ok then return "ERR:Download failed: " .. tostring(err) end
        os.execute('mkdir -p "' .. tmp_dir .. '"')
        os.execute('unzip -o "' .. tmp_zip .. '" -d "' .. tmp_dir .. '" >/dev/null 2>&1')
        local src = _find_plugin_root(tmp_dir)
        if not src then return "ERR:Update package didn't contain the plugin files." end
        os.execute('cp -rf "' .. plugin_dir .. '" "' .. backup .. '"')
        os.execute('cp -rf "' .. src .. '/." "' .. plugin_dir .. '/"')
        if not _file_exists(plugin_dir .. "/main.lua") then
            os.execute('rm -rf "' .. plugin_dir .. '" && mv "' .. backup .. '" "' .. plugin_dir .. '"')
            os.execute('rm -rf "' .. tmp_dir .. '" "' .. tmp_zip .. '"')
            return "ERR:Install failed — restored the previous version."
        end
        os.execute('rm -rf "' .. backup .. '" "' .. tmp_dir .. '" "' .. tmp_zip .. '"')
        return "OK"
    end, T(_("Updating to %1…"), tag), true)

    if not completed then
        -- dismissed → the subprocess was SIGKILLed; if it died mid-copy,
        -- restore from the backup so we never leave a broken plugin
        if _file_exists(backup .. "/main.lua")
           and not _file_exists(plugin_dir .. "/main.lua") then
            os.execute('rm -rf "' .. plugin_dir .. '" && mv "' .. backup .. '" "' .. plugin_dir .. '"')
        end
        os.execute('rm -rf "' .. backup .. '" "' .. tmp_dir .. '" "' .. tmp_zip .. '"')
        return
    end
    if result == "OK" then
        Glimpse._confirm(
            T(_("Updated to %1.\nRestart KOReader now to load it?"), tag),
            _("Restart"), function() UIManager:restartKOReader() end,
            _("Later"))
    else
        UIManager:show(InfoMessage:new{
            text = (type(result) == "string" and result:gsub("^ERR:", ""))
                or _("Update failed.") })
    end
end

-- ── menu ────────────────────────────────────────────────────────────────────

function Glimpse:addToMainMenu(menu_items)
    menu_items.glimpse = {
        text = _("Glimpse"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:_menuItems()
        end,
    }
end

-- Which gesture (if any) currently triggers Glimpse in this context —
-- read from the gestures plugin's live table for the current mode
-- (reader vs file manager). Keys are prettified ("hold_top_left_corner"
-- → "Hold top left corner"); the friendly-name table is a local of the
-- gestures plugin and not reachable.
function Glimpse:_gestureLabel()
    local g = self.ui and self.ui.gestures
    local found = {}
    if g and type(g.gestures) == "table" then
        for ges, actions in pairs(g.gestures) do
            if type(actions) == "table" and actions.glimpse_show then
                found[#found + 1] = ges
            end
        end
    end
    if #found == 0 then return _("Gesture: none set") end
    table.sort(found)
    for i, ges in ipairs(found) do
        found[i] = ges:gsub("_", " "):gsub("^%l", string.upper)
    end
    return T(_("Gesture: %1"), table.concat(found, ", "))
end

function Glimpse:_menuItems()
    local function scope_item(value, text, help)
        return {
            text = text,
            help_text = help,
            radio = true,
            checked_func = function() return self:getScope() == value end,
            callback = function()
                G_reader_settings:saveSetting(SCOPE_KEY, value)
            end,
        }
    end
    return {
        {
            -- read-only info row: which gesture opens Glimpse here
            -- (dimmed so it doesn't read as an action)
            text_func = function() return self:_gestureLabel() end,
            enabled_func = function() return false end,
            help_text = _("Assign or change it under Taps and gestures → Gesture manager → (pick a gesture) → Reader → 'Glimpse: book images'."),
        },
        {
            text = _("Show book images"),
            help_text = _("Browse the maps, family trees and other reference images found in this book, without losing your reading position. Tip: bind the gesture action 'Glimpse: book images' for one-touch access."),
            callback = function(touchmenu_instance)
                if touchmenu_instance then
                    touchmenu_instance:closeMenu()
                end
                -- let the menu-close animation finish, or the page repaint
                -- lands on top of the viewer
                UIManager:scheduleIn(0.3, function()
                    self:showViewer()
                end)
            end,
            separator = true,
        },
        {
            text_func = function()
                return self:getScope() == "whole_book"
                    and _("Mode: all images")
                    or _("Mode: up to current chapter")
            end,
            sub_item_table = {
                scope_item("read_so_far", _("Show images up to current chapter"),
                    _("Images that appear beyond your current position stay hidden, so you can't spoil yourself. Granularity is per chapter: images in the chapter you are currently reading are shown.")),
                scope_item("whole_book", _("Show all images"),
                    _("Show reference images from anywhere in the book, including parts you haven't reached yet.")),
            },
        },
        {
            text = _("Invert in Night Mode"),
            help_text = _("While KOReader's night mode is on, show images inverted (light lines on a dark background). Also toggleable from the viewer's ⋯ menu."),
            checked_func = function()
                return G_reader_settings:isTrue(INVERT_KEY)
            end,
            callback = function()
                G_reader_settings:saveSetting(INVERT_KEY,
                    not G_reader_settings:isTrue(INVERT_KEY))
            end,
        },
        {
            text = _("Show Prev/Next Buttons"),
            help_text = _("Show ‹ and › buttons in the viewer for switching between images, as an alternative to swiping. A button is grayed out when there is no image on its side."),
            checked_func = function()
                return G_reader_settings:isTrue(NAV_BUTTONS_KEY)
            end,
            callback = function()
                G_reader_settings:saveSetting(NAV_BUTTONS_KEY,
                    not G_reader_settings:isTrue(NAV_BUTTONS_KEY))
            end,
        },
        {
            text_func = function()
                local n = self:_hiddenCount()
                if n > 0 then
                    return T(_("Restore hidden images (%1)"), n)
                end
                return _("Restore hidden images")
            end,
            help_text = _("Bring back images removed with 'Remove image from collection' in the viewer's ⋯ menu. Removal is remembered per book."),
            enabled_func = function() return self:_hiddenCount() > 0 end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.ui.doc_settings:delSetting("glimpse_hidden")
                UIManager:show(Notification:new{ text = _("Hidden images restored.") })
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        },
        {
            text = _("Rescan this book"),
            help_text = _("Glimpse caches its scan of the book. Use this if the book file was replaced or images seem out of date."),
            keep_menu_open = true,
            separator = true,
            callback = function()
                local okay = self:_supportedReason()
                if not okay then return end
                self._scan = nil
                local info = InfoMessage:new{ text = _("Scanning book for images…") }
                UIManager:show(info)
                UIManager:forceRePaint()
                local scan = self:_getScan(true)
                UIManager:close(info)
                if scan then
                    UIManager:show(Notification:new{
                        text = T(_("Found %1 image(s)."), #scan.images),
                    })
                else
                    UIManager:show(Notification:new{ text = _("Scan failed.") })
                end
            end,
        },
        {
            text = _("Advanced"),
            sub_item_table = {
                {
                    text = _("Hide irrelevant images"),
                    help_text = _("Hide covers, publisher logos, ornaments and other non-reference imagery, keeping maps, family trees, diagrams and illustrations. Turn off to see every image in the book. A wrongly kept image can be removed via the viewer's ⋯ menu."),
                    checked_func = function()
                        return self:getFilterLevel() ~= "all"
                    end,
                    callback = function()
                        local now_on = self:getFilterLevel() ~= "all"
                        G_reader_settings:saveSetting(FILTER_KEY,
                            now_on and "all" or "balanced")
                    end,
                },
                {
                    text = _("Show image captions (beta)"),
                    help_text = _("Show the image's caption from the book, overlaid in the viewer's top-left corner."),
                    checked_func = function()
                        return G_reader_settings:nilOrTrue(CAPTIONS_KEY)
                    end,
                    callback = function()
                        G_reader_settings:flipNilOrTrue(CAPTIONS_KEY)
                    end,
                },
            },
        },
        {
            text = _("Updates"),
            sub_item_table = {
                {
                    text_func = function()
                        return T(_("Check for updates (v%1)"), _installed_version())
                    end,
                    callback = function() self:_checkForUpdate() end,
                },
                {
                    text = _("Include pre-release versions"),
                    help_text = _("Also offer releases marked as pre-release on GitHub — test builds published before a proper release. Normal update checks never see those."),
                    checked_func = function()
                        return G_reader_settings:isTrue(PRERELEASE_KEY)
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(PRERELEASE_KEY,
                            not G_reader_settings:isTrue(PRERELEASE_KEY))
                    end,
                },
            },
        },
    }
end

return Glimpse
