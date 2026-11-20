package asset

import "core:encoding/base32"
import "core:strings"
import "mirai:store"

GENERATED_PROGRAM_PREFIX :: "mirai_ddc_"

generated_program_id :: proc(address:store.Hash,allocator:=context.allocator) -> string {
    if address=={} {return ""}
    address:=address
    encoded:=base32.encode(address[:],allocator=context.temp_allocator)
    id,error:=strings.concatenate({GENERATED_PROGRAM_PREFIX,encoded[:52]},allocator)
    return id if error==nil else ""
}

generated_program_address :: proc(id:string) -> (address:store.Hash,ok:bool) {
    if len(id)!=len(GENERATED_PROGRAM_PREFIX)+52 ||
        !strings.has_prefix(id,GENERATED_PROGRAM_PREFIX) {return}
    padded:[56]u8
    copy(padded[:52],id[len(GENERATED_PROGRAM_PREFIX):])
    copy(padded[52:],"====")
    bytes,error:=base32.decode(string(padded[:]),allocator=context.temp_allocator)
    if error!=.None || len(bytes)!=len(address) {return}
    copy(address[:],bytes)
    if address=={} || generated_program_id(address,context.temp_allocator)!=id {return {},false}
    return address,true
}
