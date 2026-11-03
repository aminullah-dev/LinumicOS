#!/usr/bin/env python3
# Usage: python3 tools/design/make_colors.py          writes the colour sets into App/Resources/Assets.xcassets
#        python3 tools/design/make_colors.py --check  fails if a colour set differs from this table or a pair misses its contrast
#
# The Linumic OS colour tokens, in one table: the brand accent, the status colours and the area tints of the sidebar
# tiles and page headers. Each has four variants: light, dark, and both again for Increase Contrast. The App names
# them in App/Views/Theme.swift. Standard library only.
#
# The app keeps to four colours, chosen by the owner on 2026-11-02 from a palette he sent: petroleum blue #003B4E (brand,
# links, tiles), olive #5A6B44 (good), sand #AF906A (warning) and terracotta #AC4E3A (bad), each moved in lightness only as
# far as the contrast rules below need, plus a neutral grey for unknown.
#
# The brand is the Linumic ink (#17202C on light, #EEF2F7 on dark: Documents/Linumic-Social/Linumic-Logos/README.md,
# tools/design/make_app_icon.py). Its hue, a slate blue near 214°, gives the accent and the Desk tile.
#
# Contrast rules (WCAG 2.x relative luminance), checked against the backgrounds the app draws on (the page and the cards
# measured on macOS renders, #FFFFFF / #1E1E1E and #F8F8F8 / #262626; iOS grouped backgrounds; a tinted page header):
#   text     the status colours are used for text and icons: at least 4.5:1 on every background and on their own pill
#            (the colour at 14% over that background). With Increase Contrast 7:1 on the page, 6.5:1 on the rest.
#   accent   the accent is link and borderless-button text: 4.5:1 on every background, more with Increase Contrast
#            (7:1 on a light page, 6:1 on dark). White on the accent (prominent buttons, a selected sidebar row): 4.5:1
#            in light mode, at least 3:1 in dark mode. In dark mode no one colour gives both 4.5:1 as text on the page
#            and 4.5:1 under white, and with Increase Contrast the text wins, as it does for macOS's own blue.
#   tile     the area tints carry a white SF Symbol: at least 3:1 for the glyph (4.5:1 with Increase Contrast).
import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
CATALOG = os.path.join(ROOT, "App", "Resources", "Assets.xcassets")
GROUP = "Theme"

# The page first, then cards and grouped backgrounds (macOS and iOS), then a tinted page header.
LIGHT_BG = ["#FFFFFF", "#F8F8F8", "#F2F2F7", "#EFEFF2"]
DARK_BG = ["#1E1E1E", "#000000", "#262626", "#2C2C2E", "#303030"]
PILL_ALPHA = 0.14

#        name               role      light      dark       light HC   dark HC
TOKENS = [
    ("AccentColor",       "accent",  "#005068", "#589DB6", "#003B4E", "#A4D2E2"),
    # Status: good, warn, bad, info, and unknown, which is neutral grey and never green.
    ("StatusGood",        "text",    "#50603C", "#A7BC8B", "#3C4A2C", "#D2E0BE"),
    ("StatusWarn",        "text",    "#73592F", "#D9BD92", "#523F20", "#EDDDC2"),
    ("StatusBad",         "text",    "#9A412F", "#EE9F8C", "#722C20", "#FAD6CD"),
    ("StatusInfo",        "text",    "#005068", "#7DBDD4", "#003B4E", "#BFE0EC"),
    ("StatusUnknown",      "text",   "#5D5D65", "#AFAFB6", "#45454A", "#DBDBDE"),
    # Area tints (sidebar tiles, page headers, number cards). Ink is the brand; Graphite is the muted Archive.
    # Harmonised 2026-10-31: one family, not a rainbow. Each keeps its hue (so money stays green, Monitor pink…) but
    # all share the same moderate saturation and the same white-glyph contrast weight (~4.4 light / 4.0 dark / 5.7 /
    # 5.4 HC), so the tiles and page headers read as one palette. Ink (the brand slate) is left as it was.
    ("AreaInk",           "tile",    "#003B4E", "#1F5F75", "#002C3A", "#003B4E"),
    ("AreaBlue",           "tile",   "#4479C7", "#4E80CA", "#3566B0", "#366AB6"),
    ("AreaIndigo",         "tile",   "#716DCE", "#7875D1", "#5C58C7", "#605CC9"),
    ("AreaPurple",         "tile",   "#955FCA", "#9B68CD", "#8547C2", "#884CC3"),
    ("AreaPink",           "tile",   "#C74C82", "#CA578A", "#B3386E", "#B83A72"),
    ("AreaRed",            "tile",   "#C9524C", "#CD5C56", "#B53C36", "#BC3E38"),
    ("AreaOrange",         "tile",   "#AC6832", "#B66E35", "#93582B", "#985C2C"),
    ("AreaAmber",          "tile",   "#95742B", "#9D792D", "#7F6225", "#836526"),
    ("AreaGreen",          "tile",   "#2B884B", "#2E9050", "#257540", "#267842"),
    ("AreaTeal",           "tile",   "#29848D", "#2C8B96", "#237179", "#24757D"),
    ("AreaBrown",          "tile",   "#9E6E44", "#A77448", "#865E3A", "#8B613C"),
    ("AreaGraphite",       "tile",   "#747883", "#7B7F8A", "#63666F", "#676A74"),
]


