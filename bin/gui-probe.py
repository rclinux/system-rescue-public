#!/usr/bin/env python3
# gui-probe.py — DIAGNOSTIC, not the real UI. Answers one question on
# whatever machine it is booted on: can a GTK4/libadwaita window actually
# render here, and does it take input?
#
# It exists because the graphical path has one genuine unknown left --
# this machine's GPU. The ISO carries only xf86-video-nouveau, which is
# marginal on Blackwell, so "it worked in a VM with QXL" proves the
# software and nothing about the hardware. This is the cheapest way to
# find out, and it writes nothing and touches no disk.
#
# Delete this file once the real GUI exists.
#
# Everything it reports is drawn IN the window, deliberately large, because
# the only way to read it is a screenshot of the VM console. It answers:
#   1. does GTK4 initialise and map a window at all
#   2. WHICH GskRenderer it ended up with (the ISO ships no DRI drivers, so
#      the GL renderer should fail over to cairo -- proving that is the point)
#   3. is libadwaita usable, since the real UI would be built on it
#   4. does it see the VM's disks, i.e. is a disk-picker UI feasible here

import os
import sys

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk, Gdk  # noqa: E402


def probe_disks():
    """Whole disks as the real UI would list them. lsblk, not guesswork."""
    try:
        out = GLib.spawn_command_line_sync("lsblk -dno NAME,SIZE,TYPE")[1]
        lines = [l for l in out.decode().splitlines() if " disk" in l]
        return lines or ["(none seen)"]
    except Exception as e:  # noqa: BLE001
        return [f"lsblk failed: {e}"]


class Probe(Adw.Application):
    def __init__(self):
        super().__init__(application_id="org.systemrescue.GuiSmokeTest")

    def do_activate(self):
        win = Adw.ApplicationWindow(application=self)
        win.set_title("system_rescue GUI probe")
        win.fullscreen()

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        box.set_margin_top(50)
        box.set_margin_start(60)
        box.set_margin_end(60)

        banner = Gtk.Label()
        banner.set_markup(
            '<span size="46000" weight="bold" foreground="#26A269">'
            "GTK4 WINDOW RENDERED — PASS</span>"
        )
        box.append(banner)

        # The renderer is only knowable once the window has a native surface,
        # so it is filled in after realize rather than guessed up front.
        detail = Gtk.Label(xalign=0.0)
        detail.set_selectable(False)
        box.append(detail)

        def fill(_w):
            native = win.get_native()
            renderer = native.get_renderer() if native else None
            rname = type(renderer).__name__ if renderer else "(none)"
            display = Gdk.Display.get_default()
            mon = display.get_monitors()
            geo = mon[0].get_geometry() if mon.get_n_items() else None
            rows = [
                f"GskRenderer      : {rname}",
                f"GSK_RENDERER env : {os.environ.get('GSK_RENDERER', '(unset)')}",
                f"GDK backend      : {type(display).__name__}",
                f"GTK version      : {Gtk.get_major_version()}."
                f"{Gtk.get_minor_version()}.{Gtk.get_micro_version()}",
                f"libadwaita       : {Adw.MAJOR_VERSION}.{Adw.MINOR_VERSION}",
                f"Python           : {sys.version.split()[0]}",
                f"Screen           : {geo.width}x{geo.height}" if geo else "Screen: ?",
                "",
                "Whole disks visible to a picker UI:",
            ] + [f"    {d}" for d in probe_disks()]
            detail.set_markup(
                '<span size="19000" font_family="monospace">'
                + GLib.markup_escape_text("\n".join(rows))
                + "</span>"
            )

        win.connect("realize", fill)

        # Prove interaction works too -- the whole premise is click-to-select.
        clicks = Gtk.Label()
        clicks.set_markup('<span size="22000">Click the button to test input</span>')
        btn = Gtk.Button(label="Click me")
        btn.set_halign(Gtk.Align.START)
        btn.add_css_class("suggested-action")
        state = {"n": 0}

        def clicked(_b):
            state["n"] += 1
            clicks.set_markup(
                f'<span size="22000" foreground="#26A269">'
                f"INPUT OK — {state['n']} click(s) received</span>"
            )

        btn.connect("clicked", clicked)
        box.append(btn)
        box.append(clicks)

        win.set_content(box)
        win.present()


if __name__ == "__main__":
    sys.exit(Probe().run(None))
