package pcg

import volume "mirai:engine/volume"
import "mirai:std/base"
import mm "mirai:std/math"

// Procedural content generation without stored placements: a Pcg_Graph shows
// what the layers of a .pcg asset place, cell by cell, again from its seed
// wherever it is resident (generate.odin). The cells are square, of the cell
// size of the source, in the frame of the graph: its entity, or the world
// for a world-anchored graph, whose points stay where they are when the
// entity moves. A Volume on the graph entity bounds where it places; without
// one, it places around the streaming sources. Pcg_Zone entities say where
// it places more, less or nothing. What the game or the editor takes out is a
// Pcg_Suppressed entity (suppressed.odin), never an edit of the asset.

@(component,far,description="Places what the layers of a .pcg asset generate in the cells of this entity, or of the world when world anchored, within its Volume; without a Volume, around the streaming sources.")
Pcg_Graph :: struct {
    source:base.Asset_Id `mirai:"kind=.pcg"`,
    seed:u32,                         // mixed with the seed of the source: another seed, other points
    revision:u32 `mirai:"readonly"`,  // of the source it shows: the key of the history of its editor
    world_anchored:bool,              // the cells are of the world: moving the entity does not move what it places
}

// The seed the points of a graph come from: that of its source, alone for a
// graph seed of 0.
graph_seed :: proc "contextless" (source_seed,graph_seed:u32) -> u32 {
    if graph_seed==0 {return source_seed}
    return u32(base.hash_u64(u64(source_seed)<<32|u64(graph_seed)))
}

// The frame of the cells of a graph whose entity is at transform.
graph_frame :: proc "contextless" (g:Pcg_Graph,transform:mm.Transform) -> mm.Transform {
    return mm.TRANSFORM_IDENTITY if g.world_anchored else transform
}

@(component,description="Where the Pcg_Graph of the world place more, less or nothing: within the Volume of this entity, or along the width of its Spline. Excluding, nothing is placed in it; else its weight is mask(channel) of the field expressions there, blending over the zone's border.")
Pcg_Zone :: struct {
    zone:volume.Zone, // its blend is where the mask goes from 0 to its weight; priority orders the zones of a channel
    channel:u32 `mirai:"max=7"`, // the mask of the field expressions it gives (mask(channel)); a Grammar layer of this channel runs along its Spline
    weight:f32 `mirai:"min=0,max=1"`, // of its mask inside it, past its blend
    exclude:bool, // nothing is placed in it, whatever the channel
}

PCG_ZONE_DEFAULT :: Pcg_Zone{zone=volume.ZONE_DEFAULT,weight=1}

MASKS_MAX :: 8 // channels of the zones, which mask(i) reads
