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
@(component,description="Another end of the network session decides what this entity does.")
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

// Whether this end decides what an entity does.
owned :: #force_inline proc "contextless" (remotes:^Table(Remote,$A),e:Entity) -> bool {return !has(remotes,e)}
