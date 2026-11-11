package terrain

import "base:intrinsics"
import "base:runtime"
import "core:math/linalg"
import "core:mem"
import "mirai:std/jobs"

// The coarse grid of a Heightfield: its heights, and the weights of its
// layers, every COARSE samples and at its last row and column, in memory
// while the source is. Between them a point takes the bilinear blend of the
// four around it (coarse_height). The nodes of the quadtree are built from
// it, and every border whose level reaches COARSE_LEVEL, so that the pieces
// that share a border build it alike whatever pages are in memory. A source
// read from its file fills it reading every page once; edits keep it. Its
// grids are in pages shared with the copies of the source, as its samples
// are. Without one (a source of the editor) the same values come from the
// samples.
COARSE_LEVEL :: 3
COARSE :: 1<<COARSE_LEVEL

Coarse :: struct {
    size:[2]int,
    heights:Grid(f32),
    weights:Grid(Weights), // while the source has layers
}

coarse_count :: #force_inline proc "contextless" (samples:int) -> int {return (samples-1+COARSE-1)/COARSE+1}
coarse_position :: #force_inline proc "contextless" (i,samples:int) -> int {return min(i*COARSE,samples-1)}

@(private)
coarse_destroy :: proc(c:^Coarse,allocator:runtime.Allocator) {
    grid_destroy(&c.heights,allocator);grid_destroy(&c.weights,allocator)
    c^={}
}

@(private)
coarse_copy :: proc(dst,src:^Coarse,allocator:runtime.Allocator) -> bool {
    if !grid_copy(&dst.heights,&src.heights,allocator) || !grid_copy(&dst.weights,&src.weights,allocator) {return false}
    dst.size=src.size
    return true
}

// A grid of the size of the coarse grid, every page with values of its own.
@(private)
coarse_grid :: proc(g:^Grid($T),size:[2]int,allocator:runtime.Allocator) -> bool {
    return (g.size=={size.x,1,size.y} || grid_init(g,{size.x,1,size.y},T{},allocator)) && grid_prepare(g,{},{size.x-1,0,size.y-1},allocator)
}

// A sample of the coarse grid: from the grid, or from the samples without one.
@(private)
coarse_value :: #force_inline proc "contextless" (s:^Source,i,j:int) -> f32 {
    if !grid_none(&s.coarse.heights) {return grid_get(&s.coarse.heights,i,j)}
    return grid_get(&s.field,coarse_position(i,int(s.samples.x)),coarse_position(j,int(s.samples.z)))
}

@(private)
coarse_weight :: #force_inline proc "contextless" (s:^Source,i,j:int) -> [4]f32 {
    if !grid_none(&s.coarse.weights) {return weights_float(grid_get(&s.coarse.weights,i,j))}
    return weights_float(grid_get(&s.weights,coarse_position(i,int(s.samples.x)),coarse_position(j,int(s.samples.z))))
}

// The cell of the coarse grid along an axis of samples that holds p, and where in it.
@(private)
coarse_cell :: #force_inline proc "contextless" (p,samples:int) -> (i:int,t:f32) {
    p:=clamp(p,0,samples-1)
    i=min(p/COARSE,coarse_count(samples)-2)
    low:=i*COARSE
    return i,f32(p-low)/f32(min(low+COARSE,samples-1)-low)
}

// The height of the coarse grid at sample x,z.
coarse_height :: proc "contextless" (s:^Source,x,z:int) -> f32 {
    i,u:=coarse_cell(x,int(s.samples.x))
    j,v:=coarse_cell(z,int(s.samples.z))
    a,b:=coarse_value(s,i,j),coarse_value(s,i+1,j)
    c,d:=coarse_value(s,i,j+1),coarse_value(s,i+1,j+1)
    return (a*(1-u)+b*u)*(1-v)+(c*(1-u)+d*u)*v
}

@(private)
coarse_weights :: proc "contextless" (s:^Source,x,z:int) -> [4]f32 {
    i,u:=coarse_cell(x,int(s.samples.x))
    j,v:=coarse_cell(z,int(s.samples.z))
    a,b:=coarse_weight(s,i,j),coarse_weight(s,i+1,j)
    c,d:=coarse_weight(s,i,j+1),coarse_weight(s,i+1,j+1)
    return (a*(1-u)+b*u)*(1-v)+(c*(1-u)+d*u)*v
}

