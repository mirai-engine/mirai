package sqlite

import "core:c"

when ODIN_OS==.Windows {
    foreign import lib "windows/sqlite.lib"
} else when ODIN_OS==.Linux {
    foreign import lib "linux/sqlite.a"
} else when ODIN_OS==.Darwin {
    when ODIN_ARCH==.arm64 {foreign import lib "macos-arm64/sqlite.a"}
    else {foreign import lib "macos/sqlite.a"}
}

// The part of the SQLite C API the editor uses (third_party/sqlite/UPSTREAM.md).

Db :: struct {}
Stmt :: struct {}

OK :: 0
BUSY :: 5
CORRUPT :: 11
NOTADB :: 26
ROW :: 100
DONE :: 101

OPEN_READWRITE :: 0x00000002
OPEN_CREATE :: 0x00000004
OPEN_NOMUTEX :: 0x00008000

// The destructor of a bound text that has SQLite copy it before the call returns.
TRANSIENT :: rawptr(~uintptr(0))

@(default_calling_convention="c",link_prefix="sqlite3_")
foreign lib {
    open_v2 :: proc(filename:cstring,db:^^Db,flags:c.int,vfs:cstring) -> c.int ---
    close_v2 :: proc(db:^Db) -> c.int ---
    errmsg :: proc(db:^Db) -> cstring ---
    errcode :: proc(db:^Db) -> c.int ---
    exec :: proc(db:^Db,sql:cstring,callback:rawptr,argument:rawptr,error:^cstring) -> c.int ---
    busy_timeout :: proc(db:^Db,milliseconds:c.int) -> c.int ---
    prepare_v2 :: proc(db:^Db,sql:[^]u8,bytes:c.int,statement:^^Stmt,tail:^[^]u8) -> c.int ---
    finalize :: proc(statement:^Stmt) -> c.int ---
    reset :: proc(statement:^Stmt) -> c.int ---
    step :: proc(statement:^Stmt) -> c.int ---
    bind_int64 :: proc(statement:^Stmt,index:c.int,value:i64) -> c.int ---
    bind_double :: proc(statement:^Stmt,index:c.int,value:f64) -> c.int ---
    bind_text :: proc(statement:^Stmt,index:c.int,text:[^]u8,bytes:c.int,destructor:rawptr) -> c.int ---
    column_int64 :: proc(statement:^Stmt,column:c.int) -> i64 ---
    column_double :: proc(statement:^Stmt,column:c.int) -> f64 ---
    column_text :: proc(statement:^Stmt,column:c.int) -> [^]u8 ---
    column_bytes :: proc(statement:^Stmt,column:c.int) -> c.int ---
}
