package store

import "base:runtime"

// A chunk is the unit the store holds: 1 to CHUNK_MAX bytes named by their
// address. External bytes are cut where their content says (FastCDC 2020 with
// normalized chunking, level 1); a native asset is cut where its writer says.
// The cut function and GEAR are part of the store's layout: changing either
// changes the address of every object.

CHUNK_MIN :: 32<<10
CHUNK_AVG :: 64<<10
CHUNK_MAX :: 256<<10

// Before CHUNK_AVG a cut needs 17 zero bits, after it 15; the bits are spread
// over the high part of the gear hash, which depends on the last 48 bytes.
@(private)
MASK_SMALL :: u64(0x924924a492490000)
@(private)
MASK_LARGE :: u64(0x9124489224890000)

// splitmix64 from the seed 0x6d69726169, frozen.
@(private,rodata)
GEAR := [256]u64{
    0x078a3e78e7f036ac,0x08cb10994d304e37,0xf7d076766e9d36bf,0x65a87d1d83a3194f,
    0xb01d3e3a999f6b35,0xcb361e8e163f9f9a,0xe66309ed0396a92c,0x85a1d25577105c48,
    0xab9b4bab3a81f563,0xbbfaf573ed6a67cf,0x41ca4f81dfa9b7d7,0xf17dbd06ebc4594c,
    0xf83dd1bd18ec7a98,0x3f826eede2d101d0,0x4f6b124e3ccb3f8f,0xfd5d41ec1db6ea9e,
    0x6c47b64eac645a47,0xdb0954e3a9639360,0x42d3629f947974d1,0xfcfdd169d30fd170,
    0x83136903bc02957d,0xb2eb0ee200d52d66,0x9bafa6c33b048811,0x75e00866b14c979c,
    0xdffa134efca5e71b,0x3a92b03943a378d9,0x0f6f8b5336d4105e,0xc8795d23cdb1897e,
    0xef398a6960c6c299,0x5773c2c896ffb2f1,0x3dd883c8d50675ee,0xd2c60bfc306ec177,
    0x222ca64a93370b7a,0x27445da095a0bb7f,0xb0cb86d24d11b549,0xf2fc7c2c6f3f04df,
    0x8f5acaae98acc82c,0x3084f6f8ecee9e79,0xd96ff4eb276cc550,0xa4234206159d8e63,
    0xc677bdb23108f939,0x6035995402bbe53e,0xb9df31bd1a1731b0,0xf23ba93fdddf09f6,
    0xcfbca616977bb6fe,0x119767f0338217f0,0x5c915a424bfebb3d,0xcadfd204d9684abd,
    0x4e4389483a4217c3,0xb8d433fc4a4e3e58,0xdcdc00595e051194,0x483a84e8ae8a278a,
    0xec0bbc96ebed2f54,0x9c1f6c8fd4bbbec9,0xc595ceb92c58ca3b,0x420c65eb7130677b,
    0x3bdeaf938c0764c5,0xb0e441aa9acce811,0x58ebd44e74af839a,0xa183e95a00726f2a,
    0x3ac53393443a76ad,0x281bb7244ef538b1,0xc4749e9d38461b65,0x3cdf7dbca1a2307b,
    0xa91909dd785247f6,0xb9423955f9b83fe6,0xea2c39227c57fe89,0x1000edb5fc5a6e72,
    0xc25824f05f8d32cd,0xb533745a8faa4c55,0xfa90318eca020ced,0xa7baf0b639122de1,
    0xe131589ce07856db,0xae794ea5ced1e3da,0xc8bc4863143fb3a4,0xde9b98775d810d80,
    0xdaa31129aa97bd32,0x0acd97a7a15ed557,0x3c486ea88e0eb02d,0x4f8dc978c983de4f,
    0x29ee5aebc62f6611,0x56cd4cfea2dd3444,0x9a546217febe87c4,0x4e19c866d2c49293,
    0x796d7872c1dc38e9,0x998a0fccdaf17218,0x6752b6ad045a9a5c,0x99b434b754176dea,
    0x779770b07c061b7d,0xab8e8ae64e253b92,0xc012608fac8a1085,0x26864c946f5554e2,
    0x5e0bcd1f3f64b81e,0x04a880e03e582074,0xf9078cd9cef7cb6b,0x4ccb6a2b57adc33e,
    0x10ae2c1071ab7532,0xc030f078e01d3d65,0x86fbf19a8406bfca,0xa48b7ba9407aa517,
    0xea05ad000f5106e0,0x2211057112a9e80c,0x6cb777870d132e3d,0x1ba1c25574762129,
    0xa09e6bff0c7329bd,0xd02473e5d750ae89,0xfc06896e3f38d688,0x2028d9094430cc4a,
    0x89ea9f412b3af080,0xdd4ed6dae0621736,0xafb4cbdce279b012,0xc8ea10be661b72ba,
    0x9ebff3597d697763,0xe3ee446a78a02538,0x442a1b95dd811dbc,0x2cb994633ceb2e70,
    0x83f28a5ea5fa3986,0x3c6d154beb1667f1,0x5529dfe34780c980,0x979f9cb0ea89422f,
    0x35d860cb769996c4,0x9d37d77551243f1a,0xae11afb4bdec6c6d,0x9954681e777f3739,
    0xd526d19b29f7e1ed,0x776e8a3d677e5e5e,0xc64d350fcd007022,0x736c8629a3c33613,
    0xddf4bf63e10867b6,0x6cb0fc3a9262d20f,0x2a00395a9b6b34b6,0x7803593032b7bec7,
    0x339cf9e3c0415667,0xaad7c4605ac98cbe,0x1ec9136a3264a743,0x210304e7e492c570,
    0xd6c51873f601321b,0xb07847976766b4ab,0x8c751e4891834df4,0x67a5c7821c20bd47,
    0x68566841310b6fc5,0x2cd8430e5dc0c7c8,0x2ab71e7ba926175b,0x3cd727b8858d4b9f,
    0x5ddf944558fa28a1,0x2be32fce005e668c,0xa365983e01f62455,0xc8d8ce1af12fb1a6,
    0xc7487cdd7fdb140b,0xb7dd64bdb0209f46,0x05ff09bc93ac8894,0xe150bd4d4aeb7a2d,
    0x4e6cc50905b374b3,0x1511e1e2cabc12d4,0x643fc9018960ec13,0x31afd52828be9cbd,
    0x11d8a3a3340f3d85,0x5d5910cb9429006b,0x7a0710f95ecc699d,0xd68d8efdd385a677,
    0x7ef4b5f7afef6eee,0xd40468212d2b659f,0xa63ec7c5c6ad91d3,0x78818710f1a44d04,
    0x847d8fbc378572ad,0xe336cb872dc142fa,0x2a62c34ae05313fb,0xbe4f1d0d4019c710,
    0x3df3677fdb63b096,0xbcb29efb9e7baa1c,0x9389b9d0a2a1fc7d,0x9f4ca728429472ba,
    0xe43300435f500e17,0x7f3d22866faf5600,0x4e04bda074615ef9,0x013e48fe4de62f65,
    0xb13aab84cece9ecc,0xc74b78871ac6423e,0x739c11e73870bacf,0x0d2af89206b3f58d,
    0x3a31fb10c0d268ee,0x4da46565e391771e,0x4892ee92f73fbb24,0xa601f5f3bcdb2d79,
    0x496b22cbaa6f21d4,0x8c546350243c787b,0xd893ac30d1dad444,0x629c4290e2c65a8a,
    0x60c3fa057ebf5ff5,0x1c03466c506e059c,0x893d27cfb51a7b86,0xd34e082839f223a7,
    0x0edd126d8ec0bc37,0x266e7c77b0c8fe0d,0xda29f69d31b16dc1,0x7b86262bd4f9c1c4,
    0xa9bd148a043dabb1,0x18d138612e725b00,0xe4d5cc8493c0753e,0xd2c72b8d78cffa4c,
    0x7f5ede26213f5474,0xa3236b0f5f8eb266,0x6525e3e7bea6dc58,0xd78654672bbb2170,
    0xd9f9059a3fb81ea1,0x2c40abdd7c97514b,0x6a12050b401507be,0xbb8b5bc1b722b230,
    0xcae7eaf578a69807,0xf792e2c2fc807e61,0x8862be0ab0951382,0x92281fe49c38589d,
    0x56b9e747de98cfda,0xa2f123692a1af947,0xc029da67391e9493,0x46c691e79e639483,
    0x100d1cc538977632,0x19b8358a680294d7,0xb9d72e5f1100c1c0,0xcf5881fba59676a1,
    0xcfe993f7c2f871a5,0x69f3cd2080419b72,0xb570b76957ef4121,0xb116c3dc25225a2d,
    0xbf699c413e72e2a5,0x013db15ac1dc5275,0xb75a0b24ce21b010,0x865f0a74496cbbd9,
    0x53a140e0f77f3e3f,0xccfa632670bec8a4,0x697de5c16309aaee,0xb9208b09b354cfbb,
    0x08b4227f839ca46c,0x559e5f779c34f3ef,0x841a45f3abd1df98,0x1b3e9e48dc16d3a1,
    0x1007a5c0591ea064,0x17f5f17b8b40541f,0x16c18dde7a02656a,0x6efcfa25a3726a01,
    0x50a35e53534d745f,0x51b7c06b92736e7d,0xc04c262fec98bba4,0xbb85f032bc5ca304,
    0xee84db6c2a1cbda7,0xe47f9f989a36de8c,0x255979b6fe3c5492,0xdc1bb02d2bc2746b,
    0xb8b919b4a0ce745f,0x10ceef01851739f6,0x42dc389d5e579b57,0x06ce04d155b10054,
    0xd7e246244e890531,0x1bd970c8c4f33d6c,0x9d0f9d3cfc230bdb,0x41be74380cbec027,
}

