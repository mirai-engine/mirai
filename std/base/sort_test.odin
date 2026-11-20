package base

import "base:runtime"
import "core:testing"

@(test)
sorting_large_values_keeps_the_original_order_within_each_key :: proc(t:^testing.T) {
    Value :: struct {key,ordinal:int,payload:[96]u8}
    values:[17]Value
    temporary:=context.temp_allocator
    allocators:=[2]runtime.Allocator{temporary,runtime.nil_allocator()}
    for allocator in allocators {
        context.temp_allocator=allocator
        for &value,i in values {value={key=(i*7)%3,ordinal=i}}
        stable_sort_by(values[:],proc(a,b:Value) -> bool {return a.key<b.key})
        context.temp_allocator=temporary
        for value,i in values[1:] {
            before:=values[i]
            testing.expect(t,before.key<value.key || before.key==value.key && before.ordinal<value.ordinal)
        }
    }
}
