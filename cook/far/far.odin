package far

import "core:math/linalg"
import "core:mem"
import "mirai:asset"
import "mirai:core"
import "mirai:render/abi"
import "mirai:std/base"
import mm "mirai:std/math"

// The far mesh of a scene (its HLOD), a derived asset of the scene: the cook
// makes it beside every scene a section references (build.cook_assets), and
// in the editor the plugin streaming makes it in jobs and again when what it
// was made of changes. It is the static meshes of the scene and of the scenes
// it references (asset.mesh_build_far); what moves (a body or a character),
// what is not drawn and skinned meshes are left out. A build reads in rounds:
// whoever reads the files gives each one asked for (far_take) and asks what
// is still wanted (far_wanted) until nothing is; then far_make builds it.

// The angle a pixel spans, about, at the distance a section turns on with the
// default settings of streaming: the parts of a far mesh are cut at what it
// spans there, where its proxy starts to show; the renderer cuts the DAG
// coarser farther away.
FAR_ANGLE :: f32(1.0/1024)
FAR_DISTANCE :: 40 // m
FAR_ERROR :: FAR_ANGLE*FAR_DISTANCE

// The components whose entities a far mesh leaves out, with what hangs from
// them: what is not drawn, and what moves (a body, a character).
FAR_LEFT_OUT :: [?]string{"Hidden","Drawn_Elsewhere","Disabled","Rigid_Body","Character"}

// The extension of the file the cook writes beside a scene.
FAR_EXTENSION :: ".far.mesh"

// The fields of render.Mesh_Renderer a far mesh reads, by name.
@(private)
Far_Renderer :: struct {
    mesh:base.Asset_Id,
    materials:[abi.MATERIAL_SLOTS]base.Asset_Id,
}

// The field of scene.Scene_Reference a far mesh reads, by name.
@(private)
Far_Reference :: struct {scene:base.Asset_Id}

// What a far mesh was made of: an asset and its content hash, 0 when it was
// asked for and there was none.
Far_Read :: struct {id:base.Asset_Id,hash:u64}

// A mesh of a scene placed in it, and the materials its renderer gives its slots.
Far_Gathered :: struct {
    mesh:base.Asset_Id,
    materials:[abi.MATERIAL_SLOTS]base.Asset_Id,
    placement:matrix[4,4]f32,
}

// A scene a scene references, placed in it.
Far_Inner :: struct {
    scene:base.Asset_Id,
    placement:matrix[4,4]f32,
}

// What a scene gives its far mesh.
Far_Of_Scene :: struct {
    parts:[dynamic]Far_Gathered,
    inner:[dynamic]Far_Inner,
}

@(private)
Far_Mesh_Read :: struct {
    file:asset.Asset,
    view:asset.Mesh_View,
}

// A far mesh being made; everything of it is in allocator.
Far_Build :: struct {
    scene:base.Asset_Id,
    allocator:mem.Allocator,
    asked:map[base.Asset_Id]bool,
    read:[dynamic]Far_Read,
    types:asset.Types,
    scenes:map[base.Asset_Id]Far_Of_Scene,
    meshes:map[base.Asset_Id]^Far_Mesh_Read,
    materials:map[base.Asset_Id]asset.Material_Info,
    textures:map[base.Asset_Id]^asset.Far_Texture,
    starved:bool, // something it read found no memory: no mesh is made of it
    untextured:bool, // it asks for no texture: what it reads is the shape of the scene and its materials (far_flat_blends)
}

// A build of the far mesh of scene, in allocator (an arena: far_destroy
// closes the files it holds, the arena frees the rest).
far_init :: proc(b:^Far_Build,scene:base.Asset_Id,allocator:mem.Allocator) {
    b^={scene=scene,allocator=allocator}
    b.asked=make(map[base.Asset_Id]bool,allocator)
    b.read=make([dynamic]Far_Read,allocator)
    asset.types_init(&b.types,allocator)
    b.scenes=make(map[base.Asset_Id]Far_Of_Scene,allocator)
    b.meshes=make(map[base.Asset_Id]^Far_Mesh_Read,allocator)
    b.materials=make(map[base.Asset_Id]asset.Material_Info,allocator)
    b.textures=make(map[base.Asset_Id]^asset.Far_Texture,allocator)
}

far_destroy :: proc(b:^Far_Build) {
    for _,m in b.meshes {asset.asset_close(&m.file)}
}

