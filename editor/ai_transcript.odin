package editor

import "core:strings"

// What a task has said so far: lines kept in one block of bytes, the oldest
// dropped when a new one has no room.

AI_TRANSCRIPT_BYTES :: 48*1024
AI_TRANSCRIPT_LINES :: 512
AI_LINE_BYTES :: 1024
AI_DECLINED_NOTE :: "Rejected changes"
AI_UNSAVED_NOTE :: "Changes not in the saved scene"
AI_RESTORED_NOTE :: "Changes taken back for review"


Ai_Line_Kind :: enum u8 {
    Output, // printed by the agent
    Prompt, // what the task was asked
    Note,   // said by the editor: why it did not start, how it ended
    Report, // a turn of a subagent of this chat ended; the text is the id of the subagent
    Divider, // a new context of the chat began; the text says why (AI_REOPENED_NOTE)
}

Ai_Line :: struct {
    offset:u32,
    length:u16,
    kind:Ai_Line_Kind,
}

Ai_Transcript :: struct {
    bytes:[AI_TRANSCRIPT_BYTES]u8,
    used:int,
    lines:[AI_TRANSCRIPT_LINES]Ai_Line,
    count:int,
    dropped:int, // lines that were forgotten: the first one kept has this index
    heights:[AI_TRANSCRIPT_LINES]f32, // of each line in the chat, at heights_width and heights_size; 0 until measured
    heights_width,heights_size:f32,
    heights_held:int, // the first line of the user that had not reached the agent when they were measured
}

ai_transcript_line :: proc(t:^Ai_Transcript,index:int) -> (text:string,kind:Ai_Line_Kind) {
    line:=t.lines[index]
    return string(t.bytes[line.offset:][:line.length]),line.kind
}

// Forgets the oldest quarter of the lines.
@(private)
ai_transcript_drop :: proc(t:^Ai_Transcript) {
    drop:=max(t.count/4,1)
    if drop>=t.count {
        t.dropped+=t.count
        t.count,t.used=0,0
        return
    }
    start:=int(t.lines[drop].offset)
    copy(t.bytes[:],t.bytes[start:t.used])
    t.used-=start
    copy(t.lines[:],t.lines[drop:t.count])
    copy(t.heights[:],t.heights[drop:t.count])
    t.count-=drop
    t.dropped+=drop
    for &line in t.lines[:t.count] {line.offset-=u32(start)}
}

// Adds text as lines, one per line break in it.
ai_transcript_add :: proc(t:^Ai_Transcript,text:string,kind:Ai_Line_Kind=.Output) {
    rest:=text
    for {
        line:=rest
        more:=false
        if split:=strings.index_byte(rest,'\n');split>=0 {line,rest,more=rest[:split],rest[split+1:],true}
        line=strings.trim_right(line,"\r")
        for {
            count:=min(len(line),AI_LINE_BYTES)
            if count<len(line) {for count>0 && (u8(line[count])&0xc0)==0x80 {count-=1}}
            for t.count==AI_TRANSCRIPT_LINES || t.used+count>AI_TRANSCRIPT_BYTES {ai_transcript_drop(t)}
            t.lines[t.count]={offset=u32(t.used),length=u16(count),kind=kind}
            t.count+=1
            ai_transcript_touch(t,t.count-1)
            t.used+=copy(t.bytes[t.used:],line[:count])
            line=line[count:]
            if line=="" {break}
        }
        if !more {break}
    }
}

// A line added or grown changes the message it goes on, which the chat
// draws as one: the lines of its kind before it are measured again.
ai_transcript_touch :: proc(t:^Ai_Transcript,index:int) {
    kind:=t.lines[index].kind
    for i:=index;i>=0;i-=1 {
        t.heights[i]=0
        if i==0 || t.lines[i-1].kind!=kind {break}
    }
}

// The note of the changes the scene lost last, reverted or not saved, which
// offers to take them back; -1 without one.
ai_transcript_declined :: proc(t:^Ai_Transcript) -> int {
    for index:=t.count-1;index>=0;index-=1 {
        text,kind:=ai_transcript_line(t,index)
        if kind==.Note && (text==AI_DECLINED_NOTE || text==AI_UNSAVED_NOTE) {return index}
    }
    return -1
}
