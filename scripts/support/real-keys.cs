using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class PinRealKeys {
 // Test observers must not hold a handle that prevents atomic replacement.
 public static string ReadConfig(string path){using(var stream=System.IO.File.Open(path,System.IO.FileMode.Open,System.IO.FileAccess.Read,System.IO.FileShare.ReadWrite|System.IO.FileShare.Delete))using(var reader=new System.IO.StreamReader(stream,System.Text.Encoding.UTF8,true))return reader.ReadToEnd();}
 public delegate bool EnumProc(IntPtr h,IntPtr d);
 private delegate IntPtr WndProc(IntPtr h,uint m,IntPtr w,IntPtr l);
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct WindowClass { public uint style;public IntPtr proc;public int classExtra,windowExtra;public IntPtr instance,icon,cursor,background;public string menu,name; }
 [StructLayout(LayoutKind.Sequential)] private struct Message {public IntPtr h;public uint m;public UIntPtr w;public IntPtr l;public uint time;public int x,y;public uint extra;}
 [StructLayout(LayoutKind.Sequential)] private struct Keyboard {public ushort key,scan;public uint flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Sequential)] private struct Mouse {public int x,y;public uint data,flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Explicit)] private struct InputData {[FieldOffset(0)]public Keyboard keyboard;[FieldOffset(0)]public Mouse mouse;}
 [StructLayout(LayoutKind.Sequential)] private struct Input {public uint type;public InputData data;}
 [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo {public uint size;public Rect bounds,work;public uint flags;}
 [StructLayout(LayoutKind.Sequential)] private struct Point {public int x,y;}
 [DllImport("user32.dll")]private static extern bool GetCursorPos(out Point point);
 [DllImport("user32.dll")]private static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")]private static extern IntPtr WindowFromPoint(Point point);
 [DllImport("user32.dll")]private static extern IntPtr GetAncestor(IntPtr h,uint flags);
 [DllImport("user32.dll")]private static extern bool EnumWindows(EnumProc callback,IntPtr d);
 [DllImport("user32.dll")]public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]private static extern int GetClassNameW(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]private static extern int GetWindowTextW(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]private static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")]private static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")]private static extern bool IsWindowEnabled(IntPtr h);
 [DllImport("user32.dll")]private static extern short GetAsyncKeyState(int key);
 [DllImport("user32.dll",SetLastError=true)]private static extern uint SendInput(uint n,Input[] inputs,int size);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]private static extern ushort RegisterClassW(ref WindowClass c);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)]private static extern IntPtr CreateWindowExW(uint ex,string c,string t,uint style,int x,int y,int w,int h,IntPtr p,IntPtr menu,IntPtr instance,IntPtr param);
 [DllImport("user32.dll")]private static extern IntPtr DefWindowProcW(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")]private static extern bool DestroyWindow(IntPtr h);
 [DllImport("user32.dll")]private static extern void PostQuitMessage(int code);
 [DllImport("user32.dll")]private static extern int GetMessageW(out Message m,IntPtr h,uint first,uint last);
 [DllImport("user32.dll")]private static extern bool TranslateMessage(ref Message m);
 [DllImport("user32.dll")]private static extern IntPtr DispatchMessageW(ref Message m);
 [DllImport("user32.dll")]private static extern bool ShowWindow(IntPtr h,int command);
 [DllImport("user32.dll")]public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll",SetLastError=true)]private static extern bool RegisterHotKey(IntPtr h,int id,uint modifiers,uint key);
 [DllImport("user32.dll")]private static extern bool UnregisterHotKey(IntPtr h,int id);
 [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",CharSet=CharSet.Unicode,SetLastError=true)]private static extern IntPtr SendString(IntPtr h,uint m,IntPtr w,string l,uint flags,uint timeout,out UIntPtr result);
 [DllImport("user32.dll",SetLastError=true)]private static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint timeout,out UIntPtr result);
 [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",CharSet=CharSet.Unicode,SetLastError=true)]private static extern IntPtr SendText(IntPtr h,uint m,IntPtr w,StringBuilder l,uint flags,uint timeout,out UIntPtr result);
 [DllImport("user32.dll")]private static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")]private static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]private static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
 [DllImport("dwmapi.dll")]private static extern int DwmGetWindowAttribute(IntPtr h,int attribute,out Rect value,int size);
 [DllImport("user32.dll")]private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
 [DllImport("user32.dll")]private static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")]private static extern IntPtr MonitorFromWindow(IntPtr h,uint flags);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]private static extern bool GetMonitorInfoW(IntPtr h,ref MonitorInfo info);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)]private static extern IntPtr GetModuleHandleW(string name);
 private static Thread fixtureThread;
 private static readonly ManualResetEventSlim ready=new ManualResetEventSlim(false);
 private static readonly WndProc procedure=WindowProcedure;
 private static string failure;
 private static string fixtureClass;
 private static bool held;
 private static IntPtr rebuildingWindow;
 private static readonly ManualResetEventSlim rebuilt=new ManualResetEventSlim(false);
 private static string rebuildFailure;
 private static long actionAppliedTicks;
 private static IntPtr actionObserver;
 private static uint observerPid;
 private static int actionSawBusy=-1;
 public static IntPtr Fixture;
 private static IntPtr WindowProcedure(IntPtr h,uint m,IntPtr w,IntPtr l){
  if(h==Fixture&&m>=0x8044&&m<=0x8046){
   Thread.Sleep((int)Math.Max(0,Math.Min(5000,w.ToInt64())));
   if(actionObserver!=IntPtr.Zero){uint owner;GetWindowThreadProcessId(actionObserver,out owner);var refresh=GetDlgItem(actionObserver,109);Interlocked.Exchange(ref actionSawBusy,owner==observerPid&&refresh!=IntPtr.Zero?(IsWindowEnabled(refresh)?0:1):-1);}
   if(m==0x8045)DestroyWindow(h);
   if(m==0x8046){
    rebuildingWindow=h;DestroyWindow(h);
    Fixture=CreateWindowExW(0,fixtureClass,"Screen Pin isolated real hotkey fixture",0x00cf0000,850,760,620,430,IntPtr.Zero,IntPtr.Zero,GetModuleHandleW(null),IntPtr.Zero);
    rebuildingWindow=IntPtr.Zero;
    if(Fixture==IntPtr.Zero)rebuildFailure="Replacement fixture creation failed";else ShowWindow(Fixture,4);
   }
   Interlocked.Exchange(ref actionAppliedTicks,System.Diagnostics.Stopwatch.GetTimestamp());
   if(m==0x8046)rebuilt.Set();
   return IntPtr.Zero;
  }
  if(m==0x8042)return new IntPtr(RegisterHotKey(h,1000+w.ToInt32(),0x4003,(uint)w.ToInt32())?1:0);
  if(m==0x8043)return new IntPtr(UnregisterHotKey(h,1000+w.ToInt32())?1:0);
  if(m==0x10){DestroyWindow(h);return IntPtr.Zero;}
  if(m==2){if(h!=rebuildingWindow)PostQuitMessage(0);return IntPtr.Zero;}
  return DefWindowProcW(h,m,w,l);
 }
 public static void Schedule(int operation,int milliseconds){AssertForeground();if(operation<0x8044||operation>0x8046||milliseconds<0||milliseconds>5000)throw new ArgumentException("Unsupported owned fixture schedule");Interlocked.Exchange(ref actionAppliedTicks,0);Interlocked.Exchange(ref actionSawBusy,-1);if(operation==0x8046){rebuilt.Reset();rebuildFailure=null;}if(!PostMessageW(Fixture,(uint)operation,new IntPtr(milliseconds),IntPtr.Zero))throw new InvalidOperationException("Fixture schedule failed");}
 public static bool Rebuilt(){if(!rebuilt.IsSet)return false;if(rebuildFailure!=null)throw new InvalidOperationException(rebuildFailure);return true;}
 public static long ActionAppliedTicks(){return Interlocked.Read(ref actionAppliedTicks);}
 public static int ActionSawBusy(){return Interlocked.CompareExchange(ref actionSawBusy,0,0);}
 public static void ObserveActions(IntPtr settings,uint expected){uint owner;GetWindowThreadProcessId(settings,out owner);var name=new StringBuilder(256);GetClassNameW(settings,name,name.Capacity);if(owner!=expected||name.ToString()!="ScreenPin.Settings")throw new InvalidOperationException("Action observer does not belong to the owned settings window");observerPid=expected;actionObserver=settings;}
 public static IntPtr StartFixture(){
  fixtureClass="ScreenPin.RealHotkeyFixture."+Guid.NewGuid().ToString("N");
  fixtureThread=new Thread(delegate(){try{
   SetThreadDpiAwarenessContext(new IntPtr(-4));
   var instance=GetModuleHandleW(null);
   var c=new WindowClass{proc=Marshal.GetFunctionPointerForDelegate(procedure),instance=instance,name=fixtureClass};
   if(RegisterClassW(ref c)==0)throw new InvalidOperationException("Fixture RegisterClassW failed");
   Fixture=CreateWindowExW(0,fixtureClass,"Screen Pin isolated real hotkey fixture",0x00cf0000,140,140,720,480,IntPtr.Zero,IntPtr.Zero,instance,IntPtr.Zero);
   if(Fixture==IntPtr.Zero)throw new InvalidOperationException("Fixture CreateWindowExW failed");
   ShowWindow(Fixture,1);ShowWindow(Fixture,5);SetForegroundWindow(Fixture);ready.Set();
   Message message;while(GetMessageW(out message,IntPtr.Zero,0,0)>0){TranslateMessage(ref message);DispatchMessageW(ref message);}
  }catch(Exception e){failure=e.ToString();ready.Set();}});
  fixtureThread.IsBackground=true;fixtureThread.Start();
  if(!ready.Wait(3000))throw new InvalidOperationException("Fixture UI thread startup timed out");
  if(failure!=null)throw new InvalidOperationException(failure);
  ActivateGuestWindow(Fixture,(uint)System.Diagnostics.Process.GetCurrentProcess().Id);
  return Fixture;
 }
 // Only an explicitly opted-in guest driver may use this real caption click.
 // Host verifiers retain their original public-UIA activation and input guards.
 public static void ActivateGuestWindow(IntPtr window,uint expectedPid){
  var run=Environment.GetEnvironmentVariable("SCREEN_PIN_FIXTURE_GUEST");if(string.IsNullOrEmpty(run))return;
  Guid id;var host=Environment.GetEnvironmentVariable("SCREEN_PIN_FIXTURE_HOST");
  if(!Guid.TryParse(run,out id)||string.IsNullOrEmpty(host)||Environment.MachineName.Equals(host,StringComparison.OrdinalIgnoreCase)||!System.Security.Principal.WindowsIdentity.GetCurrent().Name.EndsWith("\\WDAGUtilityAccount",StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Guest activation guard rejected this environment");
  if(GetForegroundWindow()==window)return;
  if((GetAsyncKeyState(1)&0x8000)!=0)throw new InvalidOperationException("Guest activation mouse button is already held; click cancelled");
  uint owner;GetWindowThreadProcessId(window,out owner);Rect rect;Point cursor;
  if(owner!=expectedPid||GetAncestor(window,2)!=window||!GetWindowRect(window,out rect)||!GetCursorPos(out cursor))throw new InvalidOperationException("Guest activation identity/bounds unavailable");
  var point=new Point{x=rect.Left+(rect.Right-rect.Left)/2,y=rect.Top+12};
  if(!SetWindowPos(window,new IntPtr(-1),0,0,0,0,0x13))throw new InvalidOperationException("Guest activation placement failed");
  try{
   Thread.Sleep(60);GetWindowThreadProcessId(window,out owner);
   if(owner!=expectedPid||GetAncestor(WindowFromPoint(point),2)!=window||!SetCursorPos(point.x,point.y))throw new InvalidOperationException("Guest activation point is covered or ownership changed; click cancelled");
   var input=new[]{new Input{data=new InputData{mouse=new Mouse{flags=2}}},new Input{data=new InputData{mouse=new Mouse{flags=4}}}};
   if(SendInput(2,input,System.Runtime.InteropServices.Marshal.SizeOf(typeof(Input)))!=2){SendInput(1,new[]{new Input{data=new InputData{mouse=new Mouse{flags=4}}}},System.Runtime.InteropServices.Marshal.SizeOf(typeof(Input)));throw new InvalidOperationException("Guest caption click was incomplete");}
   for(int i=0;i<100&&GetForegroundWindow()!=window;i++)Thread.Sleep(10);
   if(GetForegroundWindow()!=window)throw new InvalidOperationException("Guest caption click did not activate the intended window");
  }finally{SetWindowPos(window,new IntPtr(-2),0,0,0,0,0x13);SetCursorPos(cursor.x,cursor.y);}
 }
 public static void StopFixture(){ReleaseHeldKeys();if(Fixture!=IntPtr.Zero&&IsWindow(Fixture))PostMessageW(Fixture,0x10,IntPtr.Zero,IntPtr.Zero);if(fixtureThread!=null)fixtureThread.Join(2000);}
 public static void AssertForeground(){
  uint owner;GetWindowThreadProcessId(Fixture,out owner);
  var name=new StringBuilder(256);GetClassNameW(Fixture,name,name.Capacity);
  if(Fixture==IntPtr.Zero||!IsWindow(Fixture)||owner!=(uint)System.Diagnostics.Process.GetCurrentProcess().Id||name.ToString()!=fixtureClass||GetForegroundWindow()!=Fixture)
   throw new InvalidOperationException("Foreground is not the owned fixture; input cancelled without refocusing or bypassing Windows foreground policy.");
 }
 private static Input Key(ushort key,bool up){return new Input{type=1,data=new InputData{keyboard=new Keyboard{key=key,flags=up?2u:0u}}};}
 private static void Send(Input[] inputs){if(SendInput((uint)inputs.Length,inputs,Marshal.SizeOf(typeof(Input)))!=inputs.Length)throw new InvalidOperationException("SendInput did not accept the complete owned-fixture sequence");}
 private static void CheckReleased(ushort functionKey){foreach(int key in new[]{0x11,0x12,0x78,0x79,(int)functionKey})if((GetAsyncKeyState(key)&0x8000)!=0)throw new InvalidOperationException("A test modifier/function key is physically held; input cancelled.");}
 public static void Chord(ushort functionKey){AssertForeground();CheckReleased(functionKey);try{Send(new[]{Key(0x11,false),Key(0x12,false),Key(functionKey,false),Key(functionKey,true),Key(0x12,true),Key(0x11,true)});}catch{Send(new[]{Key(functionKey,true),Key(0x12,true),Key(0x11,true)});throw;}AssertForeground();}
 public static void BeginHold(){AssertForeground();CheckReleased(0x79);held=true;Send(new[]{Key(0x11,false),Key(0x12,false),Key(0x79,false)});AssertForeground();}
 public static void RepeatHeld(){AssertForeground();if(!held)throw new InvalidOperationException("No test hold is active");Send(new[]{Key(0x79,false)});AssertForeground();}
 public static void EndHold(){AssertForeground();ReleaseHeldKeys();AssertForeground();}
 public static void ReleaseHeldKeys(){if(held){held=false;Send(new[]{Key(0x79,true),Key(0x12,true),Key(0x11,true)});}}
 public static IntPtr[] FindClass(string c,uint processId){var result=new List<IntPtr>();EnumWindows(delegate(IntPtr h,IntPtr d){uint owner;GetWindowThreadProcessId(h,out owner);if(processId==0||owner==processId){var n=new StringBuilder(256);GetClassNameW(h,n,n.Capacity);if(n.ToString()==c)result.Add(h);}return true;},IntPtr.Zero);return result.ToArray();}
 public static bool Responsive(IntPtr h){UIntPtr result;return SendMessageTimeoutW(h,0,IntPtr.Zero,IntPtr.Zero,0x23,50,out result)!=IntPtr.Zero;}
 public static string Text(IntPtr ui,int id){var b=new StringBuilder(32768);UIntPtr result;if(SendText(GetDlgItem(ui,id),0x0d,new IntPtr(b.Capacity),b,0x23,50,out result)==IntPtr.Zero)throw new InvalidOperationException("Timed out reading own app result");return b.ToString();}
 public static bool Block(ushort key){AssertForeground();UIntPtr result;if(SendMessageTimeoutW(Fixture,0x8042,new IntPtr(key),IntPtr.Zero,0x23,200,out result)==IntPtr.Zero)throw new InvalidOperationException("Fixture blocker timed out");return result.ToUInt64()==1;}
 public static void Unblock(ushort key){UIntPtr result;if(SendMessageTimeoutW(Fixture,0x8043,new IntPtr(key),IntPtr.Zero,0x23,200,out result)==IntPtr.Zero||result.ToUInt64()!=1)throw new InvalidOperationException("Could not release owned blocker");}
 private static void AssertOwner(IntPtr ui,uint expected){uint owner;GetWindowThreadProcessId(ui,out owner);var name=new StringBuilder(256);GetClassNameW(ui,name,name.Capacity);if(owner!=expected||name.ToString()!="ScreenPin.Settings")throw new InvalidOperationException("Settings ownership changed");}
 public static void ControlText(IntPtr ui,uint expected,int id,string value){AssertOwner(ui,expected);UIntPtr result;if(SendString(GetDlgItem(ui,id),0x0c,IntPtr.Zero,value,0x23,200,out result)==IntPtr.Zero||result.ToUInt64()==0)throw new InvalidOperationException("Control text update failed");}
 public static void Command(IntPtr ui,uint expected,int id){AssertOwner(ui,expected);UIntPtr result;if(SendMessageTimeoutW(ui,0x111,new IntPtr(id),IntPtr.Zero,0x23,200,out result)==IntPtr.Zero)throw new InvalidOperationException("Settings command timed out");}
 public static bool Enabled(IntPtr ui,uint expected,int id){AssertOwner(ui,expected);return IsWindowEnabled(GetDlgItem(ui,id));}
 // Native host list selection measured about 310 ms on both candidates. Only
 // this test command has a 2 s bound; readback verifies the intended selection.
 public static void SelectWindow(IntPtr ui,uint expected,string title){AssertOwner(ui,expected);var list=GetDlgItem(ui,108);UIntPtr count;if(SendMessageTimeoutW(list,0x18b,IntPtr.Zero,IntPtr.Zero,0x23,200,out count)==IntPtr.Zero)throw new InvalidOperationException("Window-list inspection timed out");for(int i=0;i<(int)count.ToUInt64();i++){var text=new StringBuilder(32768);UIntPtr result;if(SendText(list,0x189,new IntPtr(i),text,0x23,200,out result)==IntPtr.Zero)throw new InvalidOperationException("Window-list text timed out");if(text.ToString().Contains(title)){if(SendMessageTimeoutW(list,0x186,new IntPtr(i),IntPtr.Zero,0x23,2000,out result)==IntPtr.Zero)throw new InvalidOperationException("Window selection timed out");if(SendMessageTimeoutW(list,0x188,IntPtr.Zero,IntPtr.Zero,0x23,200,out result)==IntPtr.Zero||(int)result.ToUInt64()!=i)throw new InvalidOperationException("Window selection readback differs");Command(ui,expected,65536+108);return;}}throw new InvalidOperationException("Own fixture is missing from the eligible-window list");}
 public static void FixtureTitle(string title){AssertForeground();UIntPtr result;if(SendString(Fixture,0x0c,IntPtr.Zero,title,0x23,200,out result)==IntPtr.Zero||result.ToUInt64()==0)throw new InvalidOperationException("Fixture title update failed");AssertForeground();}
 public static IntPtr FindDialog(uint expected,string title){foreach(var h in FindClass("#32770",expected)){var text=new StringBuilder(256);GetWindowTextW(h,text,text.Capacity);if(text.ToString()==title)return h;}return IntPtr.Zero;}
 private static void AssertDialog(IntPtr h,uint expected,string title){if(h==IntPtr.Zero||FindDialog(expected,title)!=h)throw new InvalidOperationException("Dialog ownership/title changed");}
 public static int DefaultButton(IntPtr h,uint expected,string title){AssertDialog(h,expected,title);UIntPtr result;if(SendMessageTimeoutW(h,0x400,IntPtr.Zero,IntPtr.Zero,0x23,200,out result)==IntPtr.Zero)throw new InvalidOperationException("Default-button inspection timed out");return (int)(result.ToUInt64()&0xffff);}
 public static void DialogButton(IntPtr h,uint expected,string title,int id){AssertDialog(h,expected,title);UIntPtr result;if(SendMessageTimeoutW(GetDlgItem(h,id),0xf5,IntPtr.Zero,IntPtr.Zero,0x23,200,out result)==IntPtr.Zero)throw new InvalidOperationException("Dialog action timed out");}
 public static Rect Frame(){Rect r;if(DwmGetWindowAttribute(Fixture,9,out r,Marshal.SizeOf(typeof(Rect)))!=0)throw new InvalidOperationException("Cannot read fixture DWM frame");return r;}
 public static Rect Work(){var info=new MonitorInfo{size=(uint)Marshal.SizeOf(typeof(MonitorInfo))};if(!GetMonitorInfoW(MonitorFromWindow(Fixture,2),ref info))throw new InvalidOperationException("Cannot read fixture work area");return info.work;}
 public static uint FixtureDpi(){return GetDpiForWindow(Fixture);}
 public static Rect Move(int x,int y,int width,int height){AssertForeground();var old=SetThreadDpiAwarenessContext(new IntPtr(-4));try{Rect outer;GetWindowRect(Fixture,out outer);var visible=Frame();var expected=new Rect{Left=x+visible.Left-outer.Left,Top=y+visible.Top-outer.Top,Right=x+width-(outer.Right-visible.Right),Bottom=y+height-(outer.Bottom-visible.Bottom)};if(!SetWindowPos(Fixture,IntPtr.Zero,x,y,width,height,0x4214))throw new InvalidOperationException("Cannot move owned fixture");return expected;}finally{if(old!=IntPtr.Zero)SetThreadDpiAwarenessContext(old);}}
 public static int EdgeError(Rect a,Rect b){return Math.Max(Math.Max(Math.Abs(a.Left-b.Left),Math.Abs(a.Top-b.Top)),Math.Max(Math.Abs(a.Right-b.Right),Math.Abs(a.Bottom-b.Bottom)));}
}
