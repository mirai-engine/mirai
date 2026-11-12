package editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import "mirai:std/base"
import "mirai:ui"

@(private)
CONTENT_TEST_PLUGIN_KIND :: asset.Fourcc(u32('C')|u32('H')<<8|u32('A')<<16|u32('R')<<24)
@(private)
CONTENT_TEST_WIDTH :: f32(304)

@(private)
content_test_registry :: proc() -> asset.Registry {
    files:=make([dynamic]asset.Registry_File)
    append(&files,
        asset.Registry_File{path="Animations/run.character",state=.Asset,kind=CONTENT_TEST_PLUGIN_KIND,id={1,9}},
        asset.Registry_File{path="Animations/walk.anim",state=.Asset,kind=asset.KIND_ANIMATION,id={1,1}},
        asset.Registry_File{path="Materials/red.mat",state=.Asset,kind=asset.KIND_MATERIAL,id={1,2}},
        asset.Registry_File{path="Meshes/box.mesh",state=.Asset,kind=asset.KIND_MESH,id={1,3}},
        asset.Registry_File{path="Meshes/nested/sphere.mesh",state=.Asset,kind=asset.KIND_MESH,id={1,4}},
        asset.Registry_File{path="Prefabs/robot.scene",state=.Asset,kind=asset.KIND_SCENE,flags={.Prefab},id={1,5}},
        asset.Registry_File{path="Sounds/hit.sound",state=.Asset,kind=asset.KIND_SOUND,id={1,6}},
        asset.Registry_File{path="Textures/color.tex",state=.Asset,kind=asset.KIND_TEXTURE,id={1,7}},
        asset.Registry_File{path="UI/hud.ui",state=.Asset,kind=asset.KIND_UI,id={1,8}},
    )
    // Sorted by path and found by id, as a scan leaves a registry.
    registry:=asset.Registry{files=files,allocator=context.allocator}
    for file,at in registry.files {registry.by_id[file.id]=u32(at)}
    return registry
}

// A wall to walk: a folder of a full row, a smaller one, a file right in a
// first-level folder and one at the root.
@(private)
content_test_wall_registry :: proc() -> asset.Registry {
    files:=make([dynamic]asset.Registry_File)
    append(&files,
        asset.Registry_File{path="Castle/Props/barrel.mesh",state=.Asset,kind=asset.KIND_MESH,id={4,1}},
        asset.Registry_File{path="Castle/Props/crate.mesh",state=.Asset,kind=asset.KIND_MESH,id={4,2}},
        asset.Registry_File{path="Castle/Props/torch.mesh",state=.Asset,kind=asset.KIND_MESH,id={4,3}},
        asset.Registry_File{path="Castle/Props/wall.mesh",state=.Asset,kind=asset.KIND_MESH,id={4,4}},
        asset.Registry_File{path="Castle/Towers/big.mesh",state=.Asset,kind=asset.KIND_MESH,id={4,5}},
        asset.Registry_File{path="Castle/gate.mesh",state=.Asset,kind=asset.KIND_MESH,id={4,6}},
        asset.Registry_File{path="Levels/one.scene",state=.Asset,kind=asset.KIND_SCENE,id={4,7}},
        asset.Registry_File{path="rock.mesh",state=.Asset,kind=asset.KIND_MESH,id={4,8}},
    )
    registry:=asset.Registry{files=files,allocator=context.allocator}
    for file,at in registry.files {
        registry.by_id[file.id]=u32(at)
        registry.by_path[file.path]=u32(at)
    }
    return registry
}

// Frees what content_test_registry made: its paths are not its own.
@(private)
content_test_registry_free :: proc(r:^asset.Registry) {
    delete(r.files);delete(r.dependencies);delete(r.by_id);delete(r.by_path);delete(r.duplicates);delete(r.dependents);delete(r.dependent_files)
}

// Gives the file at at the dependencies, and each of them this file as a user.
@(private)
content_test_depends :: proc(r:^asset.Registry,at:int,uses:..int) {
    r.files[at].first_dependency=u32(len(r.dependencies))
    r.files[at].dependency_count=u32(len(uses))
    for used in uses {
        id:=r.files[used].id
        append(&r.dependencies,id)
        run:=r.dependents[id] or_else asset.Registry_Dependents{first=u32(len(r.dependent_files))}
        append(&r.dependent_files,u32(at))
        run.count+=1
        r.dependents[id]=run
    }
    r.revision+=1
}

@(private)
content_test_names :: proc(c:^Content,registry:^asset.Registry,lines:[]Content_Line) -> string {
    out:=make([dynamic]u8,context.temp_allocator)
    for line,i in lines {
        if i>0 {append(&out,' ')}
        switch line.kind {
        case .Header:    append(&out,..transmute([]u8)fmt.tprintf("[%s]",line.name))
        case .Subheader: append(&out,..transmute([]u8)fmt.tprintf("<%s>",line.name))
        case .Label:     append(&out,..transmute([]u8)fmt.tprintf("{{%s}}",line.name))
        case .Create:    append(&out,..transmute([]u8)fmt.tprintf("(%s)",string(c.create_name[:c.create_name_length])))
        case .Cards:
            for card,k in c.cards[line.first:][:line.count] {
                if k>0 {append(&out,',')}
                if card.file<0 {append(&out,'#')}
                append(&out,..transmute([]u8)card.name)
            }
        }
    }
    return string(out[:])
}

@(private)
content_test_hash :: proc(path:string) -> u64 {return base.hash64(transmute([]u8)path)}

// The lines of a frame of the browser: what it reads of the registry, then them.
@(private)
content_test_lines :: proc(c:^Content,registry:^asset.Registry,width:f32=CONTENT_TEST_WIDTH,opened:[]asset.Fourcc=nil,scene_kinds:[]asset.Fourcc=nil) -> []Content_Line {
    content_registry_read(c,registry,opened)
    if c.restore {content_navigation_restore(c,registry)}
    return content_lines(c,registry,width,opened,scene_kinds)
}

@(private)
content_test_show :: proc(c:^Content,registry:^asset.Registry,opened:[]asset.Fourcc=nil,scene_kinds:[]asset.Fourcc=nil) -> string {
    return content_test_names(c,registry,content_test_lines(c,registry,CONTENT_TEST_WIDTH,opened,scene_kinds))
}

// Names: the names of the first level stay above their assets; a subfolder
// of at least a row has a thin name and the smaller ones flow together. A
// click enters a folder: nothing folds in place.
@(test)
content_names_is_a_wall_under_the_names_of_the_folders :: proc(t:^testing.T) {
    registry:=content_test_wall_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    lines:=content_test_lines(&c,&registry)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"rock [Castle] gate <Props> barrel,crate,torch,wall big [Levels] one")
    testing.expect(t,lines[1].kind==.Header && c.heights[1]==CONTENT_HEADER && lines[3].kind==.Subheader && c.heights[3]==CONTENT_SUBHEADER)
    testing.expect(t,lines[2].parent==1 && lines[3].parent==1 && lines[4].parent==1 && lines[0].parent==-1 && lines[7].parent==6 && lines[6].parent==-1)
    // The columns decide what is a full row.
    c.view.columns=5
    testing.expect_value(t,content_test_show(&c,&registry),"rock [Castle] gate,barrel,crate,torch,wall big [Levels] one")
    c.view.columns=3
    testing.expect_value(t,content_test_show(&c,&registry),"rock [Castle] gate <Props> barrel,crate,torch wall big [Levels] one")
    c.view.columns=4
    // Lines are built once for the same inputs.
    cached:=raw_data(c.lines)
    testing.expect_value(t,raw_data(content_test_lines(&c,&registry)),cached)
    // A folded folder keeps its name and shows nothing of what it holds.
    content_fold_flip(&c,content_test_hash("Castle"))
    testing.expect_value(t,content_test_show(&c,&registry),"rock [Castle] [Levels] one")
    content_fold_flip(&c,content_test_hash("Castle"))
    // Entering a folder keeps where it was, and a folder holds folders and assets.
    content_enter(&c,.None,"Castle")
    testing.expect_value(t,content_test_show(&c,&registry),"gate [Props] barrel,crate,torch,wall [Towers] big")
    testing.expect_value(t,string(c.place[:c.place_length]),"Castle")
    content_enter(&c,.None,"Castle/Props")
    testing.expect_value(t,content_test_show(&c,&registry),"barrel,crate,torch,wall")
    content_back(&c)
    testing.expect_value(t,string(c.at.folder[:c.at.length]),"Castle")
    content_back(&c)
    testing.expect(t,c.at.length==0 && c.at.virtual==.None && len(c.history)==0)
    content_back(&c)
    testing.expect(t,c.at.length==0,"Back at the root stays there")
    // A folder is listed on its own run even with a name that sorts around it.
    content_enter(&c,.None,"Castle")
    content_enter(&c,.None,"Levels",reset=true)
    testing.expect(t,len(c.history)==0,"the root of the breadcrumb forgets the way")
}

