package importer

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:std/base"
import si "mirai:std/input"
import "mirai:std/serial"
import "mirai:ui"

// Prompt packs: a folder of images whose names say what each shows
// (prompts_folder), or a manifest <name>.prompts.json that lists the image of
// each input of each family of devices,
//
//   {"entries": [
//       {"family": "Xbox", "input": "South", "image": "xbox/a.png"},
//       {"family": "Keyboard", "input": "Key", "key": "Space", "image": "keys/space.png"}
//   ]}
//
// with families and inputs named as ui.Prompt_Family and ui.Prompt_Input,
// the key of the input Key as core.Key, and images (PNG, or any image stb
// reads) relative to the manifest. An image that several entries name is
// packed once. The images are packed into atlases of PROMPTS_ATLAS_MAX at
// most (prompts_pack), each a power of two on each side, with
// PROMPTS_PADDING texels around each image that repeat its edge.
// The atlases are sRGB with straight alpha and no compression of their
// texels, parts of the import written next to <name>.prompts, its root.

PROMPTS_MANIFEST :: ".prompts.json"
PROMPTS_ATLAS_MAX :: 2048
PROMPTS_ATLAS_MIN :: 64
PROMPTS_PADDING :: 2

Prompts_Entry :: struct {
    family:ui.Prompt_Family,
    input:ui.Prompt_Input,
    key:string,
    image:string, // path of the image file
}

// The entries of the text of a manifest. folder: where its images are.
// message says what is wrong; everything lives in allocator.
prompts_manifest :: proc(text:string,folder:string,allocator:=context.allocator) -> (entries:[]Prompts_Entry,message:string) {
    value,parse_error:=json.parse(transmute([]u8)text,allocator=allocator)
    if parse_error!=.None {return nil,fmt.aprintf("the manifest is not JSON: %v",parse_error,allocator=allocator)}
    object,is_object:=value.(json.Object)
    list,is_list:=object["entries"].(json.Array)
    if !is_object || !is_list {return nil,strings.clone("the manifest is an object whose \"entries\" lists the images",allocator)}
    out:=make([]Prompts_Entry,len(list),allocator)
    names :: proc($E:typeid,allocator:mem.Allocator) -> string {return strings.join(reflect.enum_field_names(E),", ",allocator)}
    for member,at in list {
        fields,ok:=member.(json.Object)
        if !ok {return nil,fmt.aprintf("entry %d is not an object",at,allocator=allocator)}
        text_of :: proc(fields:json.Object,name:string) -> string {return fields[name].(json.String) or_else ""}
        family,input,key,image:=text_of(fields,"family"),text_of(fields,"input"),text_of(fields,"key"),text_of(fields,"image")
        e:=&out[at]
        known:bool
        if e.family,known=reflect.enum_from_name(ui.Prompt_Family,family);!known {
            return nil,fmt.aprintf("entry %d: the family %q is not one of %s",at,family,names(ui.Prompt_Family,allocator),allocator=allocator)
        }
        if e.input,known=reflect.enum_from_name(ui.Prompt_Input,input);!known {
            return nil,fmt.aprintf("entry %d: the input %q is not one of %s",at,input,names(ui.Prompt_Input,allocator),allocator=allocator)
        }
        if e.input==.Key {
            if _,named:=reflect.enum_from_name(si.Key,key);!named {return nil,fmt.aprintf("entry %d: the input Key names its key as core.Key does, and %q is not one of %s",at,key,names(si.Key,allocator),allocator=allocator)}
        } else if key!="" {
            return nil,fmt.aprintf("entry %d: only the input Key names a key",at,allocator=allocator)
        }
        pointer:=e.input<=.Mouse_Wheel
        if pointer!=(e.family==.Keyboard) {
            return nil,fmt.aprintf("entry %d: keys and the mouse are of the family Keyboard, and the buttons of a gamepad of the others",at,allocator=allocator)
        }
        if image=="" || filepath.is_abs(image) {return nil,fmt.aprintf("entry %d: image names a file relative to the manifest",at,allocator=allocator)}
        joined,_:=filepath.join({folder,image},allocator)
        e.key,e.image=strings.clone(key,allocator),joined
        for &earlier in out[:at] {
            if earlier.family==e.family && earlier.input==e.input && earlier.key==e.key {return nil,fmt.aprintf("entry %d: %v %v %s has an image already",at,e.family,e.input,e.key,allocator=allocator)}
        }
    }
    return out,""
}