// As heightfield_normal, over the coarse grid.
coarse_normal :: proc "contextless" (s:^Source,x,z,step:int) -> [3]f32 {
    nx,nz:=int(s.samples.x),int(s.samples.z)
    x0,x1,z0,z1:=max(x-step,0),min(x+step,nx-1),max(z-step,0),min(z+step,nz-1)
    west,east:=coarse_height(s,x0,z),coarse_height(s,x1,z)
    north,south:=coarse_height(s,x,z0),coarse_height(s,x,z1)
    return linalg.normalize0([3]f32{(west-east)/(f32(x1-x0)*s.cell),1,(north-south)/(f32(z1-z0)*s.cell)})
}

// As heightfield_vertex, over the coarse grid.
@(private)
coarse_vertex :: proc "contextless" (s:^Source,x,z,step:int) -> (position,normal:[3]f32,uv,uv1:[2]f32) {
    position=source_origin(s)+[3]f32{f32(x),0,f32(z)}*s.cell
    position.y=coarse_height(s,x,z)
    normal=coarse_normal(s,x,z,step)
    w:=layers_vertex(s,coarse_weights(s,x,z),coarse_normal(s,x,z,LAYER_RULE_SAMPLES),position.y)
    return position,normal,{w[0],w[1]},{w[2],w[3]}
}

// The values of page i of a grid, from memory or read from its block into
// scratch; a uniform page gives its fill.
@(private)
coarse_page :: proc(g:^Grid($T),i:int,file:string,read:^Page_Reader,scratch:[]T) -> (values:[]T,fill:T,ok:bool) {
    page:=&g.pages[i]
    if page.values!=nil {return page.values,{},true}
    if !grid_absent(g,i) {return nil,page.fill,true}
    _,count:=grid_page_extent(g,i)
    if !page_load(grid_block(g,i),file,read,mem.slice_to_bytes(scratch[:count])) {return}
    return scratch[:count],{},true
}

// How far each level of a piece is from the samples it covers, in metres
// along Y: what decides the level a view sees it at (lod_pixels). Of a
// chunk, its levels from its samples, and how far they are from the coarse
// grid; of a node, its levels from the coarse grid and that distance of its chunks.
LOD_ERRORS :: LOD_LEVELS_MAX+QUAD_DEPTH_MAX+1
Lod_Errors :: struct {
    levels:[LOD_ERRORS]f32,
    coarse:f32,
}

// Fills the coarse grid of a Heightfield from every sample, reading the
// pages in their blocks by rows of chunks, and by chunk ranges, with the
// lowest and highest of its samples, and errors, with those of its levels.
// The rows of chunks run in jobs of js when there is one: each reads its
// own pages and writes its chunks and the lines of the coarse grid in its
// rows. False when a page cannot be read or without memory.
source_coarse_build :: proc(s:^Source,ranges:[][2]f32,errors:[]Lod_Errors=nil,js:^jobs.Job_System=nil,worker:=jobs.OWNER) -> bool {
    if s.kind!=.Heightfield {return true}
    nx,nz:=int(s.samples.x),int(s.samples.z)
    size:=[2]int{coarse_count(nx),coarse_count(nz)}
    next:Coarse
    ok:=false
    defer if !ok {coarse_destroy(&next,s.allocator)}
    if !coarse_grid(&next.heights,size,s.allocator) {return false}
    next.size=size
    rows:=Coarse_Rows{s=s,next=&next,ranges=ranges,errors=errors,js=js}
    count:=chunk_counts(s).z
    if js!=nil && jobs.worker_count(js)>1 && count>1 {jobs.parallel_for(js,worker,count,1,coarse_rows,&rows)} else {coarse_rows(&rows,0,count,worker)}
    if intrinsics.atomic_load(&rows.failed) {return false}
    read:Page_Reader
    if !page_reader_init(&read,context.temp_allocator) {return false}
    defer page_reader_destroy(&read,context.temp_allocator)
    if !coarse_grid(&next.weights,size,s.allocator) || !coarse_weights_fill(s,&next,&read) {return false}
    coarse_destroy(&s.coarse,s.allocator)
    s.coarse=next
    ok=true
    return true
}

@(private)
Coarse_Rows :: struct {
    s:^Source,
    next:^Coarse,
    ranges:[][2]f32,
    errors:[]Lod_Errors,
    js:^jobs.Job_System,
    failed:bool, // a page could not be read, or there was no memory
}

