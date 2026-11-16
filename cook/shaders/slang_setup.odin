package shaders

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:cook/workspace"
import "mirai:project"

// The Slang release the engine's shaders are generated with.
SLANG_VERSION :: "2026.22"

@(private)
Slang_Package :: struct {suffix,sha256:string}

// The official prebuilt package of this platform and its pinned SHA-256.
@(private)
slang_package :: proc() -> (package_info:Slang_Package,ok:bool) {
    packages:=#partial [workspace.Target]Slang_Package{
        .Macos_Arm64={"macos-aarch64.tar.gz","885b5bd9a79a1ae81fdb92212f5f7c785001f870d45c39f9bb5df01339db3fea"},
        .Linux_X64={"linux-x86_64.tar.gz","a877b75c6ec515f5d8bf66ea4bae4f0a5ba85050b9540c2046670285808347e6"},
        .Linux_Arm64={"linux-aarch64.tar.gz","b7d03e99de10caff973d45439159300d569d4220d2364eec34ffa7ef2a5baddd"},
        .Windows_X64={"windows-x86_64.zip","dd0c4a86bd44cdb7e9cf712af0c8ebf2fff1bba19fa5e3c128ff87384e8ff17b"},
    }
    package_info=packages[workspace.TARGET]
    return package_info,package_info.suffix!=""
}

// The pinned Slang of this platform, installed into <root>/.deps/slang, where
// the generator looks for it before PATH.
slang_prebuilt :: proc() -> (p:Prebuilt,ok:bool) {
    package_info,supported:=slang_package()
    if !supported {return}
    asset:=fmt.tprintf("slang-%s-%s",SLANG_VERSION,package_info.suffix)
    return {
        name="Slang",version=SLANG_VERSION,folder="slang",asset=asset,
        url=fmt.tprintf("https://github.com/shader-slang/slang/releases/download/v%s/%s",SLANG_VERSION,asset),
        sha256=package_info.sha256,required=strings.concatenate({"bin/slangc",project.EXECUTABLE_SUFFIX},context.temp_allocator),
    },true
}

// Installs the pinned Slang compiler (prebuilt_install). The message is in `allocator`.
slang_install :: proc(root:string,archive:string="",allocator:=context.allocator) -> (message:string,ok:bool) {
    p,supported:=slang_prebuilt()
    if !supported {return fmt.aprintf("No Slang package is configured for %v %v",ODIN_OS,ODIN_ARCH,allocator=allocator),false}
    return prebuilt_install(root,p,archive,allocator)
}

// The numbers a version starts with, an optional leading `v` aside: the
// `-version` of Slang, `2026.13.1-1-g84792eb15`, gives 2026, 13 and 1.
@(private)
version_components :: proc(text:string) -> (parts:[4]int,count:int) {
    bytes:=transmute([]u8)text
    i:=0
    for i<len(bytes) && (bytes[i]==' ' || bytes[i]=='\t') {i+=1}
    if i<len(bytes) && (bytes[i]=='v' || bytes[i]=='V') {i+=1}
    for count<len(parts) {
        start:=i
        for i<len(bytes) && bytes[i]>='0' && bytes[i]<='9' {i+=1}
        if i==start {break}
        value:=0
        for digit in start..<i {value=value*10+int(bytes[digit]-'0')}
        parts[count]=value
        count+=1
        if i>=len(bytes) || bytes[i]!='.' {break}
        i+=1
    }
    return
}

// Whether a Slang version is the one the engine pins or a later one. Only its
// leading numbers count, so 2026.20.1 and 2026.21 are later than 2026.20.
slang_version_at_least :: proc(version,required:string) -> bool {
    got,got_count:=version_components(version)
    want,want_count:=version_components(required)
    if got_count==0 || want_count==0 {return false}
    for i in 0..<len(got) {
        have,wanted:=0,0
        if i<got_count {have=got[i]}
        if i<want_count {wanted=want[i]}
        if have!=wanted {return have>wanted}
    }
    return true
}

// The version the compiler at `slangc` prints, or false when it cannot be run.
@(private)
slang_version_of :: proc(runner:^Runner,slangc:string,allocator:=context.allocator) -> (version:string,ok:bool) {
    output,ran:=tool_run(runner,{slangc,"-version"},allocator)
    if !ran {return "",false}
    return strings.trim_space(output),true
}

// The version of the compiler at `slangc`, for a caller with no runner of its own.
slang_version :: proc(slangc:string,allocator:=context.allocator) -> (string,bool) {
    runner:Runner
    return slang_version_of(&runner,slangc,allocator)
}

// Whether the caller named the compiler (Options.tools, MIRAI_SLANGC or
// MIRAI_SLANG) instead of letting mirai find it. A named one is never replaced.
slang_named :: proc(tools:[Tool]string) -> bool {
    if tools[.Slangc]!="" {return true}
    for variable in ([]string{"MIRAI_SLANGC","MIRAI_SLANG"}) {
        if value,set:=os.lookup_env(variable,context.temp_allocator);set && value!="" {return true}
    }
    return false
}

// The compiler a generation runs: SLANG_VERSION or a later one. When the one
// found is older, the pinned Slang is installed under .deps as `mirai setup
// slang` does and looked up again; a compiler the caller named is not
// replaced. problem: why no compiler the engine accepts could be used, and
// what to do, in which case the generation does not run.
slang_ensure :: proc(root,slangc:string,tools:[Tool]string,runner:^Runner,allocator:=context.allocator) -> (path,version,problem:string) {
    found_version,ran:=slang_version_of(runner,slangc,allocator)
    if !ran {
        return "","",fmt.aprintf("could not run %s to learn its Slang version; check that the file exists and is executable",slangc,allocator=allocator)
    }
    if slang_version_at_least(found_version,SLANG_VERSION) {return slangc,found_version,""}
    found:=found_version if found_version!="" else "no version"
    if slang_named(tools) {
        return "","",fmt.aprintf(
            "Slang %s (%s) is older than %s, the version the engine pins: use a Slang %s or later in MIRAI_SLANGC, or remove the variable and run `mirai setup slang`",
            found,slangc,SLANG_VERSION,SLANG_VERSION,allocator=allocator)
    }
    message,installed:=slang_install(root,allocator=allocator)
    if installed {
        if located,ok:=tool_find(root,.Slangc,allocator);ok {
            if now,ran_now:=slang_version_of(runner,located,allocator);ran_now && slang_version_at_least(now,SLANG_VERSION) {
                return located,now,""
            }
        }
    }
    return "","",fmt.aprintf(
        "the Slang found (%s, %s) is older than %s, the version the engine pins, and the pinned one could not be put in its place: %s. If `.deps/slang` exists, delete it and run `mirai setup slang` by hand; then build again",
        found,slangc,SLANG_VERSION,message,allocator=allocator)
}
