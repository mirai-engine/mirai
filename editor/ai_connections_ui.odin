package editor

import "core:fmt"
import "core:strings"
import "mirai:std/base"
import "mirai:ui"

Ai_Connections_Screen :: enum u8 {Closed,Overview,Auth,Login,Transfer,Uninstall,Add,Remove}
Ai_Connections_Ui :: struct {
    screen:Ai_Connections_Screen,
    provider:Ai_Provider,
    runtime:Ai_Runtime,
    available:[Ai_Runtime]bool,
    advanced:bool,
    error:[512]u8,
    notice:[512]u8, // what the user does with an installation of their own
    status:[128]u8,
    log:[8192]u8,
    scroll:f32,
    busy:bool,
    check_display_until:f64,
    operation:[16]u8,
    version:[64]u8,
    // The agent being added by its command.
    name:[64]u8,
    name_length:int,
    command:[AI_PATH_BYTES]u8,
    command_length:int,
    arguments:[1024]u8,
    arguments_length:int,
}

AI_CONNECTIONS_WIDTH :: f32(550)
AI_DISCLOSURE_PAD :: f32(10)  // before the triangle of Advanced settings
AI_DISCLOSURE_ICON :: f32(16) // its triangle
AI_DISCLOSURE_GAP :: f32(6)   // between an icon and the label of a button
AI_CONNECTION_RUNTIME_LABELS :: [Ai_Runtime]string{.Automatic="Automatic",.Bun="Bun",.Node="Node",.Pnpm="pnpm",.Bundled="Standalone package"}

ai_connections_open :: proc(s:^Session) {
    if s.ai==nil || !s.has_project {return}
    ai_agents_refresh(s)
    ui.popup_close(s.gui.ctx)
    state:=&s.ai.connection_ui
    if state.busy {
        ai_connections_runtimes_refresh(s)
        state.screen=s.ai.login || s.ai.connection_pending.kind==.Login?.Login:(s.ai.installer.pid!=0 && base.text_get(s.ai.install_operation[:])=="uninstall"?.Transfer:.Overview)
        return
    }
    state^={screen=.Overview,runtime=s.ai.default_runtime}
    ai_connections_runtimes_refresh(s)
}

@(private)
ai_connections_page :: proc(s:^Session,screen:Ai_Connections_Screen,provider:Ai_Provider) {
    state:=&s.ai.connection_ui
    state.screen=screen;state.provider=provider;state.error={};state.notice={};state.scroll=0
    state.runtime=s.ai.default_runtime
    ai_connections_runtimes_refresh(s)
    if screen==.Add {
        state.name_length,state.command_length,state.arguments_length=0,0,0
        s.gui.ctx.edit={}
    }
}

@(private)
ai_connections_error :: proc(s:^Session,message:string) -> bool {
    base.text_set(s.ai.connection_ui.error[:],message)
    return message!=""
}

@(private)
ai_connections_transfer :: proc(s:^Session,operation:string) {
    state:=&s.ai.connection_ui
    version:=base.text_get(state.version[:])
    if ai_connections_error(s,ai_install_start(s,operation,state.provider,state.runtime,version)) {return}
    base.text_set(state.operation[:],operation)
    state.busy=true
    if operation=="uninstall" {state.screen=.Transfer}
}

// Downloads or updates an agent at once from its card, which says how it
// goes and offers to cancel it.
@(private)
ai_connections_install :: proc(s:^Session,provider:Ai_Provider,operation:string) {
    m:=s.ai;state:=&m.connection_ui;c:=&m.connections[provider]
    versions:=AI_AGENT_VERSIONS
    // An installation of the user is updated by its command, which the editor gives.
    if c.user {base.text_set(state.notice[:],ai_install_start(s,operation,provider,c.runtime));return}
    latest:=base.text_get(c.latest[:])
    state.provider=provider
    state.runtime=c.installed?c.runtime:m.default_runtime
    base.text_set(state.version[:],latest!=""?latest:versions[c.agent])
    ai_connections_transfer(s,operation)
}

// Whether the download or the update of an agent is under way, or waits for its agents to close.
@(private)
ai_connection_installing :: proc(m:^Ai,provider:Ai_Provider) -> bool {
    if m.connection_pending.kind==.Install {return m.connection_pending.provider==provider && base.text_get(m.connection_pending.operation[:])!="uninstall"}
    operation:=base.text_get(m.install_operation[:])
    return m.installer.pid!=0 && m.install_provider==provider && (operation=="download" || operation=="update")
}

