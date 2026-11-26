package editor

import "core:crypto"
import "core:fmt"
import "core:strconv"
import "core:strings"
import ka "mirai:cook/kai"
import vcs "mirai:kai"
import "mirai:platform"
import "mirai:std/serial"
import "mirai:ui"

// The team views of the Kai tab and its dialogs. They draw what
// kai_team_read left in the team's arena and what the team keeps; a button
// asks for its kai.* method, which runs between frames as any call does.
// Opening a proposal, folding and typing only change what the person sees.

// Asks for a kai.* method with params, between frames.
@(private)
kai_ask :: proc(s:^Session,method:string,format:string,args:..any) {
    command_call(s,method,fmt.tprintf(format,..args))
}

@(private)
kai_quote :: proc(text:string) -> string {return serial.text_quote(text)}

@(private)
kai_typed :: proc(buffer:[]u8,length:int) -> string {return strings.trim_space(string(buffer[:length]))}

// A line of text of the tab: wrapped, in a tone.
@(private)
kai_line :: proc(ctx:^ui.Context,text:string,tone:string="text_muted") {
    if text=="" {return}
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,padding={KAI_ROW_PAD,2,KAI_ROW_PAD,2}}) {
        ui.text(ctx,text,ui.prose(ctx,ui.metric(ctx,"font_small"),ui.tone(ctx,tone)))
    }
}

// A row of a name and what follows it, faint; with an icon button at its end
// when icon is given: true when it is clicked.
@(private)
kai_row_button :: proc(ctx:^ui.Context,name,rest:string,icon:ui.Icon=.None,tip:="",disabled:=false) -> (clicked:bool) {
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=6,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0}}) {
        kai_row_names(ctx,name,rest,ui.tone(ctx,"text"))
        if icon!=.None {clicked=ui.icon_button(ctx,ui.id(ctx,"act"),icon,ui.metric(ctx,"row")-4,tip=tip,disabled=disabled).clicked}
    }
    return
}

// Buttons that grow side by side, of the field variant, or one under another
// when side by side the tab would cut a label; the index of the one clicked, -1.
@(private)
kai_buttons :: proc(s:^Session,name:string,labels:[]string,accent:=-1,disabled:=false) -> (clicked:int) {
    ctx:=s.gui.ctx
    clicked=-1
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6,direction=kai_side_by_side(s,labels)?.Row:.Column}) {
        for label,i in labels {
            // Side by side each keeps the room of its label, and they share what is left.
            l:=ui.Layout{width=ui.grow(min=ui.text_width(&ctx.font,label,ui.metric(ctx,"font"))+2*KAI_BUTTON_SIDE),height=ui.fixed(ui.metric(ctx,"control"))}
            if ui.button(ctx,ui.id(ctx,name,i),{label=label,variant=i==accent?"accent":"field",width=-1,center=true,disabled=disabled,layout=&l}).clicked {clicked=i}
        }
    }
    return
}

// Whether buttons of labels fit their texts side by side in the tab.
@(private)
kai_side_by_side :: proc(s:^Session,labels:[]string) -> bool {
    ctx:=s.gui.ctx
    if s.kai.state.width<=0 {return true}
    size:=ui.metric(ctx,"font")
    needed:=f32(6*(len(labels)-1))
    for label in labels {needed+=ui.text_width(&ctx.font,label,size)+2*KAI_BUTTON_SIDE}
    return needed<=s.kai.state.width
}

// The room a button keeps on each side of its label.
KAI_BUTTON_SIDE :: 10

// A field of the team views.
@(private)
kai_field :: proc(ctx:^ui.Context,name:string,buffer:[]u8,length:^int,placeholder:string,width:ui.Size={},multiline:=false) {
    ui.text_field(ctx,ui.id(ctx,name),buffer,length,{placeholder=placeholder,live=true,width=width,multiline=multiline,rows=multiline?3:0})
}

// The switch of the views of the tab.
@(private)
kai_tabs_build :: proc(s:^Session) {
    ctx:=s.gui.ctx
    t:=&s.kai.state.team
    labels:=[Kai_Tab]string{.Changes="Changes",.Proposals="Proposals",.Team="Team"}
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
        for tab in Kai_Tab {
            if ui.button(ctx,ui.id(ctx,"kai_tab",int(tab)),{label=labels[tab],variant=t.tab==tab?"field":"ghost",width=-1,center=true,height=ui.metric(ctx,"control")-6,size=ui.metric(ctx,"font_small")}).clicked {t.tab=tab}
        }
    }
}

// What refused the last snapshot or publish, and the button that resolves it.
@(private)
kai_refusal_build :: proc(s:^Session) {
    ctx:=s.gui.ctx
    r:=&s.kai.state.team.refusal
    if r.text=="" {return}
    kai_line(ctx,r.text,"danger")
    label:=""
    switch r.action {
    case .None:
    case .Keep_Public: label="Keep public"
    case .Rotate: label="Rotate the key"
    }
    if label=="" {return}
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,4}}) {
        if ui.button(ctx,ui.id(ctx,"kai_resolve_refusal"),{label=label,variant="field",width=-1,center=true}).clicked {
            switch r.action {
            case .None:
            case .Keep_Public:
                place:=r.line>0?fmt.tprintf("%s:%d",r.path,r.line):r.path
                kai_ask(s,"kai.scopes",`{{"public":%s}}`,kai_quote(place))
            case .Rotate:
                scope:=r.scope
                kai_ask(s,"kai.scopes",`{{"rotate":%s}}`,kai_quote(ka.hex(scope[:4])))
            }
        }
    }
}

