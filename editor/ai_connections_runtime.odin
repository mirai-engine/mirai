package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:editor/acp"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/subprocess"

Ai_Connection_Pending :: struct {
    kind:enum{None,Install,Login,Probe},
    provider:Ai_Provider,
    runtime:Ai_Runtime,
    operation:[32]u8,
    version:[64]u8,
}

// The adapters started only to read what their initialize announces (ai_probe_start).
Ai_Probe :: struct {
    active:bool,
    provider:Ai_Provider,
    queue:bit_set[0..<AI_CONNECTION_CAPACITY],
    connect:bool, // a connect waits for it: the sign-in is asked after
}

ai_install_start :: proc(s:^Session,operation:string,provider:Ai_Provider,runtime:Ai_Runtime,version:string="") -> string {
    ai_initialize(s)
    m:=s.ai
    if !s.has_project {return "Open a project first"}
    if m.installer.pid!=0 || m.login || m.probe.active || (operation!="check" && ai_running_count(m)!=0) || m.connection_pending.kind!=.None {return "Wait for the current operation to finish"}
    if operation!="check" && operation!="runtime" && m.connections[provider].agent==.Command {return "Mirai installs only the agents of Codex and Claude"}
    if operation!="check" && operation!="runtime" && m.connections[provider].user {
        // The installation of the user is updated and removed by its own command.
        c:=&m.connections[provider]
        if operation=="update" {
            versions:=AI_AGENT_VERSIONS
            latest:=base.text_get(c.latest[:])
            return fmt.tprintf("This adapter is your installation (%s): update it with %s",base.text_get(c.adapter[:]),ai_update_command(c,latest!=""?latest:versions[c.agent]))
        }
        return fmt.tprintf("This adapter is your installation (%s): Mirai does not install over it nor remove it",base.text_get(c.adapter[:]))
    }
    home:=ai_agents_home(m)
    if home=="" {return "There is no folder of user data for the agents"}
    runtime:=runtime
    if operation=="download" || operation=="update" {
        found:bool;runtime,found=ai_runtime_resolve(s,runtime)
        if !found {return "No runtime found"}
    }
    if operation!="check" && operation!="runtime" && ai_process_running(m) {
        ai_workers_stop(s,provider,all=true)
        m.connection_pending={kind=.Install,provider=provider,runtime=runtime}
        base.text_set(m.connection_pending.operation[:],operation)
        base.text_set(m.connection_pending.version[:],version)
        m.connection_ui.busy=true
        if operation=="uninstall" {m.connection_ui.screen=.Transfer}
        base.text_set(m.connection_ui.status[:],"Closing agent...")
        return ""
    }
    command:=make([dynamic]string,context.temp_allocator)
    executable:=project.tool_file(s.engine_root,context.temp_allocator)
    if !os.is_file(executable) {return "The Mirai agent installer is missing"}
    verb:=operation=="check"?"updates":operation=="download" || operation=="update"?"install":operation
    if verb!="updates" && verb!="install" && verb!="uninstall" && verb!="runtime" {return "Unknown installation operation"}
    runtimes:=AI_RUNTIME_NAMES
    target:=operation=="check"?"all":operation=="runtime"?"bun":ai_connection_id(m,provider)
    cancel:=project.path(home,"install.cancel",allocator=context.temp_allocator)
    os.remove(cancel)
    append(&command,executable,"agent",verb,target,"--home",home,"--cancel-file",cancel)
    if verb=="install" {
        append(&command,"--runtime",runtimes[runtime])
        if version!="" {append(&command,"--version",version)}
        if m.connections[provider].agent==.Claude && ai_claude_binary()=="" {append(&command,"--claude-code")}
    }
    process,error:=subprocess.start({command=command[:],working_dir=s.project_root},pipes=.Merged)
    if error!=nil {return "The agent installer could not be started"}
    m.installer=process;m.install_provider=provider
    base.text_set(m.install_operation[:],operation);base.text_set(m.install_cancel[:],cancel)
    m.connection_ui.busy=true;m.connection_ui.error={};m.connection_ui.log={}
    if operation=="check" {m.connection_ui.check_display_until=platform.clock_seconds()+1}
    if operation=="uninstall" {m.connection_ui.screen=.Transfer}
    base.text_set(m.connection_ui.status[:],operation=="check"?"Checking for updates...":operation=="runtime"?"Downloading Bun...":operation=="uninstall"?"Uninstalling...":operation=="update"?"Updating...":"Downloading...")
    return ""
}