@(private)
ai_connections_back :: proc(s:^Session,label:string="Back") -> bool {
    ctx:=s.gui.ctx
    return ui.button(ctx,ui.id(ctx,"back"),{label=label,variant="field",width=84,height=32,center=true}).clicked
}

// The mark of an agent without its color.
@(private)
ai_connection_mark :: proc(agent:Ai_Agent) -> ui.Icon {
    icons:=[Ai_Agent]ui.Icon{.Codex=ui.icon_user(u8(User_Icon.Component)),.Claude=.Sparkle,.Command=ui.icon_user(u8(User_Icon.Connection))}
    return icons[agent]
}

@(private)
ai_connections_logo :: proc(ctx:^ui.Context,agent:Ai_Agent,size:f32) {
    colors:=[Ai_Agent]ui.Color{.Codex={230,232,237,255},.Claude={211,159,123,255},.Command={150,158,171,255}}
    if ui.box(ctx,{width=ui.fixed(size),height=ui.fixed(size),align_x=.Center,align_y=.Center,fill=colors[agent],radius=size*.25}) {
        ui.icon(ctx,ai_connection_mark(agent),{31,26,28,255},size*.56)
    }
}

@(private)
ai_connections_brand :: proc(s:^Session,provider:Ai_Provider) {
    ctx:=s.gui.ctx
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(48),gap=12,align_y=.Center}) {
        ai_connections_logo(ctx,s.ai.connections[provider].agent,40)
        ui.label(ctx,ai_connection_name(s.ai,provider),16,ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
    }
}

// The command of an agent added by it, as one line.
@(private)
ai_connection_command_line :: proc(ctx:^ui.Context,c:^Ai_Connection) -> string {
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,base.text_get(c.command[:]))
    for i in 0..<c.argument_count {strings.write_byte(&b,' ');strings.write_string(&b,base.text_get(c.arguments[i][:]))}
    return ui.text_store(ctx,strings.to_string(b))
}

