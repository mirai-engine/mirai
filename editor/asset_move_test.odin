package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:ui"

@(private="file")
Move_Test :: struct {
    using files:Files_Test,
    assets:host.Assets,
    app:host.App,
}

@(private="file")
move_test_open :: proc(t:^testing.T,m:^Move_Test,name:string) -> bool {
    files_test_open(t,&m.files,name) or_return
    if !testing.expect(t,host.assets_init(&m.assets,{root=project.path(m.root,"assets",allocator=context.temp_allocator),capacity=16})) {return false}
    m.app=host.App{assets=&m.assets}
    m.s.app=&m.app
    return true
}

@(private="file")
move_test_close :: proc(m:^Move_Test) {
    host.assets_destroy(&m.assets)
    files_test_close(&m.files)
}

@(private="file")
move_test_disk :: proc(m:^Move_Test,path:string) -> string {return project.path(m.root,"assets",path,allocator=context.temp_allocator)}

@(private="file")
move_test_texture :: proc(t:^testing.T,m:^Move_Test,path:string,id:base.Asset_Id,owner:base.Asset_Id={},source:^asset.Import_Info=nil) {
    full:=move_test_disk(m,path)
    os.make_directory_all(filepath.dir(full))
    pixels:[16]u8
    testing.expect_value(t,asset.texture_save(full,&m.assets.types,{id=id,owner=owner,width=2,height=2,format=.RGBA8,mips={pixels[:]},source=source}),asset.Error.None)
}

@(private="file")
move_test_material :: proc(t:^testing.T,m:^Move_Test,path:string,id,texture:base.Asset_Id,owner:base.Asset_Id={},source:^asset.Import_Info=nil) {
    full:=move_test_disk(m,path)
    os.make_directory_all(filepath.dir(full))
    info:=asset.MATERIAL_DEFAULTS
    info.maps.base_color.texture=texture
    testing.expect_value(t,asset.material_save(full,&m.assets.types,{id=id,owner=owner,info=info,source=source}),asset.Error.None)
}

// A material id that names texture, as an edit holds it.
@(private="file")
move_test_material_bytes :: proc(m:^Move_Test,id,texture:base.Asset_Id) -> []u8 {
    info:=asset.MATERIAL_DEFAULTS
    info.maps.base_color.texture=texture
    bytes,_:=asset.material_bytes(&m.assets.types,{id=id,info=info},context.temp_allocator)
    return bytes
}

@(private="file")
move_test_path :: proc(m:^Move_Test,id:base.Asset_Id) -> string {
    file,found:=asset.registry_find(&m.assets.registry,id)
    return file.path if found else "<none>"
}

// What the registry says file depends on.
@(private="file")
move_test_names :: proc(m:^Move_Test,id,dependency:base.Asset_Id) -> bool {
    file,found:=asset.registry_find(&m.assets.registry,id)
    return found && slice.contains(asset.registry_dependencies(&m.assets.registry,file),dependency)
}

// The Import_Info of the asset at path, and whether it has one.
@(private="file")
move_test_import :: proc(m:^Move_Test,path:string) -> (source:string,found:bool) {
    _,info,has,_:=asset.import_peek(move_test_disk(m,path),&m.assets.types)
    return strings.clone(base.text_get(info.source[:]),context.temp_allocator),has
}

@(private="file") MOVE_TEST_TEXTURE :: base.Asset_Id{1,1}
@(private="file") MOVE_TEST_ROCK :: base.Asset_Id{1,2}
@(private="file") MOVE_TEST_USER :: base.Asset_Id{1,3}
@(private="file") MOVE_TEST_OTHER :: base.Asset_Id{1,4}

