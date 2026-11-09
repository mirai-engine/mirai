package base

import "core:strings"
import "core:testing"

@(test)
a_name_resolves_only_to_the_one_candidate_it_can_mean :: proc(t:^testing.T) {
    names:=[]string{"Point_Light","Spot_Light","Foo_Bar","FooBar","Open"}
    cases:=[]struct{name:string,index,matches:int}{
        {"Point_Light",0,1},
        {"PointLight",0,1},
        {"point light",0,1},
        {"POINT-LIGHT",0,1},
        {"open",4,1},
        {"FooBar",3,1},
        {"foobar",-1,2},
        {"Light",-1,0},
        {"",-1,0},
        {"___",-1,0},
    }
    for c in cases {
        index,matches:=name_find(c.name,names)
        testing.expectf(t,index==c.index && matches==c.matches,"%q: %d of %d",c.name,index,matches)
    }
}

@(test)
what_is_wrong_with_a_name_lists_those_it_could_mean_or_the_nearest :: proc(t:^testing.T) {
    names:=[]string{"A","B","L","Enter","Left_Control","Right_Control","Point_Light","Spot_Light","Foo_Bar","FooBar"}
    cases:=[]struct{name,says:string}{
        {"LCtrl",`"LCtrl" is not one; the nearest are Left_Control`},
        {"Light",`"Light" is not one; the nearest are Spot_Light, Point_Light`},
        {"Fobar",`"Fobar" is not one; the nearest are Foo_Bar, FooBar`},
        {"Nope",`"Nope" is not one`},
        {"foobar",`"foobar" fits several: Foo_Bar, FooBar;`},
    }
    for c in cases {
        problem:=name_problem(c.name,"one",names,context.temp_allocator)
        testing.expectf(t,strings.has_prefix(problem,c.says),"%s",problem)
    }
    nearest:[NAME_NEAREST]int
    paths:=[]string{"textures/grass","meshes/grass_rock","meshes/stone"}
    testing.expect_value(t,names_nearest("grass rock",paths,nearest[:],context.temp_allocator),1)
    testing.expect_value(t,nearest[0],1)
    testing.expect_value(t,names_nearest("Nope",{"Animation_Progress","Name","Boss","Bob","Door"},nearest[:],context.temp_allocator),0)
    testing.expect_value(t,names_nearest("a",{"Alpha","Be","a_"},nearest[:],context.temp_allocator),1)
}
