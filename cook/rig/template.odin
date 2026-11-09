package rig

// The humanoid template: the human skeleton of Mesh2Motion (CC0,
// github.com/Mesh2Motion/mesh2motion-app, static/assets/human/skeleton.glb),
// in the engine's space. Its bones keep the names of that rig and of the
// Quaternius and Unreal ones, so the clips of its library play on what the
// fit makes and the body is found by its names.
//
// rest is the local transform of a bone in the template and reference its
// place in the reference model of that rig (static/assets/human/model.glb),
// 1.83 m tall. rule says where the fit finds it in another mesh; the numbers
// of the rules are what the fit measures on the reference model, so the
// reference fits to itself.

Along :: enum u8 {Center,Left,Right}

Rule_Kind :: enum u8 {
    // In the section at a height: u across the interval of along in x, w
    // across its depth in z. height is in anchor units (0 floor, 1 crotch, 2
    // neck, 3 top); fixed, when not negative, is the height of the section in
    // fractions of the mesh's height instead.
    Section,
    // On the axis of an arm: height is the fraction of the way from the
    // centre line to the farthest point of the arm, offset the distance from
    // the arm's centre there, in heights of the mesh.
    Arm,
    // The template's offset from anchor, turned from the direction toward
    // the template has to the one it has in the mesh and scaled by their
    // lengths; with toward negative, scaled by the height alone.
    Follow,
}

Rule :: struct {
    kind:Rule_Kind,
    along:Along,
    height,fixed,u,w:f32,
    offset:[3]f32,
    anchor,toward:i32,
}

Template_Bone :: struct {
    name:string,
    parent:i32,
    translation:[3]f32,
    rotation:[4]f32, // x, y, z, w
    reference:[3]f32,
    rule:Rule,
}

// The floor, crotch, neck and top of the reference model, in meters.
REFERENCE_ANCHORS :: [4]f32{-0.000386,0.850076,1.579043,1.829178}

