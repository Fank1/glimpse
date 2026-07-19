#!/usr/bin/env lua
-- Glimpse triage tool: explain, for every image in an EPUB, what the
-- scanner saw and why each filter level keeps or rejects it.
--
-- Usage: lua analyze_epub.lua <extracted-epub-root>
-- (normally invoked via analyze_epub.sh, which handles the unzipping)

local HERE = (arg[0] or "analyze_epub.lua"):match("^(.*)/[^/]*$") or "."
local scanner = dofile(HERE .. "/../plugin/glimpse_scanner.lua")

local root = arg[1]
if not root then
    io.stderr:write("usage: analyze_epub.lua <extracted-epub-root>\n")
    os.exit(2)
end

local function read_file(path)
    local f = io.open(root .. "/" .. path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

local scan, err = scanner.scan(read_file)
if not scan then
    io.stderr:write("scan failed: " .. tostring(err) .. "\n")
    os.exit(1)
end

local LEVELS = { "strict", "balanced", "relaxed" }
local reasons = {}
local counts = {}
for _, lv in ipairs(LEVELS) do
    local inc, stats = scanner.filter(scan.images, lv)
    reasons[lv] = stats.reasons
    counts[lv] = #inc
end

print(string.format("%d spine documents, %d distinct images "
    .. "(kept: strict %d / balanced %d / relaxed %d)",
    scan.spine_count, #scan.images,
    counts.strict, counts.balanced, counts.relaxed))
print(string.rep("-", 100))

local function short(s, n)
    if not s then return "-" end
    s = s:gsub("%s+", " ")
    if #s > n then return s:sub(1, n - 1) .. "…" end
    return s
end

for _, im in ipairs(scan.images) do
    local dims = (im.width and im.height)
        and string.format("%dx%d", im.width, im.height) or "?x?"
    local attr = (im.attr_width and im.attr_height)
        and string.format(" attr=%dx%d", im.attr_width, im.attr_height) or ""
    local kb = im.bytes and string.format("%dkB", math.floor(im.bytes / 1024)) or "?kB"
    local flags = {}
    if im.is_cover then flags[#flags + 1] = "COVER" end
    if im.in_figure then flags[#flags + 1] = "figure" end
    if im.is_svg_doc then flags[#flags + 1] = "svg-doc" end
    if im.files_count > 1 then
        flags[#flags + 1] = "in " .. im.files_count .. " files"
    end
    print(string.format("spine %2d  %-9s %-6s %8s%s  %s",
        im.spine_index, dims, im.format or "?", kb, attr,
        im.path:match("[^/]+$") or im.path))
    print(string.format("          caption: %-50s %s",
        short(im.caption, 50),
        #flags > 0 and ("[" .. table.concat(flags, ", ") .. "]") or ""))
    local v = {}
    for _, lv in ipairs(LEVELS) do
        local r = reasons[lv][im.path]
        v[#v + 1] = string.format("%s=%s", lv, r == "keep" and "KEEP" or r)
    end
    print("          " .. table.concat(v, "  "))
end
