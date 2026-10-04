using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace GifWall;

/// Muted looping preview inside the panel. mpv renders in software into a WriteableBitmap,
/// so the preview is ordinary WPF content: rounded, clickable, a drop target.
/// Plays only while the panel is on screen.
sealed class PreviewPlayer
{
    readonly Image image;
    readonly DispatcherTimer timer;
    Mpv? mpv;
    WriteableBitmap? bitmap;
    string? file;
    volatile bool frameReady;

    public PreviewPlayer(Image image)
    {
        this.image = image;
        // Preview size in pixels: the panel is small, so this stays cheap even in software.
        timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(1000.0 / 30) };
        timer.Tick += (_, _) => Draw();
        image.SizeChanged += (_, _) =>
            image.Clip = new RectangleGeometry(new Rect(image.RenderSize), 10, 10);
    }

    public void Play(string? path)
    {
        if (path != file) Stop();
        file = path;
        if (path == null || mpv != null) return;
        var source = PresentationSource.FromVisual(image);
        double scale = source?.CompositionTarget?.TransformToDevice.M11 ?? 1;
        int w = Math.Max(2, (int)(image.ActualWidth * scale)), h = Math.Max(2, (int)(image.ActualHeight * scale));
        if (image.ActualWidth == 0) { w = (int)(288 * scale); h = (int)(176 * scale); }
        bitmap = new WriteableBitmap(w, h, 96 * scale, 96 * scale, PixelFormats.Bgr32, null);
        image.Source = bitmap;
        try
        {
            var options = Mpv.PlayerOptions(IntPtr.Zero);
            options.Remove("wid");
            options["vo"] = "libmpv";
            options["hwdec"] = "auto-copy-safe";
            mpv = new Mpv(options);
            mpv.EnableSoftwareRender(() => frameReady = true);
            mpv.Load(path);
            timer.Start();
        }
        catch
        {
            mpv?.Dispose();
            mpv = null;
        }
    }

    public void Stop()
    {
        timer.Stop();
        mpv?.Dispose();
        mpv = null;
        image.Source = null;
        bitmap = null;
    }

    void Draw()
    {
        if (!frameReady || mpv == null || bitmap == null) return;
        frameReady = false;
        bitmap.Lock();
        try
        {
            if (mpv.RenderTo(bitmap.BackBuffer, bitmap.PixelWidth, bitmap.PixelHeight, bitmap.BackBufferStride))
                bitmap.AddDirtyRect(new Int32Rect(0, 0, bitmap.PixelWidth, bitmap.PixelHeight));
        }
        finally { bitmap.Unlock(); }
    }
}
