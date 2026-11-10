package navigation_editor

import "core:fmt"
import "core:math/linalg"
import "core:strings"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/ai"
import "mirai:std/base"
import mm "mirai:std/math"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"

// The Navigation modes of the viewport: the mesh of a class over the lit
// image (navigation is the first class, navigation.<class> each one), its
// polygons by area, walls brighter, the borders between tiles and the links
// with their arc and direction; for a class of the air, its zones and the
// free nodes of their octrees. The lines are made again only when the mesh
// or the volume changes. navigation.<class>.collision shows what the mesh of
// a class is made of, around the camera: the static collision that blocks its
// agents bright, and the one that blocks only others (a clip for players) dim.

NAV_VIEW_LINES :: 1<<17 // the most lines drawn; the rest are counted
NAV_VIEW_PREFIX :: "navigation."
NAV_VIEW_LIFT :: f32(0.04) // m above the surface, so the lines are not hidden by it
NAV_VIEW_COLLISION_SUFFIX :: ".collision"
NAV_VIEW_COLLISION_REACH :: f32(40)          // m around the camera whose collision is shown
NAV_VIEW_COLLISION_TRIANGLES :: 1<<15         // the most triangles read; the rest are counted as lines dropped
COLLISION_IN_COLOR :: mm.Vec4{1,0.75,0.2,0.9} // blocks the agents of the class: in its mesh
COLLISION_OUT_COLOR :: mm.Vec4{0.6,0.6,0.7,0.25} // blocks only others: not in its mesh

@(storage,free="nav_view_free")
Nav_View :: struct {
    vertices:[dynamic]erender.Debug_Vertex, // made the first time a mode is shown
    world:rawptr,   // what the lines were made from
    revision:u64,
    class:int,
    count,dropped:int,
    ready:bool,
    agents:[dynamic]erender.Debug_Vertex, // the paths of the selected agents, made every frame
    shown:int,      // the class the mode of this frame shows, or -1
    collision:bool, // the mode shows the collision of the class, not its mesh
    lines_collision:bool, // what the lines were made of
    center:mm.Vec3, // of the collision the lines show
    triangles:[dynamic][3]f32, // read with the colliders of their triangles, the first time the collision is shown
    indices:[dynamic]u32,
    owners:[dynamic]core.Entity,
}
NAV_VIEW_DEFAULT :: Nav_View{shown=-1,class=-1}

nav_view_free :: proc(v:^Nav_View) {
    delete(v.vertices)
    delete(v.agents)
    delete(v.triangles)
    delete(v.indices)
    delete(v.owners)
    v^=NAV_VIEW_DEFAULT
}

@(step="frame")
navigation_view_modes :: proc(s:^editor.Session,view:^Nav_View) {
    w:=editor.shown_world(s)
    n:^nav.Navigation
    if w.data!=nil {n=core.world_storage_of(w,nav.Navigation)}
    reason:=""
    if n==nil {reason="The world shown has no navigation"} else if !n.ready || n.count==0 {reason="The navigation meshes are not made yet"}
    current:=editor.view_mode_current(s.viewport)
    view.shown,view.collision=-1,false
    editor.view_mode_declare(s,{name="navigation",label="Navigation",title="Navigation",group="Advanced",submenu="Navigation",icon=.Target,reason=reason,record=navigation_view_record})
    if strings.equal_fold(current,"navigation") && reason=="" {view.shown=0}
    if n==nil {return}
    for i in 0..<n.count {
        name:=base.text_get(n.classes[i].class.name[:])
        mode:=fmt.tprintf("%s%s",NAV_VIEW_PREFIX,name)
        editor.view_mode_declare(s,{name=mode,label=name,title=fmt.tprintf("Navigation: %s",name),group="Advanced",submenu="Navigation",icon=.Layers,reason=reason,record=navigation_view_record})
        if strings.equal_fold(current,mode) && reason=="" {view.shown=i}
        if nav.class_in_volume(n,i) {continue}
        collision:=fmt.tprintf("%s%s",mode,NAV_VIEW_COLLISION_SUFFIX)
        editor.view_mode_declare(s,{name=collision,label=fmt.tprintf("%s: collision",name),title=fmt.tprintf("Navigation: what the mesh of %s is made of",name),group="Advanced",submenu="Navigation",icon=.Layers,reason=reason,record=navigation_view_record})
        if strings.equal_fold(current,collision) && reason=="" {view.shown,view.collision=i,true}
    }
    if editor.document_is_prefab(s) {view.shown=-1}
}

