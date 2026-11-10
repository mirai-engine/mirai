package ai_store

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:project"
import "mirai:third_party/sqlite"

// The chats of a project live in one SQLite database, .mirai/ai/chat.db, in
// WAL mode so that several editors of the project can share it: a write that
// finds another one under way is kept and runs later (queue.odin). The review
// of a conversation stays in .mirai/ai/chats/<id>.review.json.
VERSION :: 1 // PRAGMA user_version of the database

@(private="file")
SCHEMA :: `CREATE TABLE conversations(
    id INTEGER PRIMARY KEY,
    kind INTEGER NOT NULL,
    parent INTEGER NOT NULL DEFAULT 0,
    reserved INTEGER NOT NULL DEFAULT 0,
    title TEXT NOT NULL DEFAULT '',
    document TEXT NOT NULL DEFAULT '',
    provider TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    effort TEXT NOT NULL DEFAULT '',
    native_session TEXT NOT NULL DEFAULT '',
    last TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0,
    seconds REAL NOT NULL DEFAULT 0,
    usage_input INTEGER NOT NULL DEFAULT 0,
    usage_output INTEGER NOT NULL DEFAULT 0,
    usage_cache_read INTEGER NOT NULL DEFAULT 0,
    usage_cache_write INTEGER NOT NULL DEFAULT 0,
    usage_total INTEGER NOT NULL DEFAULT 0,
    usage_context_used INTEGER NOT NULL DEFAULT 0,
    usage_context_size INTEGER NOT NULL DEFAULT 0,
    usage_cost REAL NOT NULL DEFAULT 0
);
CREATE TABLE messages(
    id INTEGER PRIMARY KEY,
    conversation INTEGER NOT NULL,
    sequence INTEGER NOT NULL,
    kind INTEGER NOT NULL,
    text TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT '',
    event_type TEXT NOT NULL DEFAULT 'text',
    tool TEXT NOT NULL DEFAULT '',
    context_json TEXT NOT NULL DEFAULT '',
    UNIQUE(conversation,sequence)
);
CREATE INDEX messages_user ON messages(conversation,sequence) WHERE event_type='user_message';
CREATE VIRTUAL TABLE messages_fts USING fts5(text,content='messages',content_rowid='id');
CREATE TRIGGER messages_insert AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid,text) VALUES(new.id,new.text);
END;
CREATE TRIGGER messages_delete AFTER DELETE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts,rowid,text) VALUES('delete',old.id,old.text);
END;
CREATE TRIGGER messages_update AFTER UPDATE OF text ON messages BEGIN
    INSERT INTO messages_fts(messages_fts,rowid,text) VALUES('delete',old.id,old.text);
    INSERT INTO messages_fts(rowid,text) VALUES(new.id,new.text);
END;
CREATE TABLE deliveries(
    id INTEGER PRIMARY KEY,
    conversation INTEGER NOT NULL,
    kind TEXT NOT NULL,
    text TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE notes(
    conversation INTEGER PRIMARY KEY,
    text TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE TABLE pins(
    id INTEGER PRIMARY KEY,
    kind TEXT NOT NULL,
    ref TEXT NOT NULL,
    label TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE annotations(
    id INTEGER PRIMARY KEY,
    group_name TEXT NOT NULL,
    document TEXT NOT NULL,
    entity INTEGER NOT NULL,
    x REAL NOT NULL,
    y REAL NOT NULL,
    z REAL NOT NULL,
    text TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE provenance(
    ref_kind TEXT NOT NULL,
    ref TEXT NOT NULL,
    conversation INTEGER NOT NULL,
    sequence INTEGER NOT NULL,
    at INTEGER NOT NULL,
    PRIMARY KEY(ref_kind,ref)
);
CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE memory_docs(
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,
    modified_at INTEGER NOT NULL,
    text TEXT NOT NULL
);
CREATE VIRTUAL TABLE memory_docs_fts USING fts5(text,content='memory_docs',content_rowid='id');
CREATE TRIGGER memory_docs_insert AFTER INSERT ON memory_docs BEGIN
    INSERT INTO memory_docs_fts(rowid,text) VALUES(new.id,new.text);
END;
CREATE TRIGGER memory_docs_delete AFTER DELETE ON memory_docs BEGIN
    INSERT INTO memory_docs_fts(memory_docs_fts,rowid,text) VALUES('delete',old.id,old.text);
END;
CREATE TRIGGER memory_docs_update AFTER UPDATE OF text ON memory_docs BEGIN
    INSERT INTO memory_docs_fts(memory_docs_fts,rowid,text) VALUES('delete',old.id,old.text);
    INSERT INTO memory_docs_fts(rowid,text) VALUES(new.id,new.text);
END;
PRAGMA user_version=1;`

#assert(VERSION==1,"SCHEMA sets the user_version")

