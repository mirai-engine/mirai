package hub

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "mirai:kai"
import "mirai:store"

// The pages of the web view, made on the server as HTML with no script:
//   /                       the orgs the account is in, and every public repository
//   /login, /logout         sign in with a name and password a member set from its device
//   /<org>                  an org's repositories and, for its members, who is in it
//   /<org>/<repo>           a repository's shared bookmarks and the history of main
//   /<org>/<repo>/c/<rev>   a change: what it says and the files it changed
//   /<org>/<repo>/t/<rev>/<path>  the files of a change: a folder or a text file
// A repository shows to anyone when public, else only to the org's members.

LOG_MAX :: 200        // changes the history of a bookmark shows
FILE_SHOWN_MAX :: 1<<20 // bytes of a file a page shows

@(private)
page :: proc(h:^Hub,r:^Request,out:^Out) {
    session,token,signed:=session_of(h,r)
    path:=r.path
    switch {
    case path=="/style.css":
        out.type="text/css; charset=utf-8"
        append(&out.body,..transmute([]u8)string(STYLE))
        return
    case path=="/healthz":
        out.type="text/plain; charset=utf-8"
        append(&out.body,"ok")
        return
    case path=="/login" && r.method==.POST:
        name,password:=form_value(r.body,"name"),form_value(r.body,"password")
        t,ok:=session_open(h,name,password)
        if !ok {
            login_page(h,out,"that name and password do not sign in: set them from a member's machine (mirai kai web-login)")
            out.status=401
            return
        }
        hex:[64]u8
        header_add(out,fmt.tprintf("Set-Cookie: kai=%s; Path=/; HttpOnly; SameSite=Strict%s\r\n",hex_text(t[:],hex[:]),secure(r)))
        redirect(out,"/")
        return
    case path=="/login":
        login_page(h,out,"")
        return
    case path=="/logout" && r.method==.POST:
        if signed {session_close(h,token)}
        header_add(out,fmt.tprintf("Set-Cookie: kai=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0%s\r\n",secure(r)))
        redirect(out,"/")
        return
    }
    if r.method==.POST {
        out.status=405
        return
    }
    who:^Session=signed?&session:nil
    parts:=strings.split(strings.trim(path,"/"),"/",context.temp_allocator)
    if path=="/" {
        home_page(h,who,out)
        return
    }
    org:kai.Org_Id
    if !id_parse(parts[0],org[:]) {
        out.status=404
        return
    }
    v,ok:=org_access(h,org,who)
    if !ok {
        out.status=404
        return
    }
    if len(parts)==1 {
        org_page(h,&v,who,out)
        return
    }
    repo:kai.Repo_Id
    i:=-1
    if id_parse(parts[1],repo[:]) {i=kai.org_repo(&v.org,repo)}
    if i<0 || !(v.org.repos[i].public || v.member) {
        out.status=404
        return
    }
    switch {
    case len(parts)==2: repo_page(h,&v,i,who,out)
    case len(parts)>=4 && parts[2]=="c": change_page(h,&v,i,parts[3],who,out)
    case len(parts)>=4 && parts[2]=="t": tree_page(h,&v,i,parts[3],strings.join(parts[4:],"/",context.temp_allocator),who,out)
    case: out.status=404
    }
}

// What an org shows to who.
@(private)
Org_Access :: struct {
    org:kai.Org,
    s:^store.Store,
    member:bool,
}

@(private)
org_access :: proc(h:^Hub,id:kai.Org_Id,who:^Session) -> (v:Org_Access,ok:bool) {
    s,e:=kai.team_store(&h.team,id)
    if e!=.None {return}
    o,_,oe:=kai.org_head(s,id,context.temp_allocator)
    if oe!=.None {return}
    v={org=o,s=s}
    if who!=nil {_,v.member=kai.org_role(&o,who.key)}
    public:=false
    for r in o.repos {public||=r.public}
    return v,v.member || public
}

