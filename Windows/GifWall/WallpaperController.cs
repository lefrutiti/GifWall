using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using Screen = System.Windows.Forms.Screen;

namespace GifWall;

sealed class WallpaperController : INotifyPropertyChanged
{
    public static readonly WallpaperController Shared = new();

    readonly Settings s = Settings.Load();
    readonly DesktopWallpaper desktop = new();

    public event PropertyChangedEventHandler? PropertyChanged;

    WallpaperController()
    {
        ArchiveExtractor.Cleanup();
        Directory.CreateDirectory(AppPaths.Data);
    }

    /// System changes are undone on every quit, so they are re-applied on every launch.
    /// A crash skips the restore; whatever it left behind is fixed here as well.
    public async Task Start()
    {
        if (HasMedia && s.Enabled)
        {
            ApplyDesktop();
            await ApplyLock();
        }
        else
        {
            await LockScreenWallpaper.RestoreOriginal();
        }
    }

    /// Undo everything GifWall changed in the system (on quit). Settings and the chosen file are kept.
    public async Task RestoreSystem()
    {
        desktop.Hide();
        await LockScreenWallpaper.RestoreOriginal().ConfigureAwait(false);
    }

    // MARK: state

    public bool Enabled
    {
        get => s.Enabled;
        set
        {
            if (value == s.Enabled) return;
            s.Enabled = value;
            Save();
            _ = ApplyEnabled();
        }
    }

    public bool DesktopEnabled
    {
        get => s.DesktopEnabled;
        set
        {
            if (value == s.DesktopEnabled) return;
            s.DesktopEnabled = value;
            Save();
            ApplyDesktop();
        }
    }

    public bool LockEnabled
    {
        get => s.LockEnabled;
        set
        {
            if (value == s.LockEnabled) return;
            s.LockEnabled = value;
            Save();
            _ = ApplyLock();
        }
    }

    public bool LaunchAtLogin
    {
        get => Installer.LaunchAtLogin;
        set
        {
            try { Installer.LaunchAtLogin = value; } catch (Exception e) { Error = e.Message; }
            Changed();
        }
    }

    public string SourceName => s.SourceName;
    public string MediaFile => s.MediaFile;
    public bool HasMedia => s.MediaFile != "" && File.Exists(s.MediaFile);

    /// Bumped whenever the file is replaced, so the preview player reloads.
    public int MediaVersion { get; private set; }

    string? busy;
    public string? Busy { get => busy; private set { busy = value; Changed(); Changed(nameof(IsIdle)); } }
    public bool IsIdle => busy == null;

    string? error;
    public string? Error { get => error; set { error = value; Changed(); } }

    string? warning;
    public string? Warning { get => warning; private set { warning = value; Changed(); } }

    /// Files found in a dropped archive or folder, waiting for the user to pick one.
    public List<string> ArchiveItems { get; private set; } = new();
    string archiveName = "";

    // MARK: choosing a file

    public void Choose(string path)
    {
        CancelArchive();
        if (Directory.Exists(path) || ArchiveExtractor.IsArchive(path))
        {
            _ = OpenArchive(path);
            return;
        }
        if (!Media.IsSupported(path))
        {
            Error = "Формат не поддерживается";
            return;
        }
        _ = Load(path);
    }

    public void ChooseFromArchive(string path)
    {
        var name = $"{archiveName} › {Path.GetFileName(path)}";
        ArchiveItems = new();
        Changed(nameof(ArchiveItems));
        _ = LoadFromArchive(path, name);
    }

    async Task LoadFromArchive(string path, string name)
    {
        await Load(path, name);
        ArchiveExtractor.Cleanup();
    }

    public void CancelArchive()
    {
        if (ArchiveItems.Count == 0) return;
        ArchiveItems = new();
        Changed(nameof(ArchiveItems));
        ArchiveExtractor.Cleanup();
    }

    /// Path relative to the archive root, for the picker list.
    public static string ArchiveLabel(string path) => Path.GetRelativePath(ArchiveExtractor.Root, path);

