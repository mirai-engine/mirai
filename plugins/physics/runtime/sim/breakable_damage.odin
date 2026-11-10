package mirai_physics

import "core:mem"
import "mirai:std/geom"

Break_Region :: struct {
    point:Vec3,
    radius:f32,
    half_extents:Vec3,
    rotation:Quat,
    falloff:Radial_Falloff,
}

@(private)
break_region_weight :: proc "contextless" (event:^Break_Event,point:Vec3) -> f32 {
    if event.half_extents!={} {return box_weight(point,event.point,event.half_extents,event.rotation,event.falloff)}
    return radial_weight(length(point-event.point),event.radius,event.falloff)
}

breakable_strain_region :: proc(w:^World,h:Breakable_Handle,piece:i32,region:Break_Region,amount:f32,impulse:Vec3={},weaken:=false) -> (event:Break_Event,broke,strained:bool) {
    d,index:=breakable_get(w,h)
    if d==nil || piece>=0 && piece_body(w,index,piece)=={} {return}
    w.breaking.tick=w.tick
    event={breakable=h,tick=u32(w.breaking.tick),piece=piece,point=region.point,radius=region.radius,half_extents=region.half_extents,
        rotation=region.rotation,falloff=region.falloff,vector=impulse,strain=amount,kind=weaken?.Weaken:.Damage}
    broke,strained=break_damage(w,index,&event)
    return
}

// Strains every breakable that `filter` meets in a region, body by body, so that the event of each body can
// travel in its frame: those that reached a bond are listed in world_events(w).breaks with the events of
// the last step. Debris and filter.ignore_body are left alone. Returns the bodies strained.
breakables_strain :: proc(w:^World,region:Break_Region,amount:f32,impulse:Vec3={},weaken:=false,filter:=QUERY_FILTER_DEFAULT) -> (strained:int) {
    s:=&w.breaking
    if !s.made || w.kept || w.breakable_count==0 {return}
    for &d,slot in w.breakables[:w.breakable_high] {
        if d.generation&1==0 || query_filter_response(filter,d.filter)==.Ignore {continue}
        // One piece of each body, taken before any of them breaks.
        s.mark+=1
        if s.mark==0 {
            mem.zero_slice(s.marks)
            s.mark=1
        }
        bodies:=0
        for piece:=d.piece_list;piece>=0;piece=w.pieces[piece].next {
            body:=shape_body(w,w.pieces[piece].shape)
            if body=={} || .Debris in w.pieces[piece].flags || body==filter.ignore_body {continue}
            at:=body_slot(body)
            if s.marks[at]==s.mark {continue}
            s.marks[at]=s.mark
            s.firsts[bodies]=piece
            bodies+=1
        }
        handle:=breakable_handle(w,i32(slot))
        for piece in s.firsts[:bodies] {
            event,_,reached:=breakable_strain_region(w,handle,piece,region,amount,impulse,weaken)
            if !reached {continue}
            break_push(w,i32(slot),event)
            strained+=1
        }
    }
    return
}

// The breakable a body is of, and one of its pieces on that body; zero and -1 for any other body.
breakable_of :: proc(w:^World,body:Body_Handle) -> (h:Breakable_Handle,piece:i32) {
    b,_:=body_get(w,body)
    if b==nil || !w.breaking.made || w.kept {return {},-1}
    for shape:=b.shape_list;shape>=0;shape=w.shapes[shape].next {
        tag:=w.shapes[shape].tag
        if tag==0 || tag-1>=u32(w.piece_high) || w.pieces[tag-1].shape!=shape_handle(w,shape) {continue}
        return breakable_handle(w,w.pieces[tag-1].breakable),i32(tag-1)
    }
    return {},-1
}

@(private)
break_finite :: proc "contextless" (values:..f32) -> bool {
    for value in values {if value-value!=0 {return false}}
    return true
}