def rgb(hex_):
    h = hex_.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def lum(c):
    def ch(v):
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(v) for v in c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def over(fg, bg, alpha):
    return tuple(round(f * alpha + b * (1 - alpha)) for f, b in zip(fg, bg))


WHITE = (255, 255, 255)


def problems():
    out = []
    for name, role, light, dark, light_hc, dark_hc in TOKENS:
        variants = [("light", light, LIGHT_BG, False), ("dark", dark, DARK_BG, False),
                    ("light HC", light_hc, LIGHT_BG, True), ("dark HC", dark_hc, DARK_BG, True)]
        for label, value, bgs, hc in variants:
            c = rgb(value)
            if role in ("text", "accent"):
                # The accent is not drawn as text on a tinted page header, so that background is left out for it.
                for i, bg in enumerate(bgs[:-1] if role == "accent" else bgs):
                    # Increase Contrast: 7:1 on the page itself, 6.5:1 on cards, grouped backgrounds and pills.
                    need = (7.0 if i == 0 else 6.5) if hc else 4.5
                    if role == "accent" and label == "dark HC":
                        need = 6.0
                    b = rgb(bg)
                    if ratio(c, b) < need:
                        out.append(f"{name} {label} {value} on {bg}: {ratio(c, b):.2f} < {need}")
                    if role == "text":
                        pill = over(c, b, PILL_ALPHA)
                        if ratio(c, pill) < need:
                            out.append(f"{name} {label} {value} on its pill over {bg}: {ratio(c, pill):.2f} < {need}")
            if role == "accent" and label != "dark HC":
                need = 3.0 if label == "dark" else 4.5
                if ratio(WHITE, c) < need:
                    out.append(f"{name} {label}: white on {value} {ratio(WHITE, c):.2f} < {need}")
            if role == "tile":
                need = 4.5 if hc else 3.0
                if ratio(WHITE, c) < need:
                    out.append(f"{name} {label}: white glyph on {value} {ratio(WHITE, c):.2f} < {need}")
    return out


def component(v):
    return f"0x{v:02X}"


def colour(value):
    r, g, b = rgb(value)
    return {"color-space": "srgb", "components": {"alpha": "1.000", "blue": component(b), "green": component(g), "red": component(r)}}


def colorset(light, dark, light_hc, dark_hc):
    dark_a = {"appearance": "luminosity", "value": "dark"}
    high = {"appearance": "contrast", "value": "high"}
    return {
        "colors": [
            {"color": colour(light), "idiom": "universal"},
            {"appearances": [dark_a], "color": colour(dark), "idiom": "universal"},
            {"appearances": [high], "color": colour(light_hc), "idiom": "universal"},
            {"appearances": [dark_a, high], "color": colour(dark_hc), "idiom": "universal"},
        ],
        "info": {"author": "xcode", "version": 1},
    }


def files():
    """Every file this script owns, path -> text."""
    out = {}
    def put(path, obj):
        out[path] = json.dumps(obj, indent=2) + "\n"
    put(os.path.join(GROUP, "Contents.json"), {"info": {"author": "xcode", "version": 1}})
    for name, _, light, dark, light_hc, dark_hc in TOKENS:
        # The accent sits at the catalogue's top level, where ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME finds it.
        folder = f"{name}.colorset" if name == "AccentColor" else os.path.join(GROUP, f"{name}.colorset")
        put(os.path.join(folder, "Contents.json"), colorset(light, dark, light_hc, dark_hc))
    return out


def main():
    check = "--check" in sys.argv
    bad = problems()
    for line in bad:
        print("contrast:", line)
    stale = []
    for rel, text in files().items():
        path = os.path.join(CATALOG, rel)
        if check:
            try:
                with open(path) as f:
                    if f.read() != text:
                        stale.append(rel)
            except FileNotFoundError:
                stale.append(rel)
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(text)
    for rel in stale:
        print("out of date (run tools/design/make_colors.py):", rel)
    if bad or stale:
        sys.exit(1)
    print(f"{len(TOKENS)} colour tokens, every contrast rule met" + ("" if check else ", written"))


if __name__ == "__main__":
    main()
