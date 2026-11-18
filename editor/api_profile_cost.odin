package editor

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:editor/api"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"

// profile.cost: what one frame of the viewport costs by mesh and by material
// (render.Cost), the costliest first, each named by its asset.

PROFILE_COST_FRAMES :: 16 // a frame counts and the count comes back within them, or the call fails

Api_Profile_Cost_Params :: struct {
    top:int `mirai:"optional,min=1,max=64,clamp,label=Meshes and materials in the answer, of each"`,
    dt:f32 `mirai:"optional,min=0.0001,max=0.25,unit=s,label=Of each frame a manual editor runs"`,
}
Api_Profile_Cost_Row :: struct {
    asset:string `mirai:"label=Its path, or its id when no file has it; a shape or the default material by name, else the handle of the mesh or the row of the material"`,
    instances:int `mirai:"label=That passed the cull of the view; of a mesh alone"`,
    clusters:int `mirai:"label=The view listed for its raster"`,
    triangles:int `mirai:"label=Of those clusters"`,
    raster_triangles:int `mirai:"label=Of them the raster drew: those that may cover a pixel"`,
    pixels:int `mirai:"label=Of the image of the view it owns: what its material shades"`,
    shadow_clusters:int `mirai:"label=The maps of the shadows drew, once for each page they cover"`,
    shadow_triangles:int `mirai:"label=The raster of the maps drew of them"`,
    shadow_units:int `mirai:"label=Of raster work they took in the maps"`,
    shadow_over:int `mirai:"label=Clusters left over the bound of the frame of the maps: their pages wait"`,
}
Api_Profile_Cost :: struct {
    frame:u64 `mirai:"label=Of the renderer, that drew what it counts"`,
    total:Api_Profile_Cost_Row `mirai:"label=Of every mesh"`,
    meshes:[]Api_Profile_Cost_Row `mirai:"label=The costliest first, by the triangles the view and the maps drew; none that cost nothing"`,
    materials:[]Api_Profile_Cost_Row `mirai:"label=The costliest first, by the pixels they shade and then the triangles drawn; none that cost nothing"`,
    notes:[]string `mirai:"label=How to read it"`,
}

@(private)
api_profile_cost :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Profile_Cost_Params)
    r:=s.app.renderer
    if r==nil {api.call_fail(call,api.SERVER_ERROR,"This editor has no renderer: it runs without a GPU");return}
    if ok,_:=api_view_wait(s,call,p.dt,time.tick_now());!ok {return}
    if problem:=gpu.renderer_cost_ask(r);problem!="" {api.call_fail(call,api.SERVER_ERROR,problem);return}
    for _ in 0..<PROFILE_COST_FRAMES {
        if api_frames(s,1,p.dt)==0 {break}
        if cost,ready:=gpu.renderer_cost(r);ready {
            api.call_result(call,Api_Profile_Cost)^=profile_cost_answer(s.app.assets,cost,p.top,call.allocator)
            return
        }
    }
    api.call_failf(call,api.SERVER_ERROR,"The viewport drew no frame of the scene in %d frames: a panel covers it or Play shows it from its own process; uncover it and call profile.cost again",PROFILE_COST_FRAMES)
}

// The answer of a count: its rows named by the assets of a (nil: by handle),
// the costliest top of each.
profile_cost_answer :: proc(a:^host.Assets,cost:gpu.Cost,top:int,allocator:=context.allocator) -> (out:Api_Profile_Cost) {
    context.allocator=allocator
    Named :: struct {row:gpu.Cost_Row,name:string}
    row_of :: proc(row:gpu.Cost_Row,name:string) -> Api_Profile_Cost_Row {
        return {strings.clone(name),int(row.instances),int(row.clusters),int(row.triangles),int(row.raster_triangles),int(row.pixels),int(row.shadow_clusters),int(row.shadow_triangles),int(row.shadow_units),int(row.shadow_over)}
    }
    mesh_names,material_names:=profile_cost_names(a,len(cost.meshes),len(cost.materials))
    meshes:=make([dynamic]Named,context.temp_allocator)
    total:gpu.Cost_Row
    for row,handle in cost.meshes {
        if row=={} {continue}
        append(&meshes,Named{row,mesh_names[handle] if mesh_names[handle]!="" else fmt.tprintf("mesh %d",handle)})
        total.instances+=row.instances;total.clusters+=row.clusters;total.triangles+=row.triangles
        total.raster_triangles+=row.raster_triangles;total.pixels+=row.pixels
        total.shadow_clusters+=row.shadow_clusters;total.shadow_triangles+=row.shadow_triangles
        total.shadow_units+=row.shadow_units;total.shadow_over+=row.shadow_over
    }
    materials:=make([dynamic]Named,context.temp_allocator)
    for row,index in cost.materials {
        if row=={} {continue}
        append(&materials,Named{row,material_names[index] if material_names[index]!="" else fmt.tprintf("material row %d",index)})
    }
    slice.sort_by(meshes[:],proc(x,y:Named) -> bool {return u64(x.row.triangles)+u64(x.row.shadow_triangles)>u64(y.row.triangles)+u64(y.row.shadow_triangles)})
    slice.sort_by(materials[:],proc(x,y:Named) -> bool {
        if x.row.pixels!=y.row.pixels {return x.row.pixels>y.row.pixels}
        return u64(x.row.triangles)+u64(x.row.shadow_triangles)>u64(y.row.triangles)+u64(y.row.shadow_triangles)
    })
    out.frame,out.total=cost.frame,row_of(total,"")
    out.meshes=make([]Api_Profile_Cost_Row,min(top,len(meshes)))
    for &row,i in out.meshes {row=row_of(meshes[i].row,meshes[i].name)}
    out.materials=make([]Api_Profile_Cost_Row,min(top,len(materials)))
    for &row,i in out.materials {row=row_of(materials[i].row,materials[i].name)}
    notes:=make([dynamic]string)
    append(&notes,"One frame of the viewport, as it was drawn: a still view keeps the pages of the maps it drew before, so shadow_* count only what that frame drew again")
    if total.shadow_over>0 {append(&notes,fmt.aprintf("%d clusters were left over the bound of the maps: their pages wait for the next frames",total.shadow_over))}
    out.notes=notes[:]
    return
}

// The asset of each mesh handle and each material row of a, in the temporary
// allocator; "" where none is known.
@(private="file")
profile_cost_names :: proc(a:^host.Assets,meshes,materials:int) -> (mesh_names,material_names:[]string) {
    mesh_names=make([]string,meshes,context.temp_allocator)
    material_names=make([]string,materials,context.temp_allocator)
    if materials>0 {material_names[0]="the default material"}
    if a==nil {return}
    for id,ref in a.index {
        text:[base.ASSET_ID_TEXT]u8
        #partial switch ref.kind {
        case .Mesh:
            handle:=int(a.meshes[ref.index].handle)
            if handle<meshes {mesh_names[handle]=strings.clone(host.assets_name(a,id,&text),context.temp_allocator)}
        case .Material:
            row:=int(a.materials[ref.index].row)
            if row>0 && row<materials {material_names[row]=strings.clone(host.assets_name(a,id,&text),context.temp_allocator)}
        }
    }
    for shape in host.Shape {
        if shape==.None || !a.shapes_ready[shape] {continue}
        handle:=int(a.shapes[shape].handle)
        if handle<meshes && mesh_names[handle]=="" {mesh_names[handle]=fmt.tprintf("the shape %v",shape)}
    }
    return
}