@(private)
ai_connections_overview :: proc(s:^Session) {
    m:=s.ai;state:=&m.connection_ui;ctx:=s.gui.ctx
    makers:=AI_AGENT_MAKERS
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(32),align_y=.Center}) {
        ui.label(ctx,"Agents",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
        ui.spacer(ctx)
        waiting:=state.busy && base.text_get(m.install_operation[:])=="check"
        if ui.button(ctx,ui.id(ctx,"check_updates"),{label="Check for updates",icon=waiting?ui.icon_user(u8(User_Icon.Waiting)):.Refresh,variant="ghost",height=30,disabled=state.busy}).clicked {
            state.version={}
            ai_connections_transfer(s,"check")
        }
    }
    for &connection,index in ai_connections(m) {
        provider:=Ai_Provider(index)
        command_agent:=connection.agent==.Command
        ui.id_push(ctx,ui.id(ctx,"provider",index+1))
        version,latest:=base.text_get(connection.version[:]),base.text_get(connection.latest[:])
        update:=connection.installed && latest!="" && latest!=version
        installing:=ai_connection_installing(m,provider)
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,padding=ui.padding_all(12),fill=ui.tone(ctx,"card"),stroke=ui.tone(ctx,"rule"),radius=ui.metric(ctx,"radius_panel")}) {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=12,align_y=.Center}) {
                ai_connections_logo(ctx,connection.agent,36)
                if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,gap=4}) {
                    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=8,align_y=.Center}) {
                        ui.label(ctx,base.text_get(connection.name[:]),ui.metric(ctx,"font"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
                        ui.label(ctx,command_agent?ai_connection_command_line(ctx,&connection):makers[connection.agent],ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"),0)
                    }
                    // One line of state: connection, the version installed and the one that can replace it.
                    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6,align_y=.Center}) {
                        if installing {
                            ui.icon(ctx,ui.icon_user(u8(User_Icon.Waiting)),ui.tone(ctx,"accent_hover"),12)
                            ui.label(ctx,base.text_get(state.status[:]),ui.metric(ctx,"font_small"),ui.tone(ctx,"accent_hover"),0)
                        } else {
                            color:=connection.configured?ui.tone(ctx,"success"):ui.tone(ctx,"text_muted")
                            if ui.box(ctx,{width=ui.fixed(6),height=ui.fixed(6),fill=color,radius=3}) {}
                            missing:=command_agent?"Command not found":"Not installed"
                            ui.label(ctx,connection.configured?"Connected":connection.installed?"Not connected":missing,ui.metric(ctx,"font_small"),color)
                            if connection.installed && version!="" {ui.label(ctx,version,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))}
                            if connection.user {ui.label(ctx,"your installation",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))}
                            if update {buffer:[96]u8;ui.label(ctx,fmt.bprintf(buffer[:],"%s available",latest),ui.metric(ctx,"font_small"),ui.tone(ctx,"accent_hover"))}
                        }
                    }
                }
                // Download and Update start at once; while they go the button cancels them.
                action:="Download" if !connection.installed else ("Update" if update else ("Disconnect" if connection.configured else "Connect"))
                if installing {action="Cancel"}
                if ui.button(ctx,ui.id(ctx,"agent_action"),{label=action,variant=installing || connection.configured && !update?"field":"accent",width=96,height=ui.metric(ctx,"control"),center=true,disabled=!installing && (state.busy || command_agent && !connection.installed)}).clicked {
                    switch {
                    case installing:            ai_install_cancel(s)
                    case !connection.installed: ai_connections_install(s,provider,"download")
                    case update:                ai_connections_install(s,provider,"update")
                    case connection.configured: ai_connection_disconnect(s,provider)
                    case command_agent:         ai_connections_page(s,.Auth,provider)
                    case:                       ai_connections_error(s,ai_connection_set(s,provider,true))
                    }
                }
                menu_id:=ui.id(ctx,"options")
                if ui.button(ctx,ui.id(ctx,"more"),{label="···",variant="ghost",width=ui.metric(ctx,"control"),height=ui.metric(ctx,"control"),center=true,disabled=state.busy}).clicked {
                    anchor,_:=ui.widget_rect(ctx,ui.id(ctx,"more"));ui.popup_open(ctx,menu_id,anchor)
                }
                if ui.popup(ctx,menu_id,{align_right=true}) {
                    if command_agent {
                        if ui.menu_item(ctx,ui.id(ctx,"connection"),connection.configured?"Change connection...":"Connect...",{disabled=!connection.installed}) {ai_connections_page(s,.Auth,provider)}
                        ui.menu_separator(ctx)
                        if ui.menu_item(ctx,ui.id(ctx,"remove"),"Remove...") {ai_connections_page(s,.Remove,provider)}
                    } else if ui.menu_item(ctx,ui.id(ctx,"uninstall"),"Uninstall...",{disabled=!connection.installed || connection.user}) {ai_connections_page(s,.Uninstall,provider)}
                }
            }
        }
        ui.id_pop(ctx)
    }
    if ui.button(ctx,ui.id(ctx,"add_agent"),{label="Add agent by command",icon=.Plus,variant="ghost",width=-1,height=30,disabled=state.busy || m.connection_count>=AI_CONNECTION_CAPACITY}).clicked {ai_connections_page(s,.Add,AI_CODEX)}
    ai_connections_missing_runtime(s)
    if ui.button(ctx,ui.id(ctx,"advanced"),{label="Advanced settings",icon=state.advanced?.Chevron_Down:.Chevron_Right,icon_size=AI_DISCLOSURE_ICON,variant="ghost",width=-1,height=28,padding=AI_DISCLOSURE_PAD}).clicked {state.advanced=!state.advanced}
    if !state.advanced {return}
    // What it holds starts under the text of its title, past its triangle.
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(40),padding={AI_DISCLOSURE_PAD+AI_DISCLOSURE_ICON+AI_DISCLOSURE_GAP,0,0,0},gap=12,align_y=.Center}) {
        ui.label(ctx,"Runtime",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
        ui.spacer(ctx)
        labels:=AI_CONNECTION_RUNTIME_LABELS
        runtimes:=[5]string{labels[.Automatic],labels[.Bun],labels[.Node],labels[.Pnpm],labels[.Bundled]}
        selected:=int(m.default_runtime)
        if ui.dropdown(ctx,ui.id(ctx,"runtime"),{list=runtimes[:]},&selected,{width=186,height=30,disabled=state.busy}) {
            previous:=m.default_runtime;m.default_runtime=Ai_Runtime(selected);state.runtime=m.default_runtime
            if !ai_settings_save(s) {m.default_runtime=previous;ai_connections_error(s,"The connection settings could not be saved")}
        }
    }
}

