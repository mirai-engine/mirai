package asset

import "core:math"
import "core:slice"
import "core:testing"
import "mirai:std/serial"

@(test)
mesh_morphs_roundtrip_sparse_named_targets_and_refuse_broken_ranges :: proc(t:^testing.T) {
    vertices:=[3]Vertex{{position={0,0,0}},{position={1,0,0}},{position={0,1,0}}}
    indices:=[3]u32{0,1,2}
    targets:=[2]Morph_Target{{weight=.25,count=1},{weight=-.5,first=1,count=2}}
    text_set(targets[0].name[:],"Smile");text_set(targets[1].name[:],"Wide")
    deltas:=[3]Morph_Delta{{vertex=1,position={2,0,0},normal={0,.1,0},tangent={0,0,.2}},{vertex=0,position={0,3,0}},{vertex=2,tangent={1,0,0}}}
    types:Types;types_init(&types);defer types_destroy(&types)
    doc:Document
    if !testing.expect_value(t,mesh_document(&doc,&types,{id={51,17},geometry=test_geometry(vertices[:],indices[:],morphs=targets[:],deltas=deltas[:])}),Error.None) {return}
    defer document_destroy(&doc)
    testing.expect_value(t,doc.kind_version,u16(MESH_VERSION))
    bytes:serial.Writer;serial.writer_init(&bytes);defer serial.writer_destroy(&bytes)
    testing.expect_value(t,document_write(&doc,&bytes),Error.None)
    file:Asset
    if !testing.expect_value(t,asset_open(&file,serial.writer_bytes(&bytes)),Error.None) {return}
    defer asset_close(&file)
    view,error:=mesh_view(&file,&types)
    if !testing.expect_value(t,error,Error.None) {return}
    testing.expect_value(t,view.morphs[1],targets[1])
    testing.expect_value(t,view.morph_step,morph_step(3))
    for delta,i in deltas {testing.expect_value(t,view.morph_deltas[i],morph_quantize(delta,view.morph_step))}
    testing.expect(t,mesh_check_indices(view))
    broken:=view;moved:=slice.clone(view.morph_deltas,context.temp_allocator);broken.morph_deltas=moved
    moved[0].vertex=3;testing.expect(t,!mesh_check_indices(broken),"a delta of a vertex the mesh has not")
    copy(moved,view.morph_deltas);moved[2].vertex=0;testing.expect(t,!mesh_check_indices(broken),"a delta before the one before it")
    copy(moved,view.morph_deltas);moved[1].tangent|=1<<30;testing.expect(t,!mesh_check_indices(broken),"bits past those of the tangent")
    info:=view.info^;broken=view;broken.info=&info
    for step in ([?]f32{0,-.5,3,math.nan_f32(),math.inf_f32(1)}) {info.morph_step=step;testing.expectf(t,!mesh_check(broken),"targets on a step of %v",step)}
    info=view.info^;broken.morphs=nil;broken.morph_deltas=nil;testing.expect(t,!mesh_check(broken),"a step without targets")
    invalid:=targets;invalid[1].name=invalid[0].name;broken=view;broken.morphs=invalid[:];testing.expect(t,!mesh_check(broken))
    invalid=targets;invalid[1].first=max(u32);broken.morphs=invalid[:];testing.expect(t,!mesh_check(broken))
    invalid=targets;invalid[1].count=1;broken.morphs=invalid[:];testing.expect(t,!mesh_check(broken))
    invalid=targets;invalid[0].weight=transmute(f32)u32(0x7fc00000);broken.morphs=invalid[:];testing.expect(t,!mesh_check(broken))
    for cut in 0..<bytes.count {
        truncated:Asset
        if asset_open(&truncated,serial.writer_bytes(&bytes)[:cut])==.None {
            if view,read:=mesh_view(&truncated,&types);read==.None {mesh_check_indices(view)}
            asset_close(&truncated)
        }
    }
}

