using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class PinApplicationInput {
    public delegate bool EnumProc(IntPtr h, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] private struct Key { public ushort key, scan; public uint flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] private struct Mouse { public int x, y; public uint data, flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] private struct Data { [FieldOffset(0)] public Key key; [FieldOffset(0)] public Mouse mouse; }
    [StructLayout(LayoutKind.Sequential)] private struct Input { public uint type; public Data data; }
    [StructLayout(LayoutKind.Sequential)] private struct Rect {public int left,top,right,bottom;}
    [StructLayout(LayoutKind.Sequential)] private struct GuiInfo {public uint size,flags;public IntPtr active,focus,capture,menuOwner,moveSize,caret;public Rect caretRect;}
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr h, uint flag);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] private static extern bool GetGUIThreadInfo(uint thread,ref GuiInfo info);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern uint MapVirtualKeyExW(uint code, uint map, IntPtr layout);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassNameW(IntPtr h, StringBuilder text, int length);
    [DllImport("user32.dll", SetLastError=true)] private static extern uint SendInput(uint count, Input[] input, int size);

    private static string Class(IntPtr h) {
        var text = new StringBuilder(256);
        GetClassNameW(h, text, text.Capacity);
        return text.ToString();
    }
    public static bool Owned(IntPtr h, uint expected, IntPtr root, uint rootExpected) {
        uint owner, rootOwner;
        GetWindowThreadProcessId(h, out owner);
        GetWindowThreadProcessId(root, out rootOwner);
        return IsWindow(h) && IsWindow(root) && owner == expected && rootOwner == rootExpected
            && Class(root) == "Chrome_WidgetWin_1"
            && (h == root || (Class(h) == "#32770" && GetAncestor(h, 3) == root));
    }
    public static void AssertForeground(IntPtr h, uint expected, IntPtr root, uint rootExpected) {
        if (!Owned(h, expected, root, rootExpected) || GetForegroundWindow() != h)
            throw new InvalidOperationException("Foreground left the owned application/dialog; keyboard input cancelled.");
    }
    public static IntPtr Dialog(uint expected, IntPtr root) {
        var result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr data) {
            uint owner; GetWindowThreadProcessId(h,out owner);
            // Discovery is read-only. PowerShell verifies the candidate process
            // image, profile and parent before any input or close request.
            if (h != root && Owned(h, owner, root, expected)) result = h;
            return true;
        }, IntPtr.Zero);
        return result;
    }
    public static string[] Snapshot(uint expected) {
        var rows = new List<string>();
        var foreground=GetForegroundWindow();uint foregroundPid;
        GetWindowThreadProcessId(foreground,out foregroundPid);
        rows.Add("Foreground HWND="+foreground+" class="+Class(foreground)+" PID="+foregroundPid+" rootOwner="+GetAncestor(foreground,3));
        EnumWindows(delegate(IntPtr h, IntPtr data) {
            uint owner; uint thread=GetWindowThreadProcessId(h, out owner);
            if (owner == expected) {
                var info=new GuiInfo{size=(uint)Marshal.SizeOf(typeof(GuiInfo))};
                bool known=GetGUIThreadInfo(thread,ref info);
                rows.Add("HWND="+h+" class="+Class(h)+" visible="+IsWindowVisible(h)+" rootOwner="+GetAncestor(h,3)+" foreground="+(foreground==h)+" focus="+(known?info.focus.ToString():"unknown")+" focusClass="+(known?Class(info.focus):"unknown"));
            }
            return true;
        }, IntPtr.Zero);
        return rows.ToArray();
    }
    private static Input Event(ushort key, bool up, IntPtr layout) {
        uint scan=MapVirtualKeyExW(key,4,layout);
        if (scan==0 || (scan>>8)==0xe1) throw new InvalidOperationException("Unsupported scan-code translation; no input sent.");
        uint flags=8u | (up ? 2u : 0u) | ((scan>>8)==0xe0 ? 1u : 0u);
        return new Input { type=1, data=new Data { key=new Key { scan=(ushort)(scan&0xff), flags=flags } } };
    }
    public static void Text(IntPtr h, uint expected, IntPtr root, uint rootExpected, string text) {
        if (String.IsNullOrEmpty(text) || text.Length > 2048 || text.IndexOfAny(new[] {'\r', '\n', '\0'}) >= 0)
            throw new ArgumentException("Expected one bounded path without control characters");
        for (int offset=0; offset<text.Length; offset+=16) {
            AssertForeground(h, expected, root, rootExpected);
            foreach (int code in new[] {0x11,0x12,0x10,0x5b,0x5c})
                if ((GetAsyncKeyState(code)&0x8000)!=0) throw new InvalidOperationException("Modifier held during path entry; input cancelled");
            var input=new List<Input>();var releases=new List<Input>();
            for (int i=offset; i<Math.Min(offset+16,text.Length); i++) {
                var down=new Input{type=1,data=new Data{key=new Key{scan=text[i],flags=4u}}};
                var up=new Input{type=1,data=new Data{key=new Key{scan=text[i],flags=6u}}};
                input.Add(down);input.Add(up);releases.Add(up);
            }
            var events=input.ToArray();
            if (SendInput((uint)events.Length,events,Marshal.SizeOf(typeof(Input)))!=events.Length) {
                var cleanup=releases.ToArray();SendInput((uint)cleanup.Length,cleanup,Marshal.SizeOf(typeof(Input)));
                throw new InvalidOperationException("Path entry was incomplete; injected Unicode keys released");
            }
            AssertForeground(h, expected, root, rootExpected);
        }
    }
    public static void Chord(IntPtr h, uint expected, IntPtr root, uint rootExpected, ushort key, uint modifiers, bool allowDialogAfter) {
        AssertForeground(h, expected, root, rootExpected);
        if ((modifiers & ~3u) != 0) throw new ArgumentException("Only Ctrl/Alt test modifiers are supported");
        foreach (int code in new[] { 0x11, 0x12, 0x10, 0x5b, 0x5c, (int)key })
            if ((GetAsyncKeyState(code) & 0x8000) != 0)
                throw new InvalidOperationException("A test key/modifier is already held; input cancelled.");
        uint owner; uint thread=GetWindowThreadProcessId(h,out owner);
        IntPtr layout=GetKeyboardLayout(thread);
        var input = new List<Input>();
        if ((modifiers & 1) != 0) input.Add(Event(0x11, false, layout));
        if ((modifiers & 2) != 0) input.Add(Event(0x12, false, layout));
        input.Add(Event(key, false, layout)); input.Add(Event(key, true, layout));
        if ((modifiers & 2) != 0) input.Add(Event(0x12, true, layout));
        if ((modifiers & 1) != 0) input.Add(Event(0x11, true, layout));
        var events = input.ToArray();
        if (SendInput((uint)events.Length, events, Marshal.SizeOf(typeof(Input))) != events.Length) {
            var release = new List<Input> { Event(key, true, layout) };
            if ((modifiers & 2) != 0) release.Add(Event(0x12, true, layout));
            if ((modifiers & 1) != 0) release.Add(Event(0x11, true, layout));
            var cleanup = release.ToArray();
            SendInput((uint)cleanup.Length, cleanup, Marshal.SizeOf(typeof(Input)));
            throw new InvalidOperationException("SendInput accepted an incomplete sequence; injected keys released.");
        }
        var foreground = GetForegroundWindow();
        uint foregroundOwner;GetWindowThreadProcessId(foreground,out foregroundOwner);
        if (allowDialogAfter ? !Owned(foreground, foregroundOwner, root, rootExpected) : foreground != h)
            throw new InvalidOperationException("Foreground changed during input; further input cancelled.");
    }
}
