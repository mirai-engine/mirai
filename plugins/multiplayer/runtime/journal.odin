package multiplayer

import "core:mem"
import "mirai:asset"
import "mirai:core"
import "mirai:engine/scene"
import "mirai:std/compressor"
import "mirai:std/compressor/lz"

// A replicated operation journal: what a library that changes by operations
// something both ends hold (a fracture, a dig) keeps in a host storage of its
// own, one for each World, to network them. The library gives the bytes of
// each operation and applies what the journal hands it; the journal does the
// rest. The server numbers the operations of each key (what one is about: the
// Id of an entity, a source asset) and sends them to every client, which
// applies them in that order at the tick the server applied them.
//
// Each entry a client applied keeps the tick it was first applied at: a
// correction that brings the World back finds the key as it was then and the
// entries are handed again at those same ticks, never twice. One that arrives
// for a tick already simulated asks to go back to it (rewind). One the game
// of the client asked is a prediction: applied there at once and asked of the
// server, which holds it until its tick and applies it, numbered as any
// other, or refuses it.
//
// What a client cannot follow (a check that differs, a missing operation, a
// refused prediction) asks for the parts of the key: bytes the library writes
// on the server, in LZ, sent within JOURNAL_BUDGET bytes a tick and applied
// in their place among the operations. A base stands for every operation up
// to it. A scene that replaces the world forgets what the journal knew.

JOURNAL_BODY :: 168
JOURNAL_PIECE :: 192
JOURNAL_PART_BYTES :: 4<<20 // raw bytes of a part at most
JOURNAL_BUDGET :: 4096      // bytes of parts a server sends a tick
JOURNAL_ASK_TICKS :: 30     // a client asks for parts again after this long, and for a base after a gap this long
JOURNAL_AHEAD_TICKS :: 240  // server: an ask for a tick further ahead than this is let out at once (Journal_Held.ahead)
JOURNAL_LOG :: 4096         // operations of a key a client holds ahead of where it stands
JOURNAL_KEEP_TICKS :: 32    // a client keeps what it applied this long at least, for the corrections that go back
JOURNAL_PREDICTIONS :: 128
JOURNAL_PREDICTION_TICKS :: 600 // a prediction the server never answered is given up, and its region asked for

Journal_Key :: distinct [2]u64

// An operation as it travels. The library gives key, check, low, high and
// body; the journal numbers it.
Journal_Op :: struct {
    key:Journal_Key,
    sequence:u32,     // of its key, from 1
    tick:u32,         // of the server, when it applied it
    check:u64,        // of what the key holds over low..high after it on the server; 0: none
    low,high:[3]i32,  // what it changed; high.x<low.x: the key as a whole, whose check that differs asks for a base
    asker:Connection, // the client whose game asked for it; 0: the server's own
    ask_tick:u32,
    ask_index:u8,
    body:[JOURNAL_BODY]u8,
}

@(net_message,reliable)
Net_Journal_Op :: struct {
    journal:u32,
    using op:Journal_Op,
}

// A piece of a part of a key: total bytes of LZ of raw bytes, written by the
// server once it had applied after operations of the key.
@(net_message,reliable)
Net_Journal_Part :: struct {
    journal:u32,
    key:Journal_Key,
    after:u32,
    first,last:bool, // of the parts of one answer
    base:bool,       // the answer stands for every operation up to after
    whole:bool,      // the answer holds all of the key, not only what changed since the since of the client
    raw,total,offset:u32,
    count:u16,
    bytes:[JOURNAL_PIECE]u8,
}

// A client: the parts of a key over low..high, or a base of it. since: what
// it holds, in the terms of the library; 0: it needs every part.
@(net_message,from="client",reliable)
Net_Journal_Resync :: struct {
    journal:u32,
    key:Journal_Key,
    low,high:[3]i32,
    base:bool,
    since:u64,
}

// A client: an operation its game asked for at tick, index-th of its asks of the tick.
@(net_message,from="client",reliable)
Net_Journal_Ask :: struct {
    journal:u32,
    key:Journal_Key,
    tick:u32,
    index:u8,
    body:[JOURNAL_BODY]u8,
}

// The server: why it did not apply an ask, in the terms of the library.
@(net_message,reliable)
Net_Journal_Refused :: struct {
    journal:u32,
    key:Journal_Key,
    tick:u32,
    index:u8,
    reason:u8,
    error:u8,
}

