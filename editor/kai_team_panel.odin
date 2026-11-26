package editor

import "core:fmt"
import "core:strings"
import ka "mirai:cook/kai"
import vcs "mirai:kai"
import "mirai:platform"
import "mirai:std/serial"
import "mirai:ui"

// The Team view of the Kai tab, which the launcher's Team shows
// too, and the Publish to main of the Changes view. They draw what
// kai_team_read left in the team's arena; a button asks for its kai.* method,
// which runs between frames as any call does.

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
        kai_line(ctx,v.publish,"text_faint")
        if kai_buttons(s,"kai_publish",{"Publish to main"},accent=0)==0 {
            kai_ask(s,"kai.publish",`{{"description":%s}}`,kai_quote(description))
        }
        return
    }
    if len(v.orgs)==0 {
        kai_line(ctx,"Make an org or join one in Team to publish this project to your other machines and your team.")
        return
    }
    f:=&t.fields
    kai_line(ctx,v.publish,"text_faint")
    if pick:=kai_buttons(s,"kai_visibility",{"Org only","Public"},active=f.public?1:0);pick>=0 {f.public=pick==1}
    if kai_buttons(s,"kai_publish",{"Publish to main"},accent=0)==0 {
        kai_ask(s,"kai.publish",`{{"description":%s,"org":%s,"visibility":%s}}`,kai_quote(description),kai_quote(org_hex(v.orgs[0].id)),kai_quote(f.public?"public":"org"))
    }
}

// The shared bookmarks in BOOKMARKS: a click starts a change on one; the
// arrow moves it to the working copy's parent for the whole org.
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
            if ui.icon_button(ctx,ui.id(ctx,"move"),ui.icon_user(u8(User_Icon.Up)),ui.metric(ctx,"row")-4,tip="Move it to the working copy's parent for the whole org").clicked {
                kai_ask(s,"kai.bookmarks",`{{"move":%s,"change":"@-"}}`,kai_quote(b.name))
            }
        }
        if it.clicked && b.here {kai_ask(s,"kai.new",`{{"parents":[%s]}}`,kai_quote(b.name))}
        ui.id_pop(ctx)
    }
}

// The Team view: this machine, joining an org, each org with its members,
// repositories and invites, a new org and the web sign-in of a server.
kai_team_build :: proc(s:^Session) {
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
        kai_line(ctx,"Name yourself and this machine: every org you make or join shows them.")
        kai_field(ctx,"kai_name",f.name[:],&f.name_length,"Your name")
        kai_field(ctx,"kai_device",f.device[:],&f.device_length,"This machine, as Mac or Studio PC")
        name,device:=kai_typed(f.name[:],f.name_length),kai_typed(f.device[:],f.device_length)
        if kai_buttons(s,"kai_profile",{"Save"},accent=0,disabled=name=="" || device=="")==0 {
            kai_ask(s,"kai.profile",`{{"name":%s,"device":%s}}`,kai_quote(name),kai_quote(device))
        }
        return
    }
    kai_row_names(ctx,t.team.name,t.team.device,ui.tone(ctx,"text"))
    switch {
    case v.listening!="": kai_line(ctx,v.listening)
    case t.why_length>0: kai_line(ctx,string(t.why[:t.why_length]),"danger")
    case: kai_line(ctx,"The agent starts once this machine is in an org.")
    }
    for p in v.peer_lines {kai_row_names(ctx,p.name,p.rest,ui.tone(ctx,"text"))}

    kai_head(ctx,"JOIN AN ORG",-1)
    kai_field(ctx,"kai_invite_in",f.invite[:],&f.invite_length,"Paste an invite: kai2...")
    invite:=kai_typed(f.invite[:],f.invite_length)
    if kai_buttons(s,"kai_join",{"Join"},accent=0,disabled=invite=="")==0 {kai_ask(s,"kai.join",`{{"invite":%s}}`,kai_quote(invite))}

    for &o,i in v.orgs {
        ui.id_push(ctx,ui.id(ctx,"org",i))
        x:=&v.lines[i]
        kai_head(ctx,x.title,len(o.members))
        kai_line(ctx,x.role,"text_faint")
        for m in x.members {kai_row_names(ctx,m.name,m.rest,ui.tone(ctx,"text"))}
        for r in x.repos {kai_row_names(ctx,r.name,r.rest,ui.tone(ctx,"text_muted"))}
        if o.role=="admin" {kai_invite_build(s,&o)}
        ui.id_pop(ctx)
    }

    kai_head(ctx,"NEW ORG",-1)
    kai_field(ctx,"kai_org_name",f.org[:],&f.org_length,"Name of the org")
    org:=kai_typed(f.org[:],f.org_length)
    if kai_buttons(s,"kai_org_new",{"Make org"},disabled=org=="")==0 {kai_ask(s,"kai.org",`{{"new":%s}}`,kai_quote(org))}

    if len(v.orgs)>0 {
        kai_head(ctx,"WEB SIGN-IN",-1)
        kai_line(ctx,"A Kai server of your org shows its repositories on the web: set the name and password this machine signs in with there.")
        kai_field(ctx,"kai_server",f.server[:],&f.server_length,"Server host:port")
        kai_field(ctx,"kai_login",f.login[:],&f.login_length,"Name: a-z, 0-9, . _ -")
        kai_field(ctx,"kai_password",f.password[:],&f.password_length,"Password, 8 or more",password=true)
        server,login:=kai_typed(f.server[:],f.server_length),kai_typed(f.login[:],f.login_length)
        if kai_buttons(s,"kai_web",{"Set sign-in"},disabled=server=="" || login=="" || f.password_length<8)==0 {
            kai_ask(s,"kai.web_login",`{{"server":%s,"name":%s,"password":%s}}`,kai_quote(server),kai_quote(login),kai_quote(string(f.password[:f.password_length])))
            f.password_length=0
        }
    }
}

