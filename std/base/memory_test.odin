package base

import "core:testing"

@(test)
the_memory_of_the_machine_has_what_is_available_within_its_total :: proc(t:^testing.T) {
    total,available,ok:=memory_stats()
    if !testing.expect(t,ok,"the system says how much memory it has") {return}
    testing.expect(t,total>0 && available>0 && available<=total)
}
