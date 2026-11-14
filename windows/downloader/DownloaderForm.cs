using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: AssemblyTitle("Velos Windows 下载器")]
[assembly: AssemblyProduct("Velos Windows 下载器")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8")]

namespace Velos.Downloader
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { }
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            System.Net.ServicePointManager.SecurityProtocol = System.Net.SecurityProtocolType.Tls12;
            Application.Run(new DownloaderForm());
        }
        [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    }
    internal static class NativeSystem
    {
        [StructLayout(LayoutKind.Sequential)] private struct SystemInfo
        {
            internal ushort Architecture, Reserved; internal uint PageSize;
            internal IntPtr MinAddress, MaxAddress; internal UIntPtr ProcessorMask;
            internal uint Processors, ProcessorType, Allocation;
            internal ushort Level, Revision;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct OsInfo
        {
            internal uint Size, Major, Minor, Build, Platform;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string ServicePack;
        }
        [DllImport("kernel32.dll")] private static extern void GetNativeSystemInfo(out SystemInfo value);
        [DllImport("ntdll.dll", CharSet = CharSet.Unicode)] private static extern int RtlGetVersion(ref OsInfo value);
        [DllImport("shell32.dll")] private static extern int SHGetKnownFolderPath(ref Guid id, uint flags, IntPtr token, out IntPtr path);
        internal static string Architecture()
        {
            var os = new OsInfo { Size = (uint)Marshal.SizeOf(typeof(OsInfo)) };
            if (RtlGetVersion(ref os) != 0 || os.Major < 10 || os.Build < 19041) throw new NotSupportedException("需要 Windows 10 2004 或更新版本。");
            SystemInfo info; GetNativeSystemInfo(out info); return DownloadClient.Architecture(info.Architecture);
        }
        internal static string Downloads()
        {
            var id = new Guid("374DE290-123F-4565-9164-39C4925E467B"); IntPtr path;
            if (SHGetKnownFolderPath(ref id, 0, IntPtr.Zero, out path) != 0) return Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
            try { return Marshal.PtrToStringUni(path); } finally { Marshal.FreeCoTaskMem(path); }
        }
    }
    internal sealed class DownloaderForm : Form
    {
        private readonly DownloadClient client = new DownloadClient();
        private readonly ComboBox architecture = new ComboBox();
        private readonly Label status = new Label();
        private readonly WarmButton download = new WarmButton();
        private readonly WarmButton cancel = new WarmButton();
        private readonly WarmButton open = new WarmButton();
        private readonly WarmProgress progress = new WarmProgress();
        private ReleaseManifest manifest;
        private CancellationTokenSource operation;
        private string recommended, savedPath;
        private bool busy, closing;
        internal DownloaderForm()
        {
            Text = "Velos Windows 下载器"; ClientSize = new Size(540, 370); MinimumSize = Size;
            FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false; StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(255, 246, 236); ForeColor = Color.FromArgb(84, 61, 46);
            Font = new Font("Microsoft YaHei UI", 10); AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = AutoScaleMode.Dpi;
            var icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); if (icon != null) Icon = icon;
            var heading = new Label { Text = "Velos for Windows", Font = new Font(Font.FontFamily, 22, FontStyle.Bold), AutoSize = true, Location = new Point(28, 24) };
            Controls.Add(heading);
            Controls.Add(new Label { Text = "自动推荐适合此电脑的版本", AutoSize = true, Location = new Point(31, 77), ForeColor = Color.FromArgb(139, 113, 94) });
            Controls.Add(new Label { Text = "版本  " + BuildInfo.Version, AutoSize = true, Location = new Point(31, 112) });
            architecture.SetBounds(31, 148, 478, 34); architecture.DropDownStyle = ComboBoxStyle.DropDownList;
            architecture.FlatStyle = FlatStyle.Flat; architecture.BackColor = Color.FromArgb(255, 252, 247); architecture.ItemHeight = 28;
            architecture.DrawMode = DrawMode.OwnerDrawFixed;
            architecture.DrawItem += delegate(object sender, DrawItemEventArgs e) {
                if (e.Index < 0) return;
                using (var brush = new SolidBrush((e.State & DrawItemState.Selected) != 0 ? Color.FromArgb(255, 222, 196) : architecture.BackColor)) e.Graphics.FillRectangle(brush, e.Bounds);
                TextRenderer.DrawText(e.Graphics, architecture.Items[e.Index].ToString(), Font, e.Bounds, ForeColor, TextFormatFlags.VerticalCenter | TextFormatFlags.Left);
            };
            architecture.SelectedIndexChanged += delegate { if (!busy && manifest != null) ShowReady(); }; Controls.Add(architecture);
            status.SetBounds(31, 196, 478, 46); status.Text = "正在读取发布信息…"; status.AutoEllipsis = true; Controls.Add(status);
            progress.SetBounds(31, 248, 478, 7); Controls.Add(progress);
            download.Text = "准备中…"; download.SetBounds(31, 274, 228, 42); download.Prominent = true; download.Enabled = false;
            download.Click += async delegate { if (manifest == null) await LoadRelease(); else await Download(); }; Controls.Add(download);
            cancel.Text = "取消"; cancel.SetBounds(270, 274, 82, 42); cancel.Enabled = false;
            cancel.Click += delegate { if (operation != null) operation.Cancel(); }; Controls.Add(cancel);
            open.Text = "打开文件夹"; open.SetBounds(364, 274, 145, 42); open.Enabled = false;
            open.Click += delegate { try { Process.Start(new ProcessStartInfo("explorer.exe", "/select,\"" + savedPath + "\"") { UseShellExecute = true }); } catch (Exception error) { status.Text = "无法打开文件夹：" + error.Message; } }; Controls.Add(open);
            Controls.Add(new Label { Text = "GitHub 下载 · SHA-256 完整性校验", AutoSize = true, Location = new Point(31, 337), Font = new Font(Font.FontFamily, 9), ForeColor = Color.FromArgb(139, 113, 94) });
            var manual = new LinkLabel { Text = "手动下载", AutoSize = true, Location = new Point(444, 337), Font = new Font(Font.FontFamily, 9), LinkColor = Color.FromArgb(170, 91, 49), ActiveLinkColor = Color.FromArgb(140, 70, 34) };
            manual.LinkClicked += delegate { try { Process.Start(new ProcessStartInfo(BuildInfo.ReleaseUrl) { UseShellExecute = true }); } catch (Exception error) { status.Text = error.Message; } }; Controls.Add(manual);
            Shown += async delegate {
                try {
                    recommended = NativeSystem.Architecture();
                    if (recommended == "x64") architecture.Items.AddRange(new object[] { "x64 · 64 位 Windows（推荐）", "x86 · 32 位兼容版" });
                    else architecture.Items.Add("x86 · 32 位 Windows（推荐）");
                    architecture.SelectedIndex = 0; await LoadRelease();
                } catch (Exception error) { status.Text = error.Message + "\n可打开发布页查看说明。"; download.Enabled = false; }
            };
            FormClosing += delegate(object sender, FormClosingEventArgs e) {
                if (busy) { closing = true; e.Cancel = true; if (operation != null) operation.Cancel(); }
            };
            FormClosed += delegate { client.Dispose(); if (Icon != null) Icon.Dispose(); };
        }
        private string SelectedArchitecture { get { return recommended == "x64" && architecture.SelectedIndex == 0 ? "x64" : "x86"; } }
        private void BeginOperation()
        {
            busy = true; operation = new CancellationTokenSource(); architecture.Enabled = false; download.Enabled = false; cancel.Enabled = true; open.Enabled = false; progress.Fraction = 0;
        }
        private void EndOperation()
        {
            busy = false; operation.Dispose(); operation = null; architecture.Enabled = true; download.Enabled = true; cancel.Enabled = false;
            if (closing) Close();
        }
        private void ShowReady()
        {
            download.Text = "下载 " + SelectedArchitecture + " 版";
            var asset = manifest.Asset(SelectedArchitecture);
            status.Text = "约 " + (asset.size / 1048576d).ToString("0.0") + " MB · 下载后解压，运行 Velos.exe";
        }
        private async Task LoadRelease()
        {
            BeginOperation(); download.Text = "正在准备…"; status.Text = "正在连接 GitHub 获取文件信息…";
            try { manifest = await client.LoadAsync(operation.Token); ShowReady(); }
            catch (OperationCanceledException) { status.Text = "已取消或连接超时，可点击重试。"; download.Text = "重试"; }
            catch (Exception error) { status.Text = "无法获取发布信息：" + error.Message; download.Text = "重试"; }
            finally { EndOperation(); }
        }
        private async Task Download()
        {
            var asset = manifest.Asset(SelectedArchitecture);
            using (var dialog = new SaveFileDialog { Title = "保存 Velos 安装包", Filter = "ZIP 压缩包|*.zip", FileName = asset.name, InitialDirectory = NativeSystem.Downloads(), OverwritePrompt = true })
            {
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                var destination = dialog.FileName; var overwrite = File.Exists(destination);
                BeginOperation(); download.Text = "下载中…";
                try {
                    var report = new Progress<DownloadProgress>(delegate(DownloadProgress value) {
                        if (!busy || closing) return; progress.Fraction = (double)value.Received / value.Total;
                        status.Text = "已下载 " + (value.Received / 1048576d).ToString("0.0") + " / " + (value.Total / 1048576d).ToString("0.0") + " MB";
                    });
                    await client.SaveAsync(asset, destination, overwrite, report, operation.Token);
                    savedPath = destination; status.Text = "下载完成，完整性校验通过。\n打开文件夹，解压后运行 Velos.exe。"; open.Enabled = true;
                }
                catch (OperationCanceledException) { status.Text = operation.IsCancellationRequested ? "下载已取消，已有文件未改动。" : "下载超时，请重试。"; progress.Fraction = 0; }
                catch (Exception error) { status.Text = "下载失败：" + error.Message; progress.Fraction = 0; }
                finally { download.Text = "重新下载 " + SelectedArchitecture + " 版"; EndOperation(); }
            }
        }
    }
    internal sealed class WarmButton : Button
    {
        internal bool Prominent;
        internal WarmButton() { FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true); }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias; e.Graphics.Clear(Parent.BackColor);
            var bounds = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = Rounded(bounds, 12))
            using (var brush = new LinearGradientBrush(bounds, Prominent ? Color.FromArgb(255, 167, 115) : Color.FromArgb(243, 231, 218), Prominent ? Color.FromArgb(245, 148, 92) : Color.FromArgb(235, 220, 205), 90f))
            { e.Graphics.FillPath(brush, path); if (Focused && ShowFocusCues) using (var pen = new Pen(Color.FromArgb(171, 87, 43), 1.5f)) e.Graphics.DrawPath(pen, path); }
            TextRenderer.DrawText(e.Graphics, Text, Font, bounds, !Enabled ? Color.FromArgb(167, 151, 138) : Prominent ? Color.White : ForeColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
        internal static GraphicsPath Rounded(Rectangle bounds, int radius)
        {
            var d = radius * 2; var p = new GraphicsPath(); p.AddArc(bounds.Left, bounds.Top, d, d, 180, 90); p.AddArc(bounds.Right - d, bounds.Top, d, d, 270, 90);
            p.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90); p.AddArc(bounds.Left, bounds.Bottom - d, d, d, 90, 90); p.CloseFigure(); return p;
        }
    }
    internal sealed class WarmProgress : Control
    {
        private double fraction;
        internal double Fraction { get { return fraction; } set { fraction = Math.Max(0, Math.Min(1, value)); Invalidate(); } }
        internal WarmProgress() { SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true); }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(Parent.BackColor); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var track = WarmButton.Rounded(new Rectangle(0, 0, Width - 1, Height - 1), 3))
            using (var background = new SolidBrush(Color.FromArgb(235, 220, 205))) e.Graphics.FillPath(background, track);
            if (fraction <= 0) return;
            using (var fill = new SolidBrush(Color.FromArgb(245, 148, 92))) e.Graphics.FillRectangle(fill, 0, 0, (int)(Width * fraction), Height);
        }
    }
}
