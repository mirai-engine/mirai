package terrain

import "core:math"
import "core:math/linalg"
import "mirai:std/geom"
import mm "mirai:std/math"

// What a brush does, as an intent every representation maps to its data: a
// game asks to carve a sphere and the terrain under it, a Heightfield or a
// Volume, takes it out. Add and Carve join or take the shape of the brush;
// Raise and Lower move the surface by amount metres; Smooth, Flatten and Noise
// take it a part of the way; Paint and Erase change the weight of a layer;
// Tint and Roughness take the color or the roughness painted over the layers
// toward color or target (paint.odin).
// Hole, Fill, Ramp, Terrace, Erode, Thermal, Tint and Roughness are of a Heightfield alone.
Brush_Kind :: enum u8 {Raise,Lower,Smooth,Flatten,Add,Carve,Paint,Erase,Hole,Fill,Ramp,Terrace,Noise,Erode,Thermal,Tint,Roughness}

// Which way a brush may move a sample: Up never lowers one, Down never raises one.
Brush_Way :: enum u8 {Both,Up,Down}

// A shape a brush takes inside its disc: size by size values from 0 to 1, x
// first, over the square that holds the disc.
Brush_Alpha :: struct {size:int,values:[]f32}

// What Add and Carve join or take: a sphere at center, a capsule from
// center to center+delta, a box of half size extent turned by rotation.
Brush_Shape :: enum u8 {Sphere,Capsule,Box}

Brush :: struct {
    kind:Brush_Kind,
    center:[3]f32,
    radius,amount,target:f32,
    delta:[3]f32,
    rotation:quaternion128,
    layer:u32, // Paint and Erase, and what Add gives a Volume
    falloff:geom.Falloff,
    hardness:f32, // the part of the radius at full weight
    shape:Brush_Shape,
    extent:[3]f32,
    blend:f32, // Add and Carve of a Volume: the width over which the shape joins what was there
    way:Brush_Way,      // Smooth, Flatten, Ramp, Terrace, Noise and Erode
    capped:bool,        // Raise and Lower of a Heightfield stop at target: Raise lifts what is under it, Lower cuts what is over it
    interval:f32,       // Terrace: metres between its steps, from target
    riser:f32,          // Terrace: the part of each step that rises, from 0 (a cliff) to 1
    scale:f32,          // Noise: metres across its features
    talus:f32,          // Thermal: radians from horizontal the ground stands at; steeper slides down
    seed:u32,           // Noise and Erode
    slope:[2]f32,       // radians from horizontal of the Heightfield it touches; zero: any
    slope_invert:bool,  // it touches outside slope instead
    toward:bool,        // Paint takes the weight of its layer toward target, from 0 to 1, in place of adding
    color:[3]f32,       // Tint: the color the layers are tinted toward, sRGB from 0 to 1; white shows them as they are
    alpha:^Brush_Alpha, // nil: the whole disc
    turn:f32,           // radians the alpha turns around y
}

// How far from 1 the squared length of Brush.rotation may be.
ROTATION_TOLERANCE :: f32(1e-3)

// Smooth averages a box of this part of its radius, from one sample to
// SMOOTH_SAMPLES_MAX on each side.
SMOOTH_REACH :: f32(0.25)
SMOOTH_SAMPLES_MAX :: 8

// Why an edit changed nothing: the field of the brush that is wrong, or what
// the source lacks. edit_error_fix says how to fix each.
// Invalid and Budget are of what a replay or a layer change asks: bytes or
// a layer that do not fit the source, and no room for another source.
// Scale is of the terrain the brush of the world edits (brush_local).
Edit_Error :: enum u8 {None,Kind,Center,Radius,Amount,Target,Delta,Extent,Rotation,Blend,Falloff,Layer,Alpha,Slope,Terrace,Noise,Color,Scale,Talus,Unloaded,Out_Of_Memory,Invalid,Budget}

Change :: struct {
    changed:bool,
    low,high:[3]int, // inclusive sample coordinates
    error:Edit_Error,
}

