#!/usr/bin/env python3
"""Generate the Glimpse regression fixture EPUB (stdlib only).

Writes builder/fixture.epub and an extracted copy at
builder/fixture_extracted/ (the Lua tests read the extracted tree, so they
need no zip library).

The book contains, deliberately:
  - a cover flagged both the EPUB2 and EPUB3 way (must be excluded)
  - a chapter-head ornament repeated in 3 chapters (repeated -> excluded)
  - a big map in a <figure> with <figcaption>            (included)
  - a family tree JPEG captioned via alt                 (included)
  - a tiny inline icon                                   (small -> excluded)
  - an extremely wide divider                            (aspect -> excluded)
  - a medium uncaptioned image (excluded at balanced, included at relaxed)
  - an image in a subdirectory with spaces, URL-encoded in the src
  - an SVG map referenced from an inline <image> element
  - a commented-out <img> that must NOT be counted
  - uncaptioned portrait title art at spine 2         (frontmatter -> excluded)
  - four unique chapter banners with identical dimensions and chapter-title
    alt text                                          (series -> excluded)
"""

import os
import shutil
import struct
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
EPUB = os.path.join(HERE, "fixture.epub")
EXTRACTED = os.path.join(HERE, "fixture_extracted")


def make_png(w, h, shade=128):
    def chunk(typ, data):
        c = typ + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
    raw = (b"\x00" + bytes([shade]) * w) * h
    idat = chunk(b"IDAT", zlib.compress(raw, 9))
    iend = chunk(b"IEND", b"")
    return sig + ihdr + idat + iend


def make_jpeg(w, h):
    """Header-valid JPEG: SOI, APP0 (JFIF), SOF0 with dimensions, EOI.
    Not decodable, but dimension parsing only walks the headers."""
    soi = b"\xff\xd8"
    jfif = b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    app0 = b"\xff\xe0" + struct.pack(">H", 2 + len(jfif)) + jfif
    sof_payload = struct.pack(">BHHB", 8, h, w, 1) + b"\x01\x11\x00"
    sof0 = b"\xff\xc0" + struct.pack(">H", 2 + len(sof_payload)) + sof_payload
    eoi = b"\xff\xd9"
    return soi + app0 + sof0 + eoi


def make_svg(w, h):
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
        f'viewBox="0 0 {w} {h}">'
        '<rect width="100%" height="100%" fill="#ddd"/>'
        "</svg>"
    ).encode()


def xhtml(title, body):
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:xlink="http://www.w3.org/1999/xlink">\n'
        f"<head><title>{title}</title></head>\n"
        f"<body>\n{body}\n</body>\n</html>\n"
    ).encode()


ORNAMENT = '<div class="head"><img class="ornament" src="../images/ornament.png" alt="ornament.png"/></div>'

FILES = {
    "OEBPS/images/cover.png": make_png(600, 800),
    "OEBPS/images/titleart.png": make_png(800, 1200, 100),
    "OEBPS/images/ban1.png": make_png(1600, 600, 61),
    "OEBPS/images/ban2.png": make_png(1600, 600, 62),
    "OEBPS/images/ban3.png": make_png(1600, 600, 63),
    "OEBPS/images/ban4.png": make_png(1600, 600, 64),
    "OEBPS/images/map.png": make_png(1200, 900),
    "OEBPS/images/ornament.png": make_png(120, 40),
    "OEBPS/images/icon.png": make_png(24, 24),
    "OEBPS/images/divider.png": make_png(1600, 80),
    "OEBPS/images/medium.png": make_png(350, 260),
    "OEBPS/images/tree.jpg": make_jpeg(800, 1000),
    "OEBPS/images/map.svg": make_svg(900, 700),
    "OEBPS/images/old maps/east map.png": make_png(900, 700),
    "OEBPS/text/cover.xhtml": xhtml(
        "Cover", '<img src="../images/cover.png" alt="Cover"/>'
    ),
    "OEBPS/text/title.xhtml": xhtml(
        "Title", '<img src="../images/titleart.png"/>'
    ),
    "OEBPS/text/ch1.xhtml": xhtml(
        "Chapter 1",
        '<img src="../images/ban1.png" alt="Chapter One"/>\n' + ORNAMENT
        + "\n<p>It began, as these things do, with a knock "
        '<img src="../images/icon.png" width="24" height="24" alt=""/> at the door.</p>\n'
        "<figure>\n"
        '  <img src="../images/map.png" alt="map01.png"/>\n'
        "  <figcaption>Map of the <em>Realm</em> &amp; its borders</figcaption>\n"
        "</figure>",
    ),
    "OEBPS/text/ch2.xhtml": xhtml(
        "Chapter 2",
        '<img src="../images/ban2.png" alt="Chapter Two"/>\n' + ORNAMENT
        + '\n<p>The Greyholds were an old family.</p>\n'
        '<img src="../images/tree.jpg" alt="The Greyhold family tree"/>\n'
        '<img src="../images/divider.png" alt=""/>',
    ),
    "OEBPS/text/ch3.xhtml": xhtml(
        "Chapter 3",
        '<img src="../images/ban3.png" alt="Chapter Three"/>\n' + ORNAMENT
        + '\n<p>A photograph lay on the table.</p>\n'
        '<img src="../images/medium.png"/>\n'
        '<!-- <img src="../images/icon.png"/> -->',
    ),
    "OEBPS/text/ch4.xhtml": xhtml(
        "Chapter 4",
        '<img src="../images/ban4.png" alt="Chapter Four"/>\n'
        '<p>East of the mountains the land changed.</p>\n'
        '<img src="../images/old%20maps/east%20map.png" '
        'title="Map of the Eastern Marches"/>',
    ),
    "OEBPS/text/ch5.xhtml": xhtml(
        "Chapter 5",
        '<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%">\n'
        '<image xlink:href="../images/map.svg" width="900" height="700"/>\n'
        "</svg>",
    ),
}