// The shared bookmarks in BOOKMARKS: a click starts a change on one; the
// project's move to the working copy's parent; a name typed shares it there.
@(private)
kai_shared_build :: proc(s:^Session) {
    ctx:=s.gui.ctx
    t:=&s.kai.state.team
    v:=&t.view
    if v.org<0 {return}
    for &b,i in v.shared {
        ui.id_push(ctx,ui.id(ctx,"shared",i))
        row:=ui.id(ctx,"row")
        it:=ui.interact(ctx,row,{.Focusable})
        on:=ai_pointer_on(ctx,row)
        if ui.box(ctx,{id=row,width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=6,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0},fill=on?ui.tone(ctx,"chip"):{},radius=ui.metric(ctx,"radius_control")}) {
            ui.icon(ctx,ui.icon_user(u8(User_Icon.Users)),ui.tone(ctx,"text_faint"),12)
            kai_row_names(ctx,b.name,b.here?"":"not here yet",ui.tone(ctx,"text"))
            if b.device==({}) && ui.icon_button(ctx,ui.id(ctx,"move"),ui.icon_user(u8(User_Icon.Up)),ui.metric(ctx,"row")-4,tip="Move it to the working copy's parent for the whole org").clicked {
                kai_ask(s,"kai.bookmarks",`{{"move":%s,"change":"@-"}}`,kai_quote(b.name))
            }
        }
        if it.clicked && b.here {kai_ask(s,"kai.new",`{{"parents":[%s]}}`,kai_quote(b.name))}
        ui.id_pop(ctx)
    }
    f:=&t.fields
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6,padding={KAI_ROW_PAD,2,KAI_ROW_PAD,2}}) {
        kai_field(ctx,"kai_share_name",f.bookmark[:],&f.bookmark_length,"Bookmark")
        name:=kai_typed(f.bookmark[:],f.bookmark_length)
        if ui.button(ctx,ui.id(ctx,"kai_share"),{label="Share @-",variant="field",disabled=name==""}).clicked {
            kai_ask(s,"kai.bookmarks",`{{"move":%s,"change":"@-"}}`,kai_quote(name))
        }
    }
}

// The proposals of the project, or the one open.
kai_proposals_build :: proc(s:^Session) {
    ctx:=s.gui.ctx
    t:=&s.kai.state.team
    v:=&t.view
    if v.org<0 {
        kai_line(ctx,"The project is in no org: the Team view puts it in one.")
        return
    }
    if t.proposal!={} && v.shown {
        kai_proposal_build(s)
        return
    }
    f:=&t.fields
    kai_field(ctx,"kai_target",f.target[:],&f.target_length,"main")
    kai_field(ctx,"kai_title",f.title[:],&f.title_length,"Title: the parent's description")
    target:=kai_typed(f.target[:],f.target_length)
    if target=="" {target="main"}
    if kai_buttons(s,"kai_open",{"Open proposal"},0)==0 {
        title:=kai_typed(f.title[:],f.title_length)
        if title!="" {kai_ask(s,"kai.proposals",`{{"open":%s,"title":%s}}`,kai_quote(target),kai_quote(title))} else {kai_ask(s,"kai.proposals",`{{"open":%s}}`,kai_quote(target))}
        f.title_length=0
    }
    kai_head(ctx,"PROPOSALS",len(v.proposals))
    for &row,i in v.proposals {
        ui.id_push(ctx,ui.id(ctx,"proposal",i))
        id:=ui.id(ctx,"row")
        it:=ui.interact(ctx,id,{.Focusable})
        on:=ai_pointer_on(ctx,id)
        if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")-4),gap=8,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0},fill=on?ui.tone(ctx,"chip"):{},radius=ui.metric(ctx,"radius_control")}) {
            open:=row.status==.Open
            if ui.box(ctx,{width=ui.fixed(7),height=ui.fixed(7),fill=open?ui.tone(ctx,"accent"):ui.tone(ctx,"text_faint"),radius=3.5}) {}
            text:[96]u8
            detail:=fmt.bprintf(text[:],"%s, %v, %d approvals",row.target,row.status,row.approvals)
            kai_row_names(ctx,row.title,detail,ui.tone(ctx,"text"))
        }
        if it.clicked {
            t.proposal=row.id
            t.fields.file,t.fields.entity,t.fields.key=-1,false,0
            kai_team_read(s)
        }
        ui.id_pop(ctx)
    }
}

// The file of the open proposal's stack that index names over every change.
@(private)
kai_stack_file :: proc(v:^Kai_Team_View,index:int) -> string {
    if index<0 {return ""}
    at:=0
    for files in v.changes {
        if index<at+len(files) {return files[index-at].path}
        at+=len(files)
    }
    return ""
}

