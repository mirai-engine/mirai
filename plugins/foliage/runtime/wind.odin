package foliage

import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:core"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import mm "mirai:std/math"

// Every type sways in the vertex hook of its batches (foliage_vertex.slang),
// with the wind where each instance stands and the phase of the gust wave
// there, so that gusts cross a forest as they cross its grass; both bend
// about where the plant stands as foliage_sway.slang says, and the hook bends
// every batch of foliage where bodies trampled it (Foliage_Trample). A type
// that casts shadows and stands at least SHADOW_SWAY_HEIGHT casts them
// swaying (Batch_Desc.sway) in the maps near the eye, as long as the wind of
// the zone its cell stands in blows (wind_zone_at, render.batches_wind), so a
// calm valley stays calm whatever blows where the view is; the other maps,
// and every ray, meet it at rest.

WIND_SPEED_MAX :: f32(20) // m/s: the strongest wind foliage sways with
FOLIAGE_SWAY :: f32(0.08) // metres a plant leans per m/s of wind and 10 metres of height, before its type
// Metres from where the largest instance of a type stands to its farthest
// point below which its shadow stands at rest, whatever its wind: the shadow
// of a small plant is small detail whose motion reads as noise on the
// ground, and the shadows of many of them swaying cost as much as the rest of
// the maps. Between wheat to 1.2 m and bushes from 1.3 m.
SHADOW_SWAY_HEIGHT :: f32(1.25)

BEND_LEAN_MAX :: f32(1.4)    // radians, the most a bender leans foliage
BEND_RADIUS_MAX :: f32(4)    // metres

// Leans the foliage around it away from it, by its lean at its middle
// falling to none at the radius of the Volume of its entity, a Sphere of
// BEND_RADIUS_MAX at most: grass where a body passes. What it leans stays
// leaned after it goes and stands back up over TRAMPLE_RECOVER seconds. Each
// point leans by the red of its vertex color, as the wind moves it. The boxes
// the views cull foliage by hold the most a bender can lean it
// (BEND_LEAN_MAX, Batch_Desc.reach); no ray sees it.
@(component,description="Leans the foliage around it away from it, as where a body passes, as far as the Volume of its entity reaches, up to 4 m; what it leaned stands back up over a few seconds.")
Foliage_Bender :: struct {
    lean:f32 `mirai:"min=0,max=1.4,unit=rad"`,  // how far foliage at its middle leans
}

FOLIAGE_BENDER_DEFAULT :: Foliage_Bender{lean=1}

TRAMPLE_SIDE :: 128          // texels a side of the field of trampled foliage
TRAMPLE_TEXEL :: f32(0.5)    // metres
TRAMPLE_RECOVER :: f32(2)    // seconds in which trampled foliage stands back up by all but 1/e of its lean
TRAMPLE_STEP :: f32(32)      // metres between the heights the texels keep theirs from
TRAMPLE_QUIET :: f32(1e-3)   // radians: a lean below it is none
TRAMPLE_TEXTURE :: "foliage trample"
TRAMPLE_BEFORE :: "foliage trample before"
TRAMPLE_BUFFER :: "foliage trample"

// The foliage trampled around the first streaming source, which every
// Foliage_Bender writes: each texel of the world, TRAMPLE_TEXEL metres a
// side, keeps the lean of what stands in it (radians along x and z of the
// world), the height of the centre of the bender that leaned it times that
// lean, and the length of the lean, so that heights blend weighted by how
// much each leaned; the hook reads them. Texel (i,j) of the world is at (i,j)
// modulo TRAMPLE_SIDE: the field follows the view in place, and what enters
// it enters standing.
Foliage_Trample :: struct {
    texels:[][4]f16, // made the first frame a source is known
    low:[2]i64,      // the texel of the world at the lowest corner of the field
    height:f32,      // metres: the height the texels keep theirs from, a multiple of TRAMPLE_STEP
    writes:int,      // frames still to write: two after one that changed it, for the texture of the frame before
    written:u64,     // frames written: the half of the buffer the last one wrote is its parity
    now,before:u32,  // the textures of the field and of the frame before (render.table_texture); max(u32) none
}

// foliage_wind.slang: what the hook reads in the constants of each view.
Gpu_Wind_Frame :: struct {
    wind:volume.Gpu_Wind,
    trample:[4]f32,  // xy: the centre of the field along x and z, z: the height its texels are from, relative to the origin of the view; w: metres a side
    textures:[4]u32, // x: of the field, y: of the frame before
}

