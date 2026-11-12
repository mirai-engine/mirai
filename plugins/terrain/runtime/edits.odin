package terrain

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "mirai:asset"
import "mirai:std/base"
import mm "mirai:std/math"

// Edit layers of a Heightfield: what each one adds to its heights, kept
// apart, so it can be hidden, taken out or made again without touching the
// rest. The field stays the one height everything reads (chunks, colliders,
// ground, network, the game): it is the base plus every shown layer. The base
// is not stored; a brush on the base writes the field, a brush on a layer
// writes the field and adds what it changed to that layer. Hiding a layer
// takes what it adds out of the field, showing it puts it back.
//
// The layer of splines is derived, not sculpted: it holds what the splines
// that conform the ground (a road bed, a river channel) add over everything
// else, made again from them by the editor whenever they change
// (source_conform), and gone with the last of them. It is not hidden or taken
// out by hand. The weights it paints keep what they were under it
// (edit_under), which come back when it is made again.

EDITS_MAX :: 8

// On the entity of a volume.Spline: the Heightfield terrains under it take a
// bed along it in their layer of splines, made again whenever it changes. Its points give the width; the ground under its middle, the height.
@(component,description="The Heightfield terrains under the Spline of this entity conform to it: a level bed across its width that follows the ground along its middle, depth under it, meeting the ground over sides, painted with a layer. A road bed, a river channel or an embankment, made again whenever the spline, its place or these values change; undoing that change undoes the bed.")
Terrain_Conform :: struct {
    depth:f32 `mirai:"unit=m"`,         // of its bed under the ground along its middle; negative raises it
    sides:f32 `mirai:"min=0,unit=m"`,   // past its width over which the ground meets its bed
    smooth:f32 `mirai:"min=0,unit=m"`,  // along it over which its bed follows the ground: more takes out more bumps
    paint:base.Asset_Id `mirai:"kind=.mat"`, // the layer with that material it paints on its bed; none: it paints nothing
}
TERRAIN_CONFORM_DEFAULT :: Terrain_Conform{sides=2,smooth=8}

Edit_Layer :: struct {
    hidden:bool,
    splines:bool, // made by source_conform; at most one
}

@(private="file",rodata) EDIT_PAGES := [EDITS_MAX]string{"edit0_pages","edit1_pages","edit2_pages","edit3_pages","edit4_pages","edit5_pages","edit6_pages","edit7_pages"}
@(private="file",rodata) EDIT_BLOCKS := [EDITS_MAX]string{"edit0_blocks","edit1_blocks","edit2_blocks","edit3_blocks","edit4_blocks","edit5_blocks","edit6_blocks","edit7_blocks"}
// What no sample holds: weights that do not add up, where a spline painted nothing.
@(private="file") UNDER_NONE :: Weights{}

@(private)
edits_valid :: proc "contextless" (info:Source_Info) -> bool {
    if info.edit_count>EDITS_MAX || info.kind!=.Heightfield && (info.edit_count>0 || info.conform!=0) {return false}
    splines:=0
    for layer,i in info.edit_layers {
        if i>=int(info.edit_count) {if layer!={} {return false};continue}
        if layer.splines {splines+=1}
    }
    return splines<=1
}

@(private)
edits_init :: proc(s:^Source) -> bool {
    for i in 0..<int(s.edit_count) {if !grid_init(&s.edit_heights[i],s.field.size,0,s.allocator) {return false}}
    return true
}

@(private)
edits_destroy :: proc(s:^Source) {
    for &g in s.edit_heights {grid_destroy(&g,s.allocator)}
    grid_destroy(&s.edit_under,s.allocator)
}

@(private)
edits_clone :: proc(dst,src:^Source,allocator:runtime.Allocator) -> bool {
    for i in 0..<EDITS_MAX {if !grid_clone(&dst.edit_heights[i],&src.edit_heights[i],allocator) {return false}}
    return grid_clone(&dst.edit_under,&src.edit_under,allocator)
}

@(private)
edits_cost :: proc "contextless" (s:^Source) -> (count:int) {
    for &g in s.edit_heights {count+=grid_dense(&g)}
    return count+grid_dense(&s.edit_under)
}

