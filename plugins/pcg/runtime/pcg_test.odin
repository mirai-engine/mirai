package pcg

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import pcg_lib "mirai:std/pcg"

@(test_world)
Pcg_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    worlds:core.Table(core.World_Transform),
    graphs:core.Table(Pcg_Graph),
    zones:core.Table(Pcg_Zone),
    volumes:core.Table(volume.Volume),
    splines:core.Table(volume.Spline),
    suppressed:core.Table(Pcg_Suppressed),
    pendings:core.Table(scene.Prefab_Pending),
    instances:core.Table(scene.Prefab_Instance),
    members:core.Table(scene.Prefab_Member),
    data:Pcg_Data,
    ground:Pcg_Ground,
    ground_requests:Pcg_Ground_Requests,
    suppressions:Pcg_Suppressions,
    suppress:Pcg_Suppress_Requests,
    promote:Pcg_Promote_Requests,
    streaming:scene.Streaming_Sources,
    queries:core.Ground_Queries,
    network:core.Network,
}

// A world of graphs, what they place (kept by world, as the application
// keeps it) and a ground that is the plane y = height when probe is on.
@(private="file")
Pcg_Test :: struct {
    using w:Pcg_World,
    generated:Pcg_Generated,
    problems:core.Problems,
    assets:^host.Assets,
    height:f32,
    probes:int,
}

@(private="file")
test_open :: proc(w:core.World_Read) -> (core.Ground_Query,bool) {
    probe :: proc(user:rawptr,origin,down:[3]f32) -> (hit:core.Ground_Hit,found:core.Ground_Found) {
        f:=cast(^Pcg_Test)user
        f.probes+=1
        return {point={origin.x,f.height,origin.z},normal={0,1,0},weights={0,255,0,0},layers={1={7,7}}},.Ground
    }
    return {user=w.data,probe=probe,spacing=1},true
}

@(private="file")
test_init :: proc(t:^testing.T,f:^Pcg_Test) -> bool {
    if !test_world_init(t,&f.w) {return false}
    f.network.role=.Server
    pcg_requests_serve(&f.suppress,&f.promote,&f.ground_requests,PCG_SETTINGS_DEFAULT,&f.problems)
    return true
}

@(private="file")
test_destroy :: proc(f:^Pcg_Test) {
    pcg_generated_free(&f.generated)
    test_world_destroy(&f.w)
}

@(private="file")
test_where :: proc(w:^Pcg_World) -> volume.Where {
    return {volumes=core.read(&w.volumes),worlds=core.read(&w.worlds),splines=core.read(&w.splines)}
}

// One frame of the library: suppressions and promotions, the ground, then what the graphs place.
@(private="file")
test_step :: proc(f:^Pcg_Test,phase:=core.Phase.Frame) {
    w:=&f.w
    f.probes=0
    at:=test_where(w)
    spawner:=scene.Spawner{core.commands(w,test_world_info(w)),f.assets,&f.problems}
    pcg_suppress(&w.suppressions,&w.suppress,&w.promote,&w.suppressed,core.read(&w.graphs),core.read(&w.ids),core.read(&w.worlds),core.ref(&f.generated),core.ref(&w.network),spawner,context.allocator)
    test_world_settle(w)
    pcg_ground(&w.ground,&w.ground_requests,core.ref(&w.data),core.read(&w.graphs),core.ref(&w.streaming),core.ref(&w.queries),core.read(&w.zones),at,{data=f},{phase=phase},nil,&f.problems)
    pcg_update(&f.generated,core.ref(&w.data),core.ref(&w.ground),core.ref(&w.suppressions),core.read(&w.graphs),core.read(&w.zones),core.read(&w.ids),at,{phase=phase},nil,context.allocator,&f.problems)
    clear(&w.queries.changed.items)
    // The begin of the next tick: the room of its requests.
    pcg_requests_serve(&w.suppress,&w.promote,&w.ground_requests,PCG_SETTINGS_DEFAULT,&f.problems)
}

// A graph of a source the data holds, at a place, with an Id.
@(private="file")
test_graph :: proc(f:^Pcg_Test,s:^Pcg_Source,id:base.Asset_Id,at:mm.Transform=mm.TRANSFORM_IDENTITY,entity_id:=base.Entity_Id(500)) -> core.Entity {
    if data_find(&f.data,id)==nil {
        f.data.made+=1
        append(&f.data.entries,Pcg_Data_Entry{id=id,epoch=f.data.made,loads=1,source=s^})
        s^={}
    }
    e:=core.create(&f.entities)
    core.add(&f.ids,e,core.Id{value=entity_id})
    core.add(&f.graphs,e,Pcg_Graph{source=id})
    core.add(&f.worlds,e,core.World_Transform{transform=at})
    test_world_settle(&f.w)
    return e
}

// A source of trees with saplings around them and bushes kept apart from both.
@(private="file")
forest :: proc(s:^Pcg_Source) -> (tree,sapling,bush:u32) {
    source_init(s)
    s.info.seed=11
    t:=source_layer_add(s,.Scatter,.Macro)
    t.density,t.radius,t.scale,t.asset,t.collides=0.02,2,{1,1},{3,3},true
    tree=t.id
    c:=source_layer_add(s,.Cascade,.Macro)
    c.parent_layer,c.density,c.radius,c.scale=tree,3,0.3,{1,1}
    sapling=c.id
    b:=source_layer_add(s,.Scatter,.Meso)
    b.density,b.radius,b.scale=1,0.5,{1,1}
    bush=b.id
    return
}

// A flat ground of a cell: the plane y = 0, nothing kept out.
@(private="file")
flat :: proc(cell_size:f32,heights:[]f32,kept:[]u64) -> Pcg_Ground_Cell {
    for &h in heights {h=0}
    for &k in kept {k=0}
    return {cell_size=cell_size,samples=9,heights=heights,weights=make([]Layer_Weights,len(heights),context.temp_allocator),kept=kept}
}

@(private="file")
unbounded :: proc() -> Pcg_Region {return {volume=volume.world(),pose=mm.TRANSFORM_IDENTITY}}

// What a cell of a source places on flat ground.
@(private="file")
place :: proc(t:^testing.T,s:^Pcg_Source,coord:[2]i32,suppressed:[]u64={},spans:[]Pcg_Span={},zones:[]Pcg_Zone_Placed={},loc:=#caller_location) -> [dynamic]Placed {
    scratch:Pcg_Scratch
    testing.expect(t,scratch_init(&scratch),loc=loc)
    defer scratch_destroy(&scratch)
    heights:[81]f32
    kept:[KEPT_WORDS]u64
    cin:=Pcg_Cell_Input{source=s,seed=s.info.seed,coord=coord,ground=flat(s.info.cell_size,heights[:],kept[:]),frame=linalg.MATRIX4F32_IDENTITY,domain=unbounded(),zones=zones,spans=spans,suppressed=suppressed,share=generated_share(s)}
    out:=make([dynamic]Placed,context.temp_allocator)
    testing.expect(t,cell_generate(&cin,&scratch,&out),loc=loc)
    return out
}

