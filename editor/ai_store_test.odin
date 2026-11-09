package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"

@(private="file")
ai_store_test_root :: proc(name:string) -> string {
    return project.path_absolute(fmt.tprintf(".mirai/test-ai-store-%s-%d",name,os.get_pid()),context.temp_allocator)
}

@(private="file")
ai_store_test_conversation :: proc(id:u64,document:string) -> Ai_Conversation {
    c:=Ai_Conversation{id=id,created_at=100,updated_at=200}
    ai_conversation_set_text(c.title[:],&c.title_len,"Player questions")
    ai_conversation_set_text(c.document[:],&c.document_len,document)
    ai_conversation_set_text(c.provider[:],&c.provider_len,"codex")
    ai_conversation_set_text(c.model[:],&c.model_len,"gpt-6-luna")
    ai_conversation_set_text(c.effort[:],&c.effort_len,"low")
    ai_conversation_set_text(c.native_session[:],&c.native_session_len,"native-session-1")
    return c
}

@(test)
ai_store_reopens_chats_with_metadata_and_changed_stream_text :: proc(t:^testing.T) {
    root:=ai_store_test_root("roundtrip")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    store:Ai_Store
    defer ai_store_close(&store)
    testing.expect_value(t,ai_store_open(&store,root),"")
    id,message:=ai_store_next_id(&store)
    testing.expect_value(t,message,"")
    testing.expect_value(t,id,u64(1))
    c:=ai_store_test_conversation(id,"scene/main.scene")
    // What the agent spent comes back with the chat.
    c.seconds,c.usage=12.5,{input=1200,output=340,cache_read=9000,total=10540,context_used=48000,context_size=200000,cost=0.25}
    transcript:Ai_Transcript
    ai_transcript_add(&transcript,"What's the player's health? '; DROP TABLE conversations; --",.Prompt)
    ai_transcript_add(&transcript,"The player",.Output)
    testing.expect_value(t,ai_store_save(&store,&c,&transcript),"")
    testing.expect_value(t,ai_store_annotate(&store,id,0,"user","context","",`{"player":4}`),"")
    transcript={}
    ai_transcript_add(&transcript,"What's the player's health? '; DROP TABLE conversations; --",.Prompt)
    ai_transcript_add(&transcript,"The player's health is 100.",.Output)
    c.updated_at=300
    testing.expect_value(t,ai_store_save(&store,&c,&transcript,1),"")
    ai_store_close(&store)
    testing.expect(t,os.is_file(project.path(root,".mirai/ai/chat.db",allocator=context.temp_allocator)))
    testing.expect(t,!os.exists(project.path(root,".mirai/ai/chats/1.json",allocator=context.temp_allocator)))
    testing.expect_value(t,ai_store_open(&store,root),"")
    conversations:[8]Ai_Conversation
    count,list_message:=ai_store_list(&store,conversations[:])
    testing.expect_value(t,list_message,"")
    testing.expect_value(t,count,1)
    testing.expect_value(t,conversations[0],c)
    testing.expect_value(t,string(conversations[0].last[:conversations[0].last_len]),"The player's health is 100.")
    restored:Ai_Transcript
    testing.expect_value(t,ai_store_load(&store,id,&restored),"")
    testing.expect_value(t,restored.count,2)
    testing.expect_value(t,restored.dropped,0)
    text,kind:=ai_transcript_line(&restored,1)
    testing.expect_value(t,text,"The player's health is 100.")
    testing.expect_value(t,kind,Ai_Line_Kind.Output)
    lines:[4]Ai_Stored_Line
    line_count,page_message:=ai_store_page(&store,id,-1,lines[:])
    testing.expect_value(t,page_message,"")
    testing.expect_value(t,line_count,2)
    testing.expect_value(t,lines[0].role,"user")
    testing.expect_value(t,lines[0].event_type,"context")
    testing.expect_value(t,lines[0].context_json,`{"player":4}`)
    next_id,next_message:=ai_store_next_id(&store)
    testing.expect_value(t,next_message,"")
    testing.expect_value(t,next_id,u64(2))
}

