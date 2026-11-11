package effect

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/serial"

// .particle, the asset of the vfx plugin: an effect of particles, as a
// material is a look. The entities that show it name it and give it values
// of their own.
//
//   particle    Particle_Info, one row
//   parameters  Particle_Parameter: values for its Vfx program, by name
//   hidden      Particle_Field: fields an instance does not show
//
// A field of an instance is named by its path in Particle_Info: field names
// and array indices joined by dots ("lifetime", "colors.1",
// "bursts.0.count", "size_over_life.values.2"). particle_fields lists the
// paths an instance can change, each a value of at most PARTICLE_VALUE_BYTES;
// text fields (the program) are of the effect alone.

VERSION :: 4
PARTICLE_BURSTS :: 4
PARTICLE_CURVE_KEYS :: 8
PARTICLE_VALUE_BYTES :: 16
PARTICLE_NAME_BYTES :: 64
PARTICLE_MAX_PARAMETERS :: 32

Particle_Shape :: enum u32 {Point,Sphere,Hemisphere,Cone,Box,Circle,Line,Surface,Bones}
Particle_Render :: enum u32 {Billboard,Velocity,Horizontal,Ribbon,Mesh}
Particle_Blend :: enum u32 {Additive,Alpha}
Particle_Collision :: enum u32 {None,World}
Particle_Event :: enum u32 {None,Death,Collision}

// Particles started at once, when the cycle reaches time. cycles above one
// repeat it every interval seconds.
Particle_Burst :: struct {
    time:f32 `mirai:"min=0,unit=s"`,
    count:u32,
    cycles:u32,
    interval:f32 `mirai:"min=0,unit=s"`,
}

// A value over the life of a particle:
// piecewise linear between keys at ascending times from 0 to 1. Keys past the
// last one used repeat it at time 1.
Particle_Curve :: struct {
    values:[PARTICLE_CURVE_KEYS]f32,
    times:[PARTICLE_CURVE_KEYS]f32 `mirai:"min=0,max=1"`,
}

Particle_Gradient :: struct {
    colors:[PARTICLE_CURVE_KEYS][4]f32 `mirai:"color"`,
    times:[PARTICLE_CURVE_KEYS]f32 `mirai:"min=0,max=1"`,
}

