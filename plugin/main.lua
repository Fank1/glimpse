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
local DocSettings = require("docsettings")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
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
local TileCacheItem = require("document/tilecacheitem")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local md5 = require("ffi/sha2").md5
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
local ENABLED_KEY = "glimpse_enabled"          -- master on/off for the gesture + Open Glimpse, ON by default (nilOrTrue)
local INVERT_KEY = "glimpse_invert_night"
local NAV_BUTTONS_KEY = "glimpse_nav_buttons" -- prev/next buttons, off by default
local ZOOMCTL_KEY = "glimpse_zoom_control"     -- overlay −/fit/+ zoom pill, off by default
local CAPTIONS_KEY = "glimpse_captions"        -- caption overlay, ON by default (nilOrTrue)
local TOP_MENU_KEY = "glimpse_top_menu_zone"   -- tap top strip → KOReader top menu, ON by default (nilOrTrue)
local SHADOW_KEY = "glimpse_disable_shadow"    -- drop the drawer's gradient shadow, OFF by default (e-ink ghost source)
local FAST_SWITCH_KEY = "glimpse_fast_image_switch" -- image switch uses a flashless partial refresh (may ghost); ON by default (nilOrTrue)
local SUPPRESS_UNSUPPORTED_KEY = "glimpse_suppress_unsupported" -- silence the "EPUB only" notice on unsupported files, OFF by default
local BOOKMARKS_KEY = "glimpse_include_bookmarks" -- include the user's dogear-bookmarked pages (rendered thumbnails) in the Gallery, OFF by default
local LAYOUT_RIGHT_KEY = "glimpse_layout_right" -- drawer anchored to the RIGHT screen edge instead of the left, OFF by default
local MAX_ZOOM_KEY = "glimpse_max_zoom"        -- zoom ceiling as a multiple of native resolution (double-tap target + pinch clamp)
local GESTURE_TIP_KEY = "glimpse_gesture_tip_shown" -- one-time menu-open nudge to bind a gesture
-- viewer gesture toggles (Settings → Gestures), all ON by default (nilOrTrue)
local GESTURE_DOUBLETAP_KEY = "glimpse_gesture_doubletap" -- double-tap → maximum zoom
local GESTURE_SWIPE_KEY = "glimpse_gesture_swipe"         -- swipe ‹/› → prev/next image
local GESTURE_PINCH_KEY = "glimpse_gesture_pinch"         -- pinch/spread → zoom out/in

-- Zoom ceiling (multiple of the image's native resolution), user-configurable
-- under Advanced → Maximum zoom. Double-tap jumps here and pinch stops here.
-- 2.0 (200%) by default; the menu offers 150%–400%.
local DEFAULT_MAX_ZOOM = 2.0
local MAX_ZOOM_CHOICES = { 1.5, 2.0, 2.5, 3.0, 4.0 }
local function _maxZoomMult()
    local v = tonumber(G_reader_settings:readSetting(MAX_ZOOM_KEY))
    return v or DEFAULT_MAX_ZOOM
end
-- Which actions appear in the viewer's ⋯ popup ("Quick Actions", configured
-- from the plugin menu). Table order = popup order; `default` = shown unless
-- the user has toggled it. The six that were always in the popup default ON;
-- the two promoted from the plugin menu (prevnext/captions) default OFF, so
-- out of the box the popup is exactly what it was before. (Restoring ignored
-- images lives in the Gallery's Ignored tab and the plugin menu, so it is no
-- longer a ⋯ Quick Action.)
local QUICK_ACTIONS_KEY = "glimpse_quick_actions"
local QUICK_ACTIONS = {
    { key = "hide",       default = true  },
    { key = "mode",       default = true  },
    { key = "rotate",     default = true  },
    { key = "showinbook", default = true  },
    { key = "prevnext",   default = false },
    { key = "zoomctl",    default = false },
    { key = "captions",   default = false },
    { key = "bookmarks",  default = false },
    { key = "invert",     default = true  },
    { key = "layout",     default = false },
}
local function _quick_enabled(key)
    local cfg = G_reader_settings:readSetting(QUICK_ACTIONS_KEY)
    if type(cfg) == "table" and cfg[key] ~= nil then return cfg[key] end
    for _, d in ipairs(QUICK_ACTIONS) do
        if d.key == key then return d.default end
    end
    return false
end
-- True if at least one Quick Action is on. When none are, the ⋯ popup would
-- hold only "Gallery", so the button jumps straight there instead (see
-- _buildMoreButton / onTap).
local function _any_quick_enabled()
    for _, d in ipairs(QUICK_ACTIONS) do
        if _quick_enabled(d.key) then return true end
    end
    return false
end
local function _quick_label(key)
    return ({
        hide       = _("Ignore Image"),
        mode       = _("Mode switch"),
        rotate     = _("Rotate image"),
        showinbook = _("Show in Book"),
        prevnext   = _("Nav Buttons Toggle"),
        zoomctl    = _("Zoom Controls Toggle"),
        captions   = _("Image Captions Toggle"),
        bookmarks  = _("Include Bookmarks Toggle"),
        invert     = _("Invert in Night Mode Toggle"),
        layout     = _("Layout"),
    })[key] or key
end

-- ── overlay chrome: dot pill and ⋯ button (from the Figma design) ──────────

-- 8x8 Bayer ordered-dither matrix (values 0..63): turns a continuous
-- darkness level into a binary black/white DOT PATTERN. e-ink panels have
-- few native gray levels and crush a true alpha gradient into visible
-- bands no matter what dither hint accompanies the refresh; a pattern
-- that's only ever fully opaque or fully transparent (dot DENSITY
-- encoding the darkness) leaves nothing for the hardware to quantize.
-- Used by the drawer shadow (_paintPanel) and the caption scrim.
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
-- chrome sizes. r = h/2 gives a stadium. Pass fill = nil for a border-ONLY
-- stencil (transparent interior): just the outline ring, so whatever is
-- behind shows through the middle.
local function make_rounded_stencil(w, h, r, stroke, fill, outline)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    local no_fill = fill == nil
    -- The inner rectangle [r, w-r) x [r, h-r) is a constant: fully-covered
    -- interior (opaque `fill`) or, for a border-only ring, empty. Only the
    -- edge/corner band actually needs the per-pixel sqrt+coverage. Fast-fill
    -- the interior with one C rect and compute just the band — pixel-identical,
    -- but a big surface (the ⋯ menu card) no longer costs a full w*h build.
    local iL, iR, iT, iB = r, w - r, r, h - r
    local has_interior = iR > iL and iB > iT
    if has_interior and not no_fill then
        bb:paintRect(iL, iT, iR - iL, iB - iT,
            Blitbuffer.ColorRGB32(fill, fill, fill, 0xFF))
    end
    local function emit(px, py)
        local sx = math.min(math.max(px + 0.5, r), w - r)
        local sy = math.min(math.max(py + 0.5, r), h - r)
        local dx, dy = px + 0.5 - sx, py + 0.5 - sy
        local d = math.sqrt(dx * dx + dy * dy)
        local cov = math.min(math.max(r - d + 0.5, 0), 1)
        if cov > 0 then
            local t_in = math.min(math.max((r - stroke) - d + 0.5, 0), 1)
            if no_fill then
                -- keep only the ring: full alpha in the stroke band,
                -- fading to transparent as t_in rises into the interior
                local a = cov * (1 - t_in)
                if a > 0 then
                    bb:setPixel(px, py, Blitbuffer.ColorRGB32(
                        outline, outline, outline,
                        math.floor(a * 255 + 0.5)))
                end
            else
                local g = math.floor(outline + t_in * (fill - outline) + 0.5)
                bb:setPixel(px, py, Blitbuffer.ColorRGB32(
                    g, g, g, math.floor(cov * 255 + 0.5)))
            end
        end
    end
    for py = 0, h - 1 do
        if has_interior and py >= iT and py < iB then   -- rim rows: L/R edges only
            for px = 0, iL - 1 do emit(px, py) end
            for px = iR, w - 1 do emit(px, py) end
        else                                            -- full rows (top/bottom)
            for px = 0, w - 1 do emit(px, py) end
        end
    end
    return bb
end

-- Soft drop shadow for the ACTIVE chrome (⋯, nav arrows, zoom control,
-- Back/Reset). Disabled/inactive buttons get none. A rounded-rect silhouette
-- that fades out over `blur` px on ALL sides (so the edges are soft, never a
-- hard cut) and is nudged down `dy` px so the weight sits below the button.
-- Kept SMALL and FAINT on purpose — a big or dark halo reads as grey fringe
-- on the bright day page, which is what we're avoiding, not the soft edge
-- itself. Painted in DAY polarity (black); night mode wants a shadow that
-- still reads as dark, so it stores WHITE, which the framebuffer inversion
-- flips back to dark — exactly what the drawer's own shadow does (see
-- _paintPanel). Cached module-wide (few sizes, tiny buffers).
local _shadow_cache = {}
local function drop_shadow_bb(w, h, r, blur, dy, opacity, night, dither)
    local value = night and 0xFF or 0x00
    local key = table.concat({ w, h, r, blur, dy, opacity, value,
        dither and 1 or 0 }, ":")
    if _shadow_cache[key] then return _shadow_cache[key] end
    local sw, sh = w + 2 * blur, h + 2 * blur + dy
    local bb = Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BBRGB32)
    -- The widget paints an opaque rounded rect exactly over the silhouette, so
    -- the shadow's centre is never seen — only the soft rim is. Skip building
    -- the guaranteed-covered inner rectangle (paint_drop_shadow blits only the
    -- same rim), so a large surface like the ⋯ menu card costs a thin frame,
    -- not a full w*h per-pixel build+blit. inL/inR/inT/inB MUST match the band
    -- geometry in paint_drop_shadow.
    local inL, inR = blur + r, blur + w - r
    local inT, inB = blur + r, blur + h - r
    local function emit(px, py)
        -- distance to the silhouette (rounded rect inset by `blur`)
        local sx = math.min(math.max(px + 0.5, blur + r), blur + w - r)
        local sy = math.min(math.max(py + 0.5, blur + r), blur + h - r)
        local ddx, ddy = px + 0.5 - sx, py + 0.5 - sy
        local dist = math.sqrt(ddx * ddx + ddy * ddy) - r
        local cov = dist <= 0 and 1 or math.max(0, 1 - dist / blur)
        if cov > 0 then
            -- smoothstep the falloff — reads softer than a linear ramp
            cov = cov * cov * (3 - 2 * cov)
            if dither then
                -- Binary dot pattern (same SHADOW_BAYER8 the drawer shadow
                -- uses) instead of a per-pixel alpha: on e-ink a soft alpha
                -- gradient gets crushed into a dark flash on the partial
                -- refresh, but a black-or-transparent DOT pattern (density
                -- encodes darkness) has no gray for the panel to quantize, so
                -- it settles without the "drawn full-black first" flash. Only
                -- worthwhile on a wide rim (the ⋯-menu card) — a few scattered
                -- dots on a tiny button shadow would just look like noise.
                local level = opacity * cov * 255
                local threshold = (SHADOW_BAYER8[(px % 8) + 1][(py % 8) + 1] + 0.5) * 4
                if level > threshold then
                    bb:setPixel(px, py,
                        Blitbuffer.ColorRGB32(value, value, value, 255))
                end
            else
                local a = math.floor(opacity * cov * 255 + 0.5)
                if a > 0 then
                    bb:setPixel(px, py,
                        Blitbuffer.ColorRGB32(value, value, value, a))
                end
            end
        end
    end
    for py = 0, sh - 1 do
        if py >= inT and py < inB then      -- rim rows: only the left/right edges
            for px = 0, inL - 1 do emit(px, py) end
            for px = inR, sw - 1 do emit(px, py) end
        else                                -- rows above/below the centre: full
            for px = 0, sw - 1 do emit(px, py) end
        end
    end
    _shadow_cache[key] = bb
    return bb
end

-- Blit the drop shadow for a rounded widget of (w,h,r) at (x,y): expanded
-- `blur` px on each side (soft edges), offset down `dy`. Lighter on the bright
-- day page than at night (where a stronger shadow still reads fine).
local function paint_drop_shadow(bb, x, y, w, h, r, blur, dy, day_op, night_op, dither)
    -- "Disable shadows" (Advanced) drops the drawer's gradient shadow AND
    -- these small button shadows together, for e-ink ghosting or taste
    if G_reader_settings:isTrue(SHADOW_KEY) then return end
    local night = Screen.night_mode
    local s = drop_shadow_bb(w, h, r, blur, dy,
        night and night_op or day_op, night, dither)
    local sw, sh = s:getWidth(), s:getHeight()
    local ox, oy = x - blur, y - blur + dy
    -- blit only the rim (the opaque widget covers the centre); 4 bands cover
    -- the whole buffer MINUS the inner rectangle that drop_shadow_bb skipped
    local inL, inR = blur + r, blur + w - r
    local inT, inB = blur + r, blur + h - r
    if inR <= inL or inB <= inT then    -- too small to split: one plain blit
        bb:alphablitFrom(s, ox, oy, 0, 0, sw, sh)
        return
    end
    bb:alphablitFrom(s, ox, oy, 0, 0, sw, inT)                       -- top
    bb:alphablitFrom(s, ox, oy + inB, 0, inB, sw, sh - inB)          -- bottom
    bb:alphablitFrom(s, ox, oy + inT, 0, inT, inL, inB - inT)        -- left
    bb:alphablitFrom(s, ox + inR, oy + inT, inR, inT, sw - inR, inB - inT) -- right
end

-- The pill behind the dots / "n / N" counter. Default is
-- the design's black fill + 2px white stroke (keeps the dots legible over
-- dark images). `inverted` flips it to a white fill + black stroke: used
-- for the "n / N" text fallback, which as a solid black block with white
-- text drew far more attention than the light dots pill it replaces.
local GlimpsePill = WidgetContainer:extend{
    inner = nil, -- content, centered
    padding_h = Screen:scaleBySize(9),
    height = Screen:scaleBySize(21),
    radius = Screen:scaleBySize(8), -- Figma "less rounding" (was a full stadium)
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
        self._bg_bb = make_rounded_stencil(w, h, self.radius, self.stroke,
            fill, outline)
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

-- A small numbered badge for a gallery thumbnail's corner: white rounded
-- square, thin black border, bold black number — so the reading order is
-- explicit and a specific image is findable, without disturbing the
-- masonry layout. Day polarity (night's fb inversion → dark badge, light
-- number), same as the rest of the chrome. Widens for 2+ digit numbers.
local GlimpseBadge = Widget:extend{
    num = 1,
    glyph = nil, -- when set, drawn instead of the number (e.g. "+" on Ignored)
    icon = nil,  -- SVG path; when set, drawn (square badge) instead of text
    height = Screen:scaleBySize(17),
    radius = Screen:scaleBySize(4),
    stroke = Screen:scaleBySize(1),
    pad_h = Screen:scaleBySize(4),
}

function GlimpseBadge:init()
    if self.icon then
        local sz = Screen:scaleBySize(11)
        local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
            self.icon, sz, sz)
        if ok and ibb then self._icon_bb = ibb end
        self._w = self.height -- square
    else
        self._txt = TextWidget:new{
            text = self.glyph or tostring(self.num),
            face = Font:getFace("cfont", 11),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        self._w = math.max(self.height, self._txt:getSize().w + 2 * self.pad_h)
    end
end

function GlimpseBadge:getSize()
    return Geom:new{ w = self._w, h = self.height }
end

function GlimpseBadge:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self._w, h = self.height }
    if not self._bg_bb then
        self._bg_bb = make_rounded_stencil(self._w, self.height,
            self.radius, self.stroke, 0xFF, 0x00)
    end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, self._w, self.height)
    if self._icon_bb then
        local iw, ih = self._icon_bb:getWidth(), self._icon_bb:getHeight()
        bb:alphablitFrom(self._icon_bb,
            x + math.floor((self._w - iw) / 2),
            y + math.floor((self.height - ih) / 2),
            0, 0, iw, ih)
    elseif self._txt then
        local ts = self._txt:getSize()
        self._txt:paintTo(bb, x + math.floor((self._w - ts.w) / 2),
            y + math.floor((self.height - ts.h) / 2))
    end
end

function GlimpseBadge:free()
    if self._bg_bb then self._bg_bb:free(); self._bg_bb = nil end
    if self._icon_bb then self._icon_bb:free(); self._icon_bb = nil end
    if self._txt then self._txt:free() end
end

-- A veil the gallery drops over every thumbnail EXCEPT the long-pressed one,
-- to spotlight the cell whose action tooltip is open. Blends white over each
-- other cell at `dim` opacity (day polarity — night's framebuffer inversion
-- turns it into a matching dark veil), so the dimmed thumbs read at ~1-dim.
-- Added LAST to the grid so it paints over the thumbnails and their badges.
local GlimpseDimVeil = Widget:extend{
    cells = nil,   -- { {x,y,w,h,idx}, ... } in the grid's paint space
    except = nil,  -- idx kept at full opacity
    dim = 0.6,     -- white overlay opacity (thumb shows through at ~40%)
}

function GlimpseDimVeil:getSize()
    return Geom:new{ w = 0, h = 0 }
end

function GlimpseDimVeil:paintTo(bb, x, y)
    for _, c in ipairs(self.cells or {}) do
        if c.idx ~= self.except then
            bb:lightenRect(x + c.x, y + c.y, c.w, c.h, self.dim)
        end
    end
end

-- The ⋯ button: solid white rounded square with an anti-aliased 2px black
-- border, so it stays visible over any image. `disabled` grays the border
-- and icon (used by prev/next at the ends of the image list); `inverted`
-- is the pressed state.
local GlimpseMoreButton = Widget:extend{
    size = Screen:scaleBySize(42),       -- 2px larger than the old 40 (icon/border unchanged)
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
    -- active buttons cast a soft downward drop shadow; a disabled dead-end
    -- prev/next stays flat, reinforcing that it's inert
    if not self.disabled then
        paint_drop_shadow(bb, x, y, self.size, self.size, self.radius,
            Screen:scaleBySize(2), Screen:scaleBySize(2), 0.3, 0.5)
    end
    if not self._bg_bb then
        -- disabled (dead-end prev/next): keep the white fill for consistency
        -- with the enabled buttons — just dim the outline ring and the icon
        -- (lifted to the same gray below) so it still reads as inactive.
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

-- Vertical zoom control (Figma "Zoom Control", node 125:357): a white rounded
-- pill the width of the chrome buttons, three equal zones split by two light
-- hairlines — plus (top), fit-to-screen (middle), minus (bottom). Same
-- white-fill/black-2px-border/day-polarity styling as the buttons, so it
-- night-inverts identically. `fit_disabled` dims the middle icon to ~20%
-- (the "image is already fitted" variant), leaving − and + active. Painting
-- only; the parent hit-tests the three zones (see onTap) and positions it.
local GlimpseZoomControl = Widget:extend{
    width = GlimpseMoreButton.size,       -- align with the Next/⋯ column
    -- three SQUARE zones stacked: each zone is as tall as the pill is wide,
    -- matching the button proportions beside it
    height = GlimpseMoreButton.size * 3,
    radius = Screen:scaleBySize(7),
    stroke = Screen:scaleBySize(2),
    inset = Screen:scaleBySize(2),        -- divider clearance from the border
    divider_gray = 0xDB,                  -- #DBDBDB, the Figma hairline
    -- painted in day polarity, so night mode inverts 0xDB → a near-black line
    -- on the black pill, which reads as too faint; a lower value inverts to a
    -- lighter (higher-contrast) line at night
    divider_gray_night = 0xC4,            -- inverts to ~0x3B on black
    disabled_gray = 0xCC,                 -- dimmed icon at a zoom limit (~0.2)
    fit_disabled = false,                 -- middle icon: image already fitted
    minus_disabled = false,               -- at fit / minimum zoom
    plus_disabled = false,                -- at maximum zoom
    inverted_zone = nil,                  -- 0/1/2: zone flashed while pressed
}

function GlimpseZoomControl:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function GlimpseZoomControl:_ensureIcons()
    if self._icons_done then return end
    self._icons_done = true
    local function render(name, sz)
        local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
            _PLUGIN_DIR .. "/assets/" .. name, sz, sz)
        if ok and ibb then return ibb end
    end
    -- dimmed copy for a disabled state: lift the black strokes to a light
    -- gray (keeps the anti-aliased alpha), matching the 20%-opacity look
    local function dim(ibb)
        if not ibb then return end
        local g = self.disabled_gray
        for yy = 0, ibb:getHeight() - 1 do
            for xx = 0, ibb:getWidth() - 1 do
                local c = ibb:getPixel(xx, yy):getColorRGB32()
                if c.alpha > 0 then
                    ibb:setPixel(xx, yy, Blitbuffer.ColorRGB32(g, g, g, c.alpha))
                end
            end
        end
        return ibb
    end
    local s16, s18 = Screen:scaleBySize(16), Screen:scaleBySize(18)
    self._minus_bb = render("zoom-minus.svg", s16)
    self._plus_bb  = render("zoom-plus.svg", s16)
    self._fit_bb   = render("zoom-fit.svg", s18)
    self._minus_dim_bb = dim(render("zoom-minus.svg", s16))
    self._plus_dim_bb  = dim(render("zoom-plus.svg", s16))
    self._fit_dim_bb   = dim(render("zoom-fit.svg", s18))
end

function GlimpseZoomControl:paintTo(bb, x, y)
    local w, h = self.width, self.height
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
    if not self._bg_bb then
        self._bg_bb = make_rounded_stencil(w, h, self.radius, self.stroke,
            0xFF, 0x00)
    end
    -- active control: same soft drop shadow as the buttons
    paint_drop_shadow(bb, x, y, w, h, self.radius,
        Screen:scaleBySize(2), Screen:scaleBySize(2), 0.3, 0.5)
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, w, h)
    -- two hairline dividers at the zone boundaries (h/3, 2h/3)
    local third = h / 3
    local dth = math.max(1, Screen:scaleBySize(1))
    local dx = x + self.inset
    local dw = w - 2 * self.inset
    local dg = Screen.night_mode and self.divider_gray_night
        or self.divider_gray
    local dcol = Blitbuffer.ColorRGB32(dg, dg, dg, 0xFF)
    bb:paintRect(dx, y + math.floor(third - dth / 2), dw, dth, dcol)
    bb:paintRect(dx, y + math.floor(2 * third - dth / 2), dw, dth, dcol)
    -- icons, centered in each zone (zone centers = h/6, h/2, 5h/6)
    self:_ensureIcons()
    local function icon(ibb, cy)
        if not ibb then return end
        bb:alphablitFrom(ibb,
            x + math.floor((w - ibb:getWidth()) / 2),
            y + math.floor(cy - ibb:getHeight() / 2),
            0, 0, ibb:getWidth(), ibb:getHeight())
    end
    icon(self.plus_disabled and self._plus_dim_bb or self._plus_bb,
        third / 2)
    icon(self.fit_disabled and self._fit_dim_bb or self._fit_bb, h / 2)
    icon(self.minus_disabled and self._minus_dim_bb or self._minus_bb,
        h - third / 2)
    -- pressed feedback: invert just the tapped zone, clipped to the pill's
    -- rounded silhouette via the bg stencil's alpha (like GlimpseMoreButton)
    if self.inverted_zone then
        local z0 = math.floor(self.inverted_zone * third)
        local z1 = math.floor((self.inverted_zone + 1) * third)
        for yy = z0, z1 - 1 do
            for xx = 0, w - 1 do
                local a = self._bg_bb:getPixel(xx, yy):getColorRGB32().alpha
                if a > 127 then
                    bb:setPixel(x + xx, y + yy,
                        bb:getPixel(x + xx, y + yy):getColorRGB32():invert())
                end
            end
        end
    end
