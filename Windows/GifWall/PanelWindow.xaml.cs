using System;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;
using static GifWall.Native;
using Forms = System.Windows.Forms;

namespace GifWall;

/// The tray panel: the Windows counterpart of the macOS menu bar window. Opens above the tray icon,
/// closes (hides) when it loses focus.
public partial class PanelWindow : Window
{
    readonly WallpaperController c = WallpaperController.Shared;
    readonly PreviewPlayer preview;
    int shownVersion = -1;
    bool dialogOpen;

    public PanelWindow()
    {
        InitializeComponent();
        ApplyTheme();
        preview = new PreviewPlayer(PreviewImage);
        c.PropertyChanged += Controller_Changed;
        SystemEvents.UserPreferenceChanged += (_, _) => Dispatcher.Invoke(ApplyTheme);
        Deactivated += (_, _) => { if (!dialogOpen) Hide(); };
        IsVisibleChanged += (_, _) =>
        {
            if (IsVisible) { Refresh(); preview.Play(c.HasMedia ? c.MediaFile : null); }
            else preview.Stop();
        };
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) Hide(); };
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            int round = DWMWCP_ROUND;
            DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));
        };
        Refresh();
    }

    /// Shows the panel next to the tray: above the taskbar's notification area, wherever the taskbar is.
    public void ShowNearTray()
    {
        Show();
        UpdateLayout();
        var screen = Forms.Screen.FromPoint(Forms.Cursor.Position);
        var work = screen.WorkingArea;
        var full = screen.Bounds;
        var dpi = VisualTreeHelper.GetDpi(this);
        double w = ActualWidth * dpi.DpiScaleX, h = ActualHeight * dpi.DpiScaleY, gap = 12 * dpi.DpiScaleX;
        double x = work.Right - w - gap, y = work.Bottom - h - gap;
        if (work.Top > full.Top) y = work.Top + gap;           // taskbar at the top
        else if (work.Left > full.Left) x = work.Left + gap;   // taskbar on the left
        Left = x / dpi.DpiScaleX;
        Top = y / dpi.DpiScaleY;
        Activate();
        SetForegroundWindow(new WindowInteropHelper(this).Handle);
    }

    void Controller_Changed(object? sender, PropertyChangedEventArgs e) => Dispatcher.BeginInvoke(Refresh);

    void Refresh()
    {
        bool idle = c.IsIdle;
        EnabledSwitch.IsChecked = c.Enabled;
        EnabledSwitch.IsEnabled = idle && c.HasMedia;
        StatusText.Text = c.Enabled ? "Включены" : "Выключены · стандартные обои";

        EmptyHint.Visibility = c.HasMedia ? Visibility.Collapsed : Visibility.Visible;
        PreviewClip.Opacity = c.Enabled ? 1 : 0.45;
        if (IsVisible && c.MediaVersion != shownVersion)
        {
            shownVersion = c.MediaVersion;
            preview.Play(c.HasMedia ? c.MediaFile : null);
        }

        BusyPanel.Visibility = idle ? Visibility.Collapsed : Visibility.Visible;
        BusyText.Text = c.Busy ?? "";

        var items = c.ArchiveItems;
        ArchivePanel.Visibility = items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ArchiveList.ItemsSource = items.Select(p => new
        {
            Path = p,
            Label = WallpaperController.ArchiveLabel(p),
            Icon = Media.IsVideo(p) ? "" : "",
        }).ToList();
        SourceText.Text = c.SourceName;
        SourceText.Visibility = items.Count == 0 && c.SourceName != "" ? Visibility.Visible : Visibility.Collapsed;

        DesktopSwitch.IsChecked = c.DesktopEnabled;
        LockSwitch.IsChecked = c.LockEnabled;
        LoginSwitch.IsChecked = c.LaunchAtLogin;
        SettingsPanel.IsEnabled = idle;
        SettingsPanel.Opacity = c.Enabled ? 1 : 0.6;

        WarningText.Text = c.Warning ?? "";
        WarningText.Visibility = c.Warning != null && c.Error == null ? Visibility.Visible : Visibility.Collapsed;
        ErrorText.Text = c.Error ?? "";
        ErrorText.Visibility = c.Error != null ? Visibility.Visible : Visibility.Collapsed;
        ChooseButton.IsEnabled = idle;
    }

    // MARK: actions

    void EnabledSwitch_Click(object sender, RoutedEventArgs e) => c.Enabled = EnabledSwitch.IsChecked == true;
    void DesktopSwitch_Click(object sender, RoutedEventArgs e) => c.DesktopEnabled = DesktopSwitch.IsChecked == true;
    void LockSwitch_Click(object sender, RoutedEventArgs e) => c.LockEnabled = LockSwitch.IsChecked == true;
    void LoginSwitch_Click(object sender, RoutedEventArgs e) => c.LaunchAtLogin = LoginSwitch.IsChecked == true;
    void Quit_Click(object sender, RoutedEventArgs e) => ((App)Application.Current).Quit();
    void Choose_Click(object sender, RoutedEventArgs e) => OpenDialog();
    void CancelArchive_Click(object sender, RoutedEventArgs e) => c.CancelArchive();
    void ArchiveItem_Click(object sender, RoutedEventArgs e) => c.ChooseFromArchive((string)((Button)sender).Tag);

    void Preview_Click(object sender, MouseButtonEventArgs e)
    {
        if (c.IsIdle) OpenDialog();
    }

    void OpenDialog()
    {
        var dialog = new OpenFileDialog { Filter = Media.DialogFilter, Title = "Выберите видео или анимацию" };
        dialogOpen = true;
        try
        {
            if (dialog.ShowDialog(this) == true) c.Choose(dialog.FileName);
        }
        finally
        {
            dialogOpen = false;
            Activate();
        }
    }

    void Preview_DragEnter(object sender, DragEventArgs e)
    {
        bool ok = c.IsIdle && e.Data.GetDataPresent(DataFormats.FileDrop);
        e.Effects = ok ? DragDropEffects.Copy : DragDropEffects.None;
        DropBorder.Visibility = ok ? Visibility.Visible : Visibility.Collapsed;
        e.Handled = true;
    }

    void Preview_DragLeave(object sender, DragEventArgs e) => DropBorder.Visibility = Visibility.Collapsed;

    void Preview_Drop(object sender, DragEventArgs e)
    {
        DropBorder.Visibility = Visibility.Collapsed;
        if (c.IsIdle && e.Data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files) c.Choose(files[0]);
    }

    // MARK: theme

    /// Follows the Windows light/dark app setting and the accent color.
    void ApplyTheme()
    {
        bool dark = false;
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            dark = key?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { }
        Color accent = Color.FromRgb(0x00, 0x67, 0xC0);
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\DWM");
            if (key?.GetValue("AccentColor") is int abgr)
                accent = Color.FromRgb((byte)abgr, (byte)(abgr >> 8), (byte)(abgr >> 16));
        }
        catch { }

        SolidColorBrush B(uint rgb, byte a = 255) => new(Color.FromArgb(a, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
        Resources["Bg"] = dark ? B(0x2C2C2C) : B(0xF9F9F9);
        Resources["Fg"] = dark ? B(0xFFFFFF) : B(0x1A1A1A);
        Resources["Secondary"] = dark ? B(0xFFFFFF, 0xA0) : B(0x000000, 0x90);
        Resources["Tertiary"] = dark ? B(0xFFFFFF, 0x60) : B(0x000000, 0x60);
        Resources["Well"] = dark ? B(0xFFFFFF, 0x10) : B(0x000000, 0x0C);
        Resources["Hover"] = dark ? B(0xFFFFFF, 0x14) : B(0x000000, 0x0A);
        Resources["Border"] = dark ? B(0xFFFFFF, 0x18) : B(0x000000, 0x18);
        Resources["Accent"] = new SolidColorBrush(accent);

        if (new WindowInteropHelper(this).Handle is var hwnd && hwnd != IntPtr.Zero)
        {
            int on = dark ? 1 : 0;
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref on, sizeof(int));
        }
    }
}
