package main

import "core:strings"
import "core:testing"

@(test)
the_lint_reports_a_write_to_a_copy_of_a_row_that_reaches_nothing :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    // The source is the body of a file after its package line and its import
    // of core; flagged, the locals the lint reports, in order.
    Case :: struct {name,source:string,flagged:[]string}
    cases:=[]Case{
        // Each form that writes a copy and nothing else.
        {"a field of what at gave",
            `f :: proc(lamps:^core.Table(Lamp)) {for row in 0..<core.count(lamps) {lamp:=core.at(lamps,row);lamp.lit=true}}`,
            {"lamp"}},
        {"a field of the first value of get",
            `f :: proc(points:^core.Table(Light),e:core.Entity) {light,found:=core.get(points,e);if !found {return};light.intensity=3}`,
            {"light"}},
        {"the value of a Read",
            `f :: proc(points:core.Read(Light),e:core.Entity) {light,_:=core.get(points,e);light.intensity+=1}`,
            {"light"}},
        {"bound in the init of an if",
            `f :: proc(t:^core.Table(Health),e:core.Entity) {if health,ok:=core.get(t,e);ok {health.hp-=1}}`,
            {"health"}},
        {"an element, and a field of an element",
            `f :: proc(t:^core.Table(Mesh),row:int) {mesh:=core.at(t,row);mesh.materials[0]=1;mesh.slots[2].on=true}`,
            {"mesh"}},
        {"assigned whole",
            `f :: proc(t:^core.Table(Health),row:int,full:Health) {health:=core.at(t,row);health=full}`,
            {"health"}},
        {"under or_else, or_continue and or_return",
            `f :: proc(t:^core.Table(Health),es:[]core.Entity) -> bool {
                a:=core.get(t,es[0]) or_else Health{};a.hp=1
                for e in es {b:=core.get(t,e) or_continue;b.hp=2}
                c:=core.get(t,es[1]) or_return;c.hp=3
                return true
            }`,
            {"a","b","c"}},
        {"the address of a field kept to write through it",
            `f :: proc(agents:^core.Table(Agent),row:int) {agent:=core.at(agents,row);state:=&agent.state;state.fear=1}`,
            {"agent"}},
        {"written where its row was found",
            `f :: proc(t:^core.Table(Pose),e:core.Entity) {pose,found:=core.get(t,e);if found {pose.scale=2} else {pose.scale=1}}`,
            {"pose"}},
        {"a loop through its elements by reference",
            `f :: proc(t:^core.Table(Mesh),row:int,wanted:u64) {mesh:=core.at(t,row);for &material in mesh.materials {material=wanted}}`,
            {"mesh"}},
        {"used whole only before the write",
            `f :: proc(t:^core.Table(Health),row:int) {health:=core.at(t,row);show(health);health.hp=0}`,
            {"health"}},
        {"its fields read after the write",
            `f :: proc(t:^core.Table(Timer),row:int,dt:f32) -> bool {timer:=core.at(t,row);timer.left-=dt;return timer.left<=0}`,
            {"timer"}},
        {"bound by an assignment",
            `f :: proc(t:^core.Table(Health),e:core.Entity) {health:Health;found:bool;health,found=core.get(t,e);if found {health.hp=1}}`,
            {"health"}},
        {"a name another block gave a pointer first",
            `f :: proc(t:^core.Table(Health),a,b:core.Entity) {
                if health:=core.edit(t,a);health!=nil {health.hp=1}
                if health,ok:=core.get(t,b);ok {health.hp=2}
            }`,
            {"health"}},
        {"core imported by another name",
            "",
            {"health"}},

        // The forms that write the row, or a value meant to go elsewhere.
        {"read, change the copy and set it",
            `f :: proc(points:^core.Table(Light),e:core.Entity,on:bool) {if light,ok:=core.get(points,e);ok {light.intensity=on?800:0;core.set(points,e,light)}}`,
            {}},
        {"set_at, and set in a defer",
            `f :: proc(t:^core.Table(Lamp),row:int) {lamp:=core.at(t,row);lamp.lit=true;core.set_at(t,row,lamp)}
            g :: proc(t:^core.Table(Lamp),e:core.Entity) {lamp,_:=core.get(t,e);defer core.set(t,e,lamp);lamp.lit=true}`,
            {}},
        {"a scratch value given to another procedure, returned or stored",
            `f :: proc(t:core.Read(Pose),row:int,out:^Pose) -> Pose {
                a:=core.at(t,row);a.position.y=0;draw(a)
                b:=core.at(t,row);b.scale=1;out^=b
                c:=core.at(t,row);c.position.x+=1
                return c
            }`,
            {}},
        {"added to another entity",
            `f :: proc(t:^core.Table(Pose),from,to:core.Entity) {pose,_:=core.get(t,from);pose.position.y+=1;core.add(t,to,pose)}`,
            {}},
        {"written in a loop that uses it whole on its next turn",
            `f :: proc(t:core.Read(Pose),row:int) {pose:=core.at(t,row);for i in 0..<3 {draw(pose);pose.position.x+=1}}`,
            {}},
        {"the pointer edit gives, and a field of what at gave",
            `f :: proc(t:^core.Table(Pose),e:core.Entity,row:int) {
                if pose:=core.edit(t,e);pose!=nil {pose.position.y=0}
                at:=core.edit_at(t,row);at.scale=1
                position:=core.at(t,row).position;position.y=0
            }`,
            {}},
        {"bound again from another read",
            `f :: proc(t:core.Read(Pose),rows:int) -> f32 {best:=core.at(t,0);for row in 1..<rows {if core.at(t,row).scale>best.scale {best=core.at(t,row)}};return best.scale}`,
            {}},
        {"a name another block gives a pointer after",
            `f :: proc(t:^core.Table(Health),a,b:core.Entity) -> f32 {
                total:f32
                if health,ok:=core.get(t,a);ok {total+=health.hp}
                if health:=core.edit(t,b);health!=nil {health.hp=2}
                return total
            }`,
            {}},
        {"a field, a label and an argument named as the copy",
            `f :: proc(t:core.Read(Lamp),row:int,out:^Room) {lamp:=core.at(t,row);out.lamp=Lamp{};out.lamps[0].lit=lamp.lit;show(lamp=Lamp{})}`,
            {}},
        {"a procedure inside another does not see its locals",
            `f :: proc(t:core.Read(Lamp),row:int) -> bool {
                lamp:=core.at(t,row)
                light :: proc(lamp:^Lamp) {lamp.lit=true}
                return lamp.lit
            }`,
            {}},
        {"the get of another package",
            `f :: proc(cache:^Cache,key:u64) {entry:=cache_table.get(cache,key);entry.used=true}`,
            {}},
        {"a default given where no row was found",
            `f :: proc(t:core.Read(Pose),e:core.Entity) -> f32 {pose,found:=core.get(t,e);if !found {pose.rotation=1;pose.scale=1};return pose.scale*2}`,
            {}},
        {"the address of a field given to a procedure that reads it",
            `f :: proc(t:core.Read(Mind),e:core.Entity) -> int {mine,_:=core.get(t,e);return count(&mine.memory)}`,
            {}},
        {"its own address given to a procedure that fills it",
            `f :: proc(t:^core.Table(Pose),row:int) {pose:=core.at(t,row);pose.scale=2;settle(&pose)}`,
            {}},
    }
    for c in cases {
        source:=strings.concatenate({"package sample\nimport \"mirai:core\"\n",c.source,"\n"})
        if c.source=="" {source="package sample\nimport ecs \"mirai:core\"\nf :: proc(t:^ecs.Table(Health),row:int) {health:=ecs.at(t,row);health.hp=1}\n"}
        findings:=make([dynamic]Row_Copy_Finding)
        if !testing.expectf(t,row_copy_lint_source("sample.odin",source,&findings),"%s: it parses",c.name) {continue}
        if !testing.expectf(t,len(findings)==len(c.flagged),"%s: %d reported, %d expected: %v",c.name,len(findings),len(c.flagged),findings[:]) {continue}
        for f,i in findings {
            testing.expectf(t,f.name==c.flagged[i],"%s: reported %s, expected %s",c.name,f.name,c.flagged[i])
            testing.expectf(t,f.line>=3 && f.column>=1,"%s: %s has its place",c.name,f.name)
        }
    }
    // Inside core the reads have no package before them, and a source without core has none.
    findings:=make([dynamic]Row_Copy_Finding)
    testing.expect(t,row_copy_lint_source("core.odin","package core\nf :: proc(t:^Table(Name),row:int) {name:=at(t,row);name.text[0]=0}\n",&findings))
    testing.expect_value(t,len(findings),1)
    clear(&findings)
    testing.expect(t,row_copy_lint_source("other.odin","package other\nf :: proc(t:^Thing,row:int) {name:=at(t,row);name.text[0]=0}\n",&findings))
    testing.expect_value(t,len(findings),0)
    testing.expect(t,!row_copy_lint_source("broken.odin","package broken\nf :: proc( {\n",&findings))
}
