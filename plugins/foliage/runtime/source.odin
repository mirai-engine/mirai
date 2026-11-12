package foliage

import "base:runtime"
import "core:math"
import "core:slice"
import "mirai:asset"
import render "mirai:engine/render"
import "mirai:std/base"
import "mirai:std/geom"
import "mirai:std/serial"

// The .foliage asset of a scene: the types of foliage and, by cells of
// CELL_SIZE metres across x and z in the space of the entity that shows it,
// three layers of instances. Manual instances are stored, each with an id
// that is its own while the source keeps it, wherever it moves, and is never
// given again. Generated ones are not: a generator makes them again from the
// seed for each cell that asks for them, each with an id that stays while the
// generator makes it (the cell, the type and its point). Overrides change a
// generated instance by that id: they take it out, move it or put another in
// its place. An override whose id the generator no longer makes is kept, as
// an orphan. A cell that generates may say how much of the density of its
// types it generates where, on a grid over it.

VERSION :: 4
CELL_SIZE :: f32(32)    // metres across x and z of a cell
TYPES_MAX :: 1024
CELLS_MAX :: 1 << 20
INSTANCES_MAX :: 1 << 26 // manual instances and overrides of a source, each
COORD_MAX :: 1 << 24     // of a cell, in cells from the origin of its entity
POSITION_MAX :: f32(1e6) // metres above or below the plane of the entity
RADIUS_MAX :: CELL_SIZE/4 // metres of the radius of a type at its highest scale
DENSITY_SAMPLES :: 17     // per side of the density of a cell, CELL_SIZE/16 apart: its corners and borders included

Foliage_Info :: struct {
    seed:u32,      // of the generated instances
    revision:u32,  // of the saved data
    next_type:u32, // the id the next type takes: an id is never given twice
    instances:u32, // the ids given to manual instances: the next takes one more
}

Foliage_Collision :: enum u8 {
    None,
    Capsule, // along y, standing on the instance: size.x radius, size.y height
    Box,     // standing on the instance: size the sides
}

// A type of foliage: what it shows, how the generator scatters it and how it
// is drawn and collides. It references a .mesh or a prefab and changes neither.
Foliage_Type :: struct {
    id:u32,                     // stable: generated instances and overrides name the type by it
    name:[32]u8 `mirai:"text"`,
    mesh:base.Asset_Id,
    materials:[render.MATERIAL_SLOTS]base.Asset_Id, // by slot of its mesh, instead of the mesh's; none: the mesh's
    prefab:base.Asset_Id,       // its meshes, when it has no mesh of its own
    density:f32 `mirai:"min=0,unit=1/m2"`, // generated instances per square metre
    radius:f32 `mirai:"min=0,unit=m"`, // at scale 1: a generated instance stands no nearer to another of a type with a radius than both radii; 0: anywhere
    scale:[2]f32 `mirai:"min=0"`,  // across x and z: lowest and highest
    height:[2]f32 `mirai:"min=0"`, // along y, times the scale across: lowest and highest
    yaw:f32 `mirai:"angle"`,       // a turn around y of up to this, at random
    tilt:f32 `mirai:"angle"`,      // a lean of up to this, at random
    align:f32 `mirai:"min=0,max=1"`, // how much it leans with the ground under it
    offset:[2]f32 `mirai:"unit=m"`, // along y of the instance, at random: lowest and highest
    rule:Foliage_Rule,
    fade_distance:f32 `mirai:"min=0,unit=m"`, // from the eye, where it starts to fade out
    cull_distance:f32 `mirai:"min=0,unit=m"`, // where it is gone; 0: never
    wind:f32 `mirai:"min=0"`,      // how much the wind moves it; its vertex colors weigh it
    casts_shadow:bool,
    ray_visible:bool,              // reflections and the indirect light see it
    impostor_distance:f32 `mirai:"min=0,unit=m"`, // from the eye, where its mesh gives way to its impostor and its shadows to its crown; 0: none
    wind_variants:u32 `mirai:"max=16"`, // the swaying shapes of a type that casts shadows, each instance on one; 0: WIND_VARIANTS
    collision:Foliage_Collision,
    size:[3]f32 `mirai:"min=0,unit=m"`, // of its collision, at scale 1
    preset:u32,                    // the Collision_Preset of its collision
}