@(private)
home_page :: proc(h:^Hub,who:^Session,out:^Out) {
    b:=page_begin(out,"Kai",who)
    mine,public:=0,0
    for id in kai.team_org_ids(&h.team) {
        v,ok:=org_access(h,id,who)
        if !ok {continue}
        if v.member {
            if mine==0 {strings.write_string(b,"<h2>Your orgs</h2><ul class=\"list\">")}
            mine+=1
            fmt.sbprintf(b,"<li><a href=\"/%s\">%s</a> <span class=\"muted\">%d repositories, %d members</span></li>",id_text(id),html(v.org.name),len(v.org.repos),len(v.org.members))
            continue
        }
        for r in v.org.repos {
            if !r.public {continue}
            if public==0 {strings.write_string(b,"<h2>Public repositories</h2><ul class=\"list\">")}
            public+=1
            fmt.sbprintf(b,"<li><a href=\"/%s/%s\">%s</a> <span class=\"muted\">of %s</span></li>",id_text(id),id_text(r.id),html(r.name),html(v.org.name))
        }
    }
    if mine>0 || public>0 {strings.write_string(b,"</ul>")}
    if mine==0 && public==0 {strings.write_string(b,"<p class=\"muted\">Nothing to show yet. A member joins this server to an org with <code>mirai kai serve --join &lt;invite&gt;</code>, and sets a web sign-in from its machine.</p>")}
    page_end(b,out)
}

@(private)
org_page :: proc(h:^Hub,v:^Org_Access,who:^Session,out:^Out) {
    b:=page_begin(out,v.org.name,who)
    fmt.sbprintf(b,"<h1>%s</h1><h2>Repositories</h2><ul class=\"list\">",html(v.org.name))
    org:=v.org.id
    for r in v.org.repos {
        if !r.public && !v.member {continue}
        fmt.sbprintf(b,"<li><a href=\"/%s/%s\">%s</a>%s</li>",id_text(org),id_text(r.id),html(r.name),r.public?" <span class=\"tag\">public</span>":"")
    }
    strings.write_string(b,"</ul>")
    if v.member {
        strings.write_string(b,"<h2>Members</h2><table><tr><th>Person</th><th>Machine</th><th>Role</th></tr>")
        for m in v.org.members {
            key:=m.key
            fmt.sbprintf(b,"<tr><td>%s</td><td>%s <span class=\"muted\">%s</span></td><td>%s</td></tr>",html(m.name),html(m.device),bytes_hex(key[:4]),role_text(m.role))
        }
        strings.write_string(b,"</table>")
    }
    page_end(b,out)
}

@(private)
repo_page :: proc(h:^Hub,v:^Org_Access,i:int,who:^Session,out:^Out) {
    r:=v.org.repos[i]
    b:=page_begin(out,r.name,who)
    org:=v.org.id
    base:=fmt.tprintf("/%s/%s",id_text(org),id_text(r.id))
    fmt.sbprintf(b,"<p class=\"crumbs\"><a href=\"/%s\">%s</a> /</p><h1>%s</h1>",id_text(org),html(v.org.name),html(r.name))
    refs,_,e:=kai.repo_refs_head(v.s,org,r.id,context.temp_allocator)
    if e!=.None || len(refs.bookmarks)==0 {
        strings.write_string(b,"<p class=\"muted\">Nobody published this repository yet: Publish to main from the editor's Kai tab.</p>")
        page_end(b,out)
        return
    }
    strings.write_string(b,"<h2>Bookmarks</h2><table><tr><th>Bookmark</th><th>Change</th><th></th></tr>")
    shown:=0
    for x,k in refs.bookmarks {
        if x.name=="main" {shown=k}
        target:=x.target
        fmt.sbprintf(b,"<tr><td>%s</td><td><a href=\"%s/c/%s\">%s</a></td><td><a href=\"%s/t/%s\">files</a></td></tr>",html(x.name),base,id_text(target),change_text(v.s,target),base,id_text(target))
    }
    strings.write_string(b,"</table>")
    fmt.sbprintf(b,"<h2>History of %s</h2><table>",html(refs.bookmarks[shown].name))
    at:=refs.bookmarks[shown].target
    for _ in 0..<LOG_MAX {
        c,ce:=kai.change_get(v.s,at,context.temp_allocator)
        if ce!=.None {break}
        fmt.sbprintf(b,"<tr><td><a href=\"%s/c/%s\">%s</a></td><td>%s</td><td class=\"muted\">%s</td><td class=\"muted\">%s</td></tr>",
            base,id_text(at),change_text(v.s,at),html(first_line(c.description)),author(v,c.author),when_text(c.written))
        if len(c.parents)==0 {break}
        at=c.parents[0]
    }
    strings.write_string(b,"</table>")
    page_end(b,out)
}