// Moving and renaming change where an asset is and nothing else: its id, what
// names it, the history that wrote it and the start scene follow it. What
// cannot be says why.
@(test)
moving_and_renaming_an_asset_keep_its_id_and_what_names_it :: proc(t:^testing.T) {
    m:=new(Move_Test,context.temp_allocator)
    if !move_test_open(t,m,"asset-move") {return}
    defer move_test_close(m)
    s:=&m.s
    r:=&m.assets.registry
    move_test_texture(t,m,"Rocks/rock.tex",MOVE_TEST_TEXTURE)
    move_test_material(t,m,"Rocks/rock.mat",MOVE_TEST_ROCK,MOVE_TEST_TEXTURE)
    move_test_material(t,m,"user.mat",MOVE_TEST_USER,MOVE_TEST_TEXTURE)
    move_test_texture(t,m,"Textures/other.tex",MOVE_TEST_OTHER)
    host.assets_scan(&m.assets)

    path,message:=asset_move(s,MOVE_TEST_TEXTURE,"Textures","")
    testing.expect_value(t,message,"")
    testing.expect_value(t,path,"Textures/rock.tex")
    testing.expect_value(t,move_test_path(m,MOVE_TEST_TEXTURE),"Textures/rock.tex")
    testing.expect(t,!os.exists(move_test_disk(m,"Rocks/rock.tex")) && os.exists(move_test_disk(m,"Textures/rock.tex")))
    testing.expect(t,move_test_names(m,MOVE_TEST_ROCK,MOVE_TEST_TEXTURE) && move_test_names(m,MOVE_TEST_USER,MOVE_TEST_TEXTURE))
    missing:=make([dynamic]asset.Registry_Missing,context.temp_allocator)
    asset.registry_missing(r,&missing)
    testing.expect_value(t,len(missing),0)

    // Renaming is moving within its folder; the extension stays and may be typed.
    path,message=asset_move(s,MOVE_TEST_TEXTURE,"Textures","granite.tex")
    testing.expect(t,message=="" && path=="Textures/granite.tex" && move_test_path(m,MOVE_TEST_TEXTURE)==path)
    path,message=asset_move(s,MOVE_TEST_TEXTURE,"Textures","Granite")
    testing.expect(t,message=="" && move_test_path(m,MOVE_TEST_TEXTURE)=="Textures/Granite.tex","a change of case renames")

    // A name taken, a name that cannot be, a folder that cannot be.
    _,message=asset_move(s,MOVE_TEST_TEXTURE,"Textures","other")
    testing.expect(t,strings.contains(message,"already exists"),message)
    _,message=asset_move(s,MOVE_TEST_TEXTURE,"Textures","a/b")
    testing.expect(t,message!="")
    _,message=asset_move(s,MOVE_TEST_TEXTURE,"../out","")
    testing.expect(t,strings.has_prefix(message,"folder:"),message)
    testing.expect_value(t,move_test_path(m,MOVE_TEST_TEXTURE),"Textures/Granite.tex")

    // What is unsaved does not move until it is saved or discarded.
    rock:=asset.registry_file_path(r,"Rocks/rock.mat",context.temp_allocator)
    testing.expect(t,file_write(s,rock,move_test_material_bytes(m,MOVE_TEST_ROCK,MOVE_TEST_OTHER),"Change rock"))
    files_test_commit(&m.files)
    _,message=asset_move(s,MOVE_TEST_ROCK,"Moved","")
    testing.expect(t,strings.contains(message,"unsaved"),message)
    testing.expect_value(t,move_test_path(m,MOVE_TEST_ROCK),"Rocks/rock.mat")
    assets_discard(s,{"Rocks/rock.mat"})
    // The history names the file where it went: undo puts it back there.
    path,message=asset_move(s,MOVE_TEST_ROCK,"Moved","")
    testing.expect(t,message=="" && path=="Moved/rock.mat")
    moved:=asset.registry_file_path(r,"Moved/rock.mat",context.temp_allocator)
    last:=move_test_last_file(m)
    testing.expect_value(t,last,moved)

}

@(private="file")
move_test_last_file :: proc(m:^Move_Test) -> string {
    for i:=len(m.edits.steps)-1;i>=0;i-=1 {
        if len(m.edits.steps[i].files)>0 {return m.edits.steps[i].files[0].path}
    }
    return ""
}

