package ai

import "core:testing"

@(test)
response_curves_map_inputs_to_scores :: proc(t:^testing.T) {
    linear:=Response{kind=.Linear,slope=1}
    testing.expect(t,near(response_evaluate(linear,0.25),0.25) && near(response_evaluate(linear,2),1) && near(response_evaluate(linear,-1),0))
    testing.expect(t,near(response_evaluate({kind=.Linear,slope=1,invert=true},0.25),0.75))
    squared:=Response{kind=.Polynomial,degree=2,slope=1}
    testing.expect(t,near(response_evaluate(squared,0.5),0.25))
    shifted:=Response{kind=.Polynomial,degree=2,slope=4,shift_x=0.5}
    testing.expect(t,near(response_evaluate(shifted,0.5),0) && near(response_evaluate(shifted,0.75),0.25))
    sigmoid:=Response{kind=.Sigmoid,slope=10,shift_x=0.5}
    low,mid,high:=response_evaluate(sigmoid,0),response_evaluate(sigmoid,0.5),response_evaluate(sigmoid,1)
    testing.expect(t,near(mid,0.5) && low<0.1 && high>0.9 && low<response_evaluate(sigmoid,0.4) && response_evaluate(sigmoid,0.6)<high)
    step:=Response{kind=.Step,shift_x=0.6}
    testing.expect(t,response_evaluate(step,0.59)==0 && response_evaluate(step,0.6)==1)
    testing.expect(t,response_evaluate({kind=.Step,shift_x=0.6,shift_y=0.2},0.1)==0.2)
}

@(test)
considerations_score_their_product_compensated_for_their_count :: proc(t:^testing.T) {
    half:=Consideration{input=0,min=0,max=1,response={kind=.Linear,slope=1}}
    a,b:=score_considerations({half},1,{0.5}),score_considerations({half,half,half},1,{0.5})
    testing.expect(t,near(a,0.5))
    testing.expect(t,b>0.5*0.5*0.5 && near(b,0.125+(1-0.125)*(1-1.0/3)*0.125,1e-4))
    // A zero vetoes the choice; without considerations it is worth its weight.
    testing.expect(t,score_considerations({half,half,half},1,{0})==0)
    testing.expect(t,near(score_considerations(nil,0.2,nil),0.2))
    // A missing input reads as zero and an empty range is a threshold.
    testing.expect(t,near(score_considerations({{input=5,min=0,max=1,response={kind=.Linear,slope=1,shift_y=0.25}}},1,{1}),0.25))
    threshold:=Consideration{input=0,min=3,max=3,response={kind=.Linear,slope=1}}
    testing.expect(t,score_considerations({threshold},1,{2.9})==0 && score_considerations({threshold},1,{3})==1)
}
