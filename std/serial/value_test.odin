package serial

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:std/base"

@(private="file") Kind_V1 :: enum u8 {Box,Sphere,Capsule}
@(private="file") Kind_V2 :: enum u16 {Sphere,Box=7,Mesh}
@(private="file") Flag_V1 :: enum {Static,Dynamic,Debris}
@(private="file") Flag_V2 :: enum {Debris,Trigger,Static}
@(private="file") Part_V1 :: struct {offset:[3]f32,kind:Kind_V1}
@(private="file") Part_V2 :: struct {kind:Kind_V2,offset:[4]f32,weight:f64}
@(private="file")
Old :: struct {
    id:base.Entity_Id,
    target:base.Entity,
    mesh:base.Asset_Id,
    speed:f32,
    count:u8,
    big:i64,
    ratio:f64,
    on:bool,
    flags:bit_set[Flag_V1;u8],
    parts:[3]Part_V1,
    name:[8]u8 `mirai:"text"`,
    gone:u32,
    cache:u32 `mirai:"transient"`,
}
@(private="file")
New :: struct {
    name:[16]u8 `mirai:"text"`,
    speed:f64,
    count:i32,
    big:i8,
    ratio:f32,
    on:u8,
    flags:bit_set[Flag_V2;u16],
    parts:[2]Part_V2,
    mesh:base.Asset_Id,
    id:base.Entity_Id,
    target:base.Entity,
    added:f32,
    cache:u32 `mirai:"transient"`,
}

@(private="file")
bytes_of :: proc(value:^$T) -> []u8 {return ([^]u8)(value)[:size_of(T)]}

@(private="file")
schemas_equal :: proc(t:^testing.T,a,b:^Schema) {
    testing.expect_value(t,len(a.types),len(b.types))
    testing.expect_value(t,len(a.fields),len(b.fields))
    testing.expect_value(t,len(a.choices),len(b.choices))
    if len(a.types)!=len(b.types) || len(a.fields)!=len(b.fields) || len(a.choices)!=len(b.choices) {return}
    for type,i in a.types {
        other:=b.types[i]
        testing.expect(t,type.kind==other.kind && type.size==other.size && type.align==other.align && type.name==other.name && type.name_hash==other.name_hash && type.first==other.first && type.count==other.count && type.elem==other.elem)
        testing.expect_value(t,schema_layout_hash(b,Type_Index(i)),schema_layout_hash(a,Type_Index(i)))
    }
    for field,i in a.fields {
        other:=b.fields[i]
        testing.expect(t,field.name==other.name && field.name_hash==other.name_hash && field.type==other.type && field.offset==other.offset && field.flags==other.flags)
        testing.expect(t,field.has_min==other.has_min && field.has_max==other.has_max && field.min==other.min && field.max==other.max && field.step==other.step)
        testing.expect(t,field.precision==other.precision && field.bits==other.bits && field.label==other.label && field.unit==other.unit)
    }
    for choice,i in a.choices {testing.expect(t,choice==b.choices[i])}
}

@(test)
schema_binary_form_round_trips_types_fields_and_choices :: proc(t:^testing.T) {
    Tagged :: struct {
        speed:f32 `mirai:"min=-1,max=20,step=0.5,unit=m/s,precision=0.01,label=Top speed"`,
        lives:u8 `mirai:"bits=3,readonly"`,
        tint:[4]f32 `mirai:"color"`,
        world:matrix[4,4]f32,
        rotation:quaternion128,
        wide:u128,
    }
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    _,ok:=schema_add(&s,Old);testing.expect(t,ok)
    _,ok=schema_add(&s,New);testing.expect(t,ok)
    _,ok=schema_add(&s,Tagged);testing.expect(t,ok)
    testing.expect_value(t,schema_validate(&s),Schema_Error.None)

    w:Writer;writer_init(&w);defer writer_destroy(&w)
    schema_write(&w,&s)
    r:=reader_init(writer_bytes(&w))
    back:Schema
    testing.expect_value(t,schema_read(&r,&back),Schema_Error.None)
    defer schema_destroy(&back)
    testing.expect_value(t,reader_remaining(&r),0)
    schemas_equal(t,&s,&back)

    again:Writer;writer_init(&again);defer writer_destroy(&again)
    schema_write(&again,&back)
    testing.expect(t,mem.compare(writer_bytes(&again),writer_bytes(&w))==0)

    hashes:[dynamic]u64;defer delete(hashes)
    schema_hashes_update(&back,&hashes)
    for hash,i in hashes {testing.expect_value(t,hash,schema_layout_hash(&s,Type_Index(i)))}
}

