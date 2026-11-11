package editor

import "core:encoding/json"
import "core:strings"
import "mirai:editor/api"
import "mirai:std/base"

Ai_Connect_Params :: struct {
    provider:[32]u8 `mirai:"text,label=Id of a connection of ai.connections"`,
    existing:bool `mirai:"optional,label=An agent added by its command: marked connected; without it it signs in with the first method it offers. Codex and Claude take neither: they are asked whether they are signed in"`,
}
Ai_Disconnect_Params :: struct {provider:[32]u8 `mirai:"text,label=Id of a connection of ai.connections"`}
Ai_Install_Params :: struct {
    operation:[16]u8 `mirai:"text,label=check (looks for updates of what is installed); download; update; uninstall (of provider); runtime (downloads a private Bun) or cancel (stops the operation that runs)"`,
    provider:[32]u8 `mirai:"optional,text,label=For download; update and uninstall: id of a connection of ai.connections"`,
    runtime:[16]u8 `mirai:"optional,text,label=automatic; bun; node; pnpm or bundled. Empty: the one of this machine"`,
    version:[64]u8 `mirai:"optional,text"`,
}
Ai_Add_Agent_Params :: struct {
    name:[64]u8 `mirai:"text"`,
    command:[512]u8 `mirai:"text,label=Program of an agent that speaks ACP over stdio; searched in PATH without a folder"`,
    arguments:[1024]u8 `mirai:"optional,text,label=Separated by spaces; passed without a shell"`,
}
Ai_Configure_Params :: struct {
    provider:[32]u8 `mirai:"optional,text,label=Id of a connection of ai.connections, for model and effort; only the fields of the subagents go without it"`,
    model:[128]u8 `mirai:"optional,text"`,
    effort:[32]u8 `mirai:"optional,text"`,
    instructions:[AI_MESSAGE_BYTES]u8 `mirai:"optional,text,label=What the editor tells the agents of the project; empty clears it"`,
    subagent_mode:[8]u8 `mirai:"optional,text,label=What a subagent runs with: same (as the main chat); fixed (subagent_connection; subagent_model and subagent_effort) or pick (the agent chooses)"`,
    subagent_connection:[32]u8 `mirai:"optional,text,label=Of fixed: the id of a connection of ai.connections"`,
    subagent_model:[128]u8 `mirai:"optional,text,label=Of fixed; empty: the one of its connection"`,
    subagent_effort:[32]u8 `mirai:"optional,text,label=Of fixed; empty: the one of its connection"`,
}

Ai_Connections_Result :: struct {
    runtime:string `mirai:"label=The default one: automatic; bun; node; pnpm or bundled"`,
    instructions:string `mirai:"label=What the editor tells the agents of the project"`,
    connections:[]Ai_Connection_Result,
    subagent:Ai_Subagent_Result `mirai:"label=What a subagent runs with unless agent.spawn says otherwise"`,
    operation:Ai_Connections_Operation `mirai:"label=The state of the installation or sign-in"`,
}
Ai_Subagent_Result :: struct {
    mode:string `mirai:"label=same; fixed or pick"`,
    connection:string,
    model:string,
    effort:string,
}
Ai_Connection_Result :: struct {
    provider:string `mirai:"label=Its id"`,
    name:string,
    agent:string `mirai:"label=codex; claude or command (an agent added by its command)"`,
    command:string `mirai:"optional,label=Of command: its program"`,
    arguments:[]string `mirai:"optional,label=Of command: what its program takes"`,
    installed:bool `mirai:"label=Whether it is installed; of command: whether its program was found"`,
    user:bool `mirai:"optional,label=Codex and Claude: the adapter is an installation of the user, which Mirai neither updates nor removes"`,
    adapter:string `mirai:"optional,label=Codex and Claude: the program of the adapter found"`,
    version:string `mirai:"label=The one its initialize announced, or the one Mirai installed; empty until an adapter of the user starts"`,
    latest:string,
    update:string `mirai:"optional,label=Of an installation of the user with latest: the command that updates it"`,
    capabilities:[]string `mirai:"optional,label=Codex and Claude: what its last initialize announced: load; resume; close; http_mcp; image; embedded_context; rename"`,
    connected:bool `mirai:"label=Whether it is configured; it neither tests the account nor starts the agent"`,
    runtime:string,
    model:string `mirai:"label=Empty: the one the agent starts with"`,
    effort:string `mirai:"label=Empty: the one the agent starts with"`,
}
Ai_Connections_Operation :: struct {
    busy:bool,
    status:string,
    error:string,
}

