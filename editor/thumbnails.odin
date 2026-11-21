package editor

import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:project"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "mirai:std/serial"
import "mirai:store"
import "mirai:ui"

// Thumbnails of geometry: images with premultiplied alpha that the renderer
// draws with the materials of the subject, kept as the cells of one atlas the
// UI shows with host.UI_QUAD_THUMBNAIL. A subject is a shape or a mesh of the
// project alone, or the geometry of one entity as it shows it. The layout
// asks for the preview it shows at the size it shows it: a small cell for up
// to THUMBNAIL_SIZE pixels, a large one beyond, which covers a card of the
// content browser at its largest at a density of 2. One is drawn per frame,
// and the icon stands in until it is there.
//
// The preview of an asset is derived data of the machine's store: an object
// under THUMBNAIL_NAMESPACE named by a key of what it is drawn from, so it is
// drawn once per machine and a peer of a session gives it to another
// (content_library.odin). The key of an asset of a package is that of its
// object and of every object of the build it is in (thumbnail_package_key),
// which any machine that has the manifest and the build computes without the
// asset's bytes; that of an asset of the project's own files is the content of
// the asset and of everything it needs, as the registry has it
// (thumbnail_store_key). Both take the shaders the renderer runs and
// THUMBNAIL_RENDERER: a change of either is a preview to draw again. Up to
// THUMBNAIL_LOADS are read per frame, besides the one drawn. The view of a
// scene the editor took is no derived data: it stays in the thumbs folder of
// the project (thumbnail_subjects.odin).

Thumbnail_Level :: enum u8 {Small,Large}

THUMBNAIL_SIZE :: 64   // pixels of a small cell
THUMBNAIL_LARGE :: 256 // of a large one
THUMBNAIL_SIDES :: [Thumbnail_Level]int{.Small=THUMBNAIL_SIZE,.Large=THUMBNAIL_LARGE}
THUMBNAIL_SAMPLES :: [Thumbnail_Level]int{.Small=3,.Large=2} // per side of a pixel
// The atlas: a band of small cells over a band of large ones.
THUMBNAIL_ATLAS :: 2048
THUMBNAIL_SMALL_ROWS :: 4
THUMBNAIL_LARGE_ROWS :: 4
THUMBNAIL_SMALL_CELLS :: THUMBNAIL_ATLAS/THUMBNAIL_SIZE*THUMBNAIL_SMALL_ROWS
THUMBNAIL_CELLS :: THUMBNAIL_SMALL_CELLS+THUMBNAIL_ATLAS/THUMBNAIL_LARGE*THUMBNAIL_LARGE_ROWS
THUMBNAIL_HEIGHT :: THUMBNAIL_SMALL_ROWS*THUMBNAIL_SIZE+THUMBNAIL_LARGE_ROWS*THUMBNAIL_LARGE
THUMBNAIL_TRIANGLES :: 400000
THUMBNAIL_SHAPE_TINT :: [4]f32{0.7,0.7,0.7,1}
// Advances when the same subject gives another image: the studio, the
// geometry, the reduction or how a provider draws its image changed.
THUMBNAIL_RENDERER :: 3
THUMBNAIL_LOADS :: 8
THUMBNAIL_FILE_MAGIC :: u32('M')|u32('T')<<8|u32('H')<<16|u32('B')<<24
THUMBNAIL_FILE_VERSION :: 3
THUMBNAIL_FILE_HEADER :: 24 // magic, version, key, side and the bytes of the stream of the image after it
THUMBNAIL_NAMESPACE :: asset.REF_CACHE_PREFIX+"thumbnails" // <key as 16 hexadecimal digits>: the preview, as its file holds it

// A stored preview as its file holds it, and the coders of its image.
Thumbnail_File :: struct {
    bytes:[dynamic]u8,
    decoder:asset.Stream_Decoder,
    encoder:asset.Stream_Encoder,
}

thumbnail_file_destroy :: proc(file:^Thumbnail_File) {
    delete(file.bytes)
    asset.stream_decoder_destroy(&file.decoder)
    asset.stream_encoder_destroy(&file.encoder)
    file^={}
}

// What a preview is drawn from. Its bytes are its signature.
Thumbnail_Subject :: struct {
    mesh:erender.Mesh_Renderer,
    tint:erender.Material_Values, // what its entity shows of its materials
    rotation:mm.Quat, // of an entity in the world; a preview does not follow where it is
    scale:[3]f32,
    revision:u64,     // of the loaded assets and of the files of the registry
    provider:asset.Fourcc,  // the kind of asset whose Thumbnail_Provider draws mesh, or its image; 0: the editor
    pose:base.Asset_Id,     // what the provider poses mesh with (an animation)
    clip:u32,               // of pose, from 1
    document:base.Asset_Id, // a prefab or a scene whose entities are drawn instead of mesh
    root:base.Entity_Id,    // the entity of document whose subtree is drawn; 0: all of it
    captured:bool,          // a view of a scene the editor took when it opened it: only stored, never drawn
    data:[THUMBNAIL_DATA]u8, // what the provider draws its image from (Thumbnail_Provider.image)
}

THUMBNAIL_DATA :: 1024

THUMBNAIL_PROVIDER_KINDS :: 4 // of a provider
THUMBNAIL_PROVIDERS :: 8