@(private="file") MOVE_TEST_MODEL :: base.Asset_Id{2,1}
@(private="file") MOVE_TEST_BASE :: base.Asset_Id{2,2}
@(private="file") MOVE_TEST_NORMAL :: base.Asset_Id{2,3}

// An import moves with its parts, which keep where they are beside it, and
// keeps its source. A duplicate copies them too with new ids, naming the
// copies, out of any import.
@(test)
an_import_moves_and_copies_with_its_parts :: proc(t:^testing.T) {
    m:=new(Move_Test,context.temp_allocator)
    if !move_test_open(t,m,"asset-move-import") {return}
    defer move_test_close(m)
    s:=&m.s
    r:=&m.assets.registry
    source:=asset.Import_Info{}
    base.text_set(source.source[:],"sources/rock.glb")
    move_test_material(t,m,"Models/rock.mat",MOVE_TEST_MODEL,MOVE_TEST_BASE,source=&source)
    move_test_texture(t,m,"Models/rock_D.tex",MOVE_TEST_BASE,MOVE_TEST_MODEL,&source)
    move_test_texture(t,m,"Models/maps/rock_N.tex",MOVE_TEST_NORMAL,MOVE_TEST_MODEL,&source)
    move_test_material(t,m,"user.mat",MOVE_TEST_USER,MOVE_TEST_BASE)
    host.assets_scan(&m.assets)

    path,message:=asset_move(s,MOVE_TEST_MODEL,"Props","")
    testing.expect(t,message=="" && path=="Props/rock.mat",message)
    testing.expect_value(t,move_test_path(m,MOVE_TEST_BASE),"Props/rock_D.tex")
    testing.expect_value(t,move_test_path(m,MOVE_TEST_NORMAL),"Props/maps/rock_N.tex")
    base_file,_:=asset.registry_find(r,MOVE_TEST_BASE)
    testing.expect(t,base_file.owner==MOVE_TEST_MODEL)
    testing.expect(t,move_test_names(m,MOVE_TEST_USER,MOVE_TEST_BASE))
    for moved in ([]string{"Props/rock.mat","Props/rock_D.tex","Props/maps/rock_N.tex"}) {
        named,has:=move_test_import(m,moved)
        testing.expect(t,has && named=="sources/rock.glb",moved)
    }

    // Renaming leaves the parts where they are.
    path,message=asset_move(s,MOVE_TEST_MODEL,"Props","boulder")
    testing.expect(t,message=="" && path=="Props/boulder.mat")
    testing.expect_value(t,move_test_path(m,MOVE_TEST_BASE),"Props/rock_D.tex")

    // A part that cannot go where its owner goes keeps everything where it is.
    move_test_texture(t,m,"Taken/rock_D.tex",MOVE_TEST_OTHER)
    host.assets_scan(&m.assets)
    _,message=asset_move(s,MOVE_TEST_MODEL,"Taken","")
    testing.expect(t,strings.contains(message,"Taken/rock_D.tex"),message)
    testing.expect_value(t,move_test_path(m,MOVE_TEST_MODEL),"Props/boulder.mat")

    copy,copied,problem:=asset_duplicate(s,MOVE_TEST_MODEL)
    testing.expect_value(t,problem,"")
    testing.expect_value(t,copied,"Props/boulder 2.mat")
    testing.expect(t,copy!={} && copy!=MOVE_TEST_MODEL)
    copy_file,found:=asset.registry_find(r,copy)
    testing.expect(t,found && copy_file.owner=={})
    base_copy,base_found:=asset.registry_find_path(r,"Props/rock_D 2.tex")
    normal_copy,normal_found:=asset.registry_find_path(r,"Props/maps/rock_N 2.tex")
    testing.expect(t,base_found && normal_found)
    testing.expect(t,base_copy.id!=MOVE_TEST_BASE && base_copy.owner==copy && normal_copy.owner==copy)
    testing.expect(t,move_test_names(m,copy,base_copy.id) && !move_test_names(m,copy,MOVE_TEST_BASE),"the copy names the copy of its part")
    _,has:=move_test_import(m,"Props/boulder 2.mat")
    testing.expect(t,!has,"a copy is no output of the import")
    _,has=move_test_import(m,"Props/boulder.mat")
    testing.expect(t,has)
    testing.expect_value(t,len(r.duplicates),0)
}

