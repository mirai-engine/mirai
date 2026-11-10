package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "mirai:editor/ai_store"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The memory of the agents, in Markdown that is versioned with the game: the
// short index AI_PROJECT_MEMORY and the file of the user go with the stable
// instructions, and the topics are read on demand. memory_docs is an index of
// the topics that can be rebuilt from the files.

AI_MEMORY_FOLDER :: ".agents/memory"       // of the project: one file per topic
AI_MEMORY_USER_FILE :: "USER.md"           // in the memory folder of the agents home
AI_MEMORY_INDEX_BYTES :: 8<<10             // of AI_PROJECT_MEMORY
AI_MEMORY_USER_BYTES :: 4<<10              // of the file of the user
AI_MEMORY_TOPIC_BYTES :: 16<<10            // of a topic
AI_MEMORY_INDEXED_BYTES :: 256<<10         // a larger file stays out of the index
AI_MEMORY_TOPIC_NAME :: 64                 // bytes of a topic, with its end
AI_MEMORY_DEFAULT_HITS :: 10

ai_memory_topics_folder :: proc(s:^Session) -> string {
    return project.path(s.project_root,AI_MEMORY_FOLDER,allocator=context.temp_allocator)
}

// Empty when the editor has no folder for the agents.
ai_memory_user_path :: proc(m:^Ai) -> string {
    home:=ai_agents_home(m)
    if home=="" {return ""}
    return project.path(home,"memory",AI_MEMORY_USER_FILE,allocator=context.temp_allocator)
}

// What a memory file holds, up to limit bytes and cut where a character starts.
@(private)
ai_memory_load :: proc(path:string,limit:int) -> (text:string,cut:bool) {
    file,error:=os.open(path)
    if error!=nil {return}
    defer os.close(file)
    buffer:=make([]u8,limit+1,context.temp_allocator)
    count:=0
    for count<len(buffer) {
        read,read_error:=os.read(file,buffer[count:])
        if read_error!=nil || read==0 {break}
        count+=read
    }
    text=string(buffer[:count])
    if count>limit {return ai_utf8_cut(text,limit),true}
    return text,false
}

// The index of the project and the file of the user, at the end of the stable instructions.
ai_memory_stable_write :: proc(s:^Session,b:^strings.Builder) {
    block :: proc(b:^strings.Builder,title,path:string,limit:int) {
        if path=="" {return}
        text,cut:=ai_memory_load(path,limit)
        text=strings.trim_space(text)
        if text=="" {return}
        fmt.sbprintf(b,"\n%s (%s):\n%s\n",title,path,text)
        if cut {fmt.sbprintf(b,"(cut at %d bytes: shorten this file with memory.save)\n",limit)}
    }
    block(b,"Memory of this project",project.path(s.project_root,AI_PROJECT_MEMORY,allocator=context.temp_allocator),AI_MEMORY_INDEX_BYTES)
    block(b,"Memory of this user, in every project",ai_memory_user_path(s.ai),AI_MEMORY_USER_BYTES)
}

// Brings the index up to the topic files by their modified time: at the start
// of the project and after each turn, also what was edited outside the editor.
ai_memory_scan :: proc(s:^Session) {
    m:=s.ai
    if m.store.db==nil || s.project_root=="" {return}
    indexed,problem:=ai_store.memory_list(&m.store)
    if problem!="" {notify(s,problem);return}
    known:=make(map[string]i64,context.temp_allocator)
    for &doc in indexed {known[doc.path]=doc.modified_at}
    entries,_:=os.read_all_directory_by_path(ai_memory_topics_folder(s),context.temp_allocator)
    for entry in entries {
        if entry.type==.Directory || !strings.has_suffix(entry.name,".md") || entry.size>AI_MEMORY_INDEXED_BYTES {continue}
        path:=fmt.tprintf("%s/%s",AI_MEMORY_FOLDER,entry.name)
        modified:=time.time_to_unix_nano(entry.modification_time)
        was,present:=known[path]
        delete_key(&known,path)
        if present && was==modified {continue}
        text,_:=ai_memory_load(entry.fullpath,AI_MEMORY_INDEXED_BYTES)
        if message:=ai_store.memory_upsert(&m.store,path,modified,text);message!="" {notify(s,message)}
    }
    for path in known {
        if message:=ai_store.memory_remove(&m.store,path);message!="" {notify(s,message)}
    }
}

