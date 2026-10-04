using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace GifWall;

/// Minimal libmpv client. mpv plays every format we accept (video, GIF, WebP, APNG) with hardware decoding,
/// so files are played as is instead of being converted first.
sealed class Mpv : IDisposable
{
    const string Lib = "libmpv-2.dll";
    [DllImport(Lib)] static extern IntPtr mpv_create();
    [DllImport(Lib)] static extern int mpv_initialize(IntPtr ctx);
    [DllImport(Lib)] static extern int mpv_set_option_string(IntPtr ctx, byte[] name, byte[] value);
    [DllImport(Lib)] static extern int mpv_set_property_string(IntPtr ctx, byte[] name, byte[] value);
    [DllImport(Lib)] static extern int mpv_command(IntPtr ctx, IntPtr[] args);
    [DllImport(Lib)] static extern IntPtr mpv_wait_event(IntPtr ctx, double timeout);
    [DllImport(Lib)] static extern void mpv_terminate_destroy(IntPtr ctx);
    [DllImport(Lib)] static extern int mpv_render_context_create(out IntPtr res, IntPtr ctx, RenderParam[] parameters);
    [DllImport(Lib)] static extern int mpv_render_context_render(IntPtr res, RenderParam[] parameters);
    [DllImport(Lib)] static extern void mpv_render_context_set_update_callback(IntPtr res, UpdateFn? callback, IntPtr cbCtx);
    [DllImport(Lib)] static extern ulong mpv_render_context_update(IntPtr res);
    [DllImport(Lib)] static extern void mpv_render_context_free(IntPtr res);

    [StructLayout(LayoutKind.Sequential)]
    struct RenderParam { public int Type; public IntPtr Data; }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate void UpdateFn(IntPtr cbCtx);

    const int RenderApiType = 1, RenderSwSize = 17, RenderSwFormat = 18, RenderSwStride = 19, RenderSwPointer = 20;

    [StructLayout(LayoutKind.Sequential)]
    struct MpvEvent { public int Id; public int Error; public ulong ReplyUserdata; public IntPtr Data; }

    [StructLayout(LayoutKind.Sequential)]
    struct EndFile { public int Reason; public int Error; }

    const int EventShutdown = 1, EventEndFile = 7, EventFileLoaded = 8;
    const int EndFileReasonError = 4;

    readonly IntPtr ctx;
    readonly Thread pump;
    readonly object gate = new();
    bool closed;
    IntPtr render;
    UpdateFn? updateFn;   // kept alive while mpv holds the pointer

    /// Raised on the event thread when the current file stops; true if it failed to play.
    public event Action<bool>? FileEnded;
    public event Action? FileLoaded;

    public Mpv(IDictionary<string, string> options)
    {
        ctx = mpv_create();
        if (ctx == IntPtr.Zero) throw new InvalidOperationException("libmpv");
        foreach (var (k, v) in options) mpv_set_option_string(ctx, U(k), U(v));
        if (mpv_initialize(ctx) < 0)
        {
            mpv_terminate_destroy(ctx);
            throw new InvalidOperationException("libmpv");
        }
        pump = new Thread(Pump) { IsBackground = true, Name = "mpv events" };
        pump.Start();
    }

    /// Options shared by the wallpaper and the preview: muted, looping, aspect-filled, no UI of its own.
    public static Dictionary<string, string> PlayerOptions(IntPtr window) => new()
    {
        ["wid"] = window.ToInt64().ToString(),
        ["hwdec"] = "auto-safe",
        ["loop-file"] = "inf",
        ["image-display-duration"] = "inf",
        ["mute"] = "yes",
        ["audio"] = "no",
        ["sub-auto"] = "no",
        ["panscan"] = "1.0",
        // A wallpaper is ambient motion: 30 fps looks the same as 60 and halves rendering and compositing work.
        // Frames are dropped before rendering (decoding still runs on the GPU decoder, which is cheap).
        ["vf"] = "fps=30:round=near",
        ["osd-level"] = "0",
        ["input-default-bindings"] = "no",
        ["input-vo-keyboard"] = "no",
        ["input-cursor"] = "no",
        ["cursor-autohide"] = "no",
        ["terminal"] = "no",
        ["config"] = "no",
    };

    public void Load(string path) => Command("loadfile", path);

    public void Set(string name, string value)
    {
        lock (gate) { if (!closed) mpv_set_property_string(ctx, U(name), U(value)); }
    }