@(private="file")
under_valid :: proc "contextless" (w:Weights) -> bool {return w==UNDER_NONE || weights_full(w)}

@(private)
edits_read :: proc(s:^Source,file:^asset.Asset,types:^asset.Types,allocator:runtime.Allocator,paged:bool) -> bool {
    for i in 0..<int(s.edit_count) {
        if !grid_read_document(&s.edit_heights[i],file,types,s.field.size,EDIT_PAGES[i],EDIT_BLOCKS[i],value_finite,allocator,paged) || !grid_within(&s.edit_heights[i],2*HEIGHT_LIMIT) {return false}
    }
    if _,found:=asset.asset_table(file,"edit_under_pages");!found {return true}
    return s.edit_count>0 && grid_read_document(&s.edit_under,file,types,s.field.size,"edit_under_pages","edit_under_blocks",under_valid,allocator,paged)
}

@(private)
edits_put :: proc(document:^asset.Document,types:^asset.Types,s:^Source,keep:bool) -> asset.Error {
    for i in 0..<int(s.edit_count) {
        g:=&s.edit_heights[i]
        if g.size!=s.field.size {return .Invalid}
        grid_put_document(document,types,g,EDIT_PAGES[i],EDIT_BLOCKS[i],value_finite,s.file,s.allocator,keep) or_return
    }
    if grid_none(&s.edit_under) {return .None}
    if s.edit_under.size!=s.field.size {return .Invalid}
    return grid_put_document(document,types,&s.edit_under,"edit_under_pages","edit_under_blocks",under_valid,s.file,s.allocator,keep)
}

// The edit layers of a resized Heightfield: what grows takes the nearest edge, as its heights do.
@(private)
edits_resize :: proc(dst,src:^Source,shift:[2]int) -> bool {
    old:=[2]int{int(src.samples.x),int(src.samples.z)}
    size:=dst.field.size
    last:=[3]int{size.x-1,0,size.z-1}
    for i in 0..<int(src.edit_count) {
        g:=&dst.edit_heights[i]
        if !grid_prepare(g,{},last,dst.allocator) {return false}
        for z in 0..<size.z {for x in 0..<size.x {grid_set(g,x,z,grid_get(&src.edit_heights[i],clamp(x-shift.x,0,old.x-1),clamp(z-shift.y,0,old.y-1)))}}
        grid_settle(g,{},last,dst.allocator)
    }
    if grid_none(&src.edit_under) {return true}
    if !grid_init(&dst.edit_under,size,UNDER_NONE,dst.allocator) || !grid_prepare(&dst.edit_under,{},last,dst.allocator) {return false}
    for z in 0..<size.z {for x in 0..<size.x {
        sx,sz:=x-shift.x,z-shift.y
        if sx<0 || sz<0 || sx>=old.x || sz>=old.y {continue}
        grid_set(&dst.edit_under,x,z,grid_get(&src.edit_under,sx,sz))
    }}
    return true
}

@(private="file")
change_grow :: proc "contextless" (change:^Change,low,high:[3]int) {
    if !change.changed {change.low,change.high=low,high} else {
        for axis in 0..<3 {change.low[axis],change.high[axis]=min(change.low[axis],low[axis]),max(change.high[axis],high[axis])}
    }
    change.changed=true
}

// Adds sign times a layer into the field, over the pages where it adds anything.
@(private="file")
field_add :: proc(s:^Source,g:^Grid(f32),sign:f32,change:^Change) -> bool {
    for id in 0..<len(g.pages) {
        page:=g.pages[id]
        if page.values==nil && page.fill==0 {continue}
        low,high:=grid_page_region(g,id)
        if !grid_prepare(&s.field,low,high,s.allocator) {return false}
        for z in low.z..=high.z {for x in low.x..=high.x {
            grid_set(&s.field,x,z,clamp(grid_get(&s.field,x,z)+sign*grid_get(g,x,z),-HEIGHT_LIMIT,HEIGHT_LIMIT))
        }}
        change_grow(change,low,high)
    }
    return true
}