@(test)
ai_store_filters_documents_and_keeps_projects_isolated :: proc(t:^testing.T) {
    root:=ai_store_test_root("isolation")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    first,second:Ai_Store
    defer ai_store_close(&first)
    defer ai_store_close(&second)
    testing.expect_value(t,ai_store_open(&first,project.path(root,"one",allocator=context.temp_allocator)),"")
    testing.expect_value(t,ai_store_open(&second,project.path(root,"two",allocator=context.temp_allocator)),"")
    transcript:Ai_Transcript
    ai_transcript_add(&transcript,"Hello",.Prompt)
    a:=ai_store_test_conversation(1,"scene/one.scene")
    b:=ai_store_test_conversation(2,"scene/two.scene")
    testing.expect_value(t,ai_store_save(&first,&a,&transcript),"")
    testing.expect_value(t,ai_store_save(&first,&b,&transcript),"")
    conversations:[8]Ai_Conversation
    count,message:=ai_store_list(&first,conversations[:],"scene/two.scene")
    testing.expect_value(t,message,"")
    testing.expect_value(t,count,1)
    testing.expect_value(t,conversations[0].id,u64(2))
    count,message=ai_store_list(&second,conversations[:])
    testing.expect_value(t,message,"")
    testing.expect_value(t,count,0)
    next_id,next_message:=ai_store_next_id(&first)
    testing.expect_value(t,next_message,"")
    testing.expect_value(t,next_id,u64(3))
    other_id,other_message:=ai_store_next_id(&second)
    testing.expect_value(t,other_message,"")
    testing.expect_value(t,other_id,u64(1))
}

@(test)
ai_store_preserves_messages_beyond_the_transcript_cache :: proc(t:^testing.T) {
    root:=ai_store_test_root("retention")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    store:Ai_Store
    defer ai_store_close(&store)
    testing.expect_value(t,ai_store_open(&store,root),"")
    c:=ai_store_test_conversation(1,"scene/main.scene")
    transcript:Ai_Transcript
    for index in 0..<900 {
        text:=fmt.tprintf("Line %04d: a long streamed transcript keeps its complete earlier history in the project database.",index)
        ai_transcript_add(&transcript,text)
        if (index+1)%40==0 {testing.expect_value(t,ai_store_save(&store,&c,&transcript),"")}
    }
    testing.expect(t,transcript.dropped>0)
    testing.expect_value(t,ai_store_save(&store,&c,&transcript),"")
    testing.expect_value(t,ai_store_annotate(&store,1,895,"assistant","tool_call","mirai.scene.inspect",`{"selection":[1]}`),"")
    testing.expect_value(t,ai_store_save(&store,&c,&transcript),"")
    ai_store_close(&store)
    testing.expect_value(t,ai_store_open(&store,root),"")
    restored:Ai_Transcript
    testing.expect_value(t,ai_store_load(&store,1,&restored),"")
    testing.expect(t,restored.dropped>0)
    testing.expect_value(t,restored.count+restored.dropped,900)
    last,_:=ai_transcript_line(&restored,restored.count-1)
    testing.expect(t,strings.has_prefix(last,"Line 0899:"))
    old:[16]Ai_Stored_Line
    count,message:=ai_store_page(&store,1,10,old[:])
    testing.expect_value(t,message,"")
    testing.expect_value(t,count,10)
    testing.expect_value(t,old[0].sequence,u64(0))
    testing.expect(t,strings.has_prefix(old[0].text,"Line 0000:"))
    testing.expect_value(t,old[9].sequence,u64(9))
    latest:[16]Ai_Stored_Line
    count,message=ai_store_page(&store,1,-1,latest[:])
    testing.expect_value(t,message,"")
    testing.expect_value(t,count,16)
    testing.expect_value(t,latest[11].sequence,u64(895))
    testing.expect_value(t,latest[11].tool,"mirai.scene.inspect")
    testing.expect_value(t,latest[11].context_json,`{"selection":[1]}`)
}

@(private="file")
ai_store_test_hits :: proc(t:^testing.T,store:^Ai_Store,query:string,conversation:u64=0) -> []Ai_Search_Hit {
    hits:=make([]Ai_Search_Hit,8,context.temp_allocator)
    count,message:=ai_store_search(store,query,hits,conversation,marks={"[","]"})
    testing.expectf(t,message=="","search %q: %s",query,message)
    return hits[:count]
}

