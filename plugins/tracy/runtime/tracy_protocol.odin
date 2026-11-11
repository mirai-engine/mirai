// Wire constants and records of Tracy 0.14.2, the subset that the native
// client needs for GPU zones. They were checked against
// `public/common/TracyProtocol.hpp` and `public/common/TracyQueue.hpp` of
// https://github.com/5hif7y/tracy (commit 778d6d71). Tracy is distributed
// under the 3-clause BSD license, Copyright (c) 2017-2026 Bartosz Taudul.
//
// These are the records and writers used by the native client; the socket,
// handshake, queue drain and LZ4 framing (lz4.odin blocks, which the server
// decodes as independent ones) live in tracy_transport.odin.
package tracy

PROTOCOL_VERSION :: 83
BROADCAST_VERSION :: 3
SERVER_PORT :: 8086
BROADCAST_PORT :: 8086

HANDSHAKE_SIZE :: 8
HANDSHAKE :: [HANDSHAKE_SIZE]u8{'T', 'r', 'a', 'c', 'y', 'P', 'r', 'f'}

TARGET_FRAME_SIZE :: 256 * 1024
LZ4_SIZE :: TARGET_FRAME_SIZE + TARGET_FRAME_SIZE / 255 + 16 // lz4_bound of a whole frame

// The order is part of the trace format: only add at the end.
Gpu_Context_Type :: enum u8 {
    Invalid     = 0,
    OpenGL      = 1,
    Vulkan      = 2,
    OpenCL      = 3,
    Direct3D12  = 4,
    Direct3D11  = 5,
    Metal       = 6,
    Custom      = 7,
    CUDA        = 8,
    ROCProf     = 9,
    WebGPU      = 10,
}

// The subset of Tracy's QueueType used by the native client. The values are
// the exact positions in TracyQueue.hpp; only add at the end of that enum.
Queue_Type :: enum u8 {
    Zone_Begin           = 19,
    Zone_Begin_32        = 20,
    Zone_Begin_16        = 21,
    Zone_End             = 25,
    Zone_End_32          = 26,
    Zone_End_16          = 27,
    Gpu_Zone_Begin       = 45,
    Gpu_Zone_End         = 49,
    Gpu_Time             = 60,
    Gpu_Context_Name     = 61,
    Terminate            = 73,
    Thread_Context       = 75,
    Frame_Mark           = 83,
    Source_Location      = 87,
    Gpu_New_Context      = 95,
    Single_String_Data   = 112,
    Single_String_Data_8 = 114,
    String_Data          = 119,
    Thread_Name          = 120,
    Plot_Name            = 121,
    Frame_Name           = 125,
}

Zone_Begin :: struct #packed {
    time:            i64,
    source_location: u64,
}

Zone_End :: struct #packed {
    time: i64,
}

// The short variants of the zone records. Tracy's dequeue converts a small
// non-negative delta to these types; the server adds the protocol offsets back
// when it reads them.
Zone_Begin_32 :: struct #packed {
    time:            u32,
    source_location: u64,
}

Zone_Begin_16 :: struct #packed {
    time:            u16,
    source_location: u64,
}

Zone_End_32 :: struct #packed {
    time: u32,
}

Zone_End_16 :: struct #packed {
    time: u16,
}

Gpu_Zone_Begin :: struct #packed {
    cpu_time:        i64,
    thread:          u32,
    query_id:        u16,
    ctx:         u8,
    source_location: u64,
}

Gpu_Zone_End :: struct #packed {
    cpu_time: i64,
    thread:   u32,
    query_id: u16,
    ctx:  u8,
}

Gpu_New_Context :: struct #packed {
    cpu_time: i64,
    gpu_time: i64,
    thread:   u32,
    period:   f32,
    ctx:  u8,
    flags:    u8,
    type:     Gpu_Context_Type,
}

Gpu_Context_Name :: struct #packed {
    ctx: u8,
}

Gpu_Time :: struct #packed {
    gpu_time: i64,
    query_id: u16,
    ctx:  u8,
}

// Absolute GPU and CPU clocks at the same moment. The server uses it to
// align the GPU timeline of a context with the CPU timeline.
Frame_Mark :: struct #packed {
    time: i64,
    name: u64,
}

Thread_Context :: struct #packed {
    thread: u32,
}

