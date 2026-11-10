package terrain_multiplayer

import "core:fmt"
import "core:log"
import "core:mem"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:engine/scene"
import "mirai:asset"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/compressor"
import "mirai:std/compressor/lz"
import multiplayer "plugins:multiplayer/runtime"
import terrain "plugins:terrain/runtime"

// Edits of terrain over the network. The server decides: it applies the
// edits and layer changes of its game and the ones its clients ask for, and
// sends each to every client, numbered by source, with the tick it applied it
// at, the region it changed and the check of what that region holds after it
// (terrain.Replay_Result). terrain does not know the network: in a session
// this library routes every tick (terrain.Terrain_Replays.routed), so
// terrain_replay applies what it orders and then the requests of
// dig and request_layer, and says how each went.
//
// A client follows the stream of each source in its order, the edits and the
// parts the server sends it, where Terrain_Net_World (part of the World)
// says it stands: a correction that goes back finds the source as it was and
// applies them again at the tick each was first applied at. An edit of
// another for a tick the client already simulated, over one it predicts, asks
// to go back to that tick (multiplayer.rewind), so both are in the order of
// the server; otherwise it is applied in the present.
//
// An edit of its own game is a prediction: applied at once, kept with its
// check and asked of the server (Net_Terrain_Ask); a layer change is only
// asked, and applies when it comes back. The server holds the ask until its
// tick and refuses what it does not allow (Net_Terrain_Refused, which says
// why). When the server's edit comes back, a prediction that left what the
// server left stands as the edit; one that did not, a refused one or an edit
// of another whose check differs here asks for the parts of that region
// (Net_Terrain_Resync): the pages of its grids, and the sections of a Mesh,
// which the server sends whole, in LZ. Nothing depends on two architectures
// giving the same bits: what differs comes back as the server's parts.
//
// A client asks for a base of each source it loads, or cannot read, with the
// origin of what it holds (terrain.terrain_origin). The base is a head (the
// shape, layers and materials of the source) and the parts the server wrote
// since that origin, or every part when the client's is another: what was
// edited before the session, or a source saved where the client does not
// have it, comes with it, not the history.

NET_PAGE_WORDS :: 48
NET_PAGE_BYTES :: NET_PAGE_WORDS*4
NET_BODY_BYTES :: terrain.BRUSH_BYTES
NET_SECTION_BYTES_MAX :: 64*1024*1024 // the raw bytes of a section of a Mesh a client takes
NET_STATE_BUDGET :: 4096  // bytes of parts a server sends per tick
NET_ASK_TICKS :: 30       // a client asks for parts again after this long, and for a base after a gap this long
NET_AHEAD_TICKS :: 240    // server: an ask for a tick further ahead than this is refused
NET_KEEP_TICKS :: 32      // a client keeps what it applied this long at least, for the corrections that go back
NET_LOG_MAX :: 4096       // edits of a source a client holds ahead of where it stands
NET_SOURCES :: 32
NET_PREDICTIONS :: 128
NET_PREDICTION_TICKS :: 600 // a prediction the server never answered is given up, and its parts asked for
NET_READ_SAMPLES :: 8     // samples past what an edit writes that another edit reads (Smooth)

#assert(terrain.LAYER_CHANGE_BYTES<=NET_BODY_BYTES)

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
    Edit,       // the edit failed there: error says why
}

// The edits and layer changes a server applied, to every client, in the order of their source.
@(net_message,reliable)
Net_Terrain_Edit :: struct {
    source:base.Asset_Id,
    sequence:u32,
    tick:u32, // of the server, when it applied it
    asker:multiplayer.Connection, // the client that asked for it; 0: the server's own
    ask_tick:u32,
    ask_index:u8,
    kind:terrain.Replay_Kind, // Edit or Layer
    low,high:[3]i32, // what it changed: samples, or sections of a Mesh
    check:u64,       // Edit: of low..high after it; Layer: of the layers
    body:[NET_BODY_BYTES]u8, // the brush of an Edit, the change of a Layer
}

// A client: an edit or layer change its game asked for at tick, index-th of its requests in that tick.
@(net_message,from="client",reliable)
Net_Terrain_Ask :: struct {
    source:base.Asset_Id,
    tick:u32,
    index:u8,
    kind:terrain.Replay_Kind,
    body:[NET_BODY_BYTES]u8,
}

@(net_message,reliable)
Net_Terrain_Refused :: struct {
    source:base.Asset_Id,
    tick:u32,
    index:u8,
    reason:Terrain_Refusal,
    error:terrain.Edit_Error,
}

// A client: the parts of a source over low..high, or a base of it. origin:
// that of the source here, whose parts the server's since it complete; 0:
// it needs every part.
@(net_message,from="client",reliable)
Net_Terrain_Resync :: struct {
    source:base.Asset_Id,
    low,high:[3]i32,
    base:bool,
    origin:u64,
}

// What a Net_Terrain_Page holds: the head of a base (terrain.terrain_head_bytes),
// a page of a grid, a section of a Mesh or the end of a base, without bytes.
Net_Part :: enum u8 {Head,Grid,Section,End}

// A part of a source as the server holds it after edit after, in pieces:
// total bytes of LZ of raw bytes; a page of raw 0 is all fill. A head starts
// a base: it stands for every edit up to after, and whole says the parts
// that follow are all of them.
@(net_message,reliable)
Net_Terrain_Page :: struct {
    source:base.Asset_Id,
    after:u32,
    base,whole:bool,
    part:Net_Part,
    grid:terrain.Grid_Kind,
    page:u32,
    fill:u32,
    raw:u32,
    total:u32,
    offset:u32,
    count:u16,
    words:[NET_PAGE_WORDS]u32,
}

// Where a client stands in the stream of a source: the edits and the parts it applied.
Net_Cursor :: struct {
    source:base.Asset_Id,
    edits:u32,
    pages:u32,
}

// An edit of the game of a client, applied before the server answered.
Net_Prediction :: struct {
    source:base.Asset_Id,
    tick:u32,
    index:u8,
    low,high:[3]i32,
    check:u64,
}

// What a client applied of the network, part of the World: a correction
// brings back where it stood with the sources as they were.
@(storage)
Terrain_Net_World :: struct {
    cursors:[NET_SOURCES]Net_Cursor,
    cursor_count:u32,
    predictions:[NET_PREDICTIONS]Net_Prediction,
    prediction_count:u32,
}

@(private)
Net_Logged :: struct {
    edit:Net_Terrain_Edit, // sequence 0: not received
    placed:u64,            // the tick + 1 it was first applied (or skipped) at; 0 until then
    verified:bool,
}