@(test)
ai_store_search_finds_words_ids_and_paths_ranked :: proc(t:^testing.T) {
    root:=ai_store_test_root("search")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    store:Ai_Store
    defer ai_store_close(&store)
    testing.expect_value(t,ai_store_open(&store,root),"")
    a:=ai_store_test_conversation(1,"scene/main.scene")
    transcript:Ai_Transcript
    ai_transcript_add(&transcript,"Hang a lantern over the door",.Prompt)
    ai_transcript_add(&transcript,"The player",.Output)
    ai_transcript_add(&transcript,"Tool: scene.set Crate · ref 0x000000010000002a materials/floor.mat · +0.4 s · 2.0 ms",.Note)
    testing.expect_value(t,ai_store_save(&store,&a,&transcript),"")
    // The stream grows a line already saved: its later record replaces it.
    transcript={}
    ai_transcript_add(&transcript,"Hang a lantern over the door",.Prompt)
    ai_transcript_add(&transcript,"The player's lantern, the lantern of the quest, hangs at the door.",.Output)
    testing.expect_value(t,ai_store_save(&store,&a,&transcript,1),"")
    b:=ai_store_test_conversation(2,"scene/main.scene")
    transcript={}
    ai_transcript_add(&transcript,"Is there a lantern among the many props that the cellar of the old house keeps for later?",.Prompt)
    testing.expect_value(t,ai_store_save(&store,&b,&transcript),"")

    hits:=ai_store_test_hits(t,&store,"lantern")
    testing.expect_value(t,len(hits),3)
    if len(hits)==3 {
        testing.expect(t,hits[0].conversation==1 && hits[0].sequence==1 && hits[0].kind==.Output,"the line that says it most, and short, ranks first")
        testing.expect(t,hits[0].score<=hits[1].score && hits[1].score<=hits[2].score)
        testing.expect(t,hits[2].conversation==2,"a long line that says it once ranks last")
        testing.expectf(t,strings.contains(hits[0].snippet,"[lantern]"),"the snippet marks what matched, got %q",hits[0].snippet)
    }
    hits=ai_store_test_hits(t,&store,"player")
    testing.expect(t,len(hits)==1 && strings.contains(hits[0].snippet,"quest"),"a replaced line is indexed once, with its latest text")
    hits=ai_store_test_hits(t,&store,"0x000000010000002a")
    testing.expect(t,len(hits)==1 && hits[0].kind==.Note && hits[0].sequence==2,"a tool note is found by the id of its entity")
    hits=ai_store_test_hits(t,&store,"materials/floor.mat")
    testing.expect(t,len(hits)==1 && hits[0].sequence==2,"and by the path of its asset")
    hits=ai_store_test_hits(t,&store,"scene.set")
    testing.expect(t,len(hits)==1,"and by its method")
    hits=ai_store_test_hits(t,&store,"lantern",2)
    testing.expect(t,len(hits)==1 && hits[0].conversation==2,"a conversation narrows the search to its own lines")
    hits=ai_store_test_hits(t,&store,"door cellar")
    testing.expect_value(t,len(hits),0)
    hits=ai_store_test_hits(t,&store,"door OR cellar")
    testing.expect_value(t,len(hits),3)
    hits=ai_store_test_hits(t,&store,"dragon")
    testing.expect_value(t,len(hits),0)
    prefixed:[4]Ai_Search_Hit
    count,message:=ai_store_search(&store,"lant",prefixed[:],prefix=true)
    testing.expect(t,message=="" && count==3,"a prefix matches the start of a word")
    for query in ([]string{"",`"; DROP TABLE line; --`,"  · - "}) {
        count,message=ai_store_search(&store,query,prefixed[:])
        if query==`"; DROP TABLE line; --` {
            testing.expect(t,message=="" && count==0,"quotes and SQL in a query are words")
        } else {
            testing.expect_value(t,message,AI_SEARCH_NO_WORDS)
        }
    }
}

