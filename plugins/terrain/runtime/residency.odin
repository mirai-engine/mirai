package terrain

import "core:math"
import "core:math/linalg"
import "core:slice"
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
// pieces whose mesh shows something else. Each terrain opens, from its roots,
// the nodes under which a chunk is near a viewer, or nearer than their finest
// level reaches; within Terrain_Settings.chunks, the nearest open first, so
// past it the farthest show coarser nodes and nothing goes. Runs when a view
// or the transform of a terrain moves, or the sources, the colliders or the
// chunks change; while pieces wait to be built, again once a frame
// (once_more: the first call of a frame).
@(private)
resident_lod :: proc(resident:^Terrain_Resident,data:^Terrain_Data,worlds:^core.Table(core.World_Transform,.Read),views:Lod_Views,sources:core.Ref(scene.Streaming_Sources),settings:Terrain_Settings,terrains:^core.Table(Terrain,$A),c:^Chunk_Tables,physics:phys.Physics_Settings,problems:^core.Problems,once_more:=true,focus:=Terrain_Focus{}) {
    views:=views
    // Only the places of the terrains move their pieces: what else moves in the world does not.
    placed:=core.changes(worlds,&resident.lod_seen[0])
    moved:=placed.all
    if placed.written && !moved {for &owner in resident.owners {
        if row:=core.row_of(worlds,owner.entity);row>=0 && core.changed(worlds,placed,row) || slice.contains(placed.gone,owner.entity) {moved=true;break}
    }}
    moved|=core.touched(c.colliders,&resident.lod_seen[1])
    stamp:=[3]u64{sources.ptr!=nil?sources.ptr.revision:0,u64(len(resident.owners)),resident.marks}
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
    if !pending && !moved && stamp==resident.lod_stamp && distances==resident.lod_distances && brush==resident.focus && still {return}
    for view,v in views.items[:views.count] {resident.lod_views[v]=view.position}
    resident.lod_view_count,resident.lod_stamp,resident.lod_distances,resident.focus=views.count,stamp,distances,brush
    resident.cut=true
    stream:=settings.resident_distance>0
    clear(&resident.splits)
    roots:=0
    // The distances of every piece from its terrain, and the pixels a metre of error covers there.
    lod_measure(resident,data,worlds,views,sources,settings.resident_distance,stream)
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
        roots+=q.counts[q.depth].x*q.counts[q.depth].y*q.tall[q.depth]
        for d in 1..=q.depth {for i in q.first[d]..<q.first[d+1] {
            node:=&owner.nodes[i]
            node.want=false
            for child in quad_children(q,i) {if child>=0 && (child<chunks?owner.nodes[child].resident:owner.nodes[child].want) {node.want=true;break}}
            // Its finest level is too coarse for the view, and its children are
            // finer. The chunks of a streamed Heightfield need their pages: only
            // their residency opens to them.
            minimum:=node_lod_min(s,q,i)
            // A node of a Volume shows every sample at the levels of its clusters: only a chunk under it opens it.
            finer:=node_lod_min(s,q,quad_children(q,i)[0])<minimum && (d>1 || !stream)
            if !node.want && finer {
                switch {
                case settings.lod_distance<0: node.want=true
                case by_error:
                    slack:=f32(node.open?1/LOD_HYSTERESIS:1)
                    node.want=lod_error(entry.source.coarse.errors,q,i,int(minimum))*node.pixels>LOD_PIXELS*slack && lod_spacing_level(node.spacing/slack,s.cell)<minimum
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
    for &owner in resident.owners {for &node in owner.nodes {node.open=false}}
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
            chunk.resident=node.cut || stream && (node.open || i>=q.first[q.depth])
            chunk.wanted.collision=node.cut && node.collide
            if i>=chunks {continue}
            if node.cut && (!stream || node.reach<=DEEP_REACH) {source.deep[i]=true}
        }
        by_error:=lod_by_error(entry,settings)
        // A Volume has no levels of its own: its nodes show what is far.
        if s.kind==.Heightfield {heightfield_levels(entry,source,settings,by_error,base)}
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
                key.lod=chunk_lod_border(&border,source.levels[i],{int(coord.x),int(coord.z)})
                key.join=join_cut_key(s,source.join.cuts[:],i)
                if source.join.ground!={} && join_band_chunk(s,i,key.lod.level) {key.join=source.join.hash}
            } else {
                depth:=u8(quad_depth(q,i))
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
                }
            }
            chunk.wanted=key
            if chunk.wanted!=chunk.built || !chunk.shown || chunk.revision!=data_version(entry,i) {source_pending(source,i)}
        }
    }
}

