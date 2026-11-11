package codec

// What a compression plugin brings: how the game decodes its streams and how a cook writes them.
// Everything goes by the C convention, since a cook loads the library of the plugin into a program
// built apart from it. Nothing here depends on a codec: the engine's own LZ is not one of these.

API_VERSION :: 1
COOK_SYMBOL :: "mirai_compression_cook"
MAX :: 8

// Four characters, stored in each stream so that a game finds what decodes it.
Id :: distinct u32

id_of :: proc "contextless" (text:string) -> Id {
    value:u32
    for i in 0..<min(len(text),4) {value|=u32(text[i])<<(uint(i)*8)}
    for i in len(text)..<4 {value|=u32(' ')<<(uint(i)*8)}
    return Id(value)
}

Decode :: struct {
    id:Id,
    // What decode keeps per thread. nil: it keeps nothing.
    scratch_make:proc "c" () -> rawptr,
    scratch_free:proc "c" (scratch:rawptr),
    // True when src decodes to exactly dst_bytes. Never reads or writes outside them, whatever src holds.
    decode:proc "c" (scratch:rawptr,src:[^]u8,src_bytes:uint,dst:[^]u8,dst_bytes:uint) -> bool,
}

Table :: struct {
    list:[MAX]Decode,
    count:int,
}

Encode :: struct {
    id:Id,
    bound:proc "c" (size:uint) -> uint,
    // The bytes written, 0 when it failed. Deterministic, and safe to call from several threads.
    encode:proc "c" (level:i32,src:[^]u8,src_bytes:uint,dst:[^]u8,capacity:uint) -> uint,
    edit,ship,quick:i32, // the level of each asset.Pack
}

// A field of a @(storage) of a plugin, alone in its storage: the codecs a game decodes with and
// writes what it saves with.
Provider :: struct {
    table:Table,
    general,streamed:Encode,
}

Texture_Format :: enum u32 {BC1,BC3,BC5,BC6H,BC7}

// The blocks of one image: pixels are RGBA16F for BC6H, RGBA8 otherwise, width*height of them, and
// out holds ceil(width/4)*ceil(height/4) blocks. lambda is that of cook/textures.Build_Options
// (0: the least error). srgb says the pixels are color. Deterministic.
Texture_Encode :: #type proc "c" (format:Texture_Format,pixels:[^]u8,width,height,lambda:i32,srgb:bool,out:[^]u8,out_bytes:uint) -> bool

// What the library of the Cook part of a plugin gives through its COOK_SYMBOL.
Cook_Api :: struct {
    version:u32,
    decoders:Table,
    general:Encode,  // what is loaded once
    streamed:Encode, // what is read while playing: the pages of a mesh
    id:u64,          // changes when what the plugin writes changes: it names what caches keep of it
    texture:Texture_Encode, // nil: the engine's encoders make the blocks
}

Cook_Entry :: #type proc "c" () -> ^Cook_Api
