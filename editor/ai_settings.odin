package editor

import "core:encoding/json"
import "core:os"
import "core:strings"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// A connection: its place in Ai.connections. Codex and Claude are always the
// first two; the others are ACP agents the user adds by their command.
Ai_Provider :: distinct u8
AI_CODEX :: Ai_Provider(0)
AI_CLAUDE :: Ai_Provider(1)
AI_CONNECTION_CAPACITY :: 8
AI_COMMAND_ARGUMENTS :: 8
// How a connection starts: the official adapter of Codex or Claude, the one
// of the user or the one Mirai installs, or an agent that speaks ACP started
// by its command. Each signs in by itself; Mirai keeps no credential.
Ai_Agent :: enum u8 {Codex,Claude,Command}
Ai_Runtime :: enum u8 {Automatic,Bun,Node,Pnpm,Bundled}
AI_AGENT_IDS :: [Ai_Agent]string{.Codex="codex",.Claude="claude",.Command=""}
AI_AGENT_NAMES :: [Ai_Agent]string{.Codex="Codex",.Claude="Claude",.Command=""}
AI_AGENT_MAKERS :: [Ai_Agent]string{.Codex="OpenAI",.Claude="Anthropic",.Command=""}
AI_AGENT_PACKAGES :: [Ai_Agent]string{.Codex="@agentclientprotocol/codex-acp",.Claude="@agentclientprotocol/claude-agent-acp",.Command=""}
AI_AGENT_VERSIONS :: [Ai_Agent]string{.Codex="2.2.2",.Claude="0.89.1",.Command=""}
AI_RUNTIME_NAMES :: [Ai_Runtime]string{.Automatic="Automatic",.Bun="Bun",.Node="Node",.Pnpm="pnpm",.Bundled="Bundled"}
AI_CODEX_MODELS :: [3]string{"gpt-6-luna","gpt-6.1-sol","gpt-6-astra"}
AI_CODEX_MODEL_NAMES :: [3]string{"Luna 6","Sol 6.1","Astra 6"} // the mark of the agent says whose they are
Ai_Connection :: struct {
    agent:Ai_Agent,
    id:[32]u8,      // in the settings, the chat history and the API
    name:[64]u8,
    command:[AI_PATH_BYTES]u8, // Command: the program, searched in PATH without a folder
    arguments:[AI_COMMAND_ARGUMENTS][128]u8, // Command: passed as they are, without a shell
    argument_count:int,
    configured:bool,
    runtime:Ai_Runtime,
    installed:bool, // Command: its program was found
    user:bool,      // Codex and Claude: the adapter is an installation of the user
    adapter:[AI_PATH_BYTES]u8, // Codex and Claude: the program of the adapter found
    version,latest:[64]u8,
    // Codex and Claude: what the last initialize of an adapter announced, and which adapter.
    known_adapter:[AI_PATH_BYTES]u8,
    known_version:[64]u8,
    known_capabilities:Ai_Capabilities,
    model:[128]u8,  // empty: the one the agent starts with
    effort:[32]u8,  // empty: the one the agent starts with
}
// Of the project: the model and effort of each connection, and the agents
// added by their command. Whether Codex and Claude are connected belongs to
// the machine (ai_agents_read).
Ai_Connection_Disk :: struct {
    provider,model,effort:string,
    configured:bool `json:"configured,omitempty"`,
    name:string `json:"name,omitempty"`,
    command:string `json:"command,omitempty"`,
    arguments:[]string `json:"arguments,omitempty"`,
}
Ai_Subagent_Disk :: struct {mode,connection,model,effort:string}
Ai_Settings_Disk :: struct {version:int, connections:[]Ai_Connection_Disk, subagent:Ai_Subagent_Disk}

ai_connections :: proc(m:^Ai) -> []Ai_Connection {return m.connections[:m.connection_count]}
ai_connection_id :: proc(m:^Ai,provider:Ai_Provider) -> string {return base.text_get(m.connections[provider].id[:])}
ai_connection_name :: proc(m:^Ai,provider:Ai_Provider) -> string {return base.text_get(m.connections[provider].name[:])}

ai_provider_find :: proc(m:^Ai,id:string) -> (provider:Ai_Provider,ok:bool) {
    for &c,index in ai_connections(m) {
        if id!="" && base.text_get(c.id[:])==id {return Ai_Provider(index),true}
    }
    return AI_CODEX,false
}

