using System;
using System.IO;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace Velos.Setup
{
    internal sealed class InstallRecord
    {
        public string product { get; set; }
        public string version { get; set; }
        public string architecture { get; set; }
        public string sha256 { get; set; }
    }
    internal interface IInstallationIntegration
    {
        object Capture();
        void Register(string root, string version, long bytes);
        void Restore(object previous);
        void Remove(string root);
    }
    internal sealed class Installation
    {
        internal const string Product = "Velos.Windows.UserInstall.v1";
        private readonly string root;
        private readonly IInstallationIntegration integration;
        private static readonly string[] Files = { "Velos.exe", "Uninstall.exe", "LICENSE.txt", "install.json" };
        internal Installation(string root, IInstallationIntegration integration)
        { this.root = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar); this.integration = integration; }
        internal static string DefaultRoot { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Velos"); } }
        internal string ApplicationPath { get { return Path.Combine(root, "Velos.exe"); } }
        internal static void Guard(string path)
        {
            var current = Path.GetFullPath(path);
            while (!String.IsNullOrEmpty(current))
            {
                if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("安装位置包含链接或重解析点，请检查安装目录。");
                current = Path.GetDirectoryName(current);
            }
        }
        private InstallRecord ReadRecord()
        {
            var path = Path.Combine(root, "install.json"); Guard(path);
            if (!File.Exists(path)) return null;
            if (new FileInfo(path).Length > 4096) throw new InvalidDataException("安装记录无效。");
            var record = new JavaScriptSerializer().Deserialize<InstallRecord>(File.ReadAllText(path));
            if (record == null || record.product != Product) throw new InvalidDataException("安装目录不属于此安装程序。");
            return record;
        }
        private void CheckExisting()
        {
            Guard(root);
            if (Directory.Exists(root) && Directory.GetFileSystemEntries(root).Length > 0 && ReadRecord() == null)
                throw new IOException("安装目录已存在其他文件，未覆盖。请检查 " + root);
            foreach (var file in Files) Guard(Path.Combine(root, file));
        }
        internal static void VerifyExecutable(string path, string architecture)
        {
            if (architecture != "x64" && architecture != "x86") throw new InvalidDataException("未知程序架构。");
            using (var stream = File.OpenRead(path))
            using (var reader = new BinaryReader(stream))
            {
                if (stream.Length < 88 || reader.ReadUInt16() != 0x5a4d) throw new InvalidDataException("下载的文件不是 Windows 程序。");
                stream.Position = 60; var offset = reader.ReadInt32();
                if (offset < 64 || offset > stream.Length - 24) throw new InvalidDataException("程序文件头损坏。");
                stream.Position = offset;
                if (reader.ReadUInt32() != 0x4550 || reader.ReadUInt16() != (architecture == "x64" ? 0x8664 : 0x14c))
                    throw new InvalidDataException("程序架构与此电脑不匹配。");
            }
        }
        internal async Task InstallAsync(DownloadClient client, ReleaseAsset asset, string architecture, string setupPath, string license,
            IProgress<DownloadProgress> progress, Action committing, CancellationToken token)
        {
            CheckExisting();
            var available = new DriveInfo(Path.GetPathRoot(root)).AvailableFreeSpace;
            if (available < asset.size * 2 + new FileInfo(setupPath).Length * 2 + 1048576) throw new IOException("磁盘可用空间不足。");
            var prior = integration.Capture();
            Directory.CreateDirectory(root); Guard(root);
            var stage = Path.Combine(root, ".setup-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(stage);
            var committed = new List<string>(); var integrated = false; var preserveRecovery = false;
            try
            {
                await client.SaveAsync(asset, Path.Combine(stage, "Velos.exe"), false, progress, token);
                VerifyExecutable(Path.Combine(stage, "Velos.exe"), architecture);
                File.Copy(setupPath, Path.Combine(stage, "Uninstall.exe"));
                File.WriteAllText(Path.Combine(stage, "LICENSE.txt"), license, new System.Text.UTF8Encoding(false));
                File.WriteAllText(Path.Combine(stage, "install.json"), new JavaScriptSerializer().Serialize(new InstallRecord {
                    product = Product, version = BuildInfo.Version, architecture = architecture, sha256 = asset.sha256
                }), new System.Text.UTF8Encoding(false));
                token.ThrowIfCancellationRequested(); CheckExistingStage(stage); if (committing != null) committing();
                foreach (var file in Files)
                {
                    var destination = Path.Combine(root, file); Guard(destination);
                    if (File.Exists(destination)) File.Replace(Path.Combine(stage, file), destination, Path.Combine(stage, file + ".old"));
                    else File.Move(Path.Combine(stage, file), destination);
                    committed.Add(file);
                }
                integrated = true; integration.Register(root, BuildInfo.Version, asset.size);
            }
            catch (Exception original)
            {
                var errors = new List<Exception> { original };
                if (integrated) try { integration.Restore(prior); } catch (Exception error) { errors.Add(error); }
                for (var index = committed.Count - 1; index >= 0; index--)
                {
                    var file = committed[index]; var old = Path.Combine(stage, file + ".old"); var destination = Path.Combine(root, file);
                    try { if (File.Exists(old)) File.Replace(old, destination, null); else File.Delete(destination); }
                    catch (Exception error) { errors.Add(error); }
                }
                if (errors.Count > 1) { preserveRecovery = true; throw new AggregateException("安装未完成，恢复文件已保留在 " + stage, errors); }
                throw;
            }
            finally
            {
                // Delete only files created by this transaction, never recursively delete an installation directory.
                if (!preserveRecovery) foreach (var file in Files)
                    foreach (var suffix in new[] { "", ".old" })
                    { var path = Path.Combine(stage, file + suffix); if (File.Exists(path)) File.Delete(path); }
                if (Directory.Exists(stage) && Directory.GetFileSystemEntries(stage).Length == 0) Directory.Delete(stage);
                if (Directory.Exists(root) && Directory.GetFileSystemEntries(root).Length == 0) Directory.Delete(root);
            }
        }
        private void CheckExistingStage(string stage)
        {
            Guard(root); foreach (var file in Files) Guard(Path.Combine(root, file));
            if (ReadRecord() == null)
                foreach (var entry in Directory.GetFileSystemEntries(root))
                    if (!String.Equals(entry, stage, StringComparison.OrdinalIgnoreCase)) throw new IOException("安装期间目录出现其他文件，未覆盖。");
        }
        internal void Uninstall()
        {
            Guard(root); if (ReadRecord() == null) throw new IOException("未找到有效的 Velos 安装记录。");
            foreach (var file in Files) Guard(Path.Combine(root, file));
            // Check locks before removing shortcuts or files, so a running app can be closed and retried.
            foreach (var file in Files) { var path = Path.Combine(root, file); if (File.Exists(path)) using (File.Open(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { } }
            foreach (var file in new[] { "Velos.exe", "Uninstall.exe", "LICENSE.txt" }) File.Delete(Path.Combine(root, file));
            integration.Remove(root); File.Delete(Path.Combine(root, "install.json"));
            if (Directory.GetFileSystemEntries(root).Length == 0) Directory.Delete(root);
        }
    }
}
