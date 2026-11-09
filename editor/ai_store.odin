package editor

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
// WAL mode so that several editors of the project can share it: a write waits
// for another one instead of failing. The review of a conversation stays in
// .mirai/ai/chats/<id>.review.json.
AI_STORE_VERSION :: 1 // PRAGMA user_version of the database
AI_STORE_BUSY_MS :: 5000 // what a write waits for another editor of the project

@(private="file")
AI_STORE_SCHEMA :: `CREATE TABLE conversations(
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

#assert(AI_STORE_VERSION==1,"AI_STORE_SCHEMA sets the user_version")

// A later write of a sequence replaces its kind and text and keeps what an
// annotation completed; a line that did not change is not written again.
@(private="file")
AI_STORE_MESSAGE_UPSERT :: `INSERT INTO messages(conversation,sequence,kind,text,role) VALUES(?1,?2,?3,?4,?5)
ON CONFLICT(conversation,sequence) DO UPDATE SET kind=excluded.kind,text=excluded.text
WHERE kind<>excluded.kind OR text<>excluded.text`

@(private="file")
AI_STORE_CONVERSATION_UPSERT :: `INSERT INTO conversations(id,kind,parent,reserved,title,document,provider,model,effort,native_session,last,
created_at,updated_at,seconds,usage_input,usage_output,usage_cache_read,usage_cache_write,usage_total,usage_context_used,usage_context_size,usage_cost)
VALUES(?1,?2,?3,0,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21)
ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,parent=excluded.parent,reserved=0,title=excluded.title,document=excluded.document,
provider=excluded.provider,model=excluded.model,effort=excluded.effort,native_session=excluded.native_session,last=excluded.last,
created_at=excluded.created_at,updated_at=excluded.updated_at,seconds=excluded.seconds,usage_input=excluded.usage_input,
usage_output=excluded.usage_output,usage_cache_read=excluded.usage_cache_read,usage_cache_write=excluded.usage_cache_write,
usage_total=excluded.usage_total,usage_context_used=excluded.usage_context_used,usage_context_size=excluded.usage_context_size,
usage_cost=excluded.usage_cost`

@(private="file")
AI_STORE_CONVERSATION_COLUMNS :: "id,kind,parent,title,document,provider,model,effort,native_session,last,created_at,updated_at,seconds,usage_input,usage_output,usage_cache_read,usage_cache_write,usage_total,usage_context_used,usage_context_size,usage_cost"

Ai_Store :: struct {
    folder:string, // of the review files; empty while closed
    db:^sqlite.Db,
    conversations:[dynamic]Ai_Conversation, // by updated_at and id, the latest first
    data_version:i64, // of the database when conversations was read
    allocator:runtime.Allocator,
    error:[512]u8,
    error_len:int,
}

Ai_Conversation_Kind :: enum u8 {
    Main,     // the chat of the project
    Agent,    // a subagent of the main chat
    Archived, // of an agent outside the editor
}

Ai_Conversation_Kinds :: bit_set[Ai_Conversation_Kind]

Ai_Conversation :: struct {
    id:u64,
    kind:Ai_Conversation_Kind,
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
    last:[AI_LAST_BYTES]u8, // the start of the last answer of the agent, as History shows it
    last_len:int,
    created_at:i64,
    updated_at:i64,
    seconds:f32,    // its turns ran, all together
    usage:Ai_Usage,
}

// What a conversation spent, as its agent reports it over ACP: its tokens
// across the turns, with the end of each turn, and its context, as it changes.
Ai_Usage :: struct {
    input:i64 `json:"input,omitempty"`,
    output:i64 `json:"output,omitempty"`,
    cache_read:i64 `json:"cache_read,omitempty"`,
    cache_write:i64 `json:"cache_write,omitempty"`,
    total:i64 `json:"total,omitempty"`,
    context_used:i64 `json:"context_used,omitempty"`, // tokens in its context window
    context_size:i64 `json:"context_size,omitempty"`,
    cost:f64 `json:"cost,omitempty"`, // USD
}

Ai_Stored_Line :: struct {
    sequence:u64,
    kind:Ai_Line_Kind,
    text:string,
    role:string,
    event_type:string,
    tool:string,
    context_json:string,
}

// Text waiting to reach a conversation.
Ai_Delivery :: struct {
    id:i64,
    conversation:u64,
    kind:string,
    text:string,
    created_at:i64,
}

Ai_Pin :: struct {
    id:i64,
    kind:string,
    ref:string,
    label:string,
    created_at:i64,
}

Ai_Annotation :: struct {
    id:i64,
    group_name:string,
    document:string,
    entity:u64,
    x,y,z:f64,
    text:string,
    created_at:i64,
}

// Who last changed an entity or an asset.
Ai_Provenance :: struct {
    conversation:u64,
    sequence:u64,
    at:i64,
}

Ai_Provenance_Ref :: struct {kind,ref:string}

Ai_Memory_Doc :: struct {
    path:string,
    modified_at:i64,
}

ai_conversation_set_text :: proc(buffer:[]u8,length:^int,text:string) -> bool {
    if len(text)>len(buffer) {return false}
    length^=copy(buffer,text)
    return true
}

@(private)
ai_store_error :: proc(s:^Ai_Store,message:string) -> string {
    s.error_len=copy(s.error[:],message)
    return string(s.error[:s.error_len])
}

@(private)
AI_STORE_NOT_OPEN :: "Chat history is not open"

// Reports the last failure of the database. A corrupt file is never removed:
// it may be all the history of the project.
@(private)
ai_db_fail :: proc(s:^Ai_Store,what:string) -> string {
    if s.db==nil {return ai_store_error(s,what)}
    reason:=string(sqlite.errmsg(s.db))
    code:=sqlite.errcode(s.db)&0xff
    if code==sqlite.CORRUPT || code==sqlite.NOTADB {
        return ai_store_error(s,fmt.tprintf("%s: %s. The file .mirai/ai/chat.db was left as it is: restore it, or move it and .mirai/ai/chats away to start a new history",what,reason))
    }
    return ai_store_error(s,fmt.tprintf("%s: %s",what,reason))
}

@(private)
Ai_Db_Value :: union {i64,f64,string}

@(private="file")
ai_db_bind :: proc(statement:^sqlite.Stmt,values:..Ai_Db_Value) -> bool {
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
ai_db_prepare :: proc(s:^Ai_Store,sql:string,values:..Ai_Db_Value) -> (statement:^sqlite.Stmt,ok:bool) {
    if sqlite.prepare_v2(s.db,raw_data(sql),c.int(len(sql)),&statement,nil)!=sqlite.OK {return nil,false}
    if !ai_db_bind(statement,..values) {sqlite.finalize(statement);return nil,false}
    return statement,true
}

@(private="file")
ai_db_finish :: proc(statement:^sqlite.Stmt) -> bool {
    for {
        switch sqlite.step(statement) {
        case sqlite.ROW:  continue
        case sqlite.DONE: return true
        case:             return false
        }
    }
}

// Runs a statement that returns no rows, or whose rows are not read.
@(private)
ai_db_run :: proc(s:^Ai_Store,sql:string,values:..Ai_Db_Value) -> bool {
    statement,ok:=ai_db_prepare(s,sql,..values)
    if !ok {return false}
    defer sqlite.finalize(statement)
    return ai_db_finish(statement)
}

// Runs again a statement prepared before, with other values.
@(private="file")
ai_db_again :: proc(statement:^sqlite.Stmt,values:..Ai_Db_Value) -> bool {
    sqlite.reset(statement)
    return ai_db_bind(statement,..values) && ai_db_finish(statement)
}

// The integer of the first row of a statement, if it gives one.
@(private="file")
ai_db_value :: proc(s:^Ai_Store,sql:string,values:..Ai_Db_Value) -> (value:i64,found:bool,ok:bool) {
    statement,prepared:=ai_db_prepare(s,sql,..values)
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
ai_db_text :: proc(statement:^sqlite.Stmt,column:c.int) -> string {
    text:=sqlite.column_text(statement,column)
    bytes:=sqlite.column_bytes(statement,column)
    return string(text[:bytes]) if text!=nil else ""
}

@(private)
ai_db_clone :: proc(statement:^sqlite.Stmt,column:c.int,allocator:runtime.Allocator) -> string {
    return strings.clone(ai_db_text(statement,column),allocator)
}

@(private="file")
ai_db_exec :: proc(s:^Ai_Store,sql:cstring) -> bool {
    return sqlite.exec(s.db,sql,nil,nil,nil)==sqlite.OK
}

@(private="file")
ai_db_abort :: proc(s:^Ai_Store,what:string) -> string {
    message:=ai_db_fail(s,what)
    ai_db_exec(s,"ROLLBACK")
    return message
}

@(private)
ai_store_line_kind :: proc(value:i64) -> (kind:Ai_Line_Kind,ok:bool) {
    if value<0 || value>i64(max(Ai_Line_Kind)) {return}
    return Ai_Line_Kind(value),true
}

@(private="file")
ai_store_now :: proc() -> i64 {
    return time.to_unix_nanoseconds(time.now())/1_000_000
}

@(private="file")
ai_store_before :: proc(a,b:Ai_Conversation) -> bool {
    return a.updated_at>b.updated_at || a.updated_at==b.updated_at && a.id>b.id
}

// Puts c in its place of the order, replacing the conversation with its id.
@(private="file")
ai_store_place :: proc(s:^Ai_Store,c:^Ai_Conversation) -> bool {
    for &existing,index in s.conversations {
        if existing.id==c.id {ordered_remove(&s.conversations,index);break}
    }
    at:=len(s.conversations)
    for &existing,index in s.conversations {if ai_store_before(c^,existing) {at=index;break}}
    if _,error:=inject_at(&s.conversations,at,c^);error!=nil {return false}
    return true
}

@(private="file")
ai_store_row_write :: proc(s:^Ai_Store,c:^Ai_Conversation) -> bool {
    return ai_db_run(s,AI_STORE_CONVERSATION_UPSERT,i64(c.id),i64(c.kind),i64(c.parent),string(c.title[:c.title_len]),string(c.document[:c.document_len]),
        string(c.provider[:c.provider_len]),string(c.model[:c.model_len]),string(c.effort[:c.effort_len]),string(c.native_session[:c.native_session_len]),
        string(c.last[:c.last_len]),c.created_at,c.updated_at,f64(c.seconds),c.usage.input,c.usage.output,c.usage.cache_read,c.usage.cache_write,
        c.usage.total,c.usage.context_used,c.usage.context_size,c.usage.cost)
}

@(private="file")
ai_store_row_read :: proc(statement:^sqlite.Stmt) -> (c:Ai_Conversation,ok:bool) {
    kind:=sqlite.column_int64(statement,1)
    if kind<0 || kind>i64(max(Ai_Conversation_Kind)) {return}
    c={id=u64(sqlite.column_int64(statement,0)),kind=Ai_Conversation_Kind(kind),parent=u64(sqlite.column_int64(statement,2)),
        created_at=sqlite.column_int64(statement,10),updated_at=sqlite.column_int64(statement,11),seconds=f32(sqlite.column_double(statement,12)),
        usage={input=sqlite.column_int64(statement,13),output=sqlite.column_int64(statement,14),cache_read=sqlite.column_int64(statement,15),
            cache_write=sqlite.column_int64(statement,16),total=sqlite.column_int64(statement,17),context_used=sqlite.column_int64(statement,18),
            context_size=sqlite.column_int64(statement,19),cost=sqlite.column_double(statement,20)}}
    ok=ai_conversation_set_text(c.title[:],&c.title_len,ai_db_text(statement,3)) &&
        ai_conversation_set_text(c.document[:],&c.document_len,ai_db_text(statement,4)) &&
        ai_conversation_set_text(c.provider[:],&c.provider_len,ai_db_text(statement,5)) &&
        ai_conversation_set_text(c.model[:],&c.model_len,ai_db_text(statement,6)) &&
        ai_conversation_set_text(c.effort[:],&c.effort_len,ai_db_text(statement,7)) &&
        ai_conversation_set_text(c.native_session[:],&c.native_session_len,ai_db_text(statement,8)) &&
        ai_conversation_set_text(c.last[:],&c.last_len,ai_db_text(statement,9))
    return
}

// Reads the list again if another editor of the project wrote the database
// since the last time.
@(private="file")
ai_store_refresh :: proc(s:^Ai_Store) -> string {
    version,_,ok:=ai_db_value(s,"PRAGMA data_version")
    if !ok {return ai_db_fail(s,"Could not read the project chats")}
    if version==s.data_version {return ""}
    statement,prepared:=ai_db_prepare(s,"SELECT "+AI_STORE_CONVERSATION_COLUMNS+" FROM conversations WHERE reserved=0 ORDER BY updated_at DESC,id DESC")
    if !prepared {return ai_db_fail(s,"Could not read the project chats")}
    defer sqlite.finalize(statement)
    clear(&s.conversations)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {break}
        if code!=sqlite.ROW {s.data_version=-1;return ai_db_fail(s,"Could not read the project chats")}
        if c,valid:=ai_store_row_read(statement);valid {
            if _,error:=append(&s.conversations,c);error!=nil {s.data_version=-1;return ai_store_error(s,"No memory for the project chats")}
        }
    }
    s.data_version=version
    return ""
}

// Gives a new database its schema; two editors that open it at once take
// turns. A database of another version is reported and left as it is.
@(private="file")
ai_store_schema :: proc(s:^Ai_Store) -> string {
    version,_,ok:=ai_db_value(s,"PRAGMA user_version")
    if !ok {return ai_db_fail(s,"Could not open the project chat database")}
    if version==AI_STORE_VERSION {return ""}
    if version!=0 {return ai_store_error(s,fmt.tprintf("The project chat database has version %d and this editor reads version %d: use the editor that wrote it, or move .mirai/ai/chat.db and .mirai/ai/chats away to start a new history",version,AI_STORE_VERSION))}
    if !ai_db_exec(s,"BEGIN IMMEDIATE") {return ai_db_fail(s,"Could not create the project chat database")}
    version,_,ok=ai_db_value(s,"PRAGMA user_version")
    if !ok || version==0 && !ai_db_exec(s,AI_STORE_SCHEMA) || !ai_db_exec(s,"COMMIT") {return ai_db_abort(s,"Could not create the project chat database")}
    return ""
}

ai_store_open :: proc(s:^Ai_Store,root:string,allocator:=context.allocator) -> string {
    ai_store_close(s)
    s.error_len=0
    folder:=project.path(root,".mirai/ai/chats",allocator=context.temp_allocator)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return ai_store_error(s,"Could not create the project chat folder")}
    path:=strings.clone_to_cstring(project.path(root,".mirai/ai/chat.db",allocator=context.temp_allocator),context.temp_allocator)
    if sqlite.open_v2(path,&s.db,sqlite.OPEN_READWRITE|sqlite.OPEN_CREATE|sqlite.OPEN_NOMUTEX,nil)!=sqlite.OK {
        message:=ai_db_fail(s,"Could not open the project chat database")
        sqlite.close_v2(s.db);s.db=nil
        return message
    }
    sqlite.busy_timeout(s.db,AI_STORE_BUSY_MS)
    s.allocator=allocator
    s.folder=strings.clone(folder,allocator)
    s.conversations=make([dynamic]Ai_Conversation,allocator)
    s.data_version=-1
    message:=""
    if !ai_db_exec(s,"PRAGMA journal_mode=WAL") || !ai_db_exec(s,"PRAGMA synchronous=NORMAL") {
        message=ai_db_fail(s,"Could not open the project chat database")
    }
    if message=="" {message=ai_store_schema(s)}
    if message=="" {message=ai_store_refresh(s)}
    if message!="" {ai_store_close(s)}
    return message
}

ai_store_close :: proc(s:^Ai_Store) {
    if s.db!=nil {sqlite.close_v2(s.db);s.db=nil}
    if s.folder=="" {return}
    delete(s.folder,s.allocator)
    delete(s.conversations)
    s.folder,s.conversations={},{}
}

// Reserves the next identifier by inserting its row, which no list shows until
// it is saved, so that another editor of the same project does not take it.
ai_store_next_id :: proc(s:^Ai_Store) -> (id:u64,message:string) {
    if s.db==nil {return 0,ai_store_error(s,AI_STORE_NOT_OPEN)}
    value,found,ok:=ai_db_value(s,"INSERT INTO conversations(id,kind,reserved) SELECT coalesce(max(id),0)+1,?1,1 FROM conversations RETURNING id",
        i64(Ai_Conversation_Kind.Archived))
    if !ok || !found {return 0,ai_db_fail(s,"Could not reserve a chat identifier")}
    if value<=0 || value>=max(i64) {return 0,ai_store_error(s,"Chat identifiers are exhausted")}
    return u64(value),""
}

ai_store_save :: proc(s:^Ai_Store,c:^Ai_Conversation,t:^Ai_Transcript,first_sequence:int=-1) -> string {
    if s.db==nil {return ai_store_error(s,AI_STORE_NOT_OPEN)}
    if c.id==0 || c.id>=u64(max(i64)) {return ai_store_error(s,"Invalid chat identifier")}
    if last:=ai_transcript_last_answer(t);last!="" {
        plain:[AI_LAST_BYTES*2]u8
        c.last_len=copy(c.last[:],ai_utf8_cut(ai_entity_marks_plain(last,plain[:]),AI_LAST_BYTES))
    }
    if !ai_db_exec(s,"BEGIN IMMEDIATE") {return ai_db_fail(s,"Could not save the project chat")}
    upsert,done:=ai_db_prepare(s,AI_STORE_MESSAGE_UPSERT)
    if done {
        for index in 0..<t.count {
            if first_sequence>=0 && t.dropped+index<first_sequence {continue}
            text,kind:=ai_transcript_line(t,index)
            role:=kind==.Prompt?"user":kind==.Output?"assistant":"system"
            if !ai_db_again(upsert,i64(c.id),i64(t.dropped+index),i64(kind),text,role) {done=false;break}
        }
        sqlite.finalize(upsert)
    }
    if !done || !ai_store_row_write(s,c) || !ai_db_exec(s,"COMMIT") {return ai_db_abort(s,"Could not save the project chat")}
    if !ai_store_place(s,c) {return ai_store_error(s,"No memory for the project chats")}
    return ""
}

// Sets role, event type, tool and context of a message saved before.
ai_store_annotate :: proc(s:^Ai_Store,id,sequence:u64,role,event_type,tool,context_json:string) -> string {
    if s.db==nil {return ai_store_error(s,AI_STORE_NOT_OPEN)}
    if !ai_db_run(s,"UPDATE messages SET role=?1,event_type=?2,tool=?3,context_json=?4 WHERE conversation=?5 AND sequence=?6",role,event_type,tool,context_json,i64(id),i64(sequence)) {
        return ai_db_fail(s,"Could not save the project chat")
    }
    return ""
}

// The conversations whose titles have needle, or that found names. Without
// kinds, those of every kind; a parent keeps its own.
ai_store_list :: proc(s:^Ai_Store,out:[]Ai_Conversation,document_path:string="",offset:int=0,needle:string="",found:[]u64={},kinds:Ai_Conversation_Kinds={},parent:u64=0) -> (count:int,message:string) {
    if s.db==nil {return 0,ai_store_error(s,AI_STORE_NOT_OPEN)}
    if offset<0 {return 0,ai_store_error(s,"Invalid chat history offset")}
    if refresh:=ai_store_refresh(s);refresh!="" {return 0,refresh}
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

ai_store_find :: proc(s:^Ai_Store,id:u64) -> ^Ai_Conversation {
    if s.db==nil {return nil}
    ai_store_refresh(s)
    for &c in s.conversations {if c.id==id {return &c}}
    return nil
}

// The main chat of the project, nil until it has one.
ai_store_main :: proc(s:^Ai_Store) -> ^Ai_Conversation {
    if s.db==nil {return nil}
    ai_store_refresh(s)
    for &c in s.conversations {if c.kind==.Main {return &c}}
    return nil
}

// Fills t with the latest lines of the conversation it can hold.
ai_store_load :: proc(s:^Ai_Store,id:u64,t:^Ai_Transcript) -> string {
    if s.db==nil {return ai_store_error(s,AI_STORE_NOT_OPEN)}
    statement,ok:=ai_db_prepare(s,"SELECT sequence,kind,text FROM (SELECT sequence,kind,text FROM messages WHERE conversation=?1 ORDER BY sequence DESC LIMIT ?2) ORDER BY sequence",i64(id),i64(AI_TRANSCRIPT_LINES))
    if !ok {return ai_db_fail(s,"Could not read the project chat")}
    defer sqlite.finalize(statement)
    t^={}
    started:=false
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {return ""}
        if code!=sqlite.ROW {t^={};return ai_db_fail(s,"Could not read the project chat")}
        kind,valid:=ai_store_line_kind(sqlite.column_int64(statement,1))
        if !valid {continue}
        if !started {t.dropped=int(sqlite.column_int64(statement,0));started=true}
        ai_transcript_add(t,ai_db_text(statement,2),kind)
    }
}

// The messages right before a sequence, the latest ones if it is negative, in
// order.
ai_store_page :: proc(s:^Ai_Store,id:u64,before_sequence:i64,out:[]Ai_Stored_Line,allocator:=context.temp_allocator) -> (count:int,message:string) {
    if s.db==nil {return 0,ai_store_error(s,AI_STORE_NOT_OPEN)}
    end:=before_sequence if before_sequence>=0 else max(i64)
    statement,ok:=ai_db_prepare(s,"SELECT sequence,kind,text,role,event_type,tool,context_json FROM messages WHERE conversation=?1 AND sequence<?2 ORDER BY sequence DESC LIMIT ?3",i64(id),end,i64(len(out)))
    if !ok {return 0,ai_db_fail(s,"Could not read the project chat")}
    defer sqlite.finalize(statement)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {break}
        if code!=sqlite.ROW {return 0,ai_db_fail(s,"Could not read the project chat")}
        kind,valid:=ai_store_line_kind(sqlite.column_int64(statement,1))
        if !valid {continue}
        out[count]={sequence=u64(sqlite.column_int64(statement,0)),kind=kind,text=ai_db_clone(statement,2,allocator),role=ai_db_clone(statement,3,allocator),
            event_type=ai_db_clone(statement,4,allocator),tool=ai_db_clone(statement,5,allocator),context_json=ai_db_clone(statement,6,allocator)}
        count+=1
    }
    slice.reverse(out[:count])
    return count,""
}

// The sequence of the latest message marked as the turn of the user; -1 if none.
ai_store_latest_user_message :: proc(s:^Ai_Store,id:u64) -> i64 {
    if s.db==nil {return -1}
    value,found,ok:=ai_db_value(s,"SELECT sequence FROM messages WHERE conversation=?1 AND event_type='user_message' ORDER BY sequence DESC LIMIT 1",i64(id))
    return value if ok && found else -1
}

@(private="file")
ai_db_write :: proc(s:^Ai_Store,what,sql:string,values:..Ai_Db_Value) -> string {
    if s.db==nil {return ai_store_error(s,AI_STORE_NOT_OPEN)}
    if !ai_db_run(s,sql,..values) {return ai_db_fail(s,what)}
    return ""
}

// Inserts a row and gives its id.
@(private="file")
ai_db_insert :: proc(s:^Ai_Store,what,sql:string,values:..Ai_Db_Value) -> (id:i64,message:string) {
    if s.db==nil {return 0,ai_store_error(s,AI_STORE_NOT_OPEN)}
    value,found,ok:=ai_db_value(s,sql,..values)
    if !ok || !found {return 0,ai_db_fail(s,what)}
    return value,""
}

// The text of the first row of a statement, "" without one.
@(private="file")
ai_db_read_text :: proc(s:^Ai_Store,what,sql:string,allocator:runtime.Allocator,values:..Ai_Db_Value) -> (text:string,message:string) {
    if s.db==nil {return "",ai_store_error(s,AI_STORE_NOT_OPEN)}
    statement,ok:=ai_db_prepare(s,sql,..values)
    if !ok {return "",ai_db_fail(s,what)}
    defer sqlite.finalize(statement)
    switch sqlite.step(statement) {
    case sqlite.ROW:  return ai_db_clone(statement,0,allocator),""
    case sqlite.DONE: return "",""
    }
    return "",ai_db_fail(s,what)
}

ai_store_delivery_add :: proc(s:^Ai_Store,conversation:u64,kind,text:string) -> string {
    return ai_db_write(s,"Could not save the delivery","INSERT INTO deliveries(conversation,kind,text,created_at) VALUES(?1,?2,?3,?4)",i64(conversation),kind,text,ai_store_now())
}

// What waits to reach a conversation, the oldest first.
ai_store_deliveries :: proc(s:^Ai_Store,conversation:u64,allocator:=context.temp_allocator) -> (deliveries:[]Ai_Delivery,message:string) {
    if s.db==nil {return nil,ai_store_error(s,AI_STORE_NOT_OPEN)}
    statement,ok:=ai_db_prepare(s,"SELECT id,conversation,kind,text,created_at FROM deliveries WHERE conversation=?1 ORDER BY id",i64(conversation))
    if !ok {return nil,ai_db_fail(s,"Could not read the deliveries")}
    defer sqlite.finalize(statement)
    rows:=make([dynamic]Ai_Delivery,allocator)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {return rows[:],""}
        if code!=sqlite.ROW {return nil,ai_db_fail(s,"Could not read the deliveries")}
        append(&rows,Ai_Delivery{id=sqlite.column_int64(statement,0),conversation=u64(sqlite.column_int64(statement,1)),kind=ai_db_clone(statement,2,allocator),
            text=ai_db_clone(statement,3,allocator),created_at=sqlite.column_int64(statement,4)})
    }
}

ai_store_delivery_remove :: proc(s:^Ai_Store,id:i64) -> string {
    return ai_db_write(s,"Could not remove the delivery","DELETE FROM deliveries WHERE id=?1",id)
}

// The working notes of a conversation, "" without them.
ai_store_note_get :: proc(s:^Ai_Store,conversation:u64,allocator:=context.temp_allocator) -> (text:string,message:string) {
    return ai_db_read_text(s,"Could not read the chat notes","SELECT text FROM notes WHERE conversation=?1",allocator,i64(conversation))
}

ai_store_note_set :: proc(s:^Ai_Store,conversation:u64,text:string) -> string {
    return ai_db_write(s,"Could not save the chat notes","INSERT INTO notes(conversation,text,updated_at) VALUES(?1,?2,?3) ON CONFLICT(conversation) DO UPDATE SET text=excluded.text,updated_at=excluded.updated_at",i64(conversation),text,ai_store_now())
}

ai_store_pin_add :: proc(s:^Ai_Store,kind,ref,label:string) -> (id:i64,message:string) {
    return ai_db_insert(s,"Could not save the pin","INSERT INTO pins(kind,ref,label,created_at) VALUES(?1,?2,?3,?4) RETURNING id",kind,ref,label,ai_store_now())
}

ai_store_pins :: proc(s:^Ai_Store,allocator:=context.temp_allocator) -> (pins:[]Ai_Pin,message:string) {
    if s.db==nil {return nil,ai_store_error(s,AI_STORE_NOT_OPEN)}
    statement,ok:=ai_db_prepare(s,"SELECT id,kind,ref,label,created_at FROM pins ORDER BY id")
    if !ok {return nil,ai_db_fail(s,"Could not read the pins")}
    defer sqlite.finalize(statement)
    rows:=make([dynamic]Ai_Pin,allocator)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {return rows[:],""}
        if code!=sqlite.ROW {return nil,ai_db_fail(s,"Could not read the pins")}
        append(&rows,Ai_Pin{id=sqlite.column_int64(statement,0),kind=ai_db_clone(statement,1,allocator),ref=ai_db_clone(statement,2,allocator),
            label=ai_db_clone(statement,3,allocator),created_at=sqlite.column_int64(statement,4)})
    }
}

ai_store_pin_remove :: proc(s:^Ai_Store,id:i64) -> string {
    return ai_db_write(s,"Could not remove the pin","DELETE FROM pins WHERE id=?1",id)
}

ai_store_annotation_add :: proc(s:^Ai_Store,group_name,document:string,entity:u64,x,y,z:f64,text:string) -> (id:i64,message:string) {
    return ai_db_insert(s,"Could not save the annotation","INSERT INTO annotations(group_name,document,entity,x,y,z,text,created_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8) RETURNING id",
        group_name,document,i64(entity),x,y,z,text,ai_store_now())
}

ai_store_annotations :: proc(s:^Ai_Store,document:string,allocator:=context.temp_allocator) -> (annotations:[]Ai_Annotation,message:string) {
    if s.db==nil {return nil,ai_store_error(s,AI_STORE_NOT_OPEN)}
    statement,ok:=ai_db_prepare(s,"SELECT id,group_name,document,entity,x,y,z,text,created_at FROM annotations WHERE document=?1 ORDER BY id",document)
    if !ok {return nil,ai_db_fail(s,"Could not read the annotations")}
    defer sqlite.finalize(statement)
    rows:=make([dynamic]Ai_Annotation,allocator)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {return rows[:],""}
        if code!=sqlite.ROW {return nil,ai_db_fail(s,"Could not read the annotations")}
        append(&rows,Ai_Annotation{id=sqlite.column_int64(statement,0),group_name=ai_db_clone(statement,1,allocator),document=ai_db_clone(statement,2,allocator),
            entity=u64(sqlite.column_int64(statement,3)),x=sqlite.column_double(statement,4),y=sqlite.column_double(statement,5),z=sqlite.column_double(statement,6),
            text=ai_db_clone(statement,7,allocator),created_at=sqlite.column_int64(statement,8)})
    }
}

ai_store_annotation_remove :: proc(s:^Ai_Store,id:i64) -> string {
    return ai_db_write(s,"Could not remove the annotation","DELETE FROM annotations WHERE id=?1",id)
}

ai_store_annotation_set_text :: proc(s:^Ai_Store,id:i64,text:string) -> string {
    if s.db==nil {return ai_store_error(s,AI_STORE_NOT_OPEN)}
    _,found,ok:=ai_db_value(s,"UPDATE annotations SET text=?1 WHERE id=?2 RETURNING id",text,id)
    if !ok {return ai_db_fail(s,"Could not save the annotation")}
    if !found {return ai_store_error(s,fmt.tprintf("There is no annotation %d: list the annotations of the document",id))}
    return ""
}

ai_store_annotation_set_group :: proc(s:^Ai_Store,id:i64,group_name:string) -> string {
    if s.db==nil {return ai_store_error(s,AI_STORE_NOT_OPEN)}
    _,found,ok:=ai_db_value(s,"UPDATE annotations SET group_name=?1 WHERE id=?2 RETURNING id",group_name,id)
    if !ok {return ai_db_fail(s,"Could not save the annotation")}
    if !found {return ai_store_error(s,fmt.tprintf("There is no annotation %d: list the annotations of the document",id))}
    return ""
}

ai_store_provenance_set :: proc(s:^Ai_Store,ref_kind,ref:string,conversation,sequence:u64) -> string {
    return ai_db_write(s,"Could not save who changed it","INSERT INTO provenance(ref_kind,ref,conversation,sequence,at) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(ref_kind,ref) DO UPDATE SET conversation=excluded.conversation,sequence=excluded.sequence,at=excluded.at",
        ref_kind,ref,i64(conversation),i64(sequence),ai_store_now())
}

// All a transaction of a turn changed, in one write.
ai_store_provenance_record :: proc(s:^Ai_Store,refs:[]Ai_Provenance_Ref,conversation,sequence:u64) -> string {
    if s.db==nil {return ai_store_error(s,AI_STORE_NOT_OPEN)}
    if len(refs)==0 {return ""}
    if !ai_db_exec(s,"BEGIN IMMEDIATE") {return ai_db_fail(s,"Could not save who changed it")}
    for ref in refs {
        if message:=ai_store_provenance_set(s,ref.kind,ref.ref,conversation,sequence);message!="" {
            ai_db_exec(s,"ROLLBACK")
            return message
        }
    }
    if !ai_db_exec(s,"COMMIT") {return ai_db_abort(s,"Could not save who changed it")}
    return ""
}

ai_store_provenance_get :: proc(s:^Ai_Store,ref_kind,ref:string) -> (provenance:Ai_Provenance,found:bool,message:string) {
    if s.db==nil {return {},false,ai_store_error(s,AI_STORE_NOT_OPEN)}
    statement,ok:=ai_db_prepare(s,"SELECT conversation,sequence,at FROM provenance WHERE ref_kind=?1 AND ref=?2",ref_kind,ref)
    if !ok {return {},false,ai_db_fail(s,"Could not read who changed it")}
    defer sqlite.finalize(statement)
    switch sqlite.step(statement) {
    case sqlite.ROW:
        return {u64(sqlite.column_int64(statement,0)),u64(sqlite.column_int64(statement,1)),sqlite.column_int64(statement,2)},true,""
    case sqlite.DONE:
        return {},false,""
    }
    return {},false,ai_db_fail(s,"Could not read who changed it")
}

ai_store_meta_get :: proc(s:^Ai_Store,key:string,allocator:=context.temp_allocator) -> (value:string,message:string) {
    return ai_db_read_text(s,"Could not read the chat database","SELECT value FROM meta WHERE key=?1",allocator,key)
}

ai_store_meta_set :: proc(s:^Ai_Store,key,value:string) -> string {
    return ai_db_write(s,"Could not write the chat database","INSERT INTO meta(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",key,value)
}

ai_store_memory_upsert :: proc(s:^Ai_Store,path:string,modified_at:i64,text:string) -> string {
    return ai_db_write(s,"Could not index the memory document",`INSERT INTO memory_docs(path,modified_at,text) VALUES(?1,?2,?3)
