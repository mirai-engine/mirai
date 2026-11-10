package editor

import "mirai:core"
import "mirai:platform"
import gpu "mirai:render"
import "mirai:std/serial"
import "mirai:ui"

// A click of the middle button without a drag pings the point of the scene
// under the pointer: a mark in the color of who pinged, with their name,
// that everybody in the session sees for PING_SECONDS. A newer ping of the
// same editor takes the place of the one before.

PING_SECONDS :: 4.0
PING_RADIUS :: f32(0.35)
PING_HEIGHT :: f32(1.2)

@(private)
Collab_Ping :: struct {
    position:[3]f32,
    at:f64, // seconds of the clock of this end when it arrived; 0: none
}

@(private)
ping_now :: proc() -> f64 {return f64(platform.clock_ns())*1e-9}

// The editor that pings: this one alone outside a session.
@(private)
ping_self :: proc(s:^Session) -> int {
    if st:=collab_state(s);st!=nil && st.phase==.Joined {return int(st.self)}
    return 0
}

// The point of the scene under a point of the viewport: what the pointer is
// on, or the ground, or where the camera looks.
@(private)
ping_point :: proc(s:^Session,w:core.World_Ref,point:[2]f32) -> [3]f32 {
    if hit:=pick_point(s,w,point);hit.entity!=core.NONE {return hit.position}
    ray:=viewport_ray(s.viewport,point)
    if ray.direction.y< -1e-4 {
        if t:=-ray.origin.y/ray.direction.y;t>0 && t<1000 {return ray.origin+ray.direction*t}
    }
    return s.viewport.orbit.target
}

// This end pings a point of the viewport.
ping :: proc(s:^Session,w:core.World_Ref,point:[2]f32) {
    c:=collab_of(s)
    if c==nil {return}
    position:=ping_point(s,w,point)
    c.pings[ping_self(s)]={position=position,at=ping_now()}
    st:=c.state
    if st==nil || st.phase!=.Joined {return}
    out:serial.Writer
    collab_begin(&out,.Ping,32)
    serial.write_scalar(&out,st.self)
    serial.write_scalar(&out,position.x);serial.write_scalar(&out,position.y);serial.write_scalar(&out,position.z)
    collab_broadcast(st,serial.writer_bytes(&out))
}

// A ping of another editor; the host passes it on.
@(private)
collab_ping_receive :: proc(s:^Session,st:^Collab_State,from:int,data:[]u8) {
    r:=serial.reader_init(data[1:])
    id:=int(serial.read_u8(&r))
    position:=[3]f32{serial.read_f32(&r),serial.read_f32(&r),serial.read_f32(&r)}
    if r.failed || id>=COLLAB_PEERS || id==int(st.self) || !finite3(position) {return}
    if st.role==.Host && id!=from {return}
    if c:=collab_of(s);c!=nil {c.pings[id]={position=position,at=ping_now()}}
    if st.role==.Host {collab_broadcast(st,data,from)}
}

// The pings still in sight: rings on the ground of the point, a line up from
// it, and the name of who pinged over it.
pings_draw :: proc(s:^Session) {
    c:=collab_of(s)
    if c==nil || s.mode!=.Edit {return}
    now:=ping_now()
    lines:=&s.viewport.lines
    for &ping,i in c.pings {
        if ping.at==0 {continue}
        if now-ping.at>PING_SECONDS {ping.at=0;continue}
        color:=collab_color(i)
        rgba:=[4]f32{f32(color[0])/255,f32(color[1])/255,f32(color[2])/255,1}
        gpu.debug_circle(lines,ping.position,{0,1,0},PING_RADIUS,rgba,32)
        gpu.debug_circle(lines,ping.position,{0,1,0},PING_RADIUS*0.45,rgba,24)
        top:=ping.position+{0,PING_HEIGHT,0}
        gpu.debug_line(lines,ping.position,top,rgba)
        screen,front:=viewport_screen(s.viewport,top)
        if !front {continue}
        name:=collab_peer_name(s,i)
        if st:=c.state;st==nil || st.phase!=.Joined {name=""}
        rect:=ui.Rect{screen.x-6,screen.y-12,12,12}
        ui.draw_circle(s.gui.ctx,ui.rect_center(rect),6,color)
        ui.draw_ring(s.gui.ctx,ui.rect_center(rect),6,1.5,ui.tone(s.gui.ctx,"panel"))
        if name!="" {presence_name_draw(s,{rect.x,rect.y-2,rect.w,rect.h},name,color)}
    }
}
