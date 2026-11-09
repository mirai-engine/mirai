package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "mirai:editor/acp"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// What the editor knows of the agents of Codex and Claude belongs to the user
// of the machine (project.agents_folder), not to a project, a checkout or a
// build: an update of the engine, a rebuild or another worktree keep the
// adapter, whether it is connected and what it announced. The sign-in is
// the one of the agent itself (~/.codex, ~/.claude), which Mirai never
// touches: it only asks the agent whether there is one.

AI_AGENTS_FILE :: "agents.json"
// The program of the official adapter of each agent, as its package installs it.
AI_AGENT_PROGRAMS :: [Ai_Agent]string{.Codex="codex-acp",.Claude="claude-agent-acp",.Command=""}

// What an initialize of an adapter announced: what the editor can ask of it.
Ai_Capability :: enum u8 {Load,Resume,Close,Http_Mcp,Image,Embedded_Context,Rename}
Ai_Capabilities :: bit_set[Ai_Capability;u8]
AI_CAPABILITY_NAMES :: [Ai_Capability]string{.Load="load",.Resume="resume",.Close="close",.Http_Mcp="http_mcp",.Image="image",.Embedded_Context="embedded_context",.Rename="rename"}

Ai_Agent_Disk :: struct {
    provider:string,
    configured:bool,
    // The adapter the version and the capabilities are of; another one found
    // later is not known until it starts.
    adapter,version:string,
    capabilities:[]string,
}
Ai_Agents_Disk :: struct {version:int, runtime:string, agents:[]Ai_Agent_Disk}

ai_agents_home :: proc(m:^Ai) -> string {return base.text_get(m.agents_home[:])}
ai_agents_folder :: proc(m:^Ai,id:string,allocator:=context.temp_allocator) -> string {
    home:=ai_agents_home(m)
    if home=="" {return ""}
    return project.path(home,id,allocator=allocator)
}

// The machine record of Codex and Claude: connected, runtime, and what their
// adapter announced.
ai_agents_read :: proc(m:^Ai) {
    home:=ai_agents_home(m)
    if home=="" {return}
    disk:Ai_Agents_Disk
    data,error:=os.read_entire_file(project.path(home,AI_AGENTS_FILE,allocator=context.temp_allocator),context.temp_allocator)
    if error!=nil || json.unmarshal(data,&disk,allocator=context.temp_allocator)!=nil || disk.version!=1 {return}
    for name,runtime in AI_RUNTIME_NAMES {if disk.runtime==name {m.default_runtime=runtime}}
    names:=AI_CAPABILITY_NAMES
    for item in disk.agents {
        provider,ok:=ai_provider_find(m,item.provider)
        if !ok || m.connections[provider].agent==.Command {continue}
        c:=&m.connections[provider]
        c.configured=item.configured
        if len(item.adapter)>=len(c.known_adapter) || len(item.version)>=len(c.known_version) {continue}
        base.text_set(c.known_adapter[:],item.adapter);base.text_set(c.known_version[:],item.version)
        c.known_capabilities={}
        for capability in item.capabilities {
            for name,kind in names {if capability==name {c.known_capabilities+={kind}}}
        }
    }
}

ai_agents_write :: proc(m:^Ai) -> bool {
    home:=ai_agents_home(m)
    if home=="" || os.make_directory_all(home)!=nil && !os.is_dir(home) {return false}
    entries:[2]Ai_Agent_Disk
    capabilities:[2][len(Ai_Capability)]string
    names:=AI_CAPABILITY_NAMES
    for agent,index in ([2]Ai_Provider{AI_CODEX,AI_CLAUDE}) {
        c:=&m.connections[agent]
        count:=0
        for kind in Ai_Capability {if kind in c.known_capabilities {capabilities[index][count]=names[kind];count+=1}}
        entries[index]={provider=base.text_get(c.id[:]),configured=c.configured,adapter=base.text_get(c.known_adapter[:]),version=base.text_get(c.known_version[:]),capabilities=capabilities[index][:count]}
    }
    runtimes:=AI_RUNTIME_NAMES
    data,error:=json.marshal(Ai_Agents_Disk{version=1,runtime=runtimes[m.default_runtime],agents=entries[:]},{pretty=true},context.temp_allocator)
    if error!=nil {return false}
    return serial.file_write_atomic(project.path(home,AI_AGENTS_FILE,allocator=context.temp_allocator),data)==.None
}

