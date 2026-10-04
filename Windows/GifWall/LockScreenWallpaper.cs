using System;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.Win32;
using Windows.Storage;
using Windows.System.UserProfile;

namespace GifWall;

/// Lock screen: Windows can't animate it, so it shows the first frame of the wallpaper.
/// The user's own lock screen picture (and the Spotlight setting) is saved before the first change
/// and put back when GifWall is turned off, quits or is uninstalled.
/// Everything here avoids the UI thread, so it can be waited on while the session ends.
static class LockScreenWallpaper
{
    sealed record Backup(string? Image, int? Rotating, int? RotatingOverlay);

    const string SpotlightKey = @"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";
    static string BackupFile => Path.Combine(AppPaths.Data, "lockscreen-backup.json");

    public static bool HasBackup => File.Exists(BackupFile);

    public static async Task SetStatic(string png)
    {
        await BackupOnce().ConfigureAwait(false);
        var file = await StorageFile.GetFileFromPathAsync(png).AsTask().ConfigureAwait(false);
        await LockScreen.SetImageFileAsync(file).AsTask().ConfigureAwait(false);
    }

    /// Puts back the lock screen the user had before GifWall first changed it, and forgets the backup.
    public static async Task RestoreOriginal()
    {
        if (!HasBackup) return;
        Backup? b = null;
        try { b = JsonSerializer.Deserialize<Backup>(File.ReadAllText(BackupFile)); } catch { }
        if (b?.Image is { } image && File.Exists(image))
        {
            try
            {
                var file = await StorageFile.GetFileFromPathAsync(image).AsTask().ConfigureAwait(false);
                await LockScreen.SetImageFileAsync(file).AsTask().ConfigureAwait(false);
            }
            catch { }
        }
        // Setting a picture switches the lock screen from Spotlight to "Picture"; switch it back.
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(SpotlightKey);
            if (b?.Rotating is { } r) key.SetValue("RotatingLockScreenEnabled", r, RegistryValueKind.DWord);
            if (b?.RotatingOverlay is { } o) key.SetValue("RotatingLockScreenOverlayEnabled", o, RegistryValueKind.DWord);
        }
        catch { }
        try { File.Delete(BackupFile); } catch { }
        if (b?.Image != null) try { File.Delete(b.Image); } catch { }
    }

    /// Saves the current lock screen once, before GifWall first changes it; later changes keep the original.
    static async Task BackupOnce()
    {
        if (HasBackup) return;
        string? image = null;
        try
        {
            var stream = LockScreen.GetImageStream();
            if (stream != null)
            {
                using var src = stream.AsStreamForRead();
                using var buffer = new MemoryStream();
                await src.CopyToAsync(buffer).ConfigureAwait(false);
                var bytes = buffer.ToArray();
                // The stream has no type; the lock screen API accepts JPEG, PNG and BMP.
                var ext = bytes is [0x89, (byte)'P', ..] ? ".png" : bytes is [(byte)'B', (byte)'M', ..] ? ".bmp" : ".jpg";
                image = Path.Combine(AppPaths.Data, "lockscreen-original" + ext);
                await File.WriteAllBytesAsync(image, bytes).ConfigureAwait(false);
            }
        }
        catch { image = null; }

        int? rotating = null, overlay = null;
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(SpotlightKey);
            rotating = key?.GetValue("RotatingLockScreenEnabled") as int?;
            overlay = key?.GetValue("RotatingLockScreenOverlayEnabled") as int?;
        }
        catch { }
        File.WriteAllText(BackupFile, JsonSerializer.Serialize(new Backup(image, rotating, overlay)));
    }
}
