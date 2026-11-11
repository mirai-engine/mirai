package vfx_editor

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:core"
import erender "mirai:engine/render"
import vfx "plugins:vfx/runtime"

// What the editor reads back and checks of the particles of a pool to debug
// them, over the ranges the plugin gives (vfx.emitter_ranges): the rows of one
// emitter as the GPU had them in a frame, the counters of every emitter and
// values that are not finite.

READ_PARTICLES :: "vfx read particles"
READ_ATTRIBUTES :: "vfx read attributes"
READ_STATE :: "vfx read state"
READ_STATES :: "vfx read states"

// What a pass that read the rows of an emitter back knew of it: frame is the
// one the readback brings back (erender.readback).
Emitter_Pose :: struct {
    frame:u64,
    id:u64,
    origin:[3]f32, // what the places of its particles are relative to; zero for those local to it or of an effect view
}

// The rows of an emitter in one frame, as plain blocks of its range: its
// particles, their Attributes (stride/4 words each) and its counters.
Emitter_Rows :: struct {
    using pose:Emitter_Pose,
    stride:u32,
    state:vfx.Gpu_State,
    particles:[]vfx.Gpu_Particle,
    words:[]u32,
}

// Asks for the rows of an emitter of the pool back, the first count of its
// range: the pose to keep until emitter_rows brings them.
emitter_read :: proc(pass:^erender.Pass,sync:^vfx.Particle_Sync,id:u64,count:u32) -> (pose:Emitter_Pose,ok:bool) {
    if pass.world!=sync.world {return}
    r:=vfx.emitter_ranges(&sync.pool,id,count) or_return
    erender.pass_readback(pass,r.particles.buffer,r.particles.offset,{READ_PARTICLES,r.particles.size}) or_return
    erender.pass_readback(pass,r.state.buffer,r.state.offset,{READ_STATE,r.state.size}) or_return
    if r.attributes.size>0 {erender.pass_readback(pass,r.attributes.buffer,r.attributes.offset,{READ_ATTRIBUTES,r.attributes.size}) or_return}
    return {frame=pass.frame+1,id=id,origin=sync.pool.origin if !r.local else {}},true
}

// The rows emitter_read asked for that came back last, with the pose of
// their frame among poses; false while none came back or their pose is not
// there. Valid until the next frame.
emitter_rows :: proc(renderer:^erender.Renderer,sync:^vfx.Particle_Sync,poses:[]Emitter_Pose) -> (rows:Emitter_Rows,ok:bool) {
    data,frame,read:=erender.readback(renderer,sync.world_id,READ_PARTICLES)
    if !read {return}
    for p in poses {if p.frame==frame {rows.pose=p}}
    if rows.frame!=frame || len(data)<size_of(vfx.Gpu_Particle) {return}
    count:=len(data)/size_of(vfx.Gpu_Particle)
    state,state_frame,_:=erender.readback(renderer,sync.world_id,READ_STATE)
    if state_frame!=frame || len(state)!=size_of(vfx.Gpu_State) {return}
    r:=vfx.emitter_ranges(&sync.pool,rows.id,u32(count)) or_return
    if r.stride>0 {
        words,words_frame,_:=erender.readback(renderer,sync.world_id,READ_ATTRIBUTES)
        if words_frame!=frame || len(words)!=count*int(r.stride) {return}
        rows.stride,rows.words=r.stride,([^]u32)(raw_data(words))[:len(words)/4]
    }
    rows.state=(^vfx.Gpu_State)(raw_data(state))^
    rows.particles=([^]vfx.Gpu_Particle)(raw_data(data))[:count]
    return rows,true
}

// Whether a row holds a living particle, as the passes tell: a free slot has
// lifetime 0, and one whose lifetime is not a number lives on.
particle_live :: proc "contextless" (p:vfx.Gpu_Particle) -> bool {return !(p.lifetime<=0)}

// ---------------------------------------------------------------- every emitter

// An emitter of a pool with its counters as the GPU had them.
Emitter_Overview :: struct {
    id:u64,
    owner:core.Entity,
    slot:u32,
    alive,dead,capacity:u32,
    program:u32,  // its Vfx program; 0: none
    bytes:u64,    // of the pool its particles, lists, Attributes, counters and row take
    paused:bool,
}

// Asks for the counters of every emitter of the pool back, in one readback.
states_read :: proc(pass:^erender.Pass,sync:^vfx.Particle_Sync) -> bool {
    if pass.world!=sync.world || sync.pool.slot_end==0 {return false}
    buffer:=vfx.pool_buffer(&sync.pool,.State)
    return erender.pass_readback(pass,buffer,0,{READ_STATES,buffer.size})
}