// A storage of an editor package whose sole field is this gives, in its
// default, the thumbnails of the kinds of asset it names. subject says what
// the one of an asset, or of its clip-th clip from 1, shows: false for
// nothing; with no file, what a field of the kind without an asset shows (a
// default). triangles appends those of a subject whose provider is one of its
// kinds, in the space of the studio, and the materials they index; image,
// when given, draws it instead from its data, between frames, after the frame
// that asked for it (it may draw frames of a world of its own,
// host.app_world_draw): side*side premultiplied display colors of 4 bytes,
// false when nothing covers them.
Thumbnail_Provider :: struct {
    kinds:[THUMBNAIL_PROVIDER_KINDS]asset.Fourcc,
    count:int,
    subject:proc(s:^Session,file:^asset.Registry_File,clip:u32,subject:^Thumbnail_Subject) -> bool,
    triangles:proc(s:^Session,subject:^Thumbnail_Subject,vertices:^[dynamic]gpu.Thumbnail_Vertex,materials:^[dynamic]gpu.Material_Desc) -> bool,
    image:proc(s:^Session,subject:^Thumbnail_Subject,side:int,out:[]u8) -> bool,
}

Thumbnail_Cell :: struct {
    key:u64,       // of its subject; 0: free
    signature:u64, // of what its image was drawn from
    seen:u64,      // the last frame it was asked for
    ready:bool,    // false: its subject had nothing to draw
    stored:u64,    // the key in the store of the image it holds; 0: none
    wanted:u64,    // the key there of the subject whose signature is checked
    checked:u64,
    absent:u64,    // a key the store did not have
}

@(storage)
Thumbnails :: struct {
    pixels:[dynamic]u8,   // the atlas; allocated with the first preview
    readback:[dynamic]u8, // what the renderer drew, before it is reduced
    image:[dynamic]u8,    // the preview being drawn
    file:Thumbnail_File,  // a preview as the store or the thumbs folder holds it
    loads:int,            // previews looked for there in the frame loaded
    loaded:u64,
    cells:[THUMBNAIL_CELLS]Thumbnail_Cell,
    targets:[Thumbnail_Level]gpu.Thumbnail_GPU,
    renderer:^gpu.Renderer, // that owns targets
    providers:[THUMBNAIL_PROVIDERS]Thumbnail_Provider, // of the plugins of the library in use
    provider_count:int,
    providers_library:int,  // library_generation+1 they were read at
    capture:gpu.Thumbnail_Values_GPU, // of material.preview.capture
    capture_renderer:^gpu.Renderer,
    dirty:bool,             // the atlas changed since the renderer got it
    changed:[4]int,         // the pixels that did: left, top, right and bottom
    drawn:u64,              // the frame the last preview was drawn in, or loaded what it shows
    picture:Thumbnail_Picture,
    opened:base.Asset_Id,   // a scene the editor opened, whose view it takes at the frame opened_frame
    opened_frame:u64,
    announce:bool,          // the view was asked for: a notice says when it is kept
}

// The cell whose provider draws its image between frames (Thumbnail_Provider.image).
Thumbnail_Picture :: struct {
    slot:int,
    key,signature:u64, // of the cell when it asked; key 0: none asks
    wanted:u64,        // its key in the store; 0: not kept there
    stored:base.Asset_Id,
    subject:Thumbnail_Subject,
}

@(private)
thumbnails_destroy :: proc(s:^Session) {
    p:=s.thumbnails
    if p.renderer!=nil {
        for &target in p.targets {gpu.thumbnail_destroy(p.renderer.device,&target)}
    }
    if p.capture_renderer!=nil {gpu.thumbnail_values_destroy(p.capture_renderer.device,&p.capture)}
    delete(p.pixels);delete(p.readback);delete(p.image);thumbnail_file_destroy(&p.file)
    p^={}
}

// Gives the renderer the atlas when a preview changed it.
@(private)
thumbnails_flush :: proc(s:^Session) {
    thumbnails_forget(s)
    p:=s.thumbnails
    if !p.dirty {return}
    p.dirty=false
    a:=s.app.assets
    if a==nil || a.renderer==nil || len(p.pixels)==0 {return}
    c:=p.changed
    gpu.renderer_set_thumbnails(a.renderer,p.pixels[:],THUMBNAIL_ATLAS,THUMBNAIL_HEIGHT,{u32(c[0]),u32(c[1]),u32(c[2]-c[0]),u32(c[3]-c[1])})
}

// Where a cell is in the atlas, in pixels from its top left.
@(private)
thumbnail_cell :: proc "contextless" (slot:int) -> (level:Thumbnail_Level,x,y:int) {
    if slot<THUMBNAIL_SMALL_CELLS {
        columns:=THUMBNAIL_ATLAS/THUMBNAIL_SIZE
        return .Small,slot%columns*THUMBNAIL_SIZE,slot/columns*THUMBNAIL_SIZE
    }
    at,columns:=slot-THUMBNAIL_SMALL_CELLS,THUMBNAIL_ATLAS/THUMBNAIL_LARGE
    return .Large,at%columns*THUMBNAIL_LARGE,THUMBNAIL_SMALL_ROWS*THUMBNAIL_SIZE+at/columns*THUMBNAIL_LARGE
}

@(private)
thumbnail_uv :: proc "contextless" (slot:int) -> ui.Rect {
    level,x,y:=thumbnail_cell(slot)
    sides:=THUMBNAIL_SIDES
    side:=f32(sides[level])
    return {f32(x)/THUMBNAIL_ATLAS,f32(y)/THUMBNAIL_HEIGHT,side/THUMBNAIL_ATLAS,side/THUMBNAIL_HEIGHT}
}

@(private)
thumbnail_key :: proc(named:[]byte) -> u64 {
    key:=hash.fnv64a(named)
    return key!=0?key:1
}

