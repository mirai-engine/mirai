package mirai_physics

import cmath "core:math"
import "mirai:std/math"

// What a line shows; the caller picks the color.
Debug_Kind :: enum u8 {
    Static,
    Kinematic,
    Dynamic,  // an awake dynamic body
    Sleeping, // a dynamic body asleep
    Trigger,  // a shape that blocks no layer
    Character,
    Debris,
    Bounds,   // the fat box of a shape in the broad phase
    Joint,    // from a body to the anchor of a joint
    Center,   // the center of mass of a body
    Fluid,    // the volume of a fluid and its surface
    Dry,      // a dry box
}

Debug_Draw_Flag :: enum u8 {Shapes,Bounds,Contacts,Joints,Centers,Fluids}
Debug_Draw_Flags :: bit_set[Debug_Draw_Flag;u8]

Debug_Line :: struct {a,b:Vec3,kind:Debug_Kind}
// A point of a touching manifold after the last step; the normal goes from shape A to shape B.
Debug_Point :: struct {position,normal:Vec3,separation,impulse:f32}

// Caller buffers that world_debug_draw fills from the start; what does not fit is only counted.
Debug_Draw :: struct {
    lines:[]Debug_Line,
    points:[]Debug_Point,
    line_count,point_count:int,
    lines_dropped,points_dropped:int,
}

@(private) DEBUG_SEGMENTS :: 16

// Writes what `flags` asks for into `out`, for the shapes and bodies whose boxes meet `region` (a zero box
// is the whole world), without allocating:
// - Shapes: the edges of boxes, hulls and meshes, three circles of a sphere, the outline of a capsule or a
//   cylinder and the grid of a heightfield; meshes and heightfields only where they meet the region. Rounded
//   shapes show their size, without the rounding.
// - Bounds: the fat box of each shape. Contacts: the points of touching manifolds.
// - Joints: a line from each body to the anchor. Centers: a cross at each center of mass.
// - Fluids: the edges of the fluid boxes and dry boxes, and a grid on the surface of a plane over the region,
//   or DEBUG_PLANE_REACH around its position when the region is the whole world.
// Shapes and Bounds are those of the shapes in some of `layers` (Filter.layers).
world_debug_draw :: proc(w:^World,out:^Debug_Draw,flags:Debug_Draw_Flags,region:=Aabb{},layers:=~Collision_Layers(0)) #no_bounds_check {
    out.line_count,out.point_count,out.lines_dropped,out.points_dropped=0,0,0,0
    everywhere:=region==Aabb{}
    meets :: proc "contextless" (box,region:Aabb,everywhere:bool) -> bool {return everywhere || math.aabb_overlaps(box,region)}
    if flags&{.Shapes,.Bounds}!={} {
        for &shape in w.shapes[:w.shape_high] {
            if shape.generation&1==0 || shape.filter.layers&layers==0 || !meets(shape.fat,region,everywhere) {continue}
            body:=&w.bodies[shape.body]
            if .Bounds in flags {debug_box(out,shape.fat,.Bounds)}
            if .Shapes in flags {debug_shape(w,out,&shape,body,debug_kind(&shape,body),region,everywhere)}
        }
    }
    if .Centers in flags {
        for &body in w.bodies[:w.body_high] {
            if body.generation&1==0 || body.type==.Static || !meets({body.center,body.center},region,everywhere) {continue}
            for axis in ([3]Vec3{{0.1,0,0},{0,0.1,0},{0,0,0.1}}) {debug_line(out,body.center-axis,body.center+axis,.Center)}
        }
    }
    if .Joints in flags {
        for &joint in w.joints[:w.joint_high] {
            if joint.generation&1==0 {continue}
            a,b:=&w.bodies[joint.body_a],&w.bodies[joint.body_b]
            anchor_a:=xf_point(body_transform_of(a),joint.frame_a.p)
            anchor_b:=xf_point(body_transform_of(b),joint.frame_b.p)
            if !meets({vmin(anchor_a,anchor_b),vmax(anchor_a,anchor_b)},region,everywhere) {continue}
            debug_line(out,a.center,anchor_a,.Joint)
            debug_line(out,anchor_a,anchor_b,.Joint)
            debug_line(out,b.center,anchor_b,.Joint)
        }
    }
    if .Fluids in flags {
        for &f in w.fluids[:w.fluid_high] {
            if f.generation&1==0 {continue}
            if f.shape==.Plane {
                debug_fluid_plane(out,w,&f,region,everywhere)
            } else if !meets(fluid_aabb(&f),region,everywhere) {
            } else if f.shape==.River {
                debug_fluid_river(out,&f)
            } else {
                debug_fluid_box(out,&f,f.density>0?.Fluid:.Dry)
            }
        }
    }
    if .Contacts in flags {
        for &contact,index in w.contacts[:w.contact_high] {
            if contact.flags&{.Touching,.Overlap}!={.Touching} {continue}
            for m in 0..<int(contact.manifold_count) {
                manifold:=m==0?&w.manifolds[index]:&w.extra_manifolds[contact.extra][m-1]
                for point in manifold.points[:manifold.count] {
                    if !meets({point.point,point.point},region,everywhere) {continue}
                    if out.point_count>=len(out.points) {out.points_dropped+=1;continue}
                    out.points[out.point_count]={point.point,manifold.normal,point.separation,point.impulse}
                    out.point_count+=1
                }
            }
        }
    }
}

