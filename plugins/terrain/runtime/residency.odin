package terrain

import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:host"
import "mirai:core"
import camera "mirai:engine/camera"
import scene "mirai:engine/scene"
import phys "plugins:physics/runtime"
import "mirai:std/jobs"
import mm "mirai:std/math"

// The view has to move this far for the levels to be chosen again.
@(private) LOD_MOVE :: f32(0.25)
// A chunk shown this near a viewer, in reaches, is deep: its borders may read
// samples (Border_Levels). Its pages came while it went from 1 to this.
@(private) DEEP_REACH :: 1/scene.RESIDENT_KEEP

// Without Terrain_Settings.lod_distance, level 0 reaches LOD_CHUNKS chunk widths.
@(private)
lod_base :: proc "contextless" (s:^Source,settings:Terrain_Settings) -> f32 {
    return settings.lod_distance>0?settings.lod_distance:f32(LOD_CHUNKS)*f32(s.chunk_cells)*s.cell
}

@(private)
split_before :: proc(a,b:Split) -> bool {
    if a.near!=b.near {return a.near<b.near}
    if a.far!=b.far {return a.far<b.far}
    if a.depth!=b.depth {return a.depth<b.depth}
    if a.owner!=b.owner {return a.owner<b.owner}
    return a.node<b.node
}