@(test)
schema_read_survives_truncated_and_mutated_input :: proc(t:^testing.T) {
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    schema_add(&s,Old);schema_add(&s,New)
    w:Writer;writer_init(&w);defer writer_destroy(&w)
    schema_write(&w,&s)
    good:=writer_bytes(&w)
    for cut in 0..<len(good) {
        r:=reader_init(good[:cut])
        back:Schema
        error:=schema_read(&r,&back)
        testing.expect(t,error!=.None)
        testing.expect(t,back.types==nil)
    }
    state:=u64(0xabcdef)
    mutated:=make([]u8,len(good));defer delete(mutated)
    scratch:=make([]u8,1<<16);defer delete(scratch)
    out:Writer;writer_init(&out);defer writer_destroy(&out)
    accepted:=0
    for _ in 0..<4000 {
        copy(mutated,good)
        for _ in 0..<1+fuzz_next(&state)%3 {mutated[fuzz_next(&state)%u64(len(mutated))]=u8(fuzz_next(&state))}
        r:=reader_init(mutated)
        back:Schema
        if schema_read(&r,&back)!=.None {continue}
        accepted+=1
        // Whatever was accepted is safe to walk with values of the declared sizes.
        testing.expect_value(t,schema_validate(&back),Schema_Error.None)
        hashes:[dynamic]u64
        schema_hashes_update(&back,&hashes)
        delete(hashes)
        for type,index in back.types {
            if int(type.size)>len(scratch) {continue}
            refs:=make([dynamic]Ref,context.temp_allocator)
            refs_collect(&back,Type_Index(index),&refs)
            writer_reset(&out)
            text_write(&out,&back,Type_Index(index),scratch[:type.size],.Line)
            m:Migration
            migration_init(&m,&back,Type_Index(index),&s,0)
            target:=make([]u8,m.dst_size,context.temp_allocator)
            migration_apply(&m,target,scratch[:type.size],1)
            migration_destroy(&m)
        }
        schema_destroy(&back)
        free_all(context.temp_allocator)
    }
    testing.expect(t,accepted>0)
}

@(private="file")
schema_built :: proc(types:[]Type,fields:[]Field,choices:[]Choice) -> Schema_Error {
    s:Schema;schema_init(&s)
    defer {delete(s.types);delete(s.fields);delete(s.choices);delete(s.lookup)}
    append(&s.types,..types);append(&s.fields,..fields);append(&s.choices,..choices)
    return schema_validate(&s)
}

@(test)
schema_validation_rejects_what_a_walk_could_not_survive :: proc(t:^testing.T) {
    f32_type:=Type{kind=.Float,size=4,align=4,elem=TYPE_NONE}
    testing.expect_value(t,schema_built({f32_type},nil,nil),Schema_Error.None)
    testing.expect_value(t,schema_built({{kind=.Float,size=3,align=1}},nil,nil),Schema_Error.Invalid_Type)
    testing.expect_value(t,schema_built({{kind=.Float,size=4,align=3}},nil,nil),Schema_Error.Invalid_Type)
    testing.expect_value(t,schema_built({{kind=.Asset,size=8,align=8}},nil,nil),Schema_Error.Invalid_Type)
    // A struct that refers to itself, and one that refers to a later type.
    testing.expect_value(t,schema_built({{kind=.Struct,size=4,align=4,first=0,count=1}},{{type=0}},nil),Schema_Error.Invalid_Field)
    testing.expect_value(t,schema_built({{kind=.Struct,size=4,align=4,first=0,count=1},f32_type},{{type=1}},nil),Schema_Error.Invalid_Field)
    // Fields past the end, overlapping, and a field range outside the table.
    testing.expect_value(t,schema_built({f32_type,{kind=.Struct,size=4,align=4,first=0,count=1}},{{type=0,offset=1}},nil),Schema_Error.Invalid_Field)
    testing.expect_value(t,schema_built({f32_type,{kind=.Struct,size=8,align=4,first=0,count=2}},{{type=0,offset=0},{type=0,offset=2}},nil),Schema_Error.Invalid_Field)
    testing.expect_value(t,schema_built({f32_type,{kind=.Struct,size=8,align=4,first=1,count=1}},{{type=0}},nil),Schema_Error.Invalid_Field)
    testing.expect_value(t,schema_built({f32_type,{kind=.Struct,size=8,align=4,first=0,count=2}},{{type=0,offset=0},{type=0,offset=4}},nil),Schema_Error.None)
    // Arrays: no element type, an element after it, more elements than bytes.
    testing.expect_value(t,schema_built({{kind=.Array,size=8,align=4,count=2,elem=TYPE_NONE}},nil,nil),Schema_Error.Invalid_Type)
    testing.expect_value(t,schema_built({{kind=.Array,size=8,align=4,count=2,elem=0}},nil,nil),Schema_Error.Invalid_Type)
    testing.expect_value(t,schema_built({f32_type,{kind=.Array,size=8,align=4,count=3,elem=0}},nil,nil),Schema_Error.Invalid_Type)
    testing.expect_value(t,schema_built({f32_type,{kind=.Array,size=8,align=4,count=max(u32),elem=0}},nil,nil),Schema_Error.Invalid_Type)
    // Choices outside the table, and a bit that the set does not have.
    testing.expect_value(t,schema_built({{kind=.Enum,size=1,align=1,first=0,count=2}},nil,{{"A",0}}),Schema_Error.Invalid_Choice)
    testing.expect_value(t,schema_built({{kind=.Bit_Set,size=1,align=1,first=0,count=1}},nil,{{"A",8}}),Schema_Error.Invalid_Choice)
    testing.expect_value(t,schema_built({{kind=.Bit_Set,size=1,align=1,first=0,count=1}},nil,{{"A",7}}),Schema_Error.None)
    // Nesting deeper than any walk is allowed to recurse.
    deep:=make([dynamic]Type,context.temp_allocator)
    append(&deep,f32_type)
    for i in 0..<SCHEMA_MAX_DEPTH+1 {append(&deep,Type{kind=.Array,size=4,align=4,count=1,elem=Type_Index(i)})}
    testing.expect_value(t,schema_built(deep[:SCHEMA_MAX_DEPTH+1],nil,nil),Schema_Error.None)
    testing.expect_value(t,schema_built(deep[:],nil,nil),Schema_Error.Too_Deep)
}