ai_connections_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="ai.connections",summary="The connections to agents, their adapters (the installation of the user, or the one Mirai keeps in the folder of the user) and the instructions of the editor. Reading starts no agent; Mirai keeps no credential.",result=type_info_of(Ai_Connections_Result),flags={.Read_Only},run=ai_api_connections})
    api_register(s,st,{name="ai.connect",summary="Connects an agent of ai.connections. Codex and Claude use the sign-in of their own program on this computer (codex login status, claude auth status), after their adapter answers initialize; Mirai signs in to neither. Poll ai.connections for its state.",params=type_info_of(Ai_Connect_Params),result=type_info_of(Ai_Connections_Result),run=ai_api_connect})
    api_register(s,st,{name="ai.agent.add",summary="Adds a connection to an agent that speaks ACP, started by its command. Its id comes from its name; Mirai does not install it and it signs in by itself.",params=type_info_of(Ai_Add_Agent_Params),result=type_info_of(Ai_Connections_Result),run=ai_api_add_agent})
    api_register(s,st,{name="ai.agent.remove",summary="Removes a connection added with ai.agent.add; its chats stay in the history.",params=type_info_of(Ai_Disconnect_Params),result=type_info_of(Ai_Connections_Result),flags={.Destructive},run=ai_api_remove_agent})
    api_register(s,st,{name="ai.disconnect",summary="Disconnects a configured connection, keeping its installed agent and its chat history.",params=type_info_of(Ai_Disconnect_Params),result=type_info_of(Ai_Connections_Result),flags={.Idempotent},run=ai_api_disconnect})
    api_register(s,st,{name="ai.install",summary="Runs an installation operation for the adapters Mirai keeps in the folder of the user, or cancels the one that runs; check also starts each adapter of the user to read what it announces. An installation of the user is updated by its own command. Poll ai.connections for its state.",params=type_info_of(Ai_Install_Params),result=type_info_of(Ai_Connections_Result),run=ai_api_install})
    api_register(s,st,{name="ai.configure",summary="Saves the model and effort of a connection and the instructions of the editor in the project; the next message takes them. Omitted fields are kept.",params=type_info_of(Ai_Configure_Params),result=type_info_of(Ai_Connections_Result),run=ai_api_configure})
}

@(private)
ai_connections_answer :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    m:=s.ai
    runtimes,agents,names,modes:=AI_RUNTIME_NAMES,[Ai_Agent]string{.Codex="codex",.Claude="claude",.Command="command"},AI_CAPABILITY_NAMES,AI_SUBAGENT_MODES
    r:=api.call_result(call,Ai_Connections_Result)
    r.runtime,r.instructions=strings.to_lower(runtimes[m.default_runtime],call.allocator),ai_instructions_read(s)
    r.connections=make([]Ai_Connection_Result,m.connection_count,call.allocator)
    for &c,index in ai_connections(m) {
        out:=&r.connections[index]
        out^={
            provider=base.text_get(c.id[:]),name=base.text_get(c.name[:]),agent=agents[c.agent],installed=c.installed,
            version=base.text_get(c.version[:]),latest=base.text_get(c.latest[:]),connected=c.configured,
            runtime=strings.to_lower(runtimes[c.runtime],call.allocator),model=base.text_get(c.model[:]),effort=base.text_get(c.effort[:]),
        }
        if c.agent==.Command {
            out.command=base.text_get(c.command[:])
            out.arguments=make([]string,c.argument_count,call.allocator)
            for &argument,i in out.arguments {argument=base.text_get(c.arguments[i][:])}
            continue
        }
        out.user,out.adapter=c.user,base.text_get(c.adapter[:])
        if c.user && out.latest!="" {out.update=ai_update_command(&c,out.latest)}
        capabilities:=make([dynamic]string,call.allocator)
        if base.text_get(c.known_adapter[:])==out.adapter {
            for kind in Ai_Capability {if kind in c.known_capabilities {append(&capabilities,names[kind])}}
        }
        out.capabilities=capabilities[:]
    }
    r.subagent={modes[m.subagent.mode],base.text_get(m.subagent.connection[:]),base.text_get(m.subagent.model[:]),base.text_get(m.subagent.effort[:])}
    r.operation={m.connection_ui.busy,base.text_get(m.connection_ui.status[:]),base.text_get(m.connection_ui.error[:])}
}

@(private)
ai_api_connections :: proc(s:^Session,call:^api.Call) {ai_connections_answer(s,call)}

@(private)
ai_api_provider :: proc(s:^Session,call:^api.Call,name:string) -> (provider:Ai_Provider,ok:bool) {
    ai_initialize(s)
    provider,ok=ai_provider_find(s.ai,name)
    if !ok {api.call_fail(call,api.INVALID_PARAMS,"provider must be the id of a connection that ai.connections lists")}
    return
}

@(private)
ai_api_add_agent :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Ai_Add_Agent_Params)
    if _,message:=ai_connection_add(s,base.text_get(p.name[:]),base.text_get(p.command[:]),base.text_get(p.arguments[:]));message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    ai_connections_answer(s,call)
}

