package editor

import "core:crypto"
import "core:fmt"
import "core:strings"
import "core:time"
import ka "mirai:cook/kai"
import vcs "mirai:kai"
import "mirai:platform"
import "mirai:std/serial"
import "mirai:ui"

// The Team view of the Kai tab (which shows only this project's org), the
// launcher's Team view (which manages all orgs, joins and web sign-in), and
// the Publish to main of the Changes view. They draw what kai_team_read left
// in the team's arena; a button asks for its kai.* method, which runs between
// frames as any call does.

KAI_COPIED_SHOW :: 2500*time.Millisecond

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

// Buttons that grow side by side, of the field variant, or one under another
// when side by side the tab would cut a label; the index of the one clicked, -1.
@(private)
kai_buttons :: proc(s:^Session,name:string,labels:[]string,accent:=-1,disabled:=false,active:=-1) -> (clicked:int) {
    ctx:=s.gui.ctx
    clicked=-1
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6,direction=kai_side_by_side(s,labels)?.Row:.Column}) {
        for label,i in labels {
            // Side by side each keeps the room of its label, and they share what is left.
            l:=ui.Layout{width=ui.grow(min=ui.text_width(&ctx.font,label,ui.metric(ctx,"font"))+2*KAI_BUTTON_SIDE),height=ui.fixed(ui.metric(ctx,"control"))}
            variant:=i==accent?"accent":active>=0?"toggle":"field"
            if ui.button(ctx,ui.id(ctx,name,i),{label=label,variant=variant,active=i==active,width=-1,center=true,disabled=disabled,layout=&l}).clicked {clicked=i}
        }
    }
    return
}

// Whether buttons of labels fit their texts side by side in the tab.
@(private)
kai_side_by_side :: proc(s:^Session,labels:[]string) -> bool {
    ctx:=s.gui.ctx
    width:=s.kai.state!=nil?s.kai.state.width:s.kai.team!=nil?s.kai.team.width:0
    if width<=0 {return true}
    size:=ui.metric(ctx,"font")
    needed:=f32(6*(len(labels)-1))
    for label in labels {needed+=ui.text_width(&ctx.font,label,size)+2*KAI_BUTTON_SIDE}
    return needed<=width
}

// The room a button keeps on each side of its label.
KAI_BUTTON_SIDE :: 10

// A field of the team views.
@(private)
kai_field :: proc(ctx:^ui.Context,name:string,buffer:[]u8,length:^int,placeholder:string,width:ui.Size={},password:=false) {
    ui.text_field(ctx,ui.id(ctx,name),buffer,length,{placeholder=placeholder,live=true,width=width,password=password})
}

// The switch of the views of the tab.
@(private)
kai_tabs_build :: proc(s:^Session) {
    ctx:=s.gui.ctx
    st:=s.kai.state
    labels:=[Kai_Tab]string{.Changes="Changes",.Team="Team"}
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
        for tab in Kai_Tab {
            if ui.button(ctx,ui.id(ctx,"kai_tab",int(tab)),{label=labels[tab],variant=st.tab==tab?"field":"ghost",width=-1,center=true,height=ui.metric(ctx,"control")-6,size=ui.metric(ctx,"font_small")}).clicked {
                st.tab=tab
                if tab==.Team {kai_team_open(s)}
            }
        }
    }
}