// One proposal: its stack with what each change did, its comments where they
// hang, verdicts, checks, what keeps it from landing, and what to do with it.
@(private)
kai_proposal_build :: proc(s:^Session) {
    ctx:=s.gui.ctx
    t:=&s.kai.state.team
    v:=&t.view
    x:=&v.proposal
    f:=&t.fields
    id:=x.id
    digits:[12]u8
    hex:=fmt.bprintf(digits[:],"%02x%02x%02x",id[0],id[1],id[2])
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"control")),gap=6,align_y=.Center}) {
        if ui.icon_button(ctx,ui.id(ctx,"kai_back"),ui.icon_user(u8(User_Icon.Back)),ui.metric(ctx,"row"),tip="The proposals").clicked {
            t.proposal={}
            kai_team_read(s)
            return
        }
        ui.label(ctx,x.title,ui.metric(ctx,"font"),ui.tone(ctx,"text"),0,fade=true)
    }
    text:[160]u8
    kai_line(ctx,fmt.bprintf(text[:],"%s on %s by %s, %v",hex,x.target,x.opener,x.status))
    kai_line(ctx,x.text,"text")
    kai_head(ctx,"STACK",len(x.stack))
    index:=0
    for &item,i in x.stack {
        ui.id_push(ctx,ui.id(ctx,"item",i))
        description:=item.description!=""?item.description:"(no description)"
        if cut:=strings.index_byte(description,'\n');cut>=0 {description=description[:cut]}
        change:=item.change
        kai_row_names(ctx,description,fmt.bprintf(text[:],"%02x%02x%02x",change[0],change[1],change[2]),ui.tone(ctx,"text"))
        for &file,k in v.changes[i] {
            ui.id_push(ctx,ui.id(ctx,"file",k))
            if kai_file_open_row(ctx,&file,f.file==index) {
                f.file,f.entity,f.key,f.lines_length=index,false,0,0
                if message:=kai_detail_open(s,.Proposals,item.revision,file.path,index);message!="" {notify(s,message)}
            }
            index+=1
            ui.id_pop(ctx)
        }
        ui.id_pop(ctx)
    }
    if len(x.notes)>0 {
        kai_head(ctx,"COMMENTS",len(x.notes))
        for &n,i in x.notes {
            ui.id_push(ctx,ui.id(ctx,"note",i))
            place:=""
            switch {
            case n.path=="": place="on the proposal"
            case n.anchor.kind==.Lines: place=fmt.bprintf(text[:],"%s:%d-%d",n.path,n.anchor.line,n.anchor.line+n.anchor.lines-1)
            case n.anchor.kind==.Structural: place=fmt.bprintf(text[:],"%s#%d",n.path,n.anchor.key)
            case: place=n.path
            }
            kai_row_names(ctx,n.author,place,ui.tone(ctx,n.outdated?"text_faint":"text"))
            if n.outdated {kai_line(ctx,"Outdated: what it named changed","text_faint")}
            kai_line(ctx,n.text,n.outdated?"text_faint":"text")
            ui.id_pop(ctx)
        }
    }
    if len(x.verdicts)+len(x.checks)>0 {
        kai_head(ctx,"VERDICTS AND CHECKS",len(x.verdicts)+len(x.checks))
        for &verdict,i in x.verdicts {
            ui.id_push(ctx,ui.id(ctx,"verdict",i))
            kai_row_names(ctx,verdict.user,fmt.bprintf(text[:],"%v%s",verdict.verdict,verdict.current?"":", on an earlier revision"),ui.tone(ctx,verdict.current?"text":"text_faint"))
            ui.id_pop(ctx)
        }
        for &c,i in x.checks {
            ui.id_push(ctx,ui.id(ctx,"check",i))
            kai_row_names(ctx,c.name,fmt.bprintf(text[:],"%v",c.state),ui.tone(ctx,c.state==.Failed?"danger":"text"))
            ui.id_pop(ctx)
        }
    }
    switch {
    case x.status==.Landed: kai_line(ctx,"It landed.")
    case x.status==.Closed: kai_line(ctx,"It is closed.")
    case x.blocking=="": kai_line(ctx,"It may land.","success")
    case: kai_line(ctx,x.blocking,"danger")
    }
    kai_comment_build(s)
    open:=x.status==.Open
    switch kai_buttons(s,"kai_verdict",{"Approve","Request changes","Withdraw"},disabled=!open) {
    case 0: kai_ask(s,"kai.proposal",`{{"proposal":%s,"verdict":"approve"}}`,kai_quote(hex))
    case 1: kai_ask(s,"kai.proposal",`{{"proposal":%s,"verdict":"changes"}}`,kai_quote(hex))
    case 2: kai_ask(s,"kai.proposal",`{{"proposal":%s,"verdict":"withdraw"}}`,kai_quote(hex))
    }
    kai_field(ctx,"kai_check_command",f.command[:],&f.command_length,"Command, as mirai test kai")
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6}) {
        kai_field(ctx,"kai_check_name",f.check[:],&f.check_length,"Check")
        name,command:=kai_typed(f.check[:],f.check_length),kai_typed(f.command[:],f.command_length)
        if ui.button(ctx,ui.id(ctx,"kai_run_check"),{label="Run",variant="field",disabled=!open || name=="" || command==""}).clicked {
            words:=strings.fields(command,context.temp_allocator)
            quoted:=make([]string,len(words),context.temp_allocator)
            for w,i in words {quoted[i]=kai_quote(w)}
            kai_ask(s,"kai.proposal",`{{"proposal":%s,"check":%s,"command":[%s]}}`,kai_quote(hex),kai_quote(name),strings.join(quoted,",",context.temp_allocator))
        }
    }
    labels:=[3]string{"Revise",open?"Close":"Reopen","Land"}
    switch kai_buttons(s,"kai_proposal_act",labels[:],accent=open && x.blocking==""?2:-1,disabled=x.status==.Landed) {
    case 0: kai_ask(s,"kai.proposal",`{{"proposal":%s,"revise":true}}`,kai_quote(hex))
    case 1: kai_ask(s,"kai.proposal",open?`{{"proposal":%s,"close":true}}`:`{{"proposal":%s,"reopen":true}}`,kai_quote(hex))
    case 2: if open && x.blocking=="" {kai_ask(s,"kai.proposal",`{{"proposal":%s,"land":true}}`,kai_quote(hex))}
    }
}

