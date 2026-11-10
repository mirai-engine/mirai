package shapes

import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:testing"
import "mirai:std/geom"
import mm "mirai:std/math"

// A brush of the given full size at a point of the frame of its solid.
@(private="file")
brush_at :: proc(kind:Brush_Kind,position,size:[3]f32,op:=geom.Boolean_Op.Union) -> Brush {
    return {kind=kind,op=op,place={position,mm.QUAT_IDENTITY,size}}
}

// Six times the volume the triangles enclose: positive when they face out.
@(private="file")
volume6 :: proc(m:geom.Mesh) -> f64 {
    v:f64
    for i:=0;i<len(m.indices);i+=3 {
        a,b,c:=m.positions[m.indices[i]],m.positions[m.indices[i+1]],m.positions[m.indices[i+2]]
        v+=f64(linalg.dot(a,linalg.cross(b,c)))
    }
    return v
}

// Every triangle faces the way its vertex normals point.
@(private="file")
normals_agree :: proc(m:geom.Mesh) -> bool {
    for i:=0;i<len(m.indices);i+=3 {
        a,b,c:=m.positions[m.indices[i]],m.positions[m.indices[i+1]],m.positions[m.indices[i+2]]
        n:=linalg.cross(b-a,c-a)
        if linalg.length(n)<1e-9 {continue}
        for k in 0..<3 {
            if linalg.dot(n,m.normals[m.indices[i+k]])<=0 {return false}
        }
    }
    return true
}

@(test)
built_shapes_are_closed_and_face_out :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    set:geom.Polygon_Set
    geom.polygon_set_init(&set)
    defer geom.polygon_set_destroy(&set)
    holed:=SHAPE_DEFAULT
    circle:=make([dynamic]geom.Vec2,context.temp_allocator)
    stamp_points(.Circle,{0,0},0.25,0,&circle)
    testing.expect(t,shape_stamp(&holed,circle[:],.Difference,&set)==.None && holed.loop_count==2)
    reversed:=SHAPE_DEFAULT
    reversed.points[1],reversed.points[3]=reversed.points[3],reversed.points[1]
    solid:=Shape{kind=.Solid,uv_scale=2}
    brushes:=[]Brush{
        brush_at(.Box,{0,0,0},{2,2,2}),
        brush_at(.Sphere,{1,1,1},{1.6,1.6,1.6},.Subtract),
        brush_at(.Cylinder,{0,1.5,0},{0.6,1,0.6}),
    }
    Case :: struct {name:string,shape:Shape,brushes:[]Brush,volume_min,volume_max:f64}
    cases:=[]Case{
        {"square",SHAPE_DEFAULT,nil,1-1e-4,1+1e-4},
        {"clockwise square",reversed,nil,1-1e-4,1+1e-4},
        {"square with a hole",holed,nil,0.75,0.81},
        {"solid with a subtracted sphere and an added cylinder",solid,brushes,7.95,8.05},
        // The polygon is the first brush of its solid.
        {"square and an added box",SHAPE_DEFAULT,{brush_at(.Box,{1,0,0},{1,1,1})},2-1e-3,2+1e-3},
        {"square intersected with a box",SHAPE_DEFAULT,{brush_at(.Box,{0.5,0,0},{1,2,2},.Intersect)},0.5-1e-3,0.5+1e-3},
    }
    g:Shape_Geometry
    shape_geometry_init(&g)
    defer shape_geometry_destroy(&g)
    for &c in cases {
        if !testing.expectf(t,shape_geometry_build(&c.shape,c.brushes,false,&g)==.None,"%s",c.name) {continue}
        m:=geom.mesh_buffer_view(&g.mesh)
        testing.expectf(t,geom.mesh_is_valid(m) && len(m.uvs)==len(m.positions) && len(m.normals)==len(m.positions),"%s: streams",c.name)
        testing.expectf(t,geom.mesh_is_closed(m.positions,m.indices),"%s: closed",c.name)
        testing.expectf(t,normals_agree(m),"%s: normals",c.name)
        volume:=volume6(m)/6
        testing.expectf(t,volume>=c.volume_min && volume<=c.volume_max,"%s: volume %v",c.name,volume)
        // What collides is the same solid, its coplanar seams disabled and its outline edges not.
        collision:=geom.mesh_buffer_view(&g.collision)
        testing.expectf(t,geom.mesh_is_closed(collision.positions,collision.indices),"%s: collision closed",c.name)
        testing.expectf(t,abs(volume6(collision)/6-volume)<1e-3,"%s: collision volume",c.name)
        testing.expect_value(t,len(g.disabled_edges),len(collision.indices)/3)
        disabled,enabled:=0,0
        for mask in g.disabled_edges {
            for k in 0..<3 {if mask&(1<<uint(k))!=0 {disabled+=1} else {enabled+=1}}
        }
        testing.expectf(t,disabled>0 && enabled>0,"%s: %d disabled, %d enabled",c.name,disabled,enabled)
    }
}

