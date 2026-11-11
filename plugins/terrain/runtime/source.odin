package terrain

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:strings"
import "mirai:std/codec"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "mirai:std/serial"

VERSION :: 11
SAMPLES_MAX :: 16385
// A Volume has at most this many chunks: one that reaches further takes more cells per chunk.
VOLUME_CHUNKS_MAX :: 1<<18
CHUNK_CELLS_MIN :: 4
CHUNK_CELLS_MAX :: 256
UV_METERS :: f32(4)
SDF_BAND_CELLS :: f32(4)
HEIGHT_LIMIT :: f32(100000)

Source_Kind :: enum u8 {Heightfield,Volume}

Source_Info :: struct {
    kind:Source_Kind,
    samples:[3]u32,
    cell:f32 `mirai:"unit=m"`,
    chunk_cells:u32,
    revision:u32,
    layer_count:u32, // at least 1
    layers:[LAYERS_MAX]Terrain_Layer,
    // The material slot 0 shows: a Surface program that blends the layers by
    // their weights (uv0 and uv1); zero, Terrain_Layers with the materials of
    // the layers.
    layers_material:base.Asset_Id,
    interior:Interior, // Volume: what is under its surface, written into its weights by source_interior_apply
}

Source :: struct {
    allocator:runtime.Allocator,
    codecs:Page_Codecs, // of the game that holds it
    using info:Source_Info,
    field:Grid(f32),      // the heights of a Heightfield, samples.x by samples.z, or the distances of a Volume, samples.x by y by z in blocks: one all air or all solid holds no values
    holes:Grid(u8),       // Heightfield: 1 for each cell without surface; no pages without holes
    scratch:[dynamic]f32, // the region a brush reads while it writes
    weights:Grid(Weights), // samples.x by samples.z, or of each sample of a Volume in blocks
    dug:Dug,               // what the last edit took out
    file:string,           // Heightfield and Volume: where the pages of its grids in blocks are read from
    origin:u64,            // the content hash of the file it was read from or last saved to; 0: none. Its pages and sections tell whether they were written since (altered)
    coarse:Coarse,         // Heightfield of a world: kept with its samples (coarse.odin)
}

source_valid :: proc "contextless" (info:Source_Info) -> bool {
    if !(info.cell>0) || info.cell-info.cell!=0 || info.cell>10000 || info.chunk_cells<CHUNK_CELLS_MIN || info.chunk_cells>CHUNK_CELLS_MAX {return false}
    if info.layer_count<1 || info.layer_count>LAYERS_MAX {return false}
    if info.kind==.Volume {if !interior_valid(info.interior,info.layer_count) {return false}} else if info.interior!={} {return false}
    for layer,i in info.layers {
        if i<int(info.layer_count) {if !layer_valid(layer) {return false}} else if layer!={} {return false}
    }
    for n in info.samples {if n>SAMPLES_MAX {return false}}
    switch info.kind {
    case .Heightfield: return info.samples.y==1 && info.samples.x>=2 && info.samples.z>=2
    case .Volume:
        if !(info.samples.x>=3 && info.samples.y>=3 && info.samples.z>=3) {return false}
        chunks:=u64(1)
        for n in info.samples {chunks*=u64(max((int(n)-2+int(info.chunk_cells))/int(info.chunk_cells),1))}
        return chunks<=VOLUME_CHUNKS_MAX
    }
    return false
}
// How far from zero a value of the field may be: a height, or the band of the distances of a Volume.
field_limit :: proc "contextless" (info:Source_Info) -> f32 {return info.kind==.Volume?info.cell*SDF_BAND_CELLS:HEIGHT_LIMIT}

// The samples a build of a chunk reads past its own: the gradients of a Volume and the cells its
// collider looks at across its faces, or what the normals, the rules of layers and the borders of the
// collider of a Heightfield reach.
@(private)
chunk_halo :: proc "contextless" (s:^Source) -> int {return s.kind==.Volume?VOLUME_HALO:max(int(s.chunk_cells)/2,LAYER_RULE_SAMPLES)+2}

// What the field of a new source holds: heights at zero, or air.
@(private)
field_fill :: proc "contextless" (info:Source_Info) -> f32 {return info.kind==.Volume?field_limit(info):0}

@(private)
source_allocate :: proc(s:^Source,info:Source_Info,allocator:=context.allocator) -> bool {
    if !source_valid(info) {return false}
    temporary:=Source{allocator=allocator,info=info}
    if !grid_init(&temporary.field,{int(info.samples.x),int(info.samples.y),int(info.samples.z)},field_fill(info),allocator) {return false}
    if !weights_init(&temporary) {source_destroy(&temporary);return false}
    temporary.scratch=make([dynamic]f32,allocator)
    source_destroy(s)
    s^=temporary
    return true
}

