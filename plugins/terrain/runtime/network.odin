package terrain

import "base:runtime"
import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"

// Edits another library orders, as a bridge of the network does: terrain
// does not know the network. While a tick is routed (Terrain_Replays.routed,
// asked again each tick), terrain_replay applies the replays in their order
// and then takes the requests of dig, which terrain_update then
// finds empty, and says how each went with the check of what it left
// (Terrain_Replay_Events). A replay is an edit of a brush, a change of the
// layers, the values of a whole page of a grid, or the head of a base, which
// gives a source its shape and layers;
// it names its source, not a terrain. What terrain_replay applies does not
// move Source.revision, the key of the history of the editor.

Replay_Kind :: enum u8 {Edit,Layer,Page,Head}

// A change of the layers of a source, as request_layer and request_layer_remove ask.
Layer_Change :: struct {
    index:u32,
    layer:Terrain_Layer,
    remove:bool,
}

Replay :: struct {
    kind:Replay_Kind,
    source:base.Asset_Id,
    tag:u64, // of who pushed it, back in its result
    brush:Brush,        // Edit
    layer:Layer_Change, // Layer
    verify:bool,        // Edit and Layer: the check covers low..high, not what it changed
    low,high:[3]i32,    // samples, inclusive
    grid:Grid_Kind,     // Page
    page:u32,           // Page: its id
    span:u8,            // Page without values: above 1, every page of the box that many pages a side from page holds fill, as a part of the directory of a grid in blocks does (terrain_grid_fill)
    fill:u32,           // Page without values: the bits of the one value it holds
    whole:bool,         // Head: every value of the source starts over, as a new source of that shape holds them; else it takes only the layers
    values:[]u8,        // Page: its values coded (terrain_page_bytes); Head: terrain_head_bytes. Who pushed it keeps them until terrain_replay runs
}

@(storage,queue)
Terrain_Replays :: struct {
    routed:bool, // this tick: the requests of dig and request_layer go through terrain_replay
    asked:bool,  // this tick, routed: the requests of request_layer are results without being applied, for who routes them to apply them when they come back
    items:core.Queue(Replay),
}

Replay_Result :: struct {
    kind:Replay_Kind,
    request:bool, // a request of dig or request_layer, not a replay
    owner:core.Entity,
    source:base.Asset_Id,
    tag:u64,
    brush:Brush,
    layer:Layer_Change,
    error:Edit_Error, // Invalid also for a source that is not loaded and a page that does not fit it
    loaded:bool,      // the source is loaded
    changed:bool,
    low,high:[3]i32,  // what an Edit or Layer changed, or the region its check covers when verified
    check:u64,        // Edit: of the values of every grid over low..high, after it; Layer: of the layers
}

// What terrain_replay did in the tick, in the order it did it.
@(storage)
Terrain_Replay_Events :: struct {results:core.Events(Replay_Result)}

// Bytes of a Brush as it travels: its alpha is not part of it.
BRUSH_BYTES :: size_of(Brush)

brush_bytes :: proc "contextless" (brush:Brush) -> (bytes:[BRUSH_BYTES]u8) {
    brush:=brush
    brush.alpha=nil
    mem.copy_non_overlapping(&bytes,&brush,BRUSH_BYTES)
    return
}

// The brush of bytes that came from another end: false when a field holds
// what no Brush holds (an enum or bool out of its values, a value that is not
// finite). Its alpha is nil.
brush_of_bytes :: proc(bytes:[BRUSH_BYTES]u8) -> (brush:Brush,ok:bool) {
    bytes:=bytes
    if !plain_valid(raw_data(bytes[:]),type_info_of(Brush)) {return}
    mem.copy_non_overlapping(&brush,&bytes,BRUSH_BYTES)
    brush.alpha=nil
    return brush,true
}

// Bytes of a Layer_Change as it travels.
LAYER_CHANGE_BYTES :: size_of(Layer_Change)

layer_change_bytes :: proc "contextless" (change:Layer_Change) -> (bytes:[LAYER_CHANGE_BYTES]u8) {
    change:=change
    mem.copy_non_overlapping(&bytes,&change,LAYER_CHANGE_BYTES)
    return
}

