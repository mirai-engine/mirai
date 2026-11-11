package mirai_physics

import cmath "core:math"
import math "mirai:std/math"

// Buoyancy, damping and drag of the bodies in fluids, in the integration of velocities of every substep:
// the buoyancy near the surface is a stiff spring that a force held for a whole tick makes bounce, and a
// strong drag applied explicitly diverges.
//
// - Buoyancy rho V g at the center of the submerged volume, for the exact volume of each form: boxes and
//   hulls clipped by the planes of the fluid; spheres, upright capsules and cylinders in closed form between
//   horizontal planes; a leaning capsule as spheres along its axis; and a curved form that a wall of a box
//   cuts, as a polyhedron of its volume.
// - Damping of the waterline: a pressure against the vertical velocity of each point of the area the
//   surface cuts, of the size that gives the heave of a floating body FLUID_DAMPING_RATIO.
// - Drag 1/2 rho Cd A |v| v relative to the current, with the area the submerged part shows to the flow,
//   and an angular drag of the submerged volume, both implicit.

// Of the heave of a floating body, as the waves it makes damp it: of the order of what floating bodies show
// (0.1 to 0.3). With drag alone the small oscillations of a body on its waterline never end.
FLUID_DAMPING_RATIO :: 0.2

// Drag coefficients a shape takes when its Shape_Desc gives none: measured values for each form.
CD_SPHERE :: 0.47   // a sphere
CD_BOX :: 1.05      // a cube face on
CD_CYLINDER :: 0.82 // a long cylinder along its axis
CD_CAPSULE :: 0.82  // as a cylinder with round ends
CD_HULL :: 1.05     // a blunt polyhedron, as a cube
CD_HUMAN :: 1.0     // a person in a flow

@(private)
shape_drag_default :: proc "contextless" (type:Shape_Type) -> f32 {
    switch type {
    case .Sphere: return CD_SPHERE
    case .Capsule: return CD_CAPSULE
    case .Box: return CD_BOX
    case .Cylinder: return CD_CYLINDER
    case .Hull: return CD_HULL
    case .Mesh,.Heightfield:
    }
    return 0
}

@(private) WET_DRY :: 4 // dry boxes a body can be in at once; more are ignored
@(private) WET_COLUMN :: 4
@(private) WET_NEAR :: 8 // fluids whose box meets the box of a body that it looks for its waters among

// A water a body is in.
@(private)
Wet_Water :: struct {
    fluid:i32,     // slot
    segment:i32,   // of a path: the one nearest the body, where every substep starts to look
    surface:Plane, // free surface over the body: the plane that touches it over its center
    height:f32,    // of the surface over its center
    current:Vec3,
    density:f32,
}

// What a body in a fluid meets in a step, found once from its box and read in every substep: the water it
// is in and another it reaches across a border (a river into a lake), each with its own region, the second
// without what the first holds.
@(private)
Wet :: struct {
    waters:[2]Wet_Water,
    water_count:i32,
    character:i32, // slot of the character of the body, -1 for another body; a character is in its first water
    current:Vec3,  // that the drags pull toward: of its waters, by the drag of each in the last substep
    dry:[WET_DRY]i32, // over the first water in priority
    dry_count:i32,
    column:[WET_COLUMN]Fluid_Interval, // a character: the fluid in its column
    column_count:i32,
    volume:f32,     // m3 under the surface in the last substep
    supported:bool, // touches something: its own balance tells nothing
    restless:bool,  // floating, buoyancy and weight were out of balance in some substep: it does not sleep
}

// The planes of one part of the region of a fluid around a body, keeping dot(n,p)<=d: the fluid (sign 1),
// or the fluid inside a dry box, taken out (sign -1). Interface planes are those between fluid and air.
@(private) TERM_PLANES :: 12
@(private)
Fluid_Term :: struct {
    planes:[TERM_PLANES]Plane,
    count:i32,
    interface:u32, // bits of the planes
    sign:f32,
}

// What the submerged part of a body adds up to, relative to its center of mass in world axes.
@(private)
Fluid_Load :: struct {
    volume:f32,
    moment:Vec3,       // volume times its center
    cd_volume:f32,     // Cd times the volume, for the angular drag
    drag:f32,          // Cd times the area the submerged part shows to the flow
    area:f32,          // of the waterline
    area_moment:Vec3,  // area times its center
    area_xx,area_zz,area_xz:f32, // second moments of the waterline about the center of mass
}

// What a polyhedron clipped by planes keeps, in fixed buffers: faces as loops of points, counter-clockwise
// seen from outside, consecutive in `points`.
@(private) CLIP_POINTS :: 4096
@(private) CLIP_FACES :: 512
@(private) Clip_Face :: struct {first,count:u16,plane:i16} // plane: of the term that made the face, -1 one of the form
@(private)
Clip_Polyhedron :: struct {
    points:[CLIP_POINTS]Vec3,
    faces:[CLIP_FACES]Clip_Face,
    point_count,face_count:int,
}
@(private)
Clip_Scratch :: struct {
    buffers:[2]Clip_Polyhedron,
    cut:[CLIP_FACES]Vec3,
}