// A part a client received, or is receiving: its LZ bytes until they are all
// here, then its raw bytes.
Journal_Part :: struct {
    after:u32,
    first,last,base,whole:bool,
    raw,total,have:u32,
    complete,broken:bool,
    bytes:[]u8,
    placed,done:u64, // the tick + 1 it was first handed at and that it was done at; 0 until then
    skipped:bool,
}

// What the library applies now: an operation or a part of the key. It names
// tag in what it applies and gives it back to journal_result.
Journal_Due :: struct {
    tag:u64,
    op:^Journal_Op,
    part:^Journal_Part,
}

Journal_Result :: enum u8 {
    Done,
    Again,  // it waits: hand it again in the next tick
    Failed, // it does not apply here
}

// Server: an ask of a client, held until its tick. ahead: for a tick further
// ahead than JOURNAL_AHEAD_TICKS, let out at once to be refused.
Journal_Held :: struct {
    connection:Connection,
    ask:Net_Journal_Ask,
    ahead:bool,
}

// Server: the parts a connection asked for of a key, or that the server
// offers it, sent in their order, each in as many pieces as the budget of a
// tick lets. The library reads what to write and keeps where it is in cursor.
Journal_Serve :: struct {
    connection:Connection,
    key:Journal_Key,
    low,high:[3]i32,
    base,whole:bool,
    since:u64,
    started:bool,
    cursor:[4]u64,
    parts,bytes:int, // sent
    piece:Net_Journal_Part,
    packed:[dynamic]u8,
    sending,ended,offered:bool,
}

// Client: an operation of its game it applied before the server answered.
@(private)
Journal_Prediction :: struct {
    key:Journal_Key,
    tick:u32,
    index:u8,
    low,high:[3]i32,
    check:u64,
}

@(private)
Journal_Entry :: struct {
    op:Journal_Op, // sequence 0: not received
    placed,done:u64,
    skipped,absorbed,verified:bool,
}

@(private)
Journal_Stream :: struct {
    key:Journal_Key,
    // client
    log:[dynamic]Journal_Entry, // log[i] is the operation first+i
    first:u32,
    floor:u32,                  // the operations up to it are in every World a correction can bring back
    newest:u32,
    parts:[dynamic]Journal_Part, // parts[i] is the part first_part+i received
    first_part:u32,
    since:u64,                  // of the last base the library asked for
    basing:bool,                // a base was asked for and has not ended: what differs until then, it brings
    covered:u32,                // the operations up to it are of the last base that ended
    ask,ask_base:bool,
    ask_since:u64,
    ask_low,ask_high:[3]i32,
    asked:u64,                  // tick + 1 of the last Net_Journal_Resync
    gap:u64,                    // tick + 1 the client first missed an operation; 0: none
    // server
    sequence:u32,
}

@(private)
Journal_Applying :: struct {
    key:Journal_Key,
    number:u32, // of the operation, or of the part
    part:bool,
    held:Journal_Held, // of an ask
}

@(private)
Journal_Refusal :: struct {
    refused:Net_Journal_Refused,
    tick:u64, // tick + 1 it was told at; 0 until then
}

Journal_Stats :: struct {
    sent,received:u64, // operations
    absorbed:u64,      // client: predictions that stood as the server's operation
    refused:u64,       // server: asks refused; client: refusals heard
    desyncs:u64,       // client: operations after which a key differed from the server
    resyncs:u64,       // client: Net_Journal_Resync sent
    parts_sent,parts_applied:u64,
    bytes_sent:u64,    // server: LZ bytes of parts
}

Journal :: struct {
    id:u32,
    changes:u32, // the scene change of the world it is of (scene.Scene_Root)
    streams:[dynamic]Journal_Stream,
    held:[dynamic]Journal_Held,           // server
    serves:[dynamic]Journal_Serve,        // server
    entered:[dynamic]Connection,          // server: in its world, where what it sends reaches them
    predictions:[dynamic]Journal_Prediction, // client
    refused:[dynamic]Journal_Refusal,     // client
    applying:[dynamic]Journal_Applying,   // what the library applies in this tick, by tag
    applying_tick:u64,
    serving,budget:int,
    served_tick:u64,
    raw:[dynamic]u8,
    decoder:compressor.Decoder, // client: of the parts received
    encoder:lz.Encoder,         // server: of the parts sent
    stats:Journal_Stats,
}

journal_free :: proc(j:^Journal) {
    journal_forget(j)
    delete(j.streams);delete(j.held);delete(j.serves);delete(j.entered);delete(j.predictions);delete(j.refused);delete(j.applying);delete(j.raw)
    compressor.decoder_destroy(&j.decoder)
    lz.encoder_destroy(&j.encoder)
    j^={}
}