// The live emitters of a pool with the counters states_read brought back,
// the most particles alive first; false without memory for the list.
pool_overview :: proc(renderer:^erender.Renderer,sync:^vfx.Particle_Sync,allocator:=context.temp_allocator) -> (list:[]Emitter_Overview,frame:u64,ok:bool) {
    pool:=&sync.pool
    data,read_frame,read:=erender.readback(renderer,sync.world_id,READ_STATES)
    states:=([^]vfx.Gpu_State)(raw_data(data))[:len(data)/size_of(vfx.Gpu_State)] if read else nil
    error:mem.Allocator_Error
    list,error=make([]Emitter_Overview,pool.order_count,allocator)
    if error!=nil {return nil,0,false}
    for at,i in pool.order[:pool.order_count] {
        s:=&pool.slots[at]
        row:=&list[i]
        row^={id=s.id,owner=s.desc.owner,slot=u32(at),capacity=s.capacity,program=s.desc.program.id,paused=s.desc.paused}
        row.bytes=vfx.emitter_bytes(pool,int(at))
        if int(at)<len(states) {row.alive,row.dead=min(states[at].alive,s.capacity),min(states[at].dead,s.capacity)}
    }
    slice.sort_by(list,proc(a,b:Emitter_Overview) -> bool {return a.alive>b.alive || a.alive==b.alive && a.id<b.id})
    return list,read_frame,true
}

// ---------------------------------------------------------------- values that are not finite

ROWS_SCAN_NAMES :: 3 // fields a scan names at most

// The particles of rows that hold NaN or Inf, and the first fields of them.
Rows_Scan :: struct {
    particles:int,
    names:[ROWS_SCAN_NAMES]string,
    count:int,
}

rows_scan :: proc(rows:^Emitter_Rows,fields:[]erender.Program_Attribute) -> (scan:Rows_Scan) {
    note :: proc(scan:^Rows_Scan,name:string) {
        for n in scan.names[:scan.count] {if n==name {return}}
        if scan.count<ROWS_SCAN_NAMES {scan.names[scan.count]=name;scan.count+=1}
    }
    finite :: proc "contextless" (values:..f32) -> bool {
        for v in values {if math.is_nan(v) || math.is_inf(v) {return false}}
        return true
    }
    words:=int(rows.stride/4)
    for p,slot in rows.particles {
        if !particle_live(p) {continue}
        bad:=false
        base_fields:=[?]struct{name:string,ok:bool}{
            {"position",finite(p.position.x,p.position.y,p.position.z)},
            {"velocity",finite(p.velocity.x,p.velocity.y,p.velocity.z)},
            {"age",finite(p.age,p.lifetime)},
            {"size",finite(p.size,p.rotation,p.spin)},
        }
        for f in base_fields {
            if !f.ok {note(&scan,f.name);bad=true}
        }
        if words>0 && (slot+1)*words<=len(rows.words) {
            own:=rows.words[slot*words:][:words]
            for &field in fields {
                if field.kind!=.Float || int(field.offset/4)+int(field.components)>words {continue}
                for word in own[field.offset/4:][:field.components] {
                    if !finite(transmute(f32)word) {note(&scan,field.name);bad=true;break}
                }
            }
        }
        if bad {scan.particles+=1}
    }
    return
}

// The vfx.nan problem of an emitter whose rows hold values that are not
// finite: what holds them and how to fix it. program: the name of its Vfx
// program; empty for none.
rows_report :: proc(problems:^core.Problems,owner:core.Entity,scan:Rows_Scan,program:string) {
    scan:=scan
    if scan.particles==0 {return}
    names:=strings.join(scan.names[:scan.count],", ",context.temp_allocator)
    if program!="" {
        core.report(problems,owner,"vfx.nan","%d particles hold NaN or Inf in %s: its Vfx program %s writes them; guard its divisions, square roots and normalizes of what may be zero in initialize and update",scan.particles,names,program)
    } else {
        core.report(problems,owner,"vfx.nan","%d particles hold NaN or Inf in %s: give its effect finite values, a lifetime and size above 0 and a drag of 0 or more",scan.particles,names)
    }
}

// ---------------------------------------------------------------- attributes by name

// The words of a particle's Attributes by name, as JSON text: a number, or a
// list of the components of a vector.
attributes_text :: proc(words:[]u32,fields:[]erender.Program_Attribute,allocator:=context.temp_allocator) -> string {
    b:=strings.builder_make(allocator)
    strings.write_byte(&b,'{')
    written:=false
    for &field in fields {
        first:=int(field.offset/4)
        if first+int(field.components)>len(words) {continue}
        if written {strings.write_byte(&b,',')}
        written=true
        fmt.sbprintf(&b,"%q:",field.name)
        if field.components>1 {strings.write_byte(&b,'[')}
        for word,c in words[first:][:field.components] {
            if c>0 {strings.write_byte(&b,',')}
            attribute_write(&b,field.kind,word)
        }
        if field.components>1 {strings.write_byte(&b,']')}
    }
    strings.write_byte(&b,'}')
    return strings.to_string(b)
}

// One word of an attribute of that kind, as text (JSON: null for a value that is not finite).
attribute_write :: proc(b:^strings.Builder,kind:erender.Program_Kind,word:u32) {
    switch kind {
    case .Int: fmt.sbprintf(b,"%d",transmute(i32)word)
    case .Uint: fmt.sbprintf(b,"%d",word)
    case .Bool: strings.write_string(b,"true" if word!=0 else "false")
    case .Float,.Texture:
        v:=transmute(f32)word
        if math.is_nan(v) || math.is_inf(v) {strings.write_string(b,"null")} else {fmt.sbprintf(b,"%v",v)}
    }
}
