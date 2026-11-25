package hub

import "mirai:kai"
import "mirai:store"

// The previews of a file the web view shows beside it (kai/preview.odin):
// the summary and the thumbnail of an asset and the detail of what a change
// did to it, which peers that read the asset published as derived data of the
// org. A route reaches a file as the file route does (the project, a revision
// its bookmarks reach, a path no scope takes) and answers what a record names
// once its output is here and preview_check takes it. A record that is here
// without its output has the node fetch it; nothing is made here.

PREVIEW_STATE_TEXT :: [kai.Preview_State]string{.None="none",.Fetching="fetching",.Found="found"}

// The file at path of the revision rev_text names, as the file route finds it;
// else the answer is set.
@(private)
preview_file :: proc(c:^Call,v:^Project_View,rev_text,path:string) -> (file:kai.Tree_Entry,revision:kai.Revision,ok:bool) {
    if !kai.path_valid(path) || scoped(v,path) {
        fail(c,404,"no such file in this revision")
        return
    }
    r,rok:=revision_resolve(c,v,rev_text)
    if !rok {return}
    ch,e:=kai.change_get(store_of(c.h),r,context.temp_allocator)
    if e!=.None {
        fail(c,404,"the change is not on this node yet")
        return
    }
    entry,found,_:=kai.tree_file(store_of(c.h),ch.tree,path)
    if !found || entry.kind==.Conflict {
        fail(c,404,"no such file in this revision")
        return
    }
    return entry,r,true
}

// The preview of kind made from from and to, and whether it is here; one
// whose output is not here yet is fetched from the peers.
@(private)
preview_of :: proc(c:^Call,v:^Project_View,kind:kai.Preview_Kind,from,to:store.Hash) -> (bytes:[]u8,state:kai.Preview_State) {
    key:=kai.preview_key(kind,from,to)
    lacking:=make([dynamic]store.Hash,context.temp_allocator)
    bytes,state=kai.preview_get(store_of(c.h),v.org.id,kind,key,&lacking,context.temp_allocator)
    if state==.Fetching {kai.runner_ddc_ask(runner_of(c.h),v.org.id,key)}
    return
}

@(private)
route_summary :: proc(c:^Call) {
    v,ok:=project_open(c,path_param(c,"project"))
    if !ok {return}
    rev_text,_:=query_param(c,"rev")
    path,_:=query_param(c,"path")
    file,_,fok:=preview_file(c,&v,rev_text,path)
    if !fok {return}
    summary,state:=preview_of(c,&v,.Summary,{},file.address)
    _,thumbnail:=preview_of(c,&v,.Thumbnail,{},file.address)
    states:=PREVIEW_STATE_TEXT
    j:=json_make()
    json_object(&j)
    json_member_string(&j,"path",path)
    json_member_hash(&j,"address",file.address)
    json_member_string(&j,"state",states[state])
    json_key(&j,"summary")
    if state==.Found {json_string(&j,string(summary))} else {json_null(&j)}
    json_member_string(&j,"thumbnail",states[thumbnail])
    json_end_object(&j)
    json_response(c,&j)
}

@(private)
route_thumbnail :: proc(c:^Call) {
    v,ok:=project_open(c,path_param(c,"project"))
    if !ok {return}
    rev_text,_:=query_param(c,"rev")
    path,_:=query_param(c,"path")
    file,r,fok:=preview_file(c,&v,rev_text,path)
    if !fok {return}
    png,state:=preview_of(c,&v,.Thumbnail,{},file.address)
    switch state {
    case .None:
        fail(c,404,"no peer published a thumbnail of this file: the editor that publishes a bookmark gives the previews it keeps of a mesh, a material or a texture")
        return
    case .Fetching:
        fail(c,404,"the node is fetching the thumbnail of this file from its peers: ask again")
        return
    case .Found:
    }
    c.response={status=200,content_type="image/png",body=png,headers=SANDBOX_HEADER,cache="private, max-age=31536000, immutable"}
    if x,is_hex:=hash_parse(rev_text);!is_hex || x!=r {c.response.cache="no-store"}
}

@(private)
route_asset_diff :: proc(c:^Call) {
    v,ok:=project_open(c,path_param(c,"project"))
    if !ok {return}
    from_text,_:=query_param(c,"from")
    to_text,_:=query_param(c,"to")
    path,_:=query_param(c,"path")
    if to_text=="" {
        fail(c,400,"to names the revision after the change; from the one before, absent for none")
        return
    }
    if !kai.path_valid(path) || scoped(&v,path) {
        fail(c,404,"no such file in these revisions")
        return
    }
    sides:[2]store.Hash
    for text,k in ([2]string{from_text,to_text}) {
        if text=="" {continue}
        r,rok:=revision_resolve(c,&v,text)
        if !rok {return}
        ch,e:=kai.change_get(store_of(c.h),r,context.temp_allocator)
        if e!=.None {
            fail(c,404,"a change is not on this node yet")
            return
        }
        if entry,found,_:=kai.tree_file(store_of(c.h),ch.tree,path);found && entry.kind!=.Conflict {sides[k]=entry.address}
    }
    if sides[0]=={} && sides[1]=={} {
        fail(c,404,"no such file in these revisions")
        return
    }
    detail:[]u8
    state:=kai.Preview_State.None
    if sides[0]!=sides[1] {detail,state=preview_of(c,&v,.Detail,sides[0],sides[1])}
    states:=PREVIEW_STATE_TEXT
    j:=json_make()
    json_object(&j)
    json_member_string(&j,"path",path)
    json_member_string(&j,"state",states[state])
    json_key(&j,"detail")
    if state==.Found {json_string(&j,string(detail))} else {json_null(&j)}
    json_end_object(&j)
    json_response(c,&j)
}