shape_debug_draw :: proc(w:^World,handle:Shape_Handle,out:^Debug_Draw,region:=Aabb{}) -> bool {
    out.line_count,out.point_count,out.lines_dropped,out.points_dropped=0,0,0,0
    shape,_:=shape_read(w,handle)
    if shape==nil {return false}
    body:=&w.bodies[shape.body]
    debug_shape(w,out,shape,body,debug_kind(shape,body),region,region==Aabb{})
    return true
}

@(private)
debug_kind :: proc "contextless" (shape:^Shape,body:^Body) -> Debug_Kind {
    switch {
    case shape.filter.block==0: return .Trigger
    case .Character in body.flags: return .Character
    case .Debris in body.flags: return .Debris
    case body.type==.Static: return .Static
    case body.type==.Kinematic: return .Kinematic
    case .Awake not_in body.flags: return .Sleeping
    }
    return .Dynamic
}

@(private) DEBUG_PLANE_REACH :: 64 // m
@(private) DEBUG_PLANE_LINES :: 32 // across each axis of the surface of a plane
@(private) DEBUG_PLANE_PIECES :: 8 // of each line, which follow the height of the surface

// The banks of a river along its path.
@(private)
debug_fluid_river :: proc "contextless" (out:^Debug_Draw,f:^Fluid) {
    count:=int(f.river_at[f.river_count-1])+1
    bank :: proc "contextless" (f:^Fluid,j,count:int,side:f32) -> Vec3 {
        a,b:=f.river[max(j-1,0)].position,f.river[min(j+1,count-1)].position
        across:=normalize(Vec3{a.z-b.z,0,b.x-a.x})
        return f.river[j].position+across*(side*0.5*f.river[j].width)
    }
    for j in 0..<count-1 {
        debug_line(out,bank(f,j,count,1),bank(f,j+1,count,1),.Fluid)
        debug_line(out,bank(f,j,count,-1),bank(f,j+1,count,-1),.Fluid)
    }
    debug_line(out,bank(f,0,count,1),bank(f,0,count,-1),.Fluid)
    debug_line(out,bank(f,count-1,count,1),bank(f,count-1,count,-1),.Fluid)
}

@(private)
debug_fluid_box :: proc "contextless" (out:^Debug_Draw,f:^Fluid,kind:Debug_Kind) {
    s,c:=cmath.sincos(f.yaw)
    x,z:=Vec3{c,0,-s}*f.half_extents.x,Vec3{s,0,c}*f.half_extents.z
    y:=UP*f.half_extents.y
    corner :: proc "contextless" (p,x,y,z:Vec3,i:int) -> Vec3 {
        return p+(i&1!=0?x:-x)+(i&2!=0?y:-y)+(i&4!=0?z:-z)
    }
    for i in 0..<8 {
        for bit in ([3]int{1,2,4}) {
            if i&bit==0 {debug_line(out,corner(f.position,x,y,z,i),corner(f.position,x,y,z,i|bit),kind)}
        }
    }
}

