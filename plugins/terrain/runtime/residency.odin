package terrain

import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:core"
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
// pieces whose mesh shows something else. Each terrain opens, from its roots,
// the nodes under which a chunk is near a viewer, or nearer than their finest
// level reaches; within Terrain_Settings.chunks, the nearest open first, so
// past it the farthest show coarser nodes and nothing goes. A Volume, which
// has no nodes, keeps its nearest chunks. Runs when the view, the transforms,
// the sources, the colliders or the chunks change; while pieces wait to be
// built, again once a frame (once_more: the first call of a frame).
@(private)
resident_lod :: proc(resident:^Terrain_Resident,data:^Terrain_Data,worlds:core.Read(core.World_Transform),view:core.View,sources:core.Ref(scene.Streaming_Sources),settings:Terrain_Settings,terrains:core.Read(Terrain),c:^Chunk_Tables,physics:phys.Physics_Settings,problems:^core.Problems,once_more:=true,focus:=Terrain_Focus{}) {
    stamp:=[5]u64{core.version(worlds),sources.ptr!=nil?sources.ptr.revision:0,u64(len(resident.owners)),resident.marks,core.version(c.colliders)}
    pending:=false
    if once_more {for &source in resident.sources {if len(source.pending)>0 {pending=true;break}}}
    offset:=view.position-resident.lod_view
    distances:=[3]f32{settings.lod_distance,settings.collision_distance,settings.resident_distance}
    // Where the brush is chooses pieces; what its stroke changed does not.
    brush:=Terrain_Focus{source=focus.source,center=focus.center,radius=focus.radius}
    if !pending && stamp==resident.lod_stamp && distances==resident.lod_distances && brush==resident.focus && linalg.dot(offset,offset)<LOD_MOVE*LOD_MOVE {return}
    resident.lod_view,resident.lod_stamp,resident.lod_distances,resident.focus=view.position,stamp,distances,brush
    resident.cut=true
    stream:=settings.resident_distance>0
    clear(&resident.splits)
    roots:=0
    // The distances of every piece from its terrain, and the pixels a metre
    // of error covers there: each terrain apart, in jobs.
    distances_work:=Lod_Distances{resident,data,worlds,view,sources,settings.resident_distance,stream,view_pixels(view)}
    if data.jobs!=nil && jobs.worker_count(data.jobs)>1 && len(resident.owners)>1 {
        jobs.parallel_for(data.jobs,jobs.OWNER,len(resident.owners),1,lod_distances,&distances_work)
    } else {lod_distances(&distances_work,0,len(resident.owners),jobs.OWNER)}
    resident_needed(resident,data,terrains,c,settings,physics,focus)
    joins_resident(resident,data)
    // What each terrain would open.
    for &owner,o in resident.owners {
        entry:=data_find(data,owner.source)
        source:=entry!=nil?resident_source_find(resident,owner.source,owner.entity):nil
        if source==nil || len(source.chunks)!=len(entry.dirty) || len(owner.nodes)!=len(source.chunks) {continue}
        s:=&entry.source
        q:=&source.quad
        chunks:=q.first[1]
        base:=lod_base(s,settings)
        by_error:=lod_by_error(entry,settings)
        if q.depth==0 {
            for node,i in owner.nodes {if node.resident {append(&resident.splits,Split{node.reach,node.distance,0,u32(o),u32(i)})}}
            continue
        }
        roots+=q.counts[q.depth].x*q.counts[q.depth].y
        for d in 1..=q.depth {for i in q.first[d]..<q.first[d+1] {
            node:=&owner.nodes[i]
            node.want=false
            for child in quad_children(q,i) {if child>=0 && (child<chunks?owner.nodes[child].resident:owner.nodes[child].want) {node.want=true;break}}
            // Its finest level is too coarse for the view, and its children are
            // finer. The chunks of a streamed Heightfield need their pages: only
            // their residency opens to them.
            minimum:=node_lod_min(s,q,i)
            finer:=node_lod_min(s,q,quad_children(q,i)[0])<minimum && (s.kind!=.Heightfield || d>1 || !stream)
            if !node.want && finer {
                switch {
                case settings.lod_distance<0: node.want=true
                case by_error:
                    slack:=f32(node.open?1/LOD_HYSTERESIS:1)
                    node.want=lod_error(entry.errors,q,i,int(minimum))*node.pixels>LOD_PIXELS*slack && lod_spacing_level(node.spacing/slack,s.cell)<minimum
                case minimum>0:
                    reach:=base*f32(u64(1)<<uint(minimum-1))
                    node.want=node.distance<reach/LOD_HYSTERESIS || node.open && node.distance<reach*LOD_HYSTERESIS
                }
            }
            if node.want {append(&resident.splits,Split{node.reach,node.distance,-i32(d),u32(o),u32(i)})}
        }}
    }
    // Within Terrain_Settings.chunks of pieces, the nearest open first.
    budget:=int(data.settings.chunks)
    if roots>budget {
        core.report(problems,core.NONE,"terrain.chunks_full","the roots of the terrains alone are %d pieces and Terrain_Settings.chunks allows %d: they show, and nothing finer does; raise it, or show fewer terrains",roots,budget)
    }
    budget-=roots
    slice.sort_by(resident.splits[:],split_before)
    for &owner in resident.owners {for &node in owner.nodes {node.open=false;if owner.quad.depth==0 {node.cut=false}}}
    for split in resident.splits {
        owner:=&resident.owners[split.owner]
        q:=&owner.quad
        node:=&owner.nodes[split.node]
        if q.depth==0 {
            if budget>=1 {budget-=1;node.cut=true} else {node.resident=false}
            continue
        }
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
        if q.depth==0 {
            dropped:=0
            for node,i in owner.nodes {if !node.cut && node.distance<max(f32) && (!stream || scene.resident(node.reach,false)) {dropped+=1;_=i}}
            if dropped>0 {core.report(problems,owner.entity,"terrain.chunks_full","%d chunks of this terrain do not show: it has no nodes to show in their place, and with the other terrains they pass the %d pieces of Terrain_Settings.chunks; raise it, or lower Terrain_Settings.resident_distance",dropped,data.settings.chunks)}
            continue
        }
        for d in 0..=q.depth {for i in q.first[d]..<q.first[d+1] {
            parent:=quad_parent(q,i)
            node:=&owner.nodes[i]
            node.cut=!node.open && (parent<0 || owner.nodes[parent].open)
        }}
    }
    resident_colliders(resident,data,terrains,c,settings,physics)
    // How each terrain builds what it wants.
    for &owner in resident.owners {
        entry:=data_find(data,owner.source)
        source:=entry!=nil?resident_source_find(resident,owner.source,owner.entity):nil
        if source==nil || len(source.chunks)!=len(entry.dirty) || len(owner.nodes)!=len(source.chunks) {continue}
        s:=&entry.source
        q:=&source.quad
        chunks:=q.first[1]
        base:=lod_base(s,settings)
        for &deep in source.deep {deep=false}
        for node,i in owner.nodes {
            chunk:=&source.chunks[i]
            // A streamed terrain keeps its open nodes and its roots too: they stand in
            // for what they cover while it comes (owner_cut), and show when all else goes.
            // A Volume has no nodes, and its chunks are no roots.
            chunk.resident=node.cut || stream && (node.open || q.depth>0 && i>=q.first[q.depth])
            if i>=chunks {continue}
            chunk.wanted.collision=node.cut && node.collide
            if node.cut && (!stream || node.reach<=DEEP_REACH) {source.deep[i]=true}
        }
        by_error:=lod_by_error(entry,settings)
        for &level,i in source.levels {
            chunk:=&source.chunks[i]
            next:=u8(0)
            joined:=source.join.ground!={} && join_side_chunk(s,i) || join_cut_key(s,source.join.cuts[:],i)!=0
            if settings.lod_distance>=0 && !chunk_holed(s,i) && !joined {
                maximum:=chunk_lod_max(s,chunk_coord(s,i))
                next=lod_level_error(entry.errors,q,i,0,maximum,chunk.pixels,chunk.spacing,s.cell,level)
                // The distance makes a chunk coarser only as far as its error lets it be.
                if !by_error {
                    distant:=lod_level(chunk.distance,base,maximum,level)
                    next=len(entry.errors)==quad_total(q)?min(distant,next):distant
                }
            }
            level=next
        }
        if s.kind==.Heightfield {lod_levels_balance(s,source.levels)}
        border:=Border_Levels{counts=q.counts[0],levels=source.levels,deep=source.deep}
        for &chunk,i in source.chunks {
            if !chunk.resident {
                if (chunk.shown || chunk.mesh!={}) && !chunk.visible {source_pending(source,i)}
                continue
            }
            key:=chunk.wanted
            key.border=0
            if i<chunks {
                coord:=chunk_coord(s,i)
                if s.kind==.Heightfield {key.lod=chunk_lod_border(&border,source.levels[i],{int(coord.x),int(coord.z)})} else {key.lod=chunk_lod_sides(s,source.levels,coord)}
                key.join=join_cut_key(s,source.join.cuts[:],i)
                if source.join.ground!={} && join_band_chunk(s,i,key.lod.level) {key.join=source.join.hash}
            } else {
                depth:=u8(quad_depth(q,i))
                minimum,maximum:=node_lod_min(s,q,i),node_lod_max(s,q,i)
                level:=chunk.wanted.lod.level
                switch {
                case settings.lod_distance<0: level=minimum
                case by_error: level=lod_level_error(entry.errors,q,i,minimum,maximum,chunk.pixels,chunk.spacing,s.cell,level)
                case: level=lod_level(chunk.distance,base,maximum,level)
                }
                key.lod=Chunk_Lod{level=clamp(level,minimum,maximum)}
                key.collision=false
                if s.kind==.Heightfield {
                    a,b:=quad_chunks(q,i)
                    key.border=piece_border(&border,a,b)
                }
            }
            chunk.wanted=key
            if chunk.wanted!=chunk.built || !chunk.shown || chunk.revision!=data_version(entry,i) {source_pending(source,i)}
        }
    }
}

