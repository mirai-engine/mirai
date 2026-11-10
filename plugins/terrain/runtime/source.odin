package terrain

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "mirai:std/serial"

KIND :: asset.Fourcc(u32('T')|u32('E')<<8|u32('R')<<16|u32('R')<<24)
EXTENSION :: ".terrain"
VERSION :: 9
HEIGHT_SAMPLES_MAX :: 16385
VOLUME_SAMPLES_MAX :: 129
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
    using info:Source_Info,
    heights:Grid(f32),    // Heightfield: samples.x by samples.z
    holes:Grid(u8),       // Heightfield: 1 for each cell without surface; no pages without holes
    distances:Grid(f32),  // Volume: samples.x by y by z in blocks; one all air or all solid holds no values
    scratch:[dynamic]f32, // the region a brush reads while it writes
    ray_mesh:geom.Mesh_Buffer,
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
    switch info.kind {
    case .Heightfield: return info.samples.y==1 && info.samples.x>=2 && info.samples.z>=2 && info.samples.x<=HEIGHT_SAMPLES_MAX && info.samples.z<=HEIGHT_SAMPLES_MAX
    case .Volume: return info.samples.x>=3 && info.samples.y>=3 && info.samples.z>=3 && info.samples.x<=VOLUME_SAMPLES_MAX && info.samples.y<=VOLUME_SAMPLES_MAX && info.samples.z<=VOLUME_SAMPLES_MAX
    }
    return false
}
@(private)
height_valid :: proc "contextless" (value:f32) -> bool {return value-value==0 && abs(value)<=HEIGHT_LIMIT}

@(private)
source_allocate :: proc(s:^Source,info:Source_Info,allocator:=context.allocator,editable:=true) -> bool {
    if !source_valid(info) {return false}
    temporary:=Source{allocator=allocator,info=info}
    if info.kind==.Heightfield {
        if !grid_init(&temporary.heights,{int(info.samples.x),1,int(info.samples.z)},0,allocator) {return false}
    } else if !grid_init(&temporary.distances,{int(info.samples.x),int(info.samples.y),int(info.samples.z)},info.cell*SDF_BAND_CELLS,allocator) {
        return false
    }
    if !weights_init(&temporary) {source_destroy(&temporary);return false}
    temporary.scratch=make([dynamic]f32,allocator)
    geom.mesh_buffer_init(&temporary.ray_mesh,allocator)
    if info.kind==.Volume && editable {
        if reserve(&temporary.ray_mesh.positions,36)!=nil || reserve(&temporary.ray_mesh.normals,36)!=nil || reserve(&temporary.ray_mesh.indices,36)!=nil {source_destroy(&temporary);return false}
    }
    source_destroy(s)
    s^=temporary
    return true
}