ai_install_cancel :: proc(s:^Session) {
    m:=s.ai
    if m.connection_pending.kind!=.None {m.connection_pending={};m.connection_ui.busy=false;m.connection_ui.screen=.Overview;return}
    if m.probe.active {ai_probe_end(s,"");m.probe={};m.connection_ui.busy=false;m.connection_ui.screen=.Overview;return}
    if m.login {
        if m.login_process.pid!=0 {m.login_cancelled=true;_=subprocess.terminate(&m.login_process);return}
        m.login=false;acp.stop(&m.workers[0].client);m.connection_ui.busy=false;m.connection_ui.screen=.Overview;return
    }
    if m.installer.pid==0 {return}
    cancel:=base.text_get(m.install_cancel[:])
    if cancel!="" {_=os.write_entire_file(cancel,string("cancel"))}
    base.text_set(m.connection_ui.status[:],"Cancelling...")
}

ai_install_poll :: proc(s:^Session) {
    m:=s.ai
    if m.connection_pending.kind!=.None && !ai_process_running(m) {
        pending:=m.connection_pending;m.connection_pending={}
        message:=""
        switch pending.kind {
        case .Install:message=ai_install_start(s,base.text_get(pending.operation[:]),pending.provider,pending.runtime,base.text_get(pending.version[:]))
        case .Login:message=ai_login_start(s,pending.provider)
        case .Probe:message=ai_probe_next(s)
        case .None:
        }
        if message!="" {m.connection_ui.busy=false;m.connection_ui.screen=.Overview;base.text_set(m.connection_ui.error[:],message)}
    }
    if m.installer.pid==0 {return}
    buffer:[4096]u8
    for pass in 0..<8 {
        count,_:=subprocess.read(&m.installer,.Stdout,buffer[:])
        if count==0 {break}
        used:=len(base.text_get(m.connection_ui.log[:]))
        keep:=min(count,len(m.connection_ui.log)-1)
        if used+keep>=len(m.connection_ui.log) {
            drop:=used+keep-len(m.connection_ui.log)+1
            copy(m.connection_ui.log[:used-drop],m.connection_ui.log[drop:used]);used-=drop
        }
        copy(m.connection_ui.log[used:used+keep],buffer[count-keep:count]);m.connection_ui.log[used+keep]=0
    }
    state,_:=subprocess.wait(&m.installer,0)
    if !state.exited {return}
    code:=state.exit_code
    operation:=base.text_get(m.install_operation[:])
    if operation=="check" && platform.clock_seconds()<m.connection_ui.check_display_until {return}
    cancelled:=os.is_file(base.text_get(m.install_cancel[:]))
    subprocess.release(&m.installer)
    os.remove(base.text_get(m.install_cancel[:]))
    closed:=m.connection_ui.screen==.Closed
    m.connection_ui.busy=false
    if operation!="runtime" && !closed {m.connection_ui.screen=.Overview}
    ai_agents_refresh(s)
    ai_connections_runtimes_refresh(s)
    if code!=0 {
        base.text_set(m.connection_ui.error[:],cancelled?"Installation cancelled":"The operation failed; see the installation log")
        return
    }
    if operation=="check" {
        // The latest versions of the adapters of Codex and Claude, in that order.
        versions:[2]string
        file:=project.path(ai_agents_home(m),"updates.json",allocator=context.temp_allocator)
        if bytes,error:=os.read_entire_file(file,context.temp_allocator);error==nil && json.unmarshal(bytes,&versions,allocator=context.temp_allocator)==nil {
            for &connection in ai_connections(m) {
                if connection.agent==.Command {continue}
                latest:=versions[int(connection.agent)]
                base.text_set(connection.latest[:],latest!=base.text_get(connection.version[:])?latest:"")
            }
        }
        base.text_set(m.connection_ui.status[:],"Updates checked")
        // What an adapter of the user is, it says itself when it starts.
        queue:bit_set[0..<AI_CONNECTION_CAPACITY]
        for &connection,index in ai_connections(m) {if connection.user {queue+={index}}}
        if queue!={} {
            if message:=ai_probe_start(s,queue,false);message!="" {base.text_set(m.connection_ui.error[:],message)}
        }
    } else if operation=="runtime" {
        base.text_set(m.connection_ui.status[:],"Bun installed")
    } else if operation=="uninstall" {
        m.connections[m.install_provider].configured=false;ai_settings_save(s)
        base.text_set(m.connection_ui.status[:],"Agent uninstalled")
    } else {
        m.connections[m.install_provider].latest={}
        ai_settings_save(s)
        if !closed && !m.connections[m.install_provider].configured {m.connection_ui.provider=m.install_provider;m.connection_ui.screen=.Auth}
        base.text_set(m.connection_ui.status[:],"Agent installed")
    }
}