// The shape faces +Y of the entity, where a cone opens; the particles leave
// it along its normal, or along +Y from a box and a line. A Surface starts
// them on the triangles of a mesh, by their area, and they leave along its
// normal with the velocity of the surface times inherit_velocity. Bones
// starts them on the bones of a skinned mesh, by their length, away from the
// bone by up to shape_size.x as shell says, with the velocity of the bone.
Particle_Info :: struct {
    duration:f32 `mirai:"min=0,unit=s"`,      // of a cycle
    prewarm:bool,                             // a looping instance starts as if it had run a whole life
    max_particles:u32,                        // alive at once; 0: what the rate, the bursts and the lifetime need
    rate:f32 `mirai:"min=0,unit=1/s"`,
    rate_over_distance:f32 `mirai:"min=0,unit=1/m"`, // per metre the entity travels
    bursts:[PARTICLE_BURSTS]Particle_Burst,
    shape:Particle_Shape,
    shape_size:[3]f32 `mirai:"min=0,unit=m"`, // radius in x, half extents of a box, half length of a line
    shape_angle:f32 `mirai:"angle,min=0"`,    // of a cone, from its axis
    shell:f32 `mirai:"min=0,max=1"`,          // 0: from the volume of the shape, 1: from its surface
    lifetime:[2]f32 `mirai:"min=0,unit=s"`,   // each particle takes a value between both
    speed:[2]f32 `mirai:"unit=m/s"`,          // along the normal of the shape
    velocity:[2][3]f32 `mirai:"unit=m/s"`,    // in the space of the entity, between both, besides speed
    size:[2]f32 `mirai:"min=0,unit=m"`,
    rotation:[2]f32 `mirai:"angle"`,
    spin:[2]f32 `mirai:"angle"`,              // per second
    colors:[2][4]f32 `mirai:"color"`,         // each particle takes a mix
    intensity:f32 `mirai:"min=0"`,            // multiplies the color: above 1 it glows
    emission_mode:asset.Emission_Mode,        // what the color of an unlit particle is: nits, or the value the exposed image shows
    inherit_velocity:f32,                     // share of the velocity of the entity a particle starts with
    local_space:bool,                         // particles move with the entity
    gravity:f32,                              // share of the gravity of where each particle is (volume Gravity)
    acceleration:[3]f32 `mirai:"unit=m/s²"`,
    drag:f32 `mirai:"min=0,unit=1/s"`,
    noise:f32 `mirai:"unit=m/s²"`,            // strength of a turbulent flow
    noise_frequency:f32 `mirai:"min=0,unit=1/m"`,
    noise_speed:f32 `mirai:"unit=1/s"`,
    attractor:[3]f32 `mirai:"unit=m"`,        // a point of the entity that pulls the particles
    attractor_strength:f32 `mirai:"unit=m/s²"`,
    collision:Particle_Collision,             // World: against the traced scene
    bounce:f32 `mirai:"min=0,max=1"`,
    friction:f32 `mirai:"min=0,max=1"`,
    collision_life:f32 `mirai:"min=0,max=1"`, // share of its life a particle loses per hit
    render:Particle_Render,
    blend:Particle_Blend,
    lit:bool,                                 // the sun, the lights and the light probes light it
    lights:u32,                               // of its particles that light the scene, at most
    light_shadows:bool,                       // they cast shadows, within the shadow budgets; else they light all in their range
    light_intensity:f32 `mirai:"min=0,unit=cd"`, // of a particle of full color: its color and opacity tint it
    light_range:f32 `mirai:"min=0,unit=m"`,
    light_radius:f32 `mirai:"min=0,unit=m"`,  // of the sphere that glows; 0: half the size of the particle
    sort:bool,                                // blended particles drawn back to front (2048 at most)
    material:base.Asset_Id,                   // its base color texture is the flipbook; none: a soft puff
    mesh:base.Asset_Id,                       // of Mesh particles; none: a cube
    stretch:f32 `mirai:"min=0,unit=s"`,       // Velocity: seconds of motion a sprite spans
    soft:f32 `mirai:"min=0,unit=m"`,          // a sprite fades over this distance into what is behind it
    flipbook:[2]u32,                          // columns and rows
    flipbook_speed:f32 `mirai:"min=0"`,       // frames per second; 0: the whole flipbook over the life
    size_over_life:Particle_Curve,
    color_over_life:Particle_Gradient,
    trigger:Particle_Event,                   // when sub_particle starts particles where one of these is
    sub_particle:base.Asset_Id,               // a .particle
    sub_count:u32,                            // its particles per event
    report:Particle_Event,                    // what of its particles the game hears of (vfx.Particle_Reports), frames later: presentation alone
    program:[PARTICLE_NAME_BYTES]u8 `mirai:"text"`, // a Vfx program of the shaders; "" for none
}

PARTICLE_CURVE_ONE :: Particle_Curve{values={1,1,1,1,1,1,1,1},times={0,1,1,1,1,1,1,1}}

PARTICLE_DEFAULTS :: Particle_Info{
    duration=2,rate=20,
    shape=.Cone,shape_size={0.1,0.1,0.1},shape_angle=0.35,
    lifetime={1.5,2},speed={1,2},size={0.2,0.35},colors={{1,1,1,1},{1,1,1,1}},intensity=1,emission_mode=.Relative,
    blend=.Alpha,lit=true,light_intensity=100,light_range=4,soft=0.3,flipbook={1,1},
    size_over_life={values={0.5,1,1,1,1,1,1,1},times={0,0.3,1,1,1,1,1,1}},
    color_over_life={
        colors={{1,1,1,0},{1,1,1,1},{1,1,1,1},{1,1,1,0},{1,1,1,0},{1,1,1,0},{1,1,1,0},{1,1,1,0}},
        times={0,0.15,0.7,1,1,1,1,1},
    },
}

