package editor

import "core:testing"

// A headless editor draws its UI at the density asked for, which a restart keeps; a window takes the one of its display.
@(test)
a_headless_editor_takes_the_density_of_its_ui :: proc(t:^testing.T) {
    o,ok:=options_read({"--headless","--density","1.25"})
    testing.expect(t,ok)
    testing.expect_value(t,o.density,f32(1.25))
    kept:=options_passed({"--headless","--density","1.5","--frames","3"})
    testing.expect_value(t,len(kept),3)
    if len(kept)==3 {testing.expect_value(t,kept[2],"1.5")}
    _,ok=options_read({"--density","1.25"})
    testing.expect(t,!ok,"a window takes the density of its display")
    _,ok=options_read({"--headless","--density","9"})
    testing.expect(t,!ok)
    _,ok=options_read({"--headless","--density","high"})
    testing.expect(t,!ok)
}

// --api-port 0 asks for a free port, never the default one, which stays the one of the user's editor.
@(test)
api_port_zero_is_a_free_one_and_never_the_default :: proc(t:^testing.T) {
    o,ok:=options_read({"--headless","--api-port","0"})
    testing.expect(t,ok && o.api_port_any && o.api_port==0)
    o,ok=options_read({"--api-port","7957"})
    testing.expect(t,ok && !o.api_port_any && o.api_port==7957)
    o,ok=options_read({})
    testing.expect(t,ok && !o.api_port_any && o.api_port==0,"without it: the default one")
    _,ok=options_read({"--api-port","-1"})
    testing.expect(t,!ok)
    _,ok=options_read({"--api-port","70000"})
    testing.expect(t,!ok)
}
