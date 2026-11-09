package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:editor/api"
import "mirai:project"

@(private="file")
SAMPLE_RESULT :: `{"phase": "Compiling", "errors": 0, "frame": 18446744073709551615, "ok": false,
  "entities": [{"id": "00000000000000a1", "name": "Floor"}, {"id": "00000000000000a2", "name": "Lamp", "tags": ["light"]}],
  "camera": {"position": [1, 2.5, -3]}}`

@(test)
select_reads_members_elements_and_counts_from_the_end :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    at :: proc(t:^testing.T,path_text,expected:string,loc:=#caller_location) {
        path,ok:=api.json_path_parse(path_text)
        if !testing.expectf(t,ok,"%s parses",path_text,loc=loc) {return}
        value,problem:=api.json_at(SAMPLE_RESULT,path)
        testing.expectf(t,problem=="" && value==expected,"%s: %q %s",path_text,value,problem,loc=loc)
    }
    at(t,"phase",`"Compiling"`)
    at(t,"frame","18446744073709551615")
    at(t,"entities[1].name",`"Lamp"`)
    at(t,"entities[-1].tags[0]",`"light"`)
    at(t,"camera.position[2]","-3")
    at(t,"camera",`{"position": [1, 2.5, -3]}`)
    at(t,"entities.1.name",`"Lamp"`)
    at(t,"entities.-1.tags.0",`"light"`)
    testing.expect_value(t,api.json_scalar_text(`"Compiling"`),"Compiling")
    testing.expect_value(t,api.json_scalar_text("2.5"),"2.5")
    testing.expect_value(t,api.json_scalar_text(`{"a": [1]}`),"{\n  \"a\": [\n    1\n  ]\n}")

    missing :: proc(t:^testing.T,path_text,said:string,loc:=#caller_location) {
        path,_:=api.json_path_parse(path_text)
        _,problem:=api.json_at(SAMPLE_RESULT,path)
        testing.expectf(t,strings.contains(problem,said),"%s: %s",path_text,problem,loc=loc)
    }
    missing(t,"phases","has no 'phases'; it has: phase, errors, frame, ok, entities, camera")
    missing(t,"entities[2]","entities has 2 elements: there is no [2]")
    missing(t,"entities.2.name","entities has 2 elements: there is no [2]")
    missing(t,"camera.0","camera has no '0'; it has: position")
    missing(t,"entities[0].name.first","entities[0].name is not an object")
    missing(t,"camera[0]","camera is not an array")
    for wrong in ([]string{"","a..b",".a","a.","a[","a[x]","a[0]b","a.[0]"}) {
        _,ok:=api.json_path_parse(wrong)
        testing.expectf(t,!ok,"'%s' is not a path",wrong)
    }
}

// A capture result is megabytes of base64: an error about it stays short and
// says how much it left out.
@(test)
errors_cut_what_they_echo_and_say_how_much :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    result:=strings.concatenate({`{"content":[{"type":"image","data":"`,strings.repeat("A",3<<20),`"}],"isError":false}`})
    path,_:=api.json_path_parse("path")
    _,problem:=api.json_at(result,path)
    testing.expect(t,strings.contains(problem,"has no 'path'; it has: content, isError"),problem)
    path,_=api.json_path_parse("content.data")
    _,problem=api.json_at(result,path)
    testing.expect(t,len(problem)<256 && strings.contains(problem,"more bytes)"),"a value in a message is cut")

    short:=rpc_error_short({api.INVALID_PARAMS,"--select path",strings.concatenate({`{"result":`,result,"}"})})
    testing.expect(t,len(short.data)<2*RPC_ECHO_BYTES && api.json_valid(context.allocator,short.data),short.data)
    testing.expect(t,strings.contains(api.json_member(short.data,"prefix"),`{\"result\":{\"content\"`),short.data)
    testing.expect(t,api.json_member(short.data,"omitted_bytes")!="",short.data)

    small:=`{"result":{"a":1}}`
    testing.expect_value(t,rpc_error_short({api.INVALID_PARAMS,"x",small}).data,small)

    // Neither the cut of a character nor a list of names runs on.
    prefix,omitted:=api.text_cut("aé",2)
    testing.expect(t,prefix=="a" && omitted==2)
    many:=strings.concatenate({`{"`,strings.repeat("x",4096),`":1}`})
    path,_=api.json_path_parse("y")
    _,problem=api.json_at(many,path)
    testing.expect(t,len(problem)<2*RPC_ECHO_BYTES,"the names it lists are cut")
}

