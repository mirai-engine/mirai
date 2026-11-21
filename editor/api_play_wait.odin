package editor

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

Api_Compare :: enum u8 {
    Exists,Gone,Equal,Not_Equal,Below,At_Most,Above,At_Least,Approx,Contains,
}

Api_Entity_Match :: enum u8 {Unique,Any,All}

Api_Play_Condition :: struct {
    entity:Api_Entity_Text `mirai:"optional,text,entity,label=Name or path Parent/Child or id or handle"`,
    component:[64]u8 `mirai:"optional,text,label=Filter to entities with this component"`,
    match:Api_Entity_Match `mirai:"optional,label=Unique (default) expects one entity; Any and All expect at least one"`,
    count:bool `mirai:"optional,label=Compare the number of entities matching entity or component"`,
    storage:[64]u8 `mirai:"optional,text,label=A storage of the game world"`,
    view:bool `mirai:"optional,label=What play.view sees; an entity given is its point (points.0)"`,
    no_problems:bool `mirai:"optional,label=Expect zero runtime problem reports in the run"`,
    problem:[core.PROBLEM_CODE]u8 `mirai:"optional,text,label=A runtime problem code to check with Exists or Gone"`,
    field:[128]u8 `mirai:"optional,text,label=Component.field.0.field or world_position.2 for an entity; a field path inside a storage or view; a component name alone checks presence"`,
    length:bool `mirai:"optional,label=Compare the number of elements of the list at field"`,
    compare:Api_Compare `mirai:"optional,label=Exists (default) or Gone for presence; Equal, Not_Equal, Below, At_Most, Above, At_Least, Approx or Contains for values"`,
    value:serial.Json `mirai:"optional,label=Expected JSON scalar or numeric vector; give one of value, number or text"`,
    number:f64 `mirai:"optional,label=Expected number; a bool can also be compared as 1 or 0"`,
    text:[128]u8 `mirai:"optional,text,label=Expected text or name of an enum member"`,
    tolerance:f64 `mirai:"optional,min=0,label=Maximum absolute error per coordinate for Approx"`,
}

