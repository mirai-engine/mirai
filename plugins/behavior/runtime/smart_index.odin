package behavior

import "mirai:core"

@(private)
Smart_Entry :: struct {
    object:core.Entity,
    offer:u8,
}

@(storage,host,by_world,free="smart_index_free")
Smart_Index :: struct {
    entries:[dynamic]Smart_Entry,
    offsets:[257]int,
    seen:core.Seen,
}

smart_index_free :: proc(index:^Smart_Index) {
    delete(index.entries)
    index^={}
}

@(step="fixed",stage="input",server)
smart_index_step :: proc(index:^Smart_Index,objects:^core.Table(Smart_Object,.Read),problems:^core.Problems) {
    if !smart_index_update(index,objects) {
        core.report(problems,core.NONE,"behavior.memory","No memory to index smart offers; free memory")
    }
}

// Groups offers by use, keeping table and offer order within each group.
smart_index_update :: proc(index:^Smart_Index,objects:^core.Table(Smart_Object,.Read)) -> bool {
    if objects==nil {return false}
    seen:=index.seen
    if !core.table_touched(objects,&seen) {return true}
    offsets:[257]int
    count:=core.count(objects)
    for &object in objects.values[:count] {
        for offer in object.offers {
            if offer.use!=USE_NONE {offsets[int(offer.use)+1]+=1}
        }
    }
    for i in 1..<len(offsets) {offsets[i]+=offsets[i-1]}
    if resize(&index.entries,offsets[len(offsets)-1])!=nil {
        index.offsets={}
        return false
    }
    cursor:=offsets
    for &object,row in objects.values[:count] {
        for offer,i in object.offers {
            if offer.use==USE_NONE {continue}
            use:=int(offer.use)
            index.entries[cursor[use]]={objects.entities[row],u8(i)}
            cursor[use]+=1
        }
    }
    index.offsets=offsets
    index.seen=seen
    return true
}

@(private)
smart_entries :: proc "contextless" (index:^Smart_Index,use:Smart_Use) -> []Smart_Entry {
    if index==nil || use==USE_NONE {return nil}
    return index.entries[index.offsets[use]:index.offsets[int(use)+1]]
}
