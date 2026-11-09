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
    directory,_:=os.temp_directory(context.temp_allocator)
    root=project.path_absolute(fmt.tprintf("%s/mirai-author-%d-%s",directory,os.get_pid(),name),context.temp_allocator)
    os.remove_all(root)
    if !testing.expect(t,os.copy_directory_all(root,project.path(engine,"templates/game",allocator=context.temp_allocator))==nil,"the template is copied") {return}
    return root,engine,true
}

@(private="file") Game_Status :: struct {health:f32,hits:i32,message:[32]u8 `mirai:"text"`}

// The types of a game with the Status the interfaces of the template bind
// and the components of the engine its scene has.
@(private="file")
game_info :: proc(info:^core.World_Info) {
    tables:=make([]core.Table_Info,9,context.temp_allocator)
    tables[0]={name="Transform",type=core.Transform,info=type_info_of(core.Transform),place=.World}
    tables[1]={name="Hidden",type=erender.Hidden,info=type_info_of(erender.Hidden),place=.World}
    tables[2]={name="Disabled",type=core.Disabled,info=type_info_of(core.Disabled),place=.World}
    tables[3]={name="Mesh_Renderer",type=erender.Mesh_Renderer,info=type_info_of(erender.Mesh_Renderer),place=.World}
    tables[4]={name="Tint",type=erender.Tint,info=type_info_of(erender.Tint),place=.World}
    tables[5]={name="Point_Light",type=erender.Point_Light,info=type_info_of(erender.Point_Light),place=.World}
    tables[6]={name="Status",library="game",type=Game_Status,info=type_info_of(Game_Status),place=.World,game=true}
    tables[7]={name="Name",type=core.Name,info=type_info_of(core.Name),place=.World}
    tables[8]={name="Parent",type=core.Parent,info=type_info_of(core.Parent),place=.World}
    info^={tables=tables}
    core.world_info_index(info,context.temp_allocator)
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
    defer os.remove_all(root)
    p:Project
    if problem:=project_open(&p,root,engine,false);!testing.expect(t,problem=="",problem) {return}
    defer project_close(&p)
    paths:=make([dynamic]string,context.temp_allocator)
    for &file in p.registry.files {
        if file.kind==asset.KIND_UI && !strings.has_prefix(file.path,"plugins/") {append(&paths,strings.clone(file.path,context.temp_allocator))}
    }
    if !testing.expect(t,len(paths)>0,"the template has interfaces") {return}
    for path in paths {
        // What Save writes of the file as it reads: a file written by an
        // earlier layout of its tables differs from itself by that alone.
        r:Records
        record,_:=asset.registry_find_path(&p.registry,path)
        id:=record.id
        if !testing.expectf(t,records_read(p.assets,id,&r,context.temp_allocator),"%s reads",path) {continue}
        saved,_,why,loads:=records_bytes(p.assets,id,&r)
        if !testing.expectf(t,loads,"%s loads: %s",path,why) {continue}
        out:serial.Writer
        serial.writer_init(&out,0,context.temp_allocator)
        if problem:=ui_read(&p,path,&out);!testing.expectf(t,problem=="","%s: %s",path,problem) {continue}
        document:=serial.json_pretty(string(serial.writer_bytes(&out)),context.temp_allocator)
        written,problem:=ui_write(&p,path,document)
        if !testing.expectf(t,problem=="","%s: %s",path,problem) {continue}
        testing.expectf(t,written.made==0 && written.removed==0,"%s: its own document makes or removes nodes",path)
        // theme.ui keeps, in a rule of a style, values of keys that rule does not
        // set: no document says them, and Save writes them back.
        if path!="menu/theme.ui" {testing.expectf(t,slice.equal(file_bytes(&p,path),saved),"%s: its document writes other bytes than Save does",path)}
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
    defer os.remove_all(root)
    p:Project
    if problem:=project_open(&p,root,engine,false);!testing.expect(t,problem=="",problem) {return}
    defer project_close(&p)
    info:core.World_Info
    game_info(&info)
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
    // Without the types of a game the path is not checked, and the command says so.
    p.info=nil
    _,unchecked:=ui_write(&p,"hud/hud.ui",wrong)
    testing.expect(t,unchecked=="",unchecked)
}

@(test)
the_commands_read_write_and_check_the_documents_kept_under_source :: proc(t:^testing.T) {
    root,engine,copied:=template_copy(t,"command")
    if !copied {return}
    defer os.remove_all(root)
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
    // The folder of documents becomes the assets in one command, each named by its file.
    written:=run(base_args,"ui","write",project.path(root,SOURCE_FOLDER,allocator=context.temp_allocator))
    testing.expectf(t,written.code==0 && strings.contains(written.out,"hud/hud.ui: ") && strings.contains(written.err,"are not checked"),"%d %s%s",written.code,written.out,written.err)
    // A new document makes its asset, and one that does not read is refused naming where.
    fresh:=project.path(root,SOURCE_FOLDER,"hud/score.ui.json",allocator=context.temp_allocator)
    testing.expect(t,os.write_entire_file(fresh,`{"use":["menu/theme.ui"],"nodes":[{"name":"score","kind":"Text","style":"chip_value","text":"0"}]}`)==nil)
    made:=run(base_args,"ui","write",fresh)
    testing.expectf(t,made.code==0 && strings.contains(made.out,"hud/score.ui: made"),"%d %s%s",made.code,made.out,made.err)
    testing.expect(t,os.is_file(project.path(root,"assets/hud/score.ui",allocator=context.temp_allocator)))
    testing.expect(t,os.write_entire_file(fresh,`{"nodes":[{"name":"score","kind":"Text","colour":"red"}]}`)==nil)
    refused:=run(base_args,"ui","write",fresh)
    testing.expectf(t,refused.code==1 && strings.contains(refused.err,"mirai ui write: hud/score.ui: nodes[0]") && strings.contains(refused.err,"colour"),"%d %s%s",refused.code,refused.out,refused.err)
    // A check reports what the game would not load and exits non-zero.
    clean:=run(base_args,"ui","check")
    testing.expectf(t,clean.code==0 && strings.contains(clean.out,"no problems"),"%d %s%s",clean.code,clean.out,clean.err)
    testing.expect(t,os.remove(project.path(root,"assets/menu/theme.ui",allocator=context.temp_allocator))==nil)
    broken:=run(base_args,"ui","check")
    testing.expectf(t,broken.code==1 && strings.contains(broken.out,"does not load") && strings.contains(broken.err,"problems"),"%d %s%s",broken.code,broken.out,broken.err)
    // A scene needs the types of the game, which a project that was never built does not have.
    scene:=run(base_args,"scene","read","arena/main.scene")
    testing.expectf(t,scene.code==1 && strings.contains(scene.err,"mirai build editor --dev"),"%d %s%s",scene.code,scene.out,scene.err)
}

@(test)
the_document_of_a_scene_writes_it_back_and_declares_what_its_file_has :: proc(t:^testing.T) {
    root,engine,copied:=template_copy(t,"scene")
    if !copied {return}
    defer os.remove_all(root)
    p:Project
    if problem:=project_open(&p,root,engine,false);!testing.expect(t,problem=="",problem) {return}
    defer project_close(&p)
    info:core.World_Info
    game_info(&info)
    p.info=&info
    for path in ([]string{"arena/main.scene","player/Player.prefab"}) {
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
    cases:=[]struct{document,message:string}{
        {`{"entities":[{"name":"x","components":{"Nope":{}}}]}`,"entities[0].components.Nope: the game of this build has no component 'Nope'"},
        {`{"entities":[{"name":"x","preset":"cube"}]}`,"entities[0].preset: a preset is a recipe the editor runs"},
        {`{"entities":[{"id":"0x00000000000000ff"}]}`,"entities[0].id: 0x00000000000000ff is no entity of the file"},
        {`{"entities":[{"name":"x","components":{"Tint":{"colour":[1,1,1,1]}}}]}`,"entities[0].components.Tint"},
        {`{"entities":[{"name":"x","sizes":3}]}`,"entities[0] has no 'sizes'; an entity has id, name"},
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
