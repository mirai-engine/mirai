package editor

import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
Asset_Field_Test :: struct {
    any:base.Asset_Id,
    sound:base.Asset_Id,
    source:base.Asset_Id `mirai:"section=Clip,kind=.anim .character .graph"`,
    unknown:base.Asset_Id `mirai:"kind=.graph"`,
}

@(test)
asset_field_takes_the_kinds_its_tag_names_and_those_a_plugin_declares :: proc(t:^testing.T) {
    CHARACTER :: asset.Fourcc(0x5241_4843)
    s:Session
    s.providers.library=s.library_generation+1
    s.providers.kinds[0]={kind=CHARACTER,label="Character",extension=".character"}
    s.providers.kind_count=1
    kinds :: proc(s:^Session,name:string) -> Asset_Kinds {
        schema:serial.Schema
        serial.schema_init(&schema,context.temp_allocator)
        type,_:=serial.schema_add_type_info(&schema,type_info_of(Asset_Field_Test))
        return field_asset_kinds(s,serial.schema_field(&schema,type,base.name_hash(name))^)
    }
    source:=kinds(&s,"source")
    testing.expect_value(t,source,Asset_Kinds{0=asset.KIND_ANIMATION,1=CHARACTER})
    testing.expect(t,asset_kind_takes(source,asset.KIND_ANIMATION) && asset_kind_takes(source,CHARACTER))
    testing.expect(t,!asset_kind_takes(source,asset.KIND_MESH))
    // A tag whose kinds none declares falls back to the name of the field.
    testing.expect_value(t,kinds(&s,"unknown"),Asset_Kinds{})
    sound:=kinds(&s,"sound")
    testing.expect(t,asset_kind_takes(sound,asset.KIND_SOUND_SET) && !asset_kind_takes(sound,asset.KIND_MESH))
    testing.expect(t,asset_kind_takes(kinds(&s,"any"),asset.KIND_MESH))
}