// Where a type stands: the slope and height of the ground in their ranges,
// and the layers of the terrain under it with at least weight of them, where
// its generated instances are as dense as those layers are there.
Foliage_Rule :: struct {
    enabled:bool,
    slope:[2]f32 `mirai:"angle"`,   // from horizontal: lowest and highest
    height:[2]f32 `mirai:"unit=m"`, // of the ground in the space of the entity: lowest and highest
    layers:u32,                     // bits of the layers of the terrain it stands on; 0: any
    weight:f32 `mirai:"min=0,max=1"`, // of those layers together, at least
}
RULE_LAYERS :: 4 // the bits of Foliage_Rule.layers, as the layers of a terrain

FOLIAGE_TYPE_DEFAULT :: Foliage_Type{density=0.5,scale={0.8,1.2},height={1,1},yaw=6.2831855,align=1,cull_distance=120,fade_distance=100,wind=1,size={0.3,2,0},rule={slope={0,math.PI/2},height={-POSITION_MAX,POSITION_MAX},weight=0.5}}

Foliage_Cell :: struct {
    coord:[2]i32,  // along x and z, in cells
    generate:bool, // the generator scatters its types in it
    manual_first,manual_count:u32,
    override_first,override_count:u32,
    density_first,density_count:u32, // of the bytes of densities: none or DENSITY_SAMPLES squared
}

INSTANCE_GROUNDED :: u32(1) // placed on the ground: `ground` is how far above it
INSTANCE_ALIGNED :: u32(2)  // of one grounded: its rotation is from the ground under it, which leans it as much as its type aligns

// An instance of a cell: where it is from the corner of its cell, its
// rotation (quat_pack of std/math, 10 bits), its scale across and along y.
Foliage_Instance :: struct {
    id:u32,        // of a manual one, from 1 (Foliage_Info.instances); 0 in an override
    type:u32,
    flags:u32,
    position:[3]f32,
    rotation:u32,
    scale:[2]f32,
    ground:f32 `mirai:"unit=m"`, // with INSTANCE_GROUNDED, its height over the ground it was placed on
}

Override_Kind :: enum u8 {
    Deleted,  // the generated instance is not there
    Moved,    // it is where instance says, with its type
    Replaced, // instance, of its own type, is there instead
}

// What changes the generated instance `point` of type `type` of its cell.
Foliage_Override :: struct {
    type:u32,
    point:u32,
    kind:Override_Kind,
    instance:Foliage_Instance,
}

// A cell in memory: its instances and its overrides, in the order of their
// type and point. version: what foliage_load gives a cell whose content
// changed when its file was read again, which the batches built from it compare.
Cell :: struct {
    coord:[2]i32,
    generate:bool,
    version:u32,
    manual:[dynamic]Foliage_Instance,
    overrides:[dynamic]Foliage_Override,
    // Of one that generates, how much of the density of its types, from 0 to
    // 255, on DENSITY_SAMPLES by DENSITY_SAMPLES points over it, x first;
    // none: all of it everywhere. Some of it is above 0.
    density:[dynamic]u8,
}

// A .foliage in memory. Cells are in the order of their coordinates, z then x.
Source :: struct {
    info:Foliage_Info,
    types:[dynamic]Foliage_Type,
    cells:[dynamic]Cell,
}

source_destroy :: proc(s:^Source) {
    for &cell in s.cells {delete(cell.manual);delete(cell.overrides);delete(cell.density)}
    delete(s.types);delete(s.cells)
    s^={}
}

source_type :: proc "contextless" (s:^Source,id:u32) -> (^Foliage_Type,int) {
    for &t,i in s.types {if t.id==id {return &t,i}}
    return nil,-1
}

// A new type with the next id; its defaults are FOLIAGE_TYPE_DEFAULT. nil
// without memory, with the source as it was.
source_type_add :: proc(s:^Source,name:string,mesh:base.Asset_Id) -> ^Foliage_Type {
    t:=FOLIAGE_TYPE_DEFAULT
    t.id=s.info.next_type
    t.mesh=mesh
    base.text_set(t.name[:],name)
    if _,err:=append(&s.types,t);err!=nil {return nil}
    s.info.next_type+=1
    return &s.types[len(s.types)-1]
}