// The change of bytes from another end: false when a field holds what no
// Layer_Change holds. Whether the source takes it is for terrain_replay.
layer_change_of_bytes :: proc(bytes:[]u8) -> (change:Layer_Change,ok:bool) {
    if len(bytes)<LAYER_CHANGE_BYTES || !plain_valid(raw_data(bytes),type_info_of(Layer_Change)) {return}
    mem.copy_non_overlapping(&change,raw_data(bytes),LAYER_CHANGE_BYTES)
    return change,true
}

// Whether the bytes at data are a value of info: each bool 0 or 1, each enum
// one of its values, each float finite; a pointer is not read.
@(private)
plain_valid :: proc(data:rawptr,info:^runtime.Type_Info) -> bool {
    core_info:=runtime.type_info_base(info)
    #partial switch variant in core_info.variant {
    case runtime.Type_Info_Boolean:
        return (^u8)(data)^<=1
    case runtime.Type_Info_Float:
        switch core_info.size {
        case 4: value:=(^f32)(data)^;return value-value==0
        case 8: value:=(^f64)(data)^;return value-value==0
        }
        return false
    case runtime.Type_Info_Quaternion:
        for i in 0..<4 {if value:=([^]f32)(data)[i];value-value!=0 {return false}}
        return core_info.size==16
    case runtime.Type_Info_Enum:
        value:i64
        switch core_info.size {
        case 1: value=i64((^u8)(data)^)
        case 2: value=i64((^u16)(data)^)
        case 4: value=i64((^u32)(data)^)
        case: return false
        }
        for v in variant.values {if i64(v)==value {return true}}
        return false
    case runtime.Type_Info_Array:
        for i in 0..<variant.count {if !plain_valid(rawptr(uintptr(data)+uintptr(i*variant.elem_size)),variant.elem) {return false}}
        return true
    case runtime.Type_Info_Struct:
        for i in 0..<int(variant.field_count) {if !plain_valid(rawptr(uintptr(data)+variant.offsets[i]),variant.types[i]) {return false}}
        return true
    case runtime.Type_Info_Pointer,runtime.Type_Info_Integer,runtime.Type_Info_Bit_Set:
        return true
    }
    return false
}

// Applies a brush to the source of entry: its pages into memory, the budget
// of samples, the coarse grid, the errors of its levels and the chunks it
// marks. terrain_update and terrain_replay edit with it.
@(private)
data_edit :: proc(data:^Terrain_Data,entry:^Data_Source,brush:Brush) -> (change:Change) {
    work_wait(data,&entry.source)
    previous_cost:=source_cost(&entry.source)
    if !brush_pages_read(entry,brush) {return {error=.Out_Of_Memory}}
    data.samples=u32(int(data.samples)-previous_cost+source_cost(&entry.source))
    previous_cost=source_cost(&entry.source)
    change=source_edit(&entry.source,brush)
    if change.error!=.None || !change.changed {return}
    if !source_coarse_update(&entry.source,change.low,change.high) {return {error=.Out_Of_Memory}}
    data_errors_edit(entry,change.low,change.high)
    data.samples=u32(int(data.samples)-previous_cost+source_cost(&entry.source))
    data_mark(entry,change)
    data.stats.edits+=1
    return
}

// What a change covers for a check: its samples.
@(private)
change_region :: proc(s:^Source,change:Change) -> (low,high:[3]i32) {
    if !change.changed {return {},{-1,-1,-1}}
    a,b:=change.low,change.high
    return {i32(a.x),i32(a.y),i32(a.z)},{i32(b.x),i32(b.y),i32(b.z)}
}

// Hash of the values of every grid of a source over the inclusive region:
// equal on two ends when they hold the same there. The pages it reads are in memory (source_region_read).
@(private)
source_check :: proc(s:^Source,low,high:[3]i32) -> u64 {
    bytes:=make([dynamic]u8,context.temp_allocator)
    values :: proc(bytes:^[dynamic]u8,g:^Grid($T),size:[3]int,low,high:[3]i32) {
        for z in max(int(low.z),0)..=min(int(high.z),size.z-1) {for y in max(int(low.y),0)..=min(int(high.y),size.y-1) {for x in max(int(low.x),0)..=min(int(high.x),size.x-1) {
            value:=grid_value(g,{x,y,z})
            append(bytes,..mem.ptr_to_bytes(&value))
        }}}
    }
    // An empty grid of holes reads none, as one whose cells are all filled.
    values(&bytes,&s.field,grid_size(s,.Field),low,high)
    values(&bytes,&s.holes,grid_size(s,.Holes),low,high)
    values(&bytes,&s.weights,grid_size(s,.Weights),low,high)
    return base.hash64(bytes[:])
}

