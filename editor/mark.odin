package editor

import "core:math"
import "mirai:ui"

MARK_ARM :: ui.Color{119,66,255,255}
MARK_STAR :: ui.Color{255,255,255,255}
MARK_TILE :: ui.Color{0,0,0,255} // behind the mark in the icon of the window, as in its artwork
MARK_ICON_SCALE :: f32(0.84)     // of the mark on its tile
MARK_ICON_SIZE :: 128            // pixels of a side of the icon of the window

// The mark as MARK_ICON_SIZE squared RGBA pixels, four by four samples a
// pixel, on a dark tile with round corners so the white star reads on light
// taskbars as well: what the window shows as its icon.
mark_icon_pixels :: proc(allocator:=context.allocator) -> []u8 {
    SAMPLES :: 4
    SIDE :: MARK_ICON_SIZE*SAMPLES
    RADIUS :: f32(SIDE)*0.22
    Layer :: enum u8 {None,Tile,Arm,Star}
    layers,error:=make([]Layer,SIDE*SIDE,context.temp_allocator)
    if error!=nil {return nil}
    for y in 0..<SIDE {
        for x in 0..<SIDE {
            q:=[2]f32{f32(x)+0.5,f32(y)+0.5}
            corner:=[2]f32{clamp(q.x,RADIUS,SIDE-RADIUS),clamp(q.y,RADIUS,SIDE-RADIUS)}
            d:=q-corner
            if d.x*d.x+d.y*d.y<=RADIUS*RADIUS {layers[y*SIDE+x]=.Tile}
        }
    }
    points:=MARK_SHAPE_POINTS
    triangles:=MARK_SHAPE_TRIANGLES
    for i:=0;i+2<len(triangles);i+=3 {
        p:[3][2]f32
        for k in 0..<3 {p[k]=SIDE*0.5+points[triangles[i+k]]*(SIDE/16*MARK_ICON_SCALE)}
        layer:=Layer.Star if mark_shape_star(triangles[i]) else .Arm
        x0:=max(int(min(p[0].x,p[1].x,p[2].x)),0)
        y0:=max(int(min(p[0].y,p[1].y,p[2].y)),0)
        x1:=min(int(max(p[0].x,p[1].x,p[2].x))+1,SIDE)
        y1:=min(int(max(p[0].y,p[1].y,p[2].y))+1,SIDE)
        for y in y0..<y1 {
            for x in x0..<x1 {
                if mark_inside(p,{f32(x)+0.5,f32(y)+0.5}) {layers[y*SIDE+x]=layer}
            }
        }
    }
    pixels:=make([]u8,MARK_ICON_SIZE*MARK_ICON_SIZE*4,allocator)
    for py in 0..<MARK_ICON_SIZE {
        for px in 0..<MARK_ICON_SIZE {
            sum:[4]f32
            for sy in 0..<SAMPLES {
                for sx in 0..<SAMPLES {
                    color:ui.Color
                    switch layers[(py*SAMPLES+sy)*SIDE+px*SAMPLES+sx] {
                    case .None:
                    case .Tile: color=MARK_TILE
                    case .Arm: color=MARK_ARM
                    case .Star: color=MARK_STAR
                    }
                    a:=f32(color[3])
                    sum+={f32(color[0])*a,f32(color[1])*a,f32(color[2])*a,a}
                }
            }
            p:=pixels[(py*MARK_ICON_SIZE+px)*4:]
            if sum[3]>0 {for i in 0..<3 {p[i]=u8(math.round(sum[i]/sum[3]))}}
            p[3]=u8(math.round(sum[3]/(SAMPLES*SAMPLES)))
        }
    }
    return pixels
}

@(private="file")
mark_inside :: proc(p:[3][2]f32,q:[2]f32) -> bool {
    edge :: proc(a,b,q:[2]f32) -> f32 {return (b.x-a.x)*(q.y-a.y)-(b.y-a.y)*(q.x-a.x)}
    e0,e1,e2:=edge(p[0],p[1],q),edge(p[1],p[2],q),edge(p[2],p[0],q)
    return (e0>=0 && e1>=0 && e2>=0) || (e0<=0 && e1<=0 && e2<=0)
}

WORDMARK_SIZE :: [2]f32{223.4,40} // units of the grid of the name

