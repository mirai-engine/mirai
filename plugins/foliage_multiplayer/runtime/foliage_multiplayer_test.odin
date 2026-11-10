package foliage_multiplayer

import "core:testing"
import "mirai:core"
import wire "mirai:net"
import "mirai:std/serial"
import foliage "plugins:foliage/runtime"
import multiplayer "plugins:multiplayer/runtime"

@(private="file")
Net_World :: struct {
    using world:core.Test_World,
    removed:core.Table(foliage.Foliage_Removed),
    objects:core.Table(multiplayer.Replicate),
    transforms:core.Table(core.Transform),
}

@(private="file")
net_types :: proc(types:^[dynamic]core.Test_Type) {
    foliage.test_types(types)
    multiplayer.test_types(types)
}

// A server replicates each entity of the instances taken out of a cell
// once, as one object to every connection whose changes travel after its
// creation; a client and a world alone replicate nothing.
@(test)
a_server_replicates_the_instances_taken_out_of_each_cell_to_every_connection_as_one_object :: proc(t:^testing.T) {
    w:Net_World
    if !core.test_world_init(t,&w,net_types) {return}
    defer core.test_world_destroy(&w)
    commands:=core.commands(&w,core.test_world_info(&w))
    cells:[2]core.Entity
    for &e,i in cells {
        e=core.create(&w.entities)
        page:=foliage.Foliage_Removed{foliage=500,coord={i32(i),0},count=2}
        page.instances[0],page.instances[1]={u64(i)},{u64(i)+10}
        core.add(&w.removed,e,page)
    }
    core.test_world_settle(&w)
    net:Foliage_Net
    network:core.Network
    step :: proc(net:^Foliage_Net,network:^core.Network,w:^Net_World,commands:core.Commands) {
        foliage_net_removals(net,core.ref(network),core.read(&w.removed),core.read(&w.objects),core.read(&w.transforms),commands)
        core.test_world_settle(w)
    }
    for role in ([2]core.Network_Role{.Standalone,.Client}) {
        network.role=role
        step(&net,&network,&w,commands)
        testing.expect_value(t,core.count(core.read(&w.objects)),0)
    }
    network.role=.Server
    step(&net,&network,&w,commands)
    for e in cells {
        object,replicated:=core.get(core.read(&w.objects),e)
        testing.expect(t,replicated && object==REPLICATE && core.has(core.read(&w.transforms),e))
    }
    testing.expect(t,REPLICATE.simulation!=.Each,"what is taken out of a cell later travels as a change of its object")
    // Taken out of a cell that has its entity: no other object.
    version:=core.version(core.read(&w.objects))
    page:=core.get(&w.removed,cells[0])
    page.instances[page.count]={99}
    page.count+=1
    core.test_world_settle(&w)
    step(&net,&network,&w,commands)
    testing.expect_value(t,core.version(core.read(&w.objects)),version)
    // A cell that has its first, or one that fills its entity, is one object more.
    later:=core.create(&w.entities)
    core.add(&w.removed,later,foliage.Foliage_Removed{foliage=500,coord={7,7},count=1})
    core.test_world_settle(&w)
    step(&net,&network,&w,commands)
    testing.expect(t,core.has(core.read(&w.objects),later))
    testing.expect_value(t,core.count(core.read(&w.objects)),3)
}

// The entity of a cell is one fragment of the protocol whose ids change
// apart: one more id taken out sends its own entries and the count, a small
// part of what its creation sends a client that comes later.
@(test)
an_instance_taken_out_later_sends_a_small_part_of_its_cell :: proc(t:^testing.T) {
    schema:serial.Schema;serial.schema_init(&schema);defer serial.schema_destroy(&schema)
    index,added:=serial.schema_add(&schema,foliage.Foliage_Removed)
    testing.expect(t,added,schema.error)
    p:wire.Protocol;wire.protocol_init(&p);defer wire.protocol_destroy(&p)
    type,registered:=wire.type_register(&p,"Foliage_Removed",{{schema=&schema,type=index}})
    if !testing.expect(t,added && registered,"a page of a cell fits in an object") {return}
    wire.protocol_seal(&p)
    desc:=&p.types[type]
    testing.expect(t,desc.words<=wire.MAX_STATE_WORDS)
    // The change bits of the count and of each entry.
    bit_of :: proc(desc:^wire.Object_Type,offset:uintptr) -> int {
        for leaf in desc.leaves {if uintptr(leaf.source)==offset {return int(leaf.bit)}}
        return -1
    }
    count_bit:=bit_of(desc,offset_of(foliage.Foliage_Removed,count))
    if !testing.expect(t,count_bit>=0) {return}
    entries:=offset_of(foliage.Foliage_Removed,instances)
    first:=bit_of(desc,entries)
    testing.expect(t,first>=0 && first!=count_bit)
    for k in 0..<foliage.REMOVED_PAGE {
        bit:=bit_of(desc,entries+uintptr(k*size_of(foliage.Removed_Instance)))
        if !testing.expect(t,bit>=0 && bit!=count_bit) {return}
        sent:=int(desc.bit_max_bits[count_bit])+int(desc.bit_max_bits[bit])
        if !testing.expect(t,sent*16<desc.max_bits,"one id taken out sends a sixteenth of the cell at most") {return}
    }
}
