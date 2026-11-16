package importer

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:ui"

// A folder of prompt images, as packs come (Kenney, Xelu and others): the
// name of each image and the folders it is in say the family and the input
// it shows (keyboard_a, xbox_button_color_a, PS5_Cross, Mouse_Left_Key_Dark).
// Of the variants of one input the plainest wins: the one whose name has the
// fewest words that say nothing of the input (outline, pressed, alt, or an
// older model of the controller), then the shortest name, then the largest file. Images whose names say no input are left out.

PROMPTS_IMAGE_EXTENSIONS :: [?]string{".png",".jpg",".jpeg",".tga",".bmp"}

// Words of names that say neither the family nor the input: they do not
// count against an image.
@(private="file")
PROMPTS_NEUTRAL :: [?]string{"button","buttons","key","keys","icon","icons","color","colour","colored","double","default","dark","series","controller","gamepad","input","prompts","prompt","png","arrow","arrows","and","the","kenney","xelu","mouse","keyboard","free","pack","x1","x2"}

// The words of a path: lower case, split at what is not a letter or a digit
// and where a lower case letter meets an upper case one (XboxSeriesX_A).
@(private="file")
prompts_words :: proc(path:string,allocator:=context.temp_allocator) -> []string {
    words:=make([dynamic]string,allocator)
    start:=-1
    for i:=0;i<=len(path);i+=1 {
        c:=path[i] if i<len(path) else 0
        letter:=c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9'
        split:=!letter || start>=0 && c>='A' && c<='Z' && path[i-1]>='a' && path[i-1]<='z'
        if split && start>=0 {
            append(&words,strings.to_lower(path[start:i],allocator))
            start=-1
        }
        if letter && start<0 {start=i}
    }
    return words[:]
}

@(private="file")
Prompts_Words :: struct {
    words:[]string,
    used:[]bool,
}

// Whether the words have word, and marks it used.
@(private="file")
take :: proc(w:^Prompts_Words,names:..string) -> bool {
    for word,i in w.words {
        for name in names {
            if word==name {
                w.used[i]=true
                return true
            }
        }
    }
    return false
}

// Whether the words have one that starts with prefix, and marks it used.
@(private="file")
take_prefix :: proc(w:^Prompts_Words,prefix:string) -> bool {
    for word,i in w.words {
        if strings.has_prefix(word,prefix) {
            w.used[i]=true
            return true
        }
    }
    return false
}

@(private="file")
has :: proc(w:^Prompts_Words,names:..string) -> bool {
    for word in w.words {
        for name in names {if word==name {return true}}
    }
    return false
}

// What the path of an image of a pack says it shows: its family, input and
// key, and how many of its words say nothing of them. ok is false when it
// names no input.
prompts_name_entry :: proc(path:string) -> (family:ui.Prompt_Family,input:ui.Prompt_Input,key:string,noise:int,ok:bool) {
    // The input is in the name of the file; the family there or in its folders.
    file:=filepath.stem(path)
    words:=prompts_words(file)
    w:=Prompts_Words{words,make([]bool,len(words),context.temp_allocator)}
    folders:=prompts_words(filepath.dir(path))
    f:=Prompts_Words{folders,make([]bool,len(folders),context.temp_allocator)}
    is_xbox :: proc(w:^Prompts_Words) -> bool {return take_prefix(w,"xbox") || take(w,"xb","xone","x360")}
    is_playstation :: proc(w:^Prompts_Words) -> bool {return take_prefix(w,"playstation") || take(w,"ps","ps3","ps4","ps5","dualshock","dualsense","sony")}
    is_keyboard :: proc(w:^Prompts_Words) -> bool {return take(w,"keyboard","kb","mouse","key","keys")}
    switch {
    case is_xbox(&w) || is_xbox(&f):
        family=.Xbox
        input,ok=prompts_pad_input(&w,true)
    case is_playstation(&w) || is_playstation(&f):
        family=.PlayStation
        input,ok=prompts_pad_input(&w,false)
    case has(&w,"mouse"):
        family=.Keyboard
        take(&w,"mouse")
        input,ok=prompts_mouse_input(&w)
    case is_keyboard(&w) || is_keyboard(&f):
        family,input=.Keyboard,.Key
        key,ok=prompts_key(&w)
    }
    if !ok {return}
    neutral:=PROMPTS_NEUTRAL
    for word,i in w.words {
        if w.used[i] || slice.contains(neutral[:],word) {continue}
        noise+=1
    }
    // The art of older controllers and of the Elite counts against an image.
    older:=[?]string{"elite","360","one","ps3","ps4","playstation3","playstation4"}
    for word in words {if slice.contains(older[:],word) {noise+=1}}
    if family==.Xbox && (input==.Start || input==.Back) && has(&w,"start","back") {noise+=1}
    return
}