// Metres a point of a type moves at most, `height` metres over its place:
// along the strongest wind, and leaned by a bender. What spreads level does
// not move (foliage_bend).
hook_reach :: proc "contextless" (amount,height:f32) -> f32 {return height*(WIND_SPEED_MAX*amount+BEND_LEAN_MAX)}

// Metres a point of a type moves per m/s of wind and metre of its height:
// what its batches give the hook (Batch_Desc.vertex.x).
sway_amount :: proc "contextless" (t:Foliage_Type) -> f32 {return t.wind*FOLIAGE_SWAY*0.1}

// Metres in the space of a part of a type, `top` metres of it the highest
// over its place, its farthest point `size` metres from where its largest
// instance stands, that its shadow sways at most (Batch_Desc.sway): the most
// a point moves at WIND_SPEED_MAX; 0 for a type that casts none, does not
// sway, or stands lower than SHADOW_SWAY_HEIGHT.
shadow_sway :: proc "contextless" (t:Foliage_Type,top,size:f32) -> f32 {
    if !t.casts_shadow || !(t.wind>0) || size<SHADOW_SWAY_HEIGHT {return 0}
    return WIND_SPEED_MAX*sway_amount(t)*max(top,0)
}

// A zone of wind cells that cast swaying shadows stand in, and a place of
// the world in it: the middle of the last cell that took it.
Wind_Zone :: struct {
    zone:i32, // of wind_zone_at
    at:[3]f32,
}

// The zone of wind of a place of the world, which the cells there sway in:
// the row of the Wind on top of those that hold it (as they
// apply), or -1 for none. Which Wind it names is that of the revision of the
// zones it was taken at (Foliage_Resident.zones_revision).
wind_zone_at :: proc(resident:^Foliage_Resident,at:[3]f32) -> i32 {
    hits,_:=volume.index_hits(&resident.zones,at)
    return hits.hits[hits.count-1].row if hits.count>0 else -1
}

// The zones of wind made again from the Wind of the world: a new revision
// when where they are changed, so that the cells take their zones again; a
// change of their values alone keeps it, as the sets sway with them each frame.
wind_zones_update :: proc(resident:^Foliage_Resident,winds:^core.Table(volume.Wind,$A),zones:volume.Where) {
    changed,ok:=volume.index_update(&resident.zones,zones,winds)
    if !changed {return}
    h:=u64(0xcbf29ce484222325)
    if ok {
        bytes :: proc(h:u64,data:[]u8) -> u64 {return hash.fnv64a(data,h)}
        for &p in resident.zones.places {
            h=bytes(h,mem.ptr_to_bytes(&p.volume))
            h=bytes(h,mem.ptr_to_bytes(&p.pose))
            h=bytes(h,mem.ptr_to_bytes(&p.zone))
            h=bytes(h,mem.ptr_to_bytes(&p.rules))
            h=bytes(h,mem.slice_to_bytes(p.outline))
        }
    }
    if h!=resident.zones_hash || !ok {
        resident.zones_hash=h
        resident.zones_revision+=1
    }
}

// Whether an owner casts swaying shadows in a zone: one of its types does,
// and one of its cells is in that zone.
wind_zone_used :: proc(zone:i32,owner:^Resident_Owner) -> bool {
    if !owner.sways {return false}
    for &cell in owner.cells {if cell.built && cell.zone==zone {return true}}
    return false
}

// The wind a batch that casts swaying shadows in a zone sways in
// (Batch_Desc.wind), the zone kept for its wind to be given each frame.
wind_zone_take :: proc(resident:^Foliage_Resident,zone:i32,at:[3]f32) -> u32 {
    for &z in resident.winds {
        if z.zone==zone {z.at=at;return u32(zone+1)}
    }
    append(&resident.winds,Wind_Zone{zone,at})
    return u32(zone+1)
}