source_make :: proc(s:^Source,kind:Source_Kind,samples:[3]int,cell:f32,chunk_cells:int,allocator:=context.allocator) -> bool {
    for n in samples {if n<1 || n>HEIGHT_SAMPLES_MAX {return false}}
    if chunk_cells<CHUNK_CELLS_MIN || chunk_cells>CHUNK_CELLS_MAX {return false}
    info:=Source_Info{kind=kind,samples={u32(samples.x),u32(samples.y),u32(samples.z)},cell=cell,chunk_cells=u32(chunk_cells),layer_count=1,layers={0=LAYER_DEFAULT}}
    if !source_allocate(s,info,allocator) {return false}
    if kind==.Volume {
        half:=[3]f32{f32(samples.x-1),f32(samples.y-1),f32(samples.z-1)}*(cell*0.5)
        bottom:=-half.y+cell
        center_y:=bottom*0.5
        extents:=[3]f32{max(half.x-cell,cell*0.25),max(-bottom*0.5,cell*0.25),max(half.z-cell,cell*0.25)}
        g:=&s.distances
        scratch,error:=make([]f32,PAGE_VALUES,context.temp_allocator)
        if error!=nil {source_destroy(s);return false}
        // Each block takes values of its own only where it is not all air or all solid.
        for &page,i in g.pages {
            first,_:=grid_page_region(g,i)
            extent,count:=grid_page_extent(g,i)
            values:=scratch[:count]
            for z in 0..<extent.z {for y in 0..<extent.y {for x in 0..<extent.x {
                p:=source_point(s,first+{x,y,z})-[3]f32{0,center_y,0}
                d:=[3]f32{abs(p.x),abs(p.y),abs(p.z)}-extents
                outside:=[3]f32{max(d.x,0),max(d.y,0),max(d.z,0)}
                distance:=linalg.length(outside)+min(max(d.x,max(d.y,d.z)),0)
                values[x+extent.x*(y+extent.y*z)]=clamp(distance,-cell*SDF_BAND_CELLS,cell*SDF_BAND_CELLS)
            }}}
            page.fill=values[0]
            if page_uniform(values) {continue}
            held,made:=shared_make(f32,count,s.allocator)
            if !made {source_destroy(s);return false}
            copy(held,values)
            page.values=held
        }
    }
    return true
}

source_destroy :: proc(s:^Source) {
    delete(s.scratch)
    grid_destroy(&s.heights,s.allocator)
    grid_destroy(&s.distances,s.allocator)
    grid_destroy(&s.holes,s.allocator)
    grid_destroy(&s.weights,s.allocator)
    coarse_destroy(&s.coarse,s.allocator)
    geom.mesh_buffer_destroy(&s.ray_mesh)
    delete(s.file,s.allocator)
    s^={}
}

// A Heightfield or Volume source holds every sample of its shape.
@(private)
source_samples_held :: proc "contextless" (s:^Source) -> bool {
    if s.kind==.Heightfield {return s.heights.size=={int(s.samples.x),1,int(s.samples.z)} && len(s.heights.pages)>0}
    return s.distances.size=={int(s.samples.x),int(s.samples.y),int(s.samples.z)} && len(s.distances.pages)>0
}

source_clone :: proc(dst,src:^Source,allocator:=context.allocator,editable:=true) -> bool {
    if !source_valid(src.info) || !source_samples_held(src) {return false}
    temporary:Source
    if !source_allocate(&temporary,src.info,allocator,editable) {return false}
    if !grid_clone(&temporary.heights,&src.heights,allocator) || !grid_clone(&temporary.distances,&src.distances,allocator) || !grid_clone(&temporary.holes,&src.holes,allocator) || !grid_clone(&temporary.weights,&src.weights,allocator) {source_destroy(&temporary);return false}
    if src.file!="" {
        error:runtime.Allocator_Error
        if temporary.file,error=strings.clone(src.file,allocator);error!=nil {source_destroy(&temporary);return false}
    }
    temporary.origin=src.origin
    source_destroy(dst)
    dst^=temporary
    return true
}

source_load :: proc(s:^Source,path:string,types:^asset.Types,allocator:=context.allocator) -> (id:base.Asset_Id,ok:bool) {
    file:asset.Asset
    if asset.asset_load(&file,path,allocator)!=.None {return}
    defer asset.asset_close(&file)
    return source_read(s,&file,types,allocator)
}