// Publish to main: the working change closes whole and main moves to it for
// the org. A project in no org yet goes into one in the same call (Public or
// Org only), so it is never in an org without having been published.
@(private)
kai_publish_build :: proc(s:^Session) {
    ctx:=s.gui.ctx
    t:=s.kai.team
    if t==nil {
        if ui.button(ctx,ui.id(ctx,"kai_share_open"),{label="Share with a team",variant="ghost",width=-1,center=true}).clicked {kai_team_open(s)}
        return
    }
    st:=s.kai.state
    v:=&t.view
    description:=kai_typed(st.description[:],st.description_length)
    if v.org>=0 {
        main_target:vcs.Revision
        for b in v.shared {
            if b.name==ka.BOOKMARK_DEFAULT {main_target=b.target;break}
        }
        up_to_date:=len(st.view.files)==0 && description=="" && st.view.description=="" && st.view.parent_revision!={} && main_target==st.view.parent_revision
        kai_line(ctx,v.publish,"text_faint")
        if kai_buttons(s,"kai_publish",{up_to_date?"Up to date":"Publish to main"},accent=up_to_date?-1:0,disabled=up_to_date)==0 {
            kai_ask(s,"kai.publish",`{{"description":%s}}`,kai_quote(description))
        }
        return
    }
    if len(v.orgs)==0 {
        kai_line(ctx,"Create or join an org in Projects -> Team to publish this project to your other machines and your team.")
        return
    }
    f:=&t.fields
    t.publish_org=clamp(t.publish_org,0,len(v.orgs)-1)
    target:=&v.orgs[t.publish_org]
    if len(v.orgs)>1 {
        kai_line(ctx,"Publish this project to:","text_faint")
        names:=make([]string,len(v.orgs),context.temp_allocator)
        for o,i in v.orgs {names[i]=o.name}
        if pick:=kai_buttons(s,"kai_publish_org",names,active=t.publish_org);pick>=0 {t.publish_org=pick}
    } else {
        kai_line(ctx,v.publish,"text_faint")
    }
    if pick:=kai_buttons(s,"kai_visibility",{"Org only","Public"},active=f.public?1:0);pick>=0 {f.public=pick==1}
    if kai_buttons(s,"kai_publish",{"Publish to main"},accent=0)==0 {
        kai_ask(s,"kai.publish",`{{"description":%s,"org":%s,"visibility":%s}}`,kai_quote(description),kai_quote(org_hex(target.id)),kai_quote(f.public?"public":"org"))
    }
}

// The shared bookmarks in BOOKMARKS: a click starts a change on one.
@(private)
kai_shared_build :: proc(s:^Session) {
    ctx:=s.gui.ctx
    t:=s.kai.team
    if t==nil || t.view.org<0 {return}
    for &b,i in t.view.shared {
        ui.id_push(ctx,ui.id(ctx,"shared",i))
        row:=ui.id(ctx,"row")
        it:=ui.interact(ctx,row,{.Focusable})
        on:=ai_pointer_on(ctx,row)
        if ui.box(ctx,{id=row,width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=6,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0},fill=on?ui.tone(ctx,"chip"):{},radius=ui.metric(ctx,"radius_control")}) {
            ui.icon(ctx,ui.icon_user(u8(User_Icon.Users)),ui.tone(ctx,"text_faint"),12)
            kai_row_names(ctx,b.name,b.here?"shared":"on its way",ui.tone(ctx,"text"))
        }
        if it.clicked && b.here {kai_ask(s,"kai.new",`{{"parents":[%s]}}`,kai_quote(b.name))}
        ui.id_pop(ctx)
    }
}