// The wind of each frame: the hook reads all of it in the constants of each
// view, with the field every bender tramples around the first streaming
// source; the zones of wind are read again, and the renderer is told how
// much of their sway the batches of each zone take.
@(step="render",loops="game editor")
foliage_wind :: proc(resident:^Foliage_Resident,winds:^core.Table(volume.Wind,.Read),volumes:^core.Table(volume.Volume,.Read),worlds:^core.Table(core.World_Transform,.Read),parents:^core.Table(core.Parent,.Read),sections:^core.Table(scene.Scene_Reference,.Read),splines:^core.Table(volume.Spline,.Read),sources:core.Ref(scene.Streaming_Sources),benders:^core.Table(Foliage_Bender,.Read),frame:core.Frame_Time,renderer:^render.Renderer) {
    if resident==nil || len(resident.owners)==0 && len(resident.sways.entities)==0 {return}
    zones:=volume.Where{volumes,worlds,parents,sections,splines}
    resident.wind=volume.gpu_wind(winds,zones)
    at:=[3]f32{}
    if sources.ptr!=nil && sources.ptr.count>0 {at=sources.ptr.items[0].position} else if len(resident.owners)>0 {at=resident.owners[0].transform.position}
    trample_draw(resident,benders,volumes,worlds,frame,at,renderer)
    render.frame_pass(renderer,.Mask,foliage_wind_record,resident)
    wind_zones_update(resident,winds,zones)
    for z in resident.winds {render.batches_wind(renderer,u32(z.zone+1),wind_share(volume.wind_at(winds,zones,z.at)))}
    if resident.impostors.count>0 {render.frame_pass(renderer,.Gbuffer,foliage_impostors_record,resident)}
}

// How much of its sway foliage takes in a wind: its speed along the ground
// over WIND_SPEED_MAX, at most all; a vertical wind leans nothing.
wind_share :: proc "contextless" (wind:[4]f32) -> f32 {return min(linalg.length(wind.xz)/WIND_SPEED_MAX,1)}

// The field of this frame around `at`: what left it is forgotten, what was
// trampled stands back up for the frame's time, and every bender whose
// entity is placed tramples it again where it is drawn, as far as the box of
// its Volume reaches, each texel keeping the strongest lean. A bender without
// a Volume, radius or lean tramples nothing; radius and lean are held to
// their limits.
trample_update :: proc(f:^Foliage_Trample,benders:^core.Table(Foliage_Bender,$A),volumes:^core.Table(volume.Volume,$B),worlds:^core.Table(core.World_Transform,$C),frame:core.Frame_Time,at:[3]f32) {
    if f.texels==nil {
        texels,error:=make([][4]f16,TRAMPLE_SIDE*TRAMPLE_SIDE)
        if error!=nil {return}
        f.texels=texels
        f.low=trample_low(at)
        f.height=trample_height(at.y)
        f.now,f.before=max(u32),max(u32)
    }
    changed:=trample_follow(f,at)
    changed|=trample_recover(f,frame.dt)
    for row in 0..<core.count(benders) {
        e:=core.entity_at(benders,row)
        bender:=core.at(benders,row)
        world,placed:=core.get(worlds,e)
        if !placed || !(bender.lean>0) {continue}
        reach,_:=core.get(volumes,e)
        box:=volume.bounds(reach,world.transform)
        radius:=max(box.max.x-box.min.x,box.max.y-box.min.y,box.max.z-box.min.z)*0.5
        if !(radius>0) {continue}
        position:=render.drawn_transform(world,frame).position
        changed|=trample_bend(f,position,min(radius,BEND_RADIUS_MAX),min(bender.lean,BEND_LEAN_MAX))
    }
    if changed {f.writes=2}
}

// The field of this frame around `at`, and its textures, written by the
// frame while it changes.
trample_draw :: proc(resident:^Foliage_Resident,benders:^core.Table(Foliage_Bender,$A),volumes:^core.Table(volume.Volume,$B),worlds:^core.Table(core.World_Transform,$C),frame:core.Frame_Time,at:[3]f32,renderer:^render.Renderer) {
    f:=&resident.trample
    trample_update(f,benders,volumes,worlds,frame,at)
    trample_textures(resident,renderer)
    if f.writes>0 && f.now!=max(u32) && render.frame_pass(renderer,.Geometry,foliage_trample_record,resident) {
        f.writes-=1
        f.written+=1
    }
}

// The texel of the world at the lowest corner of the field around `at`, and
// the height its texels keep theirs from.
trample_low :: proc "contextless" (at:[3]f32) -> [2]i64 {
    return {i64(math.floor(f64(at.x)/f64(TRAMPLE_TEXEL)))-TRAMPLE_SIDE/2,i64(math.floor(f64(at.z)/f64(TRAMPLE_TEXEL)))-TRAMPLE_SIDE/2}
}
trample_height :: proc "contextless" (y:f32) -> f32 {return math.round(y/TRAMPLE_STEP)*TRAMPLE_STEP}

// Where texel i of the world is kept, along one side.
@(private)
trample_wrap :: proc "contextless" (i:i64) -> int {
    m:=i%TRAMPLE_SIDE
    return int(m+TRAMPLE_SIDE if m<0 else m)
}