// A part a client received, or is receiving: its LZ bytes until they are all
// here, then its raw values.
@(private)
Net_Part_State :: struct {
    after:u32,
    base,whole:bool,
    part:Net_Part,
    grid:terrain.Grid_Kind,
    page:u32,
    fill:u32,
    raw,total,have:u32,
    complete,broken:bool,
    told:bool, // a head: the person was told it came
    bytes:[]u8,
    placed:u64,
}

@(private)
Net_Source :: struct {
    id:base.Asset_Id,
    // client
    log:[dynamic]Net_Logged, // log[i] is the edit first+i
    first:u32,
    floor:u32, // the edits up to it were let go: one that arrives now is old
    newest:u32,
    pages:[dynamic]Net_Part_State, // pages[i] is the part first_page+i the client received
    first_page:u32,
    loaded:bool,
    missing:bool, // it cannot be read here: a whole base was asked for
    based:bool,   // a head applied since it loaded: it holds what the server wrote since its origin
    basing:bool,  // a base was asked for and has not ended: what differs until then, it brings
    covered:u32,  // the edits up to it are of the last base that ended: what they left, it brought
    ask,ask_base:bool,
    ask_origin:u64, // of the base asked for: terrain.terrain_origin when it was asked, 0 for every part
    ask_low,ask_high:[3]i32,
    asked:u64,  // tick + 1 of the last Net_Terrain_Resync
    gap:u64,    // tick + 1 the client first missed an edit, 0: none
    // server
    sequence:u32,
}

@(private)
Net_Ask_Held :: struct {
    connection:multiplayer.Connection,
    ask:Net_Terrain_Ask,
    refusal:Terrain_Refusal,
}

@(private)
Net_Rate :: struct {
    connection:multiplayer.Connection,
    tokens:f32,
    tick:u64,
}

// Server: the parts a connection asked for, sent in their order, each as
// many pieces as the budget of a tick lets.
@(private)
Net_Serve :: struct {
    connection:multiplayer.Connection,
    source:base.Asset_Id,
    low,high:[3]i32,
    base,whole:bool,
    origin,served_origin:u64, // of the source of the client, and of the server's as it started
    started:bool,
    part:Net_Part,
    grid:terrain.Grid_Kind,
    next:int,
    chunk:Net_Terrain_Page, // of the part being sent
    packed:[dynamic]u8,
    sending:bool,
    parts,bytes:int, // sent
}

@(private)
Net_Refused :: struct {
    refused:Net_Terrain_Refused,
    tick:u64, // tick + 1 it was handled at, 0 until then
}

Net_Stats :: struct {
    sent,received:u64, // edits
    absorbed:u64,      // client: predictions that stood as the server's edit
    refused:u64,       // server: asks refused; client: refusals heard
    desyncs:u64,       // client: edits after which a region differed from the server
    resyncs:u64,       // client: Net_Terrain_Resync sent
    pages_sent,pages_applied:u64, // parts: heads, pages and sections
    bytes_sent:u64,    // server: LZ bytes of parts
}

// What this library knows of the network: one for each World, never copied.
@(storage,host,by_world,free="net_free")
Terrain_Net :: struct {
    changes:u32, // the scene change of the world it is of (scene.Scene_Root)
    sources:[dynamic]Net_Source,
    asks:[dynamic]Net_Ask_Held,     // server: held until their tick
    applying:[dynamic]Net_Ask_Held, // server: pushed to terrain in this tick, by tag
    rates:[dynamic]Net_Rate,
    serves:[dynamic]Net_Serve,
    entered:[dynamic]multiplayer.Connection, // server: in its world, where what it sends reaches them
    refused:[dynamic]Net_Refused,   // client
    raw:[dynamic]u8,
    decoder:compressor.Decoder, // client: of the parts received
    encoder:lz.Encoder,    // server: of the parts sent
    stats:Net_Stats,
    launched:bool, // client of a session the player was launched with: it tells the person how it went
}

net_free :: proc(n:^Terrain_Net) {
    if n.launched {
        fmt.printfln("terrain: %d edits of the server came here, %d of them left another check and asked for their parts; %d parts applied",n.stats.received,n.stats.desyncs,n.stats.pages_applied)
    }
    net_forget(n)
    delete(n.sources);delete(n.asks);delete(n.applying);delete(n.rates);delete(n.serves);delete(n.entered);delete(n.refused)
    delete(n.raw)
    compressor.decoder_destroy(&n.decoder)
    lz.encoder_destroy(&n.encoder)
    n^={}
}

@(private)
source_free :: proc(src:^Net_Source) {
    for page in src.pages {delete(page.bytes)}
    delete(src.log);delete(src.pages)
}

@(private)
net_forget :: proc(n:^Terrain_Net) {
    for &src in n.sources {source_free(&src)}
    for &sv in n.serves {delete(sv.packed)}
    clear(&n.sources);clear(&n.asks);clear(&n.applying);clear(&n.rates);clear(&n.serves);clear(&n.entered);clear(&n.refused)
}

// What a person running a session reads: printed by a player launched on
// the network, as multiplayer prints, else in the log.
@(private)
tell :: proc(session:core.Ref(multiplayer.Net_Session),format:string,args:..any) {
    if session.ptr!=nil && session.launched {fmt.printfln(format,..args)} else {log.infof(format,..args)}
}

// A scene replaced the world: what this library knew was of the world before.
@(private)
net_world :: proc(n:^Terrain_Net,root:core.Ref(scene.Scene_Root)) {
    if root.ptr==nil || root.changes==n.changes {return}
    n.changes=root.changes
    net_forget(n)
}

@(private)
memory_problem :: proc(problems:^core.Problems) {
    core.report(problems,core.NONE,"terrain.net_memory","out of memory for what the server sends of a terrain; an edit or a part was left out, and the terrain may differ from the server's until its parts are sent again: free memory")
}

@(private)
net_source :: proc(n:^Terrain_Net,id:base.Asset_Id,create:bool) -> ^Net_Source {
    for &src in n.sources {if src.id==id {return &src}}
    if !create {return nil}
    if _,error:=append(&n.sources,Net_Source{id=id,first_page=1});error!=nil {return nil}
    return &n.sources[len(n.sources)-1]
}

@(private)
log_at :: proc(src:^Net_Source,sequence:u32) -> ^Net_Logged {
    if sequence<src.first || int(sequence-src.first)>=len(src.log) {return nil}
    logged:=&src.log[sequence-src.first]
    return logged.edit.sequence==sequence?logged:nil
}

