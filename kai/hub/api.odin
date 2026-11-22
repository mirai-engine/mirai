package hub

import "base:runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:strconv"
import "core:strings"
import "mirai:kai"
import "mirai:store"

// The routes of the API, in one table that both dispatches and describes:
// GET /api answers the table itself, so a client reads what each route takes
// and gives instead of a document. Paths name ids in lowercase hex.

Response :: struct {
    status:int,
    content_type:string,
    cache:string,   // Cache-Control; "" is no-store
    headers:string, // more header lines, each ending in CRLF
    body:[]u8,
    close:bool,
}

Access :: enum u8 {
    Public,  // anyone; a private project answers only a member's session
    Session, // a session of a signed-in user
    Member,  // a session of a member of the org the route names
}

Place :: enum u8 {Path,Query,Body}

Param :: struct {name:string,place:Place,kind:string,text:string}


Route :: struct {
    method:Method,
    path:string,   // segments; {name} takes one segment as the param name
    access:Access,
    summary:string,
    params:[]Param,
    result:string,
    limit:Limit,   // the rate it counts against
    handler:proc(c:^Call),
}

// One request on its way through a route.
Call :: struct {
    h:^Hub,
    conn:^Conn,
    request:^Request,
    route:^Route,
    names:[4]string,
    values:[4]string,
    count:int,
    session:^Session,
    response:Response,
}

P :: Param
REV :: P{"rev",.Query,"revision","a revision (64 hex) or a bookmark name; the project's main bookmark when absent"}
PROJECT :: P{"project",.Path,"log id","the project (64 hex)"}
ORG :: P{"org",.Path,"log id","the org (64 hex)"}
ASSERTION :: P{"assertion",.Body,"object","the passkey's answer to navigator.credentials.get: {credential, authenticator_data, client_data_json, signature}, each base64url of the browser's bytes"}

