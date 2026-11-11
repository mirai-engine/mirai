package anim

import "core:mem"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"
import "base:runtime"
import "mirai:std/jobs"

// What the renderer deforms a mesh with: the joints and influences of its
// skin and its morph targets, for the vertices of every level. A mesh with
// targets and without a skin is posed by one joint.
Skin_Rig :: struct {
    id:base.Asset_Id,
    stamp:[2]i64,
    checked,revision:u64,
    skeleton:base.Asset_Id,
    joints:[]asset.Rig_Joint,
    influences:[]erender.Skin_Influence,
    morphs:[]asset.Morph_Target,
    morph:erender.Morph_Data,
}
// A bone of the skeleton of this skinned mesh, with every bone under it, is a
// part in layers of its own: a camera that does not draw them, or that leaves
// them out of the body of its own player (render.Camera.own_hidden), draws the
// part collapsed into the bone, as a scale of zero on it would. Shadows,
// reflections and every other view draw it whole.
@(component,description="Puts a bone of this skinned mesh, with the bones under it, in layers that a camera can leave out, as the head of its own body seen from its eyes.")
Skin_Part :: struct {
    bone:Bone_Ref,
    layers:u32, // the part is in these instead of those of the mesh; 0: no part
}

Skin_Instance :: struct {
    pose:core.Entity,
    rig:u32,
    revision:u64,
    source,mesh:erender.Mesh_Handle, // the mesh of the world, and its copy the renderer deforms (copied)
    bound:u64,
    local,world:[]mm.Transform,
    palette:[]mm.Mat4,
    morph_weights:[]f32,       // those the renderer has
    seen:u64,
    exact:u64,                 // Playing.changed+1 of the pose the palette was made of, without interpolation; 0: none
    drawn,basis:mm.Transform,  // of the mesh and of the parent of the rig when it was made
    valid,reset:bool,
    copied:bool, // mesh was made: a rig is drawn as the mesh of the world until its palette leaves the bind pose
    part:int,                  // 1 + the bone of its Skin_Part; 0: none
    part_layers:u32,
    in_part:[]bool,            // by joint of the rig: it hangs from the bone of the part
    part_palette:[]mm.Mat4,    // the palette with the part collapsed into its bone
}

Skin_Update :: struct {slot:int,drawn,basis:mm.Transform,exact:u64}
// morphed: its weights changed, and go to the renderer with the palette or on their own.
Skin_Draw :: struct {work,slot:int,morphed:bool}

// The rigs of the meshes the application loaded, by asset: one per
// application, which every world reads.
@(storage,host,free="skin_runtime_free")
Skin_Runtime :: struct {
    allocator:mem.Allocator,
    rigs:[dynamic]Skin_Rig,
    rig_rows:map[base.Asset_Id]u32,
}

// The meshes a world deforms on the GPU, by entity: each world keeps its own.
@(storage,host,by_world,free="skin_instances_free")
Skin_Instances :: struct {
    allocator:mem.Allocator,
    instances:core.Entity_Map(Skin_Instance),
    work:[dynamic]Pose_Palette_Work,
    updates:[dynamic]Skin_Update,
    draws:[dynamic]Skin_Draw,
    candidates:[dynamic]Budget_Candidate,
    workspace:Palette_Workspace,
    frame:u64,
}

// Ends what an instance holds; taking it out of the map is the caller's.
@(private)
skin_instance_free :: proc(renderer:^erender.Renderer,instance:^Skin_Instance) {
    if instance.copied {erender.mesh_remove(renderer,instance.mesh)}
    delete(instance.local);delete(instance.world);delete(instance.palette);delete(instance.morph_weights)
    delete(instance.in_part);delete(instance.part_palette)
    instance^={}
}

// Makes the copy of the mesh of an instance that the renderer deforms.
@(private)
skin_copy :: proc(renderer:^erender.Renderer,instance:^Skin_Instance,rig:^Skin_Rig,problems:^core.Problems,entity:core.Entity) -> bool {
    mesh,created:=erender.skin_create(renderer,instance.source,rig.influences,u32(len(instance.palette)),rig.morph,instance.part>0)
    if !created {
        core.report(problems,entity,"animation.skin_gpu","the renderer refused to deform the mesh of this entity: its skin does not match its vertices or names joints it does not have, or memory ran out; import the mesh again, or free memory")
        return false
    }
    instance.mesh,instance.copied,instance.reset=mesh,true,true
    return true
}

