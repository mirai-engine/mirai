package ai_store

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:project"
import "mirai:std/base"
import "mirai:third_party/sqlite"

@(private="file")
test_add :: proc(lines:^[dynamic]Line,text:string,kind:Line_Kind=.Output) {
    append(lines,Line{sequence=u64(len(lines)),kind=kind,text=text})
}

@(private="file")
test_conversation :: proc(id:u64,document:string) -> Conversation {
    c:=Conversation{id=id,created_at=100,updated_at=200}
    conversation_set_text(c.title[:],&c.title_len,"Player questions")
    conversation_set_text(c.document[:],&c.document_len,document)
    conversation_set_text(c.provider[:],&c.provider_len,"codex")
    conversation_set_text(c.model[:],&c.model_len,"gpt-6-luna")
    conversation_set_text(c.effort[:],&c.effort_len,"low")
    conversation_set_text(c.native_session[:],&c.native_session_len,"native-session-1")
    return c
}

@(test)
reopens_chats_with_metadata_and_changed_stream_text :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-store-roundtrip")
    if root=="" {return}
    store:Store
    defer close(&store)
    testing.expect_value(t,open(&store,root),"")
    id,message:=next_id(&store)
    testing.expect_value(t,message,"")
    testing.expect_value(t,id,u64(1))
    c:=test_conversation(id,"scene/main.scene")
    // What the agent spent comes back with the chat.
    c.seconds,c.usage=12.5,{input=1200,output=340,cache_read=9000,total=10540,context_used=48000,context_size=200000,cost=0.25}
    transcript:=make([dynamic]Line,context.temp_allocator)
    test_add(&transcript,"What's the player's health? '; DROP TABLE conversations; --",.Prompt)
    test_add(&transcript,"The player",.Output)
    testing.expect_value(t,save(&store,&c,transcript[:]),"")
    testing.expect_value(t,annotate(&store,id,0,"user","context","",`{"player":4}`),"")
    clear(&transcript)
    test_add(&transcript,"What's the player's health? '; DROP TABLE conversations; --",.Prompt)
    test_add(&transcript,"The player's health is 100.",.Output)
    c.updated_at=300
    conversation_set_text(c.last[:],&c.last_len,"The player's health is 100.")
    testing.expect_value(t,save(&store,&c,transcript[1:]),"")
    close(&store)
    testing.expect(t,os.is_file(project.path(root,".mirai/ai/chat.db",allocator=context.temp_allocator)))
    testing.expect_value(t,open(&store,root),"")
    conversations:[8]Conversation
    count,list_message:=list(&store,conversations[:])
    testing.expect_value(t,list_message,"")
    testing.expect_value(t,count,1)
    testing.expect_value(t,conversations[0],c)
    restored:[8]Line
    restored_count,load_message:=load(&store,id,restored[:])
    testing.expect_value(t,load_message,"")
    testing.expect_value(t,restored_count,2)
    testing.expect_value(t,restored[0].sequence,u64(0))
    testing.expect_value(t,restored[1].text,"The player's health is 100.")
    testing.expect_value(t,restored[1].kind,Line_Kind.Output)
    lines:[4]Stored_Line
    line_count,page_message:=page(&store,id,-1,lines[:])
    testing.expect_value(t,page_message,"")
    testing.expect_value(t,line_count,2)
    testing.expect_value(t,lines[0].role,"user")
    testing.expect_value(t,lines[0].event_type,"context")
    testing.expect_value(t,lines[0].context_json,`{"player":4}`)
    following,next_message:=next_id(&store)
    testing.expect_value(t,next_message,"")
    testing.expect_value(t,following,u64(2))
}