// The comment on the open proposal: on the whole of it, on the file picked
// in the stack, on lines of it (typed, or picked in its detail), on the
// entity picked in its detail, or on the entity selected in the scene.
@(private)
kai_comment_build :: proc(s:^Session) {
    ctx:=s.gui.ctx
    t:=&s.kai.state.team
    v:=&t.view
    f:=&t.fields
    id:=v.proposal.id
    digits:[12]u8
    hex:=fmt.bprintf(digits[:],"%02x%02x%02x",id[0],id[1],id[2])
    file:=kai_stack_file(v,f.file)
    kai_field(ctx,"kai_comment",f.comment[:],&f.comment_length,"Comment",multiline=true)
    selected:=s.selection!=nil && len(s.selection.entities)==1
    if file!="" {
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6,align_y=.Center}) {
            kai_row_names(ctx,"On",file,ui.tone(ctx,"text_faint"))
            text:[32]u8
            switch {
            case f.key!=0: ui.label(ctx,fmt.bprintf(text[:],"#%x",f.key),ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))
            case !f.entity: kai_field(ctx,"kai_lines",f.lines[:],&f.lines_length,"Lines 3-7",ui.fixed(80))
            }
        }
        if f.key==0 && selected && (strings.has_suffix(file,".scene") || strings.has_suffix(file,".prefab")) {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0}}) {
                ui.checkbox(ctx,ui.id(ctx,"kai_on_entity"),&f.entity)
                ui.label(ctx,"Selected entity",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))
            }
        }
    }
    comment:=kai_typed(f.comment[:],f.comment_length)
    if kai_buttons(s,"kai_comment_go",{"Comment"},disabled=comment=="")==0 {
        proposal:=kai_quote(hex)
        lines:=kai_typed(f.lines[:],f.lines_length)
        switch {
        case file=="": kai_ask(s,"kai.proposal",`{{"proposal":%s,"comment":%s}}`,proposal,kai_quote(comment))
        case f.key!=0: kai_ask(s,"kai.proposal",`{{"proposal":%s,"comment":%s,"file":%s,"entity":%d}}`,proposal,kai_quote(comment),kai_quote(file),f.key)
        case f.entity && selected:
            entity:=api_entity_id(edited_world(s),s.selection.entities[0])
            kai_ask(s,"kai.proposal",`{{"proposal":%s,"comment":%s,"file":%s,"entity":%d}}`,proposal,kai_quote(comment),kai_quote(file),u64(entity))
        case lines!="": kai_ask(s,"kai.proposal",`{{"proposal":%s,"comment":%s,"file":%s,"lines":%s}}`,proposal,kai_quote(comment),kai_quote(file),kai_quote(lines))
        case: kai_ask(s,"kai.proposal",`{{"proposal":%s,"comment":%s,"file":%s}}`,proposal,kai_quote(comment),kai_quote(file))
        }
        f.comment_length,f.lines_length=0,0
    }
}