@(private="file")
of_layer :: proc(placed:[]Placed,layer:u32) -> [dynamic]Placed {
    out:=make([dynamic]Placed,context.temp_allocator)
    for p in placed {if p.layer==layer {append(&out,p)}}
    return out
}

@(private="file")
flat_distance :: proc(a,b:[3]f32) -> f32 {return linalg.length(a.xz-b.xz)}

// A .pcg comes back as it was written, programs compiled, and a file cut or
// damaged anywhere is refused without touching the source it would replace.
@(test)
a_pcg_asset_comes_back_as_it_was_written_and_damage_is_refused :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    s:Pcg_Source
    forest(&s)
    defer source_destroy(&s)
    s.info.ecotopes=2
    tree,_:=source_layer(&s,1)
    tree.ground_rule={enabled=true,slope={0,0.5},height={-10,90},layers={0={7,7}},weight=0.25}
    testing.expect(t,source_layer_texts(&s,1,"let n = fbm2(x*0.01, z*0.01, 4, 2, 0.5); clamp(n + 0.5 + mask(3) - ecotope(1), 0, 1)"))
    fence:=source_layer_add(&s,.Grammar,.Macro)
    fence.channel=1
    symbols:=[?]Grammar_Symbol_Def{grammar_symbol("Post",0.2,false,{9,1}),grammar_symbol("Rail",2,true,{9,2})}
    testing.expect(t,source_layer_texts(&s,fence.id,"","[Post, [Rail, Post]*]",symbols[:]))
    painted:=source_cell(&s,{-2,3},true)
    for k in 0..<PAINT_SAMPLES*PAINT_SAMPLES {append(&painted.density,u8(k*7));append(&painted.ecotopes,u8(k),u8(255-k%256))}
    source_cell(&s,{4,-1},true)
    data,error:=source_bytes(&s,{5,6},&types)
    defer delete(data)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    file:asset.Asset
    testing.expect_value(t,asset.asset_open(&file,data),asset.Error.None)
    back:Pcg_Source
    defer source_destroy(&back)
    id,issue:=source_read(&back,&file,&types)
    asset.asset_close(&file)
    testing.expect(t,issue.kind==.None && id==base.Asset_Id{5,6})
    testing.expect_value(t,back.info,s.info)
    if !testing.expect_value(t,len(back.layers),len(s.layers)) {return}
    for l,i in s.layers {
        b:=back.layers[i]
        testing.expect_value(t,b.params,l.params)
        testing.expect(t,b.field_expr==l.field_expr && b.grammar_expr==l.grammar_expr && slice.equal(b.grammar_symbols,l.grammar_symbols),"its texts come back")
    }
    testing.expect(t,len(back.compiled)==len(back.layers) && back.compiled[0].has_field && back.compiled[0].masks==1<<3 && back.compiled[3].has_grammar,"its programs are compiled on reading")
    if !testing.expect_value(t,len(back.cells),2) {return}
    testing.expect(t,back.cells[0].coord==[2]i32{4,-1} && back.cells[1].coord==[2]i32{-2,3},"in the order of z, then x")
    testing.expect(t,slice.equal(back.cells[1].density[:],painted.density[:]) && slice.equal(back.cells[1].ecotopes[:],painted.ecotopes[:]))
    // Cut at any length, or with any byte changed, a file is refused or read whole: the source stays.
    for length in 0..<len(data) {
        cut:asset.Asset
        if asset.asset_open(&cut,data[:length])!=.None {continue}
        _,refused:=source_read(&back,&cut,&types)
        asset.asset_close(&cut)
        testing.expect(t,refused.kind!=.None,"a cut file is refused")
    }
    damaged:=slice.clone(data,context.temp_allocator)
    rng:=mm.rng_make(77)
    for _ in 0..<400 {
        copy(damaged,data)
        for _ in 0..<4 {damaged[mm.random_below(&rng,u32(len(damaged)))]~=u8(1+mm.random_below(&rng,255))}
        other:asset.Asset
        if asset.asset_open(&other,damaged)!=.None {continue}
        read:Pcg_Source
        if _,ok:=source_read(&read,&other,&types);ok.kind==.None {testing.expect(t,source_valid(&read),"what reads is valid")}
        source_destroy(&read)
        asset.asset_close(&other)
    }
    testing.expect_value(t,len(back.layers),len(s.layers))
    // What does not validate is not written: an expression that does not compile, a radius past a quarter cell, a parent after its cascade.
    testing.expect(t,source_layer_texts(&s,1,"fbm2(x, z"))
    issue=source_issue(&s)
    testing.expect(t,issue.kind==.Field && issue.layer==1 && issue.field.kind==.Syntax)
    _,invalid:=source_bytes(&s,{5,6},&types)
    testing.expect_value(t,invalid,asset.Error.Invalid)
    testing.expect(t,source_layer_texts(&s,1,""))
    tree,_=source_layer(&s,1)
    tree.radius=s.info.cell_size
    testing.expect_value(t,source_issue(&s).kind,Pcg_Issue_Kind.Layer)
    tree.radius=2
    testing.expect(t,source_valid(&s))
    cascade,_:=source_layer(&s,2)
    cascade.parent_layer=3
    testing.expect_value(t,source_issue(&s).kind,Pcg_Issue_Kind.Layer)
    cascade.parent_layer=1
    fence,_=source_layer(&s,4)
    testing.expect(t,source_layer_texts(&s,4,"","[Post, Gate]",symbols[:]))
    testing.expect_value(t,source_issue(&s).kind,Pcg_Issue_Kind.Grammar)
}