@(private) SPHERE_RINGS :: 6
@(private) SPHERE_SEGMENTS :: 12
@(private) PRISM_SEGMENTS :: 12
@(private) CAPSULE_SPHERES :: 16 // most spheres along a leaning capsule
@(private) VERTICAL_COS :: 0.99999 // an axis this close to +Y is upright for the closed forms

// The scratch the step needs for fluids, made once when the world first has one: a world without fluids
// does not hold it. False without memory.
@(private)
fluid_scratch_make :: proc(w:^World) -> bool {
    st:=&w.step
    if len(st.wet)>0 {return true}
    wet,error:=make([]Wet,w.desc.body_capacity,w.allocator)
    if error!=nil {return false}
    clips,clip_error:=make([]Clip_Scratch,w.desc.worker_count,w.allocator)
    if clip_error!=nil {
        delete(wet,w.allocator)
        return false
    }
    st.wet,st.clips=wet,clips
    return true
}

// Which fluid each awake body is in this step, and the parts of its region: what every substep reads.
@(private)
fluids_prepare :: proc(w:^World) {
    st:=&w.step
    st.fluid_active=w.fluid_count>0 && len(st.wet)>0
    if !st.fluid_active {return}
    world_parallel(w,st.awake_count,64,w,fluids_prepare_task)
    for &cs in st.characters[:st.character_count] {
        if cs.c<0 {continue}
        wet:=&st.wet[cs.c]
        if wet.water_count==0 {continue}
        wet.character=cs.character
        body:=&w.bodies[cs.body]
        water:=&wet.waters[0]
        column:[FLUID_COLUMN_DRY+1]Fluid_Interval
        count:=fluid_column(w,water.fluid,fluid_spot(w,water.fluid,body.position,water.segment),body.position,&column)
        wet.column_count=i32(min(count,WET_COLUMN))
        copy(wet.column[:],column[:wet.column_count])
    }
}

@(private)
fluids_prepare_task :: proc(data:rawptr,first,last,worker:int) #no_bounds_check {
    w:=(^World)(data)
    st:=&w.step
    for i in first..<last {
        st.wet[i]={character=-1}
        if st.params[i].inv_mass==0 {continue}
        wet_find(w,&w.bodies[st.awake[i]],st.bodies[i].v*st.dt,&st.wet[i])
    }
}

// The waters a body is in, by the rule of fluid_find at its center, at the lowest point of its box and at
// the corners of its bottom, among the fluids its box swept by `reach` meets; and the dry boxes it meets.
@(private)
wet_find :: proc "contextless" (w:^World,body:^Body,reach:Vec3,wet:^Wet) #no_bounds_check {
    wet^={character=-1}
    if body.shape_list<0 {return}
    shapes:=w.shapes[body.shape_list].aabb
    for s:=w.shapes[body.shape_list].next;s>=0;s=w.shapes[s].next {shapes=math.aabb_merge(shapes,w.shapes[s].aabb)}
    box:=math.aabb_merge(shapes,{shapes.min+reach,shapes.max+reach})
    near:[WET_NEAR]i32
    near_count:=0
    for &f,k in w.fluids[:w.fluid_high] {
        if f.generation&1==0 || f.density<=0 || !math.aabb_overlaps(f.bounds,box) || near_count==WET_NEAR {continue}
        near[near_count]=i32(k)
        near_count+=1
    }
    if near_count==0 {return}
    c,lo,hi:=body.center,shapes.min,shapes.max
    for probe in ([6]Vec3{c,{c.x,lo.y,c.z},lo,{hi.x,lo.y,lo.z},{lo.x,lo.y,hi.z},{hi.x,lo.y,hi.z}}) {
        fluid,_:=fluid_find(w,probe,near[:near_count])
        if fluid<0 || wet.water_count>0 && wet.waters[0].fluid==fluid {continue}
        spot:=fluid_spot(w,fluid,c)
        wet.waters[wet.water_count]={fluid=fluid,segment=spot.segment,surface={spot.normal,dot(spot.normal,Vec3{c.x,spot.top,c.z})},height=spot.top,current=spot.current,density=w.fluids[fluid].density}
        wet.water_count+=1
        if wet.water_count==len(wet.waters) {break}
    }
    if wet.water_count==0 {return}
    wet.current=wet.waters[0].current
    for key:=body.contact_list;key>=0; {
        contact:=&w.contacts[key>>1]
        key=contact.edges[key&1].next
        if contact.flags&{.Touching,.Overlap}=={.Touching} {wet.supported=true;break}
    }
    priority:=w.fluids[wet.waters[0].fluid].priority
    for &d,k in w.fluids[:w.fluid_high] {
        if d.generation&1==0 || d.density>0 || d.priority<=priority || wet.dry_count==WET_DRY {continue}
        if !math.aabb_overlaps(d.bounds,box) {continue}
        wet.dry[wet.dry_count]=i32(k)
        wet.dry_count+=1
    }
}

