package effect

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"

// .particle, the asset of the vfx plugin: an effect of particles, as a
// material is a look. The entities that show it name it and give it values
// of their own.
//
//   particle    Particle_Info, one row per layer, in emission order
//   parameters  Particle_Parameter: values for its Vfx program, by name
//   hidden      Particle_Field: fields an instance does not show
//
// A field of an instance is named by its path in Particle_Info: field names
// and array indices joined by dots ("lifetime", "colors.1",
// "bursts.0.count", "size_over_life.values.2"). particle_fields lists the
// paths an instance can change, each a value of at most PARTICLE_VALUE_BYTES;
// text fields (the program) are of the effect alone.

PARTICLE_LAYERS :: 8
PARTICLE_BURSTS :: 4
PARTICLE_CURVE_KEYS :: 8
PARTICLE_VALUE_BYTES :: 16
PARTICLE_NAME_BYTES :: 64
PARTICLE_MAX_PARAMETERS :: 32
PARTICLE_MESHES :: 4

Particle_Shape :: enum u32 {Point,Sphere,Hemisphere,Cone,Box,Circle,Line,Surface}
Particle_Render :: enum u32 {Billboard,Velocity,Horizontal,Ribbon,Mesh,Beam}
// How a sprite, a ribbon or a beam covers what is behind it: Additive adds
// its light, Alpha covers it by its opacity, Multiply darkens it by its color.
// A Mesh particle blends as the alpha mode of its material says.
Particle_Blend :: enum u32 {Additive,Alpha,Multiply}
Particle_Collision :: enum u32 {None,World}
// How a Mesh particle turns: Tumble, about an axis of its own by its rotation
// and spin; Velocity, its front (-Z) along its velocity, its +Y as near the
// up of the world; Emitter, as its emitter was turned when it was born. The
// last two roll about its front by its rotation.
Particle_Facing :: enum u32 {Tumble,Velocity,Emitter}
// What a ribbon is wide along: across its path, facing the camera; or the +Y
// of its emitter where each of its particles was born (the blade of a sword).
Particle_Ribbon_Axis :: enum u32 {Camera,Emitter_Up}
// Trail: vfx.TRAILS_PER_SECOND times each second of its life, where it is.
// The particles an event starts join a ribbon of the particle that made it:
// those of Trail are a trail behind it.
Particle_Event :: enum u32 {None,Death,Collision,Trail}

// Particles started at once, when the cycle reaches time. cycles above one
// repeat it every interval seconds.
Particle_Burst :: struct {
    time:f32 `mirai:"min=0,unit=s"`,
    count:u32,
    cycles:u32,
    interval:f32 `mirai:"min=0,unit=s"`,
}

// A value over the life of a particle:
// Piecewise linear between ascending times. A zero suffix leaves keys unused.
Particle_Curve :: struct {
    values:[PARTICLE_CURVE_KEYS]f32,
    times:[PARTICLE_CURVE_KEYS]f32 `mirai:"min=0,max=1"`,
}

Particle_Gradient :: struct {
    colors:[PARTICLE_CURVE_KEYS][4]f32 `mirai:"color"`,
    times:[PARTICLE_CURVE_KEYS]f32 `mirai:"min=0,max=1"`,
}

// Dynamic point lights emitted by a particle effect, driven by its clock and
// particle life. intensity or range of 0 disables light emission at zero cost.
Particle_Light :: struct {
    color:[3]f32 `mirai:"color"`,          // tint; {0,0,0} uses the effect's particle color
    intensity:f32 `mirai:"min=0,unit=cd"`, // peak candela per emitted light; 0 disables
    range:f32 `mirai:"min=0,unit=m"`,      // attenuation range; 0 disables
    radius:f32 `mirai:"min=0,unit=m"`,     // source sphere radius for soft highlights and shadows
    max_lights:u16,                        // max concurrent lights for this emitter; 0 uses 1 when enabled
    shadows:bool,                          // whether emitted lights cast shadows
    indirect:f32 `mirai:"min=0"`,         // indirect GI bounce multiplier
    scattering:f32 `mirai:"min=0"`,       // volumetric fog scattering multiplier
}

