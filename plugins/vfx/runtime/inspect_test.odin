package vfx

import "core:math"
import "core:testing"
import erender "mirai:engine/render"

// The Attributes of a particle go by the names of their fields, a value that
// is not finite as null, and a scan names only the fields that hold one.
@(test)
rows_name_their_attributes_and_the_fields_that_are_not_finite :: proc(t:^testing.T) {
    fields:=[]erender.Program_Attribute{{"heat",.Float,1,0},{"hits",.Uint,1,4}}
    particles:=[3]Gpu_Particle{{position={1,2,3},lifetime=4,seed=11},{},{position={-1,0,0},lifetime=2,seed=22}}
    words:=[6]u32{transmute(u32)f32(0.5),3,0,0,transmute(u32)f32(2),7}
    rows:=Emitter_Rows{stride=8,particles=particles[:],words=words[:]}
    testing.expect_value(t,attributes_text(words[:2],fields),`{"heat":0.5,"hits":3}`)
    scan:=rows_scan(&rows,fields)
    testing.expect_value(t,scan.particles,0)
    words[0]=transmute(u32)f32(math.nan_f32())
    particles[2].velocity.y=math.inf_f32(1)
    testing.expect_value(t,attributes_text(words[:2],fields),`{"heat":null,"hits":3}`)
    scan=rows_scan(&rows,fields)
    testing.expect(t,scan.particles==2 && scan.count==2 && scan.names[0]=="heat" && scan.names[1]=="velocity")
}
