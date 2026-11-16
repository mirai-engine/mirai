package base

import "base:intrinsics"
import "core:testing"
import "core:thread"

@(test)
ring_is_a_queue_and_a_stack_at_both_ends :: proc(t:^testing.T) {
    r:Ring(int)
    testing.expect(t,ring_init(&r,4));defer ring_destroy(&r)
    for i in 1..=4 {testing.expect(t,ring_push_back(&r,i))}
    testing.expect(t,!ring_push_back(&r,5))
    testing.expect(t,!ring_push_front(&r,0))
    testing.expect_value(t,r.failed,u64(2))
    value,ok:=ring_pop_front(&r)
    testing.expect(t,ok && value==1)
    testing.expect(t,ring_push_back(&r,5),"The freed slot wraps around")
    for expected,i in ([4]int{2,3,4,5}) {testing.expect_value(t,ring_get(&r,i)^,expected)}
    testing.expect(t,ring_get(&r,4)==nil && ring_get(&r,-1)==nil)
    testing.expect_value(t,ring_front(&r)^,2)
    testing.expect_value(t,ring_back(&r)^,5)
    value,ok=ring_pop_back(&r)
    testing.expect(t,ok && value==5)
    testing.expect(t,ring_push_front(&r,1))
    for expected in ([4]int{1,2,3,4}) {
        value,ok=ring_pop_front(&r)
        testing.expect(t,ok && value==expected)
    }
    _,ok=ring_pop_front(&r)
    testing.expect(t,!ok)
    _,ok=ring_pop_back(&r)
    testing.expect(t,!ok)
    testing.expect(t,ring_front(&r)==nil && ring_back(&r)==nil)
    testing.expect_value(t,ring_space(&r),4)
    testing.expect_value(t,r.peak,4)
}

@(test)
ring_overwrites_its_oldest_item_when_asked :: proc(t:^testing.T) {
    backing:[3]int
    r:Ring(int);ring_init_buffer(&r,backing[:])
    for i in 1..=3 {
        _,overwrote:=ring_push_overwrite(&r,i)
        testing.expect(t,!overwrote)
    }
    dropped,overwrote:=ring_push_overwrite(&r,4)
    testing.expect(t,overwrote && dropped==1)
    dropped,overwrote=ring_push_overwrite(&r,5)
    testing.expect(t,overwrote && dropped==2)
    for expected,i in ([3]int{3,4,5}) {testing.expect_value(t,ring_get(&r,i)^,expected)}
    testing.expect_value(t,r.failed,u64(0))
    ring_clear(&r)
    testing.expect_value(t,r.count,0)
    empty:Ring(int)
    testing.expect(t,!ring_init(&empty,0))
    testing.expect(t,!ring_push_back(&empty,1))
    _,overwrote=ring_push_overwrite(&empty,1)
    testing.expect(t,!overwrote)
}

@(test)
spsc_queue_refuses_pushes_beyond_its_capacity :: proc(t:^testing.T) {
    q:Spsc_Queue(int)
    testing.expect(t,spsc_init(&q,3));defer spsc_destroy(&q)
    for i in 0..<3 {testing.expect(t,spsc_push(&q,i))}
    testing.expect(t,!spsc_push(&q,3),"The capacity is the one asked for, not the rounded one")
    testing.expect_value(t,q.producer.failed,u64(1))
    testing.expect_value(t,spsc_len(&q),3)
    for i in 0..<3 {
        value,ok:=spsc_pop(&q)
        testing.expect(t,ok && value==i)
    }
    _,ok:=spsc_pop(&q)
    testing.expect(t,!ok)
    for round in 0..<10 {
        testing.expect(t,spsc_push(&q,round))
        value,popped:=spsc_pop(&q)
        testing.expect(t,popped && value==round)
    }
    empty:Spsc_Queue(int)
    testing.expect(t,!spsc_init(&empty,0))
    testing.expect(t,!spsc_push(&empty,1))
}

SPSC_TEST_ITEMS :: 100000

// Waiting for the other side: spin first, since handing the processor over costs far more than a queue operation.
@(private="file")
spsc_test_wait :: proc(spins:^int) {
    spins^+=1
    if spins^&1023==0 {thread.yield()} else {intrinsics.cpu_relax()}
}

@(private="file")
spsc_test_producer :: proc(data:rawptr) {
    q:=(^Spsc_Queue(u64))(data)
    spins:=0
    for i in 1..=u64(SPSC_TEST_ITEMS) {
        for !spsc_push(q,i) {spsc_test_wait(&spins)}
    }
}

@(test)
spsc_queue_passes_every_item_in_order_between_two_threads :: proc(t:^testing.T) {
    q:Spsc_Queue(u64)
    testing.expect(t,spsc_init(&q,1000));defer spsc_destroy(&q)
    producer:=thread.create_and_start_with_data(&q,spsc_test_producer)
    defer thread.destroy(producer)
    expected,sum:=u64(1),u64(0)
    spins:=0
    for expected<=SPSC_TEST_ITEMS {
        value,ok:=spsc_pop(&q)
        if !ok {spsc_test_wait(&spins);continue}
        if value!=expected {testing.expectf(t,false,"got %d, expected %d",value,expected);break}
        sum+=value;expected+=1
    }
    thread.join(producer)
    testing.expect_value(t,sum,u64(SPSC_TEST_ITEMS)*(SPSC_TEST_ITEMS+1)/2)
    _,ok:=spsc_pop(&q)
    testing.expect(t,!ok)
}

@(test)
priority_queue_pops_the_smallest_key_first :: proc(t:^testing.T) {
    q:Priority_Queue(f32,u32)
    testing.expect(t,priority_queue_init(&q,5));defer priority_queue_destroy(&q)
    for key,i in ([5]f32{3,1,4,1.5,-2}) {testing.expect(t,priority_queue_push(&q,key,u32(i)))}
    testing.expect(t,!priority_queue_push(&q,0,9))
    testing.expect_value(t,q.failed,u64(1))
    key,value,ok:=priority_queue_peek(&q)
    testing.expect(t,ok && key==-2 && value==4)
    order:=[5]u32{4,1,3,0,2}
    for expected in order {
        key,value,ok=priority_queue_pop(&q)
        testing.expect(t,ok)
        testing.expect_value(t,value,expected)
    }
    _,_,ok=priority_queue_pop(&q)
    testing.expect(t,!ok)
    _,_,ok=priority_queue_peek(&q)
    testing.expect(t,!ok)
    testing.expect(t,priority_queue_push(&q,1,1))
    priority_queue_clear(&q)
    testing.expect_value(t,q.count,0)
}

@(test)
priority_queue_sorts_random_keys :: proc(t:^testing.T) {
    COUNT :: 2000
    keys:[COUNT]u64
    values:[COUNT]u32
    q:Priority_Queue(u64,u32);priority_queue_init_buffer(&q,keys[:],values[:])
    rng:=rng_make(11)
    sum_in,sum_out:u64
    for i in 0..<COUNT {
        key:=rng_u64(&rng)%1000
        sum_in+=key
        testing.expect(t,priority_queue_push(&q,key,u32(key)))
        // Interleaved pops keep the heap honest with holes.
        if i%7==3 {
            popped,value,_:=priority_queue_pop(&q)
            testing.expect_value(t,u64(value),popped)
            sum_out+=popped
        }
    }
    previous:u64
    for q.count>0 {
        key,value,_:=priority_queue_pop(&q)
        if key<previous || u64(value)!=key {testing.expectf(t,false,"key %d after %d",key,previous);break}
        previous=key;sum_out+=key
    }
    testing.expect_value(t,sum_out,sum_in)
}
