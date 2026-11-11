package vfx_editor

import "core:testing"
import erender "mirai:engine/render"
import "mirai:std/serial"
import vfx "plugins:vfx/runtime"

// particle.instance.inspect gives the Attributes of a particle by the names
// of the fields of its program, a vector as a list, in the world.
@(test)
instance_inspect_names_the_attributes_of_its_program :: proc(t:^testing.T) {
    particles:=[2]vfx.Gpu_Particle{{position={1,2,3},lifetime=2,age=0.5,seed=5},{}}
    words:=[8]u32{transmute(u32)f32(0.25),transmute(u32)f32(1),transmute(u32)f32(2),transmute(u32)f32(3),0,0,0,0}
    rows:=vfx.Emitter_Rows{pose={id=7,frame=12,origin={10,0,0}},stride=16,particles=particles[:],words=words[:]}
    fields:=[2]erender.Program_Attribute{{"heat",.Float,1,0},{"home",.Float,3,4}}
    shown:=gpu_particle(&rows,0,fields[:])
    testing.expect_value(t,string(shown.attributes),`{"heat":0.25,"home":[1,2,3]}`)
    testing.expect_value(t,shown.position,[3]f32{11,2,3})
    testing.expect_value(t,shown.seed,u32(5))
    // Its text is JSON the API writes as it is.
    value:struct{heat:f32,home:[3]f32}
    testing.expect_value(t,serial.text_decode(string(shown.attributes),&value,context.temp_allocator),"")
    testing.expect(t,value.heat==0.25 && value.home==[3]f32{1,2,3})
}