// Takes a type out with what shows it: its manual instances and the
// overrides of its generated ones. A generated instance another type
// replaced with one of it is Deleted. False when there is no such type.
source_type_remove :: proc(s:^Source,id:u32) -> bool {
    _,index:=source_type(s,id)
    if index<0 {return false}
    ordered_remove(&s.types,index)
    for &cell in s.cells {
        kept:=0
        for instance in cell.manual {if instance.type!=id {cell.manual[kept]=instance;kept+=1}}
        base.truncate(&cell.manual,kept)
        kept=0
        for override in cell.overrides {
            if override.type==id {continue}
            o:=override
            if o.kind==.Replaced && o.instance.type==id {o.kind,o.instance=.Deleted,{}}
            cell.overrides[kept]=o;kept+=1
        }
        base.truncate(&cell.overrides,kept)
    }
    return true
}

// The cell a point of the space of the entity is in, and where it is from its corner.
cell_of :: proc "contextless" (position:[3]f32) -> (coord:[2]i32,local:[3]f32) {
    floor :: proc "contextless" (v:f32) -> i32 {i:=i32(v);return i-1 if f32(i)>v else i}
    coord={floor(position.x/CELL_SIZE),floor(position.z/CELL_SIZE)}
    local={position.x-f32(coord.x)*CELL_SIZE,position.y,position.z-f32(coord.y)*CELL_SIZE}
    // What rounds to the far side belongs to the cell after.
    for axis in 0..<2 {
        at:=0 if axis==0 else 2
        if local[at]>=CELL_SIZE {coord[axis]+=1;local[at]-=CELL_SIZE}
        if local[at]<0 {local[at]=0}
    }
    return
}

cell_corner :: proc "contextless" (coord:[2]i32) -> [3]f32 {return {f32(coord.x)*CELL_SIZE,0,f32(coord.y)*CELL_SIZE}}

@(private)
coord_before :: proc "contextless" (a,b:[2]i32) -> bool {return a.y<b.y || a.y==b.y && a.x<b.x}

// The cell of a coordinate, made when it is not there and `make_it`.
source_cell :: proc(s:^Source,coord:[2]i32,make_it:=false) -> ^Cell {
    low,high:=0,len(s.cells)
    for low<high {
        mid:=(low+high)/2
        if coord_before(s.cells[mid].coord,coord) {low=mid+1} else {high=mid}
    }
    if low<len(s.cells) && s.cells[low].coord==coord {return &s.cells[low]}
    if !make_it {return nil}
    inject_at(&s.cells,low,Cell{coord=coord})
    return &s.cells[low]
}

// Raises (on) or lowers the density the cells generate with under a disc
// around center, in x and z: to all of it, or by all of it, within hardness
// of its radius, and less toward its border (geom.Falloff.Smooth), so that
// lowering takes away what the same disc raised. A
// cell that comes to generate all of it everywhere keeps no grid of it; one
// that comes to generate none stops generating, and goes when it holds
// nothing else. True when one changed; false also without memory, with the
// cells as they were.
source_generate_area :: proc(s:^Source,center:[3]f32,radius:f32,on:bool,hardness:f32) -> (changed:bool) {
    if !(radius>0) {return}
    n:=DENSITY_SAMPLES
    step:=CELL_SIZE/f32(n-1)
    low,_:=cell_of(center-{radius,0,radius})
    high,_:=cell_of(center+{radius,0,radius})
    mask:[DENSITY_SAMPLES*DENSITY_SAMPLES]u8
    for z in low.y..=high.y {for x in low.x..=high.x {
        cell:=source_cell(s,{x,z})
        if cell==nil && !on {continue}
        full:=cell!=nil && cell.generate && len(cell.density)!=n*n
        for &v,k in mask {
            v=cell!=nil && cell.generate && len(cell.density)==n*n?cell.density[k]:(full?255:0)
        }
        corner:=cell_corner({x,z})
        for &v,k in mask {
            d:=corner.xz+{f32(k%n),f32(k/n)}*step-center.xz
            w:=geom.falloff_weight(.Smooth,hardness,math.sqrt(d.x*d.x+d.y*d.y)/radius)
            if w<=0 {continue}
            change:=u8(w*255+0.5)
            v=on?max(v,change):v-min(v,change)
        }
        changed|=cell_density_set(s,{x,z},mask[:])
    }}
    return
}