// A source location answered to ServerQuerySourceLocation. `name` is the
// pointer the server will ask for with ServerQueryString.
Source_Location :: struct #packed {
    name:     u64,
    function: u64,
    file:     u64,
    line:     u32,
    b:        u8,
    g:        u8,
    r:        u8,
}

// Sizes of the reference C++ records, from the headers above. A test keeps
// them equal to size_of of the Odin records.
ZONE_BEGIN_SIZE          :: 16
ZONE_BEGIN_32_SIZE       :: 12
ZONE_BEGIN_16_SIZE       :: 10
ZONE_END_SIZE            :: 8
ZONE_END_32_SIZE         :: 4
ZONE_END_16_SIZE         :: 2

// Offsets of the compact zone time fields, from TracyProtocol.hpp.
PROTOCOL_OFFSET_16 :: u64(1) << 16
PROTOCOL_OFFSET_32 :: (u64(1) << 16) + (u64(1) << 32)
GPU_ZONE_BEGIN_SIZE      :: 23
GPU_ZONE_END_SIZE        :: 15
GPU_NEW_CONTEXT_SIZE     :: 27
GPU_CONTEXT_NAME_SIZE    :: 1
GPU_TIME_SIZE            :: 11
FRAME_MARK_SIZE          :: 16
THREAD_CONTEXT_SIZE      :: 4
SOURCE_LOCATION_SIZE     :: 31
STRING_TRANSFER_SIZE     :: 8

// Writes a zone begin with the smallest record the delta allows, like Tracy's
// dequeue does. A 64-bit <time> is stored with ProtocolOffset32Bit subtracted;
// the server adds it back for non-negative values.
write_zone_begin_delta :: proc(out:[]u8,delta:i64,source_location:u64) -> (int,bool) {
    if delta>=0 && u64(delta)<PROTOCOL_OFFSET_16 {
        if len(out)<1+ZONE_BEGIN_16_SIZE {return 0,false}
        item:=Zone_Begin_16{time=u16(delta),source_location=source_location}
        out[0]=u8(Queue_Type.Zone_Begin_16)
        bytes:=transmute([ZONE_BEGIN_16_SIZE]u8)item
        copy(out[1:],bytes[:])
        return 1+ZONE_BEGIN_16_SIZE,true
    }
    if delta>=0 && u64(delta)<PROTOCOL_OFFSET_32 {
        if len(out)<1+ZONE_BEGIN_32_SIZE {return 0,false}
        item:=Zone_Begin_32{time=u32(u64(delta)-PROTOCOL_OFFSET_16),source_location=source_location}
        out[0]=u8(Queue_Type.Zone_Begin_32)
        bytes:=transmute([ZONE_BEGIN_32_SIZE]u8)item
        copy(out[1:],bytes[:])
        return 1+ZONE_BEGIN_32_SIZE,true
    }
    if len(out)<1+ZONE_BEGIN_SIZE {return 0,false}
    wire:=delta
    if wire>=0 {wire-=i64(PROTOCOL_OFFSET_32)}
    item:=Zone_Begin{time=wire,source_location=source_location}
    out[0]=u8(Queue_Type.Zone_Begin)
    bytes:=transmute([ZONE_BEGIN_SIZE]u8)item
    copy(out[1:],bytes[:])
    return 1+ZONE_BEGIN_SIZE,true
}

// The ZoneEnd counterpart of write_zone_begin_delta.
write_zone_end_delta :: proc(out:[]u8,delta:i64) -> (int,bool) {
    if delta>=0 && u64(delta)<PROTOCOL_OFFSET_16 {
        if len(out)<1+ZONE_END_16_SIZE {return 0,false}
        item:=Zone_End_16{time=u16(delta)}
        out[0]=u8(Queue_Type.Zone_End_16)
        bytes:=transmute([ZONE_END_16_SIZE]u8)item
        copy(out[1:],bytes[:])
        return 1+ZONE_END_16_SIZE,true
    }
    if delta>=0 && u64(delta)<PROTOCOL_OFFSET_32 {
        if len(out)<1+ZONE_END_32_SIZE {return 0,false}
        item:=Zone_End_32{time=u32(u64(delta)-PROTOCOL_OFFSET_16)}
        out[0]=u8(Queue_Type.Zone_End_32)
        bytes:=transmute([ZONE_END_32_SIZE]u8)item
        copy(out[1:],bytes[:])
        return 1+ZONE_END_32_SIZE,true
    }
    if len(out)<1+ZONE_END_SIZE {return 0,false}
    wire:=delta
    if wire>=0 {wire-=i64(PROTOCOL_OFFSET_32)}
    item:=Zone_End{time=wire}
    out[0]=u8(Queue_Type.Zone_End)
    bytes:=transmute([ZONE_END_SIZE]u8)item
    copy(out[1:],bytes[:])
    return 1+ZONE_END_SIZE,true
}

