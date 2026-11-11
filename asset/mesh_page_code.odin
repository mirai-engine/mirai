package asset

import "base:intrinsics"
import "core:mem"
import "core:slice"
import "mirai:std/base"
import "mirai:std/compressor"
import "mirai:std/compressor/lz"

// How page_data stores the block of a page (mesh_page_layout): LZ over
// its words as they are (Mesh_Page.coded_bytes 0) or over a coding of them,
// whichever LZ makes smaller. The coding writes every field of the words
// as whole bytes and gathers the bytes of each field in a slot of its own,
// its low bytes and then its high bytes, so that LZ meets values of one
// kind together. The runs are the clusters of the page, one shorter than
// PAGE_RUN_MERGE with the next.
//
//   u16 run count, and of each run u16 vertices and u16 words of triangles
//   u32 bytes of the headers, and of each slot u32 low bytes and u32 high bytes
//   the headers: of each stream but the triangles, of each run, of each set
//     of fields a byte (PAGE_SHARED, and the bytes of each ref from bit 1),
//     then of each field a byte (PAGE_DELTA, and the bytes of each code from
//     bit 1) and its base (1 byte for a field of 8 bits, else 2)
//   the slots: the refs of every set, then the fields of each stream
//   the bytes of the triangles of each run, coded
//   the tangent and normal of each vertex as they are, PAGE_KEPT bytes
//
// A value is the base plus its code, modulo the size of the field; with
// PAGE_DELTA, the value before it (the base for the first) plus the code
// unzigzagged. With PAGE_SHARED, a set (position, uv) has values only for
// its distinct vertices in the run, and a vertex refs the one it repeats: 0
// for a new one, else how many distinct ones back. A byte of a triangle is
// the zero codes met so far in the run less its code, so a vertex used for
// the first time codes as 0. The tangent and normal of a vertex are kept as
// they are: they repeat across the clusters of a page, which LZ finds in
// those 6 bytes and loses in codes of steps. The fields and the kept bytes
// cover every bit of the words: any words code back bit for bit.

// The scratch mesh_page_decode needs: a coding is at most this long, else
// the page keeps its words.
MESH_PAGE_SCRATCH_BYTES :: MESH_PAGE_WORDS*4+(MESH_PAGE_WORDS/(4*PAGE_RUN_MERGE)+1)*PAGE_RUN_BYTES+PAGE_TABLE_BYTES

@(private="file") PAGE_RUN_VERTICES :: 512 // the most vertices of a run
@(private="file") PAGE_RUN_MERGE :: 32     // a run of fewer vertices takes the next cluster
@(private="file") PAGE_RUN_BYTES :: 64     // the most a run adds in the run count and the headers
@(private="file") PAGE_DELTA :: 1          // of a field header: its codes are steps
@(private="file") PAGE_SHARED :: 1         // of a set header: values of distinct vertices
@(private="file") PAGE_FIELDS_MAX :: 5     // of a stream
@(private="file") PAGE_KEPT :: 6           // bytes a vertex keeps: bits 16-31 of v_tangent, normal
@(private="file") PAGE_SLOTS_MAX :: 1+len(PAGE_FIELDS)
@(private="file") PAGE_TABLE_BYTES :: 2+4+PAGE_SLOTS_MAX*8

// A field of the words of an element of a stream: its word, its lowest bit,
// its size (8 or 16, on a whole byte) and its set, the fields a vertex
// repeats together.
@(private)
Page_Field :: struct {word,shift,bits,set:u8}

// The vertices (position xyz; uv), uv1, colors and surfaces (roughness,
// metallic, the rest; emission).
@(private)
PAGE_FIELDS :: [?]Page_Field{
    {0,0,16,0},{0,16,16,0},{1,0,16,0},{1,16,16,1},{2,0,16,1},
    {0,0,16,0},{0,16,16,0},
    {0,0,8,0},{0,8,8,0},{0,16,8,0},{0,24,8,0},
    {0,0,8,0},{0,8,8,0},{0,16,16,0},{1,0,16,1},{1,16,16,1},
}