@(test)
ai_store_search_follows_saves_and_reopening :: proc(t:^testing.T) {
    root:=ai_store_test_root("search-saves")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    store:Ai_Store
    defer ai_store_close(&store)
    testing.expect_value(t,ai_store_open(&store,root),"")
    c:=ai_store_test_conversation(1,"scene/main.scene")
    transcript:Ai_Transcript
    ai_transcript_add(&transcript,"Paint the barn red",.Prompt)
    testing.expect_value(t,ai_store_save(&store,&c,&transcript),"")
    testing.expect_value(t,len(ai_store_test_hits(t,&store,"barn")),1)
    testing.expect_value(t,len(ai_store_test_hits(t,&store,"windmill")),0)
    ai_transcript_add(&transcript,"The windmill turns by the barn now.",.Output)
    testing.expect_value(t,ai_store_save(&store,&c,&transcript,1),"")
    testing.expect_value(t,len(ai_store_test_hits(t,&store,"windmill")),1)
    testing.expect_value(t,len(ai_store_test_hits(t,&store,"barn")),2)
    ai_store_close(&store)
    testing.expect_value(t,ai_store_open(&store,root),"")
    testing.expect_value(t,len(ai_store_test_hits(t,&store,"barn")),2)
}

@(test)
ai_store_reports_a_corrupt_database_and_keeps_it :: proc(t:^testing.T) {
    root:=ai_store_test_root("corrupt")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    path:=project.path(root,".mirai/ai/chat.db",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(project.path(root,".mirai/ai",allocator=context.temp_allocator))==nil)
    garbage:=strings.repeat("not a database ",512,context.temp_allocator)
    testing.expect(t,os.write_entire_file(path,garbage)==nil)
    store:Ai_Store
    defer ai_store_close(&store)
    message:=ai_store_open(&store,root)
    testing.expect(t,message!="","a file that is no database is reported")
    testing.expect_value(t,string(store.error[:store.error_len]),message)
    testing.expect_value(t,store.folder,"")
    kept,error:=os.read_entire_file(path,context.temp_allocator)
    testing.expect(t,error==nil && string(kept)==garbage,"and stays as it was")
}

@(private="file")
ai_store_test_write :: proc(t:^testing.T,folder,name,text:string) {
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/%s",folder,name),text)==nil)
}

@(test)
ai_store_imports_a_legacy_folder_once :: proc(t:^testing.T) {
    root:=ai_store_test_root("legacy")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    folder:=project.path(root,".mirai/ai/chats",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(folder)==nil)
    ai_store_test_write(t,folder,"7.json",`{"version":1,"id":7,"title":"Old chat","document":"scene/old.scene","provider":"codex","model":"m","effort":"low","native_session":"n","last":"Bye","created_at":10,"updated_at":20,"seconds":1.5,"usage":{"input":3}}`)
    ai_store_test_write(t,folder,"7.log",
        `{"sequence":0,"kind":1,"text":"Paint the barn","role":"user"}`+"\n"+
        `{"sequence":1,"annotation":true,"role":"early","event_type":"early"}`+"\n"+
        `{"sequence":1,"text":"The barn","role":"assistant"}`+"\n"+
        `{"sequence":1,"text":"The barn is red","role":"assistant"}`+"\n"+
        `{"sequence":0,"annotation":true,"role":"user","event_type":"user_message","context":"{}"}`+"\n"+
        `{"sequence":2,"text":"cut in the mi`)
    ai_store_test_write(t,folder,"7.review.json","{}")
    ai_store_test_write(t,folder,"9.json","no json")
    ai_store_test_write(t,folder,"12.log","")
    ai_store_test_write(t,project.path(root,".mirai/ai",allocator=context.temp_allocator),"search.db","old index")

    store:Ai_Store
    defer ai_store_close(&store)
    testing.expect_value(t,ai_store_open(&store,root),"")
    for round in 0..<2 {
        conversations:[4]Ai_Conversation
        count,message:=ai_store_list(&store,conversations[:])
        testing.expect_value(t,message,"")
        testing.expect_value(t,count,1)
        testing.expect_value(t,conversations[0].id,u64(7))
        testing.expect_value(t,conversations[0].kind,Ai_Conversation_Kind.Archived)
        testing.expect_value(t,string(conversations[0].title[:conversations[0].title_len]),"Old chat")
        testing.expect_value(t,conversations[0].usage.input,i64(3))
        lines:[8]Ai_Stored_Line
        line_count,page_message:=ai_store_page(&store,7,-1,lines[:])
        testing.expect_value(t,page_message,"")
        testing.expect_value(t,line_count,2)
        testing.expect_value(t,lines[0].kind,Ai_Line_Kind.Prompt)
        testing.expect_value(t,lines[0].event_type,"user_message")
        testing.expect_value(t,lines[1].text,"The barn is red")
        testing.expect_value(t,lines[1].role,"assistant")
        testing.expect_value(t,lines[1].event_type,"text")
        testing.expect_value(t,ai_store_latest_user_message(&store,7),i64(0))
        testing.expect_value(t,len(ai_store_test_hits(t,&store,"barn")),2)
        testing.expect_value(t,len(ai_store_test_hits(t,&store,"cut")),0)
        if round==0 {
            ai_store_close(&store)
            testing.expect_value(t,ai_store_open(&store,root),"")
        }
    }
    for gone in ([]string{"7.json","7.log","12.log","../search.db"}) {
        testing.expectf(t,!os.exists(fmt.tprintf("%s/%s",folder,gone)),"%s stays",gone)
    }
    for kept in ([]string{"7.review.json","9.json"}) {
        testing.expectf(t,os.exists(fmt.tprintf("%s/%s",folder,kept)),"%s is gone",kept)
    }
    id,message:=ai_store_next_id(&store)
    testing.expect_value(t,message,"")
    testing.expect_value(t,id,u64(10))
}