@(rodata)
HUMANOID:=[?]Template_Bone{
    {"root",-1,{0,0,0},{0.707107,0,0,0.707107},{0,0,0},{kind=.Follow,anchor=1,toward=-1}},
    {"pelvis",0,{0,0.0501,-0.9167},{-0.790468,0,0,0.612503},{0,0.9167,0.0501},{kind=.Section,along=.Center,height=1.091396,fixed=-1,u=0.5,w=0.722123}},
    {"spine_01",1,{0,0.103973,0},{0.064703,0,0,0.997905},{0,1.01738,0.02414},{kind=.Section,along=.Center,height=1.229509,fixed=-1,u=0.5,w=0.603184}},
    {"spine_02",2,{0,0.124035,0},{0.07728,-0,0,0.997009},{0,1.14048,0.00894},{kind=.Section,along=.Center,height=1.398378,fixed=-1,u=0.5,w=0.622393}},
    {"spine_03",3,{0,0.141272,0},{0.093324,-0,0,0.995636},{0,1.281681,0.01344},{kind=.Section,along=.Center,height=1.592077,fixed=-1,u=0.5,w=0.538468}},
    {"neck_01",4,{0,0.174801,0},{-0.349636,0,0,0.936885},{0,1.452315,0.051379},{kind=.Section,along=.Center,height=1.826154,fixed=-1,u=0.5,w=0.564476}},
    {"head",5,{0,0.132064,0},{0.203031,0,0,0.979172},{0,1.568491,-0.011424},{kind=.Section,along=.Center,height=1.985524,fixed=-1,u=0.5,w=0.399028}},
    {"head_leaf",6,{0,0.06981,0},{0.04707,0,0,0.998892},{0,1.638038,-0.017468},{kind=.Section,along=.Center,height=2.235854,fixed=-1,u=0.5,w=0.4707}},
    {"clavicle_l",4,{-0.0188,0.123129,-0.105539},{0.530812,-0.288154,0.314649,0.732259},{-0.0188,1.424781,-0.06286},{kind=.Follow,anchor=4,toward=9}},
    {"upperarm_l",8,{0,0.202085,0},{-0.192103,0.660515,0.267884,0.674577},{-0.173742,1.445681,0.065181},{kind=.Arm,along=.Left,height=0.179659,offset={-0.000086,0.014781,0.010268}}},
    {"lowerarm_l",9,{0,0.296595,0},{-0.021641,0.000287,0.006738,0.999743},{-0.470229,1.444103,0.073036},{kind=.Arm,along=.Left,height=0.486159,offset={0.000012,0.00697,0.0006}}},
    {"hand_l",10,{0,0.279788,0},{0.0084,-0.00006,-0.009398,0.999921},{-0.749928,1.438845,0.068336},{kind=.Arm,along=.Left,height=0.775449,offset={-0.000107,0.007592,0.010396}}},
    {"index_01_l",11,{-0.003784,0.101535,-0.04949},{-0.061252,0.704452,-0.061252,0.704446},{-0.851463,1.435061,0.018846},{kind=.Follow,anchor=11,toward=10}},
    {"index_02_l",12,{0,0.038845,0},{0,-0,-0.010773,0.999942},{-0.889725,1.435061,0.012142},{kind=.Follow,anchor=11,toward=10}},
    {"index_03_l",13,{0,0.029881,0},{0,-0,-0.010879,0.999941},{-0.91904,1.435062,0.006351},{kind=.Follow,anchor=11,toward=10}},
    {"index_04_leaf_l",14,{0,0.024088,0},{-0.000001,0,0.108173,0.994132},{-0.942564,1.435062,0.001171},{kind=.Follow,anchor=11,toward=10}},
    {"middle_01_l",11,{-0.001383,0.106587,-0.02318},{-0.018655,0.706863,-0.018655,0.706858},{-0.856515,1.437461,0.045156},{kind=.Follow,anchor=11,toward=10}},
    {"middle_02_l",16,{0,0.042969,0},{0,-0,-0.002188,0.999998},{-0.899425,1.437462,0.042889},{kind=.Follow,anchor=11,toward=10}},
    {"middle_03_l",17,{0,0.032429,0},{0,-0,-0.024181,0.999708},{-0.931802,1.437462,0.041037},{kind=.Follow,anchor=11,toward=10}},
    {"middle_04_leaf_l",18,{0,0.031328,0},{0,0,0.052732,0.998609},{-0.962955,1.437462,0.037737},{kind=.Follow,anchor=11,toward=10}},
    {"pinky_01_l",11,{-0.003383,0.099544,0.031657},{0.027719,0.706566,0.027719,0.70656},{-0.849472,1.435462,0.099993},{kind=.Follow,anchor=11,toward=10}},
    {"pinky_02_l",20,{0,0.034465,0},{0,-0,0.013902,0.999903},{-0.883831,1.435462,0.102693},{kind=.Follow,anchor=11,toward=10}},
    {"pinky_03_l",21,{0,0.027501,0},{0,-0,-0.012939,0.999916},{-0.911177,1.435461,0.105609},{kind=.Follow,anchor=11,toward=10}},
    {"pinky_04_leaf_l",22,{0,0.026418,0},{0,-0,-0.040163,0.999193},{-0.93751,1.435462,0.10773},{kind=.Follow,anchor=11,toward=10}},
    {"ring_01_l",11,{-0.001683,0.104392,0.006434},{0.012589,0.706997,0.012589,0.706992},{-0.85432,1.437161,0.07477},{kind=.Follow,anchor=11,toward=10}},
    {"ring_02_l",24,{0,0.039325,0},{0,-0,-0.019747,0.999805},{-0.89362,1.437161,0.07617},{kind=.Follow,anchor=11,toward=10}},
    {"ring_03_l",25,{0,0.030596,0},{0,-0,-0.004022,0.999992},{-0.924216,1.437161,0.076051},{kind=.Follow,anchor=11,toward=10}},
    {"ring_04_leaf_l",26,{0,0.029986,0},{0,0,0.005967,0.999982},{-0.954199,1.437161,0.075693},{kind=.Follow,anchor=11,toward=10}},
    {"thumb_01_l",11,{-0.0228,0.020291,-0.039695},{-0.249777,0.917359,-0.300277,0.076796},{-0.770219,1.416045,0.028641},{kind=.Follow,anchor=11,toward=10}},
    {"thumb_02_l",28,{0,0.046585,0},{-0.082695,-0.004105,-0.008713,0.996528},{-0.80259,1.396845,0.001189},{kind=.Follow,anchor=11,toward=10}},
    {"thumb_03_l",29,{0,0.047142,0},{-0.038974,-0.006633,-0.022494,0.998965},{-0.838448,1.37469,-0.019925},{kind=.Follow,anchor=11,toward=10}},
    {"thumb_04_leaf_l",30,{0,0.034847,0},{-0.032898,-0.009022,0.039629,0.998632},{-0.865069,1.35642,-0.033035},{kind=.Follow,anchor=11,toward=10}},
    {"clavicle_r",4,{0.0188,0.123129,-0.105539},{0.530812,0.288154,-0.314649,0.732259},{0.0188,1.424781,-0.06286},{kind=.Follow,anchor=4,toward=33}},
    {"upperarm_r",32,{0,0.202085,0},{-0.192103,-0.660515,-0.267884,0.674577},{0.173742,1.445681,0.065181},{kind=.Arm,along=.Right,height=0.179659,offset={0.000086,0.014781,0.010268}}},
    {"lowerarm_r",33,{0,0.296595,0},{-0.021641,-0.000287,-0.006738,0.999743},{0.470229,1.444103,0.073036},{kind=.Arm,along=.Right,height=0.486159,offset={-0.000012,0.00697,0.0006}}},
    {"hand_r",34,{0,0.279788,0},{0.0084,0.00006,0.009398,0.999921},{0.749928,1.438845,0.068336},{kind=.Arm,along=.Right,height=0.775449,offset={0.000107,0.007592,0.010396}}},
    {"index_01_r",35,{0.003784,0.101535,-0.04949},{-0.061252,-0.704452,0.061252,0.704446},{0.851463,1.435061,0.018846},{kind=.Follow,anchor=35,toward=34}},
    {"index_02_r",36,{0,0.038845,0},{0,-0,0.010773,0.999942},{0.889725,1.435061,0.012141},{kind=.Follow,anchor=35,toward=34}},
    {"index_03_r",37,{0,0.029881,0},{0,-0,0.010879,0.999941},{0.919039,1.435061,0.006351},{kind=.Follow,anchor=35,toward=34}},
    {"index_04_leaf_r",38,{0,0.024088,0},{-0.000001,0,-0.108173,0.994132},{0.942564,1.435061,0.00117},{kind=.Follow,anchor=35,toward=34}},
    {"middle_01_r",35,{0.001383,0.106587,-0.02318},{-0.018655,-0.706863,0.018655,0.706858},{0.856515,1.437461,0.045155},{kind=.Follow,anchor=35,toward=34}},
    {"middle_02_r",40,{0,0.042969,0},{0,-0,0.002188,0.999998},{0.899425,1.437461,0.042889},{kind=.Follow,anchor=35,toward=34}},
    {"middle_03_r",41,{0,0.032429,0},{0,-0,0.024181,0.999708},{0.931801,1.437461,0.041037},{kind=.Follow,anchor=35,toward=34}},
    {"middle_04_leaf_r",42,{0,0.031328,0},{0,0,-0.052732,0.998609},{0.962955,1.437461,0.037737},{kind=.Follow,anchor=35,toward=34}},
    {"pinky_01_r",35,{0.003383,0.099544,0.031657},{0.027719,-0.706566,-0.027719,0.70656},{0.849472,1.435461,0.099993},{kind=.Follow,anchor=35,toward=34}},
    {"pinky_02_r",44,{0,0.034465,0},{0,0,-0.013902,0.999903},{0.883831,1.435461,0.102693},{kind=.Follow,anchor=35,toward=34}},
    {"pinky_03_r",45,{0,0.027501,0},{0,-0,0.012939,0.999916},{0.911177,1.435461,0.105609},{kind=.Follow,anchor=35,toward=34}},
    {"pinky_04_leaf_r",46,{0,0.026418,0},{0,-0,0.040163,0.999193},{0.93751,1.435461,0.107729},{kind=.Follow,anchor=35,toward=34}},
    {"ring_01_r",35,{0.001684,0.104392,0.006434},{0.012589,-0.706997,-0.012589,0.706992},{0.85432,1.437161,0.074769},{kind=.Follow,anchor=35,toward=34}},
    {"ring_02_r",48,{0,0.039325,0},{0,0,0.019747,0.999805},{0.89362,1.437161,0.076169},{kind=.Follow,anchor=35,toward=34}},
    {"ring_03_r",49,{0,0.030596,0},{0,-0,0.004022,0.999992},{0.924215,1.437161,0.07605},{kind=.Follow,anchor=35,toward=34}},
    {"ring_04_leaf_r",50,{0,0.029986,0},{0,0,-0.005967,0.999982},{0.954199,1.437161,0.075693},{kind=.Follow,anchor=35,toward=34}},
    {"thumb_01_r",35,{0.0228,0.020291,-0.039695},{-0.249777,-0.917359,0.300277,0.076796},{0.770219,1.416045,0.028641},{kind=.Follow,anchor=35,toward=34}},
    {"thumb_02_r",52,{0,0.046585,0},{-0.082695,0.004105,0.008713,0.996528},{0.80259,1.396845,0.001189},{kind=.Follow,anchor=35,toward=34}},
    {"thumb_03_r",53,{0,0.047142,0},{-0.038974,0.006633,0.022494,0.998965},{0.838448,1.37469,-0.019926},{kind=.Follow,anchor=35,toward=34}},
    {"thumb_04_leaf_r",54,{0,0.034847,0},{-0.032898,0.009022,-0.039629,0.998632},{0.865068,1.35642,-0.033036},{kind=.Follow,anchor=35,toward=34}},
    {"thigh_l",1,{-0.089,0.027771,-0.046024},{-0.989046,0,0,0.147611},{-0.089,0.9321,-0.0014},{kind=.Section,along=.Left,height=1.112521,fixed=-1,u=0.534053,w=0.538427}},
    {"calf_l",56,{0,0.406626,0},{-0.100033,-0.000131,0.000013,0.994984},{-0.089,0.525867,-0.019267},{kind=.Section,along=.Left,height=0.618785,fixed=-1,u=0.544154,w=0.41647}},
    {"foot_l",57,{0,0.433194,0},{0.586511,0.000526,0.000227,0.809941},{-0.089,0.097964,0.048229},{kind=.Section,along=.Left,height=0.115643,fixed=0.03,u=0.509663,w=0.788119}},
    {"ball_l",58,{0,0.181408,0},{-0.000111,0.976743,0.214414,0.000506},{-0.089,0.0152,-0.113199},{kind=.Section,along=.Left,height=0.018326,fixed=0.03,u=0.509663,w=0.046571}},
    {"ball_leaf_l",59,{0,0.086288,0},{-0.027501,-0,0,0.999622},{-0.089,0.011614,-0.199412},{kind=.Section,along=.Left,height=0.01411,fixed=0.03,u=0.509663,w=-0.349464}},
    {"thigh_r",1,{0.089,0.027771,-0.046024},{-0.989046,-0,0,0.147611},{0.089,0.9321,-0.0014},{kind=.Section,along=.Right,height=1.112521,fixed=-1,u=0.465947,w=0.538427}},
    {"calf_r",61,{0,0.406626,0},{-0.100033,0.000131,-0.000013,0.994984},{0.089,0.525867,-0.019267},{kind=.Section,along=.Right,height=0.618785,fixed=-1,u=0.455845,w=0.41647}},
    {"foot_r",62,{0,0.433194,0},{0.586511,-0.000526,-0.000227,0.809941},{0.089,0.097964,0.048229},{kind=.Section,along=.Right,height=0.115643,fixed=0.03,u=0.490337,w=0.788119}},
    {"ball_r",63,{0,0.181408,0},{-0.000111,-0.976743,-0.214414,0.000506},{0.089,0.0152,-0.113199},{kind=.Section,along=.Right,height=0.018326,fixed=0.03,u=0.490337,w=0.046571}},
    {"ball_leaf_r",64,{0,0.086288,0},{-0.027501,0,0,0.999622},{0.089,0.011614,-0.199412},{kind=.Section,along=.Right,height=0.01411,fixed=0.03,u=0.490337,w=-0.349464}},
}
