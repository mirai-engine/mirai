#+build !windows
package project

// A path as the system names it: on Linux and macOS, the path itself.
path_native :: proc(location:string) -> (native:string,ok:bool) {
    return location,true
}