// Whether a palette leaves every vertex where the bind puts it.
@(private)
palette_at_bind :: proc(palette:[]mm.Mat4) -> bool {
    for joint in palette {
        for column in 0..<4 {
            for row in 0..<4 {
                if abs(joint[row,column]-(1 if row==column else 0))>1e-5 {return false}
            }
        }
    }
    return true
}

@(private)
skin_rig_free :: proc(rig:^Skin_Rig) {
    delete(rig.joints);delete(rig.influences);delete(rig.morphs);delete(rig.morph.ranges);delete(rig.morph.deltas)
    rig.joints,rig.influences,rig.morphs,rig.morph=nil,nil,nil,{}
}

// The meshes a World deformed go with it when it is freed.
@(step="release")
animation_skin_release :: proc(state:^Skin_Instances,renderer:^erender.Renderer) {
    if state==nil {return}
    if state.allocator.procedure!=nil {context.allocator=state.allocator}
    for &instance in state.instances.values {skin_instance_free(renderer,&instance)}
    core.entity_map_clear(&state.instances)
}

// What the rigs hold in memory.
skin_runtime_free :: proc(state:^Skin_Runtime) {
    if state.allocator.procedure!=nil {context.allocator=state.allocator}
    for &rig in state.rigs {skin_rig_free(&rig)}
    delete(state.rigs);delete(state.rig_rows)
    state^={}
}

// What the instances of a world hold in memory. Their meshes go with the
// World that showed them (animation_skin_release) or with the renderer.
skin_instances_free :: proc(state:^Skin_Instances) {
    if state.allocator.procedure!=nil {context.allocator=state.allocator}
    for &instance in state.instances.values {skin_instance_free(nil,&instance)}
    core.entity_map_destroy(&state.instances)
    delete(state.work);delete(state.updates);delete(state.draws);delete(state.candidates);palette_workspace_free(&state.workspace)
    state^={}
}

// The rig of a mesh, read again when its file changes; max(u32) without
// memory for it. What makes it unreadable is a problem of entity e, which
// shows the mesh: a mesh made at runtime has no rig, nor does one the
// assets loaded without a skin or morphs, whose file is not read again.
@(private)
skin_rig_load :: proc(state:^Skin_Runtime,assets:^host.Assets,allocator:runtime.Allocator,id:base.Asset_Id,problems:^core.Problems,e:core.Entity)->u32 {
    if state.rig_rows==nil {state.rig_rows=make(map[base.Asset_Id]u32,allocator)}
    index,found:=state.rig_rows[id]
    if !found {
        index=u32(len(state.rigs))
        if _,error:=append(&state.rigs,Skin_Rig{id=id});error!=nil {memory_problem(problems,e,"the skin of its mesh");return max(u32)}
        if map_insert(&state.rig_rows,id,index)==nil {pop(&state.rigs);memory_problem(problems,e,"the skin of its mesh");return max(u32)}
    }
    rig:=&state.rigs[index]
    if rig.checked==assets_stamp(assets) {return index}
    record,exists:=asset.registry_find(&assets.registry,id)
    stamp:=[2]i64{}
    if exists {stamp={record.size,record.time}}
    if found && rig.checked!=0 && rig.stamp==stamp {rig.checked=assets_stamp(assets);return index}
    loaded:Skin_Rig
    error:=asset.Error.None if host.assets_mesh_generated(assets,id) else asset.Error.Not_Found
    if exists && !host.assets_mesh_rigged(assets,id) {
        error=.None
    } else if exists {loaded,error=skin_rig_read(assets,allocator,id)}
    if error==.Out_Of_Memory {rig.checked=0;memory_problem(problems,e,"the skin of its mesh");return max(u32)}
    asset_problem(problems,e,assets,"animation.skin_mesh","Mesh_Renderer.mesh",id,error)
    skin_rig_free(rig)
    rig.skeleton,rig.joints,rig.influences,rig.morphs,rig.morph=loaded.skeleton,loaded.joints,loaded.influences,loaded.morphs,loaded.morph
    rig.stamp,rig.checked=stamp,assets_stamp(assets);rig.revision+=1
    return index
}