// Tabs: chips of the first level, rows of the folders of the one chosen, and
// a grid of the folder chosen and everything under it.
@(test)
content_tabs_show_chips_of_the_folders_over_what_the_chosen_one_holds :: proc(t:^testing.T) {
    registry:=content_test_wall_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    c.view.arrangement=.Tabs
    testing.expect_value(t,content_test_show(&c,&registry),"barrel,crate,torch,wall big,gate,one,rock")
    testing.expect(t,len(c.tabs)==2 && c.tabs[0].path=="Castle" && c.tabs[1].row==0)
    content_enter(&c,.None,"Castle",reset=true)
    testing.expect_value(t,content_test_show(&c,&registry),"barrel,crate,torch,wall big,gate")
    rows:=make([dynamic]int,context.temp_allocator)
    for tab in c.tabs {append(&rows,tab.row)}
    testing.expect(t,slice.equal(rows[:],[]int{0,0,1,1}),"the folders of the one chosen in a row of their own")
    content_enter(&c,.None,"Castle/Props",reset=true)
    testing.expect_value(t,content_test_show(&c,&registry),"barrel,crate,torch,wall")
    testing.expect_value(t,len(c.tabs),4)
}

// Cards: folders are cells among the assets; subfolders first, Recent open at
// the root and the other virtual folders as cells.
@(test)
content_cards_put_the_folders_among_the_assets :: proc(t:^testing.T) {
    registry:=content_test_wall_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    c.view.arrangement=.Cards
    testing.expect_value(t,content_test_show(&c,&registry),"#Castle,#Levels,rock")
    testing.expect_value(t,c.cards[0].folder,"Castle")
    session:=Session{content=&c}
    content_used(&session,{4,8})
    content_used(&session,{4,6})
    content_favorite_toggle(&c,{4,1})
    lines:=content_test_lines(&c,&registry)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"{Recent} gate,rock #Favorites,#Castle,#Levels,rock")
    testing.expect_value(t,lines[0].kind,Content_Line_Kind.Label)
    content_enter(&c,.None,"Castle")
    testing.expect_value(t,content_test_show(&c,&registry),"#Props,#Towers,gate")
    content_enter(&c,.Recent)
    testing.expect_value(t,content_test_show(&c,&registry),"gate,rock")
}

// Recent, Favorites and Current scene are entered as folders; Current scene is
// what the scene references transitively, read when the registry changes.
@(test)
content_virtual_folders_are_entered_and_current_scene_is_what_the_scene_references :: proc(t:^testing.T) {
    registry:=content_test_wall_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    session:=Session{content=&c}
    content_used(&session,{4,8})
    content_favorite_toggle(&c,{4,2})
    // The scene uses the barrel, which uses the crate.
    content_test_depends(&registry,0,1)
    content_test_depends(&registry,6,0)
    content_scene_read(&c,&registry,registry.files[6].id)
    used:=raw_data(c.scene_used)
    testing.expect_value(t,len(c.scene_used),2)
    testing.expect_value(t,content_test_show(&c,&registry),"[Recent] rock [Current scene] barrel,crate [Favorites] crate rock [Castle] gate <Props> barrel,crate,torch,wall big [Levels] one")
    // A row of each at the root, with no more than the columns.
    c.view.columns=3
    content_favorite_toggle(&c,{4,3})
    content_favorite_toggle(&c,{4,4})
    content_favorite_toggle(&c,{4,5})
    lines:=content_test_lines(&c,&registry)
    header:=-1
    for line,i in lines {
        if line.kind==.Header && line.virtual==.Favorites {header=i;break}
    }
    testing.expect(t,header>=0 && lines[header+1].count==3 && lines[header+2].kind!=.Cards || lines[header+2].kind==.Cards && lines[header+2].parent!=i32(header),"one row")
    c.view.columns=4
    // Reading again without a change neither rebuilds nor moves the list.
    revision:=c.revision
    content_scene_read(&c,&registry,registry.files[6].id)
    testing.expect(t,c.revision==revision && raw_data(c.scene_used)==used)
    registry.revision+=1
    content_scene_read(&c,&registry,registry.files[6].id)
    testing.expect(t,c.revision>revision,"a change of the registry reads it again")
    // Entering one shows all of it.
    content_enter(&c,.Favorites)
    testing.expect_value(t,content_test_show(&c,&registry),"crate,torch,wall,big")
    content_enter(&c,.Scene)
    testing.expect_value(t,content_test_show(&c,&registry),"barrel,crate")
    // Used assets come first in Recent, once; a star keeps an asset in Favorites.
    c.marks={}
    content_used(&session,registry.files[0].id)
    content_used(&session,registry.files[3].id)
    content_used(&session,registry.files[0].id)
    testing.expect(t,c.marks.recent[0]==registry.files[0].id && c.marks.recent[1]==registry.files[3].id && c.marks.recent[2]=={})
    content_favorite_toggle(&c,registry.files[3].id)
    content_favorite_toggle(&c,registry.files[4].id)
    content_favorite_toggle(&c,registry.files[3].id)
    testing.expect(t,c.marks.favorites[0]==registry.files[4].id && c.marks.favorites[1]=={} && content_favorite(&c.marks,registry.files[4].id))
    for i in 0..<CONTENT_RECENT+3 {content_used(&session,{9,u64(i)})}
    testing.expect_value(t,c.marks.recent[0],base.Asset_Id{9,CONTENT_RECENT+2})
}

// What a scene makes of itself shows only with the Plugins filter or a search;
// every plugin kind wears the same color.
@(test)
content_hides_what_a_scene_makes_of_itself_and_colors_every_plugin_kind_alike :: proc(t:^testing.T) {
    registry:=content_test_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    kinds:=[]asset.Fourcc{CONTENT_TEST_PLUGIN_KIND}
    content_enter(&c,.None,"Animations")
    testing.expect_value(t,content_test_show(&c,&registry,kinds),"run,walk")
    testing.expect_value(t,content_test_show(&c,&registry,kinds,kinds),"walk")
    c.category=.Plugin
    c.revision+=1
    testing.expect_value(t,content_test_show(&c,&registry,kinds,kinds),"run")
    c.category=.None
    c.filter_length=copy(c.filter[:],"run")
    testing.expect_value(t,content_test_show(&c,&registry,kinds,kinds),"run")
    c.filter_length=0
    session:Session
    session.providers.library=session.library_generation+1
    session.providers.kinds[0]={kind=CONTENT_TEST_PLUGIN_KIND,color={1,2,3,255}}
    session.providers.kind_count=1
    testing.expect_value(t,asset_kind_color(&session,CONTENT_TEST_PLUGIN_KIND),CONTENT_PLUGIN_COLOR)
    testing.expect_value(t,asset_kind_color(&session,asset.KIND_MESH),asset_color(asset.KIND_MESH))
}