// Chooses what each terrain wants of its source and how each piece is built,
// from the distances of its views and its streaming sources, and marks the
// pieces whose mesh shows something else. Each terrain walks its tree from
// its roots and goes down only where a chunk under a node may be near a
// viewer or take a collider, or where the view is nearer than the finest
// level of a node reaches: what it looks at follows what is near and seen,
// not how many nodes it has. Within Terrain_Settings.chunks, the nearest open
// first, so past it the farthest show coarser nodes and nothing goes. Runs
// when a view or the transform of a terrain moves, or the sources, the
// colliders or the chunks change; while pieces wait to be built, again once a
// frame (once_more: the first call of a frame).
@(private)
resident_lod :: proc(resident:^Terrain_Resident,data:^Terrain_Data,worlds:^core.Table(core.World_Transform,.Read),views:Lod_Views,sources:core.Ref(scene.Streaming_Sources),simulation:core.Ref(scene.Simulation_Sources),settings:Terrain_Settings,terrains:^core.Table(Terrain,$A),c:^Chunk_Tables,physics:phys.Physics_Settings,problems:^core.Problems,once_more:=true,focus:=Terrain_Focus{}) {
    views:=views
    // Only the places of the terrains move their pieces: what else moves in the world does not.
    placed:=core.changes(worlds,&resident.lod_seen[0])
    moved:=placed.all
    if placed.written && !moved {for &owner in resident.owners {
        if row:=core.row_of(worlds,owner.entity);row>=0 && core.changed(worlds,placed,row) || slice.contains(placed.gone,owner.entity) {moved=true;break}
    }}
    moved|=core.touched(c.colliders,&resident.lod_seen[1])
    stamp:=[3]u64{sources.ptr!=nil?sources.ptr.revision:0,u64(len(resident.owners)),resident.marks}
    simulated:[]scene.Source
    if simulation.ptr!=nil {simulated=simulation.ptr.items[:clamp(simulation.ptr.count,0,scene.SOURCES_MAX)]}
    grounds_moved:=scene.sources_moved(resident.lod_simulation[:resident.lod_simulation_count],simulated)
    pending:=false
    if once_more {for &source in resident.sources {if len(source.pending)>0 {pending=true;break}}}
    still:=views.count==resident.lod_view_count
    for view,v in views.items[:views.count] {
        offset:=view.position-resident.lod_views[v]
        still&&=linalg.dot(offset,offset)<LOD_MOVE*LOD_MOVE
    }
    distances:=[3]f32{settings.lod_distance,settings.collision_distance,settings.resident_distance}
    // Where the brush is chooses pieces; what its stroke changed does not.
    brush:=Terrain_Focus{source=focus.source,center=focus.center,radius=focus.radius}
    if !pending && !moved && !grounds_moved && stamp==resident.lod_stamp && distances==resident.lod_distances && brush==resident.focus && still {return}
    resident.lod_simulation_count=copy(resident.lod_simulation[:],simulated)
    for view,v in views.items[:views.count] {resident.lod_views[v]=view.position}
    resident.lod_view_count,resident.lod_stamp,resident.lod_distances,resident.focus=views.count,stamp,distances,brush
    resident.cut=true
    stream:=settings.resident_distance>0
    looked:=false
    for view in views.items[:views.count] {looked||=view.size.x>0 && view.size.y>0}
    resident.lod_pass+=1
    pass:=resident.lod_pass
    clear(&resident.splits)
    roots:=0
    owners_sides(resident,data,worlds,c.ids)
    if !lod_places(resident,data,worlds,terrains,views,sources,simulated,settings.resident_distance,stream) {return}
    // What each terrain held a state of is looked at again, with what is above it.
    for &owner,o in resident.owners {
        place:=&resident.places[o]
        clear(&owner.kept)
        if place.s!=nil {for i in owner.visit {if node_held(&owner,place,int(i)) {append(&owner.kept,i)}}}
        clear(&owner.visit)
        if place.s==nil {continue}
        for i in owner.kept {visit_add_up(&owner,place,int(i),pass,views.count,stream)}
    }
    reach:=collider_reach(resident,settings,c,physics,pass,views.count,stream)
    for &owner,o in resident.owners {
        if place:=&resident.places[o];place.s!=nil {owner_walk(resident,data,&owner,place,settings,reach,focus,pass,views.count,stream)}
    }
    resident_needed(resident,settings,reach,focus)
    joins_resident(resident,data,pass,views.count,stream)
    // What each terrain would open: its chunks first, each node over its children.
    for &owner,o in resident.owners {
        place:=&resident.places[o]
        if place.s==nil {continue}
        entry:=data_find(data,owner.source)
        s:=place.s
        q:=place.q
        chunks:=q.first[1]
        base:=lod_base(s,settings)
        by_error:=lod_by_error(entry,settings)
        roots+=q.counts[q.depth].x*q.counts[q.depth].y*q.tall[q.depth]
        slice.sort(owner.visit[:])
        for at in owner.visit {
            i:=int(at)
            if i<chunks {continue}
            node:=&owner.nodes[i]
            node.want=false
            for child in quad_children(q,i) {
                if child<0 || owner.nodes[child].visit!=pass {continue}
                if child<chunks?owner.nodes[child].resident:owner.nodes[child].want {node.want=true;break}
            }
            if !node.want {node.want=node_finer(s,q,i,node,settings,stream,by_error,base)}
            if node.want {append(&resident.splits,Split{node.reach,node.distance,-i32(quad_depth(q,i)),u32(o),u32(i)})}
        }
        // What would open has its children looked at: one of them may show in its place.
        count:=len(owner.visit)
        for k in 0..<count {
            i:=int(owner.visit[k])
            if i<chunks || !owner.nodes[i].want {continue}
            for child in quad_children(q,i) {if child>=0 {visit_add(&owner,place,child,pass,views.count,stream)}}
        }
        slice.sort(owner.visit[:])
    }
    // Within Terrain_Settings.chunks of pieces, the nearest open first.
    budget:=int(data.settings.chunks)
    if roots>budget {
        core.report(problems,core.NONE,"terrain.chunks_full","the roots of the terrains alone are %d pieces and Terrain_Settings.chunks allows %d: they show, and nothing finer does; raise it, or show fewer terrains",roots,budget)
    }
    budget-=roots
    slice.sort_by(resident.splits[:],split_before)
    for &owner in resident.owners {for i in owner.visit {owner.nodes[i].open=false}}
    for split in resident.splits {
        owner:=&resident.owners[split.owner]
        q:=&owner.quad
        node:=&owner.nodes[split.node]
        parent:=quad_parent(q,int(split.node))
        if parent>=0 && !owner.nodes[parent].open {continue}
        cost:=-1
        for child in quad_children(q,int(split.node)) {if child>=0 {cost+=1}}
        if budget<cost {continue}
        budget-=cost
        node.open=true
    }
    for &owner in resident.owners {
        q:=&owner.quad
        for i in owner.visit {
            parent:=quad_parent(q,int(i))
            node:=&owner.nodes[i]
            node.cut=!node.open && (parent<0 || owner.nodes[parent].open)
        }
    }
    resident_colliders(resident,data,terrains,c,settings,physics,looked)
    // How each terrain builds what it wants: the levels of its chunks, then
    // those along the edges it shares, then each piece.
    for &owner,o in resident.owners {
        place:=&resident.places[o]
        entry:=data_find(data,owner.source)
        source:=entry!=nil?resident_source_find(resident,owner.source,owner.entity):nil
        if place.s==nil || source==nil || len(source.chunks)!=len(entry.dirty) || len(owner.nodes)!=len(source.chunks) {continue}
        s:=&entry.source
        q:=&source.quad
        chunks:=q.first[1]
        for i in owner.visit {
            node:=&owner.nodes[i]
            chunk:=&source.chunks[i]
            // A streamed terrain keeps its open nodes and its roots too: they stand in
            // for what they cover while it comes (owner_cut), and show when all else goes.
            root:=int(i)>=q.first[q.depth]
            standing:=root_stands_in(&owner,s,int(i),looked)
            chunk.resident=node.cut || standing || stream && (node.open || root)
            chunk.wanted.collision=(node.cut || standing) && node.collide
            if int(i)<chunks {source.deep[i]=node.cut && (!stream || node.reach<=DEEP_REACH)}
        }
        // A Volume has no levels of its own: its nodes show what is far.
        if s.kind!=.Heightfield {continue}
        // The borders of a node read the chunks along its edges.
        count:=len(owner.visit)
        for k in 0..<count {
            i:=int(owner.visit[k])
            if i<chunks || !owner.nodes[i].cut {continue}
            a,b:=quad_chunks(q,i)
            for x in a.x..<b.x {
                visit_add(&owner,place,chunk_index(s,{i32(x),0,i32(a.y)}),pass,views.count,stream)
                visit_add(&owner,place,chunk_index(s,{i32(x),0,i32(b.y-1)}),pass,views.count,stream)
            }
            for z in a.y..<b.y {
                visit_add(&owner,place,chunk_index(s,{i32(a.x),0,i32(z)}),pass,views.count,stream)
                visit_add(&owner,place,chunk_index(s,{i32(b.x-1),0,i32(z)}),pass,views.count,stream)
            }
        }
        slice.sort(owner.visit[:])
        heightfield_levels(entry,source,&owner,settings,lod_by_error(entry,settings),lod_base(s,settings),pass,&resident.stack)
    }
    owners_levels_meet(resident,data)
    visited:=0
    for &owner in resident.owners {visited+=len(owner.visit)}
    resident.stats.visited=u32(visited)
    for &owner,o in resident.owners {
        place:=&resident.places[o]
        entry:=data_find(data,owner.source)
        source:=entry!=nil?resident_source_find(resident,owner.source,owner.entity):nil
        if place.s==nil || source==nil || len(source.chunks)!=len(entry.dirty) || len(owner.nodes)!=len(source.chunks) {continue}
        s:=&entry.source
        q:=&source.quad
        chunks:=q.first[1]
        base:=lod_base(s,settings)
        by_error:=lod_by_error(entry,settings)
        border:=resident_border(resident,source)
        for at in owner.visit {
            i:=int(at)
            chunk:=&source.chunks[i]
            if !chunk.resident {
                if (chunk.shown || chunk.mesh!={}) && !chunk.visible {source_pending(source,i)}
                continue
            }
            key:=chunk.wanted
            key.border=0
            if i<chunks {
                coord:=chunk_coord(s,i)
                key.lod=chunk_lod_border(&border,source.levels[i],{int(coord.x),int(coord.z)})
                key.join=join_cut_key(s,source.join.cuts[:],i)
                if source.join.ground!={} && join_band_chunk(s,i,key.lod.level) {key.join=source.join.hash}
                if s.kind==.Heightfield {
                    low,high,_:=chunk_region(s,coord)
                    key.join~=edge_key(resident,data,&owner,s,low.xz,high.xz)
                }
            } else {
                minimum,maximum:=node_lod_min(s,q,i),node_lod_max(s,q,i)
                level:=chunk.wanted.lod.level
                switch {
                case settings.lod_distance<0: level=minimum
                case by_error: level=lod_level_error(entry.source.coarse.errors,q,i,minimum,maximum,chunk.pixels,chunk.spacing,s.cell,level)
                case: level=lod_level(chunk.distance,base,maximum,level)
                }
                key.lod=Chunk_Lod{level=clamp(level,minimum,maximum)}
                // A node of a joined Volume blends the ground under its chunks of the band as they do.
                key.join=source.join.ground!={}?source.join.hash:0
                if s.kind==.Heightfield {
                    a,b:=quad_chunks(q,i)
                    key.border=piece_border(&border,a,b)
                    low,high:=quad_region(s,q,i)
                    key.join=join_cut_region_key(source.join.cuts[:],low,high)~edge_key(resident,data,&owner,s,low,high)
                }
            }
            chunk.wanted=key
            if chunk.wanted!=chunk.built || !chunk.shown || chunk.revision!=data_version(entry,i) {source_pending(source,i)}
        }
    }
}

