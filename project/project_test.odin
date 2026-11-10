package project

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
test_write :: proc(t:^testing.T,parts:..string,text:="") {
    file:=path(..parts,allocator=context.temp_allocator)
    directory:=file[:strings.last_index_byte(file,'/')]
    testing.expect(t,os.make_directory_all(directory)==nil || os.is_dir(directory))
    testing.expect(t,os.write_entire_file(file,text)==nil,file)
}

// A plugin folder with its manifest and the folders of its parts.
@(private="file")
test_plugin :: proc(t:^testing.T,plugins,name:string,dependencies:[]string={},parts:Plugin_Parts={.Runtime},automatic:=false) {
    m:Plugin_Manifest
    base.text_set(m.name[:],name)
    base.text_set(m.version[:],"1.0.0")
    for dependency,i in dependencies {base.text_set(m.dependencies[i][:],dependency)}
    m.parts=parts
    m.automatic=automatic
    test_write(t,plugins,name,PLUGIN_FILE,text=plugin_text(&m,context.temp_allocator))
    part_names:=PART_NAMES
    for part in parts {
        folder:=path(plugins,name,part_names[part],allocator=context.temp_allocator)
        testing.expect(t,os.make_directory_all(folder)==nil || os.is_dir(folder))
    }
}

@(private="file")
test_project :: proc(t:^testing.T,root:string,plugins:..string) {
    m:=manifest_default("Test")
    for name,i in plugins {base.text_set(m.plugins[i][:],name)}
    test_write(t,root,PROJECT_FILE,text=manifest_text(&m,context.temp_allocator))
}

@(private="file")
active_names :: proc(p:^Project) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for index,i in p.active {
        if i>0 {strings.write_byte(&b,' ')}
        strings.write_string(&b,base.text_get(p.plugins[index].manifest.name[:]))
    }
    return strings.to_string(b)
}

@(test)
a_project_manifest_round_trips_as_json :: proc(t:^testing.T) {
    m:=manifest_default("Mi Juego")
    base.text_set(m.start_scene[:],"levels/main.scene")
    base.text_set(m.thumbnail[:],"art/cover.png")
    base.text_set(m.plugins[0][:],"terrain")
    base.text_set(m.plugins[1][:],"water_2")
    base.text_set(m.build.executable[:],"mi-juego")
    m.build.optimization=.Speed
    m.build.debug=true
    base.text_set(m.build.defines[0][:],"MIRAI_ECS_MAX_TYPES=512")
    base.text_set(m.build.defines[1][:],"DEMO")
    base.text_set(m.window.title[:],"Mi Juego \"beta\"")
    m.window.mode=.Maximized
    m.window.width,m.window.height=1920,1080
    text:=manifest_text(&m,context.temp_allocator)
    testing.expect(t,strings.contains(text,`"mode": "Maximized"`),text)
    testing.expect(t,strings.contains(text,`"plugins": ["terrain", "water_2"]`),text)
    testing.expect(t,strings.contains(text,`"defines": ["MIRAI_ECS_MAX_TYPES=512", "DEMO"]`),text)
    testing.expect(t,strings.contains(text,`"optimization": "Speed"`),text)
    testing.expect(t,strings.contains(text,`"start_scene": "levels/main.scene"`),text)
    testing.expect(t,strings.contains(text,`"thumbnail": "art/cover.png"`),text)
    back,error:=manifest_parse(text)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect(t,back==m)
    testing.expect_value(t,manifest_text(&back,context.temp_allocator),text)
}

@(test)
the_size_of_a_png_is_read_from_its_header :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"project")
    header:=[24]u8{0x89,'P','N','G',0x0d,0x0a,0x1a,0x0a,0,0,0,13,'I','H','D','R',0,0,0,200,0,0,0,100}
    file:=path(folder,"icon.png",allocator=context.temp_allocator)
    testing.expect(t,os.write_entire_file(file,header[:])==nil)
    width,height,ok:=png_size(file)
    testing.expect(t,ok && width==200 && height==100 && width>PLUGIN_ICON_MAX)
    testing.expect(t,os.write_entire_file(file,"not a png at all, longer than a header")==nil)
    _,_,ok=png_size(file)
    testing.expect(t,!ok)
}

@(test)
a_plugin_manifest_round_trips_as_json :: proc(t:^testing.T) {
    m:Plugin_Manifest
    base.text_set(m.name[:],"terrain")
    base.text_set(m.version[:],"1.12.3")
    base.text_set(m.dependencies[0][:],"noise")
    base.text_set(m.dependencies[1][:],"streaming")
    m.parts={.Runtime,.Editor,.Assets}
    base.text_set(m.icon[:],"art/icon.png")
    base.text_set(m.asset_kinds[0].extension[:],".terrain")
    base.text_set(m.asset_kinds[1].extension[:],".biome")
    m.asset_kinds[1].merged=true
    text:=plugin_text(&m,context.temp_allocator)
    testing.expect(t,strings.contains(text,`"extension": ".biome"`) && !strings.contains(text,`"extension": ""`),text)
    testing.expect(t,strings.contains(text,`"dependencies": ["noise", "streaming"]`),text)
    testing.expect(t,strings.contains(text,`"icon": "art/icon.png"`),text)
    testing.expect(t,strings.contains(text,`"parts": ["Runtime", "Editor", "Assets"]`),text)
    back,error:=plugin_parse(text)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect(t,back==m)
}

