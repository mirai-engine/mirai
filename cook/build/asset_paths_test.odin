package build

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:project"
import "mirai:std/base"

// A path of an asset written in the code of the project names an asset, or
// the check says where it is written, with the path of the asset of that
// name; text that only looks like one is not a path. The world generates
// from the code alone, the asset there or not, so what makes the asset (an
// import, the content tool) builds with it. A kind of an active plugin is an
// asset before any file of it exists. What the game ships is told apart from
// what an editor part or a development plugin writes.
@(test)
a_path_of_an_asset_in_the_code_names_one_or_the_check_says_where :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"asset-paths")
    if folder=="" {return}
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    kit:=project.path(game,"plugins","kit",allocator=context.temp_allocator)
    sources:=[]string{"game","editor","plugins/kit/runtime"}
    package_names:=[]string{"game","tools","kit"}
    for path in ([]string{project.path(engine,"core",allocator=context.temp_allocator),project.path(game,"assets","pets",allocator=context.temp_allocator)}) {
        if !testing.expect(t,base.make_directory_all(path)==nil) {return}
    }
    for source in sources {
        if !testing.expect(t,base.make_directory_all(project.path(game,source,allocator=context.temp_allocator))==nil) {return}
    }
    if !testing.expect(t,os.write_entire_file(project.path(engine,"core","core.odin",allocator=context.temp_allocator),"package core\n")==nil) {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    dog:asset.Scene;asset.scene_init(&dog,&types,{0xd0,1})
    asset.scene_entity_add(&dog,1,0,"Dog")
    testing.expect_value(t,asset.scene_save(&dog,project.path(game,"assets","pets","Dog.scene",allocator=context.temp_allocator)),asset.Error.None)
    asset.scene_destroy(&dog)
    // A source an import reads is in the assets too, and is no asset.
    testing.expect(t,os.write_entire_file(project.path(game,"assets","pets","Dog.umap",allocator=context.temp_allocator),"map")==nil)
    plugins:=make([]project.Plugin,1,context.temp_allocator)
    plugins[0]={origin=.Project,folder=kit}
    base.text_set(plugins[0].manifest.name[:],"kit")
    base.text_set(plugins[0].manifest.asset_kinds[0].extension[:],".character")
    base.text_set(plugins[0].manifest.asset_kinds[0].kind[:],"CHAR")
    Case :: struct {source,code,path,says:string,shipped,development:bool}
    cases:=[]Case{
        {"game",`DOG :: "pets/Dog.scene"`,"pets/Dog.scene","",true,false},
        {"game",`DOG :: "pets/Dgo.scene"`,"pets/Dgo.scene",`"pets/Dgo.scene" names no asset`,true,false},
        {"game",`DOG :: "Dog.scene"`,"Dog.scene",`the asset of that name is "pets/Dog.scene"`,true,false},
        {"game",`HERO :: "chars/hero.character"`,"chars/hero.character",`"chars/hero.character" names no asset`,true,false},
        {"game",`SAID :: "spawned %s.scene"`,"","",false,false},
        {"game",`SAID :: "a .scene of the assets"`,"","",false,false},
        {"game",`SAID :: "no level in it: open a .umap"`,"","",false,false},
        {"editor",`DOG :: "pets/Dgo.scene"`,"pets/Dgo.scene",`"pets/Dgo.scene" names no asset`,false,false},
        {"plugins/kit/runtime",`DOG :: "pets/Dog.scene"`,"pets/Dog.scene","",true,false},
        {"plugins/kit/runtime",`DOG :: "pets/Dog.scene"`,"pets/Dog.scene","",false,true},
    }
    for c in cases {
        for source,i in sources {
            text:=strings.concatenate({"package ",package_names[i],"\n",c.code if source==c.source else "","\n"},context.temp_allocator)
            if !testing.expect(t,os.write_entire_file(project.path(game,source,"code.odin",allocator=context.temp_allocator),text)==nil) {return}
        }
        plugins[0].manifest.development=c.development
        p:=project.Project{root=game,engine_root=engine,plugins=plugins,active={0}}
        out:=world_generate(&p,context.temp_allocator)
        testing.expectf(t,len(out.errors)==0,"%s: the world generates whatever the assets: %v",c.code,out.errors)
        if c.path=="" {
            testing.expectf(t,len(out.asset_refs)==0,"%s: no path: %v",c.code,out.asset_refs)
        } else if testing.expectf(t,len(out.asset_refs)==1,"%s in %s: %v",c.code,c.source,out.asset_refs) {
            ref:=out.asset_refs[0]
            testing.expectf(t,ref.path==c.path && ref.line==2 && strings.has_suffix(ref.file,strings.concatenate({c.source,"/code.odin"},context.temp_allocator)) && ref.shipped==c.shipped,"%s in %s: %v",c.code,c.source,ref)
        }
        errors:=asset_refs_check(project.asset_folders(&p,context.temp_allocator),out.asset_refs,"",context.temp_allocator)
        testing.expectf(t,slice.equal(errors,asset_paths_check(&p,"",context.temp_allocator)),"%s: a check that reads only the code says the same",c.code)
        if c.says=="" {
            testing.expectf(t,len(errors)==0,"%s: %v",c.code,errors)
            continue
        }
        testing.expectf(t,len(errors)==1 && strings.contains(errors[0],c.says) && strings.contains(errors[0],"code.odin(2:"),"%s: no error says %q: %v",c.code,c.says,errors)
    }
}
