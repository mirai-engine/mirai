package mirai_physics

import "mirai:std/geom"

// What the tests ask of a breakable and read of it: each request is one event of break_apply.

Bond_Info :: struct {a,b:i32,area,strain:f32,broken:bool}

// Bonds of the breakable, broken ones included; `a` and `b` are piece ids.
breakable_bonds :: proc(w:^World,h:Breakable_Handle,out:[]Bond_Info) -> int {
    d,_:=breakable_get(w,h)
    if d==nil {return 0}
    count:=0
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {
        c:=&w.bonds[slot]
        if .Cluster in c.flags {continue}
        if count<len(out) {out[count]={c.a,c.b,c.area,c.strain,.Broken in c.flags}}
        count+=1
    }
    return count
}

// Mass of the pieces that are still in the world.
breakable_mass :: proc(w:^World,h:Breakable_Handle) -> f32 {
    d,_:=breakable_get(w,h)
    if d==nil {return 0}
    volume:f32
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        if .Gone not_in w.pieces[slot].flags {volume+=w.pieces[slot].volume}
    }
    return volume*d.density
}

// The hull of a piece as a closed triangle mesh in the frame of its body.
breakable_piece_mesh :: proc(w:^World,h:Breakable_Handle,id:i32,out:^geom.Mesh_Buffer) -> bool {
    d,index:=breakable_get(w,h)
    if d==nil || id<0 || id>=w.piece_high || w.pieces[id].breakable!=index {return false}
    hull:=hull_get(w,w.pieces[id].hull)
    if hull==nil {return false}
    hull_to_mesh(hull,out)
    return true
}

// A strain around a point that fades to nothing at the radius.
@(private)
test_strain :: proc(h:Breakable_Handle,piece:i32,point:Vec3,radius,amount:f32,impulse:Vec3,kind:=Break_Kind.Damage) -> Break_Event {
    return {breakable=h,piece=piece,region={point=point,radius=radius,blend=radius},vector=impulse,strain=amount,kind=kind}
}

breakable_damage :: proc(w:^World,h:Breakable_Handle,point:Vec3,radius:f32,impulse:Vec3) -> (event:Break_Event,broke:bool) {
    event,broke,_=break_apply(w,test_strain(h,-1,point,radius,length(impulse),impulse))
    return
}
breakable_strain :: proc(w:^World,h:Breakable_Handle,point:Vec3,radius,amount:f32,impulse:Vec3={}) -> (event:Break_Event,broke:bool) {
    event,broke,_=break_apply(w,test_strain(h,-1,point,radius,amount,impulse))
    return
}
breakable_weaken :: proc(w:^World,h:Breakable_Handle,point:Vec3,radius,amount:f32) -> (event:Break_Event,strained:bool) {
    event,_,strained=break_apply(w,test_strain(h,-1,point,radius,amount,{},.Weaken))
    return
}
breakable_slice :: proc(w:^World,h:Breakable_Handle,point,normal:Vec3) -> (event:Break_Event,cut:bool) {
    event,cut,_=break_apply(w,{breakable=h,piece=-1,region={point=point},vector=normal,kind=.Slice})
    return
}

// The same on the body that holds one piece alone.
breakable_damage_body :: proc(w:^World,h:Breakable_Handle,piece:i32,point:Vec3,radius:f32,impulse:Vec3) -> (event:Break_Event,broke,strained:bool) {
    if piece<0 {return}
    return break_apply(w,test_strain(h,piece,point,radius,length(impulse),impulse))
}
breakable_strain_body :: proc(w:^World,h:Breakable_Handle,piece:i32,point:Vec3,radius,amount:f32,impulse:Vec3={}) -> (event:Break_Event,broke,strained:bool) {
    if piece<0 {return}
    return break_apply(w,test_strain(h,piece,point,radius,amount,impulse))
}
breakable_slice_body :: proc(w:^World,h:Breakable_Handle,piece:i32,point,normal:Vec3) -> (event:Break_Event,cut:bool) {
    if piece<0 {return}
    event,cut,_=break_apply(w,{breakable=h,piece=piece,region={point=point},vector=normal,kind=.Slice})
    return
}
breakable_remove_body :: proc(w:^World,h:Breakable_Handle,piece:i32) -> (event:Break_Event,removed:bool) {
    event,removed,_=break_apply(w,{breakable=h,piece=piece,kind=.Remove})
    return
}
breakable_strain_region :: proc(w:^World,h:Breakable_Handle,piece:i32,region:Break_Region,amount:f32,impulse:Vec3={},weaken:=false) -> (event:Break_Event,broke,strained:bool) {
    return break_apply(w,{breakable=h,piece=piece,region=region,vector=impulse,strain=amount,kind=weaken?.Weaken:.Damage})
}
break_event_apply :: proc(w:^World,event:Break_Event) -> bool {
    _,changed,_:=break_apply(w,event)
    return changed
}
