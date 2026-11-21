package shaders

import "core:fmt"
import "core:strings"

// The loader and the store of the Attributes of a Vfx program: its words at
// the offsets Slang reflects, from the byte offset of the particle in
// particle_data. The store only exists in the stages that write particles.
// A message for a layout the pool does not hold.
@(private)
vfx_attributes :: proc(out:^strings.Builder,name:string,layout:Layout) -> string {
    if layout.size>ATTRIBUTE_BYTES {return fmt.tprintf("%s: Attributes takes %d bytes; a particle holds %d",name,layout.size,ATTRIBUTE_BYTES)}
    axes:="xyzw"
    for field in layout.fields {
        scalar:=field.scalar
        if (field.kind!="scalar" && field.kind!="vector") || field.count<1 || field.count>4 || (scalar!="float32" && scalar!="int32" && scalar!="uint32" && scalar!="bool") {
            return fmt.tprintf("%s.%s: Attributes takes float, int, uint and bool scalars and vectors of up to four",name,field.name)
        }
        if field.offset%4!=0 || field.offset+field.count*4>ATTRIBUTE_BYTES {return fmt.tprintf("%s.%s: an attribute out of the %d bytes of a particle",name,field.name,ATTRIBUTE_BYTES)}
    }
    fmt.sbprintf(out,"%s::Attributes mirai_attributes_load_%s(uint at) {{\n    %s::Attributes a=(%s::Attributes)0;\n",name,name,name,name)
    for field in layout.fields {
        for i in 0..<field.count {
            component:=field.count>1?fmt.tprintf(".%s",axes[i:][:1]):""
            load:=fmt.tprintf("particle_data.Load(at+%du)",field.offset+i*4)
            switch field.scalar {
            case "float32": fmt.sbprintf(out,"    a.%s%s=asfloat(%s);\n",field.name,component,load)
            case "int32":   fmt.sbprintf(out,"    a.%s%s=asint(%s);\n",field.name,component,load)
            case "bool":    fmt.sbprintf(out,"    a.%s%s=%s!=0u;\n",field.name,component,load)
            case:           fmt.sbprintf(out,"    a.%s%s=%s;\n",field.name,component,load)
            }
        }
    }
    strings.write_string(out,"    return a;\n}\n#ifdef PARTICLES_WRITABLE\n")
    fmt.sbprintf(out,"void mirai_attributes_store_%s(uint at,%s::Attributes a) {{\n",name,name)
    for field in layout.fields {
        for i in 0..<field.count {
            component:=field.count>1?fmt.tprintf(".%s",axes[i:][:1]):""
            value:=field.scalar=="bool"?fmt.tprintf("(a.%s%s?1u:0u)",field.name,component):fmt.tprintf("asuint(a.%s%s)",field.name,component)
            fmt.sbprintf(out,"    particle_data.Store(at+%du,%s);\n",field.offset+i*4,value)
        }
    }
    strings.write_string(out,"}\n#endif\n")
    return ""
}


Vfx_Use :: enum {Emit,Simulate,Stage,Trace,Rebase}
Vfx_Uses :: bit_set[Vfx_Use]
Vfx_Program_Uses :: struct {name:string,uses:Vfx_Uses}

// Simulation can trace for built-in collision and lighting independently of the Vfx program.
@(private)
vfx_stage_uses :: proc(source,variant:string,uses:Vfx_Uses) -> (used,rays:bool) {
    switch source {
    case "particle_shift": return .Rebase in uses,false
    case "particle_emit": return .Emit in uses && (variant!="hw" || .Trace in uses),.Trace in uses
    case "particle_simulate": return .Simulate in uses,true
    case "particle_stage": return .Stage in uses && (variant!="hw" || .Trace in uses),.Trace in uses
    case "particle_mesh","particle_mesh_blend": return false,false
    case: return true,true
    }
}