// Gives a cell the density it generates with (DENSITY_SAMPLES squared, as
// Cell.density): all of it is no grid, none stops the generator there.
// True when it changed.
cell_density_set :: proc(s:^Source,coord:[2]i32,mask:[]u8) -> bool {
    some,all:=false,true
    for v in mask {some|=v>0;all&=v==255}
    if !some {return source_cell_generate(s,coord,false)}
    cell:=source_cell(s,coord,true)
    if cell==nil {return false}
    if all {
        if cell.generate && len(cell.density)==0 {return false}
        clear(&cell.density)
        cell.generate=true
        return true
    }
    if cell.generate && slice.equal(cell.density[:],mask) {return false}
    if resize(&cell.density,len(mask))!=nil {return false}
    copy(cell.density[:],mask)
    cell.generate=true
    return true
}

// Turns the generator of a cell on or off, with all of the density of its
// types everywhere: on makes the cell, and off takes out one that holds
// nothing else. False when it already was so.
source_cell_generate :: proc(s:^Source,coord:[2]i32,on:bool) -> bool {
    cell:=source_cell(s,coord,on)
    if cell==nil || cell.generate==on && len(cell.density)==0 {return false}
    cell.generate=on
    clear(&cell.density)
    if on || len(cell.manual)>0 || len(cell.overrides)>0 {return true}
    for &held,i in s.cells {
        if &held!=cell {continue}
        delete(held.manual);delete(held.overrides);delete(held.density)
        ordered_remove(&s.cells,i)
        break
    }
    return true
}

// Adds a manual instance at a point of the space of the entity, to the cell
// it falls in, with the next id; its cell and its id, 0 when the ids of the
// source ran out.
source_instance_add :: proc(s:^Source,type:u32,position:[3]f32,rotation:u32,scale:[2]f32,flags:u32=0,ground:f32=0) -> (coord:[2]i32,id:u32) {
    local:[3]f32
    coord,local=cell_of(position)
    if s.info.instances==max(u32) {return}
    s.info.instances+=1
    id=s.info.instances
    cell:=source_cell(s,coord,true)
    append(&cell.manual,Foliage_Instance{id=id,type=type,flags=flags,position=local,rotation=rotation,scale=scale,ground=ground})
    return
}

// The index in its cell of the manual instance of an id; -1 for none.
manual_find :: proc "contextless" (cell:^Cell,id:u32) -> int {
    if cell==nil || id==0 {return -1}
    for b,i in cell.manual {if b.id==id {return i}}
    return -1
}

@(private)
override_before :: proc "contextless" (a:Foliage_Override,type,point:u32) -> bool {return a.type<type || a.type==type && a.point<point}

// The first override of a cell at or after (type, point), in their order.
override_lower :: proc "contextless" (cell:^Cell,type,point:u32) -> int {
    low,high:=0,len(cell.overrides)
    for low<high {
        mid:=(low+high)/2
        if override_before(cell.overrides[mid],type,point) {low=mid+1} else {high=mid}
    }
    return low
}

// The override of the generated instance (type, point) of a cell; -1 for none.
override_find :: proc "contextless" (cell:^Cell,type,point:u32) -> int {
    at:=override_lower(cell,type,point)
    if at<len(cell.overrides) && cell.overrides[at].type==type && cell.overrides[at].point==point {return at}
    return -1
}

// Gives the generated instance (type, point) of a cell an override, which
// replaces the one it had.
source_override_set :: proc(s:^Source,coord:[2]i32,override:Foliage_Override) {
    cell:=source_cell(s,coord,true)
    at:=override_lower(cell,override.type,override.point)
    if at<len(cell.overrides) && cell.overrides[at].type==override.type && cell.overrides[at].point==override.point {cell.overrides[at]=override;return}
    inject_at(&cell.overrides,at,override)
}

// Takes the override of (type, point) out of a cell: the generator's instance is back.
source_override_remove :: proc(s:^Source,coord:[2]i32,type,point:u32) -> bool {
    cell:=source_cell(s,coord)
    if cell==nil {return false}
    at:=override_find(cell,type,point)
    if at<0 {return false}
    ordered_remove(&cell.overrides,at)
    return true
}

// Takes the manual instance of an id out of its cell; the others keep their order.
source_instance_remove :: proc(s:^Source,coord:[2]i32,id:u32) -> bool {
    cell:=source_cell(s,coord)
    index:=manual_find(cell,id)
    if index<0 {return false}
    ordered_remove(&cell.manual,index)
    return true
}

@(private)
finite :: proc "contextless" (v:f32) -> bool {return v-v==0}

