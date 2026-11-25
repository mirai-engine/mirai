package hub

import "core:strings"
import "mirai:store"

// The frontend: the files of the folder web beside this package, embedded at
// build time, flat. Names that start with a dot are not served. A path that
// names no file and has no dot in its last part gets index.html, when there
// is one, so the frontend routes its own paths.
//
// Every file is revalidated on each load (no-cache) against its ETag, the
// BLAKE3 of its bytes: a deploy never mixes modules of two builds, and an
// unchanged file answers 304 with no body.

@(private)
STATIC_TYPES :: [?][2]string{
    {".html","text/html; charset=utf-8"},{".js","text/javascript; charset=utf-8"},{".mjs","text/javascript; charset=utf-8"},
    {".css","text/css; charset=utf-8"},{".json","application/json"},{".svg","image/svg+xml"},{".png","image/png"},
    {".jpg","image/jpeg"},{".webp","image/webp"},{".ico","image/x-icon"},{".woff2","font/woff2"},{".wasm","application/wasm"},
    {".txt","text/plain; charset=utf-8"},{".map","application/json"},
}

static_response :: proc(r:^Request) -> Response {
    files:=#load_directory("web")
    name:=strings.trim_prefix(r.path,"/")
    if name=="" {name="index.html"}
    for f in files {
        if f.name==name && name[0]!='.' {return static_file(r,f.name,f.data)}
    }
    last:=name
    if cut:=strings.last_index_byte(last,'/');cut>=0 {last=last[cut+1:]}
    if strings.index_byte(last,'.')<0 {
        for f in files {
            if f.name=="index.html" {return static_file(r,f.name,f.data)}
        }
    }
    return error_response(404,"no such file")
}

// The strong validator of a file: "<hex of the first 16 bytes of its BLAKE3>", quoted.
static_etag :: proc(data:[]u8) -> string {
    text:[64]u8
    return strings.concatenate({`"`,store.hex(store.address_of_bytes(data),&text)[:32],`"`},context.temp_allocator)
}

// Whether an If-None-Match header names tag, or is *.
@(private)
etag_matches :: proc(header,tag:string) -> bool {
    rest:=header
    for part in strings.split_iterator(&rest,",") {
        item:=strings.trim_space(part)
        item=strings.trim_prefix(item,"W/")
        if item=="*" || item==tag {return true}
    }
    return false
}

@(private)
static_file :: proc(r:^Request,name:string,data:[]u8) -> Response {
    kind:="application/octet-stream"
    for t in STATIC_TYPES {
        if strings.has_suffix(name,t[0]) {kind=t[1]}
    }
    tag:=static_etag(data)
    headers:=strings.concatenate({"ETag: ",tag,"\r\n"},context.temp_allocator)
    if header,found:=request_header(r,"if-none-match");found && etag_matches(header,tag) {
        return {status=304,cache="no-cache",headers=headers}
    }
    return {status=200,content_type=kind,body=data,cache="no-cache",headers=headers}
}