    void Command(params string[] args)
    {
        lock (gate)
        {
            if (closed) return;
            var ptrs = new IntPtr[args.Length + 1];
            try
            {
                for (int i = 0; i < args.Length; i++) ptrs[i] = Marshal.StringToCoTaskMemUTF8(args[i]);
                mpv_command(ctx, ptrs);
            }
            finally
            {
                foreach (var p in ptrs) if (p != IntPtr.Zero) Marshal.FreeCoTaskMem(p);
            }
        }
    }

    void Pump()
    {
        while (true)
        {
            var e = Marshal.PtrToStructure<MpvEvent>(mpv_wait_event(ctx, -1));
            if (e.Id == EventShutdown) break;
            if (e.Id == EventFileLoaded) FileLoaded?.Invoke();
            if (e.Id == EventEndFile && e.Data != IntPtr.Zero)
                FileEnded?.Invoke(Marshal.PtrToStructure<EndFile>(e.Data).Reason == EndFileReasonError);
        }
        // Only the event thread destroys the handle: mpv_wait_event must never race with destruction.
        mpv_terminate_destroy(ctx);
    }

    /// Software rendering into caller memory (for the preview, which has no window of its own).
    /// `frameReady` is called on an mpv thread whenever a new frame should be rendered with RenderTo.
    public void EnableSoftwareRender(Action frameReady)
    {
        var api = Marshal.StringToCoTaskMemUTF8("sw");
        try
        {
            if (mpv_render_context_create(out render, ctx, [new() { Type = RenderApiType, Data = api }, new()]) < 0)
                throw new InvalidOperationException("libmpv render");
        }
        finally { Marshal.FreeCoTaskMem(api); }
        updateFn = _ => frameReady();
        mpv_render_context_set_update_callback(render, updateFn, IntPtr.Zero);
    }

    static readonly IntPtr Bgr0 = Marshal.StringToCoTaskMemUTF8("bgr0");   // matches WPF Bgr32

    /// Renders the current frame into a BGRA buffer. Returns false if there is no new frame.
    public unsafe bool RenderTo(IntPtr buffer, int width, int height, int stride)
    {
        lock (gate)
        {
            if (closed || render == IntPtr.Zero) return false;
            if ((mpv_render_context_update(render) & 1) == 0) return false;
            int* size = stackalloc int[2] { width, height };
            nuint strideValue = (nuint)stride;
            mpv_render_context_render(render,
            [
                new() { Type = RenderSwSize, Data = (IntPtr)size },
                new() { Type = RenderSwFormat, Data = Bgr0 },
                new() { Type = RenderSwStride, Data = (IntPtr)(&strideValue) },
                new() { Type = RenderSwPointer, Data = buffer },
                new(),
            ]);
            return true;
        }
    }

    /// Stops playback and waits until mpv has released the window it draws into.
    public void Dispose()
    {
        lock (gate)
        {
            if (closed) return;
            // The render context must be freed before the core is destroyed.
            if (render != IntPtr.Zero)
            {
                mpv_render_context_set_update_callback(render, null, IntPtr.Zero);
                mpv_render_context_free(render);
                render = IntPtr.Zero;
            }
            Command("quit");
            closed = true;
        }
        pump.Join(3000);
    }

    static byte[] U(string s) => Encoding.UTF8.GetBytes(s + "\0");

    /// Decodes the first frame of any supported file into a PNG. Returns false if mpv can't decode the file.
    public static Task<bool> WriteFirstFrame(string src, string png) => Task.Run(() =>
    {
        var dir = Path.Combine(Path.GetDirectoryName(png)!, "frame");
        try { Directory.Delete(dir, true); } catch { }
        Directory.CreateDirectory(dir);
        using var done = new ManualResetEventSlim();
        using (var mpv = new Mpv(new Dictionary<string, string>
        {
            ["vo"] = "image",
            ["vo-image-format"] = "png",
            ["vo-image-outdir"] = dir,
            ["frames"] = "1",
            ["audio"] = "no",
            ["sub-auto"] = "no",
            ["hwdec"] = "no",
            ["terminal"] = "no",
            ["config"] = "no",
        }))
        {
            mpv.FileEnded += _ => done.Set();
            mpv.Load(src);
            done.Wait(TimeSpan.FromSeconds(30));
        }
        try
        {
            var frame = Directory.GetFiles(dir, "*.png");
            if (frame.Length == 0) return false;
            File.Move(frame[0], png, true);
            return true;
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { }
        }
    });
}