// What an initialize announced: kept with the connection when it is the
// adapter the connection runs. Every start of the adapter checks it again.
ai_agent_announced :: proc(s:^Session,provider:Ai_Provider,client:^acp.Client,value:json.Value) {
    m:=s.ai;c:=&m.connections[provider]
    if c.agent==.Command {return}
    version:=acp.text(acp.at(value,"agentInfo","version"))
    capabilities:Ai_Capabilities
    if client.load_session {capabilities+={.Load}}
    if client.resume_session {capabilities+={.Resume}}
    if client.close_session {capabilities+={.Close}}
    if client.http_mcp {capabilities+={.Http_Mcp}}
    if client.image {capabilities+={.Image}}
    if client.embedded_context {capabilities+={.Embedded_Context}}
    if client.session_rename {capabilities+={.Rename}}
    adapter:=base.text_get(c.adapter[:])
    if len(version)>=len(c.version) || version==base.text_get(c.known_version[:]) && capabilities==c.known_capabilities && adapter==base.text_get(c.known_adapter[:]) {return}
    base.text_set(c.version[:],version);base.text_set(c.known_version[:],version);base.text_set(c.known_adapter[:],adapter)
    c.known_capabilities=capabilities
    if base.text_get(c.latest[:])==version {c.latest={}}
    ai_agent_outdated(c)
    if !ai_agents_write(m) {notify(s,"What the agent announced could not be saved")}
}

// Whether a version is older than another: their numbers compared in order.
ai_version_older :: proc(version,than:string) -> bool {
    a,b:=version,than
    for a!="" || b!="" {
        x,y:=ai_version_part(&a),ai_version_part(&b)
        if x!=y {return x<y}
    }
    return false
}

@(private)
ai_version_part :: proc(text:^string) -> int {
    end:=0
    for end<len(text^) && text[end]>='0' && text[end]<='9' {end+=1}
    value,_:=strconv.parse_int(text[:end])
    rest:=text[end:]
    if dot:=strings.index_byte(rest,'.');dot>=0 {rest=rest[dot+1:]} else {rest=""}
    text^=rest
    return value
}

// An installation of the user older than the version the editor knows
// offers that one: the update is the command of the user, not a download of Mirai.
ai_agent_outdated :: proc(c:^Ai_Connection) {
    if !c.user || base.text_get(c.latest[:])!="" {return}
    versions:=AI_AGENT_VERSIONS
    version:=base.text_get(c.version[:])
    if version!="" && ai_version_older(version,versions[c.agent]) {base.text_set(c.latest[:],versions[c.agent])}
}

// The folders where the installers of the user leave programs, besides PATH:
// what an application started outside a shell may not have in its PATH.
@(private)
ai_user_folders :: proc(allocator:=context.temp_allocator) -> []string {
    folders:=make([dynamic]string,allocator)
    search,_:=os.lookup_env("PATH",allocator)
    listed,_:=os.split_path_list(search,allocator)
    for folder in listed {if folder!="" {append(&folders,folder)}}
    home:=os.get_env("USERPROFILE" when ODIN_OS==.Windows else "HOME",allocator)
    if home!="" {
        append(&folders,project.path(home,".local","bin",allocator=allocator),project.path(home,".bun","bin",allocator=allocator),project.path(home,".npm-global","bin",allocator=allocator))
    }
    when ODIN_OS==.Windows {
        if roaming:=os.get_env("APPDATA",allocator);roaming!="" {append(&folders,project.path(roaming,"npm",allocator=allocator))}
        if local:=os.get_env("LOCALAPPDATA",allocator);local!="" {append(&folders,project.path(local,"pnpm",allocator=allocator))}
    } else {
        append(&folders,"/opt/homebrew/bin","/usr/local/bin")
        if home!="" {append(&folders,project.path(home,"Library","pnpm",allocator=allocator),project.path(home,".local","share","pnpm",allocator=allocator))}
    }
    return folders[:]
}

// A program of the user: the path to start and, for the script npm leaves on
// Windows, the JavaScript it runs with Node. Empty when missing.
ai_user_program :: proc(name,package_name:string,allocator:=context.temp_allocator) -> (program,script:string) {
    for folder in ai_user_folders(allocator) {
        when ODIN_OS==.Windows {
            if path:=project.path(folder,strings.concatenate({name,".exe"},allocator),allocator=allocator);os.is_file(path) {return path,""}
            if !os.is_file(project.path(folder,strings.concatenate({name,".cmd"},allocator),allocator=allocator)) {continue}
            // The script of npm starts the package it installed in its folder.
            entry:=project.path(folder,"node_modules",package_name,"dist","index.js",allocator=allocator)
            if os.is_file(entry) {return entry,entry}
        } else {
            if path:=project.path(folder,name,allocator=allocator);os.is_file(path) {return path,""}
        }
    }
    return "",""
}