Particle_Field :: struct {name:[PARTICLE_NAME_BYTES]u8 `mirai:"text"`}

// A value for a parameter of the Vfx program of the effect, by its name.
Particle_Parameter :: struct {
    name:[PARTICLE_NAME_BYTES]u8 `mirai:"text"`,
    kind:asset.Parameter_Kind,
    components:u8, // 1 to 4; a texture has one
    value:[4]f64,  // every 32-bit integer and float exactly
    texture:base.Asset_Id,
}

Particle_Desc :: struct {
    id:base.Asset_Id,
    info:Particle_Info,
    parameters:[]Particle_Parameter,
    hidden:[]Particle_Field,
    source:^asset.Import_Info, // of an effect an import wrote; nil for one made here
}

Particle_View :: struct {
    info:^Particle_Info,
    parameters:[]Particle_Parameter,
    hidden:[]Particle_Field,
}

particle_document :: proc(doc:^asset.Document,types:^asset.Types,desc:Particle_Desc,allocator:=context.allocator) -> asset.Error {
    info:=desc.info
    if !particle_check({info=&info,parameters=desc.parameters,hidden=desc.hidden}) {return .Invalid}
    asset.document_init(doc,PARTICLE_KIND,desc.id,allocator)
    doc.kind_version=VERSION
    error:=particle_tables(doc,types,&info,desc)
    if error!=.None {asset.document_destroy(doc)}
    return error
}

@(private="file")
particle_tables :: proc(doc:^asset.Document,types:^asset.Types,info:^Particle_Info,desc:Particle_Desc) -> asset.Error {
    asset.document_put_row(doc,types,"particle",info) or_return
    asset.document_put(doc,types,"parameters",desc.parameters) or_return
    asset.document_put(doc,types,"hidden",desc.hidden) or_return
    if desc.source!=nil {asset.import_put(doc,types,desc.source) or_return}
    return .None
}

particle_save :: proc(path:string,types:^asset.Types,desc:Particle_Desc,allocator:=context.allocator) -> asset.Error {
    doc:asset.Document
    particle_document(&doc,types,desc,allocator) or_return
    defer asset.document_destroy(&doc)
    return asset.document_save(&doc,path)
}

// The file of a particle effect, as bytes from allocator.
particle_bytes :: proc(types:^asset.Types,desc:Particle_Desc,allocator:=context.allocator) -> (data:[]u8,error:asset.Error) {
    doc:asset.Document
    particle_document(&doc,types,desc,allocator) or_return
    defer asset.document_destroy(&doc)
    return asset.document_bytes(&doc,allocator)
}

particle_view :: proc(a:^asset.Asset,types:^asset.Types) -> (view:Particle_View,error:asset.Error) {
    asset.kind_check(a,PARTICLE_KIND,VERSION) or_return
    view.info=asset.asset_row(a,types,"particle",Particle_Info,whole=true) or_return
    view.parameters=table_rows(a,types,"parameters",Particle_Parameter) or_return
    view.hidden=table_rows(a,types,"hidden",Particle_Field) or_return
    if !particle_check(view) {return {},.Corrupt}
    return view,.None
}

// What is wrong with the values of an effect: the field and how to correct
// it. An empty message: nothing.
Particle_Problem :: struct {
    field:string,
    message:string,
}