// The weights the splines painted over go back to what they were under them.
@(private="file")
under_restore :: proc(s:^Source,change:^Change) -> bool {
    g:=&s.edit_under
    if grid_none(g) {return true}
    for id in 0..<len(g.pages) {
        page:=g.pages[id]
        if page.values==nil && page.fill==UNDER_NONE {continue}
        low,high:=grid_page_region(g,id)
        if !grid_prepare(&s.weights,low,high,s.allocator) {return false}
        for z in low.z..=high.z {for x in low.x..=high.x {
            if w:=grid_get(g,x,z);w!=UNDER_NONE {grid_set(&s.weights,x,z,w)}
        }}
        change_grow(change,low,high)
    }
    grid_destroy(g,s.allocator)
    return true
}

// A new edit layer on top, adding nothing yet; that of splines goes over
// every other. False for a Volume, past EDITS_MAX, a second one of splines
// or without memory.
source_edit_layer_add :: proc(s:^Source,splines:=false) -> (index:int,ok:bool) {
    if s.kind!=.Heightfield || s.edit_count>=EDITS_MAX || !source_samples_held(s) {return}
    count:=int(s.edit_count)
    at:=count
    for layer,i in s.edit_layers[:count] {
        if layer.splines {
            if splines {return}
            at=i
        }
    }
    g:Grid(f32)
    if !grid_init(&g,s.field.size,0,s.allocator) {return}
    for i:=count;i>at;i-=1 {s.edit_heights[i],s.edit_layers[i]=s.edit_heights[i-1],s.edit_layers[i-1]}
    s.edit_heights[at],s.edit_layers[at]=g,{splines=splines}
    s.edit_count+=1
    return at,true
}

// Takes a layer of sculpting out, and what it adds out of the field.
source_edit_layer_remove :: proc(s:^Source,index:int) -> (change:Change) {
    if index<0 || index>=int(s.edit_count) || s.edit_layers[index].splines || !source_samples_held(s) {return Change{error=.Layer}}
    return edit_layer_drop(s,index)
}

// A layer and what it adds out; the weights a layer of splines painted go back.
@(private="file")
edit_layer_drop :: proc(s:^Source,index:int) -> (change:Change) {
    layer:=s.edit_layers[index]
    if !layer.hidden && !field_add(s,&s.edit_heights[index],-1,&change) {return Change{error=.Out_Of_Memory}}
    if layer.splines && !under_restore(s,&change) {return Change{error=.Out_Of_Memory}}
    grid_destroy(&s.edit_heights[index],s.allocator)
    count:=int(s.edit_count)
    for i in index..<count-1 {s.edit_heights[i],s.edit_layers[i]=s.edit_heights[i+1],s.edit_layers[i+1]}
    s.edit_heights[count-1],s.edit_layers[count-1]={},{}
    s.edit_count-=1
    change.changed=true
    return
}

// Hides a layer of sculpting, or shows it: the field loses or takes back what
// it adds.
source_edit_layer_hide :: proc(s:^Source,index:int,hidden:bool) -> (change:Change) {
    if index<0 || index>=int(s.edit_count) || s.edit_layers[index].splines || !source_samples_held(s) {return Change{error=.Layer}}
    layer:=&s.edit_layers[index]
    if layer.hidden==hidden {return}
    if !field_add(s,&s.edit_heights[index],hidden?-1:1,&change) {return Change{error=.Out_Of_Memory}}
    layer.hidden=hidden
    change.changed=true
    return
}

// What a stroke changed in the field from before, over the samples from low
// to high (all: everywhere), goes into a shown layer of sculpting too.
source_edit_layer_take :: proc(s:^Source,before:^Grid(f32),index:int,low,high:[3]int,all:=false) -> bool {
    if index<0 || index>=int(s.edit_count) || s.edit_layers[index].hidden || s.edit_layers[index].splines || before.size!=s.field.size {return false}
    g:=&s.edit_heights[index]
    from,to:=low,high
    if all {from,to={},s.field.size-1}
    from.y,to.y=0,0
    for axis in 0..<3 {from[axis],to[axis]=max(from[axis],0),min(to[axis],s.field.size[axis]-1)}
    if from.x>to.x || from.z>to.z {return true}
    // Only the pages the stroke changed take values of their own.
    pf,pt:=grid_pages(g,from,to)
    for pz in pf.z..=pt.z {for px in pf.x..=pt.x {
        id:=grid_page_id(g,{px,0,pz})
        if grid_page_same(&s.field,before,id) {continue}
        lo,hi:=grid_page_region(g,id)
        if !grid_prepare(g,lo,hi,s.allocator) {return false}
        for z in lo.z..=hi.z {for x in lo.x..=hi.x {
            if d:=grid_get(&s.field,x,z)-grid_get(before,x,z);d!=0 {grid_set(g,x,z,grid_get(g,x,z)+d)}
        }}
        grid_settle(g,lo,hi,s.allocator)
    }}
    return true
}

