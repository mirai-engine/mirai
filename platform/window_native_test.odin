#+build windows
package platform

import "core:os"
import "core:testing"
import win32 "core:sys/windows"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

// Creating a Vulkan surface needs an instance, and an instance loads a
// driver. The check only runs when asked for, and only with VK_DRIVER_FILES
// naming the driver to load: a software one (lavapipe) leaves the GPU alone.
PLATFORM_TEST_VULKAN :: #config(PLATFORM_TEST_VULKAN,false)

@(private="file")
vulkan_surface_is_created_for_the_window :: proc(t:^testing.T,p:^Platform) {
    driver,chosen:=os.lookup_env("VK_DRIVER_FILES",context.temp_allocator)
    testing.expect(t,chosen && driver!="","VK_DRIVER_FILES must name the Vulkan driver this check may load")
    if !chosen || driver=="" {return}
    get:=cast(vk.ProcGetInstanceProcAddr)sdl.Vulkan_GetVkGetInstanceProcAddr()
    testing.expect(t,get!=nil)
    if get==nil {return}
    create:=cast(vk.ProcCreateInstance)get(nil,"vkCreateInstance")
    extensions:=vulkan_instance_extensions(p)
    application:=vk.ApplicationInfo{sType=.APPLICATION_INFO,pApplicationName="mirai platform test",apiVersion=vk.API_VERSION_1_1}
    info:=vk.InstanceCreateInfo{
        sType=.INSTANCE_CREATE_INFO,pApplicationInfo=&application,
        enabledExtensionCount=u32(len(extensions)),ppEnabledExtensionNames=raw_data(extensions),
    }
    instance:vk.Instance
    testing.expect_value(t,create(&info,nil,&instance),vk.Result.SUCCESS)
    if instance==nil {return}
    destroy_instance:=cast(vk.ProcDestroyInstance)get(instance,"vkDestroyInstance")
    destroy_surface:=cast(vk.ProcDestroySurfaceKHR)get(instance,"vkDestroySurfaceKHR")
    defer destroy_instance(instance,nil)
    source:=surface_source(p)
    surface,ok:=source.vulkan_create(rawptr(instance),source.vulkan_user)
    testing.expect(t,ok && surface!=0)
    if ok {destroy_surface(instance,vk.SurfaceKHR(surface),nil)}
    // Without a Platform there is no window to make a surface for.
    _,ok=vulkan_surface_create(rawptr(instance),nil)
    testing.expect(t,!ok)
}