// Where an image is in the atlases.
Prompts_Place :: struct {page,x,y:int}

// Packs rectangles of sizes into pages: shelves of rows of rectangles in
// order of height, each page the smallest power of two on each side that
// holds what is left, up to PROMPTS_ATLAS_MAX, or one of half its area when
// that and the page for what it leaves take fewer texels. A rectangle takes
// its size plus PROMPTS_PADDING on each side. pages: the size of each page.
prompts_pack :: proc(sizes:[][2]int,allocator:=context.allocator) -> (places:[]Prompts_Place,pages:[][2]int,ok:bool) {
    PAD :: PROMPTS_PADDING
    order:=make([]int,len(sizes),context.temp_allocator)
    for &o,i in order {
        o=i
        if sizes[i].x<=0 || sizes[i].y<=0 || sizes[i].x+2*PAD>PROMPTS_ATLAS_MAX || sizes[i].y+2*PAD>PROMPTS_ATLAS_MAX {return}
    }
    taller :: proc(sizes:[][2]int,a,b:int) -> bool {
        if sizes[a].y!=sizes[b].y {return sizes[a].y>sizes[b].y}
        if sizes[a].x!=sizes[b].x {return sizes[a].x>sizes[b].x}
        return a<b
    }
    for i in 1..<len(order) {
        for j:=i;j>0 && taller(sizes,order[j],order[j-1]);j-=1 {order[j],order[j-1]=order[j-1],order[j]}
    }
    // How many of order fit a page of a size, and where.
    fit :: proc(sizes:[][2]int,order:[]int,width,height:int,out:[]Prompts_Place,page:int) -> int {
        x,y,shelf:=0,0,0
        for index,at in order {
            w,h:=sizes[index].x+2*PAD,sizes[index].y+2*PAD
            if x+w>width {x,y,shelf=0,y+shelf,0}
            if y+h>height || w>width {return at}
            out[index]={page,x,y}
            x+=w;shelf=max(shelf,h)
        }
        return len(order)
    }
    // The page of an area, wider than high, that holds the most of rest.
    fullest :: proc(sizes:[][2]int,rest:[]int,area:int,out:[]Prompts_Place) -> (page:[2]int,placed:int) {
        for width:=PROMPTS_ATLAS_MAX;width>=PROMPTS_ATLAS_MIN;width/=2 {
            height:=area/width
            if height<PROMPTS_ATLAS_MIN || height>width {continue}
            if count:=fit(sizes,rest,width,height,out,0);count>placed {page,placed={width,height},count}
        }
        return
    }
    // The smallest page that holds all of rest; zero when none does.
    smallest :: proc(sizes:[][2]int,rest:[]int,out:[]Prompts_Place) -> [2]int {
        for area:=PROMPTS_ATLAS_MIN*PROMPTS_ATLAS_MIN;area<=PROMPTS_ATLAS_MAX*PROMPTS_ATLAS_MAX;area*=2 {
            if page,placed:=fullest(sizes,rest,area,out);placed==len(rest) {return page}
        }
        return {}
    }
    places=make([]Prompts_Place,len(sizes),allocator)
    list:=make([dynamic][2]int,allocator)
    rest:=order
    for len(rest)>0 {
        chosen:=smallest(sizes,rest,places)
        if chosen=={} {chosen={PROMPTS_ATLAS_MAX,PROMPTS_ATLAS_MAX}}
        // A page of half the area and another for what it leaves may take less.
        if area:=chosen.x*chosen.y;area>PROMPTS_ATLAS_MIN*PROMPTS_ATLAS_MIN {
            half,placed:=fullest(sizes,rest,area/2,places)
            if placed>0 && placed<len(rest) {
                next:=smallest(sizes,rest[placed:],places)
                if next!={} && area/2+next.x*next.y<area {chosen=half}
            }
        }
        placed:=fit(sizes,rest,chosen.x,chosen.y,places,len(list))
        if placed==0 {delete(places,allocator);delete(list);return nil,nil,false}
        append(&list,chosen)
        rest=rest[placed:]
    }
    return places,list[:],true
}

