package base

import "core:testing"

@(test)
bits_set_clear_and_test_single_bits :: proc(t:^testing.T) {
    testing.expect_value(t,bits_words(0),0)
    testing.expect_value(t,bits_words(1),1)
    testing.expect_value(t,bits_words(64),1)
    testing.expect_value(t,bits_words(65),2)
    bits:[3]u64
    for index in ([5]int{0,63,64,100,191}) {
        testing.expect(t,!bits_test(bits[:],index))
        bits_set(bits[:],index)
        testing.expect(t,bits_test(bits[:],index))
    }
    testing.expect_value(t,bits_count(bits[:]),5)
    bits_clear(bits[:],63)
    bits_toggle(bits[:],64)
    bits_toggle(bits[:],65)
    bits_assign(bits[:],100,false)
    bits_assign(bits[:],101,true)
    testing.expect(t,!bits_test(bits[:],63) && !bits_test(bits[:],64) && bits_test(bits[:],65))
    testing.expect(t,!bits_test(bits[:],100) && bits_test(bits[:],101))
    testing.expect_value(t,bits_count(bits[:]),4)
    testing.expect(t,bits_any(bits[:]))
    bits_clear_all(bits[:])
    testing.expect(t,!bits_any(bits[:]))
}

@(test)
bits_ranges_cover_word_boundaries :: proc(t:^testing.T) {
    bits:[4]u64
    bits_set_range(bits[:],60,70)
    for index in 0..<256 {
        if bits_test(bits[:],index)!=(index>=60 && index<130) {testing.expectf(t,false,"bit %d",index);break}
    }
    bits_clear_range(bits[:],64,64)
    testing.expect_value(t,bits_count(bits[:]),6)
    testing.expect(t,bits_test(bits[:],63) && !bits_test(bits[:],64) && !bits_test(bits[:],127) && bits_test(bits[:],128))
    bits_set_range(bits[:],5,3)
    bits_set_range(bits[:],200,0)
    bits_clear_range(bits[:],6,1)
    testing.expect(t,bits_test(bits[:],5) && !bits_test(bits[:],6) && bits_test(bits[:],7) && !bits_test(bits[:],8))
    bits_set_range(bits[:],0,256)
    testing.expect_value(t,bits_count(bits[:]),256)
    index,ok:=bits_first_clear(bits[:],256)
    testing.expect(t,!ok && index==-1)
    bits_clear(bits[:],77)
    index,ok=bits_first_clear(bits[:],256)
    testing.expect(t,ok && index==77)
    index,ok=bits_first_clear(bits[:],77)
    testing.expect(t,!ok,"The first clear bit is beyond the size asked about")
}

@(test)
bits_iterate_visits_set_bits_in_order :: proc(t:^testing.T) {
    bits:[3]u64
    expected:=[7]int{0,1,63,64,129,130,191}
    for index in expected {bits_set(bits[:],index)}
    seen:=0
    it:=bits_iterator(bits[:])
    for index in bits_iterate(&it) {
        if seen<len(expected) {testing.expect_value(t,index,expected[seen])}
        seen+=1
    }
    testing.expect_value(t,seen,len(expected))
    index,ok:=bits_first(bits[:])
    testing.expect(t,ok && index==0)
    index,ok=bits_next(bits[:],2)
    testing.expect(t,ok && index==63)
    index,ok=bits_next(bits[:],65)
    testing.expect(t,ok && index==129)
    index,ok=bits_next(bits[:],191)
    testing.expect(t,ok && index==191)
    index,ok=bits_next(bits[:],192)
    testing.expect(t,!ok)
    index,ok=bits_next(bits[:],-5)
    testing.expect(t,ok && index==0)
    none:=bits_iterator(nil)
    _,ok=bits_iterate(&none)
    testing.expect(t,!ok)
    empty:[2]u64
    none=bits_iterator(empty[:])
    _,ok=bits_iterate(&none)
    testing.expect(t,!ok)
    _,ok=bits_first(empty[:])
    testing.expect(t,!ok)
}

@(test)
bits_combine_whole_sets :: proc(t:^testing.T) {
    a:=[2]u64{0b1100,0xff00}
    b:=[2]u64{0b1010,0x0ff0}
    out:[2]u64
    bits_and(out[:],a[:],b[:])
    testing.expect_value(t,out,[2]u64{0b1000,0x0f00})
    bits_or(out[:],a[:],b[:])
    testing.expect_value(t,out,[2]u64{0b1110,0xfff0})
    bits_xor(out[:],a[:],b[:])
    testing.expect_value(t,out,[2]u64{0b0110,0xf0f0})
    bits_and_not(out[:],a[:],b[:])
    testing.expect_value(t,out,[2]u64{0b0100,0xf000})
}

