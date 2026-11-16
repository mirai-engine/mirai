#+build !windows
package asset

import "core:mem"

@(private)
bench_read_uncached :: proc(path:string,size:int,allocator:mem.Allocator) -> (data:[]u8,ok:bool) {
    return nil,false
}