@(private="file") MOVE_TEST_START :: base.Asset_Id{3,1}

// A folder moves and copies with all it holds: its assets, its empty folders
// and its other files; it does not go into itself nor over what exists.
@(test)
a_folder_moves_and_copies_with_all_it_holds :: proc(t:^testing.T) {
    m:=new(Move_Test,context.temp_allocator)
    if !move_test_open(t,m,"asset-move-folder") {return}
    defer move_test_close(m)
    s:=&m.s
    r:=&m.assets.registry
    move_test_texture(t,m,"Env/maps/ground.tex",MOVE_TEST_TEXTURE)
    move_test_material(t,m,"Env/ground.mat",MOVE_TEST_ROCK,MOVE_TEST_TEXTURE)
    move_test_material(t,m,"user.mat",MOVE_TEST_USER,MOVE_TEST_TEXTURE)
    os.make_directory_all(move_test_disk(m,"Env/empty"))
    testing.expect(t,os.write_entire_file(move_test_disk(m,"Env/notes.txt"),"notes")==nil)
    os.make_directory_all(move_test_disk(m,"Other"))
    testing.expect_value(t,asset_create(s,asset.KIND_SCENE,"Env/start.scene",MOVE_TEST_START),"")
    s.has_project=true
    manifest:=project.manifest_default("move")
    base.text_set(manifest.start_scene[:],"Env/start.scene")
    manifest_file:=project.path(m.root,project.PROJECT_FILE,allocator=context.temp_allocator)
    testing.expect(t,project.manifest_write(manifest_file,&manifest).code==.None)
    host.assets_scan(&m.assets)

    _,message:=asset_folder_move(s,"Env","Env","")
    testing.expect(t,strings.contains(message,"inside itself"),message)
    _,message=asset_folder_move(s,"Env","Env/maps","")
    testing.expect(t,strings.contains(message,"inside itself"),message)
    _,message=asset_folder_move(s,"Env","","Other")
    testing.expect(t,strings.contains(message,"already exists"),message)
    _,message=asset_folder_move(s,"Missing","World","")
    testing.expect(t,message!="")
    _,message=asset_folder_move(s,"","World","")
    testing.expect(t,message!="")

    path,moved:=asset_folder_move(s,"Env","World","")
    testing.expect(t,moved=="" && path=="World/Env",moved)
    testing.expect_value(t,move_test_path(m,MOVE_TEST_ROCK),"World/Env/ground.mat")
    testing.expect_value(t,move_test_path(m,MOVE_TEST_TEXTURE),"World/Env/maps/ground.tex")
    testing.expect(t,move_test_names(m,MOVE_TEST_USER,MOVE_TEST_TEXTURE))
    testing.expect(t,os.is_dir(move_test_disk(m,"World/Env/empty")) && os.exists(move_test_disk(m,"World/Env/notes.txt")))
    testing.expect_value(t,project.start_scene(m.root,context.temp_allocator),"World/Env/start.scene")

    path,moved=asset_folder_move(s,"World/Env","World","Biome")
    testing.expect(t,moved=="" && path=="World/Biome" && move_test_path(m,MOVE_TEST_ROCK)=="World/Biome/ground.mat")

    // Unsaved files keep their folder where it is.
    testing.expect_value(t,asset.registry_memory_set(r,"World/Biome/ground.mat",move_test_material_bytes(m,MOVE_TEST_ROCK,{})),asset.Error.None)
    _,moved=asset_folder_move(s,"World/Biome","","")
    testing.expect(t,strings.contains(moved,"unsaved"),moved)
    assets_discard(s,{"World/Biome/ground.mat"})

    copy,copied:=asset_folder_duplicate(s,"World/Biome")
    testing.expect(t,copied=="" && copy=="World/Biome 2",copied)
    ground,found:=asset.registry_find_path(r,"World/Biome 2/ground.mat")
    map_copy,map_found:=asset.registry_find_path(r,"World/Biome 2/maps/ground.tex")
    testing.expect(t,found && map_found && ground.id!=MOVE_TEST_ROCK && map_copy.id!=MOVE_TEST_TEXTURE)
    testing.expect(t,move_test_names(m,ground.id,map_copy.id),"copies name each other")
    testing.expect(t,os.is_dir(move_test_disk(m,"World/Biome 2/empty")) && os.exists(move_test_disk(m,"World/Biome 2/notes.txt")))
    testing.expect_value(t,move_test_path(m,MOVE_TEST_ROCK),"World/Biome/ground.mat")
    testing.expect_value(t,len(r.duplicates),0)
}

