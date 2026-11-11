package terrain_multiplayer

import "core:fmt"
import "core:log"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import multiplayer "plugins:multiplayer/runtime"
import terrain "plugins:terrain/runtime"

// Edits of terrain over the network, as a journal (multiplayer.Journal) keyed
// by source. The server decides: the edits and layer changes of its game and
// those its clients ask for are its operations, with the region each changed
// and the check of what that region holds after it (terrain.Replay_Result).
// terrain does not know the network: in a session this library routes every
// tick (terrain.Terrain_Replays.routed), so terrain_replay applies what it
// orders and then the requests of dig and request_layer, and says how each went.
//
// An edit of the client's own game is a prediction: applied at once and
// asked of the server; a layer change is only asked, and applies when it
// comes back. The server holds the ask until its tick and refuses what it
// does not allow (Terrain_Refusal, which says why). What differs comes back
// as the parts of its region: the pages of its grids, whole. Nothing depends
// on two architectures giving the same bits.
//
// A client asks for a base of each source it loads, or cannot read, with the
// origin of what it holds (terrain.terrain_origin). The base is a head (the
// shape and layers of the source) and the pages the server wrote since that
// origin, or every page when the client's is another: what was edited before
// the session, or a source saved where the client does not have it, comes
// with it, not the history.

TERRAIN_JOURNAL :: u32(0x74657272)
NET_READ_SAMPLES :: 8 // samples past what an edit writes that another edit reads (Smooth)

#assert(1+terrain.BRUSH_BYTES<=multiplayer.JOURNAL_BODY && 1+terrain.LAYER_CHANGE_BYTES<=multiplayer.JOURNAL_BODY)

// What a server allows its clients.
@(storage,setting)
Terrain_Net_Settings :: struct {
    rate:f32 `mirai:"min=0"`,          // edits a second each client may ask, in bursts of one second; 0: clients do not edit
    reach:f32 `mirai:"min=0,unit=m"`,  // how far from a body its seat drives a client may edit; 0: anywhere
    radius:f32 `mirai:"min=0,unit=m"`, // the largest brush a client may ask; 0: any
}
TERRAIN_NET_SETTINGS_DEFAULT :: Terrain_Net_Settings{rate=60,radius=64}

// Why a server did not apply an edit a client asked for.
Terrain_Refusal :: enum u8 {
    None,
    Rate,       // more than Terrain_Net_Settings.rate
    Player,     // the connection has no seat
    Reach,      // farther than Terrain_Net_Settings.reach from what its seat drives
    Radius,     // a brush larger than Terrain_Net_Settings.radius
    Brush,      // not a brush, or not a layer change
    Tick,       // for a tick too far ahead
    Not_Loaded, // the server does not have the source loaded
    Edit,       // the edit failed there: its error says why
}

// What a part of a source is, ahead of its values: the head of a base
// (terrain.terrain_head_bytes), a page of a grid, or a slab or a table of a
// grid in blocks that holds one value without pages (terrain.terrain_grid_fill).
Net_Part :: enum u8 {Head,Grid,Slab,Table}

@(private)
Part_Head :: struct #packed {
    part:Net_Part,
    grid:terrain.Grid_Kind,
    page:u32,
    fill:u32,
}

// Server: where an answer is in the parts of its source (multiplayer.Journal_Serve.cursor).
@(private)
Serve_Cursor :: struct {
    origin:u64, // of the source here as the answer started
    next:int,   // the slot of a page, or the block of the fills, it looks at next
    grid:terrain.Grid_Kind,
    headed:bool,
    fills:bool, // of a whole base: the pages of the grid went, its parts of one value go
}
#assert(size_of(Serve_Cursor)<=size_of(type_of(multiplayer.Journal_Serve{}.cursor)))

// Client: what this end knows of a source besides its stream.
@(private)
Net_Source :: struct {
    id:base.Asset_Id,
    loaded:bool,
    missing:bool, // it cannot be read here: a whole base was asked for
    based:bool,   // a head applied since it loaded: it holds what the server wrote since its origin
}

@(private)
Net_Rate :: struct {
    connection:multiplayer.Connection,
    tokens:f32,
    tick:u64,
}