@(private)
journal_forget :: proc(j:^Journal) {
    for &s in j.streams {
        for part in s.parts {delete(part.bytes)}
        delete(s.log);delete(s.parts)
    }
    for &sv in j.serves {delete(sv.packed)}
    clear(&j.streams);clear(&j.held);clear(&j.serves);clear(&j.entered);clear(&j.predictions);clear(&j.refused);clear(&j.applying)
}

// At the start of each function of the library that uses the journal: which
// journal it is, and a scene that replaced the world forgets what it knew.
journal_world :: proc(j:^Journal,id:u32,root:core.Ref(scene.Scene_Root)) {
    j.id=id
    if root.ptr==nil || root.changes==j.changes {return}
    j.changes=root.changes
    journal_forget(j)
}

@(private)
journal_memory :: proc(problems:^core.Problems) {
    core.report(problems,core.NONE,"multiplayer.journal_memory","out of memory for what the server sends of a journal; an operation or a part was left out and is asked for again, and what it is about may differ from the server until then: free memory")
}

@(private)
journal_stream :: proc(j:^Journal,key:Journal_Key,create:bool) -> ^Journal_Stream {
    for &s in j.streams {if s.key==key {return &s}}
    if !create {return nil}
    if _,error:=append(&j.streams,Journal_Stream{key=key,first_part=1});error!=nil {return nil}
    return &j.streams[len(j.streams)-1]
}

@(private)
entry_at :: proc(s:^Journal_Stream,sequence:u32) -> ^Journal_Entry {
    if sequence<s.first || int(sequence-s.first)>=len(s.log) {return nil}
    entry:=&s.log[sequence-s.first]
    return entry.op.sequence==sequence?entry:nil
}

@(private)
part_at :: proc(s:^Journal_Stream,number:u32) -> ^Journal_Part {
    if number<s.first_part || int(number-s.first_part)>=len(s.parts) {return nil}
    return &s.parts[number-s.first_part]
}

@(private)
boxes_overlap :: proc "contextless" (a_low,a_high,b_low,b_high:[3]i32,margin:i32) -> bool {
    if a_high.x<a_low.x || b_high.x<b_low.x {return false}
    for axis in 0..<3 {if a_low[axis]-margin>b_high[axis] || b_low[axis]-margin>a_high[axis] {return false}}
    return true
}

// A region of a key differs from the server: its parts are asked for.
@(private)
region_differs :: proc(s:^Journal_Stream,low,high:[3]i32) {
    if high.x<low.x || s.basing {return}
    if !s.ask {s.ask_low,s.ask_high,s.ask=low,high,true;return}
    for axis in 0..<3 {s.ask_low[axis],s.ask_high[axis]=min(s.ask_low[axis],low[axis]),max(s.ask_high[axis],high[axis])}
}

// A base of a key is asked for: of what changed since the since the library
// last gave, or of every part.
@(private)
base_ask :: proc(s:^Journal_Stream,whole:bool) {
    if s.ask_base {
        if whole {s.ask_since=0}
        return
    }
    s.ask_base,s.ask_since=true,whole?0:s.since
}

@(private)
prediction_find :: proc(j:^Journal,key:Journal_Key,tick:u32,index:u8) -> int {
    for p,i in j.predictions {if p.key==key && p.tick==tick && p.index==index {return i}}
    return -1
}

@(private)
refused_has :: proc(j:^Journal,key:Journal_Key,tick:u32,index:u8) -> bool {
    for r in j.refused {if r.refused.key==key && r.refused.tick==tick && r.refused.index==index {return true}}
    return false
}

