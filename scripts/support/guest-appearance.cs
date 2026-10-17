using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class PinGuestAppearance {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]public struct Font{public int Height,Width,Escapement,Orientation,Weight;public byte Italic,Underline,StrikeOut,CharacterSet,OutPrecision,ClipPrecision,Quality,PitchAndFamily;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)]public string Face;}
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]public struct Metrics{public uint Size;public int Border,ScrollWidth,ScrollHeight,CaptionWidth,CaptionHeight;public Font Caption;public int SmallCaptionWidth,SmallCaptionHeight;public Font SmallCaption;public int MenuWidth,MenuHeight;public Font Menu,Status,Message;public int PaddedBorder;}
 [StructLayout(LayoutKind.Sequential)]private struct HighContrast{public uint Size,Flags;public IntPtr Scheme;}
 public class Contrast{public uint Flags;public string Scheme;}
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)]private static extern bool SystemParametersInfoW(uint action,uint size,ref Metrics value,uint flags);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)]private static extern bool SystemParametersInfoW(uint action,uint size,ref HighContrast value,uint flags);
 [DllImport("user32.dll")]private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
 [DllImport("user32.dll")]public static extern uint GetSysColor(int index);
 [StructLayout(LayoutKind.Sequential)]private struct Size{public int Width,Height;}
 [DllImport("user32.dll")]private static extern IntPtr GetDC(IntPtr window);
 [DllImport("user32.dll")]private static extern int ReleaseDC(IntPtr window,IntPtr dc);
 [DllImport("gdi32.dll",CharSet=CharSet.Unicode)]private static extern int GetObjectW(IntPtr h,int size,out Font font);
 [DllImport("gdi32.dll",CharSet=CharSet.Unicode)]private static extern IntPtr CreateFontIndirectW(ref Font font);
 [DllImport("gdi32.dll")]private static extern bool DeleteObject(IntPtr h);
 [DllImport("gdi32.dll")]private static extern IntPtr SelectObject(IntPtr dc,IntPtr value);
 [DllImport("gdi32.dll",CharSet=CharSet.Unicode)]private static extern bool GetTextExtentPoint32W(IntPtr dc,string text,int length,out Size size);
 [DllImport("user32.dll")]private static extern IntPtr SendMessageTimeoutW(IntPtr h,uint msg,IntPtr w,IntPtr l,uint flags,uint timeout,out UIntPtr value);
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")]private static extern IntPtr GetWindowLongPtrW(IntPtr h,int index);
 public static bool ReadOnlyEdit(IntPtr h){return (GetWindowLongPtrW(h,-16).ToInt64()&0x800)!=0;}
 public static int FirstVisibleCharacter(IntPtr h){UIntPtr value;if(SendMessageTimeoutW(h,0xce,IntPtr.Zero,IntPtr.Zero,0x23,500,out value)==IntPtr.Zero)throw new InvalidOperationException("Owned edit scroll query timed out");return (int)value.ToUInt64();}
 public static int TextWidth(IntPtr window,string text){
  UIntPtr handle;if(SendMessageTimeoutW(window,0x31,IntPtr.Zero,IntPtr.Zero,0x23,500,out handle)==IntPtr.Zero)throw new InvalidOperationException("Owned font query timed out");
  Font font;if(GetObjectW(new IntPtr((long)handle.ToUInt64()),Marshal.SizeOf(typeof(Font)),out font)==0)throw new InvalidOperationException("Owned font metadata unavailable");
  var local=CreateFontIndirectW(ref font);if(local==IntPtr.Zero)throw new InvalidOperationException("Local font copy unavailable");var dc=GetDC(window);if(dc==IntPtr.Zero){DeleteObject(local);throw new InvalidOperationException("Owned font DC unavailable");}
  var previous=SelectObject(dc,local);try{if(previous==IntPtr.Zero||previous==new IntPtr(-1))throw new InvalidOperationException("Local font selection failed");Size size;var displayed=text.Replace("&","");Check(GetTextExtentPoint32W(dc,displayed,displayed.Length,out size));return size.Width;}finally{if(previous!=IntPtr.Zero&&previous!=new IntPtr(-1))SelectObject(dc,previous);ReleaseDC(window,dc);DeleteObject(local);}
 }
 [StructLayout(LayoutKind.Sequential)]private struct Rect{public int Left,Top,Right,Bottom;}
 [StructLayout(LayoutKind.Sequential)]private struct Point{public int X,Y;}
 [StructLayout(LayoutKind.Sequential)]private struct Mouse{public int X,Y;public uint Data,Flags,Time;public UIntPtr Extra;}
 [StructLayout(LayoutKind.Sequential)]private struct Key{public ushort KeyCode,Scan;public uint Flags,Time;public UIntPtr Extra;}
 [StructLayout(LayoutKind.Explicit)]private struct InputData{[FieldOffset(0)]public Mouse Mouse;[FieldOffset(0)]public Key Key;}
 [StructLayout(LayoutKind.Sequential)]private struct Input{public uint Type;public InputData Data;}
 [DllImport("user32.dll")]private static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")]private static extern bool GetWindowRect(IntPtr h,out Rect rect);
 [DllImport("user32.dll")]private static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("user32.dll")]private static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")]private static extern bool GetCursorPos(out Point point);
 [DllImport("user32.dll")]private static extern IntPtr WindowFromPoint(Point point);
 [DllImport("user32.dll")]private static extern IntPtr GetAncestor(IntPtr h,uint flags);
 [DllImport("user32.dll")]private static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]private static extern uint SendInput(uint count,Input[] input,int size);
 public static void Activate(IntPtr window,uint expectedPid){
  if(GetForegroundWindow()==window)return;
  uint owner;GetWindowThreadProcessId(window,out owner);Rect rect;Point cursor;
  if(owner!=expectedPid||!GetWindowRect(window,out rect)||!GetCursorPos(out cursor))throw new InvalidOperationException("Owned activation identity/bounds unavailable");
  var point=new Point{X=rect.Left+(rect.Right-rect.Left)/2,Y=rect.Top+12};
  Check(SetWindowPos(window,new IntPtr(-1),0,0,0,0,0x13));
  try{
   System.Threading.Thread.Sleep(60);
   if(GetAncestor(WindowFromPoint(point),2)!=window)throw new InvalidOperationException("Owned activation point is covered; click cancelled");
   GetWindowThreadProcessId(window,out owner);if(owner!=expectedPid)throw new InvalidOperationException("Owned activation identity changed");
   Check(SetCursorPos(point.X,point.Y));
   var input=new[]{new Input{Data=new InputData{Mouse=new Mouse{Flags=2}}},new Input{Data=new InputData{Mouse=new Mouse{Flags=4}}}};
   if(SendInput(2,input,Marshal.SizeOf(typeof(Input)))!=2)throw new InvalidOperationException("Owned caption click was incomplete");
   for(int i=0;i<100&&GetForegroundWindow()!=window;i++)System.Threading.Thread.Sleep(10);
   if(GetForegroundWindow()!=window)throw new InvalidOperationException("Owned caption click did not activate the intended window");
  }finally{SetWindowPos(window,new IntPtr(-2),0,0,0,0,0x13);SetCursorPos(cursor.X,cursor.Y);}
 }
 private static void Check(bool result){if(!result)throw new Win32Exception(Marshal.GetLastWin32Error());}
 public static Metrics ReadMetrics(){var previous=SetThreadDpiAwarenessContext(new IntPtr(-1));try{var m=new Metrics{Size=(uint)Marshal.SizeOf(typeof(Metrics))};Check(SystemParametersInfoW(41,m.Size,ref m,0));return m;}finally{SetThreadDpiAwarenessContext(previous);}}
 public static void ApplyMetrics(Metrics value){var previous=SetThreadDpiAwarenessContext(new IntPtr(-1));try{Check(SystemParametersInfoW(42,value.Size,ref value,3));}finally{SetThreadDpiAwarenessContext(previous);}}
 // Snapshot only; ownership of this returned pointer remains unresolved after a native heap failure in the earlier interop fixture. Its lifetime is bounded by this short-lived guest verifier.
 public static Contrast ReadContrast(){var c=new HighContrast{Size=(uint)Marshal.SizeOf(typeof(HighContrast))};Check(SystemParametersInfoW(66,c.Size,ref c,0));return new Contrast{Flags=c.Flags,Scheme=c.Scheme==IntPtr.Zero?null:Marshal.PtrToStringUni(c.Scheme)};}
 public static void ApplyContrast(Contrast value){var c=new HighContrast{Size=(uint)Marshal.SizeOf(typeof(HighContrast)),Flags=value.Flags,Scheme=value.Scheme==null?IntPtr.Zero:Marshal.StringToHGlobalUni(value.Scheme)};try{Check(SystemParametersInfoW(67,c.Size,ref c,3));}finally{if(c.Scheme!=IntPtr.Zero)Marshal.FreeHGlobal(c.Scheme);}}
}
