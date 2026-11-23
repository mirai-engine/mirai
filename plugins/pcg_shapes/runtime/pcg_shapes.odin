package pcg_shapes

import "base:runtime"
import "core:slice"
import "mirai:core"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:std/base"
import mm "mirai:std/math"
import pcg "plugins:pcg/runtime"
import phys "plugins:physics/runtime"
import shapes "plugins:shapes/runtime"

// What joins procedural placement and shapes, so that neither knows the
// other. A Pcg_Graph with a Pcg_Shapes_Output builds the modules its Grammar
// layers place along the Splines of their zones (a wall, a fence, a facade, a
// path) as derived children: a Shape whose profile runs the length of the
// module, the mesh of the module bent along it (Bend), or a ribbon of a
// Spline on the ground, which shapes then draws and collides. A module the
// graph no longer places (suppressed, or a span that changed) takes its
// child with it, and a child is made again only when what it is made of
// changes: the cells of the graph (pcg.Pcg_Generated), its source, or the
// output. Each child is named by its cell and the stable id of its module, so
// a world copied for Play or rolled back finds the children it has and never
// makes one twice.

PCG_SHAPES_MODULES :: 8
SIZE_MAX :: f32(1e5) // m: a size past it is not a module

// What a module becomes: Shape, a solid of a profile thickness by height run
// along the module; Bend, the mesh the module places bent from its start to
// its end; Ribbon, a Spline of the width of size drawn on the ground.
Pcg_Shapes_Form :: enum u8 {Shape,Bend,Ribbon}

// What the modules a grammar symbol places become.
Pcg_Shapes_Module :: struct {
    asset:base.Asset_Id,                 // what the symbol places, as its grammar says; none: every module no other entry names (an entry of zeros is unused)
    form:Pcg_Shapes_Form,
    size:[2]f32 `mirai:"min=0,unit=m"`, // Shape: thickness and height of its profile; Ribbon: width and height over the ground; Bend: its scale across, 0 for 1
    material:base.Asset_Id `mirai:"kind=.mat"`, // of a Shape or a Ribbon
}

@(component,description="Builds the modules the Grammar layers of the Pcg_Graph of this entity place as derived children: a Shape along each one, its mesh bent along it, or a ribbon on the ground, by what each module places.")
Pcg_Shapes_Output :: struct {
    layer:u32, // the id of the Grammar layer of the source it builds; 0: every one
    modules:[PCG_SHAPES_MODULES]Pcg_Shapes_Module `mirai:"trim"`,
}

PCG_SHAPES_OUTPUT_DEFAULT :: Pcg_Shapes_Output{modules={0={form=.Shape,size={0.3,2}}}}

// On the child that builds one module. It has no core.Id: a scene never saves
// it, and the bridge makes it again from the graph.
@(component,derived,description="The derived child that builds one module a Pcg_Graph places with its Pcg_Shapes_Output: made again from it, never saved.")
Pcg_Shape_Part :: struct {
    coord:[2]i32 `mirai:"readonly"`, // the cell of its module
    id:u64 `mirai:"readonly"`,       // the stable id of its module in that cell
    hash:u64 `mirai:"readonly"`,     // of what it was made from
}

// What the bridge saw of the graphs last, kept by world and never copied with
// it: a world copied or replaced compares its children again.
@(storage,host,by_world,free="pcg_shapes_cache_free")
Pcg_Shapes_Cache :: struct {
    outputs:[dynamic]Output_Seen,
    seen:[3]core.Seen, // the tables of Pcg_Shapes_Output, Pcg_Shape_Part and Pcg_Graph
    allocator:runtime.Allocator,
    stats:Pcg_Shapes_Stats,
}
Pcg_Shapes_Stats :: struct {passes,made,ended:u64}
Output_Seen :: struct {
    entity:core.Entity,
    revision:u32,       // of what its graph placed
    epoch:u64,          // of the entry of its source, and its loads
    loads:u32,
    place:mm.Transform, // of its entity, which the children of a world-anchored graph are placed from
}

pcg_shapes_cache_free :: proc(c:^Pcg_Shapes_Cache) {
    delete(c.outputs)
    c^={}
}

// What a child of a module is.
Module_Child :: struct {
    form:Pcg_Shapes_Form,
    place:mm.Transform, // under the graph entity
    length:f32,
    size:[2]f32,
    asset,material:base.Asset_Id,
    collides:bool,
}

// Why a module builds nothing.
Module_Error :: enum u8 {None,Entry,Symbol,Size,Mesh}

// The entry of an output for what a module places: the first that names it,
// else the first that names nothing; -1 for none. An entry of zeros is unused.
pcg_shapes_entry :: proc "contextless" (out:Pcg_Shapes_Output,asset:base.Asset_Id) -> int {
    wildcard:=-1
    for m,i in out.modules {
        if m=={} {continue}
        if m.asset==asset && asset!={} {return i}
        if m.asset=={} && wildcard<0 {wildcard=i}
    }
    return wildcard
}

