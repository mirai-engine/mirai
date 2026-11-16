package terrain

import "core:math"
import "core:math/linalg"
import "mirai:std/base"
import mm "mirai:std/math"

// Erode of a Heightfield: drops of water start inside the disc, run down the
// surface with inertia, take ground where they speed up and leave it where
// they slow or fill a pit (the particle model of Hans Theobald Beyer). The
// region reaches EROSION_REACH times the radius, and what changes fades out
// past the disc. Heights go in cells, so a drop does the same at any spacing.

EROSION_REACH :: f32(1.5)
EROSION_DROPS :: f32(0.5)  // drops per cell of the disc at an amount of 1
EROSION_DROPS_MAX :: 4096  // of a touch
EROSION_LIFE :: 48         // steps of a drop
EROSION_INERTIA :: f32(0.05)
EROSION_CAPACITY :: f32(4) // what a drop carries per cell it falls, at speed and water 1
EROSION_SLOPE_MIN :: f32(0.01)
EROSION_DEPOSIT :: f32(0.3)
EROSION_TAKE :: f32(0.3)
EROSION_EVAPORATE :: f32(0.02)
EROSION_GRAVITY :: f32(4)
EROSION_SPREAD :: 2 // cells around a drop it takes ground from

@(private)
source_erode :: proc(s:^Source,brush:Brush,low,high:[3]int) -> (change:Change) {
    size:=[2]int{high.x-low.x+1,high.z-low.z+1}
    if size.x<3 || size.y<3 {return}
    n:=size.x*size.y
    if resize(&s.scratch,2*n)!=nil {return Change{error=.Out_Of_Memory}}
    h,before:=s.scratch[:n],s.scratch[n:2*n]
    for z in 0..<size.y {for x in 0..<size.x {h[x+size.x*z]=grid_get(&s.field,low.x+x,low.z+z)/s.cell}}
    copy(before,h)
    origin:=source_origin(s)
    center:=[2]f32{(brush.center.x-origin.x)/s.cell-f32(low.x),(brush.center.z-origin.z)/s.cell-f32(low.z)}
    reach:=brush.radius/s.cell
    random:=mm.rng_make(base.hash_u64(u64(brush.seed)),u64(base.hash_u64(transmute(u64)[2]f32{brush.center.x,brush.center.z})))
    drops:=clamp(int(EROSION_DROPS*math.PI*reach*reach*min(brush.amount,1)),1,EROSION_DROPS_MAX)
    for _ in 0..<drops {
        // A start inside the disc, as often as the brush weighs there.
        start:[2]f32
        placed:=false
        for _ in 0..<8 {
            r:=reach*math.sqrt(mm.random_f32(&random))
            a:=mm.random_f32(&random)*math.TAU
            offset:=[2]f32{math.cos(a),math.sin(a)}*r
            if mm.random_f32(&random)<brush_weight(brush,offset*s.cell,r*s.cell) {start,placed=center+offset,true;break}
        }
        if placed {erode_drop(h,size,start)}
    }
    change.low,change.high=high,low
    for z in 0..<size.y {for x in 0..<size.x {
        i:=x+size.x*z
        if h[i]==before[i] {continue}
        gx,gz:=low.x+x,low.z+z
        // The slope filter reads the surface as it was, in cells.
        if brush.slope!={} {
            x0,x1:=max(x-1,0),min(x+1,size.x-1)
            z0,z1:=max(z-1,0),min(z+1,size.y-1)
            dx:=(before[x1+size.x*z]-before[x0+size.x*z])/f32(x1-x0)
            dz:=(before[x+size.x*z1]-before[x+size.x*z0])/f32(z1-z0)
            slope:=math.atan(math.sqrt(dx*dx+dz*dz))
            if (slope>=brush.slope.x && slope<=brush.slope.y)==brush.slope_invert {continue}
        }
        t:=linalg.length([2]f32{f32(x),f32(z)}-center)/reach
        fade:=t<=1?f32(1):clamp((EROSION_REACH-t)/(EROSION_REACH-1),0,1)
        old:=before[i]*s.cell
        value:=brush_way_keep(brush.way,false,old,old+(h[i]-before[i])*s.cell*fade)
        value=clamp(value,-HEIGHT_LIMIT,HEIGHT_LIMIT)
        if value==old {continue}
        grid_set(&s.field,gx,gz,value)
        change.changed=true
        change.low.x,change.low.z=min(change.low.x,gx),min(change.low.z,gz)
        change.high.x,change.high.z=max(change.high.x,gx),max(change.high.z,gz)
    }}
    change.low.y,change.high.y=0,0
    return
}