@(test)
filters_documents_and_keeps_projects_isolated :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-store-isolation")
    if root=="" {return}
    first,second:Store
    defer close(&first)
    defer close(&second)
    testing.expect_value(t,open(&first,project.path(root,"one",allocator=context.temp_allocator)),"")
    testing.expect_value(t,open(&second,project.path(root,"two",allocator=context.temp_allocator)),"")
    transcript:=make([dynamic]Line,context.temp_allocator)
    test_add(&transcript,"Hello",.Prompt)
    a:=test_conversation(1,"scene/one.scene")
    b:=test_conversation(2,"scene/two.scene")
    testing.expect_value(t,save(&first,&a,transcript[:]),"")
    testing.expect_value(t,save(&first,&b,transcript[:]),"")
    conversations:[8]Conversation
    count,message:=list(&first,conversations[:],"scene/two.scene")
    testing.expect_value(t,message,"")
    testing.expect_value(t,count,1)
    testing.expect_value(t,conversations[0].id,u64(2))
    count,message=list(&second,conversations[:])
    testing.expect_value(t,message,"")
    testing.expect_value(t,count,0)
    following,next_message:=next_id(&first)
    testing.expect_value(t,next_message,"")
    testing.expect_value(t,following,u64(3))
    other_id,other_message:=next_id(&second)
    testing.expect_value(t,other_message,"")
    testing.expect_value(t,other_id,u64(1))
}

@(test)
preserves_messages_beyond_what_a_load_holds :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-store-retention")
    if root=="" {return}
    store:Store
    defer close(&store)
    testing.expect_value(t,open(&store,root),"")
    c:=test_conversation(1,"scene/main.scene")
    transcript:=make([dynamic]Line,context.temp_allocator)
    for index in 0..<900 {
        test_add(&transcript,fmt.tprintf("Line %04d: a long streamed transcript keeps its complete earlier history in the project database.",index))
        if (index+1)%40==0 {testing.expect_value(t,save(&store,&c,transcript[index-39:]),"")}
    }
    testing.expect_value(t,save(&store,&c,transcript[880:]),"")
    testing.expect_value(t,annotate(&store,1,895,"assistant","tool_call","mirai.scene.inspect",`{"selection":[1]}`),"")
    testing.expect_value(t,save(&store,&c,transcript[880:]),"")
    close(&store)
    testing.expect_value(t,open(&store,root),"")
    restored:[64]Line
    restored_count,load_message:=load(&store,1,restored[:])
    testing.expect_value(t,load_message,"")
    testing.expect_value(t,restored_count,len(restored))
    testing.expect_value(t,restored[0].sequence,u64(900-len(restored)))
    testing.expect(t,strings.has_prefix(restored[len(restored)-1].text,"Line 0899:"))
    old:[16]Stored_Line
    count,message:=page(&store,1,10,old[:])
    testing.expect_value(t,message,"")
    testing.expect_value(t,count,10)
    testing.expect_value(t,old[0].sequence,u64(0))
    testing.expect(t,strings.has_prefix(old[0].text,"Line 0000:"))
    testing.expect_value(t,old[9].sequence,u64(9))
    latest:[16]Stored_Line
    count,message=page(&store,1,-1,latest[:])
    testing.expect_value(t,message,"")
    testing.expect_value(t,count,16)
    testing.expect_value(t,latest[11].sequence,u64(895))
    testing.expect_value(t,latest[11].tool,"mirai.scene.inspect")
    testing.expect_value(t,latest[11].context_json,`{"selection":[1]}`)
}

@(private="file")
test_hits :: proc(t:^testing.T,store:^Store,query:string,conversation:u64=0) -> []Search_Hit {
    hits:=make([]Search_Hit,8,context.temp_allocator)
    count,message:=search(store,query,hits,conversation,marks={"[","]"})
    testing.expectf(t,message=="","search %q: %s",query,message)
    return hits[:count]
}