// The length of a module of a Grammar layer: the unit size of the symbol
// whose asset it places, times its scale along the span. ok is false when no
// symbol places it, or two that do have other sizes.
pcg_shapes_length :: proc "contextless" (l:^pcg.Pcg_Layer,p:pcg.Placed) -> (length:f32,ok:bool) {
    unit:=f32(-1)
    for sym in l.grammar_symbols {
        what:=sym.asset if sym.asset!={} else l.asset
        if what!=p.asset {continue}
        if unit>=0 && unit!=sym.unit_size {return 0,false}
        unit=sym.unit_size
    }
    if !(unit>0) {return 0,false}
    length=unit*p.scale.z
    return length,length>0 && length<=SIZE_MAX
}

// The child a module builds, under its graph entity: in the frame of the
// graph, through to_entity for a world-anchored one.
pcg_shapes_child :: proc "contextless" (out:Pcg_Shapes_Output,l:^pcg.Pcg_Layer,p:pcg.Placed,to_entity:mm.Transform) -> (c:Module_Child,error:Module_Error) {
    entry:=pcg_shapes_entry(out,p.asset)
    if entry<0 {return c,.Entry}
    m:=out.modules[entry]
    ok:bool
    if c.length,ok=pcg_shapes_length(l,p);!ok {return c,.Symbol}
    c.form,c.size,c.asset,c.material,c.collides=m.form,m.size,p.asset,m.material,p.collides
    switch m.form {
    case .Shape:  if !(m.size.x>0 && m.size.x<=SIZE_MAX && m.size.y>0 && m.size.y<=SIZE_MAX) {return c,.Size}
    case .Ribbon: if !(m.size.x>0 && m.size.x<=SIZE_MAX && m.size.y>=0 && m.size.y<=SIZE_MAX) {return c,.Size}
    case .Bend:
        if !(m.size.x>=0 && m.size.x<=SIZE_MAX && m.size.y>=0 && m.size.y<=SIZE_MAX) {return c,.Size}
        if p.asset=={} {return c,.Mesh}
    case: return c,.Entry
    }
    module:=mm.Transform{position=p.position,rotation=p.rotation,scale={1,1,1}}
    // A Shape is centred on its entity along its depth.
    if m.form==.Shape {module.position+=mm.quat_rotate(p.rotation,{0,0,c.length*0.5})}
    c.place=mm.transform_compose(to_entity,module)
    return c,.None
}

@(private)
child_hash :: proc(c:Module_Child) -> u64 {
    c:=c
    return base.hash64(([^]byte)(&c)[:size_of(c)])
}

// The rectangle of a profile thickness by height, standing on y = 0, as the
// polygon of a Shape in its XY plane.
@(private)
profile :: proc "contextless" (size:[2]f32,length:f32,material:base.Asset_Id) -> (s:shapes.Shape) {
    s=shapes.SHAPE_DEFAULT
    half:=size.x*0.5
    s.depth,s.material=length,material
    s.points[0],s.points[1],s.points[2],s.points[3]={-half,0},{half,0},{half,size.y},{-half,size.y}
    return
}

@(private)
child_make :: proc(commands:core.Commands,parent:core.Entity,coord:[2]i32,id,hash:u64,c:Module_Child) {
    child:=core.commands_create(commands)
    core.commands_add(commands,child,core.Parent{entity=parent})
    core.commands_add(commands,child,core.Transform{position=c.place.position,rotation=c.place.rotation,scale=c.place.scale})
    core.commands_add(commands,child,Pcg_Shape_Part{coord=coord,id=id,hash=hash})
    switch c.form {
    case .Shape:
        core.commands_add(commands,child,profile(c.size,c.length,c.material))
        // Without it a shape collides as a static mesh; a module that does not collides with nothing.
        if !c.collides {
            none:=phys.COLLIDER_DEFAULT
            none.kind,none.preset,none.belongs,none.collides=.External,phys.PRESET_CUSTOM,0,0
            core.commands_add(commands,child,none)
        }
    case .Bend:
        b:=shapes.BEND_DEFAULT
        b.start,b.end={},{0,0,c.length}
        b.start_tangent,b.end_tangent=b.end,b.end
        across:=[2]f32{c.size.x if c.size.x>0 else 1,c.size.y if c.size.y>0 else 1}
        b.start_scale,b.end_scale=across,across
        core.commands_add(commands,child,b)
        core.commands_add(commands,child,render.Mesh_Renderer{mesh=c.asset,shape=.None,shadows=true})
        if c.collides {
            collider:=phys.COLLIDER_DEFAULT
            collider.kind=.External
            core.commands_add(commands,child,collider)
        }
    case .Ribbon:
        core.commands_add(commands,child,volume.Spline{count=2,material=c.material,points={
            0={width=c.size.x,height=c.size.y},
            1={position={0,0,c.length},width=c.size.x,height=c.size.y},
        }})
    }
}

