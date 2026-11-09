package main

import "core:testing"

// An older base refuses a field it does not have with this message: render and bench drop that
// field and measure without it.
@(test)
a_field_an_older_build_does_not_take_is_named :: proc(t:^testing.T) {
    Case :: struct {message,field:string,found:bool}
    cases:=[?]Case{
        {`invalid params: "memory" is not a field: the fields are frames, advance, dt, label, top, wait, allow_limited at line 1 column 56`,"memory",true},
        {`invalid params: frames must be at least 2`,"",false},
        {`"broken is not a field`,"",false},
    }
    for c in cases {
        field,found:=unknown_field(c.message)
        testing.expectf(t,found==c.found && field==c.field,"%q: %q %v",c.message,field,found)
    }
}