@(private)
page_at :: proc(src:^Net_Source,number:u32) -> ^Net_Part_State {
    if number<src.first_page || int(number-src.first_page)>=len(src.pages) {return nil}
    return &src.pages[number-src.first_page]
}

@(private)
cursor_of :: proc(state:^Terrain_Net_World,id:base.Asset_Id) -> ^Net_Cursor {
    for &cursor in state.cursors[:state.cursor_count] {if cursor.source==id {return &cursor}}
    if int(state.cursor_count)>=NET_SOURCES {return nil}
    state.cursors[state.cursor_count]={source=id}
    state.cursor_count+=1
    return &state.cursors[state.cursor_count-1]
}

@(private)
prediction_find :: proc(state:^Terrain_Net_World,id:base.Asset_Id,tick:u32,index:u8) -> int {
    for p,i in state.predictions[:state.prediction_count] {if p.source==id && p.tick==tick && p.index==index {return i}}
    return -1
}

@(private)
prediction_remove :: proc(state:^Terrain_Net_World,i:int) {
    copy(state.predictions[i:state.prediction_count-1],state.predictions[i+1:state.prediction_count])
    state.prediction_count-=1
}

@(private)
boxes_overlap :: proc "contextless" (a_low,a_high,b_low,b_high:[3]i32,margin:i32) -> bool {
    if a_high.x<a_low.x || b_high.x<b_low.x {return false}
    for axis in 0..<3 {if a_low[axis]-margin>b_high[axis] || b_low[axis]-margin>a_high[axis] {return false}}
    return true
}

// A base of a source is asked for, with the origin of what it holds now
// when the parts of the server since it complete it: nothing written here
// since its file, or only what came of the server. What it applies until the
// base comes is of the server too.
@(private)
base_ask :: proc(src:^Net_Source,data:core.Ref(terrain.Terrain_Data),whole:=false) {
    if src.ask_base {
        if whole {src.ask_origin=0}
        return
    }
    src.ask_base,src.ask_origin=true,0
    if origin,clean,ok:=terrain.terrain_origin(data,src.id);ok && !whole && (clean || src.based) {src.ask_origin=origin}
}

// A region of a source differs from the server: its parts are asked for.
@(private)
region_differs :: proc(src:^Net_Source,low,high:[3]i32) {
    if high.x<low.x || src.basing {return}
    if !src.ask {src.ask_low,src.ask_high,src.ask=low,high,true;return}
    for axis in 0..<3 {src.ask_low[axis],src.ask_high[axis]=min(src.ask_low[axis],low[axis]),max(src.ask_high[axis],high[axis])}
}

// What arrived since the tick before. An edit of another for a tick already
// simulated, over one this client predicts, asks to go back, in the next
// frame. A tick that runs again took its messages the first time: what they
// left is outside the World.
@(step="fixed",loops="game",stage="begin")
terrain_net_receive :: proc(
    events:core.Ref(multiplayer.Net_Events),authority:core.Ref(core.Network),n:^Terrain_Net,state:core.Ref(Terrain_Net_World),session:core.Ref(multiplayer.Net_Session),
    time:core.Time,rewinds:^multiplayer.Net_Rewinds,root:core.Ref(scene.Scene_Root),settings:Terrain_Net_Settings,problems:^core.Problems,
) {
    if n==nil {return}
    net_world(n,root)
    if authority.ptr==nil || authority.role==.Standalone || time.resimulating {return}
    server:=authority.role==.Server
    own:=multiplayer.own_connection(session)
    for item in events.received.items {
        if edit,ok:=multiplayer.event_read(item,Net_Terrain_Edit);ok {
            if server || edit.sequence==0 {continue}
            src:=net_source(n,edit.source,true)
            put,enough:=false,false
            if src!=nil {put,enough=log_put(src,edit)}
            if !enough {memory_problem(problems)}
            if !put {continue}
            n.stats.received+=1
            if edit.asker!=own && i32(edit.tick-u32(time.tick))<0 && state.ptr!=nil {
                for p in state.predictions[:state.prediction_count] {
                    if p.source==edit.source && boxes_overlap(p.low,p.high,edit.low,edit.high,NET_READ_SAMPLES) {multiplayer.rewind(rewinds,edit.tick);break}
                }
            }
        } else if page,page_ok:=multiplayer.event_read(item,Net_Terrain_Page);page_ok {
            if !server {page_chunk(n,page,problems)}
        } else if refused,refused_ok:=multiplayer.event_read(item,Net_Terrain_Refused);refused_ok {
            if !server {append(&n.refused,Net_Refused{refused=refused});n.stats.refused+=1}
        } else if ask,ask_ok:=multiplayer.event_read(item,Net_Terrain_Ask);ask_ok {
            if server && item.sender!=0 {append(&n.asks,Net_Ask_Held{item.sender,ask,ask_admit(n,item.sender,ask,time,settings)})}
        } else if resync,resync_ok:=multiplayer.event_read(item,Net_Terrain_Resync);resync_ok {
            if server && item.sender!=0 {serve_add(n,item.sender,resync)}
        }
    }
}

@(private)
log_put :: proc(src:^Net_Source,edit:Net_Terrain_Edit) -> (put,enough:bool) {
    enough=true
    if len(src.log)==0 && src.first<=src.floor {src.first=edit.sequence}
    // One that arrives before an edit it came after goes in front, unless what was there was let go.
    if edit.sequence<src.first {
        if edit.sequence<=src.floor || len(src.log)+int(src.first-edit.sequence)>NET_LOG_MAX {return}
        if _,error:=inject_at(&src.log,0,..make([]Net_Logged,int(src.first-edit.sequence),context.temp_allocator));error!=nil {return false,false}
        src.first=edit.sequence
    }
    if int(edit.sequence-src.first)>=NET_LOG_MAX {return}
    at:=int(edit.sequence-src.first)
    if at>=len(src.log) && resize(&src.log,at+1)!=nil {return false,false}
    if src.log[at].edit.sequence==edit.sequence {return}
    src.log[at]=Net_Logged{edit=edit}
    src.newest=max(src.newest,edit.sequence)
    return true,true
}

