package editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import img "mirai:cook/image"
import "mirai:core"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// A filmstrip of capture: the game stepped as play.step steps it and
// drawn before the first tick and every some ticks, a cell of each drawing
// (around where an entity shows, a fixed region or the whole image) put in
// one grid with its tick in its corner.

@(private)
Api_Filmstrip_Cell :: struct {
    tick:u64,
    at:[2]f32, // where the followed entity shows, in window points
    seen:bool, // the entity was in front of the camera
}

@(private)
Api_Filmstrip :: struct {
    run:Api_Step_Run,
    frames,count,columns:int,
    ticks:[]int,        // of each cell, how many ticks of the run it comes after; nil: whenever it is taken
    follow:core.Entity, // NONE: the region, or the whole image without one
    size:[2]f32,        // of a cell around follow, in window points
    region:[4]f32,      // in points of the image; no width: the whole image
    window:bool,        // the Play of the user as the window shows it, editor and all
    sheet:img.Sheet,
    cells:[]Api_Filmstrip_Cell,
    taken:int,
    counted:Api_Capture_Seen, // of the last cell, with the most textures any cell found pending
}

@(private) FILMSTRIP_PAST_AROUND :: u64(60) // ticks a filmstrip of the past shows on each side of its tick
@(private) FILMSTRIP_PAST_CELLS :: 9
@(private) FILMSTRIP_PAST_FRAMES :: 2       // frames drawn per cell

// Writes to path a filmstrip of the ticks a run keeps around one, played again
// on the World of the run, which is put back after; what it answers as JSON,
// or "" after failing the call.
api_filmstrip_around :: proc(s:^Session,call:^api.Call,r:^Run,tick:u64,path:string) -> string {
    if s.app==nil || s.app.renderer==nil {api.call_fail(call,api.SERVER_ERROR,"A filmstrip needs a GPU");return ""}
    if reason:=history_reason(s,r);reason!="" {api.call_fail(call,api.SERVER_ERROR,reason);return ""}
    h:=r.history
    oldest,newest,_,_,_:=history_span(h)
    from:=tick>oldest+FILMSTRIP_PAST_AROUND?tick-FILMSTRIP_PAST_AROUND:oldest
    to:=min(tick+FILMSTRIP_PAST_AROUND,newest)
    first:=history_frame_for(h,from)
    if first==0 {api_history_older(call,h,from);return ""}
    file,writable:=api_output_file(s,call,path,call.allocator)
    if !writable {return ""}
    span:=to>from?to-from:0
    every:=max(span/(FILMSTRIP_PAST_CELLS-1),1)
    strip:=new(Api_Filmstrip,call.allocator)
    strip^={frames=FILMSTRIP_PAST_FRAMES,count=int(span/every)+1}
    strip.run={owner=r.owner,player=r.player}
    strip.cells=make([]Api_Filmstrip_Cell,strip.count,call.allocator)
    defer img.sheet_destroy(&strip.sheet)
    saved,copied:=history_save(s,r)
    if !copied {api.call_fail(call,api.SERVER_ERROR,"No memory for a copy of the World to play its past on; the game stays as it is");return ""}
    problem:string
    {
        kept:=extras_mark(s.app)
        defer extras_drop(s.app,kept)
        problem=api_filmstrip_past_cells(s,r,strip,first,to,every)
    }
    history_restore(s,r,&saved)
    if problem!="" {api.call_fail(call,api.SERVER_ERROR,problem);return ""}
    sheet:=strip.sheet
    strip.sheet={}
    if problem:=api_png_write(s,file,sheet.image.pixels,sheet.image.width,sheet.image.height);problem!="" {api.call_fail(call,api.SERVER_ERROR,problem);return ""}
    return api_filmstrip_result(file,sheet,strip.cells[:strip.taken],false,call.allocator,strip.counted)
}

@(private)
api_filmstrip_past_cells :: proc(s:^Session,r:^Run,strip:^Api_Filmstrip,first,to,every:u64) -> string {
    h:=r.history
    if !history_seek(s,r,first).ok {return "No memory to go back to that tick"}
    if problem:=api_filmstrip_take(s,strip,run_ref(s,r),0);problem!="" {return problem}
    walk:=history_walk(h,first,to,every)
    for _,due in history_walk_next(&walk) {
        if !history_seek(s,r,walk.at).ok {return "No memory to play the past again"}
        if !due {continue}
        if problem:=api_filmstrip_take(s,strip,run_ref(s,r),0);problem!="" {return problem}
    }
    return ""
}

