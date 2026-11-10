package foliage_multiplayer

import "mirai:core"
import foliage "plugins:foliage/runtime"
import multiplayer "plugins:multiplayer/runtime"

// The instances of foliage taken out in play, over the network. The server
// takes them out (foliage.foliage_removals does nothing on a client) and
// replicates each entity of foliage.Foliage_Removed, the ids taken out of a
// cell, to every connection as one object: its component is a fragment whose
// entries change apart, so an id taken out later sends that entry and the
// count alone, and a client that comes later gets the whole of it with its
// creation. A client makes the entity with its component, and its foliage,
// which names the Foliage by its Id, leaves the instances out as the
// server's does. A cell costs an object for each foliage.REMOVED_PAGE instances, not
// one for each.

REPLICATE :: multiplayer.Replicate{simulation=.Server,audience=.Always,priority=1,radius=1}

// What foliage_net_removals last looked at.
@(storage)
Foliage_Net :: struct {
    removed:core.Seen, // the table of Foliage_Removed it last looked at
    role:core.Network_Role,
}

// Server: what was taken out goes to the clients. Only when what was taken
// out, or the role, changed.
@(step="fixed",loops="game",stage="react")
foliage_net_removals :: proc(net:^Foliage_Net,authority:core.Ref(core.Network),removed:core.Read(foliage.Foliage_Removed),objects:core.Read(multiplayer.Replicate),transforms:core.Read(core.Transform),commands:core.Commands) {
    role:=authority.ptr!=nil?authority.role:.Standalone
    if !core.touched(removed,&net.removed) && role==net.role {return}
    net.role=role
    if role!=.Server {return}
    for row in 0..<core.count(removed) {
        e:=core.entity_at(removed,row)
        if core.has(objects,e) {continue}
        // What the network places: where its Foliage is.
        if !core.has(transforms,e) {core.commands_add(commands,e,core.TRANSFORM_IDENTITY)}
        core.commands_add(commands,e,REPLICATE)
    }
}
