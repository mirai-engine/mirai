package base

import "core:testing"

@(test)
handle_pool_hands_out_distinct_valid_handles :: proc(t:^testing.T) {
    p:Handle_Pool
    testing.expect(t,handle_pool_init(&p,4));defer handle_pool_destroy(&p)
    handles:[4]Handle
    for &h,i in handles {
        h=handle_pool_alloc(&p)
        testing.expect(t,h!=0)
        testing.expect_value(t,handle_index(h),u32(i))
        testing.expect(t,handle_pool_valid(&p,h))
        slot,ok:=handle_pool_slot(&p,h)
        testing.expect(t,ok && slot==i)
        testing.expect_value(t,handle_pool_handle(&p,i),h)
    }
    testing.expect_value(t,handle_pool_alloc(&p),Handle(0))
    testing.expect_value(t,p.failed,u64(1))
    testing.expect_value(t,p.count,4)
    testing.expect_value(t,p.peak,4)
    testing.expect(t,!handle_pool_valid(&p,0),"The null handle is never valid")
    testing.expect(t,!handle_pool_valid(&p,handle_make(9,1)),"A slot beyond the pool")
}

@(test)
handle_pool_invalidates_handles_of_freed_slots :: proc(t:^testing.T) {
    p:Handle_Pool
    testing.expect(t,handle_pool_init(&p,2));defer handle_pool_destroy(&p)
    a:=handle_pool_alloc(&p)
    b:=handle_pool_alloc(&p)
    testing.expect(t,handle_pool_free(&p,a))
    testing.expect(t,!handle_pool_valid(&p,a))
    testing.expect(t,!handle_pool_free(&p,a),"A handle is freed once")
    testing.expect(t,!handle_pool_alive(&p,0))
    testing.expect_value(t,handle_pool_handle(&p,0),Handle(0))
    _,ok:=handle_pool_slot(&p,a)
    testing.expect(t,!ok)
    c:=handle_pool_alloc(&p)
    testing.expect_value(t,handle_index(c),handle_index(a))
    testing.expect(t,c!=a && handle_generation(c)>handle_generation(a))
    testing.expect(t,handle_pool_valid(&p,c) && handle_pool_valid(&p,b) && !handle_pool_valid(&p,a))
    // A forged handle carrying the generation of a free slot is not valid either.
    testing.expect(t,handle_pool_free(&p,c))
    testing.expect(t,!handle_pool_valid(&p,handle_make(0,p.generations[0])))
    testing.expect_value(t,p.count,1)
}

@(test)
handle_pool_clear_keeps_old_handles_dead :: proc(t:^testing.T) {
    p:Handle_Pool
    testing.expect(t,handle_pool_init(&p,3));defer handle_pool_destroy(&p)
    old:[3]Handle
    for &h in old {h=handle_pool_alloc(&p)}
    handle_pool_free(&p,old[1])
    handle_pool_clear(&p)
    testing.expect_value(t,p.count,0)
    for h in old {testing.expect(t,!handle_pool_valid(&p,h))}
    for _ in 0..<3 {
        h:=handle_pool_alloc(&p)
        testing.expect(t,h!=0 && handle_pool_valid(&p,h))
        for previous in old {testing.expect(t,h!=previous)}
    }
    for h in old {testing.expect(t,!handle_pool_valid(&p,h))}
    testing.expect_value(t,handle_pool_alloc(&p),Handle(0))
}

@(test)
handle_pool_retires_a_slot_that_ran_out_of_generations :: proc(t:^testing.T) {
    generations,next:[2]u32
    p:Handle_Pool
    handle_pool_init_buffer(&p,generations[:],next[:])
    a:=handle_pool_alloc(&p)
    b:=handle_pool_alloc(&p)
    // Slot 0 lives its last generation.
    p.generations[0]=GENERATION_LAST
    last:=handle_pool_handle(&p,0)
    testing.expect(t,handle_pool_valid(&p,last) && !handle_pool_valid(&p,a))
    testing.expect(t,handle_pool_free(&p,last))
    testing.expect(t,!handle_pool_valid(&p,last))
    testing.expect_value(t,p.retired,1)
    testing.expect_value(t,handle_pool_alloc(&p),Handle(0))
    testing.expect(t,handle_pool_free(&p,b))
    c:=handle_pool_alloc(&p)
    testing.expect_value(t,handle_index(c),u32(1))
    handle_pool_clear(&p)
    testing.expect_value(t,p.retired,1)
    d:=handle_pool_alloc(&p)
    testing.expect_value(t,handle_index(d),u32(1))
    testing.expect_value(t,handle_pool_alloc(&p),Handle(0))
    testing.expect(t,!handle_pool_valid(&p,last))
}

@(test)
handle_pool_rejects_an_empty_capacity :: proc(t:^testing.T) {
    p:Handle_Pool
    testing.expect(t,!handle_pool_init(&p,0))
    testing.expect_value(t,handle_pool_alloc(&p),Handle(0))
    testing.expect(t,!handle_pool_valid(&p,handle_make(0,1)))
}

Test_Body :: distinct Handle