end

function GlimpseZoomControl:free()
    for _, k in ipairs({ "_bg_bb", "_minus_bb", "_plus_bb", "_fit_bb",
            "_minus_dim_bb", "_plus_dim_bb", "_fit_dim_bb" }) do
        if self[k] then self[k]:free(); self[k] = nil end
    end
    self._icons_done = nil
end

-- Caption overlay: the image's caption tucked into the top-left corner of
-- the drawer as a solid tab — white fill, black text, ONLY the bottom-right
-- corner rounded (the other three sit flush in the screen corner). Painted
-- in DAY polarity, so night mode's framebuffer inversion flips it to a black
-- tab with white text automatically — the wanted look holds both ways with
-- no per-mode branching. Truncates to max_width.
local GlimpseCaption = Widget:extend{
    text = "",
    max_width = 0,
    pad_left = Screen:scaleBySize(6),  -- left text inset (tight to the corner)
    pad_right = Screen:scaleBySize(8), -- right text inset
    pad_top = 0,                       -- top text inset (flush)
    pad_bottom = Screen:scaleBySize(2),-- bottom text inset
    radius = Screen:scaleBySize(10),   -- bottom-right corner only
}

function GlimpseCaption:init()
    local face = Font:getFace("cfont", 12)
    -- Measure the caption's natural single-line width so a short caption keeps
    -- a snug tab, and only wrap (grow downward) when it would exceed max_width.
    local probe = TextWidget:new{ text = self.text, face = face, bold = true }
    local natural = probe:getSize().w
    probe:free()
    local box_w = math.min(natural + Screen:scaleBySize(1), self.max_width)
    if box_w < 1 then box_w = 1 end
    self._text = TextBoxWidget:new{
        text = self.text,
        face = face,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = box_w,
        alignment = "left",
        -- height omitted -> auto, grows with the number of wrapped lines
    }
end

function GlimpseCaption:getSize()
    local s = self._text:getSize()
    return Geom:new{
        w = s.w + self.pad_left + self.pad_right,
        h = s.h + self.pad_top + self.pad_bottom,
    }
end

-- Solid white tab with the caption text baked in, only the bottom-right corner
-- rounded (anti-aliased). TextBoxWidget:paintTo blits an opaque rectangle, so
-- the text is composited FIRST and the corner is carved LAST — otherwise the
-- opaque text box would refill the rounded corner. Opaque everywhere except
-- the carved corner, so it reads as a clean-edged tab over the image and
-- inverts to solid black at night.
function GlimpseCaption:_buildBg(w, h)
    self._bg_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    self._bg_bb:fill(Blitbuffer.ColorRGB32(255, 255, 255, 255))
    -- Bake the wrapped text onto the white tab.
    self._text:paintTo(self._bg_bb, self.pad_left, self.pad_top)
    -- Carve the anti-aliased bottom-right corner on the finished composite.
    local r = self.radius
    if r > 0 then
        local cx, cy = w - r, h - r  -- arc centre of the bottom-right corner
        for py = math.floor(cy), h - 1 do
            for px = math.floor(cx), w - 1 do
                local dx, dy = px + 0.5 - cx, py + 0.5 - cy
                local cov = r - math.sqrt(dx * dx + dy * dy) + 0.5
                local a
                if cov <= 0 then a = 0
                elseif cov < 1 then a = math.floor(cov * 255 + 0.5) end
                if a then
                    self._bg_bb:setPixel(px, py, Blitbuffer.ColorRGB32(255, 255, 255, a))
                end
            end
        end
    end
end

function GlimpseCaption:paintTo(bb, x, y)
    self.dimen = self:getSize()
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    if not self._bg_bb then self:_buildBg(w, h) end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, w, h)
end

function GlimpseCaption:free()
    if self._text then self._text:free() end
    if self._bg_bb then self._bg_bb:free(); self._bg_bb = nil end
end

-- Bookmark identity pill: shown in the viewer's top-left while a bookmarked
-- page is displayed full-size (Figma node 156:5). White rounded rectangle,
-- 2px #cbcbcb border, a bookmark glyph + "Page N (Chapter)" label. Painted in
-- day polarity like the caption tab, so night mode's framebuffer inversion
-- flips it to a dark pill with a light glyph and text automatically.
local GlimpseBookmarkPill = Widget:extend{
    text = "",
    icon = nil,                          -- bookmark SVG path
    max_width = 0,
    radius = Screen:scaleBySize(8),
    stroke = Screen:scaleBySize(2),
    pad_h = Screen:scaleBySize(8),
    pad_v = Screen:scaleBySize(4),
    gap = Screen:scaleBySize(4),         -- glyph→text spacing
    icon_size = Screen:scaleBySize(16),
    border_gray = 0xCB,                  -- #cbcbcb (Figma)
}

function GlimpseBookmarkPill:init()
    if self.icon then
        local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
            self.icon, self.icon_size, self.icon_size)
        if ok and ibb then self._icon_bb = ibb end
    end
    local iw = self._icon_bb and self._icon_bb:getWidth() or 0
    local gap = iw > 0 and self.gap or 0
    -- cap the text to what's left after border padding, glyph and gap, so a
    -- long chapter title truncates with an ellipsis instead of overflowing
    local text_cap = self.max_width - 2 * self.pad_h - iw - gap
    if text_cap < 1 then text_cap = nil end
    self._txt = TextWidget:new{
        text = self.text,
        face = Font:getFace("cfont", 12),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = text_cap,
    }
    local ts = self._txt:getSize()
    self._w = 2 * self.pad_h + iw + gap + ts.w
    self._h = 2 * self.pad_v + math.max(self.icon_size, ts.h)
end

function GlimpseBookmarkPill:getSize()
    return Geom:new{ w = self._w, h = self._h }
end

function GlimpseBookmarkPill:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self._w, h = self._h }
    if not self._bg_bb then
        self._bg_bb = make_rounded_stencil(self._w, self._h,
            self.radius, self.stroke, 0xFF, self.border_gray)
    end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, self._w, self._h)
    local cx = x + self.pad_h
    if self._icon_bb then
        local iw, ih = self._icon_bb:getWidth(), self._icon_bb:getHeight()
        bb:alphablitFrom(self._icon_bb, cx,
            y + math.floor((self._h - ih) / 2), 0, 0, iw, ih)
        cx = cx + iw + self.gap
    end
    local ts = self._txt:getSize()
    self._txt:paintTo(bb, cx, y + math.floor((self._h - ts.h) / 2))
end

function GlimpseBookmarkPill:free()
    if self._bg_bb then self._bg_bb:free(); self._bg_bb = nil end
    if self._icon_bb then self._icon_bb:free(); self._icon_bb = nil end
    if self._txt then self._txt:free() end
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
    height = Screen:scaleBySize(42),     -- 2px larger than the old 40 (icon/border unchanged)
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

-- Stretch (or shrink) to an explicit width; the label stays centred (see
-- paintTo). Used to make the gallery Shown/Ignored toggle fill the bottom bar.
function GlimpseTextButton:setWidth(w)
    if w and w > 0 and w ~= self._w then
        self._w = w
        if self._bg_bb then self._bg_bb:free(); self._bg_bb = nil end
    end
end

function GlimpseTextButton:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self._w, h = self.height }
    if not self._bg_bb then
        self._bg_bb = make_rounded_stencil(self._w, self.height,
            self.radius, self.stroke, 0xFF, 0x00)
    end
    -- active button: same soft drop shadow as the ⋯ button
    paint_drop_shadow(bb, x, y, self._w, self.height, self.radius,
        Screen:scaleBySize(2), Screen:scaleBySize(2), 0.3, 0.5)
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

