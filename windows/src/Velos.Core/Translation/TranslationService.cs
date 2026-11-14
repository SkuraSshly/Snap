using System.Net.Http;
using System.Text;
using Velos.Core.Settings;

namespace Velos.Core.Translation;

public sealed class TranslationService(Func<TranslationPreferences> read, Func<EngineId, string, string> credential, Func<EngineId, string, bool>? contains = null)
{
#if DEBUG
    public Func<HttpMessageHandler>? DebugHandler { get; init; }
#endif
    private bool IsConfigured(EngineDefinition engine) => engine.Fields.Where(field => !field.Optional)
        .All(field => contains?.Invoke(engine.Id, field.Id) ?? !string.IsNullOrWhiteSpace(credential(engine.Id, field.Id)));
    public IReadOnlyList<EngineDefinition> Available => EngineDefinition.All.Where(e => read().EnabledEngines.HasFlag(e.Id) && IsConfigured(e)).ToArray();
    public async Task<string> Translate(EngineId engine, string text, TranslateLanguage? source, TranslateLanguage target, IProgress<string>? partial, CancellationToken token)
    {
        var definition = EngineDefinition.Get(engine);
        if (!read().EnabledEngines.HasFlag(engine)) throw new InvalidOperationException("此引擎未启用，不会联网。");
        if (!IsConfigured(definition)) throw new InvalidOperationException("没有填写完整的 Key 或服务配置。");
        var credentials = definition.Fields.ToDictionary(f => f.Id, f => credential(engine, f.Id));
        using var request = EngineRequests.Create(engine, text, source, target, field => credentials.GetValueOrDefault(field, ""), read().LlmPrompt, DateTimeOffset.UtcNow, Guid.NewGuid().ToString());
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(definition.IsLlm ? 120 : 10));
        using var handler =
#if DEBUG
            DebugHandler?.Invoke() ??
#endif
            new HttpClientHandler { UseCookies = false, AllowAutoRedirect = false, UseDefaultCredentials = false };
        using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan, MaxResponseContentBufferSize = 8 * 1024 * 1024 };
        try
        {
            HttpResponseMessage response;
            using (var headers = CancellationTokenSource.CreateLinkedTokenSource(timeout.Token))
            {
                headers.CancelAfter(TimeSpan.FromSeconds(10));
                response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, headers.Token);
            }
            using var responseLifetime = response;
            if (!response.IsSuccessStatusCode)
            {
                var bytes = new byte[4096]; using var error = await response.Content.ReadAsStreamAsync(timeout.Token);
                var length = await error.ReadAsync(bytes, timeout.Token);
                throw new InvalidOperationException(EngineResponses.HttpError((int)response.StatusCode, Encoding.UTF8.GetString(bytes, 0, length)));
            }
            if (!definition.IsLlm)
            {
                using var input = await response.Content.ReadAsStreamAsync(timeout.Token);
                using var buffer = new MemoryStream(); var bytes = new byte[8192]; int length;
                while ((length = await input.ReadAsync(bytes, timeout.Token)) > 0) { if (buffer.Length + length > 8 * 1024 * 1024) throw new InvalidOperationException("服务响应过大。"); await buffer.WriteAsync(bytes.AsMemory(0, length), timeout.Token); }
                return EngineResponses.Parse(engine, Encoding.UTF8.GetString(buffer.GetBuffer(), 0, (int)buffer.Length));
            }
            using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
            using var idle = new IdleReadStream(stream); using var reader = new StreamReader(idle);
            var output = new StringBuilder(); string? eventName = null;
            while (true)
            {
                var line = await reader.ReadLineAsync(timeout.Token);
                if (line is null) break;
                if (line.Length > 1024 * 1024) throw new InvalidOperationException("服务响应过大。");
                if (line.StartsWith("event:", StringComparison.Ordinal)) { eventName = line[6..].Trim(); continue; }
                if (!line.StartsWith("data:", StringComparison.Ordinal)) continue;
                var piece = EngineResponses.StreamPiece(engine, line[5..].Trim(), eventName);
                if (piece.Piece.Length > 0) { output.Append(piece.Piece); if (output.Length > 2_000_000) throw new InvalidOperationException("译文过长。"); partial?.Report(output.ToString()); }
                if (piece.End) break;
            }
            if (output.Length == 0) throw new InvalidOperationException("服务没有返回译文。");
            return output.ToString().Trim();
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { throw new InvalidOperationException("网络超时，请稍后再试。"); }
        catch (TimeoutException) { throw new InvalidOperationException("网络超时（10 秒未收到数据）。"); }
        catch (HttpRequestException) { throw new InvalidOperationException("网络连接失败，请检查网络或代理设置。"); }
        finally { credentials.Clear(); }
    }
}