// Connects an agent. Codex and Claude are asked whether they are signed in
// on this computer, after their adapter says what it is when Mirai does not
// know it yet. An agent added by its command is marked connected (existing)
// or signs in with the first method it offers.
ai_connection_set :: proc(s:^Session,provider:Ai_Provider,use_existing:bool) -> string {
    ai_initialize(s)
    m:=s.ai
    c:=&m.connections[provider]
    if !c.installed {return c.agent==.Command?"The command of the agent was not found":"Download the agent first"}
    if ai_running_count(m)!=0 || m.login || m.installer.pid!=0 || m.probe.active {return "Wait for the current operation to finish"}
    if c.agent!=.Command {
        if base.text_get(c.known_adapter[:])!=base.text_get(c.adapter[:]) || base.text_get(c.known_version[:])=="" {
            return ai_probe_start(s,{int(provider)},true)
        }
        return ai_login_start(s,provider)
    }
    if !use_existing {return ai_login_start(s,provider)}
    ai_workers_stop(s,provider)
    previous:=c^
    c.configured=true
    if !ai_settings_save(s) {c^=previous;return "The connection settings could not be saved"}
    return ""
}

ai_connection_disconnect :: proc(s:^Session,provider:Ai_Provider) {
    m:=s.ai
    m.connections[provider].configured=false
    ai_workers_stop(s,provider)
    if !ai_settings_save(s) {notify(s,"The connection settings could not be saved")}
}

// Starts the adapters of the queue one after the other, each only until it
// answers initialize: the only test that a program speaks ACP. What they
// announce is kept (ai_agent_announced); with connect the sign-in of the
// first is asked after.
ai_probe_start :: proc(s:^Session,queue:bit_set[0..<AI_CONNECTION_CAPACITY],connect:bool) -> string {
    m:=s.ai
    if m.probe.active || m.login || ai_running_count(m)!=0 || m.connection_pending.kind!=.None {return "Wait for the current operation to finish"}
    m.probe={queue=queue,connect=connect}
    m.connection_ui.busy=true
    // Each adapter starts once the processes before it ended.
    if ai_process_running(m) {ai_workers_stop(s,AI_CODEX,all=true);m.connection_pending={kind=.Probe};return ""}
    return ai_probe_next(s)
}

@(private)
ai_probe_next :: proc(s:^Session) -> string {
    m:=s.ai
    for index in 0..<AI_CONNECTION_CAPACITY {
        if index not_in m.probe.queue {continue}
        m.probe.queue-={index}
        provider:=Ai_Provider(index)
        if message:=ai_start_client(s,&m.workers[0],provider);message!="" {
            m.probe={}
            return message
        }
        m.probe.active,m.probe.provider=true,provider
        m.connection_ui.busy=true;m.connection_ui.error={}
        base.text_set(m.connection_ui.status[:],"Starting the adapter...")
        return ""
    }
    m.probe.active=false
    m.connection_ui.busy=false
    return ""
}

// The adapter being tested answered (failure empty) or did not: the next one
// starts, or the sign-in a connect waits for is asked.
ai_probe_end :: proc(s:^Session,failure:string) {
    m:=s.ai
    if !m.probe.active {return}
    provider,connect:=m.probe.provider,m.probe.connect
    acp.stop(&m.workers[0].client)
    m.probe.active=false
    if failure!="" {
        m.probe={}
        m.connection_ui.busy=false
        base.text_set(m.connection_ui.error[:],fmt.tprintf("%s did not answer as the ACP adapter of %s: %s",base.text_get(m.connections[provider].adapter[:]),ai_connection_name(m,provider),failure))
        return
    }
    if m.probe.queue!={} {m.connection_pending={kind=.Probe};return}
    m.probe={}
    m.connection_ui.busy=false
    if connect {
        m.connection_pending={kind=.Login,provider=provider}
        m.connection_ui.busy=true;m.connection_ui.screen=.Login
        base.text_set(m.connection_ui.status[:],"Closing the adapter...")
    }
}