-- Gallery tab switcher (Figma "New Switcher", node 161:193): a segmented
-- control showing BOTH pools at once — "Gallery [n]" and "Ignored [n]" — with
-- the current pool on a black pill. White wrapper with a 2px black border; the
-- active segment's label and count are white, the inactive segment's black.
-- The count is a small bordered chip (subtle #565656 border on the black pill,
-- #898989 on white). Day polarity like the rest of the chrome — night mode's
-- framebuffer inversion yields the dark variant. The parent hit-tests the two
-- segments via :hitSegment (self._seg_dimens is filled in at paint time).
local GlimpseTabSwitcher = Widget:extend{
    segments = nil,   -- { {label=, count=}, {label=, count=} }
    active = 1,       -- 1-based index of the active segment
    height = Screen:scaleBySize(42),    -- match the buttons so tops line up
    radius = Screen:scaleBySize(8),
    active_radius = Screen:scaleBySize(4),
    stroke = Screen:scaleBySize(2),
    pad = Screen:scaleBySize(5),        -- wrapper border → segment inset
    seg_pad = Screen:scaleBySize(12),   -- content inset within a segment
    label_gap = Screen:scaleBySize(6),  -- label ↔ count chip
    -- count chip: a bit taller than before, and square for a single digit
    -- (badge_min_w == badge_h), widening only when the number needs it
    badge_h = Screen:scaleBySize(17),
    badge_min_w = Screen:scaleBySize(17),
    badge_pad = Screen:scaleBySize(3),
    badge_radius = Screen:scaleBySize(4),
    badge_stroke = math.max(1, Screen:scaleBySize(1)),
    border_active = 0x56,               -- #565656 chip border on the black pill
    border_inactive = 0x89,             -- #898989 chip border on white
}

function GlimpseTabSwitcher:init()
    local face = Font:getFace("cfont", 15)
    local cface = Font:getFace("cfont", 11)
    self._lbl, self._cnt, self._badge_w = {}, {}, {}
    local seg_content = 0
    for i, seg in ipairs(self.segments) do
        local fg = (i == self.active) and Blitbuffer.COLOR_WHITE
            or Blitbuffer.COLOR_BLACK
        self._lbl[i] = TextWidget:new{
            text = seg.label, face = face, bold = true, fgcolor = fg }
        self._cnt[i] = TextWidget:new{
            text = tostring(seg.count), face = cface, bold = true, fgcolor = fg }
        local bw = math.max(self.badge_min_w,
            self._cnt[i]:getSize().w + 2 * self.badge_pad)
        self._badge_w[i] = bw
        local cw = self._lbl[i]:getSize().w + self.label_gap + bw
        if cw > seg_content then seg_content = cw end
    end
    self._seg_w = seg_content + 2 * self.seg_pad
    self._w = 2 * self._seg_w + 2 * self.pad
    self._nat_w = self._w   -- content width; setWidth only grows past this
    self._seg_dimens = {}
end

-- Stretch the switcher to a target total width, splitting it evenly between
-- the two segments so it fills the span the layout hands it (never shrinks
-- below the natural content width). Called before the first paintTo, so the
-- lazily-built stencils pick up the final size.
function GlimpseTabSwitcher:setWidth(w)
    w = math.max(w or 0, self._nat_w)
    self._seg_w = math.floor((w - 2 * self.pad) / 2)
    self._w = 2 * self._seg_w + 2 * self.pad
end

function GlimpseTabSwitcher:getSize()
    return Geom:new{ w = self._w, h = self.height }
end

function GlimpseTabSwitcher:paintTo(bb, x, y)
    local w, h = self._w, self.height
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
    -- same soft downward shadow as the active buttons, so it lifts off the grid
    paint_drop_shadow(bb, x, y, w, h, self.radius,
        Screen:scaleBySize(2), Screen:scaleBySize(2), 0.3, 0.5)
    if not self._wrap_bb then
        self._wrap_bb = make_rounded_stencil(w, h, self.radius,
            self.stroke, 0xFF, 0x00)
    end
    bb:alphablitFrom(self._wrap_bb, x, y, 0, 0, w, h)
    -- active-segment pill: a solid black rounded rect, inset by `pad`
    local seg_h = h - 2 * self.pad
    if not self._active_bb then
        self._active_bb = make_rounded_stencil(self._seg_w, seg_h,
            self.active_radius, self.stroke, 0x00, 0x00)
    end
    bb:alphablitFrom(self._active_bb,
        x + self.pad + (self.active - 1) * self._seg_w, y + self.pad,
        0, 0, self._seg_w, seg_h)
    -- segments: label + count chip, centered in each half
    self._badge_bb = self._badge_bb or {}
    for i = 1, #self.segments do
        local seg_x = x + self.pad + (i - 1) * self._seg_w
        self._seg_dimens[i] = Geom:new{ x = seg_x, y = y, w = self._seg_w, h = h }
        local lbl, cnt = self._lbl[i], self._cnt[i]
        local lsz, csz = lbl:getSize(), cnt:getSize()
        local bw = self._badge_w[i]
        local cx = seg_x + math.floor(
            (self._seg_w - (lsz.w + self.label_gap + bw)) / 2)
        lbl:paintTo(bb, cx, y + math.floor((h - lsz.h) / 2))
        local bx = cx + lsz.w + self.label_gap
        local by = y + math.floor((h - self.badge_h) / 2)
        if not self._badge_bb[i] then
            local col = (i == self.active) and self.border_active
                or self.border_inactive
            self._badge_bb[i] = make_rounded_stencil(bw, self.badge_h,
                self.badge_radius, self.badge_stroke, nil, col)
        end
        bb:alphablitFrom(self._badge_bb[i], bx, by, 0, 0, bw, self.badge_h)
        cnt:paintTo(bb, bx + math.floor((bw - csz.w) / 2),
            by + math.floor((self.badge_h - csz.h) / 2))
    end
end

function GlimpseTabSwitcher:hitSegment(pos)
    for i, d in ipairs(self._seg_dimens or {}) do
        if d and pos:intersectWith(d) then return i end
    end
end

function GlimpseTabSwitcher:free()
    if self._wrap_bb then self._wrap_bb:free(); self._wrap_bb = nil end
    if self._active_bb then self._active_bb:free(); self._active_bb = nil end
    if self._badge_bb then
        for _, b in pairs(self._badge_bb) do if b then b:free() end end
        self._badge_bb = nil
    end
    for _, t in ipairs(self._lbl or {}) do t:free() end
    for _, t in ipairs(self._cnt or {}) do t:free() end
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

-- White rounded card with an anti-aliased border, sized to its single
-- child. Drawn from the shared stencil rather than a FrameContainer radius,
-- whose hard-edged rounding leaves grit in the corners at these sizes.
-- Painted in three passes: a solid white rounded fill, then the child, then
-- the border ring ON TOP — so full-width content (the gray row dividers)
-- tucks under the outline instead of drawing over it (FrameContainer paints
-- its border last for the same reason).
local GlimpseCard = WidgetContainer:extend{
    radius = Screen:scaleBySize(9),
    stroke = Screen:scaleBySize(2),
    outline = 0x00,     -- black border, matching the old FrameContainer
    -- a soft drop shadow lifts the floating menu off the page/drawer; a
    -- touch larger than the button shadow since it's a bigger surface
    shadow_blur = Screen:scaleBySize(4),
    shadow_dy = Screen:scaleBySize(3),
}

function GlimpseCard:getSize()
    return self[1]:getSize()
end

function GlimpseCard:paintTo(bb, x, y)
    local sz = self[1]:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = sz.h }
    if not self._fill_bb or self._bg_w ~= sz.w or self._bg_h ~= sz.h then
        if self._fill_bb then self._fill_bb:free() end
        if self._ring_bb then self._ring_bb:free() end
        self._bg_w, self._bg_h = sz.w, sz.h
        -- solid white rounded rect (outline == fill, so no visible edge yet)
        self._fill_bb = make_rounded_stencil(sz.w, sz.h,
            self.radius, self.stroke, 0xFF, 0xFF)
        -- border-only ring, laid over the content afterwards
        self._ring_bb = make_rounded_stencil(sz.w, sz.h,
            self.radius, self.stroke, nil, self.outline)
    end
    -- shadow first, under the opaque card fill (skipped when "Disable
    -- shadows" is on, via paint_drop_shadow's own guard). DITHERED (last arg):
    -- this wide card rim is where the e-ink "flash black then settle" was
    -- annoying, and it's big enough for the dot pattern to read as a shadow.
    paint_drop_shadow(bb, x, y, sz.w, sz.h, self.radius,
        self.shadow_blur, self.shadow_dy, 0.3, 0.5, true)
    bb:alphablitFrom(self._fill_bb, x, y, 0, 0, sz.w, sz.h)
    self[1]:paintTo(bb, x, y)
    bb:alphablitFrom(self._ring_bb, x, y, 0, 0, sz.w, sz.h)
end

function GlimpseCard:free(full)
    if self._fill_bb then self._fill_bb:free(); self._fill_bb = nil end
    if self._ring_bb then self._ring_bb:free(); self._ring_bb = nil end
    WidgetContainer.free(self, full)
end

-- Rendered menu-row icons, cached module-wide by path+size. The ⋯ menu is
-- rebuilt on every open; rasterising the same handful of SVGs each time was
-- pure waste (noticeable on e-ink, and worse in night mode where every blit
-- is slower). The set is tiny and immutable, so these live for the session.
local _menu_icon_cache = {}
local function menu_icon(path, size)
    local key = path .. ":" .. size
    local ibb = _menu_icon_cache[key]
    if ibb == nil then
        local ok, r = pcall(RenderImage.renderSVGImageFile, RenderImage,
            path, size, size)
        ibb = (ok and r) or false   -- cache the failure too, don't retry each open
        _menu_icon_cache[key] = ibb
    end
    return ibb or nil
end

-- A small popup menu of icon+text rows, anchored to a widget (the ⋯
-- button). White rounded card with a thin border, gray separators between
-- rows; tap a row to fire its callback, tap outside to dismiss. Built in
-- our own style instead of ButtonDialog because a ButtonDialog button
-- shows an icon OR text, never both.
local GlimpsePopupMenu = InputContainer:extend{
    items = nil,    -- { {text=, icon=<svg path or nil>, callback=}, ... }
    footer_item = nil, -- optional {text=, icon=, callback=}: a SEPARATE card
                       -- floating below the main one, for an always-present
                       -- common action (Gallery) set apart from the rest
    footer_gap = Screen:scaleBySize(8), -- gap between the main card and footer
    anchor = nil,   -- function -> Geom (like MovableContainer's anchor)
    pad_left = Screen:scaleBySize(16),
    pad_right = Screen:scaleBySize(16),
    icon_size = Screen:scaleBySize(18),
    icon_gap = Screen:scaleBySize(12),
    row_h = Screen:scaleBySize(44),
}

function GlimpsePopupMenu:init()
    -- the footer item shares the icon column and row width with the main
    -- rows so the two cards line up, so measure it alongside them
    local all_items = {}
    for _, it in ipairs(self.items) do all_items[#all_items + 1] = it end
    if self.footer_item then all_items[#all_items + 1] = self.footer_item end
    local any_lead = false
    for _, it in ipairs(all_items) do
        if it.icon or it.check ~= nil then any_lead = true break end
    end
    local icon_col = any_lead and (self.icon_size + self.icon_gap) or 0

    -- widest label decides the shared row width
    local max_text_w = 0
    local probes = {}
    for i, it in ipairs(all_items) do
        local wg = TextWidget:new{
            text = it.text, face = Font:getFace("cfont", 15), bold = true,
        }
        probes[i] = wg
        max_text_w = math.max(max_text_w, wg:getSize().w)
    end
    for _, wg in ipairs(probes) do wg:free() end
    local row_w = self.pad_left + icon_col + max_text_w + self.pad_right

    self._rows = {}
    -- build a card holding `list`, appending each row to self._rows for the
    -- shared tap hit-test; icons/checkboxes/dividers exactly as before
    local function build_card(list)
        local vg = VerticalGroup:new{ align = "left" }
        for i, it in ipairs(list) do
            local icon_bb, lead_wg
            if it.icon then
                -- shared, cached bb (do NOT free on close — see _menu_icon_cache)
                icon_bb = menu_icon(it.icon, self.icon_size)
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
                text = it.text, icon_bb = icon_bb, lead_wg = lead_wg,
                width = row_w, height = self.row_h, icon_col = icon_col,
                icon_size = self.icon_size, pad_left = self.pad_left,
            }
            row._callback = it.callback
            -- toggle rows (a checkbox that flips a setting live) carry a getter
            -- so onTap can refresh the glyph in place and keep the menu open
            row._check_get = it.check_get
            row._lead_wg = lead_wg
            self._rows[#self._rows + 1] = row
            table.insert(vg, row)
            if i < #list then
                table.insert(vg, LineWidget:new{
                    background = Blitbuffer.COLOR_GRAY,
                    dimen = Geom:new{ w = row_w, h = Screen:scaleBySize(1) },
                })
            end
        end
        return GlimpseCard:new{ vg }
    end

    local content
    if self.footer_item then
        -- main card, a gap, then the footer as its OWN detached card so it
        -- reads as a separate, always-present action
        content = VerticalGroup:new{ align = "left",
            build_card(self.items),
            VerticalSpan:new{ width = self.footer_gap },
            build_card({ self.footer_item }),
        }
    else
        content = build_card(self.items)
    end

    self.movable = MovableContainer:new{
        anchor = self.anchor,
        content,
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
-- The rectangle is padded to also cover the cards' drop shadow, otherwise
-- the shadow's outer feather is painted but never flushed (invisible on
-- show, then a ghost left behind on close).
GlimpsePopupMenu.shadow_pad = GlimpseCard.shadow_blur + GlimpseCard.shadow_dy

function GlimpsePopupMenu:refreshRegion()
    local d = self.movable and self.movable.dimen
    if not d then return nil end
    local p = self.shadow_pad
    return Geom:new{ x = d.x - p, y = d.y - p, w = d.w + 2 * p, h = d.h + 2 * p }
end

function GlimpsePopupMenu:dismiss()
    local region = self:refreshRegion()
    if region and self._restore_region then
        region = region:combine(self._restore_region)
    end
    UIManager:close(self, "ui", region)
end

function GlimpsePopupMenu:onTap(_, ges)
    for _, row in ipairs(self._rows) do
        if row.dimen and ges.pos:intersectWith(row.dimen) then
            if row._check_get then
                -- a live toggle (checkbox): apply the change immediately (the
                -- callback flips the setting and re-lays-out the drawer beneath
                -- us) but KEEP THE MENU OPEN, and refresh the checkbox glyph in
                -- place so its new state shows. Lets the user flip several
                -- settings in one visit instead of reopening the menu each time.
                if row._callback then row._callback() end
                if row._lead_wg and row._lead_wg.setText then
                    row._lead_wg:setText(row._check_get() and "☑" or "☐")
                end
                -- repaint the menu on top of the just-updated drawer
                UIManager:setDirty(self, "ui", self:refreshRegion())
                return true
            end
            -- an action row: dismiss, then run it
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

-- The G-sensor's SetRotationMode is delivered to the topmost widget only, so
-- with this popup open the viewer beneath it never rotates. Dismiss and hand
-- the rotation to the viewer (via on_rotate) so auto-rotation still works.
function GlimpsePopupMenu:onSetRotationMode(rotation)
    if self.on_rotate and rotation ~= nil
            and rotation ~= Screen:getRotationMode() then
        self:dismiss()
        self.on_rotate(rotation)
        return true
    end
end

function GlimpsePopupMenu:onCloseWidget()
    -- row icons are shared from _menu_icon_cache now, so we must NOT free them
    -- here (that would blank them for the next open); they live for the session
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
    on_show_menu = nil,    -- function(): open KOReader's top menu (only)
    scope = nil,           -- effective scope: "read_so_far" | "whole_book"
    on_toggle_scope = nil, -- function(): flip the scope setting and reopen
    on_toggle_bookmarks = nil, -- function(): flip "include bookmarks" and reopen
    on_choose_layout = nil, -- function(): open the Left/Right side chooser
    get_pref = nil,        -- function(meta) -> per-image prefs {rotation=}
    set_pref = nil,        -- function(meta, key, value)
    -- Gallery tabs. The single-image view uses image/image_metas (= the
    -- primary pool); the Gallery shows shown_* or ignored_* per active tab.
    shown_metas = nil,     -- scanner records for the shown collection
    shown_list = nil,      -- parallel render closures for shown_metas
    ignored_metas = nil,   -- scanner records the filter dropped / user hid
    ignored_list = nil,    -- parallel render closures for ignored_metas
    primary_tab = "shown", -- which pool the single-image view is showing
    on_ignore = nil,       -- function(meta, tab, page): move to Ignored
    on_unignore = nil,     -- function(meta, tab, page): add back to Shown
    on_remove_bookmark = nil, -- function(meta, from_gallery, tab, page): drop
                           -- the KOReader dogear (and this item from Glimpse)
    -- gallery masonry (⋯ → Gallery): fixed-width columns, variable heights
    gallery_cols = 3,
    -- No title bar and no button row: everything is image. Position comes
    -- from the dot pill, actions from the ⋯ button, closing from
    -- tap-outside, multiswipe or Back.
    with_title_bar = false,
    -- Zoom ceiling as a multiple of the image's native resolution: pinch may
    -- push past 100% (actual pixel size) for readability. User-configurable
    -- under Advanced → Maximum zoom; the viewer is created with the chosen
    -- value (see showViewer). This literal is only the fallback if unset.
    max_zoom_of_native = DEFAULT_MAX_ZOOM,
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
    -- Zoom steps (pinch, +/− buttons, double-tap) only change the image and
    -- the zoom control's dim state — never the rest of the chrome. When a full
    -- build already exists, take the light path that rebuilds just the image
    -- instead of tearing down and reconstructing every widget each step.
    if self._zooming and not self._gallery_mode
            and self._overlay and self._image_layer and self._image_layer.dimen then
        return self:_updateImageOnly()
    end
    self:_clean_image_wg()
    local orig_dimen = self.main_frame.dimen

    -- Layout (Settings → Layout): the drawer sits against the LEFT screen edge
    -- by default, or the RIGHT edge when turned on. The whole panel — border,
    -- rounded corners, gradient shadow — and all the overlaid chrome mirror
    -- horizontally; the outer (screen) edge is always the flush/borderless one.
    self._on_right = G_reader_settings:isTrue(LAYOUT_RIGHT_KEY)

    self._panel_w = math.floor(Screen:getWidth() * self.panel_ratio)
    self._panel_h = Screen:getHeight() - 2 * self.panel_vgap
    -- content area inside the drawer's border (the outer/screen edge is
    -- borderless and flush; the inner edge facing the page carries the border
    -- and rounded corners); self.width/height are what the inherited zoom/pan
    -- code sizes the image against
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

    -- Explicit day-white backing behind the image area. KOReader's night mode
    -- inverts the framebuffer when compositing, so this shows black in dark
    -- mode (issue #9) rather than leaving a light gap around the image; in day
    -- mode it just matches the white card. Logical/day polarity, flag 0.
    local image_layer = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        self.image_container,
    }
    local overlay = OverlapGroup:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        image_layer,
    }
    -- kept for the light zoom repaint (_updateImageOnly): the overlay holds the
    -- image AND all chrome (nav, ⋯, pill, zoom control, caption) in z-order, so
    -- repainting it alone redraws everything the viewer shows without re-running
    -- the drawer's panel/shadow paint.
    self._overlay = overlay
    self._image_layer = image_layer
    -- chrome is centered/aligned on the image area (content minus the gap
    -- that keeps it clear of the rounded right edge), like the design
    local image_area_w = self.width - self.image_right_gap
    -- 14, not 16: the bottom row sits 2px closer to the drawer's bottom
    -- edge than before (the buttons also grew 2px, see GlimpseMoreButton)
    local btn_inset = Screen:scaleBySize(14)
    local btn_gap = Screen:scaleBySize(10)
    -- the −/fit/+ zoom control (Quick Action, off by default): only in the
    -- single-image view. When on it occupies the slot above the bottom-right
    -- button, so ⋯ shifts to Next's LEFT (below) and the Reset pill is
    -- suppressed (its middle button resets to fit instead — see _buildPill).
    local show_zc = (not self._gallery_mode)
        and G_reader_settings:isTrue(ZOOMCTL_KEY)
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
        -- affordance, so they ALWAYS show here (regardless of the setting or
        -- page count) — greyed out at a single page, so the bottom bar's
        -- layout stays put instead of the toggle/close jumping around
        nav = true
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
        -- icon-only Back (square, like the nav arrows) STACKED directly above
        -- the Next arrow — the same slot ⋯ uses in single-image mode. Off the
        -- bottom row, so the switcher can span the full width Prev→Next.
        self._close_frame = GlimpseMoreButton:new{
            icon = _PLUGIN_DIR .. "/assets/back.svg",
        }
        local size = self._close_frame.size
        self._close_frame.overlap_offset = {
            self._nav_next_frame.overlap_offset[1],
            self._nav_next_frame.overlap_offset[2] - btn_gap - size,
        }
        table.insert(overlay, self._close_frame)
    elseif self._more_frame and self:_hasQuickActions() then
        local more_size = self._more_frame:getSize()
        local more_x, more_y
        if self._nav_next_frame then
            if show_zc then
                -- zoom control owns the slot above Next, so ⋯ sits to Next's
                -- LEFT on the same bottom row (matches the Figma layout)
                more_x = self._nav_next_frame.overlap_offset[1]
                    - btn_gap - more_size.w
                more_y = self._nav_next_frame.overlap_offset[2]
            else
                -- nav on: ⋯ stacks directly ABOVE Next (same right edge), with
                -- the same gap it used to keep to Next's left now below it
                more_x = self._nav_next_frame.overlap_offset[1]
                more_y = self._nav_next_frame.overlap_offset[2] - btn_gap - more_size.h
            end
        else
            -- nav off: ⋯ takes the bottom-right slot Next would have used
            more_x = image_area_w - more_size.w
            more_y = self.height - more_size.h - btn_inset
        end
        self._more_frame.overlap_offset = { more_x, more_y }
        table.insert(overlay, self._more_frame)
    elseif self._more_frame then
        -- every Quick Action turned off: hide the ⋯ button entirely. Clear
        -- its geometry so the pill reclaims the space (the right-bound loop
        -- skips a nil overlap_offset) and a tap where it used to be can't hit
        -- a stale dimen (see onTap).
        self._more_frame.overlap_offset = nil
        self._more_frame.dimen = nil
    end
    if self._pill_frame then
        -- the Reset button and the gallery Shown/Ignored toggle are the
        -- same height as the ⋯ button, so share its bottom inset to sit on
        -- the same baseline; the shorter dots pill uses a larger inset so
        -- its CENTRE lines up with the buttons flanking it — derived from the
        -- actual heights (not a fixed guess) so it stays centred at any DPI.
        -- NB: over-fit only swaps in the tall Reset button when the −/fit/+
        -- zoom control is OFF (see _buildPill); with it on the dots stay, so
        -- key off "is the pill a button", not _isOverFit — otherwise zooming
        -- past fit would drop the still-shown dots to the bottom baseline.
        local pill_is_button = self._gallery_mode
            or (self:_isOverFit()
                and not G_reader_settings:isTrue(ZOOMCTL_KEY))
        local bottom_inset
        if pill_is_button then
            bottom_inset = btn_inset
        else
            local pill_h = self._pill_frame:getSize().h
            bottom_inset = btn_inset
                + math.floor((GlimpseMoreButton.size - pill_h) / 2)
        end
        -- span between whatever sits on its left (the Prev button, or the
        -- left inset) and the nearest right-side chrome (⋯ / Back / Next)
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
        -- the gallery tab switcher FILLS the span between the Prev and Next
        -- arrows (Back now stacks above Next, so nothing else shares the row);
        -- the dot pill just centres within the span
        if self._gallery_mode then
            local pill_left = self._nav_prev_frame
                and (left_bound + btn_gap) or left_bound
            -- the segmented switcher stretches to fill the span; the plain
            -- "Page X of Y" pill (books with no Ignored pile) has no setWidth
            -- and just stays left-aligned at the same spot
            if self._pill_frame.setWidth then
                -- Next always exists in the gallery (nav is forced on); leave
                -- it the same gap the other buttons keep between each other
                local switcher_right = self._nav_next_frame.overlap_offset[1] - btn_gap
                self._pill_frame:setWidth(switcher_right - pill_left)
            end
            self._pill_frame.overlap_offset = {
                pill_left, self.height - self._pill_frame:getSize().h - bottom_inset,
            }
        else
            local pill_size = self._pill_frame:getSize()
            self._pill_frame.overlap_offset = {
                math.floor(left_bound + (right_bound - left_bound - pill_size.w) / 2),
                self.height - pill_size.h - bottom_inset,
            }
        end
        table.insert(overlay, self._pill_frame)
    end
    -- zoom control (−/fit/+): built once, repositioned each update; freed when
    -- turned off or in the gallery. Sits above the bottom-right button (Next
    -- when nav is on, else ⋯); its middle "fit" icon greys out at fit.
    if self._zoomctl_frame and not show_zc then
        self._zoomctl_frame:free()
        self._zoomctl_frame = nil
    end
    if show_zc then
        if not self._zoomctl_frame then
            self._zoomctl_frame = GlimpseZoomControl:new{}
        end
        local zc = self._zoomctl_frame
        local over_fit = self:_isOverFit()
        zc.fit_disabled = not over_fit
        zc.minus_disabled = not over_fit      -- at fit / minimum zoom
        zc.plus_disabled = self:_isAtMax()    -- can't zoom in further
        zc.inverted_zone = nil                -- clear any press flash
        local zsz = zc:getSize()
        local anchor = self._nav_next_frame
            or (self._more_frame and self._more_frame.overlap_offset
                and self._more_frame)
        local zx, zy
        if anchor and anchor.overlap_offset then
            local asz = anchor:getSize()
            zx = anchor.overlap_offset[1] + (asz.w - zsz.w) -- right-align
            zy = anchor.overlap_offset[2] - btn_gap - zsz.h
        else
            zx = image_area_w - zsz.w
            zy = self.height - zsz.h - btn_inset
        end
        zc.overlap_offset = { zx, zy }
        table.insert(overlay, zc)
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
            self._caption_wg = GlimpseCaption:new{
                text = caption,
                max_width = image_area_w - 2 * Screen:scaleBySize(16),
            }
            -- flush into the drawer's top-left corner: the tab's own three
            -- square corners sit in the screen corner, only its bottom-right
            -- is rounded (see GlimpseCaption)
            self._caption_wg.overlap_offset = { 0, 0 }
            table.insert(overlay, self._caption_wg)
        end
    end
    -- bookmark identity pill, top-left, when the current item is a bookmark
    if self._bookmark_pill_wg then
        self._bookmark_pill_wg:free()
        self._bookmark_pill_wg = nil
    end
    if not self._gallery_mode then
        local meta = self.image_metas
            and self.image_metas[self._images_list_cur or 1]
        if meta and meta.is_bookmark then
            local label
            if meta.chapter and meta.chapter ~= "" then
                label = T(_("Page %1 (%2)"), meta.page or "?", meta.chapter)
            else
                label = T(_("Page %1"), meta.page or "?")
            end
            local inset = Screen:scaleBySize(12)
            self._bookmark_pill_wg = GlimpseBookmarkPill:new{
                text = label,
                icon = _PLUGIN_DIR .. "/assets/bookmark.svg",
                max_width = image_area_w - 2 * inset,
            }
            self._bookmark_pill_wg.overlap_offset = { inset, inset }
            table.insert(overlay, self._bookmark_pill_wg)
        end
    end
    -- Right-side layout: the whole chrome is positioned above as if the drawer
    -- were on the left (prev arrow at the left inset, next/⋯ at the right edge,
    -- caption top-left, the image_right_gap keeping chrome clear of the rounded
    -- edge). Mirror every overlaid element's x within the content width in one
    -- pass, so the flush-edge chrome lands on the (now-right) screen edge and
    -- the rounded-edge chrome keeps its gap on the (now-left) inner edge. The
    -- image layer itself is symmetric (centred fit) and needs no mirroring.
    if self._on_right then
        for _, wdg in ipairs(overlay) do
            local off = wdg.overlap_offset
            if off then
                local ok, sz = pcall(wdg.getSize, wdg)
                local ww = (ok and sz and sz.w) or 0
                off[1] = self.width - off[1] - ww
            end
        end
        -- The prev/next arrows are chevrons (‹ back, › forward): their DIRECTION
        -- is universal, so keep ‹ on the left and › on the right. The mirror
        -- above put ‹ at the (now-right) flush edge and › at the inner edge —
        -- swap their positions back so the arrows read correctly. ⋯ (stacked
        -- above the inner-edge arrow) and the pill stay mirrored.
        local pf, nf = self._nav_prev_frame, self._nav_next_frame
        if pf and pf.overlap_offset and nf and nf.overlap_offset then
            pf.overlap_offset, nf.overlap_offset = nf.overlap_offset, pf.overlap_offset
        end
    end
    table.insert(self.frame_elements, overlay)
    self.frame_elements:resetLayout()

    -- main_frame is a transparent full-height column pinned to one screen edge;
    -- the drawer body (white, black border, rounded corners on the inner edge)
    -- and its gradient shadow are painted by the _paintPanel hook, since
    -- FrameContainer supports neither per-corner radii nor translucency. The
    -- border padding is on the INNER edge (right for a left drawer, left for a
    -- right drawer); the outer edge is flush.
    self.main_frame.background = nil
    self.main_frame.radius = nil
    self.main_frame.bordersize = 0
    self.main_frame.padding = 0
    self.main_frame.padding_left = self._on_right and self.panel_border or 0
    self.main_frame.padding_right = self._on_right and 0 or self.panel_border
    self.main_frame.padding_top = self.panel_vgap + self.panel_border
    self.main_frame.padding_bottom = self.panel_vgap + self.panel_border
    -- anchor the drawer to the chosen screen edge (every update, since the side
    -- can change): a WidgetContainer with align=nil paints its child at its
    -- dimen origin, so offset that origin to the right edge for a right drawer.
    self[1].align = nil
    if self._on_right then
        self[1].dimen = Geom:new{ x = Screen:getWidth() - self._panel_w,
            y = 0, w = self._panel_w, h = Screen:getHeight() }
    else
        self[1].dimen = Geom:new{ x = 0, y = 0,
            w = Screen:getWidth(), h = Screen:getHeight() }
    end
    if not self._panel_paint_hooked then
        self._panel_paint_hooked = true
        local orig_paintTo = self.main_frame.paintTo
        local viewer = self
        self.main_frame.paintTo = function(frame, bb, x, y)
            viewer:_paintPanel(bb, x, y)
            orig_paintTo(frame, bb, x, y)
            viewer:_restoreCorners(bb, x, y)
        end
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
    -- Image switch: hard-clear this (panel-only) region so the previous
    -- image's ink doesn't ghost through the new one. The plain "ui"/"partial"
    -- waveforms skip the black→white→black clear cycle, so the old image
    -- lingers. We use "full" (not "flashui") on purpose: on Kobo "flashui"
    -- resolves to the AUTO waveform (the driver picks a light/fast flash that
    -- leaves residue, worst on the big fills — the black Night-Mode card),
    -- whereas "full" is true GC16, the full 16-level clearing waveform, and
    -- is the mode the EPDC waits to *settle* between consecutive updates so
    -- rapid switches don't accumulate ghosts. It stays region-limited (a Geom
    -- is always passed below), so only the drawer clears, never the whole
    -- screen; zoom/pan steps (fast) stay flashless. Consumed before the
    -- suppress return so an open-time switch never leaves the flag dangling.
    local flash_switch = self._flash_switch
    self._flash_switch = nil
    -- "Fast image switching" (Advanced, ON by default): flashless partial
    -- refresh on switch. Turning it OFF restores the clean full (GC16) clear,
    -- which scrubs the previous image so detailed maps can't ghost through.
    if flash_switch and not fast
            and not G_reader_settings:nilOrTrue(FAST_SWITCH_KEY) then
        wfm_mode = "full"
    end
    self.dithered = not fast
    -- Light image switch (default on via "Fast image switching"): the chrome is
    -- freshly rebuilt above (pill, nav state, caption, bookmark pill all
    -- correct) and the neighbour bitmap is already decoded (see
    -- _prefetchNeighbors), so skip the slow dithered whole-drawer refresh and
    -- repaint just the content overlay with a non-dithered, image-region
    -- refresh — the same fast path zoom uses. Turning the setting OFF falls
    -- through to the clean dithered clear below (wfm_mode already "full" then).
    local switching = self._switching
    self._switching = nil
    if switching and not self._gallery_mode and not self._suppress_refresh
            and not self._full_band_refresh
            and self._overlay and self._image_layer
            and G_reader_settings:nilOrTrue(FAST_SWITCH_KEY) then
        self:_repaintOverlayFast(wfm_mode)
        return
    end
    if self._suppress_refresh then
        -- showViewer builds the full initial state (remembered image,
        -- restored zoom) before showing, then refreshes once
        return
    end
    -- Content-changing transitions (gallery enter/exit, tab switch) repaint the
    -- shadow and refresh its WHOLE band, like open/close — otherwise the band,
    -- which an interior update deliberately leaves alone, can be left half-wiped
    -- by a later promoted e-ink refresh (very visible on the right layout, where
    -- the shadow falls toward screen-centre rather than off the far edge). The
    -- numeric alpha repaints the page under the band first, so the shadow
    -- re-blend stays accumulation-free (same contract as open).
    local full_band = self._full_band_refresh
    self._full_band_refresh = nil
    if full_band then
        UIManager:setDirty(self, function()
            if not self.main_frame.dimen then return end
            local d = self.main_frame.dimen:combine(orig_dimen)
            if not G_reader_settings:isTrue(SHADOW_KEY) then
                local extra = 2 * self.shadow_width - self.shadow_overlap + 1
                if self._on_right then
                    local nx = math.max(0, d.x - extra)
                    d.w = d.w + (d.x - nx); d.x = nx
                else
                    d.w = math.min(Screen:getWidth() - d.x, d.w + extra)
                end
            end
            return wfm_mode, d, not fast
        end)
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
        -- Guard a teardown race: a swipe's refresh is deferred to the next
        -- paint tick, so an immediate close can clear main_frame.dimen before
        -- this runs. Nil mode makes UIManager drop the (now meaningless)
        -- refresh instead of indexing a nil dimen.
        if not self.main_frame.dimen then return end
        return wfm_mode, self.main_frame.dimen:combine(orig_dimen), not fast
    end)
    self.alpha = alpha