@(private)
output_seen :: proc "contextless" (cache:^Pcg_Shapes_Cache,e:core.Entity) -> ^Output_Seen {
    for &o in cache.outputs {if o.entity==e {return &o}}
    return nil
}

// Keeps a child for every module the Grammar layers of each graph with a
// Pcg_Shapes_Output place, as its output says: only on a tick when the
// outputs, the children or the graphs changed, or one graph placed otherwise,
// its source was read again or, world-anchored, it moved; and then only the
// children whose module changed are made again.
@(step="fixed frame",loops="game editor",stage="simulate",after="pcg_update",before="shapes_update")
pcg_shapes_update :: proc(
    cache:^Pcg_Shapes_Cache,outputs:^core.Table(Pcg_Shapes_Output,.Read),parts:^core.Table(Pcg_Shape_Part,.Read),
    graphs:^core.Table(pcg.Pcg_Graph,.Read),worlds:^core.Table(core.World_Transform,.Read),parents:^core.Table(core.Parent,.Read),
    generated:core.Ref(pcg.Pcg_Generated),data:core.Ref(pcg.Pcg_Data),commands:core.Commands,allocator:runtime.Allocator,problems:^core.Problems,
) {
    if cache==nil {return}
    all:=core.touched(outputs,&cache.seen[0]) | core.touched(parts,&cache.seen[1]) | core.touched(graphs,&cache.seen[2])
    dirty:=all
    for row in 0..<core.count(outputs) {
        if dirty {break}
        dirty=output_moved(cache,core.entity_at(outputs,row),graphs,worlds,generated,data)
    }
    // The outputs gone take what was seen of them.
    for i:=len(cache.outputs)-1;i>=0;i-=1 {
        if !core.has(outputs,cache.outputs[i].entity) {unordered_remove(&cache.outputs,i);dirty=true}
    }
    if !dirty {return}
    if cache.allocator.procedure==nil {cache.allocator=allocator}
    cache.stats.passes+=1
    context.allocator=cache.allocator
    // The children there are, by graph, cell and module; those of no output go.
    known:=make([dynamic]Module_Key,0,core.count(parts),context.temp_allocator)
    for row in 0..<core.count(parts) {
        child:=core.entity_at(parts,row)
        parent,has:=core.get(parents,child)
        if !has || !core.has(outputs,parent.entity) || !core.has(graphs,parent.entity) {
            core.commands_destroy(commands,child)
            cache.stats.ended+=1
            continue
        }
        part:=core.at(parts,row)
        append(&known,Module_Key{parent.entity,child,part.coord,part.id,part.hash})
    }
    slice.sort_by(known[:],key_before)
    wanted:=make([dynamic]Wanted,context.temp_allocator)
    for row in 0..<core.count(outputs) {
        e:=core.entity_at(outputs,row)
        out:=core.at(outputs,row)
        if !all && !output_moved(cache,e,graphs,worlds,generated,data) {continue}
        now,graph,source,ok:=output_now(e,graphs,worlds,generated,data)
        if seen:=output_seen(cache,e);seen!=nil {
            seen^=now
        } else if _,error:=append(&cache.outputs,now);error!=nil {
            core.report(problems,e,"pcg_shapes.memory","out of memory for the modules of this Pcg_Shapes_Output; they are tried again: free memory")
            continue
        }
        if !core.has(graphs,e) {
            core.report(problems,e,"pcg_shapes.graph","this Pcg_Shapes_Output builds nothing: its entity has no Pcg_Graph; give it one, or take the output away")
        }
        // The modules it wants now, in the order of the children.
        clear(&wanted)
        errors:[Module_Error]int
        if ok {
            to_entity:=mm.TRANSFORM_IDENTITY
            if graph.world_anchored {
                inverse,inverted:=mm.transform_inverse(now.place)
                if !inverted {
                    core.report(problems,e,"pcg_shapes.place","the modules of this world-anchored Pcg_Graph cannot be placed under its entity, whose scale is 0: give it a scale")
                    continue
                }
                to_entity=inverse
            }
            for &cell in pcg.generated_graph(generated.ptr,e).cells {
                if !cell.built {continue}
                for p in cell.placed {
                    if out.layer!=0 && p.layer!=out.layer {continue}
                    l,_:=pcg.source_layer(source,p.layer)
                    if l==nil || l.kind!=.Grammar {continue}
                    c,error:=pcg_shapes_child(out,l,p,to_entity)
                    if error!=.None {errors[error]+=1;continue}
                    append(&wanted,Wanted{Module_Key{e,core.NONE,cell.coord,p.id,child_hash(c)},c})
                }
            }
        }
        slice.sort_by(wanted[:],proc(a,b:Wanted) -> bool {return key_before(a.key,b.key)})
        // The children it has against those it wants.
        low,high:=0,len(known)
        for low<high {mid:=(low+high)/2;if known[mid].parent<e {low=mid+1} else {high=mid}}
        end:=low
        for end<len(known) && known[end].parent==e {end+=1}
        have:=known[low:end]
        i,j:=0,0
        for i<len(have) || j<len(wanted) {
            if j>=len(wanted) || i<len(have) && key_before(have[i],wanted[j].key) {
                core.commands_destroy(commands,have[i].child)
                cache.stats.ended+=1
                i+=1
                continue
            }
            w:=wanted[j]
            j+=1
            // The same module is kept when it is made of the same, and once.
            kept:=false
            for i<len(have) && have[i].coord==w.coord && have[i].id==w.id {
                if !kept && have[i].hash==w.hash {kept=true} else {
                    core.commands_destroy(commands,have[i].child)
                    cache.stats.ended+=1
                }
                i+=1
            }
            if kept {continue}
            child_make(commands,e,w.coord,w.id,w.hash,w.made)
            cache.stats.made+=1
        }
        if errors[.Entry]>0 {core.report(problems,e,"pcg_shapes.entry","%d modules of this Pcg_Shapes_Output place what no entry of its modules names: add an entry with their asset, or one with none for every other",errors[.Entry])}
        if errors[.Symbol]>0 {core.report(problems,e,"pcg_shapes.symbol","%d modules of this Pcg_Shapes_Output have no length: no grammar symbol of their layer places their asset with a unit size above 0, or two that do have different sizes; give each symbol its own asset",errors[.Symbol])}
        if errors[.Size]>0 {core.report(problems,e,"pcg_shapes.size","%d modules of this Pcg_Shapes_Output have an entry whose size is not a number, below 0 or past %v m, or 0 for the thickness and height of a Shape or the width of a Ribbon: give it the metres of its profile",errors[.Size],SIZE_MAX)}
        if errors[.Mesh]>0 {core.report(problems,e,"pcg_shapes.mesh","%d modules of this Pcg_Shapes_Output are bent, but their symbol places no mesh: give the symbol or its layer the mesh to bend",errors[.Mesh])}
    }
}