// The preview of a subject, by the key that names it, for points of the
// window; stored names the asset it is the preview of, which the thumbs
// folder keeps, or none. Nothing while it has no image: a new one waits its
// turn, one a frame, and a cell of its size is taken from the preview that
// was shown longest ago. A subject that changed keeps its old image until
// the new one is read or drawn, which waits for an open edit to end. Any
// change of the loaded assets or of the files of the registry looks at the
// subject again; one whose stored key did not change keeps its image.
@(private)
preview_request :: proc(s:^Session,key:u64,subject:^Thumbnail_Subject,points:f32,stored:base.Asset_Id={}) -> ui.Quad {
    p:=s.thumbnails
    a:=s.app.assets
    // A texture is read on the processor; the others are drawn.
    if key==0 || a==nil || a.renderer==nil && subject.provider!=asset.KIND_TEXTURE {return {}}
    level:=Thumbnail_Level.Large if points*max(s.app.density,1)>THUMBNAIL_SIZE else .Small
    key:=key
    if level==.Large {key=thumbnail_key(mem.ptr_to_bytes(&key))}
    frame:=s.frame
    if p.loaded!=frame {p.loaded,p.loads=frame,0}
    subject.revision=base.hash_combine(a.revision,a.registry.revision)
    signature:=thumbnail_key(mem.ptr_to_bytes(subject))
    slot,free,oldest:=-1,-1,-1
    cells:=p.cells[:THUMBNAIL_SMALL_CELLS] if level==.Small else p.cells[THUMBNAIL_SMALL_CELLS:]
    first:=0 if level==.Small else THUMBNAIL_SMALL_CELLS
    for &cell,at in cells {
        i:=first+at
        if cell.key==key {
            slot=i
            break
        }
        if cell.key==0 {
            if free<0 {free=i}
        } else if cell.seen+1<frame && (oldest<0 || cell.seen<p.cells[oldest].seen) {
            oldest=i
        }
    }
    if slot<0 {
        if p.drawn==frame+1 && (stored=={} || p.loads>=THUMBNAIL_LOADS) {return {}}
        slot=free>=0?free:oldest
        if slot<0 {return {}}
        p.cells[slot]={key=key}
    }
    cell:=&p.cells[slot]
    cell.seen=frame
    if cell.signature==signature || s.edits.open {return thumbnail_quad(cell,slot)}
    kept:=stored!={} && s.store.root!=""
    if kept && cell.checked!=signature {
        cell.wanted,cell.checked=thumbnail_key_of(s,stored,subject^,level),signature
    }
    wanted:=cell.wanted if kept else 0
    sides:=THUMBNAIL_SIDES
    side:=sides[level]
    if wanted!=0 && cell.stored==wanted && cell.ready {
        // What changed is nothing it is drawn from.
        cell.signature=signature
        return thumbnail_quad(cell,slot)
    }
    if wanted!=0 && cell.absent!=wanted {
        if p.loads>=THUMBNAIL_LOADS {return thumbnail_quad(cell,slot)}
        p.loads+=1
        if thumbnail_store_load(&s.store,side,wanted,&p.file,&p.image) {
            thumbnail_put(p,slot,p.image[:])
            cell.signature,cell.stored,cell.ready=signature,wanted,true
            return thumbnail_quad(cell,slot)
        }
        cell.absent=wanted
    }
    if subject.captured {
        cell.signature=signature
        return thumbnail_quad(cell,slot)
    }
    if p.drawn==frame+1 {return thumbnail_quad(cell,slot)}
    if subject.provider==asset.KIND_TEXTURE {
        // Read on the processor from its smallest levels, not drawn.
        p.drawn=frame+1
        cell.signature,cell.stored=signature,0
        resize(&p.image,side*side*4)
        texture:base.Asset_Id
        mem.copy(&texture,&subject.data[0],size_of(texture))
        cell.ready=thumbnail_texture_image(s,texture,side,p.image[:])
        thumbnail_drawn(s,slot,side,wanted)
        return thumbnail_quad(cell,slot)
    }
    if provider,found:=thumbnail_provider(s,subject.provider);subject.provider!=0 && found && provider.image!=nil {
        // Drawn between frames: the cell shows what it had until then.
        if p.picture.key!=0 {return thumbnail_quad(cell,slot)}
        p.drawn=frame+1
        cell.signature=signature
        p.picture={slot=slot,key=cell.key,signature=signature,wanted=wanted,stored=stored,subject=subject^}
        return thumbnail_quad(cell,slot)
    }
    p.drawn=frame+1
    cell.signature,cell.stored=signature,0
    resize(&p.image,side*side*4)
    cell.ready=preview_render(s,subject,level,p.image[:])
    thumbnail_drawn(s,slot,side,wanted)
    return thumbnail_quad(cell,slot)
}

// Whether a preview may show an asset this frame: at once when it is loaded;
// otherwise it waits its turn, as a preview that is drawn does, and loads in a
// frame no other preview drew or loaded in.
@(private)
preview_load_turn :: proc(s:^Session,id:base.Asset_Id) -> bool {
    a:=s.app.assets
    if _,loaded:=a.index[id];loaded {return true}
    p:=s.thumbnails
    if p==nil {return true}
    if p.drawn==s.frame+1 {return false}
    p.drawn=s.frame+1
    return true
}