@(test)
ai_store_keeps_each_new_table :: proc(t:^testing.T) {
    root:=ai_store_test_root("tables")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    store:Ai_Store
    defer ai_store_close(&store)
    testing.expect_value(t,ai_store_open(&store,root),"")

    testing.expect_value(t,ai_store_delivery_add(&store,1,"report","Agent 4 is done"),"")
    testing.expect_value(t,ai_store_delivery_add(&store,2,"report","Another chat"),"")
    deliveries,message:=ai_store_deliveries(&store,1)
    testing.expect_value(t,message,"")
    testing.expect(t,len(deliveries)==1 && deliveries[0].kind=="report" && deliveries[0].text=="Agent 4 is done")
    testing.expect_value(t,ai_store_delivery_remove(&store,deliveries[0].id),"")
    deliveries,message=ai_store_deliveries(&store,1)
    testing.expect(t,message=="" && len(deliveries)==0)

    note:string
    note,message=ai_store_note_get(&store,1)
    testing.expect(t,message=="" && note=="")
    testing.expect_value(t,ai_store_note_set(&store,1,"first"),"")
    testing.expect_value(t,ai_store_note_set(&store,1,"second"),"")
    note,message=ai_store_note_get(&store,1)
    testing.expect(t,message=="" && note=="second")

    pin,pin_message:=ai_store_pin_add(&store,"asset","materials/floor.mat","Floor")
    testing.expect_value(t,pin_message,"")
    pins,pins_message:=ai_store_pins(&store)
    testing.expect(t,pins_message=="" && len(pins)==1 && pins[0].id==pin && pins[0].ref=="materials/floor.mat" && pins[0].label=="Floor")
    testing.expect_value(t,ai_store_pin_remove(&store,pin),"")
    pins,pins_message=ai_store_pins(&store)
    testing.expect(t,pins_message=="" && len(pins)==0)

    note_id,note_message:=ai_store_annotation_add(&store,"lights","scene/main.scene",0x1_0000_002a,1.5,2,-3,"Too dark")
    testing.expect_value(t,note_message,"")
    _,_=ai_store_annotation_add(&store,"lights","scene/other.scene",1,0,0,0,"Elsewhere")
    testing.expect_value(t,ai_store_annotation_set_text(&store,note_id,"Brighter"),"")
    testing.expect_value(t,ai_store_annotation_set_group(&store,note_id,"shadows"),"")
    annotations,annotations_message:=ai_store_annotations(&store,"scene/main.scene")
    testing.expect(t,annotations_message=="" && len(annotations)==1)
    if len(annotations)==1 {
        a:=annotations[0]
        testing.expect(t,a.group_name=="shadows" && a.entity==0x1_0000_002a && a.x==1.5 && a.y==2 && a.z==-3 && a.text=="Brighter")
    }
    testing.expect(t,ai_store_annotation_set_group(&store,note_id+100,"lost")!="","a missing annotation is an error")
    testing.expect(t,ai_store_annotation_set_text(&store,note_id+100,"Lost")!="","a missing annotation is an error")
    testing.expect_value(t,ai_store_annotation_remove(&store,note_id),"")
    annotations,annotations_message=ai_store_annotations(&store,"scene/main.scene")
    testing.expect(t,annotations_message=="" && len(annotations)==0)

    _,found,provenance_message:=ai_store_provenance_get(&store,"asset","materials/floor.mat")
    testing.expect(t,provenance_message=="" && !found)
    testing.expect_value(t,ai_store_provenance_set(&store,"asset","materials/floor.mat",1,5),"")
    testing.expect_value(t,ai_store_provenance_set(&store,"asset","materials/floor.mat",2,9),"")
    provenance:Ai_Provenance
    provenance,found,provenance_message=ai_store_provenance_get(&store,"asset","materials/floor.mat")
    testing.expect(t,provenance_message=="" && found && provenance.conversation==2 && provenance.sequence==9 && provenance.at>0)

    testing.expect_value(t,ai_store_meta_set(&store,"handoff","1"),"")
    testing.expect_value(t,ai_store_meta_set(&store,"handoff","2"),"")
    value,meta_message:=ai_store_meta_get(&store,"handoff")
    testing.expect(t,meta_message=="" && value=="2")
    value,meta_message=ai_store_meta_get(&store,"missing")
    testing.expect(t,meta_message=="" && value=="")

    testing.expect_value(t,ai_store_memory_upsert(&store,".agents/memory/combat.md",10,"The sword swings with a long arc"),"")
    testing.expect_value(t,ai_store_memory_upsert(&store,".agents/memory/world.md",11,"The harbor has a lantern"),"")
    testing.expect_value(t,ai_store_memory_upsert(&store,".agents/memory/combat.md",12,"The axe swings with a short arc"),"")
    docs,docs_message:=ai_store_memory_list(&store)
    testing.expect(t,docs_message=="" && len(docs)==2 && docs[0].path==".agents/memory/combat.md" && docs[0].modified_at==12)
    hits:[4]Ai_Memory_Hit
    count,search_message:=ai_store_memory_search(&store,"axe OR harbor",hits[:],marks={"[","]"})
    testing.expect(t,search_message=="" && count==2,"OR takes either word")
    count,search_message=ai_store_memory_search(&store,"sword",hits[:])
    testing.expect(t,search_message=="" && count==0,"a replaced document is indexed with its latest text")
    count,search_message=ai_store_memory_search(&store,"lant",hits[:],prefix=true,marks={"[","]"})
    testing.expect(t,search_message=="" && count==1 && hits[0].path==".agents/memory/world.md" && strings.contains(hits[0].snippet,"[lantern]"))
    _,search_message=ai_store_memory_search(&store,"  · - ",hits[:])
    testing.expect_value(t,search_message,AI_SEARCH_NO_WORDS)
    testing.expect_value(t,ai_store_memory_remove(&store,".agents/memory/world.md"),"")
    count,search_message=ai_store_memory_search(&store,"harbor",hits[:])
    testing.expect(t,search_message=="" && count==0)
}

