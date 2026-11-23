package pcg_shapes

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:testing"
import "mirai:core"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:std/base"
import mm "mirai:std/math"
import pcg "plugins:pcg/runtime"
import phys "plugins:physics/runtime"
import shapes "plugins:shapes/runtime"

@(test_world)
Shapes_World :: struct {
    using world:Test_World,
    outputs:core.Table(Pcg_Shapes_Output),
    parts:core.Table(Pcg_Shape_Part),
    graphs:core.Table(pcg.Pcg_Graph),
    worlds:core.Table(core.World_Transform),
    parents:core.Table(core.Parent),
    transforms:core.Table(core.Transform),
    solids:core.Table(shapes.Shape),
    bends:core.Table(shapes.Bend),
    meshes:core.Table(render.Mesh_Renderer),
    colliders:core.Table(phys.Collider),
    splines:core.Table(volume.Spline),
    data:pcg.Pcg_Data,
}

// A world with a graph of a fence along a span of 60 m over two cells, and
// what the graph places there, kept by world as the application keeps it.
@(private="file")
Shapes_Test :: struct {
    using w:Shapes_World,
    generated:pcg.Pcg_Generated,
    cache:Pcg_Shapes_Cache,
    problems:core.Problems,
    graph:core.Entity,
    layer:u32,
}

@(private="file") SOURCE :: base.Asset_Id{5,5}
@(private="file") POST :: base.Asset_Id{9,1}
@(private="file") RAIL :: base.Asset_Id{9,2}
@(private="file") SPAN :: pcg.Pcg_Span{entity=900,span=0,channel=0,a={1,0,4},b={61,0,4}}
@(private="file") CELLS :: [2][2]i32{{0,0},{1,0}}

@(private="file")
fence_output :: proc() -> (out:Pcg_Shapes_Output) {
    out.modules[0]={asset=POST,form=.Shape,size={0.2,1.2}}
    out.modules[1]={asset=RAIL,form=.Bend}
    return
}

@(private="file")
test_init :: proc(t:^testing.T,f:^Shapes_Test,out:=Pcg_Shapes_Output{},grammar:="[Post, [Rail, Post]*]",anchored:=false,at:=mm.TRANSFORM_IDENTITY) -> bool {
    if !test_world_init(t,&f.w) {return false}
    s:pcg.Pcg_Source
    pcg.source_init(&s)
    s.info.seed=3
    fence:=pcg.source_layer_add(&s,.Grammar,.Macro)
    fence.collides=true
    f.layer=fence.id
    symbols:=[?]pcg.Grammar_Symbol_Def{pcg.grammar_symbol("Post",0.2,false,POST),pcg.grammar_symbol("Rail",2,true,RAIL)}
    if !testing.expect(t,pcg.source_layer_texts(&s,fence.id,"",grammar,symbols[:])) || !testing.expect_value(t,pcg.source_compile(&s).kind,pcg.Pcg_Issue_Kind.None) {pcg.source_destroy(&s);return false}
    f.data.made+=1
    append(&f.data.entries,pcg.Pcg_Data_Entry{id=SOURCE,epoch=f.data.made,loads=1,source=s})
    f.graph=core.create(&f.entities)
    core.add(&f.graphs,f.graph,pcg.Pcg_Graph{source=SOURCE,world_anchored=anchored})
    core.add(&f.worlds,f.graph,core.World_Transform{transform=at})
    core.add(&f.outputs,f.graph,out if out!={} else fence_output())
    test_world_settle(&f.w)
    graph:=pcg.Generated_Graph{entity=f.graph,cells=make([dynamic]pcg.Generated_Cell)}
    for coord in CELLS {append(&graph.cells,pcg.Generated_Cell{coord=coord,placed=make([dynamic]pcg.Placed)})}
    append(&f.generated.graphs,graph)
    return generate(t,f)
}

@(private="file")
test_destroy :: proc(f:^Shapes_Test) {
    pcg.pcg_generated_free(&f.generated)
    pcg_shapes_cache_free(&f.cache)
    test_world_destroy(&f.w)
}