@(private)
ai_connections_missing_runtime :: proc(s:^Session) {
    state:=&s.ai.connection_ui;ctx:=s.gui.ctx
    if state.available[.Bun] || state.available[.Node] || state.available[.Pnpm] {return}
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(42),gap=12,align_y=.Center}) {
        ui.label(ctx,"No runtime found",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
        ui.spacer(ctx)
        if ui.button(ctx,ui.id(ctx,"download_bun"),{label="Download Bun",icon=state.busy?ui.icon_user(u8(User_Icon.Waiting)):.Import,variant="field",height=32,disabled=state.busy}).clicked {ai_connections_transfer(s,"runtime")}
    }
}

// An agent added by its command: marked connected, or signed in by itself.
// Codex and Claude have no page: Connect asks them whether they are signed in.
@(private)
ai_connections_auth :: proc(s:^Session) {
    state:=&s.ai.connection_ui;ctx:=s.gui.ctx
    ai_connections_brand(s,state.provider)
    if ui.button(ctx,ui.id(ctx,"existing"),{label="Use existing sign-in",variant="field",width=-1,height=38,center=true}).clicked {
        if !ai_connections_error(s,ai_connection_set(s,state.provider,true)) {ai_connections_page(s,.Overview,state.provider)}
    }
    if ui.button(ctx,ui.id(ctx,"browser"),{label="Sign in with the agent",variant="accent",width=-1,height=38,center=true}).clicked {
        if !ai_connections_error(s,ai_connection_set(s,state.provider,false)) {state.screen=.Login;state.busy=true}
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(36),align_x=.End,align_y=.Center}) {
        if ai_connections_back(s) {ai_connections_page(s,.Overview,state.provider)}
    }
}

@(private)
ai_connections_wait :: proc(s:^Session) {
    state:=&s.ai.connection_ui;ctx:=s.gui.ctx
    if state.screen==.Login {ai_connections_brand(s,state.provider)}
    status:=base.text_get(state.status[:])
    ui.label(ctx,status!=""?status:(state.screen==.Login?"Waiting for browser sign-in":"Preparing installation"),ui.metric(ctx,"font_small"),ui.tone(ctx,"text"))
    if state.screen==.Login && s.ai.connections[state.provider].agent==.Command && base.text_get(state.log[:])!="" {ui.text(ctx,base.text_get(state.log[:]),ui.prose(ctx,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted")))}
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(38),align_x=.End,align_y=.Center}) {
        if ai_connections_back(s,state.busy?"Cancel":"Done") {
            if state.busy {ai_install_cancel(s)}
            if s.ai.installer.pid!=0 || s.ai.login {
                state.busy=true
                state.screen=s.ai.login?.Login:.Transfer
            } else {
                state.busy=false
                ai_connections_page(s,.Overview,state.provider)
            }
        }
    }
}

// The name, the command and the arguments of an agent that speaks ACP.
@(private)
ai_connections_add :: proc(s:^Session) {
    state:=&s.ai.connection_ui;ctx:=s.gui.ctx
    field :: proc(ctx:^ui.Context,id:ui.Id,label,placeholder:string,buffer:[]u8,length:^int) {
        ui.label(ctx,label,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
        ui.text_field(ctx,id,buffer,length,{height=32,live=true,placeholder=placeholder})
    }
    field(ctx,ui.id(ctx,"agent_name"),"Name","Gemini",state.name[:len(state.name)-1],&state.name_length)
    field(ctx,ui.id(ctx,"agent_command"),"Command","gemini",state.command[:len(state.command)-1],&state.command_length)
    field(ctx,ui.id(ctx,"agent_arguments"),"Arguments","--experimental-acp",state.arguments[:len(state.arguments)-1],&state.arguments_length)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(40),gap=8,align_x=.End,align_y=.Center}) {
        if ai_connections_back(s,"Cancel") {ai_connections_page(s,.Overview,AI_CODEX)}
        if ui.button(ctx,ui.id(ctx,"confirm_add"),{label="Add",variant="accent",width=100,height=32,center=true,disabled=state.name_length==0 || state.command_length==0}).clicked {
            provider,message:=ai_connection_add(s,string(state.name[:state.name_length]),string(state.command[:state.command_length]),string(state.arguments[:state.arguments_length]))
            if !ai_connections_error(s,message) {ai_connections_page(s,.Auth,provider)}
        }
    }
}

