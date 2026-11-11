package geom

import "base:runtime"
import "core:math"
import "core:math/linalg"

// Built-in shapes, centered on the origin with +Y up. With their default
// arguments all of them fit the unit cube. Every procedure appends positions,
// normals, texture coordinates and indices to a buffer that holds nothing or
// a mesh with exactly those streams. Flat faces show the whole image; round
// surfaces wrap it once around the Y axis. Angles come from turn_sincos, so
// the vertices are the same bits on every machine. A shape takes the room of
// all it appends first: without memory it appends nothing and answers false.

SHAPE_SEGMENTS :: 32 // around the Y axis
SHAPE_RINGS    :: 16 // latitude bands of the sphere

// Room for the vertices and indices a shape appends at most: its appends
// stay inside it.
@(private) shape_room :: proc(out:^Mesh_Buffer,vertices,indices:int) -> bool {
    return reserve_more(&out.positions,vertices)==nil && reserve_more(&out.normals,vertices)==nil && reserve_more(&out.uvs,vertices)==nil && reserve_more(&out.indices,indices)==nil
}

@(private) vertex :: #force_inline proc(out:^Mesh_Buffer,position,normal:Vec3,uv:Vec2) {
    append(&out.positions,position)
    append(&out.normals,normal)
    append(&out.uvs,uv)
}

// Convex shapes contain the origin: a triangle faces outwards when its normal
// points away from it. Triangles with a repeated position are dropped.
@(private="file") triangle :: proc(out:^Mesh_Buffer,a,b,c:u32) {
    pa,pb,pc:=out.positions[a],out.positions[b],out.positions[c]
    if pa==pb || pb==pc || pa==pc {return}
    n:=dcross(dvec(pb)-dvec(pa),dvec(pc)-dvec(pa))
    if ddot(n,dvec(pa)+dvec(pb)+dvec(pc))<0 {append(&out.indices,a,c,b)} else {append(&out.indices,a,b,c)}
}

// Texture axes of a flat face seen from outside: right is where u grows and
// up is where the top of the image is. Walls keep the world's up.
@(private="file") face_axes :: proc(n:Vec3) -> (right,up:Vec3) {
    up={0,1,0}
    if abs(n.y)>0.999 {up={0,0,-1} if n.y>0 else Vec3{0,0,1}}
    right=linalg.normalize(linalg.cross(up,n))
    up=linalg.cross(n,right)
    return
}

// A flat convex polygon with its own vertices. `points` are corners of the
// unit shape, where the image fills the square around the origin spanned by
// the axes of the face; `size` scales them.
@(private="file") face :: proc(out:^Mesh_Buffer,points:[]Vec3,size:Vec3) {
    unit:=linalg.normalize(linalg.cross(points[1]-points[0],points[2]-points[0]))
    center:Vec3
    for p in points {center+=p}
    if linalg.dot(unit,center)<0 {unit=-unit}
    right,up:=face_axes(unit)
    n:=fnormalize(unit/size,unit)
    base:=u32(len(out.positions))
    for p in points {vertex(out,p*size,n,{linalg.dot(p,right)+0.5,0.5-linalg.dot(p,up)})}
    for i in 1..<len(points)-1 {triangle(out,base,base+u32(i),base+u32(i+1))}
}

// Flat disc of the unit cylinder at height y, scaled to radius and height.
@(private="file") disc :: proc(out:^Mesh_Buffer,y:f32,radius,height:f32,segments:int) {
    n:=Vec3{0,1 if y>0 else -1,0}
    right,up:=face_axes(n)
    center:=u32(len(out.positions))
    vertex(out,{0,y*height,0},n,{0.5,0.5})
    for i in 0..<segments {
        s,c:=turn_sincos(f64(i)/f64(segments))
        p:=Vec3{0.5*f32(c),y,0.5*f32(s)}
        vertex(out,{f32(c)*radius,y*height,f32(s)*radius},n,{linalg.dot(p,right)+0.5,0.5-linalg.dot(p,up)})
    }
    for i in 0..<segments {triangle(out,center,center+1+u32(i),center+1+u32((i+1)%segments))}
}

