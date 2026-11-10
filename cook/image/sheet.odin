package image

import "core:math"
import mm "mirai:std/math"

// A contact sheet: evenly spaced frames of a sequence as tiles of a grid, in
// order from the top left, each with a number in its top left corner, to look
// at a whole run in one image.

SHEET_WIDTH :: 1536    // pixels across a sheet at most
SHEET_GAP :: 2         // pixels between two tiles
SHEET_CAPACITY :: 64   // tiles of a sheet at most

Sheet :: struct {
    image:Image,
    columns,rows:int,
    tile:[2]int, // pixels of a tile
    count:int,
}

// A grid of count tiles of frames of width by height, columns across or, with
// 0, as square as the frames let it be.
sheet_make :: proc(count,width,height:int,allocator:=context.allocator,columns:=0) -> (sheet:Sheet,error:Error) {
    if count<1 || count>SHEET_CAPACITY || columns<0 {return {},.Bad_Count}
    if width<=0 || height<=0 {return {},.Empty}
    columns:=min(columns,count) if columns>0 else max(int(math.ceil(math.sqrt(f64(count)))),1)
    rows:=(count+columns-1)/columns
    tile_width:=max(min(width,(SHEET_WIDTH-(columns-1)*SHEET_GAP)/columns),1)
    tile_height:=max((height*tile_width+width/2)/width,1)
    sheet_width,sheet_height:=columns*tile_width+(columns-1)*SHEET_GAP,rows*tile_height+(rows-1)*SHEET_GAP
    pixels,alloc_error:=make([]u8,sheet_width*sheet_height*4,allocator)
    if alloc_error!=nil {return {},.Out_Of_Memory}
    for i in 0..<sheet_width*sheet_height {pixels[i*4+3]=255}
    return {image={pixels=pixels,width=sheet_width,height=sheet_height,allocator=allocator},columns=columns,rows=rows,tile={tile_width,tile_height},count=count},.None
}

sheet_destroy :: proc(sheet:^Sheet) {
    if sheet.image.pixels!=nil {image_destroy(&sheet.image)}
    sheet^={}
}

// The frame of a sequence of total frames that tile k of count shows: evenly
// spaced, the first and the last included. -1 when k is not a tile.
sheet_frame :: proc(k,count,total:int) -> int {
    if k<0 || k>=count || total<=0 {return -1}
    if count==1 || total==1 {return 0}
    return (k*(total-1)*2+(count-1))/((count-1)*2)
}

// The tile of a sheet of count tiles that shows frame of total; -1: none.
sheet_tile :: proc(frame,count,total:int) -> int {
    if frame<0 || frame>=total {return -1}
    for k in 0..<min(count,total) {
        if sheet_frame(k,min(count,total),total)==frame {return k}
    }
    return -1
}

// Puts a frame of RGBA floats in tile k, scaled down by averaging, with label
// in its corner. linear: the floats are linear light, encoded to sRGB and
// clipped at 1; otherwise they are stored values of 0 to 1. Different tiles
// are put from different threads.
sheet_put :: proc(sheet:^Sheet,k:int,pixels:[]f32,width,height:int,linear:bool,label:u64) -> Error {
    if k<0 || k>=sheet.count {return .Bad_Count}
    if width<=0 || height<=0 || len(pixels)!=width*height*4 {return .Empty}
    tw,th:=sheet.tile.x,sheet.tile.y
    left,top:=(k%sheet.columns)*(tw+SHEET_GAP),(k/sheet.columns)*(th+SHEET_GAP)
    stride:=sheet.image.width
    for y in 0..<th {
        y0,y1:=y*height/th,max((y+1)*height/th,y*height/th+1)
        for x in 0..<tw {
            x0,x1:=x*width/tw,max((x+1)*width/tw,x*width/tw+1)
            sum:[3]f32
            for sy in y0..<y1 {
                row:=pixels[(sy*width+x0)*4:][:(x1-x0)*4]
                for sx in 0..<x1-x0 {sum+={row[sx*4],row[sx*4+1],row[sx*4+2]}}
            }
            sum/=f32((y1-y0)*(x1-x0))
            out:=sheet.image.pixels[((top+y)*stride+left+x)*4:][:4]
            for c in 0..<3 {
                v:=sum[c]
                if !(v>0) {v=0}
                if linear {v=mm.linear_to_srgb(min(v,1))}
                out[c]=u8(clamp(v,0,1)*255+0.5)
            }
            out[3]=255
        }
    }
    sheet_label(sheet,left,top,label)
    return .None
}

