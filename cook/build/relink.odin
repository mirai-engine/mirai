package build

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import si "core:sys/info"
import "core:time"
import "mirai:project"
import "mirai:std/subprocess"
import "mirai:std/base"

// Linking again instead of compiling. A library of a plugin is named after
// what it is built from (plugin_library_name), so that a program that loaded
// the previous one loads the new one beside it, and what links against it
// names it in its imports. When a library changes only inside procedures its
// declarations do not carry, its declarations change only in that name, and
// what links against it would compile to the same objects: it only has to
// link them again against the new name. A compile of a plugin library or of
// the library of a project keeps its objects and the command of its linker
// (Link_Record); a later build that finds its sources and the declarations
// it reads the same but for those names runs the command again with the
// names of now, and compiles when that fails.

// What a compile left to link again: under the fingerprint of what it read
// with the names of the plugin libraries masked (link_names_mask), the
// folder of its objects and the command of its linker as the compiler ran it.
@(private)
Link_Record :: struct {
    hash:u64,
    folder:string,
    command:string,
}

// The folder of the objects of every compile a project keeps:
// <project>/.mirai/build/o/<compile>, short so that the objects stay within
// MAX_PATH on Windows (see ODIN_WORKAROUNDS).
@(private)
objects_root :: proc(root:string,allocator:=context.allocator) -> string {
    return project.path(project.folder_path(root,.Generated,context.temp_allocator),"build","o",allocator=allocator)
}

// How many linkers a job runs at once besides its compilers: one per core.
// A linker of a plugin library takes little memory and little time.
links_at_once :: proc() -> int {
    _,logical,counted:=si.cpu_core_count()
    return max(logical,1) if counted else 1
}

// What the compiler is given besides its flags to leave the objects and
// print the command of the linker.
@(private)
LINK_KEEP_FLAGS :: [2]string{"-keep-temp-files","-show-system-calls"}

// The file of the output of a compile in its folder of objects. Its import
// library on Windows and its debug information go beside it.
@(private)
LINK_OUTPUT :: "l"

@(private)
link_staged :: proc(folder:string,allocator:=context.allocator) -> string {
    return project.path(folder,strings.concatenate({LINK_OUTPUT,project.LIBRARY_SUFFIX},context.temp_allocator),allocator=allocator)
}

// Masks in a declaration the hashes of the names of plugin libraries in its
// foreign imports, the only thing in it that changes when the library changes
// inside its procedures: the hex digits of "<family>-<8 hex>." in the quoted
// path of every line that starts with foreign import become '0'. In place.
link_names_mask :: proc(data:[]u8) {
    start:=0
    for start<len(data) {
        end:=start
        for end<len(data) && data[end]!='\n' {end+=1}
        line:=data[start:end]
        first:=0
        for first<len(line) && (line[first]==' ' || line[first]=='\t') {first+=1}
        if strings.has_prefix(string(line[first:]),"foreign import") {
            open:=strings.index_byte(string(line),'"')
            close:=open>=0?strings.last_index_byte(string(line),'"'):-1
            if open>=0 && close>open {
                quoted:=line[open+1:close]
                base:=strings.last_index_any(string(quoted),"/\\")+1
                dash:=strings.last_index_byte(string(quoted[base:]),'-')
                if dash>=0 {
                    at:=base+dash+1
                    if at+9<=len(quoted) && quoted[at+8]=='.' && link_hex(quoted[at:at+8]) {
                        for i in at..<at+8 {quoted[i]='0'}
                    }
                }
            }
        }
        start=end+1
    }
}

@(private)
link_hex :: proc(digits:[]u8) -> bool {
    for c in digits {
        if !(c>='0' && c<='9' || c>='a' && c<='f') {return false}
    }
    return true
}

// The command of the linker in what a compiler with -show-system-calls wrote
// to its error stream: the line after the last "[SYSTEM CALL]" that names a linker.
link_command_find :: proc(output:string) -> (command:string,ok:bool) {
    rest:=output
    taking:=false
    for line in strings.split_lines_iterator(&rest) {
        if taking {
            command,ok=strings.trim_space(line),true
            taking=false
            continue
        }
        if strings.has_prefix(line,"[SYSTEM CALL]") {taking=strings.contains(line,"link")}
    }
    return command,ok && command!=""
}

// What the compiler wrote to its error stream without the calls -show-system-calls
// added: what a failure shows.
link_calls_strip :: proc(output:string,allocator:=context.allocator) -> string {
    b:=strings.builder_make(allocator)
    rest:=output
    skip:=false
    for line in strings.split_lines_iterator(&rest) {
        if skip {skip=false;continue}
        if strings.has_prefix(line,"[SYSTEM CALL]") {skip=true;continue}
        strings.write_string(&b,line)
        strings.write_byte(&b,'\n')
    }
    return strings.trim_space(strings.to_string(b))
}

