package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

Unsaved_Test_Look :: struct {material:base.Asset_Id}

Unsaved_Test_World :: struct {
    entities:core.Entities,
    looks:core.Table(Unsaved_Test_Look),
}

@(test)
unsaved_assets_are_saved_discarded_and_found_through_what_a_world_uses :: proc(t:^testing.T) {
    temporary,_:=os.temp_directory(context.temp_allocator)
    root,_:=strings.replace_all(project.path(temporary,fmt.tprintf("mirai-unsaved-%d",os.get_pid()),allocator=context.temp_allocator),"\\","/",context.temp_allocator)
    os.remove_all(root)
    defer os.remove_all(root)
    folder:=project.path(root,"assets",allocator=context.temp_allocator)
    os.make_directory_all(folder)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    stone,clay,other:=base.Asset_Id{1,1},base.Asset_Id{2,2},base.Asset_Id{3,3}
    with_clay:=asset.MATERIAL_DEFAULTS
    with_clay.maps.base_color.texture=clay
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/stone.mat",folder),&types,{id=stone,info=with_clay}),asset.Error.None)
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/clay.mat",folder),&types,{id=clay,info=asset.MATERIAL_DEFAULTS}),asset.Error.None)
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/other.mat",folder),&types,{id=other,info=asset.MATERIAL_DEFAULTS}),asset.Error.None)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}

    w:Unsaved_Test_World
    core.entities_init(&w.entities);defer core.entities_destroy(&w.entities)
    core.table_init(&w.looks,"Look");defer core.table_destroy(&w.looks)
    tables:=[1]core.Table_Info{{name="Look",type=Unsaved_Test_Look,info=type_info_of(Unsaved_Test_Look),offset=offset_of(Unsaved_Test_World,looks)}}
    info:=core.World_Info{entities=offset_of(Unsaved_Test_World,entities),tables=tables[:]}
    e:=core.create(&w.entities)
    core.add(&w.looks,e,Unsaved_Test_Look{material=stone})
    core.table_settle(&w.looks,&w.entities)
    s:=Session{app=&app}

    rough:=asset.MATERIAL_DEFAULTS
    rough.roughness=0.25
    bytes:=proc(t:^testing.T,types:^asset.Types,id:base.Asset_Id,info:asset.Material_Info) -> []u8 {
        data,error:=asset.material_bytes(types,{id=id,info=info},context.temp_allocator)
        testing.expect_value(t,error,asset.Error.None)
        return data
    }
    testing.expect(t,file_write(&s,fmt.tprintf("%s/clay.mat",folder),bytes(t,&types,clay,rough),"Write"))
    testing.expect(t,file_write(&s,fmt.tprintf("%s/other.mat",folder),bytes(t,&types,other,rough),"Write"))
    testing.expect_value(t,len(assets_unsaved(&s)),2)
    testing.expect(t,asset_unsaved(&s,clay) && !asset_unsaved(&s,stone))
    // A game of players of other processes says which and how to go on: they read the saved files.
    refused:=play_unsaved(&s)
    testing.expect(t,strings.contains(refused,"clay.mat, other.mat") && strings.contains(refused,"asset.save") && strings.contains(refused,"saved_only:true"),refused)

    // The world shows stone, and stone needs clay: clay is what it uses unsaved.
    used:=make([dynamic]string,context.temp_allocator)
    world_unsaved_assets(&s,{data=&w,info=&info},&used)
    testing.expect(t,len(used)==1 && used[0]=="clay.mat","what a world uses reaches the dependencies of what it names")

    saved,ok:=assets_save(&s,used[:])
    testing.expect(t,ok && saved==1)
    on_disk,_:=os.read_entire_file(fmt.tprintf("%s/clay.mat",folder),context.temp_allocator)
    testing.expect(t,string(on_disk)==string(bytes(t,&types,clay,rough)),"saved, the file holds the change")
    testing.expect_value(t,len(assets_unsaved(&s)),1)

    // A restart or a recovery keeps them in a folder and puts them back.
    testing.expect(t,file_write(&s,fmt.tprintf("%s/stone.mat",folder),nil,"Remove",remove=true))
    kept:=project.path(root,"kept",allocator=context.temp_allocator)
    testing.expect(t,assets_unsaved_store(&s,kept) && assets_unsaved_kept(kept))
    paths:=assets_unsaved_paths(&s)
    testing.expect_value(t,len(paths),2)
    testing.expect_value(t,assets_discard(&s,paths),2)
    restored,read:=assets_unsaved_restore(&s,kept)
    testing.expect(t,read && restored==2 && !os.exists(kept))
    held,found:=asset.registry_memory_find(&assets.registry,"stone.mat")
    testing.expect(t,found && held.removed,"a removed file comes back removed")
    held,found=asset.registry_memory_find(&assets.registry,"other.mat")
    testing.expect(t,found && string(held.data)==string(bytes(t,&types,other,rough)))
    testing.expect_value(t,assets_discard(&s,[]string{"stone.mat"}),1)

    testing.expect_value(t,assets_discard(&s,assets_unsaved_paths(&s)),1)
    testing.expect_value(t,len(assets_unsaved(&s)),0)
    testing.expect_value(t,play_unsaved(&s),"")
    row:=host.assets_material_row(&assets,other)
    testing.expect_value(t,host.assets_material_values(&assets,row).roughness,asset.MATERIAL_DEFAULTS.roughness)
}

