package common

// The sorts and heaps of the encoders, with the exact order of comparisons and swaps of
// the original so that elements that compare equal end up in the same places.

// Introspective quicksort (median of three, falls back to heapsort when it goes deep).
stdsort :: proc(a:[]$T,$less:proc(x,y:T)->bool) {
    length:=uint(len(a))
    if length<=1 {return}
    Stack :: struct {left,right:int,len:uint}
    stack:[64]Stack
    sp:=64
    levs:=length
    for {
        sp-=1
        levs=(levs>>1)+(levs>>2)
        if levs==0 || sp<=1 {break}
    }
    stack[sp-1].len=0
    left:=0
    right:=int(length)-1
    swap2 :: #force_inline proc(a:[]$T,i,j:int) {a[i],a[j]=a[j],a[i]}
    // i,j,k = k,i,j
    swap3 :: #force_inline proc(a:[]$T,i,j,k:int) {
        a[i],a[j]=a[j],a[i]
        a[i],a[k]=a[k],a[i]
    }
    for length!=0 {
        for length>1 {
            if length==2 {
                if less(a[right],a[left]) {swap2(a,left,right)}
                break
            }
            mid:=left+int(length>>1)
            if less(a[mid],a[left]) {
                if less(a[mid],a[right]) {
                    if less(a[left],a[right]) {swap2(a,left,mid)} else {swap3(a,mid,left,right)}
                } else {
                    swap2(a,left,right)
                }
            } else if less(a[right],a[mid]) {
                if less(a[left],a[right]) {swap2(a,mid,right)} else {swap3(a,left,mid,right)}
            }
            if length<=4 {
                if length==3 {break}
                piv:=left+1
                if less(a[mid],a[piv]) {
                    if less(a[piv],a[right]) {swap2(a,piv,mid)} else {swap3(a,mid,piv,right)}
                } else if less(a[piv],a[left]) {
                    swap2(a,left,piv)
                }
                break
            }
            if sp==64 {
                // heapsort of [left,right]
                s:=length>>1
                i:=left+int(s)
                ind:int
                k:uint
                build: for {
                    s-=1
                    i-=1
                    ind=i
                    k=(s<<1)+1
                    for {
                        for {
                            v:=left+int(k)
                            n:=v+1
                            if n<=right && less(a[v],a[n]) {k+=1; v=n}
                            if less(a[ind],a[v]) {
                                swap2(a,ind,v)
                                ind=v
                                k=(k<<1)+1
                                if k<length {continue}
                            }
                            break
                        }
                        if s!=0 {continue build}
                        length-=1
                        swap2(a,left,right)
                        right-=1
                        ind=left
                        k=1
                        if length>1 {continue}
                        break build
                    }
                }
            } else {
                piv:=left
                l:=left
                r:=right
                swap2(a,mid,piv)
                for {
                    for {
                        r-=1
                        if !less(a[piv],a[r]) {break}
                    }
                    if !(l<r) {break}
                    for {
                        l+=1
                        if !less(a[l],a[piv]) {break}
                    }
                    if !(l<r) {
                        l-=1
                        break
                    }
                    swap2(a,l,r)
                }
                swap2(a,piv,l)
                piv=l
                rpiv:=piv
                for {
                    rpiv+=1
                    if !(rpiv<right && !less(a[piv],a[rpiv])) {break}
                }
                lpiv:=piv
                for {
                    lpiv-=1
                    if !(left<lpiv) || less(a[lpiv],a[piv]) {break}
                }
                length=uint(right-rpiv+1)
                ll:=uint(lpiv-left+1)
                if length<ll {
                    stack[sp]={rpiv,right,length}
                    sp+=1
                    right=lpiv
                    length=ll
                } else {
                    stack[sp]={left,lpiv,ll}
                    sp+=1
                    left=rpiv
                }
            }
        }
        sp-=1
        left=stack[sp].left
        right=stack[sp].right
        length=stack[sp].len
    }
}

// Heaps where compare is "less": the largest element is on top.

heap_promote :: proc(a:[]$T,cur:int,$compare:proc(x,y:T)->bool) #no_bounds_check {
    i:=cur
    for i>0 {
        parent:=(i-1)>>1
        if !compare(a[parent],a[i]) {return}
        a[parent],a[i]=a[i],a[parent]
        i=parent
    }
}

// Removes the top; the heap is then a[:len(a)-1].
heap_popped :: proc(a:[]$T,$compare:proc(x,y:T)->bool) #no_bounds_check {
    n:=len(a)
    if n==0 {return}
    i:=0
    for {
        child:=i*2+1
        if child>=n {break}
        if child+1<n && compare(a[child],a[child+1]) {child+=1}
        a[i]=a[child]
        i=child
    }
    n-=1
    if i<n {
        a[i]=a[n]
        heap_promote(a,i,compare)
    }
}

// Moves the top to the end.
heap_pop :: proc(a:[]$T,$compare:proc(x,y:T)->bool) {
    if len(a)==0 {return}
    temp:=a[0]
    heap_popped(a,compare)
    a[len(a)-1]=temp
}

// a[len(a)-1] was just appended.
heap_push :: proc(a:[]$T,$compare:proc(x,y:T)->bool) {
    if len(a)==0 {return}
    heap_promote(a,len(a)-1,compare)
}

heap_adjust :: proc(a:[]$T,start,n:int,$compare:proc(x,y:T)->bool) #no_bounds_check {
    i:=start
    for {
        child:=i*2+1
        if child>=n {break}
        if child+1<n {child+=compare(a[child],a[child+1])?1:0}
        if compare(a[child],a[i]) {break}
        a[i],a[child]=a[child],a[i]
        i=child
    }
}

heap_make :: proc(a:[]$T,$compare:proc(x,y:T)->bool) {
    n:=len(a)
    cur:=n>>1
    for cur>0 {
        cur-=1
        heap_adjust(a,cur,n,compare)
    }
}

// The first i with !less(values[i],x), or len(values).
lower_bound :: proc(values:[]$T,x:$U,$less:proc(v:T,x:U)->bool) -> int {
    first:=0
    count:=len(values)
    for count>0 {
        step:=count/2
        it:=first+step
        if less(values[it],x) {
            first=it+1
            count-=step+1
        } else {
            count=step
        }
    }
    return first
}
