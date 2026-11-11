package base

// What a player reads in their language: every .strings of the assets of a
// game as one table, by the name_hash of a key and of the code of a language
// ("es", "pt-BR"): the languages of a game are those its .strings name. Whoever shows a text, a node of a .ui, a field of a row
// or the code of the game, names its key and asks here. The application
// fills it and nothing else writes it.
Texts :: struct {
    slots:[]Text_Slot, // by text_slot of language and key, the next free one on a collision; a power of two of them
    text:[]u8,         // UTF-8
    generation:u32,    // changes with every load: what was made of a text is made again
}

// The text of a key in a language. Under the language 0, the text the key
// was written in: that of the first language of its .strings that has it.
Text_Slot :: struct {
    language,key:u64, // key 0: free
    offset,length:u32,
}

text_slot :: #force_inline proc "contextless" (language,key:u64) -> u64 {return hash_combine(language,key)}

// The text of a key in a language by its code; where it lacks one, in the
// language of its region (es-419 and es-AR say what es says), and then in
// the one the key was written in, also for the code "". found is false for
// a key no .strings has. It belongs to the table and lasts until its next
// load.
text :: proc "contextless" (texts:^Texts,key,language:string) -> (value:string,found:bool) {
    if texts==nil || len(texts.slots)==0 || key=="" {return}
    hash:=name_hash(key)
    mask:=u64(len(texts.slots)-1)
    code:=language
    for {
        wanted:=name_hash(code) if code!="" else 0
        for at:=text_slot(wanted,hash)&mask;texts.slots[at].key!=0;at=(at+1)&mask {
            slot:=texts.slots[at]
            if slot.language==wanted && slot.key==hash {return string(texts.text[slot.offset:][:slot.length]),true}
        }
        if code=="" {return}
        cut:=len(code)-1
        for cut>0 && code[cut]!='-' {cut-=1}
        code=code[:cut]
    }
}
