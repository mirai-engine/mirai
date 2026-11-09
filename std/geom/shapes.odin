package geom

import "base:runtime"
import "core:math/linalg"

// Shapes made from code for props, on the same Mesh_Buffer as the built-in
// primitives: several calls append to one buffer, and the buffer is the whole
// mesh, parts merged. Each writes its positions, normals, texture coordinates
// and indices; mesh_buffer_paint then colors what the last parts left without
// color.

// Colors the vertices of the buffer that have no color yet: what was built
// since the last paint. Colors keep the rest of a Mesh; a part never painted
// is white when the mesh is written.
mesh_buffer_paint :: proc(b:^Mesh_Buffer,color:Vec4) {
    for len(b.colors)<len(b.positions) {append(&b.colors,color)}
}

// Moves the vertices of a part from first on: scales them, turns them around
// Y (turns: 1 is a full turn), then moves them to at.
mesh_buffer_place :: proc(b:^Mesh_Buffer,first:int,at:Vec3,turn:f32=0,size:Vec3={1,1,1}) {
    s,c:=turn_sincos(f64(turn))
    spin :: #force_inline proc "contextless" (v:Vec3,s,c:f64) -> Vec3 {
        return {f32(f64(v.x)*c-f64(v.z)*s),v.y,f32(f64(v.x)*s+f64(v.z)*c)}
    }
    for &p in b.positions[first:] {p=spin(p*size,s,c)+at}
    for &n in b.normals[first:] {n=fnormalize(spin(n/size,s,c),n)}
}

// Gives every triangle of the buffer its own vertices with the normal of the
// face, for a look of cut facets; its color and texture coordinates stay.
mesh_buffer_flatten :: proc(b:^Mesh_Buffer) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=temp_is(b.positions.allocator))
    scratch:=context.temp_allocator
    count:=len(b.indices)
    positions:=make([]Vec3,count,scratch)
    normals:=make([]Vec3,count,scratch)
    uvs:=make([]Vec2,len(b.uvs)>0?count:0,scratch)
    colored:=len(b.colors)==len(b.positions) && len(b.colors)>0
    colors:=make([]Vec4,colored?count:0,scratch)
    if count>0 && (positions==nil || normals==nil) {return}
    for t:=0;t+2<count;t+=3 {
        a,c,d:=b.indices[t],b.indices[t+1],b.indices[t+2]
        n:=fnormalize(linalg.cross(b.positions[c]-b.positions[a],b.positions[d]-b.positions[a]),b.normals[a])
        for corner,k in ([3]u32{a,c,d}) {
            positions[t+k],normals[t+k]=b.positions[corner],n
            if len(uvs)>0 {uvs[t+k]=b.uvs[corner]}
            if colored {colors[t+k]=b.colors[corner]}
        }
    }
    clear(&b.positions);clear(&b.normals);clear(&b.uvs);clear(&b.colors);clear(&b.indices)
    append(&b.positions,..positions)
    append(&b.normals,..normals)
    append(&b.uvs,..uvs)
    append(&b.colors,..colors)
    for i in 0..<u32(count) {append(&b.indices,i)}
}

// A tube along a path, as a trunk or a branch: rings around a curve through
// its points, tapering from radius[0] at the first to radius[1] at the last,
// closed at both ends. rings: the lengths of the curve.
tube_build :: proc(out:^Mesh_Buffer,path:[]Vec3,radius:Vec2={0.25,0.12},sides:=6,rings:=8) {
    if len(path)<2 {return}
    sides,rings:=max(sides,3),max(rings,1)
    base:=u32(len(out.positions))
    tangent_at :: proc(path:[]Vec3,t:f32) -> Vec3 {
        step:=f32(0.001)
        return fnormalize(curve_point(path,min(t+step,1))-curve_point(path,max(t-step,0)),{0,1,0})
    }
    tangent:=tangent_at(path,0)
    across:=abs(tangent.y)<0.9?Vec3{0,1,0}:Vec3{1,0,0}
    across=fnormalize(linalg.cross(tangent,across),{1,0,0})
    for ring in 0..=rings {
        t:=f32(ring)/f32(rings)
        center:=curve_point(path,t)
        tangent=tangent_at(path,t)
        across=fnormalize(across-tangent*linalg.dot(across,tangent),across)
        side:=linalg.cross(tangent,across)
        r:=radius[0]+(radius[1]-radius[0])*t
        for i in 0..=sides {
            sn,cs:=turn_sincos(f64(i)/f64(sides))
            normal:=across*f32(cs)+side*f32(sn)
            shape_vertex(out,center+normal*r,normal,{f32(i)/f32(sides),t})
        }
    }
    row:=u32(sides+1)
    for ring in 0..<u32(rings) {
        for i in 0..<u32(sides) {
            a:=base+ring*row+i
            b:=a+row
            shape_quad(out,a,b,b+1,a+1)
        }
    }
    shape_cap(out,base,sides,-tangent_at(path,0))
    shape_cap(out,base+u32(rings)*row,sides,tangent_at(path,1))
}

