package core

import "base:runtime"
import "core:testing"

@(private) Mem_Slot :: struct {points:[dynamic][3]f32,tag:u32,bytes:[]u8}
@(private) Mem_Node :: struct {kids:[dynamic]Mem_Node,weight:u32}
@(private) Mem_Pools :: struct {
    slots:[dynamic]Mem_Slot,
    fixed:[4]Mem_Slot,
    names:map[u32]u32,
    lists:map[u32][dynamic]u32,
    tree:[dynamic]Mem_Node,
    flat:[8]u32,
}

@(private)
@(test_world)
Mem_World :: struct {
    using world:Test_World,
    values:Table(u32),
    pools:Mem_Pools,
}

// What a World's tables and storages hold grows with their rows and items,
// by the capacity they reserved.
@(test)
the_memory_of_a_world_follows_what_its_tables_and_storages_hold :: proc(t:^testing.T) {
    info,described:=test_info(t,Mem_World)
    if !described {return}
    defer test_info_destroy(&info)
    w:Mem_World
    if !testing.expect(t,world_init(&info,.World,&w,context.allocator)) {return}
    defer world_destroy(&info,.World,&w)
    empty:=world_memory(&info,&w)
    for i in 0..<100 {
        e:=create(&w.entities)
        add(&w.values,e,u32(i))
    }
    settle(&info,&w,nil)
    rows:=world_memory(&info,&w)
    testing.expectf(t,rows>=empty+100*size_of(Entity),"100 rows and their entities add to it: %d -> %d",empty,rows)
    append(&w.pools.slots,Mem_Slot{})
    for i in 0..<1000 {append(&w.pools.slots[0].points,[3]f32{f32(i),0,0})}
    items:=world_memory(&info,&w)
    testing.expect_value(t,items-rows,cap(w.pools.slots)*size_of(Mem_Slot)+cap(w.pools.slots[0].points)*size_of([3]f32))
}

// The ops world_info_index compiles read what reading the types at every
// step reads, in arrays of values that hold arrays, fixed or not, in the
// values of a map and in a type that holds itself.
@(test)
the_compiled_memory_ops_read_what_the_types_say :: proc(t:^testing.T) {
    info,described:=test_info(t,Mem_World)
    if !described {return}
    defer test_info_destroy(&info)
    w:Mem_World
    if !testing.expect(t,world_init(&info,.World,&w,context.allocator)) {return}
    defer world_destroy(&info,.World,&w)
    defer { // world_destroy frees arrays and slices, not maps
        delete(w.pools.names)
        for _,list in w.pools.lists {delete(list)}
        delete(w.pools.lists)
    }
    for i in 0..<5 {
        append(&w.pools.slots,Mem_Slot{tag=u32(i)})
        for _ in 0..<i*7 {append(&w.pools.slots[i].points,[3]f32{})}
        w.pools.slots[i].bytes=make([]u8,i*13)
    }
    for &slot,i in w.pools.fixed {slot.bytes=make([]u8,i+1)}
    for i in 0..<20 {w.pools.names[u32(i)]=u32(i)}
    for i in 0..<6 {w.pools.lists[u32(i)]=make([dynamic]u32,i,i*5+1)}
    append(&w.pools.tree,Mem_Node{})
    for i in 0..<3 {
        append(&w.pools.tree[0].kids,Mem_Node{weight=u32(i)})
        for _ in 0..=i {append(&w.pools.tree[0].kids[i].kids,Mem_Node{})}
    }
    for _ in 0..<3 {create(&w.entities)}
    ws:=info.schema
    if !testing.expect(t,ws!=nil) {return}
    for &s,k in info.storages {
        if s.place!=.World {continue}
        data:=rawptr(uintptr(&w)+s.offset)
        testing.expect_value(t,memory_read(ws.memory,ws.storages[k].held,data),reflected(data,s.info))
    }
    entities:=rawptr(uintptr(&w)+info.entities)
    testing.expect_value(t,memory_read(ws.memory,ws.entities,entities),reflected(entities,type_info_of(Entities)))
    testing.expect(t,reflected(&w.pools,type_info_of(Mem_Pools))>5*size_of(Mem_Slot),"the pools hold something")
}

@(private="file")
reflected :: proc(data:rawptr,info:^runtime.Type_Info) -> int {bytes,_:=reflected_bytes(data,info);return bytes}

// What a value holds behind its pointers, read from its type at every step:
// what the compiled ops of world_memory must give.
@(private="file")
reflected_bytes :: proc(data:rawptr,info:^runtime.Type_Info) -> (bytes,elements:int) {
    base:=runtime.type_info_base(info)
    #partial switch v in base.variant {
    case runtime.Type_Info_Struct:
        for i in 0..<int(v.field_count) {
            b,e:=reflected_bytes(rawptr(uintptr(data)+v.offsets[i]),v.types[i])
            bytes+=b;elements+=e
        }
    case runtime.Type_Info_Array:
        if value_flat(v.elem) {return}
        for i in 0..<v.count {
            b,e:=reflected_bytes(rawptr(uintptr(data)+uintptr(i*v.elem_size)),v.elem)
            bytes+=b;elements+=e
        }
    case runtime.Type_Info_Enumerated_Array:
        if value_flat(v.elem) {return}
        for i in 0..<v.count {
            b,e:=reflected_bytes(rawptr(uintptr(data)+uintptr(i*v.elem_size)),v.elem)
            bytes+=b;elements+=e
        }
    case runtime.Type_Info_Dynamic_Array:
        a:=cast(^runtime.Raw_Dynamic_Array)data
        bytes=a.cap*v.elem_size
        if a.len==0 || value_flat(v.elem) {return}
        for i in 0..<a.len {
            b,e:=reflected_bytes(rawptr(uintptr(a.data)+uintptr(i*v.elem_size)),v.elem)
            bytes+=b;elements+=e+1
        }
    case runtime.Type_Info_Slice:
        a:=cast(^runtime.Raw_Slice)data
        bytes=a.len*v.elem_size
        if a.len==0 || value_flat(v.elem) {return}
        for i in 0..<a.len {
            b,e:=reflected_bytes(rawptr(uintptr(a.data)+uintptr(i*v.elem_size)),v.elem)
            bytes+=b;elements+=e+1
        }
    case runtime.Type_Info_Map:
        m:=(cast(^runtime.Raw_Map)data)^
        if m.data==0 {return}
        capacity:=uintptr(runtime.map_cap(m))
        bytes=int(runtime.map_total_allocation_size(capacity,v.map_info))
        keys,values,hashes,_,_:=runtime.map_kvh_data_dynamic(m,v.map_info)
        for i in 0..<capacity {
            if !runtime.map_hash_is_valid(hashes[i]) {continue}
            kb,ke:=reflected_bytes(rawptr(runtime.map_cell_index_dynamic(keys,v.map_info.ks,i)),v.key)
            vb,ve:=reflected_bytes(rawptr(runtime.map_cell_index_dynamic(values,v.map_info.vs,i)),v.value)
            bytes+=kb+vb;elements+=ke+ve+1
        }
    }
    return
}
