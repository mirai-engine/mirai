package author

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The commands mirai ui and mirai scene on a copy of the game template, as
// the author program of the engine runs them. They need MIRAI_ROOT, which
// `mirai test` sets, to find the plugins of the template.

@(private="file")
Run_Result :: struct {code:int,out,err:string}

@(private="file")
author_run :: proc(args:..string) -> Run_Result {
    output,errors:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
    code:=command(args,strings.to_writer(&output),strings.to_writer(&errors))
    return {code,strings.to_string(output),strings.to_string(errors)}
}

// A copy of the game template in a folder of its own, and the engine it is of.
@(private="file")
template_copy :: proc(t:^testing.T,name:string) -> (root,engine:string,ok:bool) {
    found:bool
    if engine,found=os.lookup_env("MIRAI_ROOT",context.temp_allocator);!found {
        log.warn("MIRAI_ROOT is not set: the commands of mirai ui and mirai scene were not run. Use `mirai test cook/author`.")
        return
    }
    root=base.test_folder(t,fmt.tprintf("author-%s",name))
    if root=="" {return}
    if !testing.expect(t,os.copy_directory_all(root,project.path(engine,"templates/game",allocator=context.temp_allocator))==nil,"the template is copied") {return}
    return root,engine,true
}

@(private="file") Game_Status :: struct {health:f32,hits:i32,message:[32]u8 `mirai:"text"`}

// The world of the game of the tests: where a recipe is run.
@(private="file")
Game_World :: struct {
    using world:core.Test_World,
    transforms:core.Table(core.Transform),
    hidden:core.Table(erender.Hidden),
    disabled:core.Table(core.Disabled),
    meshes:core.Table(erender.Mesh_Renderer),
    tints:core.Table(erender.Tint),
    point_lights:core.Table(erender.Point_Light),
    statuses:core.Table(Game_Status) `mirai:"game,name=Status"`,
    names:core.Table(core.Name),
    parents:core.Table(core.Parent),
    hierarchy:core.Hierarchy,
}

@(private="file")
file_bytes :: proc(p:^Project,path:string) -> []u8 {
    bytes,_:=os.read_entire_file(project.path(p.assets_root,path,allocator=context.temp_allocator),context.temp_allocator)
    return bytes
}

@(test)
the_document_of_each_interface_of_the_template_writes_it_back_as_it_is :: proc(t:^testing.T) {
    root,engine,copied:=template_copy(t,"ui")
    if !copied {return}
    p:Project
    if problem:=project_open(&p,root,engine,false);!testing.expect(t,problem=="",problem) {return}
    defer project_close(&p)
    paths:=make([dynamic]string,context.temp_allocator)
    for &file in p.registry.files {
        if file.kind==asset.KIND_UI && !strings.has_prefix(file.path,"plugins/") {append(&paths,strings.clone(file.path,context.temp_allocator))}
    }
    if !testing.expect(t,len(paths)>0,"the template has interfaces") {return}
    for path in paths {
        out:serial.Writer
        serial.writer_init(&out,0,context.temp_allocator)
        if problem:=ui_read(&p,path,&out);!testing.expectf(t,problem=="","%s: %s",path,problem) {continue}
        document:=serial.json_pretty(string(serial.writer_bytes(&out)),context.temp_allocator)
        written,problem:=ui_write(&p,path,document)
        if !testing.expectf(t,problem=="","%s: %s",path,problem) {continue}
        testing.expectf(t,written.made==0 && written.removed==0,"%s: its own document makes or removes nodes",path)
        testing.expectf(t,written.same,"%s: its own document changes the bytes of its file",path)
        again,_:=ui_write(&p,path,document)
        testing.expectf(t,again.same,"%s: written twice, the second changes nothing",path)
        serial.writer_init(&out,0,context.temp_allocator)
        testing.expect_value(t,ui_read(&p,path,&out),"")
        testing.expectf(t,serial.json_pretty(string(serial.writer_bytes(&out)),context.temp_allocator)==document,"%s: read again, its document is another",path)
    }
}

