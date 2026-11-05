# dmgbuild settings for the DMG window. render.sh builds a throwaway DMG with these only to keep its
# .DS_Store; the release copies that file and background.tiff in beside Oops.app and the Applications
# link (script/release_dmg.py). The .DS_Store finds the background by the volume name, Oops, and its
# path, /.background.tiff. Finder measures window_rect from the bottom of the screen, and its height
# includes the title bar.
# The throwaway holds no app and no Applications link: Finder offers to install an app from any disk image
# that appears, and icon_locations needs only the names.
background = defines["background"]  # noqa: F821 (dmgbuild supplies defines)
window_rect = ((200, 368), (640, 432))
default_view = "icon-view"
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {"Oops.app": (160, 176), "Applications": (480, 176)}
