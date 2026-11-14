using System.ComponentModel;
using System.Runtime.InteropServices;
using Velos.Core.Translation;

namespace Velos.Windows.Translation;

public sealed class CredentialStore
{
    private readonly string prefix;
    private readonly object sync = new();
    private readonly Dictionary<(EngineId, string), string> values = [];
    private readonly Dictionary<(EngineId, string), bool> presence = [];
    public CredentialStore(string? prefix = null)
    {
#if DEBUG
        this.prefix = prefix ?? "Velos/Debug/Translation/";
#else
        this.prefix = "Velos/Translation/";
#endif
    }
    private string Target(EngineId engine, string field) => prefix + engine + "/" + field;
    public string Get(EngineId engine, string field)
    {
        lock (sync)
        {
            if (values.TryGetValue((engine, field), out var cached)) return cached;
            if (!CredRead(Target(engine, field), 1, 0, out var pointer))
            {
                if (Marshal.GetLastWin32Error() != 1168) throw new Win32Exception();
                presence[(engine, field)] = false;
                return values[(engine, field)] = "";
            }
            try
            {
                var credential = Marshal.PtrToStructure<Credential>(pointer);
                presence[(engine, field)] = credential.BlobSize > 0;
                return values[(engine, field)] = credential.Blob == 0 ? "" : Marshal.PtrToStringUni(credential.Blob, checked((int)credential.BlobSize / 2)) ?? "";
            }
            finally { CredFree(pointer); }
        }
    }
    public bool Contains(EngineId engine, string field)
    {
        lock (sync)
        {
            if (presence.TryGetValue((engine, field), out var saved)) return saved;
            var target = Target(engine, field);
            if (!CredEnumerate(target + "*", 0, out var count, out var entries))
            { if (Marshal.GetLastWin32Error() == 1168) return presence[(engine, field)] = false; throw new Win32Exception(); }
            try
            {
                // 只查看条目名称和长度，不解引用 CredentialBlob，不为设置界面读取 Key。
                for (var i = 0; i < count; i++)
                {
                    var item = Marshal.PtrToStructure<Credential>(Marshal.ReadIntPtr(entries, checked((int)i * nint.Size)));
                    if (item.Type == 1 && item.Target == target && item.BlobSize > 0) return presence[(engine, field)] = true;
                }
                return presence[(engine, field)] = false;
            }
            finally { CredFree(entries); }
        }
    }
    public void Set(EngineId engine, string field, string value)
    {
        lock (sync)
        {
            value = value.Trim(); var target = Target(engine, field);
            if (value.Length == 0)
            {
                if (!CredDelete(target, 1, 0) && Marshal.GetLastWin32Error() != 1168) throw new Win32Exception();
                values.Remove((engine, field)); presence[(engine, field)] = false; return;
            }
            if (value.Length * 2 > 2560) throw new ArgumentException("凭据过长，最多 1280 个字符。");
            var secret = Marshal.StringToCoTaskMemUni(value);
            try
            {
                var credential = new Credential { Type = 1, Target = target, UserName = "Velos", Persist = 2, Blob = secret,
                    BlobSize = checked((uint)value.Length * 2), Comment = "Velos 翻译引擎" };
                if (!CredWrite(ref credential, 0)) throw new Win32Exception();
                values[(engine, field)] = value; presence[(engine, field)] = true;
            }
            finally { Marshal.ZeroFreeCoTaskMemUnicode(secret); }
        }
    }
    public void ClearCache() { lock (sync) { values.Clear(); presence.Clear(); } }
    public void ClearAll() { foreach (var engine in EngineDefinition.All) foreach (var field in engine.Fields) Set(engine.Id, field.Id, ""); }
    [StructLayout(LayoutKind.Sequential)] private struct FileTime { public uint Low, High; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct Credential
    {
        public uint Flags, Type; public string? Target, Comment; public FileTime LastWritten;
        public uint BlobSize; public nint Blob; public uint Persist, AttributeCount; public nint Attributes; public string? Alias, UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CredRead(string target, uint type, uint flags, out nint credential);
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CredWrite(ref Credential credential, uint flags);
    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CredDelete(string target, uint type, uint flags);
    [DllImport("advapi32.dll", EntryPoint = "CredEnumerateW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CredEnumerate(string filter, uint flags, out uint count, out nint credentials);
    [DllImport("advapi32.dll")] private static extern void CredFree(nint credential);
}