source_make :: proc(s:^Source,kind:Source_Kind,samples:[3]int,cell:f32,chunk_cells:int,allocator:=context.allocator) -> bool {
    for n in samples {if n<1 || n>SAMPLES_MAX {return false}}
    if chunk_cells<CHUNK_CELLS_MIN || chunk_cells>CHUNK_CELLS_MAX {return false}
    info:=Source_Info{kind=kind,samples={u32(samples.x),u32(samples.y),u32(samples.z)},cell=cell,chunk_cells=u32(chunk_cells),layer_count=1,layers={0=LAYER_DEFAULT}}
    return source_allocate(s,info,allocator) && (kind!=.Volume || volume_box(s))
}

source_destroy :: proc(s:^Source) {
    delete(s.scratch)
    grid_destroy(&s.field,s.allocator)
    grid_destroy(&s.holes,s.allocator)
    grid_destroy(&s.weights,s.allocator)
    coarse_destroy(&s.coarse,s.allocator)
    delete(s.file,s.allocator)
    s^={}
}

// A source holds every sample of its shape.
@(private)
source_samples_held :: proc "contextless" (s:^Source) -> bool {
    return s.field.size=={int(s.samples.x),int(s.samples.y),int(s.samples.z)}
}

source_clone :: proc(dst,src:^Source,allocator:=context.allocator) -> bool {
    if !source_valid(src.info) || !source_samples_held(src) {return false}
    temporary:Source
    if !source_allocate(&temporary,src.info,allocator) {return false}
    if !grid_clone(&temporary.field,&src.field,allocator) || !grid_clone(&temporary.holes,&src.holes,allocator) || !grid_clone(&temporary.weights,&src.weights,allocator) {source_destroy(&temporary);return false}
    if src.file!="" {
        error:runtime.Allocator_Error
        if temporary.file,error=strings.clone(src.file,allocator);error!=nil {source_destroy(&temporary);return false}
    }
    temporary.origin=src.origin
    source_destroy(dst)
    dst^=temporary
    return true
}

source_load :: proc(s:^Source,path:string,types:^asset.Types,allocator:=context.allocator,codecs:^codec.Table=nil) -> (id:base.Asset_Id,ok:bool) {
    file:asset.Asset
    if asset.asset_load(&file,path,allocator,codecs=codecs)!=.None {return}
    defer asset.asset_close(&file)
    return source_read(s,&file,types,allocator)
}

// The source an open .terrain holds; s is replaced only when it is valid. With
// pages, the path of file, a Heightfield or Volume leaves the values of its
// pages in that file (asset_load_front opens it without them), read when
// needed.
source_read :: proc(s:^Source,file:^asset.Asset,types:^asset.Types,allocator:=context.allocator,pages:="") -> (id:base.Asset_Id,ok:bool) {
    if asset.kind_check(file,TERRAIN_KIND,VERSION)!=.None {return}
    info,error:=asset.asset_row(file,types,"terrain",Source_Info)
    if error!=.None || info==nil || !source_valid(info^) {return}
    temporary:Source
    if !source_allocate(&temporary,info^,allocator) {return}
    defer source_destroy(&temporary)
    g:=&temporary.field
    if !grid_read_document(g,file,types,g.size,"field_pages","field_blocks",value_finite,allocator,pages!="") || !grid_within(g,field_limit(info^)) {return}
    if pages!="" {
        error:runtime.Allocator_Error
        if temporary.file,error=strings.clone(pages,allocator);error!=nil {return}
    }
    paged:=pages!=""
    if !source_weights_read(&temporary,file,types,allocator,paged) || !source_holes_read(&temporary,file,types,allocator,paged) {return}
    temporary.origin=file.blob.header.content_hash
    source_destroy(s)
    s^=temporary
    temporary={}
    return file.blob.header.id,true
}

// Writes the .terrain of a source to path. origin: path is the file the
// source is read from, which is its origin from now on. Its pages stay
// altered: the file codes their values with loss, so what the source holds
// is not what the file has until it is read again.
source_save :: proc(s:^Source,path:string,id:base.Asset_Id,types:^asset.Types,origin:=false) -> asset.Error {
    data:=source_bytes(s,id,types,s.allocator) or_return
    defer delete(data,s.allocator)
    if serial.file_write_atomic(path,data)!=.None {return .IO}
    if origin {s.origin=asset.blob_hash(data)}
    return .None
}