// Fields: a layer stands where its viability says, from the frame x of each
// point, the mask of its zones or the ecotopes painted in its cell. Grammars
// split a span into modules, each in the cell of its middle, with ids from
// the spline, the span and the ordinal.
@(test)
fields_and_grammars_decide_where_a_layer_places :: proc(t:^testing.T) {
    s:Pcg_Source
    source_init(&s)
    defer source_destroy(&s)
    s.info.seed=3
    east:=source_layer_add(&s,.Scatter,.Macro)
    east.density=0.5
    testing.expect(t,source_layer_texts(&s,east.id,"select(x - 16, 1, 0)"))
    masked:=source_layer_add(&s,.Scatter,.Macro)
    masked.density=0.5
    testing.expect(t,source_layer_texts(&s,masked.id,"mask(2)"))
    fence:=source_layer_add(&s,.Grammar,.Macro)
    fence.channel=1
    symbols:=[?]Grammar_Symbol_Def{grammar_symbol("Post",0.2,false,{9,1}),grammar_symbol("Rail",2,true,{9,2})}
    testing.expect(t,source_layer_texts(&s,fence.id,"","[Post, [Rail, Post]*]",symbols[:]))
    if !testing.expect_value(t,source_compile(&s).kind,Pcg_Issue_Kind.None) {return}
    // A zone of channel 2 over x < 10.
    zone:=Pcg_Zone_Placed{region={volume=volume.box({5,100,100}),pose=mm.Transform{position={5,0,16},rotation=1,scale={1,1,1}}},zone={blend=0},channel=2,weight=1}
    zone.box=volume.bounds(zone.region.volume,zone.region.pose)
    zones:=[?]Pcg_Zone_Placed{zone}
    spans:=[?]Pcg_Span{{entity=900,span=0,channel=1,a={1,0,4},b={61,0,4}},{entity=900,span=1,channel=2,a={1,0,9},b={20,0,9}}}
    first:=place(t,&s,{0,0},spans=spans[:],zones=zones[:])
    second:=place(t,&s,{1,0},spans=spans[:],zones=zones[:])
    easts:=of_layer(first[:],1)
    testing.expect(t,len(easts)>20,"some stand")
    for p in easts {testing.expect(t,p.position.x>16,"none where the field says 0")}
    for p in of_layer(first[:],2) {testing.expect(t,p.position.x<10+1e-3,"none outside the zone of its mask")}
    testing.expect(t,len(of_layer(first[:],2))>5)
    posts,posts_next:=of_layer(first[:],3),of_layer(second[:],3)
    testing.expect(t,len(posts)>0 && len(posts_next)>0,"the span crosses both cells")
    ids:=make([dynamic]u64,context.temp_allocator)
    for p in posts {
        testing.expect(t,p.position.x>=1 && p.position.x<32,"each module in the cell of its middle")
        testing.expect(t,p.asset=={9,1} || p.asset=={9,2})
        append(&ids,p.id)
    }
    for p in posts_next {append(&ids,p.id)}
    slice.sort(ids[:])
    for i in 1..<len(ids) {testing.expect(t,ids[i]!=ids[i-1],"each module its own id")}
    key:=base.hash_mix(900,u64(3))
    testing.expect(t,slice.contains(ids[:],pcg_lib.grammar_span_id(key,0,0)),"the first module is named by the spline, the span and ordinal 0")
    // The same inputs give the same, and another seed other points.
    again:=place(t,&s,{0,0},spans=spans[:],zones=zones[:])
    testing.expect(t,slice.equal(again[:],first[:]))
    s.info.seed=4
    other:=place(t,&s,{0,0},spans=spans[:],zones=zones[:])
    testing.expect(t,!slice.equal(other[:],first[:]))
}

// Macro points keep their places, and Meso points keep apart from them by
// their exact radii across the borders of cells; the cascades grow around
// the points that stand, apart from them; the layers of a dither group share
// one set of points, each to one layer.
@(test)
meso_keeps_apart_from_macro_and_cascades_grow_around_their_parents :: proc(t:^testing.T) {
    s:Pcg_Source
    tree,sapling,bush:=forest(&s)
    defer source_destroy(&s)
    if !testing.expect_value(t,source_compile(&s).kind,Pcg_Issue_Kind.None) {return}
    trees:=make([dynamic]Placed,context.temp_allocator)
    middle:[dynamic]Placed
    for k in 0..<9 {
        coord:=[2]i32{i32(k%3)-1,i32(k/3)-1}
        placed:=place(t,&s,coord)
        if coord=={0,0} {middle=placed}
        append(&trees,..of_layer(placed[:],tree)[:])
    }
    bushes,saplings:=of_layer(middle[:],bush),of_layer(middle[:],sapling)
    testing.expect(t,len(bushes)>100 && len(saplings)>0 && len(of_layer(middle[:],tree))>0)
    for b in bushes {
        for tr in trees {testing.expect(t,flat_distance(b.position,tr.position)>=2.5-1e-3,"a bush stands no nearer to a tree than both radii, in any cell")}
        for sp in saplings {testing.expect(t,flat_distance(b.position,sp.position)>=0.8-1e-3,"nor to a sapling")}
    }
    for i in 0..<len(trees) {for j in i+1..<len(trees) {testing.expect(t,flat_distance(trees[i].position,trees[j].position)>=4-1e-3,"trees keep apart across cells")}}
    for sp in saplings {
        parent:=-1
        for tr,k in trees {if tr.id==sp.parent {parent=k}}
        if !testing.expect(t,parent>=0,"a sapling names a tree that stands") {continue}
        testing.expect(t,flat_distance(sp.position,trees[parent].position)>=2.3-1e-3,"beyond both reaches")
        testing.expect_value(t,sp.id>>32,u64(sapling))
    }
    // A dither group: two layers of one footprint share points, never both at one.
    d:Pcg_Source
    source_init(&d)
    defer source_destroy(&d)
    a:=source_layer_add(&d,.Scatter)
    a.density,a.dither_group=0.3,5
    b:=source_layer_add(&d,.Scatter)
    b.density,b.dither_group=0.3,5
    testing.expect(t,source_layer_texts(&d,b.id,"0.5"))
    if !testing.expect_value(t,source_compile(&d).kind,Pcg_Issue_Kind.None) {return}
    testing.expect_value(t,len(d.units),1)
    shared:=place(t,&d,{0,0})
    points:=make([dynamic]u64,context.temp_allocator)
    for p in shared {append(&points,p.id&0xffffffff)}
    slice.sort(points[:])
    for i in 1..<len(points) {testing.expect(t,points[i]!=points[i-1],"a point goes to one layer")}
    as,bs:=len(of_layer(shared[:],1)),len(of_layer(shared[:],2))
    testing.expect(t,as>bs && bs>0,"each by its share and viability")
}

// What is suppressed is taken out after the points kept apart: chopping a
// tree leaves its place empty, and no bush or sapling moves into it.
@(test)
suppressing_a_tree_never_grows_bushes_at_its_stump :: proc(t:^testing.T) {
    s:Pcg_Source
    tree,_,bush:=forest(&s)
    defer source_destroy(&s)
    if !testing.expect_value(t,source_compile(&s).kind,Pcg_Issue_Kind.None) {return}
    before:=place(t,&s,{2,-3})
    trees:=of_layer(before[:],tree)
    if !testing.expect(t,len(trees)>0) {return}
    chopped:=[?]u64{trees[0].id}
    after:=place(t,&s,{2,-3},chopped[:])
    testing.expect_value(t,len(after),len(before)-1)
    kept:=0
    for p in before {
        if p.id==trees[0].id {continue}
        testing.expect(t,kept<len(after) && after[kept]==p,"everything else stays as it was")
        kept+=1
    }
    for p in of_layer(after[:],bush) {testing.expect(t,flat_distance(p.position,trees[0].position)>=2.5-1e-3,"nothing grows at the stump")}
}