// A real window of the system that is never shown: it takes no focus and no
// input. Windows asks a window what a point of it is with WM_NCHITTEST; the
// answer comes from the regions through SDL, as it will for a pointer.
native_hidden_window_checks :: proc(t:^testing.T) {
    p,error:=create({window={title="Mirai hidden test",size={800,600},chrome=.Custom,hidden=true},pacing=Frame_Pacing{}})
    testing.expect_value(t,error,Error.None)
    if p==nil {return}
    defer destroy(p)
    testing.expect_value(t,string(sdl.GetCurrentVideoDriver()),"windows")
    frame_begin(p)
    f:=input_frame(p)
    testing.expect(t,!f.window.visible && !f.window.focused && !f.window.minimized)
    testing.expect(t,f.window.size.x>0 && f.window.size.y>0 && f.window.density>0)
    testing.expect_value(t,f.window.pixel_size,[2]i32{i32(f32(f.window.size.x)*f.window.density+0.5),i32(f32(f.window.size.y)*f.window.density+0.5)})
    hwnd:=win32.HWND(sdl.GetPointerProperty(sdl.GetWindowProperties(p.window.handle),sdl.PROP_WINDOW_WIN32_HWND_POINTER,nil))
    testing.expect(t,hwnd!=nil)
    if hwnd==nil {return}
    testing.expect(t,!win32.IsWindowVisible(hwnd))
    testing.expect(t,sdl.GetWindowFlags(p.window.handle)&{.BORDERLESS,.RESIZABLE,.HIDDEN,.VULKAN}=={.BORDERLESS,.RESIZABLE,.HIDDEN,.VULKAN})

    // What the GPU backend needs: the extensions come from the Vulkan loader, no device is touched.
    extensions:=vulkan_instance_extensions(p)
    has_surface,has_win32:=false,false
    for name in extensions {
        if name=="VK_KHR_surface" {has_surface=true}
        if name=="VK_KHR_win32_surface" {has_win32=true}
    }
    testing.expect(t,has_surface && has_win32)
    source:=surface_source(p)
    testing.expect(t,source.vulkan_create!=nil && source.vulkan_user==rawptr(p) && source.metal_layer==nil)
    testing.expect(t,i32(source.width)==f.window.pixel_size.x && i32(source.height)==f.window.pixel_size.y)
    testing.expect(t,window_refresh_rate(p)>0)
    when PLATFORM_TEST_VULKAN {vulkan_surface_is_created_for_the_window(t,p)}

    hit :: proc(hwnd:win32.HWND,x,y:i32) -> int {
        point:=win32.POINT{x,y}
        win32.ClientToScreen(hwnd,&point)
        return int(win32.SendMessageW(hwnd,win32.WM_NCHITTEST,0,win32.MAKELPARAM(point.x,point.y)))
    }
    width,height:=f.window.pixel_size.x,f.window.pixel_size.y
    scale:=f.window.density
    at :: proc(points,scale:f32) -> i32 {return i32(points*scale)}
    // Without regions only the edges do something.
    testing.expect_value(t,hit(hwnd,width/2,at(20,scale)),win32.HTCLIENT)
    testing.expect_value(t,hit(hwnd,width/2,at(3,scale)),win32.HTTOP)
    testing.expect_value(t,hit(hwnd,at(3,scale),at(3,scale)),win32.HTTOPLEFT)
    testing.expect_value(t,hit(hwnd,width-1,height-1),win32.HTBOTTOMRIGHT)
    testing.expect_value(t,hit(hwnd,at(3,scale),height/2),win32.HTLEFT)
    testing.expect_value(t,hit(hwnd,width-1,height/2),win32.HTRIGHT)
    testing.expect_value(t,hit(hwnd,width/2,height-1),win32.HTBOTTOM)
    size:=f.window.size
    testing.expect(t,window_set_regions(p,{
        {{0,0,f32(size.x),36},.Drag},
        {{60,4,80,28},.Client},
        {{f32(size.x)-46,0,46,36},.Control},
    }))
    testing.expect_value(t,hit(hwnd,width/2,at(20,scale)),win32.HTCAPTION)
    testing.expect_value(t,hit(hwnd,at(100,scale),at(20,scale)),win32.HTCLIENT)
    testing.expect_value(t,hit(hwnd,width/2,at(60,scale)),win32.HTCLIENT)
    testing.expect_value(t,hit(hwnd,width-at(20,scale),at(20,scale)),win32.HTCLIENT)
    testing.expect_value(t,hit(hwnd,width-at(20,scale),at(1,scale)),win32.HTTOPRIGHT)
    // The application is dragging something of its own: no edge resizes.
    testing.expect(t,window_set_regions(p,{{{0,0,f32(size.x),36},.Drag}},resizable=false))
    testing.expect_value(t,hit(hwnd,width/2,at(3,scale)),win32.HTCAPTION)
    testing.expect_value(t,hit(hwnd,at(3,scale),height/2),win32.HTCLIENT)

    // Size and title reach the window; it stays hidden through all of it.
    window_set_size(p,{900,640})
    window_set_title(p,"renamed")
    frame_begin(p)
    testing.expect_value(t,f.window.size,[2]i32{900,640})
    testing.expect(t,f.window.resized)
    title:[64]u16
    length:=win32.GetWindowTextW(hwnd,raw_data(title[:]),i32(len(title)))
    renamed:=[?]u16{'r','e','n','a','m','e','d'}
    testing.expect_value(t,length,i32(len(renamed)))
    for unit,i in renamed {testing.expect(t,title[i]==unit)}
    testing.expect(t,!win32.IsWindowVisible(hwnd))
    testing.expect(t,!f.window.visible)
}

// A window that is not asked to stay hidden is shown, cloaked, at creation:
// the system already gave it its size when the first frame presents, and that
// frame uncloaks it. Hidden before, it never reaches the screen.
native_veiled_window_checks :: proc(t:^testing.T) {
    _=sdl.SetHint(sdl.HINT_WINDOW_ACTIVATE_WHEN_SHOWN,"0")
    defer _=sdl.ResetHint(sdl.HINT_WINDOW_ACTIVATE_WHEN_SHOWN)
    p,error:=create({window={title="Mirai veiled test",size={640,400},chrome=.Custom},pacing=Frame_Pacing{}})
    testing.expect_value(t,error,Error.None)
    if p==nil {return}
    defer destroy(p)
    hwnd:=win32.HWND(sdl.GetPointerProperty(sdl.GetWindowProperties(p.window.handle),sdl.PROP_WINDOW_WIN32_HWND_POINTER,nil))
    testing.expect(t,hwnd!=nil)
    if hwnd==nil {return}
    cloaked :: proc(hwnd:win32.HWND) -> bool {
        value:win32.DWORD
        _=win32.DwmGetWindowAttribute(hwnd,u32(win32.DWMWINDOWATTRIBUTE.DWMWA_CLOAKED),&value,size_of(value))
        return value!=0
    }
    testing.expect(t,bool(win32.IsWindowVisible(hwnd)) && cloaked(hwnd))
    testing.expect(t,input_frame(p).window.visible)
    frame_end(p,false)
    testing.expect(t,cloaked(hwnd))
    window_hide(p)
    frame_end(p,true)
    testing.expect(t,!cloaked(hwnd))
    testing.expect_value(t,p.window.veil,0)
    testing.expect(t,!win32.IsWindowVisible(hwnd))
}