    async Task OpenArchive(string path)
    {
        Error = null;
        Busy = "Распаковка…";
        try
        {
            var files = await ArchiveExtractor.Open(path);
            Busy = null;
            archiveName = Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
            if (files.Count == 1)
            {
                ChooseFromArchive(files[0]);
            }
            else
            {
                ArchiveItems = files;
                Changed(nameof(ArchiveItems));
            }
        }
        catch (Exception e)
        {
            Busy = null;
            Error = e.Message;
        }
    }

    /// Copies the file into our folder (so it keeps working if the original is moved) and makes sure mpv can decode it.
    async Task Load(string path, string? displayName = null)
    {
        Error = null;
        Warning = null;
        Busy = "Подготовка…";
        var incoming = Path.Combine(AppPaths.Data, "incoming" + Path.GetExtension(path).ToLowerInvariant());
        var frame = Path.Combine(AppPaths.Data, "incoming-frame.png");
        try
        {
            await Task.Run(() => File.Copy(path, incoming, true));
            if (!await Mpv.WriteFirstFrame(incoming, frame)) throw new InvalidOperationException("Формат не поддерживается или файл повреждён");

            // Unique name: the old file may still be open in the players until they switch to the new one.
            var media = Path.Combine(AppPaths.Data, $"current-{DateTime.Now.Ticks}{Path.GetExtension(path).ToLowerInvariant()}");
            File.Move(incoming, media);
            File.Move(frame, AppPaths.Still, true);
            s.MediaFile = media;
            s.SourceName = displayName ?? Path.GetFileName(path);
            // Picking a new file means the user wants it shown.
            s.Enabled = true;
            Save();

            var (w, h) = Media.PngSize(AppPaths.Still);
            var screen = Screen.AllScreens.Select(x => x.Bounds).OrderByDescending(b => b.Width * b.Height).First();
            var upscale = Math.Max((double)screen.Width / w, (double)screen.Height / h);
            if (upscale > 2) Warning = $"Исходник {w}×{h} растянут в {Math.Round(upscale)}× — будет размыто";

            MediaVersion++;
            Changed(nameof(MediaVersion));
            Busy = null;
            ApplyDesktop();
            await ApplyLock();
            DeleteOldMedia(except: media);
        }
        catch (Exception e)
        {
            try { File.Delete(incoming); } catch { }
            try { File.Delete(frame); } catch { }
            Error = e is IOException or UnauthorizedAccessException ? "Не удалось прочитать файл: " + e.Message : e.Message;
        }
        finally
        {
            Busy = null;
        }
    }

    void DeleteOldMedia(string except)
    {
        foreach (var f in Directory.GetFiles(AppPaths.Data, "current-*"))
            if (!string.Equals(f, except, StringComparison.OrdinalIgnoreCase))
                try { File.Delete(f); } catch { }
    }

    // MARK: applying

    async Task ApplyEnabled()
    {
        Error = null;
        ApplyDesktop();
        if (s.Enabled) await ApplyLock();
        else await LockScreenWallpaper.RestoreOriginal();
    }

    void ApplyDesktop()
    {
        if (s.Enabled && s.DesktopEnabled && HasMedia) desktop.Show(s.MediaFile); else desktop.Hide();
        if (desktop.Error != null) Error = desktop.Error;
    }

    async Task ApplyLock()
    {
        if (!HasMedia || !s.Enabled) return;
        try
        {
            if (s.LockEnabled && File.Exists(AppPaths.Still))
                await LockScreenWallpaper.SetStatic(AppPaths.Still);
            else
                await LockScreenWallpaper.RestoreOriginal();
        }
        catch (Exception e)
        {
            Error = "Не удалось сменить экран блокировки: " + e.Message;
        }
    }

    // MARK: system events

    public void DisplaysChanged() { if (s.Enabled && s.DesktopEnabled && HasMedia) desktop.Rebuild(); }
    public void SessionLocked(bool locked) => desktop.SetLocked(locked);
    public void DisplayPower(bool off) => desktop.SetDisplayOff(off);

    void Save()
    {
        s.Save();
        Changed(null);
    }

    void Changed([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
