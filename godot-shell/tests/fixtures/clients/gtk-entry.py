"""A GTK 4 window with an email entry, for the on-screen keyboard's scenario: each change of the
entry's text, and Enter, is a line appended to argv[1]."""
import os
import sys

os.environ.setdefault("GSK_RENDERER", "cairo")
# GTK's own text-input-v3 module, whatever the session sets.
os.environ["GTK_IM_MODULE"] = "wayland"
import gi  # noqa: E402

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk  # noqa: E402

out = sys.argv[1]


def log(line):
    with open(out, "a") as f:
        f.write(line + "\n")


def activate(app):
    win = Gtk.ApplicationWindow(application=app, title="entry")
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    entry = Gtk.Entry(input_purpose=Gtk.InputPurpose.EMAIL)
    entry.connect("changed", lambda e: log("entry " + e.get_text()))
    entry.connect("activate", lambda e: log("activate " + e.get_text()))
    box.append(entry)
    box.append(Gtk.Label(label="below", vexpand=True))
    win.set_child(box)
    win.present()


app = Gtk.Application(application_id="org.livi.test.gtk")
app.connect("activate", activate)
app.run([])