@(private)
change_page :: proc(h:^Hub,v:^Org_Access,i:int,text:string,who:^Session,out:^Out) {
    r:=v.org.repos[i]
    revision:kai.Revision
    if !id_parse(text,revision[:]) || !reaches(v,r.id,revision) {
        out.status=404
        return
    }
    c,e:=kai.change_get(v.s,revision,context.temp_allocator)
    if e!=.None {
        out.status=404
        return
    }
    org:=v.org.id
    base:=fmt.tprintf("/%s/%s",id_text(org),id_text(r.id))
    b:=page_begin(out,r.name,who)
    fmt.sbprintf(b,"<p class=\"crumbs\"><a href=\"/%s\">%s</a> / <a href=\"%s\">%s</a> /</p>",id_text(org),html(v.org.name),base,html(r.name))
    fmt.sbprintf(b,"<h1>%s</h1><p class=\"muted\">%s, %s · <a href=\"%s/t/%s\">files</a></p>",change_text(v.s,revision),author(v,c.author),when_text(c.written),base,text)
    if c.description!="" {fmt.sbprintf(b,"<pre class=\"text\">%s</pre>",html(c.description))}
    before:store.Hash
    if len(c.parents)>0 {
        if p,pe:=kai.change_get(v.s,c.parents[0],context.temp_allocator);pe==.None {before=p.tree}
        strings.write_string(b,"<p>Parents: ")
        for p,k in c.parents {
            p:=p
            fmt.sbprintf(b,"%s<a href=\"%s/c/%s\">%s</a>",k>0?", ":"",base,id_text(p),change_text(v.s,p))
        }
        strings.write_string(b,"</p>")
    }
    diffs:=make([dynamic]kai.Diff,context.temp_allocator)
    kai.tree_diff(v.s,before,c.tree,&diffs,context.temp_allocator)
    fmt.sbprintf(b,"<h2>%d files changed</h2><table>",len(diffs))
    for d in diffs {
        fmt.sbprintf(b,"<tr><td class=\"mark\">%c</td><td><a href=\"%s/t/%s/%s\">%s</a></td></tr>",rune(kai.diff_mark(d)),base,text,path_href(d.path),html(d.path))
    }
    strings.write_string(b,"</table>")
    page_end(b,out)
}