// The filters of kinds take what they name, and Only unused what nothing uses.
@(test)
content_filters_keep_the_folders_of_what_they_take :: proc(t:^testing.T) {
    registry:=content_test_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    kinds:=[]asset.Fourcc{CONTENT_TEST_PLUGIN_KIND}
    c.category=.Mesh
    testing.expect_value(t,content_test_show(&c,&registry),"[Meshes] box,sphere")
    c.category=.Plugin
    testing.expect_value(t,content_test_show(&c,&registry,kinds),"[Animations] run")
    c.category=.None
    ui_category,_:=content_category(asset.KIND_UI)
    testing.expect_value(t,ui_category,Content_Category.Ui)
    skeleton_category,_:=content_category(asset.KIND_SKELETON)
    testing.expect_value(t,skeleton_category,Content_Category.Mesh)
    plugin_category,engine:=content_category(CONTENT_TEST_PLUGIN_KIND)
    testing.expect(t,!engine && plugin_category==.Plugin)
    // Only unused: what no asset references, never a scene.
    content_test_depends(&registry,5,3)
    c.unused=true
    testing.expect_value(t,content_test_show(&c,&registry),"[Animations] walk [Materials] red [Meshes] sphere [Prefabs] robot [Sounds] hit [Textures] color [UI] hud")
}

// The selection toggle shows what the selection holds and what that uses,
// with the parts of an import among them.
@(test)
content_selection_toggle_shows_what_the_selection_uses :: proc(t:^testing.T) {
    registry:=content_test_parts_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    content_test_depends(&registry,5,2)
    content_test_depends(&registry,2,0)
    c.selection_only=true
    content_selection_set(&c,&registry,{CONTENT_TEST_ROBOT,{77,77}})
    testing.expect_value(t,content_test_show(&c,&registry),"[Robot] MI_Robot_01,SKM_Robot,robot")
    content_selection_set(&c,&registry,{})
    testing.expect_value(t,len(content_test_lines(&c,&registry)),0)
    c.category=.Mesh
    content_filters_clear(&c)
    testing.expect(t,c.category==.None && !c.selection_only)
    testing.expect_value(t,content_test_show(&c,&registry),"[Robot] MI_Shared,robot [Spider] spider [Stray] orphan")
}

// A search lists the results of the folder shown flat, best first, and Enter
// takes the first.
@(test)
content_search_ranks_results_of_the_folder_shown :: proc(t:^testing.T) {
    files:=make([dynamic]asset.Registry_File)
    append(&files,
        asset.Registry_File{path="box.mesh",state=.Asset,kind=asset.KIND_MESH,id={5,1}},
        asset.Registry_File{path="box/zed.mesh",state=.Asset,kind=asset.KIND_MESH,id={5,2}},
        asset.Registry_File{path="red_box.mesh",state=.Asset,kind=asset.KIND_MESH,id={5,3}},
        asset.Registry_File{path="xboxy.mesh",state=.Asset,kind=asset.KIND_MESH,id={5,4}},
    )
    registry:=asset.Registry{files=files}
    defer content_test_registry_free(&registry)
    for file,at in registry.files {registry.by_id[file.id]=u32(at)}
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    c.filter_length=copy(c.filter[:],"BOX")
    testing.expect_value(t,content_test_show(&c,&registry),"box,red_box,xboxy,zed")
    c.filter_length=copy(c.filter[:],"red box")
    testing.expect_value(t,content_test_show(&c,&registry),"red_box")
    c.filter_length=copy(c.filter[:],"box")
    content_enter(&c,.None,"box")
    testing.expect_value(t,content_test_show(&c,&registry),"zed")
    c.filter_length=copy(c.filter[:],"   ")
    testing.expect_value(t,content_test_show(&c,&registry),"zed")
}

// Alt+click and the menu walk what an asset uses and what uses it.
@(test)
content_relations_show_what_an_asset_uses_and_what_uses_it :: proc(t:^testing.T) {
    registry:=content_test_wall_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    content_test_depends(&registry,0,1)
    content_test_depends(&registry,6,0)
    content_relations_open(&c,registry.files[0].id)
    lines:=content_test_lines(&c,&registry)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"{Uses} crate {Used by} one")
    testing.expect(t,lines[1].group==CONTENT_USES_GROUP && lines[3].group==CONTENT_USERS_GROUP)
    content_relations_open(&c,registry.files[0].id)
    testing.expect_value(t,len(c.trail),1)
    content_relations_open(&c,registry.files[1].id)
    testing.expect_value(t,content_test_show(&c,&registry),"{Used by} barrel")
    content_back(&c)
    testing.expect_value(t,content_test_show(&c,&registry),"{Uses} crate {Used by} one")
    content_back(&c)
    testing.expect_value(t,len(c.trail),0)
    // Entering a folder leaves the relations.
    content_relations_open(&c,registry.files[0].id)
    content_enter(&c,.None,"Levels")
    testing.expect(t,len(c.trail)==0 && c.at.length>0)
}

@(test)
ctrl_or_shift_add_an_asset_to_the_selection_or_take_it_away :: proc(t:^testing.T) {
    c:Content
    defer core.value_free(&c,type_info_of(Content))
    a,b,d:=base.Asset_Id{1,1},base.Asset_Id{1,2},base.Asset_Id{1,3}
    content_select(&c,a,false)
    content_select(&c,b,true)
    content_select(&c,d,true)
    testing.expect(t,c.selected==d && content_selected(&c,a) && content_selected(&c,b) && content_selected_count(&c)==3)
    // Taking the last clicked away leaves the one added before it.
    content_select(&c,d,true)
    testing.expect(t,c.selected==b && !content_selected(&c,d) && content_selected_count(&c)==2)
    content_select(&c,a,true)
    testing.expect(t,c.selected==b && !content_selected(&c,a) && content_selected_count(&c)==1)
    content_unselect(&c,b)
    testing.expect(t,c.selected=={} && content_selected_count(&c)==0)
    content_select(&c,a,true)
    content_select(&c,b,true)
    content_select(&c,d,false)
    testing.expect(t,c.selected==d && content_selected_count(&c)==1,"A click alone selects it alone")
}

@(test)
content_lines_follow_registry_revisions_when_storage_and_count_are_reused :: proc(t:^testing.T) {
    root:=base.test_folder(t,"content-registry")
    if root=="" {return}
    path:=fmt.tprintf("%s/.index",root)
    source:=content_test_registry()
    defer content_test_registry_free(&source)
    source.allocator=context.allocator
    if !testing.expect(t,asset.registry_save(&source,path)) {return}
    registry:asset.Registry
    asset.registry_init(&registry,root)
    defer asset.registry_destroy(&registry)
    resize(&registry.files,len(source.files))
    testing.expect_value(t,asset.registry_load(&registry,path),asset.Error.None)
    c:=Content{category=.Mesh,view=CONTENT_VIEW_DEFAULT}
    defer core.value_free(&c,type_info_of(Content))
    c.selected=source.files[3].id
    testing.expect_value(t,content_test_show(&c,&registry),"[Meshes] box,sphere")
    files,count,revision:=raw_data(registry.files),len(registry.files),registry.revision
    source.files[3].path="Meshes/bar_box.mesh"
    source.files[4].path="Meshes/renamed/round_sphere.mesh"
    testing.expect(t,asset.registry_save(&source,path))
    testing.expect_value(t,asset.registry_load(&registry,path),asset.Error.None)
    testing.expect(t,raw_data(registry.files)==files && len(registry.files)==count)
    testing.expect_value(t,registry.revision,revision+1)
    testing.expect_value(t,content_test_show(&c,&registry),"[Meshes] bar_box,round_sphere")
    testing.expect_value(t,c.selected,source.files[3].id)
    cached:=raw_data(c.lines)
    testing.expect_value(t,raw_data(content_test_lines(&c,&registry)),cached)
    testing.expect_value(t,asset.registry_scan(&registry),asset.Error.None)
    testing.expect_value(t,registry.revision,revision+2)
    testing.expect_value(t,len(content_test_lines(&c,&registry)),0)
}

