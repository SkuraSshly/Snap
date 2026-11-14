using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Buffers.Binary;
using System.IO.Pipes;
using Velos.Core.Settings;
using Velos.Windows;
using Velos.Windows.Translation;

namespace Velos.Translation;

internal static class OcrWorker
{
    private const int Magic = 0x564f4353;
    private readonly static SemaphoreSlim gate = new(1, 1);
    private static Connection? worker;
    private static ChildProcessJob? job;
    private static int stopping;
    private static Task? warmUp;
    public static void WarmUp(TranslationPreferences preferences)
    {
        if (warmUp is { IsCompleted: false } || Volatile.Read(ref stopping) != 0) return;
        warmUp = RunWarmUp();
        async Task RunWarmUp()
        {
            try {
                var visual = new System.Windows.Media.DrawingVisual();
                using (var drawing = visual.RenderOpen()) {
                    drawing.DrawRectangle(System.Windows.Media.Brushes.White, null, new System.Windows.Rect(0, 0, 240, 80));
                    drawing.DrawText(new System.Windows.Media.FormattedText("Velos 截屏", System.Globalization.CultureInfo.CurrentCulture, System.Windows.FlowDirection.LeftToRight,
                        new System.Windows.Media.Typeface(UI.WarmTheme.Text, System.Windows.FontStyles.Normal, System.Windows.FontWeights.Normal, System.Windows.FontStretches.Normal), 30, System.Windows.Media.Brushes.Black, 1), new System.Windows.Point(16, 20));
                }
                var image = new System.Windows.Media.Imaging.RenderTargetBitmap(240, 80, 96, 96, System.Windows.Media.PixelFormats.Pbgra32); image.Render(visual);
                var pixels = new byte[240 * 80 * 4]; image.CopyPixels(pixels, 240 * 4, 0);
                await Recognize(pixels, 240, 80, preferences with { SmartLayout = false, PreferredRecognitionLanguage = null }, CancellationToken.None, bestCandidates: false);
            }
            catch (Exception) { /* 按键后按需预热；失败留给真实识别显示，空闲时不轮询。 */ }
        }
    }

