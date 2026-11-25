#+build !linux
package hub

// Only Linux confines a node; elsewhere it runs as it is.
sandbox_apply :: proc(store_root:string,ports:Sandbox_Ports) -> (applied:bool,why:string) {
    return false,"Landlock and seccomp are Linux's; this system runs the node unconfined"
}