// What an error of an edit asks of whoever made it. kind: the brush, which
// chooses the brush to use in place of one a Volume lacks.
edit_error_fix :: proc "contextless" (error:Edit_Error,kind:Brush_Kind) -> string {
    switch error {
    case .None: return ""
    case .Kind:
        #partial switch kind {
        case .Hole,.Fill: return "a Volume has no holes: Carve opens it and Add closes it"
        case .Ramp:       return "a Ramp is of a Heightfield: on a Volume use Add with a Capsule or a Box"
        case .Terrace:    return "Terrace is of a Heightfield: on a Volume use Flatten at the height of each step"
        case .Erode:      return "Erode is of a Heightfield: on a Volume use Smooth or Noise"
        case .Thermal:    return "Thermal is of a Heightfield: on a Volume use Smooth"
        case .Tint,.Roughness: return "a Volume has no painted color or roughness: Paint a layer of the material wanted"
        }
        return "kind is not a brush: name one from Raise to Roughness"
    case .Center:  return "center has a value that is not a number: give the point to edit"
    case .Radius:  return "radius is not above 0 or passes 100000 m: give the reach of the brush in metres"
    case .Amount:  return "amount is not above 0, is not a number or, for Add and Carve, passes 1: metres for Raise, Lower and Noise, a part from 0 to 1 for the others (1 takes or adds the whole shape)"
    case .Target:  return "target is not a number within 100000 m, or for a Paint toward a weight or a Roughness is not from 0 to 1"
    case .Delta:   return "delta has a value that is not a number or passes 200000 m: give the way from center to the other end of a Capsule or a Ramp"
    case .Extent:  return "extent of a Box has a side that is not above 0 or passes 100000 m: give its half sizes in metres"
    case .Rotation: return "rotation is not a quaternion of length 1: give the turn of the Box as a unit quaternion, or 0 for none"
    case .Blend:   return "blend is below 0, not a number or passes 100000 m: give the metres over which the shape joins the ground, or 0"
    case .Falloff: return "falloff, shape or way is not one of its values, or hardness is not from 0 to below 1"
    case .Layer:   return "layer is not a layer of the source: name one below its layer count, or add the layer first"
    case .Alpha:   return "alpha has fewer than 2 values a side or not size by size of them, or was given to a request, which keeps no memory of it: leave it nil"
    case .Slope:   return "slope is not an ordered range from 0 to a quarter turn, or turn is not a number"
    case .Terrace: return "interval of a Terrace is not above 0 or its riser is not from 0 to 1"
    case .Noise:   return "scale of a Noise is not above 0 or passes 100000 m"
    case .Color:   return "color of a Tint has a channel that is not from 0 to 1: give the sRGB color to tint toward, white to take the tint away"
    case .Scale:   return "the terrain is scaled by 0 or unevenly: a brush needs the same scale on its x and z, and a shape of Add or Carve, or any brush of a Volume, the same on all three axes; give the terrain such a scale"
    case .Talus:   return "talus of a Thermal is not above 0 and below a quarter turn: give the angle in radians the ground stands at"
    case .Unloaded: return "the source holds no samples there: it is not loaded, or its pages could not be read"
    case .Out_Of_Memory: return "out of memory and nothing changed: free memory, or use a smaller brush"
    case .Invalid: return "what it brings does not fit the source: its shape, its pages or its layers are of another one"
    case .Budget:  return "Terrain_Settings.sources has no room for another source: raise it"
    }
    return ""
}