// Values the renderer can take as they are: finite, inside their ranges,
// with enums it knows, curves that go forward and names that end.
particle_validate :: proc(view:Particle_View) -> Particle_Problem {
    p:=view.info
    if p==nil {return {"particle","Give the values of the effect"}}
    if field,ok:=particle_finite(p);!ok {return {field,"Use finite numbers"}}
    if p.shape>max(Particle_Shape) {return {"shape","Use Point, Sphere, Hemisphere, Cone, Box, Circle, Line, Surface or Bones"}}
    if p.render>max(Particle_Render) {return {"render","Use Billboard, Velocity, Horizontal, Ribbon or Mesh"}}
    if p.blend>max(Particle_Blend) {return {"blend","Use Additive or Alpha"}}
    if p.collision>max(Particle_Collision) {return {"collision","Use None or World"}}
    if p.trigger>max(Particle_Event) {return {"trigger","Use None, Death or Collision"}}
    if p.report>max(Particle_Event) {return {"report","Use None, Death or Collision"}}
    if p.emission_mode>max(asset.Emission_Mode) {return {"emission_mode","Use Physical or Relative"}}
    if len(serial.text_field(p.program[:]))==len(p.program) {return {"program","Name the program in fewer than 64 bytes"}}
    if p.duration<0 {return {"duration","Use a duration of zero or more seconds"}}
    if p.rate<0 || p.rate_over_distance<0 {return {"rate","Use rates of zero or more"}}
    for size in p.shape_size {if size<0 {return {"shape_size","Use sizes of zero or more"}}}
    if p.shape_angle<0 {return {"shape_angle","Use an angle of zero or more"}}
    if p.shell<0 || p.shell>1 {return {"shell","Use a value from 0 to 1"}}
    if p.lifetime[0]<0 || p.lifetime[1]<0 {return {"lifetime","Use lifetimes of zero or more seconds"}}
    if p.size[0]<0 || p.size[1]<0 {return {"size","Use sizes of zero or more"}}
    if p.intensity<0 {return {"intensity","Use an intensity of zero or more"}}
    if p.light_intensity<0 || p.light_range<0 || p.light_radius<0 {return {"light_intensity","Use zero or more for light_intensity, light_range and light_radius"}}
    if p.drag<0 || p.noise_frequency<0 || p.stretch<0 || p.soft<0 || p.flipbook_speed<0 {return {"drag","Use zero or more for drag, noise_frequency, stretch, soft and flipbook_speed"}}
    if p.bounce<0 || p.bounce>1 || p.friction<0 || p.friction>1 || p.collision_life<0 || p.collision_life>1 {return {"bounce","Use values from 0 to 1 for bounce, friction and collision_life"}}
    for burst in p.bursts {
        if burst.time<0 || burst.interval<0 {return {"bursts","Use burst times and intervals of zero or more seconds"}}
    }
    if !particle_times_valid(p.size_over_life.times) {return {"size_over_life","Use key times that go up from 0 to 1"}}
    if !particle_times_valid(p.color_over_life.times) {return {"color_over_life","Use key times that go up from 0 to 1"}}
    for value in p.size_over_life.values {if value<0 {return {"size_over_life","Use sizes of zero or more"}}}
    if problem:=particle_parameters_validate(view.parameters);problem.message!="" {return problem}
    for &hidden in view.hidden {
        if name:=serial.text_field(hidden.name[:]);name=="" || len(name)==len(hidden.name) {return {"hidden","Name each hidden field in fewer than 64 bytes"}}
    }
    return {}
}

particle_check :: proc(view:Particle_View) -> bool {return particle_validate(view).message==""}

@(private="file")
particle_times_valid :: proc(times:[PARTICLE_CURVE_KEYS]f32) -> bool {
    for time,at in times {
        if time<0 || time>1 || at>0 && time<times[at-1] {return false}
    }
    return true
}

// The first field of the effect with a number that is not finite.
@(private="file")
particle_finite :: proc(p:^Particle_Info) -> (field:string,ok:bool) {
    Search :: struct {info:^Particle_Info,field:string}
    search:=Search{info=p}
    visit :: proc(value:Particle_Value,user:rawptr) -> bool {
        s:=cast(^Search)user
        if value.kind!=.Float {return true}
        floats:=([^]f32)(uintptr(s.info)+value.offset)
        for at in 0..<value.size/4 {
            if floats[at]-floats[at]!=0 {s.field=value.top;return false}
        }
        return true
    }
    if !particle_values_visit(visit,&search) {return search.field,false}
    return "",true
}

