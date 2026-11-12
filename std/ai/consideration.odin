package ai

import "mirai:std/math"

// Considerations: each reads one input, maps it through a response curve to
// a score from 0 to 1, and the score of a choice is their product (a
// consideration at 0 vetoes it) compensated so that a choice with many
// considerations is not penalized, times its weight. Only arithmetic is
// used, so scores are the same on every platform.

Response_Kind :: enum u8 {
    Linear,     // slope*(x-shift_x)+shift_y
    Polynomial, // slope*(x-shift_x)^degree+shift_y
    Sigmoid,    // an S around shift_x with steepness slope, from 0 to 1, plus shift_y
    Step,       // 1 from shift_x on, 0 before it, plus shift_y
}

// A curve over inputs normalized to 0..1; the result is clamped to 0..1.
Response :: struct {
    kind:Response_Kind,
    degree:u8, // Polynomial
    slope,shift_x,shift_y:f32,
    invert:bool, // 1 - result
}

response_evaluate :: proc "contextless" (r:Response,x:f32) -> f32 {
    y:f32
    switch r.kind {
    case .Linear: y=r.slope*(x-r.shift_x)+r.shift_y
    case .Polynomial:
        power:f32=1
        for _ in 0..<r.degree {power*=x-r.shift_x}
        y=r.slope*power+r.shift_y
    case .Sigmoid:
        s:=r.slope*(x-r.shift_x)
        y=0.5+0.5*s/(1+abs(s))+r.shift_y
    case .Step: y=(1 if x>=r.shift_x else 0)+r.shift_y
    }
    y=math.saturate(y)
    return 1-y if r.invert else y
}

// Reads `inputs[input]`, rescales it from [min, max] to 0..1 and applies the curve.
Consideration :: struct {
    input:u16,
    min,max:f32,
    response:Response,
}

// The score of one consideration, from 0 to 1. An input index past `inputs` reads as 0.
consideration_score :: proc "contextless" (c:Consideration,inputs:[]f32) -> f32 {
    x:f32=inputs[c.input] if int(c.input)<len(inputs) else 0
    span:=c.max-c.min
    normalized:=math.saturate((x-c.min)/span) if span!=0 else (1 if x>=c.max else 0)
    return response_evaluate(c.response,normalized)
}

// The score of one choice: the product of its considerations, compensated for
// their count, times its weight; its weight without considerations.
score_considerations :: proc "contextless" (considerations:[]Consideration,weight:f32,inputs:[]f32) -> f32 {
    if len(considerations)==0 {return weight}
    product:f32=1
    for c in considerations {
        product*=consideration_score(c,inputs)
        if product==0 {return 0}
    }
    return score_product(product,len(considerations),weight)
}

// The score of a choice from the product of its `count` considerations, as
// score_considerations gives it.
score_product :: proc "contextless" (product:f32,count:int,weight:f32) -> f32 {
    if count<=0 {return weight}
    compensation:=1-1/f32(count)
    return (product+(1-product)*compensation*product)*weight
}
