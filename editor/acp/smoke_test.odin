package acp

import "core:fmt"
import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:platform"
import "mirai:std/base"

ACP_SMOKE :: #config(ACP_SMOKE,false)

when ACP_SMOKE {
    Smoke :: struct {
        t:^testing.T,
        client:^Client,
        cwd:string,
        session:[256]u8,
        reply:[1024]u8,
        model,effort:[128]u8,
        failed,done:bool,
    }

    smoke_event :: proc(user:rawptr,event:Event) {
        smoke:=cast(^Smoke)user
        switch event.kind {
        case .Initialized:
            testing.expect(smoke.t,smoke.client.image && smoke.client.embedded_context && smoke.client.http_mcp && smoke.client.session_rename)
            error:=open_session(smoke.client,{cwd=smoke.cwd,session_id=base.text_get(smoke.session[:]),model="gpt-6-luna",effort="low",title="ACP connection smoke"})
            testing.expect_value(smoke.t,error,Error.None)
            smoke.failed=error!=.None
        case .Config_Options:
            options,_:=at(event.value,"configOptions").(json.Array)
            for option in options {
                category:=text(at(option,"category"))
                if category=="model" {base.text_set(smoke.model[:],text(at(option,"currentValue")))}
                if category=="thought_level" {base.text_set(smoke.effort[:],text(at(option,"currentValue")))}
            }
        case .Session_Ready:
            message:="Reply with exactly ACP_OK."
            if base.text_get(smoke.session[:])!="" {message="What exact token did you reply with in your immediately previous answer? Return just that token. Do not use tools."}
            error:=prompt(smoke.client,{
                {kind=.Text,text="Mirai editor instruction: this is a connection smoke test. Do not invoke tools or modify any files."},
                {kind=.Text,text=message},
            })
            testing.expect_value(smoke.t,error,Error.None)
            smoke.failed=error!=.None
        case .Update:
            update:=at(event.value,"update")
            if text(at(update,"sessionUpdate"))=="agent_message_chunk" {
                base.text_append(smoke.reply[:],text(at(update,"content","text")))
            }
        case .Prompt_Done:
            smoke.done=true
            fmt.printf("ACP smoke: model=%s effort=%s stop=%s session=%s reply=%s\n",base.text_get(smoke.model[:]),base.text_get(smoke.effort[:]),event.text,session_id(smoke.client),base.text_get(smoke.reply[:]))
        case .Error:
            smoke.failed=true
            testing.expectf(smoke.t,false,"ACP error %d: %s",event.code,event.text)
        case .Permission:
            _=permission(smoke.client,event.request_id,"",true)
            smoke.failed=true
            testing.expect(smoke.t,false,"The connection smoke test unexpectedly requested a tool permission")
        case .Stderr:
            if strings.contains(event.text,"error") {fmt.printf("ACP adapter stderr: %s\n",event.text)}
        case .Authenticated,.Notice,.Exited:
        }
    }

    @(test)
    acp_codex_smoke_uses_the_requested_model_and_existing_account :: proc(t:^testing.T) {
        adapter,has_adapter:=os.lookup_env("MIRAI_ACP_SMOKE_ADAPTER",context.temp_allocator)
        bun,has_bun:=os.lookup_env("MIRAI_ACP_SMOKE_BUN",context.temp_allocator)
        cwd,has_cwd:=os.lookup_env("MIRAI_ACP_SMOKE_CWD",context.temp_allocator)
        codex,has_codex:=os.lookup_env("MIRAI_ACP_SMOKE_CODEX",context.temp_allocator)
        testing.expect(t,has_adapter && has_bun && has_cwd && has_codex,"The explicit smoke test requires adapter, Bun, project and Codex paths")
        if !has_adapter || !has_bun || !has_cwd || !has_codex {return}
        c:=test_client(t)
        defer destroy(&c)
        inherited,_:=os.environ(context.temp_allocator)
        environment:=slice.concatenate([][]string{inherited,{fmt.aprintf("CODEX_PATH=%s",codex,allocator=context.temp_allocator)}},context.temp_allocator)
        start_error:=start(&c,{command={bun,adapter},working_dir=cwd,env=environment},session_titles=true)
        testing.expect_value(t,start_error,Error.None)
        if start_error!=.None {return}
        smoke:=Smoke{t=t,client=&c,cwd=cwd}
        deadline:=platform.clock_seconds()+90
        for !smoke.failed && !smoke.done && platform.clock_seconds()<deadline {
            poll(&c,smoke_event,&smoke)
            platform.sleep_coarse(1_000_000)
        }
        testing.expect(t,smoke.done && !smoke.failed,"The agent completed the benign connection prompt")
        if smoke.done {
            testing.expect_value(t,base.text_get(smoke.model[:]),"gpt-6-luna")
            testing.expect_value(t,base.text_get(smoke.effort[:]),"low")
            testing.expect_value(t,strings.trim_space(base.text_get(smoke.reply[:])),"ACP_OK")
            testing.expect_value(t,c.phase,Phase.Ready)
        }
        stop(&c)
        deadline=platform.clock_seconds()+5
        for c.process.pid!=0 && platform.clock_seconds()<deadline {
            poll(&c,nil,nil)
            platform.sleep_coarse(1_000_000)
        }
        testing.expect_value(t,c.process.pid,0)
        if !smoke.done || smoke.failed {return}
        base.text_set(smoke.session[:],session_id(&c))
        smoke.reply={};smoke.done=false
        start_error=start(&c,{command={bun,adapter},working_dir=cwd,env=environment},session_titles=true)
        testing.expect_value(t,start_error,Error.None)
        deadline=platform.clock_seconds()+90
        for !smoke.failed && !smoke.done && platform.clock_seconds()<deadline {
            poll(&c,smoke_event,&smoke)
            platform.sleep_coarse(1_000_000)
        }
        testing.expect(t,smoke.done && !smoke.failed,"The restarted agent recovered its previous conversation")
        testing.expect_value(t,session_id(&c),base.text_get(smoke.session[:]))
        testing.expect_value(t,strings.trim_space(base.text_get(smoke.reply[:])),"ACP_OK")
        stop(&c)
        deadline=platform.clock_seconds()+5
        for c.process.pid!=0 && platform.clock_seconds()<deadline {
            poll(&c,nil,nil)
            platform.sleep_coarse(1_000_000)
        }
        testing.expect_value(t,c.process.pid,0)
    }
}