@(private)
content_test_frame :: proc(s:^Session,input:ui.Input,content_view:bool=true) -> ui.Frame {
    ctx:=s.gui.ctx
    ui.frame_begin(ctx,input)
    ui.id_push(ctx,ui.Id(100))
    if ui.box(ctx,{width=ui.fixed(CONTENT_TEST_WIDTH),height=ui.fixed(420),direction=.Column,gap=6}) {
        // The gear of the header of the panel, which the shell builds.
        content_settings_button(s,ui.id(ctx,"content_settings_open"),PANEL_HEADER)
        content_build(s,core.World_Ref{},388,CONTENT_TEST_WIDTH)
        content_settings_build(s,content_view)
    }
    ui.id_pop(ctx)
    return ui.frame_end(ctx)
}

@(private)
content_test_click :: proc(t:^testing.T,s:^Session,id:ui.Id,content_view:bool=true,clicks:u8=1,modifiers:ui.Modifiers={}) {
    rect,found:=ui.widget_rect(s.gui.ctx,id)
    testing.expect(t,found)
    if !found {return}
    for phase in 0..<3 {
        input:=ui.Input{size={800,600},pointer=ui.rect_center(rect),modifiers=modifiers}
        if phase==1 {input.down,input.pressed,input.clicks={.Left},{.Left},clicks}
        if phase==2 {input.released={.Left}}
        frame:=content_test_frame(s,input,content_view)
        testing.expect(t,!frame.overflow)
        testing.expect_value(t,s.gui.ctx.stats.layout_errors,u32(0))
    }
}

// A click at the middle of a rect, where no widget may be.
@(private)
content_test_click_at :: proc(t:^testing.T,s:^Session,rect:ui.Rect,modifiers:ui.Modifiers={}) {
    for phase in 0..<3 {
        input:=ui.Input{size={800,600},pointer=ui.rect_center(rect),modifiers=modifiers}
        if phase==1 {input.down,input.pressed,input.clicks={.Left},{.Left},1}
        if phase==2 {input.released={.Left}}
        _=content_test_frame(s,input)
        testing.expect_value(t,s.gui.ctx.stats.layout_errors,u32(0))
    }
}

@(private)
content_test_still :: proc(s:^Session,content_view:bool=true) {_=content_test_frame(s,{size={800,600},pointer_absent=true},content_view)}

@(test)
content_browser_enters_folders_selects_drags_stars_filters_and_searches_from_the_keyboard :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    assets:=host.Assets{registry=content_test_registry(),indexed=true}
    defer content_test_registry_free(&assets.registry)
    app:=host.App{assets=&assets}
    g:=Editor_Ui{ctx=&ctx}
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    selection:history.Selection
    info:core.World_Info
    session:=Session{app=&app,gui=&g,content=&c,selection=&selection,info=&info,headless=true}
    for _ in 0..<3 {
        frame:=content_test_frame(&session,{size={800,600},pointer_absent=true})
        testing.expect(t,!frame.overflow)
        testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    }
    folder:=ui.id_derive(&ctx,100,"content_folder",int(content_test_hash("Meshes")))
    rect,found:=ui.widget_rect(&ctx,folder)
    testing.expectf(t,found && rect.w==CONTENT_TEST_WIDTH && rect.h==CONTENT_HEADER,"%v",rect)
    content_test_click(t,&session,folder)
    testing.expect_value(t,string(c.at.folder[:c.at.length]),"Meshes")
    content_test_still(&session)
    asset_id:=assets.registry.files[3].id
    entry:=ui.id_derive(&ctx,100,"content_entry",int(content_test_hash(assets.registry.files[3].path)))
    rect,found=ui.widget_rect(&ctx,entry)
    _,cell:=content_cells(c.view,CONTENT_TEST_WIDTH)
    names:=u8(2)
    for line in c.lines {
        if line.kind!=.Cards {continue}
        for card in c.cards[line.first:][:line.count] {if card.file==3 {names=line.names}}
    }
    // The layout puts edges on whole pixels: a size moves by one at most.
    testing.expectf(t,found && abs(rect.w-cell)<=1 && abs(rect.h-content_card_height(c.view,cell,names))<=1,"%v",rect)
    content_test_click(t,&session,entry)
    testing.expect_value(t,c.selected,asset_id)
    testing.expect(t,g.drag.kind==.Asset && g.drag.asset_id==asset_id)
    g.drag={}
    // Ctrl+click adds a card to the selection, and takes it away again.
    content_enter(&c,.None,"Materials")
    content_test_still(&session)
    material:=ui.id_derive(&ctx,100,"content_entry",int(content_test_hash(assets.registry.files[2].path)))
    content_test_click(t,&session,material,modifiers={.Primary})
    testing.expect(t,c.selected==assets.registry.files[2].id && content_selected(&c,asset_id) && content_selected_count(&c)==2 && g.drag.kind==.None)
    content_test_click(t,&session,material,modifiers={.Shift})
    testing.expect(t,c.selected==asset_id && content_selected_count(&c)==1)
    content_enter(&c,.None,"Meshes")
    content_test_still(&session)
    rect,_=ui.widget_rect(&ctx,entry)
    // The star of a card under the pointer marks it.
    star:=ui.id_derive(&ctx,100,"content_star",int(content_test_hash(assets.registry.files[3].path)))
    _=content_test_frame(&session,{size={800,600},pointer=ui.rect_center(rect)})
    content_test_click(t,&session,star)
    testing.expect(t,content_favorite(&c.marks,asset_id))
    // A bar of the strip takes one family; another takes its place, and the
    // one on turns off. Every family has its bar.
    bar :: proc(ctx:^ui.Context,category:Content_Category) -> ui.Id {return ui.id_derive(ctx,100,"content_category",int(category)+1)}
    content_test_click(t,&session,bar(&ctx,.Mesh))
    testing.expect_value(t,c.category,Content_Category.Mesh)
    content_test_click(t,&session,bar(&ctx,.Material))
    testing.expect_value(t,c.category,Content_Category.Material)
    content_test_click(t,&session,bar(&ctx,.Material))
    testing.expect_value(t,c.category,Content_Category.None)
    for category in CONTENT_STRIP_CATEGORIES {
        content_test_click(t,&session,bar(&ctx,category))
        testing.expect_value(t,c.category,category)
    }
    content_test_click(t,&session,bar(&ctx,.Plugin))
    testing.expect_value(t,c.category,Content_Category.None)
    content_test_still(&session)
    // Choosing the tab gives the keyboard to the search; what is typed over a
    // card searches too.
    c.focus_search=true
    content_test_still(&session)
    filter:=ui.id_derive(&ctx,100,"content_filter")
    testing.expect_value(t,ctx.edit.id,filter)
    ctx.edit={}
    ui.focus_set(&ctx,entry)
    content_test_still(&session)
    testing.expect_value(t,c.card_focus,entry)
    typed:=ui.Input{size={800,600},pointer_absent=true}
    typed.text_count=copy(typed.text[:],"bo")
    _=content_test_frame(&session,typed)
    testing.expect_value(t,string(c.filter[:c.filter_length]),"bo")
    content_test_still(&session)
    testing.expect_value(t,ctx.edit.id,filter)
    ctx.edit={}
    c.filter_length=0
    // Once the browser is not built, or a press goes to what is under the UI,
    // letters are shortcuts again.
    ui.focus_set(&ctx,entry)
    content_test_still(&session)
    for built in ([]bool{true,false}) {
        ui.frame_begin(&ctx,typed)
        testing.expect_value(t,content_typing(&c,&ctx),built)
        _=ui.frame_end(&ctx)
    }
    content_test_still(&session)
    pressed:=ui.Input{size={800,600},pointer={790,590},down={.Left},pressed={.Left},clicks=1}
    _=content_test_frame(&session,pressed)
    testing.expect(t,ctx.focus==0 && c.card_focus==0)
    _=content_test_frame(&session,{size={800,600},pointer={790,590},released={.Left}})
    // The gear: the layout is a choice that keeps the menu open; Only unused filters.
    content_test_still(&session)
    content_test_click(t,&session,ui.id_derive(&ctx,100,"content_settings_open"))
    popup:=content_settings_popup(&g)
    content_test_still(&session)
    content_test_click(t,&session,ui.id_derive(&ctx,popup,"layout",int(Content_Arrangement.Tabs)+1))
    testing.expect(t,c.view.arrangement==.Tabs && ui.popup_is_open(&ctx,popup))
    content_test_click(t,&session,ui.id_derive(&ctx,popup,"layout",int(Content_Arrangement.Names)+1))
    content_test_click(t,&session,ui.id_derive(&ctx,popup,"unused"))
    testing.expect(t,c.unused && !ui.popup_is_open(&ctx,popup))
    c.unused=false
    // Shown from a field of Details: the search empties, its folder is entered
    // if it is not in sight and it is selected with the keyboard.
    c.selected={}
    c.filter_length=copy(c.filter[:],"robot")
    session.ai=new(Ai)
    defer free(session.ai)
    content_reveal(&session,assets.registry.files[4].id)
    testing.expect(t,c.filter_length==0 && !c.focus_search)
    content_test_still(&session)
    testing.expect(t,c.selected==assets.registry.files[4].id && c.reveal=={} && string(c.at.folder[:c.at.length])=="Meshes")
    testing.expect_value(t,ctx.focus,ui.id_derive(&ctx,100,"content_entry",int(content_test_hash(assets.registry.files[4].path))))
    testing.expect(t,ctx.edit.id==0 && c.filter_length==0)
    // Without assets the browser is still built and the gear still answers.
    app.assets=nil
    content_test_still(&session)
    content_test_click(t,&session,ui.id_derive(&ctx,100,"content_settings_open"))
    testing.expect(t,ui.popup_is_open(&ctx,popup))
}

