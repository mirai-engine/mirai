package asset

import "core:math/rand"
import "core:mem"
import "core:testing"
import "mirai:std/serial"

// One page of clusters of the given vertex counts, with words drawn from
// random of the bits given (32: any words) in every stream flags names.
@(private="file")
code_geometry :: proc(flags:Mesh_Flags,counts:[]u32,bits:uint,r:^rand.Generator) -> (g:Mesh_Geometry) {
    word :: proc(bits:uint,r:^rand.Generator) -> u32 {return rand.uint32(r^)&u32(u64(1)<<bits-1)}
    g.flags=flags
    clusters:=make([]Cluster,len(counts),context.temp_allocator)
    page:=Mesh_Page{cluster_count=u32(len(counts))}
    for n,at in counts {
        triangles:=u32(rand.uint32(r^)%(CLUSTER_TRIANGLES+1))
        clusters[at]={vertex_first=page.vertex_count,triangle_first=page.triangle_words,counts=(n-1)|triangles<<8}
        page.vertex_count+=n
        page.triangle_words+=cluster_triangle_words(clusters[at])
    }
    page.words=mesh_page_layout(flags,page.vertex_count,page.triangle_words).words
    count:=int(page.vertex_count)
    g.clusters=clusters
    g.vertices=make([]Cluster_Vertex,count,context.temp_allocator)
    for &v in g.vertices {v={word(bits,r),word(bits,r),word(bits,r),word(bits,r)}}
    if .Has_Uv1 in flags {g.uv1s=make([]u32,count,context.temp_allocator);for &v in g.uv1s {v=word(bits,r)}}
    if .Has_Colors in flags {g.colors=make([]u32,count,context.temp_allocator);for &v in g.colors {v=word(bits,r)}}
    if .Has_Surface in flags {
        g.surfaces=make([]Surface_Vertex,count,context.temp_allocator)
        for &v in g.surfaces {v={word(bits,r),word(bits,r)}}
    }
    g.triangles=make([]u32,page.triangle_words,context.temp_allocator)
    for &v in g.triangles {v=word(bits,r)}
    g.pages=make([]Mesh_Page,1,context.temp_allocator)
    g.pages[0]=page
    return
}

@(test)
page_coding_gives_back_any_words_bit_for_bit :: proc(t:^testing.T) {
    state:=rand.create(7)
    r:=rand.default_random_generator(&state)
    Case :: struct {flags:Mesh_Flags,counts:[]u32,bits:uint,untiled:bool}
    cases:=[]Case{
        {{},{256,1,40,256,3},32,false},
        {{.Has_Uv1,.Has_Colors},{12,7,256,31,1,90},5,false},
        {{.Has_Surface,.Has_Colors},{64,64,64},0,false},
        {{.Has_Colors},{100,64,3},9,false},
        {{.Has_Uv1,.Has_Colors,.Has_Surface},{256,256,256,256,256},13,true},
        {{.Has_Uv1},{1,1,1,1},32,true},
    }
    block:=make([]u32,MESH_PAGE_WORDS,context.temp_allocator)
    want:=make([]u32,MESH_PAGE_WORDS,context.temp_allocator)
    decoder:Decoder
    testing.expect_value(t,decoder_init(&decoder),Error.None)
    defer decoder_destroy(&decoder)
    encoder:Stream_Encoder
    stream_encoder_init(&encoder,context.temp_allocator)
    coder:=page_coder_make(context.temp_allocator)
    scratch:=make([]u8,MESH_PAGE_SCRATCH_BYTES,context.temp_allocator)
    coded:=make([]u8,MESH_PAGE_SCRATCH_BYTES,context.temp_allocator)
    packed:=make([]u8,pack_bound(MESH_PAGE_SCRATCH_BYTES),context.temp_allocator)
    same :: proc(a,b:[]u32) -> bool {return mem.compare(mem.slice_to_bytes(a),mem.slice_to_bytes(b))==0}
    for c,at in cases {
        g:=code_geometry(c.flags,c.counts,c.bits,&r)
        if c.untiled {g.clusters[len(g.clusters)-1].vertex_first=0}
        mesh_page_gather(g,g.pages[0],want)
        words:=int(g.pages[0].words)
        pages,data,error:=pages_compress(g,.Fast,.Open,context.temp_allocator)
        if !testing.expectf(t,error==.None,"case %d packs",at) {continue}
        testing.expectf(t,mesh_page_decode(g.flags,pages[0],data[:],scratch,block,&decoder.stream) && same(block[:words],want[:words]),"case %d decodes to its words",at)
        raw,_:=pack(&encoder,.Fast,.Open,mem.slice_to_bytes(want[:words]),packed)
        testing.expectf(t,int(pages[0].data_bytes)<=raw,"case %d takes %d bytes, no more than its words in LZ, %d",at,pages[0].data_bytes,raw)
        size,ok:=page_code(&coder,g,g.pages[0],want,coded)
        testing.expectf(t,ok && page_decode_coded(g,g.pages[0],coded[:size],packed,scratch,block,&encoder,&decoder.stream) && same(block[:words],want[:words]),"case %d codes back bit for bit",at)
    }
}