// Each name once, a type the programs take and numbers they hold exactly.
particle_parameters_validate :: proc(parameters:[]Particle_Parameter) -> Particle_Problem {
    if len(parameters)>PARTICLE_MAX_PARAMETERS {return {"parameters",fmt.tprintf("Give at most %d program parameters",PARTICLE_MAX_PARAMETERS)}}
    for &parameter,at in parameters {
        if problem:=particle_parameter_validate(&parameter);problem.message!="" {return problem}
        for &other in parameters[:at] {
            if other.name==parameter.name {return {"parameters",fmt.tprintf("Give parameter %q once",serial.text_field(parameter.name[:]))}}
        }
    }
    return {}
}

particle_parameter_validate :: proc(parameter:^Particle_Parameter) -> Particle_Problem {
    name:=serial.text_field(parameter.name[:])
    if name=="" || len(name)==len(parameter.name) {return {"parameters","Name each parameter in fewer than 64 bytes"}}
    if parameter.kind>max(asset.Parameter_Kind) || parameter.components<1 || parameter.components>4 {return {"parameters",fmt.tprintf("Give parameter %q a kind (Float, Int, Uint, Bool or Texture) and one to four components",name)}}
    if parameter.kind==.Texture && parameter.components!=1 {return {"parameters",fmt.tprintf("Give texture parameter %q one component",name)}}
    if parameter.kind!=.Texture && parameter.texture!={} {return {"parameters",fmt.tprintf("Parameter %q is not a texture: leave its texture empty",name)}}
    for value,axis in parameter.value {
        if value-value!=0 {return {"parameters",fmt.tprintf("Give parameter %q finite values",name)}}
        if axis>=int(parameter.components) || parameter.kind==.Texture {
            if value!=0 {return {"parameters",fmt.tprintf("Leave the unused components of parameter %q at zero",name)}}
            continue
        }
        exact:=true
        switch parameter.kind {
        case .Float:   exact=abs(value)<=f64(max(f32))
        case .Int:     exact=value==f64(i64(value)) && value>=f64(min(i32)) && value<=f64(max(i32))
        case .Uint:    exact=value==f64(i64(value)) && value>=0 && value<=f64(max(u32))
        case .Bool:    exact=value==0 || value==1
        case .Texture:
        }
        if !exact {return {"parameters",fmt.tprintf("Give parameter %q values its kind %v holds",name,parameter.kind)}}
    }
    return {}
}

// The rows of a table the file may not have: none then.
@(private="file")
table_rows :: proc(a:^asset.Asset,types:^asset.Types,name:string,$T:typeid) -> (rows:[]T,error:asset.Error) {
    if _,found:=asset.asset_table(a,name);!found {return nil,.None}
    return asset.asset_rows(a,types,name,"",T)
}

// The stored value of a program parameter of the effect; nil without one.
particle_parameter_find :: proc(parameters:[]Particle_Parameter,name:string) -> ^Particle_Parameter {
    for &parameter in parameters {
        if serial.text_field(parameter.name[:])==name {return &parameter}
    }
    return nil
}

Particle_Value_Kind :: enum u8 {Float,Integer,Bool,Enum,Asset}

// A value of Particle_Info an instance can change: a field, or an element
// of one that is an array of structs or of arrays.
Particle_Value :: struct {
    path:string,
    top:string,  // the field of Particle_Info it is in
    offset:uintptr,
    size:int,
    kind:Particle_Value_Kind,
    info:^runtime.Type_Info,
    tag:reflect.Struct_Tag,
}

Particle_Value_Visitor :: #type proc(value:Particle_Value,user:rawptr) -> bool

