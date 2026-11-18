package mirai_net

import "mirai:std/serial"

// Messages travel inside the datagrams of a connection, on one of its
// channels. Each channel delivers in order: a message overtaken by a later one
// of its channel is dropped. What a kind adds is on top of that:
//
//   Unreliable  sent once; lost with its datagram.
//   Sequenced   as Unreliable, and a message still waiting to be sent is
//               replaced by a newer one: only the latest matters.
//   Reliable    resent until acknowledged and delivered in the order sent.
//               Messages are cut in chunks as the window draws them from
//               the queue, so one can exceed the datagram and the queue:
//               message_send streams it, and it arrives in pieces of at
//               most PIECE_BYTES (Command.more). The chunks in flight grow
//               to what the path carries (channel_window), up to what the
//               queue holds.

Channel_Kind :: enum u8 {Unreliable,Sequenced,Reliable}

Channel_Desc :: struct {
    kind:Channel_Kind,
    budget:int,            // bytes of this channel per update of a connection; 0 has no limit
    queue_bytes:int,       // messages waiting to be sent, default 32 KiB; Reliable: also the most it keeps in flight and holds ahead on receiving, up to 4 MiB
    max_message_bytes:int, // Unreliable and Sequenced: at most MAX_UNRELIABLE_BYTES, the default. Reliable has no limit
}

MAX_UNRELIABLE_BYTES :: 1024
PIECE_BYTES :: 16<<10
@(private) MAX_WINDOW :: 16384
@(private) CHUNK_BYTES :: 256
@(private) CHUNK_WINDOW :: 64 // chunks a reliable channel starts with in flight, and the fewest it holds
@(private) CHANNEL_SYSTEM :: 6
@(private) CHANNEL_EVENTS :: 7
@(private) CHANNEL_ORDER :: [MAX_CHANNELS]int{CHANNEL_SYSTEM,CHANNEL_EVENTS,0,1,2,3,4,5}

// The chunks a reliable channel holds in flight and ahead on receiving: what its queue holds, as a
// power of two so that sequence numbers map to slots across their wraparound.
@(private)
channel_chunks :: proc "contextless" (queue_bytes:int) -> int {
    chunks:=CHUNK_WINDOW
    for chunks<MAX_WINDOW && chunks*2*CHUNK_BYTES<=queue_bytes {chunks*=2}
    return chunks
}

@(private)
Byte_Ring :: struct {data:[]u8,head,used:int}
@(private)
ring_write :: proc "contextless" (r:^Byte_Ring,bytes:[]u8) -> bool {
    if r.used+len(bytes)>len(r.data) {return false}
    at:=(r.head+r.used)%len(r.data)
    first:=min(len(bytes),len(r.data)-at)
    copy(r.data[at:],bytes[:first])
    copy(r.data,bytes[first:])
    r.used+=len(bytes)
    return true
}
@(private)
ring_peek :: proc "contextless" (r:^Byte_Ring,out:[]u8) {
    first:=min(len(out),len(r.data)-r.head)
    copy(out,r.data[r.head:][:first])
    copy(out[first:],r.data)
}
@(private)
ring_skip :: proc "contextless" (r:^Byte_Ring,count:int) {
    r.head=(r.head+count)%len(r.data)
    r.used-=count
}
@(private)
ring_read :: proc "contextless" (r:^Byte_Ring,out:[]u8) {ring_peek(r,out);ring_skip(r,len(out))}
@(private)
ring_write_message :: proc "contextless" (r:^Byte_Ring,bytes:[]u8) -> bool {
    if r.used+4+len(bytes)>len(r.data) {return false}
    size:=u32le(len(bytes))
    ring_write(r,([^]u8)(&size)[:4])
    return ring_write(r,bytes)
}
@(private)
ring_peek_size :: proc "contextless" (r:^Byte_Ring) -> int {
    size:u32le
    ring_peek(r,([^]u8)(&size)[:4])
    return int(size)
}

@(private)
Chunk_State :: enum u8 {Empty,Ready,Flight,Acked}
@(private)
Send_Chunk :: struct {length:u16,more:bool,state:Chunk_State}
@(private)
Recv_Chunk :: struct {length:u16,more,present:bool}