// The cells of the graph placed again on flat ground, without what is
// suppressed, as pcg_update builds them.
@(private="file")
generate :: proc(t:^testing.T,f:^Shapes_Test,suppressed:[]u64={}) -> bool {
    scratch:pcg.Pcg_Scratch
    if !testing.expect(t,pcg.scratch_init(&scratch)) {return false}
    defer pcg.scratch_destroy(&scratch)
    s:=&f.data.entries[0].source
    spans:=[1]pcg.Pcg_Span{SPAN}
    graph:=&f.generated.graphs[0]
    for &cell in graph.cells {
        heights:[81]f32
        kept:[pcg.KEPT_WORDS]u64
        weights:[81]pcg.Layer_Weights
        ground:=pcg.Pcg_Ground_Cell{cell_size=s.info.cell_size,samples=9,heights=heights[:],weights=weights[:],kept=kept[:]}
        domain:=pcg.Pcg_Region{volume=volume.world(),pose=mm.TRANSFORM_IDENTITY}
        cin:=pcg.Pcg_Cell_Input{source=s,seed=s.info.seed,coord=cell.coord,ground=ground,frame=linalg.MATRIX4F32_IDENTITY,domain=domain,spans=spans[:],suppressed=suppressed,share=1}
        clear(&cell.placed)
        if !testing.expect(t,pcg.cell_generate(&cin,&scratch,&cell.placed)) {return false}
        cell.built=true
        cell.revision+=1
    }
    graph.revision+=1
    return true
}

@(private="file")
test_step :: proc(f:^Shapes_Test,cache:^Pcg_Shapes_Cache=nil) {
    w:=&f.w
    c:=cache if cache!=nil else &f.cache
    pcg_shapes_update(c,core.read(&w.outputs),core.read(&w.parts),core.read(&w.graphs),core.read(&w.worlds),core.read(&w.parents),core.ref(&f.generated),core.ref(&w.data),core.commands(w,test_world_info(w)),context.allocator,&f.problems)
    test_world_settle(w)
}

@(private="file")
Child :: struct {coord:[2]i32,id,hash:u64,entity:core.Entity}

// The children of the graph, by cell and module.
@(private="file")
children :: proc(w:^Shapes_World) -> []Child {
    out:=make([dynamic]Child,context.temp_allocator)
    for row in 0..<core.count(&w.parts) {
        p:=core.at(&w.parts,row)
        append(&out,Child{p.coord,p.id,p.hash,core.entity_at(&w.parts,row)})
    }
    slice.sort_by(out[:],proc(a,b:Child) -> bool {return a.coord.x<b.coord.x || a.coord.x==b.coord.x && a.id<b.id})
    return out[:]
}

@(private="file")
modules :: proc(f:^Shapes_Test) -> (n:int) {
    for cell in f.generated.graphs[0].cells {n+=len(cell.placed)}
    return
}

@(private="file")
same_keys :: proc(a,b:[]Child) -> bool {
    if len(a)!=len(b) {return false}
    for x,i in a {if x.coord!=b[i].coord || x.id!=b[i].id || x.hash!=b[i].hash {return false}}
    return true
}

// A fence of posts and rails along a span becomes one child for each of its
// modules in both cells: a post a Shape of its profile and of its 0.2 m, a
// rail its mesh bent over its stretched length with a collider of its own,
// laid end to end over the whole 60 m. The same inputs give the same children.
@(test)
a_grammar_fence_becomes_one_child_per_module_deterministically :: proc(t:^testing.T) {
    f:Shapes_Test
    if !test_init(t,&f) {return}
    defer test_destroy(&f)
    test_step(&f)
    n:=modules(&f)
    kids:=children(&f.w)
    testing.expectf(t,n>=3 && len(kids)==n,"%d modules, %d children; %v",n,len(kids),core.problems_list(&f.problems))
    testing.expect_value(t,f.problems.count,0)
    total:=f32(0)
    posts,rails:=0,0
    for k in kids {
        parent,_:=core.get(&f.parents,k.entity)
        testing.expect(t,parent.entity==f.graph,"under its graph")
        place,_:=core.get(&f.transforms,k.entity)
        testing.expect(t,abs(place.position.z-4)<1e-3 && place.position.x>=1-1e-3 && place.position.x<=61+1e-3,"on the span")
        if s,is_shape:=core.get(&f.solids,k.entity);is_shape {
            testing.expect(t,abs(s.depth-0.2)<1e-5 && s.point_count==4 && s.points[2]==[2]f32{0.1,1.2},"a post: its profile along its length")
            testing.expect(t,!core.has(&f.colliders,k.entity),"a post of a layer that collides collides as its shape")
            total+=s.depth
            posts+=1
        } else if b,is_bend:=core.get(&f.bends,k.entity);is_bend {
            shown,_:=core.get(&f.meshes,k.entity)
            collider,collides:=core.get(&f.colliders,k.entity)
            testing.expect(t,shown.mesh==RAIL && collides && collider.kind==.External,"a rail: its mesh bent, colliding")
            testing.expect(t,b.end.z>=2-1e-3,"a rail stretches")
            total+=b.end.z
            rails+=1
        } else {testing.expect(t,false,"each child is a post or a rail")}
    }
    testing.expect(t,posts==rails+1 && abs(total-60)<1e-2,"posts and rails alternate over the whole span")
    // Another world of the same inputs.
    g:Shapes_Test
    if !test_init(t,&g) {return}
    defer test_destroy(&g)
    test_step(&g)
    testing.expect(t,same_keys(kids,children(&g.w)),"the same inputs, the same children")
}