// Codex and Claude as they start: neither installed nor connected.
ai_connections_reset :: proc(m:^Ai) {
    m.connections={}
    m.model_counts={}
    ids,names:=AI_AGENT_IDS,AI_AGENT_NAMES
    for agent,index in ([2]Ai_Agent{.Codex,.Claude}) {
        c:=&m.connections[index]
        c.agent=agent
        base.text_set(c.id[:],ids[agent]);base.text_set(c.name[:],names[agent])
        base.text_set(c.effort[:],"low")
    }
    base.text_set(m.connections[AI_CODEX].model[:],"gpt-6-luna")
    base.text_set(m.connections[AI_CLAUDE].model[:],"default")
    m.connection_count=2
}

// The id of an agent added by its name: lowercase letters, digits and dashes.
@(private)
ai_connection_slug :: proc(name:string,buffer:[]u8) -> string {
    used:=0
    for c in transmute([]u8)name {
        if used>=len(buffer) {break}
        switch c {
        case 'a'..='z','0'..='9': buffer[used]=c;used+=1
        case 'A'..='Z': buffer[used]=c+32;used+=1
        case ' ','-','_','.': if used>0 && buffer[used-1]!='-' {buffer[used]='-';used+=1}
        }
    }
    for used>0 && buffer[used-1]=='-' {used-=1}
    return string(buffer[:used])
}

// Adds an agent that speaks ACP, started by its command with its arguments
// separated by spaces. It signs in by itself; Connect only marks it connected
// or asks it to sign in.
ai_connection_add :: proc(s:^Session,name,command,arguments:string) -> (provider:Ai_Provider,message:string) {
    ai_initialize(s)
    m:=s.ai
    name:=strings.trim_space(name);command:=strings.trim_space(command)
    if name=="" || command=="" {return 0,"Give the agent a name and a command"}
    if m.connection_count>=AI_CONNECTION_CAPACITY {return 0,"No room for more agents"}
    if len(name)>=len(m.connections[0].name) || len(command)>=len(m.connections[0].command) {return 0,"The name or the command is too long"}
    buffer:[32]u8
    id:=ai_connection_slug(name,buffer[:len(buffer)-1])
    if id=="" {return 0,"The name needs a letter or a digit"}
    if _,taken:=ai_provider_find(m,id);taken {return 0,"An agent with that name exists"}
    c:Ai_Connection
    c.agent=.Command
    base.text_set(c.id[:],id);base.text_set(c.name[:],name);base.text_set(c.command[:],command)
    rest:=arguments
    for argument in strings.fields_iterator(&rest) {
        if c.argument_count>=AI_COMMAND_ARGUMENTS {return 0,"The command has too many arguments"}
        if len(argument)>=len(c.arguments[0]) {return 0,"An argument is too long"}
        base.text_set(c.arguments[c.argument_count][:],argument);c.argument_count+=1
    }
    _,c.installed=ai_executable_find(command)
    provider=Ai_Provider(m.connection_count)
    m.connections[provider]=c;m.model_counts[provider]=0;m.connection_count+=1
    if !ai_settings_save(s) {m.connection_count-=1;return 0,"The connection settings could not be saved"}
    return provider,""
}

// Removes an agent added by its command, with its connection; its chats stay.
ai_connection_remove :: proc(s:^Session,provider:Ai_Provider) -> string {
    m:=s.ai
    if int(provider)>=m.connection_count || m.connections[provider].agent!=.Command {return "Only agents added by their command can be removed"}
    if ai_running_count(m)!=0 || m.login || m.installer!=0 || m.connection_pending.kind!=.None {return "Wait for the current operation to finish"}
    // Workers name their connection by its place, which the ones after it lose.
    ai_workers_stop(s,provider,all=true)
    for &worker in m.workers {worker.provider=AI_CODEX}
    // What is restored if the settings cannot be saved.
    previous_connections:=m.connections
    previous_counts:=m.model_counts
    previous_models:=m.models
    count:=m.connection_count
    copy(m.connections[int(provider):count-1],m.connections[int(provider)+1:count])
    copy(m.model_counts[int(provider):count-1],m.model_counts[int(provider)+1:count])
    copy(m.models[int(provider):count-1],m.models[int(provider)+1:count])
    m.connection_count-=1
    m.connections[m.connection_count]={};m.model_counts[m.connection_count]=0
    if !ai_settings_save(s) {
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        m.connections=previous_connections
        m.model_counts=previous_counts
        m.models=previous_models
        m.connection_count=count
        return "The connection settings could not be saved"
    }
    return ""
}

