package physics

import "mirai:core"
import "mirai:host"
import render "mirai:engine/render"
import "mirai:std/base"
import "mirai:std/geom"
import "mirai:std/jobs"
import mm "mirai:std/math"
import sim "plugins:physics/runtime/sim"

// Bodies of the simulation that another library owns: static collision it makes from its own data, as the
// cells of a foliage. The library makes and ends them here and keeps their handles, which live with the world
// as the simulation does: a copy for Play or a rollback takes both. Physics never makes, moves or ends one by
// itself, and knows whose each one is, so a hit on one names its owner without the owner looking for it.

Body_Handle :: sim.Body_Handle
Shape_Handle :: sim.Shape_Handle
Hull_Handle :: sim.Hull_Handle

// The library that owns a body: a number it declares for itself, never zero.
Body_Owner :: distinct u32

// What a body is to its owner: the entity its hits name and the owner's own index of it.
Owned_Body :: struct {
    owner:Body_Owner,
    entity:core.Entity,
    user:u64,
}

// A shape of an owned body: a Box, Sphere, Capsule, Cylinder or Hull collider where position and rotation put
// it in the frame of the body, with the collision of the collider; user is what its owner knows it by.
Owned_Shape :: struct {
    collider:Collider,
    position:[3]f32,
    rotation:mm.Quat,
    user:u64,
    hull:Hull_Handle, // of a Hull collider: one of owned_hulls, which shapes of every scale share
    scale:[3]f32,     // of that hull along its axes, each above 0
}

// By the slot of its body.
@(private)
Owned :: struct {body:Body_Handle,owner:Body_Owner,user:u64}

@(private)
owned_find :: proc(state:^Physics_State,body:Body_Handle) -> ^Owned {
    if state==nil || !state.ready || body=={} {return nil}
    slot:=int(base.handle_index(base.Handle(body)))
    if slot>=len(state.owned) || state.owned[slot].body!=body || !sim.body_valid(&state.world,body) {return nil}
    return &state.owned[slot]
}

Owned_Error :: enum u8 {
    None,
    Invalid,       // no simulation, or no owner
    Capacity,      // Physics_Settings.bodies are in use
    Out_Of_Memory,
}

// Makes a static body of its owner at a world pose; zero with the reason when it is not made.
owned_body_create :: proc(state:^Physics_State,body:Owned_Body,position:[3]f32,rotation:mm.Quat) -> (made:Body_Handle,error:Owned_Error) {
    if state==nil || !state.ready || body.owner==0 {return {},.Invalid}
    made=sim.body_create(&state.world,{type=.Static,position=position,rotation=rotation,user_data=u64(body.entity)})
    if made=={} {return {},.Capacity}
    slot:=int(base.handle_index(base.Handle(made)))
    if slot>=len(state.owned) {
        count:=min(max(slot+1,2*len(state.owned)),state.world.desc.body_capacity)
        if resize(&state.owned,count)!=nil || resize(&state.owned_stamps,base.chunks_of(count))!=nil {
            sim.body_destroy(&state.world,made)
            return {},.Out_Of_Memory
        }
    }
    state.owned[slot]={made,body.owner,body.user}
    slot_stamp(state,state.owned_stamps[:],slot)
    return made,.None
}

// Ends an owned body with its shapes. False for a body that is not owned, or is gone.
owned_body_destroy :: proc(state:^Physics_State,body:Body_Handle) -> bool {
    owned:=owned_find(state,body)
    if owned==nil {return false}
    owned^={}
    sim.body_destroy(&state.world,body)
    return true
}

// Puts an owned body at a world pose, as its owner moves what it made: what touches it wakes and is not pushed.
// False for a body that is not owned, or is gone.
owned_body_place :: proc(state:^Physics_State,body:Body_Handle,position:[3]f32,rotation:mm.Quat) -> bool {
    if owned_find(state,body)==nil {return false}
    sim.body_set_transform(&state.world,body,position,rotation)
    return true
}