@(test)
an_installed_engine_is_told_by_its_manifest :: proc(t:^testing.T) {
    installed:=base.test_folder(t,"project")
    testing.expect(t,!engine_installed(installed) && !engine_root_is(installed))
    m:Engine_Manifest
    base.text_set(m.version[:],ENGINE_VERSION)
    base.text_set(m.commit[:],"8ddf7a96ab537fe5d94c9f83c9b5760747080b0c")
    base.text_set(m.platform[:],ENGINE_PLATFORM)
    base.text_set(m.odin[:],"dev-2026-11")
    base.text_set(m.slang[:],"2026.20")
    testing.expect_value(t,engine_manifest_write(installed,&m).code,Error_Code.None)
    testing.expect(t,engine_installed(installed) && engine_root_is(installed))
    back,error:=engine_manifest_read(installed)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect(t,back==m)
    testing.expect_value(t,engine_root_find(installed,context.temp_allocator),installed)

    // A checkout is told by its sources; one without them is no engine.
    checkout:=base.test_folder(t,"project")
    test_write(t,checkout,"AGENTS.md")
    testing.expect(t,!engine_root_is(checkout))
    testing.expect(t,os.make_directory_all(path(checkout,"tools/mirai",allocator=context.temp_allocator))==nil)
    testing.expect(t,engine_root_is(checkout) && !engine_installed(checkout))
}

@(test)
a_manifest_keeps_its_defaults_for_the_fields_the_file_omits :: proc(t:^testing.T) {
    m,error:=manifest_parse(`{"name": "Solo"}`)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,base.text_get(m.name[:]),"Solo")
    testing.expect_value(t,m.window.mode,Window_Mode.Maximized)
    testing.expect_value(t,m.window.width,1280)
    testing.expect_value(t,m.window.height,720)
    testing.expect_value(t,m.build.optimization,Optimization.Minimal)
    testing.expect_value(t,base.text_get(m.plugins[0][:]),"")
    testing.expect_value(t,window_title(&m),"Solo")

    // A list in the file replaces the whole list.
    m,error=manifest_parse(`{"name": "Solo", "plugins": ["a", "b"], "window": {"height": 600}}`)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,base.text_get(m.plugins[1][:]),"b")
    testing.expect_value(t,m.window.width,1280)
    testing.expect_value(t,m.window.height,600)
}

@(test)
a_bad_project_manifest_is_refused_with_what_and_where :: proc(t:^testing.T) {
    Case :: struct {text:string,code:Error_Code,text_code:serial.Text_Error_Code,line,column:int,subject,detail:string}
    long_name:=strings.repeat("a",65,context.temp_allocator)
    many:=strings.builder_make(context.temp_allocator)
    for i in 0..=MAX_PLUGINS {fmt.sbprintf(&many,"%s\"p%d\"",i>0?",":"",i)}
    cases:=[]Case{
        {text="",code=.Text,text_code=.Expected_Object,line=1,column=1},
        {text="{\n  \"name\": \"x\",\n  \"scenes\": 3\n}",code=.Text,text_code=.Unknown_Field,line=3,column=3,detail=`"scenes" is not a field: the fields are name, `},
        {text="{\"name\": \"x\"} trailing",code=.Text,text_code=.Syntax,line=1,column=15},
        {text="{\"name\": 7}",code=.Text,text_code=.Expected_Array,line=1,column=10},
        {text="{\"name\": \"x\",\n \"plugins\": \"terrain\"}",code=.Text,text_code=.Expected_Array,line=2,column=13},
        {text="{\"name\": \"x\", \"plugins\": [7]}",code=.Text,text_code=.Expected_String,line=1,column=27},
        {text=fmt.tprintf("{{\"name\": \"x\", \"plugins\": [\"%s\"]}}",long_name),code=.Text,text_code=.Text_Too_Long,line=1,column=27},
        {text=fmt.tprintf("{{\"plugins\": [%s]}}",strings.to_string(many)),code=.Text,text_code=.Too_Many_Elements,line=1},
        {text="{\"name\": \"x\", \"build\": {\"optimization\": \"Fast\"}}",code=.Text,text_code=.Unknown_Member,line=1,column=41,detail=`build.optimization: "Fast" is not one of`},
        {text="{\"name\": \"x\", \"window\": {\"width\": \"wide\"}}",code=.Text,text_code=.Expected_Number,line=1,column=35},
        {text="{}",code=.Name_Missing},
        {text="{\"name\": \"x\", \"plugins\": [\"Terrain\"]}",code=.Name_Invalid,subject="Terrain"},
        {text="{\"name\": \"x\", \"plugins\": [\"9lives\"]}",code=.Name_Invalid,subject="9lives"},
        {text="{\"name\": \"x\", \"plugins\": [\"a\", \"b\", \"a\"]}",code=.Name_Repeated,subject="a"},
        {text="{\"name\": \"x\", \"start_scene\": \"/abs/main.scene\"}",code=.Scene_Invalid},
        {text="{\"name\": \"x\", \"start_scene\": \"C:/main.scene\"}",code=.Scene_Invalid},
        {text="{\"name\": \"x\", \"start_scene\": \"assets/../../main.scene\"}",code=.Scene_Invalid},
        {text="{\"name\": \"x\", \"start_scene\": \"assets\\\\main.scene\"}",code=.Scene_Invalid},
        {text="{\"name\": \"x\", \"build\": {\"executable\": \"my game\"}}",code=.Executable_Invalid,subject="my game"},
        {text="{\"name\": \"x\", \"build\": {\"defines\": [\"A=1\", \"2B=1\"]}}",code=.Define_Invalid,subject="2B=1"},
        {text="{\"name\": \"x\", \"build\": {\"defines\": [\"=1\"]}}",code=.Define_Invalid,subject="=1"},
        {text="{\"name\": \"x\", \"window\": {\"width\": 0}}",code=.Window_Invalid},
        {text="{\"name\": \"x\", \"window\": {\"height\": 20000}}",code=.Window_Invalid},
    }
    for c in cases {
        _,error:=manifest_parse(c.text)
        testing.expect_value(t,error.code,c.code)
        testing.expect_value(t,error.text,c.text_code)
        testing.expect(t,error.line==c.line,fmt.tprintf("line %d of %q",error.line,c.text))
        if c.column!=0 {testing.expect(t,error.column==c.column,fmt.tprintf("column %d of %q",error.column,c.text))}
        testing.expect_value(t,base.text_get(error.subject[:]),c.subject)
        testing.expectf(t,strings.has_prefix(error.detail,c.detail),"%q: %q, expected %q",c.text,error.detail,c.detail)
    }
}