@(test)
wait_conditions_compare_numbers_as_numbers_and_the_rest_as_written :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    met :: proc(t:^testing.T,text,value:string,expected:bool,loc:=#caller_location) {
        condition,ok:=api.condition_parse(text)
        if !testing.expectf(t,ok,"%s parses",text,loc=loc) {return}
        result,mismatch:=api.condition_met(condition,value)
        testing.expectf(t,mismatch=="" && result==expected,"%s against %s: %v %s",text,value,result,mismatch,loc=loc)
    }
    met(t,"phase=Done",`"Done"`,true)
    met(t,`phase="Done"`,`"Done"`,true)
    met(t,"phase==Done",`"Compiling"`,false)
    met(t,"phase!=Done",`"Compiling"`,true)
    met(t,"errors=0","0.0",true)
    met(t,"errors>0","3",true)
    met(t,"errors>=3","3",true)
    met(t,"errors<3","3",false)
    met(t,"errors<=-1","-2",true)
    met(t,"frame=18446744073709551615","18446744073709551615",true)
    met(t,"frame=18446744073709551614","18446744073709551615",false)
    met(t,"ok=false","false",true)
    met(t,"selection=[]","[ ]",true)
    met(t,"position=[1,2]","[1, 2]",true)
    met(t,"entities[0].name=Floor",`"Floor"`,true)

    condition,parsed:=api.condition_parse("phase>2")
    testing.expect(t,parsed)
    _,mismatch:=api.condition_met(condition,`"Done"`)
    testing.expect(t,strings.contains(mismatch,"is not a number"),mismatch)
    for wrong in ([]string{"phase","=Done","phase>Done","phase<=","a..b=1","phase!Done"}) {
        _,ok:=api.condition_parse(wrong)
        testing.expectf(t,!ok,"'%s' is not a condition",wrong)
    }
}

// A command an AI agent runs inherits the editor that started it and its
// context, which the agent never names: the calls to that editor carry it.
@(test)
the_commands_of_an_agent_call_its_editor_in_its_context :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    testing.expect(t,os.set_env(api.AI_TASK_VARIABLE,"agent-3")==nil && os.set_env(api.PORT_VARIABLE,"7951")==nil)
    agent:=agent_environment()
    testing.expect(t,agent.task=="agent-3" && agent.port==7951)
    testing.expect(t,os.set_env(api.PORT_VARIABLE,"port")==nil)
    testing.expect_value(t,agent_environment(),Agent_Environment{})
    os.unset_env(api.AI_TASK_VARIABLE);os.unset_env(api.PORT_VARIABLE)
    testing.expect_value(t,agent_environment(),Agent_Environment{})
    cases:=[?]struct{args:[]string,port:int,task:string}{
        {{"scene.inspect"},7951,"agent-3"},
        {{"scene.inspect","--port","7951"},7951,"agent-3"},
        {{"scene.inspect","--port","7960"},7960,""},
    }
    for c in cases {
        connection,ok:=connection_args(c.args,agent)
        port:=connection_editor(connection).port
        testing.expectf(t,ok && port==c.port && connection_task(connection,port)==c.task,"%v: %d %q",c.args,port,connection_task(connection,port))
    }
    connection,ok:=connection_args({"scene.inspect","--project","elsewhere"},agent)
    testing.expect(t,ok && connection.project!="" && connection_task(connection,7960)=="","another editor is not told the context")
    testing.expect(t,connection.named,"--project names the project whose session a call may open")
    connection,ok=connection_args({"scene.inspect","--port","7951"},{})
    testing.expect(t,ok && !connection.named,"a port names no project to open")
    testing.expect(t,ok && connection_task(connection,7951)=="","outside an agent a call has no context")
    // An agent outside the editor names its client: --client first, then MIRAI_CLIENT, then Claude Code's shell.
    connection,ok=connection_args({"--client","codex","ai.turn_end"},{})
    testing.expect(t,ok && connection.client=="codex" && len(connection.rest)==1)
    _,ok=connection_args({"--client","two words","ai.turn_end"},{})
    testing.expect(t,!ok,"a client name is letters, digits, '.', '_' or '-'")
    os.unset_env(api.CLIENT_VARIABLE);os.unset_env("CLAUDECODE")
    testing.expect_value(t,client_environment(),"")
    testing.expect(t,os.set_env("CLAUDECODE","1")==nil)
    testing.expect_value(t,client_environment(),"claude-code")
    testing.expect(t,os.set_env(api.CLIENT_VARIABLE,"cursor")==nil)
    testing.expect_value(t,client_environment(),"cursor")
    os.unset_env(api.CLIENT_VARIABLE);os.unset_env("CLAUDECODE")
}

