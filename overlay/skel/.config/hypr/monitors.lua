-- uConsole display configuration.
--
-- The panel is a 480x1280 portrait DSI LCD that is physically mounted rotated
-- 90° in the shell, so it must be transformed to present as 1280x480
-- landscape. transform = 3 is 270°, matching the `wlr-randr --transform 270`
-- that ClockworkPi's own images use.
--
-- Depending on kernel version and which DSI lane the CM5 brings up, the output
-- appears as DSI-1 or DSI-2. Both are configured; Hyprland ignores a rule for
-- an output that is not present.

hl.monitor({ output = "DSI-1", mode = "480x1280@60", position = "0x0", scale = 1, transform = 3 })
hl.monitor({ output = "DSI-2", mode = "480x1280@60", position = "0x0", scale = 1, transform = 3 })

-- Anything plugged into the CM5's HDMI lands to the right of the panel.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

-- Omarchy defaults GDK_SCALE to 2, which is right for a HiDPI laptop and far
-- too large for a 1280x480 panel where vertical space is the scarce resource.
hl.env("GDK_SCALE", "1")
