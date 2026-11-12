package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:project"
import "mirai:std/base"

// A path of an asset written in the code of the project names an asset, or
// the build fails where it is written, with the path of the asset of that
// name; text that only looks like one is not a path.
@(test)
a_path_of_an_asset_in_the_code_names_one_or_the_build_says_where :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"asset-paths")
    if folder=="" {return}
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    for path in ([]string{project.path(engine,"core",allocator=context.temp_allocator),project.path(game,"game",allocator=context.temp_allocator),project.path(game,"assets","pets",allocator=context.temp_allocator)}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    if !testing.expect(t,os.write_entire_file(project.path(engine,"core","core.odin",allocator=context.temp_allocator),"package core\n")==nil) {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    dog:asset.Scene;asset.scene_init(&dog,&types,{0xd0,1})
    asset.scene_entity_add(&dog,1,0,"Dog")
    testing.expect_value(t,asset.scene_save(&dog,project.path(game,"assets","pets","Dog.scene",allocator=context.temp_allocator)),asset.Error.None)
    asset.scene_destroy(&dog)
    // A source an import reads is in the assets too, and is no asset.
    testing.expect(t,os.write_entire_file(project.path(game,"assets","pets","Dog.umap",allocator=context.temp_allocator),"map")==nil)
    cases:=[]struct{code,says:string}{
        {`DOG :: "pets/Dog.scene"`,""},
        {`DOG :: "pets/Dgo.scene"`,`"pets/Dgo.scene" names no asset`},
        {`DOG :: "Dog.scene"`,`the asset of that name is "pets/Dog.scene"`},
        {`SAID :: "spawned %s.scene"`,""},
        {`SAID :: "a .scene of the assets"`,""},
        {`SAID :: "no level in it: open a .umap"`,""},
    }
    for c in cases {
        source:=strings.concatenate({"package game\n",c.code,"\n"},context.temp_allocator)
        if !testing.expect(t,os.write_entire_file(project.path(game,"game","game.odin",allocator=context.temp_allocator),source)==nil) {return}
        p:=project.Project{root=game,engine_root=engine}
        errors:=world_generate(&p,context.temp_allocator).errors
        if c.says=="" {
            testing.expectf(t,len(errors)==0,"%s: %v",c.code,errors)
            continue
        }
        found:=false
        for message in errors {found||=strings.contains(message,c.says) && strings.contains(message,"game.odin(2:")}
        testing.expectf(t,found,"%s: no error says %q: %v",c.code,c.says,errors)
    }
}