// Whether node i of an owner holds a state that the next evaluation is to
// look at: what it wants, shows or is built.
@(private)
node_held :: proc "contextless" (owner:^Resident_Owner,place:^Lod_Place,i:int) -> bool {
    n:=&owner.nodes[i]
    if n.want || n.open || n.cut || n.visible || n.covering || n.covered || n.can || n.collide || n.resident {return true}
    if i>=len(place.chunks) {return false}
    c:=&place.chunks[i]
    return c.resident || c.visible || c.shown || c.mesh!={} || c.working || c.urgent
}

// Looks at node i in this evaluation (pass): measures it the first time.
@(private)
visit_add :: proc(owner:^Resident_Owner,place:^Lod_Place,i:int,pass:u32,count:int,stream:bool) {
    if i<0 || i>=len(owner.nodes) {return}
    node:=&owner.nodes[i]
    if node.visit==pass {return}
    node.visit=pass
    append(&owner.visit,u32(i))
    node_measure(owner,place,i,count,stream)
}

// Looks at node i and at every node above it.
@(private)
visit_add_up :: proc(owner:^Resident_Owner,place:^Lod_Place,i:int,pass:u32,count:int,stream:bool) {
    for at:=i;at>=0 && owner.nodes[at].visit!=pass;at=quad_parent(place.q,at) {visit_add(owner,place,at,pass,count,stream)}
}

// Whether the finest level of node i is too coarse for the view, and its
// children are finer: it would open for them. The chunks of a streamed
// Heightfield need their pages: only their residency opens to them. A node of
// a Volume shows every sample at the levels of its clusters: only a chunk
// under it opens it.
@(private)
node_finer :: proc "contextless" (s:^Source,q:^Quad,i:int,node:^Owner_Node,settings:Terrain_Settings,stream,by_error:bool,base:f32) -> bool {
    if i<q.first[1] {return false}
    minimum:=node_lod_min(s,q,i)
    if !(node_lod_min(s,q,quad_children(q,i)[0])<minimum && (quad_depth(q,i)>1 || !stream)) {return false}
    switch {
    case settings.lod_distance<0: return true
    case by_error:
        slack:=f32(node.open?1/LOD_HYSTERESIS:1)
        return lod_error(s.coarse.errors,q,i,int(minimum))*node.pixels>LOD_PIXELS*slack && lod_spacing_level(node.spacing/slack,s.cell)<minimum
    case minimum>0:
        reach:=lod_base(s,settings)*f32(u64(1)<<uint(minimum-1))
        _=base
        return node.distance<reach/LOD_HYSTERESIS || node.open && node.distance<reach*LOD_HYSTERESIS
    }
    return false
}

// Whether a node under node i may be finer for the view than its own finest
// level: its error at that level bounded by the largest under i
// (Lod_Errors.below), its spacing and distance by those of i, which is nearer.
@(private)
node_finer_below :: proc "contextless" (s:^Source,q:^Quad,i:int,node:^Owner_Node,settings:Terrain_Settings,stream,by_error:bool) -> bool {
    child:=quad_children(q,i)[0]
    if child<q.first[1] || stream && quad_depth(q,child)<=1 {return false}
    finest:=node_lod_min(s,q,child)
    switch {
    case settings.lod_distance<0: return true
    case by_error:
        if i>=len(s.coarse.errors) {return true}
        return s.coarse.errors[i].below*node.pixels*LOD_HYSTERESIS>LOD_PIXELS && lod_spacing_level(node.spacing*LOD_HYSTERESIS,s.cell)<finest
    case finest>0:
        return node.distance<lod_base(s,settings)*f32(u64(1)<<uint(finest-1))*LOD_HYSTERESIS
    }
    return false
}

// How far the chunks that take a collider reach, by the kind of their
// collider (collider_slot): those nearer than room take one, as many as
// Physics_Settings leaves slots for, and with
// Terrain_Settings.collision_distance those within it.
@(private)
Collider_Reach :: struct {room:[2]f32,distance:f32}

@(private)
collider_resident :: #force_inline proc "contextless" (reach:Collider_Reach,kind:int,distance:f32,was:bool) -> bool {
    near:=distance<reach.room[kind] || was && distance<=reach.room[kind]*LOD_HYSTERESIS
    return near && (reach.distance<=0 || distance<=reach.distance || was && distance<=reach.distance*LOD_HYSTERESIS)
}

// The pieces the walk for colliders is to look at, by their distance.
@(private)
Lod_Near :: struct {distance:f32,owner,node:u32}