// The command with every name "<family>-<8 hex>" of a family in names
// replaced by the name of now: the libraries it links against, and on
// Windows the module definition of a plugin library, which carries its own.
link_command_rename :: proc(command:string,names:map[string]string,allocator:=context.allocator) -> string {
    b:=strings.builder_make(allocator)
    i:=0
    outer: for i<len(command) {
        for family,name in names {
            if len(family)+9>len(command)-i || command[i+len(family)]!='-' {continue}
            if !strings.equal_fold(command[i:i+len(family)],family) {continue}
            digits:=command[i+len(family)+1:i+len(family)+9]
            if !link_hex(transmute([]u8)digits) {continue}
            strings.write_string(&b,name)
            i+=len(family)+9
            continue outer
        }
        strings.write_byte(&b,command[i])
        i+=1
    }
    return strings.to_string(b)
}

// What runs the command of a linker as the compiler wrote it: on Windows the
// line of a process, split as CommandLineToArgvW does; elsewhere a line of
// the shell.
link_command_args :: proc(command:string,allocator:=context.allocator) -> []string {
    when ODIN_OS==.Windows {
        return command_line_split(command,allocator)
    } else {
        args:=make([]string,3,allocator)
        args[0],args[1],args[2]="sh","-c",strings.clone(command,allocator)
        return args
    }
}

// The arguments of a Windows command line, by the rules of CommandLineToArgvW:
// 2n backslashes before a quote are n and the quote opens or closes, 2n+1 are
// n and a quote, and backslashes before anything else stay.
command_line_split :: proc(line:string,allocator:=context.allocator) -> []string {
    args:=make([dynamic]string,allocator)
    i:=0
    for i<len(line) {
        for i<len(line) && (line[i]==' ' || line[i]=='\t') {i+=1}
        if i>=len(line) {break}
        b:=strings.builder_make(allocator)
        quoted:=false
        for i<len(line) {
            c:=line[i]
            if !quoted && (c==' ' || c=='\t') {break}
            if c=='\\' {
                count:=0
                for i<len(line) && line[i]=='\\' {count+=1;i+=1}
                if i<len(line) && line[i]=='"' {
                    for _ in 0..<count/2 {strings.write_byte(&b,'\\')}
                    if count%2==1 {
                        strings.write_byte(&b,'"')
                        i+=1
                    }
                } else {
                    for _ in 0..<count {strings.write_byte(&b,'\\')}
                }
                continue
            }
            if c=='"' {
                // A quote right after a closing one inside quotes is a quote.
                if quoted && i+1<len(line) && line[i+1]=='"' {
                    strings.write_byte(&b,'"')
                    i+=2
                    continue
                }
                quoted=!quoted
                i+=1
                continue
            }
            strings.write_byte(&b,c)
            i+=1
        }
        append(&args,strings.to_string(b))
    }
    return args[:]
}

@(private)
link_record_read :: proc(file:string,allocator:=context.allocator) -> (record:Link_Record,ok:bool) {
    data,error:=os.read_entire_file(file,context.temp_allocator)
    if error!=nil {return}
    rest:=string(data)
    lines:[3]string
    for &line in lines {
        found:bool
        if line,found=strings.split_lines_iterator(&rest);!found {return}
    }
    hash,parsed:=strconv.parse_u64_of_base(strings.trim_space(lines[0]),16)
    if !parsed || lines[1]=="" || lines[2]=="" {return}
    return {hash=hash,folder=strings.clone(strings.trim_space(lines[1]),allocator),command=strings.clone(strings.trim_space(lines[2]),allocator)},true
}

// Writes the record of a compile and removes the objects of the one it
// replaces. Without a record the next build compiles.
@(private)
link_record_write :: proc(file:string,record:Link_Record) {
    previous,had:=link_record_read(file,context.temp_allocator)
    if os.write_entire_file(file,fmt.tprintf("%x\n%s\n%s\n",record.hash,record.folder,record.command))!=nil {
        _=os.remove(file)
        return
    }
    if had && !project.path_same(previous.folder,record.folder) {remove_later({previous.folder})}
}

// Removes the record and the objects it names: what a compile that failed,
// or a build forced, leaves no record of.
@(private)
link_record_remove :: proc(file:string) {
    if record,had:=link_record_read(file,context.temp_allocator);had {remove_later({record.folder})}
    _=os.remove(file)
}