// The shape faces +Y of the entity, where a cone opens; the particles leave
// it along its normal, or along +Y from a box and a line. A Surface starts
// them on the triangles of a mesh, by their area, and they leave along its
// normal with the velocity of the surface times inherit_velocity; a skinned
// mesh moves its triangles, and the particles start where they are drawn.
// The editor shows a field in the group its tag names, or in that of the
// field before it.
Particle_Info :: struct {
    duration:f32 `mirai:"section=Spawn,min=0,unit=s"`, // of a cycle
    prewarm:bool,                             // a looping instance starts as if it had run a whole life
    max_instances:u16,                        // of the primary layer: emitters of the effect that run at once, those nearest a simulation source (scene.Simulation_Sources); the others pause and are not drawn; 0: all
    max_particles:u32,                        // alive at once; 0: what the rate, the bursts and the lifetime need
    cull_distance:f32 `mirai:"min=0,unit=m"`, // of the primary layer: its emitters farther than this from every simulation source pause and are not drawn; 0: at any distance
    rate:f32 `mirai:"min=0,unit=1/s"`,
    rate_over_distance:f32 `mirai:"min=0,unit=1/m"`, // per metre the entity travels
    bursts:[PARTICLE_BURSTS]Particle_Burst,
    shape:Particle_Shape `mirai:"section=Shape"`,
    shape_size:[3]f32 `mirai:"min=0,unit=m"`, // radius in x, half extents of a box, half length of a line
    shape_angle:f32 `mirai:"angle,min=0"`,    // of a cone, from its axis
    shell:f32 `mirai:"min=0,max=1"`,          // 0: from the volume of the shape, 1: from its surface
    lifetime:[2]f32 `mirai:"section=Motion,min=0,unit=s"`, // each particle takes a value between both
    speed:[2]f32 `mirai:"unit=m/s"`,          // along the normal of the shape
    velocity:[2][3]f32 `mirai:"unit=m/s"`,    // in the space of the entity, between both, besides speed
    size:[2]f32 `mirai:"section=Look,min=0,unit=m"`,
    rotation:[2]f32 `mirai:"angle"`,
    spin:[2]f32 `mirai:"angle"`,              // per second
    colors:[2][4]f32 `mirai:"color"`,         // each particle takes a mix
    intensity:f32 `mirai:"min=0"`,            // multiplies the color: above 1 it glows
    emission_mode:asset.Emission_Mode,        // what the color of an unlit particle is: nits, or the value the exposed image shows
    inherit_velocity:f32 `mirai:"section=Motion"`, // share of the velocity of the entity a particle starts with
    local_space:bool,                         // particles move with the entity
    gravity:f32,                              // share of the gravity of where each particle is (volume Gravity)
    acceleration:[3]f32 `mirai:"unit=m/s²"`,
    drag:f32 `mirai:"min=0,unit=1/s"`,
    noise:f32 `mirai:"unit=m/s²"`,            // strength of a turbulent flow
    noise_frequency:f32 `mirai:"min=0,unit=1/m"`,
    noise_speed:f32 `mirai:"unit=1/s"`,
    attractor:[3]f32 `mirai:"unit=m"`,        // a point of the entity that pulls the particles
    attractor_strength:f32 `mirai:"unit=m/s²"`,
    collision:Particle_Collision `mirai:"section=Collision"`, // World: against the traced scene
    bounce:f32 `mirai:"min=0,max=1"`,
    friction:f32 `mirai:"min=0,max=1"`,       // tangent speed lost per normal speed a surface stops
    collision_life:f32 `mirai:"min=0,max=1"`, // share of its life a particle loses per hit
    render:Particle_Render `mirai:"section=Look"`,
    blend:Particle_Blend,
    lit:bool,                                 // the sun, the lights and the light probes light it
    sort:bool,                                // blended particles drawn back to front
    material:base.Asset_Id,                   // its base color texture is the flipbook; none: a soft puff
    meshes:[PARTICLE_MESHES]base.Asset_Id,    // of Mesh particles, each picked by its weight; none: a cube
    mesh_weights:[PARTICLE_MESHES]f32 `mirai:"min=0"`, // how often each of meshes is picked; all 0: each as often
    facing:Particle_Facing,
    scale:[3]f32 `mirai:"min=0"`,             // of every particle: x and y of a sprite, the width of a ribbon or a beam, the axes of a mesh; 0: 1
    ribbon_axis:Particle_Ribbon_Axis,
    ribbon_tile:f32 `mirai:"min=0,unit=m"`,   // a ribbon repeats its texture every this many metres from its head; 0: once from its head to its tail
    stretch:f32 `mirai:"min=0,unit=s"`,       // Velocity: seconds of motion a sprite spans
    soft:f32 `mirai:"min=0,unit=m"`,          // a sprite fades over this distance into what is behind it
    flipbook:[2]u32,                          // columns and rows
    flipbook_speed:f32 `mirai:"min=0"`,       // frames per second; 0: the whole flipbook over the life
    size_over_life:Particle_Curve,
    color_over_life:Particle_Gradient,
    trigger:Particle_Event `mirai:"section=Collision"`, // when sub_particle starts particles where one of these is
    sub_particle:base.Asset_Id,               // a .particle
    sub_count:u32,                            // its particles per event
    beam_end:[3]f32 `mirai:"section=Look,unit=m"`, // endpoint offset in the emitter's axes
    beam_arc:f32 `mirai:"unit=m"`, // midpoint offset along the emitter's +Y
    light:Particle_Light, // dynamic point lights driven by particle life; intensity or range 0 disables
    program:[PARTICLE_NAME_BYTES]u8 `mirai:"section=Program,text"`, // a Vfx program of the shaders; "" for none
}