// What is wrong with a brush whatever source it edits; None for one a source
// can take.
brush_check :: proc "contextless" (brush:Brush) -> Edit_Error {
    finite :: proc "contextless" (value:f32) -> bool {return value-value==0}
    finite3 :: proc "contextless" (v:[3]f32) -> bool {return v.x-v.x==0 && v.y-v.y==0 && v.z-v.z==0}
    if brush.kind>max(Brush_Kind) {return .Kind}
    if !(brush.hardness>=0 && brush.hardness<1) || brush.falloff>.Constant || brush.shape>.Box || brush.way>.Down {return .Falloff}
    if !finite3(brush.center) {return .Center}
    if !finite3(brush.delta) || max(abs(brush.delta.x),abs(brush.delta.y),abs(brush.delta.z))>HEIGHT_LIMIT*2 {return .Delta}
    if !finite(brush.target) || abs(brush.target)>HEIGHT_LIMIT {return .Target}
    // Zero is no turn.
    if q:=brush.rotation;q!=0 && !(abs(q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w-1)<=ROTATION_TOLERANCE) {return .Rotation}
    shaped:=brush.kind==.Add || brush.kind==.Carve
    if shaped && brush.shape==.Box {
        if !finite3(brush.extent) || !(brush.extent.x>0 && brush.extent.y>0 && brush.extent.z>0) || max(brush.extent.x,brush.extent.y,brush.extent.z)>HEIGHT_LIMIT {return .Extent}
    } else if !(brush.radius>0) || !(brush.radius<=HEIGHT_LIMIT) {return .Radius}
    // Hole and Fill do not read it.
    if brush.kind!=.Hole && brush.kind!=.Fill && (!(brush.amount>0) || !finite(brush.amount)) {return .Amount}
    if shaped && brush.amount>1 {return .Amount}
    if !(brush.blend>=0) || brush.blend>HEIGHT_LIMIT {return .Blend}
    if !finite(brush.turn) || !finite(brush.slope.x) || !finite(brush.slope.y) {return .Slope}
    if brush.slope!={} && !(brush.slope.x>=0 && brush.slope.x<=brush.slope.y && brush.slope.y<=math.PI/2+1e-4) {return .Slope}
    if brush.alpha!=nil && (brush.alpha.size<2 || len(brush.alpha.values)!=brush.alpha.size*brush.alpha.size) {return .Alpha}
    #partial switch brush.kind {
    case .Terrace: if !(brush.interval>0 && brush.interval<=HEIGHT_LIMIT && brush.riser>=0 && brush.riser<=1) {return .Terrace}
    case .Noise:   if !(brush.scale>0 && brush.scale<=HEIGHT_LIMIT) {return .Noise}
    case .Thermal: if !(brush.talus>0 && brush.talus<math.PI/2) {return .Talus}
    case .Paint:   if brush.toward && !(brush.target>=0 && brush.target<=1) {return .Target}
    case .Roughness: if !(brush.target>=0 && brush.target<=1) {return .Target}
    case .Tint:    if !(brush.color.r>=0 && brush.color.r<=1 && brush.color.g>=0 && brush.color.g<=1 && brush.color.b>=0 && brush.color.b<=1) {return .Color}
    }
    return .None
}