write_gpu_zone_begin :: proc(out:[]u8,item:Gpu_Zone_Begin) -> (int,bool) {
    if len(out)<1+GPU_ZONE_BEGIN_SIZE {return 0,false}
    out[0]=u8(Queue_Type.Gpu_Zone_Begin)
    bytes:=transmute([GPU_ZONE_BEGIN_SIZE]u8)item
    copy(out[1:],bytes[:])
    return 1+GPU_ZONE_BEGIN_SIZE,true
}

write_gpu_zone_end :: proc(out:[]u8,item:Gpu_Zone_End) -> (int,bool) {
    if len(out)<1+GPU_ZONE_END_SIZE {return 0,false}
    out[0]=u8(Queue_Type.Gpu_Zone_End)
    bytes:=transmute([GPU_ZONE_END_SIZE]u8)item
    copy(out[1:],bytes[:])
    return 1+GPU_ZONE_END_SIZE,true
}

write_frame_mark :: proc(out:[]u8,item:Frame_Mark) -> (int,bool) {
    if len(out)<1+FRAME_MARK_SIZE {return 0,false}
    out[0]=u8(Queue_Type.Frame_Mark)
    bytes:=transmute([FRAME_MARK_SIZE]u8)item
    copy(out[1:],bytes[:])
    return 1+FRAME_MARK_SIZE,true
}

write_gpu_new_context :: proc(out:[]u8,item:Gpu_New_Context) -> (int,bool) {
    if len(out)<1+GPU_NEW_CONTEXT_SIZE {return 0,false}
    out[0]=u8(Queue_Type.Gpu_New_Context)
    bytes:=transmute([GPU_NEW_CONTEXT_SIZE]u8)item
    copy(out[1:],bytes[:])
    return 1+GPU_NEW_CONTEXT_SIZE,true
}

write_gpu_time :: proc(out:[]u8,item:Gpu_Time) -> (int,bool) {
    if len(out)<1+GPU_TIME_SIZE {return 0,false}
    out[0]=u8(Queue_Type.Gpu_Time)
    bytes:=transmute([GPU_TIME_SIZE]u8)item
    copy(out[1:],bytes[:])
    return 1+GPU_TIME_SIZE,true
}

write_context_name :: proc(out:[]u8,item:Gpu_Context_Name) -> (int,bool) {
    if len(out)<1+GPU_CONTEXT_NAME_SIZE {return 0,false}
    out[0]=u8(Queue_Type.Gpu_Context_Name)
    bytes:=transmute([GPU_CONTEXT_NAME_SIZE]u8)item
    copy(out[1:],bytes[:])
    return 1+GPU_CONTEXT_NAME_SIZE,true
}

write_thread_context :: proc(out:[]u8,item:Thread_Context) -> (int,bool) {
    if len(out)<1+THREAD_CONTEXT_SIZE {return 0,false}
    out[0]=u8(Queue_Type.Thread_Context)
    bytes:=transmute([THREAD_CONTEXT_SIZE]u8)item
    copy(out[1:],bytes[:])
    return 1+THREAD_CONTEXT_SIZE,true
}

write_source_location :: proc(out:[]u8,item:Source_Location) -> (int,bool) {
    if len(out)<1+SOURCE_LOCATION_SIZE {return 0,false}
    out[0]=u8(Queue_Type.Source_Location)
    bytes:=transmute([SOURCE_LOCATION_SIZE]u8)item
    copy(out[1:],bytes[:])
    return 1+SOURCE_LOCATION_SIZE,true
}

// Terminate is a bare header; the server stops the worker when it sees it.
write_terminate :: proc(out:[]u8) -> (int,bool) {
    if len(out)<1 {return 0,false}
    out[0]=u8(Queue_Type.Terminate)
    return 1,true
}

