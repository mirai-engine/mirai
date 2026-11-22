package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import ka "mirai:cook/kai"
import vcs "mirai:kai"
import "mirai:project"
import "mirai:store"

KAI_USAGE :: "kai init|status|snapshot|log [-n N]|diff [change]|undo|conflicts|bookmarks [project] | kai new [change...] [-m text] | kai describe [change] -m text | kai split [-r change] [-m text] <path...> | kai restore <change> | kai bookmarks set <name> <change> | kai bookmarks delete <name> [--project P] [--store S]"

// mirai kai: the version control of a project with no editor, through
// cook/kai as the editor does. A change is named by @ (the working copy), @-
// (its parent), a bookmark or a prefix of its id.
cmd_kai :: proc(_:string,args:[]string) -> int {
    if len(args)==0 {fmt.eprintfln("Usage: mirai %s",KAI_USAGE);return 2}
    verb:=args[0]
    store_root,rest,store_ok:=store_take(args[1:])
    if !store_ok {fmt.eprintln("mirai kai: --store needs the folder of a store");return 2}
    folder,message,limit,change:=".","",20,""
    positionals:=make([dynamic]string,context.temp_allocator)
    for i:=0;i<len(rest);i+=1 {
        if value,matched,ok:=option_value(rest,&i,"--project");matched {
            if !ok || value=="" {fmt.eprintln("mirai kai: --project needs a folder");return 2}
            folder=value
        } else if value,matched,ok=option_value(rest,&i,"-m");matched {
            if !ok {fmt.eprintln("mirai kai: -m needs a text");return 2}
            message=value
        } else if value,matched,ok=option_value(rest,&i,"-r");matched {
            if !ok || value=="" {fmt.eprintln("mirai kai: -r needs a change");return 2}
            change=value
        } else if value,matched,ok=option_value(rest,&i,"-n");matched {
            n,parsed:=strconv.parse_int(value)
            if !ok || !parsed || n<=0 {fmt.eprintln("mirai kai: -n needs a count");return 2}
            limit=n
        } else if !positional(rest[i]) {
            return argument_unknown("kai",rest[i])
        } else {
            append(&positionals,rest[i])
        }
    }
    root:=project.path_absolute(folder,context.temp_allocator)
    if !project_folder(root) {fmt.eprintfln("mirai kai: %s has no %s: give the folder of a project with --project",root,project.PROJECT_FILE);return 2}
    if store_root=="" {store_root=store.default_root(context.temp_allocator)}
    s,store_error:=store.open(store_root)
    if store_error!=.None {fmt.eprintfln("mirai kai: the store at %s does not open (%v): give another with --store",store_root,store_error);return 1}
    defer store.close(&s)
    p:=new(ka.Project,context.temp_allocator)
    if verb=="init" {
        if len(positionals)>0 {return argument_unknown("kai init",positionals[0])}
        if ka.project_exists(root) {fmt.eprintfln("mirai kai init: %s is a workspace already",root);return 1}
        if e:=ka.project_create(p,root,&s);e!=.None {return kai_failed("init",e)}
        defer ka.project_close(p)
        fmt.printfln("%s is a Kai workspace: its files are change %s.",root,ka.change_text(working_change(p).id))
        return 0
    }
    if e:=ka.project_open(p,root,&s);e!=.None {
        if e==.Missing {fmt.eprintfln("mirai kai %s: %s is no Kai workspace: mirai kai init makes it one",verb,root);return 1}
        return kai_failed(verb,e)
    }
    defer ka.project_close(p)
    w:=&p.workspace
    find :: proc(w:^vcs.Workspace,verb,text:string) -> (revision:vcs.Revision,ok:bool) {
        e:vcs.Error
        if revision,e=ka.revision_find(w,text);e!=.None {
            fmt.eprintfln("mirai kai %s: %q names no single visible change: @, @-, a bookmark or a prefix of a change id as mirai kai log shows it",verb,text)
            return
        }
        return revision,true
    }
    switch verb {
    case "status":
        if len(positionals)>0 {return argument_unknown("kai status",positionals[0])}
        st,e:=vcs.workspace_status(w,context.temp_allocator)
        if e!=.None {return kai_failed(verb,e)}
        c:=working_change(p)
        fmt.printfln("Working copy %s %s",ka.change_text(c.id),description_line(c.description))
        for d in st.changes {fmt.printfln("  %s %s",diff_mark(d),d.path)}
        if len(st.changes)==0 {fmt.println("  no changes")}
        if st.conflicts>0 {fmt.printfln("%d files in conflict: mirai kai conflicts lists them",st.conflicts)}
    case "snapshot":
        if len(positionals)>0 {return argument_unknown("kai snapshot",positionals[0])}
        report,e:=vcs.workspace_snapshot(w)
        if e!=.None {return kai_failed(verb,e)}
        fmt.printfln("%d files, %d read again.",report.files,report.hashed)
    case "new":
        parents:=make([dynamic]vcs.Revision,context.temp_allocator)
        for text in positionals {
            r,ok:=find(w,verb,text)
            if !ok {return 1}
            append(&parents,r)
        }
        revision,e:=ka.new_change(w,parents[:],message,nil)
        if e!=.None {return kai_failed(verb,e)}
        c,_:=vcs.change_get(w.repo.s,revision,context.temp_allocator)
        fmt.printfln("Working copy %s, a new change.",ka.change_text(c.id))
    case "split":
        if len(positionals)==0 {fmt.eprintln("mirai kai split: name the files or folders the first change takes");return 2}
        if code:=kai_split(w,change,message,positionals[:]);code!=0 {return code}
    case "describe":
        if len(positionals)>1 {return argument_unknown("kai describe",positionals[1])}
        if message=="" {fmt.eprintln("mirai kai describe: -m gives the description");return 2}
        target:=vcs.repo_working(&w.repo)
        if len(positionals)==1 {
            ok:bool
            if target,ok=find(w,verb,positionals[0]);!ok {return 1}
        }
        if _,e:=vcs.workspace_snapshot(w);e!=.None {return kai_failed(verb,e)}
        if _,e:=vcs.change_describe(&w.repo,target,message);e!=.None {return kai_failed(verb,e)}
    case "log":
        if len(positionals)>0 {return argument_unknown("kai log",positionals[0])}
        if _,e:=vcs.workspace_snapshot(w);e!=.None {return kai_failed(verb,e)}
        rows:=make([dynamic]ka.Log_Row,context.temp_allocator)
        if e:=ka.log(w,limit,&rows);e!=.None {return kai_failed(verb,e)}
        for row in rows {
            marks:=row.working ? "@" : "o"
            y,mo,d:=time.date(time.unix(0,row.change.written))
            h,mi,_:=time.clock(time.unix(0,row.change.written))
            fmt.printf("%s %s %04d-%02d-%02d %02d:%02d",marks,ka.change_text(row.change.id),y,int(mo),d,h,mi)
            for b in row.bookmarks {fmt.printf(" [%s]",b)}
            if row.conflicts>0 {fmt.printf(" (%d in conflict)",row.conflicts)}
            if len(row.change.coauthors)>0 {fmt.printf(" +%d authors",len(row.change.coauthors))}
            if len(row.change.turns)>0 {fmt.printf(" +%d agent turns",len(row.change.turns))}
            fmt.printfln(" %s",description_line(row.change.description))
        }
    case "diff":
        if len(positionals)>1 {return argument_unknown("kai diff",positionals[1])}
        if _,e:=vcs.workspace_snapshot(w);e!=.None {return kai_failed(verb,e)}
        target:=vcs.repo_working(&w.repo)
        if len(positionals)==1 {
            ok:bool
            if target,ok=find(w,verb,positionals[0]);!ok {return 1}
        }
        diffs:=make([dynamic]vcs.Diff,context.temp_allocator)
        if e:=ka.diff(w,target,&diffs);e!=.None {return kai_failed(verb,e)}
        for d in diffs {fmt.printfln("%s %s",diff_mark(d),d.path)}
    case "undo":
        if len(positionals)>0 {return argument_unknown("kai undo",positionals[0])}
        undone,e:=ka.undo(w,nil)
        if e!=.None {return kai_failed(verb,e)}
        fmt.printfln("Undid: %s.",undone.description)
    case "restore":
        if len(positionals)!=1 {fmt.eprintfln("Usage: mirai %s",KAI_USAGE);return 2}
        from,ok:=find(w,verb,positionals[0])
        if !ok {return 1}
        if e:=ka.restore(w,from,nil);e!=.None {return kai_failed(verb,e)}
    case "conflicts":
        if len(positionals)>0 {return argument_unknown("kai conflicts",positionals[0])}
        if _,e:=vcs.workspace_snapshot(w);e!=.None {return kai_failed(verb,e)}
        for m in w.state.conflicts {fmt.println(m.path)}
        if len(w.state.conflicts)==0 {fmt.println("no conflicts")}
    case "bookmarks":
        switch {
        case len(positionals)==0:
            for &b in w.repo.view.bookmarks {
                if value,resolved:=vcs.terms_resolved(&b.terms);resolved {
                    c,_:=vcs.change_get(w.repo.s,value,context.temp_allocator)
                    fmt.printfln("%s %s",b.name,ka.change_text(c.id))
                } else {
                    fmt.printfln("%s (in conflict: %d sides)",b.name,len(b.terms.adds))
                }
            }
        case positionals[0]=="set" && len(positionals)==3:
            target,ok:=find(w,verb,positionals[2])
            if !ok {return 1}
            if e:=vcs.bookmark_set(&w.repo,positionals[1],target);e!=.None {return kai_failed(verb,e)}
        case positionals[0]=="delete" && len(positionals)==2:
            if e:=vcs.bookmark_set(&w.repo,positionals[1],{});e!=.None {return kai_failed(verb,e)}
        case:
            fmt.eprintfln("Usage: mirai %s",KAI_USAGE)
            return 2
        }
    case:
        fmt.eprintfln("Usage: mirai %s",KAI_USAGE)
        return 2
    }
    return 0
}

