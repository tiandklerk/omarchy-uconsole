-- uConsole look & feel overrides.
--
-- 480 vertical pixels is the constraint that shapes everything here: Omarchy's
-- desktop-sized gaps and borders cost a visible fraction of the screen, so they
-- are tightened rather than removed (removing them entirely makes tiled windows
-- indistinguishable at this size).

hl.config({
  general = {
    gaps_in = 2,
    gaps_out = 4,
    border_size = 1,
  },
  decoration = {
    rounding = 4,
    -- Blur is a real cost on the CM5's VideoCore VII and buys little on a
    -- panel this small.
    blur = { enabled = false },
    shadow = { enabled = false },
  },
  animations = {
    -- Kept on, but short: long animations feel sluggish on this GPU.
    enabled = true,
  },
})
