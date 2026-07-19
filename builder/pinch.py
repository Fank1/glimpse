#!/usr/bin/env python3
"""Inject synthetic two-finger pinch gestures into the VM via a virtual
multitouch touchscreen (uinput). GNOME routes the touches to whatever window
is under them — run KOReader fullscreen (or centered) and pinch away.

Usage:
  python3 pinch.py out            # spread fingers = zoom IN (screen center)
  python3 pinch.py in             # pinch fingers  = zoom OUT
  python3 pinch.py out 0.5 0.4    # centered at 50% width / 40% height
  python3 pinch.py tap2           # two-finger tap

Needs: python3-evdev, and /dev/uinput writable by the 'input' group
(run glimpse-touch-setup.sh once as root).
"""
import sys
import time

from evdev import UInput, AbsInfo, ecodes as e

RES = 10000  # virtual coordinate space; the compositor scales it to screen

CAP = {
    e.EV_KEY: [e.BTN_TOUCH],
    e.EV_ABS: [
        (e.ABS_MT_SLOT, AbsInfo(0, 0, 9, 0, 0, 0)),
        (e.ABS_MT_TRACKING_ID, AbsInfo(0, 0, 65535, 0, 0, 0)),
        (e.ABS_MT_POSITION_X, AbsInfo(0, 0, RES, 0, 0, 0)),
        (e.ABS_MT_POSITION_Y, AbsInfo(0, 0, RES, 0, 0, 0)),
        (e.ABS_X, AbsInfo(0, 0, RES, 0, 0, 0)),
        (e.ABS_Y, AbsInfo(0, 0, RES, 0, 0, 0)),
    ],
}


def make_device():
    kwargs = dict(name="glimpse-virtual-touch")
    try:
        ui = UInput(CAP, input_props=[e.INPUT_PROP_DIRECT], **kwargs)
    except TypeError:  # older python-evdev without input_props
        ui = UInput(CAP, **kwargs)
    time.sleep(1.0)  # let the compositor enumerate the new touchscreen
    return ui


def syn(ui):
    ui.syn()
    time.sleep(0.012)


def touch_down(ui, p0, p1):
    ui.write(e.EV_ABS, e.ABS_MT_SLOT, 0)
    ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, 1)
    ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, p0[0])
    ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, p0[1])
    ui.write(e.EV_ABS, e.ABS_MT_SLOT, 1)
    ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, 2)
    ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, p1[0])
    ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, p1[1])
    ui.write(e.EV_KEY, e.BTN_TOUCH, 1)
    ui.write(e.EV_ABS, e.ABS_X, p0[0])
    ui.write(e.EV_ABS, e.ABS_Y, p0[1])
    syn(ui)


def touch_move(ui, p0, p1):
    ui.write(e.EV_ABS, e.ABS_MT_SLOT, 0)
    ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, p0[0])
    ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, p0[1])
    ui.write(e.EV_ABS, e.ABS_MT_SLOT, 1)
    ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, p1[0])
    ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, p1[1])
    syn(ui)


def touch_up(ui):
    ui.write(e.EV_ABS, e.ABS_MT_SLOT, 0)
    ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, -1)
    ui.write(e.EV_ABS, e.ABS_MT_SLOT, 1)
    ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, -1)
    ui.write(e.EV_KEY, e.BTN_TOUCH, 0)
    syn(ui)


def lerp(a, b, t):
    return int(a + (b - a) * t)


def pinch(ui, cx, cy, d_start, d_end, steps=24):
    # horizontal two-finger pinch around (cx, cy)
    p0 = (cx - d_start, cy)
    p1 = (cx + d_start, cy)
    touch_down(ui, p0, p1)
    for i in range(1, steps + 1):
        t = i / steps
        d = lerp(d_start, d_end, t)
        touch_move(ui, (cx - d, cy), (cx + d, cy))
    touch_up(ui)


def tap2(ui, cx, cy):
    touch_down(ui, (cx - 400, cy), (cx + 400, cy))
    time.sleep(0.08)
    touch_up(ui)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "out"
    fx = float(sys.argv[2]) if len(sys.argv) > 2 else 0.5
    fy = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5
    cx, cy = int(RES * fx), int(RES * fy)
    # keep both fingers inside a centered window: spans are screen
    # fractions, overridable as 4th/5th args (near, far)
    near = int(RES * (float(sys.argv[4]) if len(sys.argv) > 4 else 0.04))
    far = int(RES * (float(sys.argv[5]) if len(sys.argv) > 5 else 0.12))

    ui = make_device()
    try:
        if mode == "out":       # spread -> zoom in
            pinch(ui, cx, cy, near, far)
        elif mode == "in":      # pinch -> zoom out
            pinch(ui, cx, cy, far, near)
        elif mode == "tap2":
            tap2(ui, cx, cy)
        else:
            sys.exit(__doc__)
        time.sleep(0.3)  # let the last events drain before device removal
    finally:
        ui.close()


if __name__ == "__main__":
    main()
