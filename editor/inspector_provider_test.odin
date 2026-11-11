package editor

import "core:testing"
import "mirai:core"

Inspector_Test_Provider :: struct {provider:Inspector_Provider}
inspector_test_provider_default :: proc() -> (p:Inspector_Test_Provider) {inspector_test_provider_v1(&p);return}
inspector_test_provider_v1 :: proc(dst:rawptr) {(^Inspector_Test_Provider)(dst)^={provider={component=inspector_test_component_v1}}}
inspector_test_provider_v2 :: proc(dst:rawptr) {(^Inspector_Test_Provider)(dst)^={provider={component=inspector_test_component_v2}}}
inspector_test_component_v1 :: proc(c:Inspector_Context) -> bool {c.session.frame+=1;return true}
inspector_test_component_v2 :: proc(c:Inspector_Context) -> bool {c.session.frame+=2;return true}

@(private)
@(test_world,editor="Inspector_Test_Editor")
Inspector_Test_World :: struct {using world:Test_World}

@(private)
Inspector_Test_Editor :: struct {provider:Inspector_Test_Provider}

@(test)
inspector_extensions_use_current_metadata_and_preserve_the_generic_fallback :: proc(t:^testing.T) {
    info,described:=test_info(t,Inspector_Test_World)
    if !described {return}
    defer test_info_destroy(&info)
    provider:=&info.storages[info.storages_by_type[Inspector_Test_Provider]]
    session:=Session{info=&info}
    inspected:=Inspect{s=&session}
    testing.expect(t,inspector_extension(&inspected,nil) && session.frame==1)
    provider.default=inspector_test_provider_v2
    session.library_generation+=1
    testing.expect(t,inspector_extension(&inspected,nil) && session.frame==3)
    testing.expect(t,!inspector_extension(&inspected,f32))
    provider.place=.World
    session.library_generation+=1
    testing.expect(t,!inspector_extension(&inspected,nil))
}