// Imports a manifest of prompts as <name>.prompts and its atlases in folder.
import_prompts :: proc(path,folder:string,options:Import_Options={},allocator:=context.allocator) -> (report:Import_Report,error:Error) {
    caller:=context.temp_allocator
    scratch:mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator=base.dynamic_arena_allocator(&scratch)

    if unsafe_path(path) {return {},error_make(.Not_Found,"%s does not exist",path,allocator=caller)}
    entries:[]Prompts_Entry
    bytes:[]u8
    skipped:=0
    if os.is_dir(path) {
        // A folder of a pack: the names of its images say what each shows.
        entries,skipped=prompts_folder(path,context.temp_allocator)
        if len(entries)==0 {return {},error_make(.Malformed,"%s has no image whose name says a key, a mouse button or a button of a gamepad (keyboard_a.png, xbox_button_a.png, playstation_button_cross.png)",path,allocator=caller)}
        // What it maps is what the import knows it by.
        b:=strings.builder_make(context.temp_allocator)
        for e in entries {fmt.sbprintfln(&b,"%v %v %s %s",e.family,e.input,e.key,strings.trim_prefix(e.image,path))}
        bytes=b.buf[:]
    } else {
        read_error:serial.File_Error
        bytes,read_error=serial.file_read(path,context.temp_allocator,limit=MAX_SOURCE_BYTES)
        if read_error!=.None {
            return {},error_make(read_error==.Not_Found?Error_Code.Not_Found:Error_Code.Read,"%s could not be read: %v",path,read_error,allocator=caller)
        }
        message:string
        entries,message=prompts_manifest(string(bytes),filepath.dir(path),context.temp_allocator)
        if message!="" {return {},error_make(.Malformed,"%s: %s",path,message,allocator=caller)}
        if len(entries)==0 {return {},error_make(.Malformed,"%s lists no entries",path,allocator=caller)}
    }

    // Each image file once, decoded.
    files:=make([dynamic]string,context.temp_allocator)
    images:=make([dynamic]textures.Image,context.temp_allocator)
    of_entry:=make([]int,len(entries),context.temp_allocator)
    for &e,at in entries {
        key:=path_key(e.image)
        found:=-1
        for file,i in files {if file==key {found=i;break}}
        if found<0 {
            if unsafe_path(e.image) {return {},error_make(.Not_Found,"%s: entry %d: %s does not exist",path,at,e.image,allocator=caller)}
            data,image_error:=serial.file_read(e.image,context.temp_allocator,limit=MAX_SOURCE_BYTES)
            if image_error!=.None {return {},error_make(image_error==.Not_Found?Error_Code.Not_Found:Error_Code.Read,"%s: entry %d: %s could not be read: %v",path,at,e.image,image_error,allocator=caller)}
            image,decode_error:=textures.image_decode(data,context.temp_allocator)
            if decode_error!=.None {return {},error_make(.Unsupported,"%s: entry %d: %s is not an image that can be decoded: %v",path,at,e.image,decode_error,allocator=caller)}
            found=len(files)
            append(&files,key)
            append(&images,image)
        }
        of_entry[at]=found
    }
    sizes:=make([][2]int,len(images),context.temp_allocator)
    for image,i in images {sizes[i]={image.width,image.height}}
    places,pages,packed:=prompts_pack(sizes,context.temp_allocator)
    if !packed {return {},error_make(.Limit,"%s: an image is larger than an atlas of %d texels on each side",path,PROMPTS_ATLAS_MAX-2*PROMPTS_PADDING,allocator=caller)}

    report_init(&report,allocator)
    w:Writer
    ok:=writer_init(&w,path,folder,options,&report,allocator)
    w.options.textures,w.options.max_texture_size=.Uncompressed,PROMPTS_ATLAS_MAX
    defer asset.types_destroy(&w.types)
    if ok {
        for file in files {writer_input(&w,file)}
        ok=prompts_write(&w,path,bytes,entries,of_entry,images[:],places,pages) && writer_finish(&w)
    }
    if ok && skipped>0 {append(&report.warnings,fmt.aprintf("%d images of %s say no input by their names and were left out; Project Settings > UI gives any input an image of its own",skipped,path,allocator=allocator))}
    if !ok {
        writer_rollback(&w)
        error=writer_error(&w,caller)
        report_destroy(&report)
        return {},error
    }
    return report,{}
}