// The team: who this device is, its orgs with their members, devices, nodes
// and projects, pairing, the peers, and the private files of the project.
kai_team_build :: proc(s:^Session) {
    ctx:=s.gui.ctx
    t:=&s.kai.state.team
    v:=&t.view
    f:=&t.fields
    text:[160]u8
    if !t.opened {
        kai_line(ctx,"The machine of the store does not open, and the team needs it: open the project again once it does.","danger")
        kai_line(ctx,t.machine.why)
        return
    }
    kai_line(ctx,kai_runner_text(t))
    me:=&v.identity
    kai_head(ctx,"IDENTITY",len(me.devices))
    if me.user=={} {
        kai_line(ctx,"This device has no user: make one, join another device of yours with its ticket below, or recover yours with its recovery key.")
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6}) {
            kai_field(ctx,"kai_handle",f.name[:],&f.name_length,"Handle")
            name:=kai_typed(f.name[:],f.name_length)
            if ui.button(ctx,ui.id(ctx,"kai_user_make"),{label="Make user",variant="accent",disabled=name==""}).clicked {
                kai_ask(s,"kai.identity",`{{"name":%s}}`,kai_quote(name))
                f.name_length=0
            }
            if ui.button(ctx,ui.id(ctx,"kai_user_recover"),{label="Recover",variant="field"}).clicked {kai_dialog_open(s,.Recover)}
        }
    } else {
        kai_row_names(ctx,me.handle,fmt.bprintf(text[:],"this device: %s",me.device),ui.tone(ctx,"text"))
        for &d,i in me.devices {
            ui.id_push(ctx,ui.id(ctx,"device",i))
            state:=d.revoked?"revoked":d.this?"this device":""
            if kai_row_button(ctx,d.name,state,d.revoked || d.this?.None:.Cross,"Revoke: what it signs from now on counts nowhere") {
                kai_ask(s,"kai.identity",`{{"revoke":%s}}`,kai_quote(d.name))
            }
            ui.id_pop(ctx)
        }
        switch kai_buttons(s,"kai_identity_act",{me.recovered?"Rotate recovery key":"Set a recovery key","Copy subject"}) {
        case 0:
            if me.recovered {
                kai_dialog_open(s,.Rotate)
            } else {
                kai_ask(s,"kai.identity",`{"first_recovery":true}`)
            }
        case 1: if s.app!=nil && s.app.platform!=nil {platform.clipboard_set(s.app.platform,me.subject)}
        }
    }
    if me.user!={} {kai_orgs_build(s)}
    kai_pairing_build(s)
    if len(v.peers)>0 || len(v.behind)>0 {
        kai_head(ctx,"PEERS",len(v.peers))
        for &b,i in v.behind {
            ui.id_push(ctx,ui.id(ctx,"behind",i))
            if b.behind>0 {
                kai_row_names(ctx,b.org,fmt.bprintf(text[:],"behind: %d entries peers named are not here, writes wait",b.behind),ui.tone(ctx,"danger"))
            } else {
                kai_row_names(ctx,b.org,fmt.bprintf(text[:],"let go of %d entries peers named that never came",b.unfound),ui.tone(ctx,"text_faint"))
            }
            ui.id_pop(ctx)
        }
        for &p,i in v.peers {
            ui.id_push(ctx,ui.id(ctx,"peer",i))
            kai_row_names(ctx,p.who,fmt.bprintf(text[:],"%s, %s",p.org,p.rung),ui.tone(ctx,"text"))
            ui.id_pop(ctx)
        }
    }
    if v.org>=0 {kai_scopes_build(s)}
}

