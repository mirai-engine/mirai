package build

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:cook/shaders"
import "mirai:project"
import "mirai:render/abi"
import "mirai:std/base"

// What the assets of a project draw its Surface programs as, which the
// generation compiles their stages for (shaders.Options.uses): a material
// that names a program draws it by its alpha mode (Opaque for opaque and
// masked, Blend for blended and transmissive), and one an overlay of another material names
// as an overlay; an entity of a scene or a prefab draws so the materials it
// gives overlays and those whose alpha its values change. An asset of a kind whose plugin declares program_uses
// (project.Asset_Kind) draws so the programs of the materials it depends on,
// and of those the meshes it depends on name. What a program says of itself
// (`//! use`) the generation adds. Sorted by program; problem: a plugin
// names a use that does not exist.
program_uses :: proc(p:^project.Project,allocator:=context.allocator) -> (uses:[]shaders.Program_Uses_Of,problem:string) {
    Material :: struct {program:string,info:asset.Material_Info,overlays:[]base.Asset_Id}
    Drawing :: struct {dependencies:[]base.Asset_Id,uses:abi.Program_Uses}
    // An entity whose Material_Values give it overlays or values of its own.
    Look :: struct {renderer:Uses_Renderer,values:Uses_Values}
    materials:=make(map[base.Asset_Id]Material,context.temp_allocator)
    meshes:=make(map[base.Asset_Id][]base.Asset_Id,context.temp_allocator)
    drawings:=make([dynamic]Drawing,context.temp_allocator)
    looks:=make([dynamic]Look,context.temp_allocator)
    // The kinds of the active plugins that draw programs, by extension.
    kinds:=make(map[string]abi.Program_Uses,context.temp_allocator)
    for index in p.active {
        plugin:=&p.plugins[index]
        for &kind in plugin.manifest.asset_kinds {
            extension:=base.text_get(kind.extension[:])
            if extension=="" {continue}
            drawn:abi.Program_Uses
            for &name in kind.program_uses {
                word:=base.text_get(name[:])
                if word=="" {continue}
                use,known:=abi.program_use_named(word)
                if !known {
                    names:=abi.PROGRAM_USE_NAMES
                    return nil,fmt.aprintf("the plugin %s says its %s assets draw programs as %s, which is no use: the uses are %s",base.text_get(plugin.manifest.name[:]),extension,word,strings.join(slice.enumerated_array(&names),", ",context.temp_allocator),allocator=allocator)
                }
                drawn+={use}
            }
            if drawn!={} {kinds[strings.clone(extension,context.temp_allocator)]=drawn}
        }
    }
    types:asset.Types
    asset.types_init(&types,context.temp_allocator)
    visit :: proc(path:string,types:^asset.Types,kinds:map[string]abi.Program_Uses,materials:^map[base.Asset_Id]Material,meshes:^map[base.Asset_Id][]base.Asset_Id,drawings:^[dynamic]Drawing,looks:^[dynamic]Look) {
        extension:=path[strings.last_index_byte(path,'.'):] if strings.last_index_byte(path,'.')>=0 else ""
        switch extension {
        case ".mat":
            file:asset.Asset
            if asset.asset_load(&file,path,context.temp_allocator)!=.None {return}
            defer asset.asset_close(&file)
            view,error:=asset.material_view(&file,types)
            if error!=.None {return}
            overlays:=make([]base.Asset_Id,len(view.overlays),context.temp_allocator)
            for overlay,i in view.overlays {overlays[i]=overlay.material}
            materials[file.blob.header.id]={strings.clone(base.text_get(view.info.program[:]),context.temp_allocator),view.info^,overlays}
        case ".scene":
            file:asset.Asset
            if asset.asset_load(&file,path,context.temp_allocator)!=.None {return}
            defer asset.asset_close(&file)
            view,error:=asset.scene_view(&file,types)
            if error!=.None {return}
            renderers,drawn:=scene_column(&file,&view,types,"Mesh_Renderer",Uses_Renderer)
            values,given:=scene_column(&file,&view,types,"Material_Values",Uses_Values)
            for row in 0..<len(view.ids) {
                if drawn!=nil && given!=nil && drawn[row] && given[row] && (values[row].own_overlays || values[row].count>0) {append(looks,Look{renderers[row],values[row]})}
            }
        case ".mesh":
            dependencies:=make([dynamic]base.Asset_Id,context.temp_allocator)
            if header,_,_,error:=asset.import_peek(path,types,&dependencies);error==.None {meshes[header.id]=dependencies[:]}
        case:
            drawn,draws:=kinds[extension]
            if !draws {return}
            dependencies:=make([dynamic]base.Asset_Id,context.temp_allocator)
            if _,_,_,error:=asset.import_peek(path,types,&dependencies);error==.None {append(drawings,Drawing{dependencies[:],drawn})}
        }
    }
    for folder in project.asset_folders(p,context.temp_allocator) {
        if os.is_dir(folder.path) {
            w:=os.walker_create(folder.path)
            for info in os.walker_walk(&w) {
                if info.type==.Regular {visit(strings.clone(info.fullpath,context.temp_allocator),&types,kinds,&materials,&meshes,&drawings,&looks)}
            }
            os.walker_destroy(&w)
        }
        // The meshes of the packages the root pins are blobs of the store: the
        // materials each depends on are those its manifest lists.
        list,_,_:=asset.packages_load(folder.root,context.temp_allocator)
        for &entry in list.packages {
            text,read_error:=os.read_entire_file(asset.package_file(folder.root,entry.id),context.temp_allocator)
            if read_error!=nil {continue}
            pinned,parse_error:=asset.package_parse(string(text),context.temp_allocator)
            if parse_error!=.None {continue}
            for &a in pinned.assets {
                if a.kind==asset.KIND_MESH {meshes[a.id]=a.dependencies[:]}
            }
        }
    }
    found:=make(map[string]abi.Program_Uses,context.temp_allocator)
    add :: proc(found:^map[string]abi.Program_Uses,materials:map[base.Asset_Id]Material,id:base.Asset_Id,uses:abi.Program_Uses) {
        if m,known:=materials[id];known && m.program!="" {found[m.program]=found[m.program]+uses}
    }
    for id,m in materials {
        add(&found,materials,id,drawn_as(m.info))
        for overlay in m.overlays {add(&found,materials,overlay,{.Overlay})}
    }
    for &look in looks {
        v:=&look.values
        if v.own_overlays {
            for overlay in v.overlays[:min(int(v.overlay_count),len(v.overlays))] {add(&found,materials,overlay.material,{.Overlay})}
        }
        // The values of a slot over its material, or over every material of
        // the mesh when the slot takes the mesh's, whose slots it does not know.
        count:=min(int(v.count),len(v.names))
        for slot in 0..<abi.MATERIAL_SLOTS {
            if look.renderer.materials[slot]=={} && look.renderer.mesh=={} {continue}
            given:=false
            for k in 0..<count {given||=int(v.slots[k])==slot}
            if !given {continue}
            candidates:=look.renderer.materials[slot:][:1] if look.renderer.materials[slot]!={} else meshes[look.renderer.mesh]
            for id in candidates {
                m,known:=materials[id]
                if !known || m.program=="" {continue}
                info:=m.info
                for k in 0..<count {
                    value:=v.values[k]
                    if int(v.slots[k])==slot {asset.material_standard_value(&info,v.names[k],&value,true)}
                }
                add(&found,materials,id,drawn_as(info))
            }
        }
    }
    for drawing in drawings {
        for id in drawing.dependencies {
            add(&found,materials,id,drawing.uses)
            for material in meshes[id] {add(&found,materials,material,drawing.uses)}
        }
    }
    list:=make([dynamic]shaders.Program_Uses_Of,0,len(found),allocator)
    for name,drawn in found {append(&list,shaders.Program_Uses_Of{strings.clone(name,allocator),drawn})}
    slice.sort_by(list[:],proc(a,b:shaders.Program_Uses_Of) -> bool {return a.program<b.program})
    return list[:],""
}