// One for each World, never copied.
@(storage,host,by_world,free="net_free")
Terrain_Net :: struct {
    journal:multiplayer.Journal,
    sources:[dynamic]Net_Source, // client
    rates:[dynamic]Net_Rate,     // server
    launched:bool, // client of a session the player was launched with: it tells the person how it went
}

net_free :: proc(n:^Terrain_Net) {
    if n.launched {
        s:=n.journal.stats
        fmt.printfln("terrain: %d edits of the server came here, %d of them left another check and asked for their parts; %d parts applied",s.received,s.desyncs,s.parts_applied)
    }
    multiplayer.journal_free(&n.journal)
    delete(n.sources);delete(n.rates)
    n^={}
}

@(private)
net_world :: proc(n:^Terrain_Net,root:core.Ref(scene.Scene_Root)) {
    if multiplayer.journal_world(&n.journal,TERRAIN_JOURNAL,root) {clear(&n.sources);clear(&n.rates)}
}

// What a person running a session reads: printed by a player launched on
// the network, as multiplayer prints, else in the log.
@(private)
tell :: proc(session:core.Ref(multiplayer.Net_Session),format:string,args:..any) {
    if session.ptr!=nil && session.launched {fmt.printfln(format,..args)} else {log.infof(format,..args)}
}

@(private)
source_of :: proc(n:^Terrain_Net,id:base.Asset_Id) -> ^Net_Source {
    for &src in n.sources {if src.id==id {return &src}}
    if _,error:=append(&n.sources,Net_Source{id=id});error!=nil {return nil}
    return &n.sources[len(n.sources)-1]
}

// A base of a source is asked for, with the origin of what it holds now
// when the parts of the server since it complete it: nothing written here
// since its file, or only what came of the server.
@(private)
base_ask :: proc(j:^multiplayer.Journal,src:^Net_Source,data:core.Ref(terrain.Terrain_Data)) {
    since:u64
    if origin,clean,ok:=terrain.terrain_origin(data,src.id);ok && (clean || src.based) {since=origin}
    multiplayer.journal_resync(j,multiplayer.Journal_Key(src.id),true,since)
}

@(private)
op_body :: proc(r:terrain.Replay_Result) -> (body:[multiplayer.JOURNAL_BODY]u8) {
    body[0]=u8(r.kind)
    if r.kind==.Layer {
        bytes:=terrain.layer_change_bytes(r.layer)
        copy(body[1:],bytes[:])
    } else {
        bytes:=terrain.brush_bytes(r.brush)
        copy(body[1:],bytes[:])
    }
    return
}

// The edit or layer change of the bytes of an operation; false when they are neither.
@(private)
op_replay :: proc(source:base.Asset_Id,body:[multiplayer.JOURNAL_BODY]u8) -> (replay:terrain.Replay,ok:bool) {
    body:=body
    replay.source=source
    switch body[0] {
    case u8(terrain.Replay_Kind.Edit):
        brush:[terrain.BRUSH_BYTES]u8
        copy(brush[:],body[1:])
        replay.kind=.Edit
        replay.brush,ok=terrain.brush_of_bytes(brush)
    case u8(terrain.Replay_Kind.Layer):
        replay.kind=.Layer
        replay.layer,ok=terrain.layer_change_of_bytes(body[1:])
    }
    return
}

// The replay of a part: its head, then its values; false when it is not one.
@(private)
part_replay :: proc(source:base.Asset_Id,part:^multiplayer.Journal_Part) -> (replay:terrain.Replay,ok:bool) {
    if len(part.bytes)<size_of(Part_Head) {return}
    head:=(^Part_Head)(raw_data(part.bytes))^
    if head.part>max(Net_Part) || head.grid>max(terrain.Grid_Kind) {return}
    replay={source=source,grid=head.grid,page=head.page,fill=head.fill,whole=part.whole,values=part.bytes[size_of(Part_Head):]}
    switch head.part {
    case .Head:  replay.kind=.Head
    case .Grid:  replay.kind=.Page
    case .Slab:  replay.kind,replay.span=.Page,terrain.SLAB
    case .Table: replay.kind,replay.span=.Page,terrain.SLAB*terrain.TABLE
    }
    if head.part!=.Grid && head.part!=.Head {replay.values=nil}
    return replay,true
}