// The image of the cell its provider asked to draw between frames
// (Thumbnail_Picture), kept in the store. Between frames.
@(private)
thumbnail_picture_draw :: proc(s:^Session) {
    p:=s.thumbnails
    if p==nil || p.picture.key==0 {return}
    picture:=&p.picture
    defer picture.key=0
    cell:=&p.cells[picture.slot]
    provider,found:=thumbnail_provider(s,picture.subject.provider)
    if cell.key!=picture.key || cell.signature!=picture.signature || !found || provider.image==nil {return}
    level,_,_:=thumbnail_cell(picture.slot)
    sides:=THUMBNAIL_SIDES
    side:=sides[level]
    resize(&p.image,side*side*4)
    cell.stored=0
    cell.ready=provider.image(s,&picture.subject,side,p.image[:])
    thumbnail_drawn(s,picture.slot,side,picture.wanted)
}

// Puts the image of side pixels just drawn into its cell, a blank one when
// nothing covered it, and keeps it in the store under wanted.
@(private="file")
thumbnail_drawn :: proc(s:^Session,slot,side:int,wanted:u64) {
    p:=s.thumbnails
    cell:=&p.cells[slot]
    if !cell.ready {mem.zero_slice(p.image[:])}
    thumbnail_put(p,slot,p.image[:])
    if cell.ready && wanted!=0 && s.store.root!="" && thumbnail_store_save(&s.store,side,wanted,p.image[:],&p.file) {cell.stored=wanted}
}

@(private="file")
thumbnail_quad :: proc(cell:^Thumbnail_Cell,slot:int) -> ui.Quad {
    if !cell.ready {return {}}
    return {kind=host.UI_QUAD_THUMBNAIL,uv=thumbnail_uv(slot)}
}

// An image that is no subject of preview_request (the thumbnail of a project
// in the list), into a cell of its size under key: side*side premultiplied
// display colors. The slot it takes; -1 when every cell was shown in the
// last frame.
@(private)
thumbnail_image_put :: proc(s:^Session,key:u64,level:Thumbnail_Level,image:[]u8) -> int {
    p:=s.thumbnails
    sides:=THUMBNAIL_SIDES
    if p==nil || key==0 || len(image)!=sides[level]*sides[level]*4 {return -1}
    first:=0 if level==.Small else THUMBNAIL_SMALL_CELLS
    cells:=p.cells[:THUMBNAIL_SMALL_CELLS] if level==.Small else p.cells[THUMBNAIL_SMALL_CELLS:]
    slot,free,oldest:=-1,-1,-1
    for &cell,at in cells {
        i:=first+at
        if cell.key==key {slot=i;break}
        if cell.key==0 {
            if free<0 {free=i}
        } else if cell.seen+1<s.frame && (oldest<0 || cell.seen<p.cells[oldest].seen) {oldest=i}
    }
    if slot<0 {slot=free>=0?free:oldest}
    if slot<0 {return -1}
    p.cells[slot]={key=key,seen=s.frame,ready=true}
    thumbnail_put(p,slot,image)
    return slot
}

// The image thumbnail_image_put kept in slot while its cell still holds key.
@(private)
thumbnail_image_quad :: proc(s:^Session,slot:int,key:u64) -> ui.Quad {
    p:=s.thumbnails
    if p==nil || key==0 || slot<0 || slot>=THUMBNAIL_CELLS || p.cells[slot].key!=key {return {}}
    p.cells[slot].seen=s.frame
    return thumbnail_quad(&p.cells[slot],slot)
}

// The thumbs folder of the project; "" without one.
@(private)
thumbnail_folder :: proc(s:^Session) -> string {
    return thumbnail_folder_of(s.project_root)
}

// The thumbs folder of the project at root; "" without a root.
@(private)
thumbnail_folder_of :: proc(root:string) -> string {
    if root=="" {return ""}
    return project.path(project.folder_path(root,.Generated,context.temp_allocator),project.THUMBNAIL_FOLDER,allocator=context.temp_allocator)
}

// What the stored preview of an asset depends on: the renderer of previews,
// the shaders it runs (programs), its size, the subject, and the content of
// the asset, of the assets the subject names and of everything they need, as
// the registry has them now. Zero when the registry does not have the asset.
@(private)
thumbnail_store_key :: proc(r:^asset.Registry,id:base.Asset_Id,subject:Thumbnail_Subject,level:Thumbnail_Level,programs:u64) -> u64 {
    if _,found:=asset.registry_find(r,id);!found {return 0}
    if subject.captured {return THUMBNAIL_CAPTURED}
    subject:=subject
    subject.revision=0
    key:=base.hash_combine(base.hash_combine(THUMBNAIL_RENDERER,u64(level)),programs)
    key=base.hash_combine(key,base.hash64(mem.ptr_to_bytes(&subject)))
    named:=make([dynamic]base.Asset_Id,0,4+len(subject.mesh.materials),context.temp_allocator)
    append(&named,id,subject.mesh.mesh,subject.pose,subject.document)
    for material in subject.mesh.materials {append(&named,material)}
    needed:=make([dynamic]u32,context.temp_allocator)
    closure:=make([dynamic]u32,context.temp_allocator)
    for each in named {
        at,found:=r.by_id[each]
        if each=={} || !found {continue}
        append(&needed,at)
        asset.registry_closure(r,each,&closure)
        append(&needed,..closure[:])
    }
    slice.sort(needed[:])
    for at,i in needed {
        if i>0 && at==needed[i-1] {continue}
        key=base.hash_combine(key,r.files[at].content_hash)
    }
    return key|1
}

@(private)
thumbnail_file :: proc(folder:string,id:base.Asset_Id,side:int) -> string {
    buffer:[base.ASSET_ID_TEXT]u8
    return fmt.tprintf("%s/%s-%d.thumb",folder,base.asset_id_format(id,buffer[:]),side)
}