// The fields of the Mesh_Renderer and the Material_Values of engine/render
// that program_uses reads from a scene, by name.
@(private="file")
Uses_Renderer :: struct {
    mesh:base.Asset_Id,
    materials:[abi.MATERIAL_SLOTS]base.Asset_Id,
}
@(private="file")
Uses_Values :: struct {
    count:u32,
    slots:[abi.INSTANCE_VALUES_MAX]u8,
    names:[abi.INSTANCE_VALUES_MAX]u64,
    values:[abi.INSTANCE_VALUES_MAX][4]f32,
    own_overlays:bool,
    overlay_count:u32,
    overlays:[asset.MATERIAL_MAX_OVERLAYS]asset.Material_Overlay,
}

// What a material is drawn as by its values: a transmissive one is drawn
// blended unless it is masked.
@(private="file")
drawn_as :: proc(info:asset.Material_Info) -> abi.Program_Uses {
    return {.Blend} if info.alpha_mode==.Blend || info.transmission>0 && info.alpha_mode!=.Mask else {.Opaque}
}

// The values of a component of every entity row of a scene, read as T, and
// which rows have it; nil when the scene has none. Temporary memory.
@(private="file")
scene_column :: proc(file:^asset.Asset,view:^asset.Scene_View,types:^asset.Types,name:string,$T:typeid) -> (values:[]T,has:[]bool) {
    for &component in view.components {
        if component.name!=name {continue}
        index,known:=asset.types_index(types,T)
        if !known {return}
        read:=make([]T,len(component.entities),context.temp_allocator)
        if asset.scene_component_read(file,&component,&types.schema,index,mem.slice_to_bytes(read))!=.None {return nil,nil}
        values=make([]T,len(view.ids),context.temp_allocator)
        has=make([]bool,len(view.ids),context.temp_allocator)
        for row,i in component.entities {
            if int(row)<len(view.ids) {values[row],has[row]=read[i],true}
        }
        return
    }
    return
}