end

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
    -- Right-side layout mirrors the panel horizontally: the border and rounded
    -- corners move to the LEFT (inner) edge and the shadow casts leftwards.
    local on_right = self._on_right
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
    local night = Screen.night_mode
    local inv = bb.getInverse and bb:getInverse() == 1
    -- SW-invert night mode (Android/Boox): KOReader inverts the framebuffer
    -- when compositing our buffers onto it. Flag-matching our stencils to that
    -- inverse flag makes the C blitter copy them RAW, BYPASSING that inversion
    -- — which left the whole drawer white in dark mode (issue #9). So in that
    -- case DON'T flag-match: keep the stencils in logical/day polarity and let
    -- KOReader invert them exactly like it does every stock widget. On HW-
    -- invert panels the fb flag is already 0, so render_inv == inv == false and
    -- nothing changes there.
    local render_inv = inv
        and not (night and Device.isAndroid and Device:isAndroid())
    -- side is baked into the cached stencils (border/corner/gradient sides), so
    -- flipping Layout must rebuild them
    local skey = tostring(night) .. tostring(render_inv) .. tostring(on_right)
    -- Advanced → Disable shadow: skip the gradient entirely. The dithered
    -- shadow is the main e-ink ghost source, so some users prefer it off.
    local shadow_disabled = G_reader_settings:isTrue(SHADOW_KEY)

    -- shadow: cached DOT-PATTERN stencil (ordered/Bayer dithering, not a
    -- true alpha gradient — see SHADOW_BAYER8 above), density peak → 0
    -- across shadow_width, starting shadow_overlap left of the panel edge
    -- (that part only shows through the rounded corner notches); full
    -- screen height.
    local shadow_h = h + 2 * self.panel_vgap
    -- logical shadow color is white in night (inverts to dark); with the
    -- SW-invert flag set we store the final dark value directly instead
    local sv = render_inv and 0x00 or (night and 0xFF or 0x00)
    local speak = night and 1.0 or 0.5
    -- night mode gets a wider gradient so it reaches further onto the page
    -- (user tuning 2026-07-22: 2x read as reaching too far, 1.25x as too
    -- narrow — splitting the difference)
    local swidth = night and math.floor(self.shadow_width * 1.5 + 0.5) or self.shadow_width
    if not shadow_disabled and (not self._shadow_bb
            or self._shadow_bb:getHeight() ~= shadow_h
            or self._shadow_night ~= skey) then
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
            -- column i runs peak (panel edge) → fade. For a right drawer the
            -- shadow casts leftwards, so write the mirror column: the peak ends
            -- up at the buffer's RIGHT edge, which is blitted against the
            -- panel's (left) inner edge below.
            local ci = on_right and (swidth - 1 - i) or i
            for j = 0, shadow_h - 1 do
                local threshold = (SHADOW_BAYER8[col][(j % 8) + 1] + 0.5) * 4
                local a = level > threshold and 255 or 0
                self._shadow_bb:setPixel(ci, j, Blitbuffer.ColorRGB32(sv, sv, sv, a))
            end
        end
        self._shadow_bb:setInverse(render_inv and 1 or 0)
    end
    -- consumed by interior updates (see update()): the page under the
    -- shadow wasn't repainted, so blending again would accumulate
    local skip_shadow = self._skip_shadow_paint
    self._skip_shadow_paint = nil
    if not skip_shadow and not shadow_disabled then
        -- left drawer: cast right from the panel's right edge; right drawer:
        -- cast left from the panel's left edge (buffer already mirrored above)
        local sx = on_right and (x + self.shadow_overlap - swidth)
            or (x + w - self.shadow_overlap)
        bb:alphablitFrom(self._shadow_bb, sx, y, 0, 0, swidth, shadow_h)
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
    -- the rounded corners sit on the inner edge: right (x+w-cr) for a left
    -- drawer, left (x) for a right drawer
    local corner_x = on_right and x or (x + w - cr)
    if skip_shadow then
        bb:blitFrom(ucb[1], corner_x, cpy, 0, 0, cr, cr)
        bb:blitFrom(ucb[2], corner_x, cpy + h - cr, 0, 0, cr, cr)
    else
        -- match the fb's inverse flag so these copies run on the C blitter
        ucb[1]:setInverse(render_inv and 1 or 0)
        ucb[2]:setInverse(render_inv and 1 or 0)
        ucb[1]:blitFrom(bb, 0, 0, corner_x, cpy, cr, cr)
        ucb[2]:blitFrom(bb, 0, 0, corner_x, cpy + h - cr, cr, cr)
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
        local body = render_inv and 0x00 or 0xFF     -- card background
        local edge = render_inv and 0xFF or 0x00     -- border
        local c_body = Blitbuffer.ColorRGB32(body, body, body, 0xFF)
        local c_edge = Blitbuffer.ColorRGB32(edge, edge, edge, 0xFF)
        -- night edge is a hairline: thinner than the day border but at
        -- least 2px so it doesn't vanish on high-dpi devices; the layout
        -- keeps panel_border so the image doesn't shift
        local bw = night and math.max(2, Screen:scaleBySize(1))
            or self.panel_border
        local r = self.panel_radius
        -- border on three sides: top, bottom, and the INNER vertical edge
        -- (right for a left drawer, left for a right drawer). The outer edge is
        -- flush with the screen edge and borderless.
        self._panel_bb:paintRectRGB32(0, 0, w, h, c_body)
        self._panel_bb:paintRectRGB32(0, 0, w, bw, c_edge)
        self._panel_bb:paintRectRGB32(0, h - bw, w, bw, c_edge)
        self._panel_bb:paintRectRGB32(on_right and 0 or (w - bw), 0, bw, h, c_edge)
        -- inner-edge corners: AA arcs — body inside, border ring, transparent
        -- outside (the page shows in the notches). Circle centre and the
        -- scanned column band both flip to the left for a right drawer.
        for cy_top = 0, 1 do
            local ccx = on_right and r or (w - r)
            local ccy = cy_top == 0 and r or h - r
            local px_from = on_right and 0 or (w - r)
            local px_to = on_right and (r - 1) or (w - 1)
            for px = px_from, px_to do
                for qy = 0, r - 1 do
                    local pyy = cy_top == 0 and qy or h - 1 - qy
                    local fx, fy = px + 0.5, pyy + 0.5
                    local x_out = on_right and (fx <= ccx) or (fx >= ccx)
                    if x_out and (cy_top == 0 and fy <= ccy or cy_top == 1 and fy >= ccy) then
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
        self._panel_bb:setInverse(render_inv and 1 or 0)
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
    -- rounded corners on the inner edge: right (x+w-r) for a left drawer, left
    -- (x) for a right drawer
    local corner_x = self._on_right and x or (x + w - r)
    self._corner_bbs[1]:blitFrom(bb, 0, 0, corner_x, py, r, r)
    self._corner_bbs[2]:blitFrom(bb, 0, 0, corner_x, py + h - r, r, r)
    for k = 1, 2 do
        local cbb = self._corner_bbs[k]
        -- circle centre in corner-local coords: x is the INTERIOR side of the
        -- square (local 0 for a left drawer, local r for a right drawer); y is
        -- r for the top corner, 0 for the bottom one
        local ccx = self._on_right and r or 0
        local ccy = k == 1 and r or 0
        local keep_r = r - bw - self.image_padding
        for pyy = 0, r - 1 do
            for pxx = 0, r - 1 do
                local d = math.sqrt((pxx + 0.5 - ccx) ^ 2 + (pyy + 0.5 - ccy) ^ 2)
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
    local corner_x = self._on_right and x or (x + w - r)
    bb:alphablitFrom(self._corner_bbs[1], corner_x, py, 0, 0, r, r)
    bb:alphablitFrom(self._corner_bbs[2], corner_x, py + h - r, 0, 0, r, r)
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
    if self._zoomctl_frame then self._zoomctl_frame:free() end
    if self._gallery_head_wgs then
        for _, w in ipairs(self._gallery_head_wgs) do w:free() end
        self._gallery_head_wgs = nil
    end
    if self._gallery_badges then
        for _, b in ipairs(self._gallery_badges) do b:free() end
        self._gallery_badges = nil
    end
    if self._caption_wg then
        self._caption_wg:free()
        self._caption_wg = nil
    end
    if self._bookmark_pill_wg then
        self._bookmark_pill_wg:free()
        self._bookmark_pill_wg = nil
    end
    if self._thumb_bbs then
        for _, t in pairs(self._thumb_bbs) do
            if t.bb then t.bb:free() end
        end
        self._thumb_bbs = nil
    end
    self:_resetHiRes() -- free the zoomed image's full-res decode, if any
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
        -- Same teardown-race guard as update(): if the frame is already gone
        -- by the time this deferred callback runs, drop the refresh.
        if not self.main_frame.dimen then return end
        local d = self.main_frame.dimen:copy()
        -- cover the shadow at its widest (night mode = 2× shadow_width) — but
        -- only when the shadow is on. With it off, keep the region to the
        -- drawer so a promoted/flash refresh never reaches the book page.
        if not G_reader_settings:isTrue(SHADOW_KEY) then
            local extra = 2 * self.shadow_width - self.shadow_overlap + 1
            if self._on_right then
                -- shadow casts leftwards: grow the region toward the left edge
                local nx = math.max(0, d.x - extra)
                d.w = d.w + (d.x - nx)
                d.x = nx
            else
                d.w = math.min(Screen:getWidth() - d.x, d.w + extra)
            end
        end
        -- "full": a GC16 clearing refresh over the drawer (and its shadow)
        -- area on every close — the ghosting the drawer/shadow leaves on
        -- e-ink, worst at night, is scrubbed as it lifts away. This is the
        -- former "Full Refresh on Close" option, now baked in as the default
        -- (same reliable GC16 waveform the image-switch clear uses); it stays
        -- regional so the rest of the page is never flashed.
        return "full", d, true
    end)
    -- Refresh isolation (see showViewer): hand the reader back its own
    -- ghost-clear counter, on nextTick so the close's below-repaint runs while
    -- the count is still Glimpse's (0) and can't flash from the reader's total.
    -- Reading then continues its cadence exactly where it left off.
    if self._reader_refresh_count ~= nil then
        local saved = self._reader_refresh_count
        self._reader_refresh_count = nil
        UIManager:nextTick(function() UIManager.refresh_count = saved end)
    end
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
    local src = self.image
    if wg_scale == 0 then
        local fit = self:_computeFitScaleFactor()
        if fit and fit >= 1 then
            wg_scale = fit
        end
    elseif wg_scale > 1 then
        -- Zoomed past 1:1 of the capped bitmap: below this it's still
        -- downscaling the cap (sharp) and fast, but beyond it the cap would
        -- upscale, so swap in the sharp full-resolution decode (lazily
        -- created, see _getHiRes) — this is what makes approaching 100% show
        -- real detail. self.scale_factor stays expressed against the capped
        -- bitmap everywhere (fit floor, ceiling, save/restore all in those
        -- units); we only divide the WIDGET's scale by the resolution ratio
        -- here so the on-screen size is byte-identical — just crisper.
        local hi = self:_getHiRes()
        if hi then
            local r = hi:getWidth() / self.image:getWidth()
            if r > 1 then
                src = hi
                wg_scale = wg_scale / r
            end
        end
    end
    self._image_wg = ImageWidget:new{
        image = src,
        image_disposable = false, -- we may reuse self.image
        alpha = true,
        width = max_image_w,
        height = max_image_h,
        rotation_angle = self._cur_rotation or 0,
        scale_factor = wg_scale,
        center_x_ratio = self._center_x_ratio,
        center_y_ratio = self._center_y_ratio,
        -- We bake the night-mode inversion into the decoded bitmap ourselves
        -- (see the decode closure in showViewer), device-agnostically — the
        -- same pixel operation ImageWidget itself would do — so opt out of
        -- its own night handling to avoid inverting twice. (Its invertRect
        -- also spans the full widget rect, which would flip the letterbox
        -- around the image.) We deliberately do NOT flag-match the bitmap to
        -- the framebuffer's night flag: matching it once tied our night
        -- correctness to a getInverse() read that could disagree between
        -- decode and paint, which flipped the image on some devices — the
        -- "Invert in Night Mode reversed" bug. A plain flag-0 blit is the
        -- same path KOReader uses for every image, correct on HW- and
        -- SW-invert alike (only marginally slower on the rare SW-invert
        -- device, which re-inverts during the blit).
        original_in_nightmode = false,
    }
    self.image_container = CenterContainer:new{
        dimen = Geom:new{ w = avail_w, h = self.img_container_h },
        self._image_wg,
    }
end

-- Light update for zoom steps: rebuild ONLY the image widget at the new scale
-- and swap it into the existing image layer, leaving every other widget (nav,
-- ⋯, pill, caption) untouched. The zoom control is the sole chrome whose look
-- depends on zoom (its +/−/fit zones dim at the limits), so refresh its flags
-- in place. Then repaint the overlay (image + chrome, correct z-order) with a
-- flashless "ui" refresh — no chrome reconstruction, no shadow re-blend. Falls
-- back to a full update() if the layer refs aren't ready (should not happen:
-- update() only routes here once a full build exists).
function GlimpseViewer:_updateImageOnly()
    if not (self._image_layer and self._image_layer.dimen and self._overlay) then
        self._zooming = nil
        return self:update()
    end
    self:_clean_image_wg()
    self:_new_image_wg()
    -- swap the freshly-scaled image into the existing layer; FrameContainer
    -- recomputes its size from the child at paint, so nothing else to relayout
    self._image_layer[1] = self.image_container
    local zc = self._zoomctl_frame
    if zc then
        local over_fit = self:_isOverFit()
        zc.fit_disabled = not over_fit
        zc.minus_disabled = not over_fit
        zc.plus_disabled = self:_isAtMax()
        zc.inverted_zone = nil
    end
    self:_repaintOverlayFast("ui")
end

-- Full-resolution decode of the current image, for the zoomed view. Decoded
-- lazily on first zoom-in and cached for as long as this image is on screen
-- (dropped by _resetHiRes on image change / invert / rotate). Returns nil —
-- and remembers that with a `false` sentinel so it isn't retried — when there
-- is no sharper version to be had (small images the resting cap never shrank).
function GlimpseViewer:_getHiRes()
    if not self.hires_decode then return nil end
    if self._hi_bb == false then return nil end
    if self._hi_bb then return self._hi_bb end
    local hi = self.hires_decode(self._images_list_cur or 1)
    if not hi then self._hi_bb = false; return nil end
    -- only worth the extra bitmap if it's meaningfully larger than the cap
    if self.image and hi:getWidth() <= self.image:getWidth() * 1.05 then
        if hi.free then hi:free() end
        self._hi_bb = false
        return nil
    end
    self._hi_bb = hi
    return hi
end

