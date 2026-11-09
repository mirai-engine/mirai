package vfx_editor

import "core:fmt"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import vfx "plugins:vfx/runtime"
import "plugins:vfx/runtime/gridfile"

// particle.grid.bake: the cells of the grid of an entity of the edited world
// as its steps leave them, written as a .grid at path (one there already
// takes the new state) in one undo step. A Particle_Grid that names the file
// in cached starts from it.
@(private)
Api_Grid_Bake_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    path:[editor.API_PATH_BYTES]u8 `mirai:"text"`,
}

// A bake a particle.grid.bake holds its call for: the file it writes when the
// cells come back from the GPU, frames later.
@(private)
Grid_Bake_Wait :: struct {
    id:base.Asset_Id,
    file:[editor.API_PATH_BYTES]u8, // in the project
    taken,written:bool,
}

@(private)
GRID_BAKE_FRAMES_MAX :: 30 // waited for the cells before the bake is given up

@(private)
api_grid_bake :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Api_Grid_Bake_Params)
    a:=s.app.assets
    if a==nil || !s.has_project || s.app.renderer==nil {
        api.call_fail(call,api.SERVER_ERROR,"particle.grid.bake needs a project and a GPU")
        return
    }
    w:=editor.edited_world(s)
    e,found_e:=editor.api_call_entity(call,w,p.entity[:])
    if !found_e {return}
    if !editor.entity_has(w,e,vfx.Particle_Grid) {
        api.call_failf(call,api.INVALID_PARAMS,"%s is not an entity with a Particle_Grid in the edited world",base.text_get(p.entity[:]))
        return
    }
    named:=base.text_get(p.path[:])
    if named=="" {
        api.call_fail(call,api.INVALID_PARAMS,"path is required")
        return
    }
    path:=named if strings.has_suffix(named,gridfile.EXTENSION) else fmt.tprintf("%s%s",named,gridfile.EXTENSION)
    target:=editor.scene_file(s,path)
    if target=="" {
        api.call_failf(call,api.INVALID_PARAMS,"%s: %s",path,editor.document_error_text(.Bad_Path))
        return
    }
    sync:=host.app_world_storage(s.app,s.edit_world,vfx.Particle_Sync)
    if sync==nil || !vfx.grid_bake_ask(sync,e) {
        // What the grids of the world said of it, when they refused it.
        if problem:=core.problem_find(host.app_world_storage(s.app,w.data,core.Problems),e,"vfx.grid");problem!=nil {
            api.call_failf(call,api.INVALID_PARAMS,"The grid is not drawn: %s",core.problem_text(problem))
            return
        }
        api.call_fail(call,api.INVALID_PARAMS,"The grid is not drawn yet: give it a valid name and cells, and let a frame draw it")
        return
    }
    id:=editor.asset_id_new(s)
    if file,found:=asset.registry_find_path(&a.registry,path);found && file.kind==gridfile.KIND {id=file.id}
    wait:=Grid_Bake_Wait{id=id}
    base.text_set(wait.file[:],target)
    answer:[editor.API_PATH_BYTES]u8
    base.text_set(answer[:],path)
    if !editor.api_settle(s,&wait,grid_bake_wait,GRID_BAKE_FRAMES_MAX) || !wait.taken {
        if sync=host.app_world_storage(s.app,s.edit_world,vfx.Particle_Sync);sync!=nil {vfx.grid_bake_cancel(sync)}
        api.call_fail(call,api.SERVER_ERROR,"The cells of the grid did not come back from the GPU; call particle.grid.bake again, and engine.diagnostics says what the GPU reported")
        return
    }
    if !wait.written {
        api.call_failf(call,api.SERVER_ERROR,"The state of the grid could not be written to %s",base.text_get(answer[:]))
        return
    }
    out:=call.out
    serial.write_u8(out,'{')
    api.write_key(out,"path",true)
    serial.text_write_string(out,base.text_get(answer[:]))
    api.write_key(out,"grid")
    serial.write_u8(out,'"')
    serial.text_write_asset_id(out,id)
    serial.write_u8(out,'"')
    serial.write_u8(out,'}')
}

// Whether the cells asked have still to come back; when they do, written as a
// step of its own of the history of the project, as an edit of an asset is.
@(private)
grid_bake_wait :: proc(s:^editor.Session,user:rawptr) -> bool {
    wait:=cast(^Grid_Bake_Wait)user
    app:=s.app
    sync:=host.app_world_storage(app,s.edit_world,vfx.Particle_Sync)
    if sync==nil {return false}
    info,cells,taken:=vfx.grid_bake_take(sync,app,host.app_world_id(app,s.edit_world),context.temp_allocator)
    if !taken {return true}
    wait.taken=true
    bytes,error:=gridfile.grid_bytes(&app.assets.types,{id=wait.id,info=info,cells=cells},context.temp_allocator)
    wait.written=error==.None && editor.file_write(s,base.text_get(wait.file[:]),bytes,"Bake grid")
    return false
}