// A stream of a block: its first word, the words of an element, its fields
// in PAGE_FIELDS, whether it keeps the last PAGE_KEPT bytes of each element
// as they are (the tangent and normal of a vertex) and whether it is the
// triangles, coded as bytes.
@(private)
Page_Stream :: struct {first,element_words:u32,field_first,field_count:u8,kept,triangles:bool}

@(private)
page_streams :: proc "contextless" (flags:Mesh_Flags,layout:Mesh_Page_Layout) -> (streams:[5]Page_Stream,count:int) {
    streams[0]={layout.vertices,4,0,5,true,false}
    count=1
    if .Has_Uv1 in flags {streams[count]={layout.uv1s,1,5,2,false,false};count+=1}
    if .Has_Colors in flags {streams[count]={layout.colors,1,7,4,false,false};count+=1}
    if .Has_Surface in flags {streams[count]={layout.surfaces,2,11,5,false,false};count+=1}
    streams[count]={layout.triangles,1,0,0,false,true}
    count+=1
    return
}

// Decodes the block of a page from page_data, the blocks of every page of
// its mesh (Mesh_Geometry.page_data), into out[:page.words], with scratch of
// MESH_PAGE_SCRATCH_BYTES and the decoder of the reader. False for a page
// whose block is not inside page_data or does not decode to its words.
mesh_page_decode :: proc(flags:Mesh_Flags,page:Mesh_Page,page_data:[]u8,scratch:[]u8,out:[]u32,decoder:^Stream_Decoder) -> bool {
    if !page_block_valid(flags,page,len(page_data)) || page.data_bytes==0 || len(out)<int(page.words) || int(page.coded_bytes)>len(scratch) {return false}
    block:=page_data[page.data_offset:][:page.data_bytes]
    if page.coded_bytes==0 {return unpack(decoder,block,mem.slice_to_bytes(out[:page.words]))==.None}
    coded:=scratch[:page.coded_bytes]
    return unpack(decoder,block,coded)==.None && page_expand(flags,page,coded,out)
}

// A part of a coding: its bytes from at to end.
@(private="file")
Page_Part :: struct {at,end:int}

@(private="file")
u16_at :: #force_inline proc "contextless" (p:[^]u8,at:int) -> u32 {return u32(p[at])|u32(p[at+1])<<8}

@(private="file")
u32_at :: #force_inline proc "contextless" (p:[^]u8,at:int) -> u32 {return u16_at(p,at)|u16_at(p,at+2)<<16}

