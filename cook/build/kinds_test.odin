package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

// What the manifest of each plugin of the engine declares of its kinds is what
// its code compiles against: the file a build writes is the one git keeps.
@(test)
the_constants_of_the_kinds_of_each_plugin_are_those_its_manifest_declares :: proc(t:^testing.T) {
    root:=slashes(project.path_absolute(#directory+"../..",context.temp_allocator),context.temp_allocator)
    found:=make([dynamic]project.Plugin,context.temp_allocator)
    if !testing.expect_value(t,project.plugins_discover(project.path(root,"plugins",allocator=context.temp_allocator),.Engine,&found,context.temp_allocator).code,project.Error_Code.None) {return}
    generated:=0
    for &plugin in found {
        for file in kinds_files(&plugin,context.temp_allocator) {
            kept,error:=os.read_entire_file(file[0],context.temp_allocator)
            testing.expectf(t,error==nil && string(kept)==file[1],"%s is not what %s/%s declares: mirai build writes it",file[0],plugin.folder,project.PLUGIN_FILE)
            generated+=1
        }
    }
    testing.expect(t,generated>0)
    // Each constant names the kind by the stem of its extension, with its four letters.
    cache:project.Asset_Kind
    base.text_set(cache.extension[:],".physics_cache")
    base.text_set(cache.kind[:],"PCAC")
    text:=kinds_text({&cache},"sample",context.temp_allocator)
    for part in ([]string{"package sample\n",`PHYSICS_CACHE_KIND :: asset.Fourcc(u32('P')|u32('C')<<8|u32('A')<<16|u32('C')<<24)`,`PHYSICS_CACHE_EXTENSION :: ".physics_cache"`}) {
        testing.expect(t,strings.contains(text,part),text)
    }
}
