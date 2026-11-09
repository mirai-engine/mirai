package editor

import "base:runtime"
import "core:strings"
import "core:unicode"
import "mirai:third_party/sqlite"

// The search of the chats and of the memory documents: FTS5 tables of
// .mirai/ai/chat.db that triggers keep up with what is written (ai_store.odin).
AI_SEARCH_HITS :: 50
AI_SEARCH_SNIPPET_WORDS :: 16
AI_HISTORY_HITS :: 256 // the lines a search of History reads, for the chats they are in
AI_SEARCH_NO_WORDS :: "The query has no words: pass words of the chats, an entity id or an asset path"

Ai_Search_Hit :: struct {
    conversation:u64,
    sequence:u64,
    kind:Ai_Line_Kind,
    snippet:string,
    score:f64, // BM25 as FTS5 gives it: the lower, the better
}

Ai_Memory_Hit :: struct {
    path:string,
    snippet:string,
    score:f64, // as in Ai_Search_Hit
}

// The FTS5 query of what a person or an agent typed: each word is a phrase,
// quoted so that no character is syntax, and all of them must be there; OR
// between two words takes either. An asset path or a method is a phrase of
// its parts, in order. With prefix the last word also matches the start of
// a longer one, as a search box that is being typed in does.
ai_index_match :: proc(query:string,prefix:bool,allocator:=context.temp_allocator) -> string {
    b:=strings.builder_make(allocator)
    rest:=query
    words:=0
    pending_or:=false
    for word in strings.fields_iterator(&rest) {
        if word=="OR" {pending_or=words>0;continue}
        searchable:=false
        // What FTS5 keeps of a word are its letters and numbers.
        for r in word {if unicode.is_letter(r) || unicode.is_number(r) {searchable=true;break}}
        if !searchable {continue}
        if words>0 {strings.write_string(&b," OR " if pending_or else " ")}
        pending_or=false
        strings.write_byte(&b,'"')
        for r in word {
            if r=='"' {strings.write_byte(&b,'"')}
            strings.write_rune(&b,r)
        }
        strings.write_byte(&b,'"')
        words+=1
    }
    if words==0 {return ""}
    if prefix {strings.write_byte(&b,'*')}
    return strings.to_string(b)
}

// The lines of the chats that match a query, the best first, each with a
// snippet whose matches go between the marks. With a conversation, only its
// own.
ai_store_search :: proc(s:^Ai_Store,query:string,out:[]Ai_Search_Hit,conversation:u64=0,prefix:=false,marks:=[2]string{"",""},allocator:=context.temp_allocator) -> (count:int,message:string) {
    if s.db==nil {return 0,ai_store_error(s,AI_STORE_NOT_OPEN)}
    match:=ai_index_match(query,prefix)
    if match=="" {return 0,AI_SEARCH_NO_WORDS}
    if len(out)==0 {return 0,""}
    statement,ok:=ai_db_prepare(s,`SELECT messages.conversation,messages.sequence,messages.kind,snippet(messages_fts,0,?2,?3,'…',?4),rank
FROM messages_fts JOIN messages ON messages.id=messages_fts.rowid
WHERE messages_fts MATCH ?1 AND (?5=0 OR messages.conversation=?5) ORDER BY rank LIMIT ?6`,
        match,marks[0],marks[1],i64(AI_SEARCH_SNIPPET_WORDS),i64(conversation),i64(len(out)))
    if !ok {return 0,ai_db_fail(s,"The chat search failed")}
    defer sqlite.finalize(statement)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {return count,""}
        if code!=sqlite.ROW {return 0,ai_db_fail(s,"The chat search failed")}
        kind,valid:=ai_store_line_kind(sqlite.column_int64(statement,2))
        if !valid {continue}
        out[count]={conversation=u64(sqlite.column_int64(statement,0)),sequence=u64(sqlite.column_int64(statement,1)),kind=kind,
            snippet=ai_db_clone(statement,3,allocator),score=sqlite.column_double(statement,4)}
        count+=1
    }
}

// The memory documents that match a query, with the rules of the chats.
ai_store_memory_search :: proc(s:^Ai_Store,query:string,out:[]Ai_Memory_Hit,prefix:=false,marks:=[2]string{"",""},allocator:runtime.Allocator=context.temp_allocator) -> (count:int,message:string) {
    if s.db==nil {return 0,ai_store_error(s,AI_STORE_NOT_OPEN)}
    match:=ai_index_match(query,prefix)
    if match=="" {return 0,AI_SEARCH_NO_WORDS}
    if len(out)==0 {return 0,""}
    statement,ok:=ai_db_prepare(s,`SELECT memory_docs.path,snippet(memory_docs_fts,0,?2,?3,'…',?4),rank
FROM memory_docs_fts JOIN memory_docs ON memory_docs.id=memory_docs_fts.rowid
WHERE memory_docs_fts MATCH ?1 ORDER BY rank LIMIT ?5`,
        match,marks[0],marks[1],i64(AI_SEARCH_SNIPPET_WORDS),i64(len(out)))
    if !ok {return 0,ai_db_fail(s,"The memory search failed")}
    defer sqlite.finalize(statement)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {return count,""}
        if code!=sqlite.ROW {return 0,ai_db_fail(s,"The memory search failed")}
        out[count]={path=ai_db_clone(statement,0,allocator),snippet=ai_db_clone(statement,1,allocator),score=sqlite.column_double(statement,2)}
        count+=1
    }
}