// The Team view. In the launcher (launcher=true): this machine, joining an org,
// all orgs, creating a new org, and web sign-in. Inside a project's Kai tab
// (launcher=false): this machine and only this project's org.
kai_team_build :: proc(s:^Session,launcher:=false) {
    ctx:=s.gui.ctx
    t:=s.kai.team
    if t==nil || !t.opened {
        kai_line(ctx,"Kai keeps its machine in the store, which does not open: start Mirai with a store this user may write.","danger")
        return
    }
    v:=&t.view
    f:=&t.fields
    kai_head(ctx,"THIS MACHINE",-1)
    if t.team.name=="" {
        kai_field(ctx,"kai_name",f.name[:],&f.name_length,"Your name")
        kai_field(ctx,"kai_device",f.device[:],&f.device_length,"This machine's name, as Mac or Studio PC")
        name,device:=kai_typed(f.name[:],f.name_length),kai_typed(f.device[:],f.device_length)
        if kai_buttons(s,"kai_profile",{"Save"},accent=0,disabled=name=="" || device=="")==0 {
            kai_ask(s,"kai.profile",`{{"name":%s,"device":%s}}`,kai_quote(name),kai_quote(device))
        }
        return
    }
    status:=v.reach if t.running else "Offline" if t.why_length==0 else ""
    kai_row_names(ctx,v.machine,status,ui.tone(ctx,"text"))
    if !t.running && t.why_length>0 {kai_line(ctx,string(t.why[:t.why_length]),"danger")}
    for p in v.peer_lines {kai_row_names(ctx,p.name,p.rest,ui.tone(ctx,"text"))}

    if !launcher {
        if v.org>=0 && v.org<len(v.orgs) {
            kai_org_build(s,v.org,false)
        } else {
            kai_line(ctx,"This project is not in an org yet. Publish it in Changes, or create/join an org in Projects -> Team.")
        }
        return
    }

    kai_head(ctx,"JOIN AN ORG",-1)
    kai_field(ctx,"kai_invite_in",f.invite[:],&f.invite_length,"Paste an invite")
    invite:=kai_typed(f.invite[:],f.invite_length)
    joining:=&t.tasks[.Join]
    if kai_buttons(s,"kai_join",{"Join"},accent=0,disabled=invite=="" || joining.stage==.Waiting)==0 {kai_ask(s,"kai.join",`{{"invite":%s}}`,kai_quote(invite))}
    kai_task_line(ctx,joining,"Joining…")

    for _,i in v.orgs {kai_org_build(s,i,true)}

    kai_head(ctx,"NEW ORG",-1)
    kai_field(ctx,"kai_org_name",f.org[:],&f.org_length,"Org name")
    org:=kai_typed(f.org[:],f.org_length)
    if kai_buttons(s,"kai_org_new",{"Make org"},disabled=org=="")==0 {kai_ask(s,"kai.org",`{{"new":%s}}`,kai_quote(org))}

    if len(v.orgs)>0 {
        kai_head(ctx,"WEB SIGN-IN",-1)
        kai_field(ctx,"kai_server",f.server[:],&f.server_length,"Server host:port")
        kai_field(ctx,"kai_login",f.login[:],&f.login_length,"Sign-in name")
        kai_field(ctx,"kai_password",f.password[:],&f.password_length,"Password, 8 or more characters",password=true)
        server,login:=kai_typed(f.server[:],f.server_length),kai_typed(f.login[:],f.login_length)
        signing:=&t.tasks[.Web_Login]
        if kai_buttons(s,"kai_web",{"Set sign-in"},disabled=server=="" || login=="" || f.password_length<8 || signing.stage==.Waiting)==0 {
            // Straight to the agent's thread: the password goes into no call's text.
            if message:=kai_task_start(s,.Web_Login,server,login,string(f.password[:f.password_length]));message!="" {notify(s,message)}
            crypto.zero_explicit(&f.password,size_of(f.password))
            f.password_length=0
        }
        kai_task_line(ctx,signing,"Connecting…")
    }
}

// One org block: its members, server sync status / 1-click attach, optional
// repo list (in launcher), and INVITE controls for admins.
@(private)
kai_org_build :: proc(s:^Session,i:int,show_repos:bool) {
    ctx:=s.gui.ctx
    t:=s.kai.team
    v:=&t.view
    o:=&v.orgs[i]
    x:=&v.lines[i]
    ui.id_push(ctx,ui.id(ctx,"org",i))
    defer ui.id_pop(ctx)
    kai_head(ctx,x.title,len(o.members))
    kai_line(ctx,x.role,"text_faint")
    if x.server!="" {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=6,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0}}) {
            ui.icon(ctx,.Check,ui.tone(ctx,"success"),12)
            size:=ui.metric(ctx,"font_small")
            ui.text(ctx,x.server,{size=size,color=ui.tone(ctx,"text_muted"),align_y=.Center,ellipsis=true},ui.GROW,ui.fixed(size+6))
        }
    } else if o.role=="admin" && v.default_server!="" {
        attaching:=&t.tasks[.Attach]
        waiting:=attaching.stage==.Waiting && attaching.org==o.id
        if kai_buttons(s,"kai_sync_server",{"Sync to server"},disabled=attaching.stage==.Waiting)==0 {
            kai_ask(s,"kai.org",`{{"attach":%s}}`,kai_quote(org_hex(o.id)))
        }
        if waiting {
            kai_line(ctx,"Syncing to server…","text_faint")
        } else if attaching.stage==.Failed && !attaching.silent && attaching.org==o.id {
            kai_line(ctx,string(attaching.why[:attaching.why_length]),"danger")
        }
    }
    for m in x.members {kai_row_names(ctx,m.name,m.rest,ui.tone(ctx,"text"))}
    if show_repos {
        for r in x.repos {kai_row_names(ctx,r.name,r.rest,ui.tone(ctx,"text_muted"))}
    }
    if o.role=="admin" {kai_invite_build(s,o)}
}