// The views of scenes that no file is any more leave the thumbs folder,
// as the registry notes them (Registry.removed): deleted, also while the editor
// was closed, or another asset now. One that changed keeps its file, which its
// next drawing overwrites.
@(private)
thumbnails_forget :: proc(s:^Session) {
    a:=s.app.assets
    if a==nil || len(a.registry.removed)==0 {return}
    if folder:=thumbnail_folder(s);folder!="" {thumbnail_views_forget(folder,a.registry.removed[:])}
    clear(&a.registry.removed)
}

@(private)
thumbnail_views_forget :: proc(folder:string,ids:[]base.Asset_Id) {
    sides:=THUMBNAIL_SIDES
    for id in ids {
        for side in sides {os.remove(thumbnail_file(folder,id,side))}
    }
}

// The stored preview of an asset under key, into image: false when its file
// is not there, has another key or cannot be read.
@(private)
thumbnail_load :: proc(folder:string,id:base.Asset_Id,side:int,key:u64,file:^Thumbnail_File,image:^[dynamic]u8) -> bool {
    pixels:=side*side*4
    resize(&file.bytes,THUMBNAIL_FILE_HEADER+asset.pack_bound(pixels))
    head,size,error:=serial.file_read_head(thumbnail_file(folder,id,side),file.bytes[:])
    if error!=.None || size!=i64(len(head)) {return false}
    return thumbnail_decode(head,side,key,file,image)
}

// The image of the bytes of a preview of side under key; false when they hold another.
@(private)
thumbnail_decode :: proc(head:[]u8,side:int,key:u64,file:^Thumbnail_File,image:^[dynamic]u8) -> bool {
    pixels:=side*side*4
    if len(head)<THUMBNAIL_FILE_HEADER {return false}
    r:=serial.reader_init(head)
    if serial.read_u32(&r)!=THUMBNAIL_FILE_MAGIC || serial.read_u32(&r)!=THUMBNAIL_FILE_VERSION || serial.read_u64(&r)!=key || serial.read_u32(&r)!=u32(side) {return false}
    packed:=int(serial.read_u32(&r))
    if r.failed || packed!=len(head)-THUMBNAIL_FILE_HEADER {return false}
    if file.decoder.allocator.procedure==nil {
        if asset.stream_decoder_init(&file.decoder)!=.None {return false}
    }
    resize(image,pixels)
    return asset.unpack(&file.decoder,head[THUMBNAIL_FILE_HEADER:],image[:])==.None
}

// Keeps the preview of an asset under key; false when it cannot be written.
@(private)
thumbnail_save :: proc(folder:string,id:base.Asset_Id,side:int,key:u64,image:[]u8,file:^Thumbnail_File) -> bool {
    bytes:=thumbnail_encode(side,key,image,file)
    if bytes==nil {return false}
    if !os.is_dir(folder) && os.make_directory_all(folder)!=nil {return false}
    return serial.file_write_atomic(thumbnail_file(folder,id,side),bytes)==.None
}

// The bytes of a preview of side under key, in file.bytes; nil when it cannot be packed.
@(private)
thumbnail_encode :: proc(side:int,key:u64,image:[]u8,file:^Thumbnail_File) -> []u8 {
    if len(image)!=side*side*4 {return nil}
    if file.encoder.allocator.procedure==nil {
        if asset.stream_encoder_init(&file.encoder)!=.None {return nil}
    }
    resize(&file.bytes,THUMBNAIL_FILE_HEADER+asset.pack_bound(len(image)))
    packed,error:=asset.pack(&file.encoder,.Fast,.Compressed,image,file.bytes[THUMBNAIL_FILE_HEADER:])
    if error!=.None {return nil}
    w:serial.Writer
    serial.writer_init(&w,allocator=context.temp_allocator)
    serial.write_u32(&w,THUMBNAIL_FILE_MAGIC)
    serial.write_u32(&w,THUMBNAIL_FILE_VERSION)
    serial.write_u64(&w,key)
    serial.write_u32(&w,u32(side))
    serial.write_u32(&w,u32(packed))
    copy(file.bytes[:THUMBNAIL_FILE_HEADER],serial.writer_bytes(&w))
    return file.bytes[:THUMBNAIL_FILE_HEADER+packed]
}

// The name of the preview of key in THUMBNAIL_NAMESPACE.
thumbnail_name :: proc(key:u64,buffer:^[16]u8) -> string {
    digits:=transmute([]u8)string("0123456789abcdef")
    DIGITS:=digits
    for k in 0..<16 {buffer[k]=DIGITS[(key>>(4*uint(15-k)))&15]}
    return string(buffer[:])
}

// The preview of side the store keeps under key, into image: false when it has none.
@(private)
thumbnail_store_load :: proc(s:^store.Store,side:int,key:u64,file:^Thumbnail_File,image:^[dynamic]u8) -> bool {
    if s==nil || s.root=="" || key==0 {return false}
    buffer:[16]u8
    address,ref_error:=store.ref_get(s,THUMBNAIL_NAMESPACE,thumbnail_name(key,&buffer))
    if ref_error!=.None {return false}
    o,open_error:=store.object_open(s,address)
    if open_error!=.None {return false}
    defer store.object_close(&o)
    size:=int(store.object_size(&o))
    if size>THUMBNAIL_FILE_HEADER+asset.pack_bound(side*side*4) {return false}
    resize(&file.bytes,size)
    if store.object_read(&o,0,file.bytes[:])!=.None {return false}
    return thumbnail_decode(file.bytes[:],side,key,file,image)
}