ai_login_start :: proc(s:^Session,provider:Ai_Provider) -> string {
    ai_initialize(s)
    m:=s.ai
    if ai_running_count(m)!=0 || m.login || m.installer.pid!=0 || m.probe.active || m.connection_pending.kind!=.None {return "Wait for the current operation to finish"}
    if ai_process_running(m) {
        ai_workers_stop(s,provider,all=true)
        m.connection_pending={kind=.Login,provider=provider}
        m.connection_ui.busy=true;m.connection_ui.screen=.Login
        base.text_set(m.connection_ui.status[:],"Closing agent...")
        return ""
    }
    c:=&m.connections[provider]
    // Mirai signs in to no agent: Codex and Claude keep the sign-in of the
    // user (codex login, claude auth login), and Mirai only asks whether
    // there is one, with the environment of the user as it is.
    if c.agent!=.Command {
        if !c.installed {return "Download the agent first"}
        command:=make([dynamic]string,context.temp_allocator)
        if c.agent==.Codex {
            binary:=ai_codex_binary(s)
            if binary=="" {return "The native Codex executable is missing; install Codex or download the agent again"}
            append(&command,binary,"login","status")
        } else {
            binary:=ai_claude_binary()
            if binary=="" {return "Claude Code is missing; download the agent again"}
            append(&command,binary,"auth","status","--json")
        }
        process,error:=subprocess.start({command=command[:],working_dir=s.project_root},pipes=.Merged if c.agent==.Codex else .Separate)
        if error!=nil {return c.agent==.Codex?"Codex could not be started":"Claude Code could not be started"}
        m.login_provider=provider;m.login_process=process;m.login_cancelled=false;m.login=true
        m.connection_ui.busy=true;m.connection_ui.screen=.Login;m.connection_ui.log={};m.connection_ui.error={}
        base.text_set(m.connection_ui.status[:],c.agent==.Codex?"Checking the sign-in of Codex...":"Checking the sign-in of Claude Code...")
        return ""
    }
    if message:=ai_start_client(s,&m.workers[0],provider);message!="" {return message}
    m.login_provider=provider;m.login=true;m.connection_ui.busy=true;m.connection_ui.screen=.Login
    base.text_set(m.connection_ui.status[:],"Sign in using the browser opened by the agent")
    return ""
}

ai_login_poll :: proc(s:^Session) {
    m:=s.ai
    if m.login_process.pid==0 {return}
    buffer:[4096]u8
    for _ in 0..<8 {
        count,_:=subprocess.read(&m.login_process,.Stdout,buffer[:])
        if count==0 {break}
        used:=len(base.text_get(m.connection_ui.log[:]))
        available:=len(m.connection_ui.log)-1-used
        if available>0 {used+=copy(m.connection_ui.log[used:len(m.connection_ui.log)-1],buffer[:min(count,available)]);m.connection_ui.log[used]=0}
    }
    state,_:=subprocess.wait(&m.login_process,0)
    if !state.exited {return}
    code:=state.exit_code
    subprocess.release(&m.login_process)
    m.login=false;m.connection_ui.busy=false
    if m.login_cancelled {m.connection_ui.screen=.Overview;m.connection_ui.log={};base.text_set(m.connection_ui.status[:],"Cancelled");return}
    c:=&m.connections[m.login_provider]
    claude:=c.agent==.Claude
    signed_in:=code==0
    if claude {
        // Claude Code prints its state also when it is signed out, and then ends with 1.
        status:struct{loggedIn:bool}
        parsed:=json.unmarshal_string(base.text_get(m.connection_ui.log[:]),&status,allocator=context.temp_allocator)==nil
        if !parsed {m.connection_ui.log={};m.connection_ui.screen=.Overview;base.text_set(m.connection_ui.error[:],"Claude Code did not report its sign-in; update Claude Code");return}
        signed_in=status.loggedIn
    }
    m.connection_ui.log={}
    if !signed_in {
        m.connection_ui.screen=.Overview
        if claude {base.text_set(m.connection_ui.error[:],"Claude Code is not signed in on this computer. Run claude auth login in a terminal, then connect again");return}
        // A Codex that is not in PATH is named by its path.
        login:="codex login"
        if _,found:=ai_executable_find("codex");!found {login=fmt.tprintf(`"%s" login`,ai_codex_binary(s))}
        base.text_set(m.connection_ui.error[:],fmt.tprintf("Codex is not signed in on this computer. Run %s in a terminal, then connect again",login))
        return
    }
    previous:=c^
    c.configured=true
    if !ai_settings_save(s) {c^=previous;m.connection_ui.screen=.Overview;base.text_set(m.connection_ui.error[:],"The connection settings could not be saved");return}
    m.connection_ui.screen=.Overview
    base.text_set(m.connection_ui.status[:],claude?"Connected to Claude Code":"Connected to Codex")
}