// The words of a block from its coding.
@(private="file")
page_expand :: proc "contextless" (flags:Mesh_Flags,page:Mesh_Page,coded:[]u8,out:[]u32) -> bool #no_bounds_check {
    size:=len(coded)
    c:=raw_data(coded)
    if size<2 {return false}
    runs:=int(u16_at(c,0))
    at:=2+runs*4
    if at>size {return false}
    vertices,triangles:u32
    for k in 0..<runs {
        n:=u16_at(c,2+k*4)
        if n>PAGE_RUN_VERTICES {return false}
        vertices+=n
        triangles+=u16_at(c,4+k*4)
    }
    if vertices!=page.vertex_count || triangles!=page.triangle_words {return false}
    streams,count:=page_streams(flags,mesh_page_layout(flags,page.vertex_count,page.triangle_words))
    slots:=1
    kept:=0
    for stream in streams[:count] {
        slots+=int(stream.field_count)
        if stream.kept {kept+=PAGE_KEPT*int(page.vertex_count)}
    }
    // The headers, the low and high bytes of each slot, the triangles and the kept bytes.
    if at+4+slots*8>size {return false}
    parts:[2+2*PAGE_SLOTS_MAX+1]Page_Part
    end:=at+4+slots*8
    for k in 0..<1+2*slots {
        bytes:=int(u32_at(c,at+4*k))
        if bytes>size-end {return false}
        parts[k]={end,end+bytes}
        end+=bytes
    }
    tail:=1+2*slots
    parts[tail]={end,end+int(page.triangle_words)*4}
    parts[tail+1]={parts[tail].end,parts[tail].end+kept}
    if parts[tail+1].end!=size {return false}
    all:=PAGE_FIELDS
    headers:=&parts[0]
    // The refs and the values of each field of a run.
    refs,values:[PAGE_RUN_VERTICES]u16
    words:=raw_data(out)
    slots=1
    for stream in streams[:count] {
        slot_first:=slots
        slots+=int(stream.field_count)
        element:=u32(0)
        fields:=all[stream.field_first:][:stream.field_count]
        for k in 0..<runs {
            if stream.triangles {
                n:=int(u16_at(c,4+k*4))*4
                triangles_expand(c,&parts[tail],n,([^]u8)(&words[stream.first+element]))
                element+=u32(n/4)
                continue
            }
            n:=int(u16_at(c,2+k*4))
            for first:=0;first<len(fields); {
                last:=first+1
                for last<len(fields) && fields[last].set==fields[first].set {last+=1}
                if headers.at>=headers.end {return false}
                set:=c[headers.at]
                headers.at+=1
                if set>>1>2 || set&PAGE_SHARED==0 && set>>1!=0 {return false}
                shared:=set&PAGE_SHARED!=0
                count:=n
                if shared {
                    codes_expand(c,&parts[1],&parts[2],n,int(set>>1),0,0xffff,raw_data(&refs),false) or_return
                    count=0
                    for i in 0..<n {
                        ref:=int(refs[i])
                        if ref>count {return false}
                        refs[i]=u16(count-ref)
                        count+=int(ref==0)
                    }
                }
                for f in first..<last {
                    slot:=slot_first+f
                    field_expand(c,headers,&parts[2*slot+1],&parts[2*slot+2],count,fields[f].bits,raw_data(&values)) or_return
                    field_place(raw_data(&values),raw_data(&refs) if shared else nil,n,fields[f],([^]u8)(&words[stream.first+element*stream.element_words]),int(stream.element_words)*4)
                }
                first=last
            }
            element+=u32(n)
        }
        if stream.kept {
            src:=c[parts[tail+1].at:]
            for i in 0..<int(page.vertex_count) {
                vertex:=words[stream.first+u32(i)*stream.element_words:]
                vertex[2]=vertex[2]&0xffff|u32(intrinsics.unaligned_load((^u16)(&src[i*PAGE_KEPT])))<<16
                vertex[3]=intrinsics.unaligned_load((^u32)(&src[i*PAGE_KEPT+2]))
            }
        }
    }
    for part in parts[:tail] {
        if part.at!=part.end {return false}
    }
    return true
}

// The values of a field into each of n elements from base, stride bytes
// apart. With index, element i takes values[index[i]].
@(private="file")
field_place :: #force_inline proc "contextless" (values,index:[^]u16,n:int,f:Page_Field,base:[^]u8,stride:int) #no_bounds_check {
    if f.bits==8 {
        dst:=base[int(f.word)*4+int(f.shift)/8:]
        if index==nil {
            for i in 0..<n {dst[i*stride]=u8(values[i])}
        } else {
            for i in 0..<n {dst[i*stride]=u8(values[index[i]])}
        }
        return
    }
    dst:=([^]u16)(base[int(f.word)*4+int(f.shift)/8:])
    step:=stride/2
    if index==nil {
        for i in 0..<n {dst[i*step]=values[i]}
    } else {
        for i in 0..<n {dst[i*step]=values[index[i]]}
    }
}

// The m values of a field: its header and base, and its codes.
@(private="file")
field_expand :: #force_inline proc "contextless" (c:[^]u8,headers,low,high:^Page_Part,m:int,bits:u8,out:[^]u16) -> bool #no_bounds_check {
    wide:=bits>8
    need:=3 if wide else 2
    if need>headers.end-headers.at {return false}
    header:=c[headers.at]
    base:=u32(c[headers.at+1])|(u32(c[headers.at+2])<<8 if wide else 0)
    headers.at+=need
    bytes:=int(header>>1)
    if header&~u8(PAGE_DELTA|6)!=0 || bytes>int(bits/8) || base>>bits!=0 {return false}
    if header&PAGE_DELTA!=0 {return codes_expand(c,low,high,m,bytes,base,u32(1)<<bits-1,out,true)}
    return codes_expand(c,low,high,m,bytes,base,u32(1)<<bits-1,out,false)
}

