using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace Velos.Downloader
{
    internal static class DownloaderTests
    {
        private static int passed;
        private static string root;
        private static int Main(string[] args)
        {
            root = Path.GetFullPath(args.Length > 0 ? args[0] : Path.Combine(Path.GetTempPath(), "VelosDownloaderTests", Guid.NewGuid().ToString("N")));
            Directory.CreateDirectory(root);
            try { Run().GetAwaiter().GetResult(); Console.WriteLine("通过 " + passed + "/" + passed); return 0; }
            catch (Exception error) { Console.WriteLine("失败 " + error); return 1; }
        }
        private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); passed++; Console.WriteLine("通过 " + message); }
        private static ReleaseAsset Asset(byte[] bytes)
        {
            using (var hash = SHA256.Create()) return new ReleaseAsset { name = "Velos-" + BuildInfo.Version + "-win-x64.zip", url = BuildInfo.DownloadRoot + "Velos-" + BuildInfo.Version + "-win-x64.zip", size = bytes.Length, sha256 = DownloadClient.Hex(hash.ComputeHash(bytes)) };
        }
        private static HttpResponseMessage Bytes(byte[] bytes) { return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) }; }
        private static string Json(byte[] bytes)
        {
            var x64 = Asset(bytes); var x86 = Asset(bytes); x86.name = x86.name.Replace("x64", "x86"); x86.url = x86.url.Replace("x64", "x86");
            return new JavaScriptSerializer().Serialize(new ReleaseManifest { schema = 1, version = BuildInfo.Version, tag = BuildInfo.Tag, releaseUrl = BuildInfo.ReleaseUrl, minimumWindowsBuild = 19041, assets = new Dictionary<string, ReleaseAsset> { { "x64", x64 }, { "x86", x86 } } });
        }
        private static async Task Run()
        {
            Check(DownloadClient.Architecture(9) == "x64" && DownloadClient.Architecture(0) == "x86", "按系统架构识别，32 位下载器在 64 位系统仍选 x64");
            try { DownloadClient.Architecture(12); throw new Exception("未拒绝 ARM"); } catch (NotSupportedException) { Check(true, "不误下载 ARM 架构"); }
            var bytes = Encoding.UTF8.GetBytes("synthetic release data"); var json = Json(bytes);
            Check(ReleaseManifest.Parse(json).Asset("x86").name.EndsWith("win-x86.zip"), "发布清单解析与架构选择");
            foreach (var broken in new[] { json.Replace("SkuraSshly/Velos", "other/repository"), json.Replace(BuildInfo.Version, "0.0.0"), json.Replace(Asset(bytes).sha256, "not-a-hash") })
            {
                try { ReleaseManifest.Parse(broken); throw new Exception("未拒绝清单"); } catch (InvalidDataException) { Check(true, "拒绝仓库、版本或校验值不匹配"); }
            }
            using (var client = new DownloadClient(new Handler(delegate { return Task.FromResult(Bytes(Encoding.UTF8.GetBytes(json))); })))
                Check((await client.LoadAsync(CancellationToken.None)).version == BuildInfo.Version, "通过网络接口读取受限清单");
            var destination = Path.Combine(root, "success.zip"); if (File.Exists(destination)) throw new IOException("测试目录必须为空");
            using (var client = new DownloadClient(new Handler(delegate { return Task.FromResult(Bytes(bytes)); })))
                await client.SaveAsync(Asset(bytes), destination, false, null, CancellationToken.None);
            Check(Convert.ToBase64String(File.ReadAllBytes(destination)) == Convert.ToBase64String(bytes), "流式下载及 SHA-256 通过后才提交文件");
            var original = Path.Combine(root, "existing.zip"); File.WriteAllText(original, "original");
            using (var client = new DownloadClient(new Handler(delegate { return Task.FromResult(Bytes(Encoding.UTF8.GetBytes("corrupted release data"))); })))
            {
                try { await client.SaveAsync(Asset(bytes), original, true, null, CancellationToken.None); throw new Exception("未拒绝损坏文件"); }
                catch (InvalidDataException) { Check(File.ReadAllText(original) == "original", "校验失败不覆盖已有文件"); }
            }
            var invalidHash = Asset(bytes); invalidHash.sha256 = new string('0', 64);
            using (var client = new DownloadClient(new Handler(delegate { return Task.FromResult(Bytes(bytes)); })))
            {
                try { await client.SaveAsync(invalidHash, original, true, null, CancellationToken.None); throw new Exception("未验证哈希"); }
                catch (InvalidDataException) { Check(File.ReadAllText(original) == "original", "大小相同但内容校验错误仍拒绝"); }
            }
            using (var client = new DownloadClient(new Handler(delegate { return Task.FromResult(Bytes(bytes)); })))
                await client.SaveAsync(Asset(bytes), original, true, null, CancellationToken.None);
            Check(File.ReadAllText(original) == Encoding.UTF8.GetString(bytes), "用户确认覆盖后原子替换");
            var race = Path.Combine(root, "race.zip");
            using (var client = new DownloadClient(new Handler(delegate { File.WriteAllText(race, "another file"); return Task.FromResult(Bytes(bytes)); })))
            {
                try { await client.SaveAsync(Asset(bytes), race, false, null, CancellationToken.None); throw new Exception("误覆盖并发文件"); }
                catch (IOException) { Check(File.ReadAllText(race) == "another file", "下载期间出现同名文件也不会静默覆盖"); }
            }
            using (var cts = new CancellationTokenSource())
            using (var client = new DownloadClient(new Handler(delegate { return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new SlowStream()) }); })))
            {
                cts.CancelAfter(50); var slow = Asset(new byte[200]);
                try { await client.SaveAsync(slow, Path.Combine(root, "cancel.zip"), false, null, cts.Token); throw new Exception("未取消"); }
                catch (OperationCanceledException) { Check(!File.Exists(Path.Combine(root, "cancel.zip")), "下载取消不留下半成品"); }
            }
            using (var client = new DownloadClient(new Handler(delegate { var response = new HttpResponseMessage(HttpStatusCode.Redirect); response.Headers.Location = new Uri("http://example.invalid/file"); return Task.FromResult(response); })))
            {
                try { await client.SaveAsync(Asset(bytes), Path.Combine(root, "redirect.zip"), false, null, CancellationToken.None); throw new Exception("允许不安全重定向"); }
                catch (InvalidDataException) { Check(true, "拒绝 HTTPS 降级重定向"); }
            }
            Check(Directory.GetFiles(root, "*.tmp").Length == 0, "完成、失败、取消后均清理自己的临时文件");
        }
        private sealed class Handler : HttpMessageHandler
        {
            private readonly Func<Task<HttpResponseMessage>> response;
            internal Handler(Func<Task<HttpResponseMessage>> response) { this.response = response; }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) { return response(); }
        }
        private sealed class SlowStream : Stream
        {
            public override bool CanRead { get { return true; } } public override bool CanSeek { get { return false; } } public override bool CanWrite { get { return false; } }
            public override long Length { get { throw new NotSupportedException(); } } public override long Position { get { return 0; } set { throw new NotSupportedException(); } }
            public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token) { await Task.Delay(15, token); buffer[offset] = 0; return 1; }
            public override int Read(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
            public override void Flush() { } public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); } public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
        }
    }
}