// Edits a source with a brush in its space. What is wrong with the brush, or
// a brush its representation lacks, is an error and changes nothing; a brush
// that touches nothing is no error.
source_edit :: proc(s:^Source,brush:Brush) -> (change:Change) {
    s.dug={}
    if error:=brush_check(brush);error!=.None {return Change{error=error}}
    if !source_valid(s.info) || !source_samples_held(s) {return Change{error=.Unloaded}}
    volume:=s.kind==.Volume
    // What a brush adds to a Volume is of brush.layer.
    if (volume && brush.kind==.Add || brush.kind==.Paint || brush.kind==.Erase) && brush.layer>=s.layer_count {return Change{error=.Layer}}
    if brush.kind==.Paint || brush.kind==.Erase {return source_paint(s,brush)}
    if volume {
        #partial switch brush.kind {
        case .Hole,.Fill,.Ramp,.Terrace,.Erode,.Thermal,.Tint,.Roughness: return Change{error=.Kind}
        case .Add,.Carve: return source_volume_shape(s,brush)
        }
    }
    if brush.kind==.Hole || brush.kind==.Fill {return source_holes_edit(s,brush)}
    if brush.kind==.Tint || brush.kind==.Roughness {return source_paint_edit(s,brush)}
    shaped:=brush.kind==.Add || brush.kind==.Carve
    segment:=brush.kind==.Ramp
    reach:=brush_reach(brush)
    // What slides leaves the disc for the samples around it.
    if brush.kind==.Thermal {reach+=s.cell*1.5}
    origin:=source_origin(s)
    span_low,span_high:=brush_bounds(brush)
    // A Heightfield moves its columns to the shape, without blend.
    if shaped {span_low,span_high=brush_shape_bounds(brush)}
    low,high:[3]int
    for axis in 0..<3 {
        if !volume && axis==1 {continue}
        lo,hi:=math.ceil((span_low[axis]-origin[axis])/s.cell),math.floor((span_high[axis]-origin[axis])/s.cell)
        first,last:=f32(0),f32(s.samples[axis]-1)
        if volume {first,last=1,last-1}
        if hi<first || lo>last {return}
        low[axis]=int(clamp(lo,first,last))
        high[axis]=int(clamp(hi,first,last))
    }
    if !grid_prepare(&s.field,low,high,s.allocator) {return Change{error=.Out_Of_Memory}}
    if brush.kind==.Erode {return source_erode(s,brush,low,high)}
    if brush.kind==.Thermal {return source_thermal(s,brush,low,high)}
    // Smooth reads the region as it was, with a halo as wide as its box, and
    // so does the slope filter: what the brush raises before a sample does not
    // change whether it touches it.
    from,to:=low,high
    blurred:[]f32
    k:=clamp(int(brush.radius/s.cell*SMOOTH_REACH),1,SMOOTH_SAMPLES_MAX)
    smoothing:=0
    if brush.kind==.Smooth {
        for axis in 0..<3 {
            if !volume && axis==1 {continue}
            from[axis]=max(from[axis]-k,0);to[axis]=min(to[axis]+k,int(s.samples[axis])-1)
        }
        size:=to-from+1
        smoothing=2*size.x*size.y*size.z
    }
    filter_size:=high.xz-low.xz+1
    filtering:=!volume && brush.slope!={}?filter_size.x*filter_size.y:0
    if smoothing+filtering>0 && resize(&s.scratch,smoothing+filtering)!=nil {return Change{error=.Out_Of_Memory}}
    allowed:=s.scratch[smoothing:][:filtering]
    for z in 0..<(filtering>0?filter_size.y:0) {for x in 0..<filter_size.x {allowed[x+filter_size.x*z]=brush_slope_allows(s,brush,low.x+x,low.z+z)?1:0}}
    if brush.kind==.Smooth {
        size:=to-from+1
        n:=smoothing/2
        a,b:=s.scratch[:n],s.scratch[n:2*n]
        for z in from.z..=to.z {for y in from.y..=to.y {for x in from.x..=to.x {
            p:=[3]int{x,y,z}-from
            a[p.x+size.x*(p.y+size.y*p.z)]=grid_value(&s.field,{x,y,z})
        }}}
        for axis in 0..<3 {
            if size[axis]==1 {continue}
            box_blur(a,b,size,axis,k)
            a,b=b,a
        }
        blurred=a
    }
    size:=to-from+1
    band:=s.cell*SDF_BAND_CELLS
    change.low=high;change.high=low
    for z in low.z..=high.z {for y in low.y..=high.y {for x in low.x..=high.x {
        p:=[3]int{x,y,z}
        point:=origin+[3]f32{f32(x),f32(y),f32(z)}*s.cell
        old:=grid_value(&s.field,p)
        value:=old
        if shaped {
            // A Heightfield holds one height over each sample: Carve takes the
            // ground the shape holds and what stands on it, down to the bottom of
            // the shape there, and Add fills up to its top what the shape reaches.
            bottom,top,inside:=brush_shape_column(brush,point.x,point.z)
            if !inside || old<=bottom || old>=top {continue}
            value=math.lerp(old,brush.kind==.Carve?bottom:top,brush.amount)
        } else {
            distance:=f32(0)
            along:=f32(0)
            if !volume {
                nearest:=brush.center.xz
                if segment {
                    length:=linalg.dot(brush.delta.xz,brush.delta.xz)
                    if length>0 {along=clamp(linalg.dot(point.xz-brush.center.xz,brush.delta.xz)/length,0,1);nearest+=brush.delta.xz*along}
                }
                distance=linalg.length(point.xz-nearest)
            } else {distance=linalg.length(point-brush.center)}
            if distance>=reach {continue}
            weight:=brush_weight(brush,point.xz-brush.center.xz,distance)
            if weight>0 && filtering>0 && allowed[x-low.x+filter_size.x*(z-low.z)]==0 {weight=0}
            if weight<=0 {continue}
            switch brush.kind {
            case .Raise:
                // The surface of a Volume rises where its distance falls.
                switch {
                case volume: value-=brush.amount*weight
                case brush.capped:
                    if old>=brush.target {continue}
                    value=min(old+brush.amount*weight,brush.target)
                case: value+=brush.amount*weight
                }
            case .Lower:
                switch {
                case volume: value+=brush.amount*weight
                case brush.capped:
                    if old<=brush.target {continue}
                    value=max(old-brush.amount*weight,brush.target)
                case: value-=brush.amount*weight
                }
            case .Flatten:
                target:=volume?clamp(point.y-brush.target,-band,band):brush.target
                value=math.lerp(old,target,min(brush.amount*weight,1))
            case .Terrace:
                value=math.lerp(old,terrace_height(old,brush.target,brush.interval,brush.riser),min(brush.amount*weight,1))
            case .Noise:
                n:=brush_noise(point,brush.scale,brush.seed,volume)*brush.amount*weight
                value+=volume?-n:n
            case .Ramp:
                value=math.lerp(old,brush.center.y+brush.delta.y*along,min(brush.amount*weight,1))
            case .Smooth:
                // The mean of the box without the sample: its neighbors.
                at:=p-from
                n:=1
                for axis in 0..<3 {n*=min(at[axis]+k,size[axis]-1)-max(at[axis]-k,0)+1}
                if n<2 {continue}
                mean:=blurred[at.x+size.x*(at.y+size.y*at.z)]
                value=math.lerp(old,(mean*f32(n)-old)/f32(n-1),min(brush.amount*weight,1))
            case .Add,.Carve,.Paint,.Erase,.Hole,.Fill,.Erode,.Thermal,.Tint,.Roughness:
            }
            value=brush_way_keep(brush.way,volume,old,value)
        }
        limit:=volume?band:HEIGHT_LIMIT
        value=clamp(value,-limit,limit)
        if value==old {continue}
        dug_count(s,p,old,value)
        if volume {block_set(&s.field,p,value)} else {grid_set(&s.field,x,z,value)}
        change.changed=true
        for axis in 0..<3 {change.low[axis]=min(change.low[axis],p[axis]);change.high[axis]=max(change.high[axis],p[axis])}
    }}}
    if volume {grid_settle(&s.field,low,high,s.allocator)}
    return
}