// What an owned body is to its owner; false for any other body.
owned_body_of :: proc(state:^Physics_State,body:Body_Handle) -> (found:Owned_Body,ok:bool) {
    owned:=owned_find(state,body)
    if owned==nil {return}
    return {owned.owner,core.Entity(sim.body_user_data(&state.world,body)),owned.user},true
}

// Gives an owned body a shape. Zero when the body is not owned, the collider is not of those kinds, or the
// simulation has no room for it (Physics_Settings.shapes).
owned_shape_create :: proc(state:^Physics_State,collision:^Collision_Settings,body:Body_Handle,shape:Owned_Shape) -> Shape_Handle {
    if owned_find(state,body)==nil {return {}}
    #partial switch shape.collider.kind {
    case .Mesh,.Heightfield,.External,.Auto: return {}
    }
    desc:=collider_desc(shape.collider,{1,1,1},collision_filter(collision,shape.collider),core.NONE)
    if shape.collider.kind==.Hull {desc.geometry,desc.scale=shape.hull,shape.scale}
    position:=shape.position
    if shape.collider.center!={} {position+=mm.quat_rotate(shape.rotation,shape.collider.center)}
    desc.transform={position,shape.rotation}
    desc.user_data=shape.user
    return sim.shape_create(&state.world,body,desc,false)
}

// The convex hulls of what a mesh shows, at scale 1, appended to out for owned shapes of Hull colliders to
// share at their own scales: the shapes its mesh stores from its source; without them, the convex pieces
// of a decomposition of its triangles (an owned shape is convex), read and decomposed in a job of meshes;
// or one hull of all its points. A collider of any body made from the same mesh at scale 1 shares them too.
// Whoever asks for them gives each to owned_hull_release once its shapes are gone. False, with nothing
// appended, when the mesh cannot be read, a piece has no volume, or the simulation has no room for them
// (Physics_Settings.hulls); waiting, while the job reads its file: ask again in a later tick.
owned_hulls :: proc(state:^Physics_State,meshes:^Collider_Meshes,app:^host.App,mesh:render.Mesh_Renderer,out:^[dynamic]Hull_Handle) -> (ok,waiting:bool) {
    if state==nil || !state.ready {return}
    assets:=app!=nil?app.assets:nil
    points:=make([dynamic]geom.Vec3,context.temp_allocator)
    sizes:=make([dynamic]u32,context.temp_allocator)
    decomposed:=false
    if _,_,is_file:=mesh_file_version(app,mesh.mesh);is_file {
        inline:=jobs.worker_count(&app.jobs)<=1
        file:^Mesh_File
        if file,waiting=mesh_file_of(meshes,app,inline,mesh.mesh,.Hull,false);waiting || file==nil {return}
        if file.pieces {
            append(&points,..file.piece_points[:])
            append(&sizes,..file.piece_sizes[:])
        } else if file.stored==.None {
            whole:^Mesh_File
            if whole,waiting=mesh_file_of(meshes,app,inline,mesh.mesh,.Hull,true);waiting {return}
            if whole!=nil && whole.pieces {
                append(&points,..whole.piece_points[:])
                append(&sizes,..whole.piece_sizes[:])
                decomposed=true
            }
        }
        if len(sizes)<2 {
            clear(&points);clear(&sizes)
            decomposed=false
            if !file.found || len(file.geometry.positions)==0 {return}
            append(&points,..file.geometry.positions[:])
            append(&sizes,u32(len(file.geometry.positions)))
        }
    } else if !host.assets_collision_hulls(assets,mesh.mesh,mesh.shape,&points,&sizes) || len(sizes)<2 {
        clear(&points);clear(&sizes)
        buffer:geom.Mesh_Buffer
        geom.mesh_buffer_init(&buffer,context.temp_allocator)
        if _,found:=host.assets_collision(assets,mesh.mesh,mesh.shape,.Hull,&buffer);!found || len(buffer.positions)==0 {return}
        append(&points,..buffer.positions[:])
        append(&sizes,u32(len(buffer.positions)))
    }
    source,shareable:=geometry_source_of(assets,decomposed?.Auto:.Hull,mesh,{1,1,1},0)
    held:=len(out)
    from:=0
    for size,at in sizes {
        if int(size)>len(points)-from {base.truncate(out,held);return}
        piece:=points[from:][:size]
        from+=int(size)
        source.piece=len(sizes)>1?u32(at+1):0
        hull:Hull_Handle
        if shareable {
            if shared,found:=geometry_shared(state,source);found {hull,_=shared.(sim.Hull_Handle)}
        }
        if hull=={} {
            made,failure:=hull_make(&state.world,piece,0)
            solid:bool
            if hull,solid=made.(sim.Hull_Handle);failure!=.None || !solid {
                if mesh,is_mesh:=made.(sim.Mesh_Handle);is_mesh {sim.mesh_destroy(&state.world,mesh)}
                for made_hull in out[held:] {sim.hull_destroy(&state.world,made_hull)}
                base.truncate(out,held)
                return
            }
            if shareable {geometry_remember(state,hull,source)}
        }
        if _,error:=append(out,hull);error!=nil {
            sim.hull_destroy(&state.world,hull)
            for made_hull in out[held:] {sim.hull_destroy(&state.world,made_hull)}
            base.truncate(out,held)
            return
        }
    }
    return true,false
}

