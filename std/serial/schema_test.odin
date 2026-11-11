package serial

import "core:strings"
import "core:testing"
import "mirai:std/base"

@(private="file")
Shape :: enum u8 {Box,Sphere=4}
@(private="file")
Layer :: enum u8 {Static,Dynamic,Debris}
@(private="file")
Inner :: struct {offset:[3]f32,shape:Shape}
@(private="file")
Sample :: struct {
    target:base.Entity,
    mesh:base.Asset_Id,
    speed:f32 `mirai:"min=0,max=20,step=0.5,unit=m/s,precision=0.01"`,
    rotation:quaternion128,
    layers:bit_set[Layer;u8],
    parts:[2]Inner,
    label:[32]u8 `mirai:"text,label=Display name"`,
    cache:u32 `mirai:"transient,local"`,
    enabled:bool,
}
@(private="file")
Not_Plain :: struct {count:int,inner:struct {names:[]string}}

@(test)
schema_describes_plain_structs_with_nested_types_and_tags :: proc(t:^testing.T) {
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    root,ok:=schema_add(&s,Sample)
    testing.expect(t,ok,s.error)
    testing.expect_value(t,schema_type(&s,root).name,"Sample")
    testing.expect_value(t,schema_type(&s,root).size,u32(size_of(Sample)))
    fields:=schema_fields(&s,root)
    testing.expect_value(t,len(fields),9)
    testing.expect_value(t,schema_type(&s,fields[0].type).kind,Type_Kind.Entity)
    testing.expect_value(t,schema_type(&s,fields[1].type).kind,Type_Kind.Asset)
    speed:=schema_field(&s,root,base.name_hash("speed"))
    testing.expect(t,speed!=nil && speed.has_min && speed.has_max)
    testing.expect_value(t,speed.max,20.0)
    testing.expect_value(t,speed.step,0.5)
    testing.expect_value(t,speed.unit,"m/s")
    testing.expect_value(t,speed.precision,f32(0.01))
    testing.expect_value(t,speed.offset,u32(offset_of(Sample,speed)))
    rotation:=schema_field(&s,root,base.name_hash("rotation"))
    testing.expect(t,.Rotation in rotation.flags)
    testing.expect_value(t,schema_type(&s,rotation.type).count,u32(4))
    layers:=schema_choices(&s,schema_field(&s,root,base.name_hash("layers")).type)
    testing.expect_value(t,len(layers),3)
    testing.expect_value(t,layers[2].name,"Debris")
    testing.expect_value(t,layers[2].value,i64(2))
    parts:=schema_type(&s,schema_field(&s,root,base.name_hash("parts")).type)
    testing.expect_value(t,parts.kind,Type_Kind.Array)
    testing.expect_value(t,parts.count,u32(2))
    inner:=schema_fields(&s,parts.elem)
    testing.expect_value(t,len(inner),2)
    shape:=schema_choices(&s,inner[1].type)
    testing.expect_value(t,shape[1].value,i64(4))
    label:=schema_field(&s,root,base.name_hash("label"))
    testing.expect(t,.Text in label.flags)
    testing.expect_value(t,label.label,"Display name")
    cache:=schema_field(&s,root,base.name_hash("cache"))
    testing.expect(t,cache.flags==Field_Flags{.Transient,.Local})
    found,found_ok:=schema_find(&s,base.name_hash("Sample"))
    testing.expect(t,found_ok && found==root)
}

@(test)
schema_rejects_types_that_are_not_plain_data :: proc(t:^testing.T) {
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    _,ok:=schema_add(&s,Not_Plain)
    testing.expect(t,!ok)
    testing.expect_value(t,s.error,"inner.names: []string is not plain data")
}