ROUTES :: [?]Route{
    {.GET,"/api",.Public,"This description: every route of the API with its params and what it answers. Generated from the table that dispatches.",{},"{version, origin, rp_id, routes:[{method, path, access, summary, params:[{name, in, type, text}], result}], entries, notes}",.Read,route_describe},
    {.GET,"/api/node",.Public,"The node: what it serves and how to sign in.",{},"{device, modes:[...], rp_id, origin, orgs, passkeys_work}",.Read,route_node},
    {.GET,"/api/projects",.Public,"The projects of the orgs the node serves: the public ones, and the private ones of the orgs the session's user is a member of.",{},"{projects:[{id, org, name, public}]}",.Read,route_projects},
    {.GET,"/api/projects/{project}",.Public,"A project's overview: its name, its bookmarks and its README.",{PROJECT},"{id, org, name, public, main, bookmarks:[{name, revision, change, landed, device, time}], readme:{path, text, truncated}|null}",.Read,route_project},
    {.GET,"/api/projects/{project}/tree",.Public,"The entries of a folder of a revision.",{PROJECT,REV,{"path",.Query,"path","the folder, '' for the root"}},"{revision, path, entries:[{name, kind: file|executable|folder|conflict, size, files, conflicts}]}",.Read,route_tree},
    {.GET,"/api/projects/{project}/file",.Public,"The raw bytes of a file of a revision: text/plain; charset=utf-8 for UTF-8 text, else application/octet-stream as an attachment; refused past FILE_MAX bytes.",{PROJECT,REV,{"path",.Query,"path","the file"}},"the file's bytes",.Read,route_file},
    {.GET,"/api/projects/{project}/changes",.Public,"The changes a bookmark reaches, newest first, a page at a time.",{PROJECT,REV,{"page",.Query,"int","from 0"},{"limit",.Query,"int","changes per page, at most CHANGES_PAGE_MAX"}},"{revision, page, more, changes:[{revision, change, author, written, summary, parents:[revision]}]}",.Read,route_changes},
    {.GET,"/api/projects/{project}/changes/{revision}",.Public,"One change: its head, description, co-authors and the files it changes from its first parent.",{PROJECT,{"revision",.Path,"revision","64 hex"}},"{revision, change, author, author_name, created, written, parents, description, coauthors:[{key, name}], turns, files:[{path, status: added|removed|modified|conflict, before:{address, size}, after:{address, size}}]}",.Read,route_change},
    {.GET,"/api/projects/{project}/diff",.Public,"The line diff of one file between two revisions (std/diff); a binary or an oversized file says so instead.",{PROJECT,{"from",.Query,"revision","the old revision (64 hex)"},{"to",.Query,"revision","the new revision (64 hex)"},{"path",.Query,"path","the file"}},"{path, binary, too_large, before:{size}|null, after:{size}|null, added, removed, lines:[{op: same|add|remove, old, new, text}]}",.Read,route_diff},
    {.GET,"/api/projects/{project}/evolution/{change}",.Public,"The revisions of one Change_Id over time, oldest first, with the interdiff between each and the next: the files whose content differs between their trees among those either edits.",{PROJECT,{"change",.Path,"change id","32 hex"}},"{change, revisions:[{revision, written, author, summary, files:[path]}], interdiffs:[{from, to, files:[{path, before, after}]}]}",.Read,route_evolution},
    {.GET,"/api/projects/{project}/summary",.Public,"What a file is, when it is an asset a peer summarized: kai/preview.odin lays out the summary (a head line, the kind, then label<TAB>value per fact), and whether a thumbnail is here. none when no peer published one; fetching while the node takes it from its peers. A file a scope takes has none.",{PROJECT,REV,{"path",.Query,"path","the file"}},"{path, address, state: none|fetching|found, summary: text|null, thumbnail: none|fetching|found}",.Read,route_summary},
    {.GET,"/api/projects/{project}/thumbnail",.Public,"The thumbnail of an asset a peer published: a PNG of at most PREVIEW_SIDE_MAX pixels a side; 404 when there is none here.",{PROJECT,REV,{"path",.Query,"path","the file"}},"image/png",.Read,route_thumbnail},
    {.GET,"/api/projects/{project}/asset-diff",.Public,"What a change did to an asset, row by row and field by field, as a peer that read both sides recorded it: kai/preview.odin lays out the detail (a head line, added, removed, changed and cut rows, then mark<TAB>entity<TAB>text per row).",{PROJECT,{"from",.Query,"revision","the old revision (64 hex); absent when the file is new"},{"to",.Query,"revision","the new revision (64 hex)"},{"path",.Query,"path","the file"}},"{path, state: none|fetching|found, detail: text|null}",.Read,route_asset_diff},
    {.GET,"/api/projects/{project}/stacks",.Member,"The stacks of every device: <handle>/<device>:<bookmark>, each with the changes it holds above what landed.",{PROJECT},"{stacks:[{label, user, handle, device, device_name, bookmark, revision, time, changes:[{revision, change, summary}]}]}",.Read,route_stacks},
    {.GET,"/api/projects/{project}/proposals",.Member,"The proposals of a project.",{PROJECT},"{proposals:[{id, title, target, status, opener, opener_name, revision, approvals, comments}]}",.Read,route_proposals},
    {.GET,"/api/proposals/{proposal}",.Member,"One proposal: its stack, its comments placed on the current stack, its verdicts and checks, and what blocks landing.",{{"proposal",.Path,"log id","the Proposal_Log (64 hex)"}},"{id, project, title, text, target, status, opener, opener_name, revision, stack:[{change, revision, summary}], comments:[{id, author, author_name, time, text, reply_to, change, path, anchor:{kind, line, lines}, outdated}], verdicts:[{user, name, verdict, revision, current}], checks:[{name, state}], approvals, blocked:{reason, text}|null, heads:[entry address]}",.Read,route_proposal},
    {.GET,"/api/orgs/{org}/members",.Member,"The members of an org with their roles, devices and passkeys, and its nodes.",{ORG},"{org, name, owner, members:[{user, name, role, devices:[{key, name, revoked}], passkeys:[{key, revoked}]}], nodes:[{key, modes}], heads:[entry address]}",.Read,route_members},
    {.GET,"/api/orgs/{org}/ddc",.Member,"The derived data the node holds for an org: keys, outputs here or missing, keys with more than one output (nondeterminism), and the lookups it answered.",{ORG},"{keys, records, whole, missing, nondeterministic, lookups_found, lookups_missing, quota, bytes}",.Read,route_ddc},
    {.GET,"/api/node/stats",.Session,"The node's peers, relay and store, for a member of any org it serves.",{},"{peers:[{org, dh, class, rung, node}], relay:{...}, store:{bytes, packs}, hub:{requests, refused, connections, sessions}}",.Read,route_stats},
    {.GET,"/api/session",.Session,"Who the session is.",{},"{user, name, passkey: the web key id of the session's passkey, the author of the entries it signs, or null, orgs:[{org, name, role}]}",.Read,route_session},
    {.POST,"/api/session/challenge",.Public,"A challenge for navigator.credentials.get, valid CHALLENGE_SECONDS, usable once.",{},"{challenge (base64url), rp_id, timeout_ms}",.Auth,route_challenge},
    {.POST,"/api/session",.Public,"Signs in with a passkey's assertion of a challenge: a read session in the __Host-kai cookie (HttpOnly, Secure, SameSite=Strict).",{{"challenge",.Body,"base64url","the challenge given"},ASSERTION},"{user, name}",.Auth,route_sign_in},
    {.POST,"/api/session/end",.Public,"Ends the session.",{},"{}",.Auth,route_sign_out},
    {.POST,"/api/users",.Public,"Creates a user born of the browser's passkey: its Passkey_Genesis, signed by that passkey over the BLAKE3 of the unsigned bytes. It has no recovery key and no device until the passkey links a device (POST /api/approvals, kind device). The node keeps it apart, unsynced, until a member of an org it serves adds it; the oldest waiting user goes when WAITING_MAX wait. Nothing is signed by the server.",{{"unsigned",.Body,"base64url","the genesis's bytes before its assertion, as GET /api/entries lays them out"},ASSERTION},"{user}",.Create,route_user_create},
    {.POST,"/api/passkeys/link",.Public,"Links a new passkey to an existing user: a device of the user approves it with `mirai kai web approve <link>`, which signs the Web_Key_Add.",{{"user",.Body,"log id","the user (64 hex)"},{"credential",.Body,"base64url","the credential id"},{"cose",.Body,"base64url","the COSE public key of the credential"}},"{id, secret, link, command}",.Create,route_passkey_link},
    {.POST,"/api/approvals",.Public,"Asks a device of the user to approve, for a browser without a passkey: kind 'login' starts a session once approved; kind 'entry' (with a session) has the device sign a write. Kind 'device' (with a session) links a machine to the user: the machine offers itself with `mirai kai web approve <link>`, the browser reads the offer from the approval's state and signs its Device_Add. The browser shows the link and the command.",{{"kind",.Body,"text","login | entry | device"},{"draft",.Body,"object","entry: the fields of POST /api/drafts"}},"{id, secret, link, command}",.Auth,route_approval_new},
    {.GET,"/api/approvals/{id}",.Public,"What an approval asks, for the device that signs it.",{{"id",.Path,"hex","the approval"}},"{kind, rp_id, origin, challenge, user, credential, cose, type, log, body, author_ctx, linked, entries: a device's user's log once it names the device}",.Read,route_approval_get},
    {.POST,"/api/approvals/{id}",.Public,"The device's answer: a login's signature, or the signed entry.",{{"id",.Path,"hex","the approval"},{"device",.Body,"hex","login: the device key"},{"signature",.Body,"base64url","login: Ed25519 over 'kai-1/web-login' || rp_id || challenge"},{"entry",.Body,"base64url","entry and passkey links: the signed entry"},{"dh",.Body,"hex","device: the machine's X25519 key"},{"proof",.Body,"base64url","device: its Ed25519 signature over LABEL_DEVICE || the user's log id"},{"name",.Body,"text","device: its name"}},"{state} or, for a device, {code}",.Auth,route_approval_answer},
    {.POST,"/api/approvals/{id}/state",.Public,"The browser's poll of its approval; a login's sets the session cookie once approved.",{{"id",.Path,"hex","the approval"},{"secret",.Body,"base64url","the secret the approval was made with"}},"{state: waiting|approved|denied|expired, address, offer: a device's {device, dh, proof, name, code}}",.Read,route_approval_state},
    {.GET,"/api/entries",.Public,"The byte layout of a log entry and of each body a write may carry, which a client checks in a draft before it signs.",{},"{entry:{...}, bodies:{...}}",.Read,route_entries},
    {.POST,"/api/drafts",.Session,"The unsigned bytes of an entry for the session's passkey: the server fills the log's heads and the author context. It gives no challenge: the browser parses the bytes, checks every field against what the user asked, computes the BLAKE3 of the bytes itself and signs that.",{{"type",.Body,"text","proposal_comment | proposal_verdict | proposal_close | proposal_reopen | member_add | member_remove | role_set | device_add"},{"log",.Body,"log id","the log the entry joins (a proposal or an org)"},{"verdict",.Body,"text","approve | changes | withdraw"},{"revision",.Body,"revision","the revision a verdict binds to"},{"text",.Body,"text","a comment's text"},{"change",.Body,"change id","the change a comment is on; absent for the whole proposal"},{"path",.Body,"path","the file a comment is on"},{"anchor",.Body,"object","{kind: file|lines, line, lines}; user and role for org actions go in 'user' and 'role'"},{"device",.Body,"hex","device_add: the device's key, from its offer"},{"dh",.Body,"hex","device_add: its X25519 key"},{"proof",.Body,"base64url","device_add: its proof"},{"name",.Body,"text","device_add: its name"}},"{unsigned (base64url), type, log, parents, author, author_ctx, org_ctx, time}",.Write,route_draft},
    {.POST,"/api/entries",.Session,"Appends an entry the session's passkey signed: the unsigned bytes and the assertion over their BLAKE3. The server verifies it as kai/webauthn.odin and the log's fold do, keeps it and tells the peers.",{{"unsigned",.Body,"base64url","the draft's bytes, unchanged"},ASSERTION},"{address, log}",.Write,route_entry_append},
}

