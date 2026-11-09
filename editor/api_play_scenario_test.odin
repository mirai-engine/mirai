package editor

import "core:strings"
import "core:testing"

// A step that answered holds unless its answer says passed false or it is a
// play.step with until that ran out of ticks before they held.
@(test)
a_scenario_step_holds_unless_its_check_fails_or_its_until_runs_out :: proc(t:^testing.T) {
    cases:=[?]struct{params,answer:string,held:bool,says:string}{
        {`{"conditions":[{}]}`,`{"passed":true,"tick":3,"results":[]}`,true,""},
        {`{"conditions":[{}]}`,`{"passed":false,"tick":3,"results":[]}`,false,"did not hold"},
        {`{"for":5}`,`{"ran":5,"met":false}`,true,""},
        {`{"for":5,"until":[{}]}`,`{"ran":5,"met":false}`,false,"until did not hold"},
        {`{"for":5,"until":[{}]}`,`{"ran":2,"met":true}`,true,""},
        {`{}`,`null`,true,""},
    }
    for c in cases {
        held,why:=scenario_step_held(c.params,c.answer)
        testing.expectf(t,held==c.held && strings.contains(why,c.says),"%s %s: %v %s",c.params,c.answer,held,why)
    }
}