@(test)
ai_store_lists_by_kind_and_parent_and_finds_the_main_chat :: proc(t:^testing.T) {
    root:=ai_store_test_root("kinds")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    store:Ai_Store
    defer ai_store_close(&store)
    testing.expect_value(t,ai_store_open(&store,root),"")
    testing.expect(t,ai_store_main(&store)==nil)
    transcript:Ai_Transcript
    ai_transcript_add(&transcript,"Hello",.Prompt)
    rows:=[?]struct {id:u64,kind:Ai_Conversation_Kind,parent:u64}{{1,.Main,0},{2,.Agent,1},{3,.Agent,9},{4,.Archived,0}}
    for row in rows {
        c:=ai_store_test_conversation(row.id,"scene/main.scene")
        c.kind,c.parent=row.kind,row.parent
        testing.expect_value(t,ai_store_save(&store,&c,&transcript),"")
    }
    ai_store_close(&store)
    testing.expect_value(t,ai_store_open(&store,root),"")
    main_chat:=ai_store_main(&store)
    testing.expect(t,main_chat!=nil && main_chat.id==1)
    listed:[8]Ai_Conversation
    count,message:=ai_store_list(&store,listed[:])
    testing.expect(t,message=="" && count==4,"without a restriction, every kind")
    count,message=ai_store_list(&store,listed[:],kinds={.Agent})
    testing.expect(t,message=="" && count==2)
    count,message=ai_store_list(&store,listed[:],kinds={.Agent},parent=1)
    testing.expect(t,message=="" && count==1 && listed[0].id==2 && listed[0].parent==1 && listed[0].kind==.Agent)
    count,message=ai_store_list(&store,listed[:],kinds={.Main,.Archived})
    testing.expect(t,message=="" && count==2)
}