// Every module along the span becomes a ribbon of a Spline of the width of
// its entry, whatever it places, when the one entry names nothing.
@(test)
modules_become_ribbons_of_their_length :: proc(t:^testing.T) {
    f:Shapes_Test
    out:Pcg_Shapes_Output
    out.modules[0]={form=.Ribbon,size={1.5,0.05},material={3,3}}
    if !test_init(t,&f,out) {return}
    defer test_destroy(&f)
    test_step(&f)
    total:=f32(0)
    for k in children(&f.w) {
        s,ok:=core.get(&f.splines,k.entity)
        testing.expect(t,ok && s.count==2 && s.material==base.Asset_Id{3,3} && s.points[0].width==1.5 && s.points[1].height==0.05)
        total+=s.points[1].position.z
    }
    testing.expect(t,len(children(&f.w))==modules(&f) && abs(total-60)<1e-2)
}

// Suppressing a module takes only its child away; the others stay as they
// were, and putting it back makes only it again.
@(test)
a_suppressed_module_takes_only_its_child_away :: proc(t:^testing.T) {
    f:Shapes_Test
    if !test_init(t,&f) {return}
    defer test_destroy(&f)
    test_step(&f)
    before:=slice.clone(children(&f.w),context.temp_allocator)
    gone:=before[len(before)/2]
    suppressed:=[1]u64{gone.id}
    if !generate(t,&f,suppressed[:]) {return}
    made,ended:=f.cache.stats.made,f.cache.stats.ended
    test_step(&f)
    after:=children(&f.w)
    testing.expect(t,len(after)==len(before)-1 && f.cache.stats.made==made && f.cache.stats.ended==ended+1,"only the suppressed one goes")
    for a in after {
        testing.expect(t,a.id!=gone.id,"not the suppressed one")
        for b in before {if b.id==a.id {testing.expect(t,b.entity==a.entity,"the others are the same entities")}}
    }
    if !generate(t,&f) {return}
    test_step(&f)
    testing.expect(t,len(children(&f.w))==len(before) && f.cache.stats.made==made+1,"put back, it alone is made again")
}

// A world copied for Play, with a cache of its own, finds the children it
// copied and makes none twice; a world rolled back to children it no longer
// places takes them away, and a child taken away by something else comes back once.
@(test)
copies_and_rollbacks_never_duplicate_children :: proc(t:^testing.T) {
    f:Shapes_Test
    if !test_init(t,&f) {return}
    defer test_destroy(&f)
    test_step(&f)
    kids:=slice.clone(children(&f.w),context.temp_allocator)
    play:Shapes_World
    if !test_world_init(t,&play) {return}
    defer test_world_destroy(&play)
    if !testing.expect(t,test_world_copy(&play,&f.w)) {return}
    cache:Pcg_Shapes_Cache
    defer pcg_shapes_cache_free(&cache)
    pcg_shapes_update(&cache,core.read(&play.outputs),core.read(&play.parts),core.read(&play.graphs),core.read(&play.worlds),core.read(&play.parents),core.ref(&f.generated),core.ref(&play.data),core.commands(&play,test_world_info(&play)),context.allocator,&f.problems)
    test_world_settle(&play)
    testing.expect(t,cache.stats.passes==1 && cache.stats.made==0 && cache.stats.ended==0 && same_keys(kids,children(&play)),"the copy keeps the children it has")
    // A snapshot, then a module suppressed, then the snapshot back.
    snapshot:Shapes_World
    if !test_world_init(t,&snapshot) {return}
    defer test_world_destroy(&snapshot)
    if !testing.expect(t,test_world_copy(&snapshot,&f.w)) {return}
    suppressed:=[1]u64{kids[0].id}
    if !generate(t,&f,suppressed[:]) {return}
    test_step(&f)
    testing.expect_value(t,len(children(&f.w)),len(kids)-1)
    if !testing.expect(t,test_world_copy(&f.w,&snapshot)) {return}
    testing.expect_value(t,len(children(&f.w)),len(kids))
    test_step(&f)
    now:=children(&f.w)
    testing.expect_value(t,len(now),len(kids)-1)
    for i in 1..<len(now) {testing.expect(t,now[i].coord!=now[i-1].coord || now[i].id!=now[i-1].id,"each module once")}
    core.destroy(&f.entities,now[0].entity)
    test_world_settle(&f.w)
    test_step(&f)
    testing.expect(t,same_keys(now,children(&f.w)),"a child taken away comes back, once")
}