@(test)
a_shape_that_cannot_be_built_says_why :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    crossed:=SHAPE_DEFAULT
    crossed.points[1],crossed.points[2]=crossed.points[2],crossed.points[1]
    flat:=SHAPE_DEFAULT
    flat.depth=0
    counts:=SHAPE_DEFAULT
    counts.loops[0]=5
    nan:=SHAPE_DEFAULT
    nan.points[0].x=0/flat.depth
    cuts:=[]Brush{brush_at(.Box,{},{2,2,2},.Subtract),brush_at(.Box,{},{2,2,2},.Intersect)}
    flat_brush:=[]Brush{brush_at(.Box,{},{2,0,2})}
    bevels:[7]Shape
    for &b in bevels {b=SHAPE_DEFAULT;b.bevel=0.1}
    bevels[0].bevel=-0.1
    bevels[1].bevel=0/flat.depth
    bevels[2].bevel_segments=BEVEL_SEGMENTS+1
    bevels[3].bevel_profile,bevels[3].bevel_point_count=.Points,2
    bevels[3].bevel_points[0],bevels[3].bevel_points[1]={0.5,0.5},{0.6,0.7}
    bevels[4].bevel_profile,bevels[4].bevel_point_count=.Points,1
    bevels[4].bevel_points[0]={0.5,1.5}
    bevels[5].bevel_profile,bevels[5].bevel_point_count=.Points,BEVEL_POINTS+1
    bevels[6].bevel_profile=Bevel_Profile(7)
    Case :: struct {name:string,shape:Shape,brushes:[]Brush,error:Shape_Error}
    cases:=[]Case{
        {"crossed",crossed,nil,.Self_Intersecting},
        {"flat",flat,nil,.Invalid},
        {"counts",counts,nil,.Invalid},
        {"not finite",nan,nil,.Invalid},
        {"empty",{},nil,.Empty},
        {"only cuts and intersections",{kind=.Solid},cuts,.Empty},
        {"no brushes",{kind=.Solid},nil,.Empty},
        {"a brush without volume",{kind=.Solid},flat_brush,.Invalid},
        {"negative bevel",bevels[0],nil,.Invalid},
        {"bevel not finite",bevels[1],nil,.Invalid},
        {"too many segments",bevels[2],nil,.Invalid},
        {"bevel points that turn back",bevels[3],nil,.Invalid},
        {"bevel points out of range",bevels[4],nil,.Invalid},
        {"too many bevel points",bevels[5],nil,.Invalid},
        {"no such profile",bevels[6],nil,.Invalid},
    }
    g:Shape_Geometry
    shape_geometry_init(&g)
    defer shape_geometry_destroy(&g)
    for &c in cases {
        error:=shape_geometry_build(&c.shape,c.brushes,true,&g)
        testing.expectf(t,error==c.error,"%s: %v",c.name,error)
        testing.expectf(t,len(g.mesh.indices)==0 && len(g.pieces.sizes)==0,"%s: nothing kept",c.name)
    }
}