// Moves the field to `at`: the texels of the world that enter it enter
// standing, and its heights keep theirs from the step nearest it. True when
// a texel changed.
@(private)
trample_follow :: proc(f:^Foliage_Trample,at:[3]f32) -> (changed:bool) {
    low:=trample_low(at)
    height:=trample_height(at.y)
    if height!=f.height {
        shift:=f.height-height
        for &v in f.texels {
            if v[3]==0 {continue}
            v[2]=f16(f32(v[2])+shift*f32(v[3]))
            changed=true
        }
        f.height=height
    }
    move:=low-f.low
    if move=={} {return}
    clear_column :: proc(f:^Foliage_Trample,x:int) -> (changed:bool) {
        for y in 0..<TRAMPLE_SIDE {
            v:=&f.texels[y*TRAMPLE_SIDE+x]
            if v[3]!=0 {v^={};changed=true}
        }
        return
    }
    clear_row :: proc(f:^Foliage_Trample,y:int) -> (changed:bool) {
        for &v in f.texels[y*TRAMPLE_SIDE:][:TRAMPLE_SIDE] {
            if v[3]!=0 {v={};changed=true}
        }
        return
    }
    if abs(move.x)>=TRAMPLE_SIDE || abs(move.y)>=TRAMPLE_SIDE {
        for &v in f.texels {
            if v[3]!=0 {v={};changed=true}
        }
    } else {
        // What enters past the side the field moves toward.
        from,to:=f.low.x+TRAMPLE_SIDE,low.x+TRAMPLE_SIDE
        if move.x<0 {from,to=low.x,f.low.x}
        for x in from..<to {changed|=clear_column(f,trample_wrap(x))}
        from,to=f.low.y+TRAMPLE_SIDE,low.y+TRAMPLE_SIDE
        if move.y<0 {from,to=low.y,f.low.y}
        for y in from..<to {changed|=clear_row(f,trample_wrap(y))}
    }
    f.low=low
    return
}

// What was trampled stands back up for dt seconds. True when a texel changed.
@(private)
trample_recover :: proc(f:^Foliage_Trample,dt:f32) -> (changed:bool) {
    if !(dt>0) {return}
    keep:=math.exp(-dt/TRAMPLE_RECOVER)
    for &v in f.texels {
        if v[3]==0 {continue}
        lean:=f32(v[3])*keep
        v=lean<TRAMPLE_QUIET?{}:{f16(f32(v[0])*keep),f16(f32(v[1])*keep),f16(f32(v[2])*keep),f16(lean)}
        changed=true
    }
    return
}

// A bender at `position` tramples the texels within `radius` of it along x
// and z, by `lean` at its middle falling to none at the radius, away from
// it; a texel keeps the stronger of its lean and the bender's. True when a
// texel changed.
trample_bend :: proc(f:^Foliage_Trample,position:[3]f32,radius,lean:f32) -> (changed:bool) {
    lo:=[2]i64{i64(math.floor(f64(position.x-radius)/f64(TRAMPLE_TEXEL))),i64(math.floor(f64(position.z-radius)/f64(TRAMPLE_TEXEL)))}
    hi:=[2]i64{i64(math.floor(f64(position.x+radius)/f64(TRAMPLE_TEXEL))),i64(math.floor(f64(position.z+radius)/f64(TRAMPLE_TEXEL)))}
    lo=linalg.max(lo,f.low)
    hi=linalg.min(hi,f.low+TRAMPLE_SIDE-1)
    height:=position.y-f.height
    for j in lo.y..=hi.y {
        for i in lo.x..=hi.x {
            away:=[2]f32{f32((f64(i)+0.5)*f64(TRAMPLE_TEXEL)-f64(position.x)),f32((f64(j)+0.5)*f64(TRAMPLE_TEXEL)-f64(position.z))}
            d:=linalg.length(away)
            m:=lean*(1-mm.smoothstep(0.4*radius,radius,d))
            if m<TRAMPLE_QUIET {continue}
            v:=&f.texels[trample_wrap(j)*TRAMPLE_SIDE+trample_wrap(i)]
            if m<=f32(v[3]) {continue}
            side:=away/d if d>1e-4 else [2]f32{1,0}
            v^={f16(side.x*m),f16(side.y*m),f16(height*m),f16(m)}
            changed=true
        }
    }
    return
}