// Taking points out is world data: pages of SUPPRESSED_PAGE under the graph,
// which a world copy takes with it and a rollback puts back, the generator
// placing what each says; a page from the network is not trusted to fit.
@(test)
suppressed_points_are_pages_that_copy_and_roll_back_with_the_world :: proc(t:^testing.T) {
    f:Pcg_Test
    if !test_init(t,&f) {return}
    defer test_destroy(&f)
    s:Pcg_Source
    _,_,bush:=forest(&s)
    if !testing.expect_value(t,source_compile(&s).kind,Pcg_Issue_Kind.None) {source_destroy(&s);return}
    graph:=test_graph(&f,&s,{8,8})
    test_world_settle(&f.w)
    // A bounded graph without sources: every cell of its Volume.
    core.add(&f.volumes,graph,volume.box({40,10,40}))
    test_world_settle(&f.w)
    test_step(&f)
    test_step(&f)
    placed,_,ok:=pcg_cell(&f.generated,graph,{0,0})
    if !testing.expect(t,ok && len(of_layer(placed,bush))>SUPPRESSED_PAGE+2,"the cell is placed") {return}
    bushes:=of_layer(placed,bush)
    for b in bushes[:SUPPRESSED_PAGE+2] {pcg_suppress_request(&f.suppress,{graph,{0,0},b.id})}
    pcg_suppress_request(&f.suppress,{graph,{0,0},bushes[0].id})
    pcg_suppress_request(&f.suppress,{graph,{0,0},0xdead})
    // A client asks nothing.
    f.network.role=.Client
    test_step(&f)
    testing.expect_value(t,core.count(&f.suppressed),0)
    f.network.role=.Server
    for b in bushes[:SUPPRESSED_PAGE+2] {pcg_suppress_request(&f.suppress,{graph,{0,0},b.id})}
    test_step(&f)
    testing.expect_value(t,core.count(&f.suppressed),2)
    total:=0
    for row in 0..<core.count(&f.suppressed) {
        page:=core.at(&f.suppressed,row)
        parent,_:=core.get(&f.parents,core.entity_at(&f.suppressed,row))
        testing.expect(t,page.graph==500 && page.coord==[2]i32{0,0} && parent.entity==graph,"under its graph, named by its Id")
        total+=int(page.count)
    }
    testing.expect_value(t,total,SUPPRESSED_PAGE+2)
    test_step(&f)
    shown,_,_:=pcg_cell(&f.generated,graph,{0,0})
    testing.expect_value(t,len(shown),len(placed)-(SUPPRESSED_PAGE+2))
    // A copy of the world holds the same pages, and places the same from its copied source.
    copied:Pcg_Test
    if !test_init(t,&copied) {return}
    defer test_destroy(&copied)
    testing.expect(t,test_world_copy(&copied.w,&f.w))
    testing.expect_value(t,core.count(&copied.suppressed),2)
    testing.expect(t,len(copied.data.entries)==1 && len(copied.data.entries[0].source.compiled)==len(copied.data.entries[0].source.layers),"the copy compiles its source again")
    test_step(&copied)
    test_step(&copied)
    copy_shown,_,copy_ok:=pcg_cell(&copied.generated,graph,{0,0})
    testing.expect(t,copy_ok && slice.equal(copy_shown,shown),"the same points")
    // More of the cell: the second page fills, then a third one.
    snapshot:Pcg_World
    if !test_world_init(t,&snapshot) {return}
    defer test_world_destroy(&snapshot)
    testing.expect(t,test_world_copy(&snapshot,&f.w))
    for b in bushes[SUPPRESSED_PAGE+2:][:SUPPRESSED_PAGE] {pcg_suppress_request(&f.suppress,{graph,{0,0},b.id})}
    test_step(&f)
    testing.expect_value(t,core.count(&f.suppressed),3)
    counts:=make([dynamic]u32,context.temp_allocator)
    for row in 0..<core.count(&f.suppressed) {append(&counts,core.at(&f.suppressed,row).count)}
    slice.sort(counts[:])
    testing.expect(t,slice.equal(counts[:],[]u32{2,SUPPRESSED_PAGE,SUPPRESSED_PAGE}),"pages fill before new ones come")
    // Rollback: the world before, and its cells place what they placed then.
    testing.expect(t,test_world_copy(&f.w,&snapshot))
    test_step(&f)
    back,_,_:=pcg_cell(&f.generated,graph,{0,0})
    testing.expect_value(t,core.count(&f.suppressed),2)
    testing.expect(t,slice.equal(back,shown),"what the rollback puts back shows again")
    // Taking the pages away puts everything back.
    for core.count(&f.suppressed)>0 {core.destroy(&f.entities,core.entity_at(&f.suppressed,0));test_world_settle(&f.w)}
    test_step(&f)
    all,_,_:=pcg_cell(&f.generated,graph,{0,0})
    testing.expect_value(t,len(all),len(placed))
    // A page from the network is not trusted to fit.
    hostile:=core.create(&f.entities)
    core.add(&f.suppressed,hostile,Pcg_Suppressed{graph=500,coord={0,0},count=max(u32),items={0={bushes[0].id}}})
    test_world_settle(&f.w)
    test_step(&f)
    owner:=suppressed_owner(&f.suppressions,graph)
    ids,_:=suppressed_cell(owner,{0,0})
    testing.expect(t,owner!=nil && len(ids)<=SUPPRESSED_PAGE && slice.contains(ids,bushes[0].id))
    // A graph without an Id says why it cannot.
    nameless:=core.create(&f.entities)
    core.add(&f.graphs,nameless,Pcg_Graph{source={8,8}})
    core.add(&f.worlds,nameless,core.World_Transform{transform=mm.TRANSFORM_IDENTITY})
    test_world_settle(&f.w)
    before:=f.problems.count
    pcg_suppress_request(&f.suppress,{nameless,{0,0},1})
    test_step(&f)
    testing.expect(t,f.problems.count>before)
}