cube_build :: proc(out:^Mesh_Buffer,size:Vec3={1,1,1}) -> bool {
    shape_room(out,24,36) or_return
    for n in ([6]Vec3{{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}) {
        u:=Vec3{n.y,n.z,n.x}
        w:=linalg.cross(n,u)
        face(out,{(n-u-w)*0.5,(n+u-w)*0.5,(n+u+w)*0.5,(n-u+w)*0.5},size)
    }
    return true
}

// Latitude and longitude sphere: `segments` around the Y axis and `rings`
// from the north pole to the south pole.
sphere_build :: proc(out:^Mesh_Buffer,radius:f32=0.5,segments:=SHAPE_SEGMENTS,rings:=SHAPE_RINGS) -> bool {
    segments,rings:=max(segments,3),max(rings,2)
    shape_room(out,(rings+1)*(segments+1),rings*segments*6) or_return
    base:=u32(len(out.positions))
    for ring in 0..=rings {
        st,ct:=turn_sincos(f64(ring)/f64(2*rings))
        for i in 0..=segments {
            s,c:=turn_sincos(f64(i)/f64(segments))
            n:=Vec3{f32(st*c),f32(ct),f32(st*s)}
            vertex(out,n*radius,n,{1-f32(i)/f32(segments),f32(ring)/f32(rings)})
        }
    }
    row:=u32(segments+1)
    for ring in 0..<u32(rings) {
        for i in 0..<u32(segments) {
            a:=base+ring*row+i
            b:=a+row
            triangle(out,a,b,b+1)
            triangle(out,a,b+1,a+1)
        }
    }
    return true
}

// Subdivided icosahedron: 20*4^subdivisions triangles of similar size.
// Texture coordinates follow the sphere; vertices are repeated along the seam
// and at the poles.
icosphere_build :: proc(out:^Mesh_Buffer,radius:f32=0.5,subdivisions:=2) -> bool {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=temp_is(out.positions.allocator))
    scratch:=context.temp_allocator
    subdivisions:=clamp(subdivisions,0,7)
    points:=make([dynamic]DVec3,0,12,scratch)
    faces:=make([dynamic][3]u32,0,20,scratch)
    // Two poles and two rings of five, a tenth of a turn apart.
    h:=1/math.sqrt(f64(5))
    r:=2*h
    append(&points,DVec3{0,1,0})
    for i in 0..<5 {
        s,c:=turn_sincos(f64(i)/5)
        append(&points,DVec3{r*c,h,r*s})
    }
    for i in 0..<5 {
        s,c:=turn_sincos((f64(i)+0.5)/5)
        append(&points,DVec3{r*c,-h,r*s})
    }
    append(&points,DVec3{0,-1,0})
    for i in 0..<u32(5) {
        j:=(i+1)%5
        append(&faces,[3]u32{0,1+j,1+i},[3]u32{1+i,1+j,6+i},[3]u32{6+i,1+j,6+j},[3]u32{11,6+i,6+j})
    }
    midpoints:Key_Map
    key_map_init(&midpoints,scratch)
    next:=make([dynamic][3]u32,0,80,scratch)
    for _ in 0..<subdivisions {
        // Three edges per face, each shared by two.
        if key_map_reset(&midpoints,len(faces)*2)!=nil {return false}
        clear(&next)
        for f in faces {
            m:[3]u32
            for k in 0..<3 {
                a,b:=f[k],f[(k+1)%3]
                entry,inserted:=key_map_entry(&midpoints,pair_key(min(a,b),max(a,b)),u32(len(points)))
                m[k]=entry^
                if inserted {
                    lo,hi:=points[min(a,b)],points[max(a,b)]
                    append(&points,dnormalize(lo+hi))
                }
            }
            append(&next,[3]u32{f[0],m[0],m[2]},[3]u32{m[0],f[1],m[1]},[3]u32{m[2],m[1],f[2]},[3]u32{m[0],m[1],m[2]})
        }
        faces,next=next,faces
    }
    longitude :: proc(p:DVec3) -> f64 {
        turn:=math.atan2(p.z,p.x)/(2*math.PI)
        return turn+1 if turn<0 else turn
    }
    shape_room(out,3*len(faces),3*len(faces)) or_return
    for f in faces {
        corners:=[3]DVec3{points[f[0]],points[f[1]],points[f[2]]}
        turns:[3]f64
        polar:[3]bool
        low,high:=f64(2),f64(-1)
        for p,k in corners {
            polar[k]=p.x==0 && p.z==0
            if polar[k] {continue}
            turns[k]=longitude(p)
            low=min(low,turns[k]);high=max(high,turns[k])
        }
        // A triangle across the seam takes its small longitudes one turn up; a
        // pole takes the middle of the other two.
        sum,count:=f64(0),0
        for k in 0..<3 {
            if polar[k] {continue}
            if high-low>0.5 && turns[k]<0.5 {turns[k]+=1}
            sum+=turns[k];count+=1
        }
        base:=u32(len(out.positions))
        for p,k in corners {
            if polar[k] {turns[k]=sum/f64(max(count,1))}
            latitude:=math.atan2(math.sqrt(p.x*p.x+p.z*p.z),p.y)/math.PI
            n:=fvec(p)
            vertex(out,n*radius,n,{f32(1-turns[k]),f32(latitude)})
        }
        append(&out.indices,base,base+1,base+2)
    }
    return true
}