@(test)
a_path_the_game_lacks_is_refused_with_no_editor_as_ui_write_refuses_it :: proc(t:^testing.T) {
    root,engine,copied:=template_copy(t,"paths")
    if !copied {return}
    info,described:=core.test_info(t,Game_World,erender.test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    p:Project
    if problem:=project_open(&p,root,engine,false);!testing.expect(t,problem=="",problem) {return}
    defer project_close(&p)
    p.info=&info
    out:serial.Writer
    serial.writer_init(&out,0,context.temp_allocator)
    if problem:=ui_read(&p,"hud/hud.ui",&out);!testing.expect(t,problem=="",problem) {return}
    document:=string(serial.writer_bytes(&out))
    if !testing.expect(t,strings.contains(document,`"Status.message"`),"the hud binds the message of Status") {return}
    before:=slice.clone(file_bytes(&p,"hud/hud.ui"),context.temp_allocator)
    // The same document names a field the game has: written. One it lacks: refused, as ui.write says it.
    _,fine:=ui_write(&p,"hud/hud.ui",document)
    testing.expect(t,fine=="",fine)
    before=slice.clone(file_bytes(&p,"hud/hud.ui"),context.temp_allocator)
    wrong,_:=strings.replace_all(document,`"Status.message"`,`"Status.mesage"`,context.temp_allocator)
    _,problem:=ui_write(&p,"hud/hud.ui",wrong)
    testing.expect(t,strings.contains(problem,"bind_text 'Status.mesage': Game_Status has no field 'mesage'; it has health, hits, message"),problem)
    testing.expect(t,strings.contains(problem,"Nothing changed. A path names a component or a storage of the game"),problem)
    testing.expect(t,slice.equal(file_bytes(&p,"hud/hud.ui"),before),"a refused document leaves the file as it was")
}

@(test)
the_commands_read_write_and_check_the_documents_kept_under_source :: proc(t:^testing.T) {
    root,engine,copied:=template_copy(t,"command")
    if !copied {return}
    base_args:=[]string{"--project",root,"--engine",engine}
    run :: proc(base_args:[]string,args:..string) -> Run_Result {
        all:=make([dynamic]string,context.temp_allocator)
        append(&all,..base_args)
        append(&all,..args)
        return author_run(..all[:])
    }
    misuse:=run(base_args,"ui","erase")
    testing.expect(t,misuse.code==2 && strings.contains(misuse.err,"read, write and check"),misuse.err)
    read:=run(base_args,"ui","read","--sources")
    testing.expectf(t,read.code==0 && strings.contains(read.out,"hud/hud.ui: read to "),"%d %s%s",read.code,read.out,read.err)
    hud:=project.path(root,SOURCE_FOLDER,"hud/hud.ui.json",allocator=context.temp_allocator)
    text,error:=os.read_entire_file(hud,context.temp_allocator)
    if !testing.expect(t,error==nil && strings.has_prefix(string(text),"{\n"),"the document is a file of text under source/") {return}
    // A project that was never built has no types to check against: nothing
    // is written or checked, of an interface or of a scene, and the failure
    // says what builds them.
    source:=project.path(root,SOURCE_FOLDER,allocator=context.temp_allocator)
    before:=file_bytes_at(root,"assets/hud/hud.ui")
    for args in ([][]string{{"ui","write",source},{"ui","check"},{"scene","read","arena/main.scene"},{"scene","write",source},{"scene","check"}}) {
        refused:=run(base_args,..args)
        testing.expectf(t,refused.code==1 && refused.out=="" && strings.contains(refused.err,"mirai build editor <project> --dev"),"%v: %d %s%s",args,refused.code,refused.out,refused.err)
    }
    testing.expect(t,slice.equal(file_bytes_at(root,"assets/hud/hud.ui"),before))

    // With the types of the game: the folder of documents becomes the assets
    // in one command, each named by its file.
    info,described:=core.test_info(t,Game_World,erender.test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    p:Project
    if problem:=project_open(&p,root,engine,false);!testing.expect(t,problem=="",problem) {return}
    defer project_close(&p)
    p.info=&info
    on :: proc(p:^Project,kind:Document_Kind,verb:string,args:..string) -> Run_Result {
        output,errors:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
        code:=project_run(p,kind,verb,args,strings.to_writer(&output),strings.to_writer(&errors))
        return {code,strings.to_string(output),strings.to_string(errors)}
    }
    written:=on(&p,.Ui,"write",project.path(source,"hud",allocator=context.temp_allocator),project.path(source,"menu/theme.ui.json",allocator=context.temp_allocator))
    testing.expectf(t,written.code==0 && strings.contains(written.out,"hud/hud.ui: ") && strings.contains(written.out,"menu/theme.ui: "),"%d %s%s",written.code,written.out,written.err)
    // The shell binds what the game of this test does not declare: refused, and the exit code says so.
    unbound:=on(&p,.Ui,"write",source)
    testing.expectf(t,unbound.code==1 && strings.contains(unbound.err,"mirai ui write: menu/shell.ui: ") && strings.contains(unbound.err,"the game has no component or storage 'Shell'"),"%d %s",unbound.code,unbound.err)
    // A new document makes its asset, and one that does not read is refused naming where.
    fresh:=project.path(root,SOURCE_FOLDER,"hud/score.ui.json",allocator=context.temp_allocator)
    testing.expect(t,os.write_entire_file(fresh,`{"use":["menu/theme.ui"],"nodes":[{"name":"score","kind":"Text","style":"chip_value","text":"0"}]}`)==nil)
    made:=on(&p,.Ui,"write",fresh)
    testing.expectf(t,made.code==0 && strings.contains(made.out,"hud/score.ui: made"),"%d %s%s",made.code,made.out,made.err)
    testing.expect(t,os.is_file(project.path(root,"assets/hud/score.ui",allocator=context.temp_allocator)))
    testing.expect(t,os.write_entire_file(fresh,`{"nodes":[{"name":"score","kind":"Text","colour":"red"}]}`)==nil)
    refused:=on(&p,.Ui,"write",fresh)
    testing.expectf(t,refused.code==1 && strings.contains(refused.err,"mirai ui write: hud/score.ui: nodes[0]") && strings.contains(refused.err,"colour"),"%d %s%s",refused.code,refused.out,refused.err)
    // A check reports what the game would not load and exits non-zero.
    testing.expect(t,os.remove(project.path(root,"assets/menu/theme.ui",allocator=context.temp_allocator))==nil)
    testing.expect_value(t,asset.registry_refresh(&p.registry,{"menu/theme.ui"}),asset.Error.None)
    broken:=on(&p,.Ui,"check","hud/hud.ui")
    testing.expectf(t,broken.code==1 && strings.contains(broken.out,"does not load") && strings.contains(broken.err,"problems"),"%d %s%s",broken.code,broken.out,broken.err)
}

@(private="file")
file_bytes_at :: proc(root,path:string) -> []u8 {
    bytes,_:=os.read_entire_file(project.path(root,path,allocator=context.temp_allocator),context.temp_allocator)
    return bytes
}

// A widget written with a parameter that goes elsewhere takes the files that
// use it along: what they gave by its name is given where it goes now.
@(test)
writing_a_widget_follows_its_parameters_in_the_files_that_use_it :: proc(t:^testing.T) {
    root,engine,copied:=template_copy(t,"follow")
    if !copied {return}
    p:Project
    if problem:=project_open(&p,root,engine,false);!testing.expect(t,problem=="",problem) {return}
    defer project_close(&p)
    stat :: proc(node:string) -> string {
        return strings.concatenate({`{"params":{"label":"`,node,`.text"},"nodes":[{"name":"stat","kind":"Box","children":[{"name":"name","kind":"Text"},{"name":"amount","kind":"Text"}]}]}`},context.temp_allocator)
    }
    _,problem:=ui_write(&p,"kit/stat.ui",stat("name"))
    if !testing.expect(t,problem=="",problem) {return}
    _,problem=ui_write(&p,"kit/screen.ui",`{"use":["kit/stat.ui"],"nodes":[{"name":"root","kind":"Box","children":[{"name":"hits","kind":"stat","label":"Hits"}]}]}`)
    if !testing.expect(t,problem=="",problem) {return}
    before:=slice.clone(file_bytes(&p,"kit/screen.ui"),context.temp_allocator)
    moved,why:=ui_write(&p,"kit/stat.ui",stat("amount"))
    testing.expect(t,why=="" && moved.followed==1,fmt.tprintf("%s %v",why,moved))
    testing.expect(t,!slice.equal(file_bytes(&p,"kit/screen.ui"),before),"the file that uses the widget was written again")
    r:Records
    record,_:=asset.registry_find_path(&p.registry,"kit/screen.ui")
    if !testing.expect(t,records_read(p.assets,record.id,&r,context.temp_allocator)) {return}
    if !testing.expect_value(t,len(r.overrides),1) {return}
    testing.expect_value(t,serial.text_field(r.overrides[0].node[:]),"amount")
    testing.expect_value(t,records_text(&r,r.overrides[0].values.text),"Hits")
    out:serial.Writer
    serial.writer_init(&out,0,context.temp_allocator)
    testing.expect_value(t,ui_read(&p,"kit/screen.ui",&out),"")
    testing.expect(t,strings.contains(string(serial.writer_bytes(&out)),`"label":"Hits"`),string(serial.writer_bytes(&out)))
}

@(test)
the_document_of_a_scene_writes_it_back_and_declares_what_its_file_has :: proc(t:^testing.T) {
    root,engine,copied:=template_copy(t,"scene")
    if !copied {return}
    info,described:=core.test_info(t,Game_World,erender.test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    p:Project
    if problem:=project_open(&p,root,engine,false);!testing.expect(t,problem=="",problem) {return}
    defer project_close(&p)
    p.info=&info
    for path in ([]string{"arena/main.scene","player/Player.scene"}) {
        before:=slice.clone(file_bytes(&p,path),context.temp_allocator)
        out:serial.Writer
        serial.writer_init(&out,0,context.temp_allocator)
        if problem:=scene_read(&p,path,&out);!testing.expectf(t,problem=="","%s: %s",path,problem) {continue}
        written,problem:=scene_write(&p,path,string(serial.writer_bytes(&out)))
        testing.expectf(t,problem=="" && written.same,"%s: %s",path,problem)
        testing.expectf(t,slice.equal(file_bytes(&p,path),before),"%s: its own document changes its bytes",path)
        testing.expectf(t,scene_verify(&p,path)=="","%s: %s",path,scene_verify(&p,path))
    }
    // The floor grows, a lamp with a bulb is made, and what the document leaves out goes;
    // the components this game does not know stay with the entities it kept.
    kept:asset.Scene
    file:=project.path(p.assets_root,"arena/main.scene",allocator=context.temp_allocator)
    if !testing.expect_value(t,asset.scene_load(&kept,&p.types,file,context.temp_allocator),asset.Error.None) {return}
    floor:=asset.scene_ids(&kept)[2]
    count:=asset.scene_entity_count(&kept)
    document:=fmt.tprintf(`{{"entities":[{{"id":"0x%016x","name":"Ground","scale":[30,0.1,30],"components":{{"Mesh_Renderer":{{}},"Tint":{{"color":[1,0,0,1]}}}}}},{{"name":"Lamp","position":[2,3,0],"components":{{"Point_Light":{{"intensity":7}}}},"off":["Point_Light"],"children":[{{"name":"Bulb","visible":false}}]}}]}}`,u64(floor))
    written,problem:=scene_write(&p,"arena/main.scene",document)
    if !testing.expect(t,problem=="",problem) {return}
    testing.expect(t,written.made==2 && written.removed==count-1 && !written.same,fmt.tprintf("%v",written))
    after:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&after,&p.types,file,context.temp_allocator),asset.Error.None) {return}
    testing.expect_value(t,asset.scene_entity_count(&after),3)
    row,found:=asset.scene_entity_find(&after,floor)
    testing.expect(t,found && asset.scene_entity(&after,row).name=="Ground")
    place,_:=asset.scene_get(&after,floor,"Transform",core.Transform)
    testing.expect_value(t,place.scale,[3]f32{30,0.1,30})
    collider,has_table:=asset.scene_component(&after,"Collider")
    _,has_collider:=asset.scene_component_get(&after,collider,floor)
    testing.expect(t,has_table && has_collider,"a component the game of this build does not know stays")
    out:serial.Writer
    serial.writer_init(&out,0,context.temp_allocator)
    testing.expect_value(t,scene_read(&p,"arena/main.scene",&out),"")
    text:=string(serial.writer_bytes(&out))
    for part in ([]string{`"name":"Ground"`,`"Point_Light":{"intensity": 7}`,`"off":["Point_Light"]`,`"name":"Bulb","visible":false`}) {
        testing.expectf(t,strings.contains(text,part),"the document has %s: %s",part,text)
    }
    // What a document cannot declare says where and what does.
    scene_file,_:=asset.registry_find_path(&p.registry,"arena/main.scene")
    scene_id:[base.ASSET_ID_TEXT]u8
    cases:=[]struct{document,message:string}{
        {fmt.tprintf(`{{"entities":[{{"name":"x","prefab":"%s"}}]}}`,base.asset_id_format(scene_file.id,scene_id[:])),"arena/main.scene has no single entity at its top to place; give it one, with the rest under it, or hang it whole from a Scene_Reference"},
        {`{"entities":[{"name":"x","components":{"Nope":{}}}]}`,"entities[0].components.Nope: the game of this build has no component 'Nope'"},
        {`{"entities":[{"name":"x","preset":"cubes"}]}`,"entities[0].preset: "},
        {`{"entities":[{"name":"x","prefab":"player/Nobody.scene"}]}`,"entities[0].prefab: "},
        {`{"entities":[{"name":"x","prefab":"arena/main.scene"}]}`,"entities[0].prefab: arena/main.scene has no single entity at its top to place"},
        {`{"entities":[{"name":"x","prefab":{"asset":"player/Player.scene","size":2}}]}`,"entities[0].prefab has no 'size'"},
        {`{"entities":[{"id":"0x00000000000000ff"}]}`,"entities[0].id: 0x00000000000000ff is no entity of the file"},
        {`{"entities":[{"name":"x","components":{"Tint":{"colour":[1,1,1,1]}}}]}`,"entities[0].components.Tint"},
        {`{"entities":[{"name":"x","sizes":3}]}`,"entities[0] has no 'sizes'; an entity has id, name"},
        {`{"entities":[{"name":"x","components":{"Prefab_Instance":{}}}]}`,"entities[0].components.Prefab_Instance: Prefab_Instance is what links an entity to its prefab"},
    }
    held:=slice.clone(file_bytes(&p,"arena/main.scene"),context.temp_allocator)
    for c in cases {
        _,refused:=scene_write(&p,"arena/main.scene",c.document)
        testing.expectf(t,strings.contains(refused,c.message),"%s gave '%s'",c.document,refused)
    }
    testing.expect(t,slice.equal(file_bytes(&p,"arena/main.scene"),held),"a refused document leaves the file as it was")
    // A file that does not exist is made, with the ids its document gives.
    made,fresh:=scene_write(&p,"arena/annex.scene",`{"entities":[{"id":"0x0000000000000042","name":"Root","children":[{"name":"Leaf"}]}]}`)
    testing.expect(t,fresh=="" && made.fresh && made.made==2,fresh)
    annex:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&annex,&p.types,project.path(p.assets_root,"arena/annex.scene",allocator=context.temp_allocator),context.temp_allocator),asset.Error.None) {return}
    _,has_root:=asset.scene_entity_find(&annex,0x42)
    testing.expect(t,has_root && asset.scene_entity_count(&annex)==2)
}