@(private)
Channel :: struct {
    active:bool,
    kind:Channel_Kind,
    budget,spent,max_message:int,
    queue:Byte_Ring,  // Reliable: a message streamed in is cut as its bytes come
    applied:u64,     // bytes of the messages for this connection alone taken from the frames
    delivered_after:u64, // Unreliable and Sequenced: one past the datagram of the last message delivered
    // Reliable, sending: chunks send_base..<send_next are in flight, at most window of them; those
    // from fresh on were never sent, and resend holds the ones lost, in the order they were found.
    send_base,send_next,fresh:u16,
    window:int,
    acked,acked_bytes:int, // chunks acknowledged since channel_window last measured them, and their bytes
    ready:int,       // chunks in flight waiting to be sent or resent
    resend:[]u16,
    resend_head,resend_count:int,
    front_left:int,  // bytes of the message at the head of the queue not cut yet
    front_open:bool,
    chunks:[]Send_Chunk,
    chunk_data:[]u8,
    // Reliable, receiving: chunks from recv_base on, held until the ones before arrive.
    recv_base:u16,
    recv_chunks:[]Recv_Chunk,
    recv_data:[]u8,
    assembly:[]u8,
    assembly_used:int,
}

@(private)
channel_allocate :: proc(h:^Host,c:^Channel,desc:Channel_Desc) {
    c^={active=true,kind=desc.kind,budget=desc.budget,max_message=desc.max_message_bytes}
    c.queue.data=host_make(h,u8,desc.queue_bytes)
    if desc.kind==.Reliable {
        chunks:=channel_chunks(desc.queue_bytes)
        c.chunks=host_make(h,Send_Chunk,chunks)
        c.chunk_data=host_make(h,u8,chunks*CHUNK_BYTES)
        c.resend=host_make(h,u16,chunks)
        c.recv_chunks=host_make(h,Recv_Chunk,chunks)
        c.recv_data=host_make(h,u8,chunks*CHUNK_BYTES)
        c.assembly=host_make(h,u8,PIECE_BYTES)
        c.window=CHUNK_WINDOW
    }
}
@(private)
channel_release :: proc(h:^Host,c:^Channel) {
    delete(c.queue.data,h.allocator);delete(c.chunks,h.allocator);delete(c.chunk_data,h.allocator);delete(c.resend,h.allocator)
    delete(c.recv_chunks,h.allocator);delete(c.recv_data,h.allocator);delete(c.assembly,h.allocator)
    c^={}
}
@(private)
channel_reset :: proc(c:^Channel) {
    c.queue.head,c.queue.used,c.applied,c.delivered_after=0,0,0,0
    c.send_base,c.send_next,c.fresh,c.recv_base=0,0,0,0
    c.ready,c.front_left,c.front_open,c.assembly_used,c.spent,c.acked,c.acked_bytes=0,0,false,0,0,0,0
    c.resend_head,c.resend_count=0,0
    c.window=CHUNK_WINDOW
    for &chunk in c.chunks {chunk={}}
    for &chunk in c.recv_chunks {chunk={}}
}

// A reliable message that finds its queue full closes the connection: the
// alternative is to lose it without anyone knowing. message_send, event_send
// and the requests of authority refuse what would not fit, counted from the
// room of the last host_poll, so a sender of this library never gets here.
// total: of a message streamed in, its size with its first bytes, 0 with the
// bytes that follow; -1 for a whole one.
@(private)
channel_queue :: proc(h:^Host,p:^Peer,index:int,data:[]u8,total:=-1) -> bool {
    c:=&p.channels[index]
    if !c.active || len(data)>c.max_message {return false}
    if c.kind==.Sequenced {c.queue.head,c.queue.used=0,0}
    written:bool
    switch {
    case total<0: written=ring_write_message(&c.queue,data)
    case total>0:
        size:=u32le(total)
        written=c.queue.used+4+len(data)<=len(c.queue.data) && ring_write(&c.queue,([^]u8)(&size)[:4]) && ring_write(&c.queue,data)
    case:         written=ring_write(&c.queue,data)
    }
    if written {return true}
    p.stats.messages_dropped+=1
    if c.kind==.Reliable {peer_drop(h,p,.Reliable_Overflow,true)}
    return false
}