MANIFEST_ITEMS = [
    ("cover-img", "images/cover.png", "image/png", ' properties="cover-image"'),
    ("titleart", "images/titleart.png", "image/png", ""),
    ("ban1", "images/ban1.png", "image/png", ""),
    ("ban2", "images/ban2.png", "image/png", ""),
    ("ban3", "images/ban3.png", "image/png", ""),
    ("ban4", "images/ban4.png", "image/png", ""),
    ("map", "images/map.png", "image/png", ""),
    ("ornament", "images/ornament.png", "image/png", ""),
    ("icon", "images/icon.png", "image/png", ""),
    ("divider", "images/divider.png", "image/png", ""),
    ("medium", "images/medium.png", "image/png", ""),
    ("tree", "images/tree.jpg", "image/jpeg", ""),
    ("mapsvg", "images/map.svg", "image/svg+xml", ""),
    ("eastmap", "images/old%20maps/east%20map.png", "image/png", ""),
    ("cover", "text/cover.xhtml", "application/xhtml+xml", ""),
    ("title", "text/title.xhtml", "application/xhtml+xml", ""),
    ("ch1", "text/ch1.xhtml", "application/xhtml+xml", ""),
    ("ch2", "text/ch2.xhtml", "application/xhtml+xml", ""),
    ("ch3", "text/ch3.xhtml", "application/xhtml+xml", ""),
    ("ch4", "text/ch4.xhtml", "application/xhtml+xml", ""),
    ("ch5", "text/ch5.xhtml", "application/xhtml+xml", ""),
]
SPINE = ["cover", "title", "ch1", "ch2", "ch3", "ch4", "ch5"]

manifest = "\n".join(
    f'    <item id="{i}" href="{h}" media-type="{m}"{extra}/>'
    for i, h, m, extra in MANIFEST_ITEMS
)
spine = "\n".join(f'    <itemref idref="{i}"/>' for i in SPINE)

FILES["OEBPS/content.opf"] = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">\n'
    '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
    '    <dc:identifier id="uid">urn:uuid:glimpse-fixture</dc:identifier>\n'
    "    <dc:title>Glimpse Fixture</dc:title>\n"
    "    <dc:language>en</dc:language>\n"
    '    <meta name="cover" content="cover-img"/>\n'
    "  </metadata>\n"
    f"  <manifest>\n{manifest}\n  </manifest>\n"
    f"  <spine>\n{spine}\n  </spine>\n"
    "</package>\n"
).encode()

FILES["META-INF/container.xml"] = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
    "  <rootfiles>\n"
    '    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>\n'
    "  </rootfiles>\n"
    "</container>\n"
).encode()


def main():
    with zipfile.ZipFile(EPUB, "w") as z:
        z.writestr(
            zipfile.ZipInfo("mimetype"),
            "application/epub+zip",
            compress_type=zipfile.ZIP_STORED,
        )
        for name, data in sorted(FILES.items()):
            z.writestr(name, data)

    if os.path.isdir(EXTRACTED):
        shutil.rmtree(EXTRACTED)
    os.makedirs(EXTRACTED)
    with open(os.path.join(EXTRACTED, "mimetype"), "wb") as f:
        f.write(b"application/epub+zip")
    for name, data in FILES.items():
        dest = os.path.join(EXTRACTED, *name.split("/"))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(data)

    print(f"wrote {EPUB} and {EXTRACTED}/ ({len(FILES) + 1} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
