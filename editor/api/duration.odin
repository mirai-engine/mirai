package api

import "core:strconv"
import "core:strings"

// One form for a span of game time or a place in it, in every param that takes
// one: a number is ticks, exact, and a text ending in s is seconds. A person
// shares "3.2s" and an agent passes it as it is; the engine converts.

DURATION_TEXT :: 32 // bytes of the param
DURATION_FORM :: `ticks as a number (120) or seconds as a text ending in s ("1.5s")`

Duration :: struct {
    ticks:u64,       // unless in_seconds
    seconds:f64,     // with in_seconds
    in_seconds:bool,
}

// A duration from its text, also that of a number given where a text goes.
duration_parse :: proc(text:string) -> (d:Duration,ok:bool) {
    if strings.has_suffix(text,"s") {
        seconds,valid:=strconv.parse_f64(text[:len(text)-1])
        if !valid || !(seconds>=0) || seconds>1e12 {return}
        return {seconds=seconds,in_seconds=true},true
    }
    ticks,valid:=strconv.parse_u64(text,10)
    if !valid {return}
    return {ticks=ticks},true
}
