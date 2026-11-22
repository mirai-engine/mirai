package hub

import "core:strings"

// The frontend: the files of the folder web beside this package, embedded at
// build time, flat. Names that start with a dot are not served. A path that
// names no file and has no dot in its last part gets index.html, when there
// is one, so the frontend routes its own paths.

@(private)
STATIC_TYPES :: [?][2]string{
    {".html","text/html; charset=utf-8"},{".js","text/javascript; charset=utf-8"},{".mjs","text/javascript; charset=utf-8"},
    {".css","text/css; charset=utf-8"},{".json","application/json"},{".svg","image/svg+xml"},{".png","image/png"},
    {".jpg","image/jpeg"},{".webp","image/webp"},{".ico","image/x-icon"},{".woff2","font/woff2"},{".wasm","application/wasm"},
    {".txt","text/plain; charset=utf-8"},{".map","application/json"},
}

static_response :: proc(path:string) -> Response {
    files:=#load_directory("web")
    name:=strings.trim_prefix(path,"/")
    if name=="" {name="index.html"}
    for f in files {
        if f.name==name && name[0]!='.' {return static_file(f.name,f.data)}
    }
    last:=name
    if cut:=strings.last_index_byte(last,'/');cut>=0 {last=last[cut+1:]}
    if strings.index_byte(last,'.')<0 {
        for f in files {
            if f.name=="index.html" {return static_file(f.name,f.data)}
        }
    }
    return error_response(404,"no such file")
}

@(private)
static_file :: proc(name:string,data:[]u8) -> Response {
    kind:="application/octet-stream"
    for t in STATIC_TYPES {
        if strings.has_suffix(name,t[0]) {kind=t[1]}
    }
    return {status=200,content_type=kind,body=data,cache=name=="index.html"?"no-cache":"public, max-age=3600"}
}
