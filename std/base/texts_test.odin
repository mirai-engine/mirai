package base

import "core:testing"

// One lookup for whoever shows a text: a key says its text in the language
// asked by its code, which is any a .strings names (pl as much as es); a
// region that lacks it says it in its language (es-419 and es-AR as es),
// and a language that lacks it, or none asked, in the one it was written
// in; a key the table lacks, no key and no table find nothing.
@(test)
a_text_is_found_by_key_and_language_and_falls_back_to_the_one_it_was_written_in :: proc(t:^testing.T) {
    bytes:=transmute([]u8)string("StartEmpezarBackStartuj")
    es:=name_hash("es")
    slots:[16]Text_Slot
    put :: proc(slots:[]Text_Slot,language:u64,key:string,offset,length:u32) {
        hash:=name_hash(key)
        at:=text_slot(language,hash)&u64(len(slots)-1)
        for slots[at].key!=0 {at=(at+1)&u64(len(slots)-1)}
        slots[at]={language,hash,offset,length}
    }
    put(slots[:],0,"menu.start",0,5)
    put(slots[:],name_hash("en"),"menu.start",0,5)
    put(slots[:],es,"menu.start",5,7)
    put(slots[:],0,"menu.back",12,4)
    put(slots[:],name_hash("en"),"menu.back",12,4)
    put(slots[:],name_hash("pl"),"menu.start",16,7)
    texts:=Texts{slots=slots[:],text=bytes}
    cases:=[]struct{key,language,value:string,found:bool}{
        {"menu.start","es","Empezar",true},
        {"menu.start","pl","Startuj",true},
        {"menu.start","es-419","Empezar",true},
        {"menu.start","es-AR-x","Empezar",true},
        {"menu.start","","Start",true},
        {"menu.start","fr","Start",true},
        {"menu.start","-","Start",true},
        {"menu.back","es-419","Back",true},
        {"menu.quit","es","",false},
        {"","es","",false},
    }
    for c in cases {
        value,found:=text(&texts,c.key,c.language)
        testing.expectf(t,value==c.value && found==c.found,"%q in %q: %q, %v",c.key,c.language,value,found)
    }
    _,found:=text(nil,"menu.start","es")
    testing.expect(t,!found)
    _,found=text(&Texts{},"menu.start","es")
    testing.expect(t,!found)
}
