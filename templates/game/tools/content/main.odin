package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "mirai:asset"
import "mirai:cook/content"
import importer "mirai:cook/import"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import world "generated:editor_world"

// Writes what no art source holds: a badge (.tex), a hum and a shot (.sound,
// imported from the WAVs this writes beside them), the rig of the target dummy
// (.skeleton, .mesh and its sway, .anim) and the reload clip of the rifle (.anim). mirai content builds and runs it in the
// root of the project; content.Writer also writes tables of game data
// (records_write) and scenes (scene_write) from code (mirai docs content-tool).

PROJECT :: "game_content"
BADGE_SIZE :: 64
HUM_RATE :: 22050
HUM_SECONDS :: 2
SHOT_FRAMES :: HUM_RATE/4 // a quarter of a second

// An orange disc with a white core, transparent around it.
write_badge :: proc(w:^content.Writer) {
    id:=asset.content_id(PROJECT,"texture","badge")
    pixels:=make([]u8,BADGE_SIZE*BADGE_SIZE*4,context.temp_allocator)
    coverage :: proc(distance,radius:f32) -> f32 {return clamp(radius-distance+0.5,0,1)}
    for y in 0..<BADGE_SIZE {
        for x in 0..<BADGE_SIZE {
            distance:=math.sqrt(math.pow(f32(x)+0.5-BADGE_SIZE/2,2)+math.pow(f32(y)+0.5-BADGE_SIZE/2,2))
            core:=coverage(distance,12)
            color:=[3]f32{255,170,40}*(1-core)+[3]f32{255,255,255}*core
            at:=(y*BADGE_SIZE+x)*4
            pixels[at],pixels[at+1],pixels[at+2]=u8(color.r),u8(color.g),u8(color.b)
            pixels[at+3]=u8(255*coverage(distance,30))
        }
    }
    content.check(w,"assets/hud/badge.tex",asset.texture_save("assets/hud/badge.tex",&w.types,
        {id=id,width=BADGE_SIZE,height=BADGE_SIZE,format=.RGBA8,flags={.Srgb},mips={pixels}}))
}

// Two seconds of a low hum that loops without a click: every partial fits a
// whole number of times. The WAV is the source; the .sound is its import.
write_hum :: proc(w:^content.Writer) {
    FRAMES :: HUM_RATE*HUM_SECONDS
    file:=make([]u8,44+FRAMES*2,context.temp_allocator)
    le :: proc(file:[]u8,at:int,value:u32,size:int) {for i in 0..<size {file[at+i]=u8(value>>uint(8*i))}}
    copy(file,"RIFF");le(file,4,u32(len(file)-8),4);copy(file[8:],"WAVEfmt ")
    le(file,16,16,4);le(file,20,1,2);le(file,22,1,2);le(file,24,HUM_RATE,4);le(file,28,HUM_RATE*2,4);le(file,32,2,2);le(file,34,16,2)
    copy(file[36:],"data");le(file,40,FRAMES*2,4)
    for frame in 0..<FRAMES {
        t:=f64(frame)/HUM_RATE
        wave:=0.5*math.sin(2*math.PI*110*t)+0.25*math.sin(2*math.PI*220*t)+0.12*math.sin(2*math.PI*330*t)
        tremolo:=0.75+0.25*math.sin(2*math.PI*1.5*t)
        le(file,44+frame*2,u32(u16(i16(wave*tremolo*20000))),2)
    }
    // Written only when it differs, so that the import of an unchanged source is the same file.
    if !content.source_write(w,"assets/arena/hum.wav",file) {return}
    if report,imported:=content.import_source(w,"assets/arena/hum.wav");imported {importer.report_destroy(&report)}
}