@(test)
schema_import_copies_each_type_once :: proc(t:^testing.T) {
    src:Schema;schema_init(&src);defer schema_destroy(&src)
    old,_:=schema_add(&src,Old)
    new,_:=schema_add(&src,New)
    dst:Schema;schema_init(&dst);defer schema_destroy(&dst)
    hashes:[dynamic]u64;defer delete(hashes)
    link:Schema_Import;schema_import_init(&link,&dst,&hashes,&src);defer schema_import_destroy(&link)
    imported:=schema_import(&link,old)
    count:=len(dst.types)
    testing.expect_value(t,schema_import(&link,old),imported)
    testing.expect_value(t,len(dst.types),count)
    testing.expect_value(t,schema_layout_hash(&dst,imported),schema_layout_hash(&src,old))
    testing.expect_value(t,schema_type(&dst,imported).name,"Old")
    testing.expect_value(t,schema_validate(&dst),Schema_Error.None)
    testing.expect_value(t,schema_import(&link,TYPE_NONE),TYPE_NONE)

    // Another link into the same schema finds what is already there.
    other:Schema_Import;schema_import_init(&other,&dst,&hashes,&src);defer schema_import_destroy(&other)
    testing.expect_value(t,schema_import(&other,old),imported)
    testing.expect_value(t,len(dst.types),count)
    added:=schema_import(&other,new)
    testing.expect(t,added!=imported && len(dst.types)>count)
    testing.expect_value(t,schema_layout_hash(&dst,added),schema_layout_hash(&src,new))
    testing.expect_value(t,len(schema_fields(&dst,added)),len(schema_fields(&src,new)))
    testing.expect_value(t,schema_validate(&dst),Schema_Error.None)
}

@(test)
value_write_zeroes_padding_transient_fields_and_text_tails :: proc(t:^testing.T) {
    Padded :: struct {a:u8,b:u32,name:[8]u8 `mirai:"text"`,cache:u16 `mirai:"transient"`,c:u8}
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    type,_:=schema_add(&s,Padded)
    layout:Layout;layout_init(&layout,&s,type);defer layout_destroy(&layout)
    testing.expect(t,!layout.dense)
    values:[2]Padded
    mem.set(&values,0xee,size_of(values))
    for &value,i in values {
        value.a,value.b,value.c=u8(i+1),0x11223344,9
        value.name={'h','i',0,'x','x','x','x','x'}
        value.cache=0xffff
    }
    images:[2*size_of(Padded)]u8
    value_write(&layout,images[:],&values,2)
    expected:[2]Padded
    for &value,i in expected {
        value.a,value.b,value.c=u8(i+1),0x11223344,9
        value.name={'h','i',0,0,0,0,0,0}
    }
    testing.expect(t,mem.compare(images[:],bytes_of(&expected))==0)

    Dense :: struct {a:u32,b:[3]f32,c:u64}
    dense_type,_:=schema_add(&s,Dense)
    dense:Layout;layout_init(&dense,&s,dense_type);defer layout_destroy(&dense)
    testing.expect(t,dense.dense)
    source:=Dense{1,{2,3,4},5}
    image:[size_of(Dense)]u8
    value_write(&dense,image[:],&source,1)
    testing.expect(t,mem.compare(image[:],bytes_of(&source))==0)
}

@(test)
migration_with_the_same_layout_is_one_copy :: proc(t:^testing.T) {
    Plain :: struct {a:u32,b:[3]f32,kind:Kind_V1,id:base.Entity_Id}
    a:Schema;schema_init(&a);defer schema_destroy(&a)
    b:Schema;schema_init(&b);defer schema_destroy(&b)
    schema_add(&b,Old)
    type_a,_:=schema_add(&a,Plain)
    type_b,_:=schema_add(&b,Plain)
    m:Migration;migration_init(&m,&a,type_a,&b,type_b);defer migration_destroy(&m)
    testing.expect(t,m.identical)
    testing.expect_value(t,m.added+len(m.removed)+len(m.incompatible),0)
    source:=[3]Plain{{1,{1,2,3},.Sphere,7},{2,{4,5,6},.Capsule,8},{3,{7,8,9},.Box,9}}
    target:[3]Plain
    value_read(&m,&target,bytes_of(&source),3)
    testing.expect(t,target==source)

    // A transient field keeps the layout hash but is never copied.
    With_Cache :: struct {a:u32,cache:u32 `mirai:"transient"`}
    type_c,_:=schema_add(&a,With_Cache)
    type_d,_:=schema_add(&b,With_Cache)
    cached:Migration;migration_init(&cached,&a,type_c,&b,type_d);defer migration_destroy(&cached)
    testing.expect(t,!cached.identical)
    from:=With_Cache{5,99}
    to,default:With_Cache
    default.cache=42
    value_read(&cached,&to,bytes_of(&from),1,&default)
    testing.expect(t,to==With_Cache{5,0})
}