@(private="file")
near_push :: proc(heap:^[dynamic]Lod_Near,item:Lod_Near) {
    append(heap,item)
    for at:=len(heap)-1;at>0; {
        up:=(at-1)/2
        if heap[up].distance<=heap[at].distance {break}
        heap[up],heap[at]=heap[at],heap[up]
        at=up
    }
}

@(private="file")
near_pop :: proc(heap:^[dynamic]Lod_Near) -> (top:Lod_Near) {
    top=heap[0]
    last:=pop(heap)
    if len(heap)==0 {return}
    heap[0]=last
    for at:=0;true; {
        least:=at
        for child in ([2]int{2*at+1,2*at+2}) {if child<len(heap) && heap[child].distance<heap[least].distance {least=child}}
        if least==at {break}
        heap[least],heap[at]=heap[at],heap[least]
        at=least
    }
    return
}

// Where the chunks that take a collider end, nearest first: from the roots
// of every solid terrain, the nearest piece is opened until the chunks of each
// kind fill the slots Physics_Settings leaves; a piece farther than that is
// never looked at. A streamed terrain chooses by its viewers instead.
@(private)
collider_reach :: proc(resident:^Terrain_Resident,settings:Terrain_Settings,c:^Chunk_Tables,physics:phys.Physics_Settings,pass:u32,count:int,stream:bool) -> (reach:Collider_Reach) {
    reach.room={max(f32),max(f32)}
    reach.distance=settings.collision_distance
    if stream {return}
    room,shapes:=collider_room(c,physics)
    limit:=[2]int{min(room[0],shapes),min(room[1],shapes)}
    heap:=&resident.near
    clear(heap)
    done:=[2]bool{true,true}
    for &owner,o in resident.owners {
        place:=&resident.places[o]
        if place.s==nil || !place.solid {continue}
        done[collider_slot(place.s.kind)]=false
        q:=place.q
        for i in q.first[q.depth]..<quad_total(q) {
            visit_add(&owner,place,i,pass,count,stream)
            near_push(heap,{owner.nodes[i].distance,u32(o),u32(i)})
        }
    }
    found:[2]int
    for len(heap)>0 && !(done[0] && done[1]) {
        top:=near_pop(heap)
        if settings.collision_distance>0 && top.distance>settings.collision_distance*LOD_HYSTERESIS {break}
        owner,place:=&resident.owners[top.owner],&resident.places[top.owner]
        kind:=collider_slot(place.s.kind)
        if done[kind] {continue}
        i:=int(top.node)
        if i<place.q.first[1] {
            found[kind]+=1
            if found[kind]>limit[kind] {reach.room[kind],done[kind]=top.distance,true}
            continue
        }
        for child in quad_children(place.q,i) {
            if child<0 {continue}
            visit_add(owner,place,child,pass,count,stream)
            near_push(heap,{owner.nodes[child].distance,top.owner,u32(child)})
        }
    }
    return
}

// The walk of an owner from its roots: it goes down where a chunk under a
// node may be near a viewer or take a collider, where the brush of the editor
// is, where the view is nearer than the finest level of a node reaches, and
// below what was open, until it closes.
@(private)
owner_walk :: proc(resident:^Terrain_Resident,data:^Terrain_Data,owner:^Resident_Owner,place:^Lod_Place,settings:Terrain_Settings,reach:Collider_Reach,focus:Terrain_Focus,pass:u32,count:int,stream:bool) {
    entry:=data_find(data,owner.source)
    if entry==nil {return}
    s,q:=place.s,place.q
    base:=lod_base(s,settings)
    by_error:=lod_by_error(entry,settings)
    kind:=collider_slot(s.kind)
    stack:=&resident.stack
    clear(stack)
    for i in q.first[q.depth]..<quad_total(q) {append(stack,u32(i))}
    for len(stack)>0 {
        i:=int(pop(stack))
        visit_add(owner,place,i,pass,count,stream)
        if i<q.first[1] {continue}
        node:=&owner.nodes[i]
        down:=settings.lod_distance<0 || node.open
        switch {
        case down:
        case stream: down=node.reach<=scene.RESIDENT_KEEP
        case place.solid: down=collider_resident(reach,kind,node.distance,true)
        }
        if !down && focus.radius>0 && focus.source==owner.source {
            low,high:=node_box(s,q,nil,i)
            d:=[2]f32{max(low.x-focus.center.x,0,focus.center.x-high.x),max(low.z-focus.center.z,0,focus.center.z-high.z)}
            down=d.x*d.x+d.y*d.y<=focus.radius*focus.radius
        }
        if !down {down=node_finer(s,q,i,node,settings,stream,by_error,base) || node_finer_below(s,q,i,node,settings,stream,by_error)}
        if down {for child in quad_children(q,i) {if child>=0 {append(stack,u32(child))}}}
    }
}

// Which pieces the terrains show with a collider: the chunks, and past them
// the nodes with the triangles they show, so that far ground still stops
// rays and bodies; the nearest that Physics_Settings has room for beside the
// colliders of everything else, every chunk before any node, and of those,
// with Terrain_Settings.collision_distance, the ones within it.
@(private)
resident_colliders :: proc(resident:^Terrain_Resident,data:^Terrain_Data,terrains:^core.Table(Terrain,$A),c:^Chunk_Tables,settings:Terrain_Settings,physics:phys.Physics_Settings,looked:bool) {
    defer {for &owner in resident.owners {
        // A piece it shows whose collider comes or goes shows again.
        for i in owner.visit {if node:=&owner.nodes[i];node.visible && node.collide!=node.can {append(&owner.changed,i)}}}
    }
    clear(&resident.splits)
    for &owner,o in resident.owners {
        marker,known:=core.get(terrains,owner.entity)
        entry:=data_find(data,owner.source)
        source:=resident_source_find(resident,owner.source,owner.entity)
        chunks:=owner.quad.first[1]
        for at in owner.visit {
            i:=int(at)
            node:=&owner.nodes[i]
            // What it had, until owner_cut takes can again.
            node.can=node.collide
            node.collide=false
            if !known || entry==nil || !marker.solid || owner.far || !node.cut && !root_stands_in(&owner,&entry.source,i,looked) {continue}
            // A piece built empty takes no slot.
            if source!=nil && i<len(source.chunks) && source.chunks[i].shown && source.chunks[i].mesh=={} {continue}
            if settings.collision_distance>0 && node.distance>settings.collision_distance {continue}
            node.collide=true
            kind:=collider_room_slot(piece_collider_kind(&entry.source,chunks,i))
            append(&resident.splits,Split{f32(i<chunks?0:1),node.distance,i32(kind),u32(o),u32(i)})
        }
    }
    // What the colliders of other entities take stays theirs.
    room,shapes:=collider_room(c,physics)
    wants:[2]int
    for split in resident.splits {wants[split.depth]+=1}
    if wants[0]<=room[0] && wants[1]<=room[1] && wants[0]+wants[1]<=shapes {return}
    slice.sort_by(resident.splits[:],split_before)
    for split in resident.splits {
        kind:=int(split.depth)
        if room[kind]>0 && shapes>0 {room[kind]-=1;shapes-=1;continue}
        resident.owners[split.owner].nodes[split.node].collide=false
    }
}