// The ground is read GROUND_SAMPLES samples a frame, the nearest first; the
// cells waiting take coarse tiles, which their fine tiles replace frame after
// frame, and the cells place again when their tile changes.
@(test)
the_ground_is_read_by_a_count_and_coarse_tiles_turn_fine :: proc(t:^testing.T) {
    f:Pcg_Test
    if !test_init(t,&f) {return}
    defer test_destroy(&f)
    s:Pcg_Source
    forest(&s)
    if !testing.expect_value(t,source_compile(&s).kind,Pcg_Issue_Kind.None) {source_destroy(&s);return}
    f.queries.open=test_open
    f.height=3
    graph:=test_graph(&f,&s,{8,8})
    core.add(&f.volumes,graph,volume.box({160,50,160}))
    test_world_settle(&f.w)
    test_step(&f)
    owner:=ground_owner(&f.ground,graph)
    if !testing.expect(t,owner!=nil) {return}
    testing.expect_value(t,owner.samples,u32(33))
    testing.expect_value(t,len(owner.cells),121)
    fine,coarse:=0,0
    for tile in owner.tiles {
        n:=ground_tile_samples(owner,tile.coord)
        if n==33 {fine+=1} else if n==SAMPLES_MIN {coarse+=1}
    }
    testing.expect_value(t,fine,(GROUND_SAMPLES-GROUND_COARSE)/(33*33))
    testing.expect_value(t,fine+coarse,121)
    testing.expect(t,f.probes<=GROUND_SAMPLES,"no more than the count of a frame")
    // A coarse tile places already, on its coarse ground.
    coarse_cell:=[2]i32{}
    for tile in owner.tiles {if ground_tile_samples(owner,tile.coord)==SAMPLES_MIN {coarse_cell=tile.coord;break}}
    _,revision,placed_ok:=pcg_cell(&f.generated,graph,coarse_cell)
    testing.expect(t,placed_ok)
    tile,_:=ground_cell(owner,coarse_cell)
    h,_,on:=ground_at(tile,5,5)
    testing.expect(t,on && h==3,"on the height of the ground")
    frames:=1
    for frames<20 {
        test_step(&f)
        frames+=1
        testing.expect(t,f.probes<=GROUND_SAMPLES)
        done:=true
        for tile in owner.tiles {done&&=ground_tile_samples(owner,tile.coord)==33}
        if done {break}
    }
    testing.expect(t,frames<20,"every tile turns fine")
    test_step(&f)
    _,later,_:=pcg_cell(&f.generated,graph,coarse_cell)
    testing.expect(t,later!=revision,"the cell placed again on its fine tile")
    // Nothing changes: nothing is read, nothing placed again.
    test_step(&f)
    builds:=f.generated.stats.builds
    test_step(&f)
    testing.expect_value(t,f.probes,0)
    testing.expect_value(t,f.generated.stats.builds,builds)
    // An excluding zone keeps points out of where it is, and is read again where it moves.
    keep:=core.create(&f.entities)
    core.add(&f.zones,keep,Pcg_Zone{exclude=true})
    core.add(&f.volumes,keep,volume.box({16,50,16}))
    core.add(&f.worlds,keep,core.World_Transform{transform=mm.Transform{position={16,0,16},rotation=1,scale={1,1,1}}})
    test_world_settle(&f.w)
    for _ in 0..<3 {test_step(&f)}
    inside,_,_:=pcg_cell(&f.generated,graph,{0,0})
    testing.expect_value(t,len(inside),0)
    outside,_,_:=pcg_cell(&f.generated,graph,{2,2})
    testing.expect(t,len(outside)>0)
}

// Promoting a point takes it out of its graph and spawns the prefab of its
// layer where it stood, as an entity of the scene.
@(test)
promoting_a_point_suppresses_it_and_spawns_its_prefab_where_it_stood :: proc(t:^testing.T) {
    CRATE :: base.Asset_Id{0xc7,9}
    PCG :: base.Asset_Id{0xc7,10}
    folder:=base.test_folder(t,"pcg-promote")
    if folder=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    crate:asset.Scene;asset.scene_init(&crate,&types,CRATE)
    asset.scene_entity_add(&crate,1,0,"Crate")
    crate.doc.flags+={.Prefab}
    testing.expect_value(t,asset.scene_save(&crate,fmt.tprintf("%s/crate.scene",folder)),asset.Error.None)
    asset.scene_destroy(&crate)
    s:Pcg_Source
    tree,_,bush:=forest(&s)
    trunk,_:=source_layer(&s,tree)
    trunk.asset=CRATE
    bytes,error:=source_bytes(&s,PCG,&types)
    source_destroy(&s)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/trees.pcg",folder),bytes)==nil)
    delete(bytes)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder,capacity=16})) {return}
    defer host.assets_destroy(&assets)
    testing.expect(t,host.assets_scan(&assets))
    testing.expect(t,host.assets_scene(&assets,CRATE)!=nil,"the prefab is loaded")
    f:Pcg_Test
    if !test_init(t,&f) {return}
    defer test_destroy(&f)
    f.assets=&assets
    place:=mm.Transform{position={100,2,-50},rotation=1,scale={1,1,1}}
    graph:=core.create(&f.entities)
    core.add(&f.ids,graph,core.Id{value=500})
    core.add(&f.graphs,graph,Pcg_Graph{source=PCG})
    core.add(&f.worlds,graph,core.World_Transform{transform=place})
    core.add(&f.volumes,graph,volume.box({15,10,15}))
    test_world_settle(&f.w)
    pcg_load(&f.data,core.read(&f.graphs),&assets,context.allocator,&f.problems)
    if !testing.expect(t,len(f.data.entries)==1 && f.data.entries[0].issue.kind==.None,"the source is read from its file") {return}
    test_step(&f)
    test_step(&f)
    placed,_,ok:=pcg_cell(&f.generated,graph,{0,0})
    trees:=of_layer(placed,tree)
    if !testing.expect(t,ok && len(trees)>0) {return}
    chosen:=trees[0]
    entities:=core.count(&f.transforms)
    pcg_promote(&f.promote,{graph,{0,0},chosen.id})
    test_step(&f)
    // The index of what is taken out is made again at the next tick.
    test_step(&f)
    testing.expect_value(t,core.count(&f.suppressed),1)
    page:=core.at(&f.suppressed,0)
    testing.expect(t,page.count==1 && page.items[0].id==chosen.id,"the point is taken out")
    after,_,_:=pcg_cell(&f.generated,graph,{0,0})
    _,still:=placed_find(after,chosen.id)
    testing.expect(t,!still)
    spawned:=core.NONE
    for row in 0..<core.count(&f.names) {
        name:=core.at(&f.names,row)
        if base.text_get(name.text[:])=="Crate" {spawned=core.entity_at(&f.names,row)}
    }
    if !testing.expect(t,spawned!=core.NONE && core.count(&f.transforms)>entities,"its prefab is spawned") {return}
    at,_:=core.get(&f.transforms,spawned)
    want:=mm.transform_compose(place,{position=chosen.position,rotation=chosen.rotation,scale=chosen.scale})
    testing.expect(t,linalg.length(at.position-want.position)<1e-3,"where it stood in the world")
    testing.expect(t,abs(linalg.dot(at.rotation,want.rotation))>0.9999)
    // A point of a layer without a prefab is taken out, and says why it was not promoted.
    bushes:=of_layer(placed,bush)
    if !testing.expect(t,len(bushes)>0) {return}
    before:=f.problems.count
    pcg_promote(&f.promote,{graph,{0,0},bushes[0].id})
    test_step(&f)
    test_step(&f)
    testing.expect(t,f.problems.count>before)
    testing.expect_value(t,core.at(&f.suppressed,0).count,u32(2))
}

