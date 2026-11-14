using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace Velos.Setup
{
    public sealed class ReleaseAsset
    {
        public string name { get; set; }
        public string url { get; set; }
        public string sha256 { get; set; }
        public long size { get; set; }
    }
    public sealed class ReleaseManifest
    {
        public int schema { get; set; }
        public string version { get; set; }
        public string tag { get; set; }
        public string releaseUrl { get; set; }
        public int minimumWindowsBuild { get; set; }
        public Dictionary<string, ReleaseAsset> assets { get; set; }

        public static ReleaseManifest Parse(string json)
        {
            if (json == null || Encoding.UTF8.GetByteCount(json) > 65536) throw new InvalidDataException("发布信息过大。");
            var manifest = new JavaScriptSerializer { MaxJsonLength = 65536 }.Deserialize<ReleaseManifest>(json);
            if (manifest == null || manifest.schema != 2 || manifest.version != BuildInfo.Version || manifest.tag != BuildInfo.Tag ||
                manifest.releaseUrl != BuildInfo.ReleaseUrl || manifest.minimumWindowsBuild != 19041 || manifest.assets == null)
                throw new InvalidDataException("发布信息与此下载器不匹配，请从发布页重新下载。");
            foreach (var architecture in new[] { "x64", "x86" })
            {
                ReleaseAsset asset;
                var name = "Velos-" + BuildInfo.Version + "-win-" + architecture + ".exe";
                if (!manifest.assets.TryGetValue(architecture, out asset) || asset == null || asset.name != name ||
                    asset.url != BuildInfo.DownloadRoot + name || asset.size <= 0 || asset.size > 536870912 ||
                    asset.sha256 == null || !Regex.IsMatch(asset.sha256, "\\A[0-9a-fA-F]{64}\\z"))
                    throw new InvalidDataException("发布文件信息不完整或校验值无效。");
            }
            return manifest;
        }
        public ReleaseAsset Asset(string architecture)
        {
            if (architecture != "x64" && architecture != "x86") throw new NotSupportedException("只提供 x64 和 x86 版本。");
            return assets[architecture];
        }
    }
    public sealed class DownloadProgress
    {
        public long Received { get; private set; }
        public long Total { get; private set; }
        public DownloadProgress(long received, long total) { Received = received; Total = total; }
    }
    public sealed class DownloadClient : IDisposable
    {
        private readonly HttpClient client;
        public DownloadClient() : this(new HttpClientHandler { AllowAutoRedirect = false }) { }
        internal DownloadClient(HttpMessageHandler handler)
        {
            client = new HttpClient(handler) { Timeout = TimeSpan.FromMinutes(20) };
            client.DefaultRequestHeaders.UserAgent.ParseAdd("Velos-Setup/2.0");
        }
        internal static string Architecture(ushort nativeArchitecture)
        {
            if (nativeArchitecture == 9) return "x64";
            if (nativeArchitecture == 0) return "x86";
            throw new NotSupportedException("当前只提供 x64／x86 Windows 版本。");
        }
        private async Task<HttpResponseMessage> GetAsync(Uri uri, CancellationToken token)
        {
            for (var redirects = 0; redirects < 9; redirects++)
            {
                if (uri.Scheme != "https" || uri.Port != 443 || !String.IsNullOrEmpty(uri.UserInfo))
                    throw new InvalidDataException("下载链接必须使用 HTTPS。");
                var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
                var code = (int)response.StatusCode;
                if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308)
                {
                    var location = response.Headers.Location; response.Dispose();
                    if (location == null) throw new InvalidDataException("下载重定向缺少地址。");
                    uri = location.IsAbsoluteUri ? location : new Uri(uri, location); continue;
                }
                if (!response.IsSuccessStatusCode)
                {
                    response.Dispose();
                    if (code == 404) throw new IOException("暂时无法获取安装文件，请稍后重试。");
                    throw new IOException("GitHub 暂时无法下载（HTTP " + code + "），请稍后重试。");
                }
                return response;
            }
            throw new IOException("下载重定向次数过多。");
        }
        public async Task<ReleaseManifest> LoadAsync(CancellationToken token)
        {
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(token))
            {
                timeout.CancelAfter(TimeSpan.FromSeconds(30));
                using (var response = await GetAsync(new Uri(BuildInfo.DownloadRoot + "Velos-Install.json"), timeout.Token).ConfigureAwait(false))
                using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                using (var buffer = new MemoryStream())
                using (timeout.Token.Register(response.Dispose))
                {
                    var bytes = new byte[4096]; int count;
                    while ((count = await input.ReadAsync(bytes, 0, bytes.Length, timeout.Token).ConfigureAwait(false)) > 0)
                    {
                        if (buffer.Length + count > 65536) throw new InvalidDataException("发布信息过大。");
                        buffer.Write(bytes, 0, count);
                    }
                    timeout.Token.ThrowIfCancellationRequested();
                    return ReleaseManifest.Parse(Encoding.UTF8.GetString(buffer.ToArray()));
                }
            }
        }
        public async Task SaveAsync(ReleaseAsset asset, string destination, bool overwriteApproved, IProgress<DownloadProgress> progress, CancellationToken token)
        {
            destination = Path.GetFullPath(destination);
            var temporary = destination + ".velos-" + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                token.ThrowIfCancellationRequested();
                using (var response = await GetAsync(new Uri(asset.url), token).ConfigureAwait(false))
                using (token.Register(response.Dispose))
                {
                    if (response.Content.Headers.ContentLength.HasValue && response.Content.Headers.ContentLength.Value != asset.size)
                        throw new InvalidDataException("服务器返回的文件大小不一致，请重试。");
                    using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                    using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, true))
                    using (var hash = SHA256.Create())
                    {
                        var buffer = new byte[81920]; var received = 0L; int count;
                        var report = System.Diagnostics.Stopwatch.StartNew();
                        if (progress != null) progress.Report(new DownloadProgress(0, asset.size));
                        while ((count = await input.ReadAsync(buffer, 0, buffer.Length, token).ConfigureAwait(false)) > 0)
                        {
                            received += count;
                            if (received > asset.size) throw new InvalidDataException("下载的数据超过发布文件大小。");
                            hash.TransformBlock(buffer, 0, count, buffer, 0);
                            await output.WriteAsync(buffer, 0, count, token).ConfigureAwait(false);
                            if (progress != null && report.ElapsedMilliseconds >= 80) { progress.Report(new DownloadProgress(received, asset.size)); report.Restart(); }
                        }
                        hash.TransformFinalBlock(new byte[0], 0, 0);
                        token.ThrowIfCancellationRequested();
                        if (received != asset.size || !String.Equals(Hex(hash.Hash), asset.sha256, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidDataException("文件完整性校验失败，已丢弃此次下载，请重试。");
                        if (progress != null) progress.Report(new DownloadProgress(received, asset.size));
                    }
                }
                token.ThrowIfCancellationRequested();
                if (overwriteApproved && File.Exists(destination)) File.Replace(temporary, destination, null);
                else File.Move(temporary, destination);
            }
            catch (Exception) { if (token.IsCancellationRequested) throw new OperationCanceledException(token); throw; }
            finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
        }
        internal static string Hex(byte[] bytes) { return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant(); }
        public void Dispose() { client.Dispose(); }
    }
}