// A piece of a part. The first starts it in the order of the stream, which
// waits for it until the rest is here.
@(private)
page_chunk :: proc(n:^Terrain_Net,chunk:Net_Terrain_Page,problems:^core.Problems) {
    src:=net_source(n,chunk.source,true)
    if src==nil {memory_problem(problems);return}
    if chunk.offset==0 {
        raw_max:=terrain.PAGE_BYTES_MAX
        switch chunk.part {
        case .Head:    raw_max=terrain.HEAD_BYTES
        case .Grid:
        case .Section: raw_max=NET_SECTION_BYTES_MAX
        case .End:     raw_max=0
        }
        state:=Net_Part_State{after=chunk.after,base=chunk.base,whole=chunk.whole,part=chunk.part,grid=chunk.grid,page=chunk.page,fill=chunk.fill,raw=chunk.raw,total=chunk.total}
        if chunk.part>max(Net_Part) || chunk.grid>max(terrain.Grid_Kind) || int(chunk.raw)>raw_max || int(chunk.total)>asset.pack_bound(int(chunk.raw)) {
            state.complete,state.broken=true,true
        } else {
            error:mem.Allocator_Error
            if state.bytes,error=make([]u8,int(chunk.total));error!=nil {state.complete,state.broken=true,true}
        }
        if _,err:=append(&src.pages,state);err!=nil {
            delete(state.bytes)
            memory_problem(problems)
            return
        }
    }
    if len(src.pages)==0 {return}
    a:=&src.pages[len(src.pages)-1]
    if a.complete {return}
    if chunk.after!=a.after || chunk.part!=a.part || chunk.page!=a.page || chunk.grid!=a.grid || chunk.total!=a.total || chunk.offset!=a.have || int(chunk.count)>NET_PAGE_BYTES || int(chunk.offset)+int(chunk.count)>int(a.total) {
        delete(a.bytes);a.bytes=nil
        a.complete,a.broken=true,true
        return
    }
    chunk:=chunk
    copy(a.bytes[chunk.offset:][:chunk.count],([^]u8)(&chunk.words)[:chunk.count])
    a.have+=u32(chunk.count)
    if a.have<a.total {return}
    a.complete=true
    packed:=a.bytes
    defer delete(packed)
    a.bytes=nil
    if a.raw==0 {return}
    values,error:=make([]u8,int(a.raw))
    if error!=nil {a.broken=true;return}
    if len(n.decoder.scratch)==0 && compressor.decoder_init(&n.decoder)!=.None {delete(values);a.broken=true;return}
    if asset.unpack(&n.decoder,packed,values)!=.None {delete(values);a.broken=true;return}
    a.bytes=values
}

// Server: what an ask can be told at once: its rate and its tick. Without
// memory to count the asks of a connection it is refused as Rate.
@(private)
ask_admit :: proc(n:^Terrain_Net,connection:multiplayer.Connection,ask:Net_Terrain_Ask,time:core.Time,settings:Terrain_Net_Settings) -> Terrain_Refusal {
    if i32(ask.tick-u32(time.tick))>NET_AHEAD_TICKS {return .Tick}
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

// Server: what an ask can be told at its tick, where its seat stands, and the replay it is.
@(private)
ask_check :: proc(ask:Net_Terrain_Ask,connection:multiplayer.Connection,data:core.Ref(terrain.Terrain_Data),terrains:core.Read(terrain.Terrain),seats:core.Read(input.Seat),drivables:core.Read(input.Drivable),worlds:core.Read(core.World_Transform),settings:Terrain_Net_Settings) -> (replay:terrain.Replay,refusal:Terrain_Refusal) {
    ask:=ask
    replay={kind=ask.kind,source=ask.source}
    ok:bool
    #partial switch ask.kind {
    case .Edit:
        if replay.brush,ok=terrain.brush_of_bytes(ask.body);!ok {return {},.Brush}
        if settings.radius>0 && replay.brush.radius>settings.radius {return {},.Radius}
    case .Layer:
        if replay.layer,ok=terrain.layer_change_of_bytes(ask.body[:]);!ok {return {},.Brush}
    case:
        return {},.Brush
    }
    if terrain.terrain_source(data,ask.source)==nil {return {},.Not_Loaded}
    seat:=core.NONE
    if seats.table!=nil {
        for value,row in seats.table.values[:core.count(seats)] {if multiplayer.Connection(value.peer)==connection {seat=core.entity_at(seats,row);break}}
    }
    if seat==core.NONE {return {},.Player}
    if settings.reach>0 && ask.kind==.Edit {
        at:=replay.brush.center
        if owner:=terrain.terrain_of_source(terrains,ask.source);owner!=core.NONE {
            if world,found:=core.get(worlds,owner);found {at=mm.transform_point(world.transform,at)}
        }
        near:=false
        if drivables.table!=nil {
            for value,row in drivables.table.values[:core.count(drivables)] {
                if value.seat!=seat {continue}
                world,found:=core.get(worlds,core.entity_at(drivables,row))
                if found {d:=world.position-at;if d.x*d.x+d.y*d.y+d.z*d.z<=settings.reach*settings.reach {near=true;break}}
            }
        }
        if !near {return {},.Reach}
    }
    return replay,.None
}

