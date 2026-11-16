package main

import "core:fmt"
import "core:os"
import "core:strings"

// The rule every command follows: --help or -h prints its usage and does
// nothing else, and an argument that starts with '-' is an option it knows or
// an error, never a value given by position. What follows a -- belongs to
// another program, as do the flags check and test pass to the compiler.

// Runs the command args[0] with the rest, or prints its usage when asked.
command_run :: proc(root:string,args:[]string) -> int {
    for command in COMMANDS {
        if command.name!=args[0] {continue}
        if help_asked(args[1:]) {
            command_usage(args[0],os.stdout)
            return 0
        }
        return command.run(root,args[1:])
    }
    fmt.eprintfln("mirai: unknown command '%s'",args[0])
    usage()
    return 2
}

help_asked :: proc(args:[]string) -> bool {
    for arg in args {
        if arg=="--" {return false}
        if arg=="--help" || arg=="-h" {return true}
    }
    return false
}

command_usage :: proc(name:string,out:^os.File) {
    first:=true
    for command in COMMANDS {
        if command.name!=name {continue}
        fmt.fprintfln(out,"%s mirai %s",first?"Usage:":"      ",command.usage)
        first=false
    }
}

positional :: proc(arg:string) -> bool {return !strings.has_prefix(arg,"-")}

// Refuses an argument command does not take, with its usage: 2, the exit code of misuse.
argument_unknown :: proc(command,arg:string) -> int {
    argument_refuse(command,arg)
    name:=command
    if space:=strings.index_byte(command,' ');space>=0 {name=command[:space]}
    command_usage(name,os.stderr)
    return 2
}

// What argument_unknown says, without the usage.
argument_refuse :: proc(command,arg:string) {
    if positional(arg) {
        fmt.eprintfln("mirai %s: '%s' is one argument too many",command,arg)
    } else {
        fmt.eprintfln("mirai %s: '%s' is not an option of %s; a name or path that starts with '-' goes as ./%s",command,arg,command,arg)
    }
}

// argument_unknown of the first argument that is not positional; 0 when all are.
positionals_only :: proc(command:string,args:[]string) -> int {
    for arg in args {
        if !positional(arg) {return argument_unknown(command,arg)}
    }
    return 0
}