@(private)
kai_orgs_build :: proc(s:^Session) {
    ctx:=s.gui.ctx
    t:=&s.kai.state.team
    v:=&t.view
    f:=&t.fields
    text:[160]u8
    kai_head(ctx,"ORGS",len(v.orgs))
    if len(v.orgs)==0 {
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6}) {
            kai_field(ctx,"kai_org_name",f.org[:],&f.org_length,"Org name")
            name:=kai_typed(f.org[:],f.org_length)
            if ui.button(ctx,ui.id(ctx,"kai_org_make"),{label="Make org",variant="accent",disabled=name==""}).clicked {
                kai_ask(s,"kai.org",`{{"new":%s}}`,kai_quote(name))
                f.org_length=0
            }
        }
        return
    }
    for &o,i in v.orgs {
        ui.id_push(ctx,ui.id(ctx,"org",i))
        id:=o.id
        admin:=o.role==.Admin || o.role==.Owner
        kai_row_names(ctx,o.name!=""?o.name:"(its log is not here yet)",fmt.bprintf(text[:],"you: %s",ka.role_text(o.role)),ui.tone(ctx,"text"))
        if v.org<0 && admin {
            kai_line(ctx,"Put the open project in it: public lets anyone read it, org only its members.")
            switch kai_buttons(s,"kai_add",{"Public","Org only"}) {
            case 0: kai_ask(s,"kai.org",`{{"org":"%s","add":"public"}}`,kai_org_text(id))
            case 1: kai_ask(s,"kai.org",`{{"org":"%s","add":"org"}}`,kai_org_text(id))
            }
        }
        for &member,k in o.members {
            ui.id_push(ctx,ui.id(ctx,"member",k))
            handle:=member.handle!=""?member.handle:"(its log is not here yet)"
            devices:=len(member.devices)
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=6,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0}}) {
                kai_row_names(ctx,handle,fmt.bprintf(text[:],"%d devices",devices),ui.tone(ctx,"text"))
                owner:=member.role==.Owner
                // A click on the role gives the next one: reader, writer, admin.
                if ui.button(ctx,ui.id(ctx,"role"),{label=ka.role_text(member.role),variant="ghost",size=ui.metric(ctx,"font_small"),disabled=!admin || owner}).clicked {
                    next:=member.role==.Reader?"writer":member.role==.Writer?"admin":"reader"
                    kai_ask(s,"kai.org",`{{"org":"%s","member":"%s","role":%s}}`,kai_org_text(id),kai_member_text(member.user),kai_quote(next))
                }
                if o.role==.Owner && !owner && ui.icon_button(ctx,ui.id(ctx,"transfer"),ui.icon_user(u8(User_Icon.Share)),ui.metric(ctx,"row")-4,tip="Give the org to this member").clicked {
                    kai_ask(s,"kai.org",`{{"org":"%s","transfer":"%s"}}`,kai_org_text(id),kai_member_text(member.user))
                }
                if admin && !owner && member.user!=t.machine.user && ui.icon_button(ctx,ui.id(ctx,"remove"),ui.icon_user(u8(User_Icon.Trash)),ui.metric(ctx,"row")-4,tip="Remove from the org").clicked {
                    kai_ask(s,"kai.org",`{{"org":"%s","remove":"%s"}}`,kai_org_text(id),kai_member_text(member.user))
                }
            }
            ui.id_pop(ctx)
        }
        for &n,k in o.nodes {
            ui.id_push(ctx,ui.id(ctx,"node",k))
            key:=n.key
            kai_row_names(ctx,fmt.bprintf(text[:],"node %02x%02x%02x",key[0],key[1],key[2]),ka.node_modes_text(n.modes),ui.tone(ctx,"text"))
            ui.id_pop(ctx)
        }
        for &p,k in o.projects {
            ui.id_push(ctx,ui.id(ctx,"project",k))
            open:=v.org==i && p.id==v.project
            pid:=p.id
            if kai_row_button(ctx,p.name!=""?p.name:"(its log is not here yet)",open?"open here":p.public?"public":"org",v.org<0?.Link:.None,"Work on it here") {
                kai_ask(s,"kai.org",`{{"org":"%s","link":"%s"}}`,kai_org_text(id),kai_org_text(pid))
            }
            for &policy,j in p.policies {
                ui.id_push(ctx,ui.id(ctx,"policy",j))
                kai_line(ctx,fmt.bprintf(text[:],"%s: %s",policy.bookmark,policy.text))
                ui.id_pop(ctx)
            }
            ui.id_pop(ctx)
        }
        if v.org==i && admin {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6}) {
                kai_field(ctx,"kai_policy_bookmark",f.bookmark[:],&f.bookmark_length,"main")
                kai_field(ctx,"kai_policy_approvals",f.approvals[:],&f.approvals_length,"Approvals")
            }
            kai_field(ctx,"kai_policy_checks",f.checks[:],&f.checks_length,"Checks, as unit,lint")
            if kai_buttons(s,"kai_policy",{"Set policy"})==0 {
                bookmark:=kai_typed(f.bookmark[:],f.bookmark_length)
                if bookmark=="" {bookmark="main"}
                approvals,_:=strconv.parse_int(kai_typed(f.approvals[:],f.approvals_length),10)
                checks:=make([dynamic]string,context.temp_allocator)
                for c in strings.split(kai_typed(f.checks[:],f.checks_length),",",context.temp_allocator) {
                    if c:=strings.trim_space(c);c!="" {append(&checks,kai_quote(c))}
                }
                kai_ask(s,"kai.bookmarks",`{{"policy":%s,"approvals":%d,"checks":[%s]}}`,kai_quote(bookmark),approvals,strings.join(checks[:],",",context.temp_allocator))
            }
        }
        if o.role!=.Owner && kai_buttons(s,"kai_leave",{"Leave the org"})==0 {kai_ask(s,"kai.org",`{{"org":"%s","leave":true}}`,kai_org_text(id))}
        ui.id_pop(ctx)
    }
}

// Offering a ticket, joining with one, and how a pairing joined goes.
@(private)
kai_pairing_build :: proc(s:^Session) {
    ctx:=s.gui.ctx
    t:=&s.kai.state.team
    v:=&t.view
    f:=&t.fields
    me:=&v.identity
    text:[160]u8
    kai_head(ctx,"PAIRING",0)
    if me.user!={} {
        labels:=[3]string{"Member","Second device","Node"}
        offers:=len(v.orgs)>0?3:1
        switch kai_buttons(s,"kai_offer",offers==3?labels[:]:labels[1:2]) {
        case 0: kai_ask(s,"kai.pair",offers==3?`{"offer":"member"}`:`{"offer":"device"}`)
        case 1: kai_ask(s,"kai.pair",`{"offer":"device"}`)
        case 2: kai_ask(s,"kai.pair",`{"offer":"node"}`)
        }
        if t.ticket_length>0 {
            ticket:=string(t.ticket[:t.ticket_length])
            if kai_row_button(ctx,"Ticket, ten minutes",ticket,.Copy,"Copy the ticket") && s.app!=nil && s.app.platform!=nil {
                platform.clipboard_set(s.app.platform,ticket)
            }
        }
    }
    kai_field(ctx,"kai_ticket",f.ticket[:],&f.ticket_length,"Ticket from another machine")
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6}) {
        // A device with no user joins with its host's name unless one is typed.
        if me.user=={} {kai_field(ctx,"kai_device_name",f.name[:],&f.name_length,"This device's name")} else {ui.spacer(ctx)}
        ticket,name:=kai_typed(f.ticket[:],f.ticket_length),kai_typed(f.name[:],f.name_length)
        if ui.button(ctx,ui.id(ctx,"kai_join"),{label="Join",variant="field",disabled=ticket=="" || t.joining}).clicked {
            if me.user=={} && name!="" {kai_ask(s,"kai.pair",`{{"join":%s,"name":%s}}`,kai_quote(ticket),kai_quote(name))} else {kai_ask(s,"kai.pair",`{{"join":%s}}`,kai_quote(ticket))}
            f.ticket_length=0
        }
    }
    switch t.progress {
    case .None:
    case .Asking: kai_line(ctx,"Reaching the other machine")
    case .Waiting: kai_line(ctx,fmt.bprintf(text[:],"Code %s: approve on the other machine if it shows the same",string(t.progress_code[:])),"text")
    case .Approved: kai_line(ctx,"Paired: the mesh syncs with the other machine now","success")
    case .Denied,.Failed: kai_line(ctx,string(t.progress_why[:t.progress_why_length]),"danger")
    }
}

