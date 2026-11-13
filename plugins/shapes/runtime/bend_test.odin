package shapes

import "core:math"
import "core:math/linalg"
import "core:testing"
import mm "mirai:std/math"

// A tube of radius 0.1 along Z from 1 to -1, its normals out from the axis.
@(private="file")
tube :: proc(g:^Shape_Geometry,rings:=24,around:=32) {
    shape_geometry_clear(g)
    for i in 0..<rings {
        z:=1-2*f32(i)/f32(rings-1)
        for j in 0..<around {
            angle:=2*math.PI*f32(j)/f32(around)
            out:=[3]f32{math.cos(angle),math.sin(angle),0}
            append(&g.mesh.positions,out*0.1+{0,0,z})
            append(&g.mesh.normals,out)
        }
    }
    for i in 0..<rings-1 {
        for j in 0..<around {
            a,b:=u32(i*around+j),u32((i+1)*around+j)
            c,d:=u32(i*around+(j+1)%around),u32((i+1)*around+(j+1)%around)
            append(&g.mesh.indices,a,b,c,b,d,c)
        }
    }
}

@(private="file")
TUBE_BOUNDS :: mm.Aabb{{-0.1,-0.1,-1},{0.1,0.1,1}}

@(private="file")
near :: proc(a,b:[3]f32) -> bool {return linalg.length(a-b)<1e-3}

@(test)
a_bend_lays_the_mesh_along_its_curve :: proc(t:^testing.T) {
    straight:=BEND_DEFAULT
    straight.end,straight.start_tangent,straight.end_tangent={0,0,-2},{0,0,-2},{0,0,-2}
    // A quarter of a circle of radius 2 in XZ, its tangents those of the Bézier that follows one.
    quarter:=straight
    quarter.end,quarter.start_tangent,quarter.end_tangent={2,0,-2},{0,0,-3.3137},{3.3137,0,0}
    rolled:=straight
    rolled.end_roll,rolled.end_scale=math.PI/2,{2,0.5}
    moved:=straight
    moved.start_offset={0.5,0.25}
    ranged:=straight
    ranged.end,ranged.start_tangent,ranged.end_tangent,ranged.range={0,0,-4},{0,0,-4},{0,0,-4},{-2,2}
    sideways:=straight
    sideways.forward,sideways.mesh_up=.X,.Negative_Z
    Case :: struct {name:string,bend:Bend,bounds:mm.Aabb,from,to:[3]f32}
    cases:=[]Case{
        {"straight: the back of the mesh at start",straight,TUBE_BOUNDS,{0.1,0,1},{0.1,0,0}},
        {"straight: the front at end",straight,TUBE_BOUNDS,{0,0.1,-1},{0,0.1,-2}},
        {"quarter: the back at start",quarter,TUBE_BOUNDS,{0,0,1},{0,0,0}},
        {"quarter: the front at end",quarter,TUBE_BOUNDS,{0,0,-1},{2,0,-2}},
        {"quarter: the right of the mesh along the right of the curve at its end",quarter,TUBE_BOUNDS,{0.1,0,-1},{2,0,-1.9}},
        {"rolled: the right of the mesh turned to the down of the curve, scaled",rolled,TUBE_BOUNDS,{0.1,0,-1},{0,-0.2,-2}},
        {"rolled: the up of the mesh turned to the right of the curve, scaled",rolled,TUBE_BOUNDS,{0,0.1,-1},{0.05,0,-2}},
        {"offset: the curve moved along its right and up",moved,TUBE_BOUNDS,{0,0,1},{0.5,0.25,0}},
        {"range: the back of the mesh a quarter along",ranged,TUBE_BOUNDS,{0,0,1},{0,0,-1}},
        {"range: the front three quarters along",ranged,TUBE_BOUNDS,{0,0,-1},{0,0,-3}},
        {"forward X, up -Z: the right of the mesh is Y",sideways,{{-1,-0.1,-0.1},{1,0.1,0.1}},{-1,0.1,0},{0.1,0,0}},
        {"forward X, up -Z: its -Z goes up",sideways,{{-1,-0.1,-0.1},{1,0.1,0.1}},{1,0,-0.1},{0,0.1,-2}},
    }
    for c in cases {
        got:=bend_place(c.bend,c.bounds,c.from)
        testing.expectf(t,near(got,c.to),"%s: %v, not %v",c.name,got,c.to)
    }

    // The normals of the bent mesh are those of its surface, which faces out,
    // also where the bend stretches, rolls or mirrors it.
    twisted:=quarter
    twisted.end_roll,twisted.smooth=1.2,true
    twisted.end_scale,twisted.up={1.5,0.75},{0.2,1,0}
    mirrored:=quarter
    mirrored.start_scale,mirrored.end_scale={-1,1},{-1.5,1}
    g:Shape_Geometry
    shape_geometry_init(&g)
    defer shape_geometry_destroy(&g)
    for c in ([]Case{{name="quarter",bend=quarter},{name="twisted",bend=twisted},{name="mirrored",bend=mirrored},{name="range",bend=ranged}}) {
        tube(&g)
        bend:=c.bend
        if !testing.expectf(t,bend_build(&bend,&g)==.None,"%s: built",c.name) {continue}
        testing.expectf(t,near(g.mesh.positions[0],bend_place(c.bend,TUBE_BOUNDS,{0.1,0,1})),"%s: bend_place is where the build puts a point",c.name)
        worst:=f32(1)
        for i:=0;i<len(g.mesh.indices);i+=3 {
            a,b,d:=g.mesh.indices[i],g.mesh.indices[i+1],g.mesh.indices[i+2]
            face:=linalg.normalize0(linalg.cross(g.mesh.positions[b]-g.mesh.positions[a],g.mesh.positions[d]-g.mesh.positions[a]))
            for corner in ([3]u32{a,b,d}) {worst=min(worst,linalg.dot(face,g.mesh.normals[corner]))}
        }
        testing.expectf(t,worst>0.9,"%s: a corner normal %.3f from the face it bounds",c.name,worst)
    }
}

