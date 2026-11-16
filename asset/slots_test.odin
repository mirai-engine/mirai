package asset

import "core:strings"
import "core:testing"
import "mirai:std/base"

@(test)
slots_are_named_by_asset_and_a_name_of_several_fails_listing_them :: proc(t:^testing.T) {
    names:=[]string{"materials/grass.mat","materials/rock.mat","materials/rock.mat#2",SLOT_EMPTY_NAME}
    ids:=[]base.Asset_Id{{1,1},{2,2},{2,2},{}}
    Case :: struct {given:string,index:int}
    for c in ([]Case{
        {"materials/grass.mat",0},
        {"materials/grass",0},
        {"grass",0},
        {"rock#2",2},
        {"materials/rock.mat#2",2},
        {SLOT_EMPTY_NAME,3},
        {"00000000000000010000000000000001",0},
    }) {
        index,problem:=slot_named(names,ids,c.given,"layers")
        testing.expectf(t,index==c.index && problem=="","%s: %d %s",c.given,index,problem)
    }
    _,several:=slot_named(names,ids,"rock","layers")
    testing.expectf(t,strings.contains(several,"materials/rock.mat#2"),"%s",several)
    _,missing:=slot_named(names,ids,"sand","layers")
    testing.expectf(t,strings.contains(missing,"grass"),"%s",missing)
    _,past:=slot_named(names,ids,"rock#3","layers")
    testing.expect(t,past!="")
}