@(private)
type_valid :: proc (type:Foliage_Type,next:u32) -> bool {
    t:=type
    if t.id>=next || len(serial.text_field(t.name[:]))>=len(t.name) {return false}
    values:=[?]f32{t.density,t.scale[0],t.scale[1],t.height[0],t.height[1],t.yaw,t.tilt,t.align,t.fade_distance,t.cull_distance,t.wind,t.size.x,t.size.y,t.size.z,t.impostor_distance}
    for v in values {if !finite(v) || v<0 {return false}}
    if !finite(t.radius) || t.radius<0 || t.radius*t.scale[1]>RADIUS_MAX {return false}
    if t.density>1000 || t.scale[0]<=0 || t.scale[1]<t.scale[0] || t.height[0]<=0 || t.height[1]<t.height[0] || t.align>1 {return false}
    if t.scale[1]>1000 || t.height[1]>1000 || t.collision>max(Foliage_Collision) || t.wind_variants>WIND_VARIANTS_MAX {return false}
    r:=t.rule
    for v in ([7]f32{t.offset.x,t.offset.y,r.slope.x,r.slope.y,r.height.x,r.height.y,r.weight}) {if !finite(v) {return false}}
    if t.offset.x>t.offset.y || abs(t.offset.x)>POSITION_MAX || abs(t.offset.y)>POSITION_MAX {return false}
    if r.slope.x<0 || r.slope.x>r.slope.y || r.slope.y>math.PI/2+1e-4 || r.height.x>r.height.y || abs(r.height.x)>POSITION_MAX || abs(r.height.y)>POSITION_MAX {return false}
    return r.weight>=0 && r.weight<=1 && r.layers>>RULE_LAYERS==0
}

// Whether a type stands at a point of its ground: its rule (when on) with the
// height, the normal and the weights of the ground there. With layers, an
// instance whose chance (0 to 1) is not under their weight there is not
// there either: their density follows that weight.
rule_allows :: proc "contextless" (t:Foliage_Type,height:f32,normal:[3]f32,weights:[4]f32,weights_known:bool,chance:f32=0) -> bool {
    r:=t.rule
    if !r.enabled {return true}
    slope:=math.acos(clamp(normal.y,-1,1))
    if !(slope>=r.slope.x && slope<=r.slope.y && height>=r.height.x && height<=r.height.y) {return false}
    if r.layers==0 {return true}
    if !weights_known {return false}
    sum:f32
    for i in 0..<RULE_LAYERS {if r.layers&(1<<u32(i))!=0 {sum+=weights[i]}}
    // Within half a step of the 255 of the weights: a full layer between samples takes weight 1.
    return sum+0.5/255>=max(r.weight,chance)
}

@(private)
instance_valid :: proc "contextless" (b:Foliage_Instance) -> bool {
    p:=b.position
    if !finite(p.x) || !finite(p.y) || !finite(p.z) || !finite(b.ground) {return false}
    if p.x<0 || p.x>=CELL_SIZE || p.z<0 || p.z>=CELL_SIZE || abs(p.y)>POSITION_MAX {return false}
    return finite(b.scale[0]) && finite(b.scale[1]) && b.scale[0]>0 && b.scale[1]>0 && b.scale[0]<=1000 && b.scale[1]<=1000 && b.flags&~(INSTANCE_GROUNDED|INSTANCE_ALIGNED)==0 && (b.flags&INSTANCE_ALIGNED==0 || b.flags&INSTANCE_GROUNDED!=0)
}

// Whether a source can be saved and shown: what source_read checks of a file.
source_valid :: proc (s:^Source) -> bool {
    if len(s.types)>TYPES_MAX || len(s.cells)>CELLS_MAX {return false}
    for t,i in s.types {
        if !type_valid(t,s.info.next_type) {return false}
        for other in s.types[:i] {if other.id==t.id {return false}}
    }
    manual,overrides:=0,0
    for cell,i in s.cells {
        if abs(cell.coord.x)>COORD_MAX || abs(cell.coord.y)>COORD_MAX {return false}
        if i>0 && !coord_before(s.cells[i-1].coord,cell.coord) {return false}
        for b in cell.manual {
            if !instance_valid(b) || b.id==0 || b.id>s.info.instances {return false}
            if t,_:=source_type(s,b.type);t==nil {return false}
        }
        for o,k in cell.overrides {
            if o.kind>max(Override_Kind) || o.type>=s.info.next_type || o.instance.id!=0 {return false}
            if k>0 && !override_before(cell.overrides[k-1],o.type,o.point) {return false}
            if o.kind!=.Deleted && !instance_valid(o.instance) {return false}
            if o.kind==.Replaced {if t,_:=source_type(s,o.instance.type);t==nil {return false}}
        }
        if len(cell.density)!=0 && (len(cell.density)!=DENSITY_SAMPLES*DENSITY_SAMPLES || !cell.generate) {return false}
        some:=len(cell.density)==0
        for v in cell.density {some|=v>0}
        if !some {return false}
        manual+=len(cell.manual)
        overrides+=len(cell.overrides)
    }
    if manual>INSTANCES_MAX || overrides>INSTANCES_MAX {return false}
    // No two manual instances share an id, in a cell or across cells.
    ids:=make([]u32,manual,context.temp_allocator)
    manual=0
    for cell in s.cells {for b in cell.manual {ids[manual]=b.id;manual+=1}}
    slice.sort(ids)
    for i in 1..<len(ids) {if ids[i]==ids[i-1] {return false}}
    return true
}