// A later write of a sequence replaces its kind and text and keeps what an
// annotation completed; a line that did not change is not written again.
@(private="file")
MESSAGE_UPSERT :: `INSERT INTO messages(conversation,sequence,kind,text,role) VALUES(?1,?2,?3,?4,?5)
ON CONFLICT(conversation,sequence) DO UPDATE SET kind=excluded.kind,text=excluded.text
WHERE kind<>excluded.kind OR text<>excluded.text`

@(private="file")
CONVERSATION_UPSERT :: `INSERT INTO conversations(id,kind,parent,reserved,title,document,provider,model,effort,native_session,last,
created_at,updated_at,seconds,usage_input,usage_output,usage_cache_read,usage_cache_write,usage_total,usage_context_used,usage_context_size,usage_cost)
VALUES(?1,?2,?3,0,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21)
ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,parent=excluded.parent,reserved=0,title=excluded.title,document=excluded.document,
provider=excluded.provider,model=excluded.model,effort=excluded.effort,native_session=excluded.native_session,last=excluded.last,
created_at=excluded.created_at,updated_at=excluded.updated_at,seconds=excluded.seconds,usage_input=excluded.usage_input,
usage_output=excluded.usage_output,usage_cache_read=excluded.usage_cache_read,usage_cache_write=excluded.usage_cache_write,
usage_total=excluded.usage_total,usage_context_used=excluded.usage_context_used,usage_context_size=excluded.usage_context_size,
usage_cost=excluded.usage_cost`

@(private="file")
CONVERSATION_COLUMNS :: "id,kind,parent,title,document,provider,model,effort,native_session,last,created_at,updated_at,seconds,usage_input,usage_output,usage_cache_read,usage_cache_write,usage_total,usage_context_used,usage_context_size,usage_cost"

Store :: struct {
    folder:string, // of the review files; empty while closed
    db:^sqlite.Db,
    conversations:[dynamic]Conversation, // by updated_at and id, the latest first
    data_version:i64, // of the database when conversations was read
    kept:[dynamic]Kept_Write, // writes the database was busy for, the oldest first
    landed:u64, // kept writes that reached the database: what shows their rows reads again when it moves
    allocator:runtime.Allocator,
    error:[512]u8,
    error_len:int,
}

Conversation_Kind :: enum u8 {
    Main,     // the chat of the project
    Agent,    // a subagent of the main chat
    Archived, // of an agent outside the editor
}

Conversation_Kinds :: bit_set[Conversation_Kind]

Conversation :: struct {
    id:u64,
    kind:Conversation_Kind,
    parent:u64, // the conversation that started it, 0 if none
    title:[256]u8,
    title_len:int,
    document:[1024]u8,
    document_len:int,
    provider:[32]u8,
    provider_len:int,
    model:[128]u8,
    model_len:int,
    effort:[32]u8,
    effort_len:int,
    native_session:[256]u8,
    native_session_len:int,
    last:[LAST_BYTES]u8, // the start of the last answer of the agent, as History shows it
    last_len:int,
    created_at:i64,
    updated_at:i64,
    seconds:f32,    // its turns ran, all together
    usage:Usage,
}

// What a conversation spent, as its agent reports it over ACP: its tokens
// across the turns, with the end of each turn, and its context, as it changes.
Usage :: struct {
    input:i64 `json:"input,omitempty"`,
    output:i64 `json:"output,omitempty"`,
    cache_read:i64 `json:"cache_read,omitempty"`,
    cache_write:i64 `json:"cache_write,omitempty"`,
    total:i64 `json:"total,omitempty"`,
    context_used:i64 `json:"context_used,omitempty"`, // tokens in its context window
    context_size:i64 `json:"context_size,omitempty"`,
    cost:f64 `json:"cost,omitempty"`, // USD
}

LAST_BYTES :: 160

// Persisted as its number in messages.kind.
Line_Kind :: enum u8 {
    Output, // printed by the agent
    Prompt, // what the task was asked
    Note,   // said by the editor: why it did not start, how it ended
    Report, // a turn of a subagent of this chat ended; the text is the id of the subagent
    Divider, // a new context of the chat began; the text says why
}

Line :: struct {
    sequence:u64,
    kind:Line_Kind,
    text:string,
}

Stored_Line :: struct {
    sequence:u64,
    kind:Line_Kind,
    text:string,
    role:string,
    event_type:string,
    tool:string,
    context_json:string,
}

// Text waiting to reach a conversation.
Delivery :: struct {
    id:i64,
    conversation:u64,
    kind:string,
    text:string,
    created_at:i64,
}

Pin :: struct {
    id:i64,
    kind:string,
    ref:string,
    label:string,
    created_at:i64,
}

Annotation :: struct {
    id:i64,
    group_name:string,
    document:string,
    entity:u64,
    x,y,z:f64,
    text:string,
    created_at:i64,
}

// Who last changed an entity or an asset.
Provenance :: struct {
    conversation:u64,
    sequence:u64,
    at:i64,
}

Provenance_Ref :: struct {kind,ref:string}

Memory_Doc :: struct {
    path:string,
    modified_at:i64,
}

