package ai_store

import "core:mem"
import "mirai:third_party/sqlite"

// A write never waits for another editor of the project. It runs at once
// when the database is free and nothing waits before it; otherwise the store
// keeps it, with a copy of what it binds, and flush runs what it kept in the
// order it was written. What is read is what reached the database.

BUSY_MS :: 4         // what a write whose result is needed waits for the lock: a gesture asks for it, not every frame
OPEN_BUSY_MS :: 5000 // what opening and closing the store wait

BUSY :: "The project chat database is busy with another editor: try again"

@(private)
Statement :: struct {
    sql:string, // a constant of the package: a kept write points to it
    values:[]Db_Value,
}

// Its statements run in order, in one transaction when they are several.
@(private)
Write :: struct {
    what:string,                // of its failure, a constant of the package
    statements:[]Statement,
    conversation:^Conversation, // of a save: the row the list takes once it is written
}

@(private)
Kept_Write :: struct {
    using write:Write,
    block:[]u8, // all the write points to
}

@(private="file")
Write_Result :: enum u8 {Done,Busy,Failed}

@(private)
db_busy :: proc(s:^Store) -> bool {
    return sqlite.errcode(s.db)&0xff==sqlite.BUSY
}

@(private="file")
write_run :: proc(s:^Store,w:^Write) -> Write_Result {
    transaction:=len(w.statements)>1
    if transaction && !db_exec(s,"BEGIN IMMEDIATE") {
        if db_busy(s) {return .Busy}
        db_fail(s,w.what)
        return .Failed
    }
    prepared:^sqlite.Stmt
    prepared_sql:string
    result:=Write_Result.Done
    for &statement in w.statements {
        ok:=true
        if prepared==nil || raw_data(statement.sql)!=raw_data(prepared_sql) || len(statement.sql)!=len(prepared_sql) {
            if prepared!=nil {sqlite.finalize(prepared)}
            prepared,ok=db_prepare(s,statement.sql)
            prepared_sql=statement.sql
        } else {
            sqlite.reset(prepared)
        }
        if !ok || !db_bind(prepared,..statement.values) || !db_finish(prepared) {
            if db_busy(s) {result=.Busy} else {result=.Failed;db_fail(s,w.what)}
            break
        }
    }
    if prepared!=nil {sqlite.finalize(prepared)}
    if !transaction {return result}
    if result==.Done && !db_exec(s,"COMMIT") {
        if db_busy(s) {result=.Busy} else {result=.Failed;db_fail(s,w.what)}
    }
    if result!=.Done {db_exec(s,"ROLLBACK")}
    return result
}

@(private="file")
write_done :: proc(s:^Store,w:^Write) -> string {
    if w.conversation!=nil && !place(s,w.conversation) {return fail(s,"No memory for the project chats")}
    return ""
}

@(private="file")
write_keep :: proc(s:^Store,w:^Write) -> string {
    NO_MEMORY :: "No memory to keep a write of the project chats"
    size:=len(w.statements)*size_of(Statement)
    if w.conversation!=nil {size+=size_of(Conversation)}
    for &statement in w.statements {
        size+=len(statement.values)*size_of(Db_Value)
        for value in statement.values {
            if text,is_text:=value.(string);is_text {size+=len(text)}
        }
    }
    block,error:=mem.alloc_bytes_non_zeroed(size,align_of(Conversation),s.allocator)
    if error!=nil {return fail(s,NO_MEMORY)}
    kept:=Kept_Write{block=block}
    kept.what=w.what
    at:=0
    if w.conversation!=nil {
        kept.conversation=(^Conversation)(raw_data(block))
        kept.conversation^=w.conversation^
        at+=size_of(Conversation)
    }
    kept.statements=mem.slice_ptr((^Statement)(raw_data(block[at:])),len(w.statements))
    at+=len(w.statements)*size_of(Statement)
    for &statement,index in w.statements {
        values:=mem.slice_ptr((^Db_Value)(raw_data(block[at:])),len(statement.values))
        at+=len(statement.values)*size_of(Db_Value)
        copy(values,statement.values)
        kept.statements[index]={sql=statement.sql,values=values}
    }
    for &statement in kept.statements {
        for &value in statement.values {
            if text,is_text:=value.(string);is_text {
                count:=copy(block[at:],text)
                value=string(block[at:][:count])
                at+=count
            }
        }
    }
    if _,append_error:=append(&s.kept,kept);append_error!=nil {
        delete(block,s.allocator)
        return fail(s,NO_MEMORY)
    }
    return ""
}

// Runs the write, or keeps it when the database is busy or others wait: an
// empty message says it will reach the database, not that it did.
@(private)
write :: proc(s:^Store,w:^Write) -> string {
    if s.db==nil {return fail(s,NOT_OPEN)}
    if len(s.kept)==0 {
        switch write_run(s,w) {
        case .Done:   return write_done(s,w)
        case .Failed: return string(s.error[:s.error_len])
        case .Busy:
        }
    }
    return write_keep(s,w)
}

// Runs what was kept, the oldest first, until the database is busy. A write
// that fails stays kept and is reported: the next flush tries it again.
flush :: proc(s:^Store) -> string {
    for len(s.kept)>0 {
        w:=&s.kept[0]
        switch write_run(s,w) {
        case .Busy:   return ""
        case .Failed: return string(s.error[:s.error_len])
        case .Done:
        }
        message:=write_done(s,w)
        delete(w.block,s.allocator)
        ordered_remove(&s.kept,0)
        s.landed+=1
        if message!="" {return message}
    }
    return ""
}

// The writes kept for flush.
pending :: proc(s:^Store) -> int {
    return len(s.kept)
}

// For a write whose result is needed now: true when nothing waits before it.
@(private)
write_ready :: proc(s:^Store) -> bool {
    if len(s.kept)>0 {flush(s)}
    return len(s.kept)==0
}
