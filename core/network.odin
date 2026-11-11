package core

// Who decides what the entities of a World do. A World alone decides
// everything; in a network session the server decides, and a client decides
// only what it owns. The network library is the only writer of Network and
// Remote; the others read them, without knowing the network.

Network_Role :: enum u8 {
    Standalone, // no network session
    Server,
    Client,
}

@(storage,keep)
Network :: struct {
    role:Network_Role,
}

// On an entity another end decides: on a server, what the client of a
// connection holds now and simulates; on a client, a replica it neither
// predicts nor holds. What the server simulates the server decides, also
// where a client predicts it.
@(component,derived,description="Another end of the network session decides what this entity does.")
Remote :: struct {}

// Whether someone checks that the World runs the same twice (the sync test of
// a network client): what simulates outside the tables then leaves a hash of
// its state in Simulation_Hash after each tick.
@(storage)
Sync_Check :: struct {
    on:bool,
}

@(storage)
Simulation_Hash :: struct {
    value:u64,
}

// The messages of the network (@(net_message)) that arrived for the tick that
// runs, by type: what a function that receives an Inbox(T) reads. Only the
// network writes it, at the start of each tick; a tick that runs again has
// those it had.
@(storage)
Net_Messages :: struct {
    types:[dynamic]Net_Arrived, // by the index of the type in World_Info.messages
}

// The messages of one type, each a Message(T), one after another.
Net_Arrived :: struct {
    blocks:[dynamic]u128,
    count:int,
}

// What a function receives to read the messages of type T that arrived for its tick.
Inbox :: struct($T:typeid) {items:[]Message(T)}

Message :: struct($T:typeid) {
    value:T,
    sender:u64, // server: the connection of the client that sent it, as Seat.peer
    about:Entity,
}

// Where the sender of a Message(T) is, and the bytes each takes, for a T of
// that size and alignment: what fills an inbox without knowing T.
message_layout :: proc "contextless" (size,align:int) -> (sender,stride:int) {
    sender=(size+7)&~7
    stride=(sender+16+max(align,8)-1)&~(max(align,8)-1)
    return
}
#assert(offset_of(Message([3]u8),sender)==8 && size_of(Message([3]u8))==24 && size_of(Message(u128))==32)

// The messages of the type at index of World_Info.messages, of type T.
inbox :: proc "contextless" (m:^Net_Messages,index:int,$T:typeid) -> Inbox(T) {
    if index>=len(m.types) {return {}}
    return {([^]Message(T))(raw_data(m.types[index].blocks))[:m.types[index].count]}
}

// Whether this end decides what an entity does.
owned :: #force_inline proc "contextless" (remotes:Read(Remote),e:Entity) -> bool {return !has(remotes,e)}