// A call from inside a project goes to its editor, from any folder under it.
@(test)
the_project_of_a_folder_is_the_nearest_with_a_manifest :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=fmt.tprintf("%s/mirai-project-of-%d",os.get_env("TEMP",context.temp_allocator),os.get_pid())
    nested:=project.path(root,"game/sub",allocator=context.temp_allocator)
    testing.expect(t,os.make_directory_all(nested)==nil)
    defer os.remove_all(root)
    testing.expect(t,os.write_entire_file(project.path(root,project.PROJECT_FILE),"{}")==nil)
    testing.expect_value(t,project_of(nested),project.path_absolute(root))
}

@(test)
rpc_arguments_take_select_wait_until_and_every :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    request,problem,ok:=rpc_request({"build.status","--select","phase,errors","--wait-until","phase=Idle","--every","0.25"})
    testing.expectf(t,ok,"parsed: %s",problem)
    testing.expect_value(t,request.method,"build.status")
    testing.expect_value(t,request.params,"{}")
    testing.expect_value(t,len(request.select),2)
    testing.expect_value(t,request.select[1].text,"errors")
    testing.expect(t,request.waits && request.until.op==.Equal && request.until.value=="Idle")
    testing.expect_value(t,request.every_ms,250)
    request,_,ok=rpc_request({"test.add",`{"a":1}`})
    testing.expect(t,ok && request.params==`{"a":1}` && !request.waits)
    _,problem,ok=rpc_request({"build.status","--every","1"})
    testing.expect(t,!ok && strings.contains(problem,"--wait-until"),problem)
    _,problem,ok=rpc_request({"build.status","--select","a..b"})
    testing.expect(t,!ok && strings.contains(problem,"a..b"),problem)
    _,problem,ok=rpc_request({"build.status","--wait-until","phase"})
    testing.expect(t,!ok && strings.contains(problem,"phase"),problem)
    _,problem,ok=rpc_request({"build.status","--sleep","1"})
    testing.expect(t,!ok && strings.contains(problem,"--sleep"),problem)
    _,problem,ok=rpc_request({"a","{}","c"})
    testing.expect(t,!ok && problem=="")
}

@(test)
describe_shows_types_defaults_an_example_and_the_result :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    describe:=`{"server":{"name":"mirai","version":"5"},"methods":[
        {"name":"test.echo","tool":"test_echo","summary":"Repeats a text.","flags":["idempotent"],
         "params":{"type":"object","properties":{"text":{"type":"string","maxLength":32},"times":{"type":"integer","minimum":1,"maximum":4,"default":1},"mode":{"type":"string","enum":["Walk","Run"],"default":"Walk"},"target":{"type":"string","pattern":"^(0x)?[0-9a-fA-F]{1,16}$"},"at":{"type":"array","items":{"type":"number"},"minItems":3,"maxItems":3,"x-unit":"m"},"dt":{"type":"number","minimum":0.0001,"maximum":0.25,"x-unit":"s","description":"Step"},"scale":{"type":"array","items":{"type":"number","default":1},"minItems":3,"maxItems":3}},"required":["text","target","at"],"additionalProperties":false},
         "result":{"type":"object","properties":{"text":{"type":"string","maxLength":160},"count":{"type":"integer","minimum":-2147483648,"maximum":2147483647}},"required":["text","count"],"additionalProperties":false}},
        {"name":"test.echo_twice","tool":"test_echo_twice","summary":"Twice.","flags":[],"params":{"type":"object"},"result":{}}]}`
    text:=rpc_describe_text(describe,"test.echo")
    for line in ([]string{
        "test.echo (idempotent)\n",
        "  Repeats a text.\n",
        "    text: string up to 32, required\n",
        "    times: integer 1..4, default 1\n",
        "    mode: Walk|Run, default \"Walk\"\n",
        "    target: entity id (up to 16 hex), required\n",
        "    at: number[3] m, required\n",
        "    dt: number 0.0001..0.25 s. Step\n",
        "    scale: number[3], default 1 each\n",
        "  example: mirai rpc test.echo text=x target=0000000000000001 at=[0,0,0]\n",
        "    count: integer\n",
    }) {
        testing.expectf(t,strings.contains(text,line),"%q in:\n%s",line,text)
    }
    testing.expect(t,!strings.contains(text,"test.echo_twice"),"the method named alone")
    both:=rpc_describe_text(describe,"test.")
    testing.expect(t,strings.contains(both,"test.echo_twice\n  Twice.\n  params: no schema"),both)
    testing.expect(t,strings.contains(both,"example: mirai rpc test.echo_twice\n"),both)
    testing.expect(t,strings.contains(both,"result: no schema"),both)
    testing.expect_value(t,rpc_similar_names(describe,"test.repeat"),"test.echo, test.echo_twice")
    testing.expect_value(t,rpc_similar_names(describe,"echo"),"test.echo, test.echo_twice")
    testing.expect_value(t,rpc_similar_names(describe,"scene.add"),"")
}