// Hostile inputs: a ground of NaN places nothing, a program that cannot run
// and work memory that runs out place nothing and say so, and requests of
// cells and points that are not there take nothing.
@(test)
hostile_inputs_place_nothing_and_never_crash :: proc(t:^testing.T) {
    s:Pcg_Source
    forest(&s)
    defer source_destroy(&s)
    testing.expect(t,source_layer_texts(&s,1,"perlin2(x*0.1, z*0.1) + height*0 + 0.5"))
    if !testing.expect_value(t,source_compile(&s).kind,Pcg_Issue_Kind.None) {return}
    scratch:Pcg_Scratch
    if !testing.expect(t,scratch_init(&scratch)) {return}
    defer scratch_destroy(&scratch)
    heights:[81]f32
    kept:[KEPT_WORDS]u64
    for &h in heights {h=NO_GROUND}
    cin:=Pcg_Cell_Input{source=&s,seed=1,coord={0,0},ground={cell_size=32,samples=9,heights=heights[:],weights=make([]Layer_Weights,81,context.temp_allocator),kept=kept[:]},frame=linalg.MATRIX4F32_IDENTITY,domain=unbounded(),share=1}
    out:=make([dynamic]Placed,context.temp_allocator)
    testing.expect(t,cell_generate(&cin,&scratch,&out) && len(out)==0,"no ground, nothing")
    // Coordinates far out and a cell of extreme coordinates.
    for &h in heights {h=1e30}
    cin.coord={COORD_MAX,-COORD_MAX}
    testing.expect(t,cell_generate(&cin,&scratch,&out))
    for p in out {testing.expect(t,p.position.x-p.position.x==0,"what stands is finite")}
    clear(&out)
    // A program whose code was damaged does not run, and nothing is appended.
    for &h in heights {h=0}
    cin.coord={0,0}
    held:=s.compiled[0].field.code[0]
    s.compiled[0].field.code[0].dst=200
    testing.expect(t,!cell_generate(&cin,&scratch,&out) && len(out)==0)
    s.compiled[0].field.code[0]=held
    // Out of memory: the work memory of an arena too small for the cell.
    buffer:=make([]u8,96*1024)
    defer delete(buffer)
    arena:mem.Arena
    mem.arena_init(&arena,buffer)
    small:Pcg_Scratch
    if scratch_init(&small,mem.arena_allocator(&arena)) {
        testing.expect(t,!cell_generate(&cin,&small,&out) && len(out)==0,"without memory nothing is appended")
    }
    testing.expect(t,!scratch_init(&small,mem.nil_allocator()),"without any memory there is no work memory")
    // A source not compiled places nothing.
    source_compiled_free(&s)
    testing.expect(t,cell_generate(&cin,&scratch,&out) && len(out)==0)
    // Lookups of what is not there.
    testing.expect(t,data_find(nil,{1,1})==nil && generated_graph(nil,core.NONE)==nil && ground_owner(nil,core.NONE)==nil && suppressed_owner(nil,core.NONE)==nil)
    _,_,found:=pcg_cell(nil,core.NONE,{0,0})
    testing.expect(t,!found)
    cell,_:=ground_cell(nil,{0,0})
    testing.expect(t,cell.absent)
    // NaN and infinite places fall in some cell, and a mask of no zone is 0.
    coord,local:=cell_of(32,{f32(0h7fc00000),f32(0h7f800000)})
    testing.expect(t,coord.x<=COORD_MAX && local.x>=0 && local.y>=0)
    testing.expect_value(t,zone_mask(nil,0,{0,0,0}),f32(0))
}

@(private="file")
hills_open :: proc(w:core.World_Read) -> (core.Ground_Query,bool) {
    probe :: proc(user:rawptr,origin,down:[3]f32) -> (hit:core.Ground_Hit,found:core.Ground_Found) {
        f:=cast(^Pcg_Test)user
        f.probes+=1
        height:=2*math.sin(origin.x*0.7)+math.cos(origin.z*0.9)
        return {point={origin.x,height,origin.z},normal={0,1,0},weights={0,255,0,0},layers={1={7,7}}},.Ground
    }
    return {user=w.data,probe=probe,spacing=0.5},true
}

// The ground cache is state of the world: a copy for Play, or a rollback into
// the world it came from, places on its first frame what the world placed,
// without reading the ground again. A world without it reads the whole ground
// again over frames, its cells standing meanwhile on the coarse tiles of
// cells not read yet: what excluding it from the copy (copy=false) would cost.
@(test)
the_ground_cache_copies_with_the_world_and_spares_reading_it_again :: proc(t:^testing.T) {
    Case :: struct {name:string,rollback,without:bool}
    cases:=[]Case{
        {"Play: a new world from the edited one",false,false},
        {"a rollback into the world it came from",true,false},
        {"a new world without the ground cache",false,true},
    }
    placements :: proc(g:^Pcg_Generated,e:core.Entity) -> (all:[dynamic]Placed) {
        all=make([dynamic]Placed,context.temp_allocator)
        if graph:=generated_graph(g,e);graph!=nil {
            for &cell in graph.cells {if cell.built {append(&all,..cell.placed[:])}}
        }
        return
    }
    for c in cases {
        f:=new(Pcg_Test)
        defer free(f)
        if !test_init(t,f) {return}
        defer test_destroy(f)
        f.queries.open=hills_open
        s:Pcg_Source
        forest(&s)
        if !testing.expect_value(t,source_compile(&s).kind,Pcg_Issue_Kind.None) {source_destroy(&s);return}
        graph:=test_graph(f,&s,{8,8})
        core.add(&f.volumes,graph,volume.box({40,10,40}))
        test_world_settle(&f.w)
        for _ in 0..<64 {
            test_step(f)
            if f.probes==0 {break}
        }
        before:=placements(&f.generated,graph)
        bytes:=ground_bytes(&f.ground)
        if !testing.expectf(t,len(before)>0 && bytes>0,"%s: placed %d, ground %d bytes",c.name,len(before),bytes) {continue}
        into:=f
        if c.rollback {
            snapshot:=new(Pcg_World)
            defer free(snapshot)
            if !test_world_init(t,snapshot) {return}
            defer test_world_destroy(snapshot)
            testing.expect(t,test_world_copy(snapshot,&f.w))
            // The world goes on and the ground changes under it, then rolls back.
            f.ground.owners[0].tiles[0].revision+=1
            test_step(f)
            testing.expect(t,test_world_copy(&f.w,snapshot))
        } else {
            into=new(Pcg_Test)
            if !test_init(t,into) {free(into);return}
            testing.expect(t,test_world_copy(&into.w,&f.w))
        }
        defer if into!=f {test_destroy(into);free(into)}
        // A copy holds the lists it was given, without the room the world kept to grow them.
        copied:=ground_bytes(&into.ground)
        testing.expectf(t,copied>bytes/2 && (c.rollback || copied<=bytes),"%s: the copy holds %d bytes of ground, the world %d",c.name,copied,bytes)
        if c.without {
            core.value_free(&into.ground,type_info_of(Pcg_Ground))
            into.ground={}
        }
        test_step(into)
        after:=placements(&into.generated,graph)
        if c.without {
            // It places on coarse tiles first, the same once the ground is read again.
            testing.expectf(t,into.probes>0 && !slice.equal(after[:],before[:]),"%s: %d probes, placed as before %v",c.name,into.probes,slice.equal(after[:],before[:]))
            for _ in 0..<16 {
                test_step(into)
                if into.probes==0 {break}
            }
            again:=placements(&into.generated,graph)
            testing.expectf(t,slice.equal(again[:],before[:]),"%s: read again, it places as before",c.name)
            continue
        }
        testing.expectf(t,into.probes==0,"%s: %d probes of the ground",c.name,into.probes)
        testing.expectf(t,slice.equal(after[:],before[:]),"%s: %d placed, %d before",c.name,len(after),len(before))
    }
}

