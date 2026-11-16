package vfx_editor

import "core:math"
import "core:strings"
import "core:testing"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:std/base"
import vfx "plugins:vfx/runtime"

// The Attributes of a particle go by the names of their fields, a value that
// is not finite as null; a scan of rows counts the living particles that
// hold one, a lifetime that is not a number among them as the passes count
// it, and the vfx.nan problem names only the fields that hold one.
@(test)
rows_name_their_attributes_and_report_the_fields_that_are_not_finite :: proc(t:^testing.T) {
    fields:=[]erender.Program_Attribute{{"heat",.Float,1,0},{"calm",.Float,1,4}}
    particles:=[3]vfx.Gpu_Particle{{position={1,2,3},lifetime=4,seed=11},{},{position={-1,0,0},lifetime=2,seed=22}}
    words:=[6]u32{transmute(u32)f32(0.5),transmute(u32)f32(1),0,0,transmute(u32)f32(2),transmute(u32)f32(1)}
    rows:=Emitter_Rows{stride=8,particles=particles[:],words=words[:]}
    testing.expect_value(t,attributes_text(words[:2],fields),`{"heat":0.5,"calm":1}`)
    testing.expect_value(t,rows_scan(&rows,fields).particles,0)
    words[0]=transmute(u32)f32(math.nan_f32())
    particles[1].lifetime=math.nan_f32()
    testing.expect(t,particle_live(particles[1]) && !particle_live({}))
    testing.expect_value(t,attributes_text(words[:2],fields),`{"heat":null,"calm":1}`)
    scan:=rows_scan(&rows,fields)
    testing.expect(t,scan.particles==2 && scan.count==2 && scan.names[0]=="heat" && scan.names[1]=="age")
    problems:core.Problems
    rows_report(&problems,core.Entity(1),scan,"Glitch")
    text:=base.text_get(problems.entries[0].text[:])
    testing.expectf(t,problems.count==1 && base.text_get(problems.entries[0].code[:])=="vfx.nan" && strings.contains(text,"heat") && strings.contains(text,"Glitch") && !strings.contains(text,"calm"),"%s",text)
}