// The size in samples of a grid of a source; zero for one it has no values of.
@(private)
grid_size :: proc "contextless" (s:^Source,kind:Grid_Kind) -> [3]int {
    switch kind {
    case .Field:   return {int(s.samples.x),int(s.samples.y),int(s.samples.z)}
    case .Holes:   return holes_size(s)
    case .Weights: return weights_size(s)
    }
    return {}
}

// Writes page i of a grid whole: its values coded (page_code), or fill alone
// when values is empty; with a span above 1, fill for every page of the box
// that many pages a side from it. low..high is the region of samples it
// covers. False when the page is not one of the grid, the values are not
// those of the page or one is not valid, or without memory; then the grid
// reads as before.
@(private)
grid_page_put :: proc(s:^Source,entry:^Data_Source,g:^Grid($T),size:[3]int,i:int,fill:T,values:[]u8,valid:proc "contextless" (value:T) -> bool,limit:f32=0,span:=1) -> (low,high:[3]int,ok:bool) {
    if size.x<=0 {return}
    if grid_none(g) {
        zero:T
        if len(values)==0 && fill==zero {return {},{-1,-1,-1},true}
        if !grid_init(g,size,zero,s.allocator) {return}
    }
    if g.size!=size || i<0 || i>=g.counts.x*g.counts.y*g.counts.z {return}
    if span>1 {
        if len(values)>0 || !valid(fill) || !g.sparse || span!=SLAB && span!=SLAB*TABLE {return}
        when T==f32 {if limit>0 && !(abs(fill)<=limit) {return}}
        from:=grid_page_coord(g,i)
        to:=from+span-1
        for axis in 0..<3 {to[axis]=min(to[axis],g.counts[axis]-1)}
        low,_=grid_page_region(g,i)
        _,high=grid_page_region(g,grid_page_id(g,to))
        // What the box held in memory goes with it: nothing of it is read first.
        if !grid_fill_box(g,from,to,fill,s.allocator) {return}
        return low,high,true
    }
    low,high=grid_page_region(g,i)
    _,count:=grid_page_extent(g,i)
    decoded:[PAGE_VALUES]T=---
    held:=decoded[:count]
    if len(values)>0 {
        if !page_uncode(values,mem.slice_to_bytes(held)) {return}
        if !page_valid(held,valid) {return}
        when T==f32 {if limit>0 && !values_within(held,limit) {return}}
    } else if !valid(fill) {return}
    when T==f32 {if limit>0 && len(values)==0 && !(abs(fill)<=limit) {return}}
    if !source_region_read(s,low,high,entry) || !grid_prepare(g,low,high,s.allocator) {return}
    page:=grid_page_ref(g,i,s.allocator)
    if page==nil || len(page.values)!=count {return}
    if len(values)>0 {
        copy(page.values,held)
    } else {
        for &value in page.values {value=fill}
        grid_settle(g,low,high,s.allocator)
    }
    return low,high,true
}

@(private)
replay_page :: proc(data:^Terrain_Data,entry:^Data_Source,replay:Replay) -> (change:Change) {
    s:=&entry.source
    work_wait(data,s)
    before:=source_cost(s)
    i:=int(replay.page)
    fill:=replay.fill
    low,high:[3]int
    ok:bool
    span:=max(int(replay.span),1)
    switch replay.grid {
    case .Field:
        low,high,ok=grid_page_put(s,entry,&s.field,grid_size(s,.Field),i,transmute(f32)fill,replay.values,value_finite,field_limit(s.info),span)
    case .Holes:
        low,high,ok=grid_page_put(s,entry,&s.holes,grid_size(s,.Holes),i,u8(fill),replay.values,hole_valid,0,span)
        // The samples of the cells: their vertices, and the edges of the collider around them.
        if ok && high.x>=low.x {high+={1,0,1}}
    case .Weights:
        low,high,ok=grid_page_put(s,entry,&s.weights,grid_size(s,.Weights),i,transmute(Weights)fill,replay.values,weights_full,0,span)
    }
    data.samples=u32(max(int(data.samples)-before+source_cost(s),0))
    if !ok {return {error=.Invalid}}
    if high.x<low.x {return}
    change={changed=true,low=low,high=high}
    if !source_coarse_update(s,low,high) {return {error=.Out_Of_Memory}}
    data_errors_edit(entry,low,high)
    data_mark(entry,change)
    return
}

