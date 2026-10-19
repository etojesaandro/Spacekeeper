#!/usr/bin/env python3
"""Draws Spacekeeper's app icon: a white shield holding a photo, on a blue-to-teal sky.

  python3 -I AppResources/Icon/draw-icon.py AppResources/Icon/AppIcon.png
  cp AppResources/Icon/AppIcon.png AppResources/Assets.xcassets/AppIcon.appiconset/

xtool shows the first file on the home screen; Xcode builds the App Store icon from
the copy in the asset catalog.

iOS rounds the corners itself, so the picture fills the whole square, and the
App Store wants no transparency, so the file is plain RGB.
"""

import math
import sys

import cairo
from PIL import Image

SIDE = 1024


def shield(ctx, cx, top, width, height):
    """A shield with a flat top, gently rounded shoulders and a pointed base."""
    half = width / 2
    left, right = cx - half, cx + half
    shoulder = top + height * 0.12
    ctx.new_path()
    ctx.move_to(cx, top)
    ctx.curve_to(cx + half * 0.55, top + height * 0.06, right - half * 0.12, top, right, shoulder)
    ctx.curve_to(right, top + height * 0.62, cx + half * 0.55, top + height * 0.86, cx, top + height)
    ctx.curve_to(cx - half * 0.55, top + height * 0.86, left, top + height * 0.62, left, shoulder)
    ctx.curve_to(left + half * 0.12, top, cx - half * 0.55, top + height * 0.06, cx, top)
    ctx.close_path()


def sky(ctx, x0, y0, x1, y1):
    gradient = cairo.LinearGradient(x0, y0, x1, y1)
    gradient.add_color_stop_rgb(0, 0.20, 0.42, 1.00)
    gradient.add_color_stop_rgb(1, 0.05, 0.72, 0.64)
    return gradient


def main(out):
    surface = cairo.ImageSurface(cairo.FORMAT_RGB24, SIDE, SIDE)
    ctx = cairo.Context(surface)
    ctx.set_source(sky(ctx, 0, 0, SIDE, SIDE))
    ctx.paint()

    # A soft glow behind the shield lifts it from the background.
    glow = cairo.RadialGradient(SIDE / 2, SIDE * 0.46, 0, SIDE / 2, SIDE * 0.46, SIDE * 0.5)
    glow.add_color_stop_rgba(0, 1, 1, 1, 0.22)
    glow.add_color_stop_rgba(1, 1, 1, 1, 0)
    ctx.set_source(glow)
    ctx.paint()

    cx, top, width, height = SIDE / 2, SIDE * 0.17, SIDE * 0.60, SIDE * 0.68
    shield(ctx, cx, top, width, height)
    ctx.set_source_rgb(1, 1, 1)
    ctx.fill()

    # The photo inside: a rounded frame of the sky's colours with mountains and a sun.
    fx, fy, fw, fh, r = cx - width * 0.31, top + height * 0.24, width * 0.62, height * 0.42, 34
    ctx.new_path()
    ctx.arc(fx + fw - r, fy + r, r, -math.pi / 2, 0)
    ctx.arc(fx + fw - r, fy + fh - r, r, 0, math.pi / 2)
    ctx.arc(fx + r, fy + fh - r, r, math.pi / 2, math.pi)
    ctx.arc(fx + r, fy + r, r, math.pi, 3 * math.pi / 2)
    ctx.close_path()
    ctx.set_source(sky(ctx, fx, fy, fx + fw, fy + fh))
    ctx.fill_preserve()
    ctx.save()
    ctx.clip()
    ctx.set_source_rgb(1, 1, 1)
    ctx.arc(fx + fw * 0.72, fy + fh * 0.30, fh * 0.12, 0, 2 * math.pi)
    ctx.fill()
    ctx.set_source_rgba(1, 1, 1, 0.92)
    ctx.move_to(fx - 10, fy + fh + 10)
    ctx.line_to(fx + fw * 0.36, fy + fh * 0.42)
    ctx.line_to(fx + fw * 0.62, fy + fh * 0.78)
    ctx.line_to(fx + fw * 0.76, fy + fh * 0.60)
    ctx.line_to(fx + fw + 10, fy + fh + 10)
    ctx.close_path()
    ctx.fill()
    ctx.restore()

    # A small upward chevron under the photo: the photo is kept elsewhere, the phone made lighter.
    ctx.set_source(sky(ctx, cx - 60, 0, cx + 60, 0))
    ctx.set_line_width(26)
    ctx.set_line_cap(cairo.LINE_CAP_ROUND)
    ctx.set_line_join(cairo.LINE_JOIN_ROUND)
    base = top + height * 0.80
    ctx.move_to(cx - 62, base)
    ctx.line_to(cx, base - 56)
    ctx.line_to(cx + 62, base)
    ctx.stroke()

    surface.write_to_png(out)
    # The App Store refuses icons with an alpha channel.
    Image.open(out).convert("RGB").save(out, optimize=True)


if __name__ == "__main__":
    main(sys.argv[1])
