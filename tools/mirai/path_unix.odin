#+build !windows
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Writes in the startup file of the shell of the user a block that puts
// folder first in PATH, replacing the block of its kind that was there.
path_add :: proc(folder:string,kind:Path_Entry) -> (message:string,ok:bool) {
    begin_mark:=kind==.Bin?"# >>> mirai >>>":"# >>> mirai ripgrep >>>"
    end_mark:=kind==.Bin?"# <<< mirai <<<":"# <<< mirai ripgrep <<<"
    home,found:=os.lookup_env("HOME",context.temp_allocator)
    if !found || home=="" {return "mirai setup path: HOME is not set",false}
    shell,_:=os.lookup_env("SHELL",context.temp_allocator)
    quoted,_:=strings.replace_all(folder,`\`,`\\`,context.temp_allocator)
    for c in ([]string{`"`,"$","`"}) {quoted,_=strings.replace_all(quoted,c,fmt.tprintf(`\%s`,c),context.temp_allocator)}
    file:string
    line:=fmt.tprintf(`export PATH="%s:$PATH"`,quoted)
    switch filepath.base(shell) {
    case "zsh":  file=join(home,".zshrc")
    case "bash": file=join(home,ODIN_OS==.Darwin?".bash_profile":".bashrc")
    case "fish":
        file=join(home,".config","fish","conf.d","mirai.fish")
        line=fmt.tprintf(`set -gx PATH "%s" $PATH`,quoted)
    case:        file=join(home,".profile")
    }
    block:=fmt.tprintf("%s\n%s\n%s\n",begin_mark,line,end_mark)
    data,read_error:=os.read_entire_file(file,context.temp_allocator)
    if read_error!=nil && os.exists(file) {return fmt.tprintf("mirai setup path: could not read %s",file),false}
    text:=string(data)
    updated:string
    if begin:=strings.index(text,begin_mark);begin>=0 {
        end:=strings.index(text[begin:],end_mark)
        if end<0 {return fmt.tprintf("mirai setup path: %s has an unclosed mirai block",file),false}
        end=begin+end+len(end_mark)
        if end<len(text) && text[end]=='\n' {end+=1}
        if text[begin:end]==block {return fmt.tprintf("%s is already in the PATH (%s).",folder,file),true}
        updated=strings.concatenate({text[:begin],block,text[end:]},context.temp_allocator)
    } else {
        separator:=len(text)>0 && text[len(text)-1]!='\n'?"\n":""
        updated=strings.concatenate({text,separator,block},context.temp_allocator)
    }
    if parent:=filepath.dir(file);!os.is_dir(parent) {_=os.make_directory_all(parent)}
    if os.write_entire_file(file,updated)!=nil {return fmt.tprintf("mirai setup path: could not write %s",file),false}
    return fmt.tprintf("%s is now in the PATH from %s. Open a new terminal; open applications pick it up when they restart.",folder,file),true
}

// Whether path is a symbolic link that leads to a folder.
link_to_folder :: proc(path:string) -> bool {
    info,error:=os.lstat(path,context.temp_allocator)
    return error==nil && info.type==.Symlink && os.is_dir(path)
}