@(private)
tree_page :: proc(h:^Hub,v:^Org_Access,i:int,text,path:string,who:^Session,out:^Out) {
    r:=v.org.repos[i]
    revision:kai.Revision
    if !id_parse(text,revision[:]) || !reaches(v,r.id,revision) || !(path=="" || kai.path_valid(path)) {
        out.status=404
        return
    }
    c,e:=kai.change_get(v.s,revision,context.temp_allocator)
    if e!=.None {
        out.status=404
        return
    }
    // Down the folders of path to what it names.
    at:=c.tree
    kind:=kai.Entry_Kind.Folder
    size:u64
    if path!="" {
        for name in strings.split(path,"/",context.temp_allocator) {
            if kind!=.Folder {
                out.status=404
                return
            }
            entries:=make([dynamic]kai.Tree_Entry,context.temp_allocator)
            if _,fe:=kai.folder_get(v.s,at,&entries,nil,context.temp_allocator);fe!=.None {
                out.status=404
                return
            }
            found:=false
            for x in entries {
                if x.name!=name {continue}
                at,kind,size,found=x.address,x.kind,x.size,true
            }
            if !found {
                out.status=404
                return
            }
        }
    }
    org:=v.org.id
    base:=fmt.tprintf("/%s/%s",id_text(org),id_text(r.id))
    b:=page_begin(out,r.name,who)
    fmt.sbprintf(b,"<p class=\"crumbs\"><a href=\"/%s\">%s</a> / <a href=\"%s\">%s</a> / <a href=\"%s/t/%s\">%s</a>",id_text(org),html(v.org.name),base,html(r.name),base,text,change_text(v.s,revision))
    walked:=""
    for name in strings.split(path,"/",context.temp_allocator) {
        if name=="" {continue}
        walked=walked==""?name:strings.concatenate({walked,"/",name},context.temp_allocator)
        fmt.sbprintf(b," / <a href=\"%s/t/%s/%s\">%s</a>",base,text,path_href(walked),html(name))
    }
    strings.write_string(b,"</p>")
    switch kind {
    case .Folder:
        entries:=make([dynamic]kai.Tree_Entry,context.temp_allocator)
        kai.folder_get(v.s,at,&entries,nil,context.temp_allocator)
        strings.write_string(b,"<table>")
        for x in entries {
            full:=path==""?x.name:strings.concatenate({path,"/",x.name},context.temp_allocator)
            fmt.sbprintf(b,"<tr><td><a href=\"%s/t/%s/%s\">%s%s</a></td><td class=\"muted\">%s</td></tr>",base,text,path_href(full),html(x.name),x.kind==.Folder?"/":"",x.kind==.Folder?fmt.tprintf("%d files",x.files):bytes_text(x.size))
        }
        strings.write_string(b,"</table>")
    case .File,.Executable:
        if size>FILE_SHOWN_MAX {
            fmt.sbprintf(b,"<p class=\"muted\">%s: too large to show here.</p>",bytes_text(size))
            break
        }
        bytes,fe:=kai.file_bytes(v.s,at,context.temp_allocator)
        if fe!=.None {
            strings.write_string(b,"<p class=\"muted\">This server does not hold the file yet.</p>")
        } else if !utf8.valid_string(string(bytes)) || strings.index_byte(string(bytes),0)>=0 {
            fmt.sbprintf(b,"<p class=\"muted\">A binary file of %s: an asset opens in the editor.</p>",bytes_text(size))
        } else {
            fmt.sbprintf(b,"<pre class=\"text\">%s</pre>",html(string(bytes)))
        }
    case .Conflict:
        strings.write_string(b,"<p class=\"muted\">This file is in conflict in this change: resolve it in the editor.</p>")
    }
    page_end(b,out)
}

// Whether a shared bookmark of the repository reaches revision: a page shows
// only a repository's own history, never an address of another.
@(private)
reaches :: proc(v:^Org_Access,repo:kai.Repo_Id,revision:kai.Revision) -> bool {
    refs,_,e:=kai.repo_refs_head(v.s,v.org.id,repo,context.temp_allocator)
    if e!=.None {return false}
    seen:=make(map[kai.Revision]bool,context.temp_allocator)
    stack:=make([dynamic]kai.Revision,context.temp_allocator)
    for b in refs.bookmarks {append(&stack,b.target)}
    for len(stack)>0 && len(seen)<1<<16 {
        x:=pop(&stack)
        if x==revision {return true}
        if seen[x] {continue}
        seen[x]=true
        c,ce:=kai.change_get(v.s,x,context.temp_allocator)
        if ce!=.None {continue}
        append(&stack,..c.parents)
    }
    return false
}

@(private)
login_page :: proc(h:^Hub,out:^Out,why:string) {
    b:=page_begin(out,"Sign in",nil)
    strings.write_string(b,"<h1>Sign in</h1>")
    if why!="" {fmt.sbprintf(b,"<p class=\"error\">%s</p>",html(why))}
    strings.write_string(b,`<form method="post" action="/login" class="form"><label>Name <input name="name" autocomplete="username" required></label><label>Password <input name="password" type="password" autocomplete="current-password" required></label><button>Sign in</button></form>`)
    strings.write_string(b,`<p class="muted">A member sets a name and password from its machine: <code>mirai kai web-login &lt;server host:port&gt; &lt;name&gt;</code>. It sees what that machine's role in each org lets it see.</p>`)
    page_end(b,out)
}