@(step="render",after="render_sync")
navigation_view_lines :: proc(s:^editor.Session,view:^Nav_View,extras:^host.Frame_Extras) {
    if view.shown<0 {return}
    w:=editor.shown_world(s)
    n:=core.world_storage_of(w,nav.Navigation)
    if n==nil || view.shown>=n.count {return}
    if len(view.vertices)==0 {resize(&view.vertices,2*NAV_VIEW_LINES)}
    lines:=erender.debug_lines_make(view.vertices[:])
    // The collision follows the camera: made again once it went a quarter of the reach away.
    center:=s.viewport.camera.position
    moved:=view.collision && linalg.length(center-view.center)>NAV_VIEW_COLLISION_REACH*0.25
    if !view.ready || view.world!=w.data || view.revision!=n.revision || view.class!=view.shown || view.lines_collision!=view.collision || moved {
        if view.collision {
            draw_collision(&lines,view,core.world_storage_of(w,phys.Physics_State),&n.classes[view.shown],center)
            view.center=center
        } else if nav.class_in_volume(n,view.shown) {draw_volume(&lines,&n.classes[view.shown].volume)} else {draw_mesh(&lines,&n.classes[view.shown].mesh)}
        view.world,view.revision,view.class,view.lines_collision=w.data,n.revision,view.shown,view.collision
        view.count,view.dropped,view.ready=lines.count,lines.dropped,true
    }
    lines.count,lines.dropped=view.count,view.dropped
    if lines.count>0 {host.extras_debug_lines_add(extras,lines)}
    if s.selection==nil || len(s.selection.entities)==0 {return}
    paths:=core.world_table_of(w,nav.Nav_Path)
    if paths==nil {return}
    if len(view.agents)==0 {resize(&view.agents,2*NAV_VIEW_AGENT_LINES)}
    agent_lines:=erender.debug_lines_make(view.agents[:],depth_test=false)
    for e in s.selection.entities {
        p,found:=core.get(paths,e)
        if !found || p.class<0 || int(p.class)>=n.count {continue}
        if nav.class_in_volume(n,int(p.class)) {draw_flier(&agent_lines,&n.classes[p.class].volume,p)} else {draw_agent(&agent_lines,&n.classes[p.class].mesh,p)}
    }
    if agent_lines.count>0 {host.extras_debug_lines_add(extras,agent_lines)}
}

NAV_VIEW_AGENT_LINES :: 4096
AGENT_COLOR :: mm.Vec4{1,1,1,0.95}
CORRIDOR_COLOR :: mm.Vec4{0.35,0.6,1,0.6}

// The path of an agent: the outlines of its corridor and its next corners to the goal.
draw_agent :: proc(lines:^erender.Debug_Lines,mesh:^ai.Nav_Mesh,p:nav.Nav_Path) {
    up:=mm.Vec3{0,NAV_VIEW_LIFT*2,0}
    corridor:=p.corridor
    for ref in corridor.path[:clamp(corridor.count,0,ai.NAV_CORRIDOR_CAPACITY)] {
        tile,poly:=ai.nav_poly_of(mesh,ref)
        if poly==nil {continue}
        corners:[ai.NAV_VERTS_PER_POLY]mm.Vec3
        count:=ai.nav_poly_vertices(tile,poly,&corners)
        for i in 0..<count {erender.debug_line(lines,corners[i]+up,corners[(i+1)%count]+up,CORRIDOR_COLOR)}
    }
    if p.state!=.Moving && p.state!=.Crossing {return}
    corners:[16]ai.Nav_Corner
    count,_:=ai.nav_straight_path(mesh,corridor.position,corridor.target,corridor.path[:clamp(corridor.count,0,ai.NAV_CORRIDOR_CAPACITY)],corners[:])
    for i in 1..<count {erender.debug_line(lines,corners[i-1].position+up,corners[i].position+up,AGENT_COLOR)}
    if p.state==.Crossing {erender.debug_line(lines,p.from+up,p.to+up,LINK_COLOR)}
}

// The path of an agent that flies: the cells of its corridor and its path pulled tight to the goal.
draw_flier :: proc(lines:^erender.Debug_Lines,volume:^ai.Nav_Volume,p:nav.Nav_Path) {
    corridor:=p.corridor
    path:=corridor.path[:clamp(corridor.count,0,ai.NAV_CORRIDOR_CAPACITY)]
    for ref in path {
        if box,ok:=ai.nav_volume_ref_box(volume,ref);ok {draw_box(lines,box,CORRIDOR_COLOR)}
    }
    if p.state!=.Moving {return}
    corners:[32]mm.Vec3
    count,_:=ai.nav_volume_straight_path(volume,corridor.position,corridor.target,path,corners[:])
    for i in 1..<count {erender.debug_line(lines,corners[i-1],corners[i],AGENT_COLOR)}
}

