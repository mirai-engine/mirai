package importer

import "core:fmt"
import "core:math"
import "core:mem"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:std/serial"
import mm "mirai:std/math"

// What the read of one source accumulates, and the procedures a Format reads
// with. Its lists live in scratch memory and are copied into the model at the
// end; strings and slices of the result live in out. A reader appends meshes
// (mesh_add), materials (material_add), images (image_file, image_embedded),
// nodes, skeletons and animations in the space of the source, states that
// space when the file says it (source_space), and returns false after fail.
Reader :: struct {
    out:mem.Allocator,
    options:Import_Options, // its settings are those the import applies: <source>.import when it has one
    data:rawptr,          // Format.data: the options of the format
    path:string,          // of the source: absolute, with forward slashes
    directory:string,
    file_name:string,
    stem:string,          // what the model is named (its prefab, its clips): the stem of the file unless the format names it otherwise
    space:Source_Space,   // of the source: Format.space unless the reader states another
    basis:Basis,          // of space
    meshes:[dynamic]Imported_Mesh,
    materials:[dynamic]Imported_Material,
    images:[dynamic]Imported_Image,
    nodes:[dynamic]Imported_Node,
    skeletons:[dynamic]Imported_Skeleton,
    animations:[dynamic]asset.Animation_Clip_Desc,
    warnings:[dynamic]string,
    programs:[dynamic]string, // the Surface programs it wrote to the shaders of the project, their files
    files:[dynamic]string,    // the files it read besides the source (read_note)
    degenerate:int,       // faces without area the reader skipped
    // What the procedures of the reader keep.
    image_rows:map[Image_Key]int,
    material_names:map[string]bool,
    mesh_names:map[string]bool,
    polygon_arena:mem.Dynamic_Arena,
    code:Error_Code,
    message:string,
}

Image_Key :: struct {
    path:string,
    srgb,normal_map:bool,
}

// Records the first failure and returns false, so a reader can `return fail(...)`.
fail :: proc(r:^Reader,code:Error_Code,format:string,args:..any) -> bool {
    if r.code==.None {
        r.code=code
        r.message=fmt.aprintf(format,..args,allocator=context.temp_allocator)
    }
    return false
}

// Whether a failure was recorded.
failed :: proc(r:^Reader) -> bool {return r.code!=.None}

// The failure already recorded, with the thing it was found in put before it.
fail_prefix :: proc(r:^Reader,prefix:string) -> bool {
    r.message=fmt.aprintf("%s: %s",prefix,r.message,allocator=context.temp_allocator)
    return false
}

warn :: proc(r:^Reader,format:string,args:..any) {
    append(&r.warnings,fmt.aprintf(format,..args,allocator=r.out))
}

// A copy of text that lives as long as the model.
own :: proc(r:^Reader,text:string) -> string {
    clone,_:=strings.clone(text,r.out)
    return clone
}

// A name as one segment of an animation target path, with '%' and '/'
// escaped, in the temp allocator.
target_segment :: proc(name:string) -> string {
    escaped,_:=strings.replace_all(name,"%","%25",context.temp_allocator)
    escaped,_=strings.replace_all(escaped,"/","%2F",context.temp_allocator)
    return escaped
}

own_slice :: proc(r:^Reader,items:[]$T) -> []T {
    if len(items)==0 {return nil}
    copy_of,_:=slice.clone(items,r.out)
    return copy_of
}

// A name not used before in names: a repeated one gets its position appended.
unique_name :: proc(r:^Reader,names:^map[string]bool,name:string,index:int) -> string {
    chosen:=own(r,name)
    if names[chosen] {chosen=fmt.aprintf("%s (%d)",name,index,allocator=r.out)}
    for at:=2;names[chosen];at+=1 {chosen=fmt.aprintf("%s (%d.%d)",name,index,at,allocator=r.out)}
    names[chosen]=true
    return chosen
}

// The row of a new material, named apart from those before it.
material_add :: proc(r:^Reader,name:string,index:int,info:asset.Material_Info,images:[asset.Material_Map_Kind]int) -> int {
    append(&r.materials,Imported_Material{name=unique_name(r,&r.material_names,name,index),info=info,images=images})
    return len(r.materials)-1
}

// The row of a mesh, named apart from those before it.
mesh_add :: proc(r:^Reader,mesh:Imported_Mesh) -> int {
    named:=mesh
    named.name=unique_name(r,&r.mesh_names,mesh.name,len(r.meshes))
    append(&r.meshes,named)
    return len(r.meshes)-1
}

// The image at path, with how it is read; the same file read in another way is another image.
image_file :: proc(r:^Reader,path:string,srgb,normal_map:bool) -> int {
    if unsafe_path(path) {
        warn(r,"the image %s is a device, not a file",path)
        return -1
    }
    clean:=normalize_path(r,path)
    key:=Image_Key{clean,srgb,normal_map}
    if row,found:=r.image_rows[key];found {return row}
    append(&r.images,Imported_Image{name=own(r,filepath.stem(clean)),path=clean,srgb=srgb,normal_map=normal_map})
    r.image_rows[key]=len(r.images)-1
    return len(r.images)-1
}

