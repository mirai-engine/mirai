package build

import "core:os"
import "core:strings"
import "core:testing"

// A failed refresh says why: what the import program said on its error
// output, else how it ended and the source it was importing.
@(test)
a_failed_refresh_names_the_source_and_how_the_program_ended :: proc(t:^testing.T) {
    said:="package 1 of 2\nimporting /p/assets/rock.png: its source changed\n  rock: 3 assets, 0.2 s\npackage 2 of 2\nimporting /p/assets/tree.gltf: this engine reads no build of it here\n"
    Case :: struct {state:os.Process_State,said,errors:string,wanted:[]string}
    cases:=[]Case{
        {{exited=true,exit_code=1,success=true},said,"mirai import: package tree: the file is truncated\n",{"package tree: the file is truncated"}},
        {{exited=true,exit_code=9,success=false},said,"",{"crashed or was killed (code 9)","/p/assets/tree.gltf"}},
        {{exited=true,exit_code=3,success=true},said,"",{"exit code 3","/p/assets/tree.gltf"}},
        {{exited=true,exit_code=9,success=false},"","",{"crashed or was killed (code 9)","before importing any source"}},
    }
    for c in cases {
        message:=imports_failure(c.state,c.said,c.errors)
        for wanted in c.wanted {testing.expectf(t,strings.contains(message,wanted),"%q lacks %q",message,wanted)}
        testing.expectf(t,!strings.contains(message,"rock.png"),"only the source it was importing: %q",message)
    }
}