// The side a word names: -1 left, 1 right, 0 none.
@(private="file")
prompts_side :: proc(w:^Prompts_Words) -> int {
    if take(w,"left","l") {return -1}
    if take(w,"right","r") {return 1}
    return 0
}

@(private="file")
prompts_pad_input :: proc(w:^Prompts_Words,xbox:bool) -> (input:ui.Prompt_Input,ok:bool) {
    switch {
    case take(w,"lb","l1"): return .Shoulder_Left,true
    case take(w,"rb","r1"): return .Shoulder_Right,true
    case take(w,"lt","l2"): return .Trigger_Left,true
    case take(w,"rt","r2"): return .Trigger_Right,true
    case take(w,"l3"): return .Stick_Left_Press,true
    case take(w,"r3"): return .Stick_Right_Press,true
    case take(w,"bumper","shoulder"):
        side:=prompts_side(w)
        if side==0 {return}
        return .Shoulder_Left if side<0 else .Shoulder_Right,true
    case take(w,"trigger"):
        side:=prompts_side(w)
        if side==0 {return}
        return .Trigger_Left if side<0 else .Trigger_Right,true
    case take(w,"stick","thumbstick","analog","joystick","ls","rs"):
        side:=-1 if has(w,"ls") else 1 if has(w,"rs") else prompts_side(w)
        if side==0 {return}
        press:=take(w,"press","click","pressed","push")
        if press {return .Stick_Left_Press if side<0 else .Stick_Right_Press,true}
        return .Stick_Left if side<0 else .Stick_Right,true
    case take(w,"dpad","directional") || has(w,"d") && has(w,"pad") && take(w,"d") && take(w,"pad"):
        switch {
        case take(w,"up"):    return .Dpad_Up,true
        case take(w,"down"):  return .Dpad_Down,true
        case take(w,"left"):  return .Dpad_Left,true
        case take(w,"right"): return .Dpad_Right,true
        }
        return .Dpad,true
    case take(w,"menu","start","options","plus"): return .Start,true
    case take(w,"view","back","select","share","create","minus"): return .Back,true
    case take(w,"cross"): return .South,true
    case take(w,"circle"): return .East,true
    case take(w,"square"): return .West,true
    case take(w,"triangle"): return .North,true
    }
    if !xbox {return}
    // The last letter of the face buttons: XboxSeriesX_A is A.
    #reverse for word,i in w.words {
        if w.used[i] {continue}
        switch word {
        case "a": w.used[i]=true;return .South,true
        case "b": w.used[i]=true;return .East,true
        case "x": w.used[i]=true;return .West,true
        case "y": w.used[i]=true;return .North,true
        }
    }
    return
}

@(private="file")
prompts_mouse_input :: proc(w:^Prompts_Words) -> (input:ui.Prompt_Input,ok:bool) {
    switch {
    case take(w,"wheel") || has(w,"scroll") && (has(w,"vertical") || has(w,"up") || has(w,"down")):
        take(w,"scroll");take(w,"vertical","up","down")
        return .Mouse_Wheel,true
    case take(w,"middle","scroll"): return .Mouse_Middle,true
    case take(w,"left"): return .Mouse_Left,true
    case take(w,"right"): return .Mouse_Right,true
    case take(w,"move","movement","horizontal","motion"): return .Mouse_Move,true
    }
    return
}