// What each terrain shows: the pieces it wants where they are built, and
// elsewhere what it showed, until all that replaces it is built. Marks as
// urgent, built in the call that wants them, only what the simulation and a
// first frame need: the pieces with a collider within GROUND_REACH of a
// simulation source (the bodies the seats drive, the marks) or of a body that
// moves or a character, and where a Heightfield shows
// nothing, its roots, which the coarse grid of its file builds; the rest
// arrives from jobs over the frames. A Volume, without a coarse grid, builds
// the pieces it wants where it shows nothing near a viewer. It lets go of
// what it neither wants nor shows. It looks at the nodes the last evaluation
// of levels looked at.
@(private)
resident_cut :: proc(resident:^Terrain_Resident,data:^Terrain_Data,worlds:^core.Table(core.World_Transform,.Read)) {
    if !resident.cut {return}
    resident.cut=false
    for &owner in resident.owners {
        entry:=data_find(data,owner.source)
        source:=entry!=nil?resident_source_find(resident,owner.source,owner.entity):nil
        if source==nil || len(source.chunks)!=len(entry.dirty) || len(owner.nodes)!=len(source.chunks) {continue}
        for i in owner.visit {source.chunks[i].urgent=false}
        stream:=resident.lod_distances[2]>0
        owner_cut(&owner,source,stream)
        chunks:=owner.quad.first[1]
        roots:=owner.quad.first[owner.quad.depth]
        field:=entry.source.kind==.Heightfield
        bodies:=Bodies_Near{}
        if len(resident.bodies)>0 {bodies=bodies_near(&entry.source,worlds,owner.entity)}
        for at in owner.visit {
            i:=int(at)
            node:=&owner.nodes[i]
            chunk:=&source.chunks[i]
            chunk.visible=node.visible
            needed:=node.cut && node.collide && (node.ground<=GROUND_REACH || body_over(resident,&entry.source,&owner.quad,&bodies,i))
            switch {
            case chunk.shown:
            case needed: chunk.urgent=true
            case field: chunk.urgent=i>=roots && chunk.resident && !node.covered
            case node.cut && !node.covered && (!stream || node.reach<=URGENT_REACH): chunk.urgent=true
            }
            if !chunk.visible && !chunk.resident && (chunk.shown || chunk.mesh!={}) {source_pending(source,i)}
            if !needed || node.visible {continue}
            // A piece the simulation needs shows now: what keeps the node shown
            // over it from opening is built in this call too, a level a round.
            for up:=quad_parent(&owner.quad,i);up>=0 && owner.nodes[up].covering;up=quad_parent(&owner.quad,up) {
                for child in quad_children(&owner.quad,up) {if child>=0 && child!=i {pieces_standing(resident,&owner,source,child)}}
                if owner.nodes[up].visible {break}
            }
        }
        // What stands for a section that is not loaded has no viewer on it: it waits for its jobs.
        if owner.far {for i in owner.visit {source.chunks[i].urgent=false}}
    }
}

// Whether node i is a root of a Heightfield that stands in, from the coarse
// grid of its file, for what it covers while that is built: where a view
// looks and nothing covers its region. It collides meanwhile, so a body never
// lacks ground.
@(private)
root_stands_in :: proc "contextless" (owner:^Resident_Owner,s:^Source,i:int,looked:bool) -> bool {
    q:=&owner.quad
    return looked && s.kind==.Heightfield && i>=q.first[q.depth] && i<quad_total(q) && !owner.nodes[i].cut && !owner.nodes[i].covered
}

// Marks urgent what has to be built for the region of node i to show: the
// pieces it wants there that do not stand yet.
@(private)
pieces_standing :: proc(resident:^Terrain_Resident,owner:^Resident_Owner,source:^Resident_Source,i:int) {
    q:=&owner.quad
    chunks:=q.first[1]
    stack:=&resident.stack
    base_len:=len(stack)
    if append(stack,u32(i))!=1 {return}
    for len(stack)>base_len {
        at:=int(pop(stack))
        node:=&owner.nodes[at]
        if node.can || at>=chunks && source.chunks[at].shown {continue}
        if node.cut || at<chunks {
            source.chunks[at].urgent=true
            continue
        }
        for child in quad_children(q,at) {if child>=0 && append(stack,u32(child))!=1 {return}}
    }
}

// What places the bodies in the space of a source: the inverse of the place
// of its terrain, and a chunk width there.
@(private)
Bodies_Near :: struct {inverse:mm.Mat4,width:f32,ok:bool}

@(private)
bodies_near :: proc(s:^Source,worlds:^core.Table(core.World_Transform,.Read),owner:core.Entity) -> (near:Bodies_Near) {
    placed:=mm.MAT4_IDENTITY
    if world,known:=core.get(worlds,owner);known {placed=mm.transform_matrix(world.transform)}
    scale:=max(linalg.length(placed[0].xyz),linalg.length(placed[1].xyz),linalg.length(placed[2].xyz))
    if !(scale>0) {return}
    return {linalg.inverse(placed),s.cell*f32(s.chunk_cells),true}
}