@(step="fixed",loops="game",stage="begin")
terrain_net_receive :: proc(
    inbox:multiplayer.Journal_Inbox,authority:core.Ref(core.Network),n:^Terrain_Net,session:core.Ref(multiplayer.Net_Session),
    time:core.Time,rewinds:^multiplayer.Net_Rewinds,root:core.Ref(scene.Scene_Root),problems:^core.Problems,
) {
    if n==nil {return}
    net_world(n,root)
    if authority.ptr==nil || authority.role==.Standalone {return}
    multiplayer.journal_receive(&n.journal,inbox,authority.role==.Server,multiplayer.own_connection(session),time,rewinds,false,NET_READ_SAMPLES,problems)
}

// Server: what a held ask can be told at its tick, its rate, where its seat
// stands, and the replay it is. Without memory to count the asks of a
// connection it is refused as Rate.
@(private)
ask_check :: proc(n:^Terrain_Net,held:multiplayer.Journal_Held,time:core.Time,data:core.Ref(terrain.Terrain_Data),terrains:^core.Table(terrain.Terrain,$A),seats:^core.Table(input.Seat,$B),drivables:^core.Table(input.Drivable,$C),worlds:^core.Table(core.World_Transform,$D),settings:Terrain_Net_Settings) -> (replay:terrain.Replay,refusal:Terrain_Refusal) {
    if held.ahead {return {},.Tick}
    if refusal=rate_take(n,held.connection,time,settings);refusal!=.None {return}
    source:=base.Asset_Id(held.ask.key)
    ok:bool
    if replay,ok=op_replay(source,held.ask.body);!ok {return {},.Brush}
    if replay.kind==.Edit && settings.radius>0 && replay.brush.radius>settings.radius {return {},.Radius}
    if terrain.terrain_source(data,source)==nil {return {},.Not_Loaded}
    seat:=core.NONE
    if seats!=nil {
        for value,row in seats.values[:core.count(seats)] {if multiplayer.Connection(value.peer)==held.connection {seat=core.entity_at(seats,row);break}}
    }
    if seat==core.NONE {return {},.Player}
    if settings.reach>0 && replay.kind==.Edit {
        at:=replay.brush.center
        if owner:=terrain.terrain_of_source(terrains,source);owner!=core.NONE {
            if world,found:=core.get(worlds,owner);found {at=mm.transform_point(world.transform,at)}
        }
        near:=false
        if drivables!=nil {
            for value,row in drivables.values[:core.count(drivables)] {
                if value.seat!=seat {continue}
                world,found:=core.get(worlds,core.entity_at(drivables,row))
                if found {d:=world.position-at;if d.x*d.x+d.y*d.y+d.z*d.z<=settings.reach*settings.reach {near=true;break}}
            }
        }
        if !near {return {},.Reach}
    }
    return replay,.None
}

@(private)
rate_take :: proc(n:^Terrain_Net,connection:multiplayer.Connection,time:core.Time,settings:Terrain_Net_Settings) -> Terrain_Refusal {
    if !(settings.rate>0) {return .Rate}
    rate:^Net_Rate
    for &r in n.rates {if r.connection==connection {rate=&r;break}}
    if rate==nil {
        if _,err:=append(&n.rates,Net_Rate{connection=connection,tokens=settings.rate,tick=time.tick});err!=nil {return .Rate}
        rate=&n.rates[len(n.rates)-1]
    }
    rate.tokens=min(rate.tokens+f32(time.tick-rate.tick)*time.dt*settings.rate,max(settings.rate,1))
    rate.tick=time.tick
    if rate.tokens<1 {return .Rate}
    rate.tokens-=1
    return .None
}

