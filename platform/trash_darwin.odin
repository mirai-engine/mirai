#+build darwin
package platform

import NS "core:sys/darwin/Foundation"

// Moves a file or folder to the trash of the system, where the user can bring
// it back. path is absolute.
trash :: proc(path:string) -> bool {
    if path=="" {return false}
    NS.scoped_autoreleasepool()
    text:=NS.String.alloc()->initWithOdinString(path)
    defer text->release()
    url:=NS.URL.alloc()->initFileURLWithPath(text)
    defer url->release()
    ok,_:=NS.FileManager.defaultManager()->trashItemAtURL(url,nil)
    return ok
}
