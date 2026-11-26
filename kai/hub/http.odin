package hub

import "core:strconv"
import "core:strings"

// HTTP/1.1 without I/O: a connection is handed the bytes it received and
// gives a request once the head and its body are whole. Everything is bounded:
// the head (request line and headers), the number of headers, the target and
// the body. What is ambiguous between two readers of one stream is refused
// rather than guessed: a Transfer-Encoding of any kind (no request of the API
// sends a chunked body), more than one Content-Length, a body on a GET, folded
// header lines and bare line breaks. A refused request ends its connection.

HEAD_MAX :: 8<<10      // the request line and the headers
BODY_MAX :: 8<<10      // the body of a request: a form
HEADERS_MAX :: 32
TARGET_MAX :: 2048
REQUESTS_PER_CONNECTION :: 1000

Method :: enum u8 {None,GET,HEAD,POST}

Header :: struct {name,value:string}

// A request whose strings point into the input of its connection.
Request :: struct {
    method:Method,
    target:string,
    path:string,
    query:string,
    headers:[HEADERS_MAX]Header,
    header_count:int,
    body:[]u8,
    keep_alive:bool,
    expect_continue:bool,
    size:int, // bytes of the input the request takes, head and body
}

// What a parse found: Ready, Incomplete, or the status that refuses it.
Parse :: struct {
    status:int, // 0 Incomplete, 200 Ready, else the error status
    head_done:bool,
    request:Request,
}

request_header :: proc(r:^Request,name:string) -> (value:string,found:bool) {
    for h in r.headers[:r.header_count] {
        if strings.equal_fold(h.name,name) {return h.value,true}
    }
    return "",false
}

@(private)
token_char :: proc "contextless" (c:u8) -> bool {
    switch c {
    case 'a'..='z','A'..='Z','0'..='9': return true
    case '!','#','$','%','&','\'','*','+','-','.','^','_','`','|','~': return true
    }
    return false
}

