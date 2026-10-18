using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class PinViewport {
 public delegate bool EnumProc(IntPtr h,IntPtr data);
 [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]public struct Font{public int Height,Width,Escapement,Orientation,Weight;public byte Italic,Underline,StrikeOut,CharacterSet,OutPrecision,ClipPrecision,Quality,PitchAndFamily;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)]public string Face;}
 public class Box{public int id,region;public Rect bounds,visible;}
 [DllImport("user32.dll")]public static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]private static extern bool GetClientRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]private static extern int MapWindowPoints(IntPtr a,IntPtr b,ref Rect r,uint count);
 [DllImport("user32.dll")]private static extern bool EnumChildWindows(IntPtr h,EnumProc p,IntPtr data);
 [DllImport("user32.dll")]private static extern IntPtr GetParent(IntPtr h);
 [DllImport("user32.dll")]private static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]private static extern bool IsWindowEnabled(IntPtr h);
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")]private static extern IntPtr GetWindowLongPtrW(IntPtr h,int index);
 public static int[] TabIds(IntPtr root){var ids=new List<int>();EnumChildWindows(root,delegate(IntPtr h,IntPtr data){if(GetParent(h)==root&&IsWindowVisible(h)&&IsWindowEnabled(h)&&(GetWindowLongPtrW(h,-16).ToInt64()&0x10000)!=0)ids.Add(GetDlgCtrlID(h));return true;},IntPtr.Zero);return ids.ToArray();}
 [DllImport("user32.dll")]private static extern int GetDlgCtrlID(IntPtr h);
 [DllImport("user32.dll")]private static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]private static extern bool SetWindowTextW(IntPtr h,string text);
 [DllImport("user32.dll")]private static extern int GetWindowRgn(IntPtr h,IntPtr region);
 [DllImport("gdi32.dll")]private static extern IntPtr CreateRectRgn(int a,int b,int c,int d);
 [DllImport("gdi32.dll")]private static extern int GetRgnBox(IntPtr region,out Rect r);
 [DllImport("gdi32.dll")]private static extern bool DeleteObject(IntPtr h);
 [DllImport("gdi32.dll",CharSet=CharSet.Unicode)]private static extern int GetObjectW(IntPtr h,int size,out Font font);
 [DllImport("user32.dll")]public static extern uint GetGuiResources(IntPtr process,uint flags);
 [DllImport("user32.dll")]public static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")]public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
 [DllImport("user32.dll")]public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
 [DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("user32.dll")]private static extern IntPtr SendMessageTimeoutW(IntPtr h,uint msg,IntPtr wp,IntPtr lp,uint flags,uint timeout,out UIntPtr result);
 public static void Message(IntPtr h,uint pid,uint message,int wp){uint owner;GetWindowThreadProcessId(h,out owner);if(owner!=pid)throw new InvalidOperationException("Viewport message owner mismatch");UIntPtr result;if(SendMessageTimeoutW(h,message,new IntPtr(wp),IntPtr.Zero,0x23,500,out result)==IntPtr.Zero)throw new InvalidOperationException("Own viewport message timed out");}
 public static void Title(IntPtr h,uint pid,string title){uint owner;GetWindowThreadProcessId(h,out owner);if(owner!=pid||!SetWindowTextW(h,title))throw new InvalidOperationException("Fixture title ownership mismatch");}
 public static Rect Bounds(IntPtr h){Rect r;if(!GetWindowRect(h,out r))throw new InvalidOperationException("Own control bounds unavailable");return r;}
 public static Rect Client(IntPtr h){Rect r;if(!GetClientRect(h,out r))throw new InvalidOperationException("Own client bounds unavailable");MapWindowPoints(h,IntPtr.Zero,ref r,2);return r;}
 public static Font ControlFont(IntPtr h){UIntPtr result;if(SendMessageTimeoutW(h,0x31,IntPtr.Zero,IntPtr.Zero,0x23,100,out result)==IntPtr.Zero)throw new InvalidOperationException("Font query timed out");Font font;if(GetObjectW(new IntPtr((long)result.ToUInt64()),Marshal.SizeOf(typeof(Font)),out font)==0)throw new InvalidOperationException("Font metadata unavailable");return font;}
 public static Box[] Content(IntPtr root){var boxes=new List<Box>();EnumChildWindows(root,delegate(IntPtr h,IntPtr data){if(GetParent(h)!=root||!IsWindowVisible(h))return true;int id=GetDlgCtrlID(h);if(id==100||id==101||id==102||id==136||id==137||id==138||id==143||id==144||id==145)return true;var r=Bounds(h);var visible=r;var region=CreateRectRgn(0,0,0,0);if(region==IntPtr.Zero)throw new InvalidOperationException("Region query allocation failed");int type;try{type=GetWindowRgn(h,region);if(type==1)visible=new Rect();else if(type!=0){Rect local;GetRgnBox(region,out local);visible=new Rect{Left=Math.Max(r.Left,r.Left+local.Left),Top=Math.Max(r.Top,r.Top+local.Top),Right=Math.Min(r.Right,r.Left+local.Right),Bottom=Math.Min(r.Bottom,r.Top+local.Bottom)};}}finally{DeleteObject(region);}boxes.Add(new Box{id=id,region=type,bounds=r,visible=visible});return true;},IntPtr.Zero);return boxes.ToArray();}
}
