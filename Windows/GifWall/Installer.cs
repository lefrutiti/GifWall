using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using Microsoft.Win32;

namespace GifWall;

/// Per-user install without admin rights: %LOCALAPPDATA%\Programs\GifWall, a Start menu shortcut
/// and an entry in Settings › Apps, whose "Uninstall" removes everything and leaves the system as before GifWall.
static class Installer
{
    public static readonly string Dir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "GifWall");
    public static string Exe => Path.Combine(Dir, "GifWall.exe");

    const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\GifWall";
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    static string Shortcut => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "GifWall.lnk");

    public static string CurrentExe => Environment.ProcessPath!;
    public static bool IsInstalledCopy => string.Equals(Path.GetFullPath(CurrentExe), Path.GetFullPath(Exe), StringComparison.OrdinalIgnoreCase);

    /// Copies the running exe (and libmpv next to it) into the install dir, replacing an older version, and registers it.
    public static void Install()
    {
        SingleInstance.QuitRunning();
        Directory.CreateDirectory(Dir);
        var from = Path.GetDirectoryName(CurrentExe)!;
        foreach (var name in new[] { "GifWall.exe", "libmpv-2.dll" })
        {
            var src = Path.Combine(from, name);
            if (File.Exists(src)) CopyWithRetry(src, Path.Combine(Dir, name));
        }

        using (var key = Registry.CurrentUser.CreateSubKey(UninstallKey))
        {
            key.SetValue("DisplayName", "GifWall");
            key.SetValue("DisplayIcon", Exe + ",0");
            key.SetValue("DisplayVersion", "1.0");
            key.SetValue("Publisher", "GifWall");
            key.SetValue("InstallLocation", Dir);
            key.SetValue("UninstallString", $"\"{Exe}\" --uninstall");
            key.SetValue("QuietUninstallString", $"\"{Exe}\" --uninstall");
            key.SetValue("NoModify", 1, RegistryValueKind.DWord);
            key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            key.SetValue("EstimatedSize", (int)(DirSize(Dir) / 1024), RegistryValueKind.DWord);
        }
        CreateShortcut();
        // A login item from an older copy must point to the new location.
        if (LaunchAtLogin) LaunchAtLogin = true;
    }

    /// Restores the lock screen, removes data, settings, login item and shortcut. The program folder goes in RemoveProgramOnExit.
    public static void Uninstall()
    {
        SingleInstance.QuitRunning();   // quitting restores the lock screen already
        try { LockScreenWallpaper.RestoreOriginal().Wait(TimeSpan.FromSeconds(10)); } catch { }
        LaunchAtLogin = false;
        try { File.Delete(Shortcut); } catch { }
        try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); } catch { }
        try { Directory.Delete(AppPaths.Data, true); } catch { }
    }

    public static void RemoveProgramOnExit()
    {
        // A running exe can't delete itself: a detached shell removes the folder once this process has exited.
        Process.Start(new ProcessStartInfo("cmd.exe",
            $"/c ping 127.0.0.1 -n 3 > nul & rmdir /s /q \"{Dir}\"")
        {
            CreateNoWindow = true,
            UseShellExecute = false,
            WorkingDirectory = Path.GetTempPath(),
        });
    }

    public static bool LaunchAtLogin
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue("GifWall") != null;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue("GifWall", $"\"{Exe}\" --background");
            else key.DeleteValue("GifWall", false);
        }
    }

    static void CopyWithRetry(string src, string dst)
    {
        for (int i = 0; ; i++)
        {
            try { File.Copy(src, dst, true); return; }
            catch (IOException) when (i < 20) { Thread.Sleep(250); }
        }
    }

    static long DirSize(string dir)
    {
        long total = 0;
        foreach (var f in Directory.GetFiles(dir)) total += new FileInfo(f).Length;
        return total;
    }

    static void CreateShortcut()
    {
        try
        {
            var shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType == null) return;
            dynamic shell = Activator.CreateInstance(shellType)!;
            dynamic link = shell.CreateShortcut(Shortcut);
            link.TargetPath = Exe;
            link.WorkingDirectory = Dir;
            link.IconLocation = Exe + ",0";
            link.Description = "Живые обои";
            link.Save();
        }
        catch { }
    }
}

/// One GifWall per user session. Launching it again opens the panel of the running one.
static class SingleInstance
{
    const string MutexName = @"Local\GifWall.Instance";
    const string ShowName = @"Local\GifWall.Show";
    const string QuitName = @"Local\GifWall.Quit";

    static Mutex? mutex;

    /// True if this process is the only GifWall. The handles stay open for the life of the process.
    public static bool Acquire()
    {
        mutex = new Mutex(true, MutexName, out bool created);
        if (created) return true;
        // An instance that's quitting still holds the mutex for a moment.
        try { created = mutex.WaitOne(TimeSpan.FromMilliseconds(500)); } catch (AbandonedMutexException) { created = true; }
        return created;
    }

    public static void SignalShow()
    {
        try { using var e = EventWaitHandle.OpenExisting(ShowName); e.Set(); } catch { }
    }

    /// Asks a running GifWall to quit (it restores the system first) and waits until it's gone.
    public static void QuitRunning()
    {
        try { using var e = EventWaitHandle.OpenExisting(QuitName); e.Set(); } catch { return; }
        using var m = new Mutex(false, MutexName);
        try { if (m.WaitOne(TimeSpan.FromSeconds(10))) m.ReleaseMutex(); } catch (AbandonedMutexException) { }
    }

    /// Calls `show` / `quit` on a background thread whenever another process signals.
    public static void Listen(Action show, Action quit)
    {
        var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowName);
        var quitEvent = new EventWaitHandle(false, EventResetMode.AutoReset, QuitName);
        new Thread(() =>
        {
            var handles = new WaitHandle[] { showEvent, quitEvent };
            while (true)
            {
                if (WaitHandle.WaitAny(handles) == 0) show(); else { quit(); return; }
            }
        }) { IsBackground = true }.Start();
    }

    public static void Release()
    {
        try { mutex?.ReleaseMutex(); } catch { }
    }
}
