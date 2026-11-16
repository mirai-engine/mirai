package base

import "core:testing"

@(test)
handle_packs_index_and_generation :: proc(t:^testing.T) {
    h:=handle_make(7,3)
    testing.expect_value(t,handle_index(h),u32(7))
    testing.expect_value(t,handle_generation(h),u32(3))
    testing.expect(t,h!=Handle(0))
}
