# dmgbuild settings: `dmgbuild -s scripts/dmg-settings.py -D app=... -D background=... NAME out.dmg`
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
appname = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")

background = defines["background"]  # noqa: F821
window_rect = ((200, 160), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
icon_size = 112
text_size = 13
icon_locations = {appname: (170, 196), "Applications": (470, 196)}