@(test)
hash_map_stores_every_key_including_zero :: proc(t:^testing.T) {
    m:Hash_Map(int)
    testing.expect(t,hash_map_init(&m,4));defer hash_map_destroy(&m)
    testing.expect(t,hash_map_set(&m,0,100))
    testing.expect(t,hash_map_set(&m,1,101))
    testing.expect(t,hash_map_set(&m,max(u64),102))
    testing.expect(t,hash_map_set(&m,1,111),"Setting a present key replaces its value")
    testing.expect_value(t,m.count,3)
    testing.expect_value(t,hash_map_get(&m,0),100)
    testing.expect_value(t,hash_map_get(&m,1),111)
    testing.expect_value(t,hash_map_get(&m,max(u64)),102)
    _,found:=hash_map_get(&m,2)
    testing.expect(t,!found && !hash_map_contains(&m,2) && hash_map_ptr(&m,2)==nil)
    testing.expect(t,hash_map_set(&m,2,103))
    testing.expect(t,!hash_map_set(&m,3,104),"The map is full")
    testing.expect_value(t,m.failed,u64(1))
    testing.expect(t,hash_map_set(&m,2,113),"A full map still updates its keys")
    hash_map_ptr(&m,0)^+=1
    value,removed:=hash_map_remove(&m,0)
    testing.expect(t,removed && value==101)
    _,removed=hash_map_remove(&m,0)
    testing.expect(t,!removed)
    slot,inserted:=hash_map_insert(&m,7)
    testing.expect(t,inserted && slot^==0)
    slot^=77
    slot,inserted=hash_map_insert(&m,7)
    testing.expect(t,!inserted && slot^==77)
    keys,sum:=0,0
    it:=hash_map_iterator(&m)
    for key,entry in hash_map_iterate(&it) {
        keys+=1;sum+=entry^
        testing.expect_value(t,hash_map_get(&m,key),entry^)
    }
    testing.expect_value(t,keys,4)
    testing.expect_value(t,sum,111+102+113+77)
    hash_map_clear(&m)
    testing.expect(t,m.count==0 && !hash_map_contains(&m,1) && !hash_map_contains(&m,0))
    it=hash_map_iterator(&m)
    _,_,any:=hash_map_iterate(&it)
    testing.expect(t,!any)
    empty:Hash_Map(int)
    testing.expect(t,!hash_map_init(&empty,0))
    testing.expect(t,!hash_map_set(&empty,1,1) && !hash_map_contains(&empty,1) && !hash_map_contains(&empty,0))
}

@(test)
hash_map_matches_a_model_under_random_edits :: proc(t:^testing.T) {
    CAPACITY :: 512
    m:Hash_Map(u64)
    testing.expect(t,hash_map_init(&m,CAPACITY));defer hash_map_destroy(&m)
    model:=make(map[u64]u64);defer delete(model)
    rng:=rng_make(3)
    for step in 0..<60000 {
        // Few distinct keys, many of them multiples of the slot count: long probe chains and frequent removals.
        key:=u64(rng_u32(&rng)%700)*(1024 if step&1==0 else 1)
        switch rng_u32(&rng)%3 {
        case 0,1:
            value:=rng_u64(&rng)
            _,present:=model[key]
            ok:=hash_map_set(&m,key,value)
            if ok!=(present || len(model)<CAPACITY) {testing.expectf(t,false,"step %d: set returned %v",step,ok);return}
            if ok {model[key]=value}
        case 2:
            expected,present:=model[key]
            value,found:=hash_map_remove(&m,key)
            if found!=present || (found && value!=expected) {testing.expectf(t,false,"step %d: remove of %d",step,key);return}
            delete_key(&model,key)
        }
        if step%251!=0 {continue}
        if m.count!=len(model) {testing.expectf(t,false,"step %d: %d entries, expected %d",step,m.count,len(model));return}
        for model_key,model_value in model {
            value,found:=hash_map_get(&m,model_key)
            if !found || value!=model_value {testing.expectf(t,false,"step %d: key %d",step,model_key);return}
        }
        visited:=0
        it:=hash_map_iterator(&m)
        for visited_key,value in hash_map_iterate(&it) {
            visited+=1
            if model[visited_key]!=value^ {testing.expectf(t,false,"step %d: iteration found %d",step,visited_key);return}
        }
        testing.expect_value(t,visited,len(model))
    }
    testing.expect(t,m.failed>0,"The run filled the map at some point")
}