// Which chunks the terrains show with a collider: the nearest that
// Physics_Settings has room for beside the colliders of everything else, and
// of those, with Terrain_Settings.collision_distance, the ones within it.
@(private)
resident_colliders :: proc(resident:^Terrain_Resident,data:^Terrain_Data,terrains:core.Read(Terrain),c:^Chunk_Tables,settings:Terrain_Settings,physics:phys.Physics_Settings) {
    defer {for &owner in resident.owners {
        // A piece it shows whose collider comes or goes shows again.
        for &node,i in owner.nodes[:min(owner.quad.first[1],len(owner.nodes))] {if node.visible && node.collide!=node.can {append(&owner.changed,u32(i))}}}
    }
    clear(&resident.splits)
    for &owner,o in resident.owners {
        marker,known:=core.get(terrains,owner.entity)
        entry:=data_find(data,owner.source)
        kind:=entry!=nil && entry.source.kind==.Heightfield?0:1
        source:=resident_source_find(resident,owner.source,owner.entity)
        chunks:=owner.quad.first[1]
        for &node,i in owner.nodes[:min(chunks,len(owner.nodes))] {
            // What it had, until owner_cut takes can again.
            node.can=node.collide
            node.collide=false
            if !known || !marker.solid || owner.far || !node.cut {continue}
            // A chunk built empty takes no slot.
            if source!=nil && i<len(source.chunks) && source.chunks[i].shown && source.chunks[i].mesh=={} {continue}
            if settings.collision_distance>0 && node.distance>settings.collision_distance {continue}
            node.collide=true
            append(&resident.splits,Split{node.distance,node.distance,i32(kind),u32(o),u32(i)})
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
// urgent the pieces a terrain wants where it shows nothing near a viewer
// (farther they wait for their jobs), and lets go of what it neither wants
// nor shows.
@(private)
resident_cut :: proc(resident:^Terrain_Resident,data:^Terrain_Data) {
    if !resident.cut {return}
    resident.cut=false
    for &owner in resident.owners {
        entry:=data_find(data,owner.source)
        source:=entry!=nil?resident_source_find(resident,owner.source,owner.entity):nil
        if source==nil || len(source.chunks)!=len(entry.dirty) || len(owner.nodes)!=len(source.chunks) {continue}
        for &chunk in source.chunks {chunk.urgent=false}
        stream:=resident.lod_distances[2]>0
        owner_cut(&owner,source,stream)
        chunks:=owner.quad.first[1]
        for node,i in owner.nodes {
            chunk:=&source.chunks[i]
            chunk.visible=node.visible
            if i>=chunks && node.cut && !node.covered && !chunk.shown && (!stream || node.reach<=URGENT_REACH) {chunk.urgent=true}
            if !chunk.visible && !chunk.resident && (chunk.shown || chunk.mesh!={}) {source_pending(source,i)}
        }
        // What stands for a section that is not loaded has no viewer on it: it waits for its jobs.
        if owner.far {for &chunk in source.chunks {chunk.urgent=false}}
    }
}

@(private)
Lod_Distances :: struct {
    resident:^Terrain_Resident,
    data:^Terrain_Data,
    worlds:core.Read(core.World_Transform),
    view:core.View,
    sources:core.Ref(scene.Streaming_Sources),
    resident_distance:f32,
    stream:bool,
    pixels:f32,
}

// Owners first..<last of resident_lod: what each of their pieces is from the view and the viewers.
@(private)
lod_distances :: proc(work:^Lod_Distances,first,last:int,worker:int) {
    resident,data,view:=work.resident,work.data,work.view
    for &owner in resident.owners[first:last] {
        entry:=data_find(data,owner.source)
        source:=entry!=nil?resident_source_find(resident,owner.source,owner.entity):nil
        if source==nil || len(source.chunks)!=len(entry.dirty) || len(owner.nodes)!=len(source.chunks) {continue}
        s:=&entry.source
        q:=&source.quad
        placed:=mm.MAT4_IDENTITY
        if world,known:=core.get(work.worlds,owner.entity);known {placed=mm.transform_matrix(world.transform)}
        inverse:=linalg.inverse(placed)
        local:=(inverse*[4]f32{view.position.x,view.position.y,view.position.z,1}).xyz
        scale:=max(linalg.length(placed[0].xyz),linalg.length(placed[1].xyz),linalg.length(placed[2].xyz))
        near:scene.Sources_Near
        if work.stream {near=scene.sources_near(work.sources.ptr,placed,work.resident_distance)}
        for &node,i in owner.nodes {
            low,high:=node_box(s,q,entry.ranges,i)
            at:=scene.box_distance(low,high,local)
            node.distance=at*scale
            node.reach=work.stream?scene.box_near(&near,low,high):0
            // Errors are in the space of the source, as at.
            node.pixels=work.pixels/max(at,1e-3)
            // Seen at a grazing angle, its spacing shrinks along the view.
            node.spacing=node.pixels*math.sqrt(clamp((local.y-high.y)/max(at,1e-3),LOD_GRAZING,1))
            chunk:=&source.chunks[i]
            chunk.distance,chunk.reach,chunk.pixels,chunk.spacing=node.distance,node.reach,node.pixels,node.spacing
        }
    }
}

@(private)
owner_cut :: proc(owner:^Resident_Owner,source:^Resident_Source,stream:bool) {
    q:=&owner.quad
    nodes:=owner.nodes
    chunks:=q.first[1]
    // What can cover a region now: what is wanted there, or a node that is
    // built standing in for it until then.
    stands :: proc(source:^Resident_Source,nodes:[]Owner_Node,chunks,i:int) -> bool {return nodes[i].can || i>=chunks && source.chunks[i].shown}
    // Whether what a node covers can show: a piece that is built, or children that stand.
    for d in 0..=q.depth {for i in q.first[d]..<q.first[d+1] {
        node:=&nodes[i]
        node.can=false
        if node.cut {node.can=source.chunks[i].shown;continue}
        if d==0 || !node.open {continue}
        node.can=true
        for child in quad_children(q,i) {if child>=0 && !stands(source,nodes,chunks,child) {node.can=false;break}}
    }}
    // From the roots down: a node shows its children once all of them stand,
    // a node in place of what is not built yet; until then what showed there
    // stays. A Volume has no nodes: a chunk that is not wanted goes.
    for d:=q.depth;d>=0;d-=1 {for i in q.first[d]..<q.first[d+1] {
        node:=&nodes[i]
        parent:=quad_parent(q,i)
        was:=node.visible
        opened:=parent>=0 && !nodes[parent].covering && nodes[parent].can && !nodes[parent].cut
        switch {
        case parent>=0 && nodes[parent].covering: node.visible,node.covering=false,true
        case node.can: node.visible,node.covering=node.cut,node.cut
        case opened && i>=chunks && source.chunks[i].shown: node.visible,node.covering=true,true
        case q.depth==0: node.visible,node.covering=false,false
        case: node.covering=node.visible
        }
        if node.visible!=was {append(&owner.changed,u32(i))}
    }}
    // A chunk near a viewer shows now, with its collider: what keeps the node
    // shown over it from opening is built in this call.
    if stream {for &node,i in nodes[:chunks] {
        if !node.cut || node.visible || node.reach>URGENT_REACH {continue}
        for at:=quad_parent(q,i);at>=0 && nodes[at].covering;at=quad_parent(q,at) {
            for child in quad_children(q,at) {if child>=0 && !stands(source,nodes,chunks,child) {source.chunks[child].urgent=true}}
            if nodes[at].visible {break}
        }
    }}
    for d in 0..=q.depth {for i in q.first[d]..<q.first[d+1] {
        node:=&nodes[i]
        node.covered=node.covering
        if node.covered || d==0 {continue}
        node.covered=true
        for child in quad_children(q,i) {if child>=0 && !nodes[child].covered {node.covered=false;break}}
    }}
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
    return settings.lod_distance==0 && len(entry.errors)==quad_total(&entry.quad)
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
@(private)
lod_levels_balance :: proc "contextless" (s:^Source,levels:[]u8) {
    n:=chunk_counts(s)
    if n.x*n.y*n.z!=len(levels) {return}
    for changed:=true;changed; {
        changed=false
        for &level,i in levels {
            coord:=chunk_coord(s,i)
            for dz in i32(-1)..=1 {for dy in i32(-1)..=1 {for dx in i32(-1)..=1 {
                j:=chunk_index(s,coord+{dx,dy,dz})
                if j<0 || level<=levels[j]+1 {continue}
                level=levels[j]+1
                changed=true
            }}}
        }
    }
}

// The chunks each terrain needs as chunks, whatever the view asks of them:
// those near its viewers when it streams; otherwise, of a solid terrain,
// those that take a collider: the nearest that the slots of Physics_Settings
// have room for, and with Terrain_Settings.collision_distance within it.
// A Volume, without nodes, needs every chunk it does not stream.
@(private)
resident_needed :: proc(resident:^Terrain_Resident,data:^Terrain_Data,terrains:core.Read(Terrain),c:^Chunk_Tables,settings:Terrain_Settings,physics:phys.Physics_Settings,focus:=Terrain_Focus{}) {
    stream:=settings.resident_distance>0
    reach:=[2]f32{max(f32),max(f32)}
    if !stream {
        // How many chunks are within each distance, in buckets of a sixteenth of an octave.
        BUCKETS :: 16*32
        bucket :: #force_inline proc "contextless" (distance:f32) -> int {return clamp(int(math.log2(max(distance,1))*16),0,BUCKETS-1)}
        counts:[2][BUCKETS]int
        for &owner in resident.owners {
            marker,known:=core.get(terrains,owner.entity)
            entry:=data_find(data,owner.source)
            if !known || !marker.solid || entry==nil {continue}
            kind:=entry.source.kind==.Heightfield?0:1
            for node in owner.nodes[:min(owner.quad.first[1],len(owner.nodes))] {counts[kind][bucket(node.distance)]+=1}
        }
        room,shapes:=collider_room(c,physics)
        for kind in 0..<2 {
            within:=0
            for n,b in counts[kind] {
                within+=n
                if within>min(room[kind],shapes) {reach[kind]=math.pow(2,f32(b)/16);break}
            }
            // A collision distance only brings it nearer: never more than the slots admit.
            if settings.collision_distance>0 {reach[kind]=min(reach[kind],settings.collision_distance)}
        }
    }
    for &owner in resident.owners {
        marker,known:=core.get(terrains,owner.entity)
        entry:=data_find(data,owner.source)
        solid:=known && marker.solid
        kind:=entry!=nil && entry.source.kind==.Heightfield?0:1
        for &node in owner.nodes[:min(owner.quad.first[1],len(owner.nodes))] {
            switch {
            case stream: node.resident=scene.resident(node.reach,node.resident)
            case owner.quad.depth==0: node.resident=true
            case: node.resident=solid && (node.distance<=reach[kind] || node.resident && node.distance<=reach[kind]*LOD_HYSTERESIS)
            }
        }
        // The chunks under the brush of the editor.
        if focus.radius>0 && owner.source==focus.source && entry!=nil {
            s:=&entry.source
            origin:=source_origin(s)
            for &node,i in owner.nodes[:min(owner.quad.first[1],len(owner.nodes))] {
                low,high:=chunk_box(s,origin,i,{})
                d:=[2]f32{max(low.x-focus.center.x,0,focus.center.x-high.x),max(low.z-focus.center.z,0,focus.center.z-high.z)}
                if d.x*d.x+d.y*d.y<=focus.radius*focus.radius {node.resident=true}
            }
        }
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
        if core.has(core.read(c.chunks),c.colliders.entities[row]) {continue}
        shapes-=1
        #partial switch collider.kind {
        case .Heightfield: room[0]-=1
        case .Mesh: room[1]-=1
        }
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
