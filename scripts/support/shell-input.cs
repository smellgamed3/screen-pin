using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PinShellInput {
    [StructLayout(LayoutKind.Sequential)] private struct Key {public ushort key,scan;public uint flags,time;public UIntPtr extra;}
    [StructLayout(LayoutKind.Sequential)] private struct Mouse {public int x,y;public uint data,flags,time;public UIntPtr extra;}
    [StructLayout(LayoutKind.Explicit)] private struct Data {[FieldOffset(0)]public Key key;[FieldOffset(0)]public Mouse mouse;}
    [StructLayout(LayoutKind.Sequential)] private struct Input {public uint type;public Data data;}
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr h,uint flag);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetClassNameW(IntPtr h,StringBuilder text,int count);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern uint SendInput(uint count,Input[] input,int size);
    public static void AssertForeground(IntPtr h,uint pid){uint owner;GetWindowThreadProcessId(h,out owner);var name=new StringBuilder(256);GetClassNameW(h,name,name.Capacity);if(!IsWindow(h)||owner!=pid||GetAncestor(h,2)!=h||GetForegroundWindow()!=h||(name.ToString()!="CabinetWClass"&&name.ToString()!="CASCADIA_HOSTING_WINDOW_CLASS"))throw new InvalidOperationException("Foreground left the verified Explorer/Terminal window; input cancelled");}
    private static Input Event(ushort key,bool up){return new Input{type=1,data=new Data{key=new Key{key=key,flags=up?2u:0u}}};}
    public static void Chord(IntPtr h,uint pid,ushort key){
        AssertForeground(h,pid);if(key!=0x78&&key!=0x79)throw new ArgumentException("Only F9/F10 test hotkeys are supported");
        foreach(int code in new[]{0x10,0x11,0x12,0x5b,0x5c,0x78,0x79})if((GetAsyncKeyState(code)&0x8000)!=0)throw new InvalidOperationException("A test modifier/key is already held; input cancelled");
        var input=new[]{Event(0x11,false),Event(0x12,false),Event(key,false),Event(key,true),Event(0x12,true),Event(0x11,true)};
        if(SendInput((uint)input.Length,input,Marshal.SizeOf(typeof(Input)))!=input.Length){var release=new[]{Event(key,true),Event(0x12,true),Event(0x11,true)};SendInput((uint)release.Length,release,Marshal.SizeOf(typeof(Input)));throw new InvalidOperationException("Incomplete SendInput; injected keys released");}
        AssertForeground(h,pid);
    }
}