// Visits every value an instance can change, without allocating; the path
// is valid until the visitor returns. A visitor that returns false stops it,
// and so does the call, with false.
particle_values_visit :: proc(visit:Particle_Value_Visitor,user:rawptr) -> bool {
    path:[PARTICLE_NAME_BYTES]u8
    walk :: proc(info:^runtime.Type_Info,offset:uintptr,top:string,tag:reflect.Struct_Tag,path:[]u8,used:int,visit:Particle_Value_Visitor,user:rawptr) -> bool {
        value:=Particle_Value{path=string(path[:used]),top=top,offset=offset,size=info.size,info=info,tag=tag}
        if info.id==base.Asset_Id {value.kind=.Asset;return visit(value,user)}
        #partial switch v in runtime.type_info_base(info).variant {
        case runtime.Type_Info_Struct:
            for i in 0..<int(v.field_count) {
                if reflect.struct_tag_get(reflect.Struct_Tag(v.tags[i]),"mirai")=="text" {continue}
                at:=used
                if at>0 {path[at]='.';at+=1}
                if at+len(v.names[i])>len(path) {return false}
                copy(path[at:],v.names[i])
                if !walk(v.types[i],offset+v.offsets[i],top==""?v.names[i]:top,reflect.Struct_Tag(v.tags[i]),path,at+len(v.names[i]),visit,user) {return false}
            }
            return true
        case runtime.Type_Info_Array:
            elem:=runtime.type_info_base(v.elem)
            _,float:=elem.variant.(runtime.Type_Info_Float)
            _,integer:=elem.variant.(runtime.Type_Info_Integer)
            if (float || integer) && info.size<=PARTICLE_VALUE_BYTES {
                value.kind=float?.Float:.Integer
                return visit(value,user)
            }
            for index in 0..<v.count {
                digits:[20]u8
                name:=strconv.write_int(digits[:],i64(index),10)
                if used+1+len(name)>len(path) {return false}
                path[used]='.'
                copy(path[used+1:],name)
                if !walk(v.elem,offset+uintptr(index*v.elem_size),top,tag,path,used+1+len(name),visit,user) {return false}
            }
            return true
        case runtime.Type_Info_Float:   value.kind=.Float
        case runtime.Type_Info_Integer: value.kind=.Integer
        case runtime.Type_Info_Boolean: value.kind=.Bool
        case runtime.Type_Info_Enum:    value.kind=.Enum
        case: return true
        }
        return visit(value,user)
    }
    return walk(type_info_of(Particle_Info),0,"",{},path[:],0,visit,user)
}

// In the temporary allocator.
particle_fields :: proc() -> []Particle_Value {
    list:=make([dynamic]Particle_Value,context.temp_allocator)
    add :: proc(value:Particle_Value,user:rawptr) -> bool {
        kept:=value
        kept.path=strings.clone(value.path,context.temp_allocator)
        append(cast(^[dynamic]Particle_Value)user,kept)
        return true
    }
    particle_values_visit(add,&list)
    return list[:]
}

// The value of Particle_Info at a path; ok is false for a path it does not
// have. The path of the result is the one given.
particle_value_at :: proc(path:string) -> (value:Particle_Value,ok:bool) {
    Search :: struct {path:string,value:Particle_Value,found:bool}
    search:=Search{path=path}
    find :: proc(value:Particle_Value,user:rawptr) -> bool {
        s:=cast(^Search)user
        if value.path!=s.path {return true}
        s.value,s.found=value,true
        return false
    }
    particle_values_visit(find,&search)
    search.value.path=path
    return search.value,search.found
}

// The value of Particle_Info whose path has this base.name_hash; ok is false
// for a path it does not have. The path of the result is empty.
particle_value_find :: proc(path_hash:u64) -> (value:Particle_Value,ok:bool) {
    Search :: struct {hash:u64,value:Particle_Value,found:bool}
    search:=Search{hash=path_hash}
    find :: proc(value:Particle_Value,user:rawptr) -> bool {
        s:=cast(^Search)user
        if base.name_hash(value.path)!=s.hash {return true}
        s.value,s.found=value,true
        return false
    }
    particle_values_visit(find,&search)
    search.value.path=""
    return search.value,search.found
}

// Whether a field of Particle_Info is hidden from the instances.
particle_hidden :: proc(hidden:[]Particle_Field,top:string) -> bool {
    for &h in hidden {
        if serial.text_field(h.name[:])==top {return true}
    }
    return false
}
