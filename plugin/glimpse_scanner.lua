-- Glimpse scanner: finds reference-worthy images inside an EPUB.
--
-- Pure Lua (5.1/LuaJIT compatible), no KOReader requires — the caller
-- injects `read_file(archive_path) -> string|nil`, so this module can be
-- unit-tested headlessly against an extracted EPUB (see builder/).
--
-- Pipeline:
--   M.scan(read_file)          -> { images = {...}, spine_count, opf_path }
--   M.filter(images, level)    -> included_list, stats
--
-- Each image record:
--   path         archive path (URL-decoded, normalized)
--   spine_index  1-based index of the FIRST spine document referencing it
--   order        running number of first appearance (stable sort key)
--   files_count  number of distinct spine documents referencing it
--   total_count  total number of <img>/<image> occurrences
--   width/height pixel dimensions parsed from the file header (may be nil)
--   format       "png"|"jpeg"|"gif"|"webp"|"bmp"|"svg"|nil
--   bytes        file size in the archive
--   caption      best human caption (figcaption > title attr > alt) or nil
--   alt, title_attr, classes, in_figure, attr_width, attr_height
--   is_cover     flagged as the book cover by the OPF
--   is_svg_doc   the image IS a whole SVG spine document

local M = {}

-- Bump when scan output format or discovery logic changes, so cached scans
-- (stored in Glimpse's sidecar) are invalidated on plugin upgrade.
M.VERSION = 5

-- ── small string helpers ────────────────────────────────────────────────────

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function collapse_ws(s)
    return (s:gsub("%s+", " "))
end

local function url_decode(s)
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function xml_unescape(s)
    s = s:gsub("&#x(%x+);", function(h)
        local n = tonumber(h, 16)
        return (n and n < 128) and string.char(n) or ""
    end)
    s = s:gsub("&#(%d+);", function(d)
        local n = tonumber(d)
        return (n and n < 128) and string.char(n) or ""
    end)
    s = s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    s = s:gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&nbsp;", " ")
    return s
end

-- Join `href` onto the directory of `base` ("" for archive root) and resolve
-- "." / ".." segments. Returns a normalized archive path (no leading "/").
local function resolve_path(base_dir, href)
    local path = href
    if not path:match("^/") and base_dir ~= "" then
        path = base_dir .. "/" .. path
    end
    path = path:gsub("^/+", "")
    local parts = {}
    for seg in path:gmatch("[^/]+") do
        if seg == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return table.concat(parts, "/")
end

local function dir_of(path)
    return path:match("^(.*)/[^/]*$") or ""
end

-- Case-insensitive attribute extraction from a single tag string.
-- Handles double-quoted, single-quoted and unquoted values.
local function attr(tag, name)
    local pat = {}
    for c in name:gmatch(".") do
        if c:match("%a") then
            pat[#pat + 1] = "[" .. c:lower() .. c:upper() .. "]"
        else
            pat[#pat + 1] = c:gsub("(%W)", "%%%1")
        end
    end
    local n = table.concat(pat)
    local v = tag:match(n .. '%s*=%s*"([^"]*)"')
          or tag:match(n .. "%s*=%s*'([^']*)'")
          or tag:match(n .. "%s*=%s*([^%s>\"']+)")
    if v then return xml_unescape(v) end
end

-- Parse an attribute value as a pixel count ("300", "300px"); nil otherwise.
local function px(v)
    if not v then return nil end
    local n = v:match("^%s*(%d+%.?%d*)%s*[pP]?[xX]?%s*$")
    n = n and tonumber(n)
    if n and n > 0 then return math.floor(n + 0.5) end
end

-- ── binary readers ──────────────────────────────────────────────────────────

local function be16(s, i)
    local a, b = s:byte(i, i + 1)
    if not b then return nil end
    return a * 256 + b
end

local function le16(s, i)
    local a, b = s:byte(i, i + 1)
    if not b then return nil end
    return b * 256 + a
end

local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function le24(s, i)
    local a, b, c = s:byte(i, i + 2)
    if not c then return nil end
    return (c * 256 + b) * 256 + a
end

local function le32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return nil end
    return ((d * 256 + c) * 256 + b) * 256 + a
end

-- ── image dimension sniffing ────────────────────────────────────────────────

local function dims_png(d)
    if #d < 24 or d:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil end
    if d:sub(13, 16) ~= "IHDR" then return nil end
    return be32(d, 17), be32(d, 21)
end

local function dims_gif(d)
    if #d < 10 or (d:sub(1, 6) ~= "GIF87a" and d:sub(1, 6) ~= "GIF89a") then
        return nil
    end
    return le16(d, 7), le16(d, 9)
end

local function dims_jpeg(d)
    if #d < 4 or d:byte(1) ~= 0xFF or d:byte(2) ~= 0xD8 then return nil end
    local i = 3
    while i + 3 <= #d do
        if d:byte(i) ~= 0xFF then return nil end
        -- skip fill bytes
        while d:byte(i + 1) == 0xFF and i + 1 < #d do i = i + 1 end
        local marker = d:byte(i + 1)
        if not marker then return nil end
        if marker == 0xD8 or marker == 0x01
           or (marker >= 0xD0 and marker <= 0xD7) then
            i = i + 2 -- standalone marker, no length
        elseif marker == 0xD9 or marker == 0xDA then
            return nil -- EOI / start of scan without SOF: give up
        else
            local len = be16(d, i + 2)
            if not len or len < 2 then return nil end
            -- SOF0..SOF15 except DHT(C4), JPG(C8), DAC(CC)
            if marker >= 0xC0 and marker <= 0xCF
               and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                local h, w = be16(d, i + 5), be16(d, i + 7)
                if w and h then return w, h end
                return nil
            end
            i = i + 2 + len
        end
    end
    return nil
end

local function dims_webp(d)
    if #d < 30 or d:sub(1, 4) ~= "RIFF" or d:sub(9, 12) ~= "WEBP" then
        return nil
    end
    local fourcc = d:sub(13, 16)
    if fourcc == "VP8X" then
        local w, h = le24(d, 25), le24(d, 28)
        if w and h then return w + 1, h + 1 end
    elseif fourcc == "VP8 " then
        if d:byte(24) == 0x9D and d:byte(25) == 0x01 and d:byte(26) == 0x2A then
            local w, h = le16(d, 27), le16(d, 29)
            if w and h then return w % 16384, h % 16384 end
        end
    elseif fourcc == "VP8L" then
        if d:byte(21) == 0x2F then
            local b0, b1, b2, b3 = d:byte(22, 25)
            if b3 then
                local w = b0 + (b1 % 64) * 256 + 1
                local h = math.floor(b1 / 64) + b2 * 4 + (b3 % 16) * 1024 + 1
                return w, h
            end
        end
    end
    return nil
end

local function dims_bmp(d)
    if #d < 26 or d:sub(1, 2) ~= "BM" then return nil end
    local w, h = le32(d, 19), le32(d, 23)
    if w and h and w > 0 then return w, math.abs(h) end
end

local function svg_len(v)
    if not v then return nil end
    local n, unit = v:match("^%s*(%d+%.?%d*)%s*(%a*)%s*$")
    n = n and tonumber(n)
    if not n or n <= 0 then return nil end
    if unit == "" or unit == "px" then return math.floor(n + 0.5) end
    if unit == "pt" then return math.floor(n * 96 / 72 + 0.5) end
    if unit == "in" then return math.floor(n * 96 + 0.5) end
    if unit == "cm" then return math.floor(n * 96 / 2.54 + 0.5) end
    if unit == "mm" then return math.floor(n * 9.6 / 2.54 + 0.5) end
    return nil -- %, em, ... : not a pixel size
end

local function dims_svg(d)
    local head = d:sub(1, 4096)
    local lower = head:lower()
    local s = lower:find("<svg")
    if not s then return nil end
    local e = lower:find(">", s, true)
    local tag = head:sub(s, e or #head)
    local w = svg_len(attr(tag, "width"))
    local h = svg_len(attr(tag, "height"))
    if w and h then return w, h end
    local vb = attr(tag, "viewBox") or attr(tag, "viewbox")
    if vb then
        local _, _, vw, vh = vb:match("([%d%.%-]+)[%s,]+([%d%.%-]+)[%s,]+([%d%.%-]+)[%s,]+([%d%.%-]+)")
        vw, vh = tonumber(vw), tonumber(vh)
        if vw and vh and vw > 0 and vh > 0 then
            return math.floor(vw + 0.5), math.floor(vh + 0.5)
        end
    end
    return nil
end

-- Returns width, height, format — any of which may be nil.
function M.get_image_dimensions(data)
    if type(data) ~= "string" or #data == 0 then return nil, nil, nil end
    local w, h
    w, h = dims_png(data)  if w then return w, h, "png" end
    w, h = dims_jpeg(data) if w then return w, h, "jpeg" end
    w, h = dims_gif(data)  if w then return w, h, "gif" end
    w, h = dims_webp(data) if w then return w, h, "webp" end
    w, h = dims_bmp(data)  if w then return w, h, "bmp" end
    w, h = dims_svg(data)
    if data:sub(1, 512):lower():find("<svg") or (w and h) then
        return w, h, "svg"
    end
    return nil, nil, nil
end

-- ── EPUB container / OPF parsing ────────────────────────────────────────────

-- Some producers namespace-prefix every element (<opf:item>, <opf:spine>).
-- Strip element-name prefixes so the tag patterns below match either form.
local function strip_ns(xml)
    return (xml:gsub("<(%/?)[%w_%-]+:", "<%1"))
end

function M.parse_container(xml)
    if not xml then return nil end
    xml = strip_ns(xml)
    -- first <rootfile ... full-path="..."> wins
    for tag in xml:gmatch("<[rR][oO][oO][tT][fF][iI][lL][eE][^>]*>") do
        local p = attr(tag, "full-path")
        if p and p ~= "" then return resolve_path("", p) end
    end
    return nil
end

-- Returns { spine = { {path=..., media=...}, ... }, cover_path = ... }
function M.parse_opf(xml, opf_dir)
    xml = strip_ns(xml)
    local items = {} -- id -> { href, media, properties }
    for tag in xml:gmatch("<[iI][tT][eE][mM][%s/][^>]*>") do
        local id = attr(tag, "id")
        local href = attr(tag, "href")
        if id and href then
            items[id] = {
                href = href,
                media = (attr(tag, "media-type") or ""):lower(),
                properties = (attr(tag, "properties") or ""):lower(),
            }
        end
    end

    local cover_path
    -- EPUB3: manifest item with properties="cover-image"
    for _, it in pairs(items) do
        if it.properties:find("cover%-image") then
            cover_path = resolve_path(opf_dir, url_decode(it.href))
            break
        end
    end
    -- EPUB2: <meta name="cover" content="item-id"/>
    if not cover_path then
        for tag in xml:gmatch("<[mM][eE][tT][aA][%s/][^>]*>") do
            local name = attr(tag, "name")
            if name and name:lower() == "cover" then
                local it = items[attr(tag, "content") or ""]
                if it then
                    cover_path = resolve_path(opf_dir, url_decode(it.href))
                end
                break
            end
        end
    end

    local spine = {}
    local spine_block = xml:match("<[sS][pP][iI][nN][eE][%s>].-</[sS][pP][iI][nN][eE]%s*>")
                     or xml
    for tag in spine_block:gmatch("<[iI][tT][eE][mM][rR][eE][fF][%s/][^>]*>") do
        local it = items[attr(tag, "idref") or ""]
        if it then
            spine[#spine + 1] = {
                path = resolve_path(opf_dir, url_decode(it.href)),
                raw_path = resolve_path(opf_dir, it.href),
                media = it.media,
            }
        end
    end

    -- EPUB2 guide: declared roles per document ("this file IS the title
    -- page"), the most reliable chrome signal there is
    local guide = {}
    local guide_block = xml:match("<[gG][uU][iI][dD][eE][%s>].-</[gG][uU][iI][dD][eE]%s*>")
    if guide_block then
        for tag in guide_block:gmatch("<[rR][eE][fF][eE][rR][eE][nN][cC][eE][%s/][^>]*>") do
            local href = attr(tag, "href")
            local rtype = attr(tag, "type")
            if href and rtype then
                local p = resolve_path(opf_dir,
                    url_decode((href:gsub("#.*$", ""):gsub("%?.*$", ""))))
                guide[p] = rtype:lower()
            end
        end
    end

    return { spine = spine, cover_path = cover_path, guide = guide }
end

-- ── image extraction from one (X)HTML document ─────────────────────────────

local function is_html_media(media, path)
    if media:find("html") or media:find("xml%+xhtml") then return true end
    return path:lower():match("%.x?html?$") ~= nil
end

local function is_svg_media(media, path)
    return media:find("svg") ~= nil or path:lower():match("%.svg$") ~= nil
end

-- Find <figure>...</figure> spans and their captions.
local function find_figures(lower, html)
    local figures = {}
    local init = 1
    while true do
        local s = lower:find("<figure%f[%W]", init)
        if not s then break end
        local e = lower:find("</figure%s*>", s)
        if not e then break end
        local block_l = lower:sub(s, e)
        local caption
        local cs, _, p1 = block_l:find("<figcaption[^>]*>()")
        if cs then
            local p2 = block_l:find("</figcaption", p1)
            if p2 then
                local raw = html:sub(s + p1 - 1, s + p2 - 2)
                caption = trim(collapse_ws(xml_unescape(raw:gsub("<[^>]->", " "))))
                if caption == "" then caption = nil end
            end
        end
        figures[#figures + 1] = { s = s, e = e, caption = caption }
        init = e + 1
    end
    return figures
end

-- An alt/title only counts as a caption if it looks like prose, not like a
-- filename or generator boilerplate.
function M.meaningful_text(s)
    if type(s) ~= "string" then return nil end
    s = trim(collapse_ws(s))
    if #s < 4 then return nil end
    local l = s:lower():gsub("^%p+", ""):gsub("%p+$", "") -- "[Image]" -> "image"
    if l:match("^%S+%.%w%w%w?%w?$") then return nil end        -- "map01.png"
    if l:match("^images?%s*%d*$") or l:match("^img[%s_%-%d]*$") then return nil end
    if l:match("^photos?%s*%d*$") or l:match("^pictures?%s*%d*$") then return nil end
    if l:match("^picture%s*%d*$") or l:match("^illustration%s*%d*$") then return nil end
    if l:match("^cover") then return nil end
    if l:match("^%d+$") then return nil end
    return s
end

-- Chapter/part-opener art routinely carries the section heading as its alt
-- text ("Chapter 1 Choose the Good", "Prologue"), and title-page art an alt
-- describing the title page ("Book Title, Educated, Subtitle, ..."). Such a
-- caption marks the image as DECORATIVE — it must not earn caption relief.
function M.decorative_caption(s)
    if type(s) ~= "string" then return false end
    local l = trim(collapse_ws(s)):lower()
    l = l:gsub("\226\128\153", "'") -- U+2019 curly apostrophe ("Author’s")
    -- "Creation Lake: A Novel, by Rachel Kushner. Scribner." — alt text
    -- describing the title page ("novel" as a whole word, so "novelist"
    -- in a genuine caption doesn't trigger it)
    if l:match("%f[%a]novel%f[%A]") and l:find(" by ", 1, true) then
        return true
    end
    -- publisher chrome described in alt text ("Penguin Random House Back
    -- Ad logo", "reactor magazine advertisement")
    if l:match("%f[%a]logo%f[%A]") or l:find("back ad", 1, true)
       or l:match("%f[%a]advertisement%f[%A]") or l:match("%f[%a]advert%f[%A]") then
        return true
    end
    -- caption that BEGINS with a publishing-house name ("Penguin Books",
    -- "Penguin Random House UK") — only unambiguous names, start-anchored
    for _, pub in ipairs({
        "penguin", "random house", "harpercollins", "harper collins",
        "macmillan", "hachette", "simon & schuster", "simon and schuster",
        "bloomsbury", "scholastic", "knopf", "doubleday", "scribner",
        "picador", "tor books", "tor publishing", "del rey", "st%. martin",
        "little, brown", "houghton", "w%. w%. norton", "faber", "berkley",
        "bantam", "ballantine", "redhook", "red tower", "grand central",
        "gallery books", "atria", "riverhead", "putnam", "dutton",
        "sourcebooks", "entangled publishing",
    }) do
        if l:match("^" .. pub .. "%f[%W]") then return true end
    end
    return (l:match("^chapter%f[%W]") or l:match("^part%f[%W]")
        or l:match("^book%s+%w+$") or l:match("^a note%f[%W]")
        or l:match("^prologue") or l:match("^epilogue") or l:match("^interlude")
        or l:match("^introduction") or l:match("^foreword") or l:match("^preface")
        or l:match("^afterword") or l:match("^appendix") or l:match("^acknowledg")
        or l:match("^contents") or l:match("^table of contents")
        or l:match("^dedication") or l:match("^epigraph")
        or l:match("^author.?s note")
        or l:match("^book title") or l:match("^title page")
        or l:match("^half.?title") or l:match("^also by%f[%W]")
        or l:match("^by the same author")) and true or false
end

-- Uncaptioned images whose filename betrays chrome (author photo, publisher
-- logo, title page art, back-of-book ads). Also applied to the CONTAINING
-- spine document's filename. The two-and-three-letter tokens (tp, cvi, cop,
-- adc, ata) are the big publishers' production names for title page, cover
-- image, copyright, ad card and about-the-author (e.g. Penguin Random
-- House's King_..._epub_tp_r1.jpg); they only match as whole tokens.
function M.decorative_name(path)
    local base = (path:match("[^/]+$") or path):lower()
    return (base:match("%f[%a]author%f[%A]") or base:match("%f[%a]logo%f[%A]")
        or base:match("%f[%a]publisher") or base:match("%f[%a]colophon")
        or base:match("%f[%a]copyright") or base:match("half.?title")
        or base:match("title.?page") or base:match("%f[%a]title%d*%.%w+$")
        or base:match("%f[%a]backad") or base:match("%f[%a]newsletter")
        or base:match("%f[%a]signup") or base:match("%f[%a]endpaper")
        or base:match("%f[%a]tp%f[%A]") or base:match("%f[%a]cvi%f[%A]")
        or base:match("%f[%a]cop%f[%A]") or base:match("%f[%a]adc%f[%A]")
        or base:match("%f[%a]ata%f[%A]")) and true or false
end

-- Publisher figure-naming conventions (f0156-01.jpg = figure at print page
-- 156; fig12.png) mark genuine figures: a positive signal worth the same
-- relief as a caption.
function M.figure_name(path)
    local base = (path:match("[^/]+$") or path):lower()
    return (base:match("^f%d+%-%d+%.") or base:match("^f%d+[a-z]?%.")
        or base:match("^fig%d") or base:match("^figure")
        or base:match("%f[%a]fig%d+%f[%A]")) and true or false
end

-- A filename that names genuine reference content — a map, family tree,
-- diagram, chart, timeline, floor plan. Like figure_name, a POSITIVE signal:
-- it earns caption relief (halved size thresholds, ratio slack, and survives
-- the no-dimensions case) AND exempts the image from the front-matter portrait
-- cut, so an endpaper map in the first spine file (fantasy/history books ship
-- maps there) or a family tree a hair under the size floor is kept instead of
-- mistaken for a title page. Whole-token matches only, so "champion",
-- "planet", "streetlight" and the like don't trip it. Tiny decorative glyphs
-- that happen to match (a 45px "palm-tree" emoji) are still caught by the
-- series/size rules — this only lifts the thresholds, it never force-keeps.
function M.reference_name(path)
    local base = (path:match("[^/]+$") or path):lower()
    return (base:match("%f[%a]maps?%f[%A]")
        or base:match("family.?tree") or base:match("%f[%a]familytree")
        or base:match("%f[%a]genealog") or base:match("%f[%a]pedigree")
        or base:match("%f[%a]cladogram") or base:match("%f[%a]phylogen")
        or base:match("%f[%a]tree%f[%A]") or base:match("%f[%a]diagram")
        or base:match("%f[%a]charts?%f[%A]") or base:match("%f[%a]timeline")
        or base:match("%f[%a]schematic") or base:match("floor.?plan")
        or base:match("%f[%a]blueprint")) and true or false
end

-- A caption too weak to shield a chrome-NAMED file (titlepage.jpg,
-- *logo*, endpaper.jpg ...): decorative text, or the "<Title> by <Author>"
-- alt that publishers put on title-page art ("Hell Bent by Leigh Bardugo").
-- The by-author pattern alone is NOT decorative — a genuine caption like
-- "Painting of the valley by John Constable" must survive on a normally
-- named file — it only fails to rescue a file already flagged by name.
function M.weak_caption(s)
    if type(s) ~= "string" then return true end
    if M.decorative_caption(s) then return true end
    local l = trim(collapse_ws(s)):lower()
    local words = 0
    for _ in l:gmatch("%S+") do words = words + 1 end
    return words <= 8 and l:match("%s+by%s+%a") ~= nil
end

-- OPF <guide> reference types (EPUB2) and epub:type document semantics
-- (EPUB3) that declare a spine document to be publisher chrome. Deliberately
-- NOT included: "text"/"start"/"bodymatter" boundaries — genuine maps and
-- family trees often live in the front matter, so position alone is not
-- treated as chrome.
local CHROME_ROLES = {
    ["cover"] = true, ["title-page"] = true, ["titlepage"] = true,
    ["half-title-page"] = true, ["halftitlepage"] = true,
    ["copyright-page"] = true, ["copyright"] = true, ["imprint"] = true,
    ["colophon"] = true, ["dedication"] = true, ["epigraph"] = true,
    ["acknowledgements"] = true, ["acknowledgments"] = true,
    ["toc"] = true, ["index"] = true,
}

function M.chrome_role(role)
    return role ~= nil and CHROME_ROLES[role] or false
end

-- Sniff an epub:type document semantic out of a content document.
function M.epub_type_role(html)
    local head = html:sub(1, 8192):lower()
    for v in head:gmatch("epub:type%s*=%s*[\"']([^\"']*)[\"']") do
        for role in v:gmatch("[%w%-]+") do
            if CHROME_ROLES[role] then return role end
        end
    end
    return nil
end

-- Returns a list of occurrences: { src, alt, title, class, attr_w, attr_h,
-- figcaption, in_figure }
-- Void elements never hold children, so they're not pushed onto the tag
-- stack when tracing element paths.
local VOID_TAGS = {
    img = true, image = true, br = true, hr = true, meta = true, link = true,
    input = true, area = true, base = true, col = true, embed = true,
    param = true, source = true, track = true, wbr = true,
}

-- Element path (a crengine xpath, relative to the fragment's <body>) for
-- every <img>/<image>, so "Show in Book" can jump to the exact image instead
-- of the chapter top. crengine indexes among SAME-TAG siblings (div[2] = 2nd
-- <div> child) and needs the full ancestor chain — there's no descendant
-- shortcut — so we walk the tags with a stack, counting per-tag siblings in
-- each parent. Keyed by the "<" offset into `html`, which matches the <img>
-- match offsets extract_images uses (same comment-stripped string; lowercase
-- doesn't shift byte offsets). Best-effort: crengine may normalize the DOM
-- (insert tbody, fix nesting), so a path can be off — the caller validates
-- each against the image's filename and falls back to the chapter if wrong.
local function element_path_map(html)
    local paths = {}
    local stack = {}       -- open elements: { tag=, index=, counts={} }
    local body_depth = nil -- stack position of the fragment <body>
    local n = #html
    local pos = 1
    while pos <= n do
        local s = html:find("<", pos, true)
        if not s then break end
        local c = html:sub(s + 1, s + 1)
        if c == "/" then
            local e = html:find(">", s + 1, true) or n
            local name = html:sub(s + 2, e - 1):match("^%s*([%w:_%-]+)")
            name = name and name:lower()
            if name then
                for i = #stack, 1, -1 do
                    if stack[i].tag == name then
                        for _ = i, #stack do table.remove(stack) end
                        if body_depth and body_depth > #stack then
                            body_depth = nil
                        end
                        break
                    end
                end
            end
            pos = e + 1
        elseif c:match("%a") then
            local e = html:find(">", s + 1, true) or n
            local tagtext = html:sub(s, e)
            local name = tagtext:match("^<%s*([%w:_%-]+)")
            name = name and name:lower()
            if name then
                local parent = stack[#stack]
                local index = 1
                if parent then
                    parent.counts[name] = (parent.counts[name] or 0) + 1
                    index = parent.counts[name]
                end
                if (name == "img" or name == "image") and body_depth then
                    local parts = {}
                    for i = body_depth + 1, #stack do
                        parts[#parts + 1] =
                            stack[i].tag .. "[" .. stack[i].index .. "]"
                    end
                    parts[#parts + 1] = name .. "[" .. index .. "]"
                    paths[s] = table.concat(parts, "/")
                end
                if not (VOID_TAGS[name] or tagtext:match("/%s*>$")) then
                    stack[#stack + 1] = { tag = name, index = index, counts = {} }
                    if name == "body" and not body_depth then
                        body_depth = #stack
                    end
                end
            end
            pos = e + 1
        else
            pos = s + 1
        end
    end
    return paths
end

function M.extract_images(html)
    -- strip comments so commented-out markup is invisible
    html = html:gsub("<!%-%-.-%-%->", "")
    local lower = html:lower()
    local figures = find_figures(lower, html)
    local paths = element_path_map(html)
    local out = {}

    local function fig_at(pos)
        for i = 1, #figures do
            local f = figures[i]
            if pos >= f.s and pos <= f.e then return f end
        end
    end

    local function add(tag, pos, src)
        if not src or src == "" then return end
        if src:match("^data:") or src:match("^%a+://") then return end
        local f = fig_at(pos)
        out[#out + 1] = {
            src = src,
            alt = attr(tag, "alt"),
            title = attr(tag, "title"),
            class = attr(tag, "class"),
            attr_w = px(attr(tag, "width")),
            attr_h = px(attr(tag, "height")),
            figcaption = f and f.caption or nil,
            in_figure = f ~= nil,
            node_path = paths[pos],
        }
    end

    local init = 1
    while true do
        local s = lower:find("<img%f[%W]", init)
        if not s then break end
        local e = lower:find(">", s, true) or #lower
        local tag = html:sub(s, e)
        add(tag, s, attr(tag, "src") or attr(tag, "srcset"))
        init = e + 1
    end

    init = 1
    while true do
        local s = lower:find("<image%f[%W]", init)
        if not s then break end
        local e = lower:find(">", s, true) or #lower
        local tag = html:sub(s, e)
        add(tag, s, attr(tag, "xlink:href") or attr(tag, "href"))
        init = e + 1
    end

    return out
end

-- ── full scan ───────────────────────────────────────────────────────────────

-- read_file(path) -> data|nil. `scan` tries the URL-decoded path first, then
-- the raw href spelling (zip entries occasionally contain literal %20).
function M.scan(read_file)
    local function read_any(a, b)
        local d = read_file(a)
        if d and #d > 0 then return d end
        if b and b ~= a then
            d = read_file(b)
            if d and #d > 0 then return d end
        end
        return nil
    end

    local container = read_file("META-INF/container.xml")
    if not container then
        return nil, "no_container"
    end
    local opf_path = M.parse_container(container)
    if not opf_path then
        return nil, "no_opf"
    end
    local opf = read_any(opf_path, url_decode(opf_path))
    if not opf then
        return nil, "no_opf"
    end
    local book = M.parse_opf(opf, dir_of(opf_path))

    local by_path = {}   -- decoded path -> record
    local list = {}
    local order = 0

    local function record(dec_path, raw_path, spine_index, occ)
        local rec = by_path[dec_path]
        if not rec then
            order = order + 1
            rec = {
                path = dec_path,
                raw_path = raw_path,
                spine_index = spine_index,
                -- first occurrence's DOM path, so it matches spine_index's
                -- document (nil for cover/SVG-doc synth records)
                node_path = occ and occ.node_path,
                order = order,
                files_count = 0,
                total_count = 0,
                _files = {},
            }
            by_path[dec_path] = rec
            list[#list + 1] = rec
        end
        rec.total_count = rec.total_count + 1
        if not rec._files[spine_index] then
            rec._files[spine_index] = true
            rec.files_count = rec.files_count + 1
        end
        if occ then
            -- first occurrence's metadata wins; later ones only fill gaps
            rec.alt = rec.alt or M.meaningful_text(occ.alt)
            rec.title_attr = rec.title_attr or M.meaningful_text(occ.title)
            rec.classes = rec.classes or occ.class
            rec.figcaption = rec.figcaption or occ.figcaption
            rec.in_figure = rec.in_figure or occ.in_figure or false
            if occ.attr_w and occ.attr_h and not rec.attr_width then
                rec.attr_width, rec.attr_height = occ.attr_w, occ.attr_h
            end
        end
    end

    for i, item in ipairs(book.spine) do
        if is_html_media(item.media, item.path) then
            local html = read_any(item.path, item.raw_path)
            if html then
                -- declared chrome role of this document: OPF guide (EPUB2)
                -- or epub:type semantics (EPUB3)
                local doc_role = book.guide and book.guide[item.path]
                if not M.chrome_role(doc_role) then
                    doc_role = M.epub_type_role(html)
                end
                local base = dir_of(item.path)
                for _, occ in ipairs(M.extract_images(html)) do
                    local href = occ.src:gsub("#.*$", ""):gsub("%?.*$", "")
                    local raw = resolve_path(base, href)
                    local dec = resolve_path(base, url_decode(href))
                    record(dec, raw, i, occ)
                    local rec = by_path[dec]
                    if not rec.doc_path then
                        rec.doc_path = item.path
                        rec.doc_role = doc_role
                    end
                end
            end
        elseif is_svg_media(item.media, item.path) then
            -- a whole SVG document in the spine (some books ship maps this way)
            local rec_path = item.path
            record(rec_path, item.raw_path, i, nil)
            by_path[rec_path].is_svg_doc = true
        end
    end

    -- cover referenced only from the OPF (never inside a spine document):
    -- synthesize an entry so "show all" can still surface it
    if book.cover_path and not by_path[book.cover_path] then
        order = order + 1
        local rec = {
            path = book.cover_path,
            raw_path = book.cover_path,
            spine_index = 0,
            order = order,
            files_count = 0,
            total_count = 0,
            _files = {},
        }
        by_path[book.cover_path] = rec
        list[#list + 1] = rec
    end

    -- read image bytes for dimensions; finalize records
    for _, rec in ipairs(list) do
        local data = read_any(rec.path, rec.raw_path)
        if data then
            rec.bytes = #data
            local w, h, fmt = M.get_image_dimensions(data)
            rec.width, rec.height, rec.format = w, h, fmt
        end
        if book.cover_path and rec.path == book.cover_path then
            rec.is_cover = true
        end
        rec.caption = rec.figcaption or rec.title_attr or rec.alt
        rec._files = nil
    end

    table.sort(list, function(a, b)
        if a.spine_index ~= b.spine_index then
            return a.spine_index < b.spine_index
        end
        return a.order < b.order
    end)

    return {
        version = M.VERSION,
        images = list,
        spine_count = #book.spine,
        opf_path = opf_path,
        cover_path = book.cover_path,
    }
end

-- ── filtering ───────────────────────────────────────────────────────────────

M.LEVELS = {
    strict   = { short = 350, long = 600, area = 250000, ratio = 3.0 },
    balanced = { short = 200, long = 350, area = 100000, ratio = 4.5 },
    relaxed  = { short = 120, long = 200, area = 40000,  ratio = 6.0 },
}
M.CAPTION_RELIEF = 0.5    -- captioned images get half-size thresholds
M.RATIO_RELIEF = 1.5      -- ...and 50% more aspect-ratio slack
M.MAX_SPINE_FILES = 2     -- referenced from more files = chapter ornament
M.MIN_SERIES = 4          -- ≥ this many images with identical dimensions =
                          -- a decorative series (chapter/part-opener art)
M.FRONTMATTER_SPINE = 3   -- spine positions treated as front matter
-- Illustrated / reference books (non-fiction, cookbooks, science, how-to) keep
-- many figures at the standard floor; their SMALLER diagrams and charts sit
-- just under it — content here, decoration in a novel. When a book already
-- keeps this many images at "balanced", it's treated as reference-rich and
-- UNCAPTIONED images get a size-floor relief (a genuine diagram carries its
-- labels baked into the pixels, so it has no HTML caption). Captioned images
-- are left exactly as they were: they already get the stronger caption relief,
-- and a SMALL captioned image is usually a decorative drop-cap or vignette
-- (auto-generated alt), which must stay out even in a reference-rich book.
M.REF_RICH_MIN = 8
M.REF_RELIEF = 0.75       -- uncaptioned size thresholds ×0.75 in a ref-rich book
M.REF_RATIO_RELIEF = 1.2  -- ...and 20% more aspect slack

-- Returns included_list, stats where stats = { total=, included=,
-- excluded = { cover=n, repeated=n, series=n, decorative=n, frontmatter=n,
--              small=n, aspect=n, nosize=n },
-- reasons = { [path] = "keep" | one of the excluded keys } }.
-- level: "strict" | "balanced" | "relaxed" | "all"
function M.filter(images, level)
    local function new_stats()
        return { total = #images, included = 0, reasons = {},
                 excluded = { cover = 0, repeated = 0, series = 0,
                              decorative = 0, frontmatter = 0, small = 0,
                              aspect = 0, nosize = 0 } }
    end
    if level == "all" then
        local out, stats = {}, new_stats()
        for _, img in ipairs(images) do
            out[#out + 1] = img
            stats.reasons[img.path] = "keep"
        end
        stats.included = #out
        return out, stats
    end

    -- Pre-pass: group by exact pixel dimensions. Publishers generate
    -- chapter/part-opener art as one unique file per chapter, all with
    -- identical dimensions — the per-file repetition heuristic misses them,
    -- the shared dimensions give them away. A group is decorative when any
    -- caption repeats within it (empty and heading-style captions all count
    -- as "no caption"); all-distinct real captions mean genuine figure
    -- plates and the group survives.
    local dim_groups = {}
    for _, img in ipairs(images) do
        if img.width and img.height then
            local k = img.width .. "x" .. img.height
            local g = dim_groups[k]
            if not g then
                g = { n = 0, caps = {} }
                dim_groups[k] = g
            end
            g.n = g.n + 1
            local c = ""
            if img.caption and not M.decorative_caption(img.caption) then
                c = trim(collapse_ws(img.caption)):lower()
                -- within a series, a numeral-prefixed caption ("I The Man
                -- in the Tree", "2. The Breach") is a numbered section
                -- opener, not a figure caption
                if c:match("^[ivxlcdm]+[%s%.:]") or c:match("^%d+[%s%.:]") then
                    c = ""
                end
            end
            if g.caps[c] then g.dup = true end
            g.caps[c] = (g.caps[c] or 0) + 1
        end
    end

    -- Classify every image against the level's size gate. `ref_rich` (set on
    -- the second pass for illustrated books) grants UNCAPTIONED images a size
    -- relief; captioned images are unaffected, so re-running only ever admits
    -- MORE uncaptioned size-borderline figures (never drops a prior keep).
    local t = M.LEVELS[level] or M.LEVELS.balanced
    local function classify(ref_rich)
    local stats = new_stats()
    local out = {}
    for _, img in ipairs(images) do
        local reason
        -- a section-heading alt ("Chapter 1 ...") marks decoration, so it
        -- earns no caption relief
        local decorative = M.decorative_caption(img.caption)
        local captioned = ((img.caption ~= nil or img.in_figure) and not decorative)
            or M.figure_name(img.path) or M.reference_name(img.path)
        if img.is_cover then
            reason = "cover"
        elseif img.files_count > M.MAX_SPINE_FILES then
            reason = "repeated"
        else
            if img.width and img.height then
                local g = dim_groups[img.width .. "x" .. img.height]
                if g and g.n >= M.MIN_SERIES and g.dup then
                    reason = "series"
                end
                -- uncaptioned, cover-shaped portrait art at the very start
                -- of the book: cover variants and title pages the OPF does
                -- not flag
                if not reason and not captioned
                   and img.spine_index <= M.FRONTMATTER_SPINE then
                    local r = img.width / img.height
                    if r >= 0.5 and r <= 0.9 then
                        reason = "frontmatter"
                    end
                end
            end
            -- section-heading/title-page alt text; telltale chrome
            -- filenames (of the image or its containing document); or a
            -- declared chrome role (OPF guide / epub:type). Chrome names
            -- are only overridden by a STRONG caption — "<Title> by
            -- <Author>" alt text or a publisher name does not rescue
            -- titlepage.jpg / *logo* / endpaper.jpg.
            if not reason then
                if decorative
                   or (M.weak_caption(img.caption)
                       and (M.decorative_name(img.path)
                            or (img.doc_path and M.decorative_name(img.doc_path))
                            or M.chrome_role(img.doc_role))) then
                    reason = "decorative"
                end
            end
            if not reason then
                -- effective displayed size: the smaller of file dims and any
                -- numeric width/height attributes (a big file squeezed into
                -- a 40px slot is decoration)
                local w, h = img.width, img.height
                if img.attr_width and img.attr_height then
                    if not (w and h) or img.attr_width * img.attr_height < w * h then
                        w, h = img.attr_width, img.attr_height
                    end
                end
                if not (w and h) then
                    if not (captioned and level ~= "strict") then
                        reason = "nosize"
                    end
                else
                    local long, short = math.max(w, h), math.min(w, h)
                    -- caption relief wins when present; otherwise a reference-
                    -- rich book grants uncaptioned figures a lighter relief
                    local relief, ratio_relief
                    if captioned then
                        relief, ratio_relief = M.CAPTION_RELIEF, M.RATIO_RELIEF
                    elseif ref_rich then
                        relief, ratio_relief = M.REF_RELIEF, M.REF_RATIO_RELIEF
                    else
                        relief, ratio_relief = 1, 1
                    end
                    local max_ratio = t.ratio * ratio_relief
                    if short > 0 and long / short > max_ratio then
                        reason = "aspect"
                    elseif short < t.short * relief
                        or long < t.long * relief
                        or w * h < t.area * relief * relief then
                        reason = "small"
                    end
                end
            end
        end
        if reason then
            stats.excluded[reason] = stats.excluded[reason] + 1
        else
            out[#out + 1] = img
        end
        stats.reasons[img.path] = reason or "keep"
    end
    stats.included = #out
    return out, stats
    end -- classify

    local out, stats = classify(false)
    -- Adaptive relaxation: a book that already keeps REF_RICH_MIN+ figures at
    -- the standard floor is an illustrated/reference book, so re-run granting
    -- uncaptioned figures the ref-rich size relief to also admit its smaller
    -- diagrams. Only for "balanced" (the default): "strict" is a deliberate
    -- tight choice, "relaxed"/"all" are already permissive. A pure novel keeps
    -- almost nothing here, so it never trips the gate and stays untouched.
    if level == "balanced" and stats.included >= M.REF_RICH_MIN then
        out, stats = classify(true)
        stats.reference_rich = true
    end
    return out, stats
end

return M