// The chunks of a row of chunks whose samples a band holds.
@(private)
Coarse_Chunks :: struct {
    s:^Source,
    view:Sample_View,
    cz:int,
    ranges:[][2]f32,
    errors:[]Lod_Errors,
}

@(private)
coarse_chunks :: proc(row:^Coarse_Chunks,first,last:int,worker:int) {
    s:=row.s
    nx,nz:=int(s.samples.x),int(s.samples.z)
    cells:=int(s.chunk_cells)
    counts:=chunk_counts(s)
    cz:=row.cz
    low,high:=cz*cells,min(cz*cells+cells,nz-1)
    for cx in first..<last {
        index:=cx+counts.x*cz
        x_low,x_high:=cx*cells,min(cx*cells+cells,nx-1)
        if index<len(row.ranges) {
            range:=[2]f32{max(f32),-max(f32)}
            for z in low..=high {for x in x_low..=x_high {h:=sample_at(row.view,x,z);range={min(range.x,h),max(range.y,h)}}}
            row.ranges[index]=range
        }
        if index<len(row.errors) {chunk_errors_measure(s,row.view,{cx,cz},&row.errors[index])}
    }
}

// Rows first..<last of chunks of source_coarse_build.
@(private)
coarse_rows :: proc(rows:^Coarse_Rows,first,last:int,worker:int) {
    s,next,ranges,errors:=rows.s,rows.next,rows.ranges,rows.errors
    nx,nz:=int(s.samples.x),int(s.samples.z)
    size:=next.size
    cells:=int(s.chunk_cells)
    counts:=chunk_counts(s)
    // The rows of a row of chunks, from the line of the coarse grid below it to the one above.
    band_rows:=cells+2*COARSE+1
    read:Page_Reader
    read_ok:=page_reader_init(&read,context.temp_allocator)
    defer page_reader_destroy(&read,context.temp_allocator)
    heights,heights_error:=make([]f32,PAGE*PAGE,context.temp_allocator)
    band,band_error:=make([]f32,band_rows*nx,context.temp_allocator)
    if !read_ok || heights_error!=nil || band_error!=nil {intrinsics.atomic_store(&rows.failed,true);return}
    g:=&s.field
    for cz in first..<last {
        low,high:=cz*cells,min(cz*cells+cells,nz-1)
        b0,b1:=low/COARSE*COARSE,min((high+COARSE-1)/COARSE*COARSE,nz-1)
        for pz in b0/PAGE..=b1/PAGE {for px in 0..<g.counts.x {
            values,fill,read_ok:=coarse_page(g,px+g.counts.x*pz,s.file,&read,heights)
            if !read_ok {intrinsics.atomic_store(&rows.failed,true);return}
            for z in max(b0,pz*PAGE)..=min(b1,pz*PAGE+PAGE-1) {for x in px*PAGE..<min(px*PAGE+PAGE,nx) {
                band[(z-b0)*nx+x]=values==nil?fill:values[(x-px*PAGE)+min(PAGE,nx-px*PAGE)*(z-pz*PAGE)]
            }}
        }}
        sample :: #force_inline proc "contextless" (band:[]f32,nx,b0,x,z:int) -> f32 {return band[(z-b0)*nx+x]}
        // The lines of the coarse grid in the rows of this row of chunks: each is written by one row.
        for j in 0..<size.y {
            z:=coarse_position(j,nz)
            if min(z/cells,counts.z-1)!=cz {continue}
            for i in 0..<size.x {grid_set(&next.heights,i,j,sample(band,nx,b0,coarse_position(i,nx),z))}
        }
        // Its chunks, in jobs too: a row holds many.
        chunks:=Coarse_Chunks{s=s,view={band=band,nx=nx,b0=b0},cz=cz,ranges=ranges,errors=errors}
        if rows.js!=nil && jobs.worker_count(rows.js)>1 {jobs.parallel_for(rows.js,worker,counts.x,1,coarse_chunks,&chunks)} else {coarse_chunks(&chunks,0,counts.x,worker)}
    }
}

@(private)
coarse_weights_fill :: proc(s:^Source,c:^Coarse,read:^Page_Reader) -> bool {
    weights,error:=make([]Weights,PAGE*PAGE,context.temp_allocator)
    if error!=nil {return false}
    nx,nz:=int(s.samples.x),int(s.samples.z)
    g:=&s.weights
    for j in 0..<c.size.y {for i in 0..<c.size.x {
        x,z:=coarse_position(i,nx),coarse_position(j,nz)
        page,at:=grid_page_at(g,{x,0,z})
        values,fill,ok:=coarse_page(g,page,s.file,read,weights)
        if !ok {return false}
        grid_set(&c.weights,i,j,values==nil?fill:values[at])
    }}
    return true
}