// Takes the file of an asset it asked for, open, which it closes or keeps; a
// file that did not open is nil and counts as read with hash.
far_take :: proc(b:^Far_Build,id:base.Asset_Id,hash:u64,file:^asset.Asset) {
    context.allocator=b.allocator
    append(&b.read,Far_Read{id,hash})
    if file==nil {return}
    switch file.blob.header.kind {
    case asset.KIND_SCENE:
        far_scene_read(b,id,file)
        asset.asset_close(file)
    case asset.KIND_MESH:
        m,allocation_error:=new(Far_Mesh_Read)
        if allocation_error!=nil {b.starved=true;asset.asset_close(file);return}
        m.file=file^
        file^={}
        view,error:=asset.mesh_view(&m.file,&b.types)
        if error!=.None {asset.asset_close(&m.file);return}
        m.view=view
        b.meshes[id]=m
    case asset.KIND_MATERIAL:
        if view,error:=asset.material_view(file,&b.types);error==.None {
            info:=view.info^
            // A program reads its textures from its parameters: the one that names a base color is it.
            if base.text_get(info.program[:])!="" && info.maps.base_color.texture=={} {
                if texture:=asset.far_base_parameter(view.parameters);texture!={} {info.maps.base_color={texture=texture,scale={1,1}}}
            }
            b.materials[id]=info
        }
        asset.asset_close(file)
    case asset.KIND_TEXTURE:
        if view,error:=asset.texture_view(file,&b.types);error==.None {
            if texture,ok:=asset.far_texture(view);ok {
                if t,allocation_error:=new(asset.Far_Texture);allocation_error==nil {
                    t^=texture
                    b.textures[id]=t
                } else {b.starved=true}
            }
        }
        asset.asset_close(file)
    case:
        asset.asset_close(file)
    }
}

// What the build still asks for, appended to out: the scenes not read yet,
// the meshes of their parts, the materials of their slots and the textures
// of those materials. Nothing: it can be made.
far_wanted :: proc(b:^Far_Build,out:^[dynamic]base.Asset_Id) {
    context.allocator=b.allocator
    parts:=make([dynamic]Far_Gathered,context.temp_allocator)
    far_expand(b,b.scene,linalg.MATRIX4F32_IDENTITY,0,&parts,out)
    for part in parts {
        m,read:=b.meshes[part.mesh]
        if !read {
            far_ask(b,part.mesh,out)
            continue
        }
        for slot,s in m.view.slots {
            material:=part.materials[s] if s<abi.MATERIAL_SLOTS else {}
            if material=={} {material=slot.material}
            far_ask(b,material,out)
            if info,known:=b.materials[material];known && !b.untextured {
                far_ask(b,info.maps.base_color.texture,out)
                far_ask(b,info.maps.metallic_roughness.texture,out)
                far_ask(b,info.maps.emission.texture,out)
            }
        }
    }
}

@(private)
far_ask :: proc(b:^Far_Build,id:base.Asset_Id,out:^[dynamic]base.Asset_Id) {
    if id=={} || id in b.asked {return}
    b.asked[id]=true
    append(out,id)
}

// The parts of a scene placed by placement, and those of the scenes it
// references, as far as they were read; asks for the scenes not read yet.
far_expand :: proc(b:^Far_Build,id:base.Asset_Id,placement:matrix[4,4]f32,depth:int,out:^[dynamic]Far_Gathered,wanted:^[dynamic]base.Asset_Id=nil) {
    of,read:=b.scenes[id]
    if !read {
        if wanted!=nil {far_ask(b,id,wanted)}
        return
    }
    for part in of.parts {
        placed:=part
        placed.placement=placement*part.placement
        append(out,placed)
    }
    if depth+1>=FAR_DEPTH {return}
    for inner in of.inner {far_expand(b,inner.scene,placement*inner.placement,depth+1,out,wanted)}
}

@(private) FAR_DEPTH :: 16 // scene.REFERENCE_DEPTH