@(test)
bodies_are_convex_pieces_that_cover_the_shape :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    l:=SHAPE_DEFAULT
    l.point_count,l.loops[0]=6,6
    l.points[0],l.points[1],l.points[2],l.points[3],l.points[4],l.points[5]={0,0},{2,0},{2,1},{1,1},{1,2},{0,2}
    solid:=Shape{kind=.Solid}
    added:=[]Brush{brush_at(.Box,{},{2,2,2}),brush_at(.Sphere,{1,1,0},{1,1,1})}
    cut:=[]Brush{added[0],added[1],brush_at(.Box,{0,0,1},{1,1,1},.Subtract)}
    Case :: struct {name:string,shape:Shape,brushes:[]Brush,pieces:int}
    cases:=[]Case{{"L polygon",l,nil,2},{"brushes",solid,added,2},{"subtracted",solid,cut,2},{"L polygon and a box",l,{brush_at(.Box,{3,0,0},{1,1,1})},3}}
    g:Shape_Geometry
    shape_geometry_init(&g)
    defer shape_geometry_destroy(&g)
    for &c in cases {
        if !testing.expectf(t,shape_geometry_build(&c.shape,c.brushes,true,&g)==.None,"%s",c.name) {continue}
        testing.expectf(t,len(g.pieces.sizes)>=c.pieces,"%s: %d pieces",c.name,len(g.pieces.sizes))
        total:=0
        for size in g.pieces.sizes {
            testing.expectf(t,size>=4,"%s: a piece of %d points",c.name,size)
            total+=int(size)
        }
        testing.expect_value(t,total,len(g.pieces.points))
        // Every vertex of the mesh is in some piece.
        lo,hi:=geom.mesh_bounds(g.mesh.positions[:])
        plo,phi:=geom.mesh_bounds(g.pieces.points[:])
        testing.expectf(t,linalg.length(plo-lo)<0.05 && linalg.length(phi-hi)<0.05,"%s: bounds",c.name)
    }
}

@(test)
sides_share_normals_where_the_outline_turns_little :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    set:geom.Polygon_Set
    geom.polygon_set_init(&set)
    defer geom.polygon_set_destroy(&set)
    circle:=make([dynamic]geom.Vec2,context.temp_allocator)
    stamp_points(.Circle,{0,0},1,0,&circle)
    round:=SHAPE_DEFAULT
    testing.expect(t,shape_stamp(&round,circle[:],.Union,&set)==.None)
    g:Shape_Geometry
    shape_geometry_init(&g)
    defer shape_geometry_destroy(&g)
    for c in ([2]struct {shape:Shape,smooth:bool}{{SHAPE_DEFAULT,false},{round,true}}) {
        shape:=c.shape
        if !testing.expect(t,shape_geometry_build(&shape,nil,false,&g)==.None) {continue}
        // Side vertices at one place: the same normal when smooth, two when sharp.
        shared,split:=0,0
        m:=&g.mesh
        for i in 0..<len(m.positions) {
            if m.normals[i].z!=0 {continue}
            for j in i+1..<len(m.positions) {
                if m.normals[j].z!=0 || m.positions[j]!=m.positions[i] {continue}
                if linalg.length(m.normals[j]-m.normals[i])<1e-5 {shared+=1} else {split+=1}
            }
        }
        testing.expectf(t,c.smooth?(shared>0 && split==0):(split>0 && shared==0),"smooth %v: %d shared, %d split",c.smooth,shared,split)
    }
}

@(test)
a_side_keeps_its_texture_when_the_outline_grows_elsewhere :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    square:=[4]geom.Vec2{{-1,-1},{1,-1},{1,1},{-1,1}}
    grown:=[4]geom.Vec2{{-3,-1},{1,-1},{1,1},{-3,1}}
    g:Shape_Geometry
    shape_geometry_init(&g)
    defer shape_geometry_destroy(&g)
    Vertex :: struct {position,normal:geom.Vec3,uv:geom.Vec2}
    for bevel in ([2]f32{0,0.2}) {
        before:=make([dynamic]Vertex,context.temp_allocator)
        for points,pass in ([2][4]geom.Vec2{square,grown}) {
            points:=points
            s:=outline_of(points[:])
            s.bevel,s.bevel_profile=bevel,.Round
            if !testing.expect(t,shape_geometry_build(&s,nil,false,&g)==.None) {break}
            m:=&g.mesh
            if pass==0 {
                for p,i in m.positions {if p.x>0.5 {append(&before,Vertex{p,m.normals[i],m.uvs[i]})}}
                continue
            }
            // Every vertex of the right side the edit did not move keeps where its texture is.
            for v in before {
                kept:=false
                for p,i in m.positions {
                    if linalg.length(p-v.position)<1e-5 && linalg.length(m.normals[i]-v.normal)<1e-5 && linalg.length(m.uvs[i]-v.uv)<1e-5 {kept=true;break}
                }
                testing.expectf(t,kept,"bevel %.1f: the vertex at %v with normal %v lost its texture place %v",bevel,v.position,v.normal,v.uv)
                if !kept {break}
            }
        }
    }
}