@(test)
search_finds_words_ids_and_paths_ranked :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-store-search")
    if root=="" {return}
    store:Store
    defer close(&store)
    testing.expect_value(t,open(&store,root),"")
    a:=test_conversation(1,"scene/main.scene")
    transcript:=make([dynamic]Line,context.temp_allocator)
    test_add(&transcript,"Hang a lantern over the door",.Prompt)
    test_add(&transcript,"The player",.Output)
    test_add(&transcript,"Tool: scene.set Crate · ref 0x000000010000002a materials/floor.mat · +0.4 s · 2.0 ms",.Note)
    testing.expect_value(t,save(&store,&a,transcript[:]),"")
    // The stream grows a line already saved: its later record replaces it.
    clear(&transcript)
    test_add(&transcript,"Hang a lantern over the door",.Prompt)
    test_add(&transcript,"The player's lantern, the lantern of the quest, hangs at the door.",.Output)
    testing.expect_value(t,save(&store,&a,transcript[1:]),"")
    b:=test_conversation(2,"scene/main.scene")
    clear(&transcript)
    test_add(&transcript,"Is there a lantern among the many props that the cellar of the old house keeps for later?",.Prompt)
    testing.expect_value(t,save(&store,&b,transcript[:]),"")

    hits:=test_hits(t,&store,"lantern")
    testing.expect_value(t,len(hits),3)
    if len(hits)==3 {
        testing.expect(t,hits[0].conversation==1 && hits[0].sequence==1 && hits[0].kind==.Output,"the line that says it most, and short, ranks first")
        testing.expect(t,hits[0].score<=hits[1].score && hits[1].score<=hits[2].score)
        testing.expect(t,hits[2].conversation==2,"a long line that says it once ranks last")
        testing.expectf(t,strings.contains(hits[0].snippet,"[lantern]"),"the snippet marks what matched, got %q",hits[0].snippet)
    }
    hits=test_hits(t,&store,"player")
    testing.expect(t,len(hits)==1 && strings.contains(hits[0].snippet,"quest"),"a replaced line is indexed once, with its latest text")
    hits=test_hits(t,&store,"0x000000010000002a")
    testing.expect(t,len(hits)==1 && hits[0].kind==.Note && hits[0].sequence==2,"a tool note is found by the id of its entity")
    hits=test_hits(t,&store,"materials/floor.mat")
    testing.expect(t,len(hits)==1 && hits[0].sequence==2,"and by the path of its asset")
    hits=test_hits(t,&store,"scene.set")
    testing.expect(t,len(hits)==1,"and by its method")
    hits=test_hits(t,&store,"lantern",2)
    testing.expect(t,len(hits)==1 && hits[0].conversation==2,"a conversation narrows the search to its own lines")
    hits=test_hits(t,&store,"door cellar")
    testing.expect_value(t,len(hits),0)
    hits=test_hits(t,&store,"door OR cellar")
    testing.expect_value(t,len(hits),3)
    hits=test_hits(t,&store,"dragon")
    testing.expect_value(t,len(hits),0)
    prefixed:[4]Search_Hit
    count,message:=search(&store,"lant",prefixed[:],prefix=true)
    testing.expect(t,message=="" && count==3,"a prefix matches the start of a word")
    for query in ([]string{"",`"; DROP TABLE line; --`,"  · - "}) {
        count,message=search(&store,query,prefixed[:])
        if query==`"; DROP TABLE line; --` {
            testing.expect(t,message=="" && count==0,"quotes and SQL in a query are words")
        } else {
            testing.expect_value(t,message,SEARCH_NO_WORDS)
        }
    }
}

@(test)
search_follows_saves_and_reopening :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-store-search-saves")
    if root=="" {return}
    store:Store
    defer close(&store)
    testing.expect_value(t,open(&store,root),"")
    c:=test_conversation(1,"scene/main.scene")
    transcript:=make([dynamic]Line,context.temp_allocator)
    test_add(&transcript,"Paint the barn red",.Prompt)
    testing.expect_value(t,save(&store,&c,transcript[:]),"")
    testing.expect_value(t,len(test_hits(t,&store,"barn")),1)
    testing.expect_value(t,len(test_hits(t,&store,"windmill")),0)
    test_add(&transcript,"The windmill turns by the barn now.",.Output)
    testing.expect_value(t,save(&store,&c,transcript[1:]),"")
    testing.expect_value(t,len(test_hits(t,&store,"windmill")),1)
    testing.expect_value(t,len(test_hits(t,&store,"barn")),2)
    close(&store)
    testing.expect_value(t,open(&store,root),"")
    testing.expect_value(t,len(test_hits(t,&store,"barn")),2)
}