@(test)
a_bad_plugin_manifest_is_refused_with_what_and_where :: proc(t:^testing.T) {
    Case :: struct {text:string,code:Error_Code,text_code:serial.Text_Error_Code,subject:string}
    cases:=[]Case{
        {`{"version": "1.0.0"}`,.Name_Missing,.None,""},
        {`{"name": "my-plugin", "version": "1.0.0"}`,.Name_Invalid,.None,"my-plugin"},
        {`{"name": "a"}`,.Version_Invalid,.None,""},
        {`{"name": "a", "version": "1.0"}`,.Version_Invalid,.None,"1.0"},
        {`{"name": "a", "version": "1.0.x"}`,.Version_Invalid,.None,"1.0.x"},
        {`{"name": "a", "version": "1..0"}`,.Version_Invalid,.None,"1..0"},
        {`{"name": "a", "version": "1.0.0", "dependencies": ["a"]}`,.Depends_On_Itself,.None,"a"},
        {`{"name": "a", "version": "1.0.0", "dependencies": ["b", "b"]}`,.Name_Repeated,.None,"b"},
        {`{"name": "a", "version": "1.0.0", "dependencies": ["B"]}`,.Name_Invalid,.None,"B"},
        {`{"name": "a", "version": "1.0.0", "parts": ["Runtime", "Tools"]}`,.Text,.Unknown_Member,""},
        {`{"name": "a", "version": "1.0.0", "parts": "Runtime"}`,.Text,.Expected_Array,""},
        {`{"name": "a", "version": "1.0.0", "engine": {"min": "0.x"}}`,.Engine_Invalid,.None,"0.x"},
        {`{"name": "a", "version": "1.0.0", "engine": {"max": "1.2.3.4"}}`,.Engine_Invalid,.None,"1.2.3.4"},
        {`{"name": "a", "version": "1.0.0", "engine": {"min": "0.3", "max": "0.2"}}`,.Engine_Invalid,.None,"0.3"},
        {`{"name": "a", "version": "1.0.0", "icon": "../icon.png"}`,.Icon_Invalid,.None,"../icon.png"},
        {`{"name": "a", "version": "1.0.0", "icon": "icon.svg"}`,.Icon_Invalid,.None,"icon.svg"},
        {`{"name": "a", "version": "1.0.0", "asset_kinds": [{"extension": "biome"}]}`,.Asset_Kind_Invalid,.None,"biome"},
        {`{"name": "a", "version": "1.0.0", "asset_kinds": [{"extension": ".Biome"}]}`,.Asset_Kind_Invalid,.None,".Biome"},
        {`{"name": "a", "version": "1.0.0", "asset_kinds": [{"extension": ".biome"}, {"extension": ".biome", "merged": true}]}`,.Asset_Kind_Invalid,.None,".biome"},
        {`{"name": "a", "version": "1.0.0", "asset_kinds": [{"merged": true}]}`,.Asset_Kind_Invalid,.None,""},
    }
    for c in cases {
        _,error:=plugin_parse(c.text)
        testing.expect(t,error.code==c.code,fmt.tprintf("%v for %s",error.code,c.text))
        testing.expect_value(t,error.text,c.text_code)
        testing.expect_value(t,base.text_get(error.subject[:]),c.subject)
    }
}