// A preset and the card of a plugin stand for the components their recipes
// give, and a new entity with prefab is a linked instance of that prefab.
@(test)
a_scene_document_makes_entities_from_presets_cards_and_prefabs :: proc(t:^testing.T) {
    root,engine,copied:=template_copy(t,"recipes")
    if !copied {return}
    info,described:=core.test_info(t,Game_World,erender.test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    p:Project
    if problem:=project_open(&p,root,engine,false);!testing.expect(t,problem=="",problem) {return}
    defer project_close(&p)
    p.info=&info
    labels:=[]string{"Scoreboard"}
    scales:=[][3]f32{{2,2,2}}
    p.plugins={labels=labels,scales=scales,make=proc(user:rawptr,index:int,w:core.World_Ref,e:core.Entity) {
        if statuses:=core.world_table_of(w,Game_Status);statuses!=nil {core.add(statuses,e,Game_Status{hits=3})}
    }}
    written,problem:=scene_write(&p,"arena/yard.scene",`{"entities":[
        {"name":"Lamp","preset":"point_light","position":[0,3,0],"components":{"Point_Light":{"intensity":7}}},
        {"name":"Box","preset":"cube","scale":[1,2,1]},
        {"name":"Board","preset":"scoreboard"},
        {"name":"Hero","prefab":"player/Player.scene","position":[1,2,3]}]}`)
    if !testing.expect(t,problem=="",problem) {return}
    yard:asset.Scene
    file:=project.path(p.assets_root,"arena/yard.scene",allocator=context.temp_allocator)
    if !testing.expect_value(t,asset.scene_load(&yard,&p.types,file,context.temp_allocator),asset.Error.None) {return}
    named :: proc(scene:^asset.Scene,name:string) -> base.Entity_Id {
        for id,row in asset.scene_ids(scene) {if asset.scene_entity(scene,row).name==name {return id}}
        return 0
    }
    lamp,box,board,hero:=named(&yard,"Lamp"),named(&yard,"Box"),named(&yard,"Board"),named(&yard,"Hero")
    if !testing.expect(t,lamp!=0 && box!=0 && board!=0 && hero!=0,"the four entities are in the file") {return}
    light,has_light:=asset.scene_get(&yard,lamp,"Point_Light",erender.Point_Light)
    testing.expect(t,has_light && light.intensity==7 && light.range==erender.POINT_LIGHT_DEFAULT.range,"the light is the one of the preset with what the document gives")
    mesh,has_mesh:=asset.scene_get(&yard,box,"Mesh_Renderer",erender.Mesh_Renderer)
    testing.expect(t,has_mesh && mesh.shape==.Cube)
    status,has_status:=asset.scene_get(&yard,board,"Status",Game_Status)
    placed,_:=asset.scene_get(&yard,board,"Transform",core.Transform)
    testing.expect(t,has_status && status.hits==3 && placed.scale==[3]f32{2,2,2},"the card of a plugin gives its components and its scale")
    // The instance: its root where the document says, linked to its prefab, with the members the prefab has.
    prefab:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&prefab,&p.types,project.path(p.assets_root,"player/Player.scene",allocator=context.temp_allocator),context.temp_allocator),asset.Error.None) {return}
    testing.expect_value(t,written.made,3+asset.scene_entity_count(&prefab))
    roots:=asset.scene_instance_roots(&yard)
    if !testing.expect_value(t,len(roots),1) {return}
    linked,_:=asset.scene_instance(&yard,hero)
    members,_:=asset.scene_instance_members(&yard,hero)
    testing.expect(t,roots[0]==hero && linked.prefab==prefab.doc.id)
    testing.expect_value(t,len(members),asset.scene_entity_count(&prefab))
    where_,_:=asset.scene_get(&yard,hero,"Transform",core.Transform)
    testing.expect_value(t,where_.position,[3]f32{1,2,3})
    // The document that placed it, written again, changes nothing: what it leaves out of the instance is what its prefab gives.
    same,same_why:=scene_write(&p,"arena/yard.scene",`{"entities":[
        {"name":"Lamp","preset":"point_light","position":[0,3,0],"components":{"Point_Light":{"intensity":7}}},
        {"name":"Box","preset":"cube","scale":[1,2,1]},
        {"name":"Board","preset":"scoreboard"},
        {"name":"Hero","prefab":"player/Player.scene","position":[1,2,3]}]}`)
    testing.expect(t,same_why=="" && same.same,fmt.tprintf("%s %v",same_why,same))
    // Its document reads it back and writes it as it is; moving the instance by its id keeps its link.
    testing.expect_value(t,scene_verify(&p,"arena/yard.scene"),"")
    out:serial.Writer
    serial.writer_init(&out,0,context.temp_allocator)
    testing.expect_value(t,scene_read(&p,"arena/yard.scene",&out),"")
    text:=string(serial.writer_bytes(&out))
    testing.expect(t,strings.contains(text,`"root":true`),text)
    testing.expect(t,!strings.contains(text,asset.COMPONENT_INSTANCE) && !strings.contains(text,asset.COMPONENT_MEMBER),"a document names the prefab of an instance, not the components that hold it")
    moved,_:=strings.replace_all(text,`"position":[1,2,3]`,`"position":[4,2,3]`,context.temp_allocator)
    again,why:=scene_write(&p,"arena/yard.scene",moved)
    testing.expect(t,why=="" && again.made==0 && again.removed==0 && !again.same,fmt.tprintf("%s %v",why,again))
    after:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&after,&p.types,file,context.temp_allocator),asset.Error.None) {return}
    after_members,_:=asset.scene_instance_members(&after,hero)
    testing.expect(t,len(asset.scene_instance_roots(&after))==1 && len(after_members)==len(members))

    // What the document says of a member, however deep, by its name, the instance holds on its own.
    _,gate_why:=scene_write(&p,"arena/Gate.scene",`{"entities":[{"name":"Gate","children":[{"name":"Frame","children":[{"name":"Lamp","preset":"point_light"}]}]}]}`)
    if !testing.expect(t,gate_why=="",gate_why) {return}
    court:=`{"entities":[{"name":"North","prefab":"arena/Gate.scene","children":[{"name":"Frame","children":[{"name":"Lamp","position":[0,2,0],"components":{"Point_Light":{"intensity":9}}}]}]}]}`
    north,north_why:=scene_write(&p,"arena/court.scene",court)
    if !testing.expect(t,north_why=="" && north.made==3,fmt.tprintf("%s %v",north_why,north)) {return}
    held:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&held,&p.types,project.path(p.assets_root,"arena/court.scene",allocator=context.temp_allocator),context.temp_allocator),asset.Error.None) {return}
    lit:=named(&held,"Lamp")
    bulb,_:=asset.scene_get(&held,lit,"Point_Light",erender.Point_Light)
    testing.expect(t,asset.scene_entity_instance(&held,lit)!=0 && bulb.intensity==9,"the lamp is the member of the instance, with what the document says of it")
    testing.expect(t,asset.scene_overridden(&held,lit,base.name_hash("Point_Light"),"intensity"))
    again,why=scene_write(&p,"arena/court.scene",court)
    testing.expect(t,why=="" && again.same,fmt.tprintf("%s %v",why,again))

    // A prefab is not placed in a file it holds, itself or through the prefabs it places.
    _,wall_why:=scene_write(&p,"arena/Wall.scene",`{"entities":[{"name":"Wall","children":[{"name":"Door","prefab":"arena/Gate.scene"}]}]}`)
    testing.expect(t,wall_why=="",wall_why)
    gate:=slice.clone(file_bytes(&p,"arena/Gate.scene"),context.temp_allocator)
    for inner in ([]string{"arena/Gate.scene","arena/Wall.scene"}) {
        _,refused:=scene_write(&p,"arena/Gate.scene",fmt.tprintf(`{{"entities":[{{"name":"Gate","children":[{{"name":"In","prefab":%q}}]}}]}}`,inner))
        testing.expectf(t,strings.contains(refused,"entities[0].children[0].prefab: ") && strings.contains(refused,"holds the file it would be placed in"),"%s gave '%s'",inner,refused)
    }
    testing.expect(t,slice.equal(file_bytes(&p,"arena/Gate.scene"),gate),"a refused document leaves the file as it was")
}