// An Outline of one loop, one meter deep.
@(private="file")
outline_of :: proc(points:[]geom.Vec2) -> Shape {
    s:=SHAPE_DEFAULT
    s.point_count,s.loops[0]=u16(len(points)),u16(len(points))
    copy(s.points[:],points)
    return s
}

// Twice the signed area of the projection on XY of a triangle.
@(private="file")
area_xy :: proc(m:geom.Mesh,t:int) -> f64 {
    a,b,c:=m.positions[m.indices[t]],m.positions[m.indices[t+1]],m.positions[m.indices[t+2]]
    return f64(b.x-a.x)*f64(c.y-a.y)-f64(b.y-a.y)*f64(c.x-a.x)
}

@(test)
bevels_round_the_rims_without_folding :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    set:geom.Polygon_Set
    geom.polygon_set_init(&set)
    defer geom.polygon_set_destroy(&set)
    stamp:=make([dynamic]geom.Vec2,context.temp_allocator)
    holed:=SHAPE_DEFAULT
    stamp_points(.Square,{-0.22,0},0.12,0,&stamp)
    testing.expect(t,shape_stamp(&holed,stamp[:],.Difference,&set)==.None)
    stamp_points(.Circle,{0.22,0.1},0.1,0,&stamp)
    testing.expect(t,shape_stamp(&holed,stamp[:],.Difference,&set)==.None && holed.loop_count==3)
    stamp_points(.Triangle,{},0.5,0,&stamp)
    triangle:=outline_of(stamp[:])
    stamp_points(.Circle,{},0.5,0,&stamp)
    circle:=outline_of(stamp[:])
    l:=outline_of({{0,0},{2,0},{2,1},{1,1},{1,2},{0,2}})
    thin:=outline_of({{-1,-0.02},{1,-0.02},{1,0.02},{-1,0.02}})
    // A band 3 cm wide along half a circle: no edge is short, the gap across is.
    arc:=make([dynamic]geom.Vec2,context.temp_allocator)
    for i in 0..=16 {
        a:=f32(i)/16*3.14159
        append(&arc,geom.Vec2{0.5*linalg.cos(a),0.5*linalg.sin(a)})
    }
    for i:=16;i>=0;i-=1 {
        a:=f32(i)/16*3.14159
        append(&arc,geom.Vec2{0.47*linalg.cos(a),0.47*linalg.sin(a)})
    }
    band:=outline_of(arc[:])
    shallow:=SHAPE_DEFAULT
    shallow.depth=0.04
    Case :: struct {name:string,shape:Shape}
    shapes:=[]Case{
        {"square with holes",holed},{"triangle",triangle},{"circle",circle},{"L",l},
        {"thin",thin},{"thin band",band},{"shallow",shallow},
    }
    Profile :: struct {profile:Bevel_Profile,segments:u8,points:[]geom.Vec2}
    profiles:=[]Profile{{.Round,0,nil},{.Round,1,nil},{.Chamfer,0,nil},{.Points,0,{{0.4,0.1},{0.1,0.6}}}}
    g:Shape_Geometry
    shape_geometry_init(&g)
    defer shape_geometry_destroy(&g)
    for c in shapes {
        for p in profiles {
            s:=c.shape
            s.bevel,s.bevel_profile,s.bevel_segments=0.1,p.profile,p.segments
            s.bevel_point_count=u8(len(p.points))
            copy(s.bevel_points[:],p.points)
            if !testing.expectf(t,shape_geometry_build(&s,nil,false,&g)==.None,"%s %v",c.name,p.profile) {continue}
            bevel_holds(t,&s,&g,c.name)
        }
    }
    // Stars of random points, sizes and depths: every corner, gap and depth against the bevel.
    state:=rand.create(7)
    context.random_generator=rand.default_random_generator(&state)
    for round in 0..<300 {
        n:=3+rand.int_max(45)
        star:=make([]geom.Vec2,n,context.temp_allocator)
        for &p,i in star {
            a:=2*math.PI*(f32(i)+rand.float32_range(0,0.9))/f32(n)
            r:=rand.float32_range(0.02,1)
            p={r*math.cos(a),r*math.sin(a)}
        }
        s:=outline_of(star)
        s.depth=rand.float32_range(0.01,2)
        s.bevel=rand.float32_range(0.001,0.6)
        s.bevel_profile=Bevel_Profile(rand.int_max(len(Bevel_Profile)))
        s.bevel_segments=u8(rand.int_max(BEVEL_SEGMENTS+1))
        if s.bevel_profile==.Points {s.bevel_point_count,s.bevel_points[0]=1,{0.3,0.3}}
        if error:=shape_geometry_build(&s,nil,false,&g);error!=.None {
            testing.expectf(t,error==.Self_Intersecting,"star %d: %v",round,error)
            continue
        }
        bevel_holds(t,&s,&g,"star")
    }
}