// The weights of the coarse grid again, after the layers of a source changed.
source_coarse_weights :: proc(s:^Source) -> bool {
    if grid_none(&s.coarse.heights) {return true}
    c:=&s.coarse
    read:Page_Reader
    if !page_reader_init(&read,context.temp_allocator) {return false}
    defer page_reader_destroy(&read,context.temp_allocator)
    return coarse_grid(&c.weights,c.size,s.allocator) && coarse_weights_fill(s,c,&read)
}

// The coarse grid over the inclusive region of samples of an edit, whose
// pages are in memory, and the ranges of the chunks it touched. Its pages
// there take values of their own first; false without memory for them.
source_coarse_update :: proc(s:^Source,low,high:[3]int,ranges:[][2]f32) -> bool {
    if grid_none(&s.coarse.heights) {return true}
    c:=&s.coarse
    nx,nz:=int(s.samples.x),int(s.samples.z)
    // The points of the coarse grid within the region: from the first multiple of COARSE, and the last row or column.
    first:=[2]int{(max(low.x,0)+COARSE-1)/COARSE,(max(low.z,0)+COARSE-1)/COARSE}
    last:=[2]int{min(high.x/COARSE,c.size.x-1),min(high.z/COARSE,c.size.y-1)}
    if high.x>=nx-1 {last.x=c.size.x-1}
    if high.z>=nz-1 {last.y=c.size.y-1}
    if first.x<=last.x && first.y<=last.y {
        if !grid_prepare(&c.heights,{first.x,0,first.y},{last.x,0,last.y},s.allocator) || !grid_none(&c.weights) && !grid_prepare(&c.weights,{first.x,0,first.y},{last.x,0,last.y},s.allocator) {return false}
        for j in first.y..=last.y {
            z:=coarse_position(j,nz)
            if z<low.z || z>high.z {continue}
            for i in first.x..=last.x {
                x:=coarse_position(i,nx)
                if x<low.x || x>high.x {continue}
                grid_set(&c.heights,i,j,grid_get(&s.field,x,z))
                if !grid_none(&c.weights) {grid_set(&c.weights,i,j,grid_get(&s.weights,x,z))}
            }
        }
    }
    if len(ranges)==0 {return true}
    cells:=int(s.chunk_cells)
    counts:=chunk_counts(s)
    for z in max(low.z,0)..=min(high.z,nz-1) {for x in max(low.x,0)..=min(high.x,nx-1) {
        h:=grid_get(&s.field,x,z)
        cx,cz:=min(x/cells,counts.x-1),min(z/cells,counts.z-1)
        for dz in 0..<2 {for dx in 0..<2 {
            at:=[2]int{cx-dx,cz-dz}
            if at.x<0 || at.y<0 || (dx==1 && x!=cx*cells) || (dz==1 && z!=cz*cells) {continue}
            range:=&ranges[at.x+counts.x*at.y]
            range^={min(range.x,h),max(range.y,h)}
        }}
    }}
    return true
}

// Where the samples a measure reads are: a band of rows of the whole width
// while a source is read, or the source itself, whose pages are in memory.
@(private)
Sample_View :: struct {
    band:[]f32,
    nx,b0:int,
    s:^Source,
}

@(private)
sample_at :: #force_inline proc "contextless" (v:Sample_View,x,z:int) -> f32 {
    if v.band!=nil {return v.band[(z-v.b0)*v.nx+x]}
    return grid_get(&v.s.field,x,z)
}