// An image inside the model; key tells it apart from the other images of the source.
image_embedded :: proc(r:^Reader,key,name:string,data:[]u8,srgb,normal_map:bool) -> int {
    k:=Image_Key{key,srgb,normal_map}
    if row,found:=r.image_rows[k];found {return row}
    append(&r.images,Imported_Image{name=own(r,name),data=own_slice(r,data),srgb=srgb,normal_map=normal_map})
    r.image_rows[Image_Key{own(r,key),srgb,normal_map}]=len(r.images)-1
    return len(r.images)-1
}

// An image a format made itself from its texels: a conversion of other
// images, or a texture of an engine with its layers and the precision of its
// source. key tells it apart from the other images of the source.
image_pixels :: proc(r:^Reader,key,name:string,made:textures.Source,srgb,normal_map:bool,keep_precision:=false) -> int {
    k:=Image_Key{key,srgb,normal_map}
    if row,found:=r.image_rows[k];found {return row}
    owned:=made
    owned.texels,owned.allocator=own_slice(r,made.texels[:textures.source_bytes(made)]),{}
    append(&r.images,Imported_Image{name=own(r,name),made=owned,srgb=srgb,normal_map=normal_map,keep_precision=keep_precision})
    r.image_rows[Image_Key{own(r,key),srgb,normal_map}]=len(r.images)-1
    return len(r.images)-1
}

// A path as the model keeps it: absolute, cleaned, with forward slashes.
normalize_path :: proc(r:^Reader,path:string) -> string {
    absolute,error:=filepath.abs(path,context.temp_allocator)
    if error!=nil {absolute=path}
    cleaned,_:=filepath.clean(absolute,context.temp_allocator)
    slashed,allocated:=strings.replace_all(cleaned,"\\","/",r.out)
    return slashed if allocated else strings.clone(slashed,r.out)
}

// A path the source names, relative to the folder of the source unless it is absolute.
resolve_path :: proc(r:^Reader,relative:string) -> string {
    if filepath.is_abs(relative) {return normalize_path(r,relative)}
    joined,_:=filepath.join({r.directory,relative},context.temp_allocator)
    return normalize_path(r,joined)
}

// Notes a file the model is read from besides its source: a change of it
// imports the source again (sources.sync).
read_note :: proc(r:^Reader,path:string) {
    if path==r.path {return}
    for file in r.files {
        if file==path {return}
    }
    append(&r.files,strings.clone(path,context.temp_allocator))
}

// The bytes of a file the source names, in scratch memory.
read_source :: proc(r:^Reader,path:string) -> (bytes:[]u8,ok:bool) {
    data,error:=serial.file_read(path,context.temp_allocator,limit=MAX_SOURCE_BYTES)
    #partial switch error {
    case .None:
        read_note(r,path)
        return data,true
    case .Not_Found:
        return nil,fail(r,.Not_Found,"%s does not exist",path)
    case .Too_Large:
        return nil,fail(r,.Limit,"%s is larger than %d bytes",path,MAX_SOURCE_BYTES)
    }
    return nil,fail(r,.Read,"%s could not be read: %v",path,error)
}

pack_color :: proc "contextless" (color:[4]f32) -> u32 {
    r,g,b,a:=u32(clamp(color.r,0,1)*255+0.5),u32(clamp(color.g,0,1)*255+0.5),u32(clamp(color.b,0,1)*255+0.5),u32(clamp(color.a,0,1)*255+0.5)
    return r|g<<8|b<<16|a<<24
}

WHITE :: u32(0xffffffff)

finite3 :: proc "contextless" (v:[3]f32) -> bool {
    return v.x-v.x==0 && v.y-v.y==0 && v.z-v.z==0
}

transform_finite :: proc "contextless" (t:mm.Transform) -> bool {
    return finite3(t.position) && finite3(t.scale) && t.rotation.x-t.rotation.x==0 && t.rotation.y-t.rotation.y==0 && t.rotation.z-t.rotation.z==0 && t.rotation.w-t.rotation.w==0
}

// The normal of a polygon by Newell's method; +Z for one without area.
polygon_normal :: proc(points:[][3]f32) -> [3]f32 {
    normal:[3]f32
    for p,i in points {
        q:=points[(i+1)%len(points)]
        normal+=[3]f32{(p.y-q.y)*(p.z+q.z),(p.z-q.z)*(p.x+q.x),(p.x-q.x)*(p.y+q.y)}
    }
    length:=math.sqrt(normal.x*normal.x+normal.y*normal.y+normal.z*normal.z)
    if length>1e-20 {return normal/length}
    return {0,0,1}
}

// A path named by a source is never read when it holds a control character (a
// NUL cuts it short for the system) or, on Windows, names a device: CON, NUL,
// COM1 and the like open from any folder, and reading one waits for input.
unsafe_path :: proc(path:string) -> bool {
    for b in transmute([]u8)path {
        if b<32 {return true}
    }
    when ODIN_OS==.Windows {
        name:=filepath.base(path)
        if dot:=strings.index_byte(name,'.');dot>=0 {name=name[:dot]}
        upper:=strings.to_upper(strings.trim_right(name," "),context.temp_allocator)
        switch upper {
        case "CON","PRN","AUX","NUL","CONIN$","CONOUT$": return true
        }
        return len(upper)==4 && (upper[:3]=="COM" || upper[:3]=="LPT") && upper[3]>='0' && upper[3]<='9'
    } else {
        return false
    }
}
