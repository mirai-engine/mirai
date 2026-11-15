package geom

import "base:runtime"

// The exact Euclidean distance transform of a grid (Felzenszwalb and
// Huttenlocher, Distance transforms of sampled functions, 2012): a pass
// along each row finds the nearest covered cell of the row, and a pass along
// each column takes the lower envelope of the parabolas those distances
// raise. Integer squared distances, so the result is the same everywhere.

// For each cell of a grid of width×height (rows one after another), the
// nearest covered cell of its tile by Euclidean distance: nearest[i] is its
// index, max(u32) where the tile covers none, and distance2[i] (optional)
// the square of that distance in cells. Tiles are squares of `tile` cells a
// side from the first cell, 0 for the whole grid. Ties go to a fixed one of
// the cells at the same distance. False, writing nothing, for slices of
// another length or sizes that are not positive.
grid_nearest :: proc(covered:[]bool,width,height,tile:int,nearest:[]u32,distance2:[]u32=nil) -> bool #no_bounds_check {
    if width<=0 || height<=0 || tile<0 || width>int(max(i32)) || height>int(max(i32)) {return false}
    cells:=width*height
    if cells/width!=height || cells>int(max(u32)) || len(covered)!=cells || len(nearest)!=cells || distance2!=nil && len(distance2)!=cells {return false}
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    side:=max(width,height)
    // Of each cell, the nearest covered cell of its row within its tile: its column and the square of the distance.
    across:=make([]i32,cells,context.temp_allocator)
    across2:=make([]i64,cells,context.temp_allocator)
    f:=make([]i64,side,context.temp_allocator)
    d:=make([]i64,side,context.temp_allocator)
    at:=make([]i32,side,context.temp_allocator)
    v:=make([]i32,side,context.temp_allocator)
    z:=make([]f64,side+1,context.temp_allocator)
    if across==nil || across2==nil || f==nil || d==nil || at==nil || v==nil || z==nil {return false}
    span_x:=tile if tile>0 else width
    span_y:=tile if tile>0 else height
    for y in 0..<height {
        for x0:=0;x0<width;x0+=span_x {
            n:=min(span_x,width-x0)
            row:=y*width+x0
            for x in 0..<n {f[x]=0 if covered[row+x] else GRID_FAR}
            grid_envelope(f[:n],d[:n],at[:n],v,z)
            for x in 0..<n {
                across[row+x]=i32(x0)+at[x] if at[x]>=0 else -1
                across2[row+x]=d[x]
            }
        }
    }
    for x in 0..<width {
        for y0:=0;y0<height;y0+=span_y {
            n:=min(span_y,height-y0)
            for y in 0..<n {f[y]=across2[(y0+y)*width+x]}
            grid_envelope(f[:n],d[:n],at[:n],v,z)
            for y in 0..<n {
                cell:=(y0+y)*width+x
                if at[y]<0 {
                    nearest[cell]=max(u32)
                    if distance2!=nil {distance2[cell]=max(u32)}
                    continue
                }
                from:=(y0+int(at[y]))*width+x
                nearest[cell]=u32((y0+int(at[y]))*width+int(across[from]))
                if distance2!=nil {distance2[cell]=u32(min(d[y],i64(max(u32))))}
            }
        }
    }
    return true
}

@(private="file")
GRID_FAR :: i64(1)<<62

// d[q] = min over p of (q-p)²+f[p] and at[q] that p, -1 where every f is GRID_FAR.
@(private="file")
grid_envelope :: proc "contextless" (f,d:[]i64,at:[]i32,v:[]i32,z:[]f64) #no_bounds_check {
    n:=len(f)
    k:=-1
    for q in 0..<n {
        if f[q]>=GRID_FAR {continue}
        fq:=f64(f[q])+f64(q)*f64(q)
        s:f64
        for k>=0 {
            p:=int(v[k])
            s=(fq-(f64(f[p])+f64(p)*f64(p)))/f64(2*(q-p))
            if s>z[k] {break}
            k-=1
        }
        k+=1
        v[k]=i32(q)
        z[k]=s if k>0 else -max(f64)
        z[k+1]=max(f64)
    }
    if k<0 {
        for q in 0..<n {d[q],at[q]=GRID_FAR,-1}
        return
    }
    j:=0
    for q in 0..<n {
        for z[j+1]<f64(q) {j+=1}
        p:=int(v[j])
        d[q]=i64(q-p)*i64(q-p)+f[p]
        at[q]=i32(p)
    }
}
