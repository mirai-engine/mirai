package api

@(require) import "core:log"
@(require) import "core:testing"
@(require) import "core:time"

// Measurements of the hot paths: mirai test editor/api --release -define:API_BENCH=true
BENCH :: #config(API_BENCH,false)

when BENCH {

BENCH_ROUNDS :: 5

report :: proc(name:string,best:time.Duration,operations:int) {
    log.infof("%-46s %.1f ns/op   (%d ops)",name,f64(time.duration_nanoseconds(best))/f64(operations),operations)
}

// The fastest of several rounds: other processes can only make a round slower.
measure :: proc(name:string,operations:int,body:proc(operations:int)) {
    best:time.Duration
    for round in 0..<BENCH_ROUNDS {
        start:=time.tick_now()
        body(operations)
        elapsed:=time.tick_since(start)
        if round==0 || elapsed<best {best=elapsed}
    }
    report(name,best,operations)
}

@(test)
bench_process :: proc(t:^testing.T) {
    f:Fixture
    err:=server_init(&f.server,{})
    testing.expect_value(t,err,Init_Error.None)
    defer server_destroy(&f.server)
    testing.expect_value(t,method_register(&f.server,{name="test.add",params=Add_Params,result=Add_Result,handler=add_handler}),Register_Error.None)
    testing.expect_value(t,method_register(&f.server,{name="test.shapes",params=Shapes,result=Shapes,handler=shapes_handler}),Register_Error.None)
    testing.expect_value(t,method_register(&f.server,{name="test.raw",params=Raw_Params,result=Raw_Result,writes_result=true,handler=raw_handler}),Register_Error.None)
    @(static) server:^Server
    server=&f.server
    measure("process: typed call, two integers",100000,proc(n:int) {
        for _ in 0..<n {process(server,`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":2,"b":-5}}`,.Rpc)}
    })
    measure("process: typed call, ten fields round trip",100000,proc(n:int) {
        for _ in 0..<n {process(server,`{"jsonrpc":"2.0","id":1,"method":"test.shapes","params":{"position":[1,2,3],"mode":"Run","flags":["Ice"],"inner":{"x":9},"name":"ok","signed":-5}}`,.Rpc)}
    })
    measure("process: free-form call",100000,proc(n:int) {
        for _ in 0..<n {process(server,`{"jsonrpc":"2.0","id":1,"method":"test.raw","params":{"ops":[{"k":1},{"k":2}]}}`,.Rpc)}
    })
    measure("process: invalid params",100000,proc(n:int) {
        for _ in 0..<n {process(server,`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1}}`,.Rpc)}
    })
    measure("process: batch of ten calls",10000,proc(n:int) {
        for _ in 0..<n {process(server,`[{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":1,"b":2}},{"jsonrpc":"2.0","id":2,"method":"test.add","params":{"a":1,"b":2}},{"jsonrpc":"2.0","id":3,"method":"test.add","params":{"a":1,"b":2}},{"jsonrpc":"2.0","id":4,"method":"test.add","params":{"a":1,"b":2}},{"jsonrpc":"2.0","id":5,"method":"test.add","params":{"a":1,"b":2}},{"jsonrpc":"2.0","id":6,"method":"test.add","params":{"a":1,"b":2}},{"jsonrpc":"2.0","id":7,"method":"test.add","params":{"a":1,"b":2}},{"jsonrpc":"2.0","id":8,"method":"test.add","params":{"a":1,"b":2}},{"jsonrpc":"2.0","id":9,"method":"test.add","params":{"a":1,"b":2}},{"jsonrpc":"2.0","id":10,"method":"test.add","params":{"a":1,"b":2}}]`,.Rpc)}
    })
    measure("process: engine.describe, list of three methods",10000,proc(n:int) {
        for _ in 0..<n {process(server,`{"jsonrpc":"2.0","id":1,"method":"engine.describe"}`,.Rpc)}
    })
    measure("process: engine.describe, schemas of three methods",10000,proc(n:int) {
        for _ in 0..<n {process(server,`{"jsonrpc":"2.0","id":1,"method":"engine.describe","params":{"prefix":"test."}}`,.Rpc)}
    })
    measure("process: MCP tools/call",100000,proc(n:int) {
        for _ in 0..<n {process(server,`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"test_add","arguments":{"a":2,"b":-5}}}`,.Mcp)}
    })
}

@(test)
bench_loopback :: proc(t:^testing.T) {
    f:Fixture;if !fixture_start(&f,t) {return}
    defer fixture_finish(&f)
    @(static) fixture:^Fixture
    fixture=&f
    measure("loopback: one call per connection",2000,proc(n:int) {
        for _ in 0..<n {post(fixture,"/rpc",`{"jsonrpc":"2.0","id":1,"method":"test.add","params":{"a":2,"b":-5}}`)}
    })
}

}