@(private)
page_begin :: proc(out:^Out,title:string,who:^Session) -> ^strings.Builder {
    out.type="text/html; charset=utf-8"
    b:=new(strings.Builder,context.temp_allocator)
    b^=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(b,`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>%s</title><link rel="stylesheet" href="/style.css"></head><body><header><a class="brand" href="/">Kai</a>`,html(title))
    if who!=nil {
        fmt.sbprintf(b,`<form method="post" action="/logout"><span>%s</span><button class="link">Sign out</button></form>`,html(string(who.name[:who.name_len])))
    } else {
        strings.write_string(b,`<a href="/login">Sign in</a>`)
    }
    strings.write_string(b,"</header><main>")
    return b
}

@(private)
page_end :: proc(b:^strings.Builder,out:^Out) {
    strings.write_string(b,"</main></body></html>")
    append(&out.body,..b.buf[:])
}

@(private)
redirect :: proc(out:^Out,to:string) {
    out.status=303
    header_add(out,fmt.tprintf("Location: %s\r\n",to))
}

@(private)
header_add :: proc(out:^Out,line:string) {
    append(&out.headers,..transmute([]u8)line)
}

// The cookie flag behind a proxy that says it took the request over TLS.
@(private)
secure :: proc(r:^Request) -> string {
    if proto,found:=request_header(r,"x-forwarded-proto");found && proto=="https" {return "; Secure"}
    return ""
}

@(private)
author :: proc(v:^Org_Access,key:kai.Key) -> string {
    if i:=kai.org_member(&v.org,key);i>=0 {return html(fmt.tprintf("%s (%s)",v.org.members[i].name,v.org.members[i].device))}
    k:=key
    return bytes_hex(k[:4])
}

@(private)
change_text :: proc(s:^store.Store,revision:kai.Revision) -> string {
    c,e:=kai.change_get(s,revision,context.temp_allocator)
    if e!=.None {
        r:=revision
        return bytes_hex(r[:6])
    }
    return bytes_hex(c.id[:6])
}

@(private)
first_line :: proc(text:string) -> string {
    if text=="" {return "(no description)"}
    if n:=strings.index_byte(text,'\n');n>=0 {return text[:n]}
    return text
}

@(private)
when_text :: proc(ns:i64) -> string {
    t:=time.Time{_nsec=ns}
    y,m,d:=time.date(t)
    hh,mm,_:=time.clock(t)
    return fmt.tprintf("%04d-%02d-%02d %02d:%02d UTC",y,int(m),d,hh,mm)
}

@(private)
bytes_text :: proc(n:u64) -> string {
    switch {
    case n>=1<<20: return fmt.tprintf("%.1f MB",f64(n)/f64(1<<20))
    case n>=1<<10: return fmt.tprintf("%.1f KB",f64(n)/f64(1<<10))
    }
    return fmt.tprintf("%d bytes",n)
}

@(private)
role_text :: proc(role:kai.Role) -> string {
    switch role {
    case .Reader: return "reader"
    case .Node: return "server"
    case .Writer: return "writer"
    case .Admin: return "admin"
    }
    return ""
}

// text with &, <, >, " and ' as entities, in the temp allocator.
@(private)
html :: proc(text:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for c in transmute([]u8)text {
        switch c {
        case '&': strings.write_string(&b,"&amp;")
        case '<': strings.write_string(&b,"&lt;")
        case '>': strings.write_string(&b,"&gt;")
        case '"': strings.write_string(&b,"&quot;")
        case '\'': strings.write_string(&b,"&#39;")
        case: strings.write_byte(&b,c)
        }
    }
    return strings.to_string(b)
}

// A repository path in a link: each byte outside [A-Za-z0-9._~/-] escaped.
@(private)
path_href :: proc(path:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for c in transmute([]u8)path {
        switch c {
        case 'a'..='z','A'..='Z','0'..='9','.','_','~','/','-': strings.write_byte(&b,c)
        case: fmt.sbprintf(&b,"%%%02X",c)
        }
    }
    return strings.to_string(b)
}

