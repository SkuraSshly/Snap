using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace Velos.Setup {
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
        [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr window);
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
        internal static float WindowScale(IntPtr window)
        {
            try { var dpi = GetDpiForWindow(window); return dpi == 0 ? 1f : dpi / 96f; }
            catch (EntryPointNotFoundException) { return 1f; }
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