conversation_set_text :: proc(buffer:[]u8,length:^int,text:string) -> bool {
    if len(text)>len(buffer) {return false}
    length^=copy(buffer,text)
    return true
}

@(private)
fail :: proc(s:^Store,message:string) -> string {
    s.error_len=copy(s.error[:],message)
    return string(s.error[:s.error_len])
}

@(private)
NOT_OPEN :: "Chat history is not open"

// Reports the last failure of the database. A corrupt file is never removed:
// it may be all the history of the project.
@(private)
db_fail :: proc(s:^Store,what:string) -> string {
    if s.db==nil {return fail(s,what)}
    reason:=string(sqlite.errmsg(s.db))
    code:=sqlite.errcode(s.db)&0xff
    if code==sqlite.CORRUPT || code==sqlite.NOTADB {
        return fail(s,fmt.tprintf("%s: %s. The file .mirai/ai/chat.db was left as it is: restore it, or move it and .mirai/ai/chats away to start a new history",what,reason))
    }
    return fail(s,fmt.tprintf("%s: %s",what,reason))
}

@(private)
Db_Value :: union {i64,f64,string}

@(private)
db_bind :: proc(statement:^sqlite.Stmt,values:..Db_Value) -> bool {
    for value,index in values {
        code:c.int
        switch v in value {
        case i64: code=sqlite.bind_int64(statement,c.int(index+1),v)
        case f64: code=sqlite.bind_double(statement,c.int(index+1),v)
        case string:
            if len(v)>int(max(c.int)) {return false}
            code=sqlite.bind_text(statement,c.int(index+1),raw_data(v) if v!="" else raw_data(string("\x00")),c.int(len(v)),sqlite.TRANSIENT)
        }
        if code!=sqlite.OK {return false}
    }
    return true
}

@(private)
db_prepare :: proc(s:^Store,sql:string,values:..Db_Value) -> (statement:^sqlite.Stmt,ok:bool) {
    if sqlite.prepare_v2(s.db,raw_data(sql),c.int(len(sql)),&statement,nil)!=sqlite.OK {return nil,false}
    if !db_bind(statement,..values) {sqlite.finalize(statement);return nil,false}
    return statement,true
}

@(private)
db_finish :: proc(statement:^sqlite.Stmt) -> bool {
    for {
        switch sqlite.step(statement) {
        case sqlite.ROW:  continue
        case sqlite.DONE: return true
        case:             return false
        }
    }
}

// The integer of the first row of a statement, if it gives one.
@(private="file")
db_value :: proc(s:^Store,sql:string,values:..Db_Value) -> (value:i64,found:bool,ok:bool) {
    statement,prepared:=db_prepare(s,sql,..values)
    if !prepared {return}
    defer sqlite.finalize(statement)
    code:=sqlite.step(statement)
    if code==sqlite.ROW {
        value,found=sqlite.column_int64(statement,0),true
        code=sqlite.step(statement)
    }
    return value,found,code==sqlite.DONE
}

// Valid until the next step of the statement.
@(private)
db_text :: proc(statement:^sqlite.Stmt,column:c.int) -> string {
    text:=sqlite.column_text(statement,column)
    bytes:=sqlite.column_bytes(statement,column)
    return string(text[:bytes]) if text!=nil else ""
}

@(private)
db_clone :: proc(statement:^sqlite.Stmt,column:c.int,allocator:runtime.Allocator) -> string {
    return strings.clone(db_text(statement,column),allocator)
}

@(private)
db_exec :: proc(s:^Store,sql:cstring) -> bool {
    return sqlite.exec(s.db,sql,nil,nil,nil)==sqlite.OK
}

@(private="file")
db_abort :: proc(s:^Store,what:string) -> string {
    message:=db_fail(s,what)
    db_exec(s,"ROLLBACK")
    return message
}

@(private)
line_kind :: proc(value:i64) -> (kind:Line_Kind,ok:bool) {
    if value<0 || value>i64(max(Line_Kind)) {return}
    return Line_Kind(value),true
}

// True when text holds part, without minding upper and lower case.
@(private="file")
contains_fold :: proc(text,part:string) -> bool {
    if len(part)>len(text) {return false}
    for i in 0..=len(text)-len(part) {
        if strings.equal_fold(text[i:][:len(part)],part) {return true}
    }
    return false
}

@(private="file")
now :: proc() -> i64 {
    return time.to_unix_nanoseconds(time.now())/1_000_000
}

@(private="file")
before :: proc(a,b:Conversation) -> bool {
    return a.updated_at>b.updated_at || a.updated_at==b.updated_at && a.id>b.id
}

// Puts c in its place of the order, replacing the conversation with its id.
@(private)
place :: proc(s:^Store,c:^Conversation) -> bool {
    for &existing,index in s.conversations {
        if existing.id==c.id {ordered_remove(&s.conversations,index);break}
    }
    at:=len(s.conversations)
    for &existing,index in s.conversations {if before(c^,existing) {at=index;break}}
    if _,error:=inject_at(&s.conversations,at,c^);error!=nil {return false}
    return true
}

