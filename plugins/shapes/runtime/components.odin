package shapes

import "mirai:std/base"
import mm "mirai:std/math"

// Editable solids whose source is the Shape of an entity: the scene saves only
// that source, and this library derives from it the mesh and the collider of
// one child entity of the shape (Shape_Part). An Outline is a polygon with
// holes in the local XY plane of the entity, extruded along local Z by depth
// and centered on it; a Solid is made of the convex brushes of its direct
// children with Shape_Brush, in their order, each added to what the ones
// before it made or cut from it. Without a Rigid_Body on the
// shape entity it collides as a static mesh; with one, as convex pieces of
// that body. A physics.Collider on the shape entity, of kind External, gives
// the surface and the filtering of the derived collider.
//
// A bevel rounds or cuts the front and back rims of an Outline: its caps are
// inset by bevel and the rims fall by bevel along Z, following the profile
// from the cap to the side. Where a corner, an edge, a gap across the shape
// or the depth is smaller than that, the bevel there is smaller. It is drawn
// only: the shape collides as if it had none.

SHAPE_POINTS :: 512
SHAPE_LOOPS :: 16
BEVEL_POINTS :: 8
BEVEL_SEGMENTS :: 16

Shape_Kind :: enum u8 {Outline,Solid}
Brush_Kind :: enum u8 {Box,Sphere,Cylinder}
// Round: a quarter of a circle, tangent to the cap and the side. Chamfer: a
// straight cut. Points: the polyline of bevel_points.
Bevel_Profile :: enum u8 {Round,Chamfer,Points}

// On a direct child of a Solid shape, with core.Id: source data, saved with
// the scene. The local Transform of the entity places, turns and scales a
// primitive of one meter (a box of side 1, a sphere and a cylinder of
// diameter 1, the cylinder 1 tall along Y) in the frame of the solid, so its
// scale is the full size of the brush. It has no mesh or collider of its own.
@(component,description="A box, sphere or cylinder of one meter that its Transform places and scales in the frame of the Solid shape it is a child of, added to what the brushes before it made or cut from it.")
Shape_Brush :: struct {
    kind:Brush_Kind,
    subtract:bool,
}

// A brush as a build takes it: in the frame of its solid.
Brush :: struct {
    kind:Brush_Kind,
    subtract:bool,
    place:mm.Transform, // its local Transform
}

@(component,description="An editable solid: a polygon with holes extruded along its local Z, or the brushes of its children added and subtracted in order. Its mesh and collider are made from it on a child entity.")
Shape :: struct {
    kind:Shape_Kind,
    depth:f32 `mirai:"min=0,unit=m"`, // of an Outline, along local Z
    material:base.Asset_Id `mirai:"kind=.mat"`,
    uv_scale:f32 `mirai:"min=0"`, // texture repeats per meter; 0: 1
    bevel:f32 `mirai:"min=0,unit=m"`, // of an Outline: how far its caps are inset and its rims fall; 0: none
    bevel_profile:Bevel_Profile,
    bevel_segments:u8 `mirai:"min=0,max=16"`, // of a Round bevel; 0: 4
    bevel_point_count:u8 `mirai:"hidden"`,
    // Of a Points bevel, between the cap (1,0) and the side (0,1): how far in
    // from the side and how far down from the cap, in parts of bevel; the
    // first never grows and the second never shrinks from one to the next.
    bevel_points:[BEVEL_POINTS][2]f32 `mirai:"hidden"`,
    point_count:u16 `mirai:"hidden"`,
    loop_count:u8 `mirai:"hidden"`,
    loops:[SHAPE_LOOPS]u16 `mirai:"hidden"`,      // points of each loop, the outline first and then its holes
    points:[SHAPE_POINTS][2]f32 `mirai:"hidden"`, // local XY
}

// A square of one meter, one deep.
SHAPE_DEFAULT :: Shape{
    kind=.Outline,depth=1,uv_scale=1,point_count=4,loop_count=1,loops={0=4},
    points={0={-0.5,-0.5},1={0.5,-0.5},2={0.5,0.5},3={-0.5,0.5}},
}

// On the child entity that draws and collides a shape. It has no core.Id: a
// scene never saves it, and the step makes it again from the Shape.
@(component,description="The derived child that draws and collides the Shape of its parent: made again from that source, never saved.")
Shape_Part :: struct {}

Stamp_Kind :: enum u8 {
    Square,Circle,Triangle,Arrow,Cross,Hexagon,Hexagram,Pentagon,Octagon,Star,Right_Triangle,
    Half_Disc,Ellipse,Lens,Drop,Heart,
}

Shape_Error :: enum u8 {
    None,
    Invalid,           // a count, a value or an index out of range
    Empty,             // nothing is left to build
    Too_Many_Points,
    Too_Many_Loops,
    Self_Intersecting, // edges cross or touch, a hole leaves the outline or meets another
    Geometry,          // the triangulation or the boolean of the brushes failed
    Out_Of_Memory,
}