@(test)
a_plugin_states_the_engines_it_works_with_as_a_range :: proc(t:^testing.T) {
    Case :: struct {min,max,engine:string,code:Error_Code,subject:string}
    cases:=[]Case{
        {"","","0.1.0",.None,""},
        {"0.1","0.1","0.1.7",.None,""},
        {"0.1.2","","0.1.2",.None,""},
        {"","0","0.9.9",.None,""},
        {"0.2","","0.1.9",.Engine_Old,"0.2"},
        {"","0.1","0.2.0",.Engine_New,"0.1"},
        {"","0.1.3","0.1.4",.Engine_New,"0.1.3"},
    }
    for c in cases {
        m:Plugin_Manifest
        base.text_set(m.name[:],"a")
        base.text_set(m.version[:],"1.0.0")
        base.text_set(m.engine.min[:],c.min)
        base.text_set(m.engine.max[:],c.max)
        testing.expect_value(t,plugin_validate(&m).code,Error_Code.None)
        error:=plugin_engine_check(&m,c.engine)
        testing.expect(t,error.code==c.code,fmt.tprintf("%v for [%s, %s] on %s",error.code,c.min,c.max,c.engine))
        testing.expect_value(t,base.text_get(error.subject[:]),c.subject)
    }
}

@(test)
manifests_are_written_to_and_read_from_files :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"project")
    file:=path(folder,PROJECT_FILE,allocator=context.temp_allocator)
    _,error:=manifest_read(file)
    testing.expect_value(t,error.code,Error_Code.Not_Found)

    m:=manifest_default("Disk")
    base.text_set(m.plugins[0][:],"sample")
    testing.expect_value(t,manifest_write(file,&m).code,Error_Code.None)
    back:Manifest
    back,error=manifest_read(file)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect(t,back==m)
    testing.expect_value(t,start_scene(folder,context.temp_allocator),"")
    base.text_set(m.start_scene[:],"main.scene")
    testing.expect_value(t,manifest_write(file,&m).code,Error_Code.None)
    testing.expect_value(t,start_scene(folder,context.temp_allocator),"main.scene")
    testing.expect_value(t,start_scene(path(folder,"nowhere",allocator=context.temp_allocator),context.temp_allocator),"")

    // What does not validate is never written.
    m.window.width=0
    testing.expect_value(t,manifest_write(file,&m).code,Error_Code.Window_Invalid)
    back,error=manifest_read(file)
    testing.expect_value(t,back.window.width,1280)

    plugin:Plugin_Manifest
    base.text_set(plugin.name[:],"sample")
    base.text_set(plugin.version[:],"0.1.0")
    plugin.parts={.Runtime,.Editor}
    plugin_file:=path(folder,PLUGIN_FILE,allocator=context.temp_allocator)
    testing.expect_value(t,plugin_write(plugin_file,&plugin).code,Error_Code.None)
    read,plugin_error:=plugin_read(plugin_file)
    testing.expect_value(t,plugin_error.code,Error_Code.None)
    testing.expect(t,read==plugin)
    testing.expect_value(t,manifest_write(path(folder,"missing","x.mirai",allocator=context.temp_allocator),&back).code,Error_Code.Write_Failed)
}

@(test)
the_executable_takes_its_name_from_the_manifest_or_from_the_project :: proc(t:^testing.T) {
    buffer:[64]u8
    m:=manifest_default("Mi Juego: Demo")
    testing.expect_value(t,executable_name(&m,buffer[:]),"Mi_Juego__Demo")
    base.text_set(m.build.executable[:],"demo")
    testing.expect_value(t,executable_name(&m,buffer[:]),"demo")
    base.text_set(m.window.title[:],"Demo!")
    testing.expect_value(t,window_title(&m),"Demo!")
}