@(private="file")
ROW_VALUES :: 21

@(private="file")
row_values :: proc(c:^Conversation,out:[]Db_Value) {
    out[0],out[1],out[2]=i64(c.id),i64(c.kind),i64(c.parent)
    out[3],out[4]=string(c.title[:c.title_len]),string(c.document[:c.document_len])
    out[5],out[6],out[7]=string(c.provider[:c.provider_len]),string(c.model[:c.model_len]),string(c.effort[:c.effort_len])
    out[8],out[9]=string(c.native_session[:c.native_session_len]),string(c.last[:c.last_len])
    out[10],out[11],out[12]=c.created_at,c.updated_at,f64(c.seconds)
    out[13],out[14],out[15],out[16]=c.usage.input,c.usage.output,c.usage.cache_read,c.usage.cache_write
    out[17],out[18],out[19],out[20]=c.usage.total,c.usage.context_used,c.usage.context_size,c.usage.cost
}

@(private="file")
row_read :: proc(statement:^sqlite.Stmt) -> (c:Conversation,ok:bool) {
    kind:=sqlite.column_int64(statement,1)
    if kind<0 || kind>i64(max(Conversation_Kind)) {return}
    c={id=u64(sqlite.column_int64(statement,0)),kind=Conversation_Kind(kind),parent=u64(sqlite.column_int64(statement,2)),
        created_at=sqlite.column_int64(statement,10),updated_at=sqlite.column_int64(statement,11),seconds=f32(sqlite.column_double(statement,12)),
        usage={input=sqlite.column_int64(statement,13),output=sqlite.column_int64(statement,14),cache_read=sqlite.column_int64(statement,15),
            cache_write=sqlite.column_int64(statement,16),total=sqlite.column_int64(statement,17),context_used=sqlite.column_int64(statement,18),
            context_size=sqlite.column_int64(statement,19),cost=sqlite.column_double(statement,20)}}
    ok=conversation_set_text(c.title[:],&c.title_len,db_text(statement,3)) &&
        conversation_set_text(c.document[:],&c.document_len,db_text(statement,4)) &&
        conversation_set_text(c.provider[:],&c.provider_len,db_text(statement,5)) &&
        conversation_set_text(c.model[:],&c.model_len,db_text(statement,6)) &&
        conversation_set_text(c.effort[:],&c.effort_len,db_text(statement,7)) &&
        conversation_set_text(c.native_session[:],&c.native_session_len,db_text(statement,8)) &&
        conversation_set_text(c.last[:],&c.last_len,db_text(statement,9))
    return
}

// Reads the list again if another editor of the project wrote the database
// since the last time.
@(private="file")
refresh :: proc(s:^Store) -> string {
    version,_,ok:=db_value(s,"PRAGMA data_version")
    if !ok {return db_fail(s,"Could not read the project chats")}
    if version==s.data_version {return ""}
    statement,prepared:=db_prepare(s,"SELECT "+CONVERSATION_COLUMNS+" FROM conversations WHERE reserved=0 ORDER BY updated_at DESC,id DESC")
    if !prepared {return db_fail(s,"Could not read the project chats")}
    defer sqlite.finalize(statement)
    clear(&s.conversations)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {break}
        if code!=sqlite.ROW {s.data_version=-1;return db_fail(s,"Could not read the project chats")}
        if c,valid:=row_read(statement);valid {
            if _,error:=append(&s.conversations,c);error!=nil {s.data_version=-1;return fail(s,"No memory for the project chats")}
        }
    }
    s.data_version=version
    return ""
}

// Gives a new database its schema; two editors that open it at once take
// turns. A database of another version is reported and left as it is.
@(private="file")
schema :: proc(s:^Store) -> string {
    version,_,ok:=db_value(s,"PRAGMA user_version")
    if !ok {return db_fail(s,"Could not open the project chat database")}
    if version==VERSION {return ""}
    if version!=0 {return fail(s,fmt.tprintf("The project chat database has version %d and this editor reads version %d: use the editor that wrote it, or move .mirai/ai/chat.db and .mirai/ai/chats away to start a new history",version,VERSION))}
    if !db_exec(s,"BEGIN IMMEDIATE") {return db_fail(s,"Could not create the project chat database")}
    version,_,ok=db_value(s,"PRAGMA user_version")
    if !ok || version==0 && !db_exec(s,SCHEMA) || !db_exec(s,"COMMIT") {return db_abort(s,"Could not create the project chat database")}
    return ""
}

