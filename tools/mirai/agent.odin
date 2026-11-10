package main

import "core:encoding/json"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/subprocess"

AGENT_USAGE :: "agent install|updates|uninstall|runtime <codex|claude|all|bun> [--runtime Automatic|Bun|Node|pnpm|Bundled] [--version N] [--claude-code] [--home folder] [--cancel-file path]"
AGENT_PACKAGES :: [2]string{"@agentclientprotocol/codex-acp","@agentclientprotocol/claude-agent-acp"}
AGENT_VERSIONS :: [2]string{"2.2.2","0.89.1"}
AGENT_NAMES :: [2]string{"codex","claude"}
AGENT_BUN_VERSION :: "1.4.3"

Agent_Operation :: struct {cancel_file:string,parent:int,cancelled:bool}

agent_cancelled :: proc(operation:^Agent_Operation) -> bool {
    if operation.cancelled {return true}
    operation.cancelled=operation.cancel_file!="" && os.exists(operation.cancel_file)
    when ODIN_OS!=.Windows {
        operation.cancelled=operation.cancelled || os.get_ppid()!=operation.parent
    }
    return operation.cancelled
}

agent_exec :: proc(operation:^Agent_Operation,directory:string,command:[]string) -> bool {
    if agent_cancelled(operation) {return false}
    process,error:=subprocess.start({working_dir=directory,command=command,stdout=os.stdout,stderr=os.stderr})
    if error!=nil {fmt.eprintfln("Could not start %s: %v",command[0],error);return false}
    for {
        state,wait_error:=os.process_wait(process,50*time.Millisecond)
        if wait_error==nil {return state.exit_code==0 && !agent_cancelled(operation)}
        if wait_error!=.Timeout || agent_cancelled(operation) {
            _=os.process_kill(process)
            _,_=os.process_wait(process)
            return false
        }
    }
}

agent_metadata :: proc(path:string) -> (value:json.Value,ok:bool) {
    bytes,error:=os.read_entire_file(path,context.allocator)
    if error!=nil {return}
    parsed,parse_error:=json.parse(bytes,allocator=context.allocator)
    return parsed,parse_error==.None
}

agent_json_text :: proc(value:json.Value,key:string) -> string {
    object,ok:=value.(json.Object)
    if !ok {return ""}
    text,_:=object[key].(string)
    return text
}

agent_version_valid :: proc(version:string) -> bool {
    if len(version)==0 || len(version)>64 {return false}
    for c in version {if !(c>='0'&&c<='9'||c>='a'&&c<='z'||c>='A'&&c<='Z'||c=='.'||c=='-') {return false}}
    return version[0]>='0' && version[0]<='9'
}

agent_bun :: proc(operation:^Agent_Operation,home:string,download:bool) -> (path:string,ok:bool) {
    if path,ok=path_find("bun");ok {return}
    private:=join(home,"runtime","bun"+project.EXECUTABLE_SUFFIX)
    if os.is_file(private) {return private,true}
    if !download {return "",false}
    folder:=join(home,"runtime")
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return "",false}
    packages:=#partial [workspace.Target][2]string{
        .Macos_Arm64={"bun-darwin-aarch64","80afd4c069b46a6fa8f3ec520bebc750a7843e4a8d5b9583d29ad436c00a3403"},
        .Windows_X64={"bun-windows-x64","0bf84e808552beea67bf1202a287a35c6c825d837b287b3f8e9dd513dba35d3d"},
        .Linux_X64={"bun-linux-x64","3e730528d89775f03f87f05c06787c4df4099d0a37f3f252e7b829cb23816e18"},
    }
    target,checksum:=packages[workspace.TARGET][0],packages[workspace.TARGET][1]
    if target=="" {fmt.eprintln("No Bun package_name for this platform");return "",false}
    stage,error:=os.make_directory_temp(folder,".bun-*",context.allocator)
    if error!=nil {return "",false}
    defer os.remove_all(stage)
    zip:=join(stage,"bun.zip")
    url:=fmt.aprintf("https://github.com/oven-sh/bun/releases/download/bun-v%s/%s.zip",AGENT_BUN_VERSION,target)
    if !agent_exec(operation,stage,{"curl","--fail","--location","--silent","--show-error","--output",zip,url}) {return "",false}
    bytes,read_error:=os.read_entire_file(zip,context.allocator)
    if read_error!=nil {return "",false}
    hash:sha2.Context_256;sha2.init_256(&hash);sha2.update(&hash,bytes)
    digest:[32]u8;sha2.final(&hash,digest[:]);delete(bytes)
    if string(hex.encode(digest[:],context.temp_allocator))!=checksum {fmt.eprintln("Bun download checksum mismatch");return "",false}
    when ODIN_OS==.Linux {
        if !agent_exec(operation,stage,{"unzip","-q",zip,"-d",stage}) {return "",false}
    } else {
        if !agent_exec(operation,stage,{"tar","-xf",zip,"-C",stage}) {return "",false}
    }
    source:=join(stage,target,"bun"+project.EXECUTABLE_SUFFIX)
    if !os.is_file(source) || !agent_exec(operation,stage,{source,"--version"}) {return "",false}
    if agent_cancelled(operation) || os.rename(source,private)!=nil {return "",false}
    return private,true
}