// The scopes of the project: what each seals and who reads it; one added by
// its patterns.
@(private)
kai_scopes_build :: proc(s:^Session) {
    ctx:=s.gui.ctx
    t:=&s.kai.state.team
    v:=&t.view
    f:=&t.fields
    o:=&v.orgs[v.org]
    text:[160]u8
    count:=0
    for sc in o.scopes {count+=int(sc.project==v.project)}
    kai_head(ctx,"PRIVATE FILES",count)
    for &sc,i in o.scopes {
        if sc.project!=v.project {continue}
        ui.id_push(ctx,ui.id(ctx,"scope",i))
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=6,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0}}) {
            kai_row_names(ctx,v.patterns[i],fmt.bprintf(text[:],"%s, read by %s%s",sc.id,ka.role_text(sc.readers),sc.history?", keeps history":""),ui.tone(ctx,"text"))
            if ui.icon_button(ctx,ui.id(ctx,"rotate"),.Refresh,ui.metric(ctx,"row")-4,tip="Rotate its key").clicked {kai_ask(s,"kai.scopes",`{{"rotate":%s}}`,kai_quote(sc.id))}
            if ui.icon_button(ctx,ui.id(ctx,"remove"),ui.icon_user(u8(User_Icon.Trash)),ui.metric(ctx,"row")-4,tip="Remove: its paths are no longer sealed").clicked {kai_ask(s,"kai.scopes",`{{"remove":%s}}`,kai_quote(sc.id))}
        }
        ui.id_pop(ctx)
    }
    for &x,i in o.publics {
        if x.project!=v.project {continue}
        ui.id_push(ctx,ui.id(ctx,"public",i))
        kai_row_names(ctx,x.path,"kept public",ui.tone(ctx,"text"))
        ui.id_pop(ctx)
    }
    kai_field(ctx,"kai_patterns",f.patterns[:],&f.patterns_length,"Patterns, as secrets/** .env")
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0}}) {
        if ui.button(ctx,ui.id(ctx,"kai_readers"),{label=ka.role_text(f.readers),variant="ghost",size=ui.metric(ctx,"font_small")}).clicked {
            f.readers=f.readers==.Owner?.Reader:vcs.Role(u8(f.readers)+1)
        }
        ui.checkbox(ctx,ui.id(ctx,"kai_history"),&f.history)
        ui.label(ctx,"History",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint"))
    }
    typed:=kai_typed(f.patterns[:],f.patterns_length)
    if kai_buttons(s,"kai_scope_add",{"Add scope"},disabled=typed=="")==0 {
        patterns:=strings.fields(typed,context.temp_allocator)
        quoted:=make([]string,len(patterns),context.temp_allocator)
        for p,i in patterns {quoted[i]=kai_quote(p)}
        kai_ask(s,"kai.scopes",`{{"add":[%s],"readers":%s,"history":%v}}`,strings.join(quoted,",",context.temp_allocator),kai_quote(ka.role_text(f.readers)),f.history)
        f.patterns_length=0
    }
}