open :: proc(s:^Store,root:string,allocator:=context.allocator) -> string {
    close(s)
    s.error_len=0
    folder:=project.path(root,".mirai/ai/chats",allocator=context.temp_allocator)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return fail(s,"Could not create the project chat folder")}
    path:=strings.clone_to_cstring(project.path(root,".mirai/ai/chat.db",allocator=context.temp_allocator),context.temp_allocator)
    if sqlite.open_v2(path,&s.db,sqlite.OPEN_READWRITE|sqlite.OPEN_CREATE|sqlite.OPEN_NOMUTEX,nil)!=sqlite.OK {
        message:=db_fail(s,"Could not open the project chat database")
        sqlite.close_v2(s.db);s.db=nil
        return message
    }
    sqlite.busy_timeout(s.db,OPEN_BUSY_MS)
    s.allocator=allocator
    s.folder=strings.clone(folder,allocator)
    s.conversations=make([dynamic]Conversation,allocator)
    s.kept=make([dynamic]Kept_Write,allocator)
    s.data_version=-1
    message:=""
    if !db_exec(s,"PRAGMA journal_mode=WAL") || !db_exec(s,"PRAGMA synchronous=NORMAL") {
        message=db_fail(s,"Could not open the project chat database")
    }
    if message=="" {message=schema(s)}
    if message=="" {message=refresh(s)}
    if message!="" {close(s);return message}
    sqlite.busy_timeout(s.db,0)
    return ""
}

// Waits for another editor so that the writes it kept reach the database.
close :: proc(s:^Store) {
    if s.db!=nil {
        if len(s.kept)>0 {
            sqlite.busy_timeout(s.db,OPEN_BUSY_MS)
            flush(s)
        }
        sqlite.close_v2(s.db);s.db=nil
    }
    if s.folder=="" {return}
    for &kept in s.kept {delete(kept.block,s.allocator)}
    delete(s.kept)
    delete(s.folder,s.allocator)
    delete(s.conversations)
    s.folder,s.conversations,s.kept={},{},{}
}

// Reserves the next identifier by inserting its row, which no list shows until
// it is saved, so that another editor of the same project does not take it.
next_id :: proc(s:^Store) -> (id:u64,message:string) {
    value,failed:=db_insert(s,"Could not reserve a chat identifier","INSERT INTO conversations(id,kind,reserved) SELECT coalesce(max(id),0)+1,?1,1 FROM conversations RETURNING id",
        i64(Conversation_Kind.Archived))
    if failed!="" {return 0,failed}
    if value<=0 || value>=max(i64) {return 0,fail(s,"Chat identifiers are exhausted")}
    return u64(value),""
}

// Writes the conversation and its lines; a line saved before with another
// kind or text is replaced.
save :: proc(s:^Store,c:^Conversation,lines:[]Line) -> string {
    if s.db==nil {return fail(s,NOT_OPEN)}
    if c.id==0 || c.id>=u64(max(i64)) {return fail(s,"Invalid chat identifier")}
    LINE_VALUES :: 5
    statements:=make([]Statement,len(lines)+1,context.temp_allocator)
    values:=make([]Db_Value,len(lines)*LINE_VALUES+ROW_VALUES,context.temp_allocator)
    if statements==nil || values==nil {return fail(s,"No memory to save the project chat")}
    for line,index in lines {
        bound:=values[index*LINE_VALUES:][:LINE_VALUES]
        bound[0],bound[1],bound[2],bound[3]=i64(c.id),i64(line.sequence),i64(line.kind),line.text
        bound[4]=line.kind==.Prompt?"user":line.kind==.Output?"assistant":"system"
        statements[index]={MESSAGE_UPSERT,bound}
    }
    row:=values[len(lines)*LINE_VALUES:]
    row_values(c,row)
    statements[len(lines)]={CONVERSATION_UPSERT,row}
    w:=Write{what="Could not save the project chat",statements=statements,conversation=c}
    return write(s,&w)
}

// Sets role, event type, tool and context of a message saved before.
annotate :: proc(s:^Store,id,sequence:u64,role,event_type,tool,context_json:string) -> string {
    return db_write(s,"Could not save the project chat","UPDATE messages SET role=?1,event_type=?2,tool=?3,context_json=?4 WHERE conversation=?5 AND sequence=?6",role,event_type,tool,context_json,i64(id),i64(sequence))
}

// The conversations whose titles have needle, or that found names. Without
// kinds, those of every kind; a parent keeps its own.
list :: proc(s:^Store,out:[]Conversation,document_path:string="",offset:int=0,needle:string="",found:[]u64={},kinds:Conversation_Kinds={},parent:u64=0) -> (count:int,message:string) {
    if s.db==nil {return 0,fail(s,NOT_OPEN)}
    if offset<0 {return 0,fail(s,"Invalid chat history offset")}
    if refresh:=refresh(s);refresh!="" {return 0,refresh}
    skipped:=0
    for &c in s.conversations {
        if count==len(out) {break}
        if kinds!={} && c.kind not_in kinds {continue}
        if parent!=0 && c.parent!=parent {continue}
        if document_path!="" && string(c.document[:c.document_len])!=document_path {continue}
        if !contains_fold(string(c.title[:c.title_len]),needle) && !slice.contains(found,c.id) {continue}
        if skipped<offset {skipped+=1;continue}
        out[count]=c;count+=1
    }
    return count,""
}