// A mono 16-bit WAV.
@(private="file")
wav_of :: proc(samples:[]i16) -> []u8 {
    file:=make([]u8,44+len(samples)*2,context.temp_allocator)
    le :: proc(file:[]u8,at:int,value:u32,size:int) {for i in 0..<size {file[at+i]=u8(value>>uint(8*i))}}
    copy(file,"RIFF");le(file,4,u32(len(file)-8),4);copy(file[8:],"WAVEfmt ")
    le(file,16,16,4);le(file,20,1,2);le(file,22,1,2);le(file,24,HUM_RATE,4);le(file,28,HUM_RATE*2,4);le(file,32,2,2);le(file,34,16,2)
    copy(file[36:],"data");le(file,40,u32(len(samples)*2),4)
    for sample,frame in samples {le(file,44+frame*2,u32(u16(sample)),2)}
    return file
}

// A shot: a crack of noise over a thump, gone in a quarter of a second. The
// noise is a fixed sequence, so the file is the same every time.
write_shot :: proc(w:^content.Writer) {
    samples:=make([]i16,SHOT_FRAMES,context.temp_allocator)
    state:=u64(0x5307)
    for &sample,frame in samples {
        t:=f64(frame)/HUM_RATE
        noise:=f64(base.splitmix_next(&state)>>40)/f64(1<<24)*2-1
        level:=f32(0.8*noise*math.exp(-t*40)+0.6*math.sin(2*math.PI*70*t)*math.exp(-t*18))
        sample=i16(clamp(level,-1,1)*20000)
    }
    if !content.source_write(w,"assets/weapon/shot.wav",wav_of(samples)) {return}
    if report,imported:=content.import_source(w,"assets/weapon/shot.wav");imported {importer.report_destroy(&report)}
}

// The target dummy: hips, spine and head bones, a box on each bone (legs on
// the hips) and a sway of its spine that loops. Its hit zones are rows of
// assets/weapon/zones.records on those bones.
DUMMY_BONES :: [3]struct {name,path:string,parent:i32,at:[3]f32}{
    {"hips","hips",-1,{0,0.95,0}},
    {"spine","hips/spine",0,{0,0.15,0}},
    {"head","hips/spine/head",1,{0,0.5,0}},
}