// The replays, and while the tick is routed the requests of dig and
// request_layer, before terrain_update: what they change shows as an edit does.
@(step="fixed",loops="game",stage="simulate",before="terrain_update")
terrain_replay :: proc(replays:^Terrain_Replays,events:^Terrain_Replay_Events,digs:^Terrain_Digs,requests:^Terrain_Requests,data:^Terrain_Data,terrains:^core.Table(Terrain,.Read),worlds:^core.Table(core.World_Transform,.Read),assets:^host.Assets,problems:^core.Problems) {
    routed,asked:=replays.routed,replays.asked
    replays.routed,replays.asked=false,false
    if len(replays.items.items)==0 && (!routed || len(requests.edits.items)==0 && len(requests.layers.items)==0) {return}
    for replay in core.take(&replays.items) {
        result:=Replay_Result{kind=replay.kind,source=replay.source,tag=replay.tag,brush=replay.brush,layer=replay.layer,low=replay.low,high=replay.high,error=.Invalid}
        entry:=data_find(data,replay.source)
        if replay.kind==.Head {
            entry,result.error=replay_head(data,entry,replay,assets.allocator)
            result.loaded,result.changed=entry!=nil,result.error==.None
        } else if entry!=nil {
            result.loaded=true
            change:Change
            switch replay.kind {
            case .Edit:    change=data_edit(data,entry,replay.brush)
            case .Page:    change=replay_page(data,entry,replay)
            case .Layer:   change.changed,change.error=data_layer(data,entry,replay.layer)
            case .Head:
            }
            result.error,result.changed=change.error,change.changed
            #partial switch replay.kind {
            case .Edit:
                if !replay.verify {result.low,result.high=change_region(&entry.source,change)}
                if change.error==.None {result.check=replay_check(entry,result.low,result.high)}
                if change.changed {dig_push(digs,source_owner(terrains,entry.id),entry,worlds)}
            case .Layer:
                if !replay.verify {result.low,result.high=source_region(&entry.source)}
                if change.changed {result.check=layers_check(&entry.source)}
            }
        }
        core.push(&events.results,result)
    }
    if !routed {return}
    for asked_edit in core.take(&requests.edits) {
        request:=edit_resolve(asked_edit,data,terrains,worlds) or_continue
        result:=Replay_Result{request=true,owner=request.owner,brush=request.brush}
        entry:=request_source(data,terrains,request.owner,"an edit",problems,assets) or_continue
        result.source,result.loaded=entry.id,true
        change:=data_edit(data,entry,request.brush)
        result.error,result.changed=change.error,change.changed
        if change.error!=.None {
            edit_report(problems,request.owner,assets,entry,request.brush,change.error)
        } else {
            result.low,result.high=change_region(&entry.source,change)
            result.check=replay_check(entry,result.low,result.high)
            if change.changed {dig_push(digs,request.owner,entry,worlds)}
        }
        core.push(&events.results,result)
    }
    for request in core.take(&requests.layers) {
        result:=Replay_Result{kind=.Layer,request=true,owner=request.owner,layer=request.change}
        entry:=request_source(data,terrains,request.owner,"a layer change",problems,assets) or_continue
        result.source,result.loaded=entry.id,true
        if !asked {
            result.changed,result.error=data_layer(data,entry,request.change)
            layer_report(problems,request.owner,assets,entry,request.change,result.error)
            result.low,result.high=source_region(&entry.source)
            if result.changed {result.check=layers_check(&entry.source)}
        }
        core.push(&events.results,result)
    }
}

@(private)
replay_check :: proc(entry:^Data_Source,low,high:[3]i32) -> u64 {
    if high.x<low.x || high.y<low.y || high.z<low.z {return 0}
    s:=&entry.source
    if !source_region_read(s,{int(low.x),int(low.y),int(low.z)},{int(high.x),int(high.y),int(high.z)},entry) {return 0}
    return source_check(s,low,high)
}

// Hash of the layers of a source, field by field: not the padding.
@(private)
layers_check :: proc(s:^Source) -> u64 {
    bytes:=make([dynamic]u8,context.temp_allocator)
    put :: proc(bytes:^[dynamic]u8,value:$T) {value:=value;append(bytes,..mem.ptr_to_bytes(&value))}
    put(&bytes,s.layer_count);put(&bytes,s.layers_material)
    for layer in s.layers[:s.layer_count] {
        a:=layer.auto
        put(&bytes,layer.material);put(&bytes,[3]f32{layer.tiling,layer.height_blend,layer.displacement})
        put(&bytes,u8(a.enabled));put(&bytes,[6]f32{a.slope.x,a.slope.y,a.height.x,a.height.y,a.softness.x,a.softness.y})
    }
    return base.hash64(bytes[:])
}