// The .foliage file of a source, as bytes from allocator; with import_info, the
// record of the import it comes from.
source_bytes :: proc(s:^Source,id:base.Asset_Id,types:^asset.Types,allocator:=context.allocator,import_info:^asset.Import_Info=nil) -> (data:[]u8,error:asset.Error) {
    if !source_valid(s) {return nil,.Invalid}
    manual,overrides,densities:=0,0,0
    for cell in s.cells {manual+=len(cell.manual);overrides+=len(cell.overrides);densities+=len(cell.density)}
    cells,e1:=make([]Foliage_Cell,len(s.cells),context.temp_allocator)
    density:=make([dynamic]u8,0,densities,context.temp_allocator)
    instances,e2:=make([]u8,manual*INSTANCE_BYTES,context.temp_allocator)
    changes,e3:=make([]u8,overrides*OVERRIDE_BYTES,context.temp_allocator)
    if e1!=nil || e2!=nil || e3!=nil {return nil,.Out_Of_Memory}
    manual_planes:=Planes(INSTANCE_WORDS){data=instances,count=manual}
    override_planes:=Planes(OVERRIDE_WORDS){data=changes,count=overrides}
    manual,overrides=0,0
    for cell,i in s.cells {
        cells[i]={coord=cell.coord,generate=cell.generate,manual_first=u32(manual),manual_count=u32(len(cell.manual)),override_first=u32(overrides),override_count=u32(len(cell.overrides)),density_first=u32(len(density)),density_count=u32(len(cell.density))}
        append(&density,..cell.density[:])
        manual_planes.in_cell,override_planes.in_cell=false,false
        for b in cell.manual {planes_put(&manual_planes,INSTANCE_CODES,manual,instance_words(b));manual+=1}
        for o in cell.overrides {planes_put(&override_planes,OVERRIDE_CODES,overrides,override_words(o));overrides+=1}
    }
    document:asset.Document
    asset.document_init(&document,FOLIAGE_KIND,id,allocator)
    defer asset.document_destroy(&document)
    document.kind_version=VERSION
    info:=s.info
    asset.document_put_row(&document,types,"foliage",&info) or_return
    asset.document_put(&document,types,"types",s.types[:]) or_return
    asset.document_put(&document,types,"cells",cells) or_return
    asset.document_put(&document,types,"manual",instances,{.Bulk},.Stream) or_return
    asset.document_put(&document,types,"overrides",changes,{.Bulk},.Stream) or_return
    asset.document_put(&document,types,"density",density[:],{.Bulk},.Stream) or_return
    asset.import_put(&document,types,import_info) or_return
    return asset.document_bytes(&document,allocator)
}

// How the file stores the manual instances and the overrides: the records of
// each, cell after cell, as words of 4 bytes split into byte planes (byte j of
// every record, then byte j+1), each word coded as its field compresses best.
// Every bit pattern comes back as it was.
@(private)
Code :: enum u8 {
    Plain,
    Id,       // less that of the record before it in the file, zigzag: ids given in turn are 1 apart
    Near,     // less that of the record before it in its cell, zigzag: neighbours share their high bits
    Rotation, // quat_pack of 10 bits with the low bytes of its components apart from their high bits
}
INSTANCE_WORDS :: 10 // id, type, flags, position, rotation, scale, ground
OVERRIDE_WORDS :: 3+INSTANCE_WORDS // type, point, kind, the instance
INSTANCE_BYTES :: INSTANCE_WORDS*4
OVERRIDE_BYTES :: OVERRIDE_WORDS*4
@(private) INSTANCE_CODES :: [INSTANCE_WORDS]Code{.Id,.Plain,.Plain,.Near,.Near,.Near,.Rotation,.Plain,.Plain,.Plain}
@(private) OVERRIDE_CODES :: [OVERRIDE_WORDS]Code{.Plain,.Near,.Plain,.Id,.Plain,.Plain,.Near,.Near,.Near,.Rotation,.Plain,.Plain,.Plain}