// The lowest and highest point of the shape of a brush over x, z; inside is
// false where the shape does not reach that column. A shape is convex: its
// distance along the column falls to one lowest value and rises again.
brush_shape_column :: proc(brush:Brush,x,z:f32) -> (bottom,top:f32,inside:bool) {
    low,high:=brush_shape_bounds(brush)
    if x<low.x || x>high.x || z<low.z || z>high.z {return}
    a,b:=low.y,high.y
    for _ in 0..<32 {
        third:=(b-a)/3
        if brush_shape_distance(brush,{x,a+third,z})<brush_shape_distance(brush,{x,b-third,z}) {b-=third} else {a+=third}
    }
    middle:=(a+b)*0.5
    if !(brush_shape_distance(brush,{x,middle,z})<0) {return}
    cross :: proc(brush:Brush,x,z,inner,outer:f32) -> f32 {
        inner,outer:=inner,outer
        for _ in 0..<32 {
            y:=(inner+outer)*0.5
            if brush_shape_distance(brush,{x,y,z})<0 {inner=y} else {outer=y}
        }
        return (inner+outer)*0.5
    }
    return cross(brush,x,z,middle,low.y-1),cross(brush,x,z,middle,high.y+1),true
}

// The weight of a brush at an offset over x and z from its center, at a
// distance from it: its falloff times its alpha.
brush_weight :: proc "contextless" (brush:Brush,offset:[2]f32,distance:f32) -> f32 {
    weight:=geom.falloff_weight(brush.falloff,brush.hardness,distance/brush.radius)
    if weight<=0 || brush.alpha==nil {return weight}
    return weight*alpha_sample(brush.alpha^,offset,brush.radius,brush.turn)
}

// An alpha at an offset over x and z from the center of a disc of radius,
// turned by turn: bilinear between its values, 0 outside its square.
alpha_sample :: proc "contextless" (a:Brush_Alpha,offset:[2]f32,radius,turn:f32) -> f32 {
    if a.size<2 || len(a.values)!=a.size*a.size || !(radius>0) {return 0}
    sin,cos:=math.sin(turn),math.cos(turn)
    u:=(cos*offset.x+sin*offset.y)/radius
    v:=(cos*offset.y-sin*offset.x)/radius
    last:=f32(a.size-1)
    x,z:=(u*0.5+0.5)*last,(v*0.5+0.5)*last
    if !(x>=0 && z>=0 && x<=last && z<=last) {return 0}
    c,r:=min(int(x),a.size-2),min(int(z),a.size-2)
    fx,fz:=x-f32(c),z-f32(r)
    i:=r*a.size+c
    top:=a.values[i]+(a.values[i+1]-a.values[i])*fx
    bottom:=a.values[i+a.size]+(a.values[i+a.size+1]-a.values[i+a.size])*fx
    return top+(bottom-top)*fz
}