// A topic is one name of file: no folders and nothing that could leave one.
@(private)
ai_memory_topic_check :: proc(topic:string) -> string {
    if len(topic)>=AI_MEMORY_TOPIC_NAME {return fmt.tprintf("The topic has %d bytes and holds at most %d",len(topic),AI_MEMORY_TOPIC_NAME-1)}
    for c in transmute([]u8)topic {
        if c>='a' && c<='z' || c>='0' && c<='9' || c=='-' || c=='_' {continue}
        return fmt.tprintf("The topic %q is not a slug: use lowercase letters, digits, - and _, without folders",topic)
    }
    return ""
}

// Replaces the file of a topic, the index of the project (no topic) or the
// file of the user. Gives the path, relative to the project if it is in it.
ai_memory_save :: proc(s:^Session,scope,topic,text:string) -> (path,message:string) {
    m:=s.ai
    limit:=AI_MEMORY_INDEX_BYTES
    full,name:string
    switch scope {
    case "project":
        if !s.has_project {return "","The editor has no project folder"}
        if topic=="" {
            name=AI_PROJECT_MEMORY
            full=project.path(s.project_root,AI_PROJECT_MEMORY,allocator=context.temp_allocator)
        } else {
            if problem:=ai_memory_topic_check(topic);problem!="" {return "",problem}
            limit=AI_MEMORY_TOPIC_BYTES
            name=fmt.tprintf("%s/%s.md",AI_MEMORY_FOLDER,topic)
            full=project.path(s.project_root,name,allocator=context.temp_allocator)
        }
    case "user":
        if topic!="" {return "","The memory of the user is one file: leave topic empty"}
        limit=AI_MEMORY_USER_BYTES
        full=ai_memory_user_path(m)
        if full=="" {return "","This editor has no folder for the agents"}
        name=full
    case:
        return "",fmt.tprintf("Unknown scope %q: use project or user",scope)
    }
    if len(text)>limit {
        return "",fmt.tprintf("The text has %d bytes and %s holds at most %d: split it into topics or shorten it",len(text),name,limit)
    }
    folder:=full[:max(strings.last_index_any(full,"/\\"),0)]
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return "",fmt.tprintf("The folder of %s could not be created",name)}
    if serial.file_write_atomic(full,transmute([]u8)text)!=.None {return "",fmt.tprintf("%s could not be written",name)}
    if topic!="" && scope=="project" {
        if info,error:=os.stat(full,context.temp_allocator);error==nil {
            if problem:=ai_store.memory_upsert(&m.store,name,time.time_to_unix_nano(info.modification_time),text);problem!="" {return name,problem}
        }
    }
    return name,""
}

// The file a path of memory.read names: a file right inside the topics of the
// project, relative to it, or inside the memory of the user. No other path.
@(private)
ai_memory_resolve :: proc(s:^Session,path:string) -> (full,message:string) {
    refused:=fmt.tprintf("%q is not a memory file: read %s/<topic>.md, as memory.search gives it, or the file of the user",path,AI_MEMORY_FOLDER)
    wanted,_:=strings.replace_all(path,"\\","/",context.temp_allocator)
    for part in strings.split(wanted,"/",context.temp_allocator) {if part==".." || part=="." {return "",refused}}
    if !strings.has_suffix(wanted,".md") {return "",refused}
    if !filepath.is_abs(wanted) {
        rest:=strings.trim_prefix(wanted,AI_MEMORY_FOLDER+"/")
        if len(rest)==len(wanted) || rest=="" || strings.contains(rest,"/") {return "",refused}
        return project.path(s.project_root,wanted,allocator=context.temp_allocator),""
    }
    user,_:=strings.replace_all(ai_memory_user_path(s.ai),"\\","/",context.temp_allocator)
    if user=="" || wanted!=user {return "",refused}
    return wanted,""
}

