package mirai_net

import "core:testing"
import "mirai:std/serial"

@(test)
protocol_hash_distinguishes_fragment_boundaries_with_identical_leaf_encodings :: proc(t:^testing.T) {
    AB :: struct {a,b:u32}
    C :: struct {c:u32}
    A :: struct {a:u32}
    BC :: struct {b,c:u32}
    schema:serial.Schema;serial.schema_init(&schema);defer serial.schema_destroy(&schema)
    ab,_:=serial.schema_add(&schema,AB);c,_:=serial.schema_add(&schema,C)
    a,_:=serial.schema_add(&schema,A);bc,_:=serial.schema_add(&schema,BC)
    first,second:Protocol;protocol_init(&first);protocol_init(&second)
    defer protocol_destroy(&first);defer protocol_destroy(&second)
    one,ok_first:=type_register(&first,"same",{{schema=&schema,type=ab},{schema=&schema,type=c}})
    other,ok_second:=type_register(&second,"same",{{schema=&schema,type=a},{schema=&schema,type=bc}})
    if !testing.expect(t,ok_first && ok_second) {return}
    first_hash,_:=protocol_seal(&first)
    second_hash,_:=protocol_seal(&second)
    for leaf,i in first.types[one].leaves {
        theirs:=second.types[other].leaves[i]
        testing.expect(t,leaf.kind==theirs.kind && leaf.bit==theirs.bit && leaf.bits==theirs.bits)
    }
    testing.expect(t,first_hash!=second_hash)
}