// The source an open .terrain holds; s is replaced only when it is valid.
// editable false leaves out what only brushes use, as source_clone. With
// pages, the path of file, a Heightfield or Volume leaves the values of its
// pages in that file (asset_load_front opens it without them), read when
// needed.
source_read :: proc(s:^Source,file:^asset.Asset,types:^asset.Types,allocator:=context.allocator,editable:=true,pages:="") -> (id:base.Asset_Id,ok:bool) {
    if asset.kind_check(file,KIND,VERSION)!=.None {return}
    info,error:=asset.asset_row(file,types,"terrain",Source_Info)
    if error!=.None || info==nil || !source_valid(info^) {return}
    temporary:Source
    if !source_allocate(&temporary,info^,allocator,editable) {return}
    defer source_destroy(&temporary)
    if info.kind==.Heightfield {
        if !grid_read_document(&temporary.heights,file,types,temporary.heights.size,"height_pages","height_blocks",height_valid,allocator,pages!="") {return}
    } else {
        g:=&temporary.distances
        if !grid_read_document(g,file,types,g.size,"distance_pages","distance_blocks",distance_finite,allocator,pages!="") {return}
        band:=info.cell*SDF_BAND_CELLS
        for page in g.pages {if !(abs(page.fill)<=band) || !distances_within(page.values,band) {return}}
    }
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
// source is read from, so what it holds now is as that file has it.
source_save :: proc(s:^Source,path:string,id:base.Asset_Id,types:^asset.Types,origin:=false) -> asset.Error {
    data:=source_bytes(s,id,types,s.allocator) or_return
    defer delete(data,s.allocator)
    if serial.file_write_atomic(path,data)!=.None {return .IO}
    if origin {source_origin_set(s,asset.blob_hash(data))}
    return .None
}

// What a source holds is as the file of that content hash has it.
@(private)
source_origin_set :: proc(s:^Source,origin:u64) {
    s.origin=origin
    unalter :: proc(g:^Grid($T)) {for &page in g.pages {page.altered=false}}
    unalter(&s.heights);unalter(&s.holes);unalter(&s.distances);unalter(&s.weights)
}

// The .terrain file of a source, as bytes from allocator aligned for its
// chunks; with import_info, the record of the import it comes from. keep has
// the grids keep their blocks for the next time (grid_put_document).
source_bytes :: proc(s:^Source,id:base.Asset_Id,types:^asset.Types,allocator:=context.allocator,import_info:^asset.Import_Info=nil,keep:=false) -> (data:[]u8,error:asset.Error) {
    if !source_valid(s.info) || !source_samples_held(s) {return nil,.Invalid}
    band:=s.cell*SDF_BAND_CELLS
    for page in s.distances.pages {if !(abs(page.fill)<=band) || !distances_within(page.values,band) {return nil,.Invalid}}
    document:asset.Document
    asset.document_init(&document,KIND,id,s.allocator)
    defer asset.document_destroy(&document)
    document.kind_version=VERSION
    info:=s.info
    asset.document_put_row(&document,types,"terrain",&info) or_return
    if s.kind==.Heightfield {
        grid_put_document(&document,types,&s.heights,"height_pages","height_blocks",height_valid,s.file,s.allocator,keep,quantize=true) or_return
    } else {
        grid_put_document(&document,types,&s.distances,"distance_pages","distance_blocks",distance_finite,s.file,s.allocator) or_return
    }
    source_weights_put(&document,types,s,keep) or_return
    source_holes_put(&document,types,s,keep) or_return
    asset.import_put(&document,types,import_info) or_return
    return asset.document_bytes(&document,allocator)
}

// What a source counts against Terrain_Settings.samples: the samples its
// pages hold in memory, with the coarse grid of a Heightfield and the weights
// of a Volume.
source_cost :: proc(s:^Source) -> int {
    if s.kind==.Heightfield {return grid_dense(&s.heights)+grid_dense(&s.coarse.heights)}
    return grid_dense(&s.distances)+grid_dense(&s.weights)
}

// The value of a sample: a height of a Heightfield, a distance of a Volume.
source_value :: #force_inline proc "contextless" (s:^Source,p:[3]int) -> f32 {
    if s.kind==.Heightfield {return grid_get(&s.heights,p.x,p.z)}
    return block_get(&s.distances,p)
}

// Writes a sample, giving its page its own values; false without memory.
source_set :: proc(s:^Source,p:[3]int,value:f32) -> bool {
    if s.kind==.Heightfield {return grid_put(&s.heights,{p.x,0,p.z},value,s.allocator)}
    return grid_put(&s.distances,p,value,s.allocator)
}

