package build

import "core:slice"
import "core:testing"

// The command of a linker splits into the arguments it was quoted from, so
// that running it again passes the linker what the compiler passed.
@(test)
a_windows_command_line_splits_into_the_arguments_it_quotes :: proc(t:^testing.T) {
    Case :: struct {line:string,args:[]string}
    cases:=[]Case{
        {`"C:\deps\bin\radlink" "C:/Program Files/x/a-core_builtin$2.obj"   -OUT:"o/l.dll" /DLL`,{`C:\deps\bin\radlink`,`C:/Program Files/x/a-core_builtin$2.obj`,"-OUT:o/l.dll","/DLL"}},
        {`plain "" "a\"b" "end\\" c:\dir\ "two  spaces"`,{"plain","",`a"b`,`end\`,`c:\dir\`,"two  spaces"}},
    }
    for c in cases {
        split:=command_line_split(c.line,context.temp_allocator)
        testing.expectf(t,slice.equal(split,c.args),"%s splits into %v, not %v",c.line,split,c.args)
    }
}