// A ground probe that finds no terrain anywhere: authored points must still
// appear while generated layers wait for ground.
@(private="file")
no_ground_open :: proc(w:core.World_Read) -> (core.Ground_Query,bool) {
    probe :: proc(user:rawptr,origin,down:[3]f32) -> (hit:core.Ground_Hit,found:core.Ground_Found) {
        return {},.None
    }
    return {user=w.data,probe=probe,spacing=1},true
}

// Authored points round-trip through .pcg v2, validate strictly against
// hostile data, survive absent terrain, rasterize into Micro occupancy across
// cell borders, re-bucket on cell_size changes, and drop on layer removal.
@(test)
authored_points_round_trip_emit_without_ground_and_occupy_micro :: proc(t:^testing.T) {
    s:Pcg_Source
    source_init(&s)
    defer source_destroy(&s)
    l:=source_layer_add(&s,.Scatter,.Macro)
    l.asset,l.density,l.radius={0xaa,0xbb},0,2.5
    m:=source_layer_add(&s,.Scatter,.Micro)
    m.asset,m.density={0xcc,0xdd},0.5
    // Near the right border of cell (0,0) so its radius reaches into cell (1,0).
    rot:=linalg.normalize(mm.Quat(quaternion(x=0,y=0.3826834,z=0,w=0.9238795)))
    c0,id0,ok0:=source_point_add(&s,l.id,{31.0,4.5,16.0},rot,{1.5,2.0,1.5})
    testing.expect(t,ok0 && c0=={0,0} && point_authored(id0) && point_layer(id0)==l.id && point_ordinal(id0)==1)
    // Hostile adds are refused without mutating state.
    _,_,bad_micro:=source_point_add(&s,m.id,{2,0,2},1,{1,1,1})
    _,_,bad_scale:=source_point_add(&s,l.id,{2,0,2},1,{0,1,1})
    _,_,bad_neg:=source_point_add(&s,l.id,{2,0,2},1,{-1,1,1})
    _,_,bad_nan:=source_point_add(&s,l.id,{math.nan_f32(),0,2},1,{1,1,1})
    _,_,bad_rot:=source_point_add(&s,l.id,{2,0,2},0,{1,1,1})
    testing.expect(t,!bad_micro && !bad_scale && !bad_neg && !bad_nan && !bad_rot)
    testing.expect_value(t,source_point_count(&s),1)

    // Round-trip through binary .pcg v2 bytes.
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    bytes,err:=source_bytes(&s,{0x12,0x34},&types)
    if !testing.expect_value(t,err,asset.Error.None) {return}
    defer delete(bytes)
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&file,bytes),asset.Error.None) {return}
    defer asset.asset_close(&file)
    read:Pcg_Source
    source_init(&read)
    defer source_destroy(&read)
    rid,issue:=source_read(&read,&file,&types)
    if !testing.expect(t,issue.kind==.None && rid=={0x12,0x34}) {return}
    testing.expect_value(t,source_point_count(&read),1)
    pt,found:=source_point_find(&read,{0,0},id0)
    testing.expect(t,found && pt.position=={31.0,4.5,16.0} && pt.scale=={1.5,2.0,1.5})

    // Hostile corruption: point moved outside its cell is rejected.
    corrupt:Pcg_Source
    testing.expect(t,source_copy(&corrupt,&read))
    defer source_destroy(&corrupt)
    corrupt.cells[0].points[0].position.x=99
    testing.expect_value(t,source_issue(&corrupt).kind,Pcg_Issue_Kind.Cell)
    // A rotation that is not of length 1, and an id given twice, are too.
    corrupt.cells[0].points[0]=read.cells[0].points[0]
    testing.expect_value(t,source_issue(&corrupt).kind,Pcg_Issue_Kind.None)
    corrupt.cells[0].points[0].rotation=2
    testing.expect_value(t,source_issue(&corrupt).kind,Pcg_Issue_Kind.Cell)
    corrupt.cells[0].points[0]=read.cells[0].points[0]
    append(&corrupt.cells[0].points,read.cells[0].points[0])
    testing.expect_value(t,source_issue(&corrupt).kind,Pcg_Issue_Kind.Cell)

    // Re-bucketing on cell_size change keeps all points valid, and the paint of its cells.
    rechunk:Pcg_Source
    testing.expect(t,source_copy(&rechunk,&read))
    defer source_destroy(&rechunk)
    painted:=source_cell(&rechunk,{5,5},true)
    resize(&painted.density,PAINT_SAMPLES*PAINT_SAMPLES)
    testing.expect(t,source_rechunk_points(&rechunk,16) && source_valid(&rechunk))
    testing.expect_value(t,rechunk.info.cell_size,f32(16))
    _,moved_found:=source_point_find(&rechunk,{1,1},id0)
    testing.expect(t,moved_found,"31,16 moved from cell (0,0) at 32m to cell (1,1) at 16m")
    painted=source_cell(&rechunk,{5,5})
    testing.expect(t,painted!=nil && len(painted.density)==PAINT_SAMPLES*PAINT_SAMPLES,"the painted cell stays")

    // A cell size that puts more than POINTS_CELL_MAX points in one cell, or
    // that is no cell size, is refused with the source as it was.
    crowded:Pcg_Source
    testing.expect(t,source_copy(&crowded,&read))
    defer source_destroy(&crowded)
    for k in 0..<POINTS_CELL_MAX/2+1 {
        _,_,left:=source_point_add(&crowded,l.id,{10,0,10},1,{1,1,1})
        _,_,right:=source_point_add(&crowded,l.id,{40,0,10},1,{1,1,1})
        if !testing.expectf(t,left && right,"point %d",k) {break}
    }
    held:Pcg_Source
    testing.expect(t,source_copy(&held,&crowded))
    defer source_destroy(&held)
    for size in ([?]f32{64,2,math.nan_f32()}) {
        testing.expectf(t,!source_rechunk_points(&crowded,size),"cell size %v",size)
        same:=crowded.info==held.info && len(crowded.cells)==len(held.cells)
        for &cell,k in crowded.cells {
            if !same {break}
            same=cell.coord==held.cells[k].coord && slice.equal(cell.points[:],held.cells[k].points[:])
        }
        testing.expectf(t,same && source_valid(&crowded),"cell size %v leaves the source as it was",size)
    }

    // Removing the layer removes its authored points and prunes the empty cell.
    testing.expect(t,source_layer_remove(&rechunk,l.id))
    testing.expect_value(t,source_point_count(&rechunk),0)
    testing.expect(t,len(rechunk.cells)==1 && rechunk.cells[0].coord=={5,5},"only the painted cell is left")

    // Runtime with a probe that returns .None everywhere: authored point still emits,
    // and its radius (2.5 * 1.5 = 3.75m at x=31) occupies cell (1,0) across the border!
    f:=new(Pcg_Test);defer free(f)
    if !test_init(t,f) {return}
    defer test_destroy(f)
    f.queries.open=no_ground_open
    graph:=test_graph(f,&read,{0x55,0x66})
    core.add(&f.volumes,graph,volume.box({64,20,64}))
    test_world_settle(&f.w)
    for _ in 0..<8 {test_step(f)}
    placed0,_,ok_c0:=pcg_cell(&f.generated,graph,{0,0})
    testing.expect(t,ok_c0 && len(placed0)==1 && placed0[0].id==id0 && placed0[0].position=={31.0,4.5,16.0})
    cell1:=generated_cell(generated_graph(&f.generated,graph),{1,0})
    if testing.expect(t,cell1!=nil,"neighbour cell (1,0) exists") {
        // Cell (1,0) has no ground so it skipped cell_generate without points; test cell_generate directly on (1,0) with ground to verify 3x3 micro occupancy.
        g_cell:=Pcg_Ground_Cell{cell_size=32,samples=2}
        scratch:Pcg_Scratch
        testing.expect(t,scratch_init(&scratch))
        defer scratch_destroy(&scratch)
        out:=make([dynamic]Placed)
        defer delete(out)
        entry:=data_find(&f.data,{0x55,0x66})
        cin:=Pcg_Cell_Input{source=&entry.source,coord={1,0},ground=g_cell,frame=1}
        testing.expect(t,cell_generate(&cin,&scratch,&out))
        testing.expect(t,occupied_at(&scratch.occupied,32,0.5,16.0),"authored point at x=31 in cell (0,0) with radius 3.75 occupies x=0.5 in cell (1,0)")
    }
    // Play suppression still hides authored points cleanly.
    pcg_suppress_request(&f.suppress,{graph=graph,coord={0,0},id=id0})
    test_step(f);test_step(f)
    placed_after,_,_:=pcg_cell(&f.generated,graph,{0,0})
    testing.expect_value(t,len(placed_after),0)
}

