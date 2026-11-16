package editor

import "core:testing"
import "mirai:editor/api"

// Whether the JSON a handler writes keeps the shape of the type of its result.
api_result_shape_expect :: proc(t:^testing.T,text:string,shape:typeid,loc:=#caller_location) {
    testing.expect_value(t,api.result_mismatch(shape,text),"",loc=loc)
}