agent_codex_binary :: proc(stage:string) -> string {
    target:=workspace.target_names()
    if target.node=="" {return ""}
    relative:=join("node_modules","@openai",fmt.aprintf("codex-%s",target.node),"vendor",target.triple,"bin","codex"+project.EXECUTABLE_SUFFIX)
    if os.is_file(join(stage,relative)) {return relative}
    return ""
}

agent_publish :: proc(operation:^Agent_Operation,stage,target,previous:string) -> bool {
    if agent_cancelled(operation) {return false}
    had_previous:=os.exists(target)
    if had_previous && os.rename(target,previous)!=nil {return false}
    if agent_cancelled(operation) || os.rename(stage,target)!=nil {
        if had_previous {os.rename(previous,target)}
        return false
    }
    os.remove_all(previous)
    return true
}

cmd_agent :: proc(engine_root:string,args:[]string) -> int {
    packages,versions:=AGENT_PACKAGES,AGENT_VERSIONS
    if len(args)<2 {fmt.eprintfln("Usage: mirai %s",AGENT_USAGE);return 2}
    operation,name:=args[0],args[1]
    if code:=positionals_only("agent",args[:2]);code!=0 {return code}
    index:=-1
    for known,i in AGENT_NAMES {if name==known {index=i;break}}
    if index<0 && !(name=="all"&&operation=="updates") && !(name=="bun"&&operation=="runtime") {fmt.eprintln("Unknown agent");return 2}
    runtime,version,home:="Automatic","",""
    claude_code:=false
    operation_state:=Agent_Operation{parent=os.get_ppid()}
    for i:=2;i<len(args);i+=1 {
        switch args[i] {
        case "--runtime": i+=1;if i>=len(args) {return 2};runtime=args[i]
        case "--version": i+=1;if i>=len(args) {return 2};version=args[i]
        case "--cancel-file": i+=1;if i>=len(args) {return 2};operation_state.cancel_file=args[i]
        case "--home": i+=1;if i>=len(args) {return 2};home=args[i]
        case "--claude-code": claude_code=true
        case: return argument_unknown("agent",args[i])
        }
    }
    if claude_code && name!="claude" {fmt.eprintln("--claude-code installs only with claude");return 2}
    // The agents belong to the user of the machine, not to a project or a checkout.
    if home=="" {home=project.agents_folder()}
    if home=="" {fmt.eprintln("There is no folder of user data for the agents");return 1}
    if os.make_directory_all(home)!=nil && !os.is_dir(home) {return 1}
    target:=join(home,name)
    if agent_cancelled(&operation_state) {return 1}
    switch operation {
    case "runtime":
        if _,ok:=agent_bun(&operation_state,home,true);!ok {return 1}
        fmt.println("Bun installed");return 0
    case "updates":
        latest:=[2]string{}
        for package_name,i in AGENT_PACKAGES {
            file:=join(home,fmt.aprintf(".latest-%d.json",i))
            if !agent_exec(&operation_state,home,{"curl","--fail","--location","--silent","--show-error","--output",file,fmt.aprintf("https://registry.npmjs.org/%s/latest",package_name)}) {os.remove(file);return 1}
            value,ok:=agent_metadata(file);os.remove(file)
            latest[i]=agent_json_text(value,"version")
            if !ok || !agent_version_valid(latest[i]) {return 1}
        }
        data,error:=json.marshal(latest,{pretty=true},context.allocator)
        if error!=nil || os.write_entire_file(join(home,"updates.json"),data)!=nil {return 1}
        fmt.println("Updates checked");return 0
    case "uninstall":
        if agent_cancelled(&operation_state) {return 1}
        if os.exists(target) && os.remove_all(target)!=nil {return 1}
        fmt.println("Agent uninstalled");return 0
    case "install":
        if version=="" {version=versions[index]}
        if runtime=="Automatic" {
            if _,ok:=agent_bun(&operation_state,home,false);ok {runtime="Bun"}
            else if _,ok:=path_find("node");ok {runtime="Node"}
            else if _,ok:=path_find("pnpm");ok {runtime="pnpm"}
            else {fmt.eprintln("No runtime found");return 1}
        }
        if !agent_version_valid(version) || (runtime!="Bun"&&runtime!="Node"&&runtime!="pnpm"&&runtime!="Bundled") {return 2}
        stage,error:=os.make_directory_temp(home,".install-*",context.allocator)
        if error!=nil {return 1}
        defer os.remove_all(stage)
        manifest:=`{"private":true,"name":"mirai-agent"}`
        if runtime=="pnpm" {manifest=strings.concatenate({`{"private":true,"name":"mirai-agent","devEngines":{"runtime":{"name":"node","version":"^24.4.0","onFail":"download"}},"scripts":{"mirai-acp":"node node_modules/`,packages[index],`/dist/index.js"}}`},context.allocator)}
        if os.write_entire_file(join(stage,"package.json"),manifest)!=nil {return 1}
        registry:=join(stage,".npmrc")
        if os.write_entire_file(registry,"registry=https://registry.npmjs.org\n@agentclientprotocol:registry=https://registry.npmjs.org\n@openai:registry=https://registry.npmjs.org\n@anthropic-ai:registry=https://registry.npmjs.org\n")!=nil {return 1}
        bunfig:=join(stage,"bunfig.toml")
        if os.write_entire_file(bunfig,"[install]\nregistry = \"https://registry.npmjs.org\"\n[install.scopes]\n\"@agentclientprotocol\" = \"https://registry.npmjs.org\"\n\"@openai\" = \"https://registry.npmjs.org\"\n\"@anthropic-ai\" = \"https://registry.npmjs.org\"\n")!=nil {return 1}
        // The adapter of Claude runs the Claude Code of the user, installed by
        // Anthropic's installer: npm and Bun leave out the copy of the SDK, an optional package; pnpm add cannot.
        claude:=name=="claude"
        if claude && claude_code {
            installer:[]string
            when ODIN_OS==.Windows {installer={"powershell","-NoProfile","-Command","irm https://claude.ai/install.ps1 | iex"}}
            else {installer={"bash","-c","curl -fsSL https://claude.ai/install.sh | bash"}}
            if !agent_exec(&operation_state,home,installer) {fmt.eprintln("The installer of Claude Code failed");return 1}
        }
        package_name:=fmt.aprintf("%s@%s",packages[index],version)
        bun:string
        command:=make([dynamic]string)
        if runtime=="pnpm" {
            pnpm,found:=path_find("pnpm")
            if !found {fmt.eprintln("pnpm is not installed");return 1}
            when ODIN_OS==.Windows {append(&command,"cmd","/d","/c")}
            append(&command,pnpm,"add","--save-exact","--ignore-scripts","--ignore-workspace","--shamefully-hoist","--registry=https://registry.npmjs.org")
        } else if runtime=="Node" {
            npm,found:=path_find("npm")
            if !found {fmt.eprintln("Node installation requires npm");return 1}
            when ODIN_OS==.Windows {append(&command,"cmd","/d","/c","npm")} else {append(&command,npm)}
            append(&command,"install","--userconfig",registry,"--registry=https://registry.npmjs.org","--save-exact","--ignore-scripts")
            if claude {append(&command,"--omit=optional")}
        } else {
            found:bool;bun,found=agent_bun(&operation_state,home,runtime=="Bundled")
            if !found {fmt.eprintln("No runtime found");return 1}
            append(&command,bun,"add",fmt.aprintf("--config=%s",bunfig),"--registry","https://registry.npmjs.org","--exact","--ignore-scripts")
            if claude {append(&command,"--omit","optional")}
        }
        append(&command,package_name)
        if !agent_exec(&operation_state,stage,command[:]) {return 1}
        entry:=join(stage,"node_modules",packages[index],"dist","index.js")
        if !os.is_file(entry) {fmt.eprintln("Package has no ACP entry point");return 1}
        if runtime=="Bundled" {
            executable:=join(stage,"agent"+project.EXECUTABLE_SUFFIX)
            if !agent_exec(&operation_state,stage,{bun,"build",entry,"--compile","--outfile",executable}) {return 1}
            when ODIN_OS==.Darwin {
                if !agent_exec(&operation_state,stage,{"codesign","--force","--sign","-",executable}) {return 1}
            }
            if !agent_exec(&operation_state,stage,{executable,"--version"}) {return 1}
        }
        codex_binary:=index==0?agent_codex_binary(stage):""
        if index==0 && codex_binary=="" {fmt.eprintln("Codex native executable is missing");return 1}
        installed:=struct{version,runtime,codex_binary:string}{version,runtime,codex_binary}
        data,marshal_error:=json.marshal(installed,{pretty=true},context.allocator)
        if marshal_error!=nil || os.write_entire_file(join(stage,"installation.json"),data)!=nil {return 1}
        previous:=join(home,fmt.aprintf(".previous-%s",name))
        if os.exists(previous) {
            if !os.exists(target) {if os.rename(previous,target)!=nil {return 1}} else {if os.remove_all(previous)!=nil {return 1}}
        }
        if !agent_publish(&operation_state,stage,target,previous) {return 1}
        fmt.printfln("Installed %s %s",name,version);return 0
    case:fmt.eprintln("Unknown agent operation");return 2
    }
}