@(private)
channels_pending :: proc(p:^Peer) -> bool {
    for &c in p.channels {
        if c.active && (c.queue.used>0 || c.ready>0) {return true}
    }
    return false
}

// A reliable channel has at least a datagram of chunks it may send now: it streams, and goes out as
// the rate allows instead of once a tick.
@(private)
channels_streaming :: proc(p:^Peer) -> bool {
    for &c in p.channels {
        if !c.active || c.kind!=.Reliable {continue}
        room:=c.window-int(u16(c.send_next-c.send_base))
        if c.ready+min(room,c.queue.used/CHUNK_BYTES)>=DATAGRAM_CHUNKS {return true}
    }
    return false
}
@(private) DATAGRAM_CHUNKS :: PACKET_BYTES/(CHUNK_BYTES+8) // chunks a datagram carries

// Cuts queued messages into chunks while the window has room and the bytes
// of the next chunk are in the queue.
@(private)
channel_fill :: proc(c:^Channel) {
    for int(u16(c.send_next-c.send_base))<c.window {
        if !c.front_open {
            if c.queue.used==0 {return}
            c.front_left=ring_peek_size(&c.queue)
            ring_skip(&c.queue,4)
            c.front_open=true
        }
        slot:=int(c.send_next)%len(c.chunks)
        length:=min(c.front_left,CHUNK_BYTES)
        if c.queue.used<length {return}
        ring_read(&c.queue,c.chunk_data[slot*CHUNK_BYTES:][:length])
        c.front_left-=length
        c.front_open=c.front_left>0
        c.chunks[slot]={length=u16(length),more=c.front_open,state=.Ready}
        c.ready+=1
        c.send_next+=1
    }
}

// The chunks in flight a reliable channel may keep. Each chunk the path acknowledged lets one more be in
// flight, so the window doubles each round trip while it holds the channel back; a loss does not shrink
// it, since a resend waits with the chunks after it acknowledged until the loss is found. What the path
// carries bounds it through the connection's rate, which congestion control finds: never above what
// that rate sends in span, the round trip and the time a loss takes to be found, in chunks of the size
// the channel's acknowledged ones had, nor below CHUNK_WINDOW, nor above what the channel holds.
@(private)
channel_window :: proc "contextless" (c:^Channel,span,rate:f64) {
    acked,bytes:=c.acked,c.acked_bytes
    c.acked,c.acked_bytes=0,0
    if !(span>0) || !(rate>0) {return}
    wire:=acked>0?f64(bytes)/f64(acked)+4:CHUNK_BYTES+4 // bytes a chunk takes in a datagram
    chunks:=min(f64(c.window)+f64(acked),rate*span/wire,f64(len(c.chunks)))
    c.window=max(int(chunks),min(CHUNK_WINDOW,len(c.chunks)))
}