PARTICLE_CURVE_ONE :: Particle_Curve{values={1,1,1,1,1,1,1,1},times={0,1,1,1,1,1,1,1}}

PARTICLE_DEFAULTS :: Particle_Info{
    duration=2,rate=20,
    shape=.Cone,shape_size={0.1,0.1,0.1},shape_angle=0.35,
    lifetime={1.5,2},speed={1,2},size={0.2,0.35},colors={{1,1,1,1},{1,1,1,1}},intensity=1,emission_mode=.Relative,
    blend=.Alpha,lit=true,scale={1,1,1},soft=0.3,flipbook={1,1},
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
    layer:u8,
    value:[4]f64,  // every 32-bit integer and float exactly
    texture:base.Asset_Id,
}

// An effect as its file holds it: what particle_view reads (its tables are
// those of the file, its id and source are not read) and what particle_bytes
// writes.
Particle_Desc :: struct {
    id:base.Asset_Id,
    info:Particle_Info,
    layers:[]Particle_Info, // after the primary layer
    parameters:[]Particle_Parameter,
    hidden:[]Particle_Field,
    source:^asset.Import_Info, // of an effect an import wrote; nil for one made here
}

particle_document :: proc(doc:^asset.Document,types:^asset.Types,desc:Particle_Desc,allocator:=context.allocator) -> asset.Error {
    if !particle_check(desc) {return .Invalid}
    asset.document_init(doc,PARTICLE_KIND,desc.id,allocator)
    doc.kind_version=PARTICLE_VERSION
    error:=particle_tables(doc,types,desc)
    if error!=.None {asset.document_destroy(doc)}
    return error
}