// Whether a body that moves or a character stands within GROUND_REACH of
// piece i: what it falls on or walks to is to collide in this tick.
@(private)
body_over :: proc(resident:^Terrain_Resident,s:^Source,q:^Quad,near:^Bodies_Near,i:int) -> bool {
    if !near.ok {return false}
    low,high:=node_box(s,q,s.coarse.ranges,i)
    for body in resident.bodies {
        local:=(near.inverse*[4]f32{body.x,body.y,body.z,1}).xyz
        if scene.box_distance(low,high,local)<=GROUND_REACH*near.width {return true}
    }
    return false
}

// The views the levels are chosen for: that of the frame and, on a split
// screen, that of each local slot, with the pose its camera draws from and
// the size of its part of the screen. A piece shows what the nearest of them
// needs.
LOD_VIEWS :: 1+len(camera.Camera_Views{}.slots)
Lod_Views :: struct {
    items:[LOD_VIEWS]core.View,
    count:int,
}

lod_views_of :: proc(view:core.View,slots:core.Ref(camera.Camera_Views),app:^host.App) -> (views:Lod_Views) {
    views.items[0],views.count=view,1
    if slots.ptr==nil || app==nil {return}
    // The slots in play: those up to the last with a camera.
    count:=0
    for seen,slot in slots.slots {if seen.camera!=core.NONE {count=slot+1}}
    if count<2 {return}
    for seen,slot in slots.slots[:count] {
        if seen.camera==core.NONE {continue}
        rect:=host.app_player_rect(app,slot,count)
        local:=core.VIEW_DEFAULT
        local.camera,local.position,local.rotation=seen.camera,seen.pose.position,seen.pose.rotation
        local.fov,local.height,local.size=seen.pose.fov,seen.pose.height,{f32(rect.z),f32(rect.w)}
        local.projection=seen.pose.projection==.Orthographic && seen.pose.height>0?.Orthographic:.Perspective
        views.items[views.count]=local
        views.count+=1
    }
    return
}

// What an owner is seen from, in the space of its source; s nil for one
// whose pieces are not made yet.
@(private)
Lod_Place :: struct {
    s:^Source,
    q:^Quad,
    chunks:[]Resident_Chunk,
    solid:bool, // its chunks take colliders
    views:[LOD_VIEWS][3]f32,
    pixels:[LOD_VIEWS]f32,
    scale:f32,
    near:scene.Sources_Near,
    ground:scene.Sources_Near, // the simulation sources, a chunk width their reach
}

// Where each owner is seen from, before its nodes are measured.
@(private)
lod_places :: proc(resident:^Terrain_Resident,data:^Terrain_Data,worlds:^core.Table(core.World_Transform,.Read),terrains:^core.Table(Terrain,$A),views:Lod_Views,sources:core.Ref(scene.Streaming_Sources),simulated:[]scene.Source,resident_distance:f32,stream:bool) -> bool {
    views:=views
    places:=&resident.places
    // Room for every owner is made with it (resident_owner).
    if resize(places,len(resident.owners))!=nil {return false}
    for &owner,o in resident.owners {
        places[o]={}
        entry:=data_find(data,owner.source)
        source:=entry!=nil?resident_source_find(resident,owner.source,owner.entity):nil
        if source==nil || len(source.chunks)!=len(entry.dirty) || len(owner.nodes)!=len(source.chunks) {continue}
        placed:=mm.MAT4_IDENTITY
        if world,known:=core.get(worlds,owner.entity);known {placed=mm.transform_matrix(world.transform)}
        inverse:=linalg.inverse(placed)
        marker,known:=core.get(terrains,owner.entity)
        place:=Lod_Place{s=&entry.source,q=&source.quad,chunks=source.chunks,solid=known && marker.solid && !owner.far}
        place.scale=max(linalg.length(placed[0].xyz),linalg.length(placed[1].xyz),linalg.length(placed[2].xyz))
        for view,v in views.items[:views.count] {
            place.views[v]=(inverse*[4]f32{view.position.x,view.position.y,view.position.z,1}).xyz
            place.pixels[v]=view_pixels(view)
        }
        if stream {place.near=scene.sources_near(sources.ptr,placed,resident_distance)}
        place.ground=scene.sources_near_of(simulated,placed,entry.source.cell*f32(entry.source.chunk_cells)*place.scale)
        places[o]=place
    }
    return true
}

// What node i of an owner is from its views and viewers: the distance of the
// nearest view, the pixels and spacing of the view that sees it finest.
@(private)
node_measure :: proc "contextless" (owner:^Resident_Owner,place:^Lod_Place,i,count:int,stream:bool) {
    node:=&owner.nodes[i]
    s,q:=place.s,place.q
    low,high:=node_box(s,q,s.coarse.ranges,i)
    nearest,pixels,spacing:=max(f32),f32(0),f32(0)
    for local,v in place.views[:count] {
        at:=scene.box_distance(low,high,local)
        nearest=min(nearest,at)
        // Errors are in the space of the source, as at.
        seen:=place.pixels[v]/max(at,1e-3)
        pixels=max(pixels,seen)
        // Seen at a grazing angle, its spacing shrinks along the view.
        spacing=max(spacing,seen*math.sqrt(clamp((local.y-high.y)/max(at,1e-3),LOD_GRAZING,1)))
    }
    node.distance=nearest*place.scale
    node.reach=stream?scene.box_near(&place.near,low,high):0
    node.ground=scene.box_near(&place.ground,low,high)
    node.pixels,node.spacing=pixels,spacing
    chunk:=&place.chunks[i]
    chunk.distance,chunk.reach,chunk.pixels,chunk.spacing=node.distance,node.reach,node.pixels,node.spacing
}