// Once the children are what the graph places, a tick compares nothing and
// allocates nothing; a world-anchored graph that moves places its children again.
@(test)
a_clean_tick_does_no_work_and_a_world_anchored_graph_follows_its_entity :: proc(t:^testing.T) {
    f:Shapes_Test
    at:=mm.Transform{{100,0,0},1,{1,1,1}}
    if !test_init(t,&f,anchored=true,at=at) {return}
    defer test_destroy(&f)
    test_step(&f)
    test_step(&f)
    passes,made:=f.cache.stats.passes,f.cache.stats.made
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    {
        context.allocator=mem.tracking_allocator(&track)
        context.temp_allocator=context.allocator
        w:=&f.w
        pcg_shapes_update(&f.cache,core.read(&w.outputs),core.read(&w.parts),core.read(&w.graphs),core.read(&w.worlds),core.read(&w.parents),core.ref(&f.generated),core.ref(&w.data),core.commands(w,test_world_info(w)),context.allocator,&f.problems)
    }
    testing.expect(t,f.cache.stats.passes==passes && track.total_allocation_count==0,"a clean tick compares nothing and allocates nothing")
    // The points of a world-anchored graph are of the world: under its entity at x 100 they sit 100 back.
    for k in children(&f.w) {
        place,_:=core.get(&f.transforms,k.entity)
        testing.expect(t,place.position.x<=-39+1e-3 && place.position.x>=-99-1e-3,"placed from the entity")
    }
    core.edit(&f.worlds,f.graph).transform.position={50,0,0}
    test_world_settle(&f.w)
    test_step(&f)
    testing.expect_value(t,f.cache.stats.made,made+u64(modules(&f)))
    for k in children(&f.w) {
        place,_:=core.get(&f.transforms,k.entity)
        testing.expect(t,place.position.x>=-49-1e-3 && place.position.x<=11+1e-3,"placed again where it is")
    }
}

// What no entry names, a size that is no length, a bent module without a
// mesh, a symbol whose length is not known, an output without a graph:
// nothing is built for them and each says why.
@(test)
outputs_that_cannot_build_a_module_say_why :: proc(t:^testing.T) {
    Case :: struct {out:Pcg_Shapes_Output,grammar:string,code:string,built:bool}
    no_entry:Pcg_Shapes_Output
    no_entry.modules[0]={asset=POST,form=.Shape,size={0.2,1}}
    no_entry.modules[1]={asset={7,7},form=.Shape,size={0.2,1}}
    bad_size:=fence_output()
    bad_size.modules[0].size={math.nan_f32(),1}
    zero:=fence_output()
    zero.modules[0].size={0,1}
    no_mesh:Pcg_Shapes_Output
    no_mesh.modules[0]={form=.Bend}
    cases:=[?]Case{
        {no_entry,"[Post, [Rail, Post]*]","pcg_shapes.entry",true},
        {bad_size,"[Post, [Rail, Post]*]","pcg_shapes.size",true},
        {zero,"[Post, [Rail, Post]*]","pcg_shapes.size",true},
        {fence_output(),"[Post, [Rail, Post]*]","pcg_shapes.graph",false},
    }
    for c in cases {
        f:Shapes_Test
        if !test_init(t,&f,c.out,c.grammar) {return}
        if !c.built {core.remove(&f.graphs,f.graph);test_world_settle(&f.w)}
        test_step(&f)
        problems:=core.problems_list(&f.problems)
        found:=false
        for &p in problems {found||=string(cstring(&p.code[0]))==c.code && p.entity==f.graph}
        testing.expectf(t,found,"%s: %d problems",c.code,len(problems))
        testing.expectf(t,len(children(&f.w))<modules(&f) || !c.built,"%s: some are not built",c.code)
        if !c.built {testing.expect_value(t,len(children(&f.w)),0)}
        test_destroy(&f)
    }
    // A Bend of what places no mesh, and two symbols of one asset with other sizes.
    l:pcg.Pcg_Layer
    symbols:=[2]pcg.Grammar_Symbol_Def{pcg.grammar_symbol("A",1,false,{}),pcg.grammar_symbol("B",2,false,{})}
    l.grammar_symbols=symbols[:]
    _,error:=pcg_shapes_child(no_mesh,&l,pcg.Placed{rotation=1,scale={1,1,1}},mm.TRANSFORM_IDENTITY)
    testing.expect_value(t,error,Module_Error.Symbol)
    symbols[1].unit_size=1
    _,error=pcg_shapes_child(no_mesh,&l,pcg.Placed{rotation=1,scale={1,1,1}},mm.TRANSFORM_IDENTITY)
    testing.expect_value(t,error,Module_Error.Mesh)
    _,error=pcg_shapes_child(fence_output(),&l,pcg.Placed{asset=POST,rotation=1,scale={1,math.nan_f32(),math.inf_f32(1)}},mm.TRANSFORM_IDENTITY)
    testing.expect_value(t,error,Module_Error.Symbol)
}
