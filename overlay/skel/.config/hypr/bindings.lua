-- uConsole key bindings.
--
-- Short-press the power button to lock the session and blank the panel: the
-- closest thing to a handheld's sleep button that this hardware allows, since
-- the kernel exposes no suspend state (see the logind drop-in for detail).
-- Any keypress or trackball movement wakes it, via Omarchy's
-- key_press_enables_dpms / mouse_move_enables_dpms defaults.
--
-- A long press powers off, handled by logind.
--
-- `locked = true` so the binding still works once the session is locked -
-- otherwise pressing power on a locked screen would do nothing.
o.bind("XF86PowerOff", "Sleep (lock and blank screen)", "uconsole-lock-and-blank", { locked = true })

-- Add your own bindings below. To change an Omarchy default, unbind it first:
--   hl.unbind("SUPER + SPACE")
--   o.bind("SUPER + SPACE", "Omarchy menu", "omarchy-menu toggle root")