// A grid on the surface of a plane, each line in pieces that follow its height.
@(private)
debug_fluid_plane :: proc "contextless" (out:^Debug_Draw,w:^World,f:^Fluid,region:Aabb,everywhere:bool) {
    lo:=Vec3{f.position.x-DEBUG_PLANE_REACH,0,f.position.z-DEBUG_PLANE_REACH}
    hi:=Vec3{f.position.x+DEBUG_PLANE_REACH,0,f.position.z+DEBUG_PLANE_REACH}
    if !everywhere {
        if region.min.y>f.position.y+f.reach {return}
        lo,hi=region.min,region.max
    }
    at :: proc "contextless" (w:^World,f:^Fluid,x,z:f32) -> Vec3 {
        height,_:=fluid_surface_at(w,f,x,z)
        return {x,height,z}
    }
    for line in 0..=DEBUG_PLANE_LINES {
        t:=f32(line)/DEBUG_PLANE_LINES
        x,z:=lo.x+(hi.x-lo.x)*t,lo.z+(hi.z-lo.z)*t
        for piece in 0..<DEBUG_PLANE_PIECES {
            a,b:=f32(piece)/DEBUG_PLANE_PIECES,f32(piece+1)/DEBUG_PLANE_PIECES
            debug_line(out,at(w,f,x,lo.z+(hi.z-lo.z)*a),at(w,f,x,lo.z+(hi.z-lo.z)*b),.Fluid)
            debug_line(out,at(w,f,lo.x+(hi.x-lo.x)*a,z),at(w,f,lo.x+(hi.x-lo.x)*b,z),.Fluid)
        }
    }
}

@(private)
debug_line :: #force_inline proc "contextless" (out:^Debug_Draw,a,b:Vec3,kind:Debug_Kind) {
    if out.line_count>=len(out.lines) {out.lines_dropped+=1;return}
    out.lines[out.line_count]={a,b,kind}
    out.line_count+=1
}

@(private)
debug_box :: proc "contextless" (out:^Debug_Draw,box:Aabb,kind:Debug_Kind) {
    corner :: proc "contextless" (box:Aabb,i:int) -> Vec3 {
        return {i&1!=0?box.max.x:box.min.x,i&2!=0?box.max.y:box.min.y,i&4!=0?box.max.z:box.min.z}
    }
    for i in 0..<8 {
        for bit in ([3]int{1,2,4}) {
            if i&bit==0 {debug_line(out,corner(box,i),corner(box,i|bit),kind)}
        }
    }
}

// An arc of `turn` turns about `center` in the plane of the unit axes u and v, from u.
@(private)
debug_arc :: proc "contextless" (out:^Debug_Draw,center,u,v:Vec3,radius,turn:f32,kind:Debug_Kind) {
    segments:=max(int(f32(DEBUG_SEGMENTS)*turn),2)
    previous:=center+radius*u
    for i in 1..=segments {
        angle:=2*PI*turn*f32(i)/f32(segments)
        next:=center+radius*(cmath.cos(angle)*u+cmath.sin(angle)*v)
        debug_line(out,previous,next,kind)
        previous=next
    }
}

@(private)
debug_hull :: proc "contextless" (out:^Debug_Draw,hull:^Hull,xf:Transform,kind:Debug_Kind) {
    for i:=0;i<len(hull.edges);i+=2 {
        if out.line_count>=len(out.lines) {out.lines_dropped+=(len(hull.edges)-i)/2;break}
        debug_line(out,xf_point(xf,hull.vertices[hull.edges[i].origin]),xf_point(xf,hull.vertices[hull.edges[i+1].origin]),kind)
    }
}