@(private)
Planes :: struct($N:int) {
    data:[]u8,    // N*4 planes of count bytes
    count:int,
    last:[N]u32,  // the words of the record before, in the file
    in_cell:bool, // that record is of the same cell
}

@(private)
instance_words :: proc "contextless" (b:Foliage_Instance) -> [INSTANCE_WORDS]u32 {
    return {b.id,b.type,b.flags,transmute(u32)b.position.x,transmute(u32)b.position.y,transmute(u32)b.position.z,b.rotation,transmute(u32)b.scale[0],transmute(u32)b.scale[1],transmute(u32)b.ground}
}

@(private)
instance_of_words :: proc "contextless" (w:[]u32) -> Foliage_Instance {
    return {id=w[0],type=w[1],flags=w[2],position={transmute(f32)w[3],transmute(f32)w[4],transmute(f32)w[5]},rotation=w[6],scale={transmute(f32)w[7],transmute(f32)w[8]},ground=transmute(f32)w[9]}
}

@(private)
override_words :: proc "contextless" (o:Foliage_Override) -> (w:[OVERRIDE_WORDS]u32) {
    w[0],w[1],w[2]=o.type,o.point,u32(o.kind)
    instance:=instance_words(o.instance)
    copy(w[3:],instance[:])
    return
}

@(private)
word_code :: proc "contextless" (code:Code,v,last:u32,in_cell:bool) -> u32 {
    zigzag :: proc "contextless" (v:u32) -> u32 {s:=i32(v);return u32(s<<1~s>>31)}
    switch code {
    case .Plain:
    case .Id: return zigzag(v-last)
    case .Near: if in_cell {return zigzag(v-last)}
    case .Rotation: return v&0xff|(v>>10&0xff)<<8|(v>>20&0xff)<<16|(v>>8&3)<<24|(v>>18&3)<<26|(v>>28)<<28
    }
    return v
}

@(private)
word_decode :: proc "contextless" (code:Code,c,last:u32,in_cell:bool) -> u32 {
    unzigzag :: proc "contextless" (c:u32) -> u32 {return c>>1~(0-(c&1))}
    switch code {
    case .Plain:
    case .Id: return last+unzigzag(c)
    case .Near: if in_cell {return last+unzigzag(c)}
    case .Rotation: return c&0xff|(c>>24&3)<<8|(c>>8&0xff)<<10|(c>>26&3)<<18|(c>>16&0xff)<<20|(c>>28)<<28
    }
    return c
}

// Record i of the planes, from its words.
@(private)
planes_put :: proc "contextless" (p:^Planes($N),codes:[N]Code,i:int,words:[N]u32) {
    codes:=codes
    for w,k in words {
        c:=word_code(codes[k],w,p.last[k],p.in_cell)
        for b in 0..<4 {p.data[(k*4+b)*p.count+i]=u8(c>>(uint(b)*8))}
    }
    p.last,p.in_cell=words,true
}

// The words of record i of the planes, after the one before it.
@(private)
planes_get :: proc "contextless" (p:^Planes($N),codes:[N]Code,i:int) -> [N]u32 {
    codes:=codes
    words:[N]u32
    for &w,k in words {
        c:u32
        for b in 0..<4 {c|=u32(p.data[(k*4+b)*p.count+i])<<(uint(b)*8)}
        w=word_decode(codes[k],c,p.last[k],p.in_cell)
    }
    p.last,p.in_cell=words,true
    return words
}

@(private)
rows_or_none :: proc(file:^asset.Asset,types:^asset.Types,name:string,$T:typeid) -> (rows:[]T,ok:bool) {
    found,error:=asset.asset_rows(file,types,name,"",T)
    if error==.Not_Found {return nil,true}
    return found,error==.None
}