// The values of m codes of bytes each (their low bytes, then their high
// bytes), from base, modulo size + 1.
@(private="file")
codes_expand :: #force_inline proc "contextless" (c:[^]u8,low,high:^Page_Part,m,bytes:int,base,size:u32,out:[^]u16,$DELTA:bool) -> bool #no_bounds_check {
    if bytes>2 || bytes>=1 && m>low.end-low.at || bytes==2 && m>high.end-high.at {return false}
    lo,hi:=c[low.at:],c[high.at:]
    value:=base
    switch bytes {
    case 0: for i in 0..<m {out[i]=u16(base)}
    case 1: codes_add(lo,nil,out,m,&value,size,DELTA)
    case 2: codes_add(lo,hi,out,m,&value,size,DELTA)
    }
    if bytes>=1 {low.at+=m}
    if bytes==2 {high.at+=m}
    return true
}

@(private="file")
codes_add :: #force_inline proc "contextless" (lo,hi:[^]u8,out:[^]u16,m:int,value:^u32,size:u32,$DELTA:bool) #no_bounds_check {
    v:=value^
    for i in 0..<m {
        code:=u32(lo[i])|(u32(hi[i])<<8 if hi!=nil else 0)
        when DELTA {
            v=(v+((code>>1)~(0-(code&1))))&size
            out[i]=u16(v)
        } else {
            out[i]=u16((v+code)&size)
        }
    }
    value^=v
}

// The m bytes of the triangles of a run.
@(private="file")
triangles_expand :: #force_inline proc "contextless" (c:[^]u8,part:^Page_Part,m:int,out:[^]u8) #no_bounds_check {
    src:=c[part.at:]
    met:=u32(0)
    for j in 0..<m {
        out[j]=u8(met-u32(src[j]))
        met+=u32(src[j]==0)
    }
    part.at+=m
}

// What page_code works in, made once for every page of a mesh.
@(private)
Page_Coder :: struct {
    runs:[dynamic][2]u32, // vertices and words of triangles
    values:[PAGE_FIELDS_MAX][dynamic]u32,
    unique,sorted,offsets,steps,refs:[dynamic]u32,
    first:[dynamic]int, // of each distinct vertex of a set, the first vertex with it
    headers,triangles,kept:[dynamic]u8,
    slots:[PAGE_SLOTS_MAX][2][dynamic]u8, // low and high bytes
}

@(private)
page_coder_make :: proc(allocator:=context.allocator) -> Page_Coder {
    coder:Page_Coder
    coder.runs=make([dynamic][2]u32,allocator)
    for &v in coder.values {v=make([dynamic]u32,allocator)}
    coder.unique=make([dynamic]u32,allocator)
    coder.sorted=make([dynamic]u32,allocator)
    coder.offsets=make([dynamic]u32,allocator)
    coder.steps=make([dynamic]u32,allocator)
    coder.refs=make([dynamic]u32,allocator)
    coder.first=make([dynamic]int,allocator)
    coder.headers=make([dynamic]u8,allocator)
    coder.triangles=make([dynamic]u8,allocator)
    coder.kept=make([dynamic]u8,allocator)
    for &slot in coder.slots {for &bytes in slot {bytes=make([dynamic]u8,allocator)}}
    return coder
}

@(private)
page_coder_destroy :: proc(coder:^Page_Coder) {
    delete(coder.runs)
    for v in coder.values {delete(v)}
    delete(coder.unique);delete(coder.sorted);delete(coder.offsets);delete(coder.steps);delete(coder.refs);delete(coder.first)
    delete(coder.headers);delete(coder.triangles);delete(coder.kept)
    for slot in coder.slots {for bytes in slot {delete(bytes)}}
    coder^={}
}

@(private="file")
Page_Writer :: struct {out:[]u8,at:int}

@(private="file")
put :: proc(w:^Page_Writer,value:u32,bytes:int) -> bool {
    if w.at+bytes>len(w.out) {return false}
    for k in 0..<bytes {w.out[w.at+k]=u8(value>>uint(8*k))}
    w.at+=bytes
    return true
}