// Whether a call gives segments and how many cells spread over them.
@(private)
api_filmstrip_spread :: proc(call:^api.Call,p:^Api_Capture_Params) -> bool {
    if p.count==0 {return false}
    values:[1]string
    api.object_values(call.allocator,call.raw,{"segments"},values[:])
    return values[0]!=""
}

// How many ticks after the start each cell of a filmstrip comes when
// segments ran given ticks: every (with count, as far as they last) or, with
// no every, count cells spread evenly from the first tick to the last.
// Without segments (given<0), every apart. A filmstrip holds at most limit.
@(private)
api_filmstrip_ticks :: proc(given,every,count,limit:int,allocator:mem.Allocator) -> []int {
    cells:=count
    switch {
    case given<0: cells=max(count,1)
    case every==0:
        if given+1<cells {cells=given+1}
    case cells==0: cells=given/every+1
    case: cells=min(cells,given/every+1)
    }
    cells=min(cells,limit)
    ticks:=make([]int,cells,allocator)
    for &tick,i in ticks {
        switch {
        case every>0:  tick=i*every
        case cells>1: tick=int(math.round(f64(i)*f64(given)/f64(cells-1)))
        }
    }
    return ticks
}

// The filmstrip capture asks for, checked; nil when it asks for one image.
@(private)
api_filmstrip_read :: proc(s:^Session,call:^api.Call,r:^Run,own:bool,p:^Api_Capture_Params) -> (strip:^Api_Filmstrip,ok:bool) {
    keys:=[?]string{"every","count","columns","segments","follow","size","region"}
    values:[len(keys)]string
    api.object_values(call.allocator,call.raw,keys[:],values[:])
    if p.every_seconds!=0 {
        if p.every!=0 {api.call_fail(call,api.INVALID_PARAMS,"every and every_seconds both say how far apart the cells are: give one");return}
        timed:bool
        if p.every,timed=api_seconds_ticks(call,"every_",f64(p.every_seconds),s.app.tick_dt,API_STEP_LIMIT);!timed {return}
    }
    spread:=values[3]!="" && p.count>0
    if p.every==0 && !spread {
        for value,i in values[1:len(keys)-1] {
            if value!="" {api.call_failf(call,api.INVALID_PARAMS,"%s is of a filmstrip: give it with every (the ticks between two cells) and count or segments, or leave it out",keys[i+1]);return}
        }
        return nil,true
    }
    if p.count==0 && values[3]=="" {api.call_fail(call,api.INVALID_PARAMS,"count: give the cells of the filmstrip with every, or segments to run; 1 to 64");return}
    if values[3]=="" && p.every*(p.count-1)>API_STEP_LIMIT {
        api.call_failf(call,api.INVALID_PARAMS,"the filmstrip runs every times count less one ticks (%d) and a call runs at most %d: lower every or count",p.every*(p.count-1),API_STEP_LIMIT)
        return
    }
    if !own {api_play_refused(call);return}
    w:=run_ref(s,r)
    strip=new(Api_Filmstrip,call.allocator)
    strip^={frames=p.frames>0?p.frames:API_CAPTURE_SETTLE,columns=p.columns,size=p.size,window=p.ui}
    followed:=values[4]!=""
    switch {
    case followed && values[6]!="":
        api.call_fail(call,api.INVALID_PARAMS,"give an entity to follow or a region, not both");return
    case !followed && values[5]!="":
        api.call_fail(call,api.INVALID_PARAMS,"size is the cell around a followed entity: give follow too, or region in its place");return
    }
    if followed {
        known:bool
        if strip.follow,known=api_call_entity(call,w,p.follow[:],"follow",game=true);!known {return}
    }
    if values[6]!="" {
        q:=p.region
        if !rpc_finite(q.x) || !rpc_finite(q.y) || !(q.z>=1 && q.z<=4096) || !(q.w>=1 && q.w<=4096) || abs(q.x)>4096 || abs(q.y)>4096 {
            api.call_fail(call,api.INVALID_PARAMS,"region takes x y width height in window points: finite with x and y within 4096 of the corner and a width and a height from 1 to 4096")
            return
        }
        strip.region=q
    }
    steps:[]Api_Step_Input
    if values[3]!="" {
        steps=api_segments_read(call,p.segments[:],values[3],s.app.tick_dt) or_return
        if problem:=run_script_blocks(s,run_player(s,r.owner,p.player));problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    }
    timeline:=steps
    if values[3]=="" {
        timeline=make([]Api_Step_Input,1,call.allocator)
        timeline[0]={ticks=p.every*(p.count-1)}
    }
    strip.ticks=api_filmstrip_ticks(values[3]!=""?api_timeline_ticks(steps):-1,p.every,p.count,API_FILMSTRIP_CELLS,call.allocator)
    if r.owner==0 && simulating(s) && api_timeline_input(timeline) {api.call_fail(call,api.INVALID_PARAMS,"A simulation takes no player input");return}
    strip.run={owner=r.owner,player=p.player,timeline=timeline,sampler={every=1,take=api_filmstrip_take,data=strip}}
    strip.count=len(strip.ticks)
    strip.cells=make([]Api_Filmstrip_Cell,strip.count,call.allocator)
    return strip,true
}

