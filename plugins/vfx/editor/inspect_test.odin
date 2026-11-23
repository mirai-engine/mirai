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

// particle.instance.inspect names the first link that keeps an emitter from
// being seen, in the order an emitter goes through them, or the pass that
// draws it.
@(test)
why_names_the_first_broken_link :: proc(t:^testing.T) {
    seen:=Why_Facts{told=true,pooled=true,alive=3}
    Case :: struct {facts:Why_Facts,why:string}
    with :: proc(f:Why_Facts,change:proc(f:^Why_Facts)) -> Why_Facts {f:=f;change(&f);return f}
    cases:=[]Case{
        {with(seen,proc(f:^Why_Facts) {f.unresolved=true;f.program=true}),"unresolved"},
        {with(seen,proc(f:^Why_Facts) {f.told=false}),"unresolved"},
        {with(seen,proc(f:^Why_Facts) {f.program=true;f.hidden=true}),"invalid_program"},
        {with(seen,proc(f:^Why_Facts) {f.hidden=true;f.culled=true;f.pooled=false}),"hidden"},
        {with(seen,proc(f:^Why_Facts) {f.culled=true;f.alive=0}),"culled"},
        {with(seen,proc(f:^Why_Facts) {f.pooled=false;f.missing=true}),"pool_full"},
        {with(seen,proc(f:^Why_Facts) {f.missing=true;f.alive=0}),"missing_resource"},
        {with(seen,proc(f:^Why_Facts) {f.alive=0;f.gbuffer=true}),"zero_alive"},
        {with(seen,proc(f:^Why_Facts) {f.gbuffer=true}),"gbuffer"},
        {seen,"blend"},
        {with(seen,proc(f:^Why_Facts) {f.alive=-1}),"blend"},
    }
    names:=WHY_NAMES
    for c,i in cases {
        testing.expectf(t,names[instance_why(c.facts)]==c.why,"case %d: %s, not %s",i,names[instance_why(c.facts)],c.why)
    }
}

// The particles of an emitter whose particles move with it come back in the
// world, through where it was in the frame they were read; those of the
// world, from the origin they were relative to.
@(test)
particles_read_back_in_the_world :: proc(t:^testing.T) {
    p:=vfx.Gpu_Particle{position={1,0,0},velocity={0,0,2},lifetime=1}
    turned:matrix[4,4]f32=1
    // A quarter turn about +y and two metres up.
    turned[0,0],turned[0,2],turned[2,0],turned[2,2]=0,1,-1,0
    turned[1,3]=2
    local:=Emitter_Pose{local_space=true,transform=turned}
    position,velocity:=pose_world(local,p)
    testing.expectf(t,abs(position.x)<1e-6 && abs(position.y-2)<1e-6 && abs(position.z+1)<1e-6,"%v",position)
    testing.expectf(t,abs(velocity.x-2)<1e-6 && abs(velocity.z)<1e-6,"%v",velocity)
    world:=Emitter_Pose{origin={100,0,-50},transform=turned}
    position,velocity=pose_world(world,p)
    testing.expect_value(t,position,[3]f32{101,0,-50})
    testing.expect_value(t,velocity,[3]f32{0,0,2})
}
