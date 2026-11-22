package main

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:cook/shaders"
import "mirai:kai/hub"
import "mirai:std/base"

// mirai kai serve and mirai kai web: the node and the approvals of KaiHub,
// the procedures the headless mirai-kai runs too.
kai_node :: proc(verb,store_root:string,args:[]string) -> int {
    switch verb {
    case "serve": return hub.serve_command("mirai",args,store_root)
    case "web": return hub.web_command("mirai",args,store_root)
    }
    return 2
}

// The C library the static linux_arm64 node links: musl, prebuilt, from the
// final Alpine 3.20 package, whose files no longer change.
MUSL_VERSION :: "1.2.5-r4"
MUSL_PREBUILT :: shaders.Prebuilt{
    name="musl (aarch64)",version=MUSL_VERSION,folder="linux-arm64-musl",asset="musl-dev-1.2.5-r4.apk",
    url="https://dl-cdn.alpinelinux.org/alpine/v3.20/main/aarch64/musl-dev-1.2.5-r4.apk",
    sha256="54c60103a486d0d54263289fd0bf89b490514e04b74d5228c346c78089d587e4",
    required="usr/lib/libc.a",concatenated=true,
}

// The linker of a static linux_arm64 executable: ld.lld in PATH, or
// Homebrew's lld on macOS.
lld_find :: proc() -> (path:string,found:bool) {
    if path,found=path_find("ld.lld");found {return}
    for prefix in ([?]string{"/opt/homebrew/opt","/usr/local/opt"}) {
        entries,e:=os.read_all_directory_by_path(prefix,context.temp_allocator)
        if e!=nil {continue}
        for entry in entries {
            if !strings.has_prefix(entry.name,"lld") {continue}
            candidate:=fmt.tprintf("%s/bin/ld.lld",entry.fullpath)
            if os.is_file(candidate) {return candidate,true}
        }
    }
    return "",false
}

// Builds package_path as a static linux_arm64 executable at bin/<output>-linux-arm64:
// Odin's objects for the target linked by ld.lld with the pinned musl.
build_static_linux_arm64 :: proc(root,package_path,output:string,debug:bool) -> int {
    lld,has_lld:=lld_find()
    if !has_lld {
        fmt.eprintln("mirai build kai --target linux_arm64: ld.lld is not in PATH: install LLVM's lld (macOS: brew install lld; Debian and Ubuntu: apt install lld) and build again")
        return 1
    }
    message,installed:=shaders.prebuilt_install(root,MUSL_PREBUILT)
    if !installed {
        fmt.eprintfln("mirai build kai --target linux_arm64: %s",message)
        return 1
    }
    musl:=join(shaders.prebuilt_folder(root,MUSL_PREBUILT),"usr","lib")
    bin:=join(root,"bin")
    if os.make_directory_all(bin)!=nil && !os.is_dir(bin) {return 1}
    objects:=join(bin,fmt.aprintf(".%s-linux-arm64-%d",output,os.get_pid()))
    os.make_directory_all(objects)
    defer base.remove_all(objects)
    command:=make([dynamic]string)
    append(&command,odin_executable(root),"build",join(root,package_path),fmt.aprintf("-collection:mirai=%s",root),"-ignore-unknown-attributes",
        "-target:linux_arm64","-build-mode:obj",debug?"-debug":"-o:speed",fmt.aprintf("-out:%s",join(objects,fmt.tprintf("%s.o",output))))
    if code:=run_compiler(root,command[:],"mirai build kai");code!=0 {return code}
    link:=make([dynamic]string)
    staging:=join(bin,fmt.aprintf(".%s-linux-arm64-build-%d",output,os.get_pid()))
    append(&link,lld,"-static","-o",staging,join(musl,"crt1.o"),join(musl,"crti.o"))
    entries,e:=os.read_all_directory_by_path(objects,context.allocator)
    if e!=nil {return 1}
    for entry in entries {
        if strings.has_suffix(entry.name,".o") {append(&link,entry.fullpath)}
    }
    append(&link,join(musl,"libc.a"),join(musl,"crtn.o"))
    if !debug {append(&link,"--strip-all")}
    if code:=run(root,link[:]);code!=0 {
        os.remove(staging)
        fmt.eprintln("mirai build kai --target linux_arm64: ld.lld did not link the node")
        return code
    }
    final:=join(bin,fmt.aprintf("%s-linux-arm64",output))
    if os.rename(staging,final)!=nil {
        os.remove(staging)
        fmt.eprintfln("mirai build kai --target linux_arm64: could not replace %s",final)
        return 1
    }
    fmt.printfln("%s ready: a static linux_arm64 executable (%s serve ...).",final,output)
    return 0
}