@(private="file")
put_bytes :: proc(w:^Page_Writer,bytes:[]u8) -> bool {
    if w.at+len(bytes)>len(w.out) {return false}
    copy(w.out[w.at:],bytes)
    w.at+=len(bytes)
    return true
}

// The coding of the block of a page of g, gathered in block, into out. False
// without room in out or memory.
@(private)
page_code :: proc(coder:^Page_Coder,g:Mesh_Geometry,page:Mesh_Page,block:[]u32,out:[]u8) -> (size:int,ok:bool) {
    runs:=&coder.runs
    clear(runs)
    tiled:=true
    vertex,triangle:=page.first_vertex,page.first_triangle
    for c in g.clusters[page.first_cluster:][:page.cluster_count] {
        if c.vertex_first!=vertex || c.triangle_first!=triangle {tiled=false;break}
        n,t:=cluster_vertex_count(c),cluster_triangle_words(c)
        if len(runs)>0 && runs[len(runs)-1].x<PAGE_RUN_MERGE {
            runs[len(runs)-1]+={n,t}
        } else if _,error:=append(runs,[2]u32{n,t});error!=nil {return}
        vertex+=n
        triangle+=t
    }
    if !tiled || vertex!=page.first_vertex+page.vertex_count || triangle!=page.first_triangle+page.triangle_words {
        clear(runs)
        left:=[2]u32{page.vertex_count,page.triangle_words}
        for left.x>0 || left.y>0 {
            run:=[2]u32{min(left.x,PAGE_RUN_VERTICES),min(left.y,PAGE_RUN_VERTICES)}
            if _,error:=append(runs,run);error!=nil {return}
            left-=run
        }
    }
    if len(runs)>0xffff {return}
    clear(&coder.headers);clear(&coder.triangles);clear(&coder.kept)
    for &slot in coder.slots {for &bytes in slot {clear(&bytes)}}
    streams,count:=page_streams(g.flags,mesh_page_layout(g.flags,page.vertex_count,page.triangle_words))
    all:=PAGE_FIELDS
    slots:=1
    for stream in streams[:count] {
        slot_first:=slots
        slots+=int(stream.field_count)
        element:=u32(0)
        fields:=all[stream.field_first:][:stream.field_count]
        for run in runs {
            if stream.triangles {
                met:=u32(0)
                for b in mem.slice_to_bytes(block[stream.first+element:][:run.y]) {
                    code:=u8(met-u32(b))
                    if _,error:=append(&coder.triangles,code);error!=nil {return}
                    met+=u32(code==0)
                }
                element+=run.y
                continue
            }
            n:=int(run.x)
            if n>PAGE_RUN_VERTICES {return}
            for f,k in fields {
                if resize(&coder.values[k],n)!=nil {return}
                for i in 0..<n {coder.values[k][i]=block[stream.first+(element+u32(i))*stream.element_words+u32(f.word)]>>f.shift&(u32(1)<<f.bits-1)}
            }
            for first:=0;first<len(fields); {
                last:=first+1
                for last<len(fields) && fields[last].set==fields[first].set {last+=1}
                plain:=0
                for f in first..<last {plain+=field_cost(coder,coder.values[f][:],fields[f].bits) or_return}
                distinct_refs(coder,first,last,n) or_return
                shared:=false
                if len(coder.first)<n {
                    cost:=codes_cost(coder.refs[:])
                    for f in first..<last {
                        distinct_values(coder,f) or_return
                        cost+=field_cost(coder,coder.unique[:],fields[f].bits) or_return
                    }
                    shared=cost<plain
                }
                if shared {
                    bytes:=codes_bytes(coder.refs[:])
                    if _,error:=append(&coder.headers,u8(PAGE_SHARED|bytes<<1));error!=nil {return}
                    codes_write(&coder.slots[0],coder.refs[:],bytes) or_return
                } else if _,error:=append(&coder.headers,0);error!=nil {return}
                for f in first..<last {
                    values:=coder.values[f][:]
                    if shared {
                        distinct_values(coder,f) or_return
                        values=coder.unique[:]
                    }
                    field_write(coder,&coder.slots[slot_first+f],values,fields[f].bits) or_return
                }
                first=last
            }
            element+=u32(n)
        }
        if stream.kept {
            for vertex in mem.slice_data_cast([]Cluster_Vertex,block[stream.first:][:page.vertex_count*4]) {
                bytes:=transmute([size_of(Cluster_Vertex)]u8)vertex
                if _,error:=append(&coder.kept,..bytes[size_of(Cluster_Vertex)-PAGE_KEPT:]);error!=nil {return}
            }
        }
    }
    w:=Page_Writer{out=out}
    put(&w,u32(len(runs)),2) or_return
    for run in runs {put(&w,run.x,2) or_return;put(&w,run.y,2) or_return}
    put(&w,u32(len(coder.headers)),4) or_return
    for slot in coder.slots[:slots] {
        for bytes in slot {put(&w,u32(len(bytes)),4) or_return}
    }
    put_bytes(&w,coder.headers[:]) or_return
    for slot in coder.slots[:slots] {
        for bytes in slot {put_bytes(&w,bytes[:]) or_return}
    }
    put_bytes(&w,coder.triangles[:]) or_return
    put_bytes(&w,coder.kept[:]) or_return
    return w.at,true
}

