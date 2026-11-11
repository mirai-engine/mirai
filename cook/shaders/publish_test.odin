package shaders

import "core:os"
import "core:testing"
import "mirai:std/base"

@(test)
publication_rolls_back_a_failure_at_every_rename_of_the_output_and_tables :: proc(t:^testing.T) {
    Fault :: struct {calls,at:int}
    fail_move :: proc(old_path,new_path:string,user_data:rawptr) -> os.Error {
        fault:=cast(^Fault)user_data
        fault.calls+=1
        if fault.calls==fault.at {return os.General_Error.Invalid_Path}
        return os.rename(old_path,new_path)
    }
    for previous in ([2]bool{true,false}) {
        moves:=6 if previous else 5
        for at in 1..=moves {
            root:=base.test_folder(t,"shaders")
            if root=="" {return}
            output:=path_join(root,"output",allocator=context.temp_allocator)
            staging:=path_join(root,"staging",allocator=context.temp_allocator)
            if previous {
                fixture_write(t,root,"output/manifest.json","old manifest")
                fixture_write(t,root,"output/code.spv","old code")
                fixture_write(t,root,"output/include/program.slang","old program")
            }
            fixture_write(t,root,"render/table.odin","old render table")
            fixture_write(t,root,"rhi/table.odin","old rhi table")
            fixture_write(t,root,"staging/manifest.json","new manifest")
            fixture_write(t,root,"staging/code.spv","new code")
            fixture_write(t,root,"staging/include/program.slang","new program")
            fixture_write(t,root,"next-render.odin","new render table")
            fixture_write(t,root,"next-rhi.odin","new rhi table")
            replacements:=[3]Publication{
                {source=staging,target=output,backup=path_join(root,"old-output",allocator=context.temp_allocator)},
                {source=path_join(root,"next-render.odin",allocator=context.temp_allocator),target=path_join(root,"render/table.odin",allocator=context.temp_allocator),backup=path_join(root,"old-render.odin",allocator=context.temp_allocator)},
                {source=path_join(root,"next-rhi.odin",allocator=context.temp_allocator),target=path_join(root,"rhi/table.odin",allocator=context.temp_allocator),backup=path_join(root,"old-rhi.odin",allocator=context.temp_allocator)},
            }
            fault:=Fault{at=at}
            ready,recovered:=publish(replacements[:],fail_move,&fault)
            testing.expectf(t,!ready && recovered,"previous=%v, failed rename %d rolls back",previous,at)
            testing.expect_value(t,os.exists(output),previous)
            if previous {
                for pair in ([][2]string{{"manifest.json","old manifest"},{"code.spv","old code"},{"include/program.slang","old program"}}) {
                    bytes,err:=os.read_entire_file(path_join(output,pair[0],allocator=context.temp_allocator),context.temp_allocator)
                    testing.expect(t,err==nil)
                    testing.expect_value(t,string(bytes),pair[1])
                }
            }
            for pair in ([][2]string{{"render/table.odin","old render table"},{"rhi/table.odin","old rhi table"}}) {
                bytes,err:=os.read_entire_file(path_join(root,pair[0],allocator=context.temp_allocator),context.temp_allocator)
                testing.expect(t,err==nil)
                testing.expect_value(t,string(bytes),pair[1])
            }
        }
    }
}
