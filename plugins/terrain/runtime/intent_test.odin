package terrain

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"

// The height of the surface of a source under x, z, whatever it is made of.
@(private="file")
surface_under :: proc(s:^Source,x,z:f32) -> (height:f32,found:bool) {
    point,_,hit:=source_ray(s,{x,HEIGHT_LIMIT*0.25,z},{0,-1,0})
    return point.y,hit
}

// Ground with its top at 0: a flat Heightfield, or the block of a new Volume.
@(private="file")
intent_source :: proc(t:^testing.T,s:^Source,kind:Source_Kind) -> bool {
    return testing.expect(t,source_make(s,kind,kind==.Volume?[3]int{33,33,33}:[3]int{33,1,33},1,16))
}

// One brush does the same to the ground whatever holds it: a game does not
// choose it by the representation under it.
@(test)
one_brush_carves_adds_raises_and_flattens_a_heightfield_and_a_volume_alike :: proc(t:^testing.T) {
    Case :: struct {name:string,brush:Brush,middle,side:f32} // the surface under the brush after it, and 12 away
    cases:=[?]Case{
        {"carve a ball",{kind=.Carve,center={0,0,0},radius=4,amount=1},-4,0},
        {"add a ball",{kind=.Add,center={0,0,0},radius=4,amount=1},4,0},
        {"carve a box",{kind=.Carve,shape=.Box,center={0,0,0},extent={3,2,3},rotation=1,amount=1},-2,0},
        {"add a capsule",{kind=.Add,shape=.Capsule,center={-3,0,0},delta={6,0,0},radius=2,amount=1},2,0},
        {"raise",{kind=.Raise,center={0,0,0},radius=6,amount=1.5,falloff=.Constant},1.5,0},
        {"lower",{kind=.Lower,center={0,0,0},radius=6,amount=1.5,falloff=.Constant},-1.5,0},
        {"flatten",{kind=.Flatten,center={0,0,0},radius=6,amount=1,target=-1,falloff=.Constant},-1,0},
    }
    for c in cases {
        for kind in Source_Kind {
            s:Source;defer source_destroy(&s)
            if !intent_source(t,&s,kind) {return}
            change:=source_edit(&s,c.brush)
            testing.expectf(t,change.error==.None && change.changed,"%s of a %v: %v",c.name,kind,change.error)
            middle,found:=surface_under(&s,0.25,0.25)
            // A Volume reads its surface between samples a cell apart.
            testing.expectf(t,found && abs(middle-c.middle)<0.6,"%s of a %v leaves the ground at %v, not %v",c.name,kind,middle,c.middle)
            side,side_found:=surface_under(&s,12.25,0.25)
            testing.expectf(t,side_found && abs(side-c.side)<0.05,"%s of a %v moved the ground 12 m away to %v",c.name,kind,side)
        }
    }
    // A paint is one call too.
    for kind in Source_Kind {
        s:Source;defer source_destroy(&s)
        if !intent_source(t,&s,kind) || !testing.expect(t,source_layer_set(&s,1,LAYER_DEFAULT)) {return}
        testing.expectf(t,source_edit(&s,{kind=.Paint,center={0,0,0},radius=4,amount=1,layer=1,falloff=.Constant}).changed,"paint of a %v",kind)
        testing.expect(t,source_weights_at(&s,{0,0,0})[1]>0.9)
    }
}

