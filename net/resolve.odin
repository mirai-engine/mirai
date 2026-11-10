package mirai_net

import cnet "core:net"
import "core:strings"
import "core:sync"
import "core:thread"

// A host name resolved on a thread of its own: a lookup blocks for as long as the resolver takes, and a
// game asks while it keeps drawing. resolve_start begins, resolve_poll answers without waiting, and
// resolve_end releases the thread, waiting for it if the lookup still runs.
Resolve :: struct {
    text:string,
    worker:^thread.Thread,
    done:bool,            // atomic: the addresses are written
    addresses:[2]Address, // the IPv6 one first when the name has one, then the IPv4 one
    count:int,
}

// "example.com:7777", "localhost:7777" or an address as address_parse takes it. False when no thread starts.
resolve_start :: proc(r:^Resolve,text:string) -> bool {
    kept,error:=strings.clone(text)
    if error!=nil {return false}
    r^={text=kept}
    r.worker=thread.create(proc(t:^thread.Thread) {
        r:=(^Resolve)(t.data)
        ep4,ep6,_:=cnet.resolve(r.text)
        count:=0
        if ep6.address!=nil {r.addresses[count]=address_from_endpoint(ep6);count+=1}
        if ep4.address!=nil {r.addresses[count]=address_from_endpoint(ep4);count+=1}
        r.count=count
        sync.atomic_store_explicit(&r.done,true,.Release)
    })
    if r.worker==nil {
        delete(r.text)
        r^={}
        return false
    }
    r.worker.data=r
    thread.start(r.worker)
    return true
}

// done: the lookup finished; addresses is empty when the name did not resolve.
resolve_poll :: proc(r:^Resolve) -> (addresses:[]Address,done:bool) {
    if r.worker==nil || !sync.atomic_load_explicit(&r.done,.Acquire) {return nil,false}
    return r.addresses[:r.count],true
}

resolve_end :: proc(r:^Resolve) {
    if r.worker!=nil {
        thread.join(r.worker)
        thread.destroy(r.worker)
    }
    delete(r.text)
    r^={}
}