// What a bevel keeps of the mesh it changes: closed, facing its normals, within the prism that collides, and a cap and a band that cover the outline once from the front.
@(private="file")
bevel_holds :: proc(t:^testing.T,s:^Shape,g:^Shape_Geometry,name:string) {
    m:=geom.mesh_buffer_view(&g.mesh)
    testing.expectf(t,geom.mesh_is_valid(m) && len(m.uvs)==len(m.positions) && len(m.normals)==len(m.positions),"%s %v: streams",name,s.bevel_profile)
    testing.expectf(t,geom.mesh_is_closed(m.positions,m.indices),"%s %v: closed",name,s.bevel_profile)
    testing.expectf(t,normals_agree(m),"%s %v: normals",name,s.bevel_profile)
    for n in m.normals {
        if !testing.expectf(t,abs(linalg.length(n)-1)<1e-4,"%s %v: unit normals",name,s.bevel_profile) {break}
    }
    collision:=geom.mesh_buffer_view(&g.collision)
    lo,hi:=geom.mesh_bounds(m.positions)
    clo,chi:=geom.mesh_bounds(collision.positions)
    testing.expectf(t,linalg.length(lo-clo)<1e-6 && linalg.length(hi-chi)<1e-6,"%s %v: bounds %v %v",name,s.bevel_profile,lo,clo)
    prism:=volume6(collision)/6
    volume:=volume6(m)/6
    testing.expectf(t,volume>0 && volume<prism,"%s %v: volume %v of %v",name,s.bevel_profile,volume,prism)
    // No front triangle turns over, and none overlaps another.
    h:=0.5*s.depth
    front,cap:f64
    for i:=0;i<len(m.indices);i+=3 {
        z:=min(m.positions[m.indices[i]].z,m.positions[m.indices[i+1]].z,m.positions[m.indices[i+2]].z)
        if z<=0 {continue}
        a:=area_xy(m,i)
        testing.expectf(t,a>0,"%s %v: a front triangle turns over",name,s.bevel_profile)
        front+=a
        if z==h {cap+=a}
    }
    outline:=prism/f64(s.depth)*2
    testing.expectf(t,abs(front-outline)<1e-4*outline,"%s %v: front %v of %v",name,s.bevel_profile,front,outline)
    testing.expectf(t,cap>0 && cap<outline,"%s %v: cap %v of %v",name,s.bevel_profile,cap,outline)
}

@(test)
a_bevel_is_part_of_the_key_and_zero_builds_none :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    plain:=SHAPE_DEFAULT
    unused:=plain
    unused.bevel_profile,unused.bevel_point_count=.Points,1
    unused.bevel_points[0]={0.5,0.5}
    g,h:Shape_Geometry
    shape_geometry_init(&g)
    defer shape_geometry_destroy(&g)
    shape_geometry_init(&h)
    defer shape_geometry_destroy(&h)
    testing.expect(t,shape_geometry_build(&plain,nil,false,&g)==.None && shape_geometry_build(&unused,nil,false,&h)==.None)
    testing.expect(t,slice_equal(g.mesh.positions[:],h.mesh.positions[:]) && slice_equal(g.mesh.indices[:],h.mesh.indices[:]))
    round:=plain
    round.bevel=0.1
    point:=unused
    point.bevel=0.1
    moved:=point
    moved.bevel_points[0].x=0.4
    keys:=[]u64{shape_key(&plain,nil,false),shape_key(&round,nil,false),shape_key(&point,nil,false),shape_key(&moved,nil,false)}
    for a,i in keys {
        for b in keys[i+1:] {testing.expect(t,a!=b)}
    }
}

@(private="file")
slice_equal :: proc(a,b:[]$T) -> bool {
    if len(a)!=len(b) {return false}
    for x,i in a {if x!=b[i] {return false}}
    return true
}