// What a brush cannot be is an error that names the field and how to fix it,
// and changes nothing; so is a brush the representation lacks, which names
// the one to use.
@(test)
a_wrong_brush_is_an_error_that_says_what_failed_and_changes_nothing :: proc(t:^testing.T) {
    nan:=transmute(f32)u32(0x7fc00000)
    inf:=transmute(f32)u32(0x7f800000)
    good:=Brush{kind=.Carve,center={0,0,0},radius=3,amount=1}
    Case :: struct {name:string,brush:Brush,error:Edit_Error,says:string}
    cases:=[?]Case{
        {"a centre that is not a number",{kind=.Carve,center={nan,0,0},radius=3,amount=1},.Center,"center"},
        {"an infinite centre",{kind=.Raise,center={0,inf,0},radius=3,amount=1},.Center,"center"},
        {"no radius",{kind=.Carve,center={},amount=1},.Radius,"radius"},
        {"a radius that is not a number",{kind=.Smooth,center={},radius=nan,amount=1},.Radius,"radius"},
        {"a radius past the limit",{kind=.Raise,center={},radius=1e9,amount=1},.Radius,"radius"},
        {"no amount",{kind=.Carve,center={},radius=3},.Amount,"amount"},
        {"an amount that is not a number",{kind=.Lower,center={},radius=3,amount=nan},.Amount,"amount"},
        {"more than the whole shape",{kind=.Add,center={},radius=3,amount=2},.Amount,"amount"},
        {"a target that is not a number",{kind=.Flatten,center={},radius=3,amount=1,target=nan},.Target,"target"},
        {"a delta that is not a number",{kind=.Add,shape=.Capsule,center={},delta={0,nan,0},radius=3,amount=1},.Delta,"delta"},
        {"a box without a side",{kind=.Carve,shape=.Box,center={},extent={1,0,1},amount=1},.Extent,"extent"},
        {"a rotation that scales the box",{kind=.Carve,shape=.Box,center={},extent=1,amount=1,rotation=2},.Rotation,"rotation"},
        {"a rotation that is not a number",{kind=.Raise,center={},radius=3,amount=1,rotation=quaternion(w=nan,x=0,y=0,z=0)},.Rotation,"rotation"},
        {"a blend below zero",{kind=.Carve,center={},radius=3,amount=1,blend=-1},.Blend,"blend"},
        {"a hardness of one",{kind=.Raise,center={},radius=3,amount=1,hardness=1},.Falloff,"hardness"},
        {"a shape that is none",{kind=.Carve,shape=Brush_Shape(9),center={},radius=3,amount=1},.Falloff,"shape"},
        {"a kind that is none",{kind=Brush_Kind(200),center={},radius=3,amount=1},.Kind,"Raise to Thermal"},
        {"a layer the source lacks",{kind=.Paint,center={},radius=3,amount=1,layer=3},.Layer,"layer"},
        {"a terrace without steps",{kind=.Terrace,center={},radius=3,amount=1},.Terrace,"interval"},
        {"noise without a scale",{kind=.Noise,center={},radius=3,amount=1},.Noise,"scale"},
        {"a slope out of order",{kind=.Raise,center={},radius=3,amount=1,slope={1,0.5}},.Slope,"slope"},
    }
    for kind in Source_Kind {
        s,before:Source;defer source_destroy(&s);defer source_destroy(&before)
        if !intent_source(t,&s,kind) || !testing.expect(t,source_clone(&before,&s)) {return}
        for c in cases {
            if kind==.Volume && c.error==.Terrace {continue} // a Volume refuses the kind first
            change:=source_edit(&s,c.brush)
            testing.expectf(t,change.error==c.error && !change.changed,"%s on a %v: %v",c.name,kind,change.error)
            fix:=edit_error_fix(change.error,c.brush.kind)
            testing.expectf(t,strings.contains(fix,c.says),"%s: %q does not name %q",c.name,fix,c.says)
        }
        same:=true
        for z in 0..<int(s.samples.z) {for y in 0..<int(s.samples.y) {for x in 0..<int(s.samples.x) {same&&=(source_value(&s,{x,y,z}) or_else 0)==(source_value(&before,{x,y,z}) or_else 0)}}}
        testing.expectf(t,same,"a refused brush changed a %v",kind)
        // A brush that touches nothing is no error.
        away:=good;away.center={1000,0,1000}
        testing.expect_value(t,source_edit(&s,away),Change{})
    }
    // What a Volume lacks names the brush that does it there.
    volume:Source;defer source_destroy(&volume)
    if !intent_source(t,&volume,.Volume) {return}
    lacks:=[?]struct {brush:Brush,says:string}{
        {{kind=.Hole,center={},radius=2},"Carve opens it"},
        {{kind=.Fill,center={},radius=2},"Add closes it"},
        {{kind=.Ramp,center={},delta={4,1,0},radius=2,amount=1},"Add with a Capsule"},
        {{kind=.Terrace,center={},radius=2,amount=1,interval=1},"Flatten"},
        {{kind=.Erode,center={},radius=2,amount=1},"Smooth or Noise"},
        {{kind=.Thermal,center={},radius=2,amount=1,talus=0.5},"Thermal is of a Heightfield"},
    }
    for c in lacks {
        change:=source_edit(&volume,c.brush)
        testing.expect_value(t,change.error,Edit_Error.Kind)
        testing.expectf(t,strings.contains(edit_error_fix(change.error,c.brush.kind),c.says),"%v: %q",c.brush.kind,edit_error_fix(change.error,c.brush.kind))
    }
    // Every error has its fix.
    for error in Edit_Error {if error!=.None {testing.expectf(t,edit_error_fix(error,.Carve)!="","%v has no fix",error)}}
    // Random brushes never crash nor leave a value a source does not hold.
    seed:=u64(0x9e3779b97f4a7c15)
    next :: proc(seed:^u64) -> u32 {seed^=seed^*6364136223846793005+1442695040888963407;return u32(seed^>>32)}
    number :: proc(seed:^u64) -> f32 {
        switch next(seed)%8 {
        case 0: return transmute(f32)next(seed) // any bits: NaN, infinities, denormals
        case 1: return 0
        case 2: return f32(i32(next(seed)))*1e-3
        }
        return (f32(next(seed)%2000)-1000)*0.02
    }
    for kind in Source_Kind {
        s:Source;defer source_destroy(&s)
        if !intent_source(t,&s,kind) || !testing.expect(t,source_layer_set(&s,1,LAYER_DEFAULT)) {return}
        limit:=kind==.Volume?s.cell*SDF_BAND_CELLS:HEIGHT_LIMIT
        for _ in 0..<400 {
            b:Brush
            b.kind=Brush_Kind(next(&seed)%(u32(max(Brush_Kind))+3))
            b.shape=Brush_Shape(next(&seed)%4)
            b.falloff=auto_cast (next(&seed)%6)
            b.way=Brush_Way(next(&seed)%4)
            b.center={number(&seed),number(&seed),number(&seed)}
            b.delta={number(&seed),number(&seed),number(&seed)}
            b.extent={number(&seed),number(&seed),number(&seed)}
            b.radius,b.amount,b.target,b.blend,b.hardness=number(&seed),number(&seed),number(&seed),number(&seed),number(&seed)
            b.interval,b.riser,b.scale,b.turn=number(&seed),number(&seed),number(&seed),number(&seed)
            b.slope={number(&seed),number(&seed)}
            b.rotation=quaternion(w=number(&seed),x=number(&seed),y=number(&seed),z=number(&seed))
            b.layer=next(&seed)%6
            b.capped,b.toward,b.slope_invert=next(&seed)%2==0,next(&seed)%2==0,next(&seed)%2==0
            change:=source_edit(&s,b)
            if change.error!=.None {testing.expectf(t,!change.changed,"%v changed the source with error %v",b.kind,change.error)}
        }
        for z in 0..<int(s.samples.z) {for y in 0..<int(s.samples.y) {for x in 0..<int(s.samples.x) {
            value:=source_value(&s,{x,y,z}) or_else 0
            if !(abs(value)<=limit) {testing.expectf(t,false,"a %v holds %v at %v after random brushes",kind,value,[3]int{x,y,z});return}
        }}}
    }
}