// The adapter of the user for an agent, in PATH or a usual folder of its installers.
ai_user_adapter :: proc(agent:Ai_Agent,allocator:=context.temp_allocator) -> (program,script:string) {
    programs,packages:=AI_AGENT_PROGRAMS,AI_AGENT_PACKAGES
    if agent==.Command {return "",""}
    return ai_user_program(programs[agent],packages[agent],allocator)
}

// The native program of Codex inside a folder of node_modules, as npm, Bun
// and pnpm hoist it or keep it inside the package that needs it.
@(private)
ai_codex_vendor :: proc(folder:string,allocator:=context.temp_allocator) -> string {
    suffix,triple:string
    when ODIN_OS==.Darwin && ODIN_ARCH==.arm64 {suffix,triple="darwin-arm64","aarch64-apple-darwin"}
    else when ODIN_OS==.Windows && ODIN_ARCH==.amd64 {suffix,triple="win32-x64","x86_64-pc-windows-msvc"}
    else when ODIN_OS==.Linux && ODIN_ARCH==.amd64 {suffix,triple="linux-x64","x86_64-unknown-linux-musl"}
    else {return ""}
    name:="codex"+(".exe" when ODIN_OS==.Windows else "")
    vendor:=project.path("@openai",strings.concatenate({"codex-",suffix},allocator),"vendor",triple,"bin",name,allocator=allocator)
    for parent in ([3]string{folder,project.path(folder,"@openai","codex","node_modules",allocator=allocator),project.path(folder,"@agentclientprotocol","codex-acp","node_modules",allocator=allocator)}) {
        if path:=project.path(parent,vendor,allocator=allocator);os.is_file(path) {return path}
    }
    return ""
}

// The Codex the adapter runs: the one of the user, or the one that came with
// the adapter. Its sign-in is the one of the user in either case.
ai_codex_binary :: proc(s:^Session) -> string {
    c:=&s.ai.connections[AI_CODEX]
    when ODIN_OS==.Windows {
        for folder in ai_user_folders() {
            if path:=project.path(folder,"codex.exe",allocator=context.temp_allocator);os.is_file(path) {return path}
            if os.is_file(project.path(folder,"codex.cmd",allocator=context.temp_allocator)) {
                if path:=ai_codex_vendor(project.path(folder,"node_modules",allocator=context.temp_allocator));path!="" {return path}
            }
        }
    } else {
        if program,_:=ai_user_program("codex","@openai/codex");program!="" {return program}
    }
    adapter:=base.text_get(c.adapter[:])
    if c.user {
        // The package of the adapter of the user: <node_modules>/@agentclientprotocol/codex-acp/dist/index.js.
        if strings.has_suffix(adapter,"index.js") {
            modules:=project.path(adapter,"..","..","..","..",allocator=context.temp_allocator)
            if cleaned,error:=os.clean_path(modules,context.temp_allocator);error==nil {return ai_codex_vendor(cleaned)}
        }
        return ""
    }
    ids:=AI_AGENT_IDS
    folder:=ai_agents_folder(s.ai,ids[.Codex])
    disk:struct{version,runtime,codex_binary:string}
    if data,error:=os.read_entire_file(project.path(folder,"installation.json",allocator=context.temp_allocator),context.temp_allocator);error==nil {json.unmarshal(data,&disk,allocator=context.temp_allocator)}
    if disk.codex_binary=="" {return ""}
    binary:=project.path(folder,disk.codex_binary,allocator=context.temp_allocator)
    return os.is_file(binary)?binary:""
}

// The command that updates an installation of the user to version, by the
// installer whose folder it is in.
ai_update_command :: proc(c:^Ai_Connection,version:string,allocator:=context.temp_allocator) -> string {
    packages:=AI_AGENT_PACKAGES
    adapter:=strings.to_lower(base.text_get(c.adapter[:]),allocator)
    installer:="npm install -g"
    switch {
    case strings.contains(adapter,"/.bun/") || strings.contains(adapter,"\\.bun\\"): installer="bun add -g"
    case strings.contains(adapter,"pnpm"):                                           installer="pnpm add -g"
    }
    return fmt.aprintf("%s %s@%s",installer,packages[c.agent],version,allocator=allocator)
}