// Splits change (the working copy when empty) by paths: the first keeps them.
@(private="file")
kai_split :: proc(w:^vcs.Workspace,change,message:string,paths:[]string) -> int {
    description:Maybe(string)
    if message!="" {description=message}
    refused:string
    first,second,e:=ka.split(w,change!="" ? change : "@",paths,description,&refused)
    if e==.Invalid_Argument && refused!="" {fmt.eprintfln("mirai kai split: %s",refused);return 1}
    if e!=.None {return kai_failed("split",e)}
    a,_:=vcs.change_get(w.repo.s,first,context.temp_allocator)
    b,_:=vcs.change_get(w.repo.s,second,context.temp_allocator)
    fmt.printfln("%s %s keeps %d paths; %s holds the rest.",ka.change_text(a.id),description_line(a.description),len(paths),ka.change_text(b.id))
    return 0
}

@(private="file")
kai_failed :: proc(verb:string,e:vcs.Error) -> int {
    fmt.eprintfln("mirai kai %s: %s",verb,vcs.error_text(e))
    return 1
}

@(private="file")
project_folder :: proc(root:string) -> bool {
    return os.is_file(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator))
}

@(private="file")
working_change :: proc(p:^ka.Project) -> vcs.Change {
    c,_:=vcs.change_get(p.workspace.repo.s,vcs.repo_working(&p.workspace.repo),context.temp_allocator)
    return c
}

@(private="file")
description_line :: proc(text:string) -> string {
    if text=="" {return "(no description)"}
    line:=text
    if cut:=strings.index_byte(line,'\n');cut>=0 {line=line[:cut]}
    return line
}

// A added, D removed, M changed, C in conflict.
@(private="file")
diff_mark :: proc(d:vcs.Diff) -> string {
    switch {
    case d.after.kind==.Conflict: return "C"
    case d.before.address=={}: return "A"
    case d.after.address=={}: return "D"
    }
    return "M"
}