// What applies in this tick, before terrain does. Server: the asks whose tick
// came, or a refusal. Client: the stream of each source where it stands.
@(step="fixed",loops="game",stage="simulate")
terrain_net_follow :: proc(
    authority:core.Ref(core.Network),n:^Terrain_Net,state:^Terrain_Net_World,time:core.Time,replays:^terrain.Terrain_Replays,outbox:^multiplayer.Net_Outbox,
    session:core.Ref(multiplayer.Net_Session),data:core.Ref(terrain.Terrain_Data),terrains:core.Read(terrain.Terrain),
    seats:core.Read(input.Seat),drivables:core.Read(input.Drivable),worlds:core.Read(core.World_Transform),
    settings:Terrain_Net_Settings,root:core.Ref(scene.Scene_Root),assets:^host.Assets,problems:^core.Problems,
) {
    if n==nil {return}
    net_world(n,root)
    if authority.ptr==nil || authority.role==.Standalone {return}
    replays.routed=true
    if authority.role==.Server {
        clear(&n.applying)
        for i:=0;i<len(n.asks); {
            held:=n.asks[i]
            if held.refusal==.None && i32(held.ask.tick-u32(time.tick))>0 {i+=1;continue}
            ordered_remove(&n.asks,i)
            refusal:=held.refusal
            replay:terrain.Replay
            if refusal==.None {replay,refusal=ask_check(held.ask,held.connection,data,terrains,seats,drivables,worlds,settings)}
            if refusal!=.None {
                multiplayer.send(outbox,Net_Terrain_Refused{held.ask.source,held.ask.tick,held.ask.index,refusal,.None},core.NONE,held.connection)
                n.stats.refused+=1
                continue
            }
            replay.tag=u64(len(n.applying))
            core.push(&replays.items,replay)
            append(&n.applying,held)
        }
        return
    }
    replays.asked=true
    n.launched=session.ptr!=nil && session.launched
    own:=multiplayer.own_connection(session)
    refusals_take(n,state,time,terrains,problems)
    // A prediction the server never answered is given up.
    for i:=int(state.prediction_count)-1;i>=0;i-=1 {
        p:=state.predictions[i]
        if u64(p.tick)+NET_PREDICTION_TICKS>=time.tick {continue}
        if src:=net_source(n,p.source,true);src!=nil {region_differs(src,p.low,p.high)}
        prediction_remove(state,i)
    }
    // Every source a terrain shows here, or cannot read, follows its stream.
    if terrains.table!=nil {
        for marker in terrains.table.values[:core.count(terrains)] {
            if marker.source!={} && (terrain.terrain_source(data,marker.source)!=nil || terrain.terrain_unread(data,assets,marker.source)) {
                if net_source(n,marker.source,true)==nil {memory_problem(problems)}
            }
        }
    }
    for &src in n.sources {
        cursor:=cursor_of(state,src.id)
        if cursor==nil {
            core.report(problems,terrain.terrain_of_source(terrains,src.id),"terrain.net_sources","edits of more than %d terrain sources came over the network; those of this one are not applied: edit fewer sources in a session",NET_SOURCES)
            continue
        }
        if terrain.terrain_source(data,src.id)==nil {
            src.loaded,src.based=false,false
            // One it cannot read waits for the head of a whole base, which makes it.
            unread:=terrain.terrain_unread(data,assets,src.id)
            if !unread || !stream_skip_to_head(&src,cursor,time) {
                stream_skip(&src,cursor,time)
                if unread && !src.missing {src.missing=true;base_ask(&src,data,true)}
                resync_send(n,&src,time,outbox,session)
                continue
            }
        } else if !src.loaded {
            // What it holds as it loads is of its file: a base brings what the server wrote since.
            src.loaded,src.missing=true,false
            base_ask(&src,data)
        }
        stream_follow(n,&src,cursor,state,time,replays,own,data)
        resync_send(n,&src,time,outbox,session)
    }
}

// The stream of a source that is not loaded passes it by.
@(private)
stream_skip :: proc(src:^Net_Source,cursor:^Net_Cursor,time:core.Time) {
    for q in cursor.edits+1..=src.newest {
        if logged:=log_at(src,q);logged!=nil && logged.placed==0 {logged.placed=time.tick+1}
    }
    cursor.edits=max(cursor.edits,src.newest)
    for &page,i in src.pages {
        if src.first_page+u32(i)<=cursor.pages || !page.complete {continue}
        if page.placed==0 {page.placed=time.tick+1}
        cursor.edits=max(cursor.edits,page.after)
        cursor.pages=src.first_page+u32(i)
    }
}

// A source that cannot be read passes its stream by up to the head of a
// whole base that is here, and follows it from there; false without one.
@(private)
stream_skip_to_head :: proc(src:^Net_Source,cursor:^Net_Cursor,time:core.Time) -> bool {
    head:=-1
    for page,i in src.pages {
        if src.first_page+u32(i)>cursor.pages && page.part==.Head && page.whole && page.complete && !page.broken {head=i;break}
    }
    if head<0 {return false}
    for q in cursor.edits+1..=src.pages[head].after {
        if logged:=log_at(src,q);logged!=nil && logged.placed==0 {logged.placed=time.tick+1}
    }
    cursor.edits=max(cursor.edits,src.pages[head].after)
    for &page in src.pages[:head] {if page.placed==0 {page.placed=time.tick+1}}
    cursor.pages=max(cursor.pages,src.first_page+u32(head)-1)
    return true
}

@(private)
due :: proc(placed:^u64,tick:u32,wait:bool,time:core.Time) -> bool {
    if placed^!=0 {return time.tick+1>=placed^}
    if wait && i32(tick-u32(time.tick))>0 {return false}
    placed^=time.tick+1
    return true
}

// The edits and parts of a source in their order, while each is due.
@(private)
stream_follow :: proc(n:^Terrain_Net,src:^Net_Source,cursor:^Net_Cursor,state:^Terrain_Net_World,time:core.Time,replays:^terrain.Terrain_Replays,own:multiplayer.Connection,data:core.Ref(terrain.Terrain_Data)) {
    for {
        page:=page_at(src,cursor.pages+1)
        next:=cursor.edits+1
        logged:=log_at(src,next)
        if page!=nil && page.after<=cursor.edits {
            if !page.complete || !due(&page.placed,0,false,time) {return}
            if page.broken {
                src.basing=false
                base_ask(src,data)
            } else if page.part==.End {
                src.basing=false
                src.covered=max(src.covered,page.after)
            } else {
                replay:=terrain.Replay{source=src.id,tag=u64(cursor.pages+1),grid=page.grid,page=page.page,fill=page.fill,whole=page.whole,values=page.bytes}
                #partial switch page.part {
                case .Head:    replay.kind=.Head
                case .Grid:    replay.kind=.Page
                case .Section: replay.kind=.Section
                }
                core.push(&replays.items,replay)
            }
            cursor.pages+=1
            continue
        }
        if logged!=nil && (page==nil || next<=page.after) {
            edit:=&logged.edit
            mine:=edit.asker!=0 && edit.asker==own
            // The prediction of its tick is made after this, in that tick.
            if mine && time.tick<=u64(edit.ask_tick) {return}
            first:=logged.placed==0
            if !due(&logged.placed,edit.tick,true,time) {return}
            cursor.edits=next
            src.gap=0
            if at:=prediction_find(state,edit.source,edit.ask_tick,edit.ask_index);mine && edit.kind==.Edit && at>=0 {
                p:=state.predictions[at]
                prediction_remove(state,at)
                if first {
                    n.stats.absorbed+=1
                    if p.low!=edit.low || p.high!=edit.high || p.check!=edit.check {
                        n.stats.desyncs+=1
                        region_differs(src,p.low,p.high)
                        region_differs(src,edit.low,edit.high)
                    }
                }
                continue
            }
            replay:=terrain.Replay{kind=edit.kind,source=src.id,tag=u64(next),verify=true,low=edit.low,high=edit.high}
            valid:bool
            #partial switch edit.kind {
            case .Edit:  replay.brush,valid=terrain.brush_of_bytes(edit.body)
            case .Layer: replay.layer,valid=terrain.layer_change_of_bytes(edit.body[:])
            }
            if !valid {
                if first {base_ask(src,data)}
                continue
            }
            core.push(&replays.items,replay)
            continue
        }
        if page!=nil && page.base {
            // A base stands for every edit up to it.
            if !due(&page.placed,0,false,time) {return}
            for q in next..=page.after {if l:=log_at(src,q);l!=nil && l.placed==0 {l.placed=time.tick+1}}
            cursor.edits=page.after
            src.gap=0
            continue
        }
        // A missing edit: a base comes when the client entered or loaded the source; else it is asked for.
        if logged==nil && (src.newest>cursor.edits || page!=nil) && !time.resimulating {
            if src.gap==0 {src.gap=time.tick+1} else if time.tick+1-src.gap>=NET_ASK_TICKS {base_ask(src,data);src.gap=time.tick+1}
        }
        return
    }
}

