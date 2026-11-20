"""Create and verify the installer's Finder layout using one set of dimensions."""

import os
from pathlib import Path
import struct
import sys

width, height = 680, 430
icon_size = 104
app_location = (175, 197)
applications_location = (505, 197)
window_origin = (160, 120)

if "defines" in globals():
    application = Path(defines["app"])
    format = "UDZO"
    filesystem = "HFS+"
    files = [str(application)]
    symlinks = {"Applications": "/Applications"}
    background = defines["background"]
    window_rect = (window_origin, (width, height))
    show_toolbar = False
    show_sidebar = False
    show_status_bar = False
    show_pathbar = False
    show_tab_view = False
    default_view = "icon-view"
    icon_view_settings = {"arrange_by": None, "icon_size": icon_size, "text_size": 13}
    icon_locations = {application.name: app_location, "Applications": applications_location}
elif __name__ == "__main__":
    from ds_store import DSStore
    from mac_alias import Alias

    def require(condition, detail):
        if not condition:
            raise SystemExit(detail)

    mount = Path(sys.argv[1])
    app = "ezNTFS.app"
    applications = mount / "Applications"
    image = mount / ".background.png"
    require(applications.is_symlink() and os.readlink(applications) == "/Applications",
            "Applications does not link to /Applications")
    require((mount / app / "Contents" / "Info.plist").is_file(), "The application bundle is missing")

    with image.open("rb") as png:
        header = png.read(24)
    require(header[:16] == b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
            and struct.unpack(">II", header[16:24]) == (width, height), "Unexpected background dimensions")

    with DSStore.open(str(mount / ".DS_Store"), "r") as store:
        require(store["."]["icvl"] == (b"type", b"icnv"), "Finder did not select icon view")
        window = store["."]["bwsp"]
        left, top = window_origin
        require(window["WindowBounds"] == f"{{{{{left}, {top}}}, {{{width}, {height}}}}}", "Unexpected window bounds")
        require(not any(window.get(key) for key in ("ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowPathbar")),
                "Unexpected Finder window controls")
        view = store["."]["icvp"]
        require(view["backgroundType"] == 2 and view["iconSize"] == icon_size and view["arrangeBy"] == "none",
                "Unexpected background or icon view settings")
        require(store[app]["Iloc"] == app_location and store["Applications"]["Iloc"] == applications_location,
                "Unexpected icon positions")
        require(not list(store.find(".", b"pBBk")), "A stale background bookmark can override the image")
        saved = Alias.from_bytes(view["backgroundImageAlias"]).target
        actual = Alias.for_file(str(image)).target
        require((saved.cnid, saved.creation_date) == (actual.cnid, actual.creation_date),
                "Finder background alias does not point to the mounted image")
    print("Finder layout verified: background, alias, window, icons, and Applications link")
