package kai_assets

import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import "mirai:store"
import vcs "mirai:kai"

@(private="file") Test_Transform :: struct {position:[3]f32,rotation:quaternion128,scale:[3]f32}
@(private="file") Test_Light :: struct {color:[3]f32,intensity:f32,range:f32}
@(private="file") ROOT :: base.Entity_Id(0x10)
@(private="file") LAMP :: base.Entity_Id(0x20)

// The bytes of the scene every side starts from, with what change makes to it.
@(private="file")
scene_file :: proc(t:^testing.T,types:^asset.Types,change:proc(scene:^asset.Scene)=nil) -> []u8 {
    scene:asset.Scene
    testing.expect_value(t,asset.scene_init(&scene,types,{0x61,0x62}),asset.Error.None)
    defer asset.scene_destroy(&scene)
    asset.scene_entity_add(&scene,ROOT,0,"Root")
    asset.scene_entity_add(&scene,LAMP,ROOT,"Lamp")
    for id in ([]base.Entity_Id{ROOT,LAMP}) {
        value:=Test_Transform{rotation=1,scale={1,1,1}}
        asset.scene_set(&scene,id,"Transform",&value)
    }
    light:=Test_Light{{1,1,1},3,10}
    asset.scene_set(&scene,LAMP,"Light",&light)
    if change!=nil {change(&scene)}
    bytes,e:=asset.scene_bytes(&scene,context.temp_allocator)
    testing.expect_value(t,e,asset.Error.None)
    return bytes
}

@(private="file")
tree_with :: proc(t:^testing.T,s:^store.Store,bytes:[]u8) -> store.Hash {
    address,e:=store.put(s,bytes)
    testing.expect_value(t,e,store.Error.None)
    root,f:=vcs.tree_build(s,{vcs.File{path="assets/level.scene",kind=.File,address=address,size=u64(len(bytes))}})
    testing.expect_value(t,f,vcs.Error.None)
    return root
}

@(test)
a_scene_merges_by_field_through_the_driver :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"cook-kai");if folder=="" {return}
    s,e:=store.open(strings.concatenate({folder,"/store"},context.temp_allocator))
    if !testing.expect_value(t,e,store.Error.None) {return}
    defer store.close(&s)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)

    origin:=scene_file(t,&types)
    ours:=scene_file(t,&types,proc(scene:^asset.Scene) {
        moved:=Test_Transform{position={5,0,0},rotation=1,scale={1,1,1}}
        asset.scene_set(scene,LAMP,"Transform",&moved)
    })
    theirs:=scene_file(t,&types,proc(scene:^asset.Scene) {
        brighter:=Test_Light{{1,1,1},7,10}
        asset.scene_set(scene,LAMP,"Light",&brighter)
    })

    d:=Asset_Driver{types=&types}
    drivers:=[1]vcs.Driver{driver(&d)}
    m:=vcs.Merger{s=&s,drivers=drivers[:]}
    root,merge_error:=vcs.tree_merge3(&m,tree_with(t,&s,origin),tree_with(t,&s,ours),tree_with(t,&s,theirs))
    testing.expect_value(t,merge_error,vcs.Error.None)
    totals,_:=vcs.tree_totals(&s,root)
    testing.expect_value(t,totals.conflicts,0)

    files:=make([dynamic]vcs.File,context.temp_allocator)
    testing.expect_value(t,vcs.tree_files(&s,root,&files,context.temp_allocator),vcs.Error.None)
    if !testing.expect_value(t,len(files),1) {return}
    merged_bytes,_:=vcs.file_bytes(&s,files[0].address,context.temp_allocator)
    merged:asset.Scene
    testing.expect_value(t,asset.scene_read(&merged,&types,merged_bytes),asset.Error.None)
    defer asset.scene_destroy(&merged)
    transform,_:=asset.scene_get(&merged,LAMP,"Transform",Test_Transform)
    light,_:=asset.scene_get(&merged,LAMP,"Light",Test_Light)
    testing.expect(t,transform.position==[3]f32{5,0,0},"ours moved the lamp")
    testing.expect_value(t,light.intensity,7)

    // A comment on the lamp follows it into the merge; one on an entity gone does not.
    anchor:=vcs.Anchor{kind=.Structural,key=u64(LAMP)}
    testing.expect(t,vcs.drivers_anchor(drivers[:],ours,merged_bytes,&anchor))
    gone:=vcs.Anchor{kind=.Structural,key=0x99}
    testing.expect(t,!vcs.drivers_anchor(drivers[:],ours,merged_bytes,&gone))

    // Both moved the lamp apart: a conflict, written with ours where they disagree.
    apart:=scene_file(t,&types,proc(scene:^asset.Scene) {
        moved:=Test_Transform{position={0,9,0},rotation=1,scale={1,1,1}}
        asset.scene_set(scene,LAMP,"Transform",&moved)
    })
    conflicted,_:=vcs.tree_merge3(&m,tree_with(t,&s,origin),tree_with(t,&s,ours),tree_with(t,&s,apart))
    totals,_=vcs.tree_totals(&s,conflicted)
    testing.expect_value(t,totals.conflicts,1)
    testing.expect(t,!filter().procedure(nil,".mirai/cache") && filter().procedure(nil,"assets/level.scene"))
}

// A driver's result is kept by its id, its version and the three terms: the
// second identical merge does not call it, another term or version does.
@(test)
a_driver_result_is_kept_by_its_terms_and_version :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-merge-cache")
    if folder=="" {return}
    s,se:=store.open(strings.concatenate({folder,"/store"},context.temp_allocator))
    if !testing.expect_value(t,se,store.Error.None) {return}
    defer store.close(&s)
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    calls:=0
    inner:=vcs.Driver{id=9,version=1,data=&calls,merge=proc(data:rawptr,input:^vcs.Driver_Input,out:^[dynamic]u8) -> vcs.Driver_Result {
        (^int)(data)^+=1
        append(out,..input.ours)
        append(out,..input.theirs)
        return .Conflicted
    }}
    c:=Cached_Driver{driver=inner,cache={store=&s},types=&types}
    term :: proc(text:string) -> store.Hash {return store.address_of_bytes(transmute([]u8)text)}
    input:=vcs.Driver_Input{base=transmute([]u8)string("base"),ours=transmute([]u8)string("ours"),theirs=transmute([]u8)string("theirs"),has_base=true,terms={term("base"),term("ours"),term("theirs")}}
    Step :: struct {change:proc(c:^Cached_Driver,input:^vcs.Driver_Input),calls:int}
    steps:=[?]Step{
        {nil,1},
        {nil,1}, // the same terms: kept
        {proc(c:^Cached_Driver,input:^vcs.Driver_Input) {input.terms[2]=store.Hash{0=1}},2},
        {proc(c:^Cached_Driver,input:^vcs.Driver_Input) {c.driver.version=2},3},
        {nil,3},
    }
    for step,k in steps {
        if step.change!=nil {step.change(&c,&input)}
        out:=make([dynamic]u8,context.temp_allocator)
        d:=cached(&c)
        result:=d.merge(d.data,&input,&out)
        testing.expectf(t,result==.Conflicted && string(out[:])=="ourstheirs","step %d: %v %q",k,result,string(out[:]))
        testing.expectf(t,calls==step.calls,"step %d: the driver was called %d times, not %d",k,calls,step.calls)
    }
}