// Puts a region of an RGBA8 image in tile k, scaled to it by averaging, with
// label in its corner. What of the region falls outside the image is black.
sheet_put_region :: proc(sheet:^Sheet,k:int,image:Image,region:Region,label:u64) -> Error {
    if k<0 || k>=sheet.count {return .Bad_Count}
    if region.w<=0 || region.h<=0 || image.width<=0 || image.height<=0 || len(image.pixels)<image.width*image.height*4 {return .Empty}
    if region.w>ZOOM_MAX_SIDE || region.h>ZOOM_MAX_SIDE || abs(region.x)>ZOOM_MAX_SIDE || abs(region.y)>ZOOM_MAX_SIDE {return .Bad_Region}
    tw,th:=sheet.tile.x,sheet.tile.y
    left,top:=(k%sheet.columns)*(tw+SHEET_GAP),(k/sheet.columns)*(th+SHEET_GAP)
    stride:=sheet.image.width
    for y in 0..<th {
        y0,y1:=region.y+y*region.h/th,region.y+max((y+1)*region.h/th,y*region.h/th+1)
        for x in 0..<tw {
            x0,x1:=region.x+x*region.w/tw,region.x+max((x+1)*region.w/tw,x*region.w/tw+1)
            sum:[3]int
            for sy in max(y0,0)..<min(y1,image.height) {
                for sx in max(x0,0)..<min(x1,image.width) {
                    pixel:=image.pixels[(sy*image.width+sx)*4:][:3]
                    sum+={int(pixel[0]),int(pixel[1]),int(pixel[2])}
                }
            }
            area:=(y1-y0)*(x1-x0)
            out:=sheet.image.pixels[((top+y)*stride+left+x)*4:][:4]
            for c in 0..<3 {out[c]=u8((sum[c]+area/2)/area)}
            out[3]=255
        }
    }
    sheet_label(sheet,left,top,label)
    return .None
}

// Digits of 3 by 5 cells, a row of 3 bits each from the left.
@(private="file")
DIGITS :: [10][5]u8{
    {7,5,5,5,7},{2,6,2,2,7},{7,1,7,4,7},{7,1,7,1,7},{5,5,7,1,1},
    {7,4,7,1,7},{7,4,7,5,7},{7,1,1,1,1},{7,5,7,5,7},{7,5,7,1,7},
}

// The number in white on black at the top left corner of a tile, as many of
// its last digits as fit across it.
@(private="file")
sheet_label :: proc(sheet:^Sheet,left,top:int,label:u64) {
    digits:[20]u8
    n:=0
    for value:=label;;value/=10 {
        digits[n]=u8(value%10)
        n+=1
        if value<10 {break}
    }
    tw,th:=sheet.tile.x,sheet.tile.y
    cell:=max(th/64,1)
    fit:=(tw/cell-1)/4
    if fit<1 || th<cell*7 {return}
    n=min(n,fit)
    box_w,box_h:=(n*4+1)*cell,7*cell
    font:=DIGITS
    stride:=sheet.image.width
    for y in 0..<box_h {
        for x in 0..<box_w {
            cx,cy:=x/cell-1,y/cell-1
            lit:=false
            if cy>=0 && cy<5 && cx>=0 && cx%4<3 {
                d:=digits[n-1-cx/4]
                lit=font[d][cy]&(4>>u8(cx%4))!=0
            }
            out:=sheet.image.pixels[((top+y)*stride+left+x)*4:][:4]
            v:=u8(lit?255:0)
            out[0],out[1],out[2],out[3]=v,v,v,255
        }
    }
}