// What applies in this tick, before terrain does. Server: the asks whose
// tick came, or a refusal. Client: what the journal hands of each source.
@(step="fixed",loops="game",stage="simulate")
terrain_net_follow :: proc(
    authority:core.Ref(core.Network),n:^Terrain_Net,time:core.Time,replays:^terrain.Terrain_Replays,outbox:^multiplayer.Net_Outbox,
    session:core.Ref(multiplayer.Net_Session),data:core.Ref(terrain.Terrain_Data),terrains:^core.Table(terrain.Terrain,.Read),
    seats:^core.Table(input.Seat,.Read),drivables:^core.Table(input.Drivable,.Read),worlds:^core.Table(core.World_Transform,.Read),
    settings:Terrain_Net_Settings,root:core.Ref(scene.Scene_Root),assets:^host.Assets,problems:^core.Problems,
) {
    if n==nil {return}
    net_world(n,root)
    if authority.ptr==nil || authority.role==.Standalone {return}
    replays.routed=true
    j:=&n.journal
    if authority.role==.Server {
        for held in multiplayer.journal_asks(j,time) {
            replay,refusal:=ask_check(n,held,time,data,terrains,seats,drivables,worlds,settings)
            if refusal!=.None {multiplayer.journal_refuse(j,outbox,held,u8(refusal),0);continue}
            replay.tag=multiplayer.journal_ask_tag(j,held,time)
            core.push(&replays.items,replay)
        }
        return
    }
    replays.asked=true
    n.launched=session.ptr!=nil && session.launched
    for refused in multiplayer.journal_refusals(j,time) {
        refusal_report(problems,terrain.terrain_of_source(terrains,base.Asset_Id(refused.key)),refused)
    }
    // Every source a terrain shows here, or cannot read, follows its stream.
    if terrains!=nil {
        for marker in terrains.values[:core.count(terrains)] {
            if marker.source=={} || terrain.terrain_source(data,marker.source)==nil && !terrain.terrain_unread(data,assets,marker.source) {continue}
            if source_of(n,marker.source)==nil {core.report(problems,core.NONE,"terrain.net_memory","out of memory to follow a terrain source over the network; it is tried again in the next tick: free memory")}
        }
    }
    own:=multiplayer.own_connection(session)
    for &src in n.sources {
        key:=multiplayer.Journal_Key(src.id)
        if terrain.terrain_source(data,src.id)==nil {
            src.loaded,src.based=false,false
            // One it cannot read waits for the head of a whole base, which makes it.
            unread:=terrain.terrain_unread(data,assets,src.id)
            if !unread || !multiplayer.journal_skip(j,key,time,true) {
                multiplayer.journal_skip(j,key,time,false)
                if unread && !src.missing {src.missing=true;multiplayer.journal_resync(j,key,true,0)}
                continue
            }
        } else if !src.loaded {
            // What it holds as it loads is of its file: a base brings what the server wrote since.
            src.loaded,src.missing=true,false
            base_ask(j,&src,data)
        }
        for due in multiplayer.journal_due(j,key,time,own) {
            replay:terrain.Replay
            ok:bool
            if due.part!=nil {
                replay,ok=part_replay(src.id,due.part)
            } else if replay,ok=op_replay(src.id,due.op.body);ok {
                replay.verify,replay.low,replay.high=true,due.op.low,due.op.high
            }
            if !ok {multiplayer.journal_result(j,due.tag,.Failed,0,time);continue}
            replay.tag=due.tag
            core.push(&replays.items,replay)
        }
    }
}

@(private)
refusal_report :: proc(problems:^core.Problems,e:core.Entity,refused:multiplayer.Net_Journal_Refused) {
    code:="terrain.net_refused"
    if refused.reason>u8(max(Terrain_Refusal)) {return}
    switch Terrain_Refusal(refused.reason) {
    case .None:
    case .Rate:       core.report(problems,e,code,"the server refused an edit of this terrain: its client asked for more edits a second than Terrain_Net_Settings.rate of the server allows; ask for fewer, or raise it on the server")
    case .Player:     core.report(problems,e,code,"the server refused an edit of this terrain: the connection has no seat there yet; ask once the player is seated")
    case .Reach:      core.report(problems,e,code,"the server refused an edit of this terrain: its center is farther than Terrain_Net_Settings.reach of the server from every body the player drives; edit closer, or raise it on the server")
    case .Radius:     core.report(problems,e,code,"the server refused an edit of this terrain: its brush is larger than Terrain_Net_Settings.radius of the server; use a smaller radius, or raise it on the server")
    case .Brush:      core.report(problems,e,code,"the server refused an edit of this terrain: a field of its brush or layer change is not finite or not one of its values; give each field a valid value")
    case .Tick:       core.report(problems,e,code,"the server refused an edit of this terrain: it was asked for a tick more than %d ticks ahead of the server; the clock of the client is not the server's",multiplayer.JOURNAL_AHEAD_TICKS)
    case .Not_Loaded: core.report(problems,e,code,"the server refused an edit of this terrain: the server does not have its source loaded; edit where the server keeps its sections loaded")
    case .Edit:       core.report(problems,e,code,"the server refused an edit of this terrain: there it failed as %v; the problem terrain.edit_* or terrain.layer_* of the same request here says how to fix it",terrain.Edit_Error(refused.error))
    }
}