@(test)
the_game_is_named_by_its_version_identifier_and_icon :: proc(t:^testing.T) {
    m:=manifest_default("Game")
    testing.expect_value(t,base.text_get(m.version[:]),"0.1.0")
    testing.expect_value(t,manifest_validate(&m).code,Error_Code.None)
    base.text_set(m.identifier[:],"com.studio.my-game_2")
    base.text_set(m.icon[:],"art/Icon.PNG")
    testing.expect_value(t,manifest_validate(&m).code,Error_Code.None)
    cases:=[?]struct{field:^[128]u8,text:string,code:Error_Code}{
        {&m.identifier,"com..game",.Identifier_Invalid},
        {&m.identifier,"com.studio game",.Identifier_Invalid},
        {&m.identifier,".game",.Identifier_Invalid},
    }
    for c in cases {
        before:=c.field^
        base.text_set(c.field[:],c.text)
        error:=manifest_validate(&m)
        testing.expect_value(t,error.code,c.code)
        testing.expect_value(t,base.text_get(error.subject[:]),c.text[:min(len(c.text),len(error.subject))])
        testing.expect(t,strings.contains(error_text("game",error,context.temp_allocator),"com.studio.game"))
        c.field^=before
    }
    for icon in ([?]string{"icon.bmp","../icon.png","C:/icon.png",`art\icon.png`}) {
        base.text_set(m.icon[:],icon)
        testing.expect_value(t,manifest_validate(&m).code,Error_Code.Icon_Invalid)
        base.text_set(m.icon[:],"")
        base.text_set(m.thumbnail[:],icon)
        error:=manifest_validate(&m)
        testing.expect_value(t,error.code,Error_Code.Thumbnail_Invalid)
        testing.expect(t,strings.contains(error_text("game",error,context.temp_allocator),"thumbnail"))
        base.text_set(m.thumbnail[:],"")
    }
    base.text_set(m.thumbnail[:],"art/Cover.PNG")
    testing.expect_value(t,manifest_validate(&m).code,Error_Code.None)
    base.text_set(m.thumbnail[:],"")
    base.text_set(m.version[:],"1.2")
    testing.expect_value(t,manifest_validate(&m).code,Error_Code.Version_Invalid)
    // A manifest written before these fields reads with their defaults.
    old,error:=manifest_parse(`{"name": "Old"}`)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,base.text_get(old.version[:]),"0.1.0")
}

@(test)
paths_join_with_forward_slashes :: proc(t:^testing.T) {
    testing.expect_value(t,path("C:/games/demo","plugins","terrain",PLUGIN_FILE,allocator=context.temp_allocator),"C:/games/demo/plugins/terrain/plugin.mirai")
    testing.expect_value(t,path("root/","","a",allocator=context.temp_allocator),"root/a")
    testing.expect_value(t,folder_path("demo",.Generated,context.temp_allocator),"demo/.mirai")
    testing.expect_value(t,folder_path("demo",.Game,context.temp_allocator),"demo/game")
    absolute:=path_absolute("some/folder/",context.temp_allocator)
    testing.expect(t,strings.has_suffix(absolute,"/some/folder") && !strings.contains(absolute,"\\"),absolute)
}

@(test)
paths_are_the_same_file_as_their_system_tells_them_apart :: proc(t:^testing.T) {
    folds:=ODIN_OS==.Windows || ODIN_OS==.Darwin
    cases:=[?]struct{a,b:string,same:bool}{
        {"C:/games/demo","C:/games/demo",true},
        {"C:/games/demo/","C:/games/demo",true},
        {"C:/games/demo","C:/games/demos",false},
        {"C:/games/demo","C:/games/demo/assets",false},
        {"C:/games/demo","C:/games/de/mo",false},
        {"C:/Games/Demo","c:/games/demo",folds},
        {"C:\\games\\demo","C:/games/demo",ODIN_OS==.Windows},
        {"bin","BIN",folds},
        {"","",true},
    }
    for c in cases {testing.expectf(t,path_same(c.a,c.b)==c.same && path_same(c.b,c.a)==c.same,"%q and %q",c.a,c.b)}
}

@(test)
paths_of_git_bash_name_the_drive_on_windows :: proc(t:^testing.T) {
    named :: proc(t:^testing.T,location,expected:string,expected_ok:bool,loc:=#caller_location) {
        native,ok:=path_native(location)
        testing.expectf(t,ok==expected_ok && (!ok || native==expected),"%s: %s %v",location,native,ok,loc=loc)
    }
    when ODIN_OS==.Windows {
        named(t,"/c/Users/demo/x.scene","C:/Users/demo/x.scene",true)
        named(t,"/cygdrive/d/games","D:/games",true)
        named(t,"/e","E:/",true)
        named(t,"/tmp/x","",false)
        named(t,"\\x","",false)
        named(t,"//server/share/x","//server/share/x",true)
        named(t,"assets/x.scene","assets/x.scene",true)
    } else {
        named(t,"/tmp/x","/tmp/x",true)
    }
}

@(test)
a_project_finds_its_plugins_and_orders_them_by_dependency :: proc(t:^testing.T) {
    root:=base.test_folder(t,"project")
    plugins:=folder_path(root,.Plugins,context.temp_allocator)
    test_plugin(t,plugins,"water",{"terrain","noise"})
    test_plugin(t,plugins,"terrain",{"noise"},{.Runtime,.Editor,.Shaders,.Assets})
    test_plugin(t,plugins,"noise")
    test_plugin(t,plugins,"unused")
    testing.expect(t,os.make_directory_all(path(plugins,"not_a_plugin","runtime",allocator=context.temp_allocator))==nil)
    test_project(t,root,"water","terrain")

    p,error:=open(root)
    defer close(&p)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,len(p.plugins),4)
    testing.expect_value(t,active_names(&p),"noise terrain water")
    testing.expect_value(t,base.text_get(p.manifest.name[:]),"Test")
    index,found:=plugin_find(p.plugins,"terrain")
    testing.expect(t,found)
    if found {
        testing.expect_value(t,p.plugins[index].folder,path(plugins,"terrain",allocator=context.temp_allocator))
        testing.expect_value(t,p.plugins[index].manifest.parts,Plugin_Parts{.Runtime,.Editor,.Shaders,.Assets})
        testing.expect_value(t,p.plugins[index].origin,Origin.Project)
    }
    _,found=plugin_find(p.plugins,"not_a_plugin")
    testing.expect(t,!found)

    // Dependencies come first whatever the order the project names them in.
    order,order_error:=plugins_order(p.plugins,{"terrain","unused","water"},context.temp_allocator)
    testing.expect_value(t,order_error.code,Error_Code.None)
    testing.expect_value(t,len(order),4)
    if len(order)==4 {
        names:[4]string
        for plugin,i in order {names[i]=base.text_get(p.plugins[plugin].manifest.name[:])}
        testing.expect_value(t,names,[4]string{"noise","terrain","unused","water"})
    }
}

