package effect

Particle_Preset :: enum u8 {Default,Fire,Smoke,Sparks,Muzzle_Flash,Blood,Debris,Trail,Beam}

particle_preset :: proc(preset:Particle_Preset) -> (info:Particle_Info) {
    info=PARTICLE_DEFAULTS
    switch preset {
    case .Default:
    case .Fire:
        info.rate,info.lifetime,info.size=48,{0.35,0.8},{0.15,0.45}
        info.colors={{1,0.18,0.02,1},{1,0.72,0.16,0.9}}
        info.blend,info.lit,info.intensity=.Additive,false,3
        info.acceleration,info.noise={0,1.8,0},0.6
    case .Smoke:
        info.rate,info.lifetime,info.size=22,{2,3},{0.25,0.55}
        info.colors={{0.24,0.23,0.22,0.65},{0.45,0.44,0.43,0.35}}
        info.size_over_life.values={0.4,0.7,1.3,2,2,2,2,2}
        info.speed,info.noise,info.sort={0.3,0.7},1.2,true
    case .Sparks:
        info.rate,info.duration,info.bursts[0]=0,0.75,{count=36}
        info.lifetime,info.size,info.speed={0.25,0.7},{0.015,0.035},{3,9}
        info.colors={{1,0.22,0.03,1},{1,0.76,0.28,1}}
        info.blend,info.lit,info.render=.Additive,false,.Velocity
        info.intensity,info.stretch,info.gravity=5,0.035,0.6
    case .Muzzle_Flash:
        info.rate,info.duration,info.bursts[0]=0,0.15,{count=7}
        info.lifetime,info.speed,info.size={0.035,0.09},{3,6},{0.25,0.45}
        info.colors={{1,0.4,0.07,1},{1,0.9,0.55,1}}
        info.blend,info.lit,info.intensity=.Additive,false,8
    case .Blood:
        info.rate,info.duration,info.bursts[0]=0,0.6,{count=28}
        info.lifetime,info.speed,info.size={0.2,0.65},{1,4},{0.025,0.07}
        info.colors={{0.22,0.009,0.012,1},{0.72,0.02,0.025,0.9}}
        info.shape_angle,info.gravity=0.85,1
    case .Debris:
        info.rate,info.duration,info.bursts[0]=0,1,{count=24}
        info.lifetime,info.size,info.speed={0.4,1.1},{0.03,0.1},{1,5}
        info.colors={{0.16,0.12,0.08,1},{0.37,0.31,0.24,1}}
        info.render,info.gravity,info.collision=.Mesh,1,.World
        info.bounce,info.friction,info.spin=0.26,0.42,{-9,9}
    case .Trail:
        info.rate,info.rate_over_distance,info.render=0,60,.Ribbon
        info.lifetime,info.speed,info.size={0.3,0.3},{},{0.12,0.12}
        info.shape,info.lit,info.blend=.Point,false,.Additive
        info.colors={{0.14,0.45,1,0.8},{0.5,0.8,1,1}}
    case .Beam:
        info.rate,info.duration,info.bursts[0]=0,0.5,{count=1}
        info.lifetime,info.size,info.speed={0.5,0.5},{0.08,0.08},{}
        info.shape,info.render,info.local_space=.Point,.Beam,true
        info.beam_end,info.beam_arc={0,0,-2},0.3
        info.blend,info.lit,info.intensity=.Additive,false,4
        info.colors={{0.14,0.45,1,1},{0.5,0.8,1,1}}
    }
    return
}
