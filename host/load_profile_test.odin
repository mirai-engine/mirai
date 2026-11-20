package host

import "core:strings"
import "core:testing"
import "mirai:rhi"

// A load says nothing of pipelines it did not compile, and of those it did,
// why: a first start, an update of the driver, or a start that read the kept
// pipelines and still compiled (keys that changed).
@(test)
load_pipelines_note_says_why_pipelines_compiled :: proc(t:^testing.T) {
    Case :: struct {name:string,pipelines:Load_Pipelines,store:rhi.Pipeline_Store_State,words:[]string}
    cases:=[]Case{
        {"all kept",{made=100,kept=100},.Read,nil},
        {"nothing made",{},.Missing,nil},
        {"keys changed",{made=100,kept=97,ns=4_000_000},.Read,{"3 pipelines without a confirmed cache hit","although the kept pipelines were read"}},
        {"first start",{made=100},.Missing,{"100 pipelines","first start"}},
        {"driver updated",{made=100},.Other_Device,{"driver was updated"}},
        {"frames late only",{made=5,kept=5,late=12},.Read,{"12 frames drew materials without their pipelines"}},
        {"both",{made=10,kept=4,late=3},.Read,{"6 pipelines without a confirmed cache hit","3 frames"}},
    }
    for c in cases {
        note:=load_pipelines_note(Load_Summary{pipelines=c.pipelines,store=c.store})
        if len(c.words)==0 {testing.expectf(t,note=="","%s: says nothing, not %q",c.name,note)}
        for word in c.words {testing.expectf(t,strings.contains(note,word),"%s: %q says %q",c.name,note,word)}
    }
}
