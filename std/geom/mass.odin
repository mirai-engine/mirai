package geom

Mass_Properties :: struct {
    volume: f32,  // negative when the triangles face inwards
    center: Vec3, // center of mass
    inertia:Mat3, // about the center of mass, for density 1
}

@(private) Mass_Sums :: struct {
    origin:     DVec3,
    volume:     f64, // six times the volume
    first:      DVec3,
    xx,yy,zz:   f64,
    xy,xz,yz:   f64,
}

// Adds the tetrahedron between the origin of the sums and a triangle.
@(private) mass_add :: #force_inline proc "contextless" (s:^Mass_Sums,pa,pb,pc:DVec3) {
    a,b,c:=pa-s.origin,pb-s.origin,pc-s.origin
    det:=ddot(a,dcross(b,c))
    sum:=a+b+c
    s.volume+=det
    s.first+=det*sum
    s.xx+=det*(a.x*a.x+b.x*b.x+c.x*c.x+sum.x*sum.x)
    s.yy+=det*(a.y*a.y+b.y*b.y+c.y*c.y+sum.y*sum.y)
    s.zz+=det*(a.z*a.z+b.z*b.z+c.z*c.z+sum.z*sum.z)
    s.xy+=det*(a.x*a.y+b.x*b.y+c.x*c.y+sum.x*sum.y)
    s.xz+=det*(a.x*a.z+b.x*b.z+c.x*c.z+sum.x*sum.z)
    s.yz+=det*(a.y*a.z+b.y*b.z+c.y*c.z+sum.y*sum.z)
}

@(private) mass_finish :: proc "contextless" (s:Mass_Sums) -> (out:Mass_Properties) {
    volume:=s.volume/6
    out.volume=f32(volume)
    out.center=fvec(s.origin)
    if volume==0 {return}
    c:=s.first/(24*volume)
    out.center=fvec(s.origin+c)
    sign:=f64(1) if volume>0 else -1
    xx:=sign*(s.xx/120-volume*c.x*c.x)
    yy:=sign*(s.yy/120-volume*c.y*c.y)
    zz:=sign*(s.zz/120-volume*c.z*c.z)
    xy:=sign*(s.xy/120-volume*c.x*c.y)
    xz:=sign*(s.xz/120-volume*c.x*c.z)
    yz:=sign*(s.yz/120-volume*c.y*c.z)
    out.inertia=Mat3{
        f32(yy+zz),f32(-xy),f32(-xz),
        f32(-xy),f32(xx+zz),f32(-yz),
        f32(-xz),f32(-yz),f32(xx+yy),
    }
    return
}

// Volume, center of mass and inertia tensor of the solid bounded by a closed
// triangle mesh with outward counter-clockwise triangles.
// A triangle with an index out of range does not count.
mesh_mass_properties :: proc(positions:[]Vec3,indices:[]u32) -> Mass_Properties {
    lo,hi:=mesh_bounds(positions)
    sums:=Mass_Sums{origin=(dvec(lo)+dvec(hi))*0.5}
    for t:=0;t+2<len(indices);t+=3 {
        if !triangle_in(indices,t,len(positions)) {continue}
        mass_add(&sums,dvec(positions[indices[t]]),dvec(positions[indices[t+1]]),dvec(positions[indices[t+2]]))
    }
    return mass_finish(sums)
}

mesh_volume :: proc(positions:[]Vec3,indices:[]u32) -> f32 {
    return mesh_mass_properties(positions,indices).volume
}

mesh_area :: proc(positions:[]Vec3,indices:[]u32) -> f32 {
    area:f64
    for t:=0;t+2<len(indices);t+=3 {
        if !triangle_in(indices,t,len(positions)) {continue}
        a:=dvec(positions[indices[t]])
        area+=dlength(dcross(dvec(positions[indices[t+1]])-a,dvec(positions[indices[t+2]])-a))
    }
    return f32(area*0.5)
}