@(private="file")
prompts_write :: proc(w:^Writer,path:string,bytes:[]u8,entries:[]Prompts_Entry,of_entry:[]int,images:[]textures.Image,places:[]Prompts_Place,pages:[][2]int) -> bool {
    PAD :: PROMPTS_PADDING
    source:=w.source
    file:=filepath.base(path)
    name:=file[:len(file)-len(PROMPTS_MANIFEST)] if strings.has_suffix(strings.to_lower(file,context.temp_allocator),PROMPTS_MANIFEST) else filepath.stem(file)
    target:string
    w.owner,target=root_take(w,asset.KIND_PROMPTS,name,".prompts")

    // The texels of each page: the images, each with its edge repeated around it.
    jobs:=make([]Texture_Job,len(pages),context.temp_allocator)
    for size,page in pages {
        pixels:=make([]u8,size.x*size.y*4,context.temp_allocator)
        for image,i in images {
            place:=places[i]
            if place.page!=page {continue}
            for y in -PAD..<image.height+PAD {
                for x in -PAD..<image.width+PAD {
                    from:=(clamp(y,0,image.height-1)*image.width+clamp(x,0,image.width-1))*4
                    to:=((place.y+PAD+y)*size.x+place.x+PAD+x)*4
                    copy(pixels[to:][:4],image.pixels[from:][:4])
                }
            }
        }
        page_name:=fmt.tprintf("%s_atlas",name) if len(pages)==1 else fmt.tprintf("%s_atlas_%d",name,page)
        jobs[page]={name=page_name,bytes=pixels,made=textures.rgba8(pixels,size.x,size.y),size=u64(len(pixels)),hash=base.hash64(pixels),srgb=true,index=page,version=import_version(0)}
    }
    parts:=make([]Part,len(pages),context.temp_allocator)
    for &job,page in jobs {
        parts[page]=Part{kind=asset.KIND_TEXTURE,name=job.name,index=page,extension=".tex",size=job.size,hash=job.hash,settings=textures.settings_hash(texture_options(w,job))}
    }
    parts_plan(w,parts)
    for &part in parts {part.owner=w.owner}
    parts_record(w,parts)
    for &part,page in parts {
        if part.shared!=NOT_SHARED {continue}
        if !write_texture(w,jobs[page],part.id,w.owner,part.path,source) {
            if w.error.code==.None {writer_fail(w,.Write,"the atlas %s could not be built",part.path)}
            return false
        }
    }

    rows:=make([]asset.Prompt_Image,len(entries),context.temp_allocator)
    for &e,at in entries {
        image:=images[of_entry[at]]
        place:=places[of_entry[at]]
        size:=pages[place.page]
        row:=&rows[at]
        row.family,row.input,row.texture=u8(e.family),u8(e.input),parts[place.page].id
        asset.text_set(row.key[:],e.key)
        row.uv={f32(place.x+PAD)/f32(size.x),f32(place.y+PAD)/f32(size.y),f32(image.width)/f32(size.x),f32(image.height)/f32(size.y)}
        row.aspect=f32(image.width)/f32(image.height)
    }
    info:=import_info(source,name,0,u64(len(bytes)),base.hash64(bytes),0,import_version(0))
    existed:=os.exists(target)
    if error:=asset.prompts_save(target,&w.types,{id=w.owner,images=rows,source=&info},context.temp_allocator);error!=.None {return save_failed(w,error,target)}
    record(w,w.owner,asset.KIND_PROMPTS,name,target,source,existed,fmt.tprintf("%d prompts of %d images in %d atlas%s",len(rows),len(images),len(pages),len(pages)==1?"":"es"))
    return true
}
