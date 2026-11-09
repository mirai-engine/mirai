package physics

import "base:runtime"
import "core:testing"
import "mirai:core"
import "mirai:std/base"

// The room for the bodies whose Transform changes grows with the bodies of
// the world: without memory for it the tick says so and still makes its
// bodies, and with memory it has the room.
@(test)
a_tick_without_memory_for_its_changed_bodies_reports_it_and_makes_them :: proc(t:^testing.T) {
    f:Physics_Test
    physics_test_init(&f)
    defer physics_test_destroy(&f)
    failure:=Physics_Copy_Failure{owner=context.allocator}
    f.state.sealed=make([dynamic]Sealed_Body,runtime.Allocator{physics_copy_allocator,&failure})
    budgets:=[]int{0,0,max(int)}
    for budget,at in budgets {
        box:=physics_test_box(&f,{f32(at)*3,2,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
        f.problems={}
        failure.remaining=budget
        physics_test_step(&f,0)
        failure.remaining=max(int)
        reported:=false
        for &p in core.problems_list(&f.problems) {reported||=base.text_get(p.code[:])=="physics.memory"}
        testing.expectf(t,reported==(budget==0),"tick %d with %d requests served: reported %v",at,budget,reported)
        testing.expectf(t,(cap(f.state.sealed)>0)==(budget!=0),"tick %d with %d requests served: room for %d",at,budget,cap(f.state.sealed))
        testing.expectf(t,body_of(core.ref(&f.state),box)!={},"tick %d with %d requests served: its body was not made",at,budget)
    }
}