@(private)
skin_rig_read :: proc(assets:^host.Assets,allocator:runtime.Allocator,id:base.Asset_Id) -> (Skin_Rig,asset.Error) {
    file:asset.Asset
    if error:=host.assets_file(assets,id,asset.KIND_MESH,&file);error!=.None {return {},error}
    defer asset.asset_close(&file)
    view,error:=asset.mesh_view(&file,&assets.types)
    if error!=.None {return {},error}
    if (len(view.skin)==0 || len(view.joints)==0) && len(view.morphs)==0 {return {},.None}
    if !asset.mesh_check_indices(view) {return {},.Corrupt}
    vertices:=len(view.vertices)
    joints,joint_error:=make([]asset.Rig_Joint,len(view.joints),allocator)
    influences,influence_error:=make([]erender.Skin_Influence,vertices,allocator)
    rig:=Skin_Rig{skeleton=view.info.skeleton,joints=joints,influences=influences}
    if joint_error!=nil || influence_error!=nil || !morph_rig_read(&rig,view,allocator) {
        context.allocator=allocator
        skin_rig_free(&rig)
        return {},.Out_Of_Memory
    }
    copy(joints,view.joints)
    // Those of every vertex of the mesh, of every level; without a skin its targets move it by one joint.
    if len(view.skin)>0 {copy(influences,view.skin)} else {for &influence in influences {influence.weights[0]=255}}
    return rig,.None
}