// All of a source: its samples.
@(private)
source_region :: proc "contextless" (s:^Source) -> (low,high:[3]i32) {
    return {},{i32(s.samples.x)-1,i32(s.samples.y)-1,i32(s.samples.z)-1}
}

// The start of a base: the shape and layers of a source and the origin
// (Source.origin) what it holds is of.
@(private)
Head :: struct {
    origin:u64,
    info:Source_Info,
}
HEAD_BYTES :: size_of(Head)

// The head of a loaded source into out, of HEAD_BYTES at least.
terrain_head_bytes :: proc(data:core.Ref(Terrain_Data),id:base.Asset_Id,out:[]u8) -> bool {
    s:=terrain_source(data,id)
    if s==nil || len(out)<HEAD_BYTES {return false}
    head:=Head{origin=s.origin,info=s.info}
    mem.copy_non_overlapping(raw_data(out),&head,HEAD_BYTES)
    return true
}

// A source of the shape and layers of a head, every value its start: the
// heights 0, a Volume all air, the weights all of the first layer.
@(private)
source_start :: proc(s:^Source,head:^Head,allocator:runtime.Allocator) -> bool {
    temporary:Source
    defer source_destroy(&temporary)
    if !source_allocate(&temporary,head.info,allocator) {return false}
    temporary.origin=head.origin
    source_destroy(s)
    s^=temporary
    temporary={}
    return true
}

// Gives a source what a head says: a source of its shape that starts over
// when whole, which it creates when it is not loaded, or else its layers.
// Invalid for bytes that are not a head, and for one that is not
// whole of another shape.
@(private)
replay_head :: proc(data:^Terrain_Data,entry:^Data_Source,replay:Replay,allocator:runtime.Allocator) -> (result:^Data_Source,error:Edit_Error) {
    result=entry
    if len(replay.values)!=HEAD_BYTES || !plain_valid(raw_data(replay.values),type_info_of(Head)) {return result,.Invalid}
    head:Head
    mem.copy_non_overlapping(&head,raw_data(replay.values),HEAD_BYTES)
    if !source_valid(head.info) {return result,.Invalid}
    if entry!=nil && !replay.whole {
        s:=&entry.source
        if s.kind!=head.info.kind || s.samples!=head.info.samples || s.cell!=head.info.cell || s.chunk_cells!=head.info.chunk_cells {return result,.Invalid}
        if s.layer_count==head.info.layer_count && s.layers==head.info.layers && s.layers_material==head.info.layers_material && s.interior==head.info.interior {return}
        work_wait(data,s)
        before:=source_cost(s)
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        s.layer_count=head.info.layer_count
        s.layers=head.info.layers
        s.layers_material=head.info.layers_material
        s.interior=head.info.interior
        data.samples=u32(max(int(data.samples)-before+source_cost(s),0))
        data_mark_all(entry)
        return result,source_coarse_weights(s)?.None:.Out_Of_Memory
    }
    next:Data_Source
    if !source_start(&next.source,&head,allocator) {return result,.Out_Of_Memory}
    if entry==nil && len(data.entries)>=int(data.settings.sources) {source_destroy(&next.source);return result,.Budget}
    next.id=replay.source
    if entry!=nil {next.stamp,next.change=entry.stamp,entry.change+1} else {next.change=1}
    if !data_chunks_allocate(&next,allocator,data.jobs) {data_entry_free(&next);return result,.Out_Of_Memory}
    if entry!=nil {
        work_wait(data,&entry.source)
        data.samples=u32(max(int(data.samples)-source_cost(&entry.source),0))
        data_entry_free(entry)
        entry^=next
    } else {
        if _,err:=append(&data.entries,next);err!=nil {data_entry_free(&next);return result,.Out_Of_Memory}
        result=&data.entries[len(data.entries)-1]
        if at,found:=slice.linear_search(data.unread[:],replay.source);found {unordered_remove(&data.unread,at)}
        data.stats.loads+=1
    }
    data.samples+=u32(source_cost(&result.source))
    return result,.None
}