// Client: the parts it asks for.
@(private)
resync_send :: proc(n:^Terrain_Net,src:^Net_Source,time:core.Time,outbox:^multiplayer.Net_Outbox,session:core.Ref(multiplayer.Net_Session)) {
    if !src.ask && !src.ask_base {return}
    if src.asked!=0 && time.tick+1-src.asked<NET_ASK_TICKS {return}
    if session.ptr!=nil && session.status!=.Connected {return}
    resync:=Net_Terrain_Resync{source=src.id,low=src.ask_low,high=src.ask_high,base=src.ask_base,origin=src.ask_origin}
    name:[base.ASSET_ID_TEXT]u8
    if src.ask {tell(session,"terrain: source %s differs from the server over %v..%v here: its parts are asked for",base.asset_id_format(src.id,name[:]),src.ask_low,src.ask_high)}
    if !multiplayer.send(outbox,resync) {return}
    src.asked=time.tick+1
    if src.ask_base {src.basing=true}
    src.ask,src.ask_base=false,false
    n.stats.resyncs+=1
}

// Client: what the server refused is a problem of the terrain it was for, and its parts are asked for.
@(private)
refusals_take :: proc(n:^Terrain_Net,state:^Terrain_Net_World,time:core.Time,terrains:core.Read(terrain.Terrain),problems:^core.Problems) {
    for &r in n.refused {
        refused:=r.refused
        at:=prediction_find(state,refused.source,refused.tick,refused.index)
        if at>=0 {
            if src:=net_source(n,refused.source,true);src!=nil {region_differs(src,state.predictions[at].low,state.predictions[at].high)}
            prediction_remove(state,at)
        }
        if r.tick!=0 {continue}
        r.tick=time.tick+1
        refusal_report(problems,terrain.terrain_of_source(terrains,refused.source),refused)
    }
}

@(private)
refusal_report :: proc(problems:^core.Problems,e:core.Entity,refused:Net_Terrain_Refused) {
    code:="terrain.net_refused"
    switch refused.reason {
    case .None:
    case .Rate:       core.report(problems,e,code,"the server refused an edit of this terrain: its client asked for more edits a second than Terrain_Net_Settings.rate of the server allows; ask for fewer, or raise it on the server")
    case .Player:     core.report(problems,e,code,"the server refused an edit of this terrain: the connection has no seat there yet; ask once the player is seated")
    case .Reach:      core.report(problems,e,code,"the server refused an edit of this terrain: its center is farther than Terrain_Net_Settings.reach of the server from every body the player drives; edit closer, or raise it on the server")
    case .Radius:     core.report(problems,e,code,"the server refused an edit of this terrain: its brush is larger than Terrain_Net_Settings.radius of the server; use a smaller radius, or raise it on the server")
    case .Brush:      core.report(problems,e,code,"the server refused an edit of this terrain: a field of its brush or layer change is not finite or not one of its values; give each field a valid value")
    case .Tick:       core.report(problems,e,code,"the server refused an edit of this terrain: it was asked for a tick more than %d ticks ahead of the server; the clock of the client is not the server's",NET_AHEAD_TICKS)
    case .Not_Loaded: core.report(problems,e,code,"the server refused an edit of this terrain: the server does not have its source loaded; edit where the server keeps its sections loaded")
    case .Edit:       core.report(problems,e,code,"the server refused an edit of this terrain: there it failed as %v; the problem terrain.edit_* or terrain.layer_* of the same request here says how to fix it",refused.error)
    }
}

// After physics. Server: each edit it applied goes to every client, and the
// parts to who asked. Client: each prediction is kept and asked for, a layer
// change asked for, and an edit of the server that left another check asks
// for its parts.
@(step="fixed",loops="game",stage="react")
terrain_net_send :: proc(
    authority:core.Ref(core.Network),n:^Terrain_Net,state:^Terrain_Net_World,time:core.Time,outbox:^multiplayer.Net_Outbox,
    connections:core.Ref(multiplayer.Net_Connections),replayed:core.Ref(terrain.Terrain_Replay_Events),data:core.Ref(terrain.Terrain_Data),
    session:core.Ref(multiplayer.Net_Session),root:core.Ref(scene.Scene_Root),
) {
    if n==nil {return}
    net_world(n,root)
    if authority.ptr==nil || authority.role==.Standalone {return}
    if authority.role==.Server {
        edits_send(n,time,outbox,replayed)
        if connections.ptr!=nil {
            for event in connections.events.items {
                at:=-1
                for c,i in n.entered {if c==event.connection {at=i;break}}
                if event.kind==.Entered && at<0 {append(&n.entered,event.connection)}
                if event.kind!=.Disconnected {continue}
                if at>=0 {unordered_remove(&n.entered,at)}
                for i:=len(n.serves)-1;i>=0;i-=1 {if n.serves[i].connection==event.connection {delete(n.serves[i].packed);ordered_remove(&n.serves,i)}}
            }
        }
        serves_run(n,data,time,outbox,session)
        return
    }
    index:=0
    if replayed.ptr!=nil {
        for r in replayed.results.items {
            if r.request {
                key:=index
                index+=1
                if r.error!=.None || key>int(max(u8)) || refused_has(n,r.source,u32(time.tick),u8(key)) {continue}
                ask:=Net_Terrain_Ask{source=r.source,tick=u32(time.tick),index=u8(key),kind=r.kind}
                if r.kind==.Layer {
                    body:=terrain.layer_change_bytes(r.layer)
                    copy(ask.body[:],body[:])
                } else {
                    ask.body=terrain.brush_bytes(r.brush)
                    prediction_keep(n,state,Net_Prediction{r.source,u32(time.tick),u8(key),r.low,r.high,r.check})
                }
                multiplayer.send(outbox,ask)
                continue
            }
            src:=net_source(n,r.source,false)
            if src==nil {continue}
            switch r.kind {
            case .Page,.Section:
                if r.error==.None {n.stats.pages_applied+=1}
            case .Head:
                if r.error==.None {
                    n.stats.pages_applied+=1
                    src.based,src.loaded=true,true
                    if page:=page_at(src,u32(r.tag));page!=nil && !page.told {
                        page.told=true
                        name:[base.ASSET_ID_TEXT]u8
                        tell(session,"terrain: a base of source %s came from the server, %s",base.asset_id_format(src.id,name[:]),page.whole?"with every part":"with the parts written since its file")
                    }
                } else if page:=page_at(src,u32(r.tag));page!=nil && !page.whole {
                    // A head of another shape than the source here: every part is asked for.
                    name:[base.ASSET_ID_TEXT]u8
                    tell(session,"terrain: a base of source %s did not apply here (%v, %s): every part is asked for",base.asset_id_format(src.id,name[:]),r.error,r.loaded?"loaded":"not loaded")
                    src.basing=false
                    base_ask(src,data,true)
                }
            case .Edit,.Layer:
                logged:=log_at(src,u32(r.tag))
                if logged==nil || logged.verified {continue}
                logged.verified=true
                if r.error==.None && r.check==logged.edit.check || src.basing || u32(r.tag)<=src.covered {continue}
                n.stats.desyncs+=1
                // Layers that differ are of a source that missed a base.
                if r.kind==.Layer {
                    if !src.basing {base_ask(src,data)}
                } else {
                    region_differs(src,logged.edit.low,logged.edit.high)
                }
            }
        }
    }
    if !time.resimulating {net_prune(n,time,session)}
}