cylinder_build :: proc(out:^Mesh_Buffer,radius:f32=0.5,height:f32=1,segments:=SHAPE_SEGMENTS) -> bool {
    segments:=max(segments,3)
    shape_room(out,4*(segments+1),12*segments) or_return
    base:=u32(len(out.positions))
    for i in 0..=segments {
        s,c:=turn_sincos(f64(i)/f64(segments))
        n:=Vec3{f32(c),0,f32(s)}
        u:=1-f32(i)/f32(segments)
        vertex(out,{n.x*radius,-0.5*height,n.z*radius},n,{u,1})
        vertex(out,{n.x*radius,0.5*height,n.z*radius},n,{u,0})
    }
    for i in 0..<u32(segments) {
        a:=base+2*i
        triangle(out,a,a+1,a+3)
        triangle(out,a,a+3,a+2)
    }
    disc(out,0.5,radius,height,segments)
    disc(out,-0.5,radius,height,segments)
    return true
}

// The apex is at +Y. Each side triangle has its own apex vertex, with the
// normal of the middle of the triangle.
cone_build :: proc(out:^Mesh_Buffer,radius:f32=0.5,height:f32=1,segments:=SHAPE_SEGMENTS) -> bool {
    segments:=max(segments,3)
    shape_room(out,4*segments+1,6*segments) or_return
    base:=u32(len(out.positions))
    for i in 0..<segments {
        s0,c0:=turn_sincos(f64(i)/f64(segments))
        s1,c1:=turn_sincos(f64(i+1)/f64(segments))
        sm,cm:=turn_sincos((f64(i)+0.5)/f64(segments))
        u0,u1:=1-f32(i)/f32(segments),1-f32(i+1)/f32(segments)
        up:=Vec3{0,1,0}
        vertex(out,{f32(c0)*radius,-0.5*height,f32(s0)*radius},fnormalize({f32(c0)*height,radius,f32(s0)*height},up),{u0,1})
        vertex(out,{f32(c1)*radius,-0.5*height,f32(s1)*radius},fnormalize({f32(c1)*height,radius,f32(s1)*height},up),{u1,1})
        vertex(out,{0,0.5*height,0},fnormalize({f32(cm)*height,radius,f32(sm)*height},up),{(u0+u1)*0.5,0})
        a:=base+3*u32(i)
        triangle(out,a,a+1,a+2)
    }
    disc(out,-0.5,radius,height,segments)
    return true
}

// Triangular prism: the triangle faces the Z axis, with an edge on top.
prism_build :: proc(out:^Mesh_Buffer,size:Vec3={1,1,1}) -> bool {
    shape_room(out,18,24) or_return
    front:=[3]Vec3{{-0.5,-0.5,0.5},{0.5,-0.5,0.5},{0,0.5,0.5}}
    back:=[3]Vec3{{-0.5,-0.5,-0.5},{0.5,-0.5,-0.5},{0,0.5,-0.5}}
    face(out,front[:],size)
    face(out,back[:],size)
    for i in 0..<3 {
        j:=(i+1)%3
        face(out,{front[i],front[j],back[j],back[i]},size)
    }
    return true
}