// The height of a region of heights at a point between its samples, and the
// slope there.
@(private)
erode_sample :: proc "contextless" (h:[]f32,size:[2]int,p:[2]f32) -> (height:f32,gradient:[2]f32) {
    c,r:=int(p.x),int(p.y)
    u,v:=p.x-f32(c),p.y-f32(r)
    i:=c+size.x*r
    a,b,d,e:=h[i],h[i+1],h[i+size.x],h[i+size.x+1]
    gradient={(b-a)*(1-v)+(e-d)*v,(d-a)*(1-u)+(e-b)*u}
    height=a*(1-u)*(1-v)+b*u*(1-v)+d*(1-u)*v+e*u*v
    return
}

@(private)
erode_drop :: proc "contextless" (h:[]f32,size:[2]int,start:[2]f32) {
    p:=start
    direction:[2]f32
    speed,water,carried:=f32(1),f32(1),f32(0)
    inside :: proc "contextless" (p:[2]f32,size:[2]int) -> bool {return p.x>=0 && p.y>=0 && p.x<f32(size.x-1) && p.y<f32(size.y-1)}
    for _ in 0..<EROSION_LIFE {
        if !inside(p,size) {return}
        height,gradient:=erode_sample(h,size,p)
        direction=direction*EROSION_INERTIA-gradient*(1-EROSION_INERTIA)
        length:=linalg.length(direction)
        if length<1e-6 {return}
        direction/=length
        from:=p
        p+=direction
        if !inside(p,size) {return}
        next,_:=erode_sample(h,size,p)
        fall:=next-height
        capacity:=max(-fall*speed*water*EROSION_CAPACITY,EROSION_SLOPE_MIN)
        if carried>capacity || fall>0 {
            // Uphill it fills the pit it leaves; slowing, it leaves its excess.
            amount:=fall>0?min(fall,carried):(carried-capacity)*EROSION_DEPOSIT
            carried-=amount
            c,r:=int(from.x),int(from.y)
            u,v:=from.x-f32(c),from.y-f32(r)
            i:=c+size.x*r
            h[i]+=amount*(1-u)*(1-v)
            h[i+1]+=amount*u*(1-v)
            h[i+size.x]+=amount*(1-u)*v
            h[i+size.x+1]+=amount*u*v
        } else {
            amount:=min((capacity-carried)*EROSION_TAKE,-fall)
            // Taken over the cells around it, weighed by closeness: one cell alone would pit.
            total:=f32(0)
            weights:[(2*EROSION_SPREAD+1)*(2*EROSION_SPREAD+1)]f32
            for dz in -EROSION_SPREAD..=EROSION_SPREAD {for dx in -EROSION_SPREAD..=EROSION_SPREAD {
                x,z:=int(from.x)+dx,int(from.y)+dz
                k:=(dx+EROSION_SPREAD)+(dz+EROSION_SPREAD)*(2*EROSION_SPREAD+1)
                if x<0 || z<0 || x>=size.x || z>=size.y {continue}
                w:=max(f32(EROSION_SPREAD)-linalg.length([2]f32{f32(x),f32(z)}-from),0)
                weights[k]=w;total+=w
            }}
            if total>0 {
                for dz in -EROSION_SPREAD..=EROSION_SPREAD {for dx in -EROSION_SPREAD..=EROSION_SPREAD {
                    k:=(dx+EROSION_SPREAD)+(dz+EROSION_SPREAD)*(2*EROSION_SPREAD+1)
                    if weights[k]<=0 {continue}
                    at:=int(from.x)+dx+size.x*(int(from.y)+dz)
                    take:=amount*weights[k]/total
                    h[at]-=take
                    carried+=take
                }}
            }
        }
        speed=math.sqrt(max(speed*speed-fall*EROSION_GRAVITY,0))
        water*=1-EROSION_EVAPORATE
    }
}


