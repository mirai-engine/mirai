package ui

import "base:runtime"
import "core:math/bits"
import "core:slice"
import "mirai:std/base"

// Kerning read from the GPOS table of a font: the pair adjustments of the
// lookups of the 'kern' feature of the Latin, Greek and Cyrillic scripts
// (PairPos formats 1 and 2, also behind Extension lookups), for the glyphs
// of the atlas. It moves
// the pen between two glyphs and substitutes nothing. Only the X advance of
// the first glyph of a pair is read, which is what kerning puts there.

Kerning :: struct {
    left,right:[FONT_GLYPHS]u16, // class of each glyph of the atlas as the first and as the second of a pair
    columns:int,                 // classes of second glyphs
    values:[]i16,                // font units: left class * columns + right class
}

@(private="file")
Font_Reader :: struct {
    data:[]byte,
    ok:bool,
}
@(private="file")
read_u16 :: proc "contextless" (r:^Font_Reader,at:int) -> int {
    if at<0 || at+2>len(r.data) {r.ok=false;return 0}
    return int(r.data[at])<<8|int(r.data[at+1])
}
@(private="file")
read_i16 :: proc "contextless" (r:^Font_Reader,at:int) -> int {
    return int(i16(u16(read_u16(r,at))))
}
@(private="file")
read_u32 :: proc "contextless" (r:^Font_Reader,at:int) -> int {
    return read_u16(r,at)<<16|read_u16(r,at+2)
}
@(private="file")
read_tag :: proc "contextless" (r:^Font_Reader,at:int) -> string {
    if at<0 || at+4>len(r.data) {r.ok=false;return ""}
    return string(r.data[at:][:4])
}

// Where a table of the font starts and how long it is; empty when absent.
@(private="file")
font_table :: proc "contextless" (data:[]byte,tag:string) -> []byte {
    r:=Font_Reader{data=data,ok=true}
    count:=read_u16(&r,4)
    for i in 0..<count {
        record:=12+i*16
        if read_tag(&r,record)!=tag {continue}
        offset,length:=read_u32(&r,record+8),read_u32(&r,record+12)
        if !r.ok || offset+length>len(data) {return nil}
        return data[offset:][:length]
    }
    return nil
}

// Index of glyph in a Coverage table, or -1.
@(private="file")
coverage_index :: proc "contextless" (r:^Font_Reader,table,glyph:int) -> int {
    count:=read_u16(r,table+2)
    lo,hi:=0,count-1
    switch read_u16(r,table) {
    case 1:
        for lo<=hi && r.ok {
            mid:=(lo+hi)/2
            value:=read_u16(r,table+4+mid*2)
            if value==glyph {return mid}
            if value<glyph {lo=mid+1} else {hi=mid-1}
        }
    case 2:
        for lo<=hi && r.ok {
            mid:=(lo+hi)/2
            record:=table+4+mid*6
            if glyph<read_u16(r,record) {hi=mid-1;continue}
            if glyph>read_u16(r,record+2) {lo=mid+1;continue}
            return read_u16(r,record+4)+glyph-read_u16(r,record)
        }
    }
    return -1
}

// Class of glyph in a ClassDef table; 0 for the glyphs it does not list.
@(private="file")
class_of :: proc "contextless" (r:^Font_Reader,table,glyph:int) -> int {
    switch read_u16(r,table) {
    case 1:
        start,count:=read_u16(r,table+2),read_u16(r,table+4)
        if glyph>=start && glyph<start+count {return read_u16(r,table+6+(glyph-start)*2)}
    case 2:
        lo,hi:=0,read_u16(r,table+2)-1
        for lo<=hi && r.ok {
            mid:=(lo+hi)/2
            record:=table+4+mid*6
            if glyph<read_u16(r,record) {hi=mid-1;continue}
            if glyph>read_u16(r,record+2) {lo=mid+1;continue}
            return read_u16(r,record+4)
        }
    }
    return 0
}