// A StringData/ThreadName/PlotName/FrameName item: pointer, u16 length and
// the bytes. The trailing name is what the server stores.
write_string_transfer :: proc(out:[]u8,type:Queue_Type,ptr:u64,text:string) -> (int,bool) {
    #partial switch type {
    case .String_Data, .Thread_Name, .Plot_Name, .Frame_Name:
    case:
        return 0,false
    }
    length:=min(len(text),65535)
    needed:=1+STRING_TRANSFER_SIZE+2+length
    if len(out)<needed {return 0,false}
    out[0]=u8(type)
    out[1]=u8(ptr)
    out[2]=u8(ptr>>8)
    out[3]=u8(ptr>>16)
    out[4]=u8(ptr>>24)
    out[5]=u8(ptr>>32)
    out[6]=u8(ptr>>40)
    out[7]=u8(ptr>>48)
    out[8]=u8(ptr>>56)
    out[9]=u8(length)
    out[10]=u8(length>>8)
    copy(out[11:11+length],text[:length])
    return needed,true
}

// SendSingleString: a context name or other string consumed by the next
// record. Lengths up to 255 use the 8-bit variant; longer ones encode
// length-256 in a u16, as TracyProtocol.hpp's ProtocolOffset8Bit does.
write_single_string :: proc(out:[]u8,text:string) -> (int,bool) {
    if len(text) <= 255 {
        length:=len(text)
        needed:=1+1+length
        if len(out)<needed {return 0,false}
        out[0]=u8(Queue_Type.Single_String_Data_8)
        out[1]=u8(length)
        copy(out[2:2+length],text[:length])
        return needed,true
    }
    length:=min(len(text),256+65535)
    needed:=1+2+length
    if len(out)<needed {return 0,false}
    encoded:=length-256
    out[0]=u8(Queue_Type.Single_String_Data)
    out[1]=u8(encoded)
    out[2]=u8(encoded>>8)
    copy(out[3:3+length],text[:length])
    return needed,true
}

// What the server sends before the client identifies itself: the shibboleth
// and the protocol version, little-endian.
SERVER_HANDSHAKE_SIZE :: HANDSHAKE_SIZE + 4

Handshake_Status :: enum u8 {
    Pending          = 0,
    Welcome          = 1,
    ProtocolMismatch = 2,
    NotAvailable     = 3,
    Dropped          = 4,
}

// Server-to-client request types that the native client answers. The values
// are the positions in TracyProtocol.hpp's ServerQuery enum.
Server_Query :: enum u8 {
    Terminate        = 0,
    String           = 1,
    Thread_String    = 2,
    Source_Location  = 3,
    Plot_Name        = 4,
    Frame_Name       = 5,
    Parameter        = 6,
    Fiber_Name       = 7,
    External_Name    = 8,
    Disconnect       = 9,
    Callstack_Frame  = 10,
    Symbol           = 11,
    Symbol_Code      = 12,
    Source_Code      = 13,
    Data_Transfer    = 14,
    Data_Transfer_Part = 15,
}

// The UDP discovery message a client broadcasts while it waits for the
// profiler. The GUI listens on BROADCAST_PORT; the message carries the TCP
// port the client is listening on. `active_time` is seconds since the client
// started, or -1 in the final message that removes it from the GUI list.
Broadcast_Message :: struct #packed {
    broadcast_version: u16,
    listen_port:       u16,
    protocol_version:  u32,
    pid:               u64,
    active_time:       i32,
    program_name:      [64]u8,
}

BROADCAST_HEADER_SIZE :: 20
BROADCAST_MESSAGE_SIZE :: 84

// Writes the variable-length discovery message: the fixed header, the name
// and its null terminator. The GUI copies the datagram into a zeroed struct.
write_broadcast_message :: proc(out:[]u8,listen_port:u16,pid:u64,active_time:i32,program_name:string) -> (int,bool) {
    name_len:=min(len(program_name),63)
    needed:=BROADCAST_HEADER_SIZE+name_len+1
    if len(out)<needed {return 0,false}
    out[0]=u8(BROADCAST_VERSION)
    out[1]=u8(BROADCAST_VERSION>>8)
    out[2]=u8(listen_port)
    out[3]=u8(listen_port>>8)
    out[4]=u8(PROTOCOL_VERSION)
    out[5]=u8(PROTOCOL_VERSION>>8)
    out[6]=u8(PROTOCOL_VERSION>>16)
    out[7]=u8(PROTOCOL_VERSION>>24)
    for i in 0..<8 {out[8+i]=u8(pid>>(uint(i)*8))}
    value:=u32(active_time)
    out[16]=u8(value)
    out[17]=u8(value>>8)
    out[18]=u8(value>>16)
    out[19]=u8(value>>24)
    copy(out[20:20+name_len],program_name[:name_len])
    out[20+name_len]=0
    return needed,true
}