// What arrived for the journal since the tick before, at the start of a tick.
// Client: an operation of a tick already simulated asks to go back to it,
// every one when rewind_all, otherwise one over what the client predicts
// within margin. A tick that runs again took its messages the first time.
journal_receive :: proc(j:^Journal,events:core.Ref(Net_Events),server:bool,own:Connection,time:core.Time,rewinds:^Net_Rewinds,rewind_all:bool,margin:i32,problems:^core.Problems) {
    if events.ptr==nil || time.resimulating {return}
    for item in events.received.items {
        if op,ok:=event_read(item,Net_Journal_Op);ok && op.journal==j.id {
            if server || op.sequence==0 {continue}
            s:=journal_stream(j,op.key,true)
            put,enough:=false,false
            if s!=nil {put,enough=log_put(s,op.op)}
            if !enough {journal_memory(problems)}
            if !put {continue}
            j.stats.received+=1
            if op.asker==own && own!=0 || i32(op.tick-u32(time.tick))>=0 {continue}
            late:=rewind_all
            for p in j.predictions {late ||= p.key==op.key && boxes_overlap(p.low,p.high,op.low,op.high,margin)}
            if late {rewind(rewinds,op.tick)}
        } else if piece,piece_ok:=event_read(item,Net_Journal_Part);piece_ok && piece.journal==j.id {
            if !server {part_piece(j,piece,problems)}
        } else if refused,refused_ok:=event_read(item,Net_Journal_Refused);refused_ok && refused.journal==j.id {
            if server {continue}
            if _,error:=append(&j.refused,Journal_Refusal{refused=refused});error!=nil {journal_memory(problems)}
            j.stats.refused+=1
        } else if ask,ask_ok:=event_read(item,Net_Journal_Ask);ask_ok && ask.journal==j.id {
            if !server || item.sender==0 {continue}
            if _,error:=append(&j.held,Journal_Held{item.sender,ask,i32(ask.tick-u32(time.tick))>JOURNAL_AHEAD_TICKS});error!=nil {journal_memory(problems)}
        } else if resync,resync_ok:=event_read(item,Net_Journal_Resync);resync_ok && resync.journal==j.id {
            if server && item.sender!=0 {journal_offer(j,item.sender,resync.key,resync.base,resync.since,resync.low,resync.high)}
        }
    }
}

@(private)
log_put :: proc(s:^Journal_Stream,op:Journal_Op) -> (put,enough:bool) {
    enough=true
    if op.sequence<=s.floor {return}
    if len(s.log)==0 {s.first=op.sequence}
    // One that arrives before an operation it came after goes in front.
    if op.sequence<s.first {
        if len(s.log)+int(s.first-op.sequence)>JOURNAL_LOG {return}
        if _,error:=inject_at(&s.log,0,..make([]Journal_Entry,int(s.first-op.sequence),context.temp_allocator));error!=nil {return false,false}
        s.first=op.sequence
    }
    at:=int(op.sequence-s.first)
    if at>=JOURNAL_LOG {return}
    if at>=len(s.log) && resize(&s.log,at+1)!=nil {return false,false}
    if s.log[at].op.sequence==op.sequence {return}
    s.log[at]=Journal_Entry{op=op}
    s.newest=max(s.newest,op.sequence)
    return true,true
}

// A piece of a part. The first starts the part in the order of its key,
// which waits for it until the rest is here.
@(private)
part_piece :: proc(j:^Journal,piece:Net_Journal_Part,problems:^core.Problems) {
    s:=journal_stream(j,piece.key,true)
    if s==nil {journal_memory(problems);return}
    if piece.offset==0 {
        part:=Journal_Part{after=piece.after,first=piece.first,last=piece.last,base=piece.base,whole=piece.whole,raw=piece.raw,total=piece.total}
        if piece.raw>JOURNAL_PART_BYTES || int(piece.total)>asset.pack_bound(int(piece.raw)) {
            part.complete,part.broken=true,true
        } else {
            error:mem.Allocator_Error
            if part.bytes,error=make([]u8,int(piece.total));error!=nil {part.complete,part.broken=true,true}
        }
        if _,error:=append(&s.parts,part);error!=nil {
            delete(part.bytes)
            journal_memory(problems)
            return
        }
    }
    if len(s.parts)==0 {return}
    a:=&s.parts[len(s.parts)-1]
    if a.complete {return}
    if piece.after!=a.after || piece.total!=a.total || piece.offset!=a.have || int(piece.count)>JOURNAL_PIECE || int(piece.offset)+int(piece.count)>int(a.total) {
        delete(a.bytes);a.bytes=nil
        a.complete,a.broken=true,true
        return
    }
    piece:=piece
    copy(a.bytes[piece.offset:][:piece.count],piece.bytes[:piece.count])
    a.have+=u32(piece.count)
    if a.have<a.total {return}
    a.complete=true
    packed:=a.bytes
    defer delete(packed)
    a.bytes=nil
    if a.raw==0 {return}
    values,error:=make([]u8,int(a.raw))
    if error!=nil {a.broken=true;journal_memory(problems);return}
    if len(j.decoder.scratch)==0 && compressor.decoder_init(&j.decoder)!=.None {delete(values);a.broken=true;return}
    if asset.unpack(&j.decoder,packed,values)!=.None {delete(values);a.broken=true;return}
    a.bytes=values
}

// Where an entry stands at the tick now - 1: not handed yet, of a later tick
// of this timeline, in the World already, or to hand now.
@(private)
Entry_State :: enum u8 {New,Later,Done,Hand}

