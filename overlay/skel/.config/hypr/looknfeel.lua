-- uConsole look & feel overrides.
--
-- The panel is 1280x720 on a 5" diagonal: the pixel count is ordinary, the
-- physical size is not. Everything is simply small, so gaps and borders are
-- tightened modestly and the expensive effects are dropped - blur and shadows
-- cost real time on the CM5's VideoCore VII and buy little at this size.

hl.config({
  general = {
    gaps_in = 3,
    gaps_out = 6,
    border_size = 1,
  },
  decoration = {
    rounding = 6,
    blur = { enabled = false },
    shadow = { enabled = false },
  },
})