// A spline a Heightfield conforms to, in the space of the source: its
// curve sampled by length (each point with its width), how far its bed lies
// under the ground along its middle (negative raises it), how far past its
// width the ground meets it, over how much of its length its bed follows the
// ground, and the layer it paints, or -1.
Conform_Path :: struct {
    points:[]mm.Path_Point,
    depth,sides,smooth:f32,
    layer:int,
}

// Makes the layer of splines again from paths: what it added comes out, the
// weights it painted come back, and each path flattens across its width a
// bed that follows the ground under its middle, minus its depth, fading over
// its sides into the ground, and paints its layer there. The ground under a
// path is the base and every other layer, so a sculpted change under a road
// is followed by its bed the next time it is made. Without paths that reach
// it the layer goes, and what it added and painted with it.
source_conform :: proc(s:^Source,paths:[]Conform_Path) -> (change:Change) {
    if s.kind!=.Heightfield || !source_valid(s.info) || !source_samples_held(s) {return Change{error=.Unloaded}}
    // What is wrong with a path changes nothing.
    for path in paths {
        if len(path.points)<2 {continue}
        for p in path.points {if !(p.width>0) || p.position.x-p.position.x!=0 || p.position.z-p.position.z!=0 {return Change{error=.Center}}}
        if !(path.depth-path.depth==0) || abs(path.depth)>HEIGHT_LIMIT {return Change{error=.Target}}
        if !(path.sides>=0) || path.sides>HEIGHT_LIMIT || !(path.smooth>=0) {return Change{error=.Blend}}
        if path.layer>=int(s.layer_count) {return Change{error=.Layer}}
    }
    index:=-1
    for layer,i in s.edit_layers[:s.edit_count] {if layer.splines {index=i}}
    if index<0 {
        reaching:=false
        for path in paths {if len(path.points)>=2 {reaching=true}}
        if !reaching {return}
        ok:bool
        if index,ok=source_edit_layer_add(s,splines=true);!ok {return Change{error=.Out_Of_Memory}}
        change.changed=true
    }
    reaching:=false
    for path in paths {if len(path.points)>=2 {reaching=true}}
    if !reaching {
        dropped:=edit_layer_drop(s,index)
        if dropped.error!=.None {return dropped}
        change_grow(&change,dropped.low,dropped.high)
        return
    }
    if !field_add(s,&s.edit_heights[index],-1,&change) || !under_restore(s,&change) {return Change{error=.Out_Of_Memory}}
    if !grid_init(&s.edit_heights[index],s.field.size,0,s.allocator) {return Change{error=.Out_Of_Memory}}
    // The bed of each path from the ground as it is now, without the layer.
    beds:=make([][]f32,len(paths),context.temp_allocator)
    for path,k in paths {
        n:=len(path.points)
        if n<2 {continue}
        ground,along:=make([]f32,n,context.temp_allocator),make([]f32,n,context.temp_allocator)
        beds[k]=make([]f32,n,context.temp_allocator)
        for p,i in path.points {
            ground[i]=source_height(s,p.position.x,p.position.z)
            if i>0 {along[i]=along[i-1]+linalg.length(p.position.xz-path.points[i-1].position.xz)}
        }
        // The mean of the ground over smooth metres around each point, two ends that slide.
        first,last:=0,0
        sum:=f64(0)
        for i in 0..<n {
            for last<n && along[last]<=along[i]+path.smooth*0.5 {sum+=f64(ground[last]);last+=1}
            for along[first]<along[i]-path.smooth*0.5 {sum-=f64(ground[first]);first+=1}
            beds[k][i]=f32(sum/f64(last-first))-path.depth
        }
    }
    origin:=source_origin(s)
    g:=&s.edit_heights[index]
    painting:=false
    for path in paths {if path.layer>=0 && len(path.points)>=2 {painting=true}}
    if painting && !grid_init(&s.edit_under,s.field.size,UNDER_NONE,s.allocator) {return Change{error=.Out_Of_Memory}}
    // Page by page: the pieces of every path that reach it.
    Piece :: struct {path,i:int}
    pieces:=make([dynamic]Piece,context.temp_allocator)
    for id in 0..<len(g.pages) {
        low,high:=grid_page_region(g,id)
        page_low:=origin.xz+[2]f32{f32(low.x),f32(low.z)}*s.cell
        page_high:=origin.xz+[2]f32{f32(high.x),f32(high.z)}*s.cell
        clear(&pieces)
        for path,k in paths {
            if beds[k]==nil {continue}
            for i in 0..<len(path.points)-1 {
                a,b:=path.points[i],path.points[i+1]
                reach:=max(a.width,b.width)*0.5+path.sides
                lo,hi:=linalg.min(a.position.xz,b.position.xz)-reach,linalg.max(a.position.xz,b.position.xz)+reach
                if hi.x<page_low.x || lo.x>page_high.x || hi.y<page_low.y || lo.y>page_high.y {continue}
                if _,error:=append(&pieces,Piece{k,i});error!=nil {return Change{error=.Out_Of_Memory}}
            }
        }
        if len(pieces)==0 {continue}
        if !grid_prepare(g,low,high,s.allocator) || !grid_prepare(&s.field,low,high,s.allocator) {return Change{error=.Out_Of_Memory}}
        if painting && (!grid_prepare(&s.edit_under,low,high,s.allocator) || !grid_prepare(&s.weights,low,high,s.allocator)) {return Change{error=.Out_Of_Memory}}
        touched:=false
        for z in low.z..=high.z {for x in low.x..=high.x {
            point:=origin.xz+[2]f32{f32(x),f32(z)}*s.cell
            below:=grid_get(&s.field,x,z)
            h:=below
            weights:=grid_get(&s.weights,x,z)
            painted:=weights
            // Each path over the paths before it, at its nearest piece.
            for k in 0..<len(paths) {
                best,bed,width:=f32(max(f32)),f32(0),f32(0)
                for piece in pieces {
                    if piece.path!=k {continue}
                    a,b:=paths[k].points[piece.i],paths[k].points[piece.i+1]
                    d:=b.position.xz-a.position.xz
                    t:=clamp(linalg.dot(point-a.position.xz,d)/max(linalg.dot(d,d),1e-12),0,1)
                    if far:=linalg.length(point-a.position.xz-d*t);far<best {
                        best,bed,width=far,math.lerp(beds[k][piece.i],beds[k][piece.i+1],t),math.lerp(a.width,b.width,t)
                    }
                }
                if best==max(f32) {continue}
                past:=best-width*0.5
                alpha:=past<=0?f32(1):paths[k].sides>0?1-math.smoothstep(f32(0),f32(1),past/paths[k].sides):0
                if alpha<=0 {continue}
                h=math.lerp(h,bed,alpha)
                if paths[k].layer>=0 {painted=weights_paint(painted,paths[k].layer,alpha,int(s.layer_count))}
            }
            if h!=below {
                h=clamp(h,-HEIGHT_LIMIT,HEIGHT_LIMIT)
                grid_set(g,x,z,h-below)
                grid_set(&s.field,x,z,h)
                touched=true
            }
            if painted!=weights {
                grid_set(&s.edit_under,x,z,weights)
                grid_set(&s.weights,x,z,painted)
                touched=true
            }
        }}
        grid_settle(g,low,high,s.allocator)
        if painting {grid_settle(&s.edit_under,low,high,s.allocator)}
        if touched {change_grow(&change,low,high)}
    }
    if painting && grid_none(&s.edit_under)==false {
        empty:=true
        for page in s.edit_under.pages {if page.values!=nil || page.fill!=UNDER_NONE {empty=false;break}}
        if empty {grid_destroy(&s.edit_under,s.allocator)}
    }
    return
}
