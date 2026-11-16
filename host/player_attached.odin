package host

import "core:os"
import "core:sync"
import "core:thread"

// A player another process opened and keeps (--attached): it ends when its
// stdin ends, which the system does when that process is gone, however it
// went. One with --surface reads its stdin for that already.
@(private)
Player_Attached :: struct {
    reader:^thread.Thread,
    closed:bool, // atomic
}

@(private)
attached_open :: proc(a:^Player_Attached) -> bool {
    a.reader=thread.create(proc(t:^thread.Thread) {
        a:=(^Player_Attached)(t.data)
        buffer:[256]u8
        for {
            n,error:=os.read(os.stdin,buffer[:])
            if n<=0 || error!=nil {break}
        }
        sync.atomic_store(&a.closed,true)
    })
    if a.reader==nil {return false}
    a.reader.data=a
    thread.start(a.reader)
    return true
}

// The reader stays blocked on stdin until it ends: it goes with the process.
@(private)
attached_gone :: proc(a:^Player_Attached) -> bool {return sync.atomic_load(&a.closed)}