// ServerQueryPacket is `{type:u8, ptr:u64, extra:u32}` with packing.
SERVER_QUERY_PACKET_SIZE :: 13

// The server writes HandshakeShibboleth and its ProtocolVersion; the client
// answers with a Handshake_Status byte and its WelcomeMessage.
parse_server_handshake :: proc(bytes:[]u8) -> (version:u32,ok:bool) {
    if len(bytes)<SERVER_HANDSHAKE_SIZE {return 0,false}
    expected:=HANDSHAKE
    for i in 0..<HANDSHAKE_SIZE {if bytes[i]!=expected[i] {return 0,false}}
    version=u32(bytes[8])|u32(bytes[9])<<8|u32(bytes[10])<<16|u32(bytes[11])<<24
    return version,version==PROTOCOL_VERSION
}

// The client's welcome, 1170 bytes packed. The strings are zero-padded; the
// server reads fixed-size arrays. The fields follow WelcomeMessage in
// TracyProtocol.hpp.
Tracy_Welcome :: struct #packed {
    timer_mul:        f64,
    init_begin:       i64,
    init_end:         i64,
    resolution:       u64,
    epoch:            u64,
    exec_time:        u64,
    pid:              u64,
    sampling_period:  i64,
    flags:            u8,
    cpu_arch:         u8,
    cpu_manufacturer: [12]u8,
    cpu_id:           u32,
    program_name:     [64]u8,
    host_info:        [1024]u8,
}

WELCOME_SIZE :: 1170

// WelcomeFlag of TracyProtocol.hpp.
WELCOME_FLAG_ON_DEMAND :: u8(1 << 0) // the session may start after the program did: the payload below says where
WELCOME_FLAG_IS_APPLE  :: u8(1 << 1)

// OnDemandPayloadMessage: the frames counted before the session and the time
// it starts, sent raw right after the welcome.
ON_DEMAND_PAYLOAD_SIZE :: 16

write_on_demand_payload :: proc(out:[]u8,frames:u64,current_time:i64) -> (int,bool) {
    if len(out)<ON_DEMAND_PAYLOAD_SIZE {return 0,false}
    time:=u64(current_time)
    for i in 0..<8 {
        out[i]=u8(frames>>(uint(i)*8))
        out[8+i]=u8(time>>(uint(i)*8))
    }
    return ON_DEMAND_PAYLOAD_SIZE,true
}

Welcome_Info :: struct {
    timer_mul:        f64,
    init_begin:       i64,
    init_end:         i64,
    resolution:       u64,
    epoch:            u64,
    exec_time:        u64,
    pid:              u64,
    sampling_period:  i64,
    flags:            u8,
    cpu_arch:         u8,
    cpu_manufacturer: string,
    cpu_id:           u32,
    program_name:     string,
    host_info:        string,
}

// Copies a string into a fixed field, truncating and zero-padding. The caller
// must have zeroed the welcome first; welcome_fill does.
@(private="file")
welcome_copy :: proc(field:[]u8,text:string) {
    n:=min(len(field)-1,len(text)) // the server reads the field as a C string: the last byte stays zero
    copy(field[:n],text[:n])
}

welcome_fill :: proc(welcome:^Tracy_Welcome,info:Welcome_Info) {
    welcome^={}
    welcome.timer_mul=info.timer_mul
    welcome.init_begin=info.init_begin
    welcome.init_end=info.init_end
    welcome.resolution=info.resolution
    welcome.epoch=info.epoch
    welcome.exec_time=info.exec_time
    welcome.pid=info.pid
    welcome.sampling_period=info.sampling_period
    welcome.flags=info.flags
    welcome.cpu_arch=info.cpu_arch
    welcome.cpu_id=info.cpu_id
    welcome_copy(welcome.cpu_manufacturer[:],info.cpu_manufacturer)
    welcome_copy(welcome.program_name[:],info.program_name)
    welcome_copy(welcome.host_info[:],info.host_info)
}