// A body in a fluid after the last step: what of it is under the surface, for what shows the water
// moving (splashes, wakes); nothing of it goes back to the simulation.
Fluid_Body :: struct {
    body:Body_Handle,
    user_data:u64,
    center:Vec3,   // of mass
    velocity:Vec3,
    volume:f32,    // m3 under the surface
    whole:f32,     // m3 of the body: of its shapes with mass, or of a character its mass over its density
    surface:f32,   // height of the surface of its fluid over its center
    reach:f32,     // m from its center to the farthest point of its shapes
}

// The awake bodies the last step found in a fluid, in the order of the step; writes up to len(out) of them
// after the first `skip` and returns how many there are in all.
fluid_bodies :: proc(w:^World,out:[]Fluid_Body,skip:=0) -> int {
    st:=&w.step
    if !st.fluid_active {return 0}
    count:=0
    for index,i in st.awake[:st.awake_count] {
        wet:=&st.wet[i]
        if wet.water_count==0 {continue}
        if at:=count-skip;at>=0 && at<len(out) {
            body:=&w.bodies[index]
            whole:f32
            if wet.character>=0 {
                d:=&w.characters[wet.character].desc
                if d.density>0 {whole=d.mass/d.density}
            } else {
                for s:=body.shape_list;s>=0;s=w.shapes[s].next {
                    if w.shapes[s].density<=0 {continue}
                    volume,_:=shape_volume(w,&w.shapes[s])
                    whole+=volume
                }
            }
            out[at]={body=body_handle(w,index),user_data=body.user_data,center=body.center,velocity=body.linear_velocity,
                volume=wet.volume,whole=whole,surface=wet.waters[0].height,reach=body.max_extent}
        }
        count+=1
    }
    return count
}

// The accelerations the fluids give an awake body at the start of a substep, and its implicit drags: k
// such that dv/dt = -k |v-u| (v-u), u the current of the drags (Wet.current), and dw/dt = -angular |w| I^-1 w.
@(private)
fluid_forces :: proc(w:^World,i:int,worker:int) -> (linear,angular:Vec3,k,angular_k:f32) #no_bounds_check {
    st:=&w.step
    wet:=&st.wet[i]
    sb:=&st.bodies[i]
    params:=&st.params[i]
    body:=&w.bodies[st.awake[i]]
    g:=body.gravity_scale*body_gravity_of(w,body)
    reach:=body.max_extent
    force,torque,pulled:Vec3
    wet.volume=0
    for &water,j in wet.waters[:wet.character>=0?1:wet.water_count] {
        rho:=water.density
        flow:=sb.v-water.current
        load:Fluid_Load
        if wet.character>=0 {
            load=character_load(w,wet,body,sb,flow)
        } else {
            load=body_load(w,body,body.center+sb.dp,sb.dq*params.q0,wet,j,flow,&st.clips[worker])
        }
        drag:=0.5*rho*load.drag*params.inv_mass
        k+=drag
        pulled+=drag*water.current
        if load.volume<=0 {continue}
        wet.volume+=load.volume
        angular_k+=0.5*rho*load.cd_volume*reach*reach
        center:=load.moment/load.volume
        buoyancy:=-rho*load.volume*g
        force+=buoyancy
        torque+=cross(center,buoyancy)
        if gravity:=length(g);load.area>0 && gravity>0 {
            // A pressure against the vertical velocity of each point of the waterline.
            beta:=2*FLUID_DAMPING_RATIO*rho*cmath.sqrt(gravity*load.volume/load.area)
            c:=load.area_moment/load.area
            xx:=load.area_xx-load.area*c.x*c.x
            zz:=load.area_zz-load.area*c.z*c.z
            xz:=load.area_xz-load.area*c.x*c.z
            om:=sb.w
            heave:=-beta*load.area*dot(sb.v+cross(om,c)-water.current,UP)*UP
            force+=heave
            torque+=cross(c,heave)-beta*Vec3{zz*om.x-xz*om.z,0,xx*om.z-xz*om.x}
        }
    }
    wet.current=wet.water_count>1 && wet.character<0 && k>0?pulled/k:wet.waters[0].current
    if wet.volume<=0 {return}
    linear=params.inv_mass*force
    angular=params.inv_inertia*torque
    // Floating still is not enough to sleep: it must also stay so for the time to sleep.
    if !wet.supported && TIME_TO_SLEEP*max(length(linear+g),length(angular)*body.max_extent)>body.sleep_threshold {wet.restless=true}
    return
}