// Which pieces the terrains show with a collider: the chunks, and past them
// the nodes with the triangles they show, so that far ground still stops
// rays and bodies; the nearest that Physics_Settings has room for beside the
// colliders of everything else, every chunk before any node, and of those,
// with Terrain_Settings.collision_distance, the ones within it.
@(private)
resident_colliders :: proc(resident:^Terrain_Resident,data:^Terrain_Data,terrains:^core.Table(Terrain,$A),c:^Chunk_Tables,settings:Terrain_Settings,physics:phys.Physics_Settings) {
    defer {for &owner in resident.owners {
        // A piece it shows whose collider comes or goes shows again.
        for &node,i in owner.nodes {if node.visible && node.collide!=node.can {append(&owner.changed,u32(i))}}}
    }
    clear(&resident.splits)
    for &owner,o in resident.owners {
        marker,known:=core.get(terrains,owner.entity)
        entry:=data_find(data,owner.source)
        source:=resident_source_find(resident,owner.source,owner.entity)
        chunks:=owner.quad.first[1]
        for &node,i in owner.nodes {
            // What it had, until owner_cut takes can again.
            node.can=node.collide
            node.collide=false
            if !known || entry==nil || !marker.solid || owner.far || !node.cut {continue}
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

// The views the levels are chosen for: that of the frame and each local view
// of a split screen, with its own size and field. A piece shows what the
// nearest of them needs.
LOD_VIEWS :: 1+len(camera.Local_Views{}.items)
Lod_Views :: struct {
    items:[LOD_VIEWS]core.View,
    count:int,
}

lod_views_of :: proc "contextless" (view:core.View,locals:core.Ref(camera.Local_Views)) -> (views:Lod_Views) {
    views.items[0],views.count=view,1
    if locals.ptr==nil {return}
    for local,slot in locals.items {
        if int(local.slot)!=slot+1 || local.camera==core.NONE {continue}
        views.items[views.count]=local
        views.count+=1
    }
    return
}

// Nodes measured by one job of lod_distances at least.
@(private) LOD_SPAN :: 1024

// What an owner is seen from, in the space of its source.
@(private)
Lod_Place :: struct {
    owner:int,
    s:^Source,
    q:^Quad,
    chunks:[]Resident_Chunk,
    views:[LOD_VIEWS][3]f32,
    pixels:[LOD_VIEWS]f32,
    scale:f32,
    near:scene.Sources_Near,
}

@(private)
Lod_Distances :: struct {
    resident:^Terrain_Resident,
    places:[]Lod_Place,
    spans:[][3]int, // place, first and last node
    count:int,      // of views
    stream:bool,
}

// What the pieces of every owner are from its views and viewers: the places
// of the owners first, then the nodes in spans, in jobs, so a large terrain
// spreads over the workers.
@(private)
lod_measure :: proc(resident:^Terrain_Resident,data:^Terrain_Data,worlds:^core.Table(core.World_Transform,.Read),views:Lod_Views,sources:core.Ref(scene.Streaming_Sources),resident_distance:f32,stream:bool) {
    views:=views
    places,spans:=&resident.places,&resident.spans
    clear(places);clear(spans)
    for &owner,o in resident.owners {
        entry:=data_find(data,owner.source)
        source:=entry!=nil?resident_source_find(resident,owner.source,owner.entity):nil
        if source==nil || len(source.chunks)!=len(entry.dirty) || len(owner.nodes)!=len(source.chunks) {continue}
        placed:=mm.MAT4_IDENTITY
        if world,known:=core.get(worlds,owner.entity);known {placed=mm.transform_matrix(world.transform)}
        inverse:=linalg.inverse(placed)
        place:=Lod_Place{owner=o,s=&entry.source,q=&source.quad,chunks=source.chunks}
        place.scale=max(linalg.length(placed[0].xyz),linalg.length(placed[1].xyz),linalg.length(placed[2].xyz))
        for view,v in views.items[:views.count] {
            place.views[v]=(inverse*[4]f32{view.position.x,view.position.y,view.position.z,1}).xyz
            place.pixels[v]=view_pixels(view)
        }
        if stream {place.near=scene.sources_near(sources.ptr,placed,resident_distance)}
        // Room for both is made with the owner (resident_owner).
        if append(places,place)!=1 {return}
        for first:=0;first<len(owner.nodes);first+=LOD_SPAN {append(spans,[3]int{len(places)-1,first,min(first+LOD_SPAN,len(owner.nodes))})}
    }
    work:=Lod_Distances{resident,places[:],spans[:],views.count,stream}
    if data.jobs!=nil && jobs.worker_count(data.jobs)>1 && len(spans)>1 {
        jobs.parallel_for(data.jobs,jobs.OWNER,len(spans),1,lod_distances,&work)
    } else {lod_distances(&work,0,len(spans),jobs.OWNER)}
}

// Spans first..<last of lod_measure: what each of their pieces is from the views and the viewers.
@(private)
lod_distances :: proc(work:^Lod_Distances,first,last:int,worker:int) {
    for span in work.spans[first:last] {
        place:=&work.places[span[0]]
        owner:=&work.resident.owners[place.owner]
        s,q:=place.s,place.q
        for i in span[1]..<span[2] {
            node:=&owner.nodes[i]
            low,high:=node_box(s,q,s.coarse.ranges,i)
            // Of the nearest view; the pixels and spacing of the view that sees it finest.
            nearest,pixels,spacing:=max(f32),f32(0),f32(0)
            for local,v in place.views[:work.count] {
                at:=scene.box_distance(low,high,local)
                nearest=min(nearest,at)
                // Errors are in the space of the source, as at.
                seen:=place.pixels[v]/max(at,1e-3)
                pixels=max(pixels,seen)
                // Seen at a grazing angle, its spacing shrinks along the view.
                spacing=max(spacing,seen*math.sqrt(clamp((local.y-high.y)/max(at,1e-3),LOD_GRAZING,1)))
            }
            node.distance=nearest*place.scale
            node.reach=work.stream?scene.box_near(&place.near,low,high):0
            node.pixels,node.spacing=pixels,spacing
            chunk:=&place.chunks[i]
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
    // stays.
    for d:=q.depth;d>=0;d-=1 {for i in q.first[d]..<q.first[d+1] {
        node:=&nodes[i]
        parent:=quad_parent(q,i)
        was:=node.visible
        opened:=parent>=0 && !nodes[parent].covering && nodes[parent].can && !nodes[parent].cut
        switch {
        case parent>=0 && nodes[parent].covering: node.visible,node.covering=false,true
        case node.can: node.visible,node.covering=node.cut,node.cut
        case opened && i>=chunks && source.chunks[i].shown: node.visible,node.covering=true,true
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
// those that take a collider: the nearest that the slots of Physics_Settings
// have room for, and with Terrain_Settings.collision_distance within it.
// A Volume, without nodes, needs every chunk it does not stream.
@(private)
resident_needed :: proc(resident:^Terrain_Resident,data:^Terrain_Data,terrains:^core.Table(Terrain,$A),c:^Chunk_Tables,settings:Terrain_Settings,physics:phys.Physics_Settings,focus:=Terrain_Focus{}) {
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
            kind:=collider_slot(entry.source.kind)
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
        kind:=entry!=nil?collider_slot(entry.source.kind):1
        for &node in owner.nodes[:min(owner.quad.first[1],len(owner.nodes))] {
            switch {
            case stream: node.resident=scene.resident(node.reach,node.resident)
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
