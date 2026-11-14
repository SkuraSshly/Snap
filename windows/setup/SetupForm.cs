using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: AssemblyTitle("Velos 安装程序")]
[assembly: AssemblyProduct("Velos Windows Setup")]
[assembly: AssemblyVersion("2.0.0.0")]
[assembly: AssemblyFileVersion(Velos.Setup.BuildInfo.FileVersion)]
[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8")]

namespace Velos.Setup
{
    internal static class Program
    {
        [STAThread] private static void Main(string[] args)
        {
            try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { }
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            System.Net.ServicePointManager.SecurityProtocol = System.Net.SecurityProtocolType.Tls12;
            if (args.Length == 2 && args[0] == "/remove")
            {
                try { UninstallCommand.Remove(args[1]); }
                catch (Exception error) { MessageBox.Show(error.Message, "Velos", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                return;
            }
            bool created;
            using (var guard = new Mutex(true, @"Local\Velos.Windows.Setup", out created))
            {
                if (!created) { MessageBox.Show("另一个 Velos 安装或卸载程序正在运行。", "Velos"); return; }
                try
                {
                    if (args.Length == 1 && args[0] == "/uninstall") UninstallCommand.Begin();
                    else if (args.Length == 0) Application.Run(new SetupForm());
                    else MessageBox.Show("不支持的安装参数。", "Velos");
                }
                catch (Exception error) { MessageBox.Show(error.Message, "Velos", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                finally { try { guard.ReleaseMutex(); } catch (ApplicationException) { } }
            }
        }
        [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr context);
        internal static bool AppRunning()
        {
            Mutex mutex;
            if (!Mutex.TryOpenExisting(@"Local\Velos.Windows", out mutex)) return false;
            mutex.Dispose(); return true;
        }
        internal static string License()
        {
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Velos.License"))
            using (var reader = new StreamReader(stream)) return reader.ReadToEnd();
        }
    }
    internal static class UninstallCommand
    {
        internal static void Begin()
        {
            if (!String.Equals(Path.GetFullPath(Application.ExecutablePath), Path.Combine(Installation.DefaultRoot, "Uninstall.exe"), StringComparison.OrdinalIgnoreCase))
                throw new IOException("请从 Windows 已安装的应用中卸载 Velos。");
            if (Program.AppRunning()) throw new IOException("请先从托盘退出 Velos，再卸载。");
            if (MessageBox.Show("卸载 Velos？\n截图、录屏、设置和翻译凭据会保留。", "卸载 Velos", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            var temporary = Path.Combine(Path.GetTempPath(), "Velos-Uninstall-" + Guid.NewGuid().ToString("N") + ".exe");
            File.Copy(Application.ExecutablePath, temporary);
            Process.Start(new ProcessStartInfo(temporary, "/remove " + Process.GetCurrentProcess().Id) { UseShellExecute = false });
        }
        internal static void Remove(string parentId)
        {
            int id;
            if (!Int32.TryParse(parentId, out id) || !Path.GetFileName(Application.ExecutablePath).StartsWith("Velos-Uninstall-", StringComparison.Ordinal) ||
                !String.Equals(Path.GetDirectoryName(Application.ExecutablePath).TrimEnd('\\'), Path.GetTempPath().TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                throw new IOException("卸载启动方式无效。");
            try { using (var parent = Process.GetProcessById(id)) if (!parent.WaitForExit(10000)) throw new IOException("卸载程序仍在关闭，请重试。"); } catch (ArgumentException) { }
            bool created;
            using (var guard = new Mutex(true, @"Local\Velos.Windows.Setup", out created))
            {
                if (!created) throw new IOException("另一个安装程序正在运行，请重试。");
                try
                {
                    if (Program.AppRunning()) throw new IOException("请先从托盘退出 Velos，再卸载。");
                    var root = Installation.DefaultRoot;
                    new Installation(root, new WindowsIntegration(root)).Uninstall();
                    MessageBox.Show("Velos 已卸载。\n截图、录屏、设置和翻译凭据已保留。", "Velos");
                }
                finally { guard.ReleaseMutex(); }
            }
        }
    }
    internal sealed class SetupForm : Form
    {
        private readonly DownloadClient client = new DownloadClient();
        private readonly Label status = new Label(), detail = new Label();
        private readonly WarmProgress progress = new WarmProgress();
        private readonly WarmButton action = new WarmButton(), cancel = new WarmButton();
        private CancellationTokenSource operation;
        private bool busy, closing, installed, committing;
        internal SetupForm()
        {
            SuspendLayout(); AutoScaleMode = AutoScaleMode.None;
            Text = "安装 Velos"; ClientSize = new Size(520, 344); FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false; StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(255, 246, 236); ForeColor = Color.FromArgb(84, 61, 46); Font = new Font("Microsoft YaHei UI", 10);
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Velos.Wordmark"))
            using (var source = new Bitmap(stream))
            {
                var picture = new PictureBox { Image = new Bitmap(source), SizeMode = PictureBoxSizeMode.Zoom };
                picture.SetBounds(158, 32, 204, 84); Controls.Add(picture);
            }
            var heading = new Label { Text = "正在安装 Velos", TextAlign = ContentAlignment.MiddleCenter, Font = new Font(Font.FontFamily, 16, FontStyle.Bold) };
            heading.SetBounds(28, 132, 464, 35); Controls.Add(heading);
            detail.Text = "准备中 · " + BuildInfo.Version; detail.ForeColor = Color.FromArgb(139, 113, 94); detail.TextAlign = ContentAlignment.MiddleCenter;
            detail.SetBounds(28, 171, 464, 23); Controls.Add(detail);
            status.Text = "正在获取适合此电脑的安装文件…"; status.TextAlign = ContentAlignment.MiddleCenter;
            status.SetBounds(28, 205, 464, 47); Controls.Add(status);
            progress.SetBounds(32, 259, 456, 7); Controls.Add(progress);
            action.Text = "重试"; action.Prominent = true; action.Visible = false; action.SetBounds(252, 284, 138, 38);
            action.Click += async delegate {
                if (installed)
                {
                    if (Program.AppRunning()) { status.Text = "请先从托盘退出旧版 Velos，再点启动。"; return; }
                    try { Process.Start(new ProcessStartInfo(Path.Combine(Installation.DefaultRoot, "Velos.exe")) { UseShellExecute = true }); Close(); }
                    catch (Exception error) { status.Text = "无法启动：" + error.Message; }
                }
                else await Install(heading);
            }; Controls.Add(action);
            cancel.Text = "取消"; cancel.SetBounds(402, 284, 86, 38);
            cancel.Click += delegate { if (busy && !committing) operation.Cancel(); else if (!busy) Close(); }; Controls.Add(cancel);
            Shown += async delegate { await Install(heading); };
            FormClosing += delegate(object sender, FormClosingEventArgs e) { if (busy) { closing = true; e.Cancel = true; if (!committing) operation.Cancel(); } };
            FormClosed += delegate { client.Dispose(); foreach (Control control in Controls) { var picture = control as PictureBox; if (picture != null && picture.Image != null) picture.Image.Dispose(); } if (Icon != null) Icon.Dispose(); };
            var scale = NativeSystem.WindowScale(Handle); if (scale != 1) Scale(new SizeF(scale, scale));
            ClientSize = new Size((int)Math.Round(520 * scale), (int)Math.Round(344 * scale));
            ResumeLayout(false); PerformLayout();
        }
        private async Task Install(Label heading)
        {
            if (busy) return;
            busy = true; committing = false; action.Visible = false; operation = new CancellationTokenSource(); progress.Fraction = 0;
            cancel.Enabled = true; cancel.Text = "取消"; heading.Text = "正在安装 Velos";
            try
            {
                var architecture = NativeSystem.Architecture(); detail.Text = BuildInfo.Version + " · " + architecture;
                status.Text = "正在连接 GitHub…";
                var manifest = await client.LoadAsync(operation.Token);
                var report = new Progress<DownloadProgress>(delegate(DownloadProgress value) {
                    if (!busy || closing || committing) return;
                    progress.Fraction = 0.95 * value.Received / value.Total;
                    status.Text = "正在下载… " + (100d * value.Received / value.Total).ToString("0") + "%  （" + (value.Received / 1048576d).ToString("0.0") + " / " + (value.Total / 1048576d).ToString("0.0") + " MB）";
                });
                var root = Installation.DefaultRoot;
                await new Installation(root, new WindowsIntegration(root)).InstallAsync(client, manifest.Asset(architecture), architecture, Application.ExecutablePath, Program.License(), report,
                    delegate {
                        if (Program.AppRunning()) throw new IOException("请先从托盘退出旧版 Velos，再点重试。");
                        committing = true; cancel.Enabled = false; status.Text = "正在完成安装…";
                    }, operation.Token);
                installed = true; heading.Text = "安装完成"; progress.Fraction = 1;
                status.Text = "已添加到开始菜单。\n现在即可启动 Velos。"; action.Text = "启动 Velos"; cancel.Text = "完成";
            }
            catch (OperationCanceledException) { heading.Text = "安装已取消"; status.Text = "原有安装保持不变，可点击重试。"; progress.Fraction = 0; }
            catch (Exception error) { heading.Text = "安装未完成"; status.Text = error.Message; progress.Fraction = 0; }
            finally
            {
                busy = false; committing = false; operation.Dispose(); operation = null;
                if (!installed) { action.Text = "重试"; cancel.Text = "关闭"; }
                action.Visible = true; cancel.Enabled = true;
                if (closing) Close();
            }
        }
    }
}
