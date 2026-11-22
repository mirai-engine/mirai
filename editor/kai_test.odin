package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import ka "mirai:cook/kai"
import vcs "mirai:kai"
import "mirai:std/base"
import "mirai:store"

@(private="file") Kai_Transform :: struct {position:[3]f32,rotation:quaternion128,scale:[3]f32}
@(private="file") Kai_Light :: struct {color:[3]f32,intensity:f32,range:f32}
@(private="file") KAI_ROOT :: base.Entity_Id(0x10)
@(private="file") KAI_LAMP :: base.Entity_Id(0x20)

// An editor on a project with a store and the storages of Kai.
@(private="file")
Kai_Fixture :: struct {
    using f:Prefab_Fixture,
    kai:Kai,
    authorship:Kai_Authorship,
}

@(private="file")
kai_fixture_init :: proc(t:^testing.T,k:^Kai_Fixture,name:string) -> bool {
    if !prefab_fixture_init(t,&k.f,name) {return false}
    k.s.project_root,k.s.has_project=k.root,true
    opened,error:=store.open(base.test_folder(t,fmt.tprintf("%s-store",name)))
    if !testing.expect_value(t,error,store.Error.None) {return false}
    k.s.store=opened
    k.s.kai,k.s.kai_authorship=&k.kai,&k.authorship
    return true
}

@(private="file")
kai_fixture_destroy :: proc(k:^Kai_Fixture) {
    kai_close(&k.s)
    delete(k.authorship.items)
    delete(k.authorship.waiting)
    store.close(&k.s.store)
    prefab_fixture_destroy(&k.f)
}

// The scene with a lamp at x and of intensity.
@(private="file")
kai_scene :: proc(t:^testing.T,types:^asset.Types,x,intensity:f32) -> []u8 {
    scene:asset.Scene
    testing.expect_value(t,asset.scene_init(&scene,types,{0x61,0x62}),asset.Error.None)
    defer asset.scene_destroy(&scene)
    asset.scene_entity_add(&scene,KAI_ROOT,0,"Root")
    asset.scene_entity_add(&scene,KAI_LAMP,KAI_ROOT,"Lamp")
    root:=Kai_Transform{rotation=1,scale={1,1,1}}
    asset.scene_set(&scene,KAI_ROOT,"Transform",&root)
    lamp:=Kai_Transform{position={x,0,0},rotation=1,scale={1,1,1}}
    asset.scene_set(&scene,KAI_LAMP,"Transform",&lamp)
    light:=Kai_Light{{1,1,1},intensity,10}
    asset.scene_set(&scene,KAI_LAMP,"Light",&light)
    bytes,e:=asset.scene_bytes(&scene,context.temp_allocator)
    testing.expect_value(t,e,asset.Error.None)
    return bytes
}

// The lamp of the scene file: where it is and how bright.
@(private="file")
kai_lamp :: proc(t:^testing.T,types:^asset.Types,file:string) -> (x,intensity:f32) {
    bytes,read_error:=os.read_entire_file(file,context.temp_allocator)
    if !testing.expect(t,read_error==nil,"the scene is there") {return}
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_read(&scene,types,bytes),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    transform,_:=asset.scene_get(&scene,KAI_LAMP,"Transform",Kai_Transform)
    light,_:=asset.scene_get(&scene,KAI_LAMP,"Light",Kai_Light)
    return transform.position.x,light.intensity
}

@(private="file")
kai_write :: proc(t:^testing.T,s:^Session,file:string,bytes:[]u8) {
    testing.expect(t,os.write_entire_file(file,bytes)==nil)
    kai_touched(s,file)
    testing.expect_value(t,kai_snapshot(s),"")
}