// The bytes a document read from the .ui id and written back gives; ok false
// when it does not read or write.
@(private="file")
ui_round_trip :: proc(p:^Project,id:base.Asset_Id) -> (bytes:[]u8,why:string,ok:bool) {
    r:Records
    if !records_read(p.assets,id,&r,context.temp_allocator) {return nil,"it does not read",false}
    reading:=Reading{allocator=context.temp_allocator,assets=registry_assets(&p.registry)}
    args:=Tree_Args{reading=&reading,types=&p.types,registry=&p.registry,assets=p.assets,asset=id}
    libs:=doc_libs(&args,&r)
    out:serial.Writer
    serial.writer_init(&out,0,context.temp_allocator)
    document_write(&out,&p.types,&r,-1,libs[:],p.assets)
    text:=string(serial.writer_bytes(&out))
    reading.raw=text
    again:Records
    if !records_read(p.assets,id,&again,context.temp_allocator) {return nil,"it does not read",false}
    if _,_,applied:=document_apply(&args,&again,-1,text);!applied {return nil,reading.problem,false}
    written,_,loads:=document_bytes(&args,id,&again)
    if !loads {return nil,reading.problem,false}
    return written,"",true
}

// Every interface, scene and prefab the engine tracks, in the game template
// and in the demo: its document written back is the file it was read from,
// byte by byte, so text kept under source/ and the assets say the same.
@(test)
the_documents_of_the_tracked_assets_write_back_the_files_they_were_read_from :: proc(t:^testing.T) {
    engine,found:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    if !found {
        log.warn("MIRAI_ROOT is not set: the tracked assets were not read. Use `mirai test cook/author`.")
        return
    }
    info,described:=core.test_info(t,Game_World,erender.test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    for folder in ([]string{"templates/game","demo"}) {
        p:Project
        if problem:=project_open(&p,project.path(engine,folder,allocator=context.temp_allocator),engine,false);!testing.expectf(t,problem=="","%s: %s",folder,problem) {continue}
        defer project_close(&p)
        p.info=&info
        files:=0
        for &file in p.registry.files {
            if file.state!=.Asset || strings.has_prefix(file.path,"plugins/") || strings.has_prefix(file.path,".") {continue}
            path:=strings.clone(file.path,context.temp_allocator)
            switch file.kind {
            case asset.KIND_UI:
                files+=1
                written,why,ok:=ui_round_trip(&p,file.id)
                if !testing.expectf(t,ok,"%s/%s: %s",folder,path,why) {continue}
                testing.expectf(t,slice.equal(written,file_bytes(&p,path)),"%s/%s: its document writes other bytes: mirai ui write saves it again",folder,path)
            case asset.KIND_SCENE:
                files+=1
                problem:=scene_verify(&p,path)
                testing.expectf(t,problem=="","%s/%s: %s",folder,path,problem)
            }
        }
        testing.expectf(t,files>0,"%s has interfaces and scenes",folder)
    }
}