// Keeps the preview of side in the store under key; false when it cannot.
@(private)
thumbnail_store_save :: proc(s:^store.Store,side:int,key:u64,image:[]u8,file:^Thumbnail_File) -> bool {
    bytes:=thumbnail_encode(side,key,image,file)
    if bytes==nil || key==0 {return false}
    address,error:=store.put(s,bytes)
    if error!=.None {return false}
    buffer:[16]u8
    return store.ref_set(s,THUMBNAIL_NAMESPACE,thumbnail_name(key,&buffer),address)==.None
}

// The key of the preview of an asset of a package at level: its object and
// every object of the build it is in (objects), with the shaders and the
// renderer. Any machine with the manifest and the build has them, not the asset.
thumbnail_package_key :: proc(level:Thumbnail_Level,programs:u64,object:store.Hash,objects:[]store.Hash) -> u64 {
    object:=object
    key:=base.hash_combine(base.hash_combine(base.hash_combine(THUMBNAIL_RENDERER,u64(level)),programs),0x706b67)
    key=base.hash_combine(key,base.hash64(object[:]))
    for &o in objects {key=base.hash_combine(key,base.hash64(o[:]))}
    return key|1
}

// The programs previews are drawn with, as their keys take them.
@(private)
thumbnail_programs :: proc(s:^Session) -> u64 {
    return base.hash_combine(base.hash64(transmute([]u8)string(gpu.SHADERS_INTERFACE)),s.app.shaders.identity)
}

// The key of the stored preview of an asset: of a package, by its objects;
// of the project's own files, by what the registry has of it.
@(private)
thumbnail_key_of :: proc(s:^Session,id:base.Asset_Id,subject:Thumbnail_Subject,level:Thumbnail_Level) -> u64 {
    r:=&s.app.assets.registry
    programs:=thumbnail_programs(s)
    if file,found:=asset.registry_find(r,id);found && file.listed && !subject.captured {
        if pin,pinned:=library_pin_of(s,r,file);pinned {
            object,objects,_,built:=library_build_objects(s,pin.entry.manifest,&pin.p,id)
            if built {return thumbnail_package_key(level,programs,object,objects)}
        }
        // An output of this machine's library that no root pins (content_library.odin mounts them).
        if manifest,p,known:=library_package_of_output(s,r,id);known {
            object,objects,_,built:=library_build_objects(s,manifest,&p,id)
            if built {return thumbnail_package_key(level,programs,object,objects)}
        }
    }
    return thumbnail_store_key(r,id,subject,level,programs)
}

// The image of a cell in the atlas, which goes to the renderer with the next flush.
@(private)
thumbnail_put :: proc(p:^Thumbnails,slot:int,image:[]u8) {
    if len(p.pixels)==0 {resize(&p.pixels,THUMBNAIL_ATLAS*THUMBNAIL_HEIGHT*4)}
    level,x,y:=thumbnail_cell(slot)
    sides:=THUMBNAIL_SIDES
    side:=sides[level]
    stride:=THUMBNAIL_ATLAS*4
    for row in 0..<side {
        copy(p.pixels[(y+row)*stride+x*4:][:side*4],image[row*side*4:][:side*4])
    }
    cell:=[4]int{x,y,x+side,y+side}
    p.changed=p.dirty?{min(p.changed[0],cell[0]),min(p.changed[1],cell[1]),max(p.changed[2],cell[2]),max(p.changed[3],cell[3])}:cell
    p.dirty=true
}

// The values a slot shows: its material with those of the entity over them, as the extraction of the scene reads them.
@(private)
slot_values :: proc(a:^host.Assets,id:base.Asset_Id,override:^erender.Material_Values,slot:int) -> gpu.Material_Desc {
    desc:=host.assets_material_values(a,host.assets_material_row(a,id))
    if override!=nil {erender.material_values_apply(a,&desc,override,slot)}
    return desc
}

// The triangles of a subject that is one Mesh_Renderer, in its own space or
// turned and scaled as its entity is, and the materials they index.
@(private)
preview_triangles :: proc(a:^host.Assets,subject:^Thumbnail_Subject,vertices:^[dynamic]gpu.Thumbnail_Vertex,materials:^[dynamic]gpu.Material_Desc) -> bool {
    place:=mm.TRANSFORM_IDENTITY
    if subject.scale!={} {place.rotation,place.scale=subject.rotation,subject.scale}
    return triangles_append(a,subject.mesh,subject.tint,place,THUMBNAIL_TRIANGLES*3,vertices,materials)==.Added
}

// What triangles_append did with a Mesh_Renderer.
Triangles :: enum u8 {
    Nothing, // it shows none: no shape, or a mesh that cannot be read
    Added,
    No_Room, // they do not fit in room, and nothing was added
}

