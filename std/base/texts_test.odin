package base

import "core:testing"

// One lookup for whoever shows a text: a key says its text in the language
// asked, and in the one it was written in (language 0) when that language
// lacks it or none is asked; a key the table lacks, no key and no table find
// nothing.
@(test)
a_text_is_found_by_key_and_language_and_falls_back_to_the_one_it_was_written_in :: proc(t:^testing.T) {
    bytes:=transmute([]u8)string("StartEmpezarBack")
    es,fr:=name_hash("es"),name_hash("fr")
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
    texts:=Texts{slots=slots[:],text=bytes}
    cases:=[]struct{key:string,language:u64,value:string,found:bool}{
        {"menu.start",es,"Empezar",true},
        {"menu.start",0,"Start",true},
        {"menu.start",fr,"Start",true},
        {"menu.back",es,"Back",true},
        {"menu.quit",es,"",false},
        {"",es,"",false},
    }
    for c in cases {
        value,found:=text(&texts,c.key,c.language)
        testing.expectf(t,value==c.value && found==c.found,"%q in %x: %q, %v",c.key,c.language,value,found)
    }
    _,found:=text(nil,"menu.start",es)
    testing.expect(t,!found)
    _,found=text(&Texts{},"menu.start",es)
    testing.expect(t,!found)
}