// Thermal of a Heightfield: where the ground stands steeper than its talus
// toward a neighbor, half of what passes the steepest one slides down to the
// neighbors below that slope, shared by how far past it each lies (the model
// of Musgrave, Kolb and Mace). Eight neighbors at their distances, so a
// slope settles alike along any direction, and every sample moves from the
// same heights (Jacobi), so the order of the samples does not matter. What
// slides is kept: the ground in the region weighs the same before and after.

THERMAL_ITERATIONS :: 8 // slides of a touch

@(private="file") THERMAL_NEIGHBORS :: [8][2]int{{-1,0},{1,0},{0,-1},{0,1},{-1,-1},{1,-1},{-1,1},{1,1}}

@(private)
source_thermal :: proc(s:^Source,brush:Brush,low,high:[3]int) -> (change:Change) {
    size:=[2]int{high.x-low.x+1,high.z-low.z+1}
    if size.x<2 || size.y<2 {return}
    n:=size.x*size.y
    if resize(&s.scratch,4*n)!=nil {return Change{error=.Out_Of_Memory}}
    h,moved,weight,before:=s.scratch[:n],s.scratch[n:2*n],s.scratch[2*n:3*n],s.scratch[3*n:4*n]
    origin:=source_origin(s)
    for z in 0..<size.y {for x in 0..<size.x {
        i:=x+size.x*z
        h[i]=grid_get(&s.field,low.x+x,low.z+z)
        point:=origin.xz+[2]f32{f32(low.x+x),f32(low.z+z)}*s.cell
        distance:=linalg.length(point-brush.center.xz)
        w:=distance<brush.radius?brush_weight(brush,point-brush.center.xz,distance):0
        if w>0 && brush.slope!={} && !brush_slope_allows(s,brush,low.x+x,low.z+z) {w=0}
        weight[i]=w*min(brush.amount,1)
    }}
    copy(before,h)
    rise:=math.tan(brush.talus)*s.cell
    for _ in 0..<THERMAL_ITERATIONS {
        for &m in moved {m=0}
        for z in 0..<size.y {for x in 0..<size.x {
            i:=x+size.x*z
            if weight[i]<=0 {continue}
            excess:[8]f32
            total,steepest:=f32(0),f32(0)
            for d,k in THERMAL_NEIGHBORS {
                nx,nz:=x+d.x,z+d.y
                if nx<0 || nz<0 || nx>=size.x || nz>=size.y {continue}
                past:=h[i]-h[nx+size.x*nz]-rise*(k<4?1:math.SQRT_TWO)
                if past<=0 {continue}
                excess[k]=past;total+=past;steepest=max(steepest,past)
            }
            if total<=0 {continue}
            slide:=steepest*0.5*weight[i]
            moved[i]-=slide
            for d,k in THERMAL_NEIGHBORS {
                if excess[k]>0 {moved[x+d.x+size.x*(z+d.y)]+=slide*excess[k]/total}
            }
        }}
        for &value,i in h {value+=moved[i]}
    }
    change.low,change.high=high,low
    for z in 0..<size.y {for x in 0..<size.x {
        i:=x+size.x*z
        if h[i]==before[i] {continue}
        gx,gz:=low.x+x,low.z+z
        value:=clamp(brush_way_keep(brush.way,false,before[i],h[i]),-HEIGHT_LIMIT,HEIGHT_LIMIT)
        if value==before[i] {continue}
        grid_set(&s.field,gx,gz,value)
        change.changed=true
        change.low.x,change.low.z=min(change.low.x,gx),min(change.low.z,gz)
        change.high.x,change.high.z=max(change.high.x,gx),max(change.high.z,gz)
    }}
    change.low.y,change.high.y=0,0
    return
}