// The coding of a page through LZ and mesh_page_decode.
@(private="file")
page_decode_coded :: proc(g:Mesh_Geometry,page:Mesh_Page,coded,packed,scratch:[]u8,out:[]u32,encoder:^Stream_Encoder,decoder:^Stream_Decoder) -> bool {
    page:=page
    bytes,_:=pack(encoder,.Fast,.Open,coded,packed)
    page.data_offset,page.data_bytes,page.coded_bytes=0,u32(bytes),u32(len(coded))
    return mesh_page_decode(g.flags,page,packed[:bytes],scratch,out,decoder)
}

@(test)
hostile_page_codings_are_refused_or_decode_within_the_block :: proc(t:^testing.T) {
    state:=rand.create(11)
    r:=rand.default_random_generator(&state)
    g:=code_geometry({.Has_Uv1,.Has_Colors},{200,90,256},6,&r)
    page:=g.pages[0]
    coder:=page_coder_make(context.temp_allocator)
    coded:=make([]u8,MESH_PAGE_SCRATCH_BYTES,context.temp_allocator)
    block:=make([]u32,MESH_PAGE_WORDS,context.temp_allocator)
    mesh_page_gather(g,page,block)
    size,ok:=page_code(&coder,g,page,block,coded)
    if !testing.expect(t,ok) {return}
    decoder:Decoder
    testing.expect_value(t,decoder_init(&decoder),Error.None)
    defer decoder_destroy(&decoder)
    encoder:Stream_Encoder
    stream_encoder_init(&encoder,context.temp_allocator)
    packed:=make([]u8,pack_bound(len(coded)),context.temp_allocator)
    scratch:=make([]u8,MESH_PAGE_SCRATCH_BYTES,context.temp_allocator)
    out:=make([]u32,MESH_PAGE_WORDS,context.temp_allocator)
    decode:=page_decode_coded
    testing.expect(t,decode(g,page,coded[:size],packed,scratch,out,&encoder,&decoder.stream),"the coding as made decodes")
    for cut in 0..<size {
        if decode(g,page,coded[:cut],packed,scratch,out,&encoder,&decoder.stream) {testing.expectf(t,false,"a coding cut at %d of %d is refused",cut,size);break}
    }
    mutated:=make([]u8,size,context.temp_allocator)
    refused:=0
    for trial in 0..<4000 {
        copy(mutated,coded[:size])
        for _ in 0..=trial%4 {
            at:=int(rand.uint32(r))%min(size,64) if trial%2==0 else int(rand.uint32(r))%size
            mutated[at]=u8(rand.uint32(r))
        }
        if !decode(g,page,mutated,packed,scratch,out,&encoder,&decoder.stream) {refused+=1}
    }
    testing.expect(t,refused>0,"damaged headers are refused")
    testing.expect(t,!decode(g,page,coded[:size],packed,scratch[:64],out,&encoder,&decoder.stream),"a scratch too small is refused")
    testing.expect(t,!decode(g,page,coded[:size],packed,scratch,out[:page.words-1],&encoder,&decoder.stream),"an output too small is refused")
}

