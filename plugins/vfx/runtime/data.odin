package vfx

import "core:fmt"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import erender "mirai:engine/render"

// Data channels: entries of words, by the name of their channel, that the
// programs of the world write and read (`//! resource name data words`) and
// that games push. What the programs append in a frame is read in the next:
// each channel keeps two copies, the one the frame writes and the one it
// reads, which change places each frame. What a game pushes is read in the
// frame it reaches the GPU, after the entries of the programs. A channel is
// made when some program of the world reads it, with the most words any of
// them asks; making the channels again is a load transaction: their entries
// start empty. A game reads back the entries of the channels it watches
// (data_watch): what the programs appended in a frame comes once, frames
// later, without waiting for the GPU. It is presentation alone, as the
// reports are: no function of fixed reads it.

DATA_ENTRIES :: 4096      // that the programs write to a channel in a frame
DATA_GAME_ENTRIES :: 256  // that games push to a channel in a frame
DATA_CHANNELS :: 32       // of a world
DATA_WORDS :: 32          // of an entry: render.PROGRAM_DATA_WORDS

// An entry a game pushes to the data channel of its name: words of it, as
// the programs that read it lay them out.
Data_Push :: struct {
    channel:u64, // base.name_hash of its name
    words:[DATA_WORDS]f32,
    count:u32,
}

@(storage,queue)
Particle_Data :: struct {
    queue:core.Queue(Data_Push),
}

// Pushes an entry to the data channel of its name; the words past those the channel keeps are let go.
data_push :: proc(data:^Particle_Data,name:string,words:[]f32) {
    push:=Data_Push{channel=base.name_hash(name),count=u32(min(len(words),DATA_WORDS))}
    copy(push.words[:],words)
    core.push(&data.queue,push)
}

// The channels a game reads back, named each frame it reads them.
@(storage,queue)
Particle_Data_Watch :: struct {
    queue:core.Queue(u64),
}

data_watch :: proc(watch:^Particle_Data_Watch,name:string) {core.push(&watch.queue,base.name_hash(name))}

// What the programs appended to a watched channel in a frame, words after words.
Data_Read :: struct {
    name:u64,
    words:u32,
    entries:[dynamic]f32,
    frame:u64, // of the renderer, + 1, the entries are of; 0: none yet
    fresh:bool, // the entries came this frame
}

// The entries of the watched channels that came back this frame.
@(storage,host,by_world,presentation,free="particle_data_read_free")
Particle_Data_Read :: struct {
    channels:[dynamic]Data_Read,
}

particle_data_read_free :: proc(read:^Particle_Data_Read) {
    for &channel in read.channels {delete(channel.entries)}
    delete(read.channels)
    read^={}
}

// The entries of a watched channel that came back this frame, words each; none
// in a frame nothing came.
data_entries :: proc(read:^Particle_Data_Read,name:string) -> (entries:[]f32,words:int) {
    if read==nil {return}
    key:=base.name_hash(name)
    for &channel in read.channels {
        if channel.name!=key || !channel.fresh || channel.words==0 {continue}
        return channel.entries[:],int(channel.words)
    }
    return
}

Data_Entry :: struct {
    name:u64,
    words:u32,
    offset:u32, // bytes of its counters and copies among the channels
    pushed:[dynamic]f32, // what games pushed this frame, words each
    watched:bool, // a game reads it back this frame
}

Data_Channels :: struct {
    entries:[dynamic]Data_Entry,
    bytes:u32,
    layout:u64,
    made:bool, // the world buffer holds them, empty, as layout says
}

data_free :: proc(d:^Data_Channels) {
    for &entry in d.entries {delete(entry.pushed)}
    delete(d.entries)
    d^={}
}

// The bytes of a channel: the two copies the programs write, then what games pushed.
@(private)
data_bytes :: proc "contextless" (words:u32) -> u32 {return 2*data_copy_bytes(words)+DATA_GAME_ENTRIES*words*4}

// The bytes of a copy: its counter, padding, then its entries.
@(private)
data_copy_bytes :: proc "contextless" (words:u32) -> u32 {return 16+DATA_ENTRIES*words*4}

// The channels the programs of the frame read, and the most words each asks.
@(private)
data_need :: proc(d:^Data_Channels,name:u64,words:u32,used:^[DATA_CHANNELS]bool,problems:^core.Problems,e:core.Entity) {
    for &entry,at in d.entries {
        if entry.name!=name {continue}
        used[at]=true
        if words>entry.words {entry.words=words;d.made=false}
        return
    }
    if len(d.entries)==DATA_CHANNELS {
        core.report(problems,e,"vfx.data","a world has at most %d data channels",DATA_CHANNELS)
        return
    }
    used[len(d.entries)]=true
    append(&d.entries,Data_Entry{name=name,words=words})
    d.made=false
}

