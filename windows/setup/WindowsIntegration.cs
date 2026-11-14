using System;
using System.IO;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using Microsoft.Win32;

namespace Velos.Setup
{
    internal sealed class WindowsIntegration : IInstallationIntegration
    {
        internal const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Velos.Windows";
        private readonly string keyName, shortcut, expectedRoot;
        internal WindowsIntegration(string root) : this(root, UninstallKey, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Velos.lnk")) { }
        internal WindowsIntegration(string root, string keyName, string shortcut) { expectedRoot = root; this.keyName = keyName; this.shortcut = shortcut; }
        private sealed class Snapshot
        {
            internal byte[] Link;
            internal Dictionary<string, object> Values;
            internal Dictionary<string, RegistryValueKind> Kinds;
        }
        public object Capture()
        {
            Installation.Guard(shortcut);
            var snapshot = new Snapshot();
            if (File.Exists(shortcut))
            {
                if (!SamePath(Shortcut.Target(shortcut), Path.Combine(expectedRoot, "Velos.exe"))) throw new IOException("开始菜单已有其他同名快捷方式，未覆盖。");
                snapshot.Link = File.ReadAllBytes(shortcut);
            }
            using (var key = Registry.CurrentUser.OpenSubKey(keyName))
            {
                if (key != null)
                {
                    if (!SamePath(key.GetValue("InstallLocation") as string, expectedRoot)) throw new IOException("已有其他同名安装记录，未覆盖。");
                    snapshot.Values = new Dictionary<string, object>(); snapshot.Kinds = new Dictionary<string, RegistryValueKind>();
                    foreach (var name in key.GetValueNames()) { snapshot.Values[name] = key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames); snapshot.Kinds[name] = key.GetValueKind(name); }
                }
            }
            return snapshot;
        }
        public void Register(string root, string version, long bytes)
        {
            if (!SamePath(root, expectedRoot)) throw new InvalidOperationException("安装位置不匹配。");
            Installation.Guard(shortcut); Directory.CreateDirectory(Path.GetDirectoryName(shortcut));
            Shortcut.Save(shortcut, Path.Combine(root, "Velos.exe"));
            using (var key = Registry.CurrentUser.CreateSubKey(keyName))
            {
                key.SetValue("DisplayName", "Velos"); key.SetValue("DisplayVersion", version); key.SetValue("Publisher", "SkuraSshly");
                key.SetValue("InstallLocation", root); key.SetValue("DisplayIcon", Path.Combine(root, "Velos.exe") + ",0");
                key.SetValue("UninstallString", "\"" + Path.Combine(root, "Uninstall.exe") + "\" /uninstall");
                key.SetValue("URLInfoAbout", "https://github.com/SkuraSshly/Velos");
                key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
                key.SetValue("EstimatedSize", (int)((bytes + 1023) / 1024), RegistryValueKind.DWord);
                key.SetValue("NoModify", 1, RegistryValueKind.DWord); key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            }
        }
        public void Restore(object previous)
        {
            var snapshot = (Snapshot)previous;
            Installation.Guard(shortcut);
            if (snapshot.Link != null) File.WriteAllBytes(shortcut, snapshot.Link);
            else if (File.Exists(shortcut) && SamePath(Shortcut.Target(shortcut), Path.Combine(expectedRoot, "Velos.exe"))) File.Delete(shortcut);
            Registry.CurrentUser.DeleteSubKey(keyName, false);
            if (snapshot.Values != null)
                using (var key = Registry.CurrentUser.CreateSubKey(keyName))
                    foreach (var value in snapshot.Values) key.SetValue(value.Key, value.Value, snapshot.Kinds[value.Key]);
        }
        public void Remove(string root)
        {
            Installation.Guard(shortcut);
            if (File.Exists(shortcut) && SamePath(Shortcut.Target(shortcut), Path.Combine(root, "Velos.exe"))) File.Delete(shortcut);
            bool owned;
            using (var key = Registry.CurrentUser.OpenSubKey(keyName)) owned = key != null && SamePath(key.GetValue("InstallLocation") as string, root);
            if (owned) Registry.CurrentUser.DeleteSubKey(keyName, false);
            using (var run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                if (run != null && String.Equals(run.GetValue("Velos") as string, "\"" + Path.Combine(root, "Velos.exe") + "\" --login", StringComparison.OrdinalIgnoreCase)) run.DeleteValue("Velos", false);
        }
        private static bool SamePath(string first, string second)
        { return !String.IsNullOrEmpty(first) && String.Equals(Path.GetFullPath(first).TrimEnd('\\'), Path.GetFullPath(second).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase); }
    }
    internal static class Shortcut
    {
        [ComImport, Guid("00021401-0000-0000-C000-000000000046")] private class Link { }
        [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
        private interface IShellLink
        {
            void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int length, IntPtr data, uint flags);
            void GetIDList(out IntPtr value); void SetIDList(IntPtr value);
            void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int length);
            void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string value);
            void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int length);
            void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string value);
            void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int length);
            void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string value);
            void GetHotkey(out short value); void SetHotkey(short value); void GetShowCmd(out int value); void SetShowCmd(int value);
            void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int length, out int index);
            void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string value, int index);
            void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string value, uint reserved); void Resolve(IntPtr window, uint flags);
            void SetPath([MarshalAs(UnmanagedType.LPWStr)] string value);
        }
        internal static void Save(string path, string target)
        {
            var link = (IShellLink)new Link(); var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                link.SetPath(target); link.SetWorkingDirectory(Path.GetDirectoryName(target)); link.SetIconLocation(target, 0); link.SetDescription("Velos 截图、长截图、录屏和截屏翻译");
                ((IPersistFile)link).Save(temporary, true);
                if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
            }
            finally { Marshal.FinalReleaseComObject(link); if (File.Exists(temporary)) File.Delete(temporary); }
        }
        internal static string Target(string path)
        {
            var link = (IShellLink)new Link();
            try { ((IPersistFile)link).Load(path, 0); var text = new StringBuilder(32768); link.GetPath(text, text.Capacity, IntPtr.Zero, 4); return text.ToString(); }
            finally { Marshal.FinalReleaseComObject(link); }
        }
    }
}