// The lean the field keeps at a place of the world, radians along x and z,
// and the height of what leaned it; none outside the field.
trample_at :: proc(f:^Foliage_Trample,at:[3]f32) -> (lean:[2]f32,height:f32,inside:bool) {
    if f.texels==nil {return}
    i,j:=i64(math.floor(f64(at.x)/f64(TRAMPLE_TEXEL))),i64(math.floor(f64(at.z)/f64(TRAMPLE_TEXEL)))
    if i<f.low.x || j<f.low.y || i>=f.low.x+TRAMPLE_SIDE || j>=f.low.y+TRAMPLE_SIDE {return}
    v:=f.texels[trample_wrap(j)*TRAMPLE_SIDE+trample_wrap(i)]
    m:=f32(v[3])
    return {f32(v[0]),f32(v[1])},f.height+(f32(v[2])/m if m>0 else 0),true
}

// The textures of the field, made the first time (a load transaction): the
// field is written again into new ones.
@(private)
trample_textures :: proc(resident:^Foliage_Resident,renderer:^render.Renderer) {
    f:=&resident.trample
    if f.texels==nil {return}
    key:=render.world_key(resident.world)
    now,made,ok:=render.table_texture(renderer,key,{name=TRAMPLE_TEXTURE,width=TRAMPLE_SIDE,height=TRAMPLE_SIDE})
    before,made_before,ok_before:=render.table_texture(renderer,key,{name=TRAMPLE_BEFORE,width=TRAMPLE_SIDE,height=TRAMPLE_SIDE})
    if !ok || !ok_before {f.now,f.before=max(u32),max(u32);return}
    if made || made_before {f.writes=2}
    f.now,f.before=now,before
}

trample_free :: proc(resident:^Foliage_Resident) {
    if resident.app!=nil {
        render.buffer_release(resident.app.renderer,resident.world,TRAMPLE_BUFFER)
        render.table_texture_release(resident.app.renderer,resident.world,TRAMPLE_TEXTURE)
        render.table_texture_release(resident.app.renderer,resident.world,TRAMPLE_BEFORE)
    }
    delete(resident.trample.texels)
    resident.trample={}
}

@(private)
foliage_wind_record :: proc(pass:^render.Pass,user:rawptr) {
    resident:=cast(^Foliage_Resident)user
    data:=render.pass_extension_data(pass,"foliage_wind")
    if len(data)<size_of(Gpu_Wind_Frame) {return}
    frame:Gpu_Wind_Frame
    frame.wind=volume.gpu_wind_relative(resident.wind,pass.origin)
    frame.textures={max(u32),max(u32),0,0}
    if f:=&resident.trample;f.texels!=nil && f.now!=max(u32) {
        side:=f32(TRAMPLE_SIDE)*TRAMPLE_TEXEL
        centre:=[3]f32{f32(f64(f.low.x)*f64(TRAMPLE_TEXEL))+side*0.5,f.height,f32(f64(f.low.y)*f64(TRAMPLE_TEXEL))+side*0.5}
        at:=render.origin_point(centre,pass.origin)
        frame.trample={at.x,at.z,at.y,side}
        frame.textures={f.now,f.before,0,0}
    }
    copy(data,([^]u8)(&frame)[:size_of(Gpu_Wind_Frame)])
}

// The field into the half of its buffer of this frame, and into its texture;
// the half the frame before wrote into the texture of the frame before.
@(private)
foliage_trample_record :: proc(pass:^render.Pass,user:rawptr) {
    resident:=cast(^Foliage_Resident)user
    f:=&resident.trample
    if pass.world!=render.world_key(resident.world) || f.texels==nil || f.written==0 {return}
    bytes:=u64(len(f.texels)*size_of([4]f16))
    desc:=render.Buffer_Desc{name=TRAMPLE_BUFFER,size=2*bytes}
    bound,made:=render.pass_buffer(pass,0,desc)
    if !bound {return}
    if made {render.pass_buffer_fill(pass,desc,0,desc.size)}
    at:=((f.written-1)&1)*bytes
    if !render.pass_buffer_write(pass,desc,at,raw_data(f.texels),int(bytes)) {return}
    texture:=render.Table_Texture_Desc{name=TRAMPLE_TEXTURE,width=TRAMPLE_SIDE,height=TRAMPLE_SIDE}
    render.pass_table_texture_copy(pass,desc,at,texture)
    texture.name=TRAMPLE_BEFORE
    render.pass_table_texture_copy(pass,desc,bytes-at,texture)
}