// What of a body with its center of mass at com and turned by q is in its water `water`, relative to com.
@(private)
body_load :: proc(w:^World,body:^Body,com:Vec3,q:Quat,wet:^Wet,water:int,flow:Vec3,clip:^Clip_Scratch) -> (load:Fluid_Load) {
    terms:[1+WET_DRY]Fluid_Term
    count:=fluid_terms(w,wet,water,com,&terms)
    frame:=Transform{-q_rotate(q,body.local_center),q} // the body frame, relative to the center of mass
    for s:=body.shape_list;s>=0;s=w.shapes[s].next {
        shape:=&w.shapes[s]
        if shape.density<=0 {continue}
        shape_load(w,shape,xf_mul(frame,shape.local),terms[:count],flow,clip,&load)
    }
    return
}

// The parts of the region of one water of a body, with planes relative to its center of mass: the water, less
// the dry boxes over it of the first water, or less the first water of the second.
@(private)
fluid_terms :: proc "contextless" (w:^World,wet:^Wet,water:int,com:Vec3,terms:^[1+WET_DRY]Fluid_Term) -> int #no_bounds_check {
    shift :: #force_inline proc "contextless" (p:Plane,com:Vec3) -> Plane {return {p.n,p.d-dot(p.n,com)}}
    // The surface of a water and the walls and floor of its shape.
    region :: proc "contextless" (w:^World,water:^Wet_Water,com:Vec3,term:^Fluid_Term) {
        term.planes[term.count]=shift(water.surface,com)
        term.count+=1
        f:=&w.fluids[water.fluid]
        if f.shape==.Path {
            spot:=path_spot(fluid_points(w,water.fluid),com.x,com.z,water.segment)
            water.segment=spot.segment
            for plane in path_planes(spot) {
                term.planes[term.count]=shift(plane,com)
                term.count+=1
            }
        } else if f.shape==.Box {
            for plane,k in fluid_box_planes(f) {
                if k==3 {continue} // the top is the surface
                term.planes[term.count]=shift(plane,com)
                term.count+=1
            }
        }
    }
    fluid:=&terms[0]
    fluid^={sign=1,interface=1}
    region(w,&wet.waters[water],com,fluid)
    if water>0 {
        terms[1]=fluid^
        terms[1].sign=-1
        region(w,&wet.waters[0],com,&terms[1])
        return 2
    }
    count:=1
    for d in wet.dry[:wet.dry_count] {
        term:=&terms[count]
        term^=fluid^
        term.sign=-1
        for plane,k in fluid_box_planes(&w.fluids[d]) {
            if k==2 {term.interface|=1<<u32(term.count)} // the floor of the air is the surface under it
            term.planes[term.count]=shift(plane,com)
            term.count+=1
        }
        count+=1
    }
    return count
}

// Adds to `load` what one shape, at `xf` relative to the center of mass, has in the region of the terms.
@(private)
shape_load :: proc(w:^World,shape:^Shape,xf:Transform,terms:[]Fluid_Term,flow:Vec3,clip:^Clip_Scratch,load:^Fluid_Load) #no_bounds_check {
    full,local_center:=shape_volume(w,shape)
    if full<=0 {return}
    cd:=shape.drag
    speed:=length(flow)
    d:=speed>0?flow/speed:Vec3{}
    reach:=shape_extent(w,shape,xf_point(shape.local,local_center))
    center:=xf_point(xf,local_center)
    shown:=shape_shown(w,shape,xf,d)
    for &term in terms {
        part:Fluid_Load
        crossing:u32
        inside:=true
        for plane,k in term.planes[:term.count] {
            distance:=dot(plane.n,center)-plane.d
            if distance>=reach {inside=false;break}
            if distance>-reach {crossing|=1<<u32(k)}
        }
        if !inside {continue}
        if crossing==0 {
            part.volume,part.moment,part.drag=full,full*center,shown
        } else {
            switch shape.type {
            case .Box:
                storage:Box_Hull
                hull:=box_hull(&storage,shape.size)
                polyhedron_hull(&clip.buffers[0],&hull,xf)
                part=polyhedron_load(clip,&term,crossing,d)
            case .Hull:
                polyhedron_hull(&clip.buffers[0],&w.hulls[shape.resource].hull,xf)
                part=polyhedron_load(clip,&term,crossing,d)
            case .Sphere:
                part=sphere_load(shape.size.x,center,&term,crossing,d,clip)
            case .Capsule,.Cylinder:
                axis:=q_rotate(xf.q,UP)
                r,half:=shape.size.x,shape.size.y
                capsule:=shape.type==.Capsule
                if abs(axis.y)>=VERTICAL_COS && term_horizontal(&term,crossing) {
                    part=revolution_load(r,half,capsule,center,&term,crossing)
                } else if capsule {
                    part=capsule_spheres_load(r,half,center,axis,&term,crossing,d,clip)
                } else {
                    polyhedron_prism(&clip.buffers[0],r*PRISM_SCALE,half,xf)
                    part=polyhedron_load(clip,&term,crossing,d)
                }
            case .Mesh,.Heightfield:
            }
            // A curved form shows the flow the share of its area that it has of its volume.
            if shape.type!=.Box && shape.type!=.Hull {part.drag=shown*min(part.volume/full,1)}
        }
        load.volume+=term.sign*part.volume
        load.moment+=term.sign*part.moment
        load.drag+=term.sign*cd*part.drag
        load.cd_volume+=term.sign*cd*part.volume
        load.area+=part.area
        load.area_moment+=part.area_moment
        load.area_xx+=part.area_xx
        load.area_zz+=part.area_zz
        load.area_xz+=part.area_xz
    }
    load.drag=max(load.drag,0)
}