@(test)
lru_evicts_the_entry_used_least_recently :: proc(t:^testing.T) {
    c:Lru(string)
    testing.expect(t,lru_init(&c,3));defer lru_destroy(&c)
    _,_,evicted:=lru_put(&c,1,"one")
    testing.expect(t,!evicted)
    lru_put(&c,2,"two")
    lru_put(&c,3,"three")
    testing.expect_value(t,lru_get(&c,1)^,"one")
    key,value,was_evicted:=lru_put(&c,4,"four")
    testing.expect(t,was_evicted && key==2 && value=="two","2 was the one unused for longest")
    testing.expect(t,lru_get(&c,2)==nil)
    testing.expect_value(t,lru_len(&c),3)
    // Peeking does not protect an entry; putting it again does.
    testing.expect_value(t,lru_peek(&c,3)^,"three")
    lru_put(&c,1,"uno")
    key,_,was_evicted=lru_put(&c,5,"five")
    testing.expect(t,was_evicted && key==3)
    testing.expect_value(t,lru_get(&c,1)^,"uno")
    oldest,_,ok:=lru_oldest(&c)
    testing.expect(t,ok && oldest==4)
    removed,found:=lru_remove(&c,4)
    testing.expect(t,found && removed=="four")
    _,found=lru_remove(&c,4)
    testing.expect(t,!found)
    _,_,was_evicted=lru_put(&c,6,"six")
    testing.expect(t,!was_evicted,"The removed entry left room")
    testing.expect_value(t,c.hits,u64(2))
    testing.expect_value(t,c.misses,u64(1))
    testing.expect_value(t,c.evictions,u64(2))
    lru_clear(&c)
    testing.expect(t,lru_len(&c)==0 && lru_get(&c,1)==nil)
    _,_,ok=lru_oldest(&c)
    testing.expect(t,!ok)
    for i in 0..<10 {lru_put(&c,u64(i),"x")}
    testing.expect_value(t,lru_len(&c),3)
    for i in 7..<10 {testing.expect(t,lru_peek(&c,u64(i))!=nil)}
    empty:Lru(int)
    testing.expect(t,!lru_init(&empty,0))
    _,_,was_evicted=lru_put(&empty,1,1)
    testing.expect(t,!was_evicted && lru_get(&empty,1)==nil)
    _,_,ok=lru_oldest(&empty)
    testing.expect(t,!ok)
}

@(test)
intern_gives_equal_strings_the_same_symbol :: proc(t:^testing.T) {
    table:Interner
    testing.expect(t,intern_init(&table,3,16));defer intern_destroy(&table)
    position,ok:=intern_add(&table,"position")
    testing.expect(t,ok && position!=0)
    scale,_:=intern_add(&table,"scale")
    testing.expect(t,scale!=position)
    buffer:=[8]u8{'p','o','s','i','t','i','o','n'}
    again,_:=intern_add(&table,string(buffer[:]))
    testing.expect_value(t,again,position)
    testing.expect_value(t,intern_string(&table,position),"position")
    testing.expect_value(t,intern_string(&table,scale),"scale")
    testing.expect_value(t,intern_hash(&table,scale),name_hash("scale"))
    testing.expect(t,raw_data(intern_string(&table,position))!=raw_data(buffer[:]),"The table keeps its own copy")
    empty,empty_ok:=intern_add(&table,"")
    testing.expect(t,empty_ok && empty==0)
    testing.expect_value(t,intern_string(&table,0),"")
    testing.expect_value(t,intern_hash(&table,0),name_hash(""))
    testing.expect_value(t,intern_string(&table,99),"")
    found,present:=intern_find(&table,"scale")
    testing.expect(t,present && found==scale)
    _,present=intern_find(&table,"rotation")
    testing.expect(t,!present)
    _,ok=intern_add(&table,"rotation")
    testing.expect(t,!ok,"Only 3 bytes are left")
    testing.expect_value(t,table.failed,u64(1))
    _,ok=intern_add(&table,"rot")
    testing.expect(t,ok)
    _,ok=intern_add(&table,"x")
    testing.expect(t,!ok,"Three strings were the limit")
    testing.expect_value(t,table.count,3)
    intern_clear(&table)
    _,present=intern_find(&table,"scale")
    testing.expect(t,!present)
    first,_:=intern_add(&table,"scale")
    testing.expect_value(t,first,Symbol(1))
    none:Interner
    testing.expect(t,!intern_init(&none,0,10))
    _,ok=intern_add(&none,"a")
    testing.expect(t,!ok)
    _,present=intern_find(&none,"a")
    testing.expect(t,!present)
}