find :: proc(s:^Store,id:u64) -> ^Conversation {
    if s.db==nil {return nil}
    refresh(s)
    for &c in s.conversations {if c.id==id {return &c}}
    return nil
}

// The main chat of the project, nil until it has one.
main_conversation :: proc(s:^Store) -> ^Conversation {
    if s.db==nil {return nil}
    refresh(s)
    for &c in s.conversations {if c.kind==.Main {return &c}}
    return nil
}

// The latest lines of the conversation that out can hold, in order.
load :: proc(s:^Store,id:u64,out:[]Line,allocator:=context.temp_allocator) -> (count:int,message:string) {
    if s.db==nil {return 0,fail(s,NOT_OPEN)}
    statement,ok:=db_prepare(s,"SELECT sequence,kind,text FROM (SELECT sequence,kind,text FROM messages WHERE conversation=?1 ORDER BY sequence DESC LIMIT ?2) ORDER BY sequence",i64(id),i64(len(out)))
    if !ok {return 0,db_fail(s,"Could not read the project chat")}
    defer sqlite.finalize(statement)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {return count,""}
        if code!=sqlite.ROW {return 0,db_fail(s,"Could not read the project chat")}
        kind,valid:=line_kind(sqlite.column_int64(statement,1))
        if !valid {continue}
        out[count]={sequence=u64(sqlite.column_int64(statement,0)),kind=kind,text=db_clone(statement,2,allocator)}
        count+=1
    }
}

// The messages right before a sequence, the latest ones if it is negative, in
// order.
page :: proc(s:^Store,id:u64,before_sequence:i64,out:[]Stored_Line,allocator:=context.temp_allocator) -> (count:int,message:string) {
    if s.db==nil {return 0,fail(s,NOT_OPEN)}
    end:=before_sequence if before_sequence>=0 else max(i64)
    statement,ok:=db_prepare(s,"SELECT sequence,kind,text,role,event_type,tool,context_json FROM messages WHERE conversation=?1 AND sequence<?2 ORDER BY sequence DESC LIMIT ?3",i64(id),end,i64(len(out)))
    if !ok {return 0,db_fail(s,"Could not read the project chat")}
    defer sqlite.finalize(statement)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {break}
        if code!=sqlite.ROW {return 0,db_fail(s,"Could not read the project chat")}
        kind,valid:=line_kind(sqlite.column_int64(statement,1))
        if !valid {continue}
        out[count]={sequence=u64(sqlite.column_int64(statement,0)),kind=kind,text=db_clone(statement,2,allocator),role=db_clone(statement,3,allocator),
            event_type=db_clone(statement,4,allocator),tool=db_clone(statement,5,allocator),context_json=db_clone(statement,6,allocator)}
        count+=1
    }
    slice.reverse(out[:count])
    return count,""
}

// The sequence of the latest message marked as the turn of the user; -1 if none.
latest_user_message :: proc(s:^Store,id:u64) -> i64 {
    if s.db==nil {return -1}
    value,found,ok:=db_value(s,"SELECT sequence FROM messages WHERE conversation=?1 AND event_type='user_message' ORDER BY sequence DESC LIMIT 1",i64(id))
    return value if ok && found else -1
}

// what and sql are constants of the package.
@(private="file")
db_write :: proc(s:^Store,what,sql:string,values:..Db_Value) -> string {
    statements:=[1]Statement{{sql,values}}
    w:=Write{what=what,statements=statements[:]}
    return write(s,&w)
}

// Inserts a row and gives its id, which is needed now: with the database
// busy it fails instead of waiting or being kept.
@(private="file")
db_insert :: proc(s:^Store,what,sql:string,values:..Db_Value) -> (id:i64,message:string) {
    if s.db==nil {return 0,fail(s,NOT_OPEN)}
    if !write_ready(s) {return 0,fail(s,BUSY)}
    sqlite.busy_timeout(s.db,BUSY_MS)
    value,found,ok:=db_value(s,sql,..values)
    sqlite.busy_timeout(s.db,0)
    if !ok && db_busy(s) {return 0,fail(s,BUSY)}
    if !ok || !found {return 0,db_fail(s,what)}
    return value,""
}

// The text of the first row of a statement, "" without one.
@(private="file")
db_read_text :: proc(s:^Store,what,sql:string,allocator:runtime.Allocator,values:..Db_Value) -> (text:string,message:string) {
    if s.db==nil {return "",fail(s,NOT_OPEN)}
    statement,ok:=db_prepare(s,sql,..values)
    if !ok {return "",db_fail(s,what)}
    defer sqlite.finalize(statement)
    switch sqlite.step(statement) {
    case sqlite.ROW:  return db_clone(statement,0,allocator),""
    case sqlite.DONE: return "",""
    }
    return "",db_fail(s,what)
}

delivery_add :: proc(s:^Store,conversation:u64,kind,text:string) -> string {
    return db_write(s,"Could not save the delivery","INSERT INTO deliveries(conversation,kind,text,created_at) VALUES(?1,?2,?3,?4)",i64(conversation),kind,text,now())
}