// The area a whole shape shows to a flow along d.
@(private)
shape_shown :: proc "contextless" (w:^World,shape:^Shape,xf:Transform,d:Vec3) -> f32 {
    switch shape.type {
    case .Sphere:
        return PI*shape.size.x*shape.size.x
    case .Capsule,.Cylinder:
        r,half:=shape.size.x,shape.size.y
        along:=abs(dot(q_rotate(xf.q,UP),d))
        across:=cmath.sqrt(max(1-along*along,0))
        if shape.type==.Capsule {return PI*r*r+4*r*half*across}
        return PI*r*r*along+4*r*half*across
    case .Box:
        e:=shape.size
        l:=q_inv_rotate(xf.q,d)
        return 4*(e.y*e.z*abs(l.x)+e.x*e.z*abs(l.y)+e.x*e.y*abs(l.z))
    case .Hull:
        hull:=&w.hulls[shape.resource].hull
        l:=q_inv_rotate(xf.q,d)
        // Half the sum of the projected areas of the faces.
        total:f32
        for first,f in hull.face_edges {
            e:=first
            a:=hull.vertices[hull.edges[e].origin]
            e=hull.edges[e].next
            b:=hull.vertices[hull.edges[e].origin]
            for e=hull.edges[e].next;e!=first;e=hull.edges[e].next {
                c:=hull.vertices[hull.edges[e].origin]
                total+=abs(dot(cross(b-a,c-a),l))
                b=c
            }
            _=f
        }
        return 0.25*total
    case .Mesh,.Heightfield:
    }
    return 0
}

// Whether the crossing planes of a term are all horizontal: the closed forms of upright solids.
@(private)
term_horizontal :: proc "contextless" (term:^Fluid_Term,crossing:u32) -> bool {
    for plane,k in term.planes[:term.count] {
        if crossing&(1<<u32(k))!=0 && abs(plane.n.y)<VERTICAL_COS {return false}
    }
    return true
}

// The waterline of a disc of radius² a2 at (c.x, plane height, c.z), to the side `sign` of the load.
@(private)
disc_area :: proc "contextless" (load:^Fluid_Load,c:Vec3,a2,sign:f32) {
    area:=sign*PI*a2
    load.area+=area
    load.area_moment+=area*c
    load.area_xx+=area*(c.x*c.x+0.25*a2)
    load.area_zz+=area*(c.z*c.z+0.25*a2)
    load.area_xz+=area*c.x*c.z
}

// The part of an upright solid of revolution between the horizontal crossing planes of a term: a cylinder
// of half height `half`, closed by hemispheres of radius r when `caps` (half 0: a sphere).
@(private)
revolution_load :: proc "contextless" (r,half:f32,caps:bool,center:Vec3,term:^Fluid_Term,crossing:u32) -> (load:Fluid_Load) #no_bounds_check {
    lo,hi:=-max(f32),max(f32)
    lo_plane,hi_plane:=-1,-1
    for plane,k in term.planes[:term.count] {
        if crossing&(1<<u32(k))==0 {continue}
        height:=plane.d/plane.n.y-center.y
        if plane.n.y>0 {
            if height<hi {hi,hi_plane=height,k}
        } else if height>lo {lo,lo_plane=height,k}
    }
    top:=half+(caps?r:0)
    lo,hi=max(lo,-top),min(hi,top)
    if !(hi>lo) {return}
    volume,moment:=revolution_slab(r,half,caps,lo,hi)
    load.volume=volume
    load.moment=volume*center+Vec3{0,moment,0}
    for k in ([2]int{hi_plane,lo_plane}) {
        if k<0 || term.interface&(1<<u32(k))==0 {continue}
        height:=k==hi_plane?hi:lo
        a2:=revolution_radius2(r,half,caps,height)
        if a2>0 {disc_area(&load,center+Vec3{0,height,0},a2,term.sign*term.planes[k].n.y)}
    }
    return
}

