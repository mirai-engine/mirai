package editor

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:editor/acp"
import "mirai:project"
import "mirai:std/base"

@(test)
deleting_files_is_asked_of_the_user_and_moving_them_is_not :: proc(t:^testing.T) {
    parse :: proc(text:string) -> json.Value {
        value,_:=json.parse_string(text,allocator=context.temp_allocator)
        return value
    }
    testing.expect(t,ai_command_deletes("rm -rf Assets/old"))
    testing.expect(t,ai_command_deletes(`cd src && Remove-Item "a.odin"`))
    testing.expect(t,ai_command_deletes("FOO=1 sudo /usr/bin/rm a"))
    testing.expect(t,ai_command_deletes("git clean -fd"))
    testing.expect(t,ai_command_deletes("del.exe a.txt"))
    testing.expect(t,ai_command_deletes(`"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command 'rm zz_victim.txt'`),"the shell that wraps it is skipped")
    testing.expect(t,ai_command_deletes("cmd /c del a.txt"))
    testing.expect(t,!ai_command_deletes(`powershell.exe -Command 'Move-Item a b'`))
    testing.expect(t,!ai_command_deletes("mv a.odin b.odin"))
    testing.expect(t,!ai_command_deletes("git mv a b; git status"))
    testing.expect(t,!ai_command_deletes("odin build . -define:rm=1"))
    // A command of Codex, as text or as words.
    testing.expect(t,ai_permission_deletes(parse(`{"toolCall":{"rawInput":{"command":"rm Assets/a.tex"}}}`),""))
    testing.expect(t,ai_permission_deletes(parse(`{"toolCall":{"rawInput":{"command":["git","rm","a"]}}}`),""))
    testing.expect(t,!ai_permission_deletes(parse(`{"toolCall":{"rawInput":{"command":"curl example.com"}}}`),""))
    testing.expect(t,ai_permission_deletes(parse(`{"toolCall":{"kind":"execute","title":"rm zz_victim.txt"}}`),""),"or by its title")
    // A tool of the editor, by its title or by the tool call it refers to.
    testing.expect(t,ai_permission_deletes(parse(`{"_meta":{"is_mcp_tool_approval":true},"toolCall":{"toolCallId":"7"}}`),"mirai.asset_delete"))
    testing.expect(t,ai_permission_deletes(parse(`{"_meta":{"is_mcp_tool_approval":true},"toolCall":{"title":"MCP tool call approval","rawInput":{"description":"Allow the mirai MCP server to run tool \"panel_delete\"?"}}}`),""))
    testing.expect(t,!ai_permission_deletes(parse(`{"_meta":{"is_mcp_tool_approval":true},"toolCall":{"toolCallId":"8"}}`),"mirai.scene_delete"))
}

@(test)
codex_trusts_the_project_to_read_its_rules_and_claude_gets_them_as_settings :: proc(t:^testing.T) {
    config:=strings.trim_prefix(ai_codex_session_config(`C:\game "one"`),"CODEX_CONFIG=")
    value,error:=json.parse_string(config,allocator=context.temp_allocator)
    testing.expect_value(t,error,json.Error.None)
    testing.expect_value(t,acp.text(acp.at(value,"projects",`C:\game "one"`,"trust_level")),"trusted")
    limit,is_number:=acp.at(value,"project_doc_max_bytes").(json.Float)
    testing.expect(t,is_number && limit==0,"the session keeps the rest of its settings")
    meta,meta_error:=json.parse_string(AI_CLAUDE_SESSION_META,allocator=context.temp_allocator)
    testing.expect_value(t,meta_error,json.Error.None)
    ask,_:=acp.at(meta,"claudeCode","options","settings","permissions","ask").(json.Array)
    testing.expect(t,len(ask)>0 && acp.text(ask[0])=="Bash(rm:*)")
    folder:=base.test_folder(t,"codex-rules");if folder=="" {return}
    testing.expect(t,ai_codex_rules_write(folder))
    data,read_error:=os.read_entire_file(project.path(folder,AI_CODEX_RULES_PATH,allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,read_error==nil && string(data)==AI_CODEX_RULES)
    testing.expect(t,ai_codex_rules_write(folder))
}