// What each option of a tag sets, read by the one reader of tags.
@(test)
a_tag_is_read_option_by_option :: proc(t:^testing.T) {
    Case :: struct {tag:string,flags:Field_Flags,hints:Field_Hints,check:proc(field:Field) -> bool}
    cases:=[]Case{
        {`mirai:"transient,local,readonly,hidden"`,{.Transient,.Local,.Read_Only,.Hidden},{},nil},
        {`mirai:"color"`,{.Color},{},nil},
        {`mirai:"angle,text"`,{.Angle,.Text},{},nil},
        {`mirai:"trim,entity,inline"`,{},{.Trim,.Entity,.Inline},nil},
        {`mirai:"optional,clamp"`,{},{.Optional,.Clamp},nil},
        {`mirai:"advanced,owned,game,hex,data"`,{},{.Advanced,.Owned,.Game,.Hex,.Data},nil},
        {`mirai:"min=-1.5,max=20,step=0.5"`,{},{},proc(f:Field) -> bool {return f.has_min && f.min==-1.5 && f.has_max && f.max==20 && f.step==0.5}},
        {`mirai:"precision=0.01,bits=12"`,{},{},proc(f:Field) -> bool {return f.precision==0.01 && f.bits==12}},
        {`mirai:"unit=m/s,name=where,kind=.anim .match"`,{},{},proc(f:Field) -> bool {return f.unit=="m/s" && f.name=="where" && f.asset_kinds==".anim .match"}},
        {`mirai:"requires=Camera"`,{},{},proc(f:Field) -> bool {return f.required_component==base.name_hash("Camera")}},
        {`mirai:"section=Exposure,mode=Follow|Orbit,icons=Play Stop,axes=LTRB,graphics=Fog"`,{},{},proc(f:Field) -> bool {return f.section=="Exposure" && f.mode=="Follow|Orbit" && f.icons=="Play Stop" && f.axes=="LTRB" && f.graphics=="Fog"}},
        // label is the last option and takes the rest of the tag, commas and equals included.
        {`mirai:"text, optional , label=Around it; omitted: the querier, or point=x"`,{.Text},{.Optional},proc(f:Field) -> bool {return f.label=="Around it; omitted: the querier, or point=x"}},
        {`mirai:"label="`,{},{},proc(f:Field) -> bool {return f.label==""}},
        {`json:"x" mirai:"hidden" other:"y"`,{.Hidden},{},nil},
        {`json:"x"`,{},{},nil},
        {``,{},{},nil},
    }
    for c in cases {
        field,problem:=field_tag(c.tag)
        testing.expectf(t,problem=="","%s: %s",c.tag,problem)
        testing.expectf(t,field.flags==c.flags && field.hints==c.hints,"%s: %v %v",c.tag,field.flags,field.hints)
        testing.expectf(t,c.check==nil || c.check(field),"%s: %v",c.tag,field)
    }
}

// A tag that is not one says which, and the tags there are; a schema does not
// take the type and names the field.
@(test)
a_tag_that_is_not_one_is_refused :: proc(t:^testing.T) {
    refused:=[][2]string{
        {`mirai:"unti=m"`,`"unti" is not a tag of a field: the tags are`},
        {`mirai:"hiden"`,`"hiden" is not a tag of a field`},
        {`mirai:"min=0,=,max=1"`,`"" is not a tag of a field`},
        {`mirai:"key=where"`,`"key" is not a tag of a field`},
        {`mirai:"list"`,`"list" is not a tag of a field`},
        {`mirai:"any"`,`"any" is not a tag of a field`},
        {`mirai:"min=low"`,`min="low" is not a number`},
        {`mirai:"max="`,`max="" is not a number`},
        {`mirai:"bits=999"`,`bits="999" is not a number`},
        {`mirai:"bits=-5"`,`bits="-5" is not a number`},
        {`mirai:"precision=garbage"`,`precision="garbage" is not a number`},
        {`mirai:"hidden=true"`,`"hidden" takes no value`},
        {`mirai:"unit="`,`unit= has no value`},
        {`mirai:"label=Values,unit=m,section="`,``},
    }
    for c in refused {
        _,problem:=field_tag(c[0])
        testing.expectf(t,(c[1]=="")==(problem=="") && strings.contains(problem,c[1]),"%s: %q",c[0],problem)
    }
    _,problem:=field_tag(`mirai:"nope"`)
    testing.expect(t,strings.contains(problem,FIELD_TAGS))
    // Bytes that are no tag at all read as nothing or as a problem, never past them.
    h:=base.Hostile{7}
    for _ in 0..<2000 {
        bytes:[48]u8
        for &b in bytes {b=u8(base.hostile_int(&h,96)+32)}
        copy(bytes[:],`mirai:"`)
        field_tag(string(bytes[:base.hostile_int(&h,len(bytes))+1]))
    }
    Mistagged :: struct {inner:struct {speed:f32 `mirai:"min=0,unti=m/s"`}}
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    _,ok:=schema_add(&s,Mistagged)
    testing.expect(t,!ok)
    testing.expect(t,strings.has_prefix(s.error,`inner.speed: "unti" is not a tag of a field: the tags are transient, `),s.error)
    testing.expect_value(t,len(s.types),0)
    testing.expect_value(t,len(s.fields),0)
}

@(test)
schema_layout_hash_follows_the_layout :: proc(t:^testing.T) {
    A :: struct {x:f32,y:u16}
    B :: struct {x:f32,y:u32}
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    a,_:=schema_add(&s,A)
    b,_:=schema_add(&s,B)
    again:Schema;schema_init(&again);defer schema_destroy(&again)
    a_again,_:=schema_add(&again,A)
    testing.expect(t,schema_layout_hash(&s,a)!=schema_layout_hash(&s,b))
    testing.expect_value(t,schema_layout_hash(&again,a_again),schema_layout_hash(&s,a))
}
