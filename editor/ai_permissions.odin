package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:editor/acp"
import "mirai:project"

// Deleting a file is asked of the user with every agent; moving one is not.
// Claude receives the rules as settings of its session. Codex runs the
// commands its sandbox allows without asking, so the project carries rules
// that make the deleting ones ask (AI_CODEX_RULES) and is trusted so that
// Codex reads them; the requests they cause reach the user, not the policy.

AI_CLAUDE_SESSION_META :: `{"claudeCode":{"options":{"allowedTools":["mcp__mirai"],"settings":{"permissions":{"ask":["Bash(rm:*)","Bash(rmdir:*)","Bash(unlink:*)","Bash(shred:*)","Bash(git rm:*)","Bash(git clean:*)","mcp__mirai__asset_delete","mcp__mirai__panel_delete","mcp__mirai__git_discard"],"allow":["Bash(mv:*)","Bash(git mv:*)"]}}}}}`

AI_CODEX_RULES_PATH :: ".codex/rules/mirai.rules"
AI_CODEX_RULES :: `# Written by the Mirai editor: deleting files asks the user.
prefix_rule(pattern=[["rm", "rmdir", "unlink", "shred", "del", "erase", "rd", "ri", "Remove-Item", "remove-item"]], decision="prompt", justification="Deleting files asks the user")
prefix_rule(pattern=["git", ["rm", "clean"]], decision="prompt", justification="Deleting files asks the user")
`

// The commands that delete files, lowercase, and the tools of the editor that do.
AI_DELETING_COMMANDS :: [?]string{"rm","rmdir","unlink","shred","del","erase","rd","ri","remove-item"}
AI_DELETING_TOOLS :: [?]string{"asset_delete","panel_delete","git_discard","asset.delete","panel.delete","git.discard"}
AI_SHELLS :: [?]string{"powershell","pwsh","cmd","bash","sh","zsh"}

// The settings of a Codex session, with the project trusted so that its rules load.
ai_codex_session_config :: proc(root:string) -> string {
    base_config:=strings.trim_suffix(AI_CODEX_SESSION_CONFIG,"}")
    key,_:=json.marshal(root,{},context.temp_allocator)
    return fmt.tprintf(`%s,"projects":{{%s:{{"trust_level":"trusted"}}}}}`,base_config,string(key))
}

// Writes the rules of Codex in the project when they are missing or differ.
ai_codex_rules_write :: proc(root:string) -> bool {
    path:=project.path(root,AI_CODEX_RULES_PATH,allocator=context.temp_allocator)
    if data,error:=os.read_entire_file(path,context.temp_allocator);error==nil && string(data)==AI_CODEX_RULES {return true}
    folder:=filepath.dir(path)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return false}
    return os.write_entire_file(path,transmute([]u8)string(AI_CODEX_RULES))==nil
}

// Whether a shell command deletes files in one of its segments. The shell
// that wraps a command and its flags are skipped: Codex sends a command of
// PowerShell as `"...\powershell.exe" -NoProfile -Command 'rm a'`.
ai_command_deletes :: proc(command:string) -> bool {
    deleting,shells:=AI_DELETING_COMMANDS,AI_SHELLS
    name_of :: proc(word:string) -> string {
        word:=strings.trim(word,`"'`)
        if slash:=strings.last_index_any(word,`/\`);slash>=0 {word=word[slash+1:]}
        return strings.trim_suffix(strings.to_lower(word,context.temp_allocator),".exe")
    }
    for segment in strings.split_multi(command,{";","&","|","\n","(",")","{","}"},context.temp_allocator) {
        words:=strings.fields(segment,context.temp_allocator)
        at:=0
        for at<len(words) && (words[at]=="sudo" || strings.contains_rune(words[at],'=')) {at+=1}
        for at<len(words) {
            shell:=false
            for candidate in shells {if name_of(words[at])==candidate {shell=true}}
            if !shell {break}
            at+=1
            for at<len(words) && (words[at][0]=='-' || words[at][0]=='/') {at+=1}
        }
        if at==len(words) {continue}
        name:=name_of(words[at])
        if name=="git" && at+1<len(words) && (name_of(words[at+1])=="rm" || name_of(words[at+1])=="clean") {return true}
        for verb in deleting {if name==verb {return true}}
    }
    return false
}

// Whether a request for permission of Codex is to delete files: a command
// that deletes, or a tool of the editor that does. tool is the title of the
// last tool call of the turn, which an approval of a tool may only refer to.
ai_permission_deletes :: proc(request:json.Value,tool:string) -> bool {
    call:=acp.at(request,"toolCall")
    flag,is_flag:=acp.at(request,"_meta","is_mcp_tool_approval").(json.Boolean)
    if is_flag && bool(flag) {
        names:=AI_DELETING_TOOLS
        for name in names {
            for text in ([]string{acp.text(acp.at(call,"title")),acp.text(acp.at(call,"rawInput","description")),tool}) {
                if strings.contains(text,name) {return true}
            }
        }
        return false
    }
    #partial switch command in acp.at(call,"rawInput","command") {
    case json.String: if ai_command_deletes(string(command)) {return true}
    case json.Array:
        words:=make([dynamic]string,context.temp_allocator)
        for word in command {append(&words,acp.text(word))}
        if ai_command_deletes(strings.join(words[:]," ",context.temp_allocator)) {return true}
    }
    // The title of a command is the command, or what its actions do.
    return ai_command_deletes(acp.text(acp.at(call,"title")))
}