Limit :: enum u8 {Read,Auth,Write,Create}

// The rate of each limit per address: a bucket of burst requests that refills
// rate a second.
LIMITS :: [Limit]struct{rate,burst:f64}{
    .Read={20,200},
    .Auth={0.5,20},
    .Write={0.5,20},
    .Create={1.0/600,3},
}

Rate :: struct {
    address:[16]u8,
    used:bool,
    seen:f64,
    tokens:[Limit]f64,
}

// Takes one request of limit for the address; false when its bucket is empty.
rate_take :: proc(h:^Hub,address:[16]u8,limit:Limit) -> bool {
    limits:=LIMITS
    slot,oldest:=-1,-1
    for &r,i in h.rates {
        if r.used && r.address==address {
            slot=i
            break
        }
        if oldest<0 || !r.used || (h.rates[oldest].used && r.seen<h.rates[oldest].seen) {oldest=i}
    }
    if slot<0 {
        slot=oldest
        r:=&h.rates[slot]
        r^={address=address,used=true,seen=h.now}
        for l in Limit {r.tokens[l]=limits[l].burst}
    }
    r:=&h.rates[slot]
    elapsed:=h.now-r.seen
    r.seen=h.now
    for l in Limit {r.tokens[l]=min(limits[l].burst,r.tokens[l]+elapsed*limits[l].rate)}
    if r.tokens[limit]<1 {return false}
    r.tokens[limit]-=1
    return true
}