ON CONFLICT(path) DO UPDATE SET modified_at=excluded.modified_at,text=excluded.text WHERE modified_at<>excluded.modified_at OR text<>excluded.text`,path,modified_at,text)
}

ai_store_memory_remove :: proc(s:^Ai_Store,path:string) -> string {
    return ai_db_write(s,"Could not remove the memory document","DELETE FROM memory_docs WHERE path=?1",path)
}

// The indexed documents by path.
ai_store_memory_list :: proc(s:^Ai_Store,allocator:=context.temp_allocator) -> (docs:[]Ai_Memory_Doc,message:string) {
    if s.db==nil {return nil,ai_store_error(s,AI_STORE_NOT_OPEN)}
    statement,ok:=ai_db_prepare(s,"SELECT path,modified_at FROM memory_docs ORDER BY path")
    if !ok {return nil,ai_db_fail(s,"Could not read the memory documents")}
    defer sqlite.finalize(statement)
    rows:=make([dynamic]Ai_Memory_Doc,allocator)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {return rows[:],""}
        if code!=sqlite.ROW {return nil,ai_db_fail(s,"Could not read the memory documents")}
        append(&rows,Ai_Memory_Doc{path=ai_db_clone(statement,0,allocator),modified_at=sqlite.column_int64(statement,1)})
    }
}