// The length of the first chunk of data, which holds every byte up to the end
// of what is cut: it reads at most CHUNK_MAX bytes.
chunk_cut :: proc "contextless" (data:[]u8) -> int {
    n:=len(data)
    if n<=CHUNK_MIN {return n}
    if n>CHUNK_MAX {n=CHUNK_MAX}
    center:=min(n,CHUNK_AVG)
    hash:u64
    #no_bounds_check {
        for i in CHUNK_MIN..<center {
            hash=(hash<<1)+GEAR[data[i]]
            if hash&MASK_SMALL==0 {return i+1}
        }
        for i in center..<n {
            hash=(hash<<1)+GEAR[data[i]]
            if hash&MASK_LARGE==0 {return i+1}
        }
    }
    return n
}

// Cuts a stream that arrives in pieces of any size with the same cuts as
// chunk_cut over the whole stream: a cut is decided only with CHUNK_MAX bytes
// ahead or at the end. The owner gives bytes with chunker_feed, marks the end
// with chunker_end and takes chunks with chunker_next until it returns false.
// It holds a window of 2*CHUNK_MAX bytes and allocates nothing per chunk.
Chunker :: struct {
    window:[]u8,
    head,length:int, // bytes carried in window[head:][:length]
    input:[]u8,      // bytes fed and not yet cut or carried
    ended:bool,
    allocator:runtime.Allocator,
}