// The core.Key a keyboard image shows, by its name.
@(private="file")
prompts_key :: proc(w:^Prompts_Words) -> (key:string,ok:bool) {
    side:=prompts_side_of(w)
    modifier :: proc(w:^Prompts_Words,side:int,left,right:string,names:..string) -> (string,bool) {
        if !take(w,..names) {return "",false}
        return right if side>0 else left,true
    }
    if k,found:=modifier(w,side,"Left_Shift","Right_Shift","shift");found {return k,true}
    if k,found:=modifier(w,side,"Left_Control","Right_Control","ctrl","control");found {return k,true}
    if k,found:=modifier(w,side,"Left_Alt","Right_Alt","alt","option");found {return k,true}
    if k,found:=modifier(w,side,"Left_Super","Right_Super","super","win","windows","command","cmd","meta");found {return k,true}
    if take(w,"pageup","pgup") || has(w,"page") && has(w,"up") && take(w,"page") && take(w,"up") {return "Page_Up",true}
    if take(w,"pagedown","pgdn") || has(w,"page") && has(w,"down") && take(w,"page") && take(w,"down") {return "Page_Down",true}
    if has(w,"slash") && has(w,"back") && take(w,"slash") && take(w,"back") {return "Backslash",true}
    if take(w,"bracket","brackets") {
        if take(w,"left","open") {return "Left_Bracket",true}
        if take(w,"right","close") {return "Right_Bracket",true}
        return
    }
    Named :: struct {key:string,names:[]string}
    named:=[?]Named{
        {"Escape",{"escape","esc"}},{"Enter",{"enter","return"}},{"Tab",{"tab"}},{"Space",{"space","spacebar"}},
        {"Backspace",{"backspace"}},{"Delete",{"delete","del"}},{"Insert",{"insert","ins"}},{"Home",{"home"}},{"End",{"end"}},
        {"Minus",{"minus","dash","hyphen"}},{"Equals",{"equals","equal","plus"}},{"Semicolon",{"semicolon"}},{"Apostrophe",{"apostrophe","quote"}},
        {"Comma",{"comma"}},{"Period",{"period","dot"}},{"Slash",{"slash","forwardslash"}},{"Backslash",{"backslash"}},{"Grave",{"grave","tilde","backtick"}},
        {"Zero",{"0","zero"}},{"One",{"1","one"}},{"Two",{"2","two"}},{"Three",{"3","three"}},{"Four",{"4","four"}},
        {"Five",{"5","five"}},{"Six",{"6","six"}},{"Seven",{"7","seven"}},{"Eight",{"8","eight"}},{"Nine",{"9","nine"}},
    }
    for n in named {if take(w,..n.names) {return n.key,true}}
    FUNCTIONS :: [?]string{"F1","F2","F3","F4","F5","F6","F7","F8","F9","F10","F11","F12"}
    for f in FUNCTIONS {if take(w,strings.to_lower(f,context.temp_allocator)) {return f,true}}
    letters:="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    for i in 0..<len(letters) {
        if take(w,strings.to_lower(letters[i:i+1],context.temp_allocator)) {return letters[i:i+1],true}
    }
    if take(w,"up") {return "Up",true}
    if take(w,"down") {return "Down",true}
    if take(w,"left") {return "Left",true}
    if take(w,"right") {return "Right",true}
    return
}

// The side of a modifier, only when the name has one: left, right or none.
@(private="file")
prompts_side_of :: proc(w:^Prompts_Words) -> int {
    modified:=has(w,"shift","ctrl","control","alt","option","super","win","windows","command","cmd","meta")
    if !modified {return 0}
    return prompts_side(w)
}

// The entries a folder of images says, each input with the plainest of its
// images (paths absolute), and how many images said no input.
prompts_folder :: proc(folder:string,allocator:=context.allocator) -> (entries:[]Prompts_Entry,skipped:int) {
    Found :: struct {entry:Prompts_Entry,noise,words:int,size:i64}
    found:=make([dynamic]Found,context.temp_allocator)
    walk :: proc(folder,relative:string,found:^[dynamic]Found,skipped:^int) {
        handle,error:=os.open(folder)
        if error!=nil {return}
        defer os.close(handle)
        infos,read_error:=os.read_dir(handle,-1,context.temp_allocator)
        if read_error!=nil {return}
        slice.sort_by(infos,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
        extensions:=PROMPTS_IMAGE_EXTENSIONS
        for info in infos {
            inner:=info.name if relative=="" else strings.concatenate({relative,"/",info.name},context.temp_allocator)
            if info.type==.Directory {
                walk(info.fullpath,inner,found,skipped)
                continue
            }
            if !slice.contains(extensions[:],strings.to_lower(filepath.ext(info.name),context.temp_allocator)) {continue}
            family,input,key,noise,ok:=prompts_name_entry(inner)
            if !ok {skipped^+=1;continue}
            entry:=Prompts_Entry{family=family,input=input,key=key,image=info.fullpath}
            at:=-1
            for &f,i in found {if f.entry.family==family && f.entry.input==input && f.entry.key==key {at=i;break}}
            better:=Found{entry,noise,len(prompts_words(filepath.stem(info.name))),info.size}
            if at<0 {
                append(found,better)
            } else if was:=found[at];noise<was.noise || noise==was.noise && (better.words<was.words || better.words==was.words && info.size>was.size) {
                found[at]=better
            }
        }
    }
    walk(folder,"",&found,&skipped)
    // A modifier drawn once is that key on both sides.
    SIDES :: [?][2]string{{"Left_Shift","Right_Shift"},{"Left_Control","Right_Control"},{"Left_Alt","Right_Alt"},{"Left_Super","Right_Super"}}
    for sides in SIDES {
        left,right:=-1,-1
        for f,i in found {
            if f.entry.input!=.Key {continue}
            if f.entry.key==sides[0] {left=i}
            if f.entry.key==sides[1] {right=i}
        }
        if left>=0 && right<0 {
            other:=found[left]
            other.entry.key=sides[1]
            append(&found,other)
        }
    }
    entries=make([]Prompts_Entry,len(found),allocator)
    for f,i in found {
        entries[i]=f.entry
        entries[i].key=strings.clone(f.entry.key,allocator)
        entries[i].image=strings.clone(f.entry.image,allocator)
    }
    return
}