// The API names an asset by its path or its id and a folder by its path,
// answers with where it is and its id, and says what failed.
@(test)
the_api_renames_moves_and_copies_by_path_or_id :: proc(t:^testing.T) {
    m:=new(Move_Test,context.temp_allocator)
    if !move_test_open(t,m,"asset-move-api") {return}
    defer move_test_close(m)
    s:=&m.s
    move_test_texture(t,m,"Rocks/rock.tex",MOVE_TEST_TEXTURE)
    host.assets_scan(&m.assets)
    run :: proc(s:^Session,handler:proc(s:^Session,call:^api.Call),params:^$T) -> (result:Api_Asset_Moved_Result,call:api.Call) {
        method:=api.Method{params_id=T,result_id=Api_Asset_Moved_Result}
        call=api.Call{method=&method,params=params,result=&result,allocator=context.temp_allocator}
        handler(s,&call)
        call.method,call.result=nil,nil
        return
    }
    rename:Api_Asset_Move_Params
    base.text_set(rename.asset[:],"Rocks/rock.tex")
    base.text_set(rename.name[:],"granite")
    result,call:=run(s,api_asset_move,&rename)
    testing.expect(t,!call.failed,call.error.message)
    testing.expect_value(t,base.text_get(result.path[:]),"Rocks/granite.tex")
    id_text:[base.ASSET_ID_TEXT]u8
    testing.expect_value(t,base.text_get(result.id[:]),base.asset_id_format(MOVE_TEST_TEXTURE,id_text[:]))

    move:Api_Asset_Move_Params
    base.text_set(move.asset[:],base.asset_id_format(MOVE_TEST_TEXTURE,id_text[:]))
    base.text_set(move.folder[:],"Stone")
    result,call=run(s,api_asset_move,&move)
    testing.expect(t,!call.failed && base.text_get(result.path[:])=="Stone/granite.tex",call.error.message)
    // A folder moves by its path and answers without an id.
    move={}
    base.text_set(move.asset[:],"Stone")
    base.text_set(move.folder[:],"Nature")
    result,call=run(s,api_asset_move,&move)
    testing.expect(t,!call.failed && base.text_get(result.path[:])=="Nature/Stone" && base.text_get(result.id[:])=="",call.error.message)

    // No folder keeps the one it is in, and / is the root.
    move={}
    base.text_set(move.asset[:],"Nature/Stone/granite.tex")
    base.text_set(move.folder[:],"/")
    result,call=run(s,api_asset_move,&move)
    testing.expect(t,!call.failed && base.text_get(result.path[:])=="granite.tex",call.error.message)
    base.text_set(move.asset[:],"granite.tex")
    base.text_set(move.folder[:],"Nature/Stone")
    result,call=run(s,api_asset_move,&move)
    testing.expect(t,!call.failed && base.text_get(result.path[:])=="Nature/Stone/granite.tex",call.error.message)

    duplicate:Api_Asset_Move_Params
    duplicate.copy=true
    base.text_set(duplicate.asset[:],"Nature/Stone/granite.tex")
    result,call=run(s,api_asset_move,&duplicate)
    testing.expect(t,!call.failed && base.text_get(result.path[:])=="Nature/Stone/granite 2.tex",call.error.message)
    testing.expect(t,base.text_get(result.id[:])!="" && base.text_get(result.id[:])!=base.asset_id_format(MOVE_TEST_TEXTURE,id_text[:]))
    base.text_set(duplicate.folder[:],"Copies")
    base.text_set(duplicate.name[:],"basalt")
    result,call=run(s,api_asset_move,&duplicate)
    testing.expect(t,!call.failed && base.text_get(result.path[:])=="Copies/basalt.tex",call.error.message)
    nothing:Api_Asset_Move_Params
    base.text_set(nothing.asset[:],"Copies/basalt.tex")
    result,call=run(s,api_asset_move,&nothing)
    testing.expect(t,call.failed && strings.contains(call.error.message,"changes nothing"),call.error.message)

    // What it cannot find, or cannot do, it says.
    base.text_set(rename.asset[:],"Nowhere/missing.tex")
    result,call=run(s,api_asset_move,&rename)
    testing.expect(t,call.failed && strings.contains(call.error.message,"asset.list"),call.error.message)
    base.text_set(move.asset[:],"Nature")
    base.text_set(move.folder[:],"Nature/Stone")
    result,call=run(s,api_asset_move,&move)
    testing.expect(t,call.failed && strings.contains(call.error.message,"inside itself"),call.error.message)
}