ZONE_COLOR :: mm.Vec4{0.6,0.6,0.6,0.35}
FREE_COLOR :: mm.Vec4{0.3,0.85,1,0.25}

draw_box :: proc(lines:^erender.Debug_Lines,box:mm.Aabb,color:mm.Vec4) {
    corner :: #force_inline proc "contextless" (box:mm.Aabb,i:int) -> mm.Vec3 {
        return {box.max.x if i&1!=0 else box.min.x,box.max.y if i&2!=0 else box.min.y,box.max.z if i&4!=0 else box.min.z}
    }
    edges:=[12][2]int{{0,1},{2,3},{4,5},{6,7},{0,2},{1,3},{4,6},{5,7},{0,4},{1,5},{2,6},{3,7}}
    for e in edges {erender.debug_line(lines,corner(box,e[0]),corner(box,e[1]),color)}
}

// The zones of a volume and the free nodes of their octrees bigger than a
// block: the blocks and voxels along the obstacles are too many to read.
draw_volume :: proc(lines:^erender.Debug_Lines,volume:^ai.Nav_Volume) {
    Item :: struct {layer:int,index:u32,cell:[3]i32}
    stack:[8*ai.NAV_VOLUME_MAX_LAYERS+8]Item
    for &zone in volume.zones {
        if !zone.used {continue}
        data:=&zone.data
        draw_box(lines,ai.nav_volume_zone_box(volume,data.coord),ZONE_COLOR)
        stack[0]={int(data.layers),0,{}}
        top:=1
        for top>0 {
            top-=1
            item:=stack[top]
            node:=data.nodes[int(data.first[item.layer])+int(item.index)]
            switch node.cell {
            case .Blocked:
            case .Free:
                if item.layer==int(data.layers) || item.layer==0 {continue}
                box:=ai.nav_volume_cell_box(volume,data.coord,item.layer,item.cell)
                inset:=volume.voxel*0.1
                draw_box(lines,{box.min+inset,box.max-inset},FREE_COLOR)
            case .Mixed:
                if item.layer<=1 {continue}
                for o in u32(0)..<8 {
                    stack[top]={item.layer-1,node.children+o,{item.cell.x*2+i32(o&1),item.cell.y*2+i32((o>>1)&1),item.cell.z*2+i32((o>>2)&1)}}
                    top+=1
                }
            }
        }
    }
}

// The static collision around center that the mesh of a class reads: the
// triangles of the colliders that block its agents bright, those of the
// colliders that block only others dim.
draw_collision :: proc(lines:^erender.Debug_Lines,view:^Nav_View,physics:^phys.Physics_State,c:^nav.Class_Mesh,center:mm.Vec3) {
    if physics==nil {return}
    if len(view.owners)==0 {
        resize(&view.triangles,3*NAV_VIEW_COLLISION_TRIANGLES)
        resize(&view.indices,3*NAV_VIEW_COLLISION_TRIANGLES)
        resize(&view.owners,NAV_VIEW_COLLISION_TRIANGLES)
    }
    box:=mm.Aabb{center-NAV_VIEW_COLLISION_REACH,center+NAV_VIEW_COLLISION_REACH}
    // The colliders in the mesh first, then every static one: both lists name the collider of each triangle.
    _,in_count,_:=phys.static_triangles(core.ref(physics),box,view.triangles[:],view.indices[:],c.filter,view.owners[:])
    in_mesh:=make(map[core.Entity]struct{},context.temp_allocator)
    for e in view.owners[:in_count/3] {in_mesh[e]={}}
    everything:=phys.QUERY_FILTER_DEFAULT
    everything.objects=phys.COLLISION_LAYERS_ALL
    _,index_count,complete:=phys.static_triangles(core.ref(physics),box,view.triangles[:],view.indices[:],everything,view.owners[:])
    for i in 0..<index_count/3 {
        color:=COLLISION_IN_COLOR if view.owners[i] in in_mesh else COLLISION_OUT_COLOR
        a,b,d:=view.triangles[view.indices[i*3]],view.triangles[view.indices[i*3+1]],view.triangles[view.indices[i*3+2]]
        erender.debug_line(lines,a,b,color)
        erender.debug_line(lines,b,d,color)
        erender.debug_line(lines,d,a,color)
    }
    if !complete {lines.dropped+=1}
}

