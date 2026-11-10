package animation_physics

import "core:testing"
import mm "mirai:std/math"
import locomotion "plugins:locomotion/runtime"

// The matching is told what the body will do: in the air, a body that lets go of the stick keeps
// its course, so the trajectory goes on and not to a stop; a sprint asks for its own speed.
@(test)
the_goal_of_a_walk_follows_what_the_character_does_on_the_ground_and_in_the_air :: proc(t:^testing.T) {
    walk:=locomotion.Walk{max_speed=8,acceleration=24,braking=40,air_control=0.8}
    going:=mm.Vec3{7,-3,0}
    cases:=[?]struct {falling:bool,wish,desired:mm.Vec3,acceleration,braking,speed:f32}{
        {false,{1,0,0},{8,0,0},24,40,8},
        {false,{},{},24,40,8},
        {true,{-1,0,0},{-8,0,0},19.2,19.2,8},
        {true,{},{7,0,0},19.2,19.2,8},
        {false,{0,0,-1},{0,0,-11},24,40,11},
    }
    for c in cases {
        desired,acceleration,braking:=walk_goal(walk,c.falling,c.wish,going,c.speed)
        testing.expectf(t,desired==c.desired && abs(acceleration-c.acceleration)<1e-4 && abs(braking-c.braking)<1e-4,"falling %v wish %v: %v %v %v",c.falling,c.wish,desired,acceleration,braking)
    }
}
