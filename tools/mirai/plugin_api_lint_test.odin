package main

import "core:path/filepath"
import "core:testing"

// A plugin reaches the renderer through engine/render and the editor: the
// lint names the imports of the renderer and of the RHI, and no other.
@(test)
the_lint_names_the_imports_below_the_api_of_a_plugin :: proc(t:^testing.T) {
    source:=`package decals_editor

import "core:fmt"
import erender "mirai:engine/render"
import gpu "mirai:render" // "the renderer"
    import "mirai:rhi"
import "mirai:rhi/shared_device"
import "mirai:rendering"
import "plugins:physics/runtime"
// import "mirai:render"
`
    findings:=make([dynamic]Plugin_Import,context.temp_allocator)
    plugin_api_lint_source(source,&findings)
    if !testing.expect_value(t,len(findings),3) {return}
    expected:=[3]Plugin_Import{{5,"mirai:render"},{6,"mirai:rhi"},{7,"mirai:rhi/shared_device"}}
    for e,i in expected {testing.expect_value(t,findings[i],e)}
}

// It runs on the packages of the runtime and editor parts of a plugin, and
// those parts of the plugins of the engine pass it.
@(test)
the_plugins_of_the_engine_import_neither_the_renderer_nor_the_rhi :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root,_:=filepath.abs(#directory+"../..")
    Case :: struct {folder:string,applies:bool}
    for c in ([]Case{
        {"plugins/decals/editor",true},{"plugins/physics/runtime",true},{"plugins/physics/runtime/sim",true},
        {"plugins/decals/shaders",false},{"plugins/decals",false},{"plugins",false},{"editor",false},{"engine/render",false},
    }) {
        testing.expectf(t,plugin_api_lint_applies(join(root,c.folder))==c.applies,"%s: %v",c.folder,!c.applies)
    }
    testing.expect(t,plugin_api_lint_folder(join(root,"plugins")),"a plugin imports the renderer or the RHI outside its tests")
}