@(test)
ai_store_shares_the_project_with_another_open_store :: proc(t:^testing.T) {
    root:=ai_store_test_root("shared")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    first,second:Ai_Store
    defer ai_store_close(&first)
    defer ai_store_close(&second)
    testing.expect_value(t,ai_store_open(&first,root),"")
    testing.expect_value(t,ai_store_open(&second,root),"")
    id,message:=ai_store_next_id(&first)
    testing.expect_value(t,message,"")
    other,other_message:=ai_store_next_id(&second)
    testing.expect_value(t,other_message,"")
    testing.expect(t,id!=other,"two editors never take the same identifier")
    listed:[4]Ai_Conversation
    count,list_message:=ai_store_list(&second,listed[:])
    testing.expect(t,list_message=="" && count==0,"a reserved identifier is no conversation yet")

    c:=ai_store_test_conversation(id,"scene/main.scene")
    transcript:Ai_Transcript
    ai_transcript_add(&transcript,"Raise the lighthouse",.Prompt)
    testing.expect_value(t,ai_store_save(&first,&c,&transcript),"")
    count,list_message=ai_store_list(&second,listed[:])
    testing.expect(t,list_message=="" && count==1 && listed[0].id==id,"the other editor lists what the first saved")
    testing.expect(t,ai_store_find(&second,id)!=nil)
    testing.expect_value(t,len(ai_store_test_hits(t,&second,"lighthouse")),1)
    testing.expect_value(t,ai_store_annotate(&second,id,0,"user","user_message","","{}"),"")
    lines:[4]Ai_Stored_Line
    line_count,page_message:=ai_store_page(&first,id,-1,lines[:])
    testing.expect(t,page_message=="" && line_count==1 && lines[0].event_type=="user_message","and the first reads what the other wrote")
}

@(test)
ai_store_search_feeds_history_by_title_or_by_what_chats_said :: proc(t:^testing.T) {
    root:=ai_store_test_root("history-search")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    m:=new(Ai);defer free(m)
    document:=new(Document);defer free(document)
    document.path_length=copy(document.path[:],"scene/main.scene")
    s:=Session{ai=m,document=document}
    defer ai_store_close(&m.store)
    testing.expect_value(t,ai_store_open(&m.store,root),"")
    titled:=ai_store_test_conversation(1,"scene/main.scene")
    ai_conversation_set_text(titled.title[:],&titled.title_len,"Lanterns of the harbor")
    said:=ai_store_test_conversation(2,"scene/main.scene")
    titled.kind,said.kind=.Agent,.Agent
    transcript:Ai_Transcript
    ai_transcript_add(&transcript,"Light the pier",.Prompt)
    ai_transcript_add(&transcript,"Hung a [lantern](entity:0x2a) on the pier.",.Output)
    testing.expect_value(t,ai_store_save(&m.store,&said,&transcript),"")
    transcript={}
    ai_transcript_add(&transcript,"Name the boats",.Prompt)
    testing.expect_value(t,ai_store_save(&m.store,&titled,&transcript),"")
    ai_history_refresh(&s,0,"lant")
    testing.expect_value(t,m.history_count,2)
    for &c in m.history[:m.history_count] {
        last:=string(c.last[:c.last_len])
        if c.id==2 {testing.expectf(t,strings.contains(last,"Hung a lantern on the pier"),"a chat found by its lines shows what matched, got %q",last)}
    }
    ai_history_refresh(&s,0,"boats")
    testing.expect(t,m.history_count==1 && m.history[0].id==1)
    ai_history_refresh(&s,0,"·")
    testing.expect_value(t,m.history_count,0)
}