@(private)
refused_has :: proc(n:^Terrain_Net,id:base.Asset_Id,tick:u32,index:u8) -> bool {
    for r in n.refused {if r.refused.source==id && r.refused.tick==tick && r.refused.index==index {return true}}
    return false
}

@(private)
prediction_keep :: proc(n:^Terrain_Net,state:^Terrain_Net_World,p:Net_Prediction) {
    if int(state.prediction_count)>=NET_PREDICTIONS {
        // The oldest gives way: when its edit comes back it applies again, and its parts are asked for.
        old:=state.predictions[0]
        if src:=net_source(n,old.source,true);src!=nil {region_differs(src,old.low,old.high)}
        prediction_remove(state,0)
    }
    state.predictions[state.prediction_count]=p
    state.prediction_count+=1
}

// Client: what no correction can go back to any more.
@(private)
net_prune :: proc(n:^Terrain_Net,time:core.Time,session:core.Ref(multiplayer.Net_Session)) {
    keep:=u64(NET_KEEP_TICKS)
    keep=max(keep,u64(multiplayer.session_history(session)))
    keep+=2
    old :: proc(placed,tick,keep:u64) -> bool {return placed!=0 && placed+keep<tick+1}
    for &src in n.sources {
        // An edit that never came goes with the one after it, which a base passed over.
        drop:=0
        for drop<len(src.log) {
            at:=drop
            for at<len(src.log) && src.log[at].edit.sequence==0 {at+=1}
            if at>=len(src.log) || !old(src.log[at].placed,time.tick,keep) {break}
            drop=at+1
        }
        if drop>0 {
            remove_range(&src.log,0,drop)
            src.first+=u32(drop)
            src.floor=src.first-1
        }
        pages:=0
        for pages<len(src.pages) && old(src.pages[pages].placed,time.tick,keep) {delete(src.pages[pages].bytes);pages+=1}
        if pages>0 {
            remove_range(&src.pages,0,pages)
            src.first_page+=u32(pages)
        }
    }
    for i:=len(n.refused)-1;i>=0;i-=1 {
        if n.refused[i].tick!=0 && n.refused[i].tick+keep+NET_PREDICTION_TICKS<time.tick+1 {unordered_remove(&n.refused,i)}
    }
}

// Server: the edits and layer changes terrain applied in this tick, in its order.
@(private)
edits_send :: proc(n:^Terrain_Net,time:core.Time,outbox:^multiplayer.Net_Outbox,replayed:core.Ref(terrain.Terrain_Replay_Events)) {
    defer clear(&n.applying)
    if replayed.ptr==nil {return}
    for r in replayed.results.items {
        if r.kind!=.Edit && r.kind!=.Layer {continue}
        edit:=Net_Terrain_Edit{source=r.source,tick=u32(time.tick),kind=r.kind,low=r.low,high=r.high,check=r.check}
        if r.kind==.Layer {
            body:=terrain.layer_change_bytes(r.layer)
            copy(edit.body[:],body[:])
        } else {
            edit.body=terrain.brush_bytes(r.brush)
        }
        if !r.request {
            if r.tag>=u64(len(n.applying)) {continue}
            held:=n.applying[r.tag]
            if r.error!=.None {
                reason:=r.loaded?Terrain_Refusal.Edit:Terrain_Refusal.Not_Loaded
                multiplayer.send(outbox,Net_Terrain_Refused{held.ask.source,held.ask.tick,held.ask.index,reason,r.error},core.NONE,held.connection)
                n.stats.refused+=1
                continue
            }
            edit.asker,edit.ask_tick,edit.ask_index=held.connection,held.ask.tick,held.ask.index
        } else if r.error!=.None || !r.changed {
            continue
        }
        src:=net_source(n,r.source,true)
        if src==nil {continue}
        src.sequence+=1
        edit.sequence=src.sequence
        if multiplayer.send(outbox,edit) {n.stats.sent+=1}
    }
}

// Server: one serve of a connection and a source waits at a time, which
// takes in the regions and the base asked for.
@(private)
serve_add :: proc(n:^Terrain_Net,connection:multiplayer.Connection,resync:Net_Terrain_Resync) {
    for &sv in n.serves {
        if sv.connection!=connection || sv.source!=resync.source || sv.started {continue}
        if resync.base {
            if !sv.base {sv.origin=resync.origin} else if sv.origin!=resync.origin {sv.origin=0}
            sv.base=true
        }
        if resync.high.x<resync.low.x {return}
        if sv.high.x<sv.low.x {sv.low,sv.high=resync.low,resync.high;return}
        for axis in 0..<3 {sv.low[axis],sv.high[axis]=min(sv.low[axis],resync.low[axis]),max(sv.high[axis],resync.high[axis])}
        return
    }
    if !resync.base && resync.high.x<resync.low.x {return}
    append(&n.serves,Net_Serve{connection=connection,source=resync.source,low=resync.low,high=resync.high,base=resync.base,origin=resync.origin})
}