source_origin :: proc "contextless" (s:^Source) -> [3]f32 {
    return -[3]f32{f32(s.samples.x-1),f32(s.samples.y-1),f32(s.samples.z-1)}*(s.cell*0.5)
}

source_point :: proc "contextless" (s:^Source,p:[3]int) -> [3]f32 {
    point:=source_origin(s)+[3]f32{f32(p.x),f32(p.y),f32(p.z)}*s.cell
    if s.kind==.Heightfield {point.y=grid_get(&s.heights,p.x,p.z)}
    return point
}

source_height :: proc "contextless" (s:^Source,x,z:f32) -> f32 {
    origin:=source_origin(s)
    column,row:=clamp((x-origin.x)/s.cell,0,f32(s.samples.x-1)),clamp((z-origin.z)/s.cell,0,f32(s.samples.z-1))
    c,r:=min(int(column),int(s.samples.x)-2),min(int(row),int(s.samples.z)-2)
    u,v:=column-f32(c),row-f32(r)
    a,b:=grid_get(&s.heights,c,r),grid_get(&s.heights,c+1,r)
    d,e:=grid_get(&s.heights,c,r+1),grid_get(&s.heights,c+1,r+1)
    if u+v<=1 {return a+(b-a)*u+(d-a)*v}
    return e+(d-e)*(1-u)+(b-e)*(1-v)
}

