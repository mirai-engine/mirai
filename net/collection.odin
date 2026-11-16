package mirai_net

Collection_Item :: struct($T:typeid) {id:u32,value:T}

// A zero id is a vacant slot. Stable ids survive insertion, removal and replication order.
Collection :: struct($T:typeid,$CAPACITY:int) {items:[CAPACITY]Collection_Item(T)}

collection_set :: proc(c:^Collection($T,$CAPACITY),id:u32,value:T) -> Error {
    if id==0 {return .Invalid}
    free:=-1
    for &item,index in c.items {
        if item.id==id {item.value=value;return .None}
        if item.id==0 && free<0 {free=index}
    }
    if free<0 {return .Full}
    c.items[free]={id=id,value=value}
    return .None
}

collection_remove :: proc(c:^Collection($T,$CAPACITY),id:u32) -> bool {
    if id==0 {return false}
    for &item in c.items {
        if item.id==id {item={};return true}
    }
    return false
}

collection_get :: proc(c:^Collection($T,$CAPACITY),id:u32) -> (value:T,found:bool) {
    if id==0 {return}
    for item in c.items {
        if item.id==id {return item.value,true}
    }
    return
}

collection_count :: proc(c:^Collection($T,$CAPACITY)) -> (count:int) {
    for item in c.items {count+=int(item.id!=0)}
    return
}