// Hash of every value of a loaded source (source_check over all of it):
// equal on two ends that hold the same. It reads the pages it does not hold.
terrain_source_check :: proc(data:core.Ref(Terrain_Data),id:base.Asset_Id) -> (check:u64,ok:bool) {
    entry:=data.ptr!=nil?data_find(data.ptr,id):nil
    if entry==nil {return}
    low,high:=source_region(&entry.source)
    return replay_check(entry,low,high),true
}

// The origin of a loaded source (Source.origin), and whether nothing of it
// was written since: no page of a grid altered.
terrain_origin :: proc(data:core.Ref(Terrain_Data),id:base.Asset_Id) -> (origin:u64,clean,ok:bool) {
    s:=terrain_source(data,id)
    if s==nil {return}
    altered :: proc(g:^Grid($T)) -> bool {
        for page in g.pages {if page.altered {return true}}
        return g.filled
    }
    clean=!altered(&s.field) && !altered(&s.holes) && !altered(&s.weights)
    return s.origin,clean,true
}

// Whether a source a terrain names cannot be loaded: the assets do not have
// it, or it could not be read or did not fit (another problem says which).
terrain_unread :: proc(data:core.Ref(Terrain_Data),a:^host.Assets,id:base.Asset_Id) -> bool {
    if data.ptr!=nil && slice.contains(data.unread[:],id) {return true}
    record,found:=asset.registry_find(&a.registry,id)
    return !found || record.kind!=TERRAIN_KIND
}

// The pages of a grid of a loaded source over the inclusive region (all of
// them for an empty region), as page coordinates, and how many there are along each axis; ok
// is false for a grid the source does not hold.
terrain_grid_pages :: proc(data:core.Ref(Terrain_Data),id:base.Asset_Id,kind:Grid_Kind,low,high:[3]i32) -> (from,to,counts:[3]int,ok:bool) {
    s:=terrain_source(data,id)
    if s==nil {return}
    pages :: proc(g:^Grid($T),low,high:[3]i32) -> (from,to,counts:[3]int,ok:bool) {
        if grid_none(g) {return}
        a,b:=[3]int{int(low.x),int(low.y),int(low.z)},[3]int{int(high.x),int(high.y),int(high.z)}
        if b.x<a.x {a,b={},g.size-1}
        if b.x<0 || b.y<0 || b.z<0 || a.x>=g.size.x || a.y>=g.size.y || a.z>=g.size.z {return}
        from,to=grid_pages(g,a,b)
        return from,to,g.counts,true
    }
    switch kind {
    case .Field:   return pages(&s.field,low,high)
    case .Holes:   return pages(&s.holes,low,high)
    case .Weights: return pages(&s.weights,low,high)
    }
    return
}

// The values of page i of a grid of a loaded source, wherever they are (in
// memory, or in a block of its own or of its file), into out coded as they
// are (page_code), or the bits of the one value of a uniform page (size 0).
// out holds PAGE_BYTES_MAX bytes.
terrain_page_bytes :: proc(data:core.Ref(Terrain_Data),id:base.Asset_Id,kind:Grid_Kind,i:int,out:[]u8) -> (size:int,fill:u32,ok:bool) {
    s:=terrain_source(data,id)
    if s==nil || len(out)<PAGE_BYTES_MAX {return}
    read :: proc(g:^Grid($T),i:int,file:string,out:[]u8) -> (size:int,fill:u32,ok:bool) {
        if grid_none(g) || i<0 || i>=g.counts.x*g.counts.y*g.counts.z {return}
        page:=grid_page(g,i)
        extent,count:=grid_page_extent(g,i)
        size=PAGE_HEADER+count*size_of(T)
        if page.values!=nil {
            page_code(page.values,extent.x,false,out)
            return size,0,true
        }
        if !grid_absent(g,i) {
            value:=page.fill
            bits:u32
            mem.copy_non_overlapping(&bits,&value,size_of(T))
            return 0,bits,true
        }
        read:Page_Reader
        read_ok:=page_reader_init(&read,context.temp_allocator)
        defer page_reader_destroy(&read,context.temp_allocator)
        if !read_ok {return}
        held:=grid_block(g,i)
        block,block_ok:=page_block_read(held,file,read.block)
        if !block_ok || !page_unpack(block,held.hash,out[:size],&read.decoder) {return}
        return size,0,true
    }
    switch kind {
    case .Field:   return read(&s.field,i,s.file,out)
    case .Holes:   return read(&s.holes,i,s.file,out)
    case .Weights: return read(&s.weights,i,s.file,out)
    }
    return
}