    public static async Task Run(string pipeName)
    {
        if (!pipeName.StartsWith("Velos.OCR.", StringComparison.Ordinal) || pipeName.Length > 160) throw new InvalidOperationException("识别通道无效。");
        using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        using (var connect = new CancellationTokenSource(TimeSpan.FromSeconds(10))) await pipe.ConnectAsync(connect.Token);
        while (true)
        {
            var header = new byte[28];
            using (var idle = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
            {
                try { await pipe.ReadExactlyAsync(header, idle.Token); }
                catch (OperationCanceledException) when (idle.IsCancellationRequested) { return; }
                catch (EndOfStreamException) { return; }
            }
            await Respond(pipe, header);
        }
    }
    private static async Task Respond(Stream pipe, byte[] header)
    {
        if (ReadInt(header, 0) != Magic) throw new InvalidOperationException("识别协议无效。");
        var width = ReadInt(header, 4); var height = ReadInt(header, 8); var languageLength = ReadInt(header, 12); var smart = ReadInt(header, 16);
        var pixelScale = BitConverter.Int64BitsToDouble(BinaryPrimitives.ReadInt64LittleEndian(header.AsSpan(20)));
        Validate(width, height);
        if (languageLength < 0 || languageLength > 256 || smart is < 0 or > 3 || !double.IsFinite(pixelScale) || pixelScale is <= 0 or > 16) throw new InvalidOperationException("识别参数无效。");
        using var operation = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        var language = new byte[languageLength]; await pipe.ReadExactlyAsync(language, operation.Token);
        var bytes = new byte[checked(width * height * 4)]; await pipe.ReadExactlyAsync(bytes, operation.Token);
        RecognitionResult result;
        try { result = await OfflineOcr.Recognize(bytes, width, height, languageLength == 0 ? null : Encoding.UTF8.GetString(language), (smart & 1) != 0, operation.Token, pixelScale, (smart & 2) == 0); }
        catch (Exception error) { result = new RecognitionResult("", null, error is InvalidOperationException ? error.Message : $"文字识别失败。（0x{error.HResult:X8}）"); }
        var json = JsonSerializer.SerializeToUtf8Bytes(result);
        if (json.Length > 8 * 1024 * 1024) throw new InvalidOperationException("识别结果过大。");
        var length = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(length, json.Length);
        await pipe.WriteAsync(length, operation.Token); await pipe.WriteAsync(json, operation.Token); await pipe.FlushAsync(operation.Token);
    }
    public static async Task<RecognitionResult> Recognize(byte[] bgra, int width, int height, TranslationPreferences preferences, CancellationToken token, double pixelScale = 1, bool bestCandidates = true)
    {
        Validate(width, height);
        if (bgra.Length != checked(width * height * 4)) throw new InvalidOperationException("识别图片传输不完整。");
        var language = Encoding.UTF8.GetBytes(preferences.PreferredRecognitionLanguage ?? "");
        if (language.Length > 256) throw new InvalidOperationException("识别语言无效。");
        await gate.WaitAsync(token);
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(90));
            for (var attempt = 0; ; attempt++)
            {
                token.ThrowIfCancellationRequested();
                var active = await Connect(timeout.Token);
                using var cancel = timeout.Token.Register(active.Dispose);
                try
                {
                    var header = new byte[28];
                    BinaryPrimitives.WriteInt32LittleEndian(header, Magic); BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(4), width);
                    BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(8), height); BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(12), language.Length);
                    BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(16), (preferences.SmartLayout ? 1 : 0) | (bestCandidates ? 0 : 2));
                    BinaryPrimitives.WriteInt64LittleEndian(header.AsSpan(20), BitConverter.DoubleToInt64Bits(pixelScale));
                    await active.Pipe.WriteAsync(header, timeout.Token); await active.Pipe.WriteAsync(language, timeout.Token); await active.Pipe.WriteAsync(bgra, timeout.Token);
                    await active.Pipe.FlushAsync(timeout.Token);
                    var prefix = new byte[4]; await active.Pipe.ReadExactlyAsync(prefix, timeout.Token);
                    var length = ReadInt(prefix, 0); if (length < 1 || length > 8 * 1024 * 1024) throw new InvalidOperationException("识别进程返回无效结果。");
                    var bytes = new byte[length]; await active.Pipe.ReadExactlyAsync(bytes, timeout.Token);
                    var result = JsonSerializer.Deserialize<RecognitionResult>(bytes) ?? throw new InvalidOperationException("识别进程没有返回结果。");
                    if (result.Error is not null) throw new InvalidOperationException(result.Error);
                    return result;
                }
                catch (Exception error) when (error is IOException or ObjectDisposedException)
                {
                    active.Dispose(); if (ReferenceEquals(worker, active)) worker = null;
                    timeout.Token.ThrowIfCancellationRequested();
                    if (attempt != 0) throw new InvalidOperationException("离线识别进程已中断，请重试。", error);
                }
            }
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested && Volatile.Read(ref stopping) == 0) { throw new InvalidOperationException("离线文字识别超时，请缩小选区重试。"); }
        finally { gate.Release(); }
    }
    private static async Task<Connection> Connect(CancellationToken token)
    {
        if (Volatile.Read(ref stopping) != 0) throw new OperationCanceledException("Velos 正在退出。");
        if (worker is { IsAlive: true } existing) return existing;
        worker?.Dispose(); worker = null;
        job ??= new ChildProcessJob();
        var name = "Velos.OCR." + Environment.ProcessId + "." + Guid.NewGuid().ToString("N");
        var pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token); deadline.CancelAfter(TimeSpan.FromSeconds(10));
        Connection? connection = null;
        try
        {
            var info = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden };
            info.ArgumentList.Add("--ocr-worker"); info.ArgumentList.Add(name);
            var process = Process.Start(info) ?? throw new InvalidOperationException("无法启动离线识别进程。");
            connection = new Connection(process, pipe); worker = connection;
            if (Volatile.Read(ref stopping) != 0) throw new OperationCanceledException("Velos 正在退出。");
            job.Add(process);
            using var cancel = deadline.Token.Register(connection.Dispose);
            await pipe.WaitForConnectionAsync(deadline.Token);
            return connection;
        }
        catch
        {
            connection?.Dispose(); pipe.Dispose(); if (ReferenceEquals(worker, connection)) worker = null;
            token.ThrowIfCancellationRequested();
            if (deadline.IsCancellationRequested) throw new InvalidOperationException("连接离线识别进程超时，请重试。");
            throw;
        }
    }
    public static void Stop()
    {
        Interlocked.Exchange(ref stopping, 1); Interlocked.Exchange(ref worker, null)?.Dispose();
        Interlocked.Exchange(ref job, null)?.Dispose();
    }
    private static int ReadInt(byte[] data, int offset) => BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(offset, 4));
    private static void Validate(int width, int height)
    { if (width < 1 || height < 1 || width > 10000 || height > 10000 || (long)width * height > 40_000_000) throw new InvalidOperationException("识别图片尺寸无效。"); }
    private sealed class Connection(Process process, NamedPipeServerStream pipe) : IDisposable
    {
        private int disposed;
        public NamedPipeServerStream Pipe => pipe;
        public bool IsAlive { get { try { return Volatile.Read(ref disposed) == 0 && !process.HasExited && pipe.IsConnected; } catch (InvalidOperationException) { return false; } } }
        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            pipe.Dispose();
            try { if (!process.HasExited) process.Kill(); } catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
            process.Dispose();
        }
    }
}