// Whether the record names the objects of a compile of what has hash now.
@(private)
link_record_stands :: proc(record:Link_Record,hash:u64) -> bool {
    return record.hash==hash && os.is_dir(record.folder)
}

// Removes the intermediate code -keep-temp-files left beside the objects.
@(private)
link_folder_trim :: proc(folder:string) {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return}
    for entry in entries {
        if strings.has_suffix(entry.name,".ll") || strings.has_suffix(entry.name,".bc") {_=os.remove(entry.fullpath)}
    }
}

// Removes the folders of objects no record names whose compile is over: a
// compile that ended badly, or objects a record no longer names that were
// in use when it was replaced. Records: project.link files in records.
@(private)
objects_sweep :: proc(root:string,records:[]string) {
    folder:=objects_root(root,context.temp_allocator)
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return}
    named:=make(map[string]bool,context.temp_allocator)
    for file in records {
        if record,ok:=link_record_read(file,context.temp_allocator);ok {named[strings.to_lower(slashes(record.folder,context.temp_allocator),context.temp_allocator)]=true}
    }
    removed:=make([dynamic]string,context.temp_allocator)
    for entry in entries {
        if entry.type!=.Directory || strings.to_lower(slashes(entry.fullpath,context.temp_allocator),context.temp_allocator) in named {continue}
        // One being removed, whose removal did not finish when it is old.
        if strings.contains(entry.name,TRASH) {
            if time.diff(entry.modification_time,time.now())>STALE_AFTER {append(&removed,entry.fullpath)}
            continue
        }
        // <target>-<hex>-<pid>...: a compile of a job that still runs stays.
        if dash:=strings.index_byte(entry.name,'-');dash>0 && subprocess.process_alive(job_file_pid(entry.name[dash+1:])) {continue}
        append(&removed,entry.fullpath)
    }
    remove_later(removed[:])
}

// What a folder being removed has in its name (remove_later).
@(private)
TRASH :: ".trash-"

// Moves folders out of the way at once and removes them in a process of
// their own that outlives this one: removing the many files of a folder of
// objects or of an entry of the cache takes longer than the build that
// waits for it. What it does not get to remove, a later trim or sweep does
// once it is old. Without that process, they are removed here.
@(private)
remove_later :: proc(paths:[]string) {
    moved:=make([dynamic]string,context.temp_allocator)
    for path in paths {
        if !os.exists(path) {continue}
        if strings.contains(path,TRASH) {
            append(&moved,path)
            continue
        }
        to:=fmt.tprintf("%s%s%d-%x",path,TRASH,os.get_pid(),u64(time.to_unix_nanoseconds(time.now())))
        if os.rename(path,to)==nil {append(&moved,to)} else {_=base.remove_all(path)}
    }
    when ODIN_OS==.Windows {
        // A line of cmd holds at most 8191 characters.
        LINE :: 8000
    } else {
        LINE :: 100_000
    }
    for start:=0;start<len(moved); {
        command:=make([dynamic]string,context.temp_allocator)
        when ODIN_OS==.Windows {append(&command,"cmd.exe","/d","/c","rmdir","/s","/q")} else {append(&command,"rm","-rf")}
        length,end:=64,start
        for end<len(moved) && (end==start || length+len(moved[end])+3<LINE) {
            path:=moved[end]
            when ODIN_OS==.Windows {path,_=strings.replace_all(path,"/","\\",context.temp_allocator)}
            append(&command,path)
            length+=len(path)+3
            end+=1
        }
        if _,error:=subprocess.detached({command=command[:]});error!=nil {
            for path in moved[start:end] {_=base.remove_all(path)}
        }
        start=end
    }
}

// The records of the project: those of its targets and of its plugin
// libraries of every optimization.
@(private)
link_records :: proc(root:string) -> []string {
    files:=make([dynamic]string,context.temp_allocator)
    generated:=project.folder_path(root,.Generated,context.temp_allocator)
    folders:=make([dynamic]string,context.temp_allocator)
    append(&folders,project.path(generated,"build",allocator=context.temp_allocator))
    if modes,error:=os.read_all_directory_by_path(project.path(generated,"plugins",allocator=context.temp_allocator),context.temp_allocator);error==nil {
        for mode in modes {if mode.type==.Directory {append(&folders,mode.fullpath)}}
    }
    for folder in folders {
        entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
        for entry in entries {
            if entry.type!=.Directory && strings.has_suffix(entry.name,".link") {append(&files,entry.fullpath)}
        }
    }
    return files[:]
}