// Whether the slope filter of a brush lets it touch sample x, z of a
// Heightfield: the slope of its neighbors across it in the range, or out of it.
brush_slope_allows :: proc "contextless" (s:^Source,brush:Brush,x,z:int) -> bool {
    if brush.slope=={} {return true}
    x0,x1:=max(x-1,0),min(x+1,int(s.samples.x)-1)
    z0,z1:=max(z-1,0),min(z+1,int(s.samples.z)-1)
    dx:=(grid_get(&s.field,x1,z)-grid_get(&s.field,x0,z))/(f32(x1-x0)*s.cell)
    dz:=(grid_get(&s.field,x,z1)-grid_get(&s.field,x,z0))/(f32(z1-z0)*s.cell)
    slope:=math.atan(math.sqrt(dx*dx+dz*dz))
    return (slope>=brush.slope.x && slope<=brush.slope.y)!=brush.slope_invert
}

// What a brush moves old to, kept to the way it may go: up is a higher value
// of a Heightfield and a lower one of a Volume, whose surface rises as it falls.
@(private)
brush_way_keep :: proc "contextless" (way:Brush_Way,volume:bool,old,value:f32) -> f32 {
    if way==.Both {return value}
    up:=(way==.Up)!=volume
    return up?max(value,old):min(value,old)
}

// The height of a terrace of steps interval apart from base at a height: level
// over each step, rising to the next over its last riser part.
terrace_height :: proc "contextless" (height,base,interval,riser:f32) -> f32 {
    t:=(height-base)/interval
    step:=math.floor(t)
    rise:=f32(0)
    if riser>0 {
        x:=clamp((t-step-(1-riser))/riser,0,1)
        rise=x*x*(3-2*x)
    }
    return base+(step+rise)*interval
}

// Noise from -1 to 1 at a point, of features scale metres across: three
// octaves of value noise, over x and z, or x, y and z for a volume. It is
// the same at a point for a seed, so passes over it deepen one pattern.
brush_noise :: proc(p:[3]f32,scale:f32,seed:u32,volume:bool) -> f32 {
    fractal:=mm.Fractal{kind=.Value,octaves=3,lacunarity=2,gain=0.5,seed=seed}
    q:=p/scale
    return volume?mm.noise_fbm3(q,fractal):mm.noise_fbm2(q.xz,fractal)
}

// The mean of each sample of src over the 2k+1 samples around it along an
// axis, those of the region only, into dst.
@(private)
box_blur :: proc(src,dst:[]f32,size:[3]int,axis,k:int) {
    steps:=[3]int{1,size.x,size.x*size.y}
    step,n:=steps[axis],size[axis]
    lines:=size;lines[axis]=1
    for z in 0..<lines.z {for y in 0..<lines.y {for x in 0..<lines.x {
        base:=x+size.x*(y+size.y*z)
        for i in 0..<n {
            lo,hi:=max(i-k,0),min(i+k,n-1)
            sum:=f64(0)
            for j in lo..=hi {sum+=f64(src[base+j*step])}
            dst[base+i*step]=f32(sum/f64(hi-lo+1))
        }
    }}}
}

// The signed distance from p to the shape of a brush: negative inside.
brush_shape_distance :: proc(brush:Brush,p:[3]f32) -> f32 {
    switch brush.shape {
    case .Sphere: return linalg.length(p-brush.center)-brush.radius
    case .Capsule:
        length:=linalg.dot(brush.delta,brush.delta)
        along:=length>0?clamp(linalg.dot(p-brush.center,brush.delta)/length,0,1):0
        return linalg.length(p-(brush.center+brush.delta*along))-brush.radius
    case .Box:
        turn:=brush.rotation==0?quaternion128(1):brush.rotation
        q:=linalg.abs(mm.quat_rotate(mm.quat_inverse(turn),p-brush.center))-brush.extent
        return linalg.length(linalg.max(q,0))+min(max(q.x,q.y,q.z),0)
    }
    return 0
}