// Enter arms the first result, the back row walks the way (always there in
// Cards), the mouse button goes back and Alt+click opens the relations without carrying the asset.
@(test)
content_navigation_gestures_of_the_browser :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    assets:=host.Assets{registry=content_test_wall_registry(),indexed=true}
    defer content_test_registry_free(&assets.registry)
    app:=host.App{assets=&assets}
    g:=Editor_Ui{ctx=&ctx}
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    selection:history.Selection
    info:core.World_Info
    session:=Session{app=&app,gui=&g,content=&c,selection=&selection,info=&info,headless=true}
    content_test_depends(&assets.registry,0,1)
    for _ in 0..<2 {content_test_still(&session)}
    // No back row at the root; entering shows it.
    back:=ui.id_derive(&ctx,100,"content_back")
    _,shown:=ui.widget_rect(&ctx,back)
    testing.expect(t,!shown)
    content_test_click(t,&session,ui.id_derive(&ctx,100,"content_folder",int(content_test_hash("Castle"))))
    testing.expect_value(t,string(c.at.folder[:c.at.length]),"Castle")
    content_test_still(&session)
    props:=ui.id_derive(&ctx,100,"content_folder",int(content_test_hash("Castle/Props")))
    content_test_click(t,&session,props)
    testing.expect(t,string(c.at.folder[:c.at.length])=="Castle/Props" && len(c.history)==2)
    content_test_still(&session)
    // The crumb of the folder above enters it.
    content_test_click(t,&session,ui.id_derive(&ctx,100,"content_crumb",1))
    testing.expect_value(t,string(c.at.folder[:c.at.length]),"Castle")
    content_test_still(&session)
    content_test_click(t,&session,back)
    testing.expect_value(t,string(c.at.folder[:c.at.length]),"Castle/Props")
    content_test_still(&session)
    // The back button of the mouse, over the browser.
    root,_:=ui.widget_rect(&ctx,ui.id_derive(&ctx,100,"content_root"))
    _=content_test_frame(&session,{size={800,600},pointer=ui.rect_center(root),released={.Back}})
    testing.expect_value(t,string(c.at.folder[:c.at.length]),"Castle")
    content_test_still(&session)
    _=content_test_frame(&session,{size={800,600},pointer={790,590},released={.Back}})
    testing.expect_value(t,string(c.at.folder[:c.at.length]),"Castle")
    // The root of the breadcrumb goes home and forgets the way.
    content_test_still(&session)
    content_test_click(t,&session,ui.id_derive(&ctx,100,"content_crumb",0))
    testing.expect(t,c.at.length==0 && len(c.history)==0)
    // In Cards the row stays at the root too, with Project alone.
    c.view.arrangement=.Cards
    content_test_still(&session)
    _,shown=ui.widget_rect(&ctx,back)
    _,crumb:=ui.widget_rect(&ctx,ui.id_derive(&ctx,100,"content_crumb",1))
    testing.expect(t,shown && !crumb,"Cards keeps the back row at the root")
    c.view.arrangement=.Names
    // Alt+click walks the relations and carries nothing.
    content_enter(&c,.None,"Castle/Props")
    content_test_still(&session)
    barrel:=ui.id_derive(&ctx,100,"content_entry",int(content_test_hash("Castle/Props/barrel.mesh")))
    content_test_click(t,&session,barrel,modifiers={.Alt})
    testing.expect(t,len(c.trail)==1 && c.trail[0]==assets.registry.files[0].id && g.drag.kind==.None)
    content_test_still(&session)
    _,shown=ui.widget_rect(&ctx,back)
    testing.expect(t,shown,"the relations have a back row")
    content_test_click(t,&session,back)
    testing.expect_value(t,len(c.trail),0)
    // The menu shows an asset in its folder, out of the search that found it.
    content_enter(&c,.None,"",reset=true)
    c.filter_length=copy(c.filter[:],"crate")
    content_test_still(&session)
    crate:=ui.id_derive(&ctx,100,"content_entry",int(content_test_hash("Castle/Props/crate.mesh")))
    rect,found:=ui.widget_rect(&ctx,crate)
    if !testing.expect(t,found) {return}
    _=content_test_frame(&session,{size={800,600},pointer=ui.rect_center(rect),down={.Right},pressed={.Right}})
    _=content_test_frame(&session,{size={800,600},pointer=ui.rect_center(rect),released={.Right}})
    menu:=content_menu_id(&g)
    testing.expect(t,ui.popup_is_open(&ctx,menu))
    content_test_still(&session)
    content_test_click(t,&session,ui.id_derive(&ctx,menu,"show_in_folder"))
    testing.expect(t,c.filter_length==0 && string(c.at.folder[:c.at.length])=="Castle/Props")
    content_test_still(&session)
    testing.expect(t,c.selected==assets.registry.files[1].id && c.reveal=={})
    // Enter takes the first result of a search for placement, as a click does.
    viewport:=new(Viewport)
    defer free(viewport)
    session.viewport=viewport
    c.filter_length=copy(c.filter[:],"barrel")
    c.focus_search=true
    content_test_still(&session)
    _=content_test_frame(&session,{size={800,600},pointer_absent=true,keys_down={.Enter},keys_pressed={.Enter}})
    testing.expect(t,g.placement.active && g.placement.kind==.Asset && g.placement.asset_id==assets.registry.files[0].id)
}

