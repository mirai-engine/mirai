package project

// A file written a while after the last change to what it holds, so that a
// burst of changes (a slider dragged) writes it once: whoever keeps it looks
// at the hash of what the file would hold every REST_LOOK seconds, and writes
// once a look finds it as the look before did, after REST_LOOKS looks of
// changing all the time, and when it closes (rest_flush). What it holds is
// never looked at while busy (a gesture under way).

REST_LOOK :: f32(0.5) // s between looks
REST_LOOKS :: 10      // looks that a value that never rests waits to be written

Rest :: struct {
    written:u64, // the hash of what the file holds
    seen:u64,    // at the last look
    look:f32,    // s since the last look
    waits:u32,   // looks that found it changed since it was written
}

// From what the file holds.
rest_init :: proc "contextless" (r:^Rest,hash:u64) {
    r^={written=hash,seen=hash}
}

// Whether it is time to look at what the file would hold.
rest_look :: proc "contextless" (r:^Rest,dt:f32,busy:=false) -> bool {
    r.look=busy?0:r.look+dt
    if r.look<REST_LOOK {return false}
    r.look=0
    return true
}

// Whether a look that finds hash writes the file now; the caller writes it.
rest_due :: proc "contextless" (r:^Rest,hash:u64) -> bool {
    changed:=hash!=r.seen
    r.seen=hash
    if hash==r.written {
        r.waits=0
        return false
    }
    if changed && r.waits+1<REST_LOOKS {
        r.waits+=1
        return false
    }
    r.written,r.waits=hash,0
    return true
}

// Whether what hashes to hash is still to be written, when the keeper closes.
rest_flush :: proc "contextless" (r:^Rest,hash:u64) -> bool {
    due:=hash!=r.written
    rest_init(r,hash)
    return due
}
