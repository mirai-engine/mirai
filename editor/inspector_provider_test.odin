package editor

import "core:testing"
import "mirai:core"

Inspector_Test_Provider :: struct {provider:Inspector_Provider}
inspector_test_provider_v1 :: proc(dst:rawptr) {(^Inspector_Test_Provider)(dst)^={provider={component=inspector_test_component_v1}}}
inspector_test_provider_v2 :: proc(dst:rawptr) {(^Inspector_Test_Provider)(dst)^={provider={component=inspector_test_component_v2}}}
inspector_test_component_v1 :: proc(c:Inspector_Context) -> bool {c.session.frame+=1;return true}
inspector_test_component_v2 :: proc(c:Inspector_Context) -> bool {c.session.frame+=2;return true}

@(private="file")
Inspector_Test_World :: struct {using world:core.Test_World}

@(private="file")
Inspector_Test_Editor :: struct {provider:Inspector_Test_Provider}

@(private="file")
inspector_test_types :: proc(types:^[dynamic]core.Test_Type) {
    append(types,core.test_type(Inspector_Test_Provider,default=proc(dst:^Inspector_Test_Provider) {inspector_test_provider_v1(dst)}))
}

@(test)
inspector_extensions_use_current_metadata_and_preserve_the_generic_fallback :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Inspector_Test_World,core.Test_None,Inspector_Test_Editor,inspector_test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    provider:=&info.storages[info.storages_by_type[Inspector_Test_Provider]]
    session:=Session{info=&info}
    inspected:=Inspect{s=&session}
    testing.expect(t,inspector_extension(&inspected) && session.frame==1)
    provider.default=inspector_test_provider_v2
    session.library_generation+=1
    testing.expect(t,inspector_extension(&inspected) && session.frame==3)
    testing.expect(t,!inspector_extension(&inspected,type_info_of(f32)))
    provider.place=.World
    session.library_generation+=1
    testing.expect(t,!inspector_extension(&inspected))
}