// After terrain. Server: each edit it applied is published, and the parts go
// to who asked. Client: each edit of its game is asked of the server, as a
// prediction, and what the replays left is told to the journal.
@(step="fixed",loops="game",stage="react")
terrain_net_send :: proc(
    authority:core.Ref(core.Network),n:^Terrain_Net,time:core.Time,outbox:^multiplayer.Net_Outbox,
    connections:core.Ref(multiplayer.Net_Connections),replayed:core.Ref(terrain.Terrain_Replay_Events),data:core.Ref(terrain.Terrain_Data),
    session:core.Ref(multiplayer.Net_Session),root:core.Ref(scene.Scene_Root),
) {
    if n==nil {return}
    net_world(n,root)
    if authority.ptr==nil || authority.role==.Standalone {return}
    j:=&n.journal
    if authority.role==.Server {
        if replayed.ptr!=nil {edits_send(j,time,outbox,replayed)}
        multiplayer.journal_connections(j,connections)
        for sv in multiplayer.journal_serves(j,outbox,time) {
            if terrain.terrain_source(data,base.Asset_Id(sv.key))!=nil {serve_part(j,sv,data)}
        }
        return
    }
    index:=0
    if replayed.ptr!=nil {
        for r in replayed.results.items {
            if r.request {
                at:=index
                index+=1
                if r.error!=.None || at>int(max(u8)) {continue}
                multiplayer.journal_ask(j,outbox,multiplayer.Journal_Key(r.source),time,u8(at),op_body(r),r.kind==.Edit,r.low,r.high,r.check)
                continue
            }
            first:=multiplayer.journal_result(j,r.tag,r.error==.None?.Done:.Failed,r.check,time)
            if r.kind!=.Head || !first {continue}
            name:[base.ASSET_ID_TEXT]u8
            if r.error!=.None {
                tell(session,"terrain: a base of source %s did not apply here (%v, %s): every part is asked for",base.asset_id_format(r.source,name[:]),r.error,r.loaded?"loaded":"not loaded")
            } else if src:=source_of(n,r.source);src!=nil {
                src.based,src.loaded=true,true
                tell(session,"terrain: a base of source %s came from the server",base.asset_id_format(r.source,name[:]))
            }
        }
    }
    multiplayer.journal_flush(j,outbox,time,session)
}

// Server: the edits and layer changes terrain applied in this tick, in its order.
@(private)
edits_send :: proc(j:^multiplayer.Journal,time:core.Time,outbox:^multiplayer.Net_Outbox,replayed:core.Ref(terrain.Terrain_Replay_Events)) {
    for r in replayed.results.items {
        if r.kind!=.Edit && r.kind!=.Layer {continue}
        op:=multiplayer.Journal_Op{key=multiplayer.Journal_Key(r.source),check=r.check,low=r.low,high=r.high,body=op_body(r)}
        if r.kind==.Layer {op.low,op.high={0,0,0},{-1,-1,-1}}
        if !r.request {
            held,ok:=multiplayer.journal_held_of(j,r.tag)
            if !ok {continue}
            if r.error!=.None {
                multiplayer.journal_refuse(j,outbox,held,u8(r.loaded?Terrain_Refusal.Edit:Terrain_Refusal.Not_Loaded),u8(r.error))
                continue
            }
            op.asker,op.ask_tick,op.ask_index=held.connection,held.ask.tick,held.ask.index
        } else if r.error!=.None || !r.changed {
            continue
        }
        multiplayer.journal_publish(j,outbox,op,time)
    }
}