// The name MIRAI in the lettering of the mark, as high as rect and from its
// left edge: its triangles, and its outlines as hairlines to smooth its edges.
wordmark_draw :: proc(ctx:^ui.Context,rect:ui.Rect,color:ui.Color) {
    u:=min(rect.w/WORDMARK_SIZE.x,rect.h/WORDMARK_SIZE.y)
    o:=[2]f32{rect.x,rect.y+(rect.h-WORDMARK_SIZE.y*u)*0.5}
    points:=WORDMARK_POINTS
    triangles:=WORDMARK_TRIANGLES
    for i:=0;i+2<len(triangles);i+=3 {
        ui.draw_triangle(ctx,o+points[triangles[i]]*u,o+points[triangles[i+1]]*u,o+points[triangles[i+2]]*u,color)
    }
    for outline in WORDMARK_OUTLINES {
        first,count:=int(outline[0]),int(outline[1])
        for k in 0..<count {ui.draw_line(ctx,o+points[first+k]*u,o+points[first+(k+1)%count]*u,1,color)}
    }
}

// The points of the name on its grid, the triangles that fill it and the
// closed outlines of its parts, traced from its artwork.
WORDMARK_POINTS :: [97][2]f32{
    {0.152,1.666},{0.000,39.724},{7.504,33.734},{7.656,14.024},{26.836,28.958},{46.016,14.024},{46.016,33.584},{52.990,39.800},
    {52.840,1.970},{48.516,1.742},{26.912,18.954},{4.928,1.818},{74.838,1.732},{74.904,39.378},{66.398,39.378},{66.278,4.752},
    {66.365,4.178},{66.504,3.647},{66.701,3.164},{66.960,2.736},{67.287,2.368},{67.688,2.065},{68.167,1.832},{68.730,1.676},
    {88.852,1.168},{131.076,1.472},{132.905,1.916},{134.560,2.545},{136.019,3.387},{137.255,4.468},{138.244,5.814},{138.962,7.452},
    {139.385,9.408},{139.488,11.708},{139.111,13.794},{138.465,15.611},{137.564,17.173},{136.420,18.492},{135.049,19.584},{133.465,20.463},
    {131.681,21.142},{129.712,21.636},{121.678,21.864},{142.146,39.378},{129.712,39.530},{110.152,21.940},{98.326,22.016},{97.946,32.858},
    {89.078,39.756},{89.078,14.814},{127.894,14.738},{128.497,14.574},{129.061,14.346},{129.586,14.054},{130.073,13.696},{130.522,13.271},
    {130.933,12.780},{131.307,12.221},{131.644,11.594},{131.373,10.548},{131.038,9.665},{130.642,8.937},{130.188,8.351},{129.676,7.899},
    {129.109,7.568},{128.489,7.350},{127.818,7.234},{94.462,7.158},{167.764,29.958},{172.070,24.564},{188.978,24.624},{193.280,30.142},
    {178.564,0.000},{209.306,39.118},{200.092,39.302},{178.682,11.828},{156.970,39.000},{147.756,39.118},{223.412,1.676},{217.784,1.732},
    {217.407,1.848},{217.048,1.988},{216.712,2.157},{216.402,2.356},{216.123,2.590},{215.878,2.860},{215.671,3.171},{215.506,3.526},
    {215.301,8.012},{215.198,12.532},{215.177,17.079},{215.220,21.648},{215.308,26.230},{215.421,30.821},{215.542,35.413},{215.652,40.000},
    {223.314,33.368},
}
WORDMARK_TRIANGLES :: [255]u16{
    11,0,1,11,1,2,11,2,3,11,3,4,5,6,7,5,7,8,4,5,8,4,8,9,
    4,9,10,4,10,11,23,12,13,23,13,14,23,14,15,23,15,16,23,16,17,23,17,18,
    23,18,19,23,19,20,23,20,21,21,22,23,67,24,25,67,25,26,67,26,27,67,27,28,
    67,28,29,67,29,30,30,31,32,30,32,33,30,33,34,30,34,35,30,35,36,30,36,37,
    30,37,38,30,38,39,30,39,40,30,40,41,30,41,42,42,43,44,42,44,45,42,45,46,
    46,47,48,46,48,49,42,46,49,42,49,50,42,50,51,42,51,52,42,52,53,42,53,54,
    42,54,55,30,42,55,30,55,56,30,56,57,30,57,58,30,58,59,30,59,60,30,60,61,
    30,61,62,30,62,63,30,63,64,30,64,65,30,65,66,30,66,67,71,68,69,69,70,71,
    72,73,74,72,74,75,77,72,75,75,76,77,96,78,79,96,79,80,96,80,81,96,81,82,
    96,82,83,96,83,84,96,84,85,96,85,86,96,86,87,96,87,88,96,88,89,96,89,90,
    96,90,91,96,91,92,96,92,93,96,93,94,94,95,96,
}
WORDMARK_OUTLINES :: [6][2]u16{{0,12},{12,12},{24,44},{68,4},{72,6},{78,19}}
