package main

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:cook/shaders"
import "mirai:cook/workspace"
import "mirai:project"

// The ripgrep agents search the repository with: it skips what .gitignore
// leaves out (.worktrees, .deps, bin), which grep -r walks whole.
RIPGREP_VERSION :: "14.1.1"

// The official package of this platform and its pinned SHA-256.
ripgrep_prebuilt :: proc() -> (p:shaders.Prebuilt,ok:bool) {
    checksums:=#partial [workspace.Target]string{
        .Windows_X64="d0f534024c42afd6cb4d38907c25cd2b249b79bbe6cc1dbee8e3e37c2b6e25a1",
        .Macos_Arm64="24ad76777745fbff131c8fbc466742b011f925bfa4fffa2ded6def23b5b937be",
        .Linux_X64="4cf9f2741e6c465ffdb7c26f38056a59e2a2544b51f7cc128ef28337eeae4d8e",
        .Linux_Arm64="c827481c4ff4ea10c9dc7a4022c8de5db34a5737cb74484d62eb94a95841ab2f",
    }
    sha256:=checksums[workspace.TARGET]
    if sha256=="" {return}
    asset:=fmt.aprintf("ripgrep-%s-%s%s",RIPGREP_VERSION,workspace.target_names().triple,".zip" when workspace.TARGET==.Windows_X64 else ".tar.gz")
    return {
        name="ripgrep",version=RIPGREP_VERSION,folder="ripgrep",asset=asset,
        url=fmt.aprintf("https://github.com/BurntSushi/ripgrep/releases/download/%s/%s",RIPGREP_VERSION,asset),
        sha256=sha256,top=strings.trim_suffix(strings.trim_suffix(asset,".zip"),".tar.gz"),required=fmt.aprintf("rg%s",project.EXECUTABLE_SUFFIX),
    },true
}

// The folder of .deps with the pinned rg, when it is installed.
ripgrep_folder :: proc(root:string) -> (folder:string,installed:bool) {
    p,supported:=ripgrep_prebuilt()
    if !supported {return}
    folder=shaders.prebuilt_folder(root,p)
    return folder,os.is_file(join(folder,p.required))
}

// mirai setup rg: the pinned ripgrep in .deps, and its folder in the PATH of the user.
setup_ripgrep :: proc(root,archive:string) -> int {
    p,supported:=ripgrep_prebuilt()
    if !supported {fmt.eprintfln("There is no ripgrep package configured for %v %v",ODIN_OS,ODIN_ARCH);return 1}
    message,installed:=shaders.prebuilt_install(root,p,archive)
    if !installed {fmt.eprintln(message);return 1}
    fmt.println(message)
    folder,_:=ripgrep_folder(root)
    when ODIN_OS==.Windows {folder,_=strings.replace_all(folder,"/","\\")}
    added,ok:=path_add(folder,.Ripgrep)
    if !ok {fmt.eprintln(added);return 1}
    fmt.println(added)
    return 0
}