@(test)
reports_a_corrupt_database_and_keeps_it :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-store-corrupt")
    if root=="" {return}
    path:=project.path(root,".mirai/ai/chat.db",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(project.path(root,".mirai/ai",allocator=context.temp_allocator))==nil)
    garbage:=strings.repeat("not a database ",512,context.temp_allocator)
    testing.expect(t,os.write_entire_file(path,garbage)==nil)
    store:Store
    defer close(&store)
    message:=open(&store,root)
    testing.expect(t,message!="","a file that is no database is reported")
    testing.expect_value(t,string(store.error[:store.error_len]),message)
    testing.expect_value(t,store.folder,"")
    kept,error:=os.read_entire_file(path,context.temp_allocator)
    testing.expect(t,error==nil && string(kept)==garbage,"and stays as it was")
}

@(test)
keeps_each_new_table :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-store-tables")
    if root=="" {return}
    store:Store
    defer close(&store)
    testing.expect_value(t,open(&store,root),"")

    testing.expect_value(t,delivery_add(&store,1,"report","Agent 4 is done"),"")
    testing.expect_value(t,delivery_add(&store,2,"report","Another chat"),"")
    waiting,message:=deliveries(&store,1)
    testing.expect_value(t,message,"")
    testing.expect(t,len(waiting)==1 && waiting[0].kind=="report" && waiting[0].text=="Agent 4 is done")
    testing.expect_value(t,delivery_remove(&store,waiting[0].id),"")
    waiting,message=deliveries(&store,1)
    testing.expect(t,message=="" && len(waiting)==0)

    note:string
    note,message=note_get(&store,1)
    testing.expect(t,message=="" && note=="")
    testing.expect_value(t,note_set(&store,1,"first"),"")
    testing.expect_value(t,note_set(&store,1,"second"),"")
    note,message=note_get(&store,1)
    testing.expect(t,message=="" && note=="second")

    testing.expect_value(t,pin_add(&store,"asset","materials/floor.mat","Floor"),"")
    pinned,pins_message:=pins(&store)
    testing.expect(t,pins_message=="" && len(pinned)==1 && pinned[0].ref=="materials/floor.mat" && pinned[0].label=="Floor")
    if len(pinned)==1 {testing.expect_value(t,pin_remove(&store,pinned[0].id),"")}
    pinned,pins_message=pins(&store)
    testing.expect(t,pins_message=="" && len(pinned)==0)

    note_id,note_message:=annotation_add(&store,"lights","scene/main.scene",0x1_0000_002a,1.5,2,-3,"Too dark")
    testing.expect_value(t,note_message,"")
    _,_=annotation_add(&store,"lights","scene/other.scene",1,0,0,0,"Elsewhere")
    testing.expect_value(t,annotation_set_text(&store,note_id,"Brighter"),"")
    testing.expect_value(t,annotation_set_group(&store,note_id,"shadows"),"")
    notes,annotations_message:=annotations(&store,"scene/main.scene")
    testing.expect(t,annotations_message=="" && len(notes)==1)
    if len(notes)==1 {
        a:=notes[0]
        testing.expect(t,a.group_name=="shadows" && a.entity==0x1_0000_002a && a.x==1.5 && a.y==2 && a.z==-3 && a.text=="Brighter")
    }
    testing.expect(t,annotation_set_group(&store,note_id+100,"lost")!="","a missing annotation is an error")
    testing.expect(t,annotation_set_text(&store,note_id+100,"Lost")!="","a missing annotation is an error")
    testing.expect_value(t,annotation_remove(&store,note_id),"")
    notes,annotations_message=annotations(&store,"scene/main.scene")
    testing.expect(t,annotations_message=="" && len(notes)==0)

    _,found,provenance_message:=provenance_get(&store,"asset","materials/floor.mat")
    testing.expect(t,provenance_message=="" && !found)
    testing.expect_value(t,provenance_set(&store,"asset","materials/floor.mat",1,5),"")
    testing.expect_value(t,provenance_set(&store,"asset","materials/floor.mat",2,9),"")
    provenance:Provenance
    provenance,found,provenance_message=provenance_get(&store,"asset","materials/floor.mat")
    testing.expect(t,provenance_message=="" && found && provenance.conversation==2 && provenance.sequence==9 && provenance.at>0)

    testing.expect_value(t,meta_set(&store,"handoff","1"),"")
    testing.expect_value(t,meta_set(&store,"handoff","2"),"")
    value,meta_message:=meta_get(&store,"handoff")
    testing.expect(t,meta_message=="" && value=="2")
    value,meta_message=meta_get(&store,"missing")
    testing.expect(t,meta_message=="" && value=="")

    testing.expect_value(t,memory_upsert(&store,".agents/memory/combat.md",10,"The sword swings with a long arc"),"")
    testing.expect_value(t,memory_upsert(&store,".agents/memory/world.md",11,"The harbor has a lantern"),"")
    testing.expect_value(t,memory_upsert(&store,".agents/memory/combat.md",12,"The axe swings with a short arc"),"")
    docs,docs_message:=memory_list(&store)
    testing.expect(t,docs_message=="" && len(docs)==2 && docs[0].path==".agents/memory/combat.md" && docs[0].modified_at==12)
    hits:[4]Memory_Hit
    count,search_message:=memory_search(&store,"axe OR harbor",hits[:],marks={"[","]"})
    testing.expect(t,search_message=="" && count==2,"OR takes either word")
    count,search_message=memory_search(&store,"sword",hits[:])
    testing.expect(t,search_message=="" && count==0,"a replaced document is indexed with its latest text")
    count,search_message=memory_search(&store,"lant",hits[:],prefix=true,marks={"[","]"})
    testing.expect(t,search_message=="" && count==1 && hits[0].path==".agents/memory/world.md" && strings.contains(hits[0].snippet,"[lantern]"))
    _,search_message=memory_search(&store,"  · - ",hits[:])
    testing.expect_value(t,search_message,SEARCH_NO_WORDS)
    testing.expect_value(t,memory_remove(&store,".agents/memory/world.md"),"")
    count,search_message=memory_search(&store,"harbor",hits[:])
    testing.expect(t,search_message=="" && count==0)
}

