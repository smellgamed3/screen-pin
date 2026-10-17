using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

// Input is limited to an explicitly checked foreground HWND and PID. Menu
// commands are read back before Enter so navigation never guesses an action.
public static class PinDesktopKeyboard {
    public delegate bool EnumProc(IntPtr h,IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct Rect {public int Left,Top,Right,Bottom;}
    [StructLayout(LayoutKind.Sequential)] private struct GuiInfo {public uint size,flags;public IntPtr active,focus,capture,menuOwner,moveSize,caret;public Rect caretRect;}
    [StructLayout(LayoutKind.Sequential)] private struct Key {public ushort key,scan;public uint flags,time;public UIntPtr extra;}
    [StructLayout(LayoutKind.Sequential)] private struct Mouse {public int x,y;public uint data,flags,time;public UIntPtr extra;}
    [StructLayout(LayoutKind.Explicit)] private struct Data {[FieldOffset(0)]public Key key;[FieldOffset(0)]public Mouse mouse;}
    [StructLayout(LayoutKind.Sequential)] private struct Input {public uint type;public Data data;}
    [StructLayout(LayoutKind.Sequential)] private struct IconId {public uint size;public IntPtr host;public uint id;public Guid guid;}
    public class MenuItem {public uint id;public string text;public bool enabled,highlighted;}
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h,uint flags);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback,IntPtr data);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetClassNameW(IntPtr h,StringBuilder text,int size);
    [DllImport("user32.dll")] private static extern bool GetGUIThreadInfo(uint thread,ref GuiInfo info);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern uint SendInput(uint count,Input[] input,int size);
    [DllImport("user32.dll")] private static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint timeout,out UIntPtr result);
    [DllImport("user32.dll")] private static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] private static extern uint GetMenuItemID(IntPtr menu,int position);
    [DllImport("user32.dll")] private static extern uint GetMenuState(IntPtr menu,uint position,uint flags);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetMenuStringW(IntPtr menu,uint position,StringBuilder text,int count,uint flags);
    [DllImport("shell32.dll")] private static extern int Shell_NotifyIconGetRect(ref IconId id,out Rect rect);
    public static string Class(IntPtr h){var text=new StringBuilder(256);GetClassNameW(h,text,text.Capacity);return text.ToString();}
    public static uint Owner(IntPtr h){uint pid;GetWindowThreadProcessId(h,out pid);return pid;}
    public static void AssertForeground(IntPtr h,uint pid){if(h==IntPtr.Zero||!IsWindow(h)||Owner(h)!=pid||GetForegroundWindow()!=h)throw new InvalidOperationException("Foreground ownership changed; further input cancelled");}
    private static Input KeyInput(ushort key,bool up){return new Input{type=1,data=new Data{key=new Key{key=key,flags=up?2u:0u}}};}
    public static void Press(IntPtr h,uint pid,ushort key,ushort modifier){
        AssertForeground(h,pid);
        foreach(int code in new[]{0x10,0x11,0x12,0x5b,0x5c,(int)key})if((GetAsyncKeyState(code)&0x8000)!=0)throw new InvalidOperationException("A test key/modifier is already held; input cancelled");
        var input=new List<Input>();if(modifier!=0)input.Add(KeyInput(modifier,false));input.Add(KeyInput(key,false));input.Add(KeyInput(key,true));if(modifier!=0)input.Add(KeyInput(modifier,true));
        if(SendInput((uint)input.Count,input.ToArray(),Marshal.SizeOf(typeof(Input)))!=input.Count){
            var releases=new List<Input>{KeyInput(key,true)};if(modifier!=0)releases.Add(KeyInput(modifier,true));SendInput((uint)releases.Count,releases.ToArray(),Marshal.SizeOf(typeof(Input)));
            throw new InvalidOperationException("SendInput accepted an incomplete sequence");
        }
    }
    public static int FocusId(IntPtr root,uint pid){uint owner;var thread=GetWindowThreadProcessId(root,out owner);if(owner!=pid)throw new InvalidOperationException("Focus root ownership changed");var info=new GuiInfo{size=(uint)Marshal.SizeOf(typeof(GuiInfo))};if(!GetGUIThreadInfo(thread,ref info))throw new InvalidOperationException("Focus query failed");return GetDlgCtrlID(info.focus);}
    public static string[] FocusChain(IntPtr root,uint pid){uint owner;var thread=GetWindowThreadProcessId(root,out owner);if(owner!=pid)throw new InvalidOperationException("Focus root ownership changed");var info=new GuiInfo{size=(uint)Marshal.SizeOf(typeof(GuiInfo))};if(!GetGUIThreadInfo(thread,ref info))throw new InvalidOperationException("Focus query failed");var result=new List<string>();for(var h=info.focus;h!=IntPtr.Zero&&result.Count<16;h=GetAncestor(h,1)){result.Add(h.ToInt64()+":"+GetDlgCtrlID(h)+":"+Class(h));if(h==root)break;}return result.ToArray();}
    [DllImport("user32.dll")] private static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h,int id);
    public static IntPtr Menu(IntPtr host,uint pid){
        uint owner;var thread=GetWindowThreadProcessId(host,out owner);if(owner!=pid)return IntPtr.Zero;
        var info=new GuiInfo{size=(uint)Marshal.SizeOf(typeof(GuiInfo))};if(!GetGUIThreadInfo(thread,ref info)||info.menuOwner!=host)return IntPtr.Zero;
        var found=IntPtr.Zero;
        EnumWindows(delegate(IntPtr h,IntPtr data){if(Owner(h)==pid&&Class(h)=="#32768"){UIntPtr result;if(SendMessageTimeoutW(h,0x01e1,IntPtr.Zero,IntPtr.Zero,0x23,50,out result)!=IntPtr.Zero&&result!=UIntPtr.Zero)found=new IntPtr((long)result.ToUInt64());}return true;},IntPtr.Zero);
        return found;
    }
    public static MenuItem[] Items(IntPtr host,uint pid){var menu=Menu(host,pid);if(menu==IntPtr.Zero)throw new InvalidOperationException("Owned tray menu is not active");var count=GetMenuItemCount(menu);if(count!=6)throw new InvalidOperationException("Unexpected tray menu structure");var result=new List<MenuItem>();for(uint i=0;i<count;i++){var state=GetMenuState(menu,i,0x400);var text=new StringBuilder(1024);GetMenuStringW(menu,i,text,text.Capacity,0x400);result.Add(new MenuItem{id=GetMenuItemID(menu,(int)i),text=text.ToString(),enabled=(state&3)==0,highlighted=(state&0x80)!=0});}return result.ToArray();}
    public static void EnterMenu(IntPtr host,uint pid,uint command){AssertForeground(host,pid);foreach(var item in Items(host,pid))if(item.id==command&&item.enabled&&item.highlighted){Press(host,pid,0x0d,0);return;}throw new InvalidOperationException("Intended command is not highlighted/enabled; Enter cancelled");}
    public static Rect IconRect(IntPtr host,uint pid){if(Owner(host)!=pid||Class(host)!="ScreenPin.Host")throw new InvalidOperationException("Icon host identity changed");var id=new IconId{size=(uint)Marshal.SizeOf(typeof(IconId)),host=host,id=1};Rect rect;if(Shell_NotifyIconGetRect(ref id,out rect)!=0)throw new InvalidOperationException("Own notification icon rectangle is unavailable");return rect;}
}