// Each step of Ctrl+wheel changes the columns, and names go
// with five or fewer; below the most columns the grid is the list.
@(test)
the_zoom_of_the_browser_walks_columns_and_names_follow_it :: proc(t:^testing.T) {
    view:=CONTENT_VIEW_DEFAULT
    for level in 1..=CONTENT_LEVELS {
        content_level_set(&view,level)
        testing.expect_value(t,content_level(view),level)
        columns,cell:=content_cells(view,CONTENT_TEST_WIDTH)
        testing.expect_value(t,columns,CONTENT_COLUMNS_MAX-level+1)
        testing.expect(t,abs(cell*f32(columns)+f32(columns-1)*CONTENT_GAP-CONTENT_TEST_WIDTH)<0.01,"the cells and one point between them fill the width")
        testing.expect_value(t,content_shows_names(view),columns<=CONTENT_NAMED_COLUMNS)
        height:=content_card_height(view,cell)
        testing.expect_value(t,height==cell,columns>CONTENT_NAMED_COLUMNS)
    }
    content_zoom(&view,1)
    testing.expect_value(t,content_level(view),CONTENT_LEVELS)
    view=CONTENT_VIEW_DEFAULT
    content_zoom(&view,100)
    testing.expect_value(t,view.columns,CONTENT_COLUMNS_MIN)
    content_zoom(&view,-100)
    testing.expect_value(t,view.mode,Content_Mode.List)
    testing.expect(t,content_shows_names(view),"the list has names")
    content_zoom(&view,0.5)
    testing.expect(t,view.mode==.Grid && view.columns==CONTENT_COLUMNS_MAX,"Up from the list is the grid of the most columns")
    bad:=Content_View{columns=99}
    columns,_:=content_cells(bad,CONTENT_TEST_WIDTH)
    testing.expect_value(t,columns,CONTENT_COLUMNS_MAX)

    // In the browser Ctrl+wheel zooms.
    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    assets:=host.Assets{registry=content_test_registry(),indexed=true}
    defer content_test_registry_free(&assets.registry)
    app:=host.App{assets=&assets}
    g:=Editor_Ui{ctx=&ctx}
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    selection:history.Selection
    info:core.World_Info
    session:=Session{app=&app,gui=&g,content=&c,selection=&selection,info=&info,headless=true}
    for _ in 0..<2 {content_test_still(&session)}
    header,_:=ui.widget_rect(&ctx,ui.id_derive(&ctx,100,"content_folder",int(content_test_hash("Meshes"))))
    over:=ui.Input{size={800,600},pointer=ui.rect_center(header)}
    _=content_test_frame(&session,over)
    zoom:=over
    zoom.modifiers,zoom.wheel={.Primary},{0,2}
    _=content_test_frame(&session,zoom)
    testing.expect_value(t,c.view.columns,3)
    zoom.wheel={0,-10}
    _=content_test_frame(&session,zoom)
    testing.expect_value(t,c.view.mode,Content_Mode.List)
    _=content_test_frame(&session,over)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    // A cell without a name under the pointer has its preview, which takes no click.
    c.view.columns,c.view.mode=8,.Grid
    content_enter(&c,.None,"Meshes")
    content_test_still(&session)
    cell:=ui.id_derive(&ctx,100,"content_entry",int(content_test_hash(assets.registry.files[3].path)))
    cell_rect,cell_found:=ui.widget_rect(&ctx,cell)
    if !testing.expect(t,cell_found) {return}
    for _ in 0..<2 {_=content_test_frame(&session,{size={800,600},pointer=ui.rect_center(cell_rect)})}
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
    testing.expect_value(t,ctx.hot,cell)
}

@(test)
ctrl_and_the_wheel_over_create_resize_its_cards_with_those_of_the_browser :: proc(t:^testing.T) {
    view:=CONTENT_VIEW_DEFAULT
    _,cell:=content_cells(view,284)
    view.mode=.List
    content_zoom(&view,1)
    testing.expect(t,view.mode==.Grid && content_level(view)==1,"Up from the list Create and the browser are the grid of the most columns")

    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    app:host.App
    g:=Editor_Ui{ctx=&ctx}
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    selection:history.Selection
    engine,_:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    session:=Session{app=&app,gui=&g,content=&c,selection=&selection,headless=true,engine_root=engine}
    defer author.recipes_free(session.recipes)
    frame :: proc(s:^Session,input:ui.Input) {
        ui.frame_begin(s.gui.ctx,input)
        if ui.box(s.gui.ctx,{width=ui.fixed(284),height=ui.fixed(440),direction=.Column}) {create_build(s,core.World_Ref{},440,284)}
        _=ui.frame_end(s.gui.ctx)
    }
    for _ in 0..<2 {frame(&session,{size={800,600},pointer_absent=true})}
    card,found:=ui.widget_rect(&ctx,ui.id(&ctx,"card",CONTENT_TEST_CUBE+1))
    testing.expect(t,found && abs(card.w-cell)<=1,"A card of Create is a cell of the browser at its width, on whole pixels")
    over:=ui.Input{size={800,600},pointer=ui.rect_center(card)}
    frame(&session,over)
    zoom:=over
    zoom.modifiers,zoom.wheel={.Primary},{0,1}
    frame(&session,zoom)
    testing.expect(t,c.view.mode==.Grid && c.view.columns==3 && g.create_scroll==0,"The cells of the browser go a step and Create does not scroll")
    frame(&session,over)
    card,_=ui.widget_rect(&ctx,ui.id(&ctx,"card",CONTENT_TEST_CUBE+1))
    testing.expect(t,card.w>cell)
    testing.expect_value(t,ctx.stats.layout_errors,u32(0))
}

// The place of the cube among the cards of the editor.
@(private)
CONTENT_TEST_CUBE :: 7

@(private)
CONTENT_TEST_ROBOT :: base.Asset_Id{2,1}

// An imported model: its prefab owns its mesh, its skeleton, its atlas material
// and that material's texture; the material it shares with another import is of
// its own. A part whose owner is gone is of its own too.
@(private)
content_test_parts_registry :: proc() -> asset.Registry {
    files:=make([dynamic]asset.Registry_File)
    append(&files,
        asset.Registry_File{path="Robot/MI_Robot_01.mat",state=.Asset,kind=asset.KIND_MATERIAL,id={2,2},owner=CONTENT_TEST_ROBOT},
        asset.Registry_File{path="Robot/MI_Shared.mat",state=.Asset,kind=asset.KIND_MATERIAL,id={2,3}},
        asset.Registry_File{path="Robot/SKM_Robot.mesh",state=.Asset,kind=asset.KIND_MESH,id={2,4},owner=CONTENT_TEST_ROBOT},
        asset.Registry_File{path="Robot/SK_Robot.skeleton",state=.Asset,kind=asset.KIND_SKELETON,id={2,5},owner=CONTENT_TEST_ROBOT},
        asset.Registry_File{path="Robot/T_Robot_01_D.tex",state=.Asset,kind=asset.KIND_TEXTURE,id={2,6},owner=CONTENT_TEST_ROBOT},
        asset.Registry_File{path="Robot/robot.scene",state=.Asset,kind=asset.KIND_SCENE,flags={.Prefab},id=CONTENT_TEST_ROBOT},
        asset.Registry_File{path="Spider/spider.scene",state=.Asset,kind=asset.KIND_SCENE,flags={.Prefab},id={3,1}},
        asset.Registry_File{path="Stray/orphan.mesh",state=.Asset,kind=asset.KIND_MESH,id={4,1},owner={9,9}},
    )
    registry:=asset.Registry{files=files,allocator=context.allocator}
    for file,at in registry.files {registry.by_id[file.id]=u32(at)}
    return registry
}