@(test)
lists_by_kind_and_parent_and_finds_the_main_chat :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-store-kinds")
    if root=="" {return}
    store:Store
    defer close(&store)
    testing.expect_value(t,open(&store,root),"")
    testing.expect(t,main_conversation(&store)==nil)
    transcript:=make([dynamic]Line,context.temp_allocator)
    test_add(&transcript,"Hello",.Prompt)
    rows:=[?]struct {id:u64,kind:Conversation_Kind,parent:u64}{{1,.Main,0},{2,.Agent,1},{3,.Agent,9},{4,.Archived,0}}
    for row in rows {
        c:=test_conversation(row.id,"scene/main.scene")
        c.kind,c.parent=row.kind,row.parent
        testing.expect_value(t,save(&store,&c,transcript[:]),"")
    }
    close(&store)
    testing.expect_value(t,open(&store,root),"")
    main_chat:=main_conversation(&store)
    testing.expect(t,main_chat!=nil && main_chat.id==1)
    listed:[8]Conversation
    count,message:=list(&store,listed[:])
    testing.expect(t,message=="" && count==4,"without a restriction, every kind")
    count,message=list(&store,listed[:],kinds={.Agent})
    testing.expect(t,message=="" && count==2)
    count,message=list(&store,listed[:],kinds={.Agent},parent=1)
    testing.expect(t,message=="" && count==1 && listed[0].id==2 && listed[0].parent==1 && listed[0].kind==.Agent)
    count,message=list(&store,listed[:],kinds={.Main,.Archived})
    testing.expect(t,message=="" && count==2)
}