// Steps the game, takes the cells and writes the filmstrip at path.
@(private)
api_filmstrip_run :: proc(s:^Session,call:^api.Call,strip:^Api_Filmstrip,path:string,shown:bool) {
    defer img.sheet_destroy(&strip.sheet)
    r:=run_player(s,strip.run.owner,strip.run.player)
    if r==nil {api.call_fail(call,api.SERVER_ERROR,"No game is playing; play.start first");return}
    if strip.run.owner==0 && !play_paused(s) {play_pause(s,true,stepped=true)}
    if problem:=api_filmstrip_take(s,strip,run_ref(s,r),0);problem!="" {api.call_fail(call,api.SERVER_ERROR,problem);return}
    ran,_,problem:=api_step_run(s,&strip.run,api_step_frame)
    if problem!="" {
        api.call_failf(call,api.SERVER_ERROR,"%s, after %d cells",problem,strip.taken)
        return
    }
    sheet:=strip.sheet
    // The write takes the pixels.
    strip.sheet={}
    if problem:=api_png_write(s,path,sheet.image.pixels,sheet.image.width,sheet.image.height);problem!="" {api.call_fail(call,api.SERVER_ERROR,problem);return}
    serial.text_write_raw(call.out,api_filmstrip_result(path,sheet,strip.cells[:strip.taken],strip.follow!=core.NONE,call.allocator,strip.counted,ran))
    if shown {api.call_image(call,path)}
}

// What a filmstrip answers besides its image: where it is, its grid and the tick of each cell.
@(private)
api_filmstrip_result :: proc(path:string,sheet:img.Sheet,cells:[]Api_Filmstrip_Cell,followed:bool,allocator:mem.Allocator,counted:=Api_Capture_Seen{},ticks:=-1) -> string {
    out:serial.Writer
    serial.writer_init(&out,1024,allocator)
    serial.text_write_raw(&out,`{"path":`);serial.text_write_string(&out,path)
    api.write_int(&out,"width",i64(sheet.image.width));api.write_int(&out,"height",i64(sheet.image.height))
    api.write_int(&out,"columns",i64(sheet.columns));api.write_int(&out,"rows",i64(sheet.rows))
    if ticks>=0 {api.write_int(&out,"ticks",i64(ticks))}
    api.write_key(&out,"cell");serial.write_u8(&out,'[')
    serial.text_write_int(&out,i64(sheet.tile.x));serial.write_u8(&out,',');serial.text_write_int(&out,i64(sheet.tile.y))
    serial.write_u8(&out,']')
    api.write_key(&out,"cells");serial.write_u8(&out,'[')
    for &cell,i in cells {
        if i>0 {serial.write_u8(&out,',')}
        serial.text_write_raw(&out,`{"tick":`);serial.text_write_uint(&out,cell.tick)
        if followed {
            api.write_key(&out,"at")
            if cell.seen {api.write_list(&out,cell.at[:])} else {serial.text_write_raw(&out,"null")}
        }
        serial.write_u8(&out,'}')
    }
    serial.write_u8(&out,']')
    api_capture_seen_write(&out,counted)
    serial.write_u8(&out,'}')
    return string(serial.writer_bytes(&out))
}