@(test)
intern_tells_apart_many_names :: proc(t:^testing.T) {
    COUNT :: 500
    table:Interner
    testing.expect(t,intern_init(&table,COUNT,COUNT*8));defer intern_destroy(&table)
    symbols:[COUNT]Symbol
    name:[16]u8
    for i in 0..<COUNT {
        text_format(name[:],"n%d",i*7919)
        ok:bool
        symbols[i],ok=intern_add(&table,text_get(name[:]))
        testing.expect(t,ok)
    }
    for i in 0..<COUNT {
        text_format(name[:],"n%d",i*7919)
        found,present:=intern_find(&table,text_get(name[:]))
        if !present || found!=symbols[i] || intern_string(&table,found)!=text_get(name[:]) {testing.expectf(t,false,"name %d",i);break}
    }
    testing.expect_value(t,table.count,COUNT)
}

@(test)
text_keeps_utf8_whole_and_padding_zeroed :: proc(t:^testing.T) {
    name:[8]u8
    testing.expect(t,text_set(name[:],"Lamp"))
    testing.expect_value(t,text_get(name[:]),"Lamp")
    testing.expect_value(t,text_len(name[:]),4)
    testing.expect(t,text_equal(name[:],"Lamp") && !text_equal(name[:],"Lam"))
    testing.expect(t,!text_set(name[:],"Lighthouse"),"Seven bytes fit, the eighth is the NUL")
    testing.expect_value(t,text_get(name[:]),"Lightho")
    testing.expect_value(t,name[7],u8(0))
    // "ñ" takes two bytes: one that does not fit whole is left out.
    testing.expect(t,!text_set(name[:],"mañanañ"))
    testing.expect_value(t,text_get(name[:]),"mañana")
    testing.expect(t,text_set(name[:],"año"))
    testing.expect_value(t,name,[8]u8{'a',0xc3,0xb1,'o',0,0,0,0})
    other:[8]u8
    text_set(other[:],"Lighthouse");text_set(other[:],"año")
    testing.expect_value(t,other,name)
    text_clear(name[:])
    testing.expect_value(t,text_get(name[:]),"")
    full:=[4]u8{'a','b','c','d'}
    testing.expect_value(t,text_get(full[:]),"abcd")
    testing.expect(t,text_set(nil,"") && !text_set(nil,"a"))
}

@(test)
text_compares_appends_and_formats :: proc(t:^testing.T) {
    a,b:[16]u8
    text_set(a[:],"apple");text_set(b[:],"apricot")
    testing.expect_value(t,text_compare(a[:],b[:]),-1)
    testing.expect_value(t,text_compare(b[:],a[:]),1)
    testing.expect_value(t,text_compare(a[:],a[:]),0)
    text_set(b[:],"app")
    testing.expect_value(t,text_compare(a[:],b[:]),1)
    testing.expect(t,text_append(b[:],"le"))
    testing.expect_value(t,text_compare(a[:],b[:]),0)
    testing.expect(t,!text_append(b[:],"_and_more_text"))
    testing.expect_value(t,text_get(b[:]),"apple_and_more_")
    testing.expect(t,!text_append(b[:],"x") && text_append(b[:],""))
    testing.expect(t,text_format(a[:],"%s_%d","cube",12))
    testing.expect_value(t,text_get(a[:]),"cube_12")
    for byte in a[7:] {testing.expect_value(t,byte,u8(0))}
    testing.expect(t,!text_format(a[:],"%s","a_name_longer_than_the_array"))
    testing.expect_value(t,text_get(a[:]),"a_name_longer_t")
    small:[4]u8
    testing.expect(t,!text_format(small[:],"%s","añño"))
    testing.expect_value(t,text_get(small[:]),"añ")
    testing.expect(t,text_format(small[:],"%d",123))
    testing.expect(t,!text_format(small[:],"%d",1234))
    testing.expect_value(t,text_get(small[:]),"123")
    testing.expect(t,!text_format(nil,"x"))
}

@(test)
a_hash_map_grows_keeping_every_entry :: proc(t:^testing.T) {
    m:Hash_Map(int)
    testing.expect(t,hash_map_init(&m,4))
    defer hash_map_destroy(&m)
    for key in 0..<4 {testing.expect(t,hash_map_set(&m,u64(key)*7919,key))}
    testing.expect(t,!hash_map_set(&m,99,99))
    testing.expect(t,hash_map_grow(&m,64))
    testing.expect(t,m.capacity==64 && m.count==4 && m.failed==1 && m.peak==4)
    for key in 0..<4 {testing.expect_value(t,hash_map_get(&m,u64(key)*7919),key)}
    for key in 4..<64 {testing.expect(t,hash_map_set(&m,u64(key)*7919,key))}
    testing.expect(t,!hash_map_set(&m,1,1) && hash_map_grow(&m,8) && m.capacity==64)
    _,found:=hash_map_get(&m,0)
    testing.expect(t,found)
}
