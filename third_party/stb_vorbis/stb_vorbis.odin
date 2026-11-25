package stb_vorbis

import "core:c"

when ODIN_OS==.Windows {
    foreign import lib "windows/stb_vorbis.lib"
} else when ODIN_OS==.Linux {
    foreign import lib "linux/stb_vorbis.a"
} else when ODIN_OS==.Darwin {
    when ODIN_ARCH==.arm64 {foreign import lib "macos-arm64/stb_vorbis.a"}
    else {foreign import lib "macos/stb_vorbis.a"}
}

// The part of stb_vorbis the audio decodes with, and the decoders of
// shared.c that share the setup of another one (third_party/stb_vorbis/UPSTREAM.md).

Vorbis :: struct {}

Alloc :: struct {
    buffer:[^]u8,
    length:c.int,
}
Info :: struct {
    sample_rate:c.uint,
    channels:c.int,
    setup_memory_required,setup_temp_memory_required,temp_memory_required:c.uint,
    max_frame_size:c.int,
}
Comment :: struct {
    vendor:cstring,
    comment_list_length:c.int,
    comment_list:[^]cstring,
}
Probed_Page :: struct {page_start,page_end,last_decoded_sample:u32}
Place :: struct {
    first_audio_page_offset,total_samples:c.uint,
    first,last:Probed_Page,
}

ERROR_OUT_OF_MEMORY :: 3
ERROR_TOO_MANY_CHANNELS :: 5

@(default_calling_convention="c",link_prefix="stb_vorbis_")
foreign lib {
    open_memory :: proc(data:[^]u8,len:c.int,error:^c.int,alloc:^Alloc) -> ^Vorbis ---
    close :: proc(f:^Vorbis) ---
    get_info :: proc(f:^Vorbis) -> Info ---
    get_comment :: proc(f:^Vorbis) -> Comment ---
    stream_length_in_samples :: proc(f:^Vorbis) -> c.uint ---
    get_samples_float_interleaved :: proc(f:^Vorbis,channels:c.int,buffer:[^]f32,num_floats:c.int) -> c.int ---
    seek :: proc(f:^Vorbis,sample_number:c.uint) -> c.int ---
    seek_start :: proc(f:^Vorbis) -> c.int ---
    get_place :: proc(f:^Vorbis,place:^Place) ---
    shared_memory_required :: proc(setup:^Vorbis) -> c.int ---
    open_shared :: proc(setup:^Vorbis,data:[^]u8,len:c.int,place:^Place,alloc:^Alloc,error:^c.int) -> ^Vorbis ---
}