// A solid of revolution around Y, as a jar, a post or a mushroom: each point
// of profile is a radius and a height, in order along the outline. Where it
// ends away from the axis a flat disc closes it.
lathe_build :: proc(out:^Mesh_Buffer,profile:[]Vec2,segments:=SHAPE_SEGMENTS) {
    if len(profile)<2 {return}
    segments:=max(segments,3)
    base:=u32(len(out.positions))
    for p,at in profile {
        before,after:=profile[max(at-1,0)],profile[min(at+1,len(profile)-1)]
        along:=after-before
        rim:=fnormalize(Vec3{along.y,-along.x,0},{1,0,0})
        for i in 0..=segments {
            sn,cs:=turn_sincos(f64(i)/f64(segments))
            around:=Vec3{f32(cs),0,f32(sn)}
            shape_vertex(out,around*p.x+{0,p.y,0},around*rim.x+{0,rim.y,0},{f32(i)/f32(segments),f32(at)/f32(len(profile)-1)})
        }
    }
    row:=u32(segments+1)
    for span in 0..<u32(len(profile)-1) {
        for i in 0..<u32(segments) {
            a:=base+span*row+i
            b:=a+row
            shape_quad(out,a,b,b+1,a+1)
        }
    }
    if profile[0].x>0 {shape_cap(out,base,segments,{0,profile[0].y<=profile[1].y?-1:1,0})}
    last:=len(profile)-1
    if profile[last].x>0 {shape_cap(out,base+u32(last)*row,segments,{0,profile[last].y>=profile[last-1].y?1:-1,0})}
}

// A flat outline extruded along Z, as a sign or a plank: outline is a closed
// polygon of X and Y; the solid goes from z=-depth/2 to z=depth/2.
extrude_build :: proc(out:^Mesh_Buffer,outline:[]Vec2,depth:f32) {
    if len(outline)<3 {return}
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore=temp_is(out.positions.allocator))
    triangles:=make([dynamic]u32,context.temp_allocator)
    sizes:=[1]int{len(outline)}
    if polygon_triangulate(outline,sizes[:],&triangles)==0 {return}
    half:=depth/2
    for face in 0..<2 {
        z:=face==0?half:-half
        n:=Vec3{0,0,face==0?1:-1}
        base:=u32(len(out.positions))
        for p in outline {shape_vertex(out,{p.x,p.y,z},n,p)}
        for t:=0;t+2<len(triangles);t+=3 {shape_triangle(out,base+triangles[t],base+triangles[t+1],base+triangles[t+2])}
    }
    // The outline may run either way: outward is to its right when it turns left.
    area:=f64(0)
    for a,i in outline {
        b:=outline[(i+1)%len(outline)]
        area+=f64(a.x)*f64(b.y)-f64(b.x)*f64(a.y)
    }
    outward:=f32(1) if area>0 else f32(-1)
    for a,i in outline {
        b:=outline[(i+1)%len(outline)]
        edge:=fnormalize(Vec3{b.y-a.y,a.x-b.x,0}*outward,{0,1,0})
        base:=u32(len(out.positions))
        shape_vertex(out,{a.x,a.y,-half},edge,{0,0})
        shape_vertex(out,{a.x,a.y,half},edge,{0,1})
        shape_vertex(out,{b.x,b.y,half},edge,{1,1})
        shape_vertex(out,{b.x,b.y,-half},edge,{1,0})
        shape_quad(out,base,base+1,base+2,base+3)
    }
}

