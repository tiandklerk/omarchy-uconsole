-- uConsole display configuration.
--
-- The panel is a 5" 720x1280 portrait DSI LCD, mounted rotated 90 degrees in
-- the shell, so it presents as 1280x720 landscape. transform = 3 is 270
-- degrees, matching the `wlr-randr --transform 270` ClockworkPi's own images
-- use.
--
-- mode = "preferred", NOT a hard-coded resolution. This panel advertises
-- exactly one mode (720x1280@59.901) and naming a mode it does not have leaves
-- the CRTC disabled: the backlight stays lit and nothing is ever displayed,
-- which looks like a broken compositor and is not. Do not "fix" this by
-- pinning a resolution.
--
-- Depending on kernel version and which DSI lane the CM5 brings up, the output
-- appears as DSI-1 or DSI-2 (a CM5 reports DSI-2). Both are configured;
-- Hyprland ignores a rule for an output that is not present.
--
-- The catch-all comes FIRST so the specific rules below win.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
hl.monitor({ output = "DSI-1", mode = "preferred", position = "0x0", scale = 1, transform = 3 })
hl.monitor({ output = "DSI-2", mode = "preferred", position = "0x0", scale = 1, transform = 3 })

-- Omarchy defaults GDK_SCALE to 2, which is right for a HiDPI laptop and wrong
-- for a 5" 1280x720 panel.
hl.env("GDK_SCALE", "1")