// Server: the next page of the grid an answer sends, from its cursor on. Of
// a region, the pages over it, whether the grid holds them or not: what a
// client wrote there goes back to what the server reads. Of a base, the
// pages the grid holds: all of them when whole, else those written since its
// origin and those over its region.
@(private)
serve_next :: proc(sv:^multiplayer.Journal_Serve,c:^Serve_Cursor,data:core.Ref(terrain.Terrain_Data)) -> (index:int,found:bool) {
    source:=base.Asset_Id(sv.key)
    from,to,counts,region:=terrain.terrain_grid_pages(data,source,c.grid,sv.low,sv.high)
    region=region && sv.high.x>=sv.low.x
    if !sv.base {
        if !region {return}
        for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {
            p:=px+counts.x*(py+counts.y*pz)
            if p>=c.next {c.next=p+1;return p,true}
        }}}
        return
    }
    slots,_:=terrain.terrain_grid_held(data,source,c.grid)
    for c.next<slots {
        p,altered,held:=terrain.terrain_grid_held_page(data,source,c.grid,c.next)
        c.next+=1
        if !held {continue}
        px,py,pz:=p%max(counts.x,1),counts.x>0?p/counts.x%max(counts.y,1):0,counts.x>0?p/(counts.x*max(counts.y,1)):0
        inside:=region && px>=from.x && py>=from.y && pz>=from.z && px<=to.x && py<=to.y && pz<=to.z
        if sv.whole || altered || inside {return p,true}
    }
    return
}

// Server: the next part of an answer to the journal, or its end. Without
// memory the answer waits for the next tick where it was.
@(private)
serve_part :: proc(j:^multiplayer.Journal,sv:^multiplayer.Journal_Serve,data:core.Ref(terrain.Terrain_Data)) {
    c:=(^Serve_Cursor)(&sv.cursor)
    was:=c^
    if !serve_write(j,sv,c,data) {c^=was}
}

@(private)
serve_write :: proc(j:^multiplayer.Journal,sv:^multiplayer.Journal_Serve,c:^Serve_Cursor,data:core.Ref(terrain.Terrain_Data)) -> bool {
    source:=base.Asset_Id(sv.key)
    HEAD :: size_of(Part_Head)
    if sv.base && !c.headed {
        c.headed=true
        c.origin,_,_=terrain.terrain_origin(data,source)
        // Parts of one value that changed without pages are not told apart from the file: all of it goes.
        sv.whole=sv.since==0 || c.origin==0 || sv.since!=c.origin || terrain.terrain_filled(data,source)
        raw,ok:=multiplayer.journal_buffer(j,HEAD+terrain.HEAD_BYTES)
        if !ok {return false}
        (^Part_Head)(raw_data(raw))^={part=.Head}
        if !terrain.terrain_head_bytes(data,source,raw[HEAD:]) {return multiplayer.journal_part(j,sv,nil,true)}
        return multiplayer.journal_part(j,sv,raw,false)
    }
    for {
        if !c.fills {
            if index,found:=serve_next(sv,c,data);found {
                raw,ok:=multiplayer.journal_buffer(j,HEAD+terrain.PAGE_BYTES_MAX)
                if !ok {return false}
                size,fill,read:=terrain.terrain_page_bytes(data,source,c.grid,index,raw[HEAD:])
                if !read {continue}
                (^Part_Head)(raw_data(raw))^={.Grid,c.grid,u32(index),fill}
                return multiplayer.journal_part(j,sv,raw[:HEAD+size],false)
            }
            // Of a whole base, the parts of a grid in blocks that hold one value without pages follow its pages.
            if _,parts:=terrain.terrain_grid_held(data,source,c.grid);sv.base && sv.whole && parts {
                c.fills,c.next=true,0
                continue
            }
        } else {
            page,span,fill,next,more:=terrain.terrain_grid_fill(data,source,c.grid,c.next)
            if more {
                c.next=next
                raw,ok:=multiplayer.journal_buffer(j,HEAD)
                if !ok {return false}
                (^Part_Head)(raw_data(raw))^={span==terrain.SLAB?.Slab:.Table,c.grid,u32(page),fill}
                return multiplayer.journal_part(j,sv,raw,false)
            }
            c.fills=false
        }
        if c.grid==max(terrain.Grid_Kind) {return multiplayer.journal_part(j,sv,nil,true)}
        c.grid=terrain.Grid_Kind(int(c.grid)+1)
        c.next=0
    }
}

