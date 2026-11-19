package shapes

import "core:math"
import "core:math/linalg"
import "mirai:std/geom"
import mm "mirai:std/math"

// A Bend lays the mesh of its entity along a cubic Hermite segment. Each
// point of the mesh goes to where the curve is at the share of the mesh along
// forward it is at, out from the curve by how far it is from the forward axis
// of the mesh: along the right of the curve as much as it is along the right
// of the mesh (forward × mesh_up), along the up of the curve as much as along
// mesh_up. The right of the curve is its direction × up and its up is right ×
// direction; roll turns both around the curve, scale stretches them and
// offset moves the curve along them. Normals follow the derivative of that
// map, so a mesh that stretches, rolls or turns still lights as its surface
// faces. The drawn mesh and its collision bend alike on a child, made again
// only when the Bend or what the entity shows changes.

Bend_Axis :: enum u8 {X,Y,Z,Negative_X,Negative_Y,Negative_Z}

@(component,description="Bends the mesh of this entity along a curve from start to end, with the tangents of both ends, and rolls, scales and moves it across the curve from the start values to the end ones. A child draws the bent mesh and, when the entity has a Collider of kind External, collides with it.")
Bend :: struct {
    start:[3]f32 `mirai:"unit=m"`,         // in the space of the entity
    start_tangent:[3]f32 `mirai:"unit=m"`, // how fast the curve leaves start, over the whole segment
    end:[3]f32 `mirai:"unit=m"`,
    end_tangent:[3]f32 `mirai:"unit=m"`,
    up:[3]f32,                             // what the up of the curve turns to, in the space of the entity; 0: +Y
    start_roll:f32 `mirai:"unit=rad"`,     // around the curve
    end_roll:f32 `mirai:"unit=rad"`,
    start_scale:[2]f32,                    // across the curve: along its right and along its up
    end_scale:[2]f32,
    start_offset:[2]f32 `mirai:"unit=m"`,  // of the curve: along its right and along its up
    end_offset:[2]f32 `mirai:"unit=m"`,
    forward:Bend_Axis,                     // of the mesh: what runs along the curve
    mesh_up:Bend_Axis,                     // of the mesh: what goes along the up of the curve; across forward
    smooth:bool,                           // roll, scale and offset ease out of start and into end instead of changing evenly
    range:[2]f32 `mirai:"unit=m"`,         // of the mesh along forward: where the curve starts and where it ends; equal: the bounds of the mesh
}

// A straight metre along -Z, the front of the mesh at the end.
BEND_DEFAULT :: Bend{
    end={0,0,-1},start_tangent={0,0,-1},end_tangent={0,0,-1},up={0,1,0},
    start_scale={1,1},end_scale={1,1},forward=.Negative_Z,mesh_up=.Y,
}

// Past this share of the curve a range wider than the mesh stops reaching.
@(private) BEND_REACH :: 4

// The curve of a Bend over a mesh: the axes of the mesh, where along forward
// the curve starts and how long it is (span 0: the whole mesh at start), and
// the shares of the curve past which it goes straight on along its tangent.
@(private)
Bend_Curve :: struct {
    bend:Bend,
    up:[3]f32,
    forward,right,mesh_up:[3]f32,
    low,span:f32,
    first,last:f32,
}

// The curve at a share of it: where it is, and its right and up rolled and scaled.
@(private)
Bend_Slice :: struct {origin,right,up:[3]f32}

@(private)
axis_of :: proc "contextless" (a:Bend_Axis) -> (v:[3]f32) {
    v[int(a)%3]=int(a)<3?1:-1
    return
}

bend_valid :: proc "contextless" (b:Bend) -> bool {
    if b.forward>max(Bend_Axis) || b.mesh_up>max(Bend_Axis) || int(b.forward)%3==int(b.mesh_up)%3 {return false}
    values:=[?]f32{
        b.start.x,b.start.y,b.start.z,b.start_tangent.x,b.start_tangent.y,b.start_tangent.z,
        b.end.x,b.end.y,b.end.z,b.end_tangent.x,b.end_tangent.y,b.end_tangent.z,b.up.x,b.up.y,b.up.z,
        b.start_roll,b.end_roll,b.start_scale.x,b.start_scale.y,b.end_scale.x,b.end_scale.y,
        b.start_offset.x,b.start_offset.y,b.end_offset.x,b.end_offset.y,b.range.x,b.range.y,
    }
    for v in values {if v-v!=0 || abs(v)>1e9 {return false}}
    return true
}

@(private)
hermite_point :: proc "contextless" (b:^Bend,a:f32) -> [3]f32 {
    a2:=a*a
    a3:=a2*a
    return (2*a3-3*a2+1)*b.start+(a3-2*a2+a)*b.start_tangent+(a3-a2)*b.end_tangent+(3*a2-2*a3)*b.end
}

@(private)
hermite_tangent :: proc "contextless" (b:^Bend,a:f32) -> [3]f32 {
    c:=6*b.start+3*b.start_tangent+3*b.end_tangent-6*b.end
    d:=-6*b.start-4*b.start_tangent-2*b.end_tangent+6*b.end
    return c*(a*a)+d*a+b.start_tangent
}

