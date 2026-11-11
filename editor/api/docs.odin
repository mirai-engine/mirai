package api

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "mirai:project"
import "mirai:std/serial"

// The game documentation of the engine as `mirai docs` and the MCP tool docs
// read it, the same with an editor (POST /mcp) and without one (mirai mcp).

DOCS_FOLDER :: "docs/game"
DOCS_INSTRUCTION :: "The game documentation, by topic and its sub-pages. Read with the docs tool (or mirai docs) what the step at hand needs, with section for part of a topic (core prefabs is topic core, section prefabs); do not sweep it in advance:"
MCP_DOCS_TOOL :: "docs"
MCP_DOCS_ENTRY :: `{"name":"docs","description":"Reads the game documentation of this engine, with or without an editor. Without arguments, the index of topics and their sub-pages; with topic, that topic; with section too, one heading of it by its anchor or one of its task files (a link core/wiring.md is topic core, section wiring).","inputSchema":{"type":"object","properties":{"topic":{"type":"string"},"section":{"type":"string"}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"openWorldHint":false}}`

// A topic or, in pages, one of its sub-pages, whose description is its title.
Docs_Topic :: struct {name,description:string,pages:[]Docs_Topic}

// A heading of a document: its anchor, and where its line starts.
Docs_Heading :: struct {slug:string,level,start:int}

// The content of the answer to the tool docs with arguments, a JSON object or
// "": what the tool shows, as a result of tools/call.
docs_tool_write :: proc(w:^serial.Writer,root,arguments:string) {
    text,ok:=docs_tool_answer(root,arguments)
    raw(w,`{"content":[{"type":"text","text":`);serial.text_write_string(w,text)
    raw(w,`}],"isError":`);raw(w,ok?"false":"true");raw(w,"}")
}

@(private)
docs_tool_answer :: proc(root,arguments:string) -> (text:string,ok:bool) {
    fields:=[2]string{"topic","section"}
    values:[2]string
    if arguments!="" {
        object:[2]string
        if !object_values(context.temp_allocator,arguments,fields[:],object[:]) {return "arguments must be an object",false}
        for field,i in fields {
            if object[i]=="" || object[i]=="null" {continue}
            valid:bool
            if values[i],valid=string_value(context.temp_allocator,object[i]);!valid {return fmt.tprintf("%s must be a string",field),false}
        }
    }
    return docs_answer(root,values[0],values[1])
}

// The documentation of the engine at root: the index without a topic, a
// topic, or one section of it. text says what is valid when not ok. Names are
// matched against what the folder lists, so none of them is ever a path.
docs_answer :: proc(root,topic,section:string) -> (text:string,ok:bool) {
    folder:=project.path(root,DOCS_FOLDER,allocator=context.temp_allocator)
    names:=docs_names(folder)
    if len(names)==0 {return fmt.tprintf("there is no game documentation in %s",folder),false}
    if topic=="" {
        if section!="" {return "a section needs its topic",false}
        b:=strings.builder_make(context.temp_allocator)
        for found,i in docs_topics(root) {
            fmt.sbprintf(&b,"%s%-12s %s",i>0?"\n":"",found.name,found.description)
            for page in found.pages {fmt.sbprintf(&b,"\n  %s %s: %s",found.name,page.name,page.description)}
        }
        return strings.to_string(b),true
    }
    if !slice.contains(names,topic) {return fmt.tprintf("unknown topic '%s'; topics: %s",topic,strings.join(names,", ",context.temp_allocator)),false}
    body:string
    if body,ok=docs_read(project.path(folder,fmt.tprintf("%s.md",topic),allocator=context.temp_allocator));!ok {return fmt.tprintf("cannot read the topic %s",topic),false}
    if section=="" {return body,true}
    tasks_folder:=project.path(folder,topic,allocator=context.temp_allocator)
    tasks:=docs_names(tasks_folder)
    if slice.contains(tasks,section) {
        task,read:=docs_read(project.path(tasks_folder,fmt.tprintf("%s.md",section),allocator=context.temp_allocator))
        return read?task:fmt.tprintf("cannot read %s/%s",topic,section),read
    }
    headings:=docs_headings(body)
    slugs:=make([dynamic]string,context.temp_allocator)
    for heading,i in headings {
        if heading.slug==section {
            end:=len(body)
            for next in headings[i+1:] {
                if next.level<=heading.level {end=next.start;break}
            }
            return strings.trim_right_space(body[heading.start:end]),true
        }
        if heading.level>1 {append(&slugs,heading.slug)}
    }
    append(&slugs,..tasks)
    return fmt.tprintf("%s has no section '%s'; sections: %s",topic,section,strings.join(slugs[:],", ",context.temp_allocator)),false
}

// The index for the instructions of MCP: "" without documentation.
docs_compact :: proc(root:string) -> string {
    topics:=docs_topics(root)
    if len(topics)==0 {return ""}
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,DOCS_INSTRUCTION)
    for found in topics {
        fmt.sbprintf(&b,"\n- %s: %s",found.name,docs_brief(found.description))
        for page in found.pages {fmt.sbprintf(&b,"\n  - %s %s: %s",found.name,page.name,page.description)}
    }
    return strings.to_string(b)
}

