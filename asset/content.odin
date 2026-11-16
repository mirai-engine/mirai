package asset

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// What a content tool (a program that writes the assets of a project) shares
// between its assets.
Content :: struct {
    types:Types,
    project:string, // a view
    failed:bool,    // something was not written; the tool exits with an error
}

content_init :: proc(content:^Content,project:string,allocator:=context.allocator) {
    content^={project=project}
    types_init(&content.types,allocator)
}

content_destroy :: proc(content:^Content) {
    types_destroy(&content.types)
    content^={}
}

// The id of an asset a tool writes: the same on every run, and apart from those of other projects.
content_id :: proc(project,kind,name:string) -> base.Asset_Id {
    return base.asset_id_named(fmt.tprintf("%s\x1f%s\x1f%s",kind,project,name))
}

// Makes the folder of a file a tool is about to write.
content_folder :: proc(path:string) {
    if at:=strings.last_index_byte(path,'/');at>0 {os.make_directory_all(path[:at])}
}

// Prints what was written, or why it was not and marks the tool as failed.
content_check :: proc(content:^Content,what:string,error:Error) {
    if error==.None {
        fmt.printfln("wrote %s",what)
        return
    }
    fmt.eprintfln("%s: %s: %v",content.project,what,error)
    content.failed=true
}

// Writes a mesh made from code (geom.*_build, one Mesh_Buffer per asset) to path,
// beside what it belongs to; materials are its slots in order, none: the engine's
// default, and the colors of the buffer multiply them. Its id, from the project
// and the path, is the same on every run.
content_mesh :: proc(c:^Content,path:string,mesh:^geom.Mesh_Buffer,materials:..base.Asset_Id) -> base.Asset_Id {
    id:=content_id(c.project,"mesh",path)
    if !geom.mesh_buffer_paint(mesh,{1,1,1,1}) {content_check(c,path,.Out_Of_Memory);return id}
    if !geom.mesh_is_valid(geom.mesh_buffer_view(mesh)) || len(mesh.normals)!=len(mesh.positions) || len(mesh.uvs)!=len(mesh.positions) || len(mesh.indices)==0 {
        content_check(c,path,.Invalid)
        return id
    }
    scratch:=context.temp_allocator
    vertices:=make([dynamic]Vertex,0,len(mesh.positions),scratch)
    flags:Mesh_Flags
    for position,i in mesh.positions {
        painted:=mm.rgba8_pack({mesh.colors[i].r,mesh.colors[i].g,mesh.colors[i].b,1})
        if painted!=0xffffffff {flags+={.Has_Colors}}
        append(&vertices,Vertex{position=position,normal=mm.normal_pack(mesh.normals[i]),uv=mesh.uvs[i],uv1=mesh.uvs[i],color=painted})
    }
    indices:=make([]u32,len(mesh.indices),scratch)
    copy(indices,mesh.indices[:])
    if !mesh_tangents(&vertices,indices) {content_check(c,path,.Out_Of_Memory);return id}
    desc:=Mesh_Desc{id=id}
    if len(materials)>0 {
        slots:=make([]Material_Slot,len(materials),scratch)
        for material,i in materials {slots[i]={id=u32(i),material=material}}
        desc.slots=slots
    }
    if !mesh_build_dag({vertices=vertices[:],flags=flags},indices,&desc.geometry,scratch) {content_check(c,path,.Invalid);return id}
    content_folder(path)
    content_check(c,path,mesh_save(path,&c.types,desc))
    return id
}
