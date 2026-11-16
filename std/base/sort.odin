package base

// Radix sort of integer keys that carry an index to whatever they order
// (draws, entities, pairs). Stable, linear in the number of items, and it
// allocates nothing: the caller supplies a scratch array of the same length.
// Without that scratch, or with more items than a u32 counts, nothing moves.

Sort_Key32 :: struct {key:u32,index:u32}
Sort_Key64 :: struct {key:u64,index:u32}

// Sorts items by ascending key; items with equal keys keep their order.
radix_sort32 :: proc "contextless" (items,scratch:[]Sort_Key32) {radix_sort_items(items,scratch,4)}
radix_sort64 :: proc "contextless" (items,scratch:[]Sort_Key64) {radix_sort_items(items,scratch,8)}

// Keys that sort like the numbers they come from.
sort_key_f32 :: #force_inline proc "contextless" (value:f32) -> u32 {
    bits:=transmute(u32)value
    return ~bits if bits&0x80000000!=0 else bits|0x80000000
}
sort_key_i32 :: #force_inline proc "contextless" (value:i32) -> u32 {return u32(value)~0x80000000}
sort_key_i64 :: #force_inline proc "contextless" (value:i64) -> u64 {return u64(value)~0x8000000000000000}

@(private)
radix_sort_items :: proc "contextless" (items,scratch:[]$T,$DIGITS:int) {
    count:=len(items)
    if count<2 || len(scratch)<count || count>int(max(u32)) {return}
    histograms:[DIGITS][256]u32
    #no_bounds_check for item in items {
        key:=item.key
        for digit in 0..<DIGITS {histograms[digit][(key>>uint(digit*8))&255]+=1}
    }
    source,target:=items,scratch[:count]
    #no_bounds_check for digit in 0..<DIGITS {
        histogram:=&histograms[digit]
        shift:=uint(digit*8)
        // A digit that is the same in every key leaves the order as it is.
        if histogram[(source[0].key>>shift)&255]==u32(count) {continue}
        offset:u32
        for bucket in 0..<256 {
            size:=histogram[bucket]
            histogram[bucket]=offset
            offset+=size
        }
        for item in source {
            bucket:=&histogram[(item.key>>shift)&255]
            target[bucket^]=item
            bucket^+=1
        }
        source,target=target,source
    }
    if raw_data(source)!=raw_data(items) {copy(items,source)}
}