@(private="file")
particle_tables :: proc(doc:^asset.Document,types:^asset.Types,desc:Particle_Desc) -> asset.Error {
    layers:[PARTICLE_LAYERS]Particle_Info
    layers[0]=desc.info
    copy(layers[1:],desc.layers)
    asset.document_put(doc,types,"particle",layers[:1+len(desc.layers)]) or_return
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

particle_view :: proc(a:^asset.Asset,types:^asset.Types) -> (desc:Particle_Desc,error:asset.Error) {
    asset.kind_check(a,PARTICLE_KIND,PARTICLE_VERSION) or_return
    layers:=asset.asset_rows(a,types,"particle","",Particle_Info,whole=true) or_return
    if len(layers)<1 || len(layers)>PARTICLE_LAYERS {return {},.Corrupt}
    desc.info=layers[0]
    desc.layers=layers[1:]
    desc.parameters=table_rows(a,types,"parameters",Particle_Parameter) or_return
    desc.hidden=table_rows(a,types,"hidden",Particle_Field) or_return
    if !particle_check(desc) {return {},.Corrupt}
    return desc,.None
}

// What is wrong with the values of an effect: the field and how to correct
// it. An empty message: nothing.
Particle_Problem :: struct {
    field:string,
    message:string,
}

// Values the renderer can take as they are: finite, inside their ranges,
// with enums it knows, curves that go forward and names that end.
particle_validate :: proc(desc:Particle_Desc) -> Particle_Problem {
    info:=desc.info
    if problem:=particle_info_problem(&info,true);problem.message!="" {return problem}
    if len(desc.layers)>=PARTICLE_LAYERS {
        return {"layers",fmt.tprintf("Give at most %d layers including the primary layer",PARTICLE_LAYERS)}
    }
    for &layer,i in desc.layers {
        if problem:=particle_info_problem(&layer,true);problem.message!="" {
            return {fmt.tprintf("layers.%d.%s",i,problem.field),problem.message}
        }
    }
    if problem:=particle_parameters_validate(desc.parameters,len(desc.layers)+1);problem.message!="" {return problem}
    for &hidden in desc.hidden {
        if name:=serial.text_field(hidden.name[:]);name=="" || len(name)==len(hidden.name) {return {"hidden","Name each hidden field in fewer than 64 bytes"}}
    }
    return {}
}

@(private="file")
particle_info_problem :: proc(p:^Particle_Info,coupled:bool) -> Particle_Problem {
    if field,ok:=particle_finite(p);!ok {return {field,"Use finite numbers"}}
    if p.shape>max(Particle_Shape) {return {"shape","Use Point, Sphere, Hemisphere, Cone, Box, Circle, Line or Surface"}}
    if p.render>max(Particle_Render) {return {"render","Use Billboard, Velocity, Horizontal, Ribbon, Mesh or Beam"}}
    if p.blend>max(Particle_Blend) {return {"blend","Use Additive, Alpha or Multiply"}}
    if p.collision>max(Particle_Collision) {return {"collision","Use None or World"}}
    if p.facing>max(Particle_Facing) {return {"facing","Use Tumble, Velocity or Emitter"}}
    if p.ribbon_axis>max(Particle_Ribbon_Axis) {return {"ribbon_axis","Use Camera or Emitter_Up"}}
    for scale in p.scale {if scale<0 {return {"scale","Use scales of zero or more; 0 keeps that axis at 1"}}}
    if p.ribbon_tile<0 {return {"ribbon_tile","Use a length of zero or more metres; 0 spans the texture over the whole ribbon"}}
    for weight in p.mesh_weights {if weight<0 {return {"mesh_weights","Use weights of zero or more"}}}
    if coupled && p.render==.Mesh && p.sort {
        meshes:=0
        for id in p.meshes {meshes+=1 if id!={} else 0}
        if meshes>1 {return {"sort","A sorted effect draws one mesh back to front: keep one of meshes, or turn sort off"}}
    }
    if p.trigger>max(Particle_Event) {return {"trigger","Use None, Death, Collision or Trail"}}
    if p.emission_mode>max(asset.Emission_Mode) {return {"emission_mode","Use Physical or Relative"}}
    if len(serial.text_field(p.program[:]))==len(p.program) {return {"program","Name the program in fewer than 64 bytes"}}
    if p.duration<0 {return {"duration","Use a duration of zero or more seconds"}}
    if p.cull_distance<0 {return {"cull_distance","Use a distance of zero or more metres; 0 runs its emitters at any distance"}}
    if p.rate<0 || p.rate_over_distance<0 {return {"rate","Use rates of zero or more"}}
    for size in p.shape_size {if size<0 {return {"shape_size","Use sizes of zero or more"}}}
    if p.shape_angle<0 {return {"shape_angle","Use an angle of zero or more"}}
    if p.shell<0 || p.shell>1 {return {"shell","Use a value from 0 to 1"}}
    if p.lifetime[0]<0 || p.lifetime[1]<0 {return {"lifetime","Use lifetimes of zero or more seconds"}}
    if coupled && max(p.lifetime[0],p.lifetime[1])<=0 {return {"lifetime","Give the particles a lifetime above 0 seconds: with none they die as they are born"}}
    if p.size[0]<0 || p.size[1]<0 {return {"size","Use sizes of zero or more"}}
    if p.intensity<0 {return {"intensity","Use an intensity of zero or more"}}
    if p.drag<0 || p.noise_frequency<0 || p.stretch<0 || p.soft<0 || p.flipbook_speed<0 {return {"drag","Use zero or more for drag, noise_frequency, stretch, soft and flipbook_speed"}}
    if p.bounce<0 || p.bounce>1 || p.friction<0 || p.friction>1 || p.collision_life<0 || p.collision_life>1 {return {"bounce","Use values from 0 to 1 for bounce, friction and collision_life"}}
    for burst in p.bursts {
        if burst.time<0 || burst.interval<0 {return {"bursts","Use burst times and intervals of zero or more seconds"}}
    }
    if !particle_times_valid(p.size_over_life.times[:],coupled) {return {"size_over_life","Use key times that go up from 0 to 1"}}
    if !particle_times_valid(p.color_over_life.times[:],coupled) {return {"color_over_life","Use key times that go up from 0 to 1"}}
    for value in p.size_over_life.values {if value<0 {return {"size_over_life","Use sizes of zero or more"}}}
    for c in p.light.color {if c<0 {return {"light","Use light color channels of zero or more"}}}
    if p.light.intensity<0 || p.light.range<0 || p.light.radius<0 || p.light.indirect<0 || p.light.scattering<0 {
        return {"light","Use zero or more for light intensity, range, radius, indirect and scattering"}
    }
    return {}
}

// Checks a field before its effect is known. Cross-field rules are checked on the resolved effect.
particle_field_valid :: proc(field:Particle_Value,bytes:[]u8) -> bool {
    if field.size<=0 || field.size>size_of(Particle_Info) || len(bytes)<field.size {return false}
    if field.offset>uintptr(size_of(Particle_Info)-field.size) {return false}
    info:=PARTICLE_DEFAULTS
    mem.copy(rawptr(uintptr(&info)+field.offset),raw_data(bytes),field.size)
    return particle_info_problem(&info,false).message==""
}

particle_check :: proc(desc:Particle_Desc) -> bool {return particle_validate(desc).message==""}

// The scale of the particles of an effect: 1 on an axis it leaves at 0.
particle_scale :: proc "contextless" (info:^Particle_Info) -> [3]f32 {
    scale:=info.scale
    for &axis in scale {if axis<=0 {axis=1}}
    return scale
}

// Whether a field of Particle_Info means anything to what the effect draws:
// a Mesh particle blends as its material does, and only a ribbon has an axis
// and a tile.
particle_field_applies :: proc(info:^Particle_Info,top:string) -> bool {
    switch top {
    case "blend": return info.render!=.Mesh
    case "ribbon_axis","ribbon_tile": return info.render==.Ribbon
    case "facing","meshes","mesh_weights": return info.render==.Mesh
    }
    return true
}

@(private="file")
particle_times_valid :: proc(times:[]f32,ordered:bool) -> bool {
    for time,at in times[:particle_key_count(times[:])] {
        if time<0 || time>1 || ordered && at>0 && time<times[at-1] {return false}
    }
    return true
}

particle_key_count :: proc "contextless" (times:[]f32) -> int {
    count:=len(times)
    for count>1 && times[count-1]==0 {count-=1}
    return count
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
particle_parameters_validate :: proc(parameters:[]Particle_Parameter,layers:=1) -> Particle_Problem {
    counts:[PARTICLE_LAYERS]int
    for &parameter,at in parameters {
        if int(parameter.layer)>=min(layers,len(counts)) {return {"parameters","Give parameters only for layers of the effect"}}
        counts[parameter.layer]+=1
        if counts[parameter.layer]>PARTICLE_MAX_PARAMETERS {
            return {"parameters",fmt.tprintf("Give at most %d program parameters per layer",PARTICLE_MAX_PARAMETERS)}
        }
        if problem:=particle_parameter_validate(&parameter);problem.message!="" {return problem}
        for &other in parameters[:at] {
            if other.layer==parameter.layer && other.name==parameter.name {
                return {"parameters",fmt.tprintf("Give parameter %q once per layer",serial.text_field(parameter.name[:]))}
            }
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
particle_parameter_find :: proc(parameters:[]Particle_Parameter,name:string,layer:u8=0) -> ^Particle_Parameter {
    for &parameter in parameters {
        if parameter.layer==layer && serial.text_field(parameter.name[:])==name {return &parameter}
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
}

Particle_Value_Visitor :: #type proc(value:Particle_Value,user:rawptr) -> bool

@(private="file")
particle_value :: proc(entry:Value_Entry) -> Particle_Value {
    top:=entry.path
    if dot:=strings.index_byte(top,'.');dot>=0 {top=top[:dot]}
    info:=type_info_of(entry.type)
    return {entry.path,top,entry.offset,info.size,entry.kind,info}
}

particle_values_visit :: proc(visit:Particle_Value_Visitor,user:rawptr) -> bool {
    for i in 0..<len(VALUE_FIELDS) {
        if !visit(particle_value(VALUE_FIELDS[i]),user) {return false}
    }
    return true
}

particle_fields :: proc() -> []Particle_Value {
    values,err:=make([]Particle_Value,len(VALUE_FIELDS),context.temp_allocator)
    if err!=nil {return nil}
    for i in 0..<len(VALUE_FIELDS) {values[i]=particle_value(VALUE_FIELDS[i])}
    return values
}

particle_value_at :: proc(path:string) -> (value:Particle_Value,ok:bool) {
    entry,found:=particle_entry_find(base.name_hash(path))
    if !found || entry.path!=path {return {},false}
    return particle_value(entry),true
}

particle_value_find :: proc(path_hash:u64) -> (value:Particle_Value,ok:bool) {
    entry,found:=particle_entry_find(path_hash)
    if !found {return {},false}
    value=particle_value(entry)
    value.path=""
    return value,true
}

@(private="file")
particle_entry_find :: proc(path_hash:u64) -> (Value_Entry,bool) {
    lo,hi:=0,len(VALUE_FIELDS)
    for lo<hi {
        mid:=(lo+hi)/2
        field:=VALUE_FIELDS[mid]
        if field.hash==path_hash {return field,true}
        if field.hash<path_hash {lo=mid+1} else {hi=mid}
    }
    return {},false
}

// Whether a field of Particle_Info is hidden from the instances.
particle_hidden :: proc(hidden:[]Particle_Field,top:string) -> bool {
    for &h in hidden {
        if serial.text_field(h.name[:])==top {return true}
    }
    return false
}