// The source an open .foliage holds, checked whole: s is replaced only by a
// valid one. Its id, or false.
source_read :: proc(s:^Source,file:^asset.Asset,types:^asset.Types,allocator:=context.allocator) -> (id:base.Asset_Id,ok:bool) {
    if asset.kind_check(file,FOLIAGE_KIND,VERSION)!=.None {return}
    info,error:=asset.asset_row(file,types,"foliage",Foliage_Info)
    if error!=.None || info==nil {return}
    kinds:=rows_or_none(file,types,"types",Foliage_Type) or_return
    cells:=rows_or_none(file,types,"cells",Foliage_Cell) or_return
    manual_bytes:=rows_or_none(file,types,"manual",u8) or_return
    override_bytes:=rows_or_none(file,types,"overrides",u8) or_return
    density:=rows_or_none(file,types,"density",u8) or_return
    manual,overrides:=len(manual_bytes)/INSTANCE_BYTES,len(override_bytes)/OVERRIDE_BYTES
    if manual*INSTANCE_BYTES!=len(manual_bytes) || overrides*OVERRIDE_BYTES!=len(override_bytes) {return}
    if len(kinds)>TYPES_MAX || len(cells)>CELLS_MAX || manual>INSTANCES_MAX || overrides>INSTANCES_MAX {return}
    // The ranges of the cells follow each other and cover every record once.
    next_manual,next_override,next_density:=u32(0),u32(0),u32(0)
    for cell in cells {
        if cell.manual_first!=next_manual || cell.override_first!=next_override || cell.density_first!=next_density {return}
        if u64(cell.manual_first)+u64(cell.manual_count)>u64(manual) || u64(cell.override_first)+u64(cell.override_count)>u64(overrides) {return}
        if cell.density_count!=0 && cell.density_count!=DENSITY_SAMPLES*DENSITY_SAMPLES || u64(cell.density_first)+u64(cell.density_count)>u64(len(density)) {return}
        next_manual+=cell.manual_count
        next_override+=cell.override_count
        next_density+=cell.density_count
    }
    if int(next_manual)!=manual || int(next_override)!=overrides || int(next_density)!=len(density) {return}
    manual_planes:=Planes(INSTANCE_WORDS){data=manual_bytes,count=manual}
    override_planes:=Planes(OVERRIDE_WORDS){data=override_bytes,count=overrides}
    temporary:Source
    context.allocator=allocator
    temporary.info=info^
    if !reserved(&temporary.types,len(kinds)) || !reserved(&temporary.cells,len(cells)) {source_destroy(&temporary);return}
    append(&temporary.types,..kinds)
    for cell in cells {
        held:=Cell{coord=cell.coord,generate=cell.generate}
        if !reserved(&held.manual,int(cell.manual_count)) || !reserved(&held.overrides,int(cell.override_count)) || !reserved(&held.density,int(cell.density_count)) {
            delete(held.manual);delete(held.overrides);delete(held.density)
            source_destroy(&temporary)
            return
        }
        append(&held.density,..density[cell.density_first:][:cell.density_count])
        if _,err:=append(&temporary.cells,held);err!=nil {
            delete(held.manual);delete(held.overrides);delete(held.density)
            source_destroy(&temporary)
            return
        }
        added:=&temporary.cells[len(temporary.cells)-1]
        manual_planes.in_cell,override_planes.in_cell=false,false
        for i in cell.manual_first..<cell.manual_first+cell.manual_count {
            words:=planes_get(&manual_planes,INSTANCE_CODES,int(i))
            append(&added.manual,instance_of_words(words[:]))
        }
        for i in cell.override_first..<cell.override_first+cell.override_count {
            w:=planes_get(&override_planes,OVERRIDE_CODES,int(i))
            if w[2]>u32(max(Override_Kind)) {source_destroy(&temporary);return}
            append(&added.overrides,Foliage_Override{type=w[0],point=w[1],kind=Override_Kind(w[2]),instance=instance_of_words(w[3:])})
        }
        slice.sort_by(added.overrides[:],proc(a,b:Foliage_Override) -> bool {return override_before(a,b.type,b.point)})
    }
    if !source_valid(&temporary) {source_destroy(&temporary);return}
    source_destroy(s)
    s^=temporary
    return file.blob.header.id,true
}

@(private)
reserved :: proc(array:^[dynamic]$T,count:int) -> bool {
    if count==0 {return true}
    return reserve(array,count)==runtime.Allocator_Error.None
}