// The library's channels go first, then the unreliable and sequenced game channels, which are small and
// late when they wait; then the reliable game channels take one chunk each in turn, starting with the
// next one at every datagram, so a channel that streams leaves the others their share. yield: bits the
// reliable game channels leave in the datagram for the objects that wait, so a part that streams does
// not starve the state.
@(private)
channels_write :: proc(h:^Host,p:^Peer,w:^serial.Bit_Writer,reserve,yield:int) -> (wrote:bool) {
    for index in CHANNEL_ORDER {
        c:=&p.channels[index]
        if !c.active {continue}
        if c.kind==.Reliable {
            if index<USER_CHANNELS {continue}
            channel_fill(c)
            for chunk_write(p,c,index,w,reserve) {wrote=true}
        } else {
            for c.queue.used>0 {
                length:=ring_peek_size(&c.queue)
                if serial.bit_writer_remaining(w)<15+length*8+reserve {break}
                if c.budget>0 && c.spent>0 && c.spent+length>c.budget {break}
                ring_skip(&c.queue,4)
                ring_read(&c.queue,h.back.scratch[:length])
                serial.bit_write(w,1,1)
                serial.bit_write(w,u64(index),3)
                serial.bit_write(w,u64(length),11)
                serial.bit_write_bytes(w,h.back.scratch[:length])
                c.spent+=length
                p.stats.messages_sent+=1
                wrote=true
            }
        }
    }
    for index in 0..<USER_CHANNELS {
        c:=&p.channels[index]
        if c.active && c.kind==.Reliable {channel_fill(c)}
    }
    first:=p.channel_turn
    p.channel_turn=(p.channel_turn+1)%USER_CHANNELS
    for {
        any:=false
        for k in 0..<USER_CHANNELS {
            index:=(first+k)%USER_CHANNELS
            c:=&p.channels[index]
            if !c.active || c.kind!=.Reliable {continue}
            if chunk_write(p,c,index,w,reserve+yield) {any,wrote=true,true}
        }
        if !any {break}
    }
    serial.bit_write(w,0,1)
    return
}

// Writes the next chunk the channel has ready, a lost one before a new one, if it fits with left bits
// to spare and the channel's budget allows it.
@(private)
chunk_write :: proc(p:^Peer,c:^Channel,index:int,w:^serial.Bit_Writer,left:int) -> bool {
    if c.ready==0 {return false}
    seq:=c.resend_count>0?c.resend[c.resend_head]:c.fresh
    slot:=int(seq)%len(c.chunks)
    chunk:=&c.chunks[slot]
    length:=int(chunk.length)
    if serial.bit_writer_remaining(w)<30+length*8+left {return false}
    if c.budget>0 && c.spent>0 && c.spent+length>c.budget {return false}
    if !record_push(p,{kind=.Chunk,flags=u8(index),aux=seq}) {return false}
    if c.resend_count>0 {
        c.resend_head=(c.resend_head+1)%len(c.resend)
        c.resend_count-=1
    } else {
        c.fresh+=1
    }
    serial.bit_write(w,1,1)
    serial.bit_write(w,u64(index),3)
    serial.bit_write(w,u64(seq),16)
    serial.bit_write_bool(w,chunk.more)
    serial.bit_write(w,u64(length),9)
    serial.bit_write_bytes(w,c.chunk_data[slot*CHUNK_BYTES:][:length])
    chunk.state=.Flight
    c.ready-=1
    c.spent+=length
    return true
}

@(private)
channel_resolve :: proc(p:^Peer,record:Record,received:bool) {
    c:=&p.channels[record.flags]
    seq:=record.aux
    if u16(seq-c.send_base)>=u16(c.send_next-c.send_base) {return}
    size:=len(c.chunks)
    chunk:=&c.chunks[int(seq)%size]
    if chunk.state!=.Flight {return}
    if !received {
        chunk.state=.Ready
        c.resend[(c.resend_head+c.resend_count)%len(c.resend)]=seq
        c.resend_count+=1
        c.ready+=1
        p.stats.chunks_resent+=1
        return
    }
    chunk.state=.Acked
    c.acked+=1
    c.acked_bytes+=int(chunk.length)
    for c.send_base!=c.send_next && c.chunks[int(c.send_base)%size].state==.Acked {
        last:=!c.chunks[int(c.send_base)%size].more
        c.chunks[int(c.send_base)%size]={}
        c.send_base+=1
        if last {p.stats.messages_sent+=1}
    }
}

