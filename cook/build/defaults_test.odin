package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(private="file")
DEFAULTS_CORE :: `package core
@(component) Health :: struct {hp:f32,regen:f32,armor:f32}
HEALTH_DEFAULT :: Health{hp=100,regen=1}
@(component) Spot :: struct {position:[3]f32,scale:[3]f32}
SPOT_ONE :: Spot{{0,0,0},{1,1,1}}
SPOT_DEFAULT :: SPOT_ONE
@(component) Cell :: struct {count:int}
cell_default :: proc() -> Cell {return Cell{count=4}}
@(component) Plain :: struct {value:f32}
`

// A literal of a type whose default sets a field names that field or starts
// from the default; zeros of the default ask nothing, the declaration that
// builds the default is its own, and a literal compared makes no value.
@(test)
a_literal_of_a_type_with_a_default_names_what_the_default_sets :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"defaults")
    if folder=="" {return}
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    for path in ([]string{project.path(engine,"core",allocator=context.temp_allocator),project.path(game,"game",allocator=context.temp_allocator)}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    if !testing.expect(t,os.write_entire_file(project.path(engine,"core","data.odin",allocator=context.temp_allocator),DEFAULTS_CORE)==nil) {return}
    cases:=[]struct{code,says:string}{
        {"h:=core.Health{}","core.Health{...} leaves out hp, regen, which core.HEALTH_DEFAULT sets"},
        {"h:=core.Health{hp=5}","leaves out regen, which core.HEALTH_DEFAULT sets"},
        {"h:=core.Health{hp=5,regen=0}",""},
        {"h:=core.HEALTH_DEFAULT;h.armor=2",""},
        {"s:=core.Spot{scale={2,2,2}}",""},
        {"s:=core.Spot{position={1,0,0}}","leaves out scale, which core.SPOT_DEFAULT sets"},
        {"c:=core.Cell{}","leaves out count, which core.cell_default() sets"},
        {"p:=core.Plain{}",""},
        {"same:=core.HEALTH_DEFAULT==core.Health{}",""},
    }
    for c in cases {
        source:=strings.concatenate({"package game\nimport \"mirai:core\"\nuse :: proc() {\n    ",c.code,"\n}\n"},context.temp_allocator)
        if !testing.expect(t,os.write_entire_file(project.path(game,"game","game.odin",allocator=context.temp_allocator),source)==nil) {return}
        p:=project.Project{root=game,engine_root=engine}
        errors:=world_generate(&p,context.temp_allocator).errors
        if c.says=="" {
            testing.expectf(t,len(errors)==0,"%s: %v",c.code,errors)
            continue
        }
        found:=false
        for message in errors {found||=strings.contains(message,c.says) && strings.contains(message,"game.odin(4:")}
        testing.expectf(t,found,"%s: no error says %q: %v",c.code,c.says,errors)
    }
}
