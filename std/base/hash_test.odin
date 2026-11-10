package base

import "core:slice"
import "core:testing"
import "core:time"

@(test)
rng_reproduces_the_reference_pcg32_sequence :: proc(t:^testing.T) {
    // Output of the reference implementation for pcg32_srandom(42, 54).
    rng:=rng_make(42,54)
    for expected in ([6]u32{0xa15c02b7,0x7b47f409,0xba1d3330,0x83d2f293,0xbfa4784b,0xcbed606e}) {
        testing.expect_value(t,rng_u32(&rng),expected)
    }
    a,b:=rng_make(1),rng_make(1)
    for _ in 0..<100 {testing.expect_value(t,rng_u64(&a),rng_u64(&b))}
    c,d:=rng_make(1,0),rng_make(1,1)
    different:=0
    for _ in 0..<100 {if rng_u32(&c)!=rng_u32(&d) {different+=1}}
    testing.expect(t,different>90,"Streams do not share a sequence")
}

@(test)
rng_works_from_a_zeroed_state :: proc(t:^testing.T) {
    rng:Rng
    testing.expect_value(t,rng_u32(&rng),u32(0))
    testing.expect_value(t,rng_u32(&rng),u32(0))
    testing.expect(t,rng_u32(&rng)!=0,"The state leaves zero by itself")
    seen:[16]int
    for _ in 0..<16000 {seen[rng_u32(&rng)>>28]+=1}
    for count in seen {testing.expect(t,count>800 && count<1200)}
}

@(test)
hashes_are_stable_and_spread :: proc(t:^testing.T) {
    data:="content addressed"
    bytes:=transmute([]byte)data
    testing.expect_value(t,hash64(bytes),hash64(bytes))
    testing.expect(t,hash64(bytes)!=hash64(bytes[:len(bytes)-1]))
    testing.expect(t,hash64(bytes)!=hash64(bytes,1),"The seed changes the hash")
    wide:=hash128(bytes)
    testing.expect_value(t,wide,hash128(bytes))
    testing.expect(t,wide[0]!=wide[1] && wide!=hash128(bytes,1))
    // Reference values of XXH3 for the empty input.
    testing.expect_value(t,hash64(nil),u64(0x2d06800538d394c2))
    testing.expect_value(t,hash128(nil),[2]u64{0x6001c324468d497f,0x99aa06d3014798d8})
    testing.expect_value(t,hash_u64(0),u64(0))
    // The first two outputs of SplitMix64 seeded with 0.
    testing.expect_value(t,hash_u64(0x9e3779b97f4a7c15),u64(0xe220a8397b1dcdaf))
    testing.expect_value(t,hash_u64(0x3c6ef372fe94f82a),u64(0x6e789e6aa1b965f4))
    testing.expect(t,hash_u64(2)!=hash_u64(3))
    state:u64=0
    testing.expect_value(t,splitmix_next(&state),u64(0xe220a8397b1dcdaf))
    testing.expect_value(t,splitmix_next(&state),u64(0x6e789e6aa1b965f4))
    // A fold tells the order and the count of its words, zeros too.
    testing.expect_value(t,HASH_SEED,name_hash(""))
    testing.expect(t,hash_mix(hash_mix(HASH_SEED,1),2)!=hash_mix(hash_mix(HASH_SEED,2),1))
    testing.expect(t,hash_mix(HASH_SEED,0)!=HASH_SEED && hash_mix(hash_mix(HASH_SEED,0),0)!=hash_mix(HASH_SEED,0))
    id:=asset_id_from_content(bytes)
    testing.expect_value(t,id,Asset_Id(wide))
    testing.expect(t,asset_id_from_content(nil)!={})
}

@(test)
new_ids_are_never_none_and_repeat_for_a_seed :: proc(t:^testing.T) {
    first,second:=u64(2026),u64(2026)
    seen:map[Entity_Id]bool;defer delete(seen)
    for _ in 0..<1000 {
        entity:=entity_id_next(&first)
        testing.expect(t,entity!=0 && !(entity in seen))
        seen[entity]=true
        testing.expect_value(t,entity_id_next(&second),entity)
    }
    zero:u64=0
    zero-=0x9e3779b97f4a7c15 // the state whose next value mixes to zero
    testing.expect(t,entity_id_next(&zero)!=0)
    a,b:=rng_make(2026),rng_make(2026)
    asset:=asset_id_random(&a)
    testing.expect(t,asset!={} && asset[0]!=asset[1])
    testing.expect_value(t,asset_id_random(&b),asset)
    testing.expect(t,asset_id_random(&a)!=asset)
}