@(private)
break_source_valid :: proc(desc:Breakable_Desc,source:^geom.Fracture) -> bool {
    count:=len(source.pieces)
    if len(desc.piece_anchors)!=0 && len(desc.piece_anchors)!=count || len(desc.piece_clusters)!=0 && len(desc.piece_clusters)!=count ||
       len(desc.bond_strength)!=0 && len(desc.bond_strength)!=len(source.connections) ||
       len(desc.clusters)>0 && len(desc.piece_clusters)!=count {return false}
    for cluster,at in desc.clusters {
        if cluster.parent < -1 || int(cluster.parent)>=at || !(cluster.strength>0) || !break_finite(cluster.strength) {return false}
        if u64(cluster.first_point)+u64(cluster.point_count)>u64(len(desc.cluster_points)) || cluster.point_count>0 && cluster.point_count<4 {return false}
        represented:=false
        for parent in desc.piece_clusters {
            if parent < -1 || int(parent)>=len(desc.clusters) {return false}
            for ancestor:=parent;ancestor>=0;ancestor=desc.clusters[ancestor].parent {
                if ancestor==i32(at) {represented=true;break}
            }
        }
        if !represented {return false}
    }
    for cluster in desc.piece_clusters {if cluster < -1 || int(cluster)>=len(desc.clusters) {return false}}
    for point in desc.cluster_points {if !break_finite(point.x,point.y,point.z) {return false}}
    for piece in source.pieces {
        if u64(piece.first_vertex)+u64(piece.vertex_count)>u64(len(source.mesh.positions)) || u64(piece.first_index)+u64(piece.index_count)>u64(len(source.mesh.indices)) {return false}
        if u64(piece.first_index/3)+u64(piece.index_count/3)>u64(len(source.mesh.materials)) ||
           len(source.mesh.normals)>0 && u64(piece.first_vertex)+u64(piece.vertex_count)>u64(len(source.mesh.normals)) ||
           len(source.mesh.uvs)>0 && u64(piece.first_vertex)+u64(piece.vertex_count)>u64(len(source.mesh.uvs)) ||
           len(source.mesh.colors)>0 && u64(piece.first_vertex)+u64(piece.vertex_count)>u64(len(source.mesh.colors)) {return false}
        for point in source.mesh.positions[piece.first_vertex:][:piece.vertex_count] {if !break_finite(point.x,point.y,point.z) {return false}}
        for index in source.mesh.indices[piece.first_index:][:piece.index_count] {if index>=piece.vertex_count {return false}}
    }
    for bond in source.connections {if bond.a>=bond.b || int(bond.b)>=count || !(bond.area>0) || !break_finite(bond.area) {return false}}
    for strength in desc.bond_strength {if strength<0 || !break_finite(strength) {return false}}
    return true
}

@(private)
break_cluster_common :: proc "contextless" (clusters:[]Cluster_Desc,a,b:i32) -> i32 {
    left,right:=a,b
    for left>=0 && right>=0 && left!=right {
        if left>right {left=clusters[left].parent} else {right=clusters[right].parent}
    }
    return left==right?left:-1
}

breakable_strain :: proc(w:^World,h:Breakable_Handle,point:Vec3,radius,amount:f32,impulse:Vec3={}) -> (event:Break_Event,broke:bool) {
    d,index:=breakable_get(w,h)
    if d==nil {return}
    w.breaking.tick=w.tick
    event={breakable=h,tick=u32(w.breaking.tick),piece=-1,point=point,vector=impulse,radius=radius,kind=.Damage,strain=amount,falloff=.Linear}
    broke,_=break_damage(w,index,&event)
    return
}

breakable_strain_body :: proc(w:^World,h:Breakable_Handle,piece:i32,point:Vec3,radius,amount:f32,impulse:Vec3={}) -> (event:Break_Event,broke,strained:bool) {
    d,index:=breakable_get(w,h)
    if d==nil || piece_body(w,index,piece)=={} {return}
    w.breaking.tick=w.tick
    event={breakable=h,tick=u32(w.breaking.tick),piece=piece,point=point,vector=impulse,radius=radius,kind=.Damage,strain=amount,falloff=.Linear}
    broke,strained=break_damage(w,index,&event)
    return
}

