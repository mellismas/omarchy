-- Face authentication bindings, listed only where the faceauth program is
-- installed.
if o.cmd_present("faceauth") then
  o.bind("SUPER + CTRL + SHIFT + L", "Cycle face walk-away lock mode", "omarchy-faceauth-lockmode")
end