// The feature lookups of the default languages of the scripts of the atlas,
// 'latn', 'grek' and 'cyrl', or else of 'DFLT'. A lookup that several
// scripts share counts once.
@(private="file")
kern_lookups :: proc(r:^Font_Reader,lookups:[]bool) {
    scripts,features:=read_u16(r,4),read_u16(r,6)
    found:=false
    for wanted in ([4]string{"latn","grek","cyrl","DFLT"}) {
        if wanted=="DFLT" && found {break}
        language:=-1
        for i in 0..<read_u16(r,scripts) {
            record:=scripts+2+i*6
            if read_tag(r,record)!=wanted {continue}
            script:=scripts+read_u16(r,record+4)
            if offset:=read_u16(r,script);offset!=0 {language=script+offset}
        }
        if language<0 {continue}
        found=true
        for i in 0..<read_u16(r,language+4) {
            feature:=read_u16(r,language+6+i*2)
            record:=features+2+feature*6
            if feature>=read_u16(r,features) || read_tag(r,record)!="kern" {continue}
            table:=features+read_u16(r,record+4)
            for k in 0..<read_u16(r,table+2) {
                if lookup:=read_u16(r,table+4+k*2);lookup<len(lookups) {lookups[lookup]=true}
            }
        }
    }
}

// Reads the kerning of the glyphs of the atlas (glyphs: their glyph ids, 0
// where the font has none). False when the font has no kerning there; a
// table that does not parse counts as none. A transaction: it allocates the
// values with allocator.
font_kerning_read :: proc(kerning:^Kerning,data:[]byte,glyphs:[]u16,allocator:runtime.Allocator) -> bool {
    kerning^={}
    r:=Font_Reader{data=font_table(data,"GPOS"),ok=true}
    if len(r.data)==0 || read_u16(&r,0)!=1 {return false}
    lookup_list:=read_u16(&r,8)
    lookup_count:=read_u16(&r,lookup_list)
    if !r.ok || lookup_count==0 {return false}
    N :: FONT_GLYPHS
    lookups:=make([]bool,lookup_count,context.temp_allocator)
    totals:=make([]i32,N*N,context.temp_allocator)
    decided:=make([]bool,N*N,context.temp_allocator)
    classes:=make([]int,N,context.temp_allocator)
    row_values:=make([dynamic]i32,context.temp_allocator)
    // Glyph ids to the glyphs of the atlas that have them: the first one and the next.
    first_of:=make([]i16,65536,context.temp_allocator)
    next_of:=make([]i16,N,context.temp_allocator)
    if lookups==nil || totals==nil || decided==nil || classes==nil || first_of==nil || next_of==nil {return false}
    slice.fill(first_of,-1)
    for a:=N-1;a>=0;a-=1 {
        if glyphs[a]==0 {continue}
        next_of[a]=first_of[glyphs[a]]
        first_of[glyphs[a]]=i16(a)
    }
    kern_lookups(&r,lookups)
    for wanted,lookup_index in lookups {
        if !wanted {continue}
        lookup:=lookup_list+read_u16(&r,lookup_list+2+lookup_index*2)
        kind:=read_u16(&r,lookup)
        slice.fill(decided,false)
        for s in 0..<read_u16(&r,lookup+4) {
            sub:=lookup+read_u16(&r,lookup+6+s*2)
            sub_kind:=kind
            if kind==9 && read_u16(&r,sub)==1 {sub_kind=read_u16(&r,sub+2);sub+=read_u32(&r,sub+4)}
            if sub_kind!=2 || !r.ok {continue}
            format:=read_u16(&r,sub)
            coverage:=sub+read_u16(&r,sub+2)
            first,second:=read_u16(&r,sub+4),read_u16(&r,sub+6)
            size1:=2*int(bits.count_ones(u16(first&0xff)))
            size2:=2*int(bits.count_ones(u16(second&0xff)))
            // The X advance follows the X and Y placements a record has.
            advance:=2*int(bits.count_ones(u16(first&0x3))) if first&0x4!=0 else -1
            class1_count,class2_count:int
            if format==2 {
                class1_count,class2_count=read_u16(&r,sub+12),read_u16(&r,sub+14)
                for b in 0..<N {classes[b]=class_of(&r,sub+read_u16(&r,sub+10),int(glyphs[b])) if glyphs[b]!=0 else -1}
            }
            for a in 0..<N {
                if glyphs[a]==0 {continue}
                index:=coverage_index(&r,coverage,int(glyphs[a]))
                if index<0 {continue}
                row:=a*N
                switch format {
                case 1:
                    if index>=read_u16(&r,sub+8) {continue}
                    set:=sub+read_u16(&r,sub+10+index*2)
                    stride:=2+size1+size2
                    for k in 0..<read_u16(&r,set) {
                        record:=set+2+k*stride
                        for b:=int(first_of[read_u16(&r,record)]);b>=0;b=int(next_of[b]) {
                            if decided[row+b] {continue}
                            if advance>=0 {totals[row+b]+=i32(read_i16(&r,record+2+advance))}
                            decided[row+b]=true
                        }
                    }
                case 2:
                    class1:=class_of(&r,sub+read_u16(&r,sub+8),int(glyphs[a]))
                    if class1>=class1_count {continue}
                    if resize(&row_values,class2_count+1)!=nil {return false}
                    row_values[class2_count]=0
                    for c in 0..<class2_count {
                        row_values[c]=i32(read_i16(&r,sub+16+(class1*class2_count+c)*(size1+size2)+advance)) if advance>=0 else 0
                    }
                    for b in 0..<N {
                        if classes[b]<0 || decided[row+b] {continue}
                        decided[row+b]=true
                        totals[row+b]+=row_values[min(classes[b],class2_count)]
                    }
                }
                if !r.ok {return false}
            }
        }
        if !r.ok {return false}
    }
    // Glyphs with the same row share a left class and those with the same
    // column a right class: the table keeps one value per pair of classes.
    any:=false
    for value in totals {if value!=0 {any=true;break}}
    if !any {return false}
    rows:=make([]int,N,context.temp_allocator)    // first glyph of each left class
    columns:=make([]int,N,context.temp_allocator) // first glyph of each right class
    // Classes are compared by a hash of their values first.
    row_hashes:=make([]u64,N,context.temp_allocator)
    column_hashes:=make([]u64,N,context.temp_allocator)
    if rows==nil || columns==nil || row_hashes==nil || column_hashes==nil {return false}
    row_count,column_count:=0,0
    for a in 0..<N {
        hash:=base.HASH_SEED
        for value in totals[a*N:][:N] {hash=base.hash_mix(hash,u64(u32(value)))}
        class:=-1
        for c in 0..<row_count {
            if row_hashes[c]==hash && slice.equal(totals[rows[c]*N:][:N],totals[a*N:][:N]) {class=c;break}
        }
        if class<0 {class=row_count;rows[row_count]=a;row_hashes[row_count]=hash;row_count+=1}
        kerning.left[a]=u16(class)
    }
    same_column :: proc "contextless" (totals:[]i32,rows:[]int,x,y:int) -> bool {
        for row in rows {if totals[row*FONT_GLYPHS+x]!=totals[row*FONT_GLYPHS+y] {return false}}
        return true
    }
    for b in 0..<N {
        hash:=base.HASH_SEED
        for row in rows[:row_count] {hash=base.hash_mix(hash,u64(u32(totals[row*N+b])))}
        class:=-1
        for c in 0..<column_count {
            if column_hashes[c]==hash && same_column(totals,rows[:row_count],columns[c],b) {class=c;break}
        }
        if class<0 {class=column_count;columns[column_count]=b;column_hashes[column_count]=hash;column_count+=1}
        kerning.right[b]=u16(class)
    }
    error:runtime.Allocator_Error
    if kerning.values,error=make([]i16,row_count*column_count,allocator);error!=nil {kerning^={};return false}
    for c in 0..<row_count {
        for k in 0..<column_count {
            kerning.values[c*column_count+k]=i16(clamp(totals[rows[c]*N+columns[k]],i32(min(i16)),i32(max(i16))))
        }
    }
    kerning.columns=column_count
    return true
}
