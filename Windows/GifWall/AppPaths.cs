using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace GifWall;

static class AppPaths
{
    public static readonly string Data = Create(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GifWall"));
    /// First frame of the current file: the lock screen picture.
    public static string Still => Path.Combine(Data, "still.png");
    public static string SettingsFile => Path.Combine(Data, "settings.json");

    static string Create(string path)
    {
        Directory.CreateDirectory(path);
        return path;
    }
}

sealed class Settings
{
    /// Master switch. Off: the wallpaper window goes away and the original lock screen comes back;
    /// the chosen file and the other settings are kept for when it's turned on again.
    public bool Enabled { get; set; } = true;
    public bool DesktopEnabled { get; set; } = true;
    /// Lock screen shows the first frame (Windows can't animate it).
    public bool LockEnabled { get; set; } = true;
    /// Name shown under the preview (original file name, or "archive › file").
    public string SourceName { get; set; } = "";
    /// Our copy of the chosen file inside AppPaths.Data.
    public string MediaFile { get; set; } = "";

    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, Converters = { new JsonStringEnumConverter() } };

    public static Settings Load()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(AppPaths.SettingsFile), Json) ?? new(); }
        catch { return new(); }
    }

    public void Save()
    {
        try { File.WriteAllText(AppPaths.SettingsFile, JsonSerializer.Serialize(this, Json)); } catch { }
    }
}

static class Media
{
    static readonly string[] Videos = [".mp4", ".m4v", ".mov", ".mkv", ".webm", ".avi", ".wmv"];
    static readonly string[] Images = [".gif", ".webp", ".png", ".apng"];

    public const string DialogFilter =
        "Видео, анимации и архивы|*.mp4;*.m4v;*.mov;*.mkv;*.webm;*.avi;*.wmv;*.gif;*.webp;*.png;*.apng;*.zip|Все файлы|*.*";

    public static bool IsVideo(string path) => Videos.Contains(Path.GetExtension(path).ToLowerInvariant());
    public static bool IsSupported(string path) => IsVideo(path) || Images.Contains(Path.GetExtension(path).ToLowerInvariant());

    /// Width and height from a PNG header.
    public static (int W, int H) PngSize(string path)
    {
        var b = new byte[24];
        using (var f = File.OpenRead(path)) f.ReadExactly(b);
        int Be(int o) => b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3];
        return (Be(16), Be(20));
    }
}