// Each component of a delta comes back within half a step: of the mesh's
// step for positions, the finest that reaches the largest, and of the fixed
// steps for normals and tangents, clamped to the difference of two unit vectors.
@(test)
morph_deltas_quantize_within_half_a_step_and_the_builder_refuses_what_it_cannot_store :: proc(t:^testing.T) {
    fractions:=[?]f32{-1,-.999983,-.5,-1.0/3,0,1e-7,.0012345,.123456,.5000001,.75,1}
    for largest in ([?]f32{0,1e-9,1e-6,.37,1,250,3e5,1e30}) {
        step:=morph_step(largest)
        testing.expectf(t,step_valid(step) && f64(largest)<=f64(step)*MORPH_POSITION_LIMIT,"step %v reaches %v",step,largest)
        testing.expectf(t,f64(largest)>f64(step)/2*MORPH_POSITION_LIMIT || step<=1e-11,"step %v is the finest for %v",step,largest)
        for a in fractions {
            for b in fractions {
                given:=Morph_Delta{vertex=7,position={a*largest,-b*largest,b*largest},normal={2*a,2*b,a+b},tangent={2*b,-2*a,a-b}}
                q:=morph_quantize(given,step)
                back:=morph_decode(q,step)
                testing.expect_value(t,back.vertex,given.vertex)
                for axis in 0..<3 {
                    testing.expectf(t,abs(f64(back.position[axis])-f64(given.position[axis]))<=f64(step)/2,"position %v of %v",axis,given.position)
                    testing.expectf(t,abs(back.normal[axis]-given.normal[axis])<=MORPH_NORMAL_STEP/2+1e-6,"normal %v of %v",axis,given.normal)
                    testing.expectf(t,abs(back.tangent[axis]-given.tangent[axis])<=MORPH_TANGENT_STEP/2+1e-6,"tangent %v of %v",axis,given.tangent)
                }
                testing.expect(t,q.tangent>>30==0)
                testing.expect_value(t,morph_quantize(back,step),q)
            }
        }
    }
    huge:=morph_decode(morph_quantize({position={max(f32),-max(f32),0}},morph_step(max(f32))),morph_step(max(f32)))
    testing.expect(t,huge.position.x-huge.position.x==0 && huge.position.y-huge.position.y==0,"the largest deltas decode finite")
    clamped:=morph_decode(morph_quantize({normal={5,-9,2},tangent={-3,4,-2}},1),1)
    testing.expect(t,abs(clamped.normal.x-2)<1e-4 && abs(clamped.normal.y+2)<1e-4 && abs(clamped.tangent.y-2)<1e-4 && abs(clamped.tangent.z+2)<1e-4)

    vertices:=[3]Vertex{{position={0,0,0}},{position={1,0,0}},{position={0,1,0}}}
    indices:=[3]u32{0,1,2}
    target:=Morph_Target{weight=1,count=1};text_set(target.name[:],"Up")
    good:=Morph_Delta{vertex=1,position={0,.5,0}}
    nan,inf:=math.nan_f32(),math.inf_f32(-1)
    Case :: struct {what:string,target:Morph_Target,delta:Morph_Delta}
    cases:=[?]Case{
        {"a vertex out of the source",target,{vertex=3,position={0,.5,0}}},
        {"a range out of the deltas",{weight=1,first=1,count=1},good},
        {"a range that wraps",{weight=1,first=max(u32),count=2},good},
        {"a position that is not a number",target,{vertex=1,position={0,nan,0}}},
        {"an infinite position",target,{vertex=1,position={inf,0,0}}},
        {"a normal that is not a number",target,{vertex=1,normal={0,0,nan}}},
        {"an infinite tangent",target,{vertex=1,tangent={0,inf,0}}},
    }
    for c in cases {
        built:Mesh_Geometry
        targets,deltas:=[1]Morph_Target{c.target},[1]Morph_Delta{c.delta}
        testing.expectf(t,!mesh_build({vertices=vertices[:],morphs=targets[:],morph_deltas=deltas[:]},indices[:],nil,&built,context.temp_allocator),"the builder refuses %s",c.what)
    }
    built:Mesh_Geometry
    targets,deltas:=[1]Morph_Target{target},[1]Morph_Delta{good}
    if testing.expect(t,mesh_build({vertices=vertices[:],morphs=targets[:],morph_deltas=deltas[:]},indices[:],nil,&built,context.temp_allocator)) {
        testing.expect(t,len(built.morph_deltas)==1 && morph_decode(built.morph_deltas[0],built.morph_step).position==good.position,"a delta on the grid comes back as it was")
    }
    free_all(context.temp_allocator)
}

@(test)
meshes_without_morphs_have_no_morph_tables :: proc(t:^testing.T) {
    vertices:=[3]Vertex{{position={0,0,0}},{position={1,0,0}},{position={0,1,0}}}
    types:Types;types_init(&types);defer types_destroy(&types)
    doc:Document
    if !testing.expect_value(t,mesh_document(&doc,&types,{id={13,15},geometry=test_geometry(vertices[:],{0,1,2})}),Error.None) {return}
    defer document_destroy(&doc)
    bytes:serial.Writer;serial.writer_init(&bytes);defer serial.writer_destroy(&bytes)
    testing.expect_value(t,document_write(&doc,&bytes),Error.None)
    file:Asset
    if !testing.expect_value(t,asset_open(&file,serial.writer_bytes(&bytes)),Error.None) {return}
    defer asset_close(&file)
    view,error:=mesh_view(&file,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,len(view.morphs)==0 && len(view.morph_deltas)==0 && view.morph_step==0)
    _,has_morphs:=asset_table(&file,"morphs");_,has_deltas:=asset_table(&file,"morph_deltas")
    testing.expect(t,!has_morphs && !has_deltas)
}