// The lines go over the lit image: the pass of the mode draws nothing.
@(private)
navigation_view_record :: proc(pass:^erender.Pass,user:rawptr) {}

// A color for an area: walkable in green, blocked never drawn, the rest spread around the hue circle.
area_color :: proc "contextless" (area:u8,bright:bool) -> mm.Vec4 {
    alpha:=f32(0.95) if bright else 0.35
    if area==ai.NAV_AREA_WALKABLE {return {0.25,0.9,0.45,alpha}}
    hue:=f32(area)*0.618034
    hue-=f32(int(hue))
    // A hue as three ramps.
    r:=clamp(abs(hue*6-3)-1,0,1)
    g:=clamp(2-abs(hue*6-2),0,1)
    b:=clamp(2-abs(hue*6-4),0,1)
    return {r,g,b,alpha}
}

LINK_COLOR :: mm.Vec4{1,0.8,0.2,0.95}
LINK_GENERATED_COLOR :: mm.Vec4{0.95,0.55,1,0.9}
LINK_LOOSE_COLOR :: mm.Vec4{1,0.25,0.2,0.9}
PORTAL_COLOR :: mm.Vec4{0.3,0.85,1,0.6}
TILE_COLOR :: mm.Vec4{0.6,0.6,0.6,0.35}

draw_mesh :: proc(lines:^erender.Debug_Lines,mesh:^ai.Nav_Mesh) {
    up:=mm.Vec3{0,NAV_VIEW_LIFT,0}
    for &tile in mesh.tiles {
        if !tile.used {continue}
        b:=tile.data.bounds
        y:=b.min.y
        rect:=[4]mm.Vec3{{b.min.x,y,b.min.z},{b.max.x,y,b.min.z},{b.max.x,y,b.max.z},{b.min.x,y,b.max.z}}
        for i in 0..<4 {erender.debug_line(lines,rect[i],rect[(i+1)%4],TILE_COLOR)}
        for &poly,p in tile.data.polys {
            corners:[ai.NAV_VERTS_PER_POLY]mm.Vec3
            count:=ai.nav_poly_vertices(&tile,&poly,&corners)
            for e in 0..<count {
                neighbor:=poly.neighbor[e]
                a,c:=corners[e]+up,corners[(e+1)%count]+up
                switch {
                case neighbor==ai.NAV_EDGE_WALL:
                    erender.debug_line(lines,a,c,area_color(poly.area,true))
                case neighbor&ai.NAV_EDGE_PORTAL!=0:
                    erender.debug_line(lines,a,c,PORTAL_COLOR)
                case int(neighbor)-1>p:
                    erender.debug_line(lines,a,c,area_color(poly.area,false))
                }
            }
        }
    }
    for &link in mesh.links {
        if !link.used {continue}
        draw_link(lines,&link)
    }
}

// A link as the arc an agent jumps (a straight line when its ends are level
// or one under the other), with a head at each end it can be left by.
draw_link :: proc(lines:^erender.Debug_Lines,link:^ai.Nav_Link) {
    rested:=link.start_poly!=0 && link.end_poly!=0
    a:=link.start_point if rested else link.desc.start
    b:=link.end_point if rested else link.desc.end
    color:=LINK_LOOSE_COLOR
    if rested {color=LINK_GENERATED_COLOR if link.desc.owner&nav.LINK_OWNER_GENERATED!=0 else LINK_COLOR}
    SEGMENTS :: 12
    rise:=max(0.25,abs(b.y-a.y)*0.25)
    previous:=a
    for i in 1..=SEGMENTS {
        t:=f32(i)/SEGMENTS
        p:=a+(b-a)*t
        p.y+=4*rise*t*(1-t)
        erender.debug_line(lines,previous,p,color)
        previous=p
    }
    head :: proc(lines:^erender.Debug_Lines,at,from:mm.Vec3,color:mm.Vec4) {
        d:=at-from
        d.y=0
        length:=linalg.length(d)
        if !(length>1e-4) {return}
        d/=length
        side:=mm.Vec3{-d.z,0,d.x}
        erender.debug_line(lines,at,at-d*0.25+side*0.12,color)
        erender.debug_line(lines,at,at-d*0.25-side*0.12,color)
    }
    head(lines,b,a,color)
    if link.desc.two_way {head(lines,a,b,color)}
}