// Answers a request: the route its method and path name, its access and its rate.
dispatch :: proc(h:^Hub,conn:^Conn,r:^Request) -> Response {
    c:=Call{h=h,conn=conn,request=r}
    c.session=session_of(h,r)
    routes:=ROUTES
    path_known:=false
    for &route in routes {
        if !path_match(&c,route.path,r.path) {continue}
        path_known=true
        if route.method!=r.method && !(route.method==.GET && r.method==.HEAD) {continue}
        c.route=&route
        address:[16]u8
        if conn!=nil {address=conn.address}
        if !rate_take(h,address,route.limit) {return error_response(429,"too many requests from this address: wait and try again")}
        if r.method==.POST {
            if why:=post_allowed(h,r);why!="" {return error_response(403,why)}
        }
        switch route.access {
        case .Public:
        case .Session,.Member:
            if c.session==nil {return error_response(401,"sign in first: POST /api/session/challenge, then POST /api/session with the passkey's assertion")}
        }
        route.handler(&c)
        if c.response.status==0 {c.response=error_response(500,"the route gave no answer")}
        return c.response
    }
    if path_known {
        response:=error_response(405,"this path takes another method: GET /api lists the routes")
        return response
    }
    if r.path=="/api" || strings.has_prefix(r.path,"/api/") {return error_response(404,"no such route: GET /api lists the routes")}
    if r.method!=.GET && r.method!=.HEAD {return error_response(405,"static files are read with GET")}
    return static_response(r.path)
}

// A POST comes from this origin as JSON: a page of another origin cannot post
// a form here, and a browser sends the cookie only to this site.
@(private)
post_allowed :: proc(h:^Hub,r:^Request) -> string {
    if origin,found:=request_header(r,"origin");found && origin!=h.origin {return "the request comes from another origin"}
    kind,_:=request_header(r,"content-type")
    if cut:=strings.index_byte(kind,';');cut>=0 {kind=strings.trim_space(kind[:cut])}
    if len(r.body)>0 && !strings.equal_fold(kind,"application/json") {return "a POST carries application/json"}
    return ""
}

