package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

@(test_world)
Apply_Test_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    meshes:core.Table(erender.Mesh_Renderer),
    looks:core.Table(erender.Material_Values),
}

@(test)
an_imported_material_keeps_a_change_not_yet_written_over_an_import_and_goes_back_by_field :: proc(t:^testing.T) {
    root:=base.test_folder(t,"material-base")
    if root=="" {return}
    folder:=project.path(root,"assets",allocator=context.temp_allocator)
    os.make_directory_all(folder)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    body:=base.Asset_Id{4,4}
    path:=fmt.tprintf("%s/body.mat",folder)
    source:asset.Import_Info
    asset.text_set(source.source[:],"body.gltf")
    asset.text_set(source.name[:],"Body")
    given:=asset.MATERIAL_DEFAULTS
    given.roughness=0.5
    given.maps.base_color.texture={1,1}
    bytes :: proc(t:^testing.T,types:^asset.Types,id:base.Asset_Id,info:asset.Material_Info,imported:^asset.Material_Info,source:^asset.Import_Info) -> []u8 {
        data,error:=asset.material_bytes(types,{id=id,info=info,imported=imported,source=source},context.temp_allocator)
        testing.expect_value(t,error,asset.Error.None)
        return data
    }
    testing.expect(t,os.write_entire_file(path,bytes(t,&types,body,given,&given,&source))==nil)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    materials:Materials
    info:core.World_Info
    s:=Session{app=&app,materials=&materials,info=&info}

    // A person makes the material rougher, and the registry holds it until its step ends.
    rough:=given
    rough.roughness=0.9
    testing.expect(t,file_write(&s,path,bytes(t,&types,body,rough,&given,&source),"Material"))
    imported:=material_base(&s,body)
    testing.expect(t,imported!=nil && imported^==given,"the reference of its fields is what the source gave")

    // The source gives another texture, and its import writes the file.
    now:=given
    now.maps.base_color.texture={2,2}
    testing.expect(t,os.write_entire_file(path,bytes(t,&types,body,now,&now,&source))==nil)
    host.assets_scan(&assets)
    material_rebase(&s,body)
    file:asset.Asset
    if !testing.expect(t,asset_read(&s,"body.mat",&file)) {return}
    view,error:=asset.material_view(&file,&assets.types)
    testing.expect(t,error==.None && view.imported!=nil && view.imported^==now)
    testing.expect(t,view.info.roughness==0.9 && view.info.maps.base_color.texture==base.Asset_Id{2,2},"the change stays and the new texture arrives")
    asset.asset_close(&file)
    _,held:=asset.registry_memory_find(&assets.registry,"body.mat")
    testing.expect(t,held)
    imported=material_base(&s,body)
    testing.expect(t,imported!=nil && imported^==now,"the reference follows the file")

    // Going back to what the source gave leaves what the disk holds: nothing to write.
    testing.expect(t,material_write(&s,body,{kind=.Revert,paths={"roughness"}}))
    _,held=asset.registry_memory_find(&assets.registry,"body.mat")
    testing.expect(t,!held)
    testing.expect_value(t,host.assets_material_values(&assets,host.assets_material_row(&assets,body)).roughness,f32(0.5))
}

// Apply to material: what an entity changes of the material of a slot,
// values, a map and its overlays, goes into the file of the material; what it
// changes of another slot stays out.
@(test)
the_override_of_a_slot_of_an_entity_goes_into_its_material :: proc(t:^testing.T) {
    root:=base.test_folder(t,"material-apply")
    if root=="" {return}
    folder:=project.path(root,"assets",allocator=context.temp_allocator)
    os.make_directory_all(folder)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    wall:=base.Asset_Id{5,5}
    path:=fmt.tprintf("%s/wall.mat",folder)
    data,error:=asset.material_bytes(&types,{id=wall,info=asset.MATERIAL_DEFAULTS},context.temp_allocator)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect(t,os.write_entire_file(path,data)==nil)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    materials:Materials
    info:core.World_Info
    s:=Session{app=&app,materials=&materials,info=&info}

    names:=erender.MATERIAL_VALUE_FIELDS
    maps:=erender.MATERIAL_MAP_NAMES
    roughness:=base.name_hash(names[3].name)
    override:=erender.Material_Values{own_overlays=true,overlay_count=1}
    testing.expect(t,erender.material_value(&override,roughness,{0.7,0,0,0},1) && erender.material_value(&override,roughness,{0.2,0,0,0},0))
    testing.expect(t,erender.material_texture(&override,base.name_hash(maps[.Base_Color]),0,{7,7}))
    override.overlays[0]={id=1,material={9,9},blend=.Multiply,enabled=true}
    testing.expect(t,override.count==2 && erender.material_value_find(&override,0,roughness)!=erender.material_value_find(&override,1,roughness),"each slot keeps a value of its own")
    testing.expect(t,erender.material_values_slot(&override,1) && !erender.material_values_slot(&override,2))
    given,rest:=override_split(&override,0)
    testing.expect(t,given.count==1 && given.texture_count==1 && given.own_overlays,"the first slot takes the overlays")
    testing.expect(t,rest.count==1 && rest.slots[0]==1 && rest.texture_count==0 && !rest.own_overlays)
    testing.expect(t,material_write(&s,wall,{kind=.Override,override=&given}))

    file:asset.Asset
    if !testing.expect(t,asset_read(&s,"wall.mat",&file)) {return}
    defer asset.asset_close(&file)
    view,view_error:=asset.material_view(&file,&assets.types)
    if !testing.expect_value(t,view_error,asset.Error.None) {return}
    testing.expect_value(t,view.info.roughness,f32(0.2))
    testing.expect_value(t,view.info.maps.base_color.texture,base.Asset_Id{7,7})
    testing.expect(t,len(view.overlays)==1 && view.overlays[0].material==base.Asset_Id{9,9} && view.overlays[0].blend==.Multiply)
}