// What waits to reach a conversation, the oldest first.
deliveries :: proc(s:^Store,conversation:u64,allocator:=context.temp_allocator) -> (deliveries:[]Delivery,message:string) {
    if s.db==nil {return nil,fail(s,NOT_OPEN)}
    statement,ok:=db_prepare(s,"SELECT id,conversation,kind,text,created_at FROM deliveries WHERE conversation=?1 ORDER BY id",i64(conversation))
    if !ok {return nil,db_fail(s,"Could not read the deliveries")}
    defer sqlite.finalize(statement)
    rows:=make([dynamic]Delivery,allocator)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {return rows[:],""}
        if code!=sqlite.ROW {return nil,db_fail(s,"Could not read the deliveries")}
        append(&rows,Delivery{id=sqlite.column_int64(statement,0),conversation=u64(sqlite.column_int64(statement,1)),kind=db_clone(statement,2,allocator),
            text=db_clone(statement,3,allocator),created_at=sqlite.column_int64(statement,4)})
    }
}

delivery_remove :: proc(s:^Store,id:i64) -> string {
    return db_write(s,"Could not remove the delivery","DELETE FROM deliveries WHERE id=?1",id)
}

// The working notes of a conversation, "" without them.
note_get :: proc(s:^Store,conversation:u64,allocator:=context.temp_allocator) -> (text:string,message:string) {
    return db_read_text(s,"Could not read the chat notes","SELECT text FROM notes WHERE conversation=?1",allocator,i64(conversation))
}

note_set :: proc(s:^Store,conversation:u64,text:string) -> string {
    return db_write(s,"Could not save the chat notes","INSERT INTO notes(conversation,text,updated_at) VALUES(?1,?2,?3) ON CONFLICT(conversation) DO UPDATE SET text=excluded.text,updated_at=excluded.updated_at",i64(conversation),text,now())
}

pin_add :: proc(s:^Store,kind,ref,label:string) -> string {
    return db_write(s,"Could not save the pin","INSERT INTO pins(kind,ref,label,created_at) VALUES(?1,?2,?3,?4)",kind,ref,label,now())
}

pins :: proc(s:^Store,allocator:=context.temp_allocator) -> (pins:[]Pin,message:string) {
    if s.db==nil {return nil,fail(s,NOT_OPEN)}
    statement,ok:=db_prepare(s,"SELECT id,kind,ref,label,created_at FROM pins ORDER BY id")
    if !ok {return nil,db_fail(s,"Could not read the pins")}
    defer sqlite.finalize(statement)
    rows:=make([dynamic]Pin,allocator)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {return rows[:],""}
        if code!=sqlite.ROW {return nil,db_fail(s,"Could not read the pins")}
        append(&rows,Pin{id=sqlite.column_int64(statement,0),kind=db_clone(statement,1,allocator),ref=db_clone(statement,2,allocator),
            label=db_clone(statement,3,allocator),created_at=sqlite.column_int64(statement,4)})
    }
}

pin_remove :: proc(s:^Store,id:i64) -> string {
    return db_write(s,"Could not remove the pin","DELETE FROM pins WHERE id=?1",id)
}

annotation_add :: proc(s:^Store,group_name,document:string,entity:u64,x,y,z:f64,text:string) -> (id:i64,message:string) {
    return db_insert(s,"Could not save the annotation","INSERT INTO annotations(group_name,document,entity,x,y,z,text,created_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8) RETURNING id",
        group_name,document,i64(entity),x,y,z,text,now())
}

annotations :: proc(s:^Store,document:string,allocator:=context.temp_allocator) -> (annotations:[]Annotation,message:string) {
    if s.db==nil {return nil,fail(s,NOT_OPEN)}
    statement,ok:=db_prepare(s,"SELECT id,group_name,document,entity,x,y,z,text,created_at FROM annotations WHERE document=?1 ORDER BY id",document)
    if !ok {return nil,db_fail(s,"Could not read the annotations")}
    defer sqlite.finalize(statement)
    rows:=make([dynamic]Annotation,allocator)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {return rows[:],""}
        if code!=sqlite.ROW {return nil,db_fail(s,"Could not read the annotations")}
        append(&rows,Annotation{id=sqlite.column_int64(statement,0),group_name=db_clone(statement,1,allocator),document=db_clone(statement,2,allocator),
            entity=u64(sqlite.column_int64(statement,3)),x=sqlite.column_double(statement,4),y=sqlite.column_double(statement,5),z=sqlite.column_double(statement,6),
            text=db_clone(statement,7,allocator),created_at=sqlite.column_int64(statement,8)})
    }
}

annotation_remove :: proc(s:^Store,id:i64) -> string {
    return db_write(s,"Could not remove the annotation","DELETE FROM annotations WHERE id=?1",id)
}