@(test)
migration_matches_fields_by_name_and_converts_them :: proc(t:^testing.T) {
    old_schema:Schema;schema_init(&old_schema);defer schema_destroy(&old_schema)
    new_schema:Schema;schema_init(&new_schema);defer schema_destroy(&new_schema)
    old_type,_:=schema_add(&old_schema,Old)
    new_type,_:=schema_add(&new_schema,New)
    // The stored schema is the one a file would carry.
    w:Writer;writer_init(&w);defer writer_destroy(&w)
    schema_write(&w,&old_schema)
    r:=reader_init(writer_bytes(&w))
    stored:Schema
    testing.expect_value(t,schema_read(&r,&stored),Schema_Error.None)
    defer schema_destroy(&stored)

    m:Migration;migration_init(&m,&stored,old_type,&new_schema,new_type);defer migration_destroy(&m)
    testing.expect(t,!m.identical)
    testing.expect_value(t,m.added,2)   // New.added, and Part_V2.weight
    // Old.gone; Old.cache is transient on both sides, so nothing of it is lost.
    testing.expect(t,len(m.removed)==1 && m.removed[0]=="gone")

    old:=[2]Old{
        {id=0xaa,target=base.Entity(0xbb),mesh={1,2},speed=2.5,count=200,big=-1000,ratio=0.1,on=true,flags={.Static,.Debris},
            parts={{{1,2,3},.Sphere},{{4,5,6},.Box},{{7,8,9},.Capsule}},name={'c','r','a','t','e',0,0,0},gone=77,cache=5},
        {id=0xcc,speed=-1,count=3,big=100,ratio=1e300,on=false,flags={.Dynamic},parts={0={{0,0,1},.Capsule}},name={'a','b','c','d','e','f','g','h'}},
    }
    layout:Layout;layout_init(&layout,&old_schema,old_type);defer layout_destroy(&layout)
    images:[2*size_of(Old)]u8
    value_write(&layout,images[:],&old,2)

    default:New
    default.added=1.5
    default.flags={.Trigger}
    default.cache=9
    default.name={0=0xff,12=0xff}
    default.parts[0].weight=3
    default.parts[1].weight=4
    default.parts[0].offset[3]=1
    default.parts[0].kind=.Mesh
    default.parts[1].kind=.Mesh
    out:[2]New
    value_read(&m,&out,images[:],2,&default)

    first:=out[0]
    testing.expect_value(t,first.id,base.Entity_Id(0xaa))
    testing.expect_value(t,first.target,base.Entity(0xbb))
    testing.expect_value(t,first.mesh,base.Asset_Id{1,2})
    testing.expect_value(t,first.speed,2.5)
    testing.expect_value(t,first.count,i32(200))
    testing.expect_value(t,first.big,i8(-128))
    testing.expect_value(t,first.ratio,f32(0.1))
    testing.expect_value(t,first.on,u8(1))
    testing.expect(t,first.flags==bit_set[Flag_V2;u16]{.Static,.Debris,.Trigger})
    testing.expect_value(t,first.parts[0].kind,Kind_V2.Sphere)
    testing.expect_value(t,first.parts[1].kind,Kind_V2.Box)
    testing.expect_value(t,first.parts[0].offset,[4]f32{1,2,3,1})
    testing.expect_value(t,first.parts[1].offset,[4]f32{4,5,6,0})
    testing.expect_value(t,first.parts[0].weight,3.0)
    testing.expect_value(t,first.parts[1].weight,4.0)
    testing.expect_value(t,text_field(first.name[:]),"crate")
    testing.expect_value(t,first.name[12],u8(0))
    testing.expect_value(t,first.added,f32(1.5))
    testing.expect_value(t,first.cache,u32(0))

    second:=out[1]
    testing.expect_value(t,second.speed,-1.0)
    testing.expect_value(t,second.big,i8(100))
    testing.expect(t,second.ratio-second.ratio!=0) // 1e300 is past the largest f32
    testing.expect(t,second.flags==bit_set[Flag_V2;u16]{.Trigger})
    testing.expect_value(t,second.parts[0].kind,Kind_V2.Mesh) // Capsule is gone: the default stays
    testing.expect_value(t,text_field(second.name[:]),"abcdefgh")
    testing.expect_value(t,second.id,base.Entity_Id(0xcc))
}

@(test)
migration_converts_numbers_by_value_and_saturates :: proc(t:^testing.T) {
    From :: struct {a:i32,b:u16,c:f64,d:f32,e:i64,f:bool,g:u64,h:f32,i:i8,j:f64,k:u8,l:f64,m:Kind_V1,n:i32,o:i32,p:f16}
    To :: struct {a:u8,b:i8,c:i16,d:u32,e:f32,f:f64,g:i64,h:bool,i:u64,j:u64,k:b32,l:f32,m:i32,n:Kind_V2,o:Kind_V2,p:f64}
    a:Schema;schema_init(&a);defer schema_destroy(&a)
    b:Schema;schema_init(&b);defer schema_destroy(&b)
    from_type,_:=schema_add(&a,From)
    to_type,_:=schema_add(&b,To)
    m:Migration;migration_init(&m,&a,from_type,&b,to_type);defer migration_destroy(&m)
    testing.expect_value(t,len(m.incompatible),0)
    nan:=transmute(f64)u64(0x7ff8000000000000)
    cases:=[?]struct {from:From,to:To}{
        {{a=-5,b=300,c=1e9,d=-3.9,e=1<<40,f=true,g=max(u64),h=0,i=-1,j=nan,k=2,l=0.5,m=.Capsule,n=7,o=3,p=1.5},
         {a=0,b=127,c=32767,d=0,e=1<<40,f=1,g=max(i64),h=false,i=0,j=0,k=true,l=0.5,m=2,n=.Box,o=.Mesh,p=1.5}},
        {{a=255,b=5,c=-1e9,d=4.9,e=-3,f=false,g=12,h=-0.5,i=100,j=1e30,k=0,l=-2,m=.Box,n=0,o=8,p=-2},
         {a=255,b=5,c=-32768,d=4,e=-3,f=0,g=12,h=true,i=100,j=max(u64),k=false,l=-2,m=0,n=.Sphere,o=.Mesh,p=-2}},
        {{a=256,c=12.9,j=-1},{a=255,c=12,n=.Sphere,o=.Sphere}},
    }
    for entry in cases {
        from:=entry.from
        out:To
        default:To
        default.o=.Mesh
        value_read(&m,&out,bytes_of(&from),1,&default)
        testing.expect_value(t,out,entry.to)
    }
}