@(private)
debug_shape :: proc(w:^World,out:^Debug_Draw,shape:^Shape,body:^Body,kind:Debug_Kind,region:Aabb,everywhere:bool) #no_bounds_check {
    xf:=xf_mul(body_transform_of(body),shape.local)
    switch shape.type {
    case .Sphere:
        r:=shape.size.x
        debug_arc(out,xf.p,{1,0,0},{0,1,0},r,1,kind)
        debug_arc(out,xf.p,{0,1,0},{0,0,1},r,1,kind)
        debug_arc(out,xf.p,{0,0,1},{1,0,0},r,1,kind)
    case .Capsule:
        r,h:=shape.size.x,shape.size.y
        u,up,v:=q_rotate(xf.q,{1,0,0}),q_rotate(xf.q,{0,1,0}),q_rotate(xf.q,{0,0,1})
        p,q:=xf.p-h*up,xf.p+h*up
        debug_arc(out,p,u,v,r,1,kind)
        debug_arc(out,q,u,v,r,1,kind)
        for side in ([4]Vec3{u,-u,v,-v}) {debug_line(out,p+r*side,q+r*side,kind)}
        debug_arc(out,q,u,up,r,0.5,kind)
        debug_arc(out,q,v,up,r,0.5,kind)
        debug_arc(out,p,-u,-up,r,0.5,kind)
        debug_arc(out,p,-v,-up,r,0.5,kind)
    case .Box:
        storage:Box_Hull
        hull:=box_hull(&storage,shape.size)
        debug_hull(out,&hull,xf,kind)
    case .Cylinder:
        r,h:=shape.size.x,shape.size.y
        u,up,v:=q_rotate(xf.q,{1,0,0}),q_rotate(xf.q,{0,1,0}),q_rotate(xf.q,{0,0,1})
        p,q:=xf.p-h*up,xf.p+h*up
        debug_arc(out,p,u,v,r,1,kind)
        debug_arc(out,q,u,v,r,1,kind)
        for side in ([4]Vec3{u,-u,v,-v}) {debug_line(out,p+r*side,q+r*side,kind)}
    case .Hull:
        debug_hull(out,&w.hulls[shape.resource].hull,xf,kind)
    case .Mesh:
        mesh:=&w.meshes[shape.resource].mesh
        for t,index in mesh.triangles {
            if everywhere && out.line_count>=len(out.lines) {out.lines_dropped+=3*(len(mesh.triangles)-index);break}
            a,b,c:=xf_point(xf,mesh.vertices[t[0]]),xf_point(xf,mesh.vertices[t[1]]),xf_point(xf,mesh.vertices[t[2]])
            if !everywhere && !math.aabb_overlaps({vmin(vmin(a,b),c),vmax(vmax(a,b),c)},region) {continue}
            debug_line(out,a,b,kind)
            debug_line(out,b,c,kind)
            debug_line(out,c,a,kind)
        }
    case .Heightfield:
        field:=&w.heightfields[shape.resource].field
        sample :: proc "contextless" (field:^Heightfield,xf:Transform,column,row:int) -> Vec3 {
            return xf_point(xf,{f32(column)*field.cell.x,field.heights[row*field.columns+column]*field.cell.y,f32(row)*field.cell.z})
        }
        for row in 0..<field.rows {
            for column in 0..<field.columns {
                p:=sample(field,xf,column,row)
                // An edge is drawn while a cell beside it has surface.
                if column+1<field.columns && (!heightfield_hole(field,column,row) || !heightfield_hole(field,column,row-1)) {
                    q:=sample(field,xf,column+1,row)
                    if everywhere || math.aabb_overlaps({vmin(p,q),vmax(p,q)},region) {debug_line(out,p,q,kind)}
                }
                if row+1<field.rows && (!heightfield_hole(field,column,row) || !heightfield_hole(field,column-1,row)) {
                    q:=sample(field,xf,column,row+1)
                    if everywhere || math.aabb_overlaps({vmin(p,q),vmax(p,q)},region) {debug_line(out,p,q,kind)}
                }
            }
        }
    }
}