// A leaf or a blade of grass, a thin sheet with both faces that goes from
// root along direction and curves in the vertical.
Blade :: struct {
    length,width:f32,
    rise,droop:f32, // metres up at the tip, and metres the curve falls back by the tip
    belly:f32,      // where along it it is widest, from 0 (at the root) to 1 (at the tip)
    fold:f32,       // metres the edges fall below the middle of the leaf
    segments:int,   // along it; 0: 6
}

blade_build :: proc(out:^Mesh_Buffer,root,direction:Vec3,blade:Blade) {
    segments:=max(blade.segments,1)
    if blade.segments==0 {segments=6}
    forward:=fnormalize(direction,{0,0,1})
    right:=abs(forward.y)<0.99?fnormalize(linalg.cross(Vec3{0,1,0},forward),{1,0,0}):Vec3{1,0,0}
    belly:=clamp(blade.belly,0,1)
    width_at :: proc(t,belly:f32) -> f32 {return t<belly?t/belly:(1-t)/max(1-belly,1e-4)}
    center_at :: proc(root,forward:Vec3,blade:Blade,t:f32) -> Vec3 {return root+forward*(blade.length*t)+{0,blade.rise*t-blade.droop*t*t,0}}
    base:=u32(len(out.positions))
    for face in 0..<2 {
        lit:=f32(1) if face==0 else f32(-1)
        for segment in 0..=segments {
            t:=f32(segment)/f32(segments)
            center:=center_at(root,forward,blade,t)
            along:=center_at(root,forward,blade,min(t+0.02,1))-center_at(root,forward,blade,max(t-0.02,0))
            normal:=fnormalize(linalg.cross(along,right),{0,1,0})*lit
            halfwidth:=blade.width*width_at(t,belly)*0.5
            shape_vertex(out,center-right*halfwidth-{0,blade.fold,0},normal,{0,t})
            shape_vertex(out,center+right*halfwidth-{0,blade.fold,0},normal,{1,t})
        }
    }
    row:=u32(segments+1)
    for face in 0..<u32(2) {
        for segment in 0..<u32(segments) {
            a:=base+face*2*row+segment*2
            shape_quad(out,a,a+2,a+3,a+1)
        }
    }
}

// count blades around root, evenly turned around Y and each a little different
// as seed says: a palm crown, a grass tuft. splay: 0 straight up, 1 level.
fan_build :: proc(out:^Mesh_Buffer,root:Vec3,count:int,blade:Blade,splay:f32=1,seed:u32=0) {
    for i in 0..<count {
        turn:=(f64(i)+f64(shape_random(seed,i,0))*0.5)/f64(count)
        sn,cs:=turn_sincos(turn)
        grown:=blade
        grown.length*=0.8+0.4*shape_random(seed,i,1)
        grown.droop*=0.75+0.5*shape_random(seed,i,2)
        blade_build(out,root,{f32(cs)*splay,1-splay,f32(sn)*splay},grown)
    }
}

// A lumpy ball, as a rock or a bush: an icosphere whose surface moves in and
// out by lumps (a share of its radius) in a pattern seed picks. radius per axis.
blob_build :: proc(out:^Mesh_Buffer,radius:Vec3={0.5,0.5,0.5},subdivisions:=1,lumps:f32=0.25,seed:u32=0) {
    first:=len(out.positions)
    icosphere_build(out,1,subdivisions)
    for &p,i in out.positions[first:] {
        unit:=fnormalize(p,{0,1,0})
        r:=1+lumps*(shape_noise(unit*2.5,seed)*2-1)
        p=unit*r*radius
        out.normals[first+i]=fnormalize(unit/radius,unit)
    }
}