@(private)
// A late datagram delivers the reliable chunks of the game's channels, which are numbered and taken once,
// and the unreliable and sequenced messages of a game channel that delivered none from a later datagram:
// each channel keeps its order, and one beside a stream on a path that reorders still arrives. The
// channels of the library carry events about objects whose state in the same datagram is skipped, and
// keep their order with it by waiting for the resend. counter: the datagram's.
channels_read :: proc(h:^Host,p:^Peer,r:^serial.Bit_Reader,counter:u64,late:=false,skipped:^bool=nil) -> bool {
    scratch:=h.back.scratch[:]
    chunked:=false
    defer if chunked {p.ack_chunks+=1}
    for serial.bit_read_bool(r) {
        index:=int(serial.bit_read(r,3))
        c:=&p.channels[index]
        if !c.active {return false}
        if c.kind!=.Reliable {
            length:=int(serial.bit_read(r,11))
            if length>c.max_message || !serial.bit_read_bytes(r,scratch[:length]) {return false}
            if late && (index>=USER_CHANNELS || counter+1<c.delivered_after) {continue}
            c.delivered_after=counter+1
            p.stats.messages_received+=1
            if !channel_deliver(h,p,index,scratch[:length]) {return false}
            continue
        }
        seq:=u16(serial.bit_read(r,16))
        more:=serial.bit_read_bool(r)
        length:=int(serial.bit_read(r,9))
        if length>CHUNK_BYTES || !serial.bit_read_bytes(r,scratch[:length]) {return false}
        chunked=true
        if late && index>=USER_CHANNELS {
            if skipped!=nil {skipped^=true}
            continue
        }
        size:=len(c.recv_chunks)
        if int(u16(seq-c.recv_base))>=size {continue}
        slot:=int(seq)%size
        if c.recv_chunks[slot].present {continue}
        c.recv_chunks[slot]={length=u16(length),more=more,present=true}
        copy(c.recv_data[slot*CHUNK_BYTES:],scratch[:length])
        if !channel_take(h,p,index) {return false}
        if p.state!=.Connected {return true}
    }
    return !r.error
}

// Delivers the chunks of a reliable channel that follow what it delivered, while the command buffer has
// room for them besides what a datagram may still bring: a gap that closes over many small messages
// leaves the rest held, and the network half reads no datagram until they are delivered (channels_held).
// False when the other end sent something that cannot be parsed.
@(private)
channel_take :: proc(h:^Host,p:^Peer,index:int) -> bool {
    c:=&p.channels[index]
    size:=len(c.recv_chunks)
    for c.recv_chunks[int(c.recv_base)%size].present && command_room(h,2) {
        head:=int(c.recv_base)%size
        chunk:=c.recv_chunks[head]
        if c.assembly_used+int(chunk.length)>min(len(c.assembly),c.max_message) {
            // A message of the game goes on in pieces; one of the library is whole.
            if index>=USER_CHANNELS || !channel_deliver(h,p,index,c.assembly[:c.assembly_used],true) {return false}
            c.assembly_used=0
            if p.state!=.Connected {return true}
        }
        copy(c.assembly[c.assembly_used:],c.recv_data[head*CHUNK_BYTES:][:chunk.length])
        c.assembly_used+=int(chunk.length)
        c.recv_chunks[head]={}
        c.recv_base+=1
        if !chunk.more {
            message:=c.assembly[:c.assembly_used]
            c.assembly_used=0
            p.stats.messages_received+=1
            if !channel_deliver(h,p,index,message) {return false}
            if p.state!=.Connected {return true}
        }
    }
    h.back.held||=c.recv_chunks[int(c.recv_base)%size].present
    return true
}

// Delivers what the reliable channels of every connection hold, as far as there is room.
@(private)
channels_held :: proc(h:^Host) {
    h.back.held=false
    for &peer in h.back.peers {
        if peer.state!=.Connected {continue}
        for &c,index in peer.channels {
            if !c.active || c.kind!=.Reliable || !c.recv_chunks[int(c.recv_base)%len(c.recv_chunks)].present {continue}
            if !channel_take(h,&peer,index) {peer_drop(h,&peer,.Protocol_Error,true)}
            if peer.state!=.Connected {break}
        }
    }
}

@(private)
channel_deliver :: proc(h:^Host,p:^Peer,index:int,data:[]u8,more:=false) -> bool {
    if index>=USER_CHANNELS {return repl_message(h,p,index,data)}
    if command_push(h,{kind=.Message,connection=peer_handle(h,p),channel=u8(index),more=more},data)==nil {
        if p.channels[index].kind==.Reliable {peer_drop(h,p,.Capacity,true)}
    }
    return true
}