@(private)
entry_state :: proc "contextless" (placed,done,now:u64) -> Entry_State {
    if placed==0 {return .New}
    if placed>now {return .Later}
    if done!=0 && done<now {return .Done}
    return .Hand
}

@(private)
applying_tag :: proc(j:^Journal,a:Journal_Applying,time:core.Time) -> u64 {
    if j.applying_tick!=time.tick+1 {clear(&j.applying);j.applying_tick=time.tick+1}
    append(&j.applying,a)
    return u64(len(j.applying)-1)
}

// Client: what of a key applies in this tick, in its order: the operations
// whose tick came and the parts in their place among them, and what the
// ticks before handed that a correction brought back. A prediction of own
// stands for its operation, which is not handed.
journal_due :: proc(j:^Journal,key:Journal_Key,time:core.Time,own:Connection) -> []Journal_Due {
    s:=journal_stream(j,key,false)
    if s==nil {return nil}
    due:=make([dynamic]Journal_Due,context.temp_allocator)
    now:=time.tick+1
    ops,parts:=s.floor,s.first_part-1
    for {
        part:=part_at(s,parts+1)
        number:=ops+1
        entry:=entry_at(s,number)
        if part!=nil && part.after<=ops {
            if !part.complete {break}
            state:=entry_state(part.placed,part.done,now)
            if state==.Later {break}
            parts+=1
            if state==.Done {continue}
            if state==.New {
                part.placed=now
                if part.last {s.basing=false;s.covered=max(s.covered,part.after)}
                if part.broken {
                    part.skipped,part.done=true,now
                    s.basing=false
                    base_ask(s,true)
                }
                if len(part.bytes)==0 && !part.first {part.skipped,part.done=true,now}
            }
            if part.skipped {continue}
            append(&due,Journal_Due{tag=applying_tag(j,{key=key,number=parts,part=true},time),part=part})
            continue
        }
        if entry!=nil && (part==nil || number<=part.after) {
            state:=entry_state(entry.placed,entry.done,now)
            if state==.Later {break}
            op:=&entry.op
            mine:=op.asker!=0 && op.asker==own
            if state==.New {
                // The prediction of its tick is made after this, in that tick.
                if mine && time.tick<=u64(op.ask_tick) || i32(op.tick-u32(time.tick))>0 {break}
                entry.placed=now
                if at:=prediction_find(j,op.key,op.ask_tick,op.ask_index);mine && at>=0 {
                    p:=j.predictions[at]
                    entry.absorbed,entry.verified=true,true
                    j.stats.absorbed+=1
                    if p.low!=op.low || p.high!=op.high || p.check!=op.check {
                        j.stats.desyncs+=1
                        region_differs(s,p.low,p.high)
                        region_differs(s,op.low,op.high)
                    }
                }
            }
            ops=number
            s.gap=0
            if state==.Done || entry.skipped {continue}
            if entry.absorbed {
                // Of a correction: the game made its prediction again, which stands for it as before.
                if at:=prediction_find(j,op.key,op.ask_tick,op.ask_index);at>=0 {ordered_remove(&j.predictions,at)}
                if entry.done==0 {entry.done=now}
                continue
            }
            append(&due,Journal_Due{tag=applying_tag(j,{key=key,number=number},time),op=op})
            continue
        }
        if part!=nil && part.base && part.complete && (part.placed==0 || part.placed<=now) {
            // A base stands for every operation up to it.
            for q in number..=part.after {
                if l:=entry_at(s,q);l!=nil && l.placed==0 {l.placed,l.done,l.skipped=now,now,true}
            }
            ops=part.after
            s.gap=0
            continue
        }
        // A missing operation: after a while a base is asked for.
        if entry==nil && (s.newest>ops || part!=nil) && !time.resimulating {
            if s.gap==0 {s.gap=now} else if now-s.gap>=JOURNAL_ASK_TICKS {base_ask(s,false);s.gap=now}
        }
        break
    }
    return due[:]
}