@(private)
path_match :: proc(c:^Call,pattern,path:string) -> bool {
    c.count=0
    p,q:=pattern,path
    for {
        if len(p)==0 || len(q)==0 {return len(p)==0 && len(q)==0}
        if p[0]!='/' || q[0]!='/' {return false}
        p,q=p[1:],q[1:]
        pe:=strings.index_byte(p,'/')
        qe:=strings.index_byte(q,'/')
        ps:=pe<0?p:p[:pe]
        qs:=qe<0?q:q[:qe]
        if len(ps)>2 && ps[0]=='{' && ps[len(ps)-1]=='}' {
            if qs=="" || c.count>=len(c.names) {return false}
            c.names[c.count],c.values[c.count]=ps[1:len(ps)-1],qs
            c.count+=1
        } else if ps!=qs {
            return false
        }
        p=pe<0?"":p[pe:]
        q=qe<0?"":q[qe:]
    }
}

path_param :: proc(c:^Call,name:string) -> string {
    for n,i in c.names[:c.count] {
        if n==name {return c.values[i]}
    }
    return ""
}

// A query parameter, percent-decoded; "" when absent or not decodable.
query_param :: proc(c:^Call,name:string) -> (value:string,found:bool) {
    q:=c.request.query
    for part in strings.split_iterator(&q,"&") {
        eq:=strings.index_byte(part,'=')
        key:=eq<0?part:part[:eq]
        if key!=name {continue}
        raw:=eq<0?"":part[eq+1:]
        decoded,ok:=percent_decode(raw)
        return decoded,ok
    }
    return "",false
}

@(private)
percent_decode :: proc(text:string) -> (string,bool) {
    out:=make([dynamic]u8,0,len(text),context.temp_allocator)
    for i:=0;i<len(text);i+=1 {
        c:=text[i]
        switch c {
        case '+': append(&out,' ')
        case '%':
            if i+2>=len(text) {return "",false}
            hi,ok1:=hex_digit(text[i+1])
            lo,ok2:=hex_digit(text[i+2])
            if !ok1 || !ok2 {return "",false}
            append(&out,hi<<4|lo)
            i+=2
        case: append(&out,c)
        }
    }
    return string(out[:]),true
}

@(private)
hex_digit :: proc "contextless" (c:u8) -> (u8,bool) {
    switch c {
    case '0'..='9': return c-'0',true
    case 'a'..='f': return c-'a'+10,true
    case 'A'..='F': return c-'A'+10,true
    }
    return 0,false
}

// The bytes of lowercase or uppercase hex of exactly len(out) bytes.
hex_parse :: proc(text:string,out:[]u8) -> bool {
    if len(text)!=2*len(out) {return false}
    for i in 0..<len(out) {
        hi,ok1:=hex_digit(text[2*i])
        lo,ok2:=hex_digit(text[2*i+1])
        if !ok1 || !ok2 {return false}
        out[i]=hi<<4|lo
    }
    return true
}

hash_parse :: proc(text:string) -> (h:store.Hash,ok:bool) {
    ok=hex_parse(text,h[:])
    return
}

base64_parse :: proc(text:string,max_bytes:int) -> (bytes:[]u8,ok:bool) {
    if len(text)>(max_bytes*4+2)/3+4 {return nil,false}
    trimmed:=strings.trim_right(text,"=")
    decoded,e:=base64.decode(trimmed,base64.DEC_URL_TABLE,allocator=context.temp_allocator)
    if e!=nil || len(decoded)>max_bytes {return nil,false}
    return decoded,true
}

// The JSON body of the request into out; false answers 400 with why.
body_parse :: proc(c:^Call,out:^$T) -> bool {
    if len(c.request.body)==0 {
        c.response=error_response(400,"the request needs a JSON body: GET /api says its fields")
        return false
    }
    if e:=json.unmarshal(c.request.body,out,.JSON,context.temp_allocator);e!=nil {
        c.response=error_response(400,"the body is not the JSON this route takes: GET /api says its fields")
        return false
    }
    return true
}