@(test)
shares_the_project_with_another_open_store :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-store-shared")
    if root=="" {return}
    first,second:Store
    defer close(&first)
    defer close(&second)
    testing.expect_value(t,open(&first,root),"")
    testing.expect_value(t,open(&second,root),"")
    id,message:=next_id(&first)
    testing.expect_value(t,message,"")
    other,other_message:=next_id(&second)
    testing.expect_value(t,other_message,"")
    testing.expect(t,id!=other,"two editors never take the same identifier")
    listed:[4]Conversation
    count,list_message:=list(&second,listed[:])
    testing.expect(t,list_message=="" && count==0,"a reserved identifier is no conversation yet")

    c:=test_conversation(id,"scene/main.scene")
    transcript:=make([dynamic]Line,context.temp_allocator)
    test_add(&transcript,"Raise the lighthouse",.Prompt)
    testing.expect_value(t,save(&first,&c,transcript[:]),"")
    count,list_message=list(&second,listed[:])
    testing.expect(t,list_message=="" && count==1 && listed[0].id==id,"the other editor lists what the first saved")
    testing.expect(t,find(&second,id)!=nil)
    testing.expect_value(t,len(test_hits(t,&second,"lighthouse")),1)
    testing.expect_value(t,annotate(&second,id,0,"user","user_message","","{}"),"")
    lines:[4]Stored_Line
    line_count,page_message:=page(&first,id,-1,lines[:])
    testing.expect(t,page_message=="" && line_count==1 && lines[0].event_type=="user_message","and the first reads what the other wrote")
}

@(test)
a_write_does_not_wait_for_another_editor_and_lands_in_order :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-store-busy")
    if root=="" {return}
    store:Store
    defer close(&store)
    testing.expect_value(t,open(&store,root),"")
    // Another editor of the project, in a write that does not end.
    other:^sqlite.Db
    path:=strings.clone_to_cstring(project.path(root,".mirai/ai/chat.db",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,sqlite.open_v2(path,&other,sqlite.OPEN_READWRITE|sqlite.OPEN_NOMUTEX,nil)==sqlite.OK)
    defer sqlite.close_v2(other)
    testing.expect(t,sqlite.exec(other,"BEGIN IMMEDIATE",nil,nil,nil)==sqlite.OK)

    c:=test_conversation(1,"scene/main.scene")
    text:=strings.clone("Raise the lighthouse",context.temp_allocator)
    transcript:=make([dynamic]Line,context.temp_allocator)
    test_add(&transcript,text,.Prompt)
    started:=time.tick_now()
    _,reserved:=next_id(&store)
    testing.expect_value(t,reserved,BUSY)
    testing.expect_value(t,save(&store,&c,transcript[:]),"")
    testing.expect_value(t,annotate(&store,1,0,"user","user_message","","{}"),"")
    testing.expect_value(t,note_set(&store,1,"first"),"")
    testing.expect_value(t,note_set(&store,1,"second"),"")
    _,reserved=next_id(&store)
    testing.expect_value(t,reserved,BUSY)
    testing.expect_value(t,flush(&store),"")
    testing.expect(t,time.tick_since(started)<OPEN_BUSY_MS*time.Millisecond/2,"no write waited for the other editor")
    testing.expect_value(t,pending(&store),4)
    // A kept write holds its own copy of what it binds.
    for &b in transmute([]u8)text {b='x'}
    conversation_set_text(c.title[:],&c.title_len,"Renamed later")

    listed:[4]Conversation
    count,_:=list(&store,listed[:])
    testing.expect(t,count==0 && find(&store,1)==nil,"what is read is what reached the database")

    testing.expect(t,sqlite.exec(other,"COMMIT",nil,nil,nil)==sqlite.OK)
    testing.expect_value(t,flush(&store),"")
    testing.expect_value(t,pending(&store),0)
    testing.expect_value(t,store.landed,u64(4))
    count,_=list(&store,listed[:])
    testing.expect(t,count==1 && string(listed[0].title[:listed[0].title_len])=="Player questions")
    lines:[4]Stored_Line
    line_count,_:=page(&store,1,-1,lines[:])
    testing.expect(t,line_count==1 && lines[0].text=="Raise the lighthouse")
    testing.expect(t,line_count==1 && lines[0].event_type=="user_message","the annotation ran after the save of its line")
    note,_:=note_get(&store,1)
    testing.expect_value(t,note,"second")

    // Closing waits for the other editor, so that what was kept is not lost.
    testing.expect(t,sqlite.exec(other,"BEGIN IMMEDIATE",nil,nil,nil)==sqlite.OK)
    testing.expect_value(t,note_set(&store,1,"third"),"")
    testing.expect_value(t,pending(&store),1)
    testing.expect(t,sqlite.exec(other,"COMMIT",nil,nil,nil)==sqlite.OK)
    close(&store)
    testing.expect_value(t,open(&store,root),"")
    note,_=note_get(&store,1)
    testing.expect_value(t,note,"third")
}