// Client: how what journal_due handed went, with the check of what its key
// holds over the region of an operation after it. first: the first time it
// was told, not of a tick a correction runs again.
journal_result :: proc(j:^Journal,tag:u64,result:Journal_Result,check:u64,time:core.Time) -> (first:bool) {
    if tag>=u64(len(j.applying)) {return}
    a:=j.applying[tag]
    s:=journal_stream(j,a.key,false)
    if s==nil {return}
    now:=time.tick+1
    finish :: proc(done:^u64,now:u64) {if done^==0 || done^>now {done^=now}}
    if a.part {
        part:=part_at(s,a.number)
        if part==nil || result==.Again {return}
        first=part.done==0
        finish(&part.done,now)
        if !first {return}
        if result==.Done {j.stats.parts_applied+=1;return}
        // A part that does not apply asks for every part, unless it was of all of them already.
        s.basing=false
        if !(part.base && part.whole) {base_ask(s,true)}
        return
    }
    entry:=entry_at(s,a.number)
    if entry==nil || result==.Again {return}
    finish(&entry.done,now)
    if entry.verified {return}
    entry.verified,first=true,true
    if result==.Done && (entry.op.check==0 || check==entry.op.check) || s.basing || a.number<=s.covered {return}
    j.stats.desyncs+=1
    if entry.op.high.x<entry.op.low.x {base_ask(s,false)} else {region_differs(s,entry.op.low,entry.op.high)}
    return
}

// Client: a key that is not here passes its stream by. to_whole: up to the
// first part of a whole base that is here, true when there is one, from
// where journal_due applies it.
journal_skip :: proc(j:^Journal,key:Journal_Key,time:core.Time,to_whole:bool) -> bool {
    s:=journal_stream(j,key,false)
    if s==nil {return false}
    now:=time.tick+1
    head:=-1
    if to_whole {
        for part,i in s.parts {
            if part.placed==0 && part.first && part.base && part.whole && part.complete && !part.broken {head=i;break}
        }
        if head<0 {return false}
    }
    through:=head<0?s.newest:s.parts[head].after
    for q in s.floor+1..=through {
        if l:=entry_at(s,q);l!=nil && l.placed==0 {l.placed,l.done,l.skipped=now,now,true}
    }
    for &part,i in s.parts {
        if head>=0 && i>=head || !part.complete {break}
        if part.placed==0 {part.placed,part.done,part.skipped=now,now,true}
    }
    return head>=0
}

// Client: asks for the parts of a key over low..high, or a base of it with
// what it holds (since, of the library; 0: every part).
journal_resync :: proc(j:^Journal,key:Journal_Key,base:bool,since:u64,low:=[3]i32{0,0,0},high:=[3]i32{-1,-1,-1}) {
    s:=journal_stream(j,key,true)
    if s==nil {return}
    region_differs(s,low,high)
    if !base {return}
    s.since=since
    base_ask(s,since==0)
}

// Client: an operation its game asked for at the tick, the index-th of its
// asks of the tick, goes to the server; with predicted, applied here already
// over low..high, leaving check. Not again once the server refused it.
journal_ask :: proc(j:^Journal,outbox:^Net_Outbox,key:Journal_Key,time:core.Time,index:u8,body:[JOURNAL_BODY]u8,predicted:=false,low:=[3]i32{},high:=[3]i32{},check:u64=0) {
    tick:=u32(time.tick)
    if refused_has(j,key,tick,index) {return}
    if predicted && prediction_find(j,key,tick,index)<0 {
        if len(j.predictions)>=JOURNAL_PREDICTIONS {
            // The oldest gives way: when its operation comes back it applies again, and its region is asked for.
            old:=j.predictions[0]
            if s:=journal_stream(j,old.key,true);s!=nil {region_differs(s,old.low,old.high)}
            ordered_remove(&j.predictions,0)
        }
        append(&j.predictions,Journal_Prediction{key,tick,index,low,high,check})
    }
    send(outbox,Net_Journal_Ask{j.id,key,tick,index,body})
}

// Client: the refusals of the server not told yet, for the library to say
// why. Its prediction is taken back by the parts of its region.
journal_refusals :: proc(j:^Journal,time:core.Time) -> []Net_Journal_Refused {
    told:=make([dynamic]Net_Journal_Refused,context.temp_allocator)
    for &r in j.refused {
        if at:=prediction_find(j,r.refused.key,r.refused.tick,r.refused.index);at>=0 {
            if s:=journal_stream(j,r.refused.key,true);s!=nil {region_differs(s,j.predictions[at].low,j.predictions[at].high)}
            ordered_remove(&j.predictions,at)
        }
        if r.tick!=0 {continue}
        r.tick=time.tick+1
        append(&told,r.refused)
    }
    return told[:]
}