Api_Play_Check_Params :: struct {
    conditions:[]Api_Play_Condition `mirai:"label=What must hold"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_Check_Result :: struct {
    passed:bool `mirai:"label=Every condition holds"`,
    tick:u64 `mirai:"label=The tick of the game they were read at"`,
    failure:string `mirai:"optional,label=The first unmet condition and what it read"`,
    results:[]Api_Play_Check_Entry `mirai:"label=One per condition in their order"`,
}
Api_Play_Check_Entry :: struct {
    passed:bool,
    value:serial.Json `mirai:"label=Value as scene.inspect writes it; a sample of values for Any or All; null when absent"`,
}

@(private)
api_play_wait_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="play.check",summary="Says whether conditions on the game of the caller hold now (values of components or storages compared, entities there or gone) with what each one read: the assertions of a test.",params=type_info_of(Api_Play_Check_Params),result=type_info_of(Api_Play_Check_Result),flags={.Core,.Read_Only},run=api_play_check})
}

@(private)
Api_Condition_Read :: struct {
    passed:bool,
    value,detail:string,
}

@(private)
api_condition_presence :: proc(compare:Api_Compare) -> bool {
    return compare==.Exists || compare==.Gone
}

@(private)
api_condition_number :: proc(value:json.Value) -> (f64,bool) {
    #partial switch v in value {
    case json.Integer: return f64(v),true
    case json.Float:   return f64(v),true
    }
    return 0,false
}

@(private)
api_condition_compare :: proc(
    c:^Api_Play_Condition,actual,expected:json.Value,there:bool,
) -> (passed:bool,problem:string) {
    #partial switch c.compare {
    case .Exists: return there,""
    case .Gone:   return !there,""
    case:        if !there {return false,""}
    }
    if c.compare==.Approx {
        if a,is_array:=actual.(json.Array);is_array {
            b,vector:=expected.(json.Array)
            if !vector || len(a)!=len(b) || len(a)==0 {
                return false,"Approx needs two numbers or two numeric vectors of the same length"
            }
            passed=true
            for x,i in a {
                left,ln:=api_condition_number(x)
                right,rn:=api_condition_number(b[i])
                if !ln || !rn {return false,"Approx needs numeric vector coordinates"}
                passed&&=math.abs(left-right)<=c.tolerance
            }
            return
        }
        left,ln:=api_condition_number(actual)
        right,rn:=api_condition_number(expected)
        if !ln || !rn {return false,"Approx needs two numbers or two numeric vectors"}
        return math.abs(left-right)<=c.tolerance,""
    }
    actual:=actual
    if a,boolean:=actual.(json.Boolean);boolean && c.value=="" && c.text[0]==0 {
        actual=json.Integer(a?1:0)
    }
    equal,less,greater:bool
    #partial switch a in actual {
    case json.String:
        b,ok:=expected.(json.String)
        if !ok && (c.value!="" || c.number!=0) {
            return false,"a text or enum needs a text value"
        }
        if c.compare==.Contains {return strings.contains(string(a),string(b)),""}
        if c.compare!=.Equal && c.compare!=.Not_Equal {
            return false,"a text or enum takes Equal, Not_Equal or Contains"
        }
        equal=a==b
    case json.Boolean:
        b,ok:=expected.(json.Boolean)
        if !ok || c.compare!=.Equal && c.compare!=.Not_Equal {
            return false,"a bool takes Equal or Not_Equal with true or false"
        }
        equal=a==b
    case:
        if c.compare==.Contains {return false,"Contains needs text"}
        ai,int_a:=actual.(json.Integer)
        bi,int_b:=expected.(json.Integer)
        if int_a && int_b {
            equal,less,greater=ai==bi,ai<bi,ai>bi
        } else {
            a,ln:=api_condition_number(actual)
            b,rn:=api_condition_number(expected)
            if !ln || !rn {return false,"comparison needs matching scalar values; name a field inside a compound value"}
            equal,less,greater=a==b,a<b,a>b
        }
    }
    #partial switch c.compare {
    case .Equal:     return equal,""
    case .Not_Equal: return !equal,""
    case .Below:     return less,""
    case .At_Most:   return less || equal,""
    case .Above:     return greater,""
    case .At_Least:  return greater || equal,""
    }
    return false,"unknown comparison"
}

@(private)
api_condition_excerpt :: proc(value:string) -> string {
    if len(value)<=160 {return value}
    for _,at in value {
        if at>=160 {return fmt.tprintf("%s…",value[:at])}
    }
    return value
}

@(private)
api_condition_expected :: proc(c:^Api_Play_Condition,expected:json.Value,actual:json.Value) -> string {
    #partial switch c.compare {
    case .Exists: return "exists"
    case .Gone:   return "is absent"
    case .Approx: return fmt.tprintf("≈ %s (tolerance %g)",api_condition_excerpt(api_json_text(expected)),c.tolerance)
    case:
        operators:=#partial [Api_Compare]string{
            .Equal="==",.Not_Equal="!=",.Below="<",.At_Most="<=",
            .Above=">",.At_Least=">=",.Contains="contains",
        }
        expected:=expected
        if _,is_text:=actual.(json.String);c.value=="" && is_text {expected=json.String(base.text_get(c.text[:]))}
        return fmt.tprintf("%s %s",operators[c.compare],api_condition_excerpt(api_json_text(expected)))
    }
}

@(private)
api_condition_storage :: proc(s:^Session,w:core.World_Read,name:string,allocator:=context.temp_allocator) -> (value:json.Value,problem:string) {
    st:=api_state(s)
    for &info,i in w.info.storages {
        if info.name!=name || info.place!=.World || info.by_world || info.info==nil {continue}
        if info.info.size>API_STORAGE_BYTES {return nil,fmt.tprintf("storage %q is too large to inspect",name)}
        ptr:=core.world_storage_read(w,info.type)
        if ptr==nil {return nil,fmt.tprintf("storage %q is unavailable in this run",name)}
        schema,index:=&st.schema,st.storage_types[i]
        runtime_schema:serial.Schema
        if index==serial.TYPE_NONE {
            serial.schema_init(&runtime_schema,allocator)
            runtime_schema.unsized,runtime_schema.named=true,st.schema.named
            schema=&runtime_schema
            ok:bool
            if index,ok=serial.schema_add_type_info(schema,info.info);!ok {
                return nil,fmt.tprintf("storage %q could not be reflected: %s",name,schema.error)
            }
        }
        out:serial.Writer
        serial.writer_init(&out,0,allocator)
        serial.text_write(&out,schema,index,mem.byte_slice(ptr,info.info.size),.Line,omit_fields={})
        whole,error:=json.parse(serial.writer_bytes(&out),allocator=allocator)
        if error!=nil {return nil,fmt.tprintf("storage %q could not be read as JSON",name)}
        return whole,""
    }
    return nil,fmt.tprintf("storage %q is not a storage of the game; use scene.inspect with world Game",name)
}

@(private)
api_condition_problems :: proc(s:^Session,w:core.World_Read,c:^Api_Play_Condition,code:string,diagnose:bool) -> (read:Api_Condition_Read,problem:string) {
    log:=host.app_world_storage(s.app,w.data,core.Problems)
    if log==nil {return {},"the run has no runtime problems log"}
    total,recorded,hits:=log.serial,u64(0),u64(0)
    first:^core.Problem
    for &p in core.problems_list(log) {
        recorded+=p.count
        if code!="" && core.problem_code(&p)!=code {continue}
        if first==nil {first=&p}
        hits+=p.count
    }
    if c.no_problems {
        read.passed=total==0
        if diagnose {
            read.value=fmt.tprintf("%d",total)
            if !read.passed {read.detail=fmt.tprintf("expected no problems, got %d reports",total)}
        }
    } else {
        if hits==0 && recorded!=total {return {},fmt.tprintf("cannot determine whether problem %q occurred; earlier reports are no longer retained",code)}
        read.passed=(hits>0)==(c.compare==.Exists)
        if diagnose {
            read.value=fmt.tprintf("%d",hits)
            if !read.passed {read.detail=fmt.tprintf("expected problem %q %s, got %d retained reports",code,c.compare==.Exists?"to occur":"to be absent",hits)}
        }
    }
    if read.detail!="" && first!=nil {
        read.detail=fmt.tprintf("%s (%s: %s)",read.detail,core.problem_code(first),api_condition_excerpt(core.problem_text(first)))
    }
    return
}

@(private)
api_condition_entities :: proc(w:core.World_Read,selector:string,table:^core.Table_Info,allocator:=context.temp_allocator) -> []core.Entity {
    raw:^core.Raw_Table
    if table!=nil {raw=core.world_table_at(core.World_Ref(w),table)}
    if selector=="" {return raw.entities[:]}
    matches:=api_entities_named(core.World_Ref(w),selector,allocator)
    if raw==nil {return matches}
    kept:=0
    for e in matches {
        if core.raw_row(raw,e)<0 {continue}
        matches[kept]=e
        kept+=1
    }
    return matches[:kept]
}

@(private)
api_condition_leaf :: proc(
    c:^Api_Play_Condition,leaf,expected:json.Value,there:bool,
) -> (actual:json.Value,passed:bool,problem:string) {
    actual=leaf
    if c.length && there {
        list,ok:=leaf.(json.Array)
        if !ok {return nil,false,"length needs a list field"}
        actual=json.Integer(len(list))
    }
    passed,problem=api_condition_compare(c,actual,expected,there)
    return
}

@(private)
api_condition_read :: proc(
    s:^Session,w:core.World_Ref,c:^Api_Play_Condition,allocator:=context.temp_allocator,diagnose:=true,
) -> (read:Api_Condition_Read,problem:string) {
    entity,component:=base.text_get(c.entity[:]),base.text_get(c.component[:])
    storage,field,code:=base.text_get(c.storage[:]),base.text_get(c.field[:]),base.text_get(c.problem[:])
    if c.compare>.Contains || c.match>.All {return {},"unknown compare or match value"}
    comparing:=!api_condition_presence(c.compare)
    entity_query:=!c.view && (entity!="" || component!="")
    subjects:=int(entity_query)+int(c.view)+int(storage!="")+int(c.no_problems)+int(code!="")
    if subjects!=1 {return {},"choose one subject: entities, storage, view, no_problems or a problem code"}
    if !entity_query && (component!="" || c.count || c.match!=.Unique) {
        return {},"component, count and match take an entity query"
    }
    if c.no_problems || code!="" {
        if comparing || c.no_problems && c.compare!=.Exists || field!="" || c.length ||
           c.value!="" || c.number!=0 || c.text[0]!=0 || c.tolerance!=0 {
            return {},"no_problems takes no comparison; a problem code takes Exists or Gone"
        }
        return api_condition_problems(s,core.world_read(w),c,code,diagnose)
    }
    if c.count && (!comparing || field!="" || c.length || c.match!=.Unique) {
        return {},"count takes a comparison with a number and no field, length or match"
    }
    if c.length && !comparing {return {},"length takes a numeric comparison"}
    if c.tolerance<0 || math.is_nan(c.tolerance) || math.is_inf(c.tolerance) || c.tolerance!=0 && c.compare!=.Approx {
        return {},"tolerance takes a finite non-negative number with Approx"
    }
    expected:json.Value
    switch {
    case c.value!="":
        if c.text[0]!=0 || c.number!=0 {return {},"give one of value, number or text"}
        parsed,error:=json.parse_string(string(c.value),allocator=allocator)
        if error!=nil {return {},"value must be valid JSON"}
        expected=parsed
    case c.text[0]!=0:
        if c.number!=0 {return {},"give one of number or text"}
        expected=json.String(base.text_get(c.text[:]))
    case:
        expected=json.Float(c.number)
    }
    path:=field
    if path=="" {path=entity_query?"entity":"value"}
    if c.length {path=fmt.tprintf("length of %s",path)}
    if c.count || c.length {
        if _,numeric:=api_condition_number(expected);!numeric {return {},"count and length take a number"}
    }
    if entity_query {
        return api_condition_entity_read(s,w,c,entity,component,field,path,expected,diagnose,allocator)
    }

    subject:="view"
    whole:json.Value
    there:=true
    if storage!="" {
        subject=fmt.tprintf("storage %q",storage)
        whole,problem=api_condition_storage(s,core.world_read(w),storage,allocator)
    } else {
        targets:[1]Play_View_Target
        if entity!="" {
            targets[0].entity,problem=api_entity_find(w,entity,allocator)
            targets[0].named=true
            there=targets[0].entity!=core.NONE
        }
        if problem=="" && there {
            doc:string
            doc,problem=play_view_json(w,targets[:int(entity!="")],allocator)
            if problem=="" {
                parsed,error:=json.parse_string(doc,allocator=allocator)
                if error!=nil {problem="the view could not be read as JSON"}
                whole=parsed
            }
        }
    }
    if problem!="" {return {},problem}
    leaf:json.Value
    if there {leaf,problem=api_json_select(whole,field,allocator,&there)}
    actual:json.Value
    if problem=="" {actual,read.passed,problem=api_condition_leaf(c,leaf,expected,there)}
    if problem!="" {return {},fmt.tprintf("%s field %q: %s",subject,field,problem)}
    if diagnose {
        read.value=api_json_text(actual,allocator)
        if !read.passed {read.detail=fmt.tprintf("%s %s: expected %s, got %s",subject,path,api_condition_expected(c,expected,actual),api_condition_excerpt(read.value))}
    }
    return
}

@(private)
api_condition_entity_read :: proc(
    s:^Session,w:core.World_Ref,c:^Api_Play_Condition,entity,component,field,path:string,
    expected:json.Value,diagnose:bool,allocator:=context.temp_allocator,
) -> (read:Api_Condition_Read,problem:string) {
    table:^core.Table_Info
    if component!="" {
        if table,problem=api_component_named(w,component);table==nil {return {},fmt.tprintf("component filter: %s",problem)}
    }
    matches:=api_condition_entities(core.world_read(w),entity,table,allocator)
    count:=len(matches)
    summary:=""
    if diagnose {
        summary=fmt.tprintf("matched %d entities",count)
        if entity!="" {summary=fmt.tprintf("%s for %q",summary,entity)}
        if component!="" {summary=fmt.tprintf("%s with %s",summary,component)}
    }
    if c.count {
        actual:=json.Value(json.Integer(count))
        read.passed,problem=api_condition_compare(c,actual,expected,true)
        if problem!="" {return {},problem}
        if diagnose {
            read.value=fmt.tprintf("%d",count)
            if !read.passed {read.detail=fmt.tprintf("%s: expected count %s, got %d",summary,api_condition_expected(c,expected,actual),count)}
        }
        return
    }
    if count==0 || c.match==.Unique && count!=1 {
        read.passed=count==0 && c.match==.Unique && c.compare==.Gone
        if diagnose {
            cardinality:=c.match==.Unique?"exactly one":"at least one"
            read.value="null"
            if !read.passed {read.detail=fmt.tprintf("%s: expected %s entity for %s %s",summary,cardinality,path,api_condition_expected(c,expected,nil))}
        }
        return
    }
    read.passed=c.match!=.Any
    actuals:[3]string
    sample:[len(actuals)]json.Value
    shown,failed:=0,0
    expectation:=""
    for e,i in matches {
        leaf,there,wrong:=api_entity_value(s,w,e,field,true,allocator,allow_absent=true)
        actual:json.Value
        held:bool
        if wrong=="" {actual,held,wrong=api_condition_leaf(c,leaf,expected,there)}
        if wrong!="" {return {},fmt.tprintf("field %q on entity 0x%016x: %s",field,u64(e),wrong)}
        if c.match==.Any {read.passed||=held} else {read.passed&&=held}
        if !held {failed+=1}
        if diagnose && i<len(sample) {sample[i]=actual}
        if diagnose && !held && shown<len(actuals) {
            if shown==0 {expectation=api_condition_expected(c,expected,actual)}
            actuals[shown]=fmt.tprintf("0x%016x = %s",u64(e),api_condition_excerpt(api_json_text(actual,allocator)))
            shown+=1
        }
    }
    if !diagnose {return}
    if c.match==.Unique {read.value=api_json_text(sample[0],allocator)}
    else {
        bytes,_:=json.marshal(sample[:min(count,len(sample))],allocator=allocator)
        read.value=string(bytes)
    }
    if !read.passed {
        detail:=strings.join(actuals[:shown],", ",allocator)
        if failed>shown {detail=fmt.tprintf("%s, and %d more",detail,failed-shown)}
        read.detail=fmt.tprintf("%s (%v): expected %s %s, got %s",summary,c.match,path,expectation,detail)
    }
    return
}

@(private)
api_conditions_read :: proc(
    s:^Session,w:core.World_Ref,conditions:[]Api_Play_Condition,reads:[]Api_Condition_Read,what:string,
) -> (all:bool,problem:string) {
    all=true
    for &c,i in conditions {
        read,wrong:=api_condition_read(s,w,&c,diagnose=i<len(reads))
        if wrong!="" {return false,fmt.tprintf("%s[%d]: %s",what,i,wrong)}
        if i<len(reads) {reads[i]=read}
        all&&=read.passed
    }
    return
}

@(private)
api_condition_failure :: proc(reads:[]Api_Condition_Read,what:string,allocator:mem.Allocator) -> string {
    for read,i in reads {
        if !read.passed {return fmt.aprintf("%s[%d]: %s",what,i,read.detail,allocator=allocator)}
    }
    return ""
}

@(private)
api_play_check :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Play_Check_Params)
    r,_:=api_play_run(s,call,params.player)
    if r==nil {api_no_game(call);return}
    if len(params.conditions)==0 {api.call_fail(call,api.INVALID_PARAMS,"conditions is empty: give what must hold");return}
    w:=run_ref(s,r)
    reads:=make([]Api_Condition_Read,len(params.conditions),context.temp_allocator)
    passed,problem:=api_conditions_read(s,w,params.conditions,reads,"conditions")
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    result:=api.call_result(call,Api_Play_Check_Result)
    result.passed=passed
    if t:=core.world_storage_read_of(core.world_read(w),core.Time);t.ptr!=nil {result.tick=t.tick}
    result.results=make([]Api_Play_Check_Entry,len(reads),call.allocator)
    for read,i in reads {result.results[i]={read.passed,serial.Json(read.value)}}
    if !passed {result.failure=api_condition_failure(reads,"conditions",call.allocator)}
}

// A value of a live entity at a path of the one syntax of Play: a component and
// the path inside it, Component.field.0.field, or a key of the document of the
// entity as scene.inspect writes it; empty, the entity and where it is. there is
// false when the entity lacks the component the path names, which is a reading
// and not a problem. runtime reads hidden and transient fields too; scratch
// keeps a call that reads many from asking memory each time.
api_entity_value :: proc(s:^Session,w:core.World_Ref,e:core.Entity,path:string,runtime:bool,allocator:=context.temp_allocator,scratch:[]u8=nil,allow_absent:=false) -> (leaf:json.Value,there:bool,problem:string) {
    st:=api_state(s)
    head,rest:=path,""
    if end:=strings.index_any(path,".[");end>=0 {head,rest=path[:end],strings.trim_prefix(path[end:],".")}
    if head=="components" {return nil,false,fmt.tprintf("a component is named by itself: %s",strings.trim_prefix(strings.trim_prefix(path,"components"),"."))}
    readable :: proc(s:^Session,t:^core.Table_Info) -> bool {return t!=nil && t.place==.World && api_state(s).types[api_table_index(s,t)]!=serial.TYPE_NONE}
    omitted:=runtime?serial.Field_Flags{}:serial.Field_Flags{.Transient,.Hidden}
    component :: proc(s:^Session,w:core.World_Ref,e:core.Entity,t:^core.Table_Info,rest:string,omitted:serial.Field_Flags,scratch:[]u8,allocator:mem.Allocator,allow_absent:bool) -> (leaf:json.Value,there:bool,problem:string) {
        st:=api_state(s)
        value:=core.raw_find(core.world_table_at(w,t),t.info,e)
        if value==nil {return nil,false,""}
        scratch:=scratch
        if len(scratch)<t.info.size {scratch=make([]u8,max(t.info.size,1),allocator)}
        api_value_out(w,t.info,value,scratch,handles=true)
        out:serial.Writer
        serial.writer_init(&out,0,allocator)
        serial.text_write(&out,&st.schema,st.types[api_table_index(s,t)],scratch[:t.info.size],.Line,omit_fields=omitted)
        whole,parse_error:=json.parse(serial.writer_bytes(&out),allocator=allocator)
        if parse_error!=nil {return nil,false,"the value could not be read back as JSON"}
        there=true
        leaf,problem=api_json_select(whole,rest,allocator,&there if allow_absent else nil)
        return leaf,there && problem=="",problem
    }
    if t:=component_table(s,head);t!=nil && t.name==head && readable(s,t) {return component(s,w,e,t,rest,omitted,scratch,allocator,allow_absent)}
    out:serial.Writer
    serial.writer_init(&out,0,allocator)
    small:=path=="" || head=="entity" || head=="world_position"
    if small {
        position:=entity_world(w,e).position
        serial.text_write_raw(&out,`{"entity":"`);serial.text_write_hex(&out,u64(e))
        serial.text_write_raw(&out,`","world_position":`);api.write_list(&out,position[:])
        serial.write_u8(&out,'}')
    } else {
        scratch:=scratch
        if scratch==nil {scratch=make([]u8,max(st.largest,1),allocator)}
        api_entity_write(s,w,&out,e,true,scratch,true,runtime)
    }
    whole,parse_error:=json.parse(serial.writer_bytes(&out),allocator=allocator)
    if parse_error!=nil {return nil,false,"the value could not be read back as JSON"}
    if doc,is_object:=whole.(json.Object);is_object && (small || head in doc) {
        there=true
        leaf,problem=api_json_select(whole,path,allocator,&there if allow_absent else nil)
        return leaf,there && problem=="",problem
    }
    named,wrong:=api_component_named(w,head)
    if !readable(s,named) {return nil,false,fmt.tprintf("%s, or a key of the entity as world_position",wrong!=""?wrong:head)}
    return component(s,w,e,named,rest,omitted,scratch,allocator,allow_absent)
}

