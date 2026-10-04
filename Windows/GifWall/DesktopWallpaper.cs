using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Threading;
using static GifWall.Native;
using Screen = System.Windows.Forms.Screen;

namespace GifWall;

/// One window per monitor, placed inside Explorer's desktop behind the icons, looping the file with libmpv.
/// Playback pauses while the desktop is fully covered, the session is locked or the displays are off.
sealed class DesktopWallpaper
{
    readonly List<WallpaperWindow> windows = new();
    readonly DispatcherTimer occlusionTimer = new() { Interval = TimeSpan.FromSeconds(1.5) };
    string? file;
    IntPtr parent;
    bool locked, displayOff;

    public string? Error { get; private set; }

    public DesktopWallpaper()
    {
        occlusionTimer.Tick += (_, _) => Tick();
    }

    public void Show(string path)
    {
        if (path == file && windows.Count > 0 && IsWindow(parent)) return;
        file = path;
        Rebuild();
    }

    public void Hide()
    {
        file = null;
        Rebuild();
    }

    /// Monitors changed or Explorer restarted (its desktop window, and our windows inside it, are gone).
    public void Rebuild()
    {
        foreach (var w in windows) w.Dispose();
        windows.Clear();
        occlusionTimer.Stop();
        Error = null;
        if (parent != IntPtr.Zero && IsWindow(parent))
            RedrawWindow(parent, IntPtr.Zero, IntPtr.Zero, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW);
        if (file == null) return;

        var desktop = DesktopHost.Find();
        if (desktop == null)
        {
            Error = "Не удалось встроиться в рабочий стол Windows";
            return;
        }
        parent = desktop.Value.Parent;
        try
        {
            foreach (var screen in Screen.AllScreens)
                windows.Add(new WallpaperWindow(desktop.Value, screen, file));
        }
        catch (Exception e)
        {
            foreach (var w in windows) w.Dispose();
            windows.Clear();
            Error = "Не удалось запустить проигрыватель: " + e.Message;
            return;
        }
        occlusionTimer.Start();
        Tick();
    }

    public void SetLocked(bool value) { locked = value; Tick(); }
    public void SetDisplayOff(bool value) { displayOff = value; Tick(); }

    void Tick()
    {
        if (windows.Count == 0) return;
        if (!IsWindow(parent)) { Rebuild(); return; }
        var covering = locked || displayOff ? null : CoveringWindows();
        foreach (var w in windows)
            w.SetPaused(covering == null || covering.Any(r => Contains(r, w.Bounds)));
    }

    static bool Contains(RECT a, RECT b) => a.Left <= b.Left && a.Top <= b.Top && a.Right >= b.Right && a.Bottom >= b.Bottom;

    /// Rectangles that hide a whole monitor: maximized windows (taskbar aside, nothing of the desktop is visible)
    /// and windows at least as large as the monitor, e.g. fullscreen games and videos.
    static List<RECT> CoveringWindows()
    {
        var result = new List<RECT>();
        EnumWindows((hwnd, _) =>
        {
            if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return true;
            DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, out int cloaked, sizeof(int));
            if (cloaked != 0) return true;
            var cls = ClassName(hwnd);
            if (cls is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd") return true;
            // Invisible fullscreen overlays (GPU overlays, screen recorders) are click-through tool windows.
            var ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
            if ((ex & (WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT)) != 0) return true;
            if (DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out RECT r, System.Runtime.InteropServices.Marshal.SizeOf<RECT>()) != 0)
                GetWindowRect(hwnd, out r);
            if (IsZoomed(hwnd))
            {
                var screen = Screen.FromHandle(hwnd).Bounds;
                r = new RECT { Left = screen.Left, Top = screen.Top, Right = screen.Right, Bottom = screen.Bottom };
            }
            result.Add(r);
            return true;
        }, IntPtr.Zero);
        return result;
    }
}

/// Explorer's desktop: the window that sits behind the icons, where live wallpapers are drawn.
readonly record struct DesktopHost(IntPtr Parent, IntPtr InsertAfter)
{
    public static DesktopHost? Find()
    {
        var progman = FindWindow("Progman", null);
        if (progman == IntPtr.Zero) return null;
        // Asks Explorer to create the WorkerW window behind the icons (what it does for wallpaper fades).
        SendMessageTimeout(progman, 0x052C, new IntPtr(0xD), new IntPtr(1), SMTO_NORMAL, 1000, out _);
        SendMessageTimeout(progman, 0x052C, IntPtr.Zero, IntPtr.Zero, SMTO_NORMAL, 1000, out _);

        // Windows 11 24H2+: icons (SHELLDLL_DefView) and WorkerW are children of Progman.
        // Our window goes between them: above the static wallpaper, below the icons.
        var defView = FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (defView != IntPtr.Zero && FindWindowEx(progman, IntPtr.Zero, "WorkerW", null) != IntPtr.Zero)
            return new DesktopHost(progman, defView);

        // Earlier versions: a top-level WorkerW holds the icons, the next WorkerW is the empty one behind them.
        IntPtr workerW = IntPtr.Zero;
        EnumWindows((hwnd, _) =>
        {
            if (FindWindowEx(hwnd, IntPtr.Zero, "SHELLDLL_DefView", null) == IntPtr.Zero) return true;
            workerW = FindWindowEx(IntPtr.Zero, hwnd, "WorkerW", null);
            return false;
        }, IntPtr.Zero);
        return workerW != IntPtr.Zero ? new DesktopHost(workerW, IntPtr.Zero) : null;
    }
}

sealed class WallpaperWindow : IDisposable
{
    readonly IntPtr hwnd;
    readonly Mpv player;
    bool? paused;

    /// Monitor rectangle in screen pixels.
    public RECT Bounds { get; }

    public WallpaperWindow(DesktopHost host, Screen screen, string file)
    {
        var b = screen.Bounds;
        Bounds = new RECT { Left = b.Left, Top = b.Top, Right = b.Right, Bottom = b.Bottom };
        // Child coordinates are relative to the parent, whose origin is the top-left of the virtual screen.
        var origin = new POINT();
        MapWindowPoints(host.Parent, IntPtr.Zero, ref origin, 1);
        const int SS_BLACKRECT = 0x4;
        hwnd = CreateWindowEx(WS_EX_NOACTIVATE, "Static", "GifWall",
            WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | SS_BLACKRECT,
            b.Left - origin.X, b.Top - origin.Y, b.Width, b.Height, host.Parent, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (hwnd == IntPtr.Zero) throw new InvalidOperationException("CreateWindowEx");
        if (host.InsertAfter != IntPtr.Zero)
            SetWindowPos(hwnd, host.InsertAfter, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        try
        {
            player = new Mpv(Mpv.PlayerOptions(hwnd));
        }
        catch
        {
            DestroyWindow(hwnd);
            throw;
        }
        player.Load(file);
    }

    public void SetPaused(bool value)
    {
        if (paused == value) return;
        paused = value;
        player.Set("pause", value ? "yes" : "no");
    }

    public void Dispose()
    {
        player.Dispose();
        DestroyWindow(hwnd);
    }
}
