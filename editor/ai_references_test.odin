package editor

import "core:encoding/base64"
import "core:os"
import "core:testing"
import "mirai:editor/acp"
import "mirai:std/base"

@(test)
the_reference_images_of_a_message_go_with_its_prompt_after_its_text :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-references");if root=="" {return}
    s:=Session{project_root=root}
    task:Ai_Task
    base.text_set(task.name[:],"7-0")
    testing.expect(t,os.make_directory_all(ai_task_path(&s,&task,""))==nil)
    image:=[]u8{0xff,0xd8,0xff,0xe0,1,2,3,0xff,0xd9}
    testing.expect(t,os.write_entire_file(ai_task_path(&s,&task,ai_reference_file(1)),image)==nil)
    task.references=1
    content:=make([dynamic]acp.Content,context.temp_allocator)
    append(&content,acp.Content{kind=.Text,text="make it look like this"})
    problem,ok:=ai_references_content(&s,&task,&content)
    testing.expectf(t,ok,"the reference goes: %s",problem)
    testing.expect_value(t,len(content),2)
    if len(content)==2 {
        encoded,_:=base64.encode(image,allocator=context.temp_allocator)
        testing.expect(t,content[1].kind==.Image && content[1].mime_type=="image/jpeg" && content[1].data==encoded,"the image follows the text, whole")
    }
    // One the turn says it has but whose file is gone stops the prompt.
    task.references=2
    clear(&content)
    _,ok=ai_references_content(&s,&task,&content)
    testing.expect(t,!ok,"a missing reference is said, not left out")
    testing.expect(t,ai_reference_image("C:/refs/Look.PNG") && ai_reference_image("a.jpeg") && !ai_reference_image("notes.txt"))
}

@(test)
a_reference_image_fits_its_square_keeping_its_proportion :: proc(t:^testing.T) {
    w,h:=ai_fit_size(1600,900,800)
    testing.expect(t,w==800 && h==450,"the longest side takes the square")
    w,h=ai_fit_size(500,1000,800)
    testing.expect(t,w==400 && h==800)
    w,h=ai_fit_size(640,480,800)
    testing.expect(t,w==640 && h==480,"a smaller one keeps its size")
    // Three by two pixels into two by one: the first covers the first column, the second the other two.
    pixels:=[]u8{0,0,0,255, 30,0,0,255, 200,0,0,255, 60,0,0,255, 90,0,0,255, 100,0,0,255}
    out:[8]u8
    ai_fit_pixels(pixels,3,2,out[:],2,1)
    testing.expect_value(t,out[0],u8(30))
    testing.expect_value(t,out[4],u8(105))
}