// Volume and first moment along the axis of the part of an upright solid of revolution between heights
// lo and hi from its center.
@(private)
revolution_slab :: proc "contextless" (r,half:f32,caps:bool,lo,hi:f32) -> (volume,moment:f32) {
    // A sphere of radius r centered at 0, between a and b inside [-r, r].
    sphere :: proc "contextless" (r,a,b:f32) -> (volume,moment:f32) {
        v :: proc "contextless" (r,y:f32) -> f32 {return PI*(r*r*y-y*y*y/3)}
        m :: proc "contextless" (r,y:f32) -> f32 {return PI*(0.5*r*r*y*y-0.25*y*y*y*y)}
        return v(r,b)-v(r,a),m(r,b)-m(r,a)
    }
    top:=half+(caps?r:0)
    lo,hi:=max(lo,-top),min(hi,top)
    if !(hi>lo) {return}
    a,b:=max(lo,-half),min(hi,half)
    if b>a {
        volume+=PI*r*r*(b-a)
        moment+=0.5*PI*r*r*(b*b-a*a)
    }
    if !caps {return}
    if lo< -half {
        cv,cm:=sphere(r,max(lo,-half-r)+half,min(hi,-half)+half)
        volume+=cv
        moment+=cm-half*cv
    }
    if hi>half {
        cv,cm:=sphere(r,max(lo,half)-half,min(hi,half+r)-half)
        volume+=cv
        moment+=cm+half*cv
    }
    return
}

@(private)
revolution_radius2 :: proc "contextless" (r,half:f32,caps:bool,height:f32) -> f32 {
    if abs(height)<=half {return r*r}
    if !caps {return 0}
    y:=abs(height)-half
    return max(r*r-y*y,0)
}

// A sphere: in closed form when the crossing planes are horizontal, as a polyhedron of its volume when a
// wall cuts it.
@(private)
sphere_load :: proc(r:f32,center:Vec3,term:^Fluid_Term,crossing:u32,d:Vec3,clip:^Clip_Scratch) -> Fluid_Load {
    if term_horizontal(term,crossing) {return revolution_load(r,0,true,center,term,crossing)}
    polyhedron_sphere(&clip.buffers[0],r*SPHERE_SCALE,center)
    return polyhedron_load(clip,term,crossing,d)
}

// A leaning capsule as spheres along its axis, each standing for an equal share of its volume.
@(private)
capsule_spheres_load :: proc(r,half:f32,center,axis:Vec3,term:^Fluid_Term,crossing:u32,d:Vec3,clip:^Clip_Scratch) -> (load:Fluid_Load) {
    count:=clamp(1+int(cmath.ceil(2*half/r)),2,CAPSULE_SPHERES)
    sphere:=4.0/3*PI*r*r*r
    share:=(PI*r*r*2*half+sphere)/(f32(count)*sphere)
    for k in 0..<count {
        c:=center+axis*(half*(2*f32(k)/f32(count-1)-1))
        crossed:u32
        for plane,p in term.planes[:term.count] {
            distance:=dot(plane.n,c)-plane.d
            if distance>=r {crossed=~u32(0);break}
            if distance>-r {crossed|=1<<u32(p)}
        }
        part:Fluid_Load
        if crossed==~u32(0) {continue}
        if crossed==0 {part.volume,part.moment=sphere,sphere*c} else {part=sphere_load(r,c,term,crossed,d,clip)}
        load.volume+=share*part.volume
        load.moment+=share*part.moment
        load.area+=share*part.area
        load.area_moment+=share*part.area_moment
        load.area_xx+=share*part.area_xx
        load.area_zz+=share*part.area_zz
        load.area_xz+=share*part.area_xz
    }
    return
}

// A character: the volume of its body, mass over density, by the share of a capsule from its feet to its
// head under the surface of its column, upright in closed form.
@(private)
character_load :: proc "contextless" (w:^World,wet:^Wet,body:^Body,sb:^Solver_Body,flow:Vec3) -> (load:Fluid_Load) {
    ch:=&w.characters[wet.character]
    d:=&ch.desc
    feet:=body.position.y+sb.dp.y
    column:=wet.column[:wet.column_count]
    share:=body_submersion(d,feet,column)
    if share<=0 {return}
    r:=d.radius
    com:=body.center.y+sb.dp.y // on the axis of the body
    if d.density>0 {load.volume=d.mass/d.density*share}
    load.moment=load.volume*Vec3{0,feet+0.5*d.height-com,0}
    speed:=length(flow)
    across:f32=1
    if speed>0 {across=cmath.sqrt(max(1-flow.y*flow.y/(speed*speed),0))}
    load.drag=d.drag*(PI*r*r+2*r*(d.height-2*r)*across)*share
    if load.volume<=0 {return}
    for stretch in column {
        if stretch.top<=feet || stretch.top>=feet+d.height {continue}
        a2:=revolution_radius2(r,0.5*d.height-r,true,stretch.top-feet-0.5*d.height)
        disc_area(&load,{0,stretch.top-com,0},a2,1)
    }
    return
}