@(test)
content_hides_the_parts_of_an_import_in_their_folder_and_a_prefab_opens_to_its_variants :: proc(t:^testing.T) {
    registry:=content_test_parts_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    // The atlas material, the mesh, the skeleton and the texture are parts;
    // the material two imports share and the part without its owner show.
    lines:=content_test_lines(&c,&registry)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"[Robot] MI_Shared,robot [Spider] spider [Stray] orphan")
    testing.expect(t,content_part(&registry,&registry.files[0]) && !content_part(&registry,&registry.files[1]) && !content_part(&registry,&registry.files[7]))
    // A prefab opens to its variants, not to its parts: without variants it has no arrow.
    owner:=c.cards[lines[1].first+1]
    testing.expect(t,!owner.holds && !c.cards[lines[1].first].holds)
    content_unfold(&c,CONTENT_TEST_ROBOT)
    lines=content_test_lines(&c,&registry)
    testing.expect_value(t,content_test_names(&c,&registry,lines[:2]),"[Robot] MI_Shared,robot")
    content_unfold(&c,CONTENT_TEST_ROBOT)
    // A search finds a part in its folder; Recent and Favorites list it.
    c.filter_length=copy(c.filter[:],"skm")
    testing.expect_value(t,content_test_show(&c,&registry),"SKM_Robot")
    c.filter_length=0
    session:=Session{content=&c}
    content_used(&session,registry.files[2].id)
    content_favorite_toggle(&c,registry.files[4].id)
    lines=content_test_lines(&c,&registry)
    testing.expect_value(t,content_test_names(&c,&registry,lines[:6]),"[Recent] SKM_Robot [Favorites] T_Robot_01_D [Robot] MI_Shared,robot")
    // A filter of families that leaves the owner out shows its parts in their folder.
    c.category=.Mesh
    testing.expect_value(t,content_test_show(&c,&registry),"[Recent] SKM_Robot [Robot] SKM_Robot [Stray] orphan")
    c.category=.Prefab
    testing.expect_value(t,content_test_show(&c,&registry),"[Robot] robot [Spider] spider")
    c.category=.None
    c.marks={}
    c.revision+=1
    // Show parts of imports lists them in their folders too.
    c.view.show_parts=true
    lines=content_test_lines(&c,&registry)
    testing.expect_value(t,content_test_names(&c,&registry,lines[:2]),"[Robot] MI_Robot_01,MI_Shared,SKM_Robot,T_Robot_01_D")
    testing.expect_value(t,content_test_names(&c,&registry,lines[2:3]),"robot")
    c.view.show_parts=false
    // Find in Content Browser of a hidden part of a prefab lists the parts in their folders.
    c.reveal=registry.files[2].id
    content_reveal_open(&c,&registry)
    testing.expect(t,c.view.show_parts && !slice.contains(c.unfolded[:],CONTENT_TEST_ROBOT))
    lines=content_test_lines(&c,&registry)
    testing.expect_value(t,content_test_names(&c,&registry,lines[:2]),"[Robot] MI_Robot_01,MI_Shared,SKM_Robot,T_Robot_01_D")
}

@(test)
content_gear_shows_the_parts_and_details_lists_them_after_the_rest :: proc(t:^testing.T) {
    // On the heap: on the stack, with the copy each literal makes, these come near the
    // megabyte of a test thread on Windows.
    f:=new(struct{ctx:ui.Context,assets:host.Assets,app:host.App,g:Editor_Ui,ins:Inspector,selection:history.Selection,info:core.World_Info,session:Session})
    defer free(f)
    ctx,assets,g,session:=&f.ctx,&f.assets,&f.g,&f.session
    testing.expect(t,test_ui_init(ctx,{}))
    defer ui.context_destroy(ctx)
    assets.registry,assets.indexed=content_test_parts_registry(),true
    defer content_test_registry_free(&assets.registry)
    f.app.assets=assets
    g.ctx=ctx
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    session.app,session.gui,session.content,session.inspector=&f.app,g,&c,&f.ins
    session.selection,session.info,session.headless=&f.selection,&f.info,true
    for _ in 0..<2 {content_test_still(session)}
    mesh:=ui.id_derive(ctx,100,"content_entry",int(content_test_hash(assets.registry.files[2].path)))
    _,found:=ui.widget_rect(ctx,mesh)
    testing.expect(t,!found,"The mesh of the import is not in its folder")
    content_test_click(t,session,ui.id_derive(ctx,100,"content_settings_open"))
    content_test_still(session)
    content_test_click(t,session,ui.id_derive(ctx,content_settings_popup(g),"parts"))
    testing.expect(t,c.view.show_parts)
    content_test_still(session)
    _,found=ui.widget_rect(ctx,mesh)
    testing.expect(t,found,"Show parts of imports lists it")
    c.view.show_parts=false
    // Find in Content Browser gives the keyboard to the part, in its folder.
    c.reveal=assets.registry.files[2].id
    content_test_still(session)
    testing.expect(t,c.view.show_parts)
    testing.expect_value(t,ctx.focus,ui.id_derive(ctx,100,"content_entry",int(content_card_key(assets.registry.files[2].path,{},0))))
    testing.expect_value(t,c.selected,assets.registry.files[2].id)
    // The list of a material field of Details: None, the material of its own,
    // then the part; choosing it marks it as used.
    list_open(session,{key=77,table=-1,kinds={0=asset.KIND_MATERIAL}},{20,20,260,40})
    frame :: proc(ctx:^ui.Context,s:^Session,input:ui.Input) {
        ui.frame_begin(ctx,input)
        list_build(s,core.World_Ref{})
        ui.frame_end(ctx)
    }
    for _ in 0..<2 {frame(ctx,session,{size={800,600},pointer_absent=true})}
    row,shown:=ui.widget_rect(ctx,ui.id_derive(ctx,list_popup(g),"row",3))
    _,more:=ui.widget_rect(ctx,ui.id_derive(ctx,list_popup(g),"row",4))
    testing.expect(t,shown && !more)
    if !shown {return}
    for phase in 0..<3 {
        input:=ui.Input{size={800,600},pointer=ui.rect_center(row)}
        if phase==1 {input.down,input.pressed={.Left},{.Left}}
        if phase==2 {input.released={.Left}}
        frame(ctx,session,input)
    }
    testing.expect_value(t,c.marks.recent[0],assets.registry.files[0].id)
}

@(test)
content_lists_the_clips_of_a_library_while_it_is_open_and_when_a_search_finds_them :: proc(t:^testing.T) {
    registry:=content_test_registry()
    defer content_test_registry_free(&registry)
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    walk:=base.Asset_Id{1,1}
    append(&c.clip_text,..transmute([]u8)string("idlerun"))
    append(&c.clips,Content_Clip{walk,0,4},Content_Clip{walk,4,3})
    content_enter(&c,.None,"Animations")
    lines:=content_test_lines(&c,&registry)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"walk")
    testing.expect(t,c.cards[lines[0].first].holds && !c.cards[lines[0].first].open)
    content_unfold(&c,walk)
    lines=content_test_lines(&c,&registry)
    testing.expect_value(t,content_test_names(&c,&registry,lines),"walk,idle,run")
    card:=c.cards[lines[0].first+1]
    testing.expect(t,card.clip==1 && card.file==c.cards[lines[0].first].file)
    content_unfold(&c,walk)
    c.filter_length=copy(c.filter[:],"RUN")
    testing.expect_value(t,content_test_show(&c,&registry),"walk,run")
}

// Folders without files show while nothing filters; the line of Create goes
// at the top of the list, wherever the browser is.
@(test)
content_shows_empty_folders_and_the_line_of_create :: proc(t:^testing.T) {
    registry:=content_test_registry()
    defer content_test_registry_free(&registry)
    append(&registry.folders,"Animations/","Empty/","Meshes/","Meshes/nested/")
    defer delete(registry.folders)
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    testing.expect_value(t,content_test_show(&c,&registry),"[Animations] walk [Empty] [Materials] red [Meshes] box,sphere [Prefabs] robot [Sounds] hit [Textures] color [UI] hud")
    c.view.arrangement=.Cards
    testing.expect_value(t,content_test_show(&c,&registry),"#Animations,#Empty,#Materials,#Meshes #Prefabs,#Sounds,#Textures,#UI")
    c.view.arrangement=.Names
    c.creating,c.create_kind=true,asset.KIND_MATERIAL
    c.create_folder_length=copy(c.create_folder[:],"Meshes")
    c.create_name_length=copy(c.create_name[:],"New Material")
    c.revision+=1
    lines:=content_test_lines(&c,&registry)
    testing.expect_value(t,content_test_names(&c,&registry,lines[:2]),"(New Material) [Animations]")
    // A search hides the folders without files.
    content_create_end(&c)
    c.filter_length=copy(c.filter[:],"box")
    testing.expect_value(t,content_test_show(&c,&registry),"box")
    c.filter_length=0
    c.category=.Mesh
    testing.expect_value(t,content_test_show(&c,&registry),"[Meshes] box,sphere")
}