@(test)
migration_loops_over_arrays_and_keeps_what_follows_them :: proc(t:^testing.T) {
    Inner_A :: struct {x:u8,y:u16}
    Inner_B :: struct {y:u32,x:u8}
    From :: struct {before:u32,items:[4]Inner_A,grid:[2][3]Inner_A,after:u32,tail:u32}
    To :: struct {before:u32,items:[6]Inner_B,grid:[3][2]Inner_B,after:u32,tail:u32}
    a:Schema;schema_init(&a);defer schema_destroy(&a)
    b:Schema;schema_init(&b);defer schema_destroy(&b)
    from_type,_:=schema_add(&a,From)
    to_type,_:=schema_add(&b,To)
    m:Migration;migration_init(&m,&a,from_type,&b,to_type);defer migration_destroy(&m)
    from:=From{before=1,after=2,tail=3}
    for &item,i in from.items {item={u8(i+1),u16(100+i)}}
    for &row,i in from.grid {
        for &cell,j in row {cell={u8(10*i+j),u16(1000+10*i+j)}}
    }
    default:To
    for &item in default.items {item={9,9}}
    out:To
    value_read(&m,&out,bytes_of(&from),1,&default)
    testing.expect_value(t,out.before,u32(1))
    testing.expect_value(t,out.after,u32(2))
    testing.expect_value(t,out.tail,u32(3))
    for item,i in out.items {
        if i<4 {testing.expect_value(t,item,Inner_B{u32(100+i),u8(i+1)})}
        else {testing.expect_value(t,item,Inner_B{9,9})}
    }
    for i in 0..<3 {
        for j in 0..<2 {
            expected:=i<2?Inner_B{u32(1000+10*i+j),u8(10*i+j)}:Inner_B{}
            testing.expect_value(t,out.grid[i][j],expected)
        }
    }
}

@(test)
migration_leaves_fields_of_another_shape_at_their_default :: proc(t:^testing.T) {
    From :: struct {a:[3]f32,b:f32,c:Part_V1,d:base.Asset_Id,e:f32}
    To :: struct {a:f32,b:[3]f32,c:u32,d:u64,e:Kind_V2}
    a:Schema;schema_init(&a);defer schema_destroy(&a)
    b:Schema;schema_init(&b);defer schema_destroy(&b)
    from_type,_:=schema_add(&a,From)
    to_type,_:=schema_add(&b,To)
    m:Migration;migration_init(&m,&a,from_type,&b,to_type);defer migration_destroy(&m)
    testing.expect(t,slice.equal(m.incompatible[:],[]string{"a","b","c","d","e"}),fmt.tprint(m.incompatible))
    from:=From{a={1,2,3},b=4,d={5,6},e=1}
    default:=To{a=7,b={8,9,10},c=11,d=12,e=.Mesh}
    out:To
    value_read(&m,&out,bytes_of(&from),1,&default)
    testing.expect_value(t,out,default)
}

// A field renamed in code says the names it had: a value stored under any of
// them is read, through two renames too; a stored field the type has under no
// name is listed by its path, and an earlier name that is another field's is
// refused.
@(test)
a_renamed_field_keeps_its_value_through_each_name_it_had :: proc(t:^testing.T) {
    Shape_V1 :: struct {radius:f32,sides:u8}
    Shape_V3 :: struct {radius:f32}
    Lamp_V1 :: struct {power:f32,gone:u32,shape:Shape_V1}
    Lamp_V2 :: struct {strength:f32 `mirai:"was=power"`,shape:Shape_V1}
    Lamp_V3 :: struct {force:f32 `mirai:"was=strength power"`,shape:Shape_V3}
    Clash :: struct {power:f32,force:f32 `mirai:"was=power"`}
    now:Schema;schema_init(&now);defer schema_destroy(&now)
    now_type,_:=schema_add(&now,Lamp_V3)
    stored:Schema;schema_init(&stored);defer schema_destroy(&stored)
    v1,_:=schema_add(&stored,Lamp_V1)
    v2,_:=schema_add(&stored,Lamp_V2)
    first:=Lamp_V1{power=4,gone=9,shape={2,6}}
    second:=Lamp_V2{strength=4,shape={2,6}}
    cases:=[?]struct {from:Type_Index,value:[]u8,removed:[]string} {
        {v1,bytes_of(&first),{"shape.sides","gone"}},
        {v2,bytes_of(&second),{"shape.sides"}},
    }
    for entry in cases {
        m:Migration;migration_init(&m,&stored,entry.from,&now,now_type);defer migration_destroy(&m)
        out:Lamp_V3
        value_read(&m,&out,entry.value,1)
        testing.expect_value(t,out,Lamp_V3{force=4,shape={2}})
        testing.expect_value(t,m.added,0)
        testing.expect(t,slice.equal(m.removed[:],entry.removed),fmt.tprint(m.removed))
    }
    _,added:=schema_add(&now,Clash)
    testing.expect(t,!added && strings.contains(now.error,"was=power"),now.error)
}