// Loads a hull at xf into a polyhedron.
@(private)
polyhedron_hull :: proc "contextless" (p:^Clip_Polyhedron,hull:^Hull,xf:Transform) #no_bounds_check {
    p.point_count,p.face_count=0,0
    for first in hull.face_edges {
        start:=p.point_count
        e:=first
        for {
            p.points[p.point_count]=xf_point(xf,hull.vertices[hull.edges[e].origin])
            p.point_count+=1
            e=hull.edges[e].next
            if e==first {break}
        }
        p.faces[p.face_count]={u16(start),u16(p.point_count-start),-1}
        p.face_count+=1
    }
}

// A sphere as rings of quads between two fans, its vertices at radius r.
@(private)
polyhedron_sphere :: proc "contextless" (p:^Clip_Polyhedron,r:f32,center:Vec3) #no_bounds_check {
    p.point_count,p.face_count=0,0
    at :: proc "contextless" (ring,segment:int,r:f32,center:Vec3) -> Vec3 {
        if ring==0 {return center+{0,r,0}}
        if ring==SPHERE_RINGS {return center-{0,r,0}}
        sp,cp:=cmath.sincos(PI*f32(ring)/SPHERE_RINGS)
        st,ct:=cmath.sincos(2*PI*f32(segment%SPHERE_SEGMENTS)/SPHERE_SEGMENTS)
        return center+r*Vec3{sp*ct,cp,-sp*st}
    }
    for ring in 0..<SPHERE_RINGS {
        for segment in 0..<SPHERE_SEGMENTS {
            start:=p.point_count
            corners:=[4]Vec3{at(ring,segment,r,center),at(ring+1,segment,r,center),at(ring+1,segment+1,r,center),at(ring,segment+1,r,center)}
            for corner,k in corners {
                if ring==0 && k==3 || ring==SPHERE_RINGS-1 && k==2 {continue}
                p.points[p.point_count]=corner
                p.point_count+=1
            }
            p.faces[p.face_count]={u16(start),u16(p.point_count-start),-1}
            p.face_count+=1
        }
    }
}

// A cylinder of half height `half` along the Y axis of xf as a prism whose vertices are at radius r.
@(private)
polyhedron_prism :: proc "contextless" (p:^Clip_Polyhedron,r,half:f32,xf:Transform) #no_bounds_check {
    p.point_count,p.face_count=0,0
    rim :: proc "contextless" (k:int,y,r:f32) -> Vec3 {
        s,c:=cmath.sincos(2*PI*f32(k%PRISM_SEGMENTS)/PRISM_SEGMENTS)
        return {r*c,y,-r*s}
    }
    for side in 0..<PRISM_SEGMENTS {
        start:=p.point_count
        for corner in ([4]Vec3{rim(side,half,r),rim(side,-half,r),rim(side+1,-half,r),rim(side+1,half,r)}) {
            p.points[p.point_count]=xf_point(xf,corner)
            p.point_count+=1
        }
        p.faces[p.face_count]={u16(start),4,-1}
        p.face_count+=1
    }
    for cap in 0..<2 {
        start:=p.point_count
        for k in 0..<PRISM_SEGMENTS {
            p.points[p.point_count]=xf_point(xf,cap==0?rim(k,half,r):rim(PRISM_SEGMENTS-k,-half,r))
            p.point_count+=1
        }
        p.faces[p.face_count]={u16(start),PRISM_SEGMENTS,-1}
        p.face_count+=1
    }
}

// The scales that give the polyhedra the volume of the form they stand for: a prism of twelve sides holds
// 3 r² where a cylinder holds pi r², and the sphere of polyhedron_sphere (2 + sqrt(3)) r³ where a sphere
// holds 4/3 pi r³.
@(private) PRISM_SCALE :: 1.0233267079464885  // sqrt(pi/3)
@(private) SPHERE_SCALE :: 1.0392348145638028 // cbrt(4/3 pi / (2 + sqrt(3)))

// Clips the polyhedron in the first buffer by the crossing planes of a term and sums what is left.
@(private)
polyhedron_load :: proc(clip:^Clip_Scratch,term:^Fluid_Term,crossing:u32,d:Vec3) -> (load:Fluid_Load) #no_bounds_check {
    src,dst:=&clip.buffers[0],&clip.buffers[1]
    for plane,k in term.planes[:term.count] {
        if crossing&(1<<u32(k))==0 {continue}
        kept,fits:=clip_plane(src,dst,plane,i16(k),clip.cut[:])
        if !kept || !fits {return}
        src,dst=dst,src
    }
    // Tetrahedra from one point of the polyhedron, which keeps the sums small.
    origin:=src.points[0]
    volume:f32
    moment:Vec3
    projected:f32
    for face in src.faces[:src.face_count] {
        points:=src.points[face.first:][:face.count]
        a:=points[0]
        normal:Vec3
        for k in 1..<len(points)-1 {
            b,c:=points[k],points[k+1]
            n:=cross(b-a,c-a)
            normal+=n
            v:=dot(a-origin,n)
            volume+=v
            moment+=v*(origin+a+b+c)
        }
        projected+=abs(dot(normal,d))
        if face.plane>=0 && term.interface&(1<<u32(face.plane))!=0 {polygon_area(&load,points,term.sign*term.planes[face.plane].n.y)}
    }
    if volume<=0 {return {}}
    load.volume=volume/6
    load.moment=moment/24
    load.drag=0.25*projected
    return
}