@(test)
slot_map_keeps_values_packed_behind_stable_handles :: proc(t:^testing.T) {
    m:Slot_Map(int,Test_Body)
    testing.expect(t,slot_map_init(&m,4));defer slot_map_destroy(&m)
    a:=slot_map_insert(&m,10)
    b:=slot_map_insert(&m,20)
    c:=slot_map_insert(&m,30)
    d:=slot_map_insert(&m,40)
    testing.expect_value(t,slot_map_insert(&m,50),Test_Body(0))
    testing.expect_value(t,m.handles.failed,u64(1))
    testing.expect(t,slot_map_remove(&m,b))
    testing.expect(t,!slot_map_remove(&m,b))
    testing.expect(t,slot_map_get(&m,b)==nil)
    testing.expect(t,!slot_map_valid(&m,b))
    testing.expect_value(t,slot_map_len(&m),3)
    testing.expect_value(t,slot_map_get(&m,a)^,10)
    testing.expect_value(t,slot_map_get(&m,c)^,30)
    testing.expect_value(t,slot_map_get(&m,d)^,40)
    sum:=0
    for value,i in slot_map_values(&m) {
        sum+=value
        testing.expect_value(t,slot_map_get(&m,slot_map_handle(&m,i))^,value)
    }
    testing.expect_value(t,sum,80)
    testing.expect_value(t,slot_map_handle(&m,3),Test_Body(0))
    e:=slot_map_insert(&m,60)
    testing.expect(t,e!=b && handle_index(Handle(e))==handle_index(Handle(b)))
    testing.expect_value(t,slot_map_get(&m,e)^,60)
    slot_map_get(&m,a)^=11
    testing.expect_value(t,slot_map_values(&m)[0],11)
    slot_map_clear(&m)
    testing.expect_value(t,slot_map_len(&m),0)
    testing.expect(t,slot_map_get(&m,a)==nil && slot_map_get(&m,e)==nil)
}

@(test)
slot_map_matches_a_model_under_random_edits :: proc(t:^testing.T) {
    CAPACITY :: 64
    m:Slot_Map(u64,Handle)
    testing.expect(t,slot_map_init(&m,CAPACITY));defer slot_map_destroy(&m)
    rng:=rng_make(7)
    live:[CAPACITY]Handle
    expected:[CAPACITY]u64
    dead:[CAPACITY]Handle
    count,dead_count:=0,0
    for step in 0..<20000 {
        if count<CAPACITY && (count==0 || rng_u32(&rng)&1==0) {
            value:=rng_u64(&rng)
            h:=slot_map_insert(&m,value)
            testing.expect(t,h!=0)
            live[count]=h;expected[count]=value;count+=1
        } else {
            pick:=int(rng_u32(&rng))%count
            testing.expect(t,slot_map_remove(&m,live[pick]))
            dead[dead_count%CAPACITY]=live[pick];dead_count+=1
            count-=1
            live[pick]=live[count];expected[pick]=expected[count]
        }
        if step%97!=0 {continue}
        testing.expect_value(t,slot_map_len(&m),count)
        for i in 0..<count {
            value:=slot_map_get(&m,live[i])
            if value==nil || value^!=expected[i] {testing.expectf(t,false,"step %d: handle %x lost its value",step,live[i]);return}
        }
        for i in 0..<min(dead_count,CAPACITY) {
            if slot_map_valid(&m,dead[i]) {testing.expectf(t,false,"step %d: removed handle %x is valid again",step,dead[i]);return}
        }
    }
}

@(test)
sparse_set_tracks_members_in_packed_rows :: proc(t:^testing.T) {
    s:Sparse_Set
    testing.expect(t,sparse_set_init(&s,100,3));defer sparse_set_destroy(&s)
    row,inserted:=sparse_set_insert(&s,42)
    testing.expect(t,inserted && row==0)
    row,inserted=sparse_set_insert(&s,7)
    testing.expect(t,inserted && row==1)
    row,inserted=sparse_set_insert(&s,42)
    testing.expect(t,!inserted && row==0,"Inserting a member reports its row")
    row,inserted=sparse_set_insert(&s,99)
    testing.expect(t,inserted && row==2)
    row,inserted=sparse_set_insert(&s,1)
    testing.expect(t,!inserted && row==-1,"The set is full")
    testing.expect_value(t,s.failed,u64(1))
    row,inserted=sparse_set_insert(&s,100)
    testing.expect(t,!inserted && row==-1,"The key is out of bounds")
    testing.expect(t,sparse_set_contains(&s,7) && !sparse_set_contains(&s,8) && !sparse_set_contains(&s,1000))
    // Removing the first member moves the last one into its row.
    hole,last,ok:=sparse_set_remove(&s,42)
    testing.expect(t,ok && hole==0 && last==2)
    index,found:=sparse_set_index(&s,99)
    testing.expect(t,found && index==0)
    testing.expect(t,!sparse_set_contains(&s,42))
    _,_,ok=sparse_set_remove(&s,42)
    testing.expect(t,!ok)
    members:=sparse_set_members(&s)
    testing.expect_value(t,len(members),2)
    testing.expect(t,members[0]==99 && members[1]==7)
    hole,last,ok=sparse_set_remove(&s,7)
    testing.expect(t,ok && hole==1 && last==1,"Removing the last row moves nothing")
    sparse_set_clear(&s)
    testing.expect(t,!sparse_set_contains(&s,99) && s.count==0)
    row,inserted=sparse_set_insert(&s,0)
    testing.expect(t,inserted && row==0)
    testing.expect_value(t,s.peak,3)
    empty:Sparse_Set
    testing.expect(t,!sparse_set_init(&empty,0,4))
    testing.expect(t,!sparse_set_contains(&empty,0))
}