// Client, at the end of a tick: the predictions the server never answered,
// the parts it asks for and what no correction can go back to any more.
journal_flush :: proc(j:^Journal,outbox:^Net_Outbox,time:core.Time,session:core.Ref(Net_Session)) {
    now:=time.tick+1
    for i:=len(j.predictions)-1;i>=0;i-=1 {
        p:=j.predictions[i]
        if u64(p.tick)+JOURNAL_PREDICTION_TICKS>=time.tick {continue}
        if s:=journal_stream(j,p.key,true);s!=nil {region_differs(s,p.low,p.high)}
        ordered_remove(&j.predictions,i)
    }
    for &s in j.streams {
        if !s.ask && !s.ask_base || s.asked!=0 && now-s.asked<JOURNAL_ASK_TICKS {continue}
        if session.ptr!=nil && session.status!=.Connected {continue}
        resync:=Net_Journal_Resync{journal=j.id,key=s.key,low={0,0,0},high={-1,-1,-1},base=s.ask_base,since=s.ask_since}
        if s.ask {resync.low,resync.high=s.ask_low,s.ask_high}
        if !send(outbox,resync) {continue}
        s.asked=now
        if s.ask_base {s.basing=true}
        s.ask,s.ask_base=false,false
        j.stats.resyncs+=1
    }
    if time.resimulating {return}
    keep:=u64(max(JOURNAL_KEEP_TICKS,session_history(session)))+2
    old :: proc(done,keep,now:u64) -> bool {return done!=0 && done+keep<now}
    for &s in j.streams {
        // An operation that never came goes with the one after it, which a base passed over.
        drop:=0
        for drop<len(s.log) {
            at:=drop
            for at<len(s.log) && s.log[at].op.sequence==0 {at+=1}
            if at>=len(s.log) || !old(s.log[at].done,keep,now) {break}
            drop=at+1
        }
        if drop>0 {
            remove_range(&s.log,0,drop)
            s.first+=u32(drop)
            s.floor=max(s.floor,s.first-1)
        }
        parts:=0
        for parts<len(s.parts) && old(s.parts[parts].done,keep,now) {
            s.floor=max(s.floor,s.parts[parts].after)
            delete(s.parts[parts].bytes)
            parts+=1
        }
        if parts>0 {
            remove_range(&s.parts,0,parts)
            s.first_part+=u32(parts)
        }
        for len(s.log)>0 && s.first<=s.floor {
            ordered_remove(&s.log,0)
            s.first+=1
        }
    }
    for i:=len(j.refused)-1;i>=0;i-=1 {
        if j.refused[i].tick!=0 && j.refused[i].tick+keep+JOURNAL_PREDICTION_TICKS<now {unordered_remove(&j.refused,i)}
    }
}

// Server: an operation it applied in this tick goes to every client, numbered
// in its key. A library that applied the ask of a client fills asker,
// ask_tick and ask_index from journal_held_of.
journal_publish :: proc(j:^Journal,outbox:^Net_Outbox,op:Journal_Op,time:core.Time) -> bool {
    s:=journal_stream(j,op.key,true)
    if s==nil {return false}
    s.sequence+=1
    message:=Net_Journal_Op{journal=j.id,op=op}
    message.sequence,message.tick=s.sequence,u32(time.tick)
    if !send(outbox,message) {return false}
    j.stats.sent+=1
    return true
}

// Server: the asks of clients whose tick came, and those too far ahead.
journal_asks :: proc(j:^Journal,time:core.Time) -> []Journal_Held {
    due:=make([dynamic]Journal_Held,context.temp_allocator)
    for i:=0;i<len(j.held); {
        held:=j.held[i]
        if !held.ahead && i32(held.ask.tick-u32(time.tick))>0 {i+=1;continue}
        ordered_remove(&j.held,i)
        append(&due,held)
    }
    return due[:]
}

// Server: the tag of an ask the library applies, back with journal_held_of.
journal_ask_tag :: proc(j:^Journal,held:Journal_Held,time:core.Time) -> u64 {
    return applying_tag(j,{key=held.ask.key,held=held},time)
}

journal_held_of :: proc(j:^Journal,tag:u64) -> (held:Journal_Held,ok:bool) {
    if tag>=u64(len(j.applying)) || j.applying[tag].held.connection==0 {return}
    return j.applying[tag].held,true
}

journal_refuse :: proc(j:^Journal,outbox:^Net_Outbox,held:Journal_Held,reason,error:u8) {
    send(outbox,Net_Journal_Refused{j.id,held.ask.key,held.ask.tick,held.ask.index,reason,error},core.NONE,held.connection)
    j.stats.refused+=1
}

