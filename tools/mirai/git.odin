package main

import "core:fmt"
import "mirai:cook/build"
import "mirai:project"

// mirai setup git [folder]: git merges and diffs the assets of the clone the
// folder is in through mirai (build.git_setup). Once per clone, and again
// when the engine moved.
setup_git :: proc(root:string,args:[]string) -> int {
    if code:=positionals_only("setup git",args);code!=0 {return code}
    if len(args)>1 {return argument_unknown("setup git",args[1])}
    folder:=len(args)==1?args[0]:"."
    done,error:=build.git_setup(root,folder)
    switch error {
    case .None:
    case .No_Git:            fmt.eprintln("mirai setup git: git was not found: install it and put it in PATH");return 1
    case .No_Repository:     fmt.eprintfln("mirai setup git: %s is not inside a git repository: run git init there first",project.path_absolute(folder));return 1
    case .Plugins_Failed:    fmt.eprintfln("mirai setup git: the project or a plugin of %s does not read, so the kinds of asset of its plugins are not known: mirai doctor %s says what fails",project.path_absolute(folder),folder);return 1
    case .Attributes_Failed: fmt.eprintfln("mirai setup git: could not write the .gitattributes of %s",done.repository);return 1
    case .Settings_Failed:   fmt.eprintfln("mirai setup git: git did not take a setting in the local configuration of %s",done.repository);return 1
    }
    if done.attributes!="" {fmt.printfln("Wrote %s with the kinds of asset of the engine and of its plugins: commit it.",done.attributes)}
    if done.settings>0 {
        fmt.printfln("Git merges and diffs the assets of %s through mirai: %d settings written in its local configuration.",done.repository,done.settings)
    } else {
        fmt.printfln("Git already merges and diffs the assets of %s through mirai.",done.repository)
    }
    return 0
}

// What mirai doctor says of the clone a folder is in, unless it is the one
// already said: whether git has the drivers its .gitattributes names, and
// whether that file has the lines of the kinds of its plugins.
doctor_git :: proc(errors:^int,root,folder:string,said:="") -> (repository:string) {
    state:build.Git_Wiring
    stale:bool
    state,repository,stale=build.git_wiring(root,folder)
    if said!="" && project.path_same(repository,said) {return}
    if stale {fmt.printfln("  warn   the .gitattributes of %s lacks the line of a kind of asset of the engine or of its plugins -> mirai setup git %s",repository,folder)}
    switch state {
    case .None:
    case .Wired: fmt.printfln("  ok     git merges and diffs the assets of %s through mirai",repository)
    case .Unset:
        errors^+=1
        fmt.printfln("  ERROR  git takes the assets of %s as whole files: its .gitattributes names the drivers of mirai and its configuration lacks them\n         -> mirai setup git %s",repository,folder)
    case .Other: fmt.printfln("  warn   git merges and diffs the assets of %s through another copy of the engine -> mirai setup git %s to use this one",repository,folder)
    }
    return
}