// The dialog of the tab: the recovery key shown once, which only its button
// dismisses; rotating the key; a pairing request, whose two answers are
// alike and neither is the default.
kai_dialog_build :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    if s.kai==nil || s.kai.state==nil {
        g.modal=.None
        return
    }
    t:=&s.kai.state.team
    f:=&t.fields
    switch t.dialog {
    case .None: g.modal=.None
    case .Recovery:
        if ui.modal(ctx,shell_id(g,"kai_recovery"),{width=420}) {
            ui.label(ctx,"Recovery key, shown once",ui.metric(ctx,"font_title"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
            key:=string(t.recovery[:t.recovery_length])
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,padding={8,6,8,6},fill=ui.tone(ctx,"field"),radius=4}) {
                ui.text(ctx,key,ui.prose(ctx,ui.metric(ctx,"font"),ui.tone(ctx,"text")))
            }
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(28),gap=8,align_x=.End,align_y=.Center}) {
                if ui.button(ctx,shell_id(g,"kai_recovery_copy"),{label="Copy",variant="field",width=92,height=28,center=true}).clicked && s.app!=nil && s.app.platform!=nil {
                    platform.clipboard_set(s.app.platform,key)
                }
                if ui.button(ctx,shell_id(g,"kai_recovery_done"),{label="I wrote it down",variant="field",width=128,height=28,center=true}).clicked {kai_dialog_close(s)}
            }
        }
    case .Rotate:
        closed:=false
        if ui.modal(ctx,shell_id(g,"kai_rotate"),{width=420,close=&closed}) {
            ui.label(ctx,"Rotate the recovery key",ui.metric(ctx,"font_title"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
            ui.text_field(ctx,shell_id(g,"kai_rotate_key"),f.recovery[:],&f.recovery_length,{placeholder="The recovery key now, as it was shown",live=true,password=true})
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(28),gap=8,align_x=.End,align_y=.Center}) {
                if ui.button(ctx,shell_id(g,"kai_rotate_go"),{label="Rotate",variant="accent",width=92,height=28,center=true,disabled=f.recovery_length==0}).clicked {
                    kai_ask(s,"kai.identity",`{{"recovery":%s}}`,kai_quote(string(f.recovery[:f.recovery_length])))
                    crypto.zero_explicit(&f.recovery,size_of(f.recovery))
                    f.recovery_length=0
                }
                if ui.button(ctx,shell_id(g,"kai_rotate_cancel"),{label="Cancel",variant="field",width=92,height=28,center=true}).clicked {closed=true}
            }
        }
        if closed {kai_dialog_close(s)}
    case .Recover:
        closed:=false
        if ui.modal(ctx,shell_id(g,"kai_recover"),{width=420,close=&closed}) {
            ui.label(ctx,"Recover a user onto this device",ui.metric(ctx,"font_title"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
            ui.text_field(ctx,shell_id(g,"kai_recover_user"),f.recover_user[:],&f.recover_user_length,{placeholder="The user's id, or its first eight hex digits",live=true})
            ui.text_field(ctx,shell_id(g,"kai_recover_key"),f.recovery[:],&f.recovery_length,{placeholder="The recovery key, as it was shown",live=true,password=true})
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(28),gap=8,align_x=.End,align_y=.Center}) {
                if ui.button(ctx,shell_id(g,"kai_recover_go"),{label="Recover",variant="accent",width=92,height=28,center=true,disabled=f.recovery_length==0 || f.recover_user_length==0}).clicked {
                    kai_ask(s,"kai.identity",`{{"recover":%s,"recovery":%s}}`,kai_quote(string(f.recover_user[:f.recover_user_length])),kai_quote(string(f.recovery[:f.recovery_length])))
                    crypto.zero_explicit(&f.recovery,size_of(f.recovery))
                    f.recovery_length=0
                    f.recover_user_length=0
                    closed=true
                }
                if ui.button(ctx,shell_id(g,"kai_recover_cancel"),{label="Cancel",variant="field",width=92,height=28,center=true}).clicked {closed=true}
            }
        }
        if closed {kai_dialog_close(s)}
    case .Pair:
        if ui.modal(ctx,shell_id(g,"kai_pair"),{width=380}) {
            r:=&t.request
            modes:=[vcs.Pair_Mode]string{.Device="as a second device of this user",.Member="to join the org",.Node="as a node of the org",.Recover="to reach the org and fetch the user it recovers"}
            ui.label(ctx,"Pairing request",ui.metric(ctx,"font_title"),ui.tone(ctx,"text"),font=ui.FONT_SEMIBOLD)
            text:[320]u8
            ui.text(ctx,fmt.bprintf(text[:],"%s asks %s. Approve only if the other machine shows the same code.",string(r.who[:r.who_length]),modes[r.mode]),ui.prose(ctx,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_faint")))
            ui.label(ctx,string(r.code[:]),ui.metric(ctx,"font_title"),ui.tone(ctx,"text"),center=true,font=ui.FONT_SEMIBOLD)
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(28),gap=8,align_y=.Center}) {
                if ui.button(ctx,shell_id(g,"kai_pair_deny"),{label="Deny",variant="field",width=-1,height=28,center=true}).clicked {kai_ask(s,"kai.pair",`{"answer":"deny"}`)}
                if ui.button(ctx,shell_id(g,"kai_pair_approve"),{label="Approve",variant="field",width=-1,height=28,center=true}).clicked {
                    kai_ask(s,"kai.pair",`{{"answer":"approve","code":%s}}`,kai_quote(string(r.code[:])))
                }
            }
        }
    }
}

// Escape closes the rotation and the recovery; the recovery key and a pairing request wait
// for their buttons.
kai_dialog_escape :: proc(s:^Session) {
    if s.kai==nil || s.kai.state==nil {
        s.gui.modal=.None
        return
    }
    if d:=s.kai.state.team.dialog;d==.Rotate || d==.Recover {kai_dialog_close(s)}
}

// An org or a project by the first hex digits of its id, as kai.org takes it.
@(private)
kai_org_text :: proc(id:vcs.Log_Id) -> string {
    x:=id
    return ka.hex(x[:6])
}

@(private)
kai_member_text :: proc(id:vcs.Log_Id) -> string {return kai_org_text(id)}