// The refs of the n vertices of a run to the distinct values of the fields
// [first, last), into coder.refs, and the first vertex of each into coder.first.
@(private="file")
distinct_refs :: proc(coder:^Page_Coder,first,last,n:int) -> bool {
    if resize(&coder.refs,n)!=nil {return false}
    clear(&coder.first)
    for i in 0..<n {
        coder.refs[i]=0
        for j,at in coder.first {
            same:=true
            for f in first..<last {same&&=coder.values[f][i]==coder.values[f][j]}
            if same {coder.refs[i]=u32(len(coder.first)-at);break}
        }
        if coder.refs[i]==0 {
            if _,error:=append(&coder.first,i);error!=nil {return false}
        }
    }
    return true
}

@(private="file")
distinct_values :: proc(coder:^Page_Coder,f:int) -> bool {
    if resize(&coder.unique,len(coder.first))!=nil {return false}
    for i,at in coder.first {coder.unique[at]=coder.values[f][i]}
    return true
}

// What LZ is taken to spend on codes: their significant bits.
@(private="file")
codes_cost :: proc(codes:[]u32) -> (bits:int) {
    for c in codes {bits+=int(bit_width(c))}
    return
}

// The bytes each of codes takes.
@(private="file")
codes_bytes :: proc(codes:[]u32) -> int {
    widest:=u32(0)
    for c in codes {widest|=c}
    return int(bit_width(widest)+7)/8
}

@(private="file")
codes_write :: proc(slot:^[2][dynamic]u8,codes:[]u32,bytes:int) -> bool {
    for plane in 0..<bytes {
        at:=len(slot[plane])
        if resize(&slot[plane],at+len(codes))!=nil {return false}
        for c,i in codes {slot[plane][at+i]=u8(c>>uint(8*plane))}
    }
    return true
}

@(private="file")
field_cost :: proc(coder:^Page_Coder,values:[]u32,bits:u8) -> (int,bool) {
    _,codes,ok:=field_codes(coder,values,bits)
    return codes_cost(codes),ok
}

@(private="file")
field_write :: proc(coder:^Page_Coder,slot:^[2][dynamic]u8,values:[]u32,bits:u8) -> bool {
    header,codes:=field_codes(coder,values,bits) or_return
    bytes:=codes_bytes(codes)
    if _,error:=append(&coder.headers,u8(header.x|u32(bytes)<<1),u8(header.y));error!=nil {return false}
    if bits>8 {
        if _,error:=append(&coder.headers,u8(header.y>>8));error!=nil {return false}
    }
    return codes_write(slot,codes,bytes)
}