@(test)
ids_round_trip_through_hex_text :: proc(t:^testing.T) {
    buffer:[ASSET_ID_TEXT]u8
    testing.expect_value(t,entity_id_format(Entity_Id(0x0123456789abcdef),buffer[:]),"0123456789abcdef")
    testing.expect_value(t,entity_id_format(Entity_Id(255),buffer[:]),"00000000000000ff")
    id,ok:=entity_id_parse("0123456789ABCDEF")
    testing.expect(t,ok && id==Entity_Id(0x0123456789abcdef))
    id,ok=entity_id_parse("ffffffffffffffff")
    testing.expect(t,ok && id==Entity_Id(max(u64)))
    for bad in ([4]string{"","123","0123456789abcdeg","0123456789abcdef0"}) {
        _,ok=entity_id_parse(bad)
        testing.expectf(t,!ok,"'%s' is not an id",bad)
    }
    testing.expect_value(t,entity_id_format(1,buffer[:15]),"")
    asset:=Asset_Id{0x0011223344556677,0x8899aabbccddeeff}
    text:=asset_id_format(asset,buffer[:])
    testing.expect_value(t,text,"00112233445566778899aabbccddeeff")
    parsed,parsed_ok:=asset_id_parse(text)
    testing.expect(t,parsed_ok && parsed==asset)
    _,parsed_ok=asset_id_parse(text[:31])
    testing.expect(t,!parsed_ok)
    _,parsed_ok=asset_id_parse("00112233445566778899aabbccddeefz")
    testing.expect(t,!parsed_ok)
    testing.expect_value(t,asset_id_format(asset,buffer[:31]),"")
    rng:=rng_make(5)
    for _ in 0..<200 {
        random:=asset_id_random(&rng)
        back,back_ok:=asset_id_parse(asset_id_format(random,buffer[:]))
        testing.expect(t,back_ok && back==random)
    }
}

@(test)
radix_sort32_orders_keys_and_keeps_equal_ones_in_place :: proc(t:^testing.T) {
    COUNT :: 5000
    items:=make([]Sort_Key32,COUNT);defer delete(items)
    scratch:=make([]Sort_Key32,COUNT);defer delete(scratch)
    rng:=rng_make(9)
    for &item,i in items {
        // Three ranges: keys that differ in every byte, in the low one only, and in the high one only.
        key:=rng_u32(&rng)
        switch i%3 {
        case 1: key&=0xff
        case 2: key&=0xff000000
        }
        item={key,u32(i)}
    }
    expected:=slice.clone(items);defer delete(expected)
    slice.stable_sort_by(expected,proc(a,b:Sort_Key32) -> bool {return a.key<b.key})
    radix_sort32(items,scratch)
    for item,i in items {
        if item!=expected[i] {testing.expectf(t,false,"item %d is %v, expected %v",i,item,expected[i]);break}
    }
}

@(test)
radix_sort64_orders_keys_and_skips_constant_digits :: proc(t:^testing.T) {
    COUNT :: 3000
    items:=make([]Sort_Key64,COUNT);defer delete(items)
    scratch:=make([]Sort_Key64,COUNT);defer delete(scratch)
    rng:=rng_make(10)
    for shift in ([3]uint{0,24,40}) {
        for &item,i in items {item={u64(rng_u32(&rng)&0xffffff)<<shift,u32(i)}}
        expected:=slice.clone(items);defer delete(expected)
        slice.stable_sort_by(expected,proc(a,b:Sort_Key64) -> bool {return a.key<b.key})
        radix_sort64(items,scratch)
        for item,i in items {
            if item!=expected[i] {testing.expectf(t,false,"shift %d: item %d is %v, expected %v",shift,i,item,expected[i]);break}
        }
    }
    for &item,i in items {item={rng_u64(&rng),u32(i)}}
    radix_sort64(items,scratch)
    for i in 1..<COUNT {
        if items[i-1].key>items[i].key {testing.expectf(t,false,"item %d is out of order",i);break}
    }
}

@(test)
radix_sort_handles_short_and_sorted_inputs :: proc(t:^testing.T) {
    radix_sort32(nil,nil)
    one:=[1]Sort_Key32{{5,0}}
    radix_sort32(one[:],nil)
    testing.expect_value(t,one[0],Sort_Key32{5,0})
    same:=[4]Sort_Key32{{7,0},{7,1},{7,2},{7,3}}
    scratch:[4]Sort_Key32
    radix_sort32(same[:],scratch[:])
    testing.expect_value(t,same,[4]Sort_Key32{{7,0},{7,1},{7,2},{7,3}})
    reversed:=[4]Sort_Key32{{0x04000000,0},{0x0300,1},{0x020000,2},{1,3}}
    radix_sort32(reversed[:],scratch[:])
    testing.expect_value(t,reversed,[4]Sort_Key32{{1,3},{0x0300,1},{0x020000,2},{0x04000000,0}})
}