// Keeps the channels used this frame, places them, and takes what games pushed and which they watch.
@(private)
data_place :: proc(d:^Data_Channels,used:[DATA_CHANNELS]bool,pushed:[]Data_Push,watched:[]u64=nil) {
    for i:=len(d.entries)-1;i>=0;i-=1 {
        if used[i] {continue}
        delete(d.entries[i].pushed)
        ordered_remove(&d.entries,i)
        d.made=false
    }
    layout:=u64(len(d.entries))+1
    offset:=u32(0)
    for &entry in d.entries {
        entry.offset=offset
        offset+=data_bytes(entry.words)
        layout=base.hash_combine(layout,base.hash_combine(entry.name,u64(entry.words)))
        clear(&entry.pushed)
        entry.watched=false
        for name in watched {entry.watched||=name==entry.name}
    }
    if layout!=d.layout {d.made=false}
    d.layout,d.bytes=layout,offset
    for push in pushed {
        for &entry in d.entries {
            if entry.name!=push.channel || u32(len(entry.pushed))>=DATA_GAME_ENTRIES*entry.words {continue}
            row:[DATA_WORDS]f32
            words:=push.words
            copy(row[:],words[:push.count])
            append(&entry.pushed,..row[:entry.words])
        }
    }
}

@(private)
data_find :: proc(d:^Data_Channels,name:u64) -> int {
    for entry,at in d.entries {if entry.name==name {return at}}
    return -1
}

// The channels in the world buffer this frame: the counter of the copy it
// writes (parity) at zero, and what games pushed after the copies. Made
// again, they start empty.
@(private)
data_frame :: proc(sync:^Particle_Sync,pass:^erender.Pass,parity:u32) {
    d:=&sync.data
    if len(d.entries)==0 {return}
    world:=world_buffer(sync)
    base_at:=u64(data_base(sync))
    if !d.made {
        erender.pass_buffer_fill(pass,world,base_at,u64(d.bytes))
        d.made=true
    }
    for &entry in d.entries {
        at:=base_at+u64(entry.offset)
        copy_bytes:=u64(data_copy_bytes(entry.words))
        erender.pass_buffer_fill(pass,world,at+u64(parity)*copy_bytes,4)
        if len(entry.pushed)>0 {
            erender.pass_buffer_write(pass,world,at+2*copy_bytes,raw_data(entry.pushed),len(entry.pushed)*4)
        }
    }
}

// The copies the programs of the frame wrote (parity) of the watched channels back to the CPU.
@(private)
data_readback :: proc(sync:^Particle_Sync,pass:^erender.Pass,parity:u32) {
    d:=&sync.data
    if !d.made {return}
    base_at:=u64(data_base(sync))
    for entry in d.entries {
        if !entry.watched {continue}
        erender.pass_readback(pass,world_buffer(sync),base_at+u64(entry.offset)+u64(parity)*u64(data_copy_bytes(entry.words)),data_readback_desc(entry.name,entry.words))
    }
}

@(private)
data_readback_desc :: proc(name:u64,words:u32) -> erender.Buffer_Desc {
    return {fmt.tprintf("vfx data %x",name),u64(data_copy_bytes(words))}
}

// What the GPU brought back of the watched channels since the last frame.
@(private)
data_read :: proc(read:^Particle_Data_Read,d:^Data_Channels,app:^host.App,id:core.World_Id,problems:^core.Problems) {
    for &channel in read.channels {channel.fresh=false}
    for entry in d.entries {
        if !entry.watched {continue}
        bytes,frame,ok:=erender.readback(app,id,data_readback_desc(entry.name,entry.words).name)
        if !ok {continue}
        channel:^Data_Read
        for &each in read.channels {if each.name==entry.name {channel=&each}}
        if channel==nil {
            if _,err:=append(&read.channels,Data_Read{name=entry.name});err!=nil {
                core.report(problems,core.NONE,"vfx.memory","out of memory for what a watched channel of particles brought back; it is read again in the next frame: free memory")
                continue
            }
            channel=&read.channels[len(read.channels)-1]
        }
        if frame==channel.frame {continue}
        channel.frame=frame
        data_read_bytes(channel,bytes,entry.words)
    }
}

// The entries of the copy a frame wrote, from its counter and its entries.
@(private)
data_read_bytes :: proc(channel:^Data_Read,bytes:[]u8,words:u32) {
    clear(&channel.entries)
    channel.words,channel.fresh=words,true
    if len(bytes)<16 {return}
    count:=min(([^]u32)(raw_data(bytes))[0],DATA_ENTRIES)
    if 16+int(count*words*4)>len(bytes) {return}
    append(&channel.entries,..([^]f32)(raw_data(bytes[16:]))[:count*words])
}

// Where the channels start in the world buffer: after the grids.
@(private)
data_base :: proc "contextless" (sync:^Particle_Sync) -> u32 {return grids_base(sync)+sync.grids.bytes}