// Apply to material edits the material in memory, as one step with what the
// entity stops changing: undo gives both back, and only Save writes the file.
@(test)
applying_to_a_material_is_one_undo_step_in_memory_that_save_writes :: proc(t:^testing.T) {
    root:=base.test_folder(t,"material-apply-memory")
    if root=="" {return}
    folder:=project.path(root,"assets",allocator=context.temp_allocator)
    os.make_directory_all(folder)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    wall:=base.Asset_Id{6,6}
    path:=fmt.tprintf("%s/wall.mat",folder)
    testing.expect_value(t,asset.material_save(path,&types,{id=wall,info=asset.MATERIAL_DEFAULTS}),asset.Error.None)
    saved,_:=os.read_entire_file(path,context.temp_allocator)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}

    world:Apply_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    e:=core.create(&world.entities)
    mesh:=erender.Mesh_Renderer{shape=.Cube}
    mesh.materials[0]=wall
    look:=erender.MATERIAL_VALUES_DEFAULT
    look.color={1,0,0,1}
    testing.expect(t,erender.material_value(&look,"roughness",0.2) && erender.material_value(&look,"metallic",1,1))
    core.add(&world.ids,e,core.Id{value=base.Entity_Id(77)})
    core.add(&world.meshes,e,mesh)
    core.add(&world.looks,e,look)
    test_world_settle(&world)
    f:Test_Session
    test_session_open(&f,test_world_ref(&world))
    defer test_session_close(&f)
    materials:Materials
    s:=&f.s
    s.app,s.materials,s.assets_root=&app,&materials,folder
    w:=edited_world(s)

    roughness :: proc(t:^testing.T,s:^Session,assets:^host.Assets) -> f32 {
        file:asset.Asset
        if !testing.expect(t,asset_read(s,"wall.mat",&file)) {return -1}
        defer asset.asset_close(&file)
        view,error:=asset.material_view(&file,&assets.types)
        if !testing.expect_value(t,error,asset.Error.None) {return -1}
        return view.info.roughness
    }
    on_disk :: proc(path:string) -> string {
        data,_:=os.read_entire_file(path,context.temp_allocator)
        return string(data)
    }

    material,message:=material_apply(s,e,0)
    history.edits_commit(&f.edits,w,&f.selection)
    testing.expect(t,material==wall && message=="",message)
    testing.expect_value(t,len(f.edits.steps),1)
    testing.expect_value(t,roughness(t,s,&assets),f32(0.2))
    testing.expect(t,asset_unsaved(s,wall) && on_disk(path)==string(saved),"the material changed in memory: its file is as it was")
    left,_:=core.get(core.read(&world.looks),e)
    testing.expect(t,left.color==[4]f32{1,0,0,1} && left.count==1 && left.slots[0]==1,"the entity keeps its color and what it changes of another slot")

    testing.expect(t,history.undo(&f.edits,w,&f.selection))
    testing.expect_value(t,roughness(t,s,&assets),asset.MATERIAL_DEFAULTS.roughness)
    back,_:=core.get(core.read(&world.looks),e)
    testing.expect(t,back==look,"undo gives the entity its values")
    testing.expect(t,!asset_unsaved(s,wall),"and the material what it had")

    testing.expect(t,history.redo(&f.edits,w,&f.selection))
    testing.expect(t,asset_unsaved(s,wall) && on_disk(path)==string(saved))
    written,ok:=assets_save(s,{"wall.mat"})
    testing.expect(t,ok && written==1 && !asset_unsaved(s,wall) && on_disk(path)!=string(saved),"Save writes the file")
    testing.expect_value(t,roughness(t,s,&assets),f32(0.2))
}