chunker_init :: proc(c:^Chunker,allocator:=context.allocator) -> Error {
    window,error:=make([]u8,2*CHUNK_MAX,allocator)
    if error!=nil {return .Out_Of_Memory}
    c^={window=window,allocator=allocator}
    return .None
}

chunker_destroy :: proc(c:^Chunker) {
    delete(c.window,c.allocator)
    c^={}
}

// Starts a new stream with the same window.
chunker_reset :: proc "contextless" (c:^Chunker) {
    c.head,c.length,c.input,c.ended=0,0,nil,false
}

// Gives the next bytes of the stream; the previous ones must have been taken:
// chunker_next returned false since they were fed.
chunker_feed :: proc "contextless" (c:^Chunker,data:[]u8) -> Error {
    if len(c.input)>0 || c.ended {return .Invalid_Argument}
    c.input=data
    return .None
}

chunker_end :: proc "contextless" (c:^Chunker) {
    c.ended=true
}

// The next chunk, valid until the next call; false when the bytes fed so far
// decide no more cuts, or at the end of the stream.
chunker_next :: proc "contextless" (c:^Chunker) -> (chunk:[]u8,ok:bool) {
    for {
        if c.length==0 {
            if len(c.input)>=CHUNK_MAX || (c.ended && len(c.input)>0) {
                n:=chunk_cut(c.input)
                chunk,c.input=c.input[:n],c.input[n:]
                return chunk,true
            }
            if len(c.input)==0 {return nil,false}
            c.head=0
        } else if c.length>=CHUNK_MAX || (c.ended && len(c.input)==0) {
            n:=chunk_cut(c.window[c.head:][:c.length])
            chunk=c.window[c.head:][:n]
            c.head+=n
            c.length-=n
            return chunk,true
        } else if len(c.input)==0 {
            return nil,false
        }
        if c.head+CHUNK_MAX>len(c.window) {
            copy(c.window,c.window[c.head:][:c.length])
            c.head=0
        }
        n:=copy(c.window[c.head+c.length:],c.input)
        c.length+=n
        c.input=c.input[n:]
    }
}

// The chunks the store keeps of a container chunk of a native asset, whose
// writer names the cut points between its independent pieces: consecutive
// pieces are merged up to CHUNK_MAX, and a larger piece is cut at CHUNK_MAX
// offsets from its start, its remainder merging with the pieces after it.
Native_Cuts :: struct {
    data:[]u8,
    cuts:[]int, // strictly ascending, inside (0, len(data))
    at:int,     // the first byte not yet given
    next:int,   // the first cut after at
}

native_cuts :: proc "contextless" (data:[]u8,cuts:[]int) -> (n:Native_Cuts,error:Error) {
    previous:=0
    for cut in cuts {
        if cut<=previous || cut>=len(data) {return {},.Invalid_Argument}
        previous=cut
    }
    return {data=data,cuts=cuts},.None
}

native_next :: proc "contextless" (n:^Native_Cuts) -> (chunk:[]u8,ok:bool) {
    if n.at>=len(n.data) {return nil,false}
    end:=n.next<len(n.cuts)?n.cuts[n.next]:len(n.data)
    if end-n.at>CHUNK_MAX {
        end=n.at+CHUNK_MAX
    } else {
        for n.next<len(n.cuts) {
            following:=n.next+1<len(n.cuts)?n.cuts[n.next+1]:len(n.data)
            if following-n.at>CHUNK_MAX {break}
            n.next+=1
            end=following
        }
        if n.next<len(n.cuts) && n.cuts[n.next]==end {n.next+=1}
    }
    chunk=n.data[n.at:end]
    n.at=end
    return chunk,true
}