@(private="file") Action :: distinct u8
@(private="file") Action_Mask :: distinct u64
@(private="file") Team :: distinct u8
@(private="file") Aim :: struct {action:Action,held:Action_Mask,team:Team}

// The values and the bits of an integer whose numbers are generated move by
// name, through the schema a file carries, and a full mask stays full; one
// with fixed numbers keeps them.
@(test)
generated_numbers_move_by_name_and_fixed_ones_stay :: proc(t:^testing.T) {
    saved:Schema;schema_init(&saved);defer schema_destroy(&saved)
    saved.named=make(map[typeid]Named,context.temp_allocator)
    saved.named[Action]={choices={{"jump",1},{"aim",2}},by_name=true}
    saved.named[Action_Mask]={choices={{"jump",1},{"aim",2}},bits=true,by_name=true}
    saved.named[Team]={choices={{"red",1},{"blue",2}}}
    saved_type,_:=schema_add(&saved,Aim)
    w:Writer;writer_init(&w);defer writer_destroy(&w)
    schema_write(&w,&saved)
    r:=reader_init(writer_bytes(&w))
    stored:Schema
    if !testing.expect_value(t,schema_read(&r,&stored),Schema_Error.None) {return}
    defer schema_destroy(&stored)
    action:=schema_field(&stored,saved_type,base.name_hash("action"))
    testing.expect(t,action!=nil && stored.types[action.type].by_name)

    now:Schema;schema_init(&now);defer schema_destroy(&now)
    now.named=make(map[typeid]Named,context.temp_allocator)
    now.named[Action]={choices={{"crouch",1},{"jump",2},{"aim",3}},by_name=true}
    now.named[Action_Mask]={choices={{"crouch",1},{"jump",2},{"aim",3}},bits=true,by_name=true}
    now.named[Team]={choices={{"green",1},{"red",2},{"blue",3}}}
    now_type,_:=schema_add(&now,Aim)
    testing.expect(t,schema_layout_hash(&stored,saved_type)!=schema_layout_hash(&now,now_type))
    m:Migration;migration_init(&m,&stored,saved_type,&now,now_type);defer migration_destroy(&m)
    source:=[2]Aim{{action=2,held=Action_Mask(1<<1|1<<2),team=2},{held=max(Action_Mask)}}
    out:[2]Aim
    value_read(&m,&out,bytes_of(&source),2)
    testing.expect_value(t,out[0],Aim{action=3,held=Action_Mask(1<<2|1<<3),team=2})
    testing.expect_value(t,out[1].held,max(Action_Mask))

    // An action renamed in code: what was saved takes the new name and keeps
    // its values; the names of fixed numbers and a name taken stay.
    testing.expect_value(t,schema_choice_rename(&stored,"aim","point"),2)
    testing.expect_value(t,schema_choice_rename(&stored,"red","green"),0)
    testing.expect_value(t,schema_choice_rename(&stored,"jump","point"),0)
    later:Schema;schema_init(&later);defer schema_destroy(&later)
    later.named=make(map[typeid]Named,context.temp_allocator)
    later.named[Action]={choices={{"jump",1},{"point",2}},by_name=true}
    later.named[Action_Mask]={choices={{"jump",1},{"point",2}},bits=true,by_name=true}
    later.named[Team]={choices={{"red",1},{"blue",2}}}
    later_type,_:=schema_add(&later,Aim)
    testing.expect_value(t,schema_layout_hash(&stored,saved_type),schema_layout_hash(&later,later_type))
}