// The value at a path inside a JSON value: names of fields joined by dots and
// [i] for element i of a list, from its end when negative (velocity[1], also
// velocity.1); "" is the whole value. missing says which part is not there
// and what is.
@(private)
api_json_select :: proc(value:json.Value,path:string,allocator:=context.temp_allocator,there:^bool=nil) -> (leaf:json.Value,missing:string) {
    leaf=value
    rest:=path
    for rest!="" {
        part:string
        if rest[0]=='[' {
            end:=strings.index_byte(rest,']')
            if end<0 {return nil,fmt.tprintf("%q has no ] that closes it",rest)}
            part,rest=rest[1:end],rest[end+1:]
            if strings.has_prefix(rest,".") {rest=rest[1:]}
        } else {
            end:=strings.index_any(rest,".[")
            switch {
            case end<0:          part,rest=rest,""
            case rest[end]=='.': part,rest=rest[:end],rest[end+1:]
            case:                part,rest=rest[:end],rest[end:]
            }
        }
        if part=="" {return nil,fmt.tprintf("%q has an empty name: join names with one dot",path)}
        #partial switch v in leaf {
        case json.Object:
            inner,has:=v[part]
            if !has {
                keys:=make([dynamic]string,allocator)
                for key in v {append(&keys,key)}
                return nil,fmt.tprintf("%q is not there; it has %s",part,strings.join(keys[:],", ",allocator))
            }
            leaf=inner
        case json.Array:
            index,number:=strconv.parse_int(part)
            if !number && len(part)==1 && len(v)>=2 && len(v)<=4 {
                index=strings.index_byte("xyzw",part[0])
                number=index>=0
            } else if number && index<0 {index+=len(v)}
            if number && (index<0 || index>=len(v)) && there!=nil {
                there^=false
                return nil,""
            }
            if !number || index<0 || index>=len(v) {return nil,fmt.tprintf("%q is not an element of a list of %d",part,len(v))}
            leaf=v[index]
        case:
            return nil,fmt.tprintf("%q goes inside a value that has nothing inside",part)
        }
    }
    return
}

// A JSON value as text; a number as short as it reads back the same.
@(private)
api_json_text :: proc(value:json.Value,allocator:=context.temp_allocator) -> string {
    if v,is_float:=value.(json.Float);is_float {
        buffer:=make([]u8,32,allocator)
        text:=strconv.write_float(buffer,f64(v),'g',-1,64)
        return text[1:] if strings.has_prefix(text,"+") else text
    }
    bytes,_:=json.marshal(value,allocator=allocator)
    return string(bytes)
}