@(test)
a_first_party_plugin_of_the_engine_is_found :: proc(t:^testing.T) {
    root:=base.test_folder(t,"project")
    engine:=base.test_folder(t,"project")
    test_plugin(t,folder_path(engine,.Plugins,context.temp_allocator),"terrain")
    test_plugin(t,folder_path(engine,.Plugins,context.temp_allocator),"idle")
    test_plugin(t,folder_path(root,.Plugins,context.temp_allocator),"rivers",{"terrain"})
    test_project(t,root,"rivers")

    p,error:=open(root,engine)
    defer close(&p)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,len(p.plugins),3)
    testing.expect_value(t,active_names(&p),"terrain rivers")
    testing.expect_value(t,p.engine_root,engine)
    if index,found:=plugin_find(p.plugins,"terrain");testing.expect(t,found) {
        testing.expect_value(t,p.plugins[index].origin,Origin.Engine)
        testing.expect_value(t,p.plugins[index].folder,path(engine,"plugins","terrain",allocator=context.temp_allocator))
    }

    // Without an engine the dependency has no folder.
    alone,alone_error:=open(root)
    testing.expect_value(t,alone_error.code,Error_Code.Dependency_Missing)
    testing.expect_value(t,base.text_get(alone_error.plugin[:]),"rivers")
    testing.expect_value(t,base.text_get(alone_error.subject[:]),"terrain")
    testing.expect_value(t,len(alone.plugins),0)

    // A project cannot have a plugin named as one of the engine.
    test_plugin(t,folder_path(root,.Plugins,context.temp_allocator),"idle")
    _,error=open(root,engine)
    testing.expect_value(t,error.code,Error_Code.Plugin_Repeated)
    testing.expect_value(t,base.text_get(error.subject[:]),"idle")
}

@(test)
plugins_that_cannot_be_ordered_or_found_are_errors :: proc(t:^testing.T) {
    root:=base.test_folder(t,"project")
    plugins:=folder_path(root,.Plugins,context.temp_allocator)
    _,error:=open(root)
    testing.expect_value(t,error.code,Error_Code.Not_Found)

    test_project(t,root,"ghost")
    _,error=open(root)
    testing.expect_value(t,error.code,Error_Code.Plugin_Missing)
    testing.expect_value(t,base.text_get(error.subject[:]),"ghost")

    test_plugin(t,plugins,"a",{"b"})
    test_plugin(t,plugins,"b",{"c"})
    test_plugin(t,plugins,"c",{"a"})
    test_project(t,root,"a")
    _,error=open(root)
    testing.expect_value(t,error.code,Error_Code.Dependency_Cycle)
    testing.expect_value(t,base.text_get(error.plugin[:]),"c")
    testing.expect_value(t,base.text_get(error.subject[:]),"a")

    // A cycle nobody activates is not an error of this project.
    test_plugin(t,plugins,"d")
    test_project(t,root,"d")
    p,ok_error:=open(root)
    testing.expect_value(t,ok_error.code,Error_Code.None)
    testing.expect_value(t,active_names(&p),"d")
    close(&p)

    test_plugin(t,plugins,"c",{"missing"})
    test_project(t,root,"a")
    _,error=open(root)
    testing.expect_value(t,error.code,Error_Code.Dependency_Missing)
    testing.expect_value(t,base.text_get(error.plugin[:]),"c")
    testing.expect_value(t,base.text_get(error.subject[:]),"missing")
}

