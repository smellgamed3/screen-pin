using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class PinRaceSentinel {
    private delegate IntPtr Procedure(IntPtr h,uint m,IntPtr w,IntPtr l);
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct Class {public uint style;public IntPtr procedure;public int classExtra,windowExtra;public IntPtr instance,icon,cursor,background;public string menu,name;}
    [StructLayout(LayoutKind.Sequential)] private struct Message {public IntPtr h;public uint m;public UIntPtr w;public IntPtr l;public uint time;public int x,y;public uint extra;}
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern ushort RegisterClassW(ref Class value);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern IntPtr CreateWindowExW(uint ex,string c,string title,uint style,int x,int y,int width,int height,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr param);
    [DllImport("user32.dll")] private static extern IntPtr DefWindowProcW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern void PostQuitMessage(int code);
    [DllImport("user32.dll")] private static extern int GetMessageW(out Message m,IntPtr h,uint first,uint last);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref Message m);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessageW(ref Message m);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr h,int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetClassNameW(IntPtr h,StringBuilder b,int n);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] private static extern IntPtr GetModuleHandleW(string value);
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
    private static readonly Procedure procedure=WindowProc;
    private static readonly ManualResetEventSlim ready=new ManualResetEventSlim(false);
    private static Thread thread;
    private static string name,failure;
    public static IntPtr Window;
    private static IntPtr WindowProc(IntPtr h,uint m,IntPtr w,IntPtr l){if(m==0x10){DestroyWindow(h);return IntPtr.Zero;}if(m==2){PostQuitMessage(0);return IntPtr.Zero;}return DefWindowProcW(h,m,w,l);}
    public static void Start(string title){
        name="ScreenPin.RealHotkeyFixture."+Guid.NewGuid().ToString("N");
        thread=new Thread(delegate(){try{
            SetThreadDpiAwarenessContext(new IntPtr(-4));var instance=GetModuleHandleW(null);
            var c=new Class{procedure=Marshal.GetFunctionPointerForDelegate(procedure),instance=instance,name=name};
            if(RegisterClassW(ref c)==0)throw new InvalidOperationException("Sentinel class registration failed");
            Window=CreateWindowExW(0,name,title,0x00cf0000,1420,300,620,470,IntPtr.Zero,IntPtr.Zero,instance,IntPtr.Zero);
            if(Window==IntPtr.Zero)throw new InvalidOperationException("Sentinel creation failed");
            ShowWindow(Window,4);ready.Set();Message m;
            while(GetMessageW(out m,IntPtr.Zero,0,0)>0){TranslateMessage(ref m);DispatchMessageW(ref m);}
        }catch(Exception error){failure=error.ToString();ready.Set();}});
        thread.IsBackground=true;thread.Start();if(!ready.Wait(3000))throw new InvalidOperationException("Sentinel startup timed out");if(failure!=null)throw new InvalidOperationException(failure);
    }
    public static void AssertOwned(){uint owner;GetWindowThreadProcessId(Window,out owner);var text=new StringBuilder(256);GetClassNameW(Window,text,text.Capacity);if(!IsWindow(Window)||owner!=(uint)System.Diagnostics.Process.GetCurrentProcess().Id||text.ToString()!=name)throw new InvalidOperationException("Sentinel identity changed");}
    public static void Activate(IntPtr previous){
        AssertOwned();if(GetForegroundWindow()!=previous)throw new InvalidOperationException("Foreground changed before intentional switch");
        SetForegroundWindow(Window);var watch=System.Diagnostics.Stopwatch.StartNew();
        while(GetForegroundWindow()!=Window&&watch.ElapsedMilliseconds<120){var current=GetForegroundWindow();if(current!=IntPtr.Zero&&current!=previous&&current!=Window)throw new InvalidOperationException("External foreground switch observed: HWND="+current+"; further input cancelled");Thread.Sleep(1);}
        AssertForeground();
    }
    public static void AssertForeground(){AssertOwned();if(GetForegroundWindow()!=Window)throw new InvalidOperationException("Foreground left the owned sentinel; further input cancelled");}
    public static void Stop(){if(Window!=IntPtr.Zero&&IsWindow(Window)){AssertOwned();PostMessageW(Window,0x10,IntPtr.Zero,IntPtr.Zero);}if(thread!=null&&!thread.Join(2000))throw new InvalidOperationException("Sentinel did not exit normally");}
}