// What a scene gives its far mesh: each entity with a Mesh_Renderer that is
// on and drawn, placed in the scene, and each Scene_Reference; not what
// moves, nor what hangs from it.
@(private)
far_scene_read :: proc(b:^Far_Build,id:base.Asset_Id,file:^asset.Asset) {
    s:asset.Scene
    if asset.scene_from_asset(&s,&b.types,file)!=.None {return}
    defer asset.scene_destroy(&s)
    of:Far_Of_Scene
    of.parts=make([dynamic]Far_Gathered)
    of.inner=make([dynamic]Far_Inner)
    defer b.scenes[id]=of
    count:=asset.scene_entity_count(&s)
    ids,parents:=asset.scene_ids(&s),asset.scene_parents(&s)
    // Where each entity is in the scene, its parents before it whatever their rows.
    placements:=make([]matrix[4,4]f32,count,context.temp_allocator)
    placed:=make([]bool,count,context.temp_allocator)
    left:=make([]bool,count,context.temp_allocator) // left out with what hangs from it
    for name in FAR_LEFT_OUT {
        table,found:=asset.scene_component(&s,name)
        if !found {continue}
        for row in 0..<count {
            if _,has:=asset.scene_component_get(&s,table,ids[row]);has {left[row]=true}
        }
    }
    place :: proc(s:^asset.Scene,row:int,ids,parents:[]base.Entity_Id,placements:[]matrix[4,4]f32,placed,left:[]bool,depth:int) {
        if placed[row] || depth>1024 {return}
        identity:=core.TRANSFORM_IDENTITY
        local,found:=asset.scene_get(s,ids[row],"Transform",core.Transform,&identity)
        if !found {local=identity}
        m:=mm.transform_matrix(transmute(mm.Transform)local)
        if parent,has:=asset.scene_entity_find(s,parents[row]);has && parents[row]!=0 {
            place(s,parent,ids,parents,placements,placed,left,depth+1)
            m=placements[parent]*m
            left[row]||=left[parent]
        }
        placements[row]=m
        placed[row]=true
    }
    renderer_hash:=base.name_hash("Mesh_Renderer")
    for row in 0..<count {
        place(&s,row,ids,parents,placements,placed,left,0)
        if left[row] {continue}
        if renderer,has:=asset.scene_get(&s,ids[row],"Mesh_Renderer",Far_Renderer);has && renderer.mesh!={} && !asset.scene_component_off(&s,ids[row],renderer_hash) {
            append(&of.parts,Far_Gathered{mesh=renderer.mesh,materials=renderer.materials,placement=placements[row]})
        }
        if reference,has:=asset.scene_get(&s,ids[row],"Scene_Reference",Far_Reference);has && reference.scene!={} {
            append(&of.inner,Far_Inner{reference.scene,placements[row]})
        }
    }
}

// Makes the far mesh of what was read into out, in allocator; false without
// static meshes, when something it read found no memory or when it does not
// build.
far_make :: proc(b:^Far_Build,out:^asset.Mesh_Geometry,allocator:mem.Allocator) -> bool {
    if b.starved {return false}
    parts:=make([dynamic]Far_Gathered,context.temp_allocator)
    far_expand(b,b.scene,linalg.MATRIX4F32_IDENTITY,0,&parts)
    far_parts:=make([dynamic]asset.Far_Part,context.temp_allocator)
    texture :: proc(b:^Far_Build,id:base.Asset_Id) -> ^asset.Far_Texture {
        if t,known:=b.textures[id];known {return t}
        return nil
    }
    for part in parts {
        m,read:=b.meshes[part.mesh]
        if !read || .Skinned in m.view.info.flags {continue}
        p:=asset.Far_Part{geometry=m.view.geometry,placement=part.placement}
        for slot,s in m.view.slots {
            if s>=asset.MESH_MAX_SLOTS {break}
            material:=part.materials[s] if s<abi.MATERIAL_SLOTS else {}
            if material=={} {material=slot.material}
            info,known:=b.materials[material]
            if !known {info=asset.MATERIAL_DEFAULTS}
            p.materials[s]=asset.far_material(info,texture(b,info.maps.base_color.texture),texture(b,info.maps.metallic_roughness.texture),texture(b,info.maps.emission.texture))
        }
        if len(m.view.slots)==0 {p.materials[0]=asset.far_material(asset.MATERIAL_DEFAULTS,nil,nil,nil)}
        append(&far_parts,p)
    }
    if len(far_parts)==0 {return false}
    return asset.mesh_build_far(far_parts[:],FAR_ERROR,out,allocator)
}

// The scenes the references of the scene of file name, appended to out once
// each: those whose far meshes the cook makes.
far_scenes :: proc(file:^asset.Asset,types:^asset.Types,out:^[dynamic]base.Asset_Id) {
    s:asset.Scene
    if asset.scene_from_asset(&s,types,file,context.temp_allocator)!=.None {return}
    defer asset.scene_destroy(&s)
    for id in asset.scene_ids(&s) {
        reference,has:=asset.scene_get(&s,id,"Scene_Reference",Far_Reference)
        if !has || reference.scene=={} {continue}
        known:=false
        for x in out {known||=x==reference.scene}
        if !known {append(out,reference.scene)}
    }
}

