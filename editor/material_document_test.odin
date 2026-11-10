package editor

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(private="file")
WINDOW_PROGRAM :: `//! mirai surface Window_Test
//! parameter color {"default":[0.8,0.3,0.1],"min":0,"max":1,"color":true,"group":"Look"}
namespace Window_Test {
struct Parameters {float3 color;};
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    float band=sin(ctx.uv0.x*20.0);
    s.base_color=lerp(p.color,float3(1),band);
    s.roughness=band;
    return s;
}
}
`

@(test)
the_document_of_a_material_reads_its_program_and_gives_its_picks_to_the_next_message :: proc(t:^testing.T) {
    temporary,_:=os.temp_directory(context.temp_allocator)
    root,_:=strings.replace_all(project.path(temporary,"mirai-material-document",allocator=context.temp_allocator),"\\","/",context.temp_allocator)
    os.remove_all(root)
    defer os.remove_all(root)
    os.make_directory_all(project.path(root,"shaders",allocator=context.temp_allocator))
    path:=project.path(root,"shaders/window_test.slang",allocator=context.temp_allocator)
    testing.expect(t,os.write_entire_file(path,WINDOW_PROGRAM)==nil)
    materials:Materials
    defer materials_free(&materials)
    m:=new(Ai);defer free(m)
    s:=Session{materials=&materials,ai=m,project_root=root,frame=100}
    w:=&materials.document
    base.text_set(w.program[:],"Window_Test")
    base.text_set(w.path[:],path)
    material_document_read(&s,w)
    testing.expect(t,w.loaded)
    testing.expect(t,!w.timed,"a program that does not read the time draws its preview once")

    // The program is read again once its file changes, and one that reads the time moves.
    edited,_:=strings.replace(WINDOW_PROGRAM,"sin(ctx.uv0.x*20.0)","sin(ctx.uv0.x*20.0+ctx.time)",1,context.temp_allocator)
    testing.expect(t,os.write_entire_file(path,edited)==nil)
    s.frame+=MATERIAL_SOURCE_FRAMES
    w.stamp={}
    material_document_read(&s,w)
    testing.expect(t,w.loaded)
    testing.expect(t,w.timed,"a program that reads the time moves its preview")

    // Picking: one alone, then another added, then one taken out.
    material_pick_toggle(w,"color",false)
    material_pick_toggle(w,"roughness",true)
    testing.expect_value(t,w.pick_count,2)
    material_pick_toggle(w,"color",true)
    testing.expect_value(t,w.pick_count,1)
    testing.expect_value(t,base.text_get(w.picks[0][:]),"roughness")
    material_pick_toggle(w,"color",false)
    testing.expect_value(t,w.pick_count,1)
    testing.expect_value(t,base.text_get(w.picks[0][:]),"color")

    // What the next message takes: the picks, the channel and the variant set last.
    w.channel=.Roughness
    base.text_set(w.variants[0].label[:],"Wet")
    w.variant_count,w.chosen=1,1
    material_document_context(m,nil,w)
    testing.expect(t,m.material.open)
    testing.expect_value(t,base.text_get(m.material.program[:]),"Window_Test")
    testing.expect_value(t,m.material.pick_count,1)
    testing.expect_value(t,base.text_get(m.material.channel[:]),"roughness")
    testing.expect_value(t,base.text_get(m.material.variant[:]),"Wet")
    material_document_clear(&s)
    testing.expect(t,!m.material.open && !w.loaded && base.text_get(w.program[:])=="" && w.variant_count==0)
}

@(test)
a_value_of_a_variant_is_a_number_a_bool_or_its_components :: proc(t:^testing.T) {
    Case :: struct {text:string,components:int,is_bool:bool,ok:bool,value:[4]f64}
    cases:=[]Case{
        {"0.25",1,false,true,{0.25,0,0,0}},
        {"[0.5]",1,false,true,{0.5,0,0,0}},
        {"[1,0.5,0.25]",3,false,true,{1,0.5,0.25,0}},
        {"true",1,true,true,{1,0,0,0}},
        {"[1,0.5]",3,false,false,{}},
        {"\"red\"",1,false,false,{}},
        {"0.5",3,false,false,{}},
    }
    for c in cases {
        value:[4]f64
        ok:=material_variant_value(c.text,c.components,c.is_bool,&value)
        testing.expectf(t,ok==c.ok,"%s as %d components: %v",c.text,c.components,ok)
        if ok && c.ok {testing.expectf(t,value==c.value,"%s gives %v",c.text,value)}
    }
}
