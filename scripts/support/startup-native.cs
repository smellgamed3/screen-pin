using System;
using System.Runtime.InteropServices;
using System.Text;

// Read-only observations of the launched settings window. Keyboard input is
// provided separately by desktop-keyboard.cs, with foreground/PID checks.
public static class PinStartupNative {
    [StructLayout(LayoutKind.Sequential)] private struct Rect {public int Left,Top,Right,Bottom;}
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h,out Rect rect);
    [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr h,out Rect rect);
    [DllImport("user32.dll")] private static extern int MapWindowPoints(IntPtr from,IntPtr to,ref Rect rect,uint count);
    [DllImport("user32.dll")] private static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint timeout,out UIntPtr result);
    [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",CharSet=CharSet.Unicode)] private static extern IntPtr ReadText(IntPtr h,uint m,IntPtr w,StringBuilder l,uint flags,uint timeout,out UIntPtr result);
    public static bool FullyVisible(IntPtr settings,uint pid,int id){
        if(PinDesktopKeyboard.Owner(settings)!=pid||PinDesktopKeyboard.Class(settings)!="ScreenPin.Settings")return false;
        var child=PinDesktopKeyboard.GetDlgItem(settings,id);Rect rect,client;
        if(!PinDesktopKeyboard.IsWindowVisible(settings)||!PinDesktopKeyboard.IsWindowVisible(child)||!GetWindowRect(child,out rect)||!GetClientRect(settings,out client))return false;
        MapWindowPoints(settings,IntPtr.Zero,ref client,2);
        return rect.Right>rect.Left&&rect.Bottom>rect.Top&&rect.Left>=client.Left&&rect.Top>=client.Top&&rect.Right<=client.Right&&rect.Bottom<=client.Bottom;
    }
    public static int FixtureIndex(IntPtr settings,uint pid,string title){
        if(PinDesktopKeyboard.Owner(settings)!=pid||PinDesktopKeyboard.Class(settings)!="ScreenPin.Settings")throw new InvalidOperationException("Settings ownership changed");
        var list=PinDesktopKeyboard.GetDlgItem(settings,108);UIntPtr count;
        if(SendMessageTimeoutW(list,0x18b,IntPtr.Zero,IntPtr.Zero,0x23,50,out count)==IntPtr.Zero)throw new InvalidOperationException("Window list read timed out");
        for(int i=0;i<(int)count.ToUInt64();i++){var text=new StringBuilder(32768);UIntPtr result;if(ReadText(list,0x189,new IntPtr(i),text,0x23,50,out result)==IntPtr.Zero)throw new InvalidOperationException("List text read timed out");if(text.ToString().Contains(title))return i;}
        return -1;
    }
    public static int Selection(IntPtr settings,uint pid){if(PinDesktopKeyboard.Owner(settings)!=pid)throw new InvalidOperationException("Settings ownership changed");UIntPtr result;if(SendMessageTimeoutW(PinDesktopKeyboard.GetDlgItem(settings,108),0x188,IntPtr.Zero,IntPtr.Zero,0x23,50,out result)==IntPtr.Zero)throw new InvalidOperationException("Selection read timed out");return unchecked((int)result.ToUInt64());}
}
