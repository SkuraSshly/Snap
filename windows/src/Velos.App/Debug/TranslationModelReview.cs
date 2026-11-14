#if DEBUG
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using Velos.Core.Settings;
using Velos.Core.Translation;
using Velos.Translation;

namespace Velos;

public partial class App
{
    private async Task ReviewTranslationModel(List<string> results)
    {
        var preferences = new TranslationPreferences { EnabledEngines = EngineId.DeepL | EngineId.OpenAI, DefaultEngine = EngineId.DeepL, AutoCopy = true };
        var calls = new List<string>(); var copies = new List<string>(); var partial = false; var slow = false;
        var service = new TranslationService(() => preferences, (_, field) => field switch { "baseURL" => "https://example.invalid/v1", "model" => "synthetic", _ => "synthetic-key" }) {
            DebugHandler = () => new ModelTranslationHandler(async (request, token) => {
                var body = await request.Content!.ReadAsStringAsync(token); calls.Add(request.RequestUri!.Host);
                await Task.Delay(slow ? 600 : 30, token);
                if (request.RequestUri.Host.Contains("deepl")) return new HttpResponseMessage(HttpStatusCode.TooManyRequests) { Content = new StringContent("{}") };
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new ModelSseStream(body.Contains("second") ? "第二次" : "第一段", "完成")) };
            }) };
        using var model = new TranslationModel(() => preferences, service, copies.Add);
        model.Changed += () => { if (model.IsPartial) partial = true; };
        model.DebugShow("first source", "旧结果"); await model.Translate();
        Check(model.Status == TranslationModel.Phase.Done && model.Engine == EngineId.OpenAI && model.EngineNotice?.Contains("DeepL") == true && calls.Count == 2,
            "M01", "首选失败后回退已启用引擎，并显示失败与切换原因");
        Check(partial && model.Translation == "第一段完成" && copies.SequenceEqual(new[] { "第一段完成" }), "M02", "流式片段实时显示，仅完整成功结果自动复制一次");
        preferences = preferences with { EnabledEngines = EngineId.OpenAI, DefaultEngine = EngineId.OpenAI }; slow = true;
        var old = model.Translate(); await Task.Delay(40); model.Edit("second source");
        Check(model.Translation == "第一段完成", "M03", "原文修改后保留旧结果等待新请求");
        slow = false; await model.Translate(); await old;
        Check(model.Translation == "第二次完成" && copies.Count == 2, "M04", "新请求取消旧请求，迟到的旧结果不能覆盖或复制");
        slow = true; var pending = model.Translate(); await Task.Delay(40); model.Edit(""); await pending;
        Check(model.Translation.Length == 0 && model.Status == TranslationModel.Phase.Idle && copies.Count == 2, "M05", "清空原文立即清除结果并取消在途翻译，禁止迟到复制");
        model.DebugShow("final source", "原结果"); pending = model.Translate(); await Task.Delay(40); model.Dispose(); await pending;
        Check(copies.Count == 2, "M06", "关闭模型取消网络及自动复制");
        void Check(bool condition, string id, string description) { if (!condition) throw new InvalidOperationException($"[{id}] {description}"); results.Add($"通过  [{id}] {description}"); }
    }
    private sealed class ModelTranslationHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
    { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => send(request, token); }
    private sealed class ModelSseStream(string first, string second) : Stream
    {
        private readonly byte[][] chunks = [Encoding.UTF8.GetBytes("data: {\"choices\":[{\"delta\":{\"content\":\"" + first + "\"}}]}\n\n"),
            Encoding.UTF8.GetBytes("data: {\"choices\":[{\"delta\":{\"content\":\"" + second + "\"}}]}\n\ndata: [DONE]\n\n")];
        private int index, offset;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int start, int count) => ReadAsync(buffer.AsMemory(start, count)).AsTask().GetAwaiter().GetResult();
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default)
        {
            if (index == chunks.Length) return 0;
            if (index > 0 && offset == 0) await Task.Delay(150, token);
            var count = Math.Min(buffer.Length, chunks[index].Length - offset); chunks[index].AsMemory(offset, count).CopyTo(buffer); offset += count;
            if (offset == chunks[index].Length) { index++; offset = 0; } return count;
        }
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
#endif
