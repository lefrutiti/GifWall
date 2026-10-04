using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;

namespace GifWall;

/// Unpacks ZIP archives (or scans a dropped folder, e.g. a Wallpaper Engine workshop item) and finds wallpaper files inside.
static class ArchiveExtractor
{
    /// Guards against zip bombs: real wallpaper packs are far smaller.
    const long MaxUncompressedBytes = 4L << 30;

    static readonly string TempDir = Path.Combine(AppPaths.Data, "archive");

    /// Where the current list of files lives: the extraction dir or the dropped folder.
    public static string Root { get; private set; } = TempDir;

    public static bool IsArchive(string path) => Path.GetExtension(path).Equals(".zip", StringComparison.OrdinalIgnoreCase);

    /// Returns supported files: videos first, then larger files first.
    public static Task<List<string>> Open(string path) => Task.Run(() =>
    {
        Cleanup();
        if (Directory.Exists(path))
        {
            Root = Path.GetFullPath(path);
            return Find(Root);
        }

        Root = TempDir;
        try
        {
            using (var zip = ZipFile.OpenRead(path))
            {
                if (zip.Entries.Sum(e => e.Length) > MaxUncompressedBytes)
                    throw new ArchiveException("Архив слишком большой");
            }
            Directory.CreateDirectory(TempDir);
            // Rejects entries that would land outside the target ("../", absolute paths).
            ZipFile.ExtractToDirectory(path, TempDir, overwriteFiles: true);
            return Find(TempDir);
        }
        catch (ArchiveException) { Cleanup(); throw; }
        catch { Cleanup(); throw new ArchiveException("Не удалось распаковать архив"); }
    });

    static List<string> Find(string root)
    {
        var files = WallpaperEngineFiles(root) ?? MediaFiles(root);
        if (files.Count == 0) throw new ArchiveException("Здесь нет подходящих файлов");
        return files;
    }

    /// Removes the extraction dir. A dropped folder belongs to the user and is never touched.
    public static void Cleanup()
    {
        try { Directory.Delete(TempDir, true); } catch { }
    }

    /// Wallpaper Engine projects ship a `project.json`; its "file" is the real wallpaper and "preview" a tiny thumbnail.
    /// Returns null when this is not a WE project.
    static List<string>? WallpaperEngineFiles(string root)
    {
        var projects = AllFiles(root).Where(f => Path.GetFileName(f).Equals("project.json", StringComparison.OrdinalIgnoreCase)).ToList();
        if (projects.Count == 0) return null;
        var found = new List<string>();
        string? rejectedType = null;
        foreach (var project in projects)
        {
            try
            {
                using var json = JsonDocument.Parse(File.ReadAllText(project));
                var type = json.RootElement.TryGetProperty("type", out var t) ? t.GetString()?.ToLowerInvariant() ?? "" : "";
                if (type == "video" && json.RootElement.TryGetProperty("file", out var f) && f.GetString() is { } file)
                {
                    var path = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(project)!, file));
                    if (IsInside(path, root) && File.Exists(path) && Media.IsSupported(path)) found.Add(path);
                }
                else if (type != "")
                {
                    rejectedType = type;
                }
            }
            catch { }
        }
        if (found.Count == 0 && rejectedType != null)
            throw new ArchiveException($"Это обои Wallpaper Engine типа «{rejectedType}»: они рисуются движком WE и не являются видео. Подходят только обои типа «video».");
        return found.Count == 0 ? null : found;
    }

    static bool IsInside(string path, string root) =>
        path.StartsWith(Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);

    static IEnumerable<string> AllFiles(string root) =>
        Directory.EnumerateFiles(root, "*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true })
            .Where(f => !f.Contains($"{Path.DirectorySeparatorChar}__MACOSX{Path.DirectorySeparatorChar}"));

    static List<string> MediaFiles(string root) =>
        AllFiles(root)
            .Where(Media.IsSupported)
            // Catalog thumbnails ("preview.gif", "thumbnail.webp"…), never the actual wallpaper.
            .Where(f => !new[] { "preview", "thumbnail", "thumb" }.Contains(Path.GetFileNameWithoutExtension(f).ToLowerInvariant()))
            .Select(f => new FileInfo(f))
            // Skip links that point outside the folder.
            .Where(f => f.LinkTarget == null)
            .OrderByDescending(f => Media.IsVideo(f.FullName))
            .ThenByDescending(f => f.Length)
            .Select(f => f.FullName)
            .ToList();
}

sealed class ArchiveException(string message) : Exception(message);