@(test)
a_bend_out_of_range_is_refused_and_a_degenerate_one_stays_finite :: proc(t:^testing.T) {
    g:Shape_Geometry
    shape_geometry_init(&g)
    defer shape_geometry_destroy(&g)
    nan:=BEND_DEFAULT
    nan.start.y=math.nan_f32()
    huge:=BEND_DEFAULT
    huge.end_scale.x=1e30
    along:=BEND_DEFAULT
    along.mesh_up=.Negative_Z
    unknown:=BEND_DEFAULT
    unknown.forward=Bend_Axis(9)
    Case :: struct {name:string,bend:Bend}
    for c in ([]Case{{"NaN",nan},{"huge",huge},{"up along forward",along},{"unknown axis",unknown}}) {
        tube(&g)
        bend:=c.bend
        testing.expectf(t,bend_build(&bend,&g)==.Invalid,"%s",c.name)
    }
    shape_geometry_clear(&g)
    bend:=BEND_DEFAULT
    testing.expect(t,bend_build(&bend,&g)==.Empty)
    // A curve along its up and a mesh of no length collapse, finite.
    up:=BEND_DEFAULT
    up.end,up.start_tangent,up.end_tangent={0,1,0},{0,1,0},{0,1,0}
    flat:=BEND_DEFAULT
    flat.start_scale,flat.end_scale={},{}
    for c in ([]Case{{"along up",up},{"scaled to nothing",flat}}) {
        tube(&g)
        bend=c.bend
        testing.expectf(t,bend_build(&bend,&g)==.None,"%s",c.name)
        finite:=true
        for p,i in g.mesh.positions {
            n:=g.mesh.normals[i]
            for v in ([6]f32{p.x,p.y,p.z,n.x,n.y,n.z}) {finite&&=v-v==0}
        }
        testing.expectf(t,finite,"%s: finite",c.name)
    }
}