source_density :: proc "contextless" (s:^Source,point:[3]f32) -> f32 {
    if s.kind==.Heightfield {return point.y-source_height(s,point.x,point.z)}
    p:=(point-source_origin(s))/s.cell
    base_cell:[3]int
    weight:[3]f32
    for axis in 0..<3 {
        at:=clamp(p[axis],0,f32(s.samples[axis]-1))
        base_cell[axis]=min(int(at),int(s.samples[axis])-2)
        weight[axis]=at-f32(base_cell[axis])
    }
    result:=f32(0)
    for corner in 0..<8 {
        offset:=[3]int{corner&1,(corner>>1)&1,(corner>>2)&1}
        w:=(offset.x==0?1-weight.x:weight.x)*(offset.y==0?1-weight.y:weight.y)*(offset.z==0?1-weight.z:weight.z)
        result+=block_get(&s.distances,base_cell+offset)*w
    }
    return result
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
    low:=source_origin(s)
    high:=low+[3]f32{f32(s.samples.x-1),f32(s.samples.y-1),f32(s.samples.z-1)}*s.cell
    near,far:=f32(0),f32(1e9)
    for axis in 0..<3 {
        if s.kind==.Heightfield && axis==1 {continue}
        if abs(d[axis])<1e-9 {
            if origin[axis]<low[axis] || origin[axis]>high[axis] {return}
        } else {
            a,b:=(low[axis]-origin[axis])/d[axis],(high[axis]-origin[axis])/d[axis]
            if a>b {a,b=b,a}
            near,far=max(near,a),min(far,b)
        }
    }
    if near>far {return}
    if s.kind==.Heightfield {
        start:=(origin+d*(near+s.cell*1e-5)-low)/s.cell
        c,r:=clamp(int(math.floor(start.x)),0,int(s.samples.x)-2),clamp(int(math.floor(start.z)),0,int(s.samples.z)-2)
        sx,sz:=d.x>=0?1:-1,d.z>=0?1:-1
        for _ in 0..<int(s.samples.x+s.samples.z)+2 {
            tx,tz:=f32(1e9),f32(1e9)
            if abs(d.x)>1e-9 {tx=(low.x+f32(c+(sx>0?1:0))*s.cell-origin.x)/d.x}
            if abs(d.z)>1e-9 {tz=(low.z+f32(r+(sz>0?1:0))*s.cell-origin.z)/d.z}
            end:=min(far,min(tx,tz))
            // A cell whose pages are not in memory ends the ray: nothing is known past it.
            if !cell_held(s,c,r) {return}
            a,b,e,f:=source_point(s,{c,0,r}),source_point(s,{c+1,0,r}),source_point(s,{c,0,r+1}),source_point(s,{c+1,0,r+1})
            best:=f32(1e9)
            faces:=[2]mm.Triangle{{a,e,b},{b,e,f}}
            for triangle in faces[:source_hole(s,c,r)?0:2] {
                t,_,hit:=mm.ray_triangle({origin,d},triangle)
                if hit && t>=near-s.cell*1e-4 && t<=end+s.cell*1e-4 && t<best {best=t;normal=mm.triangle_normal(triangle);ok=true}
            }
            if ok {return origin+d*best,normal,true}
            if end>=far || tx==1e9 && tz==1e9 {return}
            if tx<=tz {c+=sx}
            if tz<=tx {r+=sz}
            if c<0 || r<0 || c>=int(s.samples.x)-1 || r>=int(s.samples.z)-1 {return}
            near=end
        }
        return
    }
    // Each cell is extracted from a window of its samples and those its gradients read.
    window:[4*4*4]f32
    grid:=geom.Scalar_Grid{samples={int(s.samples.x),int(s.samples.y),int(s.samples.z)},cell={s.cell,s.cell,s.cell},origin=low}
    start:=(origin+d*(near+s.cell*1e-5)-low)/s.cell
    cell,advance:[3]int
    for axis in 0..<3 {cell[axis]=clamp(int(math.floor(start[axis])),0,int(s.samples[axis])-2);advance[axis]=d[axis]>=0?1:-1}
    for _ in 0..<int(s.samples.x+s.samples.y+s.samples.z)+4 {
        next:=[3]f32{1e9,1e9,1e9}
        for axis in 0..<3 {if abs(d[axis])>1e-9 {next[axis]=(low[axis]+f32(cell[axis]+(advance[axis]>0?1:0))*s.cell-origin[axis])/d[axis]}}
        end:=min(far,min(next.x,min(next.y,next.z)))
        last:[3]int
        for axis in 0..<3 {grid.first[axis],last[axis]=max(cell[axis]-1,0),min(cell[axis]+2,int(s.samples[axis])-1)}
        // A cell whose blocks are not in memory ends the ray: nothing is known past it.
        if !volume_held(s,grid.first,last) {return}
        grid.extent=last-grid.first+1
        grid.values=window[:grid.extent.x*grid.extent.y*grid.extent.z]
        for z in 0..<grid.extent.z {for y in 0..<grid.extent.y {for x in 0..<grid.extent.x {
            window[x+grid.extent.x*(y+grid.extent.y*z)]=block_get(&s.distances,grid.first+{x,y,z})
        }}}
        if geom.isosurface(grid,cell,cell+[3]int{1,1,1},&s.ray_mesh)!=.None {return}
        best:=f32(1e9)
        for triangle:=0;triangle<len(s.ray_mesh.indices);triangle+=3 {
            a,b,c:=s.ray_mesh.positions[s.ray_mesh.indices[triangle]],s.ray_mesh.positions[s.ray_mesh.indices[triangle+1]],s.ray_mesh.positions[s.ray_mesh.indices[triangle+2]]
            face:=mm.Triangle{a,b,c}
            t,_,hit:=mm.ray_triangle({origin,d},face)
            if hit && t>=near-s.cell*1e-4 && t<=end+s.cell*1e-4 && t<best {best=t;normal=mm.triangle_normal(face);ok=true}
        }
        if ok {return origin+d*best,normal,true}
        if end>=far {return}
        for axis in 0..<3 {
            if next[axis]>end {continue}
            cell[axis]+=advance[axis]
            if cell[axis]<0 || cell[axis]>=int(s.samples[axis])-1 {return}
        }
        near=end
    }
    return
}