// An admin's invite: who it is for, where the other machine reaches this
// one, and the one-time invite it makes, to copy.
@(private)
kai_invite_build :: proc(s:^Session,o:^ka.Org_View) {
    ctx:=s.gui.ctx
    t:=s.kai.team
    f:=&t.fields
    labels:=[]string{"Writer","Reader","Server"}
    roles:=[]vcs.Role{.Writer,.Reader,.Node}
    active:=0
    for r,i in roles {if f.role==r {active=i}}
    if pick:=kai_buttons(s,"kai_invite_role",labels,active=active);pick>=0 {f.role=roles[pick]}
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=6,align_y=.Center,padding={KAI_ROW_PAD,0,KAI_ROW_PAD,0}}) {
        ui.checkbox(ctx,ui.id(ctx,"kai_invite_mine"),&f.mine)
        ui.label(ctx,"For another machine of mine",ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
    }
    kai_line(ctx,"On another network, the other machine reaches this one where the router forwards its port:","text_faint")
    kai_field(ctx,"kai_invite_at",f.at[:],&f.at_length,"External host:port (optional)")
    if kai_buttons(s,"kai_invite",{"Make invite"},accent=0)==0 {
        kai_ask(s,"kai.invite",`{{"org":%s,"role":%s,"mine":%v,"at":%s}}`,kai_quote(org_hex(o.id)),kai_quote(ka.role_text(f.role)),f.mine,kai_quote(kai_typed(f.at[:],f.at_length)))
    }
    if t.invite_length==0 {return}
    text:=string(t.invite[:t.invite_length])
    kai_line(ctx,"One machine joins with this invite, within 3 days, while this editor runs:","text_faint")
    // One word of some 200 letters: on one line, cut at the panel's edge, so it never widens the tab.
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,padding={KAI_ROW_PAD,2,KAI_ROW_PAD,2}}) {
        size:=ui.metric(ctx,"font_small")
        ui.text(ctx,text,{size=size,color=ui.tone(ctx,"text"),align_y=.Center,ellipsis=true},ui.GROW,ui.fixed(size+6))
    }
    if kai_buttons(s,"kai_invite_copy",{"Copy invite"})==0 && s.app!=nil && s.app.platform!=nil {platform.clipboard_set(s.app.platform,text)}
}

// An org's id as the kai.* methods take it.
@(private)
org_hex :: proc(id:vcs.Org_Id) -> string {
    buffer:=make([]u8,32,context.temp_allocator)
    hex:[32]u8
    copy(buffer,vcs.org_ref_name(id,&hex))
    return string(buffer)
}