// The errors of chunk coord of a Heightfield: each level, the bilinear blend
// of its lines against every sample; and the coarse grid against every sample.
@(private)
chunk_errors_measure :: proc(s:^Source,v:Sample_View,coord:[2]int,e:^Lod_Errors) {
    nx,nz:=int(s.samples.x),int(s.samples.z)
    cells:=int(s.chunk_cells)
    low:=coord*cells
    high:=[2]int{min(low.x+cells,nx-1),min(low.y+cells,nz-1)}
    e^={}
    blend :: #force_inline proc "contextless" (v:Sample_View,x0,x1,z0,z1:int,u,w:f32) -> f32 {
        a,b:=sample_at(v,x0,z0),sample_at(v,x1,z0)
        c,d:=sample_at(v,x0,z1),sample_at(v,x1,z1)
        return (a*(1-u)+b*u)*(1-w)+(c*(1-u)+d*u)*w
    }
    for level in 1..=int(chunk_lod_max(s,{i32(coord.x),0,i32(coord.y)})) {
        step:=1<<uint(level)
        worst:=f32(0)
        for z in low.y..=high.y {
            z0:=low.y+(z-low.y)/step*step;z1:=min(z0+step,high.y)
            w:=z1>z0?f32(z-z0)/f32(z1-z0):0
            for x in low.x..=high.x {
                x0:=low.x+(x-low.x)/step*step;x1:=min(x0+step,high.x)
                u:=x1>x0?f32(x-x0)/f32(x1-x0):0
                worst=max(worst,abs(sample_at(v,x,z)-blend(v,x0,x1,z0,z1,u,w)))
            }
        }
        e.levels[level]=worst
    }
    for z in low.y..=high.y {
        j,w:=coarse_cell(z,nz)
        for x in low.x..=high.x {
            i,u:=coarse_cell(x,nx)
            e.coarse=max(e.coarse,abs(sample_at(v,x,z)-blend(v,coarse_position(i,nx),coarse_position(i+1,nx),coarse_position(j,nz),coarse_position(j+1,nz),u,w)))
        }
    }
    lod_errors_monotonic(e)
}

@(private)
lod_errors_monotonic :: proc "contextless" (e:^Lod_Errors) {
    for level in 1..<LOD_ERRORS {e.levels[level]=max(e.levels[level],e.levels[level-1])}
}

// The error of a level of piece i: a node adds how far its chunks are from
// the coarse grid it is built from.
lod_error :: #force_inline proc "contextless" (errors:[]Lod_Errors,q:^Quad,i,level:int) -> f32 {
    if i>=len(errors) {return max(f32)}
    e:=&errors[i]
    level:=min(level,LOD_ERRORS-1)
    return i<q.first[1]?e.levels[level]:e.levels[level]+e.coarse
}

// The errors of node i of a Heightfield: each level of its lines over the
// coarse grid against the coarse grid, and how far its chunks are from it.
// Within an inclusive region of samples (an edit), they only grow there.
@(private)
node_errors_measure :: proc(s:^Source,q:^Quad,errors:[]Lod_Errors,i:int,within:=[2][2]int{{min(int),min(int)},{max(int),max(int)}}) {
    nx,nz:=int(s.samples.x),int(s.samples.z)
    low,high:=quad_region(s,q,i)
    whole:=within[0].x==min(int)
    e:=&errors[i]
    if whole {e^={}}
    e.coarse=0
    for child in quad_children(q,i) {if child>=0 {e.coarse=max(e.coarse,errors[child].coarse)}}
    for level in int(node_lod_min(s,q,i))..=min(int(node_lod_max(s,q,i)),LOD_ERRORS-1) {
        step:=1<<uint(level)
        worst:=e.levels[level]
        // The points of the coarse grid in its region alone.
        for j:=min((low.y+COARSE-1)/COARSE,s.coarse.size.y-1);j<s.coarse.size.y;j+=1 {
            z:=coarse_position(j,nz)
            if z>high.y {break}
            if z<low.y || !whole && (z<within[0].y-step || z>within[1].y+step) {continue}
            z0:=low.y+(z-low.y)/step*step;z1:=min(z0+step,high.y)
            w:=z1>z0?f32(z-z0)/f32(z1-z0):0
            for k:=min((low.x+COARSE-1)/COARSE,s.coarse.size.x-1);k<s.coarse.size.x;k+=1 {
                x:=coarse_position(k,nx)
                if x>high.x {break}
                if x<low.x || !whole && (x<within[0].x-step || x>within[1].x+step) {continue}
                x0:=low.x+(x-low.x)/step*step;x1:=min(x0+step,high.x)
                u:=x1>x0?f32(x-x0)/f32(x1-x0):0
                a,b:=coarse_height(s,x0,z0),coarse_height(s,x1,z0)
                c,d:=coarse_height(s,x0,z1),coarse_height(s,x1,z1)
                worst=max(worst,abs(coarse_value(s,k,j)-((a*(1-u)+b*u)*(1-w)+(c*(1-u)+d*u)*w)))
            }
        }
        e.levels[level]=worst
    }
    lod_errors_monotonic(e)
}