// Server: who entered its world and who left, as the network says in the tick.
journal_connections :: proc(j:^Journal,connections:core.Ref(Net_Connections)) {
    if connections.ptr==nil {return}
    for event in connections.events.items {
        at:=-1
        for c,i in j.entered {if c==event.connection {at=i;break}}
        if event.kind==.Entered && at<0 {append(&j.entered,event.connection)}
        if event.kind!=.Disconnected {continue}
        if at>=0 {unordered_remove(&j.entered,at)}
        for i:=len(j.serves)-1;i>=0;i-=1 {
            if j.serves[i].connection==event.connection {delete(j.serves[i].packed);ordered_remove(&j.serves,i)}
        }
    }
}

// Server: the parts of a key go to a connection, as its client asks with
// journal_resync. One answer of a connection and a key waits at a time,
// which takes in the regions and the bases asked for until it starts.
journal_offer :: proc(j:^Journal,connection:Connection,key:Journal_Key,base:bool,since:u64=0,low:=[3]i32{0,0,0},high:=[3]i32{-1,-1,-1}) {
    for &sv in j.serves {
        if sv.connection!=connection || sv.key!=key || sv.started {continue}
        if base {
            if !sv.base {sv.since=since} else if sv.since!=since {sv.since=0}
            sv.base=true
        }
        if high.x<low.x {return}
        if sv.high.x<sv.low.x {sv.low,sv.high=low,high;return}
        for axis in 0..<3 {sv.low[axis],sv.high[axis]=min(sv.low[axis],low[axis]),max(sv.high[axis],high[axis])}
        return
    }
    if !base && high.x<low.x {return}
    append(&j.serves,Journal_Serve{connection=connection,key=key,low=low,high=high,base=base,since=since})
}

// Server, as the iterator of a for: each answer that needs its next part,
// while the budget of the tick lasts, to the connections in its world. The
// library writes the part and gives it to journal_part, or leaves the answer
// for the next tick; what it gives goes in pieces within the budget.
journal_serves :: proc(j:^Journal,outbox:^Net_Outbox,time:core.Time) -> (sv:^Journal_Serve,ok:bool) {
    if j.served_tick!=time.tick+1 {
        j.served_tick,j.serving,j.budget=time.tick+1,0,JOURNAL_BUDGET
        for &other in j.serves {other.offered=false}
    }
    for j.serving<len(j.serves) && j.budget>0 {
        sv=&j.serves[j.serving]
        entered:=false
        for c in j.entered {entered ||= c==sv.connection}
        if !entered {j.serving+=1;continue}
        if !sv.sending {
            if sv.ended {
                delete(sv.packed)
                ordered_remove(&j.serves,j.serving)
                continue
            }
            if sv.offered {j.serving+=1;continue}
            sv.offered=true
            return sv,true
        }
        for j.budget>0 && sv.sending {
            count:=min(int(sv.piece.total)-int(sv.piece.offset),JOURNAL_PIECE)
            piece:=sv.piece
            piece.count=u16(count)
            copy(piece.bytes[:count],sv.packed[piece.offset:][:count])
            if !send(outbox,piece,core.NONE,sv.connection) {return nil,false}
            j.budget-=count+64
            j.stats.bytes_sent+=u64(count)
            sv.bytes+=count
            sv.piece.offset+=u32(count)
            if sv.piece.offset<sv.piece.total {continue}
            sv.sending=false
            sv.parts+=1
            sv.ended=sv.piece.last
            j.stats.parts_sent+=1
        }
    }
    return nil,false
}

// Server: the next part of an answer, its raw bytes; last ends the answer.
// False without memory to pack it: the answer waits for the next tick.
journal_part :: proc(j:^Journal,sv:^Journal_Serve,raw:[]u8,last:bool) -> bool {
    s:=journal_stream(j,sv.key,true)
    if s==nil || len(raw)>JOURNAL_PART_BYTES {return false}
    if resize(&sv.packed,asset.pack_bound(len(raw)))!=nil {return false}
    total:=0
    if len(raw)>0 {
        error:asset.Error
        if total,error=asset.pack(&j.encoder,asset.PACK_EDIT,raw,sv.packed[:]);error!=.None {return false}
    }
    sv.started,sv.offered=true,false
    sv.piece={journal=j.id,key=sv.key,after=s.sequence,first=sv.parts==0,last=last,base=sv.base,whole=sv.whole,raw=u32(len(raw)),total=u32(total)}
    sv.sending=true
    return true
}

// A buffer of the journal for the raw bytes of a part.
journal_buffer :: proc(j:^Journal,size:int) -> (buffer:[]u8,ok:bool) {
    if resize(&j.raw,size)!=nil {return}
    return j.raw[:],true
}