// Parses the request at the start of input.
request_parse :: proc(input:[]u8) -> (p:Parse) {
    end:=-1
    limit:=min(len(input),HEAD_MAX)
    for i:=0;i+3<limit;i+=1 {
        if input[i]=='\r' && input[i+1]=='\n' && input[i+2]=='\r' && input[i+3]=='\n' {
            end=i
            break
        }
    }
    if end<0 {
        // A head never holds a bare line break or a control byte: refuse it as soon as it shows.
        for c,i in input[:limit] {
            if c=='\n' && (i==0 || input[i-1]!='\r') {return {status=400}}
            if c=='\r' && i+1<limit && input[i+1]!='\n' {return {status=400}}
            if c<0x20 && c!='\r' && c!='\n' && c!='\t' || c==0x7f {return {status=400}}
        }
        if len(input)>=HEAD_MAX {return {status=431}}
        return
    }
    head:=string(input[:end])
    for c,i in transmute([]u8)head {
        if c=='\n' && (i==0 || head[i-1]!='\r') {return {status=400}}
        if c=='\r' && (i+1>=len(head) || head[i+1]!='\n') {return {status=400}}
        if c<0x20 && c!='\r' && c!='\n' && c!='\t' || c==0x7f {return {status=400}}
    }
    p.head_done=true
    r:=&p.request
    line_end:=strings.index(head,"\r\n")
    line:=line_end<0?head:head[:line_end]
    rest:=line_end<0?"":head[line_end+2:]
    sp1:=strings.index_byte(line,' ')
    if sp1<=0 {return {status=400}}
    sp2:=strings.index_byte(line[sp1+1:],' ')
    if sp2<=0 {return {status=400}}
    method,target,version:=line[:sp1],line[sp1+1:][:sp2],line[sp1+1+sp2+1:]
    switch method {
    case "GET": r.method=.GET
    case "HEAD": r.method=.HEAD
    case "POST": r.method=.POST
    case:
        for c in transmute([]u8)method {
            if !token_char(c) {return {status=400}}
        }
        return {status=501}
    }
    keep_alive:bool
    switch version {
    case "HTTP/1.1": keep_alive=true
    case "HTTP/1.0": keep_alive=false
    case:
        if strings.has_prefix(version,"HTTP/") {return {status=505}}
        return {status=400}
    }
    if len(target)>TARGET_MAX {return {status=414}}
    if len(target)==0 || target[0]!='/' {return {status=400}}
    for c in transmute([]u8)target {
        if c<=0x20 || c>=0x7f || c=='#' {return {status=400}}
    }
    r.target=target
    r.path=target
    if q:=strings.index_byte(target,'?');q>=0 {r.path,r.query=target[:q],target[q+1:]}
    hosts,lengths:=0,0
    content_length:=-1
    for len(rest)>0 {
        e:=strings.index(rest,"\r\n")
        field:=e<0?rest:rest[:e]
        rest=e<0?"":rest[e+2:]
        if len(field)==0 {return {status=400}}
        if field[0]==' ' || field[0]=='\t' {return {status=400}} // obs-fold
        colon:=strings.index_byte(field,':')
        if colon<=0 {return {status=400}}
        name:=field[:colon]
        for c in transmute([]u8)name {
            if !token_char(c) {return {status=400}}
        }
        value:=strings.trim(field[colon+1:]," \t")
        if r.header_count>=HEADERS_MAX {return {status=431}}
        r.headers[r.header_count]={name,value}
        r.header_count+=1
        switch {
        case strings.equal_fold(name,"host"): hosts+=1
        case strings.equal_fold(name,"transfer-encoding"): return {status=501}
        case strings.equal_fold(name,"content-length"):
            lengths+=1
            if lengths>1 || len(value)==0 || len(value)>10 {return {status=400}}
            for c in transmute([]u8)value {
                if c<'0' || c>'9' {return {status=400}}
            }
            n,_:=strconv.parse_int(value,10)
            if n>BODY_MAX {return {status=413}}
            content_length=n
        case strings.equal_fold(name,"connection"):
            for part in strings.split_iterator(&value,",") {
                option:=strings.trim(part," \t")
                if strings.equal_fold(option,"close") {keep_alive=false}
            }
        case strings.equal_fold(name,"expect"):
            if !strings.equal_fold(value,"100-continue") {return {status=417}}
            r.expect_continue=true
        }
    }
    if version=="HTTP/1.1" && hosts!=1 {return {status=400}}
    if hosts>1 {return {status=400}}
    if r.method!=.POST && content_length>0 {return {status=400}}
    if r.method==.POST && content_length<0 {return {status=411}}
    r.keep_alive=keep_alive
    body_at:=end+4
    length:=max(content_length,0)
    if len(input)-body_at<length {return {status=0,head_done=true,request=r^}}
    r.body=input[body_at:][:length]
    r.size=body_at+length
    p.status=200
    return
}

REASONS :: [?]struct{status:int,text:string}{
    {100,"Continue"},{200,"OK"},{201,"Created"},{204,"No Content"},{303,"See Other"},{304,"Not Modified"},
    {400,"Bad Request"},{401,"Unauthorized"},{403,"Forbidden"},{404,"Not Found"},{405,"Method Not Allowed"},
    {408,"Request Timeout"},{409,"Conflict"},{411,"Length Required"},{413,"Content Too Large"},{414,"URI Too Long"},
    {415,"Unsupported Media Type"},{417,"Expectation Failed"},{422,"Unprocessable Content"},{429,"Too Many Requests"},
    {431,"Request Header Fields Too Large"},{500,"Internal Server Error"},{501,"Not Implemented"},
    {503,"Service Unavailable"},{505,"HTTP Version Not Supported"},
}

reason :: proc(status:int) -> string {
    for r in REASONS {
        if r.status==status {return r.text}
    }
    return "Status"
}

// The headers every answer carries: no script, no third party, no framing, no
// sniffing, no referrer.
SECURITY_HEADERS :: "Content-Security-Policy: default-src 'none'; style-src 'self'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'\r\n" +
    "X-Content-Type-Options: nosniff\r\n" +
    "X-Frame-Options: DENY\r\n" +
    "Referrer-Policy: no-referrer\r\n" +
    "Cross-Origin-Opener-Policy: same-origin\r\n" +
    "Cross-Origin-Resource-Policy: same-origin\r\n" +
    "Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()\r\n"
