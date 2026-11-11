package build

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

// The cook of a project as the job Game does it: filling an empty texture
// cache and from it. Run with --release -define:COOK_BENCH=true;
// COOK_BENCH_PROJECT names the project, the demo when empty.
@(private="file") COOK_BENCH :: #config(COOK_BENCH,false)
@(private="file") COOK_BENCH_PROJECT :: #config(COOK_BENCH_PROJECT,"")

@(test)
bench_cook_of_a_project_filling_its_texture_cache_and_from_it :: proc(t:^testing.T) {
    if !COOK_BENCH {return}
    engine:=#directory+"/../.."
    root:=COOK_BENCH_PROJECT if COOK_BENCH_PROJECT!="" else project.path(engine,"demo",allocator=context.temp_allocator)
    p,error:=project.open(root,engine,context.temp_allocator)
    if !testing.expect_value(t,error.code,project.Error_Code.None) {return}
    folder:=base.test_folder(t,"cook-bench")
    if folder=="" {return}
    desc:=Cook_Desc{
        assets=project.folder_path(p.root,.Assets,context.temp_allocator),
        output=fmt.tprintf("%s/out",folder),
        manifest=project.path(p.root,COOK_FILE,allocator=context.temp_allocator),
        allocator=context.temp_allocator,
    }
    plugins:=make([dynamic]project.Asset_Folder,context.temp_allocator)
    for found in project.asset_folders(&p,context.temp_allocator) {
        if found.prefix!="" {append(&plugins,found)}
    }
    desc.plugins=plugins[:]
    desc.texture_cache=fmt.tprintf("%s/cache",folder)
    filling:=cook_assets(desc)
    testing.expect_value(t,filling.error,Cook_Error.None)
    cached:=cook_assets(desc)
    testing.expect_value(t,cached.error,Cook_Error.None)
    fmt.printfln("cook of %s on %d threads: %d files, %d textures compressed; filling the texture cache %.1f s, from it %.1f s",p.root,os.get_processor_core_count(),len(cached.files),cached.textures_compressed,filling.seconds,cached.seconds)
}