// The hex of an id, a key or a hash, in the temp allocator.
@(private)
id_text :: proc(x:$T) -> string {
    v:=x
    return bytes_hex(mem.ptr_to_bytes(&v))
}

@(private)
bytes_hex :: proc(bytes:[]u8) -> string {
    buffer:=make([]u8,2*len(bytes),context.temp_allocator)
    return hex_text(bytes,buffer)
}

@(private)
hex_text :: proc(bytes:[]u8,buffer:[]u8) -> string {
    DIGITS :: [16]u8{'0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f'}
    digits:=DIGITS
    for x,k in bytes {
        buffer[2*k]=digits[x>>4]
        buffer[2*k+1]=digits[x&15]
    }
    return string(buffer[:2*len(bytes)])
}

@(private)
id_parse :: proc(text:string,out:[]u8) -> bool {return hex_parse(text,out)}

// The value of name in an application/x-www-form-urlencoded body, decoded,
// in the temp allocator; "" when absent or malformed.
@(private)
form_value :: proc(body:[]u8,name:string) -> string {
    text:=string(body)
    for pair in strings.split_iterator(&text,"&") {
        eq:=strings.index_byte(pair,'=')
        if eq<0 || pair[:eq]!=name {continue}
        b:=strings.builder_make(context.temp_allocator)
        value:=pair[eq+1:]
        for k:=0;k<len(value);k+=1 {
            c:=value[k]
            switch {
            case c=='+': strings.write_byte(&b,' ')
            case c=='%' && k+2<len(value):
                hi,lo:=hex_digit(lower(value[k+1])),hex_digit(lower(value[k+2]))
                if hi<0 || lo<0 {return ""}
                strings.write_byte(&b,u8(hi<<4|lo))
                k+=2
            case: strings.write_byte(&b,c)
            }
        }
        return strings.to_string(b)
    }
    return ""
}

@(private)
lower :: proc(c:u8) -> u8 {return c|0x20 if c>='A' && c<='Z' else c}

@(private)
STYLE :: `:root{--bg:#f7f7f5;--fg:#1d1d1f;--muted:#6b6b70;--line:#e2e2de;--accent:#2f6fde;--card:#fff}
@media (prefers-color-scheme:dark){:root{--bg:#161618;--fg:#ececee;--muted:#9a9aa0;--line:#2c2c30;--accent:#6f9ff0;--card:#1e1e21}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
header{display:flex;justify-content:space-between;align-items:center;gap:16px;padding:12px 24px;border-bottom:1px solid var(--line);background:var(--card)}
header form{display:flex;gap:12px;align-items:center;margin:0}.brand{font-weight:700;color:var(--fg)}
main{max-width:960px;margin:0 auto;padding:24px 16px}a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
h1{font-size:24px;margin:8px 0 16px}h2{font-size:16px;margin:24px 0 8px}.muted{color:var(--muted)}.crumbs{color:var(--muted);margin:0}
.list{list-style:none;padding:0;margin:0}.list li{padding:8px 0;border-bottom:1px solid var(--line)}
table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:500}
.mark{width:2em;font-family:ui-monospace,monospace}.tag{font-size:12px;border:1px solid var(--line);border-radius:4px;padding:0 6px;color:var(--muted)}
pre.text{background:var(--card);border:1px solid var(--line);border-radius:6px;padding:12px;overflow:auto;font:13px/1.45 ui-monospace,monospace;white-space:pre-wrap}
code{font:13px ui-monospace,monospace}.error{color:#c33}.form{display:grid;gap:12px;max-width:320px}
input{display:block;width:100%;padding:8px;border:1px solid var(--line);border-radius:6px;background:var(--card);color:var(--fg);font:inherit}
button{padding:8px 14px;border:0;border-radius:6px;background:var(--accent);color:#fff;font:inherit;cursor:pointer}button.link{background:none;color:var(--accent);padding:0}`