// An automatic plugin is active exactly when all its dependencies are, after
// them, and one that joins can complete the dependencies of another. A project
// does not name one.
@(test)
an_automatic_plugin_joins_when_its_dependencies_are_active :: proc(t:^testing.T) {
    root:=base.test_folder(t,"project")
    plugins:=folder_path(root,.Plugins,context.temp_allocator)
    test_plugin(t,plugins,"simulation")
    test_plugin(t,plugins,"network")
    test_plugin(t,plugins,"fracture",{"simulation"})
    test_plugin(t,plugins,"simulation_network",{"simulation","network"},automatic=true)
    test_plugin(t,plugins,"fracture_network",{"fracture","simulation_network"},automatic=true)
    open_names :: proc(t:^testing.T,root:string,names:..string) -> string {
        test_project(t,root,..names)
        p,error:=open(root)
        defer close(&p)
        testing.expect_value(t,error.code,Error_Code.None)
        return strings.clone(active_names(&p),context.temp_allocator)
    }
    testing.expect_value(t,open_names(t,root,"simulation"),"simulation")
    testing.expect_value(t,open_names(t,root,"network"),"network")
    testing.expect_value(t,open_names(t,root,"simulation","network"),"simulation network simulation_network")
    testing.expect_value(t,open_names(t,root,"fracture","network"),"simulation fracture network simulation_network fracture_network")
    testing.expect_value(t,open_names(t,root,"fracture"),"simulation fracture")

    test_project(t,root,"simulation","simulation_network")
    _,error:=open(root)
    testing.expect_value(t,error.code,Error_Code.Automatic_Named)
    testing.expect_value(t,base.text_get(error.subject[:]),"simulation_network")

    m:Plugin_Manifest
    base.text_set(m.name[:],"bridge")
    base.text_set(m.version[:],"1.0.0")
    m.automatic=true
    testing.expect_value(t,plugin_validate(&m).code,Error_Code.Automatic_Alone)
    base.text_set(m.dependencies[0][:],"simulation")
    testing.expect_value(t,plugin_validate(&m).code,Error_Code.None)
    back,parse_error:=plugin_parse(plugin_text(&m,context.temp_allocator))
    testing.expect_value(t,parse_error.code,Error_Code.None)
    testing.expect(t,back.automatic)
}

@(test)
a_plugin_folder_has_to_match_its_manifest :: proc(t:^testing.T) {
    root:=base.test_folder(t,"project")
    plugins:=folder_path(root,.Plugins,context.temp_allocator)
    test_project(t,root)

    test_plugin(t,plugins,"renamed")
    testing.expect(t,os.rename(path(plugins,"renamed",allocator=context.temp_allocator),path(plugins,"moved",allocator=context.temp_allocator))==nil)
    _,error:=open(root)
    testing.expect_value(t,error.code,Error_Code.Folder_Mismatch)
    testing.expect_value(t,base.text_get(error.plugin[:]),"moved")
    testing.expect_value(t,base.text_get(error.subject[:]),"renamed")
    testing.expect(t,base.remove_all(path(plugins,"moved",allocator=context.temp_allocator))==nil)

    test_plugin(t,plugins,"partial",{},{.Runtime,.Editor})
    testing.expect(t,base.remove_all(path(plugins,"partial","editor",allocator=context.temp_allocator))==nil)
    _,error=open(root)
    testing.expect_value(t,error.code,Error_Code.Part_Missing)
    testing.expect_value(t,base.text_get(error.plugin[:]),"partial")
    testing.expect_value(t,base.text_get(error.subject[:]),"editor")

    testing.expect(t,os.make_directory_all(path(plugins,"partial","editor",allocator=context.temp_allocator))==nil)
    testing.expect(t,os.make_directory_all(path(plugins,"partial","shaders",allocator=context.temp_allocator))==nil)
    _,error=open(root)
    testing.expect_value(t,error.code,Error_Code.Part_Undeclared)
    testing.expect_value(t,base.text_get(error.subject[:]),"shaders")
    testing.expect(t,base.remove_all(path(plugins,"partial",allocator=context.temp_allocator))==nil)

    test_write(t,plugins,"broken",PLUGIN_FILE,text="{\n  \"name\": \"broken\",\n  \"version\": 1\n}")
    _,error=open(root)
    testing.expect_value(t,error.code,Error_Code.Text)
    testing.expect_value(t,error.text,serial.Text_Error_Code.Expected_Array)
    testing.expect_value(t,error.line,3)
    testing.expect_value(t,base.text_get(error.plugin[:]),"broken")
}

@(test)
a_file_where_the_plugins_folder_goes_is_a_project_without_plugins :: proc(t:^testing.T) {
    root:=base.test_folder(t,"project")
    test_project(t,root)
    test_write(t,root,"plugins",text="not a folder")
    p,error:=open(root)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,len(p.plugins),0)
    close(&p)
}