@(private)
bend_slice :: proc "contextless" (c:^Bend_Curve,a:f32) -> Bend_Slice {
    b:=&c.bend
    eased:=b.smooth?mm.smoothstep(0,1,a):a
    position,direction:[3]f32
    switch {
    case a<c.first:
        direction=hermite_tangent(b,c.first)
        position=hermite_point(b,c.first)+direction*(a-c.first)
    case a>c.last:
        direction=hermite_tangent(b,c.last)
        position=hermite_point(b,c.last)+direction*(a-c.last)
    case:
        direction=hermite_tangent(b,a)
        position=hermite_point(b,a)
    }
    direction=linalg.normalize0(direction)
    right:=linalg.normalize0(linalg.cross(direction,c.up))
    up:=linalg.normalize0(linalg.cross(right,direction))
    offset:=linalg.lerp(b.start_offset,b.end_offset,eased)
    position+=offset.x*right+offset.y*up
    roll:=math.lerp(b.start_roll,b.end_roll,eased)
    cos,sin:=math.cos(roll),math.sin(roll)
    scale:=linalg.lerp(b.start_scale,b.end_scale,eased)
    return {position,(cos*right-sin*up)*scale.x,(cos*up+sin*right)*scale.y}
}

// The curve of b over a mesh that spans from low to high along its forward.
@(private)
bend_curve :: proc "contextless" (b:Bend,low,high:f32) -> (c:Bend_Curve) {
    c.bend=b
    c.up=linalg.normalize0(b.up)
    if c.up=={} {c.up={0,1,0}}
    c.forward,c.mesh_up=axis_of(b.forward),axis_of(b.mesh_up)
    c.right=linalg.cross(c.forward,c.mesh_up)
    c.first,c.last=0,1
    if abs(b.range.y-b.range.x)>1e-8 {
        c.low,c.span=b.range.x,b.range.y-b.range.x
        c.first=max(-BEND_REACH,(low-c.low)/c.span)
        c.last=min((high-c.low)/c.span,BEND_REACH)
    } else if high-low>1e-8 {
        c.low,c.span=low,high-low
    } else {
        c.low=low
    }
    return
}

// Where the point p of a mesh with these bounds goes, in the space of the
// entity, with b valid.
bend_place :: proc "contextless" (b:Bend,bounds:mm.Aabb,p:[3]f32) -> [3]f32 {
    forward:=axis_of(b.forward)
    ends:=[2]f32{linalg.dot(bounds.min,forward),linalg.dot(bounds.max,forward)}
    c:=bend_curve(b,min(ends.x,ends.y),max(ends.x,ends.y))
    moved,_:=bend_point(&c,p)
    return moved
}

// Where the point p of the mesh goes, and the determinant of the map there:
// negative where the bend mirrors the mesh.
@(private)
bend_point :: proc "contextless" (c:^Bend_Curve,p:[3]f32,normal:^[3]f32=nil) -> (moved:[3]f32,det:f32) {
    along,across,lift:=linalg.dot(p,c.forward),linalg.dot(p,c.right),linalg.dot(p,c.mesh_up)
    a:=c.span!=0?(along-c.low)/c.span:0
    here:=bend_slice(c,a)
    moved=here.origin+here.right*across+here.up*lift
    // How the map stretches each axis of the mesh: right, up and back (-forward), a frame like X, Y, Z.
    step::f32(1e-3)
    ahead,behind:=bend_slice(c,a+step),bend_slice(c,a-step)
    forward:[3]f32
    if c.span!=0 {
        forward=((ahead.origin+ahead.right*across+ahead.up*lift)-(behind.origin+behind.right*across+behind.up*lift))/(2*step*c.span)
    }
    jr,ju,jb:=here.right,here.up,-forward
    det=linalg.dot(jr,linalg.cross(ju,jb))
    if normal!=nil {
        n:=normal^
        bent:=linalg.dot(n,c.right)*linalg.cross(ju,jb)+linalg.dot(n,c.mesh_up)*linalg.cross(jb,jr)-linalg.dot(n,c.forward)*linalg.cross(jr,ju)
        if det<0 {bent=-bent}
        if length:=linalg.length(bent);length>1e-12 && length==length {normal^=bent/length}
    }
    return
}

// Bends the drawn mesh of g, and what collides (g.collision) when it has
// triangles, in place: positions and normals, with every triangle the bend
// mirrors wound the other way so it faces out.
bend_build :: proc(b:^Bend,g:^Shape_Geometry) -> Shape_Error {
    if !bend_valid(b^) {return .Invalid}
    mesh:=&g.mesh
    if len(mesh.indices)<3 || len(mesh.normals)!=len(mesh.positions) {return .Empty}
    forward:=axis_of(b.forward)
    low,high:=max(f32),-max(f32)
    for p in mesh.positions {
        along:=linalg.dot(p,forward)
        low,high=min(low,along),max(high,along)
    }
    c:=bend_curve(b^,low,high)
    if resize(&g.mirrored,max(len(mesh.positions),len(g.collision.positions)))!=nil {return .Out_Of_Memory}
    for &p,i in mesh.positions {
        det:f32
        p,det=bend_point(&c,p,&mesh.normals[i])
        g.mirrored[i]=det<0
    }
    rewind(g.mirrored[:],mesh.indices[:])
    for &p,i in g.collision.positions {
        det:f32
        p,det=bend_point(&c,p)
        g.mirrored[i]=det<0
    }
    rewind(g.mirrored[:],g.collision.indices[:])
    return .None
}

// A triangle most of whose corners the bend mirrors is wound the other way.
@(private)
rewind :: proc(mirrored:[]bool,indices:[]u32) {
    for t:=0;t+2<len(indices);t+=3 {
        corners:=indices[t:t+3]
        if int(mirrored[corners[0]])+int(mirrored[corners[1]])+int(mirrored[corners[2]])>=2 {corners[1],corners[2]=corners[2],corners[1]}
    }
}
