using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Win32;
using static GifWall.Native;
using Forms = System.Windows.Forms;

namespace GifWall;

/// Tray app. Leaves the system as if GifWall had never run: on quit (menu, logoff, shutdown, uninstall)
/// the original lock screen is restored and the wallpaper window removed. The next launch applies them again.
public partial class App : Application
{
    Forms.NotifyIcon? tray;
    PanelWindow? panel;
    HwndSource? events;
    bool quitting;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var args = e.Args.Select(a => a.ToLowerInvariant()).ToArray();

        if (args.Contains("--uninstall"))
        {
            Installer.Uninstall();
            MessageBox.Show("GifWall удалён. Экран блокировки и обои вернулись к прежним.", "GifWall");
            Installer.RemoveProgramOnExit();
            Shutdown();
            return;
        }

        // First run of the downloaded exe: install for this user and continue from the installed copy.
        if (!Installer.IsInstalledCopy && !args.Contains("--portable"))
        {
            try
            {
                Installer.Install();
                Process.Start(new ProcessStartInfo(Installer.Exe) { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                MessageBox.Show("Не удалось установить GifWall: " + ex.Message, "GifWall", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            Shutdown();
            return;
        }

        if (!SingleInstance.Acquire())
        {
            SingleInstance.SignalShow();
            Shutdown();
            return;
        }
        SingleInstance.Listen(
            show: () => Dispatcher.BeginInvoke(() => panel?.ShowNearTray()),
            quit: () => Dispatcher.Invoke(Quit));

        panel = new PanelWindow();
        CreateTray();
        ListenToSystem();
        _ = WallpaperController.Shared.Start();

        // Launched by hand (not at login): show what it is right away.
        if (!args.Contains("--background")) panel.ShowNearTray();
    }

    void CreateTray()
    {
        tray = new Forms.NotifyIcon { Text = "GifWall — живые обои", Icon = TrayIcon.Create(), Visible = true };
        tray.MouseUp += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left) TogglePanel();
        };
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Открыть", null, (_, _) => panel?.ShowNearTray());
        menu.Items.Add("Выйти", null, (_, _) => Quit());
        tray.ContextMenuStrip = menu;
    }

    DateTime panelHiddenAt;

    void TogglePanel()
    {
        if (panel == null) return;
        // Clicking the tray icon deactivates (hides) the open panel first; that click shouldn't reopen it.
        if (panel.IsVisible || (DateTime.Now - panelHiddenAt).TotalMilliseconds < 300) { panel.Hide(); return; }
        panel.ShowNearTray();
    }

    /// Lock/unlock, displays turning off, monitor changes and Explorer restarts.
    void ListenToSystem()
    {
        var c = WallpaperController.Shared;
        panel!.IsVisibleChanged += (_, _) => { if (!panel.IsVisible) panelHiddenAt = DateTime.Now; };

        SystemEvents.SessionSwitch += (_, e) =>
        {
            if (e.Reason == SessionSwitchReason.SessionLock) Dispatcher.BeginInvoke(() => c.SessionLocked(true));
            if (e.Reason == SessionSwitchReason.SessionUnlock) Dispatcher.BeginInvoke(() => c.SessionLocked(false));
        };
        SystemEvents.DisplaySettingsChanged += (_, _) => Dispatcher.BeginInvoke(c.DisplaysChanged);

        // A hidden top-level window: message-only windows don't receive broadcasts like TaskbarCreated.
        events = new HwndSource(new HwndSourceParameters("GifWall.Events") { Width = 0, Height = 0, WindowStyle = 0 });
        uint taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        RegisterPowerSettingNotification(events.Handle, ref GUID_CONSOLE_DISPLAY_STATE, 0);
        events.AddHook((IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) =>
        {
            if (msg == WM_POWERBROADCAST && wParam.ToInt32() == PBT_POWERSETTINGCHANGE)
            {
                var setting = Marshal.PtrToStructure<POWERBROADCAST_SETTING>(lParam);
                if (setting.PowerSetting == GUID_CONSOLE_DISPLAY_STATE) c.DisplayPower(setting.Data == 0);
            }
            else if (msg == (int)taskbarCreated)
            {
                // Explorer restarted: its desktop (and our windows inside it) are new.
                Dispatcher.BeginInvoke(c.DisplaysChanged);
            }
            return IntPtr.Zero;
        });
    }

    public async void Quit()
    {
        if (quitting) return;
        quitting = true;
        panel?.Hide();
        if (tray != null) tray.Visible = false;
        // Never hang forever; whatever didn't finish is completed on the next launch.
        await Task.WhenAny(WallpaperController.Shared.RestoreSystem(), Task.Delay(5000));
        Shutdown();
    }

    /// Logoff/shutdown: restore synchronously, the process may be killed right after this returns.
    protected override void OnSessionEnding(SessionEndingCancelEventArgs e)
    {
        base.OnSessionEnding(e);
        quitting = true;
        try { WallpaperController.Shared.RestoreSystem().Wait(TimeSpan.FromSeconds(4)); } catch { }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        tray?.Dispose();
        events?.Dispose();
        SingleInstance.Release();
        base.OnExit(e);
    }
}

/// Tray icon: two waves with a small sparkle (matches the app icon), drawn in code so it stays crisp
/// at any DPI and follows the taskbar's light/dark theme.
static class TrayIcon
{
    public static Icon Create()
    {
        bool lightTaskbar = false;
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            lightTaskbar = key?.GetValue("SystemUsesLightTheme") is int v && v == 1;
        }
        catch { }
        int size = Forms.SystemInformation.SmallIconSize.Width * 2;
        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float k = size / 18f;
            var color = lightTaskbar ? Color.FromArgb(28, 28, 28) : Color.White;
            using var pen = new Pen(color, 1.35f * k) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            // Same geometry as the macOS menu bar icon, with y flipped (GDI+ y grows downwards).
            foreach (var baseY in new[] { 9.6f, 5.8f })
            {
                var pts = Enumerable.Range(0, 41).Select(i =>
                {
                    float u = i / 40f;
                    return new PointF((1.5f + u * 15f) * k, (18 - (baseY + 1.7f * MathF.Sin(2 * MathF.PI * (u - 0.02f)))) * k);
                }).ToArray();
                g.DrawLines(pen, pts);
            }
            float cx = 13.6f * k, cy = (18 - 14.4f) * k, r = 2.6f * k, q = 0.45f * k;
            using var star = new GraphicsPath();
            star.AddBezier(cx, cy - r, cx + q, cy - q, cx + q, cy - q, cx + r, cy);
            star.AddBezier(cx + r, cy, cx + q, cy + q, cx + q, cy + q, cx, cy + r);
            star.AddBezier(cx, cy + r, cx - q, cy + q, cx - q, cy + q, cx - r, cy);
            star.AddBezier(cx - r, cy, cx - q, cy - q, cx - q, cy - q, cx, cy - r);
            using var brush = new SolidBrush(color);
            g.FillPath(brush, star);
        }
        return Icon.FromHandle(bmp.GetHicon());
    }
}