// The pages a grid of a loaded source holds, which a base sends: how many
// slots hold them (terrain_grid_held_page gives the page of each), and for a
// grid in blocks whether whole parts of it hold one value without pages
// (terrain_grid_fill gives those).
terrain_grid_held :: proc(data:core.Ref(Terrain_Data),id:base.Asset_Id,kind:Grid_Kind) -> (slots:int,parts:bool) {
    s:=terrain_source(data,id)
    if s==nil {return}
    switch kind {
    case .Field:   return len(s.field.pages),s.field.sparse
    case .Holes:   return len(s.holes.pages),s.holes.sparse
    case .Weights: return len(s.weights.pages),s.weights.sparse
    }
    return
}

// The id of the page a slot of a grid of a loaded source holds, and whether
// it was written since the source was read from its file or saved to it; ok
// is false for a slot that holds none.
terrain_grid_held_page :: proc(data:core.Ref(Terrain_Data),id:base.Asset_Id,kind:Grid_Kind,slot:int) -> (page:int,altered,ok:bool) {
    s:=terrain_source(data,id)
    if s==nil {return}
    held :: proc(g:^Grid($T),slot:int) -> (page:int,altered,ok:bool) {
        if slot<0 || slot>=len(g.pages) {return}
        page=grid_id(g,slot)
        return page,g.pages[slot].altered,page>=0
    }
    switch kind {
    case .Field:   return held(&s.field,slot)
    case .Holes:   return held(&s.holes,slot)
    case .Weights: return held(&s.weights,slot)
    }
    return
}

// The next part of a grid in blocks of a loaded source that holds one value
// without pages and not the one a new source of its shape starts with, at or
// after cursor (0 to begin): the id of its first page, how many pages a side
// its box is and the bits of the value. next: the cursor to go on from.
terrain_grid_fill :: proc(data:core.Ref(Terrain_Data),id:base.Asset_Id,kind:Grid_Kind,cursor:int) -> (page:int,span:int,fill:u32,next:int,found:bool) {
    s:=terrain_source(data,id)
    if s==nil {return}
    fills :: proc(g:^Grid($T),start:T,cursor:int) -> (page:int,span:int,fill:u32,next:int,found:bool) {
        if !g.sparse {return}
        skip:=fill_bits(start)
        for at:=max(cursor,0);at<len(g.top)*(TABLE_SLABS+1);at+=1 {
            top,m:=at/(TABLE_SLABS+1),at%(TABLE_SLABS+1)-1
            table_low:=[3]int{top%g.top_counts.x,top/g.top_counts.x%g.top_counts.y,top/(g.top_counts.x*g.top_counts.y)}*(TABLE*SLAB)
            tile:=g.top[top]
            if tile.child<0 {
                // The part itself, once; its slabs are not looked at.
                if m<0 && tile.fill!=skip {return grid_page_id(g,table_low),TABLE*SLAB,tile.fill,(top+1)*(TABLE_SLABS+1),true}
                at=(top+1)*(TABLE_SLABS+1)-1
                continue
            }
            if m<0 {continue}
            slab:=g.tables[tile.child][m]
            slab_low:=table_low+[3]int{m%TABLE,m/TABLE%TABLE,m/(TABLE*TABLE)}*SLAB
            if slab.child>=0 || slab.fill==skip || grid_box_pages(g,slab_low,SLAB)==0 {continue}
            return grid_page_id(g,slab_low),SLAB,slab.fill,at+1,true
        }
        return
    }
    switch kind {
    case .Field:   return fills(&s.field,field_fill(s.info),cursor)
    case .Holes:   return fills(&s.holes,0,cursor)
    case .Weights: return fills(&s.weights,Weights{WEIGHT_FULL,0,0,0},cursor)
    }
    return
}

// Whether a part of a grid in blocks of a loaded source took another value
// without pages since the source was read from its file or saved to it: a
// base of it sends all of it.
terrain_filled :: proc(data:core.Ref(Terrain_Data),id:base.Asset_Id) -> bool {
    s:=terrain_source(data,id)
    return s!=nil && (s.field.filled || s.weights.filled)
}

// The terrain of a source whose problems name it, or none.
terrain_of_source :: proc(terrains:^core.Table(Terrain,$A),id:base.Asset_Id) -> core.Entity {return source_owner(terrains,id)}