breakable_weaken :: proc(w:^World,h:Breakable_Handle,point:Vec3,radius,amount:f32) -> (event:Break_Event,strained:bool) {
    d,index:=breakable_get(w,h)
    if d==nil {return}
    w.breaking.tick=w.tick
    event={breakable=h,tick=u32(w.breaking.tick),piece=-1,point=point,radius=radius,kind=.Weaken,strain=amount,falloff=.Linear}
    _,strained=break_damage(w,index,&event)
    return
}

breakable_weaken_body :: proc(w:^World,h:Breakable_Handle,piece:i32,point:Vec3,radius,amount:f32) -> (event:Break_Event,strained:bool) {
    d,index:=breakable_get(w,h)
    if d==nil || piece_body(w,index,piece)=={} {return}
    w.breaking.tick=w.tick
    event={breakable=h,tick=u32(w.breaking.tick),piece=piece,point=point,radius=radius,kind=.Weaken,strain=amount,falloff=.Linear}
    _,strained=break_damage(w,index,&event)
    return
}

@(private)
break_clusters_damage :: proc(w:^World,index:i32,event:^Break_Event,only:Body_Handle) -> (broke,strained:bool) {
    d:=&w.breakables[index]
    count:=0
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {
        if .Cluster in w.bonds[slot].flags {w.breaking.ids[count]=u32(slot);count+=1}
    }
    #reverse for encoded in w.breaking.ids[:count] {
        slot:=i32(encoded)
        c:=&w.bonds[slot]
        if .Broken in c.flags || c.cluster>=0 && .Broken not_in w.bonds[c.cluster].flags {continue}
        weight:f32
        for piece_slot:=d.piece_list;piece_slot>=0;piece_slot=w.pieces[piece_slot].next {
            piece:=&w.pieces[piece_slot]
            body:=shape_body(w,piece.shape)
            if body=={} || event.piece>=0 && body!=only {continue}
            belongs:=false
            for ancestor:=piece.cluster;ancestor>=0;ancestor=w.bonds[ancestor].cluster {
                if ancestor==slot {belongs=true;break}
            }
            if belongs {weight=max(weight,break_region_weight(event,xf_point(body_transform(w,body),piece.center)))}
        }
        if weight<=0 {continue}
        c.strain=min(max(f32),c.strain+event.strain*weight)
        strained=true
        if event.kind==.Weaken || c.strain<c.strength {continue}
        c.flags+={.Broken}
        d.revision+=1
        broke=true
        for bond_slot:=d.bond_list;bond_slot>=0;bond_slot=w.bonds[bond_slot].next {
            bond:=&w.bonds[bond_slot]
            if .Cluster not_in bond.flags && bond.cluster==slot {bond.flags+={.Broken}}
        }
    }
    return
}

breakable_clusters :: proc(w:^World,h:Breakable_Handle,out:[]Cluster_Info) -> int {
    d,_:=breakable_get(w,h)
    if d==nil {return 0}
    count:=0
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {
        c:=&w.bonds[slot]
        if .Cluster not_in c.flags {continue}
        if count<len(out) {
            parent,at:i32=-1,0
            for before:=d.bond_list;before>=0 && before!=slot;before=w.bonds[before].next {
                if .Cluster not_in w.bonds[before].flags {continue}
                if before==c.cluster {parent=at}
                at+=1
            }
            out[count]={parent,c.strength,c.strain,.Broken in c.flags}
        }
        count+=1
    }
    return count
}

@(private)
break_remove_body :: proc(w:^World,index,piece_slot:i32) -> bool {
    body:=piece_body(w,index,piece_slot)
    if body=={} || w.pieces[piece_slot].group==0 {return false}
    cosmetic:=.Debris in w.pieces[piece_slot].flags
    d:=&w.breakables[index]
    break_bodies(w,d)
    for slot:=d.piece_list;slot>=0;slot=w.pieces[slot].next {
        if w.breaking.body[slot]==body {piece_remove(w,slot)}
    }
    if cosmetic {return true}
    for slot:=d.bond_list;slot>=0;slot=w.bonds[slot].next {
        c:=&w.bonds[slot]
        if .Cluster not_in c.flags && (w.pieces[c.a].shape=={} || w.pieces[c.b].shape=={}) {c.flags+={.Broken}}
    }
    return true
}
