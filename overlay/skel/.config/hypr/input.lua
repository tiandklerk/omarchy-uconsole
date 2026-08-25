-- uConsole input configuration.
--
-- The uConsole has a membrane matrix keyboard and an optical trackball, both
-- presented by the ClockworkPi HID firmware over I2C/USB. The trackball is a
-- pointer, not a touchpad, so touchpad options do not apply to it.

hl.config({
  input = {
    kb_layout = "us",
    -- The matrix keyboard rattles on long presses at Omarchy's default rate.
    repeat_rate = 30,
    repeat_delay = 300,
    -- The trackball is small; without extra sensitivity crossing a 1280px-wide
    -- screen takes several swipes.
    sensitivity = 0.4,
    accel_profile = "adaptive",
  },
})
