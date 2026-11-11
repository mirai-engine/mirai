package destruct

import "mirai:core"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import phys "plugins:physics/runtime"

// Strain that lasts on what breaks in the Volume of its entity, a box or a
// sphere: heat that weakens a wall, a press. Each tick it asks physics for
// its strain by the tick in that volume (phys.strain_area), which reaches
// every body of the breakables its filter sees by the weight of the volume:
// whole inside, rising from its border over its blend. The region of a
// break travels in its event as a box or a sphere, so no other shape strains.
@(component,description="Strains the destructibles in the Volume of its entity, a box or a sphere, every tick: damage that breaks them, or with weakening, strain they keep without letting pieces go.")
Strain_Field :: struct {
    strain:f32 `mirai:"min=0"`, // N s per second
    weakening:bool,
    blend:f32 `mirai:"min=0,unit=m"`, // inside the border of the Volume, where the strain rises from 0
    filter:phys.Query_Filter,
}

STRAIN_FIELD_DEFAULT :: Strain_Field{filter={objects=phys.COLLISION_LAYERS_ALL}}

// The server decides what breaks: a client asks for no strain.
@(step="fixed",stage="simulate",before="physics_prepare")
strain_fields_step :: proc(
    fields:core.Read(Strain_Field),volumes:core.Read(volume.Volume),worlds:core.Read(core.World_Transform),parents:core.Read(core.Parent),sections:core.Read(scene.Scene_Reference),authority:core.Ref(core.Network),
    bodies:^phys.Body_Requests,time:core.Time,problems:^core.Problems,
) {
    if !time.playing || !(time.dt>0) || authority.role==.Client {return}
    for row in 0..<core.count(fields) {
        field:=core.at(fields,row)
        if !(field.strain>0) {continue}
        e:=core.entity_at(fields,row)
        area,pose,rules:=volume.placed({volumes,worlds,parents,sections},e)
        if !rules {continue}
        if area.shape!=.Box && area.shape!=.Sphere {
            core.report(problems,e,"destruct.strain_field","its Strain_Field strains nothing: it needs a Volume of shape Box or Sphere on its entity (volume.box, volume.sphere)")
            continue
        }
        phys.strain_area(bodies,area,pose,field.strain*time.dt,field.weakening,field.filter,field.blend)
    }
}