Ai_Memory_Search_Params :: struct {
    query:[512]u8 `mirai:"text,label=Words of the topics; all must be in one, OR between two takes either"`,
    limit:int `mirai:"optional,min=0,max=50,label=Hits to return; zero returns 10"`,
}
Ai_Memory_Search_Hit :: struct {
    path:[AI_PATH_BYTES]u8 `mirai:"text,label=What memory.read takes"`,
    snippet:[512]u8 `mirai:"text,label=Words around the matches, which go between **"`,
}
Ai_Memory_Search_Result :: struct {
    hits:[]Ai_Memory_Search_Hit `mirai:"label=The topics that match; the best first"`,
}
Ai_Memory_Read_Params :: struct {
    path:[AI_PATH_BYTES]u8 `mirai:"text,label=Of a topic as memory.search gives it; or the file of the user"`,
}
Ai_Memory_Read_Result :: struct {
    path:[AI_PATH_BYTES]u8 `mirai:"text"`,
    text:[AI_MEMORY_TOPIC_BYTES+1]u8 `mirai:"text"`,
    cut:bool `mirai:"label=The file is longer than this text"`,
}
Ai_Memory_Save_Params :: struct {
    scope:[8]u8 `mirai:"text,label=project (the game) or user (what holds in every project)"`,
    topic:[AI_MEMORY_TOPIC_NAME]u8 `mirai:"optional,text,label=A slug; empty with project replaces the short index of the project"`,
    text:[AI_MESSAGE_BYTES]u8 `mirai:"text,label=All of it: it replaces what was there"`,
}
Ai_Memory_Save_Result :: struct {
    path:[AI_PATH_BYTES]u8 `mirai:"text,label=The file it wrote"`,
}

@(private)
ai_memory_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="memory.search",summary="Full-text search of the topics of the memory of the project by their words, ranked by BM25; memory.read gives the one you want.",params=Ai_Memory_Search_Params,result=Ai_Memory_Search_Result,writes_result=true,flags={.Core,.Read_Only},run=ai_method_memory_search})
    api_register(s,st,{name="memory.read",summary="A topic of the memory of the project, or the file of the user.",params=Ai_Memory_Read_Params,result=Ai_Memory_Read_Result,writes_result=true,flags={.Core,.Read_Only},run=ai_method_memory_read})
    api_register(s,st,{name="memory.save",summary="Replaces a topic of the memory of the project, its short index, or the memory of the user, with one text that says how things are now.",params=Ai_Memory_Save_Params,result=Ai_Memory_Save_Result,flags={.Core},run=ai_method_memory_save})
}

@(private)
ai_method_memory_search :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    p:=api.call_params(call,Ai_Memory_Search_Params);w:=call.out
    hits:[ai_store.SEARCH_HITS]ai_store.Memory_Hit
    query:=base.text_get(p.query[:])
    if ai_store.index_match(query,false)=="" {api.call_fail(call,api.INVALID_PARAMS,ai_store.SEARCH_NO_WORDS);return}
    limit:=p.limit if p.limit>0 else AI_MEMORY_DEFAULT_HITS
    count,message:=ai_store.memory_search(&s.ai.store,query,hits[:min(limit,len(hits))],marks={"**","**"},allocator=call.allocator)
    if message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
    serial.text_write_raw(w,`{"hits":[`)
    for &hit,index in hits[:count] {
        if index>0 {serial.write_u8(w,',')}
        serial.write_u8(w,'{')
        api.write_text(w,"path",hit.path,true)
        api.write_text(w,"snippet",hit.snippet)
        serial.write_u8(w,'}')
    }
    serial.text_write_raw(w,"]}")
}

@(private)
ai_method_memory_read :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    path:=base.text_get(api.call_params(call,Ai_Memory_Read_Params).path[:])
    full,problem:=ai_memory_resolve(s,path)
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    if !os.is_file(full) {api.call_failf(call,api.INVALID_PARAMS,"%s does not exist: memory.search lists the topics",path);return}
    text,cut:=ai_memory_load(full,AI_MEMORY_TOPIC_BYTES)
    w:=call.out
    serial.write_u8(w,'{')
    api.write_text(w,"path",path,true)
    api.write_text(w,"text",text)
    api.write_bool(w,"cut",cut)
    serial.write_u8(w,'}')
}

@(private)
ai_method_memory_save :: proc(s:^Session,call:^api.Call) {
    ai_initialize(s)
    p:=api.call_params(call,Ai_Memory_Save_Params)
    path,message:=ai_memory_save(s,base.text_get(p.scope[:]),base.text_get(p.topic[:]),base.text_get(p.text[:]))
    if message!="" {api.call_fail(call,api.INVALID_PARAMS,message);return}
    base.text_set(api.call_result(call,Ai_Memory_Save_Result).path[:],path)
}