// Makes the far mesh of scene with the files of a registry, read here, into
// out in allocator: what the cook writes. False when it has no static meshes
// or does not build.
far_cook :: proc(registry:^asset.Registry,scene:base.Asset_Id,out:^asset.Mesh_Geometry,allocator:mem.Allocator) -> bool {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena,context.allocator,context.allocator)
    defer mem.dynamic_arena_destroy(&arena)
    b:Far_Build
    far_init(&b,scene,base.dynamic_arena_allocator(&arena))
    defer far_destroy(&b)
    far_registry_read(registry,&b)
    return far_make(&b,out,allocator)
}

// A part no thicker than this, or than a fiftieth of its width, is flat, m.
FAR_FLAT :: f32(0.01)
// How near the box of an opaque part a flat one lies on it, m.
FAR_ON :: f32(0.02)

// The static parts of scene, with what it references, that are flat, of
// blended materials without transmission, and lie on the box of an opaque
// part: surfaces drawn over others that a material of Alpha_Mode.Decal draws
// as part of them, lit and shadowed with them (mirai scene check).
far_flat_blends :: proc(registry:^asset.Registry,scene:base.Asset_Id) -> (count:int) {
    arena:mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena,context.allocator,context.allocator)
    defer mem.dynamic_arena_destroy(&arena)
    b:Far_Build
    far_init(&b,scene,base.dynamic_arena_allocator(&arena))
    defer far_destroy(&b)
    b.untextured=true
    far_registry_read(registry,&b)
    context.allocator=b.allocator
    parts:=make([dynamic]Far_Gathered)
    far_expand(&b,b.scene,linalg.MATRIX4F32_IDENTITY,0,&parts)
    Box :: struct {low,high:[3]f32}
    flat,opaque:=make([dynamic]Box),make([dynamic]Box)
    for part in parts {
        m,read:=b.meshes[part.mesh]
        if !read {continue}
        box:=Box{max(f32),-max(f32)}
        for corner in 0..<8 {
            local:=[3]f32{m.view.bounds_max.x if corner&1!=0 else m.view.bounds_min.x,m.view.bounds_max.y if corner&2!=0 else m.view.bounds_min.y,m.view.bounds_max.z if corner&4!=0 else m.view.bounds_min.z}
            at:=(part.placement*[4]f32{local.x,local.y,local.z,1}).xyz
            box.low,box.high=linalg.min(box.low,at),linalg.max(box.high,at)
        }
        blended,solid:=false,len(m.view.slots)==0
        for slot,s in m.view.slots {
            material:=part.materials[s] if s<abi.MATERIAL_SLOTS else {}
            if material=={} {material=slot.material}
            info,known:=b.materials[material]
            if !known {info=asset.MATERIAL_DEFAULTS}
            if asset.alpha_blended(info.alpha_mode) {blended||=info.transmission<=0} else if info.alpha_mode!=.Decal {solid=true}
        }
        size:=box.high-box.low
        if blended && !solid && min(size.x,size.y,size.z)<=max(FAR_FLAT,max(size.x,size.y,size.z)/50) {append(&flat,box)} else if solid {append(&opaque,box)}
    }
    for f in flat {
        for o in opaque {
            if f.low.x<=o.high.x+FAR_ON && f.low.y<=o.high.y+FAR_ON && f.low.z<=o.high.z+FAR_ON && f.high.x>=o.low.x-FAR_ON && f.high.y>=o.low.y-FAR_ON && f.high.z>=o.low.z-FAR_ON {count+=1;break}
        }
    }
    return
}

// Reads from a registry what a build asks for, until it asks for nothing.
@(private)
far_registry_read :: proc(registry:^asset.Registry,b:^Far_Build) {
    wanted:=make([dynamic]base.Asset_Id,context.temp_allocator)
    for {
        clear(&wanted)
        far_wanted(b,&wanted)
        if len(wanted)==0 {break}
        for id in wanted {
            record,found:=asset.registry_find(registry,id)
            if !found {
                far_take(b,id,0,nil)
                continue
            }
            file:asset.Asset
            opened:=asset.asset_load(&file,asset.registry_file_path(registry,record.path,context.temp_allocator),b.allocator)==.None
            far_take(b,id,record.content_hash,opened?&file:nil)
        }
    }
}
