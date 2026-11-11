package bc7split

// See std/compressor/placeholder.odin.
when !#exists("implemented.odin") {
    IMPLEMENTED :: false
    Header :: struct {version,flags:u32,mode_counts:[9]u32}
    Error :: enum u8 {None,Header_Corrupt,Input_Too_Small,Output_Too_Small,Payload_Corrupt,Missing_Decoder}
    Decoder :: struct {}
    header_read :: proc "contextless" (header:Header) -> (blocks:int,payload_size:int,err:Error) {return 0,0,.Header_Corrupt}
    decode :: proc "contextless" (d:^Decoder,header:Header,src,dst:[]u8,cached_destination:=false) -> (written:int,err:Error) {return 0,.Missing_Decoder}
}