ai_codex_model_supported :: proc(model:string) -> bool {
    for allowed in AI_CODEX_MODELS {if model==allowed {return true}}
    return false
}
// The native program of the Claude Code of the user, which the adapter runs:
// in PATH or a usual folder, where Anthropic's installer puts it, or in the
// package npm installs. Empty when missing.
ai_claude_binary :: proc(allocator:=context.temp_allocator) -> string {
    name:="claude"+(".exe" when ODIN_OS==.Windows else "")
    for folder in ai_user_folders(allocator) {
        if path:=project.path(folder,name,allocator=allocator);os.is_file(path) {return path}
        // On Windows npm puts a script in the folder and the program in its package.
        when ODIN_OS==.Windows {
            if path:=project.path(folder,"node_modules","@anthropic-ai","claude-code","bin",name,allocator=allocator);os.is_file(path) {return path}
        }
    }
    return ""
}
ai_executable_find :: proc(name:string,allocator:=context.temp_allocator) -> (path:string,found:bool) {
    if name=="" {return "",false}
    extensions:=[]string{""}
    when ODIN_OS==.Windows {extensions={"",".exe",".cmd"}}
    folders:=[]string{""}
    if !strings.contains_any(name,"/\\") {
        search,_:=os.lookup_env("PATH",allocator)
        folders,_=os.split_path_list(search,allocator)
    }
    for folder in folders {
        candidate:=folder==""?name:project.path(folder,name,allocator=allocator)
        for extension in extensions {
            full:=strings.concatenate({candidate,extension},allocator)
            if os.is_file(full) {return full,true}
        }
    }
    return "",false
}
ai_agents_refresh :: proc(s:^Session) {
    for &connection in ai_connections(s.ai) {
        if connection.agent==.Command {
            _,connection.installed=ai_executable_find(base.text_get(connection.command[:]))
            continue
        }
        connection.installed,connection.user=false,false
        connection.version,connection.adapter={},{}
        // The adapter the user installed comes first: Mirai neither updates nor removes it.
        if program,_:=ai_user_adapter(connection.agent);program!="" {
            connection.installed,connection.user=true,true
            base.text_set(connection.adapter[:],program)
        } else {
            folder:=ai_agents_folder(s.ai,base.text_get(connection.id[:]))
            disk:struct{version,runtime:string}
            if data,error:=os.read_entire_file(project.path(folder,"installation.json",allocator=context.temp_allocator),context.temp_allocator);error==nil && json.unmarshal(data,&disk,allocator=context.temp_allocator)==nil {
                for name,kind in AI_RUNTIME_NAMES {if disk.runtime==name {connection.runtime=kind}}
                entry:=ai_agent_entry(s.ai,connection.agent,connection.runtime)
                connection.installed=entry!="" && os.is_file(entry)
                if connection.installed {base.text_set(connection.adapter[:],entry);base.text_set(connection.version[:],disk.version)}
            }
        }
        if connection.agent==.Claude && ai_claude_binary()=="" {connection.installed=false}
        // A version is the one the adapter announced, while it is the adapter found.
        if connection.installed && base.text_get(connection.known_adapter[:])==base.text_get(connection.adapter[:]) && base.text_get(connection.known_version[:])!="" {connection.version=connection.known_version}
        ai_agent_outdated(&connection)
    }
}
// The program of the official adapter of Codex or Claude that Mirai installed.
ai_agent_entry :: proc(m:^Ai,agent:Ai_Agent,runtime:Ai_Runtime,allocator:=context.temp_allocator) -> string {
    ids,packages:=AI_AGENT_IDS,AI_AGENT_PACKAGES
    folder:=ai_agents_folder(m,ids[agent],allocator)
    if folder=="" {return ""}
    if runtime==.Bundled {return project.path(folder,"agent"+(".exe" when ODIN_OS==.Windows else ""),allocator=allocator)}
    return project.path(folder,"node_modules",packages[agent],"dist","index.js",allocator=allocator)
}
ai_runtime_path :: proc(s:^Session,runtime:Ai_Runtime) -> (path:string,found:bool) {
    if runtime==.Node {return ai_executable_find("node")}
    if runtime==.Pnpm {return ai_executable_find("pnpm")}
    if runtime!=.Bun && runtime!=.Bundled {return "",false}
    path,found=ai_executable_find("bun")
    if found {return}
    home:=ai_agents_home(s.ai)
    if home=="" {return "",false}
    path=project.path(home,"runtime","bun"+(".exe" when ODIN_OS==.Windows else ""),allocator=context.temp_allocator)
    return path,os.is_file(path)
}
ai_runtime_resolve :: proc(s:^Session,requested:Ai_Runtime) -> (runtime:Ai_Runtime,found:bool) {
    if requested!=.Automatic {
        if _,found=ai_runtime_path(s,requested);found {return requested,true}
    }
    for kind in ([3]Ai_Runtime{.Bun,.Node,.Pnpm}) {
        if _,found=ai_runtime_path(s,kind);found {return kind,true}
    }
    return .Automatic,false
}
ai_connections_runtimes_refresh :: proc(s:^Session) {
    for kind in ([3]Ai_Runtime{.Bun,.Node,.Pnpm}) {_,s.ai.connection_ui.available[kind]=ai_runtime_path(s,kind)}
}
ai_settings_initialize :: proc(s:^Session) {
    m:=s.ai
    m.default_runtime=.Automatic
    home:=ai_agents_home(m)
    ai_connections_reset(m)
    m.subagent={}
    if home=="" {home=project.agents_folder(context.temp_allocator)}
    if len(home)<len(m.agents_home) {base.text_set(m.agents_home[:],home)}
    file:=project.path(s.project_root,".mirai","ai","connections.json",allocator=context.temp_allocator)
    disk:Ai_Settings_Disk
    if data,error:=os.read_entire_file(file,context.temp_allocator);error==nil && json.unmarshal(data,&disk,allocator=context.temp_allocator)==nil && disk.version==2 {
        for item in disk.connections {
            provider,ok:=ai_provider_find(m,item.provider)
            if !ok {
                // An agent added by its command, kept as it was added.
                if item.command=="" || m.connection_count>=AI_CONNECTION_CAPACITY || len(item.provider)>=len(m.connections[0].id) || len(item.name)>=len(m.connections[0].name) || len(item.command)>=len(m.connections[0].command) || len(item.arguments)>AI_COMMAND_ARGUMENTS {continue}
                provider=Ai_Provider(m.connection_count)
                c:=&m.connections[provider]
                c^={agent=.Command}
                base.text_set(c.id[:],item.provider);base.text_set(c.name[:],item.name!=""?item.name:item.provider);base.text_set(c.command[:],item.command)
                for argument in item.arguments {
                    if len(argument)>=len(c.arguments[0]) {continue}
                    base.text_set(c.arguments[c.argument_count][:],argument);c.argument_count+=1
                }
                m.connection_count+=1
            }
            c:=&m.connections[provider]
            if c.agent==.Command {c.configured=item.configured}
            if len(item.model)<len(c.model) && (c.agent!=.Codex || ai_codex_model_supported(item.model)) {base.text_set(c.model[:],item.model)}
            if len(item.effort)<len(c.effort) {base.text_set(c.effort[:],item.effort)}
        }
        modes:=AI_SUBAGENT_MODES
        for name,mode in modes {if disk.subagent.mode==name {m.subagent.mode=mode}}
        if len(disk.subagent.connection)<len(m.subagent.connection) {base.text_set(m.subagent.connection[:],disk.subagent.connection)}
        if len(disk.subagent.model)<len(m.subagent.model) {base.text_set(m.subagent.model[:],disk.subagent.model)}
        if len(disk.subagent.effort)<len(m.subagent.effort) {base.text_set(m.subagent.effort[:],disk.subagent.effort)}
    }
    ai_agents_read(m)
    ai_agents_refresh(s)
}
// Saves what the project keeps of the connections and what the machine keeps of Codex and Claude.
ai_settings_save :: proc(s:^Session) -> bool {
    entries:[AI_CONNECTION_CAPACITY]Ai_Connection_Disk
    arguments:[AI_CONNECTION_CAPACITY][AI_COMMAND_ARGUMENTS]string
    for &c,index in ai_connections(s.ai) {
        entries[index]={provider=base.text_get(c.id[:]),model=base.text_get(c.model[:]),effort=base.text_get(c.effort[:])}
        if c.agent!=.Command {continue}
        entries[index].configured=c.configured
        for i in 0..<c.argument_count {arguments[index][i]=base.text_get(c.arguments[i][:])}
        entries[index].name,entries[index].command,entries[index].arguments=base.text_get(c.name[:]),base.text_get(c.command[:]),arguments[index][:c.argument_count]
    }
    modes:=AI_SUBAGENT_MODES
    defaults:=&s.ai.subagent
    disk:=Ai_Settings_Disk{version=2,connections=entries[:s.ai.connection_count],subagent={mode=modes[defaults.mode],connection=base.text_get(defaults.connection[:]),model=base.text_get(defaults.model[:]),effort=base.text_get(defaults.effort[:])}}
    data,error:=json.marshal(disk,{pretty=true},context.temp_allocator)
    if error!=nil {return false}
    folder:=project.path(s.project_root,".mirai","ai",allocator=context.temp_allocator)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return false}
    if serial.file_write_atomic(project.path(folder,"connections.json",allocator=context.temp_allocator),data)!=.None {return false}
    return ai_agents_write(s.ai)
}