@(test)
quitting_asks_once_about_the_scene_and_the_unsaved_assets :: proc(t:^testing.T) {
    temporary,_:=os.temp_directory(context.temp_allocator)
    folder,_:=strings.replace_all(project.path(temporary,fmt.tprintf("mirai-quit-%d",os.get_pid()),allocator=context.temp_allocator),"\\","/",context.temp_allocator)
    os.remove_all(folder)
    defer os.remove_all(folder)
    os.make_directory_all(folder)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    clay:=base.Asset_Id{2,2}
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/clay.mat",folder),&types,{id=clay,info=asset.MATERIAL_DEFAULTS}),asset.Error.None)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    gui:Editor_Ui
    defer confirm_assets_set(&gui,nil)
    defer delete(gui.confirm_assets)
    edits:history.Edits
    document:Document
    selection:history.Selection
    defer delete(selection.entities)
    s:=Session{app=&app,gui=&gui,document=&document,selection=&selection}
    defer documents_free(&s)
    rough:=asset.MATERIAL_DEFAULTS
    rough.roughness=0.25
    data,error:=asset.material_bytes(&types,{id=clay,info=rough},context.temp_allocator)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect(t,file_write(&s,fmt.tprintf("%s/clay.mat",folder),data,"Write"))
    s.edits=&edits
    document.unsaved=true

    documents_quit_next(&s)
    testing.expect(t,gui.modal==.Confirm && gui.pending==.Quit && len(gui.confirm_assets)==1,"the question about the scene lists the unsaved asset")
    confirm_resolve(&s,.Discard)
    testing.expect_value(t,len(assets_unsaved(&s)),0)
    testing.expect(t,.Quit_Check in s.requests)
    documents_quit_next(&s)
    testing.expect(t,s.quit && gui.modal==.None,"nothing is asked a second time")
}

Owned_Test_Look :: struct {material:base.Asset_Id,made:base.Asset_Id `mirai:"owned"`}

Owned_Test_World :: struct {
    entities:core.Entities,
    looks:core.Table(Owned_Test_Look),
}

// An asset of a field tagged owned is the scene's: saving the scene saves it,
// and Save changes does not ask about it; one it only uses is asked about.
@(test)
the_unsaved_assets_a_world_owns_are_those_of_its_owned_fields :: proc(t:^testing.T) {
    temporary,_:=os.temp_directory(context.temp_allocator)
    folder,_:=strings.replace_all(project.path(temporary,fmt.tprintf("mirai-owned-%d",os.get_pid()),allocator=context.temp_allocator),"\\","/",context.temp_allocator)
    os.remove_all(folder)
    defer os.remove_all(folder)
    os.make_directory_all(folder)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    used_id,made_id:=base.Asset_Id{1,1},base.Asset_Id{2,2}
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/used.mat",folder),&types,{id=used_id,info=asset.MATERIAL_DEFAULTS}),asset.Error.None)
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/made.mat",folder),&types,{id=made_id,info=asset.MATERIAL_DEFAULTS}),asset.Error.None)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    w:Owned_Test_World
    core.entities_init(&w.entities);defer core.entities_destroy(&w.entities)
    core.table_init(&w.looks,"Look");defer core.table_destroy(&w.looks)
    tables:=[1]core.Table_Info{{name="Look",type=Owned_Test_Look,info=type_info_of(Owned_Test_Look),offset=offset_of(Owned_Test_World,looks)}}
    info:=core.World_Info{entities=offset_of(Owned_Test_World,entities),tables=tables[:]}
    core.add(&w.looks,core.create(&w.entities),Owned_Test_Look{material=used_id,made=made_id})
    core.table_settle(&w.looks,&w.entities)
    s:=Session{app=&app}
    rough:=asset.MATERIAL_DEFAULTS
    rough.roughness=0.25
    for pair in ([2]struct{id:base.Asset_Id,file:string}{{used_id,"used.mat"},{made_id,"made.mat"}}) {
        data,error:=asset.material_bytes(&types,{id=pair.id,info=rough},context.temp_allocator)
        testing.expect_value(t,error,asset.Error.None)
        testing.expect(t,file_write(&s,fmt.tprintf("%s/%s",folder,pair.file),data,"Write"))
    }
    world:=core.World_Ref{data=&w,info=&info}
    used:=make([dynamic]string,context.temp_allocator)
    world_unsaved_assets(&s,world,&used)
    testing.expectf(t,len(used)==2,"the world uses both: %v",used)
    owned:=make([dynamic]string,context.temp_allocator)
    world_owned_unsaved(&s,world,&owned)
    testing.expectf(t,len(owned)==1 && owned[0]=="made.mat","the world owns the one of its owned field: %v",owned)
}