// Appends the triangles a Mesh_Renderer shows, where place puts them, and the
// materials they index, for an image of the studio: the primitive of its
// shape, or the finest level of its mesh that fits in room (a skin poses only
// the first), with a material for every slot, the one of the entity or the
// one the mesh came with, and the values of the entity over the slot they
// name. A mesh of the project is read from its
// file, with its tangents and second UVs, also when it is not loaded; a
// primitive or a mesh made at run time takes the tangents of its corners. A
// corner without a normal takes that of its face. room: the vertices that
// still fit.
triangles_append :: proc(a:^host.Assets,mesh:erender.Mesh_Renderer,tint:erender.Material_Values,place:mm.Transform,room:int,vertices:^[dynamic]gpu.Thumbnail_Vertex,materials:^[dynamic]gpu.Material_Desc) -> Triangles {
    first_vertex:=len(vertices)
    color,emission:=tint.color.rgb,tint.emission
    tint:=tint
    override:=&tint
    came:host.Assets_Slots
    if mesh.mesh!={} && !host.assets_mesh_generated(a,mesh.mesh) {
        file:asset.Asset
        if host.assets_file(a,mesh.mesh,asset.KIND_MESH,&file)!=.None {return .Nothing}
        defer asset.asset_close(&file)
        view,error:=asset.mesh_view(&file,&a.types)
        if error!=.None || !asset.mesh_check_indices(view) {return .Nothing}
        // The finest level that fits.
        shown:=-1
        for level,at in view.levels {
            if int(level.triangle_count)*3<=room {shown=at;break}
        }
        if shown<0 {return .No_Room}
        points:=make([dynamic]asset.Vertex,context.temp_allocator)
        indices:=make([dynamic]u32,context.temp_allocator)
        if !asset.mesh_level_decode(view.geometry,shown,&points,&indices) {return .Nothing}
        came.count=u32(min(len(view.slots),asset.MESH_MAX_SLOTS))
        for slot,at in view.slots[:came.count] {came.materials[at]=slot.material}
        first_material,slots:=slot_materials(a,mesh,override,came,materials)
        for index in indices {
            point:=points[index]
            tangent,sign:=mm.tangent_unpack(point.tangent)
            append(vertices,gpu.Thumbnail_Vertex{
                position=point.position,normal=mm.normal_unpack(point.normal),uv0=point.uv,uv1=point.uv1,tangent={tangent.x,tangent.y,tangent.z,sign},
                tint=color,emission=emission,material=first_material+min(point.material,slots-1),
            })
        }
    } else {
        built:geom.Mesh_Buffer
        geom.mesh_buffer_init(&built,context.temp_allocator)
        if !host.assets_geometry(a,mesh.mesh,mesh.shape,&built,true,&came) {return .Nothing}
        indices:=built.indices[:]
        if len(indices)>room {return .No_Room}
        tangents:=make([][4]f32,len(indices),context.temp_allocator)
        if !geom.corner_tangents(built.positions[:],built.normals[:],built.uvs[:],indices,tangents) {return .Nothing}
        first_material,slots:=slot_materials(a,mesh,override,came,materials)
        for index,at in indices {
            vertex:=gpu.Thumbnail_Vertex{position=built.positions[index],tint=color,emission=emission,tangent=tangents[at],material=first_material}
            if int(index)<len(built.normals) {vertex.normal=built.normals[index]}
            if int(index)<len(built.uvs) {vertex.uv0=built.uvs[index]}
            if triangle:=at/3;triangle<len(built.materials) {vertex.material+=min(built.materials[triangle],slots-1)}
            append(vertices,vertex)
        }
    }
    added:=vertices[first_vertex:]
    for i:=0;i+2<len(added);i+=3 {
        corners:=added[i:][:3]
        edge_a,edge_b:=corners[1].position-corners[0].position,corners[2].position-corners[0].position
        face:=[3]f32{edge_a.y*edge_b.z-edge_a.z*edge_b.y,edge_a.z*edge_b.x-edge_a.x*edge_b.z,edge_a.x*edge_b.y-edge_a.y*edge_b.x}
        for &corner in corners {
            if corner.normal=={} {corner.normal=face}
        }
    }
    vertices_place(added,place)
    return len(added)>=3?.Added:.Nothing
}

// Appends the material of every slot of a Mesh_Renderer: the one of the
// entity, else the one the mesh came with, with the values of the entity over
// the slots they name. first: the index of the first; slots: how many.
@(private="file")
slot_materials :: proc(a:^host.Assets,mesh:erender.Mesh_Renderer,override:^erender.Material_Values,came:host.Assets_Slots,materials:^[dynamic]gpu.Material_Desc) -> (first,slots:u32) {
    first,slots=u32(len(materials)),u32(clamp(int(came.count),1,erender.MATERIAL_SLOTS))
    for slot in 0..<int(slots) {
        id:=mesh.materials[slot]
        if id=={} {id=came.materials[slot]}
        append(materials,slot_values(a,id,override,slot))
    }
    return
}

// Moves vertices of their own space to where place puts them.
@(private)
vertices_place :: proc(vertices:[]gpu.Thumbnail_Vertex,place:mm.Transform) {
    if place==mm.TRANSFORM_IDENTITY {return}
    inverse:=[3]f32{1,1,1}
    for axis in 0..<3 {
        if abs(place.scale[axis])>1e-6 {inverse[axis]=1/place.scale[axis]}
    }
    for &vertex in vertices {
        vertex.position=mm.transform_point(place,vertex.position)
        vertex.normal=mm.quat_rotate(place.rotation,vertex.normal*inverse)
        vertex.tangent.xyz=mm.quat_rotate(place.rotation,vertex.tangent.xyz*place.scale)
        if place.scale.x*place.scale.y*place.scale.z<0 {vertex.tangent.w=-vertex.tangent.w}
    }
}

