package build

import "core:fmt"
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
// as an overlay. An asset of a kind whose plugin declares program_uses
// (project.Asset_Kind) draws so the programs of the materials it depends on,
// and of those the meshes it depends on name. What a program says of itself
// (`//! use`) the generation adds. Sorted by program; problem: a plugin
// names a use that does not exist.
program_uses :: proc(p:^project.Project,allocator:=context.allocator) -> (uses:[]shaders.Program_Uses_Of,problem:string) {
    Material :: struct {program:string,blended:bool,overlays:[]base.Asset_Id}
    Drawing :: struct {dependencies:[]base.Asset_Id,uses:abi.Program_Uses}
    materials:=make(map[base.Asset_Id]Material,context.temp_allocator)
    meshes:=make(map[base.Asset_Id][]base.Asset_Id,context.temp_allocator)
    drawings:=make([dynamic]Drawing,context.temp_allocator)
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
    visit :: proc(path:string,types:^asset.Types,kinds:map[string]abi.Program_Uses,materials:^map[base.Asset_Id]Material,meshes:^map[base.Asset_Id][]base.Asset_Id,drawings:^[dynamic]Drawing) {
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
            // A transmissive material is drawn blended unless it is masked.
            blended:=view.info.alpha_mode==.Blend || view.info.transmission>0 && view.info.alpha_mode!=.Mask
            materials[file.blob.header.id]={strings.clone(base.text_get(view.info.program[:]),context.temp_allocator),blended,overlays}
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
        for root in ([2]string{folder.path,folder.imported}) {
            if root=="" || !os.is_dir(root) {continue}
            w:=os.walker_create(root)
            for info in os.walker_walk(&w) {
                if info.type==.Regular {visit(strings.clone(info.fullpath,context.temp_allocator),&types,kinds,&materials,&meshes,&drawings)}
            }
            os.walker_destroy(&w)
        }
    }
    found:=make(map[string]abi.Program_Uses,context.temp_allocator)
    add :: proc(found:^map[string]abi.Program_Uses,materials:map[base.Asset_Id]Material,id:base.Asset_Id,uses:abi.Program_Uses) {
        if m,known:=materials[id];known && m.program!="" {found[m.program]=found[m.program]+uses}
    }
    for id,m in materials {
        add(&found,materials,id,{.Blend} if m.blended else {.Opaque})
        for overlay in m.overlays {add(&found,materials,overlay,{.Overlay})}
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