// The waterline of a horizontal face, to the side `sign` of the load: area and moments over (x, z).
@(private)
polygon_area :: proc "contextless" (load:^Fluid_Load,points:[]Vec3,sign:f32) #no_bounds_check {
    area,mx,mz,xx,zz,xz,y:f32
    for a,k in points {
        b:=points[(k+1)%len(points)]
        c:=a.x*b.z-b.x*a.z
        area+=c
        mx+=(a.x+b.x)*c
        mz+=(a.z+b.z)*c
        xx+=(a.x*a.x+a.x*b.x+b.x*b.x)*c
        zz+=(a.z*a.z+a.z*b.z+b.z*b.z)*c
        xz+=(a.x*b.z+2*a.x*a.z+2*b.x*b.z+b.x*a.z)*c
        y+=a.y
    }
    if area==0 {return}
    s:=sign*(area>0?f32(1):-1)
    load.area+=s*0.5*area
    load.area_moment+=s*Vec3{mx/6,0.5*area*y/f32(len(points)),mz/6}
    load.area_xx+=s*xx/12
    load.area_zz+=s*zz/12
    load.area_xz+=s*xz/24
}

// Cuts src by a plane, keeping dot(n,p)<=d, into dst, closing the cut with a face tagged `tag`. kept is
// false when nothing is left; fits is false when the buffers are too small.
@(private)
clip_plane :: proc "contextless" (src,dst:^Clip_Polyhedron,plane:Plane,tag:i16,cut:[]Vec3) -> (kept,fits:bool) #no_bounds_check {
    dst.point_count,dst.face_count=0,0
    cuts:=0
    for face in src.faces[:src.face_count] {
        points:=src.points[face.first:][:face.count]
        start:=dst.point_count
        if dst.point_count+len(points)+2>CLIP_POINTS {return false,false}
        a:=points[len(points)-1]
        da:=dot(plane.n,a)-plane.d
        for b in points {
            db:=dot(plane.n,b)-plane.d
            if (da<=0)!=(db<=0) {
                crossing:=a+(b-a)*(da/(da-db))
                dst.points[dst.point_count]=crossing
                dst.point_count+=1
                if cuts<len(cut) {cut[cuts]=crossing;cuts+=1}
            }
            if db<=0 {
                dst.points[dst.point_count]=b
                dst.point_count+=1
            }
            a,da=b,db
        }
        count:=dst.point_count-start
        if count<3 {dst.point_count=start;continue}
        if dst.face_count>=CLIP_FACES-1 {return false,false}
        dst.faces[dst.face_count]={u16(start),u16(count),face.plane}
        dst.face_count+=1
    }
    if dst.face_count==0 {return false,true}
    if cuts<3 {return true,true}
    // The cut is convex: its points in order of angle about their mean, counter-clockwise seen along n.
    mean:Vec3
    for p in cut[:cuts] {mean+=p}
    mean/=f32(cuts)
    u:=perp(plane.n)
    v:=cross(plane.n,u)
    angles:[CLIP_FACES]f32
    for k in 0..<cuts {
        r:=cut[k]-mean
        angles[k]=cmath.atan2(dot(r,v),dot(r,u))
        for at:=k;at>0 && angles[at-1]>angles[at];at-=1 {
            angles[at-1],angles[at]=angles[at],angles[at-1]
            cut[at-1],cut[at]=cut[at],cut[at-1]
        }
    }
    start:=dst.point_count
    if start+cuts>CLIP_POINTS {return false,false}
    scale:=length(cut[0]-mean)
    for p in cut[:cuts] {
        if dst.point_count>start && length2(p-dst.points[dst.point_count-1])<=1e-12*scale*scale {continue}
        dst.points[dst.point_count]=p
        dst.point_count+=1
    }
    if dst.point_count-start>1 && length2(dst.points[start]-dst.points[dst.point_count-1])<=1e-12*scale*scale {dst.point_count-=1}
    if dst.point_count-start<3 {dst.point_count=start;return true,true}
    dst.faces[dst.face_count]={u16(start),u16(dst.point_count-start),tag}
    dst.face_count+=1
    return true,true
}