@(private)
owner_cut :: proc(owner:^Resident_Owner,source:^Resident_Source,stream:bool) {
    q:=&owner.quad
    nodes:=owner.nodes
    chunks:=q.first[1]
    // The nodes the last evaluation looked at, by index: chunks first, then
    // each depth. What it did not look at holds no state.
    visit:=owner.visit[:]
    // What can cover a region now: what is wanted there, or a node that is
    // built standing in for it until then.
    stands :: proc(source:^Resident_Source,nodes:[]Owner_Node,chunks,i:int) -> bool {return nodes[i].can || i>=chunks && source.chunks[i].shown}
    // Whether what a node covers can show: a piece that is built, or children that stand.
    for at in visit {
        i:=int(at)
        node:=&nodes[i]
        node.can=false
        if node.cut {node.can=source.chunks[i].shown;continue}
        if i<chunks || !node.open {continue}
        node.can=true
        for child in quad_children(q,i) {if child>=0 && !stands(source,nodes,chunks,child) {node.can=false;break}}
    }
    // From the roots down: a node shows its children once all of them stand,
    // a node in place of what is not built yet; until then what showed there
    // stays.
    #reverse for at in visit {
        i:=int(at)
        node:=&nodes[i]
        parent:=quad_parent(q,i)
        was:=node.visible
        // A root stands in for what it covers while that comes: its parent is the whole region.
        opened:=parent<0 || !nodes[parent].covering && nodes[parent].can && !nodes[parent].cut
        switch {
        case parent>=0 && nodes[parent].covering: node.visible,node.covering=false,true
        case node.can: node.visible,node.covering=node.cut,node.cut
        case opened && i>=chunks && source.chunks[i].shown: node.visible,node.covering=true,true
        case: node.covering=node.visible
        }
        if node.visible!=was {append(&owner.changed,u32(i))}
    }
    for at in visit {
        i:=int(at)
        node:=&nodes[i]
        node.covered=node.covering
        if node.covered || i<chunks {continue}
        node.covered=true
        for child in quad_children(q,i) {if child>=0 && !nodes[child].covered {node.covered=false;break}}
    }
}

// The local box of chunk i: its region of the source, with the heights it
// reaches for a Heightfield.
chunk_box :: proc "contextless" (s:^Source,origin:[3]f32,i:int,heights:[2]f32) -> (low,high:[3]f32) {
    from,to,_:=chunk_region(s,chunk_coord(s,i))
    low=origin+[3]f32{f32(from.x),f32(from.y),f32(from.z)}*s.cell
    high=origin+[3]f32{f32(to.x),f32(to.y),f32(to.z)}*s.cell
    if s.kind==.Heightfield {low.y,high.y=heights.x,heights.y}
    return
}

// A level whose error covers about this many pixels of the view is fine enough.
LOD_PIXELS :: f32(1)
// Nor finer than vertices this many pixels apart: detail between the samples
// a pixel covers does not show, whatever its error.
LOD_SPACING_PIXELS :: f32(2)
// The spacing a view at a grazing angle sees shrinks with the square root of
// the sine of that angle, the mean of its two axes; never below this sine.
LOD_GRAZING :: f32(0.05)
// Without a view of its own size: that of 900 pixels high at 60 degrees.
@(private) LOD_VIEW_PIXELS :: f32(779.4229)

// The pixels of the view a metre one radian away covers: its height over the
// field of view.
@(private)
view_pixels :: proc "contextless" (view:core.View) -> f32 {
    if view.size.y>0 && view.fov>0 && view.projection==.Perspective {return view.size.y/(2*math.tan(view.fov*0.5))}
    return LOD_VIEW_PIXELS
}

// Whether the levels of a source are chosen by the error they show
// (Terrain_Settings.lod_distance 0, a Heightfield, which measures them).
@(private)
lod_by_error :: #force_inline proc "contextless" (entry:^Data_Source,settings:Terrain_Settings) -> bool {
    return settings.lod_distance==0 && len(entry.source.coarse.errors)==quad_total(&entry.quad)
}

// The coarsest level of piece i between minimum and maximum whose error
// covers at most LOD_PIXELS where a metre of it covers pixels; the current
// one stays while it is within LOD_HYSTERESIS of that.
@(private)
lod_level_error :: proc "contextless" (errors:[]Lod_Errors,q:^Quad,i:int,minimum,maximum:u8,pixels,spacing,cell:f32,current:u8) -> u8 {
    // The coarsest level whose error fits, and that no finer than the spacing, at a slack.
    choose :: proc "contextless" (errors:[]Lod_Errors,q:^Quad,i:int,minimum,maximum:u8,pixels,spacing,cell,slack:f32) -> u8 {
        level:=minimum
        for level<maximum && lod_error(errors,q,i,int(level+1))*pixels<=LOD_PIXELS*slack {level+=1}
        return max(level,min(lod_spacing_level(spacing/slack,cell),maximum))
    }
    level:=choose(errors,q,i,minimum,maximum,pixels,spacing,cell,1)
    finest,coarsest:=choose(errors,q,i,minimum,maximum,pixels,spacing,cell,1/LOD_HYSTERESIS),choose(errors,q,i,minimum,maximum,pixels,spacing,cell,LOD_HYSTERESIS)
    if current>=finest && current<=coarsest {level=current}
    return level
}

// Makes the chunks of a Heightfield finer until two that touch, across a
// side or a corner, are one level apart at most: a border sews a chunk only
// to a neighbor of the next level, whose interior lies near its samples. A
// Volume needs none: each face of its chunks is built at its neighbor's level.
// Each level ends as the least of every level plus how many chunks away it
// is, counting a corner as one: two sweeps, each taking the neighbors it
// already passed, give it.
@(private)
lod_levels_balance :: proc "contextless" (s:^Source,levels:[]u8) {
    n:=chunk_counts(s)
    if n.y!=1 || n.x*n.z!=len(levels) {return}
    w,h:=n.x,n.z
    take :: #force_inline proc "contextless" (levels:[]u8,w,h,x,z:int,level:^u8) {
        if x>=0 && z>=0 && x<w && z<h {level^=min(level^,levels[x+w*z]+1)}
    }
    for z in 0..<h {for x in 0..<w {
        level:=&levels[x+w*z]
        take(levels,w,h,x-1,z,level)
        for dx in -1..=1 {take(levels,w,h,x+dx,z-1,level)}
    }}
    for z:=h-1;z>=0;z-=1 {for x:=w-1;x>=0;x-=1 {
        level:=&levels[x+w*z]
        take(levels,w,h,x+1,z,level)
        for dx in -1..=1 {take(levels,w,h,x+dx,z+1,level)}
    }}
}