// Each save of a chat is a transaction of the database in WAL mode: an
// editor that dies after it leaves it whole on the disk, and loses only the
// write it kept for later; one that closes writes that write too.
@(test)
a_chat_survives_an_editor_that_dies_between_saves :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-store-crash")
    if root=="" {return}
    store:Store
    defer close(&store)
    testing.expect_value(t,open(&store,root),"")
    c:=test_conversation(1,"scene/main.scene")
    transcript:=make([dynamic]Line,context.temp_allocator)
    test_add(&transcript,"Build a harbor",.Prompt)
    testing.expect_value(t,save(&store,&c,transcript[:]),"")
    test_add(&transcript,"The harbor has a pier and a lighthouse.")
    testing.expect_value(t,save(&store,&c,transcript[1:]),"")
    // Another editor holds the database: the next save is kept.
    other:^sqlite.Db
    path:=strings.clone_to_cstring(project.path(root,".mirai/ai/chat.db",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,sqlite.open_v2(path,&other,sqlite.OPEN_READWRITE|sqlite.OPEN_NOMUTEX,nil)==sqlite.OK)
    defer sqlite.close_v2(other)
    testing.expect(t,sqlite.exec(other,"BEGIN IMMEDIATE",nil,nil,nil)==sqlite.OK)
    test_add(&transcript,"Gulls circle it.")
    testing.expect_value(t,save(&store,&c,transcript[2:]),"")
    testing.expect_value(t,pending(&store),1)
    testing.expect(t,sqlite.exec(other,"ROLLBACK",nil,nil,nil)==sqlite.OK)

    // The editor dies here: what is on the disk is what the next editor opens.
    crashed:=project.path(root,"crashed",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(project.path(crashed,".mirai/ai",allocator=context.temp_allocator))==nil)
    for name in ([]string{"chat.db","chat.db-wal"}) {
        data,error:=os.read_entire_file(project.path(root,".mirai/ai",name,allocator=context.temp_allocator),context.temp_allocator)
        if !testing.expectf(t,error==nil,"%s: %v",name,error) {return}
        testing.expect(t,os.write_entire_file(project.path(crashed,".mirai/ai",name,allocator=context.temp_allocator),data)==nil)
    }
    lines:[8]Stored_Line
    reopened:Store
    testing.expect_value(t,open(&reopened,crashed),"")
    count,_:=page(&reopened,1,-1,lines[:])
    testing.expect(t,count==2 && lines[1].text=="The harbor has a pier and a lighthouse.","the saves survive, without the write kept after them")
    testing.expect(t,find(&reopened,1)!=nil)
    close(&reopened)

    close(&store)
    testing.expect_value(t,open(&store,root),"")
    count,_=page(&store,1,-1,lines[:])
    testing.expect(t,count==3 && lines[2].text=="Gulls circle it.","closing writes what was kept")
}