// A cell of the filmstrip: the game drawn now, the part of it it shows put
// in the grid with the tick in its corner.
@(private)
api_filmstrip_take :: proc(s:^Session,data:rawptr,_:core.World_Ref,ran:int) -> string {
    strip:=cast(^Api_Filmstrip)data
    if strip.taken>=strip.count || strip.ticks!=nil && ran!=strip.ticks[strip.taken] {return ""}
    r:=run_player(s,strip.run.owner,strip.run.player)
    if r==nil {return "The game ended"}
    pixels,width,height,drawn:=api_play_pixels(s,r,strip.frames,strip.window)
    if !drawn {return fmt.tprintf("The game could not be drawn: %s",host.app_draw_problem(s.app))}
    defer delete(pixels,s.app.allocator)
    w:=run_ref(s,r)
    density:=s.app.ui_input.scale>0?s.app.ui_input.scale:1
    view:=[4]f32{0,0,f32(width),f32(height)}
    if r.owner==0 && strip.window && s.viewport.size.x>0 && s.viewport.size.y>0 {view={s.viewport.origin.x*density,s.viewport.origin.y*density,s.viewport.size.x*density,s.viewport.size.y*density}}
    cell:=&strip.cells[strip.taken]
    counted:=api_capture_seen(s.app)
    counted.textures_pending=max(counted.textures_pending,strip.counted.textures_pending)
    strip.counted=counted
    if t:=core.world_storage_of(w,core.Time);t!=nil {cell.tick=t.tick}
    region:img.Region
    switch {
    case strip.follow!=core.NONE:
        center:=view.xy+view.zw*0.5
        if seen:=core.world_storage_of(w,core.View);seen!=nil && core.alive(core.world_entities(w),strip.follow) {
            if at,shown:=api_view_project(seen^,view,api_entity_middle(w,strip.follow));shown {
                center,cell.at,cell.seen=at,at/density,true
            }
        }
        region=api_filmstrip_region(center,strip.size*density,{width,height})
    case strip.region.z>0:
        q:=strip.region*density
        region={int(math.round(q.x)),int(math.round(q.y)),max(int(math.round(q.z)),1),max(int(math.round(q.w)),1)}
    case:
        region={0,0,width,height}
    }
    if strip.sheet.count==0 {
        sheet,error:=img.sheet_make(strip.count,region.w,region.h,s.app.allocator,strip.columns)
        if error!=.None {return fmt.tprintf("No filmstrip of %d cells of %dx%d pixels: %s",strip.count,region.w,region.h,img.error_message(error))}
        strip.sheet=sheet
    }
    if error:=img.sheet_put_region(&strip.sheet,strip.taken,{pixels=pixels,width=width,height=height},region,cell.tick);error!=.None {
        return fmt.tprintf("cell %d: %s",strip.taken,img.error_message(error))
    }
    strip.taken+=1
    return ""
}

// Where a world point shows in pixels of an image whose rect (x y width
// height in pixels) a view draws; false behind its eye.
@(private)
api_view_project :: proc(view:core.View,rect:[4]f32,point:[3]f32) -> (at:[2]f32,seen:bool) {
    if !(rect.z>0) || !(rect.w>0) {return}
    drawn:=view
    drawn.size=rect.zw
    pixel,_,front:=core.view_project(drawn,point)
    if !front || !rpc_finite(pixel.x) || !rpc_finite(pixel.y) {return}
    return rect.xy+pixel,true
}

// Where an entity is seen to be, not its origin at the feet of a character:
// the center of mass of a body, or the middle of what hangs from it. The box
// of a skinned mesh is that of its bind pose.
api_entity_middle :: proc(w:core.World_Ref,e:core.Entity) -> [3]f32 {
    placed:=entity_world(w,e)
    if motions:=core.world_table_of(w,core.Motion);motions!=nil {
        if motion,moves:=core.get(core.read(motions),e);moves {return placed.position+mm.quat_rotate(placed.rotation,motion.center)}
    }
    low,high:=placed.position,placed.position
    transforms,worlds:=core.world_table_of(w,core.Transform),core.world_table_of(w,core.World_Transform)
    if transforms==nil {return placed.position}
    for other in transforms.entities {
        if other==e || !entity_under(w,other,e) {continue}
        at:=entity_world(w,other).position
        if row:=worlds!=nil?core.row_of(worlds,other):-1;row>=0 {at=worlds.values[row].transform.position}
        low,high=linalg.min(low,at),linalg.max(high,at)
    }
    return (low+high)*0.5
}

// The cell of size pixels centered on center in an image of image pixels;
// a center far off the image gives a cell beside it.
@(private)
api_filmstrip_region :: proc(center,size:[2]f32,image:[2]int) -> img.Region {
    w,h:=max(int(size.x+0.5),1),max(int(size.y+0.5),1)
    c:=center
    if !rpc_finite(c.x) || !rpc_finite(c.y) {c={f32(image.x),f32(image.y)}*0.5}
    c.x=clamp(c.x,-f32(w),f32(image.x+w))
    c.y=clamp(c.y,-f32(h),f32(image.y+h))
    return {int(math.round(c.x))-w/2,int(math.round(c.y))-h/2,w,h}
}
