package importer

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:std/base"

// What the reader of the test below saw in its options.
@(private="file")
seen:Import_Settings

// A format that records the settings it is read with and gives a triangle.
@(private="file")
SETTINGS_FORMAT :: Format{name="Settings test",extensions={0=".seen"},space=ENGINE_SPACE,sniff=proc(head:[]u8) -> Sniff {return .Extension},read=proc(r:^Reader,bytes:[]u8) -> bool {
    seen=r.options.settings
    b:Mesh_Builder
    builder_init(&b,r)
    slot:=builder_slot(&b,1,"Paint",-1) or_return
    builder_triangle(&b,slot,{{position={0,0,0},normal={0,0,1},color=WHITE},{position={1,0,0},normal={0,0,1},color=WHITE},{position={0,1,0},normal={0,0,1},color=WHITE}})
    mesh_add(r,builder_finish(&b,"Seen"))
    return true
}}

// A reader that acts on a setting (Import_Settings.skeleton: clips that keep no skeleton of their
// own) reads it from the options: those of <source>.import when the source has one, as the writer
// applies them, else those the import was given.
@(test)
a_reader_sees_the_settings_kept_with_its_source :: proc(t:^testing.T) {
    folder:=temp_folder("reader-settings")
    defer os.remove_all(folder)
    path:=fmt.tprintf("%s/model.seen",folder)
    _=os.write_entire_file(path,"anything")
    formats:=[1]Format{SETTINGS_FORMAT}
    given:=base.Asset_Id{1,2}
    model,error:=import_model(path,formats[:],{settings={skeleton=given}})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    model_destroy(&model)
    testing.expect_value(t,seen.skeleton,given)
    kept:=base.Asset_Id{3,4}
    if !testing.expect(t,settings_save(path,{skeleton=kept})) {return}
    model,error=import_model(path,formats[:],{settings={skeleton=given}})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    model_destroy(&model)
    testing.expect_value(t,seen.skeleton,kept)
}
