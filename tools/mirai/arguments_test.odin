package main

import "core:os"
import "core:testing"
import "mirai:std/base"

// --help prints the usage and does nothing else; an argument that starts with
// '-' and is no option of the command is misuse, never a name or a path.
@(test)
every_command_refuses_unknown_options_and_answers_help :: proc(t:^testing.T) {
    Case :: struct {args:[]string,code:int}
    cases:=[]Case{
        {{"new","--help"},0},
        {{"new","x","-h"},0},
        {{"worktree","new","x","--help"},0},
        {{"asset","unpack","a.mesh","--help"},0},
        {{"check","tools/mirai","--help"},0},
        {{"new","--","--help"},2},
        {{"new","--nope","x"},2},
        {{"new","-x"},2},
        {{"new","x","y"},2},
        {{"build","tools","--nope"},2},
        {{"build","engine","--nope"},2},
        {{"build","editor","-x"},2},
        {{"generate","-x"},2},
        {{"doctor","--nope"},2},
        {{"docs","-x"},2},
        {{"deps","--nope"},2},
        {{"locks","-x"},2},
        {{"measure","--nope"},2},
        {{"content","-x"},2},
        {{"worktree","new","-x"},2},
        {{"worktree","new","x","--nope"},2},
        {{"plugin","add","--nope"},2},
        {{"agent","install","-x"},2},
        {{"setup","git","-x"},2},
        {{"setup","slang","--nope"},2},
        {{"shaders","--nope"},2},
        {{"shaders","check","-x"},2},
        {{"capture","-x"},2},
        {{"record","-x"},2},
        {{"play","test","-x"},2},
        {{"render","compare","-x","b.json"},2},
        {{"bench","compare","-x"},2},
        {{"image","diff","a.png","-x"},2},
        {{"asset","unpack","a.mesh","--nope"},2},
        {{"asset","ls","-x"},2},
        {{"asset","dump","-x"},2},
        {{"asset","merge","a","b","c","-x"},2},
        {{"mcp","--nope"},2},
        {{"texts","export","-x"},2},
    }
    // The tool lets a command's allocations go with its process.
    context.allocator=context.temp_allocator
    defer free_all(context.temp_allocator)
    for c in cases {
        testing.expectf(t,command_run("",c.args)==c.code,"mirai %v: exit code other than %d",c.args,c.code)
    }
    for name in ([]string{"--help","-h","--nope","-x","x","y"}) {
        testing.expectf(t,!os.exists(name),"a refused or help command left %s behind",name)
        base.remove_all(name)
    }
}