// Square pyramid with its apex at +Y.
pyramid_build :: proc(out:^Mesh_Buffer,size:Vec3={1,1,1}) -> bool {
    shape_room(out,16,18) or_return
    apex:=Vec3{0,0.5,0}
    floor:=[4]Vec3{{-0.5,-0.5,-0.5},{0.5,-0.5,-0.5},{0.5,-0.5,0.5},{-0.5,-0.5,0.5}}
    face(out,floor[:],size)
    for i in 0..<4 {face(out,{floor[i],floor[(i+1)%4],apex},size)}
    return true
}

// Cylinder along Y closed by two hemispheres; `height` includes them and is
// at least the diameter. `rings` are the latitude bands of each hemisphere.
// v follows the length of the profile from the north pole to the south pole.
capsule_build :: proc(out:^Mesh_Buffer,radius:f32=0.25,height:f32=1,segments:=SHAPE_SEGMENTS,rings:=SHAPE_RINGS/2) -> bool {
    segments,rings:=max(segments,3),max(rings,1)
    straight:=max(height-2*radius,0)
    profile:=math.PI*f64(radius)+f64(straight)
    base:=u32(len(out.positions))
    rows:=2*rings+2
    shape_room(out,rows*(segments+1),(rows-1)*segments*6) or_return
    for row in 0..<rows {
        south:=row>rings
        ring:=row-1 if south else row
        st,ct:=turn_sincos(f64(ring)/f64(4*rings))
        offset:=-0.5*straight if south else 0.5*straight
        along:=math.PI*f64(radius)*f64(ring)/f64(2*rings)+(f64(straight) if south else 0)
        for i in 0..=segments {
            s,c:=turn_sincos(f64(i)/f64(segments))
            n:=Vec3{f32(st*c),f32(ct),f32(st*s)}
            vertex(out,n*radius+{0,offset,0},n,{1-f32(i)/f32(segments),f32(along/profile) if profile>0 else 0})
        }
    }
    row:=u32(segments+1)
    for r in 0..<u32(rows-1) {
        for i in 0..<u32(segments) {
            a:=base+r*row+i
            b:=a+row
            triangle(out,a,b,b+1)
            triangle(out,a,b+1,a+1)
        }
    }
    return true
}

// Rectangle on the XZ plane that faces +Y, split in columns along X and rows
// along Z. It is the only shape that is not closed.
plane_build :: proc(out:^Mesh_Buffer,size:Vec2={1,1},columns:=1,rows:=1) -> bool {
    columns,rows:=max(columns,1),max(rows,1)
    shape_room(out,(rows+1)*(columns+1),rows*columns*6) or_return
    base:=u32(len(out.positions))
    for r in 0..=rows {
        for c in 0..=columns {
            u,v:=f32(c)/f32(columns),f32(r)/f32(rows)
            vertex(out,{(u-0.5)*size.x,0,(v-0.5)*size.y},{0,1,0},{u,v})
        }
    }
    stride:=u32(columns+1)
    for r in 0..<u32(rows) {
        for c in 0..<u32(columns) {
            a:=base+r*stride+c
            b:=a+stride
            append(&out.indices,a,b,b+1,a,b+1,a+1)
        }
    }
    return true
}

// Ring around the Y axis: `radius` from the axis to the middle of the tube
// and `tube` the radius of the tube. u goes around the axis and v around the
// tube, from its outer equator over the top.
torus_build :: proc(out:^Mesh_Buffer,radius:f32=0.375,tube:f32=0.125,segments:=SHAPE_SEGMENTS,sides:=SHAPE_RINGS) -> bool {
    segments,sides:=max(segments,3),max(sides,3)
    shape_room(out,(segments+1)*(sides+1),segments*sides*6) or_return
    base:=u32(len(out.positions))
    for i in 0..=segments {
        s,c:=turn_sincos(f64(i)/f64(segments))
        for j in 0..=sides {
            st,ct:=turn_sincos(f64(j)/f64(sides))
            n:=Vec3{f32(ct*c),f32(st),f32(ct*s)}
            ring:=f64(radius)+f64(tube)*ct
            vertex(out,{f32(ring*c),tube*f32(st),f32(ring*s)},n,{1-f32(i)/f32(segments),f32(j)/f32(sides)})
        }
    }
    row:=u32(sides+1)
    for i in 0..<u32(segments) {
        for j in 0..<u32(sides) {
            a:=base+i*row+j
            b:=a+row
            append(&out.indices,a,a+1,b+1,a,b+1,b)
        }
    }
    return true
}