-- Drop any cached full-res decode. Call whenever self.image is replaced or
-- re-rendered (image switch, hide, invert toggle, rotation) so the next
-- zoom-in re-decodes against the current pixels.
function GlimpseViewer:_resetHiRes()
    if self._hi_bb and self._hi_bb ~= false and self._hi_bb.free then
        self._hi_bb:free()
    end
    self._hi_bb = nil
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
        -- Gallery bottom-center is the Shown/Ignored switch (only when there
        -- IS an ignored pool). "Page X of Y" now lives top-left in the grid.
        -- The button names the destination: from the collection it offers
        -- "Show Ignored (n)", from the Ignored pool "Show Gallery (n)".
        if self:_hasIgnoredTab() then
            -- both pools shown at once as a segmented switcher; the active
            -- segment is the pool on screen. Tap a segment to switch (onTap).
            local shown_n = self.shown_metas and #self.shown_metas or 0
            self._pill_frame = GlimpseTabSwitcher:new{
                segments = {
                    { label = _("Gallery"), count = shown_n },
                    { label = _("Ignored"), count = self:_ignoredCount() },
                },
                active = (self._gallery_tab == "ignored") and 2 or 1,
            }
        end
        return
    end
    if self:_isOverFit() and not G_reader_settings:isTrue(ZOOMCTL_KEY) then
        -- genuinely spilling past fit: image switching is disabled, and
        -- the indicator becomes a tappable "reset to fit" button, styled
        -- to match the ⋯ button (see onTap). When the −/fit/+ zoom control
        -- is on, its middle button handles reset instead, so keep the dots.
        self._pill_frame = GlimpseTextButton:new{
            text = _("Reset"),
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
                bold = true,
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
    local more_left
    if nav then
        more_left = image_area_w - 2 * btn_size - btn_gap
    elseif self:_hasQuickActions() then
        more_left = image_area_w - btn_size
    else
        -- ⋯ hidden (no Quick Actions) and no Next: the pill gets the full width
        more_left = image_area_w
    end
    local left_bound = nav and (btn_inset + btn_size) or btn_inset
    return more_left - left_bound - 2 * btn_gap
end

function GlimpseViewer:_buildMoreButton()
    -- With no Quick Actions enabled the ⋯ popup would contain only "Gallery",
    -- so skip the menu: the button becomes a Gallery icon that jumps straight
    -- there. Otherwise it's the ⋯ button that opens the popup. The config is
    -- fixed for the viewer's lifetime, so decide once here.
    self._more_is_gallery = not _any_quick_enabled()
    self._more_frame = GlimpseMoreButton:new{
        icon = self._more_is_gallery
            and (_PLUGIN_DIR .. "/assets/gallery.svg") or nil,
    }
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

-- The list/metas/count for the active Gallery tab (shown vs ignored). The
-- single-image view always uses _images_list/image_metas (= the primary pool).
function GlimpseViewer:_tabList()
    if self._gallery_tab == "ignored" then
        return self.ignored_list, self.ignored_metas,
            self.ignored_metas and #self.ignored_metas or 0
    end
    return self.shown_list, self.shown_metas,
        self.shown_metas and #self.shown_metas or 0
end

function GlimpseViewer:_ignoredCount()
    return self.ignored_metas and #self.ignored_metas or 0
end

-- The Ignored tab (and hence the whole tab bar) only appears when there is
-- something ignored — otherwise the Gallery looks exactly as it did before.
function GlimpseViewer:_hasIgnoredTab()
    return self:_ignoredCount() > 0
end

function GlimpseViewer:_switchGalleryTab(tab)
    if tab == self._gallery_tab then return end
    self._gallery_tab = tab
    self._gallery_page = 1
    self._full_band_refresh = true
    self:update()
end

function GlimpseViewer:_enterGallery(page, tab)
    self._gallery_mode = true
    self._gallery_tab = tab or self.primary_tab or "shown"
    local layout = self:_galleryLayout()
    if page then
        self._gallery_page = math.min(math.max(page, 1), #layout.pages)
    else
        self._gallery_page = layout.page_of[self._images_list_cur or 1] or 1
    end
    -- the gallery browses from the fit state; a zoomed view has been
    -- left behind anyway once the user goes looking for another image
    self.scale_factor = 0
    self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
    self._full_band_refresh = true
    self:update()
end

function GlimpseViewer:_exitGallery(idx)
    -- Back (no idx) from a root gallery — a review-the-Ignored-pile session with
    -- no accepted images behind it — closes Glimpse rather than dropping into a
    -- single ignored image. Tapping a specific thumbnail passes an idx, opens
    -- that image, and clears the flag so a later Back returns to it.
    if not idx and self._gallery_is_root then
        self:onClose()
        return
    end
    self._gallery_mode = false
    if idx then self._gallery_is_root = false end
    -- leaving the grid is a content-changing transition like entering it:
    -- repaint the shadow band and take the full (not light-switch) refresh so
    -- the grid can't ghost through and the shadow can't be left half-wiped
    self._full_band_refresh = true
    if idx and idx ~= (self._images_list_cur or 1) then
        self:switchToImageNum(idx) -- runs update()
    else
        self:update()
    end
end

function GlimpseViewer:_galleryPages()
    return #self:_galleryLayout().pages
end

-- Drawer-content origin: gallery cell/tab rects are recorded relative to it.
function GlimpseViewer:_contentOrigin()
    local mf = self.main_frame.dimen
    -- content is inset from mf.x by the inner-edge border padding: 0 on the left
    -- for a left drawer, panel_border on the left for a right drawer
    local left_pad = self._on_right and self.panel_border or 0
    return mf.x + left_pad, mf.y + self.panel_vgap + self.panel_border
end

-- The gallery cell {x,y,w,h,idx} at pos (drawer-content space), or nil.
function GlimpseViewer:_galleryHit(pos)
    if not self._gallery_cells then return nil end
    local ox, oy = self:_contentOrigin()
    for _, c in ipairs(self._gallery_cells) do
        if pos:intersectWith(Geom:new{
            x = ox + c.x, y = oy + c.y, w = c.w, h = c.h }) then
            return c
        end
    end
    return nil
end

-- Long-press popup: a single action anchored just above the thumbnail —
-- "Ignore this image" in the Gallery, "Add back to Gallery" in the
-- Ignored pile. Kept in its own method so the gettext `_` isn't shadowed by
-- the `_` first parameter of onHold/onTap (calling `_()` in those crashes).
function GlimpseViewer:_openMoveMenu(cell, pos)
    local metas = select(2, self:_tabList())
    local meta = metas and metas[cell.idx]
    if not meta then return end
    local ignored = self._gallery_tab == "ignored"
    local label, cb
    if meta.is_bookmark then
        -- a bookmarked page: the move action becomes "Remove bookmark", which
        -- drops it from Glimpse AND deletes the dogear in the book itself
        label = _("Remove bookmark")
        cb = function()
            if self.on_remove_bookmark then
                self.on_remove_bookmark(meta, true, self._gallery_tab,
                    self._gallery_page)
            end
        end
    elseif ignored then
        label = _("Add back to Gallery")
        cb = function()
            if self.on_unignore then
                self.on_unignore(meta, "ignored", self._gallery_page)
            end
        end
    else
        label = _("Ignore this image")
        cb = function()
            if self.on_ignore then
                self.on_ignore(meta, "shown", self._gallery_page)
            end
        end
    end
    -- spotlight the pressed cell: dim every other thumbnail while the tooltip
    -- is open (rebuild + repaint the grid with the veil, cleared on dismiss)
    self._dim_except_idx = meta and cell.idx
    self:update()
    local menu
    menu = GlimpsePopupMenu:new{
        items = { { text = label, callback = cb } },
        on_rotate = function(rot) self:onSetRotationMode(rot) end,
        -- compact: a single short action, so shrink the row from the ⋯ menu's
        row_h = Screen:scaleBySize(38),
        pad_left = Screen:scaleBySize(12),
        pad_right = Screen:scaleBySize(12),
        -- centred on the touch point, floating ABOVE it: the menu pops up so
        -- its bottom sits `lift` px clear of the finger (rises its full height
        -- upward from there), instead of resting right on the press. Still
        -- flips below when near the top of the screen.
        anchor = function()
            local w = menu.movable and menu.movable.dimen
                and menu.movable.dimen.w or 0
            local ox = self.main_frame.dimen.x
            local pad = Screen:scaleBySize(4)
            local lift = Screen:scaleBySize(28)
            local x = math.floor((pos and pos.x or 0) - w / 2)
            local maxx = ox + self.width - w - pad
            if maxx < ox + pad then maxx = ox + pad end
            x = math.max(ox + pad, math.min(x, maxx))
            local y = (pos and pos.y or 0) - lift
            return Geom:new{ x = x, y = y, w = 0, h = 0 }, false
        end,
    }
    -- clear the spotlight when the tooltip closes (tap-through action or
    -- tap-outside both route through onCloseWidget → on_dismiss)
    menu.on_dismiss = function()
        if self._dim_except_idx then
            self._dim_except_idx = nil
            self:update()
        end
    end
    UIManager:show(menu, function() return "ui", menu:refreshRegion() end)
end

-- Masonry layout for ALL images, computed once per viewer (the image
-- list and drawer size are fixed while it is open) from the scanner's
-- header-sniffed dimensions — no decoding. Returns { pages = {
-- {cell,...}, ... }, page_of = {idx -> page} }; cell = {idx,x,y,w,h}
-- relative to the drawer content origin (the onTap hit-test space).
function GlimpseViewer:_galleryLayout()
    local tab = self._gallery_tab or "shown"
    self._gallery_layouts = self._gallery_layouts or {}
    if self._gallery_layouts[tab] then return self._gallery_layouts[tab] end
    local _, metas, nb = self:_tabList()
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
    for i = 1, nb or 1 do
        local meta = metas and metas[i]
        local iw = meta and (meta.width or meta.attr_width)
        local ih = meta and (meta.height or meta.attr_height)
        if not (iw and ih and iw > 0 and ih > 0) then iw, ih = 1, 1 end
        -- displayed height = native scaled to the column width, but NEVER
        -- upscaled (matches _thumb, which caps at 1×). Sizing the cell to
        -- thumb_w * aspect instead gives a small image (icon, tiny ad) a
        -- full-width cell it can't fill, floating it in white space and
        -- ballooning the column so pages flush half-empty.
        local scale = math.min(thumb_w / iw, 1)
        local th = math.floor(ih * scale + 0.5)
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
    self._gallery_layouts[tab] = layout
    return layout
end

-- Heading band geometry, derived from the actual rendered line heights so
-- the top breathing room scales with the font (≈ a quarter of a title line)
-- on any device. Cached for the viewer's lifetime (the faces never change).
-- Single source of truth: _buildGallery positions the two lines from
-- band_top/gap, _galleryMetrics starts the grid at content_top, so they stay
-- in lockstep.
function GlimpseViewer:_headMetrics()
    if self._head_metrics then return self._head_metrics end
    local t = TextWidget:new{
        text = "Gy", face = Font:getFace("cfont", 16), bold = true }
    local s = TextWidget:new{
        text = "Gy", face = Font:getFace("cfont", 12), bold = true }
    local th1, th2 = t:getSize().h, s:getSize().h
    t:free(); s:free()
    local band_top = Screen:scaleBySize(3) + math.floor(th1 / 4)
    local gap = 0                              -- subtitle tucked under title
    local below = Screen:scaleBySize(6)        -- band → grid
    self._head_metrics = {
        band_top = band_top, th1 = th1, gap = gap,
        content_top = band_top + th1 + gap + th2 + below,
    }
    return self._head_metrics
end

-- Shared gallery geometry: the band above the grid holds the heading and
-- the Close button, the band below holds the page pill and ‹ › buttons.
-- area_w is the FULL content width (unlike the single-image view, the
-- grid has no chrome that needs to dodge the rounded right corner — the
-- top/bottom bands already keep clear of it vertically) so the grid's
-- right margin (pad) matches its left margin exactly.
function GlimpseViewer:_galleryMetrics()
    local content_top = self:_headMetrics().content_top
    return {
        area_w = self.width,
        pad = Screen:scaleBySize(16),
        top = content_top,
        bottom = Screen:scaleBySize(60),
        gap = Screen:scaleBySize(10),
        inset = Screen:scaleBySize(4),
        grid_h = self.img_container_h - content_top - Screen:scaleBySize(60),
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
    -- key by tab too: index i means different images across tabs, and we
    -- want a cached thumbnail to survive flipping tabs back and forth
    local ckey = (self._gallery_tab or "shown") .. ":" .. i
    local t = self._thumb_bbs[ckey]
    if t and t.w == w and t.h == h then
        return t.bb
    end
    if t and t.bb then
        t.bb:free()
        self._thumb_bbs[ckey] = nil
    end
    local list = (self:_tabList())
    local src = list and list[i]
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
    -- No fb-flag matching here (see _new_image_wg): the source is already
    -- night-baked device-agnostically, and a plain flag-0 blit is correct on
    -- every device.
    self._thumb_bbs[ckey] = { bb = bb, w = w, h = h }
    return bb
end

-- A bookmarked page finished rendering (async): drop the placeholder
-- thumbnail(s) cached for it and repaint so the real page shows.
function GlimpseViewer:_onBookmarkThumbReady(path)
    if self._thumb_bbs and self.image_metas then
        for i, m in ipairs(self.image_metas) do
            if m.path == path then
                for _, tab in ipairs({ "shown", "ignored" }) do
                    local ck = tab .. ":" .. i
                    local t = self._thumb_bbs[ck]
                    if t then
                        if t.bb then t.bb:free() end
                        self._thumb_bbs[ck] = nil
                    end
                end
            end
        end
    end
    if self._gallery_mode then
        -- Coalesce a burst of async page renders into ONE gallery repaint.
        -- A gallery page full of bookmarks lands its rendered tiles roughly
        -- together (they're generated in subprocesses and collected in the
        -- same pass), and repainting per tile meant N full grid rebuilds +
        -- e-ink refreshes — the sluggishness when opening a bookmark-heavy
        -- Gallery. One update on the next tick redraws them all at once.
        if not self._bm_repaint_scheduled then
            self._bm_repaint_scheduled = true
            UIManager:nextTick(function()
                self._bm_repaint_scheduled = nil
                if self._gallery_mode then self:update() end
            end)
        end
    else
        local cur_idx = self._images_list_cur or 1
        local cur = self.image_metas and self.image_metas[cur_idx]
        if cur and cur.path == path then
            -- switchToImageNum no-ops on the same index, so re-pull the
            -- closure directly (it now returns the real page) and rebuild
            if self.image and self.image_disposable and self.image.free then
                self.image:free()
            end
            self.image = self._images_list[cur_idx]
            if type(self.image) == "function" then self.image = self.image() end
            self:update()
        end
    end
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
    -- Two-line header (top band, display-only — the Gallery/Ignored switch
    -- lives on the BOTTOM bar, since the top strip is KOReader's top-menu tap
    -- zone). Line 1: "Gallery"/"Ignored" left, "Page X of Y" right-aligned
    -- when paged. Line 2 (smaller, grey): "N images in Gallery"/"N ignored".
    if self._gallery_head_wgs then
        for _, w in ipairs(self._gallery_head_wgs) do w:free() end
    end
    self._gallery_head_wgs = {}
    local function addHead(wg)
        table.insert(grid, wg)
        table.insert(self._gallery_head_wgs, wg)
    end
    if self._gallery_badges then
        for _, b in ipairs(self._gallery_badges) do b:free() end
    end
    self._gallery_badges = {}
    local band_top = self:_headMetrics().band_top
    local on_ignored_tab = self._gallery_tab == "ignored"
    local count = select(3, self:_tabList())
    local title_wg = TextWidget:new{
        text = on_ignored_tab and _("Ignored") or _("Gallery"),
        face = Font:getFace("cfont", 16),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local th1 = title_wg:getSize().h
    title_wg.overlap_offset = { m.pad, band_top }
    addHead(title_wg)
    if pages > 1 then
        local page_wg = TextWidget:new{
            text = T(_("Page %1 of %2"), self._gallery_page or 1, pages),
            face = Font:getFace("cfont", 13),
            bold = true,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        local psz = page_wg:getSize()
        page_wg.overlap_offset = {
            m.area_w - m.pad - psz.w,
            band_top + math.floor((th1 - psz.h) / 2),
        }
        addHead(page_wg)
    end
    -- subtitle: "N images", plus ", M bookmarks" when the bookmarked-pages
    -- feature has folded any real bookmarks into this pool (don't lump them
    -- into the image count). Only the Gallery (shown) tab ever holds bookmarks.
    local _list, tab_metas = self:_tabList()
    local n_bm = 0
    if tab_metas then
        for _idx = 1, #tab_metas do
            if tab_metas[_idx].is_bookmark then n_bm = n_bm + 1 end
        end
    end
    local n_img = count - n_bm
    local parts = {}
    if n_img > 0 or n_bm == 0 then
        parts[#parts + 1] = (n_img == 1) and _("1 image")
            or T(_("%1 images"), n_img)
    end
    if n_bm > 0 then
        parts[#parts + 1] = (n_bm == 1) and _("1 bookmark")
            or T(_("%1 bookmarks"), n_bm)
    end
    local sub_wg = TextWidget:new{
        text = table.concat(parts, ", "),
        face = Font:getFace("cfont", 12),
        bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = m.area_w - 2 * m.pad,
    }
    sub_wg.overlap_offset = { m.pad, band_top + th1 + self:_headMetrics().gap }
    addHead(sub_wg)
    self._gallery_cells = {}
    for _, c in ipairs(layout.pages[self._gallery_page] or {}) do
        local bb = self:_thumb(c.idx,
            c.w - 2 * m.inset, c.h - 2 * m.inset)
        if bb then
            -- every thumbnail gets a subtle rounded outline so adjacent
            -- images (which otherwise butt edge to edge) stay visually
            -- distinct. The heavier black outline is no longer a "current
            -- image" marker (that was lost on people) — it now accentuates
            -- the cell you're long-pressing (paired with the dim veil over
            -- the others), so the selection reads clearly.
            local is_spotlight = self._dim_except_idx == c.idx
            local cell = CenterContainer:new{
                dimen = Geom:new{ w = c.w, h = c.h },
                FrameContainer:new{
                    bordersize = is_spotlight
                        and Screen:scaleBySize(2) or Screen:scaleBySize(1),
                    color = is_spotlight and Blitbuffer.COLOR_BLACK
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
            -- reading-order number badge (top-left), added AFTER the cell so
            -- it paints on top. Only in the Gallery grid — the Ignored
            -- grid has no badge (order there isn't meaningful).
            if not on_ignored_tab then
                local badge = GlimpseBadge:new{ num = c.idx }
                badge.overlap_offset = {
                    c.x + m.inset + Screen:scaleBySize(3),
                    c.y + m.inset + Screen:scaleBySize(3),
                }
                table.insert(grid, badge)
                table.insert(self._gallery_badges, badge)
                -- bookmarked pages get a bookmark badge in the opposite
                -- (top-right) corner, marking them as pages rather than images
                local meta = self.image_metas and self.image_metas[c.idx]
                if meta and meta.is_bookmark then
                    local bmk = GlimpseBadge:new{
                        icon = _PLUGIN_DIR .. "/assets/bookmark.svg",
                    }
                    local bsz = bmk:getSize()
                    bmk.overlap_offset = {
                        c.x + c.w - m.inset - Screen:scaleBySize(3) - bsz.w,
                        c.y + m.inset + Screen:scaleBySize(3),
                    }
                    table.insert(grid, bmk)
                    table.insert(self._gallery_badges, bmk)
                end
            end
        end
    end
    -- while a long-press action tooltip is open, dim every OTHER cell so the
    -- pressed one stands out (painted last → over the thumbnails and badges)
    if self._dim_except_idx then
        table.insert(grid, GlimpseDimVeil:new{
            cells = self._gallery_cells,
            except = self._dim_except_idx,
            overlap_offset = { 0, 0 },
        })
    end
    self.image_container = grid
end

-- Would the ⋯ popup have at least one row? Always yes now: Gallery is a
-- permanent entry (the floating footer card), so the ⋯ button always shows
-- even if the user has turned off every configurable Quick Action.
function GlimpseViewer:_hasQuickActions()
    return true
end

-- The ⋯ menu (from the design): gallery, remove from collection, rotate
-- 90° (remembered per image, plus a reset once rotated), show in book,
-- invert in night mode (the global setting, also in the plugin menu).
-- The gallery has no ⋯ button (it shows a Close button instead), so this
-- only ever runs on the single-image view.
function GlimpseViewer:_showMoreMenu()
    -- Which rows appear is user-configurable ("Quick Actions" in the plugin
    -- menu, see QUICK_ACTIONS). Order here = the canonical popup order; each
    -- block is gated on its own flag. Toggle rows (prevnext/captions/invert)
    -- draw a checkbox in the icon column and flip the matching setting live.
    local items = {}
    local cur_meta = self.image_metas
        and self.image_metas[self._images_list_cur or 1]
    local cur_is_bookmark = cur_meta and cur_meta.is_bookmark
    -- the ignore slot: a normal image gets "Ignore Image"; a bookmarked page
    -- gets "Remove bookmark" instead (drops it from Glimpse and deletes the
    -- dogear in the book)
    if _quick_enabled("hide") then
        if cur_is_bookmark then
            items[#items + 1] = {
                text = _("Remove bookmark"),
                icon = _PLUGIN_DIR .. "/assets/bookmark.svg",
                callback = function() self:_removeCurrentBookmark() end,
            }
        else
            items[#items + 1] = {
                text = _("Ignore Image"),
                icon = _PLUGIN_DIR .. "/assets/hide.svg",
                callback = function() self:_hideCurrentImage() end,
            }
        end
    end
    if _quick_enabled("mode") then
        items[#items + 1] = {
            -- scope switch: reflects the current view, tap flips it and reopens
            text = self.scope == "whole_book"
                and _("Mode: All images")
                or _("Mode: Spoiler-free"),
            icon = _PLUGIN_DIR .. "/assets/mode.svg",
            callback = function()
                if self.on_toggle_scope then self.on_toggle_scope() end
            end,
        }
    end
    -- Rotate makes no sense for a bookmarked page (it's a rendered page, not a
    -- reference image), so hide it (and Reset Rotation) while viewing one
    if _quick_enabled("rotate") and not cur_is_bookmark then
        items[#items + 1] = {
            text = _("Rotate image"),
            icon = _PLUGIN_DIR .. "/assets/rotate.svg",
            callback = function() self:_rotateCurrent() end,
        }
        -- Reset Rotation rides with Rotate, shown only while rotated
        if (self._cur_rotation or 0) ~= 0 then
            items[#items + 1] = {
                text = _("Reset Rotation"),
                icon = _PLUGIN_DIR .. "/assets/reset-rotation.svg",
                callback = function() self:_setRotation(0) end,
            }
        end
    end
    if _quick_enabled("showinbook") then
        items[#items + 1] = {
            text = _("Show in Book"),
            icon = _PLUGIN_DIR .. "/assets/navigate.svg",
            callback = function() self:_showInBook() end,
        }
    end
    if _quick_enabled("prevnext") then
        items[#items + 1] = {
            text = _("Nav Buttons"),
            check = G_reader_settings:isTrue(NAV_BUTTONS_KEY),
            check_get = function() return G_reader_settings:isTrue(NAV_BUTTONS_KEY) end,
            callback = function() self:_togglePrevNext() end,
        }
    end
    if _quick_enabled("zoomctl") then
        items[#items + 1] = {
            text = _("Zoom Controls"),
            check = G_reader_settings:isTrue(ZOOMCTL_KEY),
            check_get = function() return G_reader_settings:isTrue(ZOOMCTL_KEY) end,
            callback = function() self:_toggleZoomControl() end,
        }
    end
    if _quick_enabled("captions") then
        items[#items + 1] = {
            text = _("Image Captions"),
            check = G_reader_settings:nilOrTrue(CAPTIONS_KEY),
            check_get = function() return G_reader_settings:nilOrTrue(CAPTIONS_KEY) end,
            callback = function() self:_toggleCaptions() end,
        }
    end
    if _quick_enabled("bookmarks") then
        items[#items + 1] = {
            -- shorter here than the plugin menu's "Include Bookmarks in
            -- Gallery" — the ⋯ popup context already implies the Gallery
            text = _("Include Bookmarks"),
            check = G_reader_settings:isTrue(BOOKMARKS_KEY),
            callback = function() self:_toggleBookmarks() end,
        }
    end
    if _quick_enabled("invert") then
        items[#items + 1] = {
            -- checkbox drawn in the icon column (see GlimpseMenuRow),
            -- so it lines up with the icons above it
            text = _("Invert in Night Mode"),
            check = G_reader_settings:isTrue(INVERT_KEY),
            check_get = function() return G_reader_settings:isTrue(INVERT_KEY) end,
            callback = function() self:_toggleInvert() end,
        }
    end
    if _quick_enabled("layout") then
        items[#items + 1] = {
            -- opens the Left/Right side chooser; the plugin reopens the drawer
            -- on the chosen side
            text = _("Layout"),
            icon = _PLUGIN_DIR .. "/assets/layout.svg",
            callback = function()
                if self.on_choose_layout then self.on_choose_layout() end
            end,
        }
    end
    -- Gallery is always available, set apart at the very bottom as its own
    -- floating card (it's the most common jump). If the user has turned off
    -- every other Quick Action, it becomes the sole (main) row instead.
    local gallery_item = {
        text = _("Gallery"),
        icon = _PLUGIN_DIR .. "/assets/gallery.svg",
        callback = function() self:_enterGallery() end,
    }
    local footer_item = gallery_item
    if #items == 0 then
        items = { gallery_item }
        footer_item = nil
    end
    local menu
    menu = GlimpsePopupMenu:new{
        items = items,
        footer_item = footer_item,
        on_rotate = function(rot) self:onSetRotationMode(rot) end,
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
            -- Left drawer: ⋯ sits at the bottom-right, so align the menu's RIGHT
            -- edge to the button's right (it grows left, away from the screen
            -- edge). Right drawer: ⋯ sits at the bottom-left, so align the LEFT
            -- edges instead (it grows right), keeping the menu on-screen.
            local x = self._on_right and d.x or (d.x + d.w - w)
            return Geom:new{ x = x, y = d.y - gap, w = 0, h = d.h }, true
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
        return "ui", menu:refreshRegion()
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
    -- the cached full-res decode has the OLD polarity baked in — drop it so a
    -- later zoom re-decodes with the new setting
    self:_resetHiRes()
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

-- ⋯ toggle rows for the two viewer-appearance settings (also in the plugin
-- menu): flip the global setting and re-lay-out so the change shows at once.
function GlimpseViewer:_togglePrevNext()
    G_reader_settings:saveSetting(NAV_BUTTONS_KEY,
        not G_reader_settings:isTrue(NAV_BUTTONS_KEY))
    self:update()
end

function GlimpseViewer:_toggleZoomControl()
    G_reader_settings:saveSetting(ZOOMCTL_KEY,
        not G_reader_settings:isTrue(ZOOMCTL_KEY))
    self:update()
end

-- One discrete zoom step for the +/− buttons: geometric, so ~4 taps span
-- best-fit → the maximum (Advanced → Maximum zoom). Clamped by
-- _applyNewScaleFactor, which snaps back to fit at/below the floor and caps
-- at the ceiling; a small image with no room to zoom is a no-op.
function GlimpseViewer:_zoomStep(dir)
    if self._gallery_mode then return end
    self:_refreshScaleFactor()
    local fit = self._fit_scale_factor or self:_computeFitScaleFactor()
    if not fit or fit <= 0 then return end
    local maxs = self:_maxScale() or fit
    if maxs <= fit + 1e-4 then return end
    local cur = (self.scale_factor == 0) and fit or self.scale_factor
    local mult = (maxs / fit) ^ (1 / 4)
    self:_applyNewScaleFactor(dir > 0 and cur * mult or cur / mult)
end

function GlimpseViewer:_toggleCaptions()
    G_reader_settings:saveSetting(CAPTIONS_KEY,
        not G_reader_settings:nilOrTrue(CAPTIONS_KEY))
    self:update()
end

-- Flipping "Include Bookmarks in Gallery" changes the image SET (it folds
-- the dogear pages in or out), so unlike the display toggles it can't just
-- repaint — it hands off to the plugin to flip the setting and reopen the
-- viewer, rebuilding the collection (like the scope switch does).
function GlimpseViewer:_toggleBookmarks()
    if self.on_toggle_bookmarks then self.on_toggle_bookmarks() end
end

-- Manual double-tap detection from instant Tap events: a second tap close
-- in time and position counts as a double-tap. Only consulted where the
-- single tap would do nothing (middle area at fit, anywhere while zoomed),
-- so no single-tap action ever has to be delayed or undone.
function GlimpseViewer:_checkDoubleTap(ges)
    -- Settings → Gestures → Double-tap for maximum zoom (on by default)
    if not G_reader_settings:nilOrTrue(GESTURE_DOUBLETAP_KEY) then return end
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

-- Double-tap: toggle between best-fit and the max zoom (150% of native,
-- max_zoom_of_native), centered on the tapped point. From fit it jumps
-- straight to max — the full-res decode swaps in (see _new_image_wg) so it's
-- as sharp as the source allows; from any zoomed state it snaps back to fit.
-- Pinch covers everything in between, stepless. (For small images the max is
-- at or below fit, so double-tap just stays at the fit view.)
function GlimpseViewer:onGlimpseDoubleTap(_, ges)
    local was_fit = self.scale_factor == 0
    -- re-center the zoom on the tapped point (harmless when we end up
    -- snapping back to fit — that path resets the center to the middle)
    local wg = self._image_wg
    if wg and ges and ges.pos then
        wg:getSize() -- pan math needs a rendered bb
        local d = wg.dimen
        local cx = d and (d.x + d.w / 2) or Screen:getWidth() / 2
        local cy = d and (d.y + d.h / 2) or Screen:getHeight() / 2
        self._center_x_ratio, self._center_y_ratio =
            wg:getPanByCenterRatio(ges.pos.x - cx, ges.pos.y - cy)
    end
    self:_refreshScaleFactor() -- resolve fit (scale 0) into a number
    if was_fit then
        -- jump to the max zoom (clamped to fit for small images by
        -- _applyNewScaleFactor, which also enforces the same ceiling)
        self:_applyNewScaleFactor(self:_maxScale() or self.scale_factor)
    else
        self.scale_factor = 0
        self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
        self._fast_refresh = true
        self._zooming = true -- snap back to fit is a zoom step too (light path)
        self:update()
        self._zooming = nil
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

-- Same press flash for one zone of the zoom control, then run the action
-- (which repaints the control un-inverted via update()).
function GlimpseViewer:_flashZoomZone(zone, action)
    local zc = self._zoomctl_frame
    if not zc or not zc.dimen then action(); return end
    zc.inverted_zone = zone
    UIManager:widgetRepaint(zc, zc.dimen.x, zc.dimen.y)
    UIManager:setDirty(nil, "fast", zc.dimen)
    UIManager:forceRePaint()
    UIManager:yieldToEPDC()
    action()
end

-- KOReader's configurable top-menu tap zone (DTAP_ZONE_MENU, default the
-- top 1/8 of the screen, full width), as a screen rect. Falls back to the
-- default if the global defaults table isn't reachable for any reason.
function GlimpseViewer:_inTopMenuZone(pos)
    local z = { x = 0, y = 0, w = 1, h = 1 / 8 }
    if G_defaults then
        local zz = G_defaults:readSetting("DTAP_ZONE_MENU")
        if zz then z = zz end
    end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    return pos:intersectWith(Geom:new{
        x = z.x * sw, y = z.y * sh, w = z.w * sw, h = z.h * sh })
end

-- Tap: the top-menu zone opens KOReader's top menu (see onTap); a tap
-- elsewhere outside the drawer closes; on the ⋯ button opens the menu.
-- Image switching is swipe-only (or the optional buttons), which leaves
-- the rest of the image as a double-tap zoom surface.
function GlimpseViewer:onTap(_, ges)
    -- Respect KOReader's own top-of-screen menu trigger: a tap in that
    -- zone opens ONLY the top menu, over the still-open drawer (the ⋯
    -- button was moved to the bottom row precisely to keep this strip
    -- clear). We open the top menu directly rather than letting the tap
    -- fall through to ReaderMenu:onTapShowMenu, which would ALSO open the
    -- bottom config menu whenever the user's show_bottom_menu setting is
    -- on (the default) — here we never want that second menu.
    if self.on_show_menu and G_reader_settings:nilOrTrue(TOP_MENU_KEY)
       and self:_inTopMenuZone(ges.pos) then
        self.on_show_menu()
        return true
    end
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
        if self._more_is_gallery then
            -- no Quick Actions: the button IS the Gallery, so jump straight in
            -- (flash like the other action buttons, no popup)
            self:_flashButton(self._more_frame, function() self:_enterGallery() end)
        else
            -- press feedback: repaint the button inverted (rounded, via its
            -- stencil mask); it stays inverted while the menu is open and
            -- repaints normal on dismiss, whose region covers the button
            local d = self._more_frame.dimen
            self._more_frame.inverted = true
            UIManager:widgetRepaint(self._more_frame, d.x, d.y)
            UIManager:setDirty(nil, "fast", d)
            self:_showMoreMenu()
        end
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
    -- zoom control: three stacked zones — plus (top), fit-reset (middle,
    -- inert when already at fit), minus (bottom)
    if self._zoomctl_frame and self._zoomctl_frame.dimen
       and ges.pos:intersectWith(self._zoomctl_frame.dimen) then
        local d = self._zoomctl_frame.dimen
        local zone = math.min(2, math.max(0,
            math.floor((ges.pos.y - d.y) / (d.h / 3))))
        if zone == 0 then
            if not self:_isAtMax() then
                self:_flashZoomZone(0, function() self:_zoomStep(1) end)
            end
        elseif zone == 1 then
            if self:_isOverFit() then
                self:_flashZoomZone(1, function()
                    self.scale_factor = 0
                    self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
                    self:update()
                end)
            end
        else
            if self:_isOverFit() then
                self:_flashZoomZone(2, function() self:_zoomStep(-1) end)
            end
        end
        return true
    end
    if self._gallery_mode then
        -- the tab switcher: tap a segment to show that pool (tapping the
        -- already-active segment is a no-op)
        local sw = self._pill_frame
        if sw and sw.hitSegment then
            local seg = sw:hitSegment(ges.pos)
            if seg then
                local tab = (seg == 2) and "ignored" or "shown"
                if tab ~= self._gallery_tab then
                    self:_switchGalleryTab(tab)
                end
                return true
            end
        end
        -- thumbnail: tap opens it ONLY when this pool is what the single-image
        -- view shows (the primary/Gallery tab). A tap on an Ignored
        -- thumbnail does nothing — adding it back is a long-press (see onHold).
        local cell = self:_galleryHit(ges.pos)
        if cell and self._gallery_tab == (self.primary_tab or "shown") then
            self:_exitGallery(cell.idx)
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
    -- new image: the outgoing image's full-res decode is no longer needed
    self:_resetHiRes()
    -- New image content: flash the panel region on the resulting refresh so
    -- the previous image doesn't ghost through (see the refresh policy in
    -- update()). switchToImageNum → ImageViewer.switchToImageNum → update().
    self._flash_switch = true
    -- take the light refresh path in update() (rebuild chrome, but repaint the
    -- content overlay with a non-dithered image-region refresh instead of a
    -- dithered whole-drawer one) — gated on "Fast image switching"
    self._switching = true
    ImageViewer.switchToImageNum(self, image_num)
    local meta = self.image_metas and self.image_metas[image_num]
    if meta and self.on_image_shown then
        self.on_image_shown(meta, image_num)
    end
    self:_prefetchNeighbors()
end

-- Warm the decode cache for the images on either side of the current one, so
-- the next arrow/swipe is a copy of an already-decoded bitmap instead of a
-- fresh decode+cap-scale. The work runs on a short delay so the just-triggered
-- switch refreshes first, and a generation counter cancels any prefetch left
-- pending when the user keeps moving — only the position they settle on warms,
-- and rapid swiping never piles up stale decodes. Calling the list closure is
-- what populates the shared cache (see the decode closure in showViewer); the
-- copy it returns is ours to free immediately.
function GlimpseViewer:_prefetchNeighbors()
    if self._gallery_mode then return end
    -- ImageViewer keeps the closure list in _images_list; self.image is the
    -- CURRENT decoded bitmap after a switch, not the list.
    local list = self._images_list
    if type(list) ~= "table" then return end
    self._prefetch_gen = (self._prefetch_gen or 0) + 1
    local gen = self._prefetch_gen
    local cur = self._images_list_cur or 1
    local nb = self._images_list_nb or 1
    local targets = {}
    if cur + 1 <= nb then targets[#targets + 1] = cur + 1 end
    if cur - 1 >= 1 then targets[#targets + 1] = cur - 1 end
    for _, idx in ipairs(targets) do
        local fn = list[idx]
        if type(fn) == "function" then
            UIManager:scheduleIn(0.15, function()
                if self._prefetch_gen ~= gen then return end
                local ok, bb = pcall(fn)
                if ok and bb and bb.free then bb:free() end
            end)
        end
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
        -- Settings → Gestures → Swipe left/right to navigate (on by default).
        -- Only the single-image nav is gated; the Gallery's swipe-to-page is
        -- its primary affordance and stays on.
        local d = ges.direction
        if self._images_list and (d == "west" or d == "east")
                and G_reader_settings:nilOrTrue(GESTURE_SWIPE_KEY) then
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

-- Upstream ImageViewer closes on ANY multiswipe (a direction-changing
-- gesture). While panning a zoomed image, a curved or hooked drag is very
-- easily reclassified from a pan into a multiswipe, which would close the
-- drawer mid-pan — the "panning sometimes just closes Glimpse" bug. Glimpse
-- closes by tapping outside the panel instead, so swallow multiswipes here.
function GlimpseViewer:onMultiSwipe(_, ges)
    return true
end

-- Settings → Gestures → Pinch to zoom in/out (on by default). Spread zooms
-- in, pinch zooms out (upstream ImageViewer); swallow both when the user has
-- turned the gesture off, so a stray pinch can't change the zoom.
function GlimpseViewer:onSpread(arg, ges)
    if not G_reader_settings:nilOrTrue(GESTURE_PINCH_KEY) then return true end
    return ImageViewer.onSpread(self, arg, ges)
end

function GlimpseViewer:onPinch(arg, ges)
    if not G_reader_settings:nilOrTrue(GESTURE_PINCH_KEY) then return true end
    return ImageViewer.onPinch(self, arg, ges)
end

-- Long-press a Gallery thumbnail opens a small anchored menu with the one
-- move action for that pool (Ignore this image / Add back to Gallery);
-- see _openMoveMenu. Outside the gallery, defer to upstream (long-press
-- starts a pan on a zoomed image).
function GlimpseViewer:onHold(_, ges)
    if self._gallery_mode then
        local cell = self:_galleryHit(ges.pos)
        if cell then self:_openMoveMenu(cell, ges.pos) end
        return true
    end
    return ImageViewer.onHold(self, _, ges)
end

-- Upstream ImageViewer:onHoldRelease turns a hold-with-no-move into a
-- full-screen refresh (self.dithered + setDirty "full"). Over the drawer that
-- flashes the whole page and re-blends the side shadow, so a stray long-press
-- on the image reads as a glitch. Drop that branch: a hold that actually
-- moved still pans a zoomed image, a stationary one is simply ignored. (In
-- the gallery the hold already opened the move menu, so nothing to release.)
function GlimpseViewer:onHoldRelease(_, ges)
    if self._gallery_mode then return true end
    if self._panning then
        self._panning = false
        self._pan_relative_x = ges.pos.x - self._pan_relative_x
        self._pan_relative_y = ges.pos.y - self._pan_relative_y
        if math.abs(self._pan_relative_x) >= self.pan_threshold
                or math.abs(self._pan_relative_y) >= self.pan_threshold then
            self:panBy(-self._pan_relative_x, -self._pan_relative_y)
        end
    end
    return true
end

-- Repaint just the overlay (image + all chrome) with the given refresh mode,
-- WITHOUT re-running the drawer's panel/shadow paint (that only changes on
-- open/close and re-blending it would darken the shadow). Used by the light
-- zoom path. Non-dithered: a zoom step doesn't need it, and a lingering
-- dithered flag on self/the image would otherwise infect the regional refresh.
function GlimpseViewer:_repaintOverlayFast(mode)
    -- OverlapGroup never updates its own dimen.x/y on paint, but the image
    -- layer (a FrameContainer filling the same content area) does — so use it
    -- for the absolute origin and the refresh region.
    local ov, il = self._overlay, self._image_layer
    if not (ov and il) then return false end
    local ox, oy, region
    if il.dimen then
        ox, oy, region = il.dimen.x, il.dimen.y, il.dimen
    else
        -- fresh overlay (rebuilt this update, e.g. a light image switch): it
        -- hasn't painted yet, so derive the content origin from the persistent
        -- main_frame + its paddings. widgetRepaint sets il.dimen for next time.
        local mf = self.main_frame
        if not (mf and mf.dimen) then return false end
        ox = mf.dimen.x + (mf.padding_left or 0)
        oy = mf.dimen.y + (mf.padding_top or 0)
        region = Geom:new{ x = ox, y = oy, w = self.width, h = self.height }
    end
    self.dithered = false
    if self._image_wg then self._image_wg.dithered = false end
    UIManager:widgetRepaint(ov, ox, oy)
    -- The overlay paints the image's SQUARE corners over the panel's rounded
    -- corner notches. A full paint fixes this in main_frame.paintTo via
    -- _restoreCorners; the light path skips main_frame, so re-blend the saved
    -- rounded corners here too — otherwise the drawer reads as a full rectangle
    -- after a zoom step.
    local mf = self.main_frame
    if self._corner_bbs and mf and mf.dimen then
        self:_restoreCorners(Screen.bb, mf.dimen.x, mf.dimen.y)
    end
    UIManager:setDirty(nil, mode, region)
    return true
end

-- On the SDL emulator, mouse wheel / two-finger trackpad scroll arrives as
-- a fake pan gesture tagged mousewheel_direction (real devices never send
-- it): treat it as zoom, so pinch can be tested without a touchscreen.
--
-- Panning otherwise falls through to the stock ImageViewer, which repositions
-- the image once on release (onPanRelease → panBy → one clean refresh). We
-- tried live finger-tracking (updating several times a second during the drag)
-- but every e-ink waveform failed on device: "ui"/REAGL black-wipes (flashes)
-- each frame, and the fast waveforms ("fast"/"a2") leave the image an
-- unreadable merged ghost. Since panning a zoomed image changes ~the whole
-- image area every frame, there's no small region to isolate and no waveform
-- that is fast, non-flashing AND ghost-free at once — so we match the native
-- viewer's jump-on-release behaviour instead. (Zoom keeps its light-update
-- speedup; that's a discrete step, not continuous motion.)
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

-- True when the image is zoomed all the way in (at the max-zoom ceiling), so
-- the + step can't do anything more. scale_factor 0 is fit, never the max.
function GlimpseViewer:_isAtMax()
    if self.scale_factor == 0 then return false end
    local maxs = self:_maxScale()
    if not maxs then return false end
    return self.scale_factor >= maxs - 0.001
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
    -- Route the update() these paths trigger (here, and inside the upstream
    -- clamp below) through the light image-only rebuild — a zoom step never
    -- changes the surrounding chrome. Covers pinch, the +/− buttons, and
    -- double-tap alike, since all of them land here.
    self._zooming = true
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
    -- Ceiling: pinch may push a little past 100% (up to max_zoom_of_native)
    -- for readability, but no further — beyond that it's pure upscaling with
    -- no new detail. Bounds both pinch and any programmatic zoom.
    local ceil = self:_maxScale()
    if ceil and new_factor > ceil then new_factor = ceil end
    if fit and new_factor <= fit then
        if self.scale_factor ~= 0 then
            self.scale_factor = 0
            self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
            self:update()
        end
        self._zooming = nil
        return
    end
    ImageViewer._applyNewScaleFactor(self, new_factor)
    self._zooming = nil
end

-- The scale_factor (in capped-bitmap units) at which the image shows at
-- exactly 100% — 1 native image pixel per screen pixel. Native dimensions
-- come from the scanner's header sniff (meta.width); when the resting bitmap
-- was never capped (small/medium images) 100% is just 1.0. Rotation doesn't
-- affect the ratio (both widths are pre-rotation). Returns nil if we can't
-- tell, leaving the memory-based extrema as the only ceiling.
function GlimpseViewer:_nativeScale()
    local lo = self.image
    if not lo or not lo.getWidth then return nil end
    local lo_w = lo:getWidth()
    if lo_w <= 0 then return nil end
    local meta = self.image_metas and self.image_metas[self._images_list_cur or 1]
    local nat_w = meta and meta.width
    if not nat_w or nat_w <= lo_w then return 1.0 end
    return nat_w / lo_w
end

-- Zoom ceiling in capped-bitmap units: native size × the readability
-- multiplier (max_zoom_of_native). Both the pinch clamp and the double-tap
-- target land here.
function GlimpseViewer:_maxScale()
    local nat = self:_nativeScale()
    return nat and nat * self.max_zoom_of_native
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
            text = _("Image ignored."),
        })
        return
    end
    if self.image and self.image_disposable and self.image.free then
        self.image:free()
        self.image = nil
    end
    self:_resetHiRes() -- the removed image's full-res decode is done with
    local new_cur = math.min(cur, nb)
    self._cur_rotation = self:_prefFor(new_cur).rotation or 0
    self.image = self._images_list[new_cur]
    if type(self.image) == "function" then
        self.image = self.image()
    end
    self._images_list_cur = new_cur
    self:update()
    UIManager:show(Notification:new{
        text = _("Image ignored."),
    })
    local meta2 = self.image_metas and self.image_metas[new_cur]
    if meta2 and self.on_image_shown then
        self.on_image_shown(meta2, new_cur)
    end
end

-- Single-view "Remove bookmark": delete the dogear in the book (via the
-- plugin callback) and drop this item in place, then advance to a neighbour —
-- the same in-list surgery as _hideCurrentImage. image/image_metas ARE the
-- shown pool (bookmarks only exist when "shown" is primary), so removing here
-- keeps the Gallery consistent without a reopen.
function GlimpseViewer:_removeCurrentBookmark()
    local cur = self._images_list_cur
    local meta = self.image_metas and self.image_metas[cur]
    if not (meta and meta.is_bookmark) then return end
    if self.on_remove_bookmark then
        self.on_remove_bookmark(meta, false)
    end
    table.remove(self._images_list, cur)
    if self.image_metas then
        table.remove(self.image_metas, cur)
    end
    local nb = self._images_list_nb - 1
    self._images_list_nb = nb
    if nb < 1 then
        self:onClose()
        UIManager:show(Notification:new{ text = _("Bookmark removed.") })
        return
    end
    if self.image and self.image_disposable and self.image.free then
        self.image:free()
        self.image = nil
    end
    self:_resetHiRes()
    local new_cur = math.min(cur, nb)
    self._cur_rotation = self:_prefFor(new_cur).rotation or 0
    self.image = self._images_list[new_cur]
    if type(self.image) == "function" then
        self.image = self.image()
    end
    self._images_list_cur = new_cur
    self:update()
    UIManager:show(Notification:new{ text = _("Bookmark removed.") })
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
        title = _("Open Glimpse"),
        reader = true,
    })
end

function Glimpse:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Glimpse:onGlimpseShow()
    -- master switch (menu → Enable Glimpse): a disabled plugin swallows its
    -- own gesture so the bound gesture is effectively unmapped without the
    -- user having to unbind it in the gesture manager
    if not G_reader_settings:nilOrTrue(ENABLED_KEY) then return true end
    self:showViewer()
    return true
end

function Glimpse:onCloseDocument()
    -- the decoded-bitmap cache (see showViewer) is per book
    self:_bbCacheFree()
end

-- Small LRU of decoded, display-capped bitmaps keyed by path|night|invert.
-- Holds the working set around the current image (prev/cur/next) so switching
-- with the arrows or a swipe is a copy of an already-decoded bitmap instead of
-- a fresh decode+cap-scale of a multi-megapixel map. Neighbors are warmed by
-- GlimpseViewer:_prefetchNeighbors after a switch settles; the cap keeps the
-- footprint bounded on low-RAM devices (the bitmaps are already display-sized).
Glimpse.BB_CACHE_MAX = 3
function Glimpse:_bbCacheGet(key)
    local c = self._bb_cache
    local e = c and c.map[key]
    if not e then return nil end
    c.seq = c.seq + 1
    e.seq = c.seq
    return e.bb
end
function Glimpse:_bbCachePut(key, bb)
    local c = self._bb_cache
    if not c then c = { map = {}, n = 0, seq = 0 }; self._bb_cache = c end
    local prev = c.map[key]
    if prev then
        if prev.bb then prev.bb:free() end
        c.n = c.n - 1
    end
    c.seq = c.seq + 1
    c.map[key] = { bb = bb, seq = c.seq }
    c.n = c.n + 1
    while c.n > Glimpse.BB_CACHE_MAX do
        local lru_key, lru_seq
        for k, e in pairs(c.map) do
            if not lru_seq or e.seq < lru_seq then lru_seq, lru_key = e.seq, k end
        end
        if not lru_key then break end
        if c.map[lru_key].bb then c.map[lru_key].bb:free() end
        c.map[lru_key] = nil
        c.n = c.n - 1
    end
end
function Glimpse:_bbCacheFree()
    local c = self._bb_cache
    if not c then return end
    for k, e in pairs(c.map) do
        if e.bb then e.bb:free() end
        c.map[k] = nil
    end
    self._bb_cache = nil
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

-- Images the user has explicitly pulled back INTO the collection from the
-- Gallery's "Ignored" tab (the filter dropped them, or they were hidden).
-- The inverse of glimpse_hidden; a path in both means "shown" wins via the
-- partition in showViewer (add-back clears hidden and sets forced together).
function Glimpse:_forcedPaths()
    return (self.ui.doc_settings and
            self.ui.doc_settings:readSetting("glimpse_forced")) or {}
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
    -- Flush now so a per-image rotation survives even an unclean shutdown
    -- (sleep/battery-pull on an e-reader) rather than waiting for KOReader's
    -- next autosave or a clean book close. Cheap: rotation is a rare,
    -- user-initiated action, never a hot path.
    self.ui.doc_settings:flush()
end

function Glimpse:_hiddenCount()
    local n = 0
    for _ in pairs(self:_hiddenPaths()) do n = n + 1 end
    return n
end

-- ── bookmarked pages (Advanced → Include bookmarked pages) ──────────────────
-- The user's dogear-bookmarked pages, surfaced in the Gallery as page
-- thumbnails rendered by KOReader's own "Skim" service (ReaderThumbnail),
-- interleaved with the scanned images in reading order. They are a deliberate
-- flag, so they ignore the spoiler scope. Rendering is asynchronous (a
-- subprocess renders each page), so a closure hands out a placeholder until
-- the real tile arrives, then a callback refreshes the view.

-- Reading-position page number for a scanned-image meta, used only to
-- interleave bookmarks with images. Mirrors "Show in Book"'s xpointer, then
-- falls back to the chapter (spine fragment) top, then 0 (cover/unknown).
function Glimpse:_metaPageNumber(meta)
    local doc = self.ui and self.ui.document
    if not (doc and doc.getPageFromXPointer) then return 0 end
    local xp
    if meta.node_path and meta.spine_index and meta.spine_index > 0
            and doc.isXPointerInDocument then
        local cand = string.format("/body/DocFragment[%d]/body/%s",
            meta.spine_index, meta.node_path)
        local ok = pcall(function() return doc:isXPointerInDocument(cand) end)
        if ok and doc:isXPointerInDocument(cand) then xp = cand end
    end
    if not xp and meta.spine_index and meta.spine_index > 0 then
        xp = string.format("/body/DocFragment[%d]", meta.spine_index)
    end
    if not xp then return 0 end
    local ok, page = pcall(function() return doc:getPageFromXPointer(xp) end)
    return (ok and page) or 0
end

-- Pseudo-image records for the dogear bookmarks, already in reading order
-- (annotations are kept position-sorted). Each carries its page number (for
-- rendering + ordering) and the screen aspect (page thumbnails come out at
-- the screen ratio, so the masonry cell should match).
function Glimpse:_collectBookmarkMetas()
    local out = {}
    local ann = self.ui and self.ui.annotation
    local bm = self.ui and self.ui.bookmark
    if not (ann and bm and ann.annotations) then return out end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local toc = self.ui and self.ui.toc
    for _, a in ipairs(ann.annotations) do
        if not a.drawer then -- a plain page bookmark, not a highlight
            local page = bm:getBookmarkPageNumber(a)
            if page then
                -- chapter title for the identity pill (empty if untitled)
                local chapter
                if toc and toc.getTocTitleByPage then
                    local ok, t = pcall(function()
                        return toc:getTocTitleByPage(page)
                    end)
                    if ok then chapter = t end
                end
                out[#out + 1] = {
                    is_bookmark = true,
                    page = page,
                    _page = page,
                    chapter = chapter,
                    xpointer = a.page,
                    path = "glimpse-bm:" .. tostring(a.page),
                    width = sw,
                    height = sh,
                }
            end
        end
    end
    return out
end

-- Delete the dogear bookmark this pseudo-meta stands for, from the book's own
-- annotations. We match on the stored xpointer (meta.xpointer == annotation
-- .page) rather than a page number, so we remove exactly the right one even
-- when several bookmarks resolve to the same page. removeItem handles the
-- dogear-visibility refresh for the current page.
function Glimpse:_removeBookmark(meta)
    local ann = self.ui and self.ui.annotation
    local bm = self.ui and self.ui.bookmark
    if not (ann and bm and ann.annotations and meta and meta.xpointer) then
        return false
    end
    for i = #ann.annotations, 1, -1 do
        local a = ann.annotations[i]
        if not a.drawer and a.page == meta.xpointer then
            bm:removeItem(a, i) -- also updates dogear_visible for the current page
            -- If the removed bookmark was on the page under the drawer, the
            -- dogear fold still shows in the visible right-hand sliver because
            -- nothing has repainted it. removeItem only flips the visibility
            -- flag; repaint the fold's corner (as KOReader's own toggle does)
            -- so it disappears immediately instead of only when Glimpse closes.
            local dogear = self.ui and self.ui.view and self.ui.view.dogear
            if dogear and dogear.getRefreshRegion and dogear.icon
                    and dogear.icon.dimen then
                UIManager:setDirty(self.ui, function()
                    return "ui", dogear:getRefreshRegion()
                end)
            end
            return true
        end
    end
    return false
end

-- A fresh, disposable page-shaped placeholder shown until the real thumbnail
-- renders (the viewer/thumbnail owns and frees what closures return).
function Glimpse:_bookmarkPlaceholder(im)
    local w = math.max(2, math.floor((im.width or Screen:getWidth()) / 3))
    local h = math.max(2, math.floor((im.height or Screen:getHeight()) / 3))
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    return bb
end

function Glimpse:_bookmarkThumb(im)
    return self._bm_cache and self._bm_cache[im.path]
end

-- The size we render/cache bookmark pages at: the drawer's display size (see
-- _requestBookmarkThumb). Shared so the disk-cache key matches the render.
function Glimpse:_bmThumbSize()
    local ratio = GlimpseViewer.panel_ratio or 1
    local w = math.max(1, math.floor(Screen:getWidth() * ratio))
    return w, Screen:getHeight()
end

-- ── on-disk bookmark-thumbnail cache ────────────────────────────────────────
-- A rendered page survives closing the book, so reopening the Gallery later
-- loads instantly from disk instead of re-forking a ~500ms subprocess render
-- per page. Lives under KOReader's cache (regenerable, disposable — never in
-- the book's sidecar). Each file is one zstd-compressed page tile, keyed by
-- book + page + render size + the document's rendering hash, so a font/margin
-- change (which reflows pages) transparently invalidates the stale renders.

function Glimpse:_bmDiskDir()
    if self._bm_disk_dir ~= nil then return self._bm_disk_dir or nil end
    local dir = DataStorage:getDataDir() .. "/cache/glimpse-thumbs/"
    lfs.mkdir(dir) -- no-op if it already exists
    self._bm_disk_dir = dir
    return dir
end

function Glimpse:_bmDiskPath(im, w, h)
    local dir = self:_bmDiskDir()
    if not dir then return nil end
    local doc = self.ui and self.ui.document
    local file = (doc and doc.file) or "?"
    local nm = ""
    if Screen.night_mode and doc and doc.configurable
            and doc.configurable.nightmode_images == 1 then
        nm = "_nm" -- getPageThumbnail bakes night pages differently; key apart
    end
    local rhash = 0
    if doc and doc.getDocumentRenderingHash then
        local ok, r = pcall(function() return doc:getDocumentRenderingHash(false) end)
        if ok and r then rhash = r end
    end
    local key = string.format("%s|p%d|w%d|h%d|r%s%s",
        file, im.page, w, h, tostring(rhash), nm)
    return dir .. md5(key) .. ".tile"
end

-- Load a previously-saved page tile synchronously (nil if absent/unreadable).
-- The returned bb is ours to own; _freeBookmarkThumbs frees it like a rendered
-- copy. Touch the file's mtime on a hit so the size cap evicts truly-cold ones.
function Glimpse:_loadBookmarkThumbFromDisk(im)
    local w, h = self:_bmThumbSize()
    local path = self:_bmDiskPath(im, w, h)
    if not path or not lfs.attributes(path, "mode") then return nil end
    local item = TileCacheItem:new{}
    local ok = pcall(function() item:load(path) end)
    if ok and item.bb then
        pcall(function() lfs.touch(path) end)
        return item.bb
    end
    return nil
end

-- Persist a freshly-rendered page tile. Reads the bb (does not free it), so the
-- caller keeps ownership of ReaderThumbnail's original.
function Glimpse:_saveBookmarkThumbToDisk(im, bb, w, h)
    local path = self:_bmDiskPath(im, w, h)
    if not path then return end
    local item = TileCacheItem:new{ bb = bb }
    pcall(function() item:dump(path) end)
end

-- Keep the shared thumbnail cache bounded: once per viewer session, drop the
-- coldest files (by mtime) until the directory is back under the byte cap.
-- Cheap — a single directory scan, only when we actually cache bookmarks.
function Glimpse:_pruneBookmarkDiskCache()
    if self._bm_pruned then return end
    self._bm_pruned = true
    local dir = self:_bmDiskDir()
    if not dir then return end
    local CAP = 64 * 1024 * 1024 -- 64 MB across all books
    local files, total = {}, 0
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local p = dir .. name
            local a = lfs.attributes(p)
            if a and a.mode == "file" then
                files[#files + 1] = { path = p, size = a.size, mtime = a.modification }
                total = total + (a.size or 0)
            end
        end
    end
    if total <= CAP then return end
    table.sort(files, function(a, b) return a.mtime < b.mtime end) -- coldest first
    for _, f in ipairs(files) do
        if total <= CAP then break end
        if pcall(os.remove, f.path) then total = total - (f.size or 0) end
    end
end

-- ReaderThumbnail renders the page with its dogear fold showing (the page IS
-- bookmarked), which is redundant with our own bookmark badge and clutters the
-- thumbnail. The render forks from this process, so stubbing the shared
-- dogear's paintTo suppresses it in the child; the reader's own dogear is
-- hidden behind our drawer meanwhile, and we restore it on teardown.
function Glimpse:_suppressDogear()
    local dogear = self.ui and self.ui.view and self.ui.view.dogear
    if dogear and not self._dogear_orig_paint then
        self._dogear_orig_paint = dogear.paintTo
        dogear.paintTo = function() end
    end
end

function Glimpse:_restoreDogear()
    local dogear = self.ui and self.ui.view and self.ui.view.dogear
    if dogear and self._dogear_orig_paint then
        dogear.paintTo = self._dogear_orig_paint
    end
    self._dogear_orig_paint = nil
end

-- Kick off an async page render for a bookmark (idempotent). On completion we
-- copy the tile out of ReaderThumbnail's cache (it owns the original, so we
-- must not free it) and poke the viewer to repaint with the real page. The
-- tile is rendered in day polarity; the ImageWidget's original_in_nightmode
-- =false gets it night-styled at paint (exactly like KOReader's PageBrowser),
-- so no night handling is needed here.
function Glimpse:_requestBookmarkThumb(im)
    if not (im and im.is_bookmark and im.page) then return end
    self._bm_cache = self._bm_cache or {}
    self._bm_pending = self._bm_pending or {}
    if self._bm_cache[im.path] or self._bm_pending[im.path] then return end
    -- Disk cache first: a page render from an earlier session (this book was
    -- closed and reopened) loads instantly, skipping the subprocess entirely.
    -- The caller re-checks _bookmarkThumb after this returns, so a disk hit
    -- shows the real page immediately with no async round-trip.
    local disk_bb = self:_loadBookmarkThumbFromDisk(im)
    if disk_bb then
        self._bm_cache[im.path] = disk_bb
        return
    end
    local thumb = self.ui and self.ui.thumbnail
    if not (thumb and thumb.getPageThumbnail) then return end
    self._bm_batch = self._bm_batch or "glimpse_bookmarks"
    self:_suppressDogear() -- keep the dogear fold out of the rendered page
    self._bm_pending[im.path] = true
    -- Render at the drawer's display size, not full screen. The single view
    -- fits the page into the ~80%-wide drawer, so a full-screen tile is
    -- oversampled (and the Gallery's 1/3-width cells downscale it further); a
    -- drawer-sized tile is still crisp at the resting (fit) view while cutting
    -- each cached page's memory to ~two-thirds. Zoom past fit just upscales,
    -- as it already did — a bookmark has no sharper source than its thumbnail.
    local w, h = self:_bmThumbSize()
    -- A cached tile makes getPageThumbnail invoke the callback SYNCHRONOUSLY,
    -- re-entering during the closure that requested it. In that case the
    -- closure's own re-check picks up the tile, so we must NOT also poke the
    -- viewer from here (it would re-enter switchToImageNum mid-build and get
    -- clobbered). `is_async` is false for a synchronous callback (it runs
    -- before the line after this call) and true for a real deferred one.
    local is_async = false
    thumb:getPageThumbnail(im.page, w, h, self._bm_batch,
        function(tile)
            if not self._bm_pending then return end -- torn down meanwhile
            self._bm_pending[im.path] = nil
            if tile and tile.bb then
                self._bm_cache[im.path] = tile.bb:copy()
                -- persist for instant reopens after the book is closed
                self:_saveBookmarkThumbToDisk(im, tile.bb, w, h)
                self:_pruneBookmarkDiskCache()
                if is_async and self._viewer
                        and self._viewer._onBookmarkThumbReady then
                    self._viewer:_onBookmarkThumbReady(im.path)
                end
            end
        end)
    is_async = true
end

-- Free our page-thumbnail copies and cancel any in-flight renders (called
-- when the viewer closes).
function Glimpse:_freeBookmarkThumbs()
    self:_restoreDogear()
    local thumb = self.ui and self.ui.thumbnail
    if thumb and thumb.cancelPageThumbnailRequests and self._bm_batch then
        pcall(function() thumb:cancelPageThumbnailRequests(self._bm_batch) end)
    end
    if self._bm_cache then
        for k, bb in pairs(self._bm_cache) do
            if bb then pcall(function() bb:free() end) end
            self._bm_cache[k] = nil
        end
    end
    self._bm_cache, self._bm_pending = nil, nil
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
        return false, _("Glimpse works with EPUB books only (this document format is not supported)."), "unsupported"
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
    -- Live in the book's own sidecar (.sdr) folder, next to KOReader's
    -- metadata, so the scan travels with the book when it's copied between
    -- devices (getSidecarDir honours the user's metadata-location setting:
    -- doc/dir/hash — the cache follows wherever the metadata lives). Older
    -- builds kept a central koreader/glimpse/<key>.lua; those files are now
    -- orphaned and simply re-scanned into the sidecar on next open.
    local dir = DocSettings:getSidecarDir(self.ui.document.file)
    lfs.mkdir(dir)
    return dir .. "/glimpse.scan.lua"
end

-- cache_only: return an in-memory or valid on-disk cached scan (or nil) WITHOUT
-- running a fresh scan. showViewer uses this to open silently on a cache hit,
-- and only put up the "Scanning…" message (a visible e-ink double refresh) when
-- a real scan is actually needed.
function Glimpse:_getScan(force, cache_only)
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
    if cache_only then return nil end

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

-- Flatten a rendered image onto opaque white. PNGs (and SVGs) with a
-- transparent background are usually black line art meant to sit on the page;
-- left transparent they vanish in night mode (black lines over the black
-- backdrop) and their anti-aliased edges invert into jaggies. Compositing onto
-- white makes every pixel opaque, so night-mode framebuffer inversion turns it
-- into clean white-on-black. A no-op for images that carry no alpha channel.
local function _flatten_on_white(bb)
    if not bb then return bb end
    local ok, btype = pcall(function() return bb:getType() end)
    if not ok then return bb end
    if btype ~= Blitbuffer.TYPE_BB8A and btype ~= Blitbuffer.TYPE_BBRGB32 then
        return bb  -- no alpha channel, nothing to flatten
    end
    local w, h = bb:getWidth(), bb:getHeight()
    -- opaque target of a matching family (colour stays colour, gray stays gray)
    local out_type = (btype == Blitbuffer.TYPE_BBRGB32)
        and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8
    local flat = Blitbuffer.new(w, h, out_type)
    flat:fill(Blitbuffer.COLOR_WHITE)
    flat:alphablitFrom(bb, 0, 0, 0, 0, w, h)
    bb:free()
    return flat
end

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
    return _flatten_on_white(bb)
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
    local ok, msg, why = self:_supportedReason()
    if not ok then
        -- Advanced → suppress the "not supported" notice: silences only the
        -- unsupported-format case (e.g. a stray gesture on a PDF/manga), never
        -- "No book is open" or a loader failure.
        if not (why == "unsupported"
                and G_reader_settings:isTrue(SUPPRESS_UNSUPPORTED_KEY)) then
            UIManager:show(InfoMessage:new{ text = msg })
        end
        return
    end

    -- Try an in-memory or valid on-disk cached scan silently first: a cache
    -- hit opens with a single refresh. Only a genuine (slow) scan puts up the
    -- "Scanning…" message — whose show+close forceRePaints read as a double
    -- refresh/flash on e-ink, and used to fire on the FIRST open of every book
    -- even when the scan was already cached.
    local scan = self:_getScan(false, true)
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
    local kept_list = scanner.filter(scan.images, level)
    local kept_paths = {}
    for _, im in ipairs(kept_list) do kept_paths[im.path] = true end
    local forced = self:_forcedPaths()
    local hidden = self:_hiddenPaths()

    -- Partition every scanned image (kept in reading order) into the
    -- collection the user sees ("shown") and the pool the Gallery's Ignored
    -- tab offers ("ignored"). Shown = kept by the relevance filter OR
    -- force-added by the user, and not hidden. Ignored = everything else:
    -- images the filter dropped (and the user hasn't re-added) plus images
    -- the user hid. Long-pressing a thumbnail in the Gallery moves an image
    -- between the two (see on_ignore/on_unignore); the paths persist per book.
    local shown_metas, ignored_metas = {}, {}
    for _, im in ipairs(scan.images) do
        local is_shown = (kept_paths[im.path] or forced[im.path])
            and not hidden[im.path]
        if is_shown then
            shown_metas[#shown_metas + 1] = im
        else
            ignored_metas[#ignored_metas + 1] = im
        end
    end

    -- scope: drop images beyond the reading position from BOTH pools (the
    -- Ignored tab respects spoiler scope too). scope_hidden counts what the
    -- chapter scope holds back from the shown collection (gallery heading).
    local scope_hidden = 0
    if self:getScope() == "read_so_far" and not whole_book_once then
        local cur = self:_currentSpineIndex()
        if cur then
            local function clip(list)
                local kept = {}
                for _, im in ipairs(list) do
                    if im.spine_index <= cur then kept[#kept + 1] = im end
                end
                return kept
            end
            local before = #shown_metas
            shown_metas = clip(shown_metas)
            scope_hidden = before - #shown_metas
            ignored_metas = clip(ignored_metas)
        end
    end

    -- Advanced → Include bookmarked pages: merge the user's dogear bookmarks
    -- into the shown collection, in reading order. Bookmarks ignore the
    -- spoiler scope (a deliberate flag), so they go in AFTER the clip. Both
    -- lists are already reading-ordered, so assign each image a page number
    -- and merge the two monotonic lists (images first on ties).
    if G_reader_settings:isTrue(BOOKMARKS_KEY) then
        local bms = self:_collectBookmarkMetas()
        if #bms > 0 then
            for _, im in ipairs(shown_metas) do
                im._page = self:_metaPageNumber(im)
            end
            local merged, a, b = {}, 1, 1
            while a <= #shown_metas or b <= #bms do
                local ia, ib = shown_metas[a], bms[b]
                if ib == nil or (ia and (ia._page or 0) <= ib._page) then
                    merged[#merged + 1] = ia; a = a + 1
                else
                    merged[#merged + 1] = ib; b = b + 1
                end
            end
            shown_metas = merged
        end
    end

    -- The single-image viewer works on the shown collection. When the filter
    -- has left nothing shown but there ARE ignored images, opening is opt-in:
    -- the empty state offers "Review filtered-out", which reopens with the
    -- ignored pool as primary (a long-press reopen — _pending_gallery — does
    -- the same). Otherwise the common decorative-only book (every image
    -- correctly filtered) lands on the plain "No images" state instead of
    -- suddenly displaying its ornaments.
    local want_ignored_primary = self._review_ignored
        or (self._pending_gallery ~= nil)
    local primary_tab = "shown"
    if #shown_metas == 0 and want_ignored_primary and #ignored_metas > 0 then
        primary_tab = "ignored"
    end
    local imgs = (primary_tab == "shown") and shown_metas or ignored_metas

    if #imgs == 0 then
        -- Only offer "Search whole book" when the read-so-far scope is
        -- actually holding images back (scope_hidden > 0) — i.e. the search
        -- WILL return something. Offering it when the whole book has none
        -- (scope_hidden == 0) misleads: it implies images exist, then finds
        -- nothing. In that case just say so plainly.
        if self:getScope() == "read_so_far" and not whole_book_once
                and scope_hidden > 0 then
            local msg = scope_hidden == 1
                and _("No images up to here yet – 1 further in the book.")
                or T(_("No images up to here yet – %1 further in the book."),
                    scope_hidden)
            UIManager:show(ConfirmBox:new{
                text = msg,
                ok_text = _("Show whole book"),
                cancel_text = _("Close"),
                ok_callback = function()
                    self:showViewer(true)
                end,
            })
        elseif #ignored_metas > 0 then
            -- everything in scope was filtered out (the #4 case): let the
            -- user review and re-add from the Gallery's Ignored tab
            local msg = #ignored_metas == 1
                and _("No images to show – 1 was filtered out as irrelevant.")
                or T(_("No images to show – %1 were filtered out as irrelevant."),
                    #ignored_metas)
            UIManager:show(ConfirmBox:new{
                text = msg,
                ok_text = _("Review filtered-out"),
                ok_callback = function()
                    self._review_ignored = true
                    self:showViewer(whole_book_once)
                end,
            })
        else
            UIManager:show(InfoMessage:new{ text = _("No images to show.") })
        end
        return
    end
    self._review_ignored = nil -- consumed once we're actually opening

    -- lazy render functions: one image decoded at a time, freed on switch;
    -- "invert in night mode" (a global setting) is applied here so
    -- re-renders pick up setting and night-mode changes live.
    -- Night handling (device-agnostic): whenever night mode is on and the
    -- user has NOT ticked "Invert in Night Mode", pre-invert the image pixels
    -- so the screen's own global night inversion brings them back to their
    -- ORIGINAL colours — exactly what KOReader's ImageWidget does for every
    -- image (original_in_nightmode), just baked once here instead of per
    -- paint. Ticking the box skips the pre-invert, so the image ends up
    -- inverted (negative) on screen. Crucially this depends only on the
    -- SAME Screen.night_mode flag ImageWidget keys off (not getInverse() nor
    -- the persisted setting) so our pre-invert is always paired with the
    -- screen's actual inversion state — the old code keyed off getInverse()
    -- and the setting, which could disagree with it and reversed the image on
    -- some devices ("Invert in Night Mode reversed").
    local read_file, close_reader = self:_makeReader()
    -- The RESTING (fit) view decodes each image capped at 2× the drawer's
    -- content box (one C-speed, aspect-preserving downscale): ImageWidget
    -- rescales from the source on EVERY zoom/pan render, so browsing and
    -- swiping off a capped bitmap stays fast even for multi-megapixel maps.
    -- Zooming in past fit trades that for sharpness: GlimpseViewer lazily
    -- re-decodes THAT ONE image at full resolution (see _getHiRes /
    -- _new_image_wg), so magnifying shows real detail instead of upscaling
    -- the cap. The capped bitmap is only ever shown at/near fit.
    local cap_w = 2 * math.floor(Screen:getWidth() * GlimpseViewer.panel_ratio)
    local cap_h = 2 * Screen:getHeight()
    -- Decode + night/invert-bake one image. hires=false applies the resting
    -- cap; hires=true keeps native resolution. The night baking is identical
    -- both ways, so the sharp copy matches the resting copy where they overlap.
    local function decode(im, hires)
        local night = Screen.night_mode
        local checked = G_reader_settings:isTrue(INVERT_KEY)
        local bb = self:_render(read_file, im)
        if bb and not hires then
            local w, h = bb:getWidth(), bb:getHeight()
            local s = math.min(1, cap_w / w, cap_h / h)
            if s < 1 then
                local scaled = RenderImage:scaleBlitBuffer(bb,
                    math.floor(w * s + 0.5), math.floor(h * s + 0.5), true)
                if scaled then bb = scaled end
            end
        end
        -- pre-invert so the screen's night inversion restores the original,
        -- unless the user asked for an inverted (negative) image
        if bb and night and not checked then
            pcall(bb.invertRect, bb, 0, 0, bb:getWidth(), bb:getHeight())
        end
        return bb
    end
    -- Build a lazy render-closure list (parallel to a metas list) — one for
    -- the shown collection, one for the ignored pool (the Gallery tabs). Both
    -- share the single-slot decoded-bitmap cache below, keyed by path, so a
    -- thumbnail and the full view of the same image hit the same slot.
    local function make_list(metas)
        local list = { image_disposable = true }
        for i, im in ipairs(metas) do
            if im.is_bookmark then
                -- a bookmarked page: render lazily via ReaderThumbnail. Hand
                -- out our cached page copy, or a placeholder while it renders
                -- (the async callback repaints once the real tile lands). No
                -- night pre-invert: pages should invert WITH night mode (like
                -- the book), and ImageWidget's original_in_nightmode=false does
                -- exactly that.
                list[i] = function()
                    local bb = self:_bookmarkThumb(im)
                    if bb then return bb:copy() end
                    self:_requestBookmarkThumb(im)
                    -- the request can complete SYNCHRONOUSLY when the page is
                    -- already in KOReader's thumbnail cache (e.g. after a
                    -- close+reopen), so re-check before falling back to the
                    -- placeholder — otherwise we'd show a blank page that never
                    -- refreshes (the sync path fires no async notification)
                    bb = self:_bookmarkThumb(im)
                    if bb then return bb:copy() end
                    return self:_bookmarkPlaceholder(im)
                end
            else
            list[i] = function()
                local night = Screen.night_mode
                local checked = G_reader_settings:isTrue(INVERT_KEY)
                -- decoded-bitmap cache (small LRU, see _bbCacheGet): reopening
                -- on the image you left, or switching to a prefetched neighbor,
                -- skips the decode and cap-scale — on device that is most of the
                -- open time. The key bakes in everything baked into pixels.
                local key = im.path .. "|" .. tostring(night) .. tostring(checked)
                local cached = self:_bbCacheGet(key)
                if cached then
                    -- hand out a copy: the viewer owns and frees what we return
                    return cached:copy()
                end
                local bb = decode(im, false)
                if bb then self:_bbCachePut(key, bb:copy()) end
                return bb
            end
            end
        end
        return list
    end
    local shown_render = make_list(shown_metas)
    local ignored_render = make_list(ignored_metas)
    local images_list = (primary_tab == "shown") and shown_render or ignored_render
    -- Full-resolution decode for the zoomed view, called on demand by the
    -- viewer (one image at a time). read_file stays valid after close_reader()
    -- — it just reopens the libarchive fallback if the primary path misses.
    local hires_decode = function(index)
        local im = imgs[index]
        if not im then return nil end
        -- bookmarked pages have no sharper source than the rendered thumbnail;
        -- keep the resting page (zoom just upscales it)
        if im.is_bookmark then
            local bb = self:_bookmarkThumb(im)
            return bb and bb:copy() or nil
        end
        return decode(im, true)
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

    -- effective scope of THIS opening: whole_book_once (the empty-state
    -- "search whole book" path) shows everything even while the setting
    -- stays read_so_far, so the viewer's scope label must reflect that.
    local effective_scope = (self:getScope() == "read_so_far"
        and not whole_book_once) and "read_so_far" or "whole_book"

    local viewer
    viewer = GlimpseViewer:new{
        image = images_list,
        image_metas = imgs,
        -- zoom ceiling (multiple of native), from Advanced → Maximum zoom
        max_zoom_of_native = _maxZoomMult(),
        -- lazily supplies the full-res decode of the zoomed image (sharp zoom)
        hires_decode = hires_decode,
        -- Gallery tabs: the two pools, independent of which one is primary
        -- (the single-image view uses `image`/`image_metas` = the primary).
        shown_metas = shown_metas,
        shown_list = shown_render,
        ignored_metas = ignored_metas,
        ignored_list = ignored_render,
        primary_tab = primary_tab,
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
            if not self.ui.rolling then return end
            -- a bookmarked page jumps straight to its own location
            if meta.is_bookmark then
                if self.ui.link then
                    self.ui.link:addCurrentLocationToStack()
                end
                self.ui.rolling:onGotoXPointer(meta.xpointer)
                return
            end
            if not meta.spine_index then return end
            if self.ui.link then
                self.ui.link:addCurrentLocationToStack()
            end
            -- Chapter-level target is always available; try to refine it to
            -- the exact image first. The scanner's node_path is derived from
            -- raw HTML, so crengine's normalized DOM can disagree — validate
            -- the built xpointer resolves to THIS image (its filename appears
            -- in the element's HTML) before trusting it, else fall back to the
            -- chapter top (the pre-fix behaviour).
            local target = string.format("/body/DocFragment[%d]", meta.spine_index)
            local doc = self.ui.document
            if meta.node_path and doc and doc.isXPointerInDocument then
                local xp = string.format("/body/DocFragment[%d]/body/%s",
                    meta.spine_index, meta.node_path)
                local ok = pcall(function() return doc:isXPointerInDocument(xp) end)
                    and doc:isXPointerInDocument(xp)
                if ok then
                    local fname = meta.path and meta.path:match("[^/]+$")
                    local ok2, html = pcall(function()
                        return doc:getHTMLFromXPointer(xp, 0)
                    end)
                    if ok2 and html and fname
                            and html:find(fname, 1, true) then
                        target = xp
                    end
                end
            end
            self.ui.rolling:onGotoXPointer(target)
        end,
        -- the viewer closed itself on a G-sensor rotation: re-layout the
        -- reader, then reopen (zoom/pan persistence restores the view)
        on_rotate = function(rotation)
            self.ui.view:onSetRotationMode(rotation)
            self:showViewer(whole_book_once)
        end,
        -- a tap in KOReader's top-menu zone opens ONLY the top menu, over
        -- the still-open drawer (ShowMenu, not onTapShowMenu, so the
        -- bottom config menu never tags along regardless of show_bottom_menu)
        on_show_menu = function()
            self.ui:handleEvent(Event:new("ShowMenu"))
        end,
        scope = effective_scope,
        -- ⋯ → "Showing: …": flip the persistent scope to the opposite of
        -- what's on screen, then close and reopen so the image list rebuilds
        -- (onClose runs onCloseWidget synchronously, clearing self._viewer,
        -- so showViewer opens fresh rather than toggling itself shut).
        -- glimpse_last lands us on the same image when it's still in scope.
        on_toggle_scope = function()
            local new_scope = effective_scope == "whole_book"
                and "read_so_far" or "whole_book"
            G_reader_settings:saveSetting(SCOPE_KEY, new_scope)
            if self._viewer then self._viewer:onClose() end
            self:showViewer()
            -- name the mode the user just switched to (Quick Actions ⋯ row)
            UIManager:show(Notification:new{
                text = new_scope == "whole_book"
                    and _("Mode: All images")
                    or _("Mode: Images up to here"),
            })
        end,
        -- ⋯ → "Include Bookmarks in Gallery": flip the setting and reopen so
        -- the dogear pages fold in/out of the collection (same close+reopen
        -- dance as the scope switch; glimpse_last keeps our place).
        on_toggle_bookmarks = function()
            local now_on = G_reader_settings:isTrue(BOOKMARKS_KEY)
            G_reader_settings:saveSetting(BOOKMARKS_KEY, not now_on)
            if self._viewer then self._viewer:onClose() end
            self:showViewer()
            UIManager:show(Notification:new{
                text = now_on and _("Bookmarked pages hidden")
                    or _("Bookmarked pages shown"),
            })
        end,
        -- ⋯ → "Layout": open the Left/Right side chooser; picking a side saves
        -- the setting and reopens the drawer on that edge (see _showLayoutDialog).
        on_choose_layout = function()
            self:_showLayoutDialog()
        end,
        -- Gallery long-press, Shown tab: move this image to Ignored (hide it
        -- and drop any force-add). Persist, then reopen back into the Gallery
        -- on the same tab/page (the scan is cached, so the reopen is cheap).
        on_ignore = function(meta, tab, page)
            local h = self:_hiddenPaths(); h[meta.path] = true
            local f = self:_forcedPaths(); f[meta.path] = nil
            self.ui.doc_settings:saveSetting("glimpse_hidden", h)
            self.ui.doc_settings:saveSetting("glimpse_forced", next(f) and f or nil)
            self.ui.doc_settings:flush()
            self._pending_gallery = { tab = tab, page = page }
            if self._viewer then self._viewer:onClose() end
            self:showViewer(whole_book_once)
            UIManager:show(Notification:new{ text = _("Moved to Ignored") })
        end,
        -- Gallery long-press, Ignored tab: add this image back to Shown
        -- (force-include it and clear any hide). Same reopen-into-gallery.
        on_unignore = function(meta, tab, page)
            local f = self:_forcedPaths(); f[meta.path] = true
            local h = self:_hiddenPaths(); h[meta.path] = nil
            self.ui.doc_settings:saveSetting("glimpse_forced", f)
            self.ui.doc_settings:saveSetting("glimpse_hidden", next(h) and h or nil)
            self.ui.doc_settings:flush()
            self._pending_gallery = { tab = tab, page = page }
            if self._viewer then self._viewer:onClose() end
            self:showViewer(whole_book_once)
            UIManager:show(Notification:new{ text = _("Added to Gallery") })
        end,
        -- Remove a bookmarked page: delete the dogear in the book, then drop it
        -- from Glimpse. From the Gallery long-press we reopen into the same
        -- tab/page (like on_ignore); from the single-view ⋯ menu the viewer has
        -- already removed the item in place, so we only delete the dogear.
        on_remove_bookmark = function(meta, from_gallery, tab, page)
            self:_removeBookmark(meta)
            if from_gallery then
                self._pending_gallery = { tab = tab, page = page }
                if self._viewer then self._viewer:onClose() end
                self:showViewer(whole_book_once)
                -- the single-view path shows its own notice after in-place
                -- removal; here (reopened into the Gallery) we show it
                UIManager:show(Notification:new{ text = _("Bookmark removed.") })
            end
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
        self:_freeBookmarkThumbs()
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
    -- Land directly in the Gallery when this open is a long-press move
    -- reopen (return to the tab/page the user was on) or the "Review
    -- filtered-out" path (open on the Ignored tab). Done before the first
    -- show so it paints as the gallery, not a flash from single view.
    -- When there are no accepted images (primary is the Ignored pool), the
    -- gallery IS the root view — there's no kept collection to drop into, so
    -- the gallery's Back button closes Glimpse instead of surfacing an ignored
    -- image as if it were kept (tapping a specific ignored thumbnail still
    -- opens it, and clears this).
    viewer._gallery_is_root = (primary_tab == "ignored")
    if self._pending_gallery then
        local pg = self._pending_gallery
        self._pending_gallery = nil
        local tab = pg.tab
        -- if the tab we were on emptied out (moved its last image), show
        -- the other one instead of a blank grid
        local n = (tab == "ignored") and #ignored_metas or #shown_metas
        if n == 0 then tab = (tab == "ignored") and "shown" or "ignored" end
        viewer:_enterGallery(pg.page, tab)
    elseif primary_tab == "ignored" then
        -- opened via "Review filtered-out": land in the Ignored grid
        viewer:_enterGallery(1, "ignored")
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
    -- one dithered refresh covering the drawer (plus its gradient shadow when
    -- the shadow is on — it falls onto the page). With the shadow OFF, refresh
    -- ONLY the drawer, so the book area to its right is never in the region:
    -- otherwise KOReader's periodic promotion of this refresh to a flashing
    -- full flashes the page black even though nothing there changed.
    local open_w = viewer._panel_w + 2
    if not G_reader_settings:isTrue(SHADOW_KEY) then
        open_w = viewer._panel_w
            + 2 * viewer.shadow_width - viewer.shadow_overlap + 1
    end
    -- Refresh isolation: Glimpse lives in its own refresh world. Snapshot the
    -- reader's ghost-clear counter and reset it to 0 for the session, so the
    -- reader's accumulated count can't promote a Glimpse refresh into a
    -- full-screen flash, and Glimpse's own refreshes don't push the reader
    -- toward its periodic flash. The count is restored on close (onCloseWidget).
    viewer._reader_refresh_count = UIManager.refresh_count
    UIManager.refresh_count = 0
    -- the region hugs the drawer's screen edge: left for a left drawer, right
    -- for a right drawer (where the panel + its leftward shadow sit against the
    -- right edge)
    local open_rw = math.min(Screen:getWidth(), open_w)
    local open_rx = viewer._on_right and (Screen:getWidth() - open_rw) or 0
    UIManager:show(viewer, Device:hasKaleidoWfm() and "partial" or "ui",
        Geom:new{
            x = open_rx, y = 0,
            w = open_rw,
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

-- Entry point (menu callback): ensure we're connected, then check releases.
-- Wrapped in Trapper so the network wait shows a dismissable spinner.
--
-- We use runWhenCONNECTED, not runWhenOnline: runWhenOnline calls isOnline(),
-- which does a BLOCKING DNS resolve on the UI thread (socket.dns.toip) — when
-- the network is up but DNS isn't ready yet (common right after Wi-Fi
-- associates on Kobo) that stalls the whole UI for seconds, and every repeat
-- tap stalls it again. isConnected() only checks the interface has an IP (a
-- fast sysfs read), and the real reachability test then happens inside the
-- dismissable subprocess below (which reports a DNS/network error cleanly
-- instead of freezing). A re-entrancy guard drops repeat taps while a check
-- is already in flight, with a safety-net timer so it can never stick on if
-- the connect callback never fires (e.g. the user declines the Wi-Fi prompt).
function Glimpse:_checkForUpdate()
    if self._update_checking then return end
    self._update_checking = true
    UIManager:scheduleIn(90, function() self._update_checking = nil end)
    local NetworkMgr = require("ui/network/manager")
    local go = function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local ok, err = pcall(function() self:_runUpdateCheck(Trapper) end)
            self._update_checking = nil
            if not ok then logger.warn("Glimpse update check error:", err) end
        end)
    end
    if NetworkMgr.runWhenConnected then
        NetworkMgr:runWhenConnected(go)
    else
        NetworkMgr:runWhenOnline(go) -- older KOReader without runWhenConnected
    end
end

function Glimpse:_runUpdateCheck(Trapper)
    local pre = G_reader_settings:isTrue(PRERELEASE_KEY)
    local api = "https://api.github.com/repos/" .. self.github_repo
        .. (pre and "/releases?per_page=10" or "/releases/latest")
    -- fetch in a subprocess so the UI stays responsive and dismissable. Retry
    -- once after a short pause on failure: right after Wi-Fi associates, DNS
    -- (resolv.conf) can lag a second or two, so the first resolve fails; the
    -- pause happens in the subprocess, so the UI never blocks.
    local completed, body = Trapper:dismissableRunInSubprocess(function()
        local b, err = _http_fetch(api)
        if not b then
            require("socket").sleep(1.5)
            b, err = _http_fetch(api)
        end
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
-- Is any gesture in the current context bound to open Glimpse? Used to
-- gate the one-time "bind a gesture" nudge (no point nagging someone who
-- already has one).
-- Gestures the user has bound to open Glimpse. The gesture is a global
-- (reader) binding, but self.ui.gestures.gestures is only the CURRENT context's
-- table — "gesture_fm" when no book is open, which never holds glimpse_show, so
-- reading it there wrongly reports no gesture. The plugin's persisted data
-- (self.ui.gestures.data) carries both the "gesture_reader" and "gesture_fm"
-- sections in either context, so scan those directly for a book-independent
-- answer. Returns a de-duplicated list of gesture names.
function Glimpse:_glimpseGestures()
    local g = self.ui and self.ui.gestures
    local data = g and g.data
    local seen, found = {}, {}
    if type(data) == "table" then
        for _, section in ipairs({ "gesture_reader", "gesture_fm" }) do
            local tbl = data[section]
            if type(tbl) == "table" then
                for ges, actions in pairs(tbl) do
                    if type(actions) == "table" and actions.glimpse_show
                            and not seen[ges] then
                        seen[ges] = true
                        found[#found + 1] = ges
                    end
                end
            end
        end
    elseif g and type(g.gestures) == "table" then
        -- fallback if the data table isn't exposed for some reason
        for ges, actions in pairs(g.gestures) do
            if type(actions) == "table" and actions.glimpse_show
                    and not seen[ges] then
                seen[ges] = true
                found[#found + 1] = ges
            end
        end
    end
    return found
end

function Glimpse:_hasGesture()
    return #self:_glimpseGestures() > 0
end

function Glimpse:_gestureLabel()
    local found = self:_glimpseGestures()
    if #found == 0 then return _("Gesture to open: none set") end
    table.sort(found)
    for i, ges in ipairs(found) do
        found[i] = ges:gsub("_", " "):gsub("^%l", string.upper)
    end
    return T(_("Gesture to open: %1"), table.concat(found, ", "))
end

-- Layout chooser (Settings → Layout, and the ⋯ Quick Action): pick which
-- screen edge the drawer opens on. Applying reopens the drawer on the chosen
-- side when it's currently open; from the plugin menu it just saves for next time.
function Glimpse:_showLayoutDialog()
    local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
    local on_right = G_reader_settings:isTrue(LAYOUT_RIGHT_KEY)
    UIManager:show(RadioButtonWidget:new{
        title_text = _("Layout"),
        info_text = _("Which side of the screen should Glimpse open on?"),
        width_factor = 0.9,
        radio_buttons = {
            { { text = _("Left"),  provider = "left",  checked = not on_right } },
            { { text = _("Right"), provider = "right", checked = on_right } },
        },
        callback = function(w)
            local want_right = w.provider == "right"
            if want_right == on_right then return end
            -- store nil for the default (left) so it reads as unset
            G_reader_settings:saveSetting(LAYOUT_RIGHT_KEY, want_right or nil)
            -- Re-lay-out the open drawer IN PLACE on the new side rather than
            -- closing + reopening: update() reads the setting and rebuilds on
            -- the new edge, and the full-band refresh spans the combined old+new
            -- drawer region (the whole width on a side flip), so the old side is
            -- cleared and the new one drawn without the panel ever disappearing.
            if self._viewer then
                self._viewer._full_band_refresh = true
                self._viewer:update()
            end
        end,
    })
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
            -- master on/off: leaves the bound gesture in place but makes it
            -- (and Open Glimpse) inert, so the user can silence Glimpse
            -- without hunting through the gesture manager to unbind it
            text = _("Enable Glimpse"),
            help_text = _("Master switch. When off, the bound gesture and the Open Glimpse entry do nothing – a quick way to silence Glimpse without unbinding its gesture."),
            checked_func = function()
                return G_reader_settings:nilOrTrue(ENABLED_KEY)
            end,
            callback = function()
                G_reader_settings:flipNilOrTrue(ENABLED_KEY)
            end,
        },
        {
            -- which gesture opens Glimpse here — informational only (KOReader
            -- has no API to deep-link the gesture manager), so it's shown as a
            -- dimmed label; the how-to lives in its help text.
            text_func = function() return self:_gestureLabel() end,
            enabled_func = function() return false end,
            help_text = _("Assign or change it under Taps and gestures → Gesture manager → (pick a gesture) → Reader → 'Open Glimpse'."),
        },
        {
            text = _("Open Glimpse"),
            help_text = _("Browse the maps, family trees and other reference images found in this book, without losing your reading position. Tip: bind the gesture action 'Open Glimpse' for one-touch access."),
            -- greyed out with no book open (e.g. from the file manager), or
            -- when the master switch (Enable Glimpse) is off
            enabled_func = function()
                return self.ui and self.ui.document ~= nil
                    and G_reader_settings:nilOrTrue(ENABLED_KEY)
            end,
            callback = function(touchmenu_instance)
                if touchmenu_instance then
                    touchmenu_instance:closeMenu()
                end
                -- let the menu-close animation finish, or the page repaint
                -- lands on top of the viewer
                UIManager:scheduleIn(0.3, function()
                    self:showViewer()
                    -- first menu-open without a gesture bound: nudge once,
                    -- on top of the now-open drawer (gated on the viewer
                    -- actually opening, so unsupported/empty books don't tip)
                    if self._viewer and not self:_hasGesture()
                            and not G_reader_settings:isTrue(GESTURE_TIP_KEY) then
                        G_reader_settings:saveSetting(GESTURE_TIP_KEY, true)
                        UIManager:show(InfoMessage:new{
                            text = _("Tip: open Glimpse instantly with a gesture.\n\nSet one under Settings → Taps and gestures → Gesture manager → pick a gesture → Reader → 'Open Glimpse'.\n\n(This tip is shown only once.)"),
                        })
                    end
                end)
            end,
        },
        {
            -- the full option name, not an abbreviation, so the current
            -- mode is unambiguous at a glance
            text_func = function()
                return self:getScope() == "whole_book"
                    and _("Mode: Show all images")
                    or _("Mode: Show images up to current chapter")
            end,
            sub_item_table = {
                scope_item("read_so_far", _("Show images up to current chapter"),
                    _("Images that appear beyond your current position stay hidden, so you can't spoil yourself. Granularity is per chapter: images in the chapter you are currently reading are shown.")),
                scope_item("whole_book", _("Show all images"),
                    _("Show reference images from anywhere in the book, including parts you haven't reached yet.")),
            },
        },
        {
            -- sits directly under Mode: it also shapes what the Gallery holds.
            -- Renamed from "Include bookmarked pages"; also a Quick Action.
            text = _("Include Bookmarks in Gallery"),
            help_text = _("Also show the pages you've bookmarked (the dogear bookmark) in the Gallery, rendered as page thumbnails and marked with a bookmark badge, in reading order alongside the images – a quick way to keep a reference page a swipe away. Off by default. Also available from the viewer's ⋯ menu (see Quick Actions)."),
            checked_func = function()
                return G_reader_settings:isTrue(BOOKMARKS_KEY)
            end,
            callback = function()
                G_reader_settings:saveSetting(BOOKMARKS_KEY,
                    not G_reader_settings:isTrue(BOOKMARKS_KEY))
            end,
            separator = true,
        },
        {
            text = _("Quick Actions"),
            help_text = _("Choose which actions appear in the viewer's ⋯ menu. Reset Rotation is automatic (shown while an image is rotated)."),
            sub_item_table = (function()
                local t = {}
                for _, d in ipairs(QUICK_ACTIONS) do
                    local key = d.key
                    t[#t + 1] = {
                        text = _quick_label(key),
                        checked_func = function() return _quick_enabled(key) end,
                        keep_menu_open = true,
                        callback = function()
                            local cfg = G_reader_settings:readSetting(QUICK_ACTIONS_KEY)
                            if type(cfg) ~= "table" then cfg = {} end
                            cfg[key] = not _quick_enabled(key)
                            G_reader_settings:saveSetting(QUICK_ACTIONS_KEY, cfg)
                        end,
                    }
                end
                return t
            end)(),
            separator = true,
        },
        {
            text = _("Settings"),
            sub_item_table = {
                {
                    text = _("Gestures"),
                    sub_item_table = {
                        {
                            text = _("Double-tap for maximum zoom"),
                            help_text = _("Double-tap the image to jump to the maximum zoom (centered on the tap), and again to return to the fitted view. On by default."),
                            checked_func = function()
                                return G_reader_settings:nilOrTrue(GESTURE_DOUBLETAP_KEY)
                            end,
                            callback = function()
                                G_reader_settings:flipNilOrTrue(GESTURE_DOUBLETAP_KEY)
                            end,
                        },
                        {
                            text = _("Swipe left/right to navigate"),
                            help_text = _("Swipe left or right across the image to move to the next or previous image. On by default. (The Gallery's swipe-to-page is unaffected.)"),
                            checked_func = function()
                                return G_reader_settings:nilOrTrue(GESTURE_SWIPE_KEY)
                            end,
                            callback = function()
                                G_reader_settings:flipNilOrTrue(GESTURE_SWIPE_KEY)
                            end,
                        },
                        {
                            text = _("Pinch to zoom in/out"),
                            help_text = _("Pinch or spread two fingers on the image to zoom out or in. On by default."),
                            checked_func = function()
                                return G_reader_settings:nilOrTrue(GESTURE_PINCH_KEY)
                            end,
                            callback = function()
                                G_reader_settings:flipNilOrTrue(GESTURE_PINCH_KEY)
                            end,
                        },
                    },
                    separator = true,
                },
                {
                    text_func = function()
                        return T(_("Layout: %1"),
                            G_reader_settings:isTrue(LAYOUT_RIGHT_KEY)
                                and _("Right") or _("Left"))
                    end,
                    help_text = _("Choose which side of the screen Glimpse opens on, left or right."),
                    keep_menu_open = true,
                    callback = function() self:_showLayoutDialog() end,
                },
                {
                    text = _("Show Nav Buttons"),
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
                    text = _("Show Zoom Controls"),
                    help_text = _("Show a vertical −/fit/+ control in the viewer for zooming in and out, as an alternative to double-tap and pinch. The middle button returns to the fitted view."),
                    checked_func = function()
                        return G_reader_settings:isTrue(ZOOMCTL_KEY)
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(ZOOMCTL_KEY,
                            not G_reader_settings:isTrue(ZOOMCTL_KEY))
                    end,
                },
                {
                    text = _("Invert Images in Night Mode"),
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
                    text = _("Show image captions"),
                    help_text = _("Show the image's caption from the book, overlaid in the viewer's top-left corner."),
                    checked_func = function()
                        return G_reader_settings:nilOrTrue(CAPTIONS_KEY)
                    end,
                    callback = function()
                        G_reader_settings:flipNilOrTrue(CAPTIONS_KEY)
                    end,
                },
                {
                    text_func = function()
                        return T(_("Maximum zoom: %1%"),
                            math.floor(_maxZoomMult() * 100 + 0.5))
                    end,
                    help_text = _("How far you can zoom in, as a percentage of the image's own resolution. Double-tap jumps to this level and pinch stops here. Higher reveals more on detailed maps, but past 100% it is upscaling, so very high can look soft."),
                    sub_item_table = (function()
                        local t = {}
                        for _idx, mult in ipairs(MAX_ZOOM_CHOICES) do
                            local pct = math.floor(mult * 100 + 0.5)
                            t[_idx] = {
                                text = (mult == DEFAULT_MAX_ZOOM)
                                    and T(_("%1% (recommended)"), pct)
                                    or T(_("%1%"), pct),
                                radio = true,
                                checked_func = function()
                                    return _maxZoomMult() == mult
                                end,
                                callback = function()
                                    G_reader_settings:saveSetting(MAX_ZOOM_KEY, mult)
                                end,
                            }
                        end
                        return t
                    end)(),
                },
                {
                    text = _("Enable top menu tap zone"),
                    help_text = _("While the viewer is open, a tap along the top edge of the screen opens KOReader's top menu (only the top menu, never the bottom one) over the drawer, instead of doing nothing. Turn off to keep the top edge inert."),
                    checked_func = function()
                        return G_reader_settings:nilOrTrue(TOP_MENU_KEY)
                    end,
                    callback = function()
                        G_reader_settings:flipNilOrTrue(TOP_MENU_KEY)
                    end,
                },
            },
        },
        {
            text = _("Advanced"),
            sub_item_table = {
                {
                    -- inverted sense: checked = filtering OFF (default unchecked,
                    -- i.e. filtering ON). Flips the same balanced/all setting.
                    text = _("Disable irrelevant image filtering"),
                    help_text = _("By default Glimpse sets aside covers, publisher logos, ornaments and other non-reference imagery, keeping maps, family trees, diagrams and illustrations. Enable this to switch that off and see every image in the book. (Individual wrongly-kept images can instead be ignored from the viewer's ⋯ menu; wrongly set-aside ones added back from the Gallery's Ignored tab.)"),
                    checked_func = function()
                        return self:getFilterLevel() == "all"
                    end,
                    callback = function()
                        local disabled_now = self:getFilterLevel() == "all"
                        G_reader_settings:saveSetting(FILTER_KEY,
                            disabled_now and "balanced" or "all")
                    end,
                },
                {
                    text = _("Suppress \"format not supported\" notice"),
                    help_text = _("Silence the message shown when Glimpse is opened on a book format it doesn't support (PDF, comics, manga…). Handy if a reading gesture sometimes triggers Glimpse on non-EPUB files. Off by default."),
                    checked_func = function()
                        return G_reader_settings:isTrue(SUPPRESS_UNSUPPORTED_KEY)
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(SUPPRESS_UNSUPPORTED_KEY,
                            not G_reader_settings:isTrue(SUPPRESS_UNSUPPORTED_KEY))
                    end,
                },
                {
                    text = _("Disable shadows"),
                    help_text = _("Remove the drawer's drop shadow. The shadow is a dithered gradient – the main cause of e-ink ghosting behind the drawer – so turn it off if a ghost lingers after closing Glimpse. No visible effect on LCD screens."),
                    checked_func = function()
                        return G_reader_settings:isTrue(SHADOW_KEY)
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(SHADOW_KEY,
                            not G_reader_settings:isTrue(SHADOW_KEY))
                    end,
                },
                {
                    text = _("Fast image switching"),
                    help_text = _("Switch between images with a quick, flashless refresh instead of a full clear. On by default: faster and no flash. Turn it off if the previous image ghosts through the next one – most noticeable on detailed maps and on slower e-ink panels. No visible effect on LCD screens."),
                    checked_func = function()
                        return G_reader_settings:nilOrTrue(FAST_SWITCH_KEY)
                    end,
                    callback = function()
                        G_reader_settings:flipNilOrTrue(FAST_SWITCH_KEY)
                    end,
                    separator = true,
                },
                {
                    text = _("Rescan this book"),
                    help_text = _("Glimpse caches its scan of the book. Use this if the book file was replaced or images seem out of date."),
                    keep_menu_open = true,
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
                    help_text = _("Also offer releases marked as pre-release on GitHub – test builds published before a proper release. Normal update checks never see those."),
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