// A right click on a folder opens Create; its entry names the new asset in
// the line, Enter makes it, and it comes selected and open.
@(test)
a_right_click_on_a_folder_creates_an_asset_named_in_place :: proc(t:^testing.T) {
    root:=base.test_folder(t,"content-create")
    if root=="" {return}
    if !testing.expect_value(t,os.make_directory_all(fmt.tprintf("%s/Materials",root)),os.Error(nil)) {return}
    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    g:=Editor_Ui{ctx=&ctx}
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    selection:history.Selection
    info:core.World_Info
    session:=Session{app=&app,gui=&g,content=&c,selection=&selection,info=&info,headless=true}
    defer delete(session.asset_documents)
    for _ in 0..<3 {content_test_still(&session)}
    folder:=ui.id_derive(&ctx,100,"content_folder",int(content_test_hash("Materials")))
    rect,found:=ui.widget_rect(&ctx,folder)
    if !testing.expect(t,found,"a folder without files shows") {return}
    _=content_test_frame(&session,{size={800,600},pointer=ui.rect_center(rect),down={.Right},pressed={.Right}})
    popup:=content_create_id(&g)
    testing.expect(t,ui.popup_is_open(&ctx,popup) && string(c.create_into[:c.create_into_length])=="Materials")
    content_test_still(&session)
    content_test_click(t,&session,ui.id_derive(&ctx,popup,"create",4))
    testing.expect(t,c.creating && c.create_kind==asset.KIND_MATERIAL && string(c.create_name[:c.create_name_length])=="New Material")
    content_test_still(&session)
    testing.expect_value(t,ctx.edit.id,ui.id_derive(&ctx,100,"content_create_name"))
    _=content_test_frame(&session,{size={800,600},pointer_absent=true,keys_down={.Enter},keys_pressed={.Enter}})
    testing.expect(t,!c.creating && c.created!={})
    file,made:=asset.registry_find_path(&assets.registry,"Materials/New Material.mat")
    testing.expect(t,made && file.kind==asset.KIND_MATERIAL && !os.exists(fmt.tprintf("%s/Materials/New Material.mat",root)))
    content_test_still(&session)
    testing.expect(t,made && c.selected==file.id && c.created=={})
    testing.expect(t,len(session.asset_documents)==1 && session.asset_documents[0].id==c.selected,"its document opens")
}

@(test)
a_selection_fills_its_row_or_cell_and_the_keyboard_has_a_ring_of_its_own :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    row:=asset_row_box(&ctx,1,4,true,false,false)
    testing.expect(t,row.fill==ui.tone(&ctx,"accent_soft") && row.stroke=={},"A selected row fills, as the rows of the outliner")
    row=asset_row_box(&ctx,1,4,false,false,true)
    testing.expect(t,row.fill=={} && row.stroke==ui.tone(&ctx,"text"),"Only the keyboard has the light ring")
    card:=asset_card_box(&ctx,1,CONTENT_VIEW_DEFAULT,60,true,false)
    testing.expect(t,card.fill==ui.tone(&ctx,"accent_soft") && card.stroke=={} && card.padding=={},"A cell has no padding")
    edge,width:=asset_frame_edge(&ctx,false,true)
    testing.expect(t,edge==ui.tone(&ctx,"toggle_on_stroke") && width==1,"Its thumbnail has a violet border, no light ring")
    columns,_:=content_cells(CONTENT_VIEW_DEFAULT,CONTENT_TEST_WIDTH)
    testing.expect_value(t,columns,4)
}

// A click where no card, row or folder is clears the selection of the
// browser; with Ctrl or Shift, or on a folder, it keeps it.
@(test)
a_click_on_the_background_of_the_browser_clears_its_selection :: proc(t:^testing.T) {
    ctx:ui.Context
    testing.expect(t,test_ui_init(&ctx,{}))
    defer ui.context_destroy(&ctx)
    assets:=host.Assets{registry=content_test_wall_registry(),indexed=true}
    defer content_test_registry_free(&assets.registry)
    app:=host.App{assets=&assets}
    g:=Editor_Ui{ctx=&ctx}
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    selection:history.Selection
    info:core.World_Info
    session:=Session{app=&app,gui=&g,content=&c,selection=&selection,info=&info,headless=true}
    for _ in 0..<2 {content_test_still(&session)}
    for mode in Content_Mode {
        c.view.mode=mode
        content_enter(&c,.None,"",reset=true)
        c.selected=assets.registry.files[7].id
        content_test_still(&session)
        folder:=ui.id_derive(&ctx,100,"content_folder",int(content_test_hash("Castle")))
        content_test_click(t,&session,folder)
        testing.expect_value(t,c.selected,assets.registry.files[7].id)
        content_enter(&c,.None,"Levels",reset=true)
        content_test_still(&session)
        card:=ui.id_derive(&ctx,100,"content_entry",int(content_test_hash(assets.registry.files[6].path)))
        content_test_click(t,&session,card)
        testing.expect_value(t,c.selected,assets.registry.files[6].id)
        g.drag={}
        area,found:=ui.widget_rect(&ctx,ui.id_derive(&ctx,100,"content_area"))
        if !testing.expect(t,found) {return}
        empty:=ui.Rect{area.x,area.y+area.h-12,area.w,8}
        for modifier in ([]ui.Modifiers{{.Primary},{.Shift}}) {
            content_test_click_at(t,&session,empty,modifier)
            testing.expect_value(t,c.selected,assets.registry.files[6].id)
        }
        content_test_click_at(t,&session,empty)
        testing.expect(t,c.selected=={} && len(c.picked)==0 && g.drag.kind==.None)
    }
}

// A folder the browser was left in that is gone gives its place to the
// nearest one above it, or to the root.
@(test)
content_navigation_falls_to_what_the_registry_still_has :: proc(t:^testing.T) {
    registry:=content_test_registry()
    defer content_test_registry_free(&registry)
    append(&registry.folders,"Empty/")
    defer delete(registry.folders)
    c:=CONTENT_DEFAULT
    defer core.value_free(&c,type_info_of(Content))
    n:Content_Navigation
    copy(n.place[:],"Meshes/gone/deeper")
    copy(n.at[:],"Meshes/nested/gone")
    n.category=.Mesh
    content_navigation_set(&c,&n)
    content_registry_read(&c,&registry,{CONTENT_TEST_PLUGIN_KIND})
    content_navigation_restore(&c,&registry)
    testing.expect_value(t,string(c.place[:c.place_length]),"Meshes")
    testing.expect_value(t,string(c.at.folder[:c.at.length]),"Meshes/nested")
    testing.expect_value(t,c.category,Content_Category.Mesh)
    testing.expect_value(t,content_test_show(&c,&registry),"sphere")
    // Nothing of it is left: the root.
    n.place,n.at={},{}
    copy(n.place[:],"Gone/away")
    copy(n.at[:],"Gone/away")
    content_navigation_set(&c,&n)
    content_navigation_restore(&c,&registry)
    testing.expect_value(t,string(c.place[:c.place_length]),"")
    testing.expect_value(t,c.at.length,0)
    // A change of the registry checks it again: a virtual folder stays.
    n.at={}
    n.virtual=.Favorites
    content_navigation_set(&c,&n)
    testing.expect(t,c.restore)
    registry.revision+=1
    content_registry_read(&c,&registry,{CONTENT_TEST_PLUGIN_KIND})
    testing.expect(t,c.restore && c.at.virtual==.Favorites)
    content_navigation_restore(&c,&registry)
    testing.expect_value(t,c.at.virtual,Content_Virtual.Favorites)
}