error_response :: proc(status:int,why:string) -> Response {
    j:=json_make()
    json_object(&j)
    json_member_string(&j,"error",why)
    json_end_object(&j)
    return {status=status,content_type="application/json",body=transmute([]u8)json_text(&j)}
}

json_response :: proc(c:^Call,j:^Json,status:=200) {
    c.response={status=status,content_type="application/json",body=transmute([]u8)json_text(j)}
}

fail :: proc(c:^Call,status:int,why:string) {c.response=error_response(status,why)}

// --- GET /api ---

@(private)
route_describe :: proc(c:^Call) {
    h:=c.h
    j:=json_make()
    json_object(&j)
    json_member_int(&j,"version",1)
    json_member_string(&j,"origin",h.origin)
    json_member_string(&j,"rp_id",h.desc.rp_id)
    json_key(&j,"limits")
    json_object(&j)
    json_member_int(&j,"FILE_MAX",FILE_MAX)
    json_member_int(&j,"DIFF_FILE_MAX",DIFF_FILE_MAX)
    json_member_int(&j,"DIFF_LINES_MAX",DIFF_LINES_MAX)
    json_member_int(&j,"CHANGES_PAGE_MAX",CHANGES_PAGE_MAX)
    json_member_int(&j,"PREVIEW_SIDE_MAX",kai.PREVIEW_SIDE_MAX)
    json_member_int(&j,"BODY_MAX",BODY_MAX)
    json_member_int(&j,"CHALLENGE_SECONDS",i64(CHALLENGE_SECONDS))
    json_member_int(&j,"SESSION_SECONDS",i64(SESSION_SECONDS))
    json_end_object(&j)
    json_key(&j,"routes")
    json_array(&j)
    routes:=ROUTES
    for &r in routes {
        json_object(&j)
        methods,accesses,places:=METHOD_TEXT,ACCESS_TEXT,PLACE_TEXT
        json_member_string(&j,"method",methods[r.method])
        json_member_string(&j,"path",r.path)
        json_member_string(&j,"access",accesses[r.access])
        json_member_string(&j,"summary",r.summary)
        json_key(&j,"params")
        json_array(&j)
        for p in r.params {
            if p.name=="" {continue}
            json_object(&j)
            json_member_string(&j,"name",p.name)
            json_member_string(&j,"in",places[p.place])
            json_member_string(&j,"type",p.kind)
            json_member_string(&j,"text",p.text)
            json_end_object(&j)
        }
        json_end_array(&j)
        json_member_string(&j,"result",r.result)
        json_end_object(&j)
    }
    json_end_array(&j)
    json_member_string(&j,"entries","GET /api/entries lays out the bytes of every entry a write carries")
    json_key(&j,"notes")
    json_array(&j)
    for note in NOTES {json_string(&j,note)}
    json_end_array(&j)
    json_end_object(&j)
    json_response(c,&j)
}

METHOD_TEXT :: [Method]string{.None="",.GET="GET",.HEAD="HEAD",.POST="POST"}
ACCESS_TEXT :: [Access]string{.Public="public",.Session="session",.Member="member"}
PLACE_TEXT :: [Place]string{.Path="path",.Query="query",.Body="body"}

NOTES :: [?]string{
    "Ids, revisions, keys and addresses are lowercase hex; bytes in bodies are base64url without padding.",
    "A private project answers 404 to anyone but a session of a member of its org; public routes take a private project with such a session.",
    "Errors answer {error} with what failed and how to fix it.",
    "Never sign a challenge the server gives for a write: a draft has none. Parse the unsigned bytes (GET /api/entries), check every field, compute BLAKE3-256 of the bytes and pass that as the challenge of navigator.credentials.get.",
    "Passkeys work over HTTPS only, for the relying party rp_id; the plain HTTP of loopback serves reads.",
    "A sign-in's assertion needs the user present; a write's also needs the user verified (userVerification: required), and a write signed with a P-256 passkey keeps the low S of its signature.",
    "Static files of the frontend are served from the folder kai/hub/web embedded at build time, flat; a path without a dot that is no file gets index.html when there is one.",
    "POST bodies are application/json and must come from this origin; at most BODY_MAX bytes.",
}

@(private)
concat :: proc(allocator:runtime.Allocator,parts:..string) -> string {
    return strings.concatenate(parts,allocator)
}

@(private)
itoa :: proc(n:int) -> string {
    buffer:=make([]u8,24,context.temp_allocator)
    return strconv.write_int(buffer,i64(n),10)
}