// How far from center, or from the segment of a Ramp, a brush that is not a
// shape touches: the water of Erode runs past its disc and leaves there what
// it carries.
@(private)
brush_reach :: proc "contextless" (brush:Brush) -> f32 {return brush.kind==.Erode?brush.radius*EROSION_REACH:brush.radius}

// The box of the space of a brush that it may change: about its center, along
// a Ramp, or around the shape of Add and Carve with the blend that joins it.
brush_bounds :: proc(brush:Brush) -> (low,high:[3]f32) {
    reach:=brush_reach(brush)
    #partial switch brush.kind {
    case .Add,.Carve:
        low,high=brush_shape_bounds(brush)
        return low-brush.blend,high+brush.blend
    case .Ramp:
        end:=brush.center+brush.delta
        return linalg.min(brush.center,end)-reach,linalg.max(brush.center,end)+reach
    }
    return brush.center-reach,brush.center+reach
}

// The box around the shape of a brush.
brush_shape_bounds :: proc(brush:Brush) -> (low,high:[3]f32) {
    switch brush.shape {
    case .Sphere: return brush.center-brush.radius,brush.center+brush.radius
    case .Capsule:
        end:=brush.center+brush.delta
        return linalg.min(brush.center,end)-brush.radius,linalg.max(brush.center,end)+brush.radius
    case .Box:
        turn:=brush.rotation==0?quaternion128(1):brush.rotation
        reach:[3]f32
        for axis in 0..<3 {
            side:[3]f32;side[axis]=brush.extent[axis]
            reach+=linalg.abs(mm.quat_rotate(turn,side))
        }
        return brush.center-reach,brush.center+reach
    }
    return
}

@(private)
smooth_min :: proc "contextless" (a,b,k:f32) -> f32 {
    if !(k>0) {return min(a,b)}
    h:=max(k-abs(a-b),0)/k
    return min(a,b)-h*h*k*0.25
}

// Add joins the shape of the brush to a Volume and Carve takes it away,
// over blend; amount is the part of the way to that.
@(private)
source_volume_shape :: proc(s:^Source,brush:Brush) -> (change:Change) {
    band:=s.cell*SDF_BAND_CELLS
    shape_low,shape_high:=brush_bounds(brush)
    origin:=source_origin(s)
    low,high:[3]int
    for axis in 0..<3 {
        lo,hi:=math.ceil((shape_low[axis]-band-origin[axis])/s.cell),math.floor((shape_high[axis]+band-origin[axis])/s.cell)
        first,last:=f32(1),f32(s.samples[axis]-2)
        if hi<first || lo>last {return}
        low[axis],high[axis]=int(clamp(lo,first,last)),int(clamp(hi,first,last))
    }
    change.low=high;change.high=low
    if !grid_prepare(&s.field,low,high,s.allocator) {return Change{error=.Out_Of_Memory}}
    defer grid_settle(&s.field,low,high,s.allocator)
    layered:=brush.kind==.Add
    if layered && !grid_prepare(&s.weights,low,high,s.allocator) {return Change{error=.Out_Of_Memory}}
    defer if layered {grid_settle(&s.weights,low,high,s.allocator)}
    for z in low.z..=high.z {for y in low.y..=high.y {for x in low.x..=high.x {
        p:=[3]int{x,y,z}
        d:=brush_shape_distance(brush,origin+[3]f32{f32(x),f32(y),f32(z)}*s.cell)
        old:=grid_value(&s.field,p)
        target:=brush.kind==.Add?smooth_min(old,d,brush.blend):-smooth_min(-old,d,brush.blend)
        value:=clamp(math.lerp(old,target,brush.amount),-band,band)
        if value==old {continue}
        dug_count(s,p,old,value)
        if layered {grid_write(&s.weights,p,weights_grow(grid_value(&s.weights,p),int(brush.layer),int(s.layer_count),volume_solid(old,s.cell),volume_solid(value,s.cell)))}
        block_set(&s.field,p,value)
        change.changed=true
        for axis in 0..<3 {change.low[axis]=min(change.low[axis],p[axis]);change.high[axis]=max(change.high[axis],p[axis])}
    }}}
    return
}