// The chunks each terrain needs as chunks, whatever the view asks of them:
// those near its viewers when it streams; otherwise, of a solid terrain,
// those that take a collider (collider_reach); and those under the brush of
// the editor. The walk looked at every chunk that may be one.
@(private)
resident_needed :: proc(resident:^Terrain_Resident,settings:Terrain_Settings,reach:Collider_Reach,focus:=Terrain_Focus{}) {
    stream:=settings.resident_distance>0
    for &owner,o in resident.owners {
        place:=&resident.places[o]
        if place.s==nil {continue}
        s:=place.s
        kind:=collider_slot(s.kind)
        chunks:=place.q.first[1]
        origin:=source_origin(s)
        for at in owner.visit {
            i:=int(at)
            if i>=chunks {continue}
            node:=&owner.nodes[i]
            switch {
            case stream: node.resident=scene.resident(node.reach,node.resident)
            case: node.resident=place.solid && collider_resident(reach,kind,node.distance,node.resident)
            }
            // The chunks under the brush of the editor.
            if focus.radius>0 && owner.source==focus.source {
                low,high:=chunk_box(s,origin,i,{})
                d:=[2]f32{max(low.x-focus.center.x,0,focus.center.x-high.x),max(low.z-focus.center.z,0,focus.center.z-high.z)}
                if d.x*d.x+d.y*d.y<=focus.radius*focus.radius {node.resident=true}
            }
        }
    }
}

// The level of each chunk of a Heightfield an evaluation looked at: the
// coarsest its error lets the view see, or by its distance, made finer where
// it meets a finer neighbor (levels_balance_sparse). A chunk joined to a
// Volume stays at level 0, where the Volume meets its samples; one with holes
// takes any level, its material cutting what its triangles span
// (Surface_Maps.holed), but under a program of the source, which cuts none.
@(private)
heightfield_levels :: proc(entry:^Data_Source,source:^Resident_Source,owner:^Resident_Owner,settings:Terrain_Settings,by_error:bool,base:f32,pass:u32,work:^[dynamic]u32) {
    s:=&entry.source
    q:=&source.quad
    for at in owner.visit {
        i:=int(at)
        if i>=q.first[1] {break}
        chunk:=&source.chunks[i]
        level:=&source.levels[i]
        next:=u8(0)
        joined:=source.join.ground!={} && join_side_chunk(s,i) || join_cut_key(s,source.join.cuts[:],i)!=0
        // A program of the source cuts no holes: its chunks with holes keep them in their triangles.
        if settings.lod_distance>=0 && !joined && !(s.layers_material!={} && chunk_holed(s,i)) {
            maximum:=chunk_lod_max(s,chunk_coord(s,i))
            next=lod_level_error(entry.source.coarse.errors,q,i,0,maximum,chunk.pixels,chunk.spacing,s.cell,level^)
            // The distance makes a chunk coarser only as far as its error lets it be.
            if !by_error {
                distant:=lod_level(chunk.distance,base,maximum,level^)
                next=len(entry.source.coarse.errors)==quad_total(q)?min(distant,next):distant
            }
        }
        level^=next
    }
    levels_balance_sparse(s,owner,source.levels,pass,work)
}

// As lod_levels_balance, over the chunks the last evaluation looked at: each
// ends as the least of every level plus how many of those chunks away it is,
// a corner counting as one. A chunk lowered lowers its neighbors in turn.
@(private)
levels_balance_sparse :: proc(s:^Source,owner:^Resident_Owner,levels:[]u8,pass:u32,work:^[dynamic]u32) {
    n:=chunk_counts(s)
    if n.y!=1 || n.x*n.z!=len(levels) {return}
    clear(work)
    for i in owner.visit {
        if int(i)>=len(levels) {break}
        append(work,i)
    }
    for len(work)>0 {
        i:=int(pop(work))
        x,z:=i%n.x,i/n.x
        for dz in -1..=1 {for dx in -1..=1 {
            if dx==0 && dz==0 || x+dx<0 || z+dz<0 || x+dx>=n.x || z+dz>=n.z {continue}
            j:=x+dx+n.x*(z+dz)
            if owner.nodes[j].visit!=pass || levels[j]<=levels[i]+1 {continue}
            levels[j]=levels[i]+1
            append(work,u32(j))
        }}
    }
}

// The slots of Physics_Settings for heightfields and meshes, and for shapes,
// that the colliders of other entities leave.
@(private)
collider_room :: proc(c:^Chunk_Tables,physics:phys.Physics_Settings) -> (room:[2]int,shapes:int) {
    made:=phys.settings_capacities(physics)
    room={int(made.heightfields),int(made.meshes)}
    shapes=int(made.shapes)
    for collider,row in c.colliders.values[:core.count(c.colliders)] {
        if core.has(c.chunks,c.colliders.entities[row]) {continue}
        shapes-=1
        if slot:=collider_room_slot(collider.kind);slot>=0 {room[slot]-=1}
    }
    return
}

// The finest level whose samples, cell apart at level 0, stand LOD_SPACING_PIXELS
// apart where a metre covers pixels.
@(private)
lod_spacing_level :: proc "contextless" (pixels,cell:f32) -> u8 {
    apart:=cell*pixels
    if !(apart>0) {return 0}
    return u8(clamp(math.ceil(math.log2(LOD_SPACING_PIXELS/apart)),0,f32(LOD_ERRORS-1)))
}
