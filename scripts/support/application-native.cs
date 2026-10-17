using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PinApplication {
 public delegate bool EnumProc(IntPtr hwnd,IntPtr data);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback,IntPtr data);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd,StringBuilder text,int length);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hwnd,StringBuilder text,int length);
 [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hwnd,int id);
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd,IntPtr dc,uint flags);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd,int command);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp);
 [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp);
 [DllImport("user32.dll",EntryPoint="SendMessageW",CharSet=CharSet.Unicode)] public static extern IntPtr SendText(IntPtr hwnd,uint msg,IntPtr wp,StringBuilder text);
 [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd,uint attr,out Rect rect,uint size);
 [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd,uint flags);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern bool GetMonitorInfoW(IntPtr monitor,ref Monitor info);
 [StructLayout(LayoutKind.Sequential)] public struct Rect {public int Left,Top,Right,Bottom;}
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct Monitor {public uint Size;public Rect Bounds,Work;public uint Flags;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)]public string Device;}
}