@(private="file")
annotation_known :: proc(s:^Store,id:i64) -> string {
    if s.db==nil {return fail(s,NOT_OPEN)}
    _,found,ok:=db_value(s,"SELECT id FROM annotations WHERE id=?1",id)
    if !ok {return db_fail(s,"Could not read the annotations")}
    if !found {return fail(s,fmt.tprintf("There is no annotation %d: list the annotations of the document",id))}
    return ""
}

annotation_set_text :: proc(s:^Store,id:i64,text:string) -> string {
    if message:=annotation_known(s,id);message!="" {return message}
    return db_write(s,"Could not save the annotation","UPDATE annotations SET text=?1 WHERE id=?2",text,id)
}

annotation_set_group :: proc(s:^Store,id:i64,group_name:string) -> string {
    if message:=annotation_known(s,id);message!="" {return message}
    return db_write(s,"Could not save the annotation","UPDATE annotations SET group_name=?1 WHERE id=?2",group_name,id)
}

@(private="file")
PROVENANCE_UPSERT :: "INSERT INTO provenance(ref_kind,ref,conversation,sequence,at) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(ref_kind,ref) DO UPDATE SET conversation=excluded.conversation,sequence=excluded.sequence,at=excluded.at"

provenance_set :: proc(s:^Store,ref_kind,ref:string,conversation,sequence:u64) -> string {
    return db_write(s,"Could not save who changed it",PROVENANCE_UPSERT,ref_kind,ref,i64(conversation),i64(sequence),now())
}

// All a transaction of a turn changed, in one write.
provenance_record :: proc(s:^Store,refs:[]Provenance_Ref,conversation,sequence:u64) -> string {
    if s.db==nil {return fail(s,NOT_OPEN)}
    if len(refs)==0 {return ""}
    REF_VALUES :: 5
    statements:=make([]Statement,len(refs),context.temp_allocator)
    values:=make([]Db_Value,len(refs)*REF_VALUES,context.temp_allocator)
    if statements==nil || values==nil {return fail(s,"No memory to save who changed it")}
    at:=now()
    for ref,index in refs {
        bound:=values[index*REF_VALUES:][:REF_VALUES]
        bound[0],bound[1],bound[2],bound[3],bound[4]=ref.kind,ref.ref,i64(conversation),i64(sequence),at
        statements[index]={PROVENANCE_UPSERT,bound}
    }
    w:=Write{what="Could not save who changed it",statements=statements}
    return write(s,&w)
}

provenance_get :: proc(s:^Store,ref_kind,ref:string) -> (provenance:Provenance,found:bool,message:string) {
    if s.db==nil {return {},false,fail(s,NOT_OPEN)}
    statement,ok:=db_prepare(s,"SELECT conversation,sequence,at FROM provenance WHERE ref_kind=?1 AND ref=?2",ref_kind,ref)
    if !ok {return {},false,db_fail(s,"Could not read who changed it")}
    defer sqlite.finalize(statement)
    switch sqlite.step(statement) {
    case sqlite.ROW:
        return {u64(sqlite.column_int64(statement,0)),u64(sqlite.column_int64(statement,1)),sqlite.column_int64(statement,2)},true,""
    case sqlite.DONE:
        return {},false,""
    }
    return {},false,db_fail(s,"Could not read who changed it")
}

meta_get :: proc(s:^Store,key:string,allocator:=context.temp_allocator) -> (value:string,message:string) {
    return db_read_text(s,"Could not read the chat database","SELECT value FROM meta WHERE key=?1",allocator,key)
}

meta_set :: proc(s:^Store,key,value:string) -> string {
    return db_write(s,"Could not write the chat database","INSERT INTO meta(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",key,value)
}

memory_upsert :: proc(s:^Store,path:string,modified_at:i64,text:string) -> string {
    return db_write(s,"Could not index the memory document",`INSERT INTO memory_docs(path,modified_at,text) VALUES(?1,?2,?3)
ON CONFLICT(path) DO UPDATE SET modified_at=excluded.modified_at,text=excluded.text WHERE modified_at<>excluded.modified_at OR text<>excluded.text`,path,modified_at,text)
}

memory_remove :: proc(s:^Store,path:string) -> string {
    return db_write(s,"Could not remove the memory document","DELETE FROM memory_docs WHERE path=?1",path)
}

// The indexed documents by path.
memory_list :: proc(s:^Store,allocator:=context.temp_allocator) -> (docs:[]Memory_Doc,message:string) {
    if s.db==nil {return nil,fail(s,NOT_OPEN)}
    statement,ok:=db_prepare(s,"SELECT path,modified_at FROM memory_docs ORDER BY path")
    if !ok {return nil,db_fail(s,"Could not read the memory documents")}
    defer sqlite.finalize(statement)
    rows:=make([dynamic]Memory_Doc,allocator)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {return rows[:],""}
        if code!=sqlite.ROW {return nil,db_fail(s,"Could not read the memory documents")}
        append(&rows,Memory_Doc{path=db_clone(statement,0,allocator),modified_at=sqlite.column_int64(statement,1)})
    }
}