@(private="file")
docs_topics :: proc(root:string) -> []Docs_Topic {
    folder:=project.path(root,DOCS_FOLDER,allocator=context.temp_allocator)
    topics:=make([dynamic]Docs_Topic,context.temp_allocator)
    for name in docs_names(folder) {
        text,_:=docs_read(project.path(folder,fmt.tprintf("%s.md",name),allocator=context.temp_allocator))
        pages_folder:=project.path(folder,name,allocator=context.temp_allocator)
        pages:=make([dynamic]Docs_Topic,context.temp_allocator)
        for page in docs_names(pages_folder) {
            body,_:=docs_read(project.path(pages_folder,fmt.tprintf("%s.md",page),allocator=context.temp_allocator))
            append(&pages,Docs_Topic{name=page,description=docs_title(body)})
        }
        append(&topics,Docs_Topic{name,docs_description(text),pages[:]})
    }
    return topics[:]
}

// The first line of a sub-page, its title; "" when that is not a heading.
@(private="file")
docs_title :: proc(text:string) -> string {
    line:=text
    if end:=strings.index_byte(text,'\n');end>=0 {line=text[:end]}
    return strings.has_prefix(line,"# ")?strings.trim_space(line[2:]):""
}

// The names of the Markdown files of a folder, without extension and sorted.
@(private="file")
docs_names :: proc(folder:string) -> []string {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return nil}
    names:=make([dynamic]string,context.temp_allocator)
    for entry in entries {
        if entry.type==.Regular && strings.has_suffix(entry.name,".md") {append(&names,entry.name[:len(entry.name)-len(".md")])}
    }
    slice.sort(names[:])
    return names[:]
}

@(private="file")
docs_read :: proc(file:string) -> (text:string,ok:bool) {
    data,error:=os.read_entire_file(file,context.temp_allocator)
    if error!=nil {return}
    text,_=strings.replace_all(string(data),"\r\n","\n",context.temp_allocator)
    return text,true
}

// The description of the YAML frontmatter of a document, on one line.
@(private="file")
docs_description :: proc(text:string) -> string {
    if !strings.has_prefix(text,"---\n") {return ""}
    end:=strings.index(text[4:],"\n---")
    if end<0 {return ""}
    rest:=text[4:4+end]
    b:=strings.builder_make(context.temp_allocator)
    inside:=false
    for line in strings.split_lines_iterator(&rest) {
        if strings.has_prefix(line,"description:") {
            inside=true
            strings.write_string(&b,strings.trim_space(line[len("description:"):]))
        } else if inside && strings.has_prefix(line," ") {
            strings.write_byte(&b,' ')
            strings.write_string(&b,strings.trim_space(line))
        } else {
            inside=false
        }
    }
    return strings.trim(strings.trim_space(strings.to_string(b)),"\"'")
}

// What a description says before its list of keywords.
@(private="file")
docs_brief :: proc(description:string) -> string {
    cut:=len(description)
    for separator in ([2]string{" - ",". "}) {
        if at:=strings.index(description,separator);at>=0 {cut=min(cut,at)}
    }
    return description[:cut]
}

// The headings of a Markdown text outside its code fences, with the anchors
// GitHub gives them, as scripts/check_docs.py computes them.
@(private="file")
docs_headings :: proc(text:string) -> []Docs_Heading {
    headings:=make([dynamic]Docs_Heading,context.temp_allocator)
    seen:=make(map[string]int,allocator=context.temp_allocator)
    fence:=u8(0)
    offset:=0
    rest:=text
    for line in strings.split_lines_iterator(&rest) {
        start:=offset
        offset+=len(line)+1
        trimmed:=strings.trim_left(line," ")
        if len(line)-len(trimmed)>3 {continue}
        if strings.has_prefix(trimmed,"```") || strings.has_prefix(trimmed,"~~~") {
            if fence==0 {fence=trimmed[0]} else if fence==trimmed[0] {fence=0}
            continue
        }
        if fence!=0 {continue}
        level:=0
        for level<len(trimmed) && trimmed[level]=='#' {level+=1}
        if level==0 || level>6 || level==len(trimmed) || trimmed[level]!=' ' && trimmed[level]!='\t' {continue}
        slug:=docs_slug(strings.trim_right(strings.trim_left(trimmed[level:]," \t")," \t#"))
        count:=seen[slug]
        seen[slug]=count+1
        append(&headings,Docs_Heading{count==0?slug:fmt.tprintf("%s-%d",slug,count),level,start})
    }
    return headings[:]
}

@(private="file")
docs_slug :: proc(title:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for i:=0;i<len(title); {
        rest:=title[i:]
        if strings.has_prefix(rest,"](") || rest[0]=='<' {
            closing:=rest[0]=='<'?u8('>'):u8(')')
            if end:=strings.index_byte(rest,closing);end>=0 {i+=end+1;continue}
        }
        r,size:=utf8.decode_rune_in_string(rest)
        i+=size
        switch {
        case r==' ': strings.write_byte(&b,'-')
        case r=='-' || r=='_': strings.write_rune(&b,r)
        case unicode.is_letter(r) || unicode.is_digit(r): strings.write_rune(&b,unicode.to_lower(r))
        }
    }
    return strings.to_string(b)
}