// An admin's invite: separated under INVITE so the role switcher is clearly
// the invite's role, with a compact clipboard icon button beside the read-only
// invite field that turns into a green check when copied.
@(private)
kai_invite_build :: proc(s:^Session,o:^ka.Org_View) {
    ctx:=s.gui.ctx
    t:=s.kai.team
    f:=&t.fields
    ui.spacer(ctx,0,4)
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=ui.tone(ctx,"divider")}) {}
    ui.spacer(ctx,0,2)
    kai_head(ctx,"INVITE",-1)
    labels:=[]string{"Writer","Reader"}
    roles:=[]vcs.Role{.Writer,.Reader}
    active:=0
    for r,i in roles {if f.role==r {active=i}}
    if pick:=kai_buttons(s,"kai_invite_role",labels,active=active);pick>=0 {f.role=roles[pick]}
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=6,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0}}) {
        ui.checkbox(ctx,ui.id(ctx,"kai_invite_mine"),&f.mine)
        ui.label(ctx,"For another machine of mine",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
    }
    at:=""
    if !t.view.online && o.server=="" {
        kai_field(ctx,"kai_invite_at",f.at[:],&f.at_length,"Public address, host:port (optional)")
        at=kai_typed(f.at[:],f.at_length)
    }
    role:=roles[active]
    switch kai_buttons(s,"kai_invite",{"Make invite","Revoke invites"},accent=0) {
    case 0:
        t.invite_asked=true
        kai_ask(s,"kai.invite",`{{"org":%s,"role":%s,"mine":%v,"at":%s}}`,kai_quote(org_hex(o.id)),kai_quote(ka.role_text(role)),f.mine,kai_quote(at))
    case 1: kai_ask(s,"kai.invite",`{{"org":%s,"revoke":true}}`,kai_quote(org_hex(o.id)))
    }
    if t.invite_length==0 || t.invite_org!=o.id {return}
    // The invite is one word of some 200 letters: a read-only field cuts it at
    // the panel's edge, and selects and copies it whole.
    control:=ui.metric(ctx,"control")
    copied:=t.invite_copied && time.tick_since(t.invite_copied_at)<KAI_COPIED_SHOW
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6,align_y=.Center}) {
        ui.text_field(ctx,ui.id(ctx,"kai_invite_text"),t.invite[:],&t.invite_length,{read_only=true,height=control})
        if ui.icon_button(ctx,ui.id(ctx,"kai_invite_copy"),copied?.Check:ui.icon_user(u8(User_Icon.Paste)),control,"field",copied?"Copied":"Copy invite",copied?ui.tone(ctx,"success"):{}).clicked {
            kai_invite_copy(s)
        }
    }
    if t.invite_via_server {
        #assert(vcs.INVITE_HOURS==72)
        kai_line(ctx,"Valid for 3 days — works even while Mirai is closed.","text_faint")
    } else if t.invite_local {
        kai_line(ctx,"Local network only — add a public host:port above to invite over the internet.","danger")
    } else {
        #assert(vcs.INVITE_HOURS==72)
        kai_line(ctx,"Valid for 3 days while Mirai is open.","text_faint")
    }
}

// Puts the invite offered last on the clipboard: whether it went there.
kai_invite_copy :: proc(s:^Session) -> bool {
    t:=s.kai.team
    if t==nil || t.invite_length==0 || s.app==nil || s.app.platform==nil {return false}
    t.invite_copied=platform.clipboard_set(s.app.platform,string(t.invite[:t.invite_length]))
    if t.invite_copied {t.invite_copied_at=time.tick_now()}
    return t.invite_copied
}

// How a task goes: waiting while it runs, why when it failed.
@(private)
kai_task_line :: proc(ctx:^ui.Context,x:^Kai_Task,waiting:string) {
    #partial switch x.stage {
    case .Waiting: kai_line(ctx,waiting,"text_faint")
    case .Failed: kai_line(ctx,string(x.why[:x.why_length]),"danger")
    }
}

// An org's id as the kai.* methods take it.
@(private)
org_hex :: proc(id:vcs.Org_Id) -> string {
    buffer:=make([]u8,32,context.temp_allocator)
    hex:[32]u8
    copy(buffer,vcs.org_ref_name(id,&hex))
    return string(buffer)
}