@(test)
paths_read_and_write_every_kind_of_field :: proc(t:^testing.T) {
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    type,_:=schema_add(&s,Old)
    value:Old
    data:=bytes_of(&value)
    set :: proc(t:^testing.T,s:^Schema,type:Type_Index,data:[]u8,path:string,value:Value,loc:=#caller_location) {
        testing.expect_value(t,value_set(s,type,data,path,value),Path_Error.None,loc)
    }
    set(t,&s,type,data,"speed",f64(2.5))
    set(t,&s,type,data,"count",i64(200))
    set(t,&s,type,data,"big",i64(-5))
    set(t,&s,type,data,"ratio",u64(3))
    set(t,&s,type,data,"on",true)
    set(t,&s,type,data,"id",base.Entity_Id(0xabc))
    set(t,&s,type,data,"target",base.Entity(77))
    set(t,&s,type,data,"mesh",base.Asset_Id{1,2})
    set(t,&s,type,data,"flags",u64(1))
    set(t,&s,type,data,"flags.Debris",true)
    set(t,&s,type,data,"flags.Static",false)
    set(t,&s,type,data,"parts[2].kind","Capsule")
    set(t,&s,type,data,"parts[1].kind",i64(1))
    set(t,&s,type,data,"parts[2].offset[1]",f64(-4))
    set(t,&s,type,data,"name","crate")
    set(t,&s,type,data,"name[7]",u64(33))
    set(t,&s,type,data,"count",f64(12))
    testing.expect_value(t,value.speed,f32(2.5))
    testing.expect_value(t,value.count,u8(12))
    testing.expect_value(t,value.big,i64(-5))
    testing.expect_value(t,value.ratio,3.0)
    testing.expect(t,value.on)
    testing.expect_value(t,value.id,base.Entity_Id(0xabc))
    testing.expect_value(t,value.mesh,base.Asset_Id{1,2})
    testing.expect(t,value.flags==bit_set[Flag_V1;u8]{.Debris})
    testing.expect_value(t,value.parts[2].kind,Kind_V1.Capsule)
    testing.expect_value(t,value.parts[1].kind,Kind_V1.Sphere)
    testing.expect_value(t,value.parts[2].offset[1],f32(-4))
    testing.expect_value(t,value.name,[8]u8{'c','r','a','t','e',0,0,33})

    get :: proc(t:^testing.T,s:^Schema,type:Type_Index,data:[]u8,path:string,expected:Value,loc:=#caller_location) {
        got,error:=value_get(s,type,data,path)
        testing.expect_value(t,error,Path_Error.None,loc)
        testing.expect_value(t,got,expected,loc)
    }
    get(t,&s,type,data,"speed",f64(2.5))
    get(t,&s,type,data,"count",u64(12))
    get(t,&s,type,data,"big",i64(-5))
    get(t,&s,type,data,"on",true)
    get(t,&s,type,data,"id",base.Entity_Id(0xabc))
    get(t,&s,type,data,"target",base.Entity(77))
    get(t,&s,type,data,"mesh",base.Asset_Id{1,2})
    get(t,&s,type,data,"flags",u64(4))
    get(t,&s,type,data,"flags.Debris",true)
    get(t,&s,type,data,"flags.Dynamic",false)
    get(t,&s,type,data,"parts[2].kind","Capsule")
    get(t,&s,type,data,"parts[2].offset[1]",f64(-4))
    get(t,&s,type,data,"name","crate")
    value.parts[0].kind=Kind_V1(9)
    get(t,&s,type,data,"parts[0].kind",i64(9))

    part,bytes,error:=value_slice(&s,type,data,"parts[2].offset")
    testing.expect_value(t,error,Path_Error.None)
    testing.expect_value(t,schema_type(&s,part).count,u32(3))
    testing.expect_value(t,len(bytes),12)
    testing.expect(t,raw_data(bytes)==rawptr(&value.parts[2].offset))
    whole,all,whole_error:=value_slice(&s,type,data,"")
    testing.expect(t,whole==type && len(all)==size_of(Old) && whole_error==.None)
}

@(test)
paths_report_what_is_wrong_and_where :: proc(t:^testing.T) {
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    type,_:=schema_add(&s,Old)
    value:Old
    data:=bytes_of(&value)
    resolve :: proc(t:^testing.T,s:^Schema,type:Type_Index,path:string,expected:Path_Error,at:int,loc:=#caller_location) {
        _,error,where_:=path_resolve(s,type,path)
        testing.expect_value(t,error,expected,loc)
        testing.expect_value(t,where_,at,loc)
    }
    resolve(t,&s,type,"nope",.Unknown_Field,0)
    resolve(t,&s,type,"parts[1].nope",.Unknown_Field,9)
    resolve(t,&s,type,"parts[3]",.Out_Of_Range,5)
    resolve(t,&s,type,"parts[99999999999]",.Out_Of_Range,5)
    resolve(t,&s,type,"speed[0]",.Not_An_Array,5)
    resolve(t,&s,type,"speed.x",.Not_A_Struct,6)
    resolve(t,&s,type,"parts[",.Syntax,6)
    resolve(t,&s,type,"parts[x]",.Syntax,6)
    resolve(t,&s,type,"parts[1]kind",.Syntax,8)
    resolve(t,&s,type,".speed",.Syntax,0)
    resolve(t,&s,type,"parts..kind",.Syntax,6)
    resolve(t,&s,type,"flags.Nope",.Unknown_Member,6)
    resolve(t,&s,type,"flags.Static.x",.Not_A_Struct,12)

    expect :: proc(t:^testing.T,s:^Schema,type:Type_Index,data:[]u8,path:string,value:Value,expected:Path_Error,loc:=#caller_location) {
        testing.expect_value(t,value_set(s,type,data,path,value),expected,loc)
    }
    expect(t,&s,type,data,"count",i64(256),.Out_Of_Range)
    expect(t,&s,type,data,"count",i64(-1),.Out_Of_Range)
    expect(t,&s,type,data,"count",f64(1.5),.Out_Of_Range)
    expect(t,&s,type,data,"count","x",.Wrong_Type)
    expect(t,&s,type,data,"big",u64(1<<63),.Out_Of_Range)
    expect(t,&s,type,data,"speed",f64(1e300),.Out_Of_Range)
    expect(t,&s,type,data,"speed",true,.Wrong_Type)
    expect(t,&s,type,data,"on",i64(1),.Wrong_Type)
    expect(t,&s,type,data,"flags",u64(256),.Out_Of_Range)
    expect(t,&s,type,data,"flags.Static",u64(1),.Wrong_Type)
    expect(t,&s,type,data,"parts[0].kind","Cone",.Unknown_Member)
    expect(t,&s,type,data,"parts[0].kind",i64(3),.Unknown_Member)
    expect(t,&s,type,data,"parts[0].kind",f64(1),.Wrong_Type)
    expect(t,&s,type,data,"name","too long a name",.Too_Long)
    expect(t,&s,type,data,"name",u64(1),.Wrong_Type)
    expect(t,&s,type,data,"id",u64(1),.Wrong_Type)
    expect(t,&s,type,data,"mesh",base.Entity_Id(1),.Wrong_Type)
    expect(t,&s,type,data,"parts",u64(1),.Not_A_Value)
    expect(t,&s,type,data,"parts[0]",u64(1),.Not_A_Value)
    testing.expect(t,value==Old{})
    _,get_error:=value_get(&s,type,data,"parts[0]")
    testing.expect_value(t,get_error,Path_Error.Not_A_Value)
    _,short_error:=value_get(&s,type,data[:4],"big")
    testing.expect_value(t,short_error,Path_Error.Out_Of_Range)
}