// material.set reaches what a material holds by name, in one step in memory:
// its maps and the layers drawn over it with its values, and it says which
// parameter its program does not have.
@(test)
material_set_gives_a_material_its_values_textures_and_overlays_in_one_step :: proc(t:^testing.T) {
    f:Files_Test
    if !files_test_open(t,&f,"material-set") {return}
    defer files_test_close(&f)
    folder:=project.path(f.root,"assets",allocator=context.temp_allocator)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    wall,moss,grain:=base.Asset_Id{6,6},base.Asset_Id{7,7},base.Asset_Id{8,8}
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/wall.mat",folder),&types,{id=wall,info=asset.MATERIAL_DEFAULTS}),asset.Error.None)
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/moss.mat",folder),&types,{id=moss,info=asset.MATERIAL_DEFAULTS}),asset.Error.None)
    pixels:=[4]u8{255,255,255,255}
    testing.expect_value(t,asset.texture_save(fmt.tprintf("%s/grain.tex",folder),&types,{id=grain,width=1,height=1,format=.RGBA8,flags={.Srgb},mips={pixels[:]}}),asset.Error.None)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    materials:Materials
    s:=&f.s
    s.app,s.materials,s.assets_root,s.has_project=&app,&materials,folder,true
    state:=new(Api_State);defer free(state)
    state.poll_temp=context.temp_allocator
    if !testing.expect_value(t,api.server_init(&state.server,{port=0,max_methods=16,max_connections=1,max_request=64*1024,max_response=1<<20,scratch=4<<20}),api.Init_Error.None) {return}
    defer api.server_destroy(&state.server)
    materials_api_register(s,state)
    if !testing.expectf(t,state.refused==0,"%s",state.refusal) {return}
    call :: proc(t:^testing.T,state:^Api_State,method,params:string) -> (reply:json.Object,failure:api.Error,ok:bool) {
        m:=api.method_find(&state.server,method)
        if !testing.expectf(t,m!=nil,"%s is registered",method) {return}
        out:=make([]u8,1<<20,context.temp_allocator)
        w:serial.Writer
        serial.writer_init_fixed(&w,out)
        failure,ok=api.method_execute(&state.server,m,params,&w)
        if !ok {return}
        text:=string(serial.writer_bytes(&w))
        testing.expect_value(t,api.result_mismatch(m.result_id,text),"")
        value,_:=json.parse_string(text,allocator=context.temp_allocator)
        reply,_=value.(json.Object)
        return
    }

    steps:=len(f.edits.steps)
    reply,failure,ok:=call(t,state,"material.set",`{"material":"wall.mat","values":{"roughness":0.25},"textures":{"maps.base_color":"grain.tex"},"overlays":[{"material":"moss.mat","blend":"Multiply"}]}`)
    files_test_commit(&f)
    if !testing.expectf(t,ok,"%s %s",failure.message,failure.data) {return}
    testing.expect_value(t,len(f.edits.steps),steps+1)
    overlays,_:=reply["overlays"].(json.Array)
    if testing.expect_value(t,len(overlays),1) {
        layer,_:=overlays[0].(json.Object)
        testing.expect(t,layer["blend"].(json.String)=="Multiply" && layer["enabled"].(json.Boolean))
    }
    file:asset.Asset
    if !testing.expect(t,asset_read(s,"wall.mat",&file)) {return}
    view,view_error:=asset.material_view(&file,&assets.types)
    if testing.expect_value(t,view_error,asset.Error.None) {
        testing.expect_value(t,view.info.roughness,f32(0.25))
        testing.expect_value(t,view.info.maps.base_color.texture,grain)
        testing.expect(t,len(view.overlays)==1 && view.overlays[0].material==moss && view.overlays[0].blend==.Multiply)
    }
    asset.asset_close(&file)
    testing.expect(t,asset_unsaved(s,wall),"it changed in memory")

    // What a call does not give stays.
    reply,failure,ok=call(t,state,"material.set",`{"material":"wall.mat","values":{"metallic":1}}`)
    files_test_commit(&f)
    if !testing.expectf(t,ok,"%s %s",failure.message,failure.data) {return}
    overlays,_=reply["overlays"].(json.Array)
    testing.expect_value(t,len(overlays),1)

    // The standard model has no parameters, and a layer is another material.
    _,failure,ok=call(t,state,"material.set",`{"material":"wall.mat","parameters":{"glow":2}}`)
    testing.expect(t,!ok && strings.contains(failure.message,"glow is not a number of the Surface program"),failure.message)
    _,failure,ok=call(t,state,"material.set",`{"material":"wall.mat","overlays":[{"material":"wall.mat"}]}`)
    testing.expect(t,!ok && strings.contains(failure.message,"a material other than the one it is drawn over"),failure.message)
}