@(test)
a_plugin_of_the_project_brings_its_companions :: proc(t:^testing.T) {
    root:=base.test_folder(t,"project")
    engine:=base.test_folder(t,"project")
    plugins:=folder_path(root,.Plugins,context.temp_allocator)
    companions:=path(plugins,"unreal",PLUGIN_COMPANIONS,allocator=context.temp_allocator)
    test_plugin(t,folder_path(engine,.Plugins,context.temp_allocator),"terrain")
    test_plugin(t,plugins,"unreal")
    test_plugin(t,companions,"unreal_terrain",{"unreal","terrain"},automatic=true)
    // A companion has none of its own.
    test_plugin(t,path(companions,"unreal_terrain",PLUGIN_COMPANIONS,allocator=context.temp_allocator),"deeper")
    test_project(t,root,"unreal","terrain")

    p,error:=open(root,engine)
    defer close(&p)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,active_names(&p),"unreal terrain unreal_terrain")
    if index,found:=plugin_find(p.plugins,"unreal_terrain");testing.expect(t,found) {
        testing.expect_value(t,p.plugins[index].folder,path(companions,"unreal_terrain",allocator=context.temp_allocator))
    }
    _,deeper:=plugin_find(p.plugins,"deeper")
    testing.expect(t,!deeper)
    testing.expect_value(t,import_plugin("project:plugins/unreal/plugins/unreal_terrain/editor/map"),"unreal_terrain")
    testing.expect_value(t,import_plugin("project:plugins/unreal/editor/level"),"unreal")
    testing.expect_value(t,import_plugin("plugins:terrain/runtime"),"terrain")

    // A companion named as another plugin of the project.
    test_plugin(t,plugins,"unreal_terrain")
    _,error=open(root,engine)
    testing.expect_value(t,error.code,Error_Code.Plugin_Repeated)
    testing.expect_value(t,base.text_get(error.subject[:]),"unreal_terrain")
}

// What ordering the plugins asks its allocator for, with the memory ending
// at each request in turn: Out_Of_Memory with no order and a text that says
// so, nothing left allocated, and with memory enough the order. And the merge
// of the settings, whose fields are in the temporary allocator: without
// memory for one it is Out_Of_Memory, and with memory enough the merged text.
@(test)
plugins_order_without_memory_fails_whole :: proc(t:^testing.T) {
    Limit :: struct {owner:runtime.Allocator,remaining:int}
    limit_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        limit:=(^Limit)(data)
        if size>0 && (mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed) {
            if limit.remaining<=0 {return nil,.Out_Of_Memory}
            limit.remaining-=1
        }
        return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
    }
    plugins:=make([]Plugin,3,context.temp_allocator)
    for name,i in ([]string{"noise","terrain","water"}) {base.text_set(plugins[i].manifest.name[:],name)}
    base.text_set(plugins[1].manifest.dependencies[0][:],"noise")
    base.text_set(plugins[2].manifest.dependencies[0][:],"terrain")
    Case :: struct {wanted:[]string,order:[]int}
    cases:=[]Case{{{"water"},{0,1,2}},{{"terrain","noise"},{0,1}},{{},{}}}
    for c in cases {
        done,refused:=false,false
        for served in 0..<8 {
            tracking:mem.Tracking_Allocator
            mem.tracking_allocator_init(&tracking,context.allocator)
            limit:=Limit{owner=mem.tracking_allocator(&tracking),remaining=served}
            order,error:=plugins_order(plugins,c.wanted,{limit_proc,&limit})
            if done=error.code==.None;done {
                testing.expectf(t,slice.equal(order,c.order),"%v: ordered %v",c.wanted,order)
            } else {
                refused=true
                testing.expectf(t,error.code==.Out_Of_Memory && order==nil,"%v with %d requests served: %v",c.wanted,served,error.code)
                testing.expect(t,strings.contains(error_text("project",error,context.temp_allocator),"memory"))
            }
            delete(order,mem.tracking_allocator(&tracking))
            testing.expectf(t,len(tracking.allocation_map)==0,"%v with %d requests served: %d left allocated",c.wanted,served,len(tracking.allocation_map))
            mem.tracking_allocator_destroy(&tracking)
            if done {break}
        }
        testing.expectf(t,done && refused,"%v: refused without memory, and with it it goes through",c.wanted)
    }

    folder,_:=os.make_directory_temp("","mirai-settings",context.temp_allocator)
    defer base.remove_all(folder)
    root,engine:=path(folder,"project",allocator=context.temp_allocator),path(folder,"engine",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(root)==nil && os.make_directory_all(path(engine,".mirai",allocator=context.temp_allocator))==nil)
    testing.expect(t,os.write_entire_file(settings_file(.Engine,root,engine,context.temp_allocator),`{"version": 3, "Sample": {"count": 2, "inner": {"level": 3}}}`)==nil)
    testing.expect(t,os.write_entire_file(settings_file(.Project,root,engine,context.temp_allocator),`{"Sample": {"count": 7, "inner": {"on": true}}, "Plugin": {"y": "z"}}`)==nil)
    whole,whole_error,_:=settings_merge(root,engine,{"Sample"})
    defer delete(whole)
    testing.expect_value(t,whole_error.code,Error_Code.None)
    merged,no_field:=false,false
    for served:=0;!merged && served<512;served+=1 {
        limit:=Limit{owner=context.temp_allocator,remaining=served}
        text:string
        error:Error
        {
            context.temp_allocator={limit_proc,&limit}
            text,error,_=settings_merge(root,engine,{"Sample"})
        }
        merged=error.code==.None && text==whole
        no_field||=error.code==.Out_Of_Memory
        delete(text)
    }
    testing.expect(t,merged && no_field,"a merge without memory for a field says so, and with memory it is whole")
}