@(test)
describe_without_arguments_groups_the_methods_by_plugin :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    listing:=`{"server":{"name":"mirai","version":"6"},"methods":[
        {"name":"engine.describe","plugin":"editor","summary":"Lists the methods."},
        {"name":"animation.play","plugin":"animation","summary":"Plays a clip."},
        {"name":"scene.add","plugin":"editor","summary":"Adds entities."}],
        "plugins":[{"name":"animation","active":true},{"name":"terrain","active":false}]}`
    testing.expect_value(t,rpc_describe_list_text(listing),"editor\n  engine.describe  Lists the methods.\n  scene.add        Adds entities.\n\nanimation\n  animation.play   Plays a clip.\n\ninactive plugins: terrain\n")
    testing.expect(t,rpc_describe_is_plugin(listing,"animation") && rpc_describe_is_plugin(listing,"terrain") && rpc_describe_is_plugin(listing,"editor"))
    testing.expect(t,!rpc_describe_is_plugin(listing,"scene.") && !rpc_describe_is_plugin(listing,"scene.add"),"a prefix or a method is not a plugin")
    testing.expect_value(t,rpc_similar_names(listing,"scene.ad"),"scene.add")
}

// Quoting a JSON object differs per shell: key=value arguments need none.
@(test)
key_value_arguments_are_the_params_of_a_call :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    params :: proc(t:^testing.T,args:[]string,expected:string,loc:=#caller_location) {
        request,problem,ok:=rpc_request(args)
        testing.expectf(t,ok && problem=="" && request.method=="scene.set" && request.params==expected,"%v: %q %s",args,request.params,problem,loc=loc)
    }
    params(t,{"scene.set","entity=Floor","name=Ground"},`{"entity":"Floor","name":"Ground"}`)
    params(t,{"scene.set","count=3","ok=true","nothing=null","at=[1,2.5]","other={\"a\":1}"},`{"count":3,"ok":true,"nothing":null,"at":[1,2.5],"other":{"a":1}}`)
    params(t,{"scene.set","id=00000000000000a1","text=with spaces=and equals","empty="},`{"id":"00000000000000a1","text":"with spaces=and equals","empty":""}`)
    params(t,{"scene.set","a.b=1","a.c.d=two","--select","x"},`{"a":{"b":1,"c":{"d":"two"}}}`)
    params(t,{"scene.set",`{"a":1}`},`{"a":1}`)
    wrong :: proc(t:^testing.T,args:[]string,said:string,loc:=#caller_location) {
        _,problem,ok:=rpc_request(args)
        testing.expectf(t,!ok && strings.contains(problem,said),"%v: %s",args,problem,loc=loc)
    }
    wrong(t,{"scene.set","a=1","a=2"},"given twice")
    wrong(t,{"scene.set","a=1","a.b=2"},"given twice")
    wrong(t,{"scene.set","a..b=1"},"names joined by dots")
    wrong(t,{"scene.set",`{"a":1}`,"b=2"},"do not go together")
}