// Draws the subject with the renderer, larger than the cell, and reduces it.
@(private)
preview_render :: proc(s:^Session,subject:^Thumbnail_Subject,level:Thumbnail_Level,out:[]u8) -> bool {
    p:=s.thumbnails
    a:=s.app.assets
    if a==nil || a.renderer==nil {return false}
    vertices:=make([dynamic]gpu.Thumbnail_Vertex,0,1024,context.temp_allocator)
    materials:=make([dynamic]gpu.Material_Desc,0,erender.MATERIAL_SLOTS+1,context.temp_allocator)
    drawn:bool
    switch {
    case subject.document!={}: drawn=document_triangles(a,subject.document,subject.root,&vertices,&materials)
    case subject.provider!=0:
        provider,found:=thumbnail_provider(s,subject.provider)
        drawn=found && provider.triangles!=nil && provider.triangles(s,subject,&vertices,&materials)
    case:                      drawn=preview_triangles(a,subject,&vertices,&materials)
    }
    if !drawn {return false}
    host.assets_commit(a)
    sides,samples:=THUMBNAIL_SIDES,THUMBNAIL_SAMPLES
    size,n:=sides[level],samples[level]
    side:=size*n
    resize(&p.readback,side*side*4)
    p.renderer=a.renderer
    if !gpu.renderer_thumbnail(a.renderer,&p.targets[level],vertices[:],materials[:],u32(side),u32(side),p.readback[:]) {return false}
    covered:=false
    for y in 0..<size {
        for x in 0..<size {
            sum:[4]u32
            for sy in 0..<n {
                for sx in 0..<n {
                    index:=((y*n+sy)*side+x*n+sx)*4
                    for channel in 0..<4 {sum[channel]+=u32(p.readback[index+channel])}
                }
            }
            for channel in 0..<4 {out[(y*size+x)*4+channel]=u8(sum[channel]/u32(n*n))}
            covered|=sum[3]>0
        }
    }
    return covered
}

// The preview of a shape or of a mesh of the project, with the materials it
// came with, for points of the window.
@(private)
preview_geometry :: proc(s:^Session,shape:host.Shape,mesh:base.Asset_Id,points:f32=0) -> ui.Quad {
    subject:=Thumbnail_Subject{mesh={mesh=mesh,shape=mesh=={}?shape:.None},tint={color=mesh=={}?THUMBNAIL_SHAPE_TINT:{1,1,1,1}}}
    named:=[3]u64{mesh[0],mesh[1],u64(subject.mesh.shape)}
    return preview_request(s,thumbnail_key(mem.ptr_to_bytes(&named)),&subject,points,mesh)
}

// The stored preview of a material: the sphere of the studio wearing it.
@(private)
preview_material :: proc(s:^Session,material:base.Asset_Id,points:f32=0) -> ui.Quad {
    subject:=Thumbnail_Subject{mesh={shape=.Sphere},tint={color={1,1,1,1}}}
    subject.mesh.materials[0]=material
    named:=[3]u64{material[0],material[1],0x6d6174}
    return preview_request(s,thumbnail_key(mem.ptr_to_bytes(&named)),&subject,points,material)
}

// The stored preview of a texture: its smallest levels that cover the cell,
// read on the processor (thumbnail_texture_image), never the whole texture.
@(private)
preview_texture :: proc(s:^Session,texture:base.Asset_Id,points:f32=0) -> ui.Quad {
    subject:=Thumbnail_Subject{provider=asset.KIND_TEXTURE}
    id:=texture
    copy(subject.data[:],mem.ptr_to_bytes(&id))
    named:=[3]u64{texture[0],texture[1],0x746578}
    return preview_request(s,thumbnail_key(mem.ptr_to_bytes(&named)),&subject,points,texture)
}

// The image of a texture at side*side, premultiplied display colors, from the
// largest of its levels no larger than side (or its smallest), decoded alone.
@(private)
thumbnail_texture_image :: proc(s:^Session,texture:base.Asset_Id,side:int,out:[]u8) -> bool {
    a:=s.app.assets
    file,found:=asset.registry_find(&a.registry,texture)
    if !found {return false}
    bytes,read_error:=asset.registry_read(&a.registry,file.path,context.temp_allocator)
    if read_error!=.None {return false}
    opened:asset.Asset
    if asset.asset_open(&opened,bytes)!=.None {return false}
    defer asset.asset_close(&opened)
    view,view_error:=asset.texture_open(&opened,&a.types)
    if view_error!=.None || len(view.mips)==0 {return false}
    level:=len(view.mips)-1
    for mip,at in view.mips {
        if int(max(mip.width,mip.height))<=side {level=at;break}
    }
    if asset.texture_decode(&opened,&a.types,&view,level)!=.None {return false}
    mip:=view.mips[level]
    width,height:=int(mip.width),int(mip.height)
    texels:=make([][4]f32,width*height,context.temp_allocator)
    if !asset.texture_level_linear(view.info.format,view.info.flags,asset.texture_layer(view,level,0),width,height,texels) {return false}
    srgb:=.Srgb in view.info.flags
    for y in 0..<side {
        for x in 0..<side {
            t:=texels[min(y*height/side,height-1)*width+min(x*width/side,width-1)]
            alpha:=clamp(t.w,0,1)
            for c in 0..<3 {
                v:=clamp(t[c],0,1)
                if srgb {v=v<=0.0031308?v*12.92:1.055*math.pow(v,1/2.4)-0.055}
                out[(y*side+x)*4+c]=u8(clamp(v*alpha,0,1)*255+0.5)
            }
            out[(y*side+x)*4+3]=u8(alpha*255+0.5)
        }
    }
    return true
}

// The preview of an entity: its own geometry as it shows it. Nothing for one without a mesh.
@(private)
preview_entity :: proc(s:^Session,w:core.World_Ref,e:core.Entity) -> ui.Quad {
    mesh,has_mesh:=entity_get(w,e,erender.Mesh_Renderer)
    if !has_mesh {return {}}
    subject:=Thumbnail_Subject{mesh=mesh,tint=erender.MATERIAL_VALUES_DEFAULT}
    if tint,ok:=entity_get(w,e,erender.Material_Values);ok {subject.tint=tint}
    world:=entity_world(w,e)
    subject.rotation,subject.scale=world.rotation,world.scale
    named:=[2]u64{u64(e),0x656e74697479}
    return preview_request(s,thumbnail_key(mem.ptr_to_bytes(&named)),&subject,0)
}
