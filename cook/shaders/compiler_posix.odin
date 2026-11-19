#+build !windows
package shaders

// The library of the package of slangc: lib/ beside its bin/.
@(private)
compiler_library :: proc(slangc:string,allocator:=context.allocator) -> string {
    name:="libslang.dylib" when ODIN_OS==.Darwin else "libslang.so"
    return path_join(path_parent(path_parent(slangc)),"lib",name,allocator=allocator)
}
