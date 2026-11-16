package base

@(require) import "base:runtime"
@(require) import "core:log"
@(require) import "core:mem"
@(require) import "core:slice"
@(require) import "core:testing"
@(require) import "core:time"

// Measurements of the hot paths: mirai test std/base --release -define:MIRAI_BENCH=true
BENCH :: #config(MIRAI_BENCH,false)

when BENCH {

BENCH_ROUNDS :: 5

// Runs the body several times and keeps the fastest: other processes can only make a round slower.
Bench :: struct {best:time.Duration,start:time.Tick,round:int}
bench_round :: proc(b:^Bench) -> bool {
    if b.round>0 {
        elapsed:=time.tick_since(b.start)
        if b.round==1 || elapsed<b.best {b.best=elapsed}
    }
    if b.round>=BENCH_ROUNDS {return false}
    b.round+=1
    b.start=time.tick_now()
    return true
}
bench_report :: proc(name:string,b:Bench,operations:int,sink:u64=0) {
    log.infof("%-46s %9.2f ns/op   (%d ops, check %x)",name,f64(time.duration_nanoseconds(b.best))/f64(operations),operations,sink)
}

@(test)
bench_allocators :: proc(t:^testing.T) {
    COUNT :: 100000
    SIZE :: 64
    pointers:=make([][]byte,COUNT);defer delete(pointers)
    sink:u64
    {
        a:Arena;arena_init(&a,COUNT*SIZE*2);defer arena_destroy(&a)
        allocator:=arena_allocator(&a)
        b:Bench
        for bench_round(&b) {
            arena_reset(&a)
            for &p in pointers {p,_=mem.alloc_bytes_non_zeroed(SIZE,16,allocator)}
        }
        sink+=u64(uintptr(raw_data(pointers[COUNT-1])))&1
        bench_report("arena alloc 64 B",b,COUNT,sink)
    }
    {
        f:Frame_Allocator;frame_init(&f,COUNT*SIZE*2);defer frame_destroy(&f)
        allocator:=frame_allocator(&f)
        b:Bench
        for bench_round(&b) {
            frame_swap(&f)
            for &p in pointers {p,_=mem.alloc_bytes_non_zeroed(SIZE,16,allocator)}
        }
        bench_report("frame alloc 64 B",b,COUNT)
    }
    {
        p:Block_Pool;block_pool_init(&p,SIZE,COUNT);defer block_pool_destroy(&p)
        b:Bench
        for bench_round(&b) {
            for &block in pointers {block,_=block_pool_alloc(&p)}
            for block in pointers {block_pool_free(&p,raw_data(block))}
        }
        bench_report("block pool alloc + free 64 B",b,COUNT)
    }
    {
        h:Heap;heap_init(&h,HEAP_OVERHEAD+COUNT*(SIZE+32));defer heap_destroy(&h)
        allocator:=heap_allocator(&h)
        b:Bench
        for bench_round(&b) {
            for &p in pointers {p,_=mem.alloc_bytes_non_zeroed(SIZE,8,allocator)}
            for p in pointers {mem.free_bytes(p,allocator)}
        }
        testing.expect_value(t,heap_stats(&h).failed,u64(0))
        bench_report("heap (TLSF) alloc + free 64 B",b,COUNT)
    }
    {
        b:Bench
        for bench_round(&b) {
            for &p in pointers {p,_=mem.alloc_bytes_non_zeroed(SIZE,8,runtime.heap_allocator())}
            for p in pointers {mem.free_bytes(p,runtime.heap_allocator())}
        }
        bench_report("system heap alloc + free 64 B",b,COUNT)
    }
}

@(test)
bench_handles_and_sets :: proc(t:^testing.T) {
    COUNT :: 100000
    handles:=make([]Handle,COUNT);defer delete(handles)
    sink:u64
    {
        p:Handle_Pool;handle_pool_init(&p,COUNT);defer handle_pool_destroy(&p)
        b:Bench
        for bench_round(&b) {
            for &h in handles {h=handle_pool_alloc(&p)}
            for h in handles {handle_pool_free(&p,h)}
        }
        bench_report("handle pool alloc + free",b,COUNT)
        for &h in handles {h=handle_pool_alloc(&p)}
        b={}
        for bench_round(&b) {
            for h in handles {if handle_pool_valid(&p,h) {sink+=1}}
        }
        bench_report("handle pool valid",b,COUNT,sink)
    }
    {
        m:Slot_Map(Vec4_Bench,Handle);slot_map_init(&m,COUNT);defer slot_map_destroy(&m)
        b:Bench
        for bench_round(&b) {
            for &h,i in handles {h=slot_map_insert(&m,Vec4_Bench{f32(i),0,0,0})}
            for h in handles {slot_map_remove(&m,h)}
        }
        bench_report("slot map insert + remove",b,COUNT)
        for &h,i in handles {h=slot_map_insert(&m,Vec4_Bench{f32(i),0,0,0})}
        rng:=rng_make(1)
        for i:=COUNT-1;i>0;i-=1 {j:=int(rng_u32(&rng))%(i+1);handles[i],handles[j]=handles[j],handles[i]}
        total:f32
        b={}
        for bench_round(&b) {
            for h in handles {total+=slot_map_get(&m,h)[0]}
        }
        bench_report("slot map get (random order)",b,COUNT,u64(total))
        b={}
        for bench_round(&b) {
            for value in slot_map_values(&m) {total+=value[0]}
        }
        bench_report("slot map iterate dense values",b,COUNT,u64(total))
    }
    {
        s:Sparse_Set;sparse_set_init(&s,COUNT,COUNT);defer sparse_set_destroy(&s)
        b:Bench
        for bench_round(&b) {
            for key in 0..<u32(COUNT) {sparse_set_insert(&s,key)}
            for key in 0..<u32(COUNT) {sparse_set_remove(&s,key)}
        }
        bench_report("sparse set insert + remove",b,COUNT)
    }
    {
        BITS :: 1<<20
        bits:=make([]u64,bits_words(BITS));defer delete(bits)
        rng:=rng_make(2)
        for index in 0..<BITS {if rng_u32(&rng)%10==0 {bits_set(bits,index)}}
        set:=bits_count(bits)
        b:Bench
        for bench_round(&b) {
            it:=bits_iterator(bits)
            for index in bits_iterate(&it) {sink+=u64(index)}
        }
        bench_report("bits iterate (10% set), per set bit",b,set,sink)
        b={}
        for bench_round(&b) {
            for index in 0..<BITS {if bits_test(bits,index) {sink+=u64(index)}}
        }
        bench_report("bits test every bit, per set bit",b,set,sink)
    }
}

Vec4_Bench :: [4]f32

@(test)
bench_queues :: proc(t:^testing.T) {
    COUNT :: 100000
    sink:u64
    {
        r:Ring(u64);ring_init(&r,1024);defer ring_destroy(&r)
        b:Bench
        for bench_round(&b) {
            for i in 0..<u64(COUNT) {
                ring_push_back(&r,i)
                if i&3==3 {for _ in 0..<4 {value,_:=ring_pop_front(&r);sink+=value}}
            }
        }
        bench_report("ring push + pop",b,COUNT,sink)
    }
    {
        q:Spsc_Queue(u64);spsc_init(&q,1024);defer spsc_destroy(&q)
        b:Bench
        for bench_round(&b) {
            for i in 0..<u64(COUNT) {
                spsc_push(&q,i)
                if i&3==3 {for _ in 0..<4 {value,_:=spsc_pop(&q);sink+=value}}
            }
        }
        bench_report("spsc push + pop (one thread)",b,COUNT,sink)
    }
    {
        q:Priority_Queue(f32,u32);priority_queue_init(&q,COUNT);defer priority_queue_destroy(&q)
        rng:=rng_make(3)
        keys:=make([]f32,COUNT);defer delete(keys)
        for &key in keys {key=f32(rng_u32(&rng)>>8)}
        b:Bench
        for bench_round(&b) {
            for key,i in keys {priority_queue_push(&q,key,u32(i))}
            for _ in 0..<COUNT {_,value,_:=priority_queue_pop(&q);sink+=u64(value)}
        }
        bench_report("priority queue push + pop (100k deep)",b,COUNT,sink)
        b={}
        for bench_round(&b) {
            for round in 0..<100 {
                for key,i in keys[round*1000:][:1000] {priority_queue_push(&q,key,u32(i))}
                for _ in 0..<1000 {_,value,_:=priority_queue_pop(&q);sink+=u64(value)}
            }
        }
        bench_report("priority queue push + pop (1k deep)",b,COUNT,sink)
    }
}

@(test)
bench_maps :: proc(t:^testing.T) {
    COUNT :: 100000
    keys:=make([]u64,COUNT);defer delete(keys)
    rng:=rng_make(4)
    for &key in keys {key=rng_u64(&rng)}
    sink:u64
    {
        m:Hash_Map(u32);hash_map_init(&m,COUNT);defer hash_map_destroy(&m)
        b:Bench
        for bench_round(&b) {
            hash_map_clear(&m)
            for key,i in keys {hash_map_set(&m,key,u32(i))}
        }
        bench_report("hash map insert",b,COUNT)
        b={}
        for bench_round(&b) {
            for key in keys {sink+=u64(hash_map_get(&m,key))}
        }
        bench_report("hash map get (hit)",b,COUNT,sink)
        b={}
        for bench_round(&b) {
            for key in keys {if hash_map_contains(&m,key+1) {sink+=1}}
        }
        bench_report("hash map get (miss)",b,COUNT,sink)
        b={}
        for bench_round(&b) {
            for key in keys {hash_map_remove(&m,key)}
            for key,i in keys {hash_map_set(&m,key,u32(i))}
        }
        bench_report("hash map remove + insert",b,COUNT)
    }
    {
        m:=make(map[u64]u32,COUNT);defer delete(m)
        b:Bench
        for bench_round(&b) {
            clear(&m)
            for key,i in keys {m[key]=u32(i)}
        }
        bench_report("builtin map insert",b,COUNT)
        b={}
        for bench_round(&b) {
            for key in keys {sink+=u64(m[key])}
        }
        bench_report("builtin map get (hit)",b,COUNT,sink)
    }
    {
        c:Lru(u32);lru_init(&c,COUNT/10);defer lru_destroy(&c)
        b:Bench
        for bench_round(&b) {
            for key,i in keys {
                if value:=lru_get(&c,key%u64(COUNT/5));value!=nil {sink+=u64(value^)} else {lru_put(&c,key%u64(COUNT/5),u32(i))}
            }
        }
        bench_report("lru get or put (half misses)",b,COUNT,sink)
    }
    {
        table:Interner;intern_init(&table,COUNT,COUNT*12);defer intern_destroy(&table)
        names:=make([][12]u8,COUNT);defer delete(names)
        for &name,i in names {text_format(name[:],"field_%d",i)}
        b:Bench
        for bench_round(&b) {
            intern_clear(&table)
            for &name in names {symbol,_:=intern_add(&table,text_get(name[:]));sink+=u64(symbol)}
        }
        bench_report("intern add (new)",b,COUNT,sink)
        b={}
        for bench_round(&b) {
            for &name in names {symbol,_:=intern_find(&table,text_get(name[:]));sink+=u64(symbol)}
        }
        bench_report("intern find",b,COUNT,sink)
    }
}

@(test)
bench_sorting_and_hashing :: proc(t:^testing.T) {
    COUNT :: 1000000
    source32:=make([]Sort_Key32,COUNT);defer delete(source32)
    items32:=make([]Sort_Key32,COUNT);defer delete(items32)
    scratch32:=make([]Sort_Key32,COUNT);defer delete(scratch32)
    source64:=make([]Sort_Key64,COUNT);defer delete(source64)
    items64:=make([]Sort_Key64,COUNT);defer delete(items64)
    scratch64:=make([]Sort_Key64,COUNT);defer delete(scratch64)
    rng:=rng_make(5)
    for &item,i in source32 {item={rng_u32(&rng),u32(i)}}
    for &item,i in source64 {item={rng_u64(&rng),u32(i)}}
    b:Bench
    for bench_round(&b) {copy(items32,source32);radix_sort32(items32,scratch32)}
    bench_report("radix sort 1M u32 keys, per item",b,COUNT,u64(items32[COUNT/2].key))
    b={}
    for bench_round(&b) {copy(items64,source64);radix_sort64(items64,scratch64)}
    bench_report("radix sort 1M u64 keys, per item",b,COUNT,items64[COUNT/2].key)
    b={}
    for bench_round(&b) {copy(items32,source32);slice.sort_by(items32,proc(x,y:Sort_Key32) -> bool {return x.key<y.key})}
    bench_report("slice.sort_by 1M u32 keys, per item",b,COUNT,u64(items32[COUNT/2].key))
    b={}
    for bench_round(&b) {copy(items32,source32)}
    bench_report("(copy of the 1M items, included above)",b,COUNT)
    // What a frame sorts: fewer items, which fit in the cache, and keys that leave some bytes unused.
    FRAME :: 50000
    b={}
    for bench_round(&b) {copy(items32[:FRAME],source32[:FRAME]);radix_sort32(items32[:FRAME],scratch32[:FRAME])}
    bench_report("radix sort 50k u32 keys, per item",b,FRAME,u64(items32[FRAME/2].key))
    b={}
    for bench_round(&b) {copy(items64[:FRAME],source64[:FRAME]);radix_sort64(items64[:FRAME],scratch64[:FRAME])}
    bench_report("radix sort 50k u64 keys, per item",b,FRAME,items64[FRAME/2].key)
    for &item in source64[:FRAME] {item.key&=0xffffffffff}
    b={}
    for bench_round(&b) {copy(items64[:FRAME],source64[:FRAME]);radix_sort64(items64[:FRAME],scratch64[:FRAME])}
    bench_report("radix sort 50k 40-bit keys in u64, per item",b,FRAME,items64[FRAME/2].key)
    b={}
    for bench_round(&b) {copy(items32[:FRAME],source32[:FRAME]);slice.sort_by(items32[:FRAME],proc(x,y:Sort_Key32) -> bool {return x.key<y.key})}
    bench_report("slice.sort_by 50k u32 keys, per item",b,FRAME,u64(items32[FRAME/2].key))

    data:=make([]byte,1<<20);defer delete(data)
    for &value in data {value=u8(rng_u32(&rng))}
    sink:u64
    for size in ([3]int{64,4096,1<<20}) {
        repeats:=(64<<20)/size
        b={}
        for bench_round(&b) {
            for i in 0..<repeats {sink+=hash64(data[:size],u64(i))}
        }
        seconds:=time.duration_seconds(b.best)
        log.infof("%-46s %9.2f ns/op   %7.2f GiB/s","hash64 of a block of bytes",f64(time.duration_nanoseconds(b.best))/f64(repeats),f64(size)*f64(repeats)/seconds/f64(1<<30))
        b={}
        for bench_round(&b) {
            for i in 0..<repeats {sink+=hash128(data[:size],u64(i))[0]}
        }
        seconds=time.duration_seconds(b.best)
        log.infof("%-46s %9.2f ns/op   %7.2f GiB/s   (%d B)","hash128 of a block of bytes",f64(time.duration_nanoseconds(b.best))/f64(repeats),f64(size)*f64(repeats)/seconds/f64(1<<30),size)
    }
    names:=[4]string{"position","Rigid_Body","linear_velocity","a_rather_long_component_field_name"}
    b={}
    for bench_round(&b) {
        for i in 0..<1000000 {sink+=name_hash(names[i&3])}
    }
    bench_report("name_hash (FNV-1a) of field names",b,1000000,sink)
}

@(test)
bench_profile_zones :: proc(t:^testing.T) {
    COUNT :: 1000000
    p:Profile;profile_init(&p,{threads=1,zones_per_thread=4096});defer profile_destroy(&p)
    sink:u64
    b:Bench
    for bench_round(&b) {
        for i in 0..<COUNT {
            scope:=profile_begin(&p,0,"zone")
            sink+=u64(i)
            profile_end(scope)
        }
    }
    bench_report("profile zone, enabled",b,COUNT,sink)
    profile_set_enabled(&p,false)
    b={}
    for bench_round(&b) {
        for i in 0..<COUNT {
            scope:=profile_begin(&p,0,"zone")
            sink+=u64(i)
            profile_end(scope)
        }
    }
    bench_report("profile zone, disabled",b,COUNT,sink)
    b={}
    for bench_round(&b) {
        for i in 0..<COUNT {sink+=u64(i)}
    }
    bench_report("(the empty loop)",b,COUNT,sink)
}

}