// Rename puts the line of Create over the name of a card: what is typed
// renames it. A card let go on the header of a folder moves there.
@(test)
the_line_of_create_renames_a_card_and_a_card_let_go_on_a_folder_moves_there :: proc(t:^testing.T) {
    root:=base.test_folder(t,"content-rename")
    if root=="" {return}
    testing.expect_value(t,os.make_directory_all(fmt.tprintf("%s/Materials",root)),os.Error(nil))
    testing.expect_value(t,os.make_directory_all(fmt.tprintf("%s/Archive",root)),os.Error(nil))
    ctx:ui.Context
    testing.expect(t,ui.context_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/Materials/rock.mat",root),&assets.types,{id=MOVE_TEST_ROCK,info=asset.MATERIAL_DEFAULTS}),asset.Error.None)
    host.assets_scan(&assets)
    app:=host.App{assets=&assets}
    g:=Editor_Ui{ctx=&ctx}
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    selection:history.Selection
    info:core.World_Info
    session:=Session{app=&app,gui=&g,content=&c,selection=&selection,info=&info,headless=true}
    defer delete(session.asset_documents)
    for _ in 0..<3 {content_test_still(&session)}

    content_rename_begin(&session,MOVE_TEST_ROCK)
    testing.expect(t,c.creating && c.create_kind==asset.KIND_MATERIAL && string(c.create_name[:c.create_name_length])=="rock")
    content_test_still(&session)
    testing.expect_value(t,ctx.edit.id,ui.id_derive(&ctx,100,"content_create_name"))
    typed:=ui.Input{size={800,600},pointer_absent=true}
    typed.text_count=copy(typed.text[:],"granite")
    _=content_test_frame(&session,typed)
    _=content_test_frame(&session,{size={800,600},pointer_absent=true,keys_down={.Enter},keys_pressed={.Enter}})
    testing.expect(t,!c.creating && c.rename_length==0)
    file,found:=asset.registry_find(&assets.registry,MOVE_TEST_ROCK)
    testing.expect(t,found && file.path=="Materials/granite.mat",file.path if found else "")
    for _ in 0..<2 {content_test_still(&session)}
    testing.expect(t,c.selected==MOVE_TEST_ROCK,"the selection follows it")

    archive,shown:=ui.widget_rect(&ctx,ui.id_derive(&ctx,100,"content_folder",int(content_test_hash("Archive"))))
    if !testing.expect(t,shown) {return}
    g.drag=Drag{kind=.Asset,asset_id=MOVE_TEST_ROCK,asset_kind=asset.KIND_MATERIAL,moved=true,released=true}
    _=content_test_frame(&session,{size={800,600},pointer=ui.rect_center(archive)})
    g.drag={}
    file,found=asset.registry_find(&assets.registry,MOVE_TEST_ROCK)
    testing.expect(t,found && file.path=="Archive/granite.mat",file.path if found else "")
}