// Frees a hull of owned_hulls once no shape of any body uses it; false while one does, or when it is gone.
owned_hull_release :: proc(state:^Physics_State,hull:Hull_Handle) -> bool {
    return state!=nil && state.ready && sim.hull_destroy(&state.world,hull)
}

// Ends one shape of an owned body, which keeps the others. False when it is not one, or is gone.
owned_shape_destroy :: proc(state:^Physics_State,shape:Shape_Handle) -> bool {
    if _,ok:=owned_shape_user(state,shape);!ok {return false}
    sim.shape_destroy(&state.world,shape,false)
    return true
}

// What the owner of a shape of an owned body knows it by; false for any other shape.
owned_shape_user :: proc(state:^Physics_State,shape:Shape_Handle) -> (user:u64,ok:bool) {
    if state==nil || !state.ready || !sim.shape_valid(&state.world,shape) || owned_find(state,sim.shape_body(&state.world,shape))==nil {return}
    return sim.shape_user_data(&state.world,shape),true
}

// Whether the simulation was replaced (a copy, a swap, a reset) since seen was last given here: what a cache
// outside the world keeps of its bodies is then of another simulation.
simulation_replaced :: proc(state:^Physics_State,seen:^u32) -> bool {
    if seen^==state.epoch {return false}
    seen^=state.epoch
    return true
}

// The capacities the simulation of a world is made with: those of the settings, and the default of each one
// left at zero.
settings_capacities :: proc(settings:Physics_Settings) -> Physics_Settings {
    desc:=sim.world_desc_default()
    s:=settings
    if s.bodies<=0 {s.bodies=i32(desc.body_capacity)}
    if s.shapes<=0 {s.shapes=i32(desc.shape_capacity)}
    if s.contacts<=0 {s.contacts=i32(desc.contact_capacity)}
    if s.joints<=0 {s.joints=i32(desc.joint_capacity)}
    if s.characters<=0 {s.characters=i32(desc.character_capacity)}
    if s.fluids<=0 {s.fluids=i32(desc.fluid_capacity)}
    if s.breakables<=0 {s.breakables=i32(desc.breakable_capacity)}
    if s.pieces<=0 {s.pieces=i32(desc.piece_capacity)}
    if s.bonds<=0 {s.bonds=i32(desc.bond_capacity)}
    if s.hulls<=0 {s.hulls=i32(desc.hull_capacity)}
    if s.meshes<=0 {s.meshes=i32(desc.mesh_capacity)}
    if s.heightfields<=0 {s.heightfields=i32(desc.heightfield_capacity)}
    if s.events<=0 {s.events=i32(desc.event_capacity)}
    if s.substeps<=0 {s.substeps=i32(desc.substeps)}
    return s
}
