package main

import "core:testing"

@(test)
only_the_physics_plugin_imports_the_solver :: proc(t:^testing.T) {
    Case :: struct {folder:string,applies:bool}
    for c in ([]Case{
        {"C:/engine/plugins/foliage/runtime",true},{"C:/engine/plugins/terrain/editor",true},
        {"C:/engine/plugins/portals/runtime/deep",true},{"C:/engine/plugins/physics_cache/runtime",true},
        {"C:/engine/plugins/destruct/runtime",true},{"C:/engine/plugins/destruct_multiplayer/runtime",true},
        {"C:/engine/demo/game",true},{"C:/engine/templates/game/game",true},
        {"C:/engine/tools/demo_content",true},{"C:/engine/tools/mirai",true},{"C:/engine/core",true},
        {"C:/engine/plugins/physics/runtime",false},{"C:/engine/plugins/physics/runtime/sim",false},{"C:/engine/plugins/physics/editor",false},
        {"C:/engine",false},{"C:/elsewhere/plugins/foliage/runtime",false},{"C:/elsewhere/tools/demo_content",false},
    }) {
        testing.expectf(t,solver_lint_applies("C:/engine",c.folder)==c.applies,"%s: %v",c.folder,!c.applies)
    }
    context.allocator=context.temp_allocator
    line,column,found,parsed:=solver_lint_source("sample.odin","package sample\n\nimport \"mirai:core\"\nimport sim \"plugins:physics/runtime/sim\"\n")
    testing.expect(t,parsed && found && line==4 && column==1)
    _,_,found,parsed=solver_lint_source("sample.odin","package sample\n\nimport physics \"plugins:physics/runtime\"\n\n// plugins:physics/runtime/sim\n")
    testing.expect(t,parsed && !found)
}