// Poses the meshes with a skin or morph targets on the GPU: a rig shows its
// own pose, a mesh with Pose_Source the pose of its rig, and a mesh with
// targets and no skin its weights alone, by one joint. The copy it poses is
// the mesh the renderer draws its entity with (erender.Posed_Meshes): placed,
// tinted, hidden and outlined as any mesh of an entity. The material values
// the curves of a rig move are the Material_Live of its meshes.
@(step="render",loops="game editor",before="render_sync")
animation_skin :: proc(
    meshes:^core.Table(erender.Mesh_Renderer,.Read),skins:^core.Table(Pose_Source,.Read),parents:^core.Table(core.Parent,.Read),
    worlds:^core.Table(core.World_Transform,.Read),lives:^core.Table(erender.Material_Live),
    hidden:^core.Table(erender.Hidden,.Read),elsewhere:^core.Table(erender.Drawn_Elsewhere,.Read),
    cache:^Skin_Runtime,state:^Skin_Instances,assets:^host.Assets,renderer:^erender.Renderer,poses:^erender.Posed_Meshes,job_system:^jobs.Job_System,allocator:runtime.Allocator,time:core.Time,frame:core.Frame_Time,playback:core.Ref(Playback),
    morphs:core.Ref(Morph_Playback),problems:^core.Problems,
    policies:^core.Table(Animation_Budget,.Read),budget:^Budget_Runtime,config:Animation_Budget_Config,parts:^core.Table(Skin_Part,.Read),
    modifiers:core.Ref(Modifier_Runtime),
) {
    if state==nil || renderer==nil || assets==nil {return}
    context.allocator=allocator
    state.allocator,cache.allocator=allocator,allocator
    state.frame+=1
    rigs:=playback.ptr.rigs[:] if playback.ptr!=nil else nil
    morphing:=morphs.ptr.states[:] if morphs.ptr!=nil else nil
    posed:=len(rigs)+core.count(skins)
    capacity:=posed+len(morphing)
    if reserve(&state.work,capacity)!=nil || reserve(&state.updates,capacity)!=nil || reserve(&state.draws,capacity)!=nil || reserve(&state.candidates,capacity)!=nil {memory_problem(problems,core.NONE,"the skinned meshes of the world, so none is drawn in this frame");return}
    clear(&state.work);clear(&state.updates);clear(&state.draws);clear(&state.candidates)
    alpha:=mm.saturate(frame.alpha)
    for row in 0..<capacity {
        rigid:=row>=posed
        entity,owner:core.Entity
        switch {
        case row<len(rigs): entity=rigs[row].entity;owner=entity
        case !rigid:
            entity=core.entity_at(skins,row-len(rigs));owner=core.at(skins,row-len(rigs)).rig
            // A mesh of another skeleton than its rig's is a rig that follows it, drawn above.
            if playback.ptr!=nil && rig_find(playback.ptr,entity)>=0 {continue}
        case: entity=morphing[row-posed].entity
        }
        static,has_mesh:=core.get(meshes,entity)
        if !has_mesh {continue}
        pose:^Playing
        if !rigid {
            pose=constraint_playing(playback.ptr,owner)
            if pose==nil || !pose.pose_ready {continue}
        }
        if static.mesh=={} || core.has(elsewhere,entity) || erender.is_hidden(hidden,parents,entity) {continue}
        world,placed:=core.get(worlds,entity)
        if !placed {continue}
        rig_index:=skin_rig_load(cache,assets,allocator,static.mesh,problems,entity)
        if rig_index==max(u32) {continue}
        rig:=&cache.rigs[rig_index]
        if rigid!=(len(rig.joints)==0) || rigid && len(rig.morphs)==0 {continue}
        if !rigid && rig.skeleton!=pose.skeleton {
            mesh_name,skeleton_name,pose_name:[base.ASSET_ID_TEXT]u8
            core.report(problems,entity,"animation.skin_skeleton","mesh %s of this entity is skinned to skeleton %s, and the pose it follows (rig 0x%016x) is of skeleton %s, so it is not drawn; give it a mesh of that skeleton, or follow a rig of its own",host.assets_name(assets,static.mesh,&mesh_name),host.assets_name(assets,rig.skeleton,&skeleton_name),u64(owner),host.assets_name(assets,pose.skeleton,&pose_name))
            continue
        }
        slot:=core.entity_map_index(&state.instances,entity)
        if slot<0 {
            // The mesh of another generation of its index goes, and the new one takes its place.
            if held:=core.entity_map_held(&state.instances,entity);held!=core.NONE {skin_instance_free(renderer,core.entity_map_get(&state.instances,held))}
            if _,kept:=core.entity_map_put(&state.instances,entity,Skin_Instance{rig=max(u32)});!kept {memory_problem(problems,entity,"its skinned mesh");continue}
            slot=core.entity_map_index(&state.instances,entity)
        }
        instance:=&state.instances.values[slot]
        // The bone of its part, which its copy is made with or without.
        part,part_layers:=0,u32(0)
        if parts!=nil && !rigid {
            if config,has_part:=core.get(parts,entity);has_part && config.layers!=0 {
                bone:=bone_resolve(pose,config.bone)
                if bone<0 {
                    core.report(problems,entity,"animation.skin_part_bone","the Skin_Part of this entity names '%s', which the skeleton of its pose does not have, so the mesh is drawn whole; %s",base.text_get(config.bone.path[:]),bone_fix(config.bone))
                } else {part,part_layers=bone+1,config.layers}
            }
        }
        if instance.valid && instance.part!=part {skin_instance_free(renderer,instance);instance.rig=max(u32)}
        if instance.part_layers!=part_layers {instance.part_layers=part_layers;instance.reset=true}
        if instance.rig!=rig_index || instance.revision!=rig.revision {
            skin_instance_free(renderer,instance)
            instance.rig,instance.revision=rig_index,rig.revision
            instance.reset=true
        }
        instance.seen=state.frame
        source:=host.assets_mesh(assets,static.mesh)
        if source==nil || source.handle==host.ASSETS_MESH_NONE {continue}
        if !rigid && modifiers.ptr!=nil && !curve_materials_apply(modifiers.ptr,pose,int(source.slot_count),lives,entity) {
            core.report(problems,entity,"animation.curve_material","the curve materials of the .character of the rig of this entity set more than %d material values, so some are not drawn; move fewer values, or fewer slots",erender.MATERIAL_VALUES_CAPACITY)
        }
        bones:=len(pose.local) if !rigid else 0
        // Not drawn in the last frame (new, or shown again): it shows the pose and the weights of the
        // tick, not an interpolation from those of a tick it was not drawn in, as the rest pose of a
        // weapon that is shown the tick its action starts.
        fresh:=!instance.valid
        if !instance.valid {
            local,local_error:=make([]mm.Transform,bones,allocator)
            world_pose,world_error:=make([]mm.Transform,bones,allocator)
            palette,palette_error:=make([]mm.Mat4,max(len(rig.joints),1),allocator)
            weights,weight_error:=make([]f32,len(rig.morphs),allocator)
            if local_error!=nil || world_error!=nil || palette_error!=nil || weight_error!=nil {delete(local);delete(world_pose);delete(palette);delete(weights);memory_problem(problems,entity,"its skinned mesh");continue}
            if rigid {palette[0]=1}
            instance.source,instance.valid,instance.local,instance.world,instance.palette,instance.morph_weights=source.handle,true,local,world_pose,palette,weights
            instance.part,instance.part_layers=part,part_layers
            if part>0 {
                in_part,in_error:=make([]bool,len(rig.joints),allocator)
                part_palette,part_error:=make([]mm.Mat4,len(rig.joints),allocator)
                if in_error!=nil || part_error!=nil {delete(in_part);delete(part_palette);skin_instance_free(renderer,instance);memory_problem(problems,entity,"its skinned mesh");continue}
                for joint,j in rig.joints {
                    for at:=int(joint.node)+1;at>=0 && at<len(pose.parents);at=int(pose.parents[at]) {
                        if at==part-1 {in_part[j]=true;break}
                    }
                }
                instance.in_part,instance.part_palette=in_part,part_palette
            }
            // Morphs deform from their first weights; a pose waits for a palette off the bind.
            if (rigid || len(rig.morphs)>0) && !skin_copy(renderer,instance,rig,problems,entity) {skin_instance_free(renderer,instance);continue}
        }
        if !rigid && (instance.pose!=owner || instance.bound!=pose.bound) {
            instance.pose=owner;instance.bound=pose.bound;instance.reset=true
        }
        if len(instance.local)!=bones {skin_instance_free(renderer,instance);continue}
        // The weights of the tick the frame shows; those of the mesh until its targets are composed.
        morphed:=rigid && instance.reset
        if len(rig.morphs)>0 {
            playing:=morph_playing(morphs.ptr,entity)
            composed:=playing!=nil && playing.mesh==rig.id && playing.revision==rig.revision && len(playing.current)==len(rig.morphs) && len(playing.previous)==len(rig.morphs)
            for &target,t in rig.morphs {
                value:=mm.lerp(playing.previous[t],playing.current[t],1 if fresh else alpha) if composed else target.weight
                morphed ||= value!=instance.morph_weights[t]
                instance.morph_weights[t]=value
            }
        }
        work_index:=-1
        if !rigid {
            // Without a change in the last tick, previous and local are the same pose.
            // Shown as it is in this tick, it stays so until the next one rather than going back.
            exact:=alpha>=1 || fresh || pose.changed!=playback.ptr.frame || instance.exact==pose.changed+1
            basis:=mm.TRANSFORM_IDENTITY
            if parent,exists:=core.get(parents,owner);exists && parent.entity!=core.NONE {
                parent_world,parent_placed:=core.get(worlds,parent.entity)
                if !parent_placed {continue}
                basis=erender.drawn_transform(parent_world,frame)
            }
            drawn:=erender.drawn_transform(world,frame)
            if instance.reset || !exact || instance.exact!=pose.changed+1 || instance.drawn!=drawn || instance.basis!=basis {
                inverse,invertible:=mm.transform_inverse_matrix(drawn)
                if !invertible {
                    core.report(problems,entity,"animation.skin_scale","the skinned mesh of this entity is not drawn: it or one of its parents has a scale of zero; give them a scale")
                    continue
                }
                policy:=ANIMATION_BUDGET_DEFAULT
                if policies!=nil {if value,present:=core.get(policies,owner);present {policy=value}}
                work_index=len(state.work)
                append(&state.work,Pose_Palette_Work{parents=pose.parents[:],previous=pose.previous[:],current=pose.local[:],local=instance.local,world=instance.world,joints=rig.joints,palette=instance.palette,basis=basis,inverse=inverse,alpha=1 if exact else alpha,bone_offset=1,enabled=true})
                append(&state.updates,Skin_Update{slot=slot,drawn=drawn,basis=basis,exact=pose.changed+1 if exact else 0})
                append(&state.candidates,Budget_Candidate{entity=entity,slot=u32(slot),policy=policy,force=instance.reset || !instance.copied || !time.playing})
            }
        }
        append(&state.draws,Skin_Draw{work=work_index,slot=slot,morphed=morphed})
    }
    if !palette_workspace_prepare(&state.workspace,len(state.instances.values),allocator) {memory_problem(problems,core.NONE,"the skinned meshes of the world, so none is drawn in this frame");return}
    if budget!=nil {
        if budget_prepare(budget,len(state.instances.values),problems) && budget_select(budget,state.candidates[:],state.frame,config,problems) {
            for &work,i in state.work {work.enabled=budget.selected[i]}
        }
    }
    system:=job_system if config.parallel else nil
    if !pose_palette_batch(system,state.work[:],&state.workspace,max(int(config.job_grain),1)) {
        for work,i in state.work {
            if work.enabled && !work.ok {core.report(problems,state.instances.entities[state.updates[i].slot],"animation.skin_pose","the skinned mesh of this entity is not drawn in this frame: its pose has a value that is not finite or its joints do not match its skeleton; check the pose (animation.analyze) and import the mesh again")}
        }
    }
    for work,i in state.work {
        if !work.enabled || !work.ok {continue}
        update:=state.updates[i];instance:=&state.instances.values[update.slot]
        if instance.part>0 {
            // Its part collapsed into the bone, where the drawn mesh has it.
            p:=instance.world[instance.part-1].position
            bone:=state.work[i].inverse*mm.Vec4{p.x,p.y,p.z,1}
            collapsed:=mm.Mat4{}
            collapsed[0,3],collapsed[1,3],collapsed[2,3],collapsed[3,3]=bone.x,bone.y,bone.z,1
            for joint,j in instance.palette {instance.part_palette[j]=collapsed if instance.in_part[j] else joint}
        }
        if !instance.copied {
            if instance.part==0 && palette_at_bind(instance.palette) {
                instance.reset=false;instance.exact=update.exact;instance.drawn,instance.basis=update.drawn,update.basis
                continue
            }
            if !skin_copy(renderer,instance,&cache.rigs[instance.rig],problems,state.instances.entities[update.slot]) {state.work[i].ok=false;continue}
        }
        if !erender.skin_update(renderer,instance.mesh,instance.palette,instance.reset,instance.morph_weights,{palette=instance.part_palette,layers=instance.part_layers}) {
            state.work[i].ok=false
            core.report(problems,state.instances.entities[update.slot],"animation.skin_gpu","the renderer refused the new pose of the skinned mesh of this entity, so it shows the last one: a joint of its palette or a morph weight is not finite or does not match the mesh; check the pose (animation.analyze)")
            continue
        }
        instance.reset=false;instance.exact=update.exact;instance.drawn,instance.basis=update.drawn,update.basis
    }
    for &draw in state.draws {
        if !state.instances.values[draw.slot].copied {continue}
        if draw.work>=0 && state.work[draw.work].enabled {
            if !state.work[draw.work].ok {continue}
        } else if draw.morphed {
            // New weights over the palette the renderer has.
            instance:=&state.instances.values[draw.slot]
            if !erender.skin_update(renderer,instance.mesh,instance.palette,instance.reset,instance.morph_weights) {
                core.report(problems,state.instances.entities[draw.slot],"animation.skin_gpu","the renderer refused the new morph weights of the mesh of this entity, so it shows the last ones: a weight is not finite or their count does not match the mesh; check them (animation.inspect)")
                continue
            }
            instance.reset=false
        }
        // A copy that still goes to the GPU is the mesh of its entity too: the renderer
        // draws nothing of it until all of the copy went, and it shows posed.
        if !erender.posed_set(poses,state.instances.entities[draw.slot],{mesh=state.instances.values[draw.slot].mesh}) {
            memory_problem(problems,state.instances.entities[draw.slot],"its skinned mesh")
        }
    }
    #reverse for &instance,at in state.instances.values {
        // At the bind pose the mesh of the world is drawn, shared with the other rigs of the mesh.
        if instance.seen==state.frame && instance.copied {continue}
        erender.posed_drop(poses,state.instances.entities[at])
        if instance.seen==state.frame {continue}
        skin_instance_free(renderer,&instance)
        core.entity_map_remove_at(&state.instances,at)
    }
}