@(private)
ai_connections_remove :: proc(s:^Session) {
    state:=&s.ai.connection_ui;ctx:=s.gui.ctx
    ai_connections_brand(s,state.provider)
    ui.label(ctx,"Remove the connection; its chats stay in the history",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(40),gap=8,align_x=.End,align_y=.Center}) {
        if ai_connections_back(s,"Cancel") {ai_connections_page(s,.Overview,AI_CODEX)}
        if ui.button(ctx,ui.id(ctx,"confirm_remove"),{label="Remove",variant="field",width=110,height=32,center=true}).clicked {
            if !ai_connections_error(s,ai_connection_remove(s,state.provider)) {ai_connections_page(s,.Overview,AI_CODEX)}
        }
    }
}

@(private)
ai_connections_uninstall :: proc(s:^Session) {
    state:=&s.ai.connection_ui;ctx:=s.gui.ctx
    ai_connections_brand(s,state.provider)
    ui.label(ctx,"Remove installation and disconnect",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(40),gap=8,align_x=.End,align_y=.Center}) {
        if ai_connections_back(s,"Cancel") {ai_connections_page(s,.Overview,state.provider)}
        if ui.button(ctx,ui.id(ctx,"confirm_uninstall"),{label="Uninstall",variant="field",width=110,height=32,center=true}).clicked {ai_connections_transfer(s,"uninstall")}
    }
}

ai_connection_configure :: proc(s:^Session,provider:Ai_Provider,model,effort:string) -> string {
    m:=s.ai;c:=&m.connections[provider]
    if len(model)>=len(c.model) || len(effort)>=len(c.effort) {return "The AI configuration exceeds its capacity"}
    if strings.contains_any(model,"\r\n\t") || strings.contains_any(effort,"\r\n\t ") {return "Invalid model or reasoning level"}
    if c.agent==.Codex && model!="" && !ai_codex_model_supported(model) {return "Unsupported Codex model"}
    previous:=c^
    if model!="" {base.text_set(c.model[:],model)}
    if effort!="" {base.text_set(c.effort[:],effort)}
    if !ai_settings_save(s) {c^=previous;return "The connection settings could not be saved"}
    return ""
}

ai_connections_build :: proc(s:^Session) {
    if s.ai==nil || s.gui==nil || s.gui.ctx==nil {return}
    state:=&s.ai.connection_ui
    if state.screen==.Closed {return}
    ctx:=s.gui.ctx
    if ui.escape(ctx) {ai_connections_page(s,.Closed,state.provider);return}
    name:=ai_connection_name(s.ai,state.provider)
    title_buffer:[128]u8
    title:="AI connections"
    switch state.screen {
    case .Closed,.Overview:
    case .Auth:title=fmt.bprintf(title_buffer[:],"Connect %s",name)
    case .Login:title="Connecting"
    case .Transfer:title="Installation"
    case .Uninstall:title=fmt.bprintf(title_buffer[:],"Uninstall %s?",name)
    case .Add:title="Add agent by command"
    case .Remove:title=fmt.bprintf(title_buffer[:],"Remove %s?",name)
    }
    closed:=false
    defer if closed {ai_connections_page(s,.Closed,state.provider)}
    if ui.modal(ctx,shell_id(s.gui,"ai_connections"),{width=AI_CONNECTIONS_WIDTH,padding=20,gap=14,scroll=&state.scroll,close=&closed,own_cross=true}) {
        ui.id_push(ctx,shell_id(s.gui,"ai_connections"))
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(30),align_y=.Center}) {
            ui.label(ctx,title,ui.metric(ctx,"font_title"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
            ui.spacer(ctx)
            if ui.icon_button(ctx,ui.id(ctx,"close"),.Cross,26).clicked {ai_connections_page(s,.Closed,state.provider)}
        }
        switch state.screen {
        case .Overview:ai_connections_overview(s)
        case .Auth:ai_connections_auth(s)
        case .Login,.Transfer:ai_connections_wait(s)
        case .Uninstall:ai_connections_uninstall(s)
        case .Add:ai_connections_add(s)
        case .Remove:ai_connections_remove(s)
        case .Closed:
        }
        if base.text_get(state.notice[:])!="" {ui.text(ctx,base.text_get(state.notice[:]),ui.prose(ctx,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted")))}
        if base.text_get(state.error[:])!="" {
            ui.text(ctx,base.text_get(state.error[:]),ui.prose(ctx,ui.metric(ctx,"font_small"),ui.tone(ctx,"danger")))
            if base.text_get(state.log[:])!="" {ui.text(ctx,base.text_get(state.log[:]),ui.prose(ctx,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted")))}
        }
        ui.id_pop(ctx)
    }
}