// The editor snapshots what it wrote, shows what a change did, starts changes
// on others whose trees merge, leaves what does not merge as a conflict that
// blocks nothing and resolves it field by field; undo takes the resolution
// back and undoing the undo redoes it.
@(test)
editor_kai_snapshot_diff_conflict_and_undo :: proc(t:^testing.T) {
    k:=new(Kai_Fixture);defer free(k)
    if !kai_fixture_init(t,k,"kai-editor") {return}
    defer kai_fixture_destroy(k)
    s:=&k.s
    types:=&k.assets.types
    file:=fmt.tprintf("%s/level.scene",k.root)
    testing.expect(t,os.write_entire_file(file,kai_scene(t,types,0,3))==nil)

    // The project becomes a workspace: its files are the first change.
    kai_open(s)
    w:=kai_workspace(s)
    if !testing.expectf(t,w!=nil,"the workspace opens: %v",s.kai.error) {return}
    testing.expect(t,ka.project_exists(k.root))
    origin:=vcs.repo_working(&w.repo)
    testing.expect_value(t,kai_describe(s,origin,"origin"),"")
    origin=vcs.repo_working(&w.repo)

    // Ours: the lamp moves. The change shows the scene changed.
    testing.expect_value(t,kai_new(s,nil,""),"")
    kai_write(t,s,file,kai_scene(t,types,5,3))
    v:=&s.kai.state.view
    testing.expectf(t,len(v.files)==1 && v.files[0].path=="level.scene" && v.files[0].mark=='M',"%v",v.files)
    testing.expect_value(t,kai_describe(s,vcs.repo_working(&w.repo),"move the lamp"),"")
    ours:=vcs.repo_working(&w.repo)

    // Theirs, on the origin: the files go back to it; the lamp moves elsewhere and brightens.
    parents:=[1]vcs.Revision{origin}
    testing.expect_value(t,kai_new(s,parents[:],"brighten"),"")
    x,intensity:=kai_lamp(t,types,file)
    testing.expect(t,x==0 && intensity==3,"a new change on the origin writes its files")
    kai_write(t,s,file,kai_scene(t,types,9,7))
    theirs:=vcs.repo_working(&w.repo)

    // Both: the light merges, the move is a conflict the file holds with ours.
    both:=[2]vcs.Revision{ours,theirs}
    testing.expect_value(t,kai_new(s,both[:],"merge"),"")
    testing.expect_value(t,len(w.state.conflicts),1)
    testing.expectf(t,len(v.files)>0 && v.files[0].mark=='C',"the change shows the conflict: %v",v.files)
    x,intensity=kai_lamp(t,types,file)
    testing.expect(t,x==5 && intensity==7,"the conflict is written with ours, and what merged")
    kai_unfold(s,"level.scene")
    if !testing.expectf(t,len(v.fields)==1 && v.fields[0].kind==.Value && strings.contains(v.fields[0].path,"Transform"),"%v",v.fields) {return}

    // Theirs for the move: written, recorded, no conflict left.
    picked:=[1]string{strings.clone(v.fields[0].path,context.temp_allocator)}
    testing.expect_value(t,kai_resolve(s,"level.scene",.Fields,picked[:]),"")
    testing.expect_value(t,len(w.state.conflicts),0)
    x,intensity=kai_lamp(t,types,file)
    testing.expect(t,x==9 && intensity==7,"theirs for the move, the light as merged")
    totals,_:=vcs.tree_totals(w.repo.s,s.kai.state.project.workspace.state.tree)
    testing.expect_value(t,totals.conflicts,0)

    // Undo takes the resolution back, and undoing the undo redoes it.
    _,message:=kai_undo(s)
    testing.expect_value(t,message,"")
    testing.expect_value(t,len(w.state.conflicts),1)
    x,_=kai_lamp(t,types,file)
    testing.expect_value(t,x,5)
    testing.expect(t,v.redo,"the newest operation is an undo")
    _,message=kai_undo(s)
    testing.expect_value(t,message,"")
    testing.expect_value(t,len(w.state.conflicts),0)
    x,_=kai_lamp(t,types,file)
    testing.expect_value(t,x,9)
}