// A child of a module, or one wanted: its graph entity, its cell and module, and what it is made of.
@(private)
Module_Key :: struct {parent,child:core.Entity,coord:[2]i32,id,hash:u64}
@(private)
Wanted :: struct {using key:Module_Key,made:Module_Child}

@(private)
key_before :: proc(a,b:Module_Key) -> bool {
    if a.parent!=b.parent {return a.parent<b.parent}
    if a.coord!=b.coord {return a.coord.y<b.coord.y || a.coord.y==b.coord.y && a.coord.x<b.coord.x}
    return a.id<b.id
}

// What an output sees of its graph now; ok is false without a graph, its
// cells or its source.
@(private)
output_now :: proc(e:core.Entity,graphs:^core.Table(pcg.Pcg_Graph,.Read),worlds:^core.Table(core.World_Transform,.Read),generated:core.Ref(pcg.Pcg_Generated),data:core.Ref(pcg.Pcg_Data)) -> (now:Output_Seen,graph:pcg.Pcg_Graph,source:^pcg.Pcg_Source,ok:bool) {
    now.entity,now.place=e,mm.TRANSFORM_IDENTITY
    has:bool
    if graph,has=core.get(graphs,e);!has {return}
    if world,placed:=core.get(worlds,e);placed {now.place=world.transform}
    built:=pcg.generated_graph(generated.ptr,e)
    entry:=data.ptr!=nil?pcg.data_find(data.ptr,graph.source):nil
    if built==nil || entry==nil {return}
    now.revision,now.epoch,now.loads=built.revision,entry.epoch,entry.loads
    return now,graph,&entry.source,true
}

// Whether what an output was built from moved since it was seen.
@(private)
output_moved :: proc(cache:^Pcg_Shapes_Cache,e:core.Entity,graphs:^core.Table(pcg.Pcg_Graph,.Read),worlds:^core.Table(core.World_Transform,.Read),generated:core.Ref(pcg.Pcg_Generated),data:core.Ref(pcg.Pcg_Data)) -> bool {
    seen:=output_seen(cache,e)
    if seen==nil {return true}
    now,graph,_,_:=output_now(e,graphs,worlds,generated,data)
    if now.revision!=seen.revision || now.epoch!=seen.epoch || now.loads!=seen.loads {return true}
    return graph.world_anchored && now.place!=seen.place
}