@(test)
a_whole_rule_stands_at_every_chance_past_its_weight_and_a_weighed_one_as_much_as_it_weighs :: proc(t:^testing.T) {
    grass:=base.Asset_Id{3,7}
    // Every sample is 60% grass.
    heights:=[4]f32{}
    weights:=[4]Layer_Weights{}
    for &w in weights {w={weights={153,102,0,0},layers=0}}
    layers:=[1]Ground_Layers{{grass,{9,9},{},{}}}
    cin:=Pcg_Cell_Input{ground={cell_size=32,samples=2,heights=heights[:],weights=weights[:],layers=layers[:]}}
    cases:=[?]struct{whole:bool,weight,chance:f32,takes:bool}{
        {false,0.5,0.3,true},  // the chance under what they weigh
        {false,0.5,0.9,false}, // past what they weigh: they stand as densely as they weigh
        {true,0.5,0.9,true},   // whole: every chance past the weight
        {true,0.7,0.1,false},  // under the weight, none
    }
    for tc in cases {
        l:Pcg_Layer
        l.ground_rule={enabled=true,slope={0,math.PI/2},height={-10,10},layers={0=grass},weight=tc.weight,whole=tc.whole}
        mask:=rule_mask(&cin,&l)
        p:=Point{at={16,16},chance=tc.chance,normal={0,1,0}}
        testing.expectf(t,rule_takes(&cin,&l,&mask,p)==tc.takes,"%v: takes %v",tc,!tc.takes)
    }
}

@(test)
ground_layers_canonical_and_reporting :: proc(t:^testing.T) {
    a,b,c:=base.Asset_Id{1,1},base.Asset_Id{1,2},base.Asset_Id{2,1}
    w1,l1:=ground_layers_canonical({200,55,0,0},{b,a,c,{}})
    w2,l2:=ground_layers_canonical({55,200,0,0},{a,b,{},{}})
    testing.expect_value(t,l1,Ground_Layers{a,b,{},{}})
    testing.expect_value(t,l1,l2)
    testing.expect_value(t,w1,[4]u8{55,200,0,0})
    testing.expect_value(t,w2,[4]u8{55,200,0,0})

    // A probe returning >TILE_LAYERS distinct canonical sets in one cell reports pcg.layers
    // only when the graph actually uses ground-layer rules.
    many_layers_probe :: proc(user:rawptr,at,down:mm.Vec3) -> (hit:core.Ground_Hit,found:core.Ground_Found) {
        ix:=u64(int(at.x*4)+1000)
        iz:=u64(int(at.z*4)+1000)
        return {point={at.x,0,at.z},normal={0,1,0},weights={255,0,0,0},layers={0={9,ix*10000+iz+1}}},.Ground
    }
    many_layers_open :: proc(w:core.World_Read) -> (core.Ground_Query,bool) {
        return {probe=many_layers_probe,spacing=1},true
    }
    Case :: struct {name:string,with_rule:bool,expect_problem:bool}
    cases:=[?]Case{
        {"authored/no ground layer rule stays quiet",false,false},
        {"active ground layer rule reports overflow",true,true},
    }
    for tc in cases {
        f:=new(Pcg_Test);defer free(f)
        if !test_init(t,f) {return}
        defer test_destroy(f)
        f.queries.open=many_layers_open
        src:Pcg_Source
        source_init(&src);defer source_destroy(&src)
        l:=source_layer_add(&src,.Scatter,.Macro)
        testing.expect(t,l!=nil)
        l.params.density=0.02
        if tc.with_rule {l.ground_rule={enabled=true,slope={0,1.5},height={-10,10},layers={0={9,1}},weight=0.5}}
        testing.expect_value(t,source_compile(&src),Pcg_Issue{})
        graph:=test_graph(f,&src,{0x77,tc.with_rule?1:2})
        core.add(&f.volumes,graph,volume.box({64,20,64}))
        test_world_settle(&f.w)
        before:=f.problems.count
        for _ in 0..<8 {test_step(f)}
        reported:=f.problems.count>before
        testing.expectf(t,reported==tc.expect_problem,"%s: pcg.layers reported=%v expected=%v",tc.name,reported,tc.expect_problem)
    }
}
