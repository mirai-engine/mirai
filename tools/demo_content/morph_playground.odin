package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

@(private)
Morph_Gltf :: struct {bytes:[dynamic]u8,views,accessors:strings.Builder,count:int}

@(private)
morph_accessor :: proc(out:^Morph_Gltf,bytes:[]u8,count,components:int,component:int=5126,extra:string="") -> int {
    for len(out.bytes)%4!=0 {append(&out.bytes,u8(0))}
    if out.count>0 {fmt.sbprint(&out.views,",");fmt.sbprint(&out.accessors,",")}
    fmt.sbprintf(&out.views,`{{"buffer":0,"byteOffset":%d,"byteLength":%d}}`,len(out.bytes),len(bytes))
    kind:="SCALAR" if components==1 else "VEC2" if components==2 else "VEC3" if components==3 else "MAT4" if components==16 else "VEC4"
    fmt.sbprintf(&out.accessors,`{{"bufferView":%d,"componentType":%d,"count":%d,"type":"%s"%s}}`,out.count,component,count,kind,extra)
    append(&out.bytes,..bytes);out.count+=1
    return out.count-1
}

@(private)
morph_jelly_source :: proc(o:^Out) -> string {
    folder :: "assets/characters/jelly"
    os.make_directory_all(path(o,folder))
    sphere:geom.Mesh_Buffer;geom.mesh_buffer_init(&sphere,context.temp_allocator);geom.sphere_build(&sphere,1,24,12)
    positions,normals:=make([dynamic]mm.Vec3,context.temp_allocator),make([dynamic]mm.Vec3,context.temp_allocator)
    colors:=make([dynamic]mm.Vec4,context.temp_allocator);indices:=make([dynamic]u32,context.temp_allocator);parts:=make([dynamic]u8,context.temp_allocator)
    pieces:=[?]struct {center,scale:mm.Vec3,color:mm.Vec4,part:u8}{
        {{0,1.1,0},{.94,.94,.72},{.12,.85,.78,1},0},
        {{-.34,1.39,.64},{.25,.31,.17},{1,.99,.87,1},1},{{.34,1.39,.64},{.25,.31,.17},{1,.99,.87,1},1},
        {{-.31,1.4,.795},{.105,.16,.06},{.15,.06,.28,1},1},{{.37,1.4,.795},{.105,.16,.06},{.15,.06,.28,1},1},
        {{-.33,1.47,.85},{.035,.05,.02},{1,1,1,1},1},{{.35,1.47,.85},{.035,.05,.02},{1,1,1,1},1},
        {{0,.93,.699},{.31,.115,.08},{.24,.03,.28,1},2},{{0,.89,.77},{.19,.06,.025},{1,.32,.48,1},2},
        {{-.65,1.08,.54},{.2,.115,.09},{1,.36,.48,1},3},{{.65,1.08,.54},{.2,.115,.09},{1,.36,.48,1},3},
        {{-.57,.19,.12},{.42,.2,.42},{.52,.27,.98,1},4},{{.57,.19,.12},{.42,.2,.42},{.52,.27,.98,1},4},
        {{-1.05,.96,.1},{.3,.25,.3},{.97,.72,.18,1},3},{{1.05,.96,.1},{.3,.25,.3},{.97,.72,.18,1},3},
        {{-.22,2,.04},{.16,.42,.16},{.52,.27,.98,1},5},{{.22,2,.04},{.16,.42,.16},{1,.37,.57,1},5},
    }
    for piece in pieces {
        first:=u32(len(positions))
        for point in sphere.positions {append(&positions,piece.center+point*piece.scale);append(&normals,linalg.normalize(point/piece.scale));append(&colors,piece.color);append(&parts,piece.part)}
        for index in sphere.indices {append(&indices,first+index)}
    }
    geom.mesh_compute_normals(positions[:],indices[:],normals[:])
    gltf:=Morph_Gltf{bytes=make([dynamic]u8,context.temp_allocator),views=strings.builder_make(allocator=context.temp_allocator),accessors=strings.builder_make(allocator=context.temp_allocator)}
    low,high:=positions[0],positions[0];for p in positions {low=linalg.min(low,p);high=linalg.max(high,p)}
    bounds:=fmt.tprintf(`,"min":[%g,%g,%g],"max":[%g,%g,%g]`,low.x,low.y,low.z,high.x,high.y,high.z)
    p:=morph_accessor(&gltf,mem.slice_data_cast([]u8,positions[:]),len(positions),3,extra=bounds)
    n:=morph_accessor(&gltf,mem.slice_data_cast([]u8,normals[:]),len(normals),3)
    color:=morph_accessor(&gltf,mem.slice_data_cast([]u8,colors[:]),len(colors),4)
    index:=morph_accessor(&gltf,mem.slice_data_cast([]u8,indices[:]),len(indices),1,5125)
    joints:=make([][4]u16,len(positions),context.temp_allocator);weights:=make([][4]f32,len(positions),context.temp_allocator)
    for point,i in positions {amount:=clamp((point.y-.45)/1.1,0,1);joints[i]={0,1,0,0};weights[i]={1-amount,amount,0,0}}
    joint:=morph_accessor(&gltf,mem.slice_data_cast([]u8,joints),len(joints),4,5123)
    weight:=morph_accessor(&gltf,mem.slice_data_cast([]u8,weights),len(weights),4)
    targets:=strings.builder_make(allocator=context.temp_allocator)
    for shape in 0..<4 {
        changed:=make([]mm.Vec3,len(positions),context.temp_allocator);changed_normals:=make([]mm.Vec3,len(positions),context.temp_allocator)
        for point,i in positions {
            value:=point
            switch shape {
            case 0: value.x*=1.3;value.y=.15+(point.y-.15)*.65
            case 1:
                if parts[i]==2 {value.y+=.17*(abs(point.x)/.31)*(abs(point.x)/.31);value.x*=1.12}
                if parts[i]==3 {value.y+=.08}
            case 2: if parts[i]==1 {value.y=1.4+(point.y-1.4)*.12}
            case 3: value=mm.quat_rotate(mm.quat_axis_angle({0,1,0},max(0,point.y-.2)*.5),point)
            }
            changed[i]=value
        }
        geom.mesh_compute_normals(changed,indices[:],changed_normals)
        for point,i in positions {changed[i]-=point;changed_normals[i]-=normals[i]}
        a:=morph_accessor(&gltf,mem.slice_data_cast([]u8,changed),len(changed),3)
        b:=morph_accessor(&gltf,mem.slice_data_cast([]u8,changed_normals),len(changed_normals),3)
        if shape>0 {fmt.sbprint(&targets,",")};fmt.sbprintf(&targets,`{{"POSITION":%d,"NORMAL":%d}}`,a,b)
    }
    times:=[5]f32{0,.5,1,1.5,2};clock:=morph_accessor(&gltf,mem.slice_data_cast([]u8,times[:]),5,1)
    dance:=[20]f32{0,.8,0,0, .65,1,0,.65, 0,.8,1,0, -.25,1,0,-.65, 0,.8,0,0}
    sleepy:=[20]f32{.15,.3,0,0, .15,.3,1,0, .15,.3,1,0, .15,.3,0,0, .15,.3,0,0}
    rubber:[60]f32
    for k in 0..<5 {for t in 0..<4 {rubber[(k*3+1)*4+t]=dance[k*4+t]*.6;rubber[(k*3+2)*4+t]=.2 if t==3 else 0}}
    d:=morph_accessor(&gltf,mem.slice_data_cast([]u8,dance[:]),20,1);s:=morph_accessor(&gltf,mem.slice_data_cast([]u8,sleepy[:]),20,1);r:=morph_accessor(&gltf,mem.slice_data_cast([]u8,rubber[:]),60,1)
    turns:[5][4]f32
    for &turn,k in turns {q:=mm.quat_axis_angle({0,0,1},.2*math.sin(f32(k)*mm.PI*.5));turn={q.x,q.y,q.z,q.w}}
    rotation:=morph_accessor(&gltf,mem.slice_data_cast([]u8,turns[:]),5,4)
    animations:=strings.builder_make(allocator=context.temp_allocator)
    clip_names:=[3]string{"JellyDance","Sleepy","Rubber"};interpolations:=[3]string{"LINEAR","STEP","CUBICSPLINE"}
    for out,i in ([3]int{d,s,r}) {
        if i>0 {fmt.sbprint(&animations,",")}
        fmt.sbprintf(&animations,`{{"name":"%s","samplers":[{{"input":%d,"output":%d,"interpolation":"%s"}},{{"input":%d,"output":%d}}],"channels":[{{"sampler":0,"target":{{"node":0,"path":"weights"}}}},{{"sampler":0,"target":{{"node":1,"path":"weights"}}}},{{"sampler":1,"target":{{"node":3,"path":"rotation"}}}}]}}`,clip_names[i],clock,out,interpolations[i],clock,rotation)
    }
    inverse_binds:=[2]mm.Mat4{mm.Mat4(1),mm.Mat4(1)};inverse_binds[1][1,3]=-1.2
    ibm:=morph_accessor(&gltf,mem.slice_data_cast([]u8,inverse_binds[:]),2,16)
    accessors:=strings.to_string(gltf.accessors)
    json:=fmt.tprintf(`{{"asset":{{"version":"2.0","generator":"Mirai Odin morph playground"}},"buffers":[{{"uri":"jelly.bin","byteLength":%d}}],"bufferViews":[%s],"accessors":[%s],"materials":[{{"name":"Candy","pbrMetallicRoughness":{{"metallicFactor":0,"roughnessFactor":0.42}}}}],"meshes":[{{"name":"Party Jelly","weights":[0,0,0,0],"extras":{{"targetNames":["Squash","Smile","Blink","Wobble"]}},"primitives":[{{"attributes":{{"POSITION":%d,"NORMAL":%d,"COLOR_0":%d,"JOINTS_0":%d,"WEIGHTS_0":%d}},"indices":%d,"material":0,"targets":[%s]}}]}}],"nodes":[{{"name":"Jelly","mesh":0}},{{"name":"JellySkinned","mesh":0,"skin":0}},{{"name":"Root","children":[3]}},{{"name":"Top","translation":[0,1.2,0]}}],"skins":[{{"name":"Jelly bones","joints":[2,3],"inverseBindMatrices":%d}}],"scenes":[{{"nodes":[0,1,2]}}],"scene":0,"animations":[%s]}}`,len(gltf.bytes),strings.to_string(gltf.views),accessors,p,n,color,joint,weight,index,strings.to_string(targets),ibm,strings.to_string(animations))
    if os.write_entire_file(path(o,folder+"/jelly.bin"),gltf.bytes[:])!=nil || os.write_entire_file(path(o,folder+"/jelly.gltf"),json)!=nil {o.content.failed=true}
    return folder+"/jelly.gltf"
}

// The jelly of morph targets of the gallery, a source written here and imported, and its moods: a
// layer that mixes its clips of shapes and an additive layer over it.
@(private)
gallery_morphs :: proc(o:^Out) {
    source:=morph_jelly_source(o);if o.content.failed {return};source_import(o,source);if o.content.failed {return}
    animation:=imported_id(o,source,asset.KIND_ANIMATION,"jelly")
    // Its moods over the dance: how sleepy it is, and how much the rubber adds, by the weights the game sets.
    layers:=[2]anim.Stack_Layer{anim.STACK_LAYER_DEFAULT,anim.STACK_LAYER_DEFAULT}
    base.text_set(layers[0].name[:],"Mood");base.text_set(layers[0].clip[:],"Sleepy");layers[0].sync,layers[0].weight,layers[0].fade=true,0,0
    base.text_set(layers[1].name[:],"Rubber");base.text_set(layers[1].clip[:],"Rubber");layers[1].mode,layers[1].weight,layers[1].fade=.Additive,.25,.2
    gallery_set(o,"characters/jelly","jelly_moods",animation,{actions={layers=layers[:]}})
}
