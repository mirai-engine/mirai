package host

// What the loads under way take of each frame on the main thread, shared
// among them: seconds of its time and bytes they give the renderer
// (assets_take). Each load gets its part of what the ones before it left. A
// load whose next asset does not fit its part, though it took nothing in the
// frame, gets the next frame to itself: a large asset goes alone, and no load
// waits forever behind the others. A load with nothing on the screen to keep
// smooth has the frames to itself (assets_load_whole): in the small part of
// the others, a scene of thousands of assets would take one per frame and
// wait for the frame rate, not for its work.

LOAD_FRAME_SECONDS :: 0.002
LOAD_FRAME_BYTES :: 16<<20
LOAD_WHOLE_FRAME_SECONDS :: 0.033 // what still lets a loading screen move

Load_Budget :: struct {
    frame:u64,   // the frame what it counts is of
    seconds:f64, // taken in that frame
    bytes:int,
    loads:int,   // that ask for parts
    served:int,  // of them, those that took their part in that frame
    alone:u64,   // the load the next frame is for; 0: none
    whole:u64,   // the load the frames are for while it lasts; 0: none
    next:u64,    // the id of the next load
}

Load_Share :: struct {
    seconds:f64,
    bytes:int,
    alone:bool, // the frame is of this load: its next asset goes whatever it takes
}

// A load starts asking for parts: its id.
assets_load_open :: proc(a:^Assets) -> u64 {
    b:=&a.loads
    b.next+=1
    b.loads+=1
    return b.next
}

assets_load_close :: proc(a:^Assets,load:u64) {
    b:=&a.loads
    if load==0 || b.loads==0 {return}
    b.loads-=1
    if b.alone==load {b.alone=0}
    if b.whole==load {b.whole=0}
}

// The load has the frames to itself until it closes.
assets_load_whole :: proc(a:^Assets,load:u64) {a.loads.whole=load}

// The part of the frame a load may take now: what the loads that took theirs
// in the frame left, shared with those that did not yet.
assets_load_share :: proc(a:^Assets,frame:u64,load:u64) -> (share:Load_Share) {
    b:=&a.loads
    if b.frame!=frame {b.frame,b.seconds,b.bytes,b.served=frame,0,0,0}
    if b.whole==load && load!=0 {
        b.served+=1
        return {max(LOAD_WHOLE_FRAME_SECONDS-b.seconds,0),max(LOAD_FRAME_BYTES-b.bytes,0),false}
    }
    if b.alone!=0 && b.alone!=load {return}
    left:=max(b.loads-b.served,1)
    b.served+=1
    share.seconds=max(LOAD_FRAME_SECONDS-b.seconds,0)/f64(left)
    share.bytes=max(LOAD_FRAME_BYTES-b.bytes,0)/left
    if b.alone==load {
        share={max(LOAD_FRAME_SECONDS-b.seconds,0),max(LOAD_FRAME_BYTES-b.bytes,0),true}
        b.alone=0
    }
    return
}

// What a load took of the frame.
assets_load_spend :: proc(a:^Assets,seconds:f64,bytes:int) {
    a.loads.seconds+=seconds
    a.loads.bytes+=bytes
}

// The next asset of a load does not fit its part and it took nothing: the
// next frame is its own, unless another load asked first.
assets_load_alone :: proc(a:^Assets,load:u64) {
    if a.loads.alone==0 {a.loads.alone=load}
}