// The .terrain file of a source, as bytes from allocator aligned for its
// chunks; with import_info, the record of the import it comes from. keep has
// the grids keep their blocks for the next time (grid_put_document).
source_bytes :: proc(s:^Source,id:base.Asset_Id,types:^asset.Types,allocator:=context.allocator,import_info:^asset.Import_Info=nil,keep:=false) -> (data:[]u8,error:asset.Error) {
    if !source_valid(s.info) || !source_samples_held(s) {return nil,.Invalid}
    if !grid_within(&s.field,field_limit(s.info)) {return nil,.Invalid}
    document:asset.Document
    asset.document_init(&document,TERRAIN_KIND,id,s.allocator)
    defer asset.document_destroy(&document)
    document.kind_version=VERSION
    info:=s.info
    asset.document_put_row(&document,types,"terrain",&info) or_return
    // Heights go on the lattice of their page coding; distances stay as they are.
    grid_put_document(&document,types,&s.field,"field_pages","field_blocks",value_finite,s.file,s.allocator,keep,quantize=s.kind==.Heightfield,codecs=s.codecs) or_return
    source_weights_put(&document,types,s,keep) or_return
    source_holes_put(&document,types,s,keep) or_return
    asset.import_put(&document,types,import_info) or_return
    return asset.document_bytes(&document,allocator)
}

// What a source counts against Terrain_Settings.samples: the samples its
// grids hold in memory, with the coarse grid of a Heightfield.
source_cost :: proc(s:^Source) -> int {
    return grid_dense(&s.field)+grid_dense(&s.weights)+grid_dense(&s.holes)+grid_dense(&s.coarse.heights)
}

// The value of a sample: a height of a Heightfield, a distance of a Volume.
source_value :: #force_inline proc "contextless" (s:^Source,p:[3]int) -> f32 {return grid_value(&s.field,p)}

// Writes a sample, giving its page its own values; false without memory.
source_set :: proc(s:^Source,p:[3]int,value:f32) -> bool {return grid_put(&s.field,p,value,s.allocator)}

source_origin :: proc "contextless" (s:^Source) -> [3]f32 {
    return -[3]f32{f32(s.samples.x-1),f32(s.samples.y-1),f32(s.samples.z-1)}*(s.cell*0.5)
}

// The box of samples a to b in the space of a source; that of a Heightfield
// reaches every height.
source_box :: proc "contextless" (s:^Source,a,b:[3]int) -> (low,high:[3]f32) {
    origin:=source_origin(s)
    low,high=origin+[3]f32{f32(a.x),f32(a.y),f32(a.z)}*s.cell,origin+[3]f32{f32(b.x),f32(b.y),f32(b.z)}*s.cell
    if s.kind==.Heightfield {low.y,high.y=-HEIGHT_LIMIT,HEIGHT_LIMIT}
    return
}

// A point of a source carried along its normal onto the surface: on a
// Heightfield to its height there, on a Volume to the surface reach about it.
source_carry :: proc(s:^Source,point,normal:[3]f32,reach:f32) -> ([3]f32,[3]f32) {
    if s.kind==.Heightfield {return {point.x,source_height(s,point.x,point.z),point.z},normal}
    if reach>0 {if hit,hit_normal,on:=source_ray(s,point+normal*reach,-normal);on && linalg.length(hit-point)<=reach*2 {return hit,hit_normal}}
    return point,normal
}

source_point :: proc "contextless" (s:^Source,p:[3]int) -> [3]f32 {
    point:=source_origin(s)+[3]f32{f32(p.x),f32(p.y),f32(p.z)}*s.cell
    if s.kind==.Heightfield {point.y=grid_get(&s.field,p.x,p.z)}
    return point
}

source_density :: proc "contextless" (s:^Source,point:[3]f32) -> f32 {
    if s.kind==.Heightfield {return point.y-source_height(s,point.x,point.z)}
    return volume_density(s,point)
}

source_normal :: proc "contextless" (s:^Source,p:[3]f32) -> [3]f32 {
    h:=s.cell*0.25
    return linalg.normalize0([3]f32{
        source_density(s,p+{h,0,0})-source_density(s,p-{h,0,0}),
        source_density(s,p+{0,h,0})-source_density(s,p-{0,h,0}),
        source_density(s,p+{0,0,h})-source_density(s,p-{0,0,h}),
    })
}

source_ray :: proc(s:^Source,origin,direction:[3]f32) -> (point,normal:[3]f32,ok:bool) {
    if !source_valid(s.info) || !source_samples_held(s) {return}
    for axis in 0..<3 {if origin[axis]-origin[axis]!=0 || direction[axis]-direction[axis]!=0 {return}}
    d:=linalg.normalize0(direction)
    if d=={} {return}
    low,high:=source_box(s,{},s.field.size-1)
    near,far:=f32(0),f32(1e9)
    for axis in 0..<3 {
        if abs(d[axis])<1e-9 {
            if origin[axis]<low[axis] || origin[axis]>high[axis] {return}
        } else {
            a,b:=(low[axis]-origin[axis])/d[axis],(high[axis]-origin[axis])/d[axis]
            if a>b {a,b=b,a}
            near,far=max(near,a),min(far,b)
        }
    }
    if near>far {return}
    if s.kind==.Heightfield {return heightfield_ray(s,origin,d,low,near,far)}
    return volume_ray(s,origin,d,low,near,far)
}