@(test)
references_are_found_wherever_a_type_holds_them :: proc(t:^testing.T) {
    Link :: struct {weight:f32,target:base.Entity,meshes:[2]base.Asset_Id}
    Holder :: struct {id:base.Entity_Id,plain:[4]u32,links:[3]Link,owner:base.Entity}
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    type,_:=schema_add(&s,Holder)
    refs:[dynamic]Ref;defer delete(refs)
    testing.expect(t,refs_collect(&s,type,&refs))
    testing.expect_value(t,len(refs),11)
    testing.expect_value(t,refs[0],Ref{u32(offset_of(Holder,id)),.Entity_Id})
    testing.expect_value(t,refs[1],Ref{u32(offset_of(Holder,links)+offset_of(Link,target)),.Entity})
    testing.expect_value(t,refs[2].kind,Type_Kind.Asset)
    testing.expect_value(t,refs[10],Ref{u32(offset_of(Holder,owner)),.Entity})

    values:[2]Holder
    for &value,i in values {
        value.id=base.Entity_Id(i+1)
        value.owner=base.Entity(10)
        for &link in value.links {link.target=base.Entity(20);link.meshes={{1,1},{2,2}}}
    }
    Counts :: struct {entities,ids,assets:int}
    counts:Counts
    refs_visit(refs[:],bytes_of(&values),size_of(Holder),2,proc(kind:Type_Kind,ref:rawptr,user:rawptr) {
        counts:=(^Counts)(user)
        #partial switch kind {
        case .Entity: counts.entities+=1;(^base.Entity)(ref)^+=1000
        case .Entity_Id: counts.ids+=1;(^base.Entity_Id)(ref)^+=1000
        case .Asset: counts.assets+=1;(^base.Asset_Id)(ref)^[0]+=1000
        }
    },&counts)
    testing.expect_value(t,counts,Counts{8,2,12})
    testing.expect_value(t,values[1].id,base.Entity_Id(1002))
    testing.expect_value(t,values[1].links[2].target,base.Entity(1020))
    testing.expect_value(t,values[0].links[1].meshes[1],base.Asset_Id{1002,2})
    testing.expect_value(t,values[0].plain,[4]u32{})

    none:[dynamic]Ref;defer delete(none)
    plain,_:=schema_add(&s,[8]f32)
    testing.expect(t,refs_collect(&s,plain,&none) && len(none)==0)
    Many :: struct {targets:[64]base.Entity}
    many,_:=schema_add(&s,Many)
    testing.expect(t,!refs_collect(&s,many,&none,limit=63))
    clear(&none)
    testing.expect(t,refs_collect(&s,many,&none,limit=64) && len(none)==64)
}

// A value passes only with what its schema allows, and the first part that
// does not is named by its path.
@(test)
value_check_names_the_first_part_its_schema_does_not_allow :: proc(t:^testing.T) {
    Part :: struct {offset:[3]f32 `mirai:"min=-1,max=1"`,kind:Kind_V1}
    Checked :: struct {
        count:i32 `mirai:"min=0,max=10"`,
        on:bool,
        flags:bit_set[Flag_V1;u8],
        parts:[2]Part,
        mesh:base.Asset_Id,
    }
    s:Schema;schema_init(&s);defer schema_destroy(&s)
    type,_:=schema_add(&s,Checked)
    refuse_mesh :: proc(user:rawptr,kind:Type_Kind,ref:[]u8) -> bool {return kind!=.Asset || ref[0]==0}
    nan:=transmute(f32)u32(0x7fc00000)
    Case :: struct {name:string,value:Checked,fault:Value_Fault,path:string}
    good:=Checked{count=3,on=true,flags={.Dynamic},parts={{{0,1,-1},.Sphere},{{0.5,0,0},.Box}}}
    cases:=[]Case{
        {"allowed",good,.None,""},
        {"not finite",{parts={{},{{0,nan,0},.Box}}},.Not_Finite,"parts[1].offset[1]"},
        {"over the max of an array field",{parts={{{0,0,2},.Box},{}}},.Above_Max,"parts[0].offset[2]"},
        {"under the min of an integer",{count=-1},.Below_Min,"count"},
        {"an enum of no value",{parts={{},{{},Kind_V1(7)}}},.Not_A_Choice,"parts[1].kind"},
        {"a bit of no member",{flags=transmute(bit_set[Flag_V1;u8])u8(0x80)},.Not_A_Choice,"flags"},
        {"a bool that is not 0 or 1",{on=transmute(bool)u8(2)},.Not_A_Choice,"on"},
        {"a reference refused",{mesh={1,1}},.Refused,"mesh"},
    }
    path:[64]u8
    for c in cases {
        value:=c.value
        problem:=value_check(&s,type,bytes_of(&value),path[:],refuse_mesh)
        testing.expectf(t,problem.fault==c.fault && problem.path==c.path,"%s: %v at %q",c.name,problem.fault,problem.path)
    }
    testing.expect_value(t,value_check(&s,type,bytes_of(&good)[:4],path[:]).fault,Value_Fault.None)
}