// Server: the next part a serve sends, at or after next of its kind: those
// over its region and, of a base, every part when whole, else those written
// since its origin.
@(private)
serve_next :: proc(sv:^Net_Serve,data:core.Ref(terrain.Terrain_Data)) -> (index:int,found:bool) {
    section:=sv.part==.Section
    parts :: proc(sv:^Net_Serve,data:core.Ref(terrain.Terrain_Data),low,high:[3]i32) -> (from,to,counts:[3]int,ok:bool) {
        if sv.part==.Section {return terrain.terrain_sections(data,sv.source,low,high)}
        return terrain.terrain_grid_pages(data,sv.source,sv.grid,low,high)
    }
    region_from,region_to,_,region:=parts(sv,data,sv.low,sv.high)
    region=region && sv.high.x>=sv.low.x
    from,to,counts,ok:=region_from,region_to,[3]int{},region
    if sv.base {from,to,counts,ok=parts(sv,data,{},{-1,-1,-1})} else if region {_,_,counts,_=parts(sv,data,sv.low,sv.high)}
    if !ok {return}
    for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {
        p:=px+counts.x*(py+counts.y*pz)
        if p<sv.next {continue}
        inside:=region && px>=region_from.x && py>=region_from.y && pz>=region_from.z && px<=region_to.x && py<=region_to.y && pz<=region_to.z
        if !sv.base || sv.whole || inside || terrain.terrain_altered(data,sv.source,sv.grid,p,section) {return p,true}
    }}}
    return
}

// Server: the next part of a serve, packed; false when none is left.
@(private)
serve_pack :: proc(n:^Terrain_Net,sv:^Net_Serve,src:^Net_Source,data:core.Ref(terrain.Terrain_Data)) -> bool {
    chunk:=Net_Terrain_Page{source=sv.source,after=src.sequence,base=sv.base}
    if !sv.started {
        sv.started=true
        sv.part=.Grid
        if sv.base {
            sv.served_origin,_,_=terrain.terrain_origin(data,sv.source)
            sv.whole=sv.origin==0 || sv.served_origin==0 || sv.origin!=sv.served_origin
            if resize(&n.raw,terrain.HEAD_BYTES)!=nil || !terrain.terrain_head_bytes(data,sv.source,n.raw[:]) {return false}
            chunk.part,chunk.whole,chunk.raw=.Head,sv.whole,u32(terrain.HEAD_BYTES)
            return serve_packed(n,sv,chunk)
        }
    }
    for sv.part!=.Head && sv.part!=.End {
        index,found:=serve_next(sv,data)
        if !found {
            if sv.part==.Section {
                // The end of a base says the client holds all of it.
                if !sv.base {return false}
                sv.part=.End
                chunk.part,chunk.whole=.End,sv.whole
                return serve_packed(n,sv,chunk)
            }
            if sv.grid==max(terrain.Grid_Kind) {sv.part=.Section} else {sv.grid=terrain.Grid_Kind(int(sv.grid)+1)}
            sv.next=0
            continue
        }
        sv.next=index+1
        chunk.part,chunk.grid,chunk.page,chunk.whole=sv.part,sv.grid,u32(index),sv.whole
        if sv.part==.Section {
            if !terrain.terrain_section_bytes(data,sv.source,index,&n.raw) {continue}
            chunk.raw=u32(len(n.raw))
        } else {
            if resize(&n.raw,terrain.PAGE_BYTES_MAX)!=nil {return false}
            size,fill,read:=terrain.terrain_page_bytes(data,sv.source,sv.grid,index,n.raw[:])
            if !read {continue}
            chunk.raw,chunk.fill=u32(size),fill
        }
        return serve_packed(n,sv,chunk)
    }
    return false
}

// Server: the raw bytes of a part, in LZ, ready to go in pieces.
@(private)
serve_packed :: proc(n:^Terrain_Net,sv:^Net_Serve,chunk:Net_Terrain_Page) -> bool {
    sv.chunk=chunk
    raw:=int(chunk.raw)
    if resize(&sv.packed,asset.pack_bound(raw))!=nil {return false}
    total:=0
    if raw>0 {
        error:asset.Error
        if total,error=asset.pack(&n.encoder,asset.PACK_EDIT,n.raw[:raw],sv.packed[:]);error!=.None {return false}
    }
    base.truncate(&sv.packed,total)
    sv.chunk.total,sv.chunk.offset=u32(total),0
    sv.sending=true
    return true
}

// Server: the parts asked for, NET_STATE_BUDGET bytes a tick, to the
// connections in its world, of the sources it has loaded.
@(private)
serves_run :: proc(n:^Terrain_Net,data:core.Ref(terrain.Terrain_Data),time:core.Time,outbox:^multiplayer.Net_Outbox,session:core.Ref(multiplayer.Net_Session)) {
    budget:=NET_STATE_BUDGET
    for i:=0;i<len(n.serves) && budget>0; {
        sv:=&n.serves[i]
        entered:=false
        for c in n.entered {if c==sv.connection {entered=true;break}}
        if !entered || terrain.terrain_source(data,sv.source)==nil {i+=1;continue}
        src:=net_source(n,sv.source,true)
        if src==nil {i+=1;continue}
        if !sv.sending && !serve_pack(n,sv,src,data) {
            name:[base.ASSET_ID_TEXT]u8
            how:=""
            if sv.base {how=sv.whole?fmt.tprintf(" as a base of every part: its origin there %016x, here %016x",sv.origin,sv.served_origin):" as a base of what was written since its origin"}
            tell(session,"terrain: %d parts of source %s (%d LZ bytes) went to connection %d%s",sv.parts,base.asset_id_format(sv.source,name[:]),sv.bytes,sv.connection,how)
            delete(sv.packed)
            ordered_remove(&n.serves,i)
            continue
        }
        for budget>0 {
            count:=min(int(sv.chunk.total)-int(sv.chunk.offset),NET_PAGE_BYTES)
            chunk:=sv.chunk
            chunk.count=u16(count)
            copy(([^]u8)(&chunk.words)[:count],sv.packed[chunk.offset:][:count])
            if !multiplayer.send(outbox,chunk,core.NONE,sv.connection) {return}
            budget-=count+64
            n.stats.bytes_sent+=u64(count)
            sv.bytes+=count
            sv.chunk.offset+=u32(count)
            if sv.chunk.offset>=sv.chunk.total {
                sv.sending=false
                sv.parts+=1
                n.stats.pages_sent+=1
                break
            }
        }
    }
}