// dig says at once what is wrong with a brush and asks for nothing; the same
// request digs the terrain under it, a Heightfield or a Volume, and a brush
// its terrain lacks is a problem of that terrain that names the brush to use.
@(test)
a_dig_request_edits_whichever_terrain_is_under_it_and_reports_what_it_cannot_do :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    ids:=[Source_Kind]base.Asset_Id{.Heightfield={71,1},.Volume={71,2}}
    for kind in Source_Kind {
        s:Source;defer source_destroy(&s)
        if !intent_source(t,&s,kind) {return}
        testing.expect_value(t,source_save(&s,fmt.tprintf("%s/intent_%v.terrain",root,kind),ids[kind],&types),asset.Error.None)
    }
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=8}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    // The Heightfield at the origin and the Volume 100 m along x.
    owners:[Source_Kind]core.Entity
    for kind in Source_Kind {
        owners[kind]=core.create(&w.entities)
        place:=core.TRANSFORM_IDENTITY
        place.position.x=f32(int(kind))*100
        core.add(&w.transforms,owners[kind],place)
        core.add(&w.worlds,owners[kind],core.World_Transform{transform={position=place.position,rotation=1,scale={1,1,1}}})
        core.add(&w.terrains,owners[kind],Terrain{source=ids[kind],solid=false})
    }
    test_world_settle(&w.w)
    terrain_test_update(&w,&resident,&app)
    nan:=transmute(f32)u32(0x7fc00000)
    testing.expect_value(t,dig(&w.terrain_requests,{kind=.Carve,center={nan,0,0},radius=3,amount=1}),Edit_Error.Center)
    testing.expect_value(t,dig(&w.terrain_requests,{kind=.Carve,center={0,0,0},radius=-3,amount=1}),Edit_Error.Radius)
    alpha:=Brush_Alpha{size=2,values={1,1,1,1}}
    testing.expect_value(t,dig(&w.terrain_requests,{kind=.Raise,center={0,0,0},radius=3,amount=1,alpha=&alpha}),Edit_Error.Alpha)
    testing.expect_value(t,len(w.terrain_requests.edits.items),0)
    // The same call, with no owner: the terrain the brush touches takes it.
    for kind in Source_Kind {
        testing.expect_value(t,dig(&w.terrain_requests,{kind=.Carve,center={f32(int(kind))*100,0,0},radius=4,amount=1}),Edit_Error.None)
    }
    testing.expect_value(t,dig(&w.terrain_requests,{kind=.Hole,center={100,0,0},radius=2}),Edit_Error.None)
    terrain_test_update(&w,&resident,&app)
    for kind in Source_Kind {
        entry:=data_find(&w.data,ids[kind])
        if !testing.expect(t,entry!=nil) {continue}
        // What no chunk shows left the memory: its pages are read again.
        testing.expect(t,source_region_read(&entry.source,{0,0,0},{32,32,32}))
        bottom,found:=surface_under(&entry.source,0.25,0.25)
        testing.expectf(t,found && abs(bottom+4)<0.6,"the dig of the %v reaches %v",kind,bottom)
    }
    lacks:=core.problem_find(&w.problems,owners[.Volume],"terrain.edit_kind")
    if testing.expect(t,lacks!=nil,"a hole of a Volume is a problem of its terrain") {
        text:=core.problem_text(lacks)
        testing.expect(t,strings.contains(text,"Carve opens it"),text)
    }
    testing.expect(t,core.problem_find(&w.problems,owners[.Heightfield],"terrain.edit_kind")==nil)
}