write_dummy :: proc(w:^content.Writer) {
    skeleton_id:=asset.content_id(PROJECT,"skeleton","dummy")
    bones:[3]asset.Skeleton_Bone
    world:[3][3]f32
    for b,i in DUMMY_BONES {
        bones[i]={parent=b.parent,translation=b.at,rotation=1,scale={1,1,1},target=base.name_hash(b.path)}
        base.text_set(bones[i].name[:],b.name);base.text_set(bones[i].path[:],b.path)
        world[i]=b.at+(world[b.parent] if b.parent>=0 else {})
    }
    content.check(w,"assets/target/dummy.skeleton",asset.skeleton_save("assets/target/dummy.skeleton",&w.types,{id=skeleton_id,bones=bones[:]}))
    // A box per bone, in the space the skeleton is bound in.
    Box :: struct {center,half:[3]f32,bone:u16,color:u32}
    boxes:=[3]Box{
        {{0,0.47,0},{0.18,0.47,0.12},0,0xff3a4a5a},
        {{0,1.32,0},{0.24,0.24,0.14},1,0xff4a6a8a},
        {{0,1.72,0},{0.13,0.14,0.13},2,0xff8aa0c0},
    }
    vertices:=make([dynamic]asset.Vertex,context.temp_allocator)
    skin:=make([dynamic]asset.Skin_Vertex,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    faces:=[6][3]f32{{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}
    for box in boxes {
        for n in faces {
            // Two axes across the face with u x v along n: its corners go round counterclockwise
            // seen from outside.
            u:=[3]f32{n.y,n.z,n.x}
            v:=linalg.cross(n,u)
            first:=u32(len(vertices))
            for corner in ([4][2]f32{{-1,-1},{1,-1},{1,1},{-1,1}}) {
                p:=box.center+(n+u*corner.x+v*corner.y)*box.half
                append(&vertices,asset.Vertex{position=p,normal=mm.normal_pack(n),color=box.color})
                influence:asset.Skin_Vertex
                influence.joints[0],influence.weights[0]=box.bone,255
                append(&skin,influence)
            }
            append(&indices,first,first+1,first+2,first,first+2,first+3)
        }
    }
    joints:[3]asset.Rig_Joint
    for i in 0..<3 {joints[i]={node=u32(i),inverse_bind=mm.transform_matrix({-world[i],1,1})}}
    desc:=asset.Mesh_Desc{id=asset.content_id(PROJECT,"mesh","dummy"),skeleton=skeleton_id,joints=joints[:]}
    if !asset.mesh_build({vertices=vertices[:],skin=skin[:],flags={.Has_Colors}},indices[:],nil,&desc.geometry,context.temp_allocator) {
        w.failed=true
        fmt.eprintln("content: the mesh of the dummy could not be built")
        return
    }
    content.check(w,"assets/target/dummy.mesh",asset.mesh_save("assets/target/dummy.mesh",&w.types,desc))
    sway:=[]lib.Keyframe{
        {time=0,value=lib.quat_vec4(1)},
        {time=1,value=lib.quat_vec4(mm.quat_axis_angle({0,0,1},0.12))},
        {time=2,value=lib.quat_vec4(1)},
        {time=3,value=lib.quat_vec4(mm.quat_axis_angle({0,0,1},-0.12))},
        {time=4,value=lib.quat_vec4(1)},
    }
    tracks:=[1]asset.Animation_Track_Desc{{target="hips/spine",property=.Rotation,keys=sway}}
    clip:=asset.Animation_Clip_Desc{name="sway",tracks=tracks[:],skeleton=skeleton_id}
    content.check(w,"assets/target/dummy.anim",asset.animation_save("assets/target/dummy.anim",&w.types,{id=asset.content_id(PROJECT,"animation","dummy"),clips={clip}}))
}

// The reload of the rifle, a clip of the rifle itself: its magazine drops,
// hides while the hand is away and comes back up (the Hidden component, given
// and taken by a track). The ability reload plays it (rifle.records).
write_rifle :: proc(w:^content.Writer) {
    rest:=[3]f32{0,-0.1,-0.15}
    away:=rest+{0,-0.3,0.1}
    drop:=[]lib.Keyframe{
        {time=0,value={rest.x,rest.y,rest.z,0}},{time=0.25,value={away.x,away.y,away.z,0}},
        {time=0.75,value={away.x,away.y,away.z,0}},{time=1,value={rest.x,rest.y,rest.z,0}},
    }
    hidden:=[]lib.Keyframe{
        {time=0,value={0,0,0,0},interpolation=.Step},{time=0.3,value={1,0,0,0},interpolation=.Step},
        {time=0.7,value={0,0,0,0},interpolation=.Step},{time=1,value={0,0,0,0}},
    }
    tracks:=[2]asset.Animation_Track_Desc{
        {target="Magazine",property=.Position,keys=drop},
        {target="Magazine/@field/Hidden",property=.Float,keys=hidden},
    }
    clip:=asset.Animation_Clip_Desc{name="reload",tracks=tracks[:]}
    content.check(w,"assets/weapon/rifle.anim",asset.animation_save("assets/weapon/rifle.anim",&w.types,{id=asset.content_id(PROJECT,"animation","rifle"),clips={clip}}))
}

main :: proc() {
    w:content.Writer
    if !content.open(&w,world.info()) {os.exit(1)}
    for folder in ([]string{"assets/arena","assets/hud","assets/target","assets/weapon"}) {os.make_directory_all(folder)}
    write_badge(&w)
    write_hum(&w)
    write_shot(&w)
    write_dummy(&w)
    write_rifle(&w)
    free_all(context.temp_allocator)
    os.exit(content.close(&w))
}