@(test)
sort_keys_order_like_their_numbers :: proc(t:^testing.T) {
    floats:=[9]f32{min(f32),-1000.5,-1,-1e-30,0,1e-30,1,1000.5,max(f32)}
    for i in 1..<len(floats) {testing.expect(t,sort_key_f32(floats[i-1])<sort_key_f32(floats[i]))}
    testing.expect(t,sort_key_f32(-0.0)<=sort_key_f32(0.0))
    ints:=[5]i32{min(i32),-1,0,1,max(i32)}
    for i in 1..<len(ints) {testing.expect(t,sort_key_i32(ints[i-1])<sort_key_i32(ints[i]))}
    longs:=[5]i64{min(i64),-1,0,1,max(i64)}
    for i in 1..<len(longs) {testing.expect(t,sort_key_i64(longs[i-1])<sort_key_i64(longs[i]))}
}

@(test)
profile_records_nested_zones_in_the_order_they_end :: proc(t:^testing.T) {
    p:Profile
    testing.expect(t,profile_init(&p,{threads=2,zones_per_thread=4}));defer profile_destroy(&p)
    outer:=profile_begin(&p,0,"frame")
    inner:=profile_begin(&p,0,"physics")
    profile_end(inner)
    profile_frame(&p)
    {
        profile_zone(&p,0,"render")
    }
    profile_end(outer)
    {
        profile_zone(&p,1,"worker")
    }
    when PROFILE_COMPILED {
        zones:[8]Profile_Zone
        testing.expect_value(t,profile_read(&p,0,zones[:]),3)
        testing.expect_value(t,zones[0].name,"physics")
        testing.expect_value(t,zones[1].name,"render")
        testing.expect_value(t,zones[2].name,"frame")
        testing.expect_value(t,zones[0].depth,u16(1))
        testing.expect_value(t,zones[1].depth,u16(1))
        testing.expect_value(t,zones[2].depth,u16(0))
        testing.expect_value(t,zones[0].frame,u32(0))
        testing.expect_value(t,zones[1].frame,u32(1))
        testing.expect(t,zones[0].start>=zones[2].start && zones[0].duration>=0)
        testing.expect(t,zones[2].duration>=zones[0].duration+zones[1].duration)
        testing.expect(t,zones[0].start+zones[0].duration<=zones[1].start)
        testing.expect_value(t,profile_read(&p,1,zones[:]),1)
        testing.expect_value(t,zones[0].name,"worker")
        testing.expect_value(t,zones[0].thread,u16(1))
        testing.expect_value(t,profile_read(&p,0,zones[:2]),2)
        testing.expect_value(t,zones[0].name,"render")
        testing.expect_value(t,profile_read(&p,2,zones[:]),0)
    }
}

@(test)
profile_keeps_the_newest_zones_and_stops_when_disabled :: proc(t:^testing.T) {
    p:Profile
    testing.expect(t,profile_init(&p,{threads=1,zones_per_thread=3}));defer profile_destroy(&p)
    names:=[6]string{"a","b","c","d","e","f"}
    for name in names {profile_end(profile_begin(&p,0,name))}
    zones:[8]Profile_Zone
    when PROFILE_COMPILED {
        testing.expect_value(t,profile_read(&p,0,zones[:]),4)
        for zone,i in zones[:4] {testing.expect_value(t,zone.name,names[i+2])}
        testing.expect_value(t,profile_lost(&p,0),u64(2))
    }
    profile_clear(&p)
    testing.expect_value(t,profile_read(&p,0,zones[:]),0)
    profile_set_enabled(&p,false)
    scope:=profile_begin(&p,0,"ignored")
    testing.expect(t,scope.profile==nil)
    profile_end(scope)
    profile_end(profile_begin(nil,0,"no profile"))
    profile_end(profile_begin(&p,7,"no such thread"))
    testing.expect_value(t,profile_read(&p,0,zones[:]),0)
    profile_set_enabled(&p,true)
    profile_end(profile_begin(&p,5,"no such thread"))
    profile_end(profile_begin(&p,-1,"no such thread"))
    testing.expect_value(t,profile_read(&p,0,zones[:]),0)
    bad:Profile
    testing.expect(t,!profile_init(&bad,{threads=0,zones_per_thread=8}))
    testing.expect(t,!profile_init(&bad,{threads=1,zones_per_thread=0}))
    profile_end(profile_begin(&bad,0,"uninitialized"))
}

@(test)
profile_zones_measure_real_time :: proc(t:^testing.T) {
    p:Profile
    testing.expect(t,profile_init(&p,{threads=1,zones_per_thread=8}));defer profile_destroy(&p)
    scope:=profile_begin(&p,0,"sleep")
    time.sleep(20*time.Millisecond)
    profile_end(scope)
    when PROFILE_COMPILED {
        zones:[1]Profile_Zone
        testing.expect_value(t,profile_read(&p,0,zones[:]),1)
        milliseconds:=f64(zones[0].duration)/1e6
        testing.expectf(t,milliseconds>15 && milliseconds<2000,"a sleep of 20 ms was measured as %v ms",milliseconds)
        testing.expect(t,zones[0].start>=0 && zones[0].start<i64(time.Second))
    }
}