@(private)
ai_api_remove_agent :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Ai_Disconnect_Params)
    provider,ok:=ai_api_provider(s,call,base.text_get(p.provider[:]))
    if !ok {return}
    if message:=ai_connection_remove(s,provider);message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    ai_connections_answer(s,call)
}

@(private)
ai_api_connect :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Ai_Connect_Params)
    provider,ok:=ai_api_provider(s,call,base.text_get(p.provider[:]))
    if !ok {return}
    if message:=ai_connection_set(s,provider,p.existing);message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    ai_connections_answer(s,call)
}

@(private)
ai_api_disconnect :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Ai_Disconnect_Params)
    provider,ok:=ai_api_provider(s,call,base.text_get(p.provider[:]))
    if !ok {return}
    ai_connection_disconnect(s,provider)
    ai_connections_answer(s,call)
}

@(private)
ai_api_install :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Ai_Install_Params)
    operation:=base.text_get(p.operation[:])
    if operation=="cancel" {ai_install_cancel(s);ai_connections_answer(s,call);return}
    if operation!="check" && operation!="download" && operation!="update" && operation!="uninstall" && operation!="runtime" {api.call_fail(call,api.INVALID_PARAMS,"operation must be check, download, update, uninstall, runtime or cancel");return}
    provider:=AI_CODEX
    if operation!="check" && operation!="runtime" {
        ok:bool
        provider,ok=ai_api_provider(s,call,base.text_get(p.provider[:]))
        if !ok {return}
    }
    runtime:=s.ai.default_runtime
    runtime_name:=base.text_get(p.runtime[:])
    if runtime_name!="" {
        found:=false
        runtimes:=AI_RUNTIME_NAMES
        for name,value in runtimes {
            if strings.equal_fold(name,runtime_name) {runtime=value;found=true;break}
        }
        if !found {api.call_fail(call,api.INVALID_PARAMS,"runtime must be automatic, bun, node, pnpm or bundled");return}
    }
    if message:=ai_install_start(s,operation,provider,runtime,base.text_get(p.version[:]));message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    ai_connections_answer(s,call)
}

@(private)
ai_api_configure :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    p:=api.call_params(call,Ai_Configure_Params)
    subagent:=base.text_get(p.subagent_mode[:])!="" || base.text_get(p.subagent_connection[:])!="" || base.text_get(p.subagent_model[:])!="" || base.text_get(p.subagent_effort[:])!=""
    if base.text_get(p.provider[:])=="" && subagent {
        if message:=ai_subagent_configure(s,p);message!="" {api.call_fail(call,api.INVALID_PARAMS,message);return}
        ai_connections_answer(s,call)
        return
    }
    provider,ok:=ai_api_provider(s,call,base.text_get(p.provider[:]))
    if !ok {return}
    if subagent {
        if message:=ai_subagent_configure(s,p);message!="" {api.call_fail(call,api.INVALID_PARAMS,message);return}
    }
    instructions:=false
    value,error:=json.parse_string(call.raw,allocator=call.allocator)
    if error==.None {
        if object,object_ok:=value.(json.Object);object_ok {_,instructions=object["instructions"]}
    }
    if message:=ai_connection_configure(s,provider,base.text_get(p.model[:]),base.text_get(p.effort[:]));message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    if instructions {
        if message:=ai_instructions_write(s,base.text_get(p.instructions[:]));message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    }
    ai_connections_answer(s,call)
}

// Omitted fields are kept. Whether the connection is configured is checked
// when a subagent starts: it may be connected by then.
@(private)
ai_subagent_configure :: proc(s:^Session,p:^Ai_Configure_Params) -> string {
    m:=s.ai
    next:=m.subagent
    if name:=base.text_get(p.subagent_mode[:]);name!="" {
        modes:=AI_SUBAGENT_MODES
        found:=false
        for value,mode in modes {if value==name {next.mode=mode;found=true}}
        if !found {return "subagent_mode must be same, fixed or pick"}
    }
    if text:=base.text_get(p.subagent_connection[:]);text!="" {base.text_set(next.connection[:],text)}
    if text:=base.text_get(p.subagent_model[:]);text!="" {base.text_set(next.model[:],text)}
    if text:=base.text_get(p.subagent_effort[:]);text!="" {base.text_set(next.effort[:],text)}
    if next.mode==.Fixed {
        provider,known:=ai_provider_find(m,base.text_get(next.connection[:]))
        if !known {return "fixed needs subagent_connection, the id of a connection that ai.connections lists"}
        model:=base.text_get(next.model[:])
        if m.connections[provider].agent==.Codex && model!="" && !ai_codex_model_supported(model) {return "Unsupported Codex model"}
    }
    effort:=base.text_get(next.effort[:])
    if effort!="" && effort!="low" && effort!="medium" && effort!="high" {return "subagent_effort must be low, medium or high"}
    previous:=m.subagent
    m.subagent=next
    if !ai_settings_save(s) {m.subagent=previous;return "The connection settings could not be saved"}
    return ""
}