// The header (mode, base) and the codes of values in the fewest bits:
// offsets from the start of the shortest arc of the field's circle that
// holds them, or zigzagged steps from the value before.
@(private="file")
field_codes :: proc(coder:^Page_Coder,values:[]u32,bits:u8) -> (header:[2]u32,codes:[]u32,ok:bool) {
    n:=len(values)
    if resize(&coder.offsets,n)!=nil || resize(&coder.steps,n)!=nil || resize(&coder.sorted,n)!=nil {return}
    if n==0 {return {},nil,true}
    size:=u32(1)<<bits
    sorted:=coder.sorted[:]
    copy(sorted,values)
    slice.sort(sorted)
    gap,start:=sorted[0]+size-sorted[n-1],0
    for i in 1..<n {
        if sorted[i]-sorted[i-1]>gap {gap,start=sorted[i]-sorted[i-1],i}
    }
    base:=sorted[start]
    for v,i in values {coder.offsets[i]=(v-base)&(size-1)}
    for i in 0..<n {
        s:=i32((values[i]-values[max(i,1)-1])<<(32-u32(bits)))>>(32-u32(bits))
        coder.steps[i]=u32((s<<1)~(s>>31))&(size-1)
    }
    if codes_cost(coder.steps[:])<=codes_cost(coder.offsets[:]) {return {PAGE_DELTA,values[0]},coder.steps[:],true}
    return {0,base},coder.offsets[:],true
}

@(private="file")
bit_width :: proc "contextless" (v:u32) -> u32 {return 32-intrinsics.count_leading_zeros(v)}

// The block of a page of g, gathered in block, appended to data as LZ
// packs it as p says: over its coding or over its words, whichever is
// smaller. coded is scratch of MESH_PAGE_SCRATCH_BYTES. Sets where page
// finds it.
@(private)
page_pack :: proc(coder:^Page_Coder,encoder:^lz.Encoder,g:Mesh_Geometry,page:^Mesh_Page,block:[]u32,coded:[]u8,p:Pack,data:^[dynamic]u8,codecs:^Pack_Codecs=nil) -> Error {
    words:=mem.slice_to_bytes(block[:page.words])
    size,ok:=page_code(coder,g,page^,block,coded)
    at:=len(data)
    bound:=block_bound(codecs,len(words))+(block_bound(codecs,size) if ok else 0)
    if at+bound>int(max(u32)) || resize(data,at+bound)!=nil {return .Out_Of_Memory}
    packed:=block_pack(encoder,p,codecs,words,data[at:]) or_return
    page.data_offset,page.data_bytes,page.coded_bytes=u32(at),u32(packed),0
    if ok {
        tried:=at+packed
        smaller:=block_pack(encoder,p,codecs,coded[:size],data[tried:]) or_return
        if smaller<packed {
            copy(data[at:],data[tried:][:smaller])
            page.data_bytes,page.coded_bytes=u32(smaller),u32(size)
        }
    }
    base.truncate(data,at+int(page.data_bytes))
    return .None
}

// The pages of g with the block of each, LZ as p says, one after the other in data.
@(private)
pages_compress :: proc(g:Mesh_Geometry,p:Pack,allocator:=context.allocator,codecs:^Pack_Codecs=nil) -> (pages:[]Mesh_Page,data:[dynamic]u8,error:Error) {
    allocation:mem.Allocator_Error
    pages,allocation=make([]Mesh_Page,len(g.pages),allocator)
    if allocation!=nil {return nil,nil,.Out_Of_Memory}
    data=make([dynamic]u8,allocator)
    block:=make([]u32,MESH_PAGE_WORDS,context.temp_allocator)
    coded:=make([]u8,MESH_PAGE_SCRATCH_BYTES,context.temp_allocator)
    if block==nil || coded==nil {delete(pages,allocator);return nil,nil,.Out_Of_Memory}
    coder:=page_coder_make(context.temp_allocator)
    defer page_coder_destroy(&coder)
    encoder:lz.Encoder
    when ASSET_LZ {
        lz.encoder_init(&encoder,context.temp_allocator)
        defer lz.encoder_destroy(&encoder)
    }
    copy(pages,g.pages)
    for &page in pages {
        mesh_page_gather(g,page,block)
        if error=page_pack(&coder,&encoder,g,&page,block,coded,p,&data,codecs);error!=.None {
            delete(pages,allocator);delete(data)
            return nil,nil,error
        }
    }
    return
}