// The point of a curve through its points at t, from 0 at the first to 1 at
// the last: Catmull-Rom with the first and last doubled.
@(private)
curve_point :: proc(path:[]Vec3,t:f32) -> Vec3 {
    spans:=len(path)-1
    position:=clamp(t,0,1)*f32(spans)
    at:=min(int(position),spans-1)
    s:=position-f32(at)
    p0,p1,p2,p3:=path[max(at-1,0)],path[at],path[at+1],path[min(at+2,spans)]
    a:=(p2-p0)*0.5
    b:=(p3-p1)*0.5
    return (p1*2-p2*2+a+b)*(s*s*s)+(p2*3-p1*3-a*2-b)*(s*s)+a*s+p1
}

@(private="file") shape_vertex :: #force_inline proc(out:^Mesh_Buffer,position,normal:Vec3,uv:Vec2) {
    append(&out.positions,position)
    append(&out.normals,normal)
    append(&out.uvs,uv)
}

// A triangle that faces where its normals do; one with a repeated position is dropped.
@(private="file") shape_triangle :: proc(out:^Mesh_Buffer,a,b,c:u32) {
    pa,pb,pc:=out.positions[a],out.positions[b],out.positions[c]
    if pa==pb || pb==pc || pa==pc {return}
    n:=dcross(dvec(pb)-dvec(pa),dvec(pc)-dvec(pa))
    if ddot(n,dvec(out.normals[a])+dvec(out.normals[b])+dvec(out.normals[c]))<0 {append(&out.indices,a,c,b)} else {append(&out.indices,a,b,c)}
}

@(private="file") shape_quad :: proc(out:^Mesh_Buffer,a,b,c,d:u32) {
    shape_triangle(out,a,b,c)
    shape_triangle(out,a,c,d)
}

// A flat disc over the ring of sides+1 vertices at first, facing n.
@(private="file") shape_cap :: proc(out:^Mesh_Buffer,first:u32,sides:int,n:Vec3) {
    center:Vec3
    for i in 0..<u32(sides) {center+=out.positions[first+i]}
    center/=f32(sides)
    base:=u32(len(out.positions))
    for i in 0..<u32(sides) {shape_vertex(out,out.positions[first+i],n,{0.5,0.5})}
    shape_vertex(out,center,n,{0.5,0.5})
    for i in 0..<u32(sides) {shape_triangle(out,base+u32(sides),base+i,base+(i+1)%u32(sides))}
}

// A number from 0 to 1 for a blade and what it changes of it.
@(private="file") shape_random :: proc "contextless" (seed:u32,i,what:int) -> f32 {
    return f32(shape_hash(seed,[3]i32{i32(i),i32(what),0x6d})&0xffff)/0xffff
}

@(private="file") shape_hash :: proc "contextless" (seed:u32,p:[3]i32) -> u32 {
    h:=seed*0x9e3779b1+0x85ebca6b
    for v in p {
        h~=u32(v)*0xc2b2ae35
        h=(h<<13|h>>19)*5+0xe6546b64
    }
    h~=h>>16
    h*=0x85ebca6b
    h~=h>>13
    return h
}

// Value noise of a point, from 0 to 1, deterministic on every machine.
@(private="file") shape_noise :: proc(p:Vec3,seed:u32) -> f32 {
    floor :: proc "contextless" (v:f32) -> i32 {i:=i32(v);return i-1 if f32(i)>v else i}
    cell:=[3]i32{floor(p.x),floor(p.y),floor(p.z)}
    t:=p-{f32(cell.x),f32(cell.y),f32(cell.z)}
    fade :: proc "contextless" (v:f32) -> f32 {return v*v*(3-2*v)}
    u:=Vec3{fade(t.x),fade(t.y),fade(t.z)}
    value :: proc "contextless" (seed:u32,c:[3]i32) -> f32 {return f32(shape_hash(seed,c)&0xffff)/0xffff}
    lerp1 :: proc "contextless" (a,b,t:f32) -> f32 {return a+(b-a)*t}
    v:[8]f32
    for k in 0..<8 {v[k]=value(seed,cell+{i32(k&1),i32(k>>1&1),i32(k>>2&1)})}
    x0:=lerp1(lerp1(v[0],v[1],u.x),lerp1(v[2],v[3],u.x),u.y)
    x1:=lerp1(lerp1(v[4],v[5],u.x),lerp1(v[6],v[7],u.x),u.y)
    return lerp1(x0,x1,u.z)
}
