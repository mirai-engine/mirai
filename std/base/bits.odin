package base

import "base:intrinsics"

// Bit sets over a slice of 64-bit words owned by the caller: bit i is bit
// i%64 of word i/64. Bits past the size the caller has in mind must stay
// clear, since counting and iteration cover whole words. Bits beyond the
// words read as clear and writing them changes nothing.

bits_words :: #force_inline proc "contextless" (count:int) -> int {return (count-1)>>6+1 if count>0 else 0}

bits_test :: #force_inline proc "contextless" (bits:[]u64,index:int) -> bool {
    // Out of range it reads a zero word rather than returning early, so a caller's branch on the result can stay a conditional move.
    word:=uint(index)>>6
    none:u64
    #no_bounds_check at:=&bits[word] if word<uint(len(bits)) else &none
    return at^&(u64(1)<<uint(index&63))!=0
}
bits_set :: #force_inline proc "contextless" (bits:[]u64,index:int) {
    word:=uint(index)>>6
    if word<uint(len(bits)) {#no_bounds_check bits[word]|=u64(1)<<uint(index&63)}
}
bits_clear :: #force_inline proc "contextless" (bits:[]u64,index:int) {
    word:=uint(index)>>6
    if word<uint(len(bits)) {#no_bounds_check bits[word]&~=u64(1)<<uint(index&63)}
}
bits_toggle :: #force_inline proc "contextless" (bits:[]u64,index:int) {
    word:=uint(index)>>6
    if word<uint(len(bits)) {#no_bounds_check bits[word]~=u64(1)<<uint(index&63)}
}
bits_assign :: #force_inline proc "contextless" (bits:[]u64,index:int,value:bool) {
    if value {bits_set(bits,index)} else {bits_clear(bits,index)}
}

@(private)
bits_range_mask :: #force_inline proc "contextless" (first,last:int) -> u64 {
    // Bits first..=last of one word.
    return (~u64(0)<<uint(first))&(~u64(0)>>uint(63-last))
}
// The bits of first..<first+count that are inside the words, as from..=last.
@(private)
bits_range_clip :: #force_inline proc "contextless" (bits:[]u64,first,count:int) -> (from,last:int,ok:bool) {
    size:=len(bits)<<6
    if count<=0 {return}
    end:=size if first>size-count else first+count
    from=max(first,0)
    return from,end-1,from<end
}
bits_set_range :: proc "contextless" (bits:[]u64,first,count:int) {
    from,last,ok:=bits_range_clip(bits,first,count)
    if !ok {return}
    a,b:=from>>6,last>>6
    if a==b {bits[a]|=bits_range_mask(from&63,last&63);return}
    bits[a]|=bits_range_mask(from&63,63)
    for word in a+1..<b {bits[word]=~u64(0)}
    bits[b]|=bits_range_mask(0,last&63)
}
bits_clear_range :: proc "contextless" (bits:[]u64,first,count:int) {
    from,last,ok:=bits_range_clip(bits,first,count)
    if !ok {return}
    a,b:=from>>6,last>>6
    if a==b {bits[a]&~=bits_range_mask(from&63,last&63);return}
    bits[a]&~=bits_range_mask(from&63,63)
    for word in a+1..<b {bits[word]=0}
    bits[b]&~=bits_range_mask(0,last&63)
}
bits_clear_all :: proc "contextless" (bits:[]u64) {
    for &word in bits {word=0}
}

bits_count :: proc "contextless" (bits:[]u64) -> int {
    total:=0
    for word in bits {total+=int(intrinsics.count_ones(word))}
    return total
}
bits_any :: proc "contextless" (bits:[]u64) -> bool {
    for word in bits {if word!=0 {return true}}
    return false
}
// First set bit at or after `from`.
bits_next :: proc "contextless" (bits:[]u64,from:int) -> (index:int,ok:bool) {
    if from<0 {return bits_next(bits,0)}
    word:=from>>6
    if word>=len(bits) {return -1,false}
    current:=bits[word]&(~u64(0)<<uint(from&63))
    for {
        if current!=0 {return word<<6+int(intrinsics.count_trailing_zeros(current)),true}
        word+=1
        if word>=len(bits) {return -1,false}
        current=bits[word]
    }
}
bits_first :: proc "contextless" (bits:[]u64) -> (index:int,ok:bool) {return bits_next(bits,0)}
// First clear bit below count.
bits_first_clear :: proc "contextless" (bits:[]u64,count:int) -> (index:int,ok:bool) {
    for word,i in bits {
        if word==~u64(0) {continue}
        index=i<<6+int(intrinsics.count_trailing_zeros(~word))
        if index>=count {return -1,false}
        return index,true
    }
    return -1,false
}

// Over the words that dst, a and b all have; the rest of dst is left as it was.
bits_and :: proc "contextless" (dst,a,b:[]u64) {
    #no_bounds_check for i in 0..<min(len(dst),len(a),len(b)) {dst[i]=a[i]&b[i]}
}
bits_or :: proc "contextless" (dst,a,b:[]u64) {
    #no_bounds_check for i in 0..<min(len(dst),len(a),len(b)) {dst[i]=a[i]|b[i]}
}
bits_xor :: proc "contextless" (dst,a,b:[]u64) {
    #no_bounds_check for i in 0..<min(len(dst),len(a),len(b)) {dst[i]=a[i]~b[i]}
}
// The bits of a that are not in b.
bits_and_not :: proc "contextless" (dst,a,b:[]u64) {
    #no_bounds_check for i in 0..<min(len(dst),len(a),len(b)) {dst[i]=a[i]&~b[i]}
}

// Visits the set bits in ascending order, one word at a time:
//     it:=bits_iterator(bits)
//     for index in bits_iterate(&it) {...}
// Bits changed during the visit are seen only in words not reached yet.
Bits_Iterator :: struct {
    bits:[]u64,
    current:u64, // bits of the word being visited that are still to report
    word:int,
}
bits_iterator :: proc "contextless" (bits:[]u64) -> Bits_Iterator {
    return {bits,bits[0] if len(bits)>0 else 0,0}
}
bits_iterate :: #force_inline proc "contextless" (it:^Bits_Iterator) -> (index:int,ok:bool) {
    for it.current==0 {
        it.word+=1
        if it.word>=len(it.bits) {return -1,false}
        #no_bounds_check it.current=it.bits[it.word]
    }
    index=it.word<<6+int(intrinsics.count_trailing_zeros(it.current))
    it.current&=it.current-1
    return index,true
}
