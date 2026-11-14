using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Windows;
using System.Text.RegularExpressions;
using Velos.Windows.Capture;
using OleData = System.Runtime.InteropServices.ComTypes.IDataObject;

namespace Velos.Screenshot;

[ComVisible(true), Guid("00000121-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IScreenshotDropSource
{
    [PreserveSig] int QueryContinueDrag([MarshalAs(UnmanagedType.Bool)] bool escape, uint keys);
    [PreserveSig] int GiveFeedback(uint effect);
}

internal static class ScreenshotDrag
{
    private static string TempRoot => Path.Combine(Path.GetTempPath(), "Velos", "ScreenshotDrag");
    public static bool Start(ShotImage image, Action<string>? error = null, string? temporaryRoot = null)
    {
        try
        {
            var result = DoDragDrop(new DragData(image, temporaryRoot), new DragSource(), 1, out var effect);
            Marshal.ThrowExceptionForHR(result);
            return result == 0x40100 && effect == 1;
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or ExternalException)
        { error?.Invoke($"无法拖出截图，请重试。（0x{failure.HResult:X8}）"); return false; }
    }

    internal static void CleanupTemporaryFiles(string? root = null)
    {
        try
        {
            var folder = new DirectoryInfo(root ?? TempRoot);
            if (!folder.Exists || IsLinkedPath(folder)) return;
            var cutoff = DateTime.UtcNow.AddDays(-1);
            foreach (var file in folder.EnumerateFiles("*.png", SearchOption.TopDirectoryOnly))
                if (Regex.IsMatch(file.Name, @"^截图 \d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}-[0-9a-f]{8}\.png$") && !file.Attributes.HasFlag(FileAttributes.ReparsePoint) && file.LastWriteTimeUtc < cutoff)
                    try { Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(file.FullName, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin); }
                    catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or OperationCanceledException) { }
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException) { }
    }
    private static bool IsLinkedPath(DirectoryInfo folder)
    {
        for (DirectoryInfo? current = folder; current is not null; current = current.Parent)
            if (current.Attributes.HasFlag(FileAttributes.ReparsePoint)) return true;
        return false;
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    private sealed class DragData : OleData
    {
        private const int InvalidAspect = unchecked((int)0x8004006b), InvalidIndex = unchecked((int)0x80040068),
            InvalidMedium = unchecked((int)0x80040069);
        private static readonly short Png = unchecked((short)DataFormats.GetDataFormat("PNG").Id);
        private static readonly short FileGroup = unchecked((short)DataFormats.GetDataFormat("FileGroupDescriptorW").Id);
        private static readonly short FileContents = unchecked((short)DataFormats.GetDataFormat("FileContents").Id);
        private readonly OleData fallback;
        private readonly byte[] png;
        private readonly byte[]? descriptor;
        private readonly string? temporaryPath;
        private bool materialized;

        public DragData(ShotImage image, string? temporaryRoot = null)
        {
            png = image.Png;
            var data = new DataObject();
            if (image.SavedPath is { } path && File.Exists(path))
                data.SetData(DataFormats.FileDrop, new[] { path });
            else
            {
                descriptor = BuildDescriptor(image);
                temporaryPath = Path.Combine(temporaryRoot ?? TempRoot, Path.GetFileNameWithoutExtension(image.PngName) + "-" + Guid.NewGuid().ToString("N")[..8] + ".png");
                // 同时提供普通文件路径。查询格式不落盘，接收方真正请求文件时才写临时 PNG。
                data.SetData(DataFormats.FileDrop, new[] { temporaryPath });
            }
            data.SetImage(ShotEncoding.Decode(image.Png));
            fallback = data;
        }

        public int QueryGetData(ref FORMATETC request)
        {
            if (request.cfFormat != Png && (descriptor is null || request.cfFormat != FileGroup && request.cfFormat != FileContents))
                return fallback.QueryGetData(ref request);
            if (request.dwAspect != DVASPECT.DVASPECT_CONTENT)
                return InvalidAspect;
            var content = request.cfFormat == FileContents;
            if (request.lindex != -1 && (!content || request.lindex != 0))
                return InvalidIndex;
            var available = TYMED.TYMED_HGLOBAL | (content ? TYMED.TYMED_ISTREAM : 0);
            return (request.tymed & available) != 0 ? 0 : InvalidMedium;
        }

        public void GetData(ref FORMATETC request, out STGMEDIUM medium)
        {
            if (request.cfFormat == 15 && temporaryPath is not null && !materialized)
            {
                Marshal.ThrowExceptionForHR(QueryGetData(ref request));
                var directory = Directory.CreateDirectory(Path.GetDirectoryName(temporaryPath)!);
                if (IsLinkedPath(directory)) throw new IOException("临时截图目录不能是链接。");
                using (var output = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read)) output.Write(png);
                materialized = true;
            }
            if (request.cfFormat != Png && (descriptor is null || request.cfFormat != FileGroup && request.cfFormat != FileContents))
            {
                fallback.GetData(ref request, out medium);
                return;
            }
            Marshal.ThrowExceptionForHR(QueryGetData(ref request));
            var useStream = request.cfFormat == FileContents && request.tymed.HasFlag(TYMED.TYMED_ISTREAM);
            var data = request.cfFormat == FileGroup ? descriptor! : png;
            var handle = useStream ? SHCreateMemStream(data, (uint)data.Length) : TransferMemory.Create(data);
            if (handle == 0)
                throw new OutOfMemoryException();
            medium = new STGMEDIUM { tymed = useStream ? TYMED.TYMED_ISTREAM : TYMED.TYMED_HGLOBAL, unionmember = handle };
        }

        public IEnumFORMATETC EnumFormatEtc(DATADIR direction)
        {
            var original = fallback.EnumFormatEtc(direction);
            if (direction != DATADIR.DATADIR_GET)
                return original;
            var formats = new List<FORMATETC> { Format(Png, -1, TYMED.TYMED_HGLOBAL) };
            if (descriptor is not null)
            {
                formats.Add(Format(FileGroup, -1, TYMED.TYMED_HGLOBAL));
                formats.Add(Format(FileContents, 0, TYMED.TYMED_ISTREAM | TYMED.TYMED_HGLOBAL));
            }
            var next = new FORMATETC[1];
            var fetched = new int[1];
            while (original.Next(1, next, fetched) == 0)
                formats.Add(next[0]);
            Marshal.ThrowExceptionForHR(SHCreateStdEnumFmtEtc((uint)formats.Count, formats.ToArray(), out var result));
            return result;
        }

        public void GetDataHere(ref FORMATETC request, ref STGMEDIUM medium) => fallback.GetDataHere(ref request, ref medium);
        public int GetCanonicalFormatEtc(ref FORMATETC input, out FORMATETC output) => fallback.GetCanonicalFormatEtc(ref input, out output);
        public void SetData(ref FORMATETC request, ref STGMEDIUM medium, bool release) => fallback.SetData(ref request, ref medium, release);
        public int DAdvise(ref FORMATETC request, ADVF flags, IAdviseSink sink, out int connection) =>
            fallback.DAdvise(ref request, flags, sink, out connection);
        public void DUnadvise(int connection) => fallback.DUnadvise(connection);
        public int EnumDAdvise(out IEnumSTATDATA? enumeration) => fallback.EnumDAdvise(out enumeration);

        internal static FORMATETC Format(short id, int index, TYMED type) =>
            new() { cfFormat = id, dwAspect = DVASPECT.DVASPECT_CONTENT, lindex = index, tymed = type };
    }

    private static byte[] BuildDescriptor(ShotImage image)
    {
        var descriptor = new VirtualFile
        {
            Count = 1, Flags = 0x80000044, Attributes = 0x80, Length = (uint)image.Png.Length, Name = image.PngName
        };
        var bytes = new byte[Marshal.SizeOf<VirtualFile>()];
        var pointer = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.StructureToPtr(descriptor, pointer, false);
            Marshal.Copy(pointer, bytes, 0, bytes.Length);
        }
        finally { Marshal.FreeHGlobal(pointer); }
        return bytes;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct VirtualFile
    {
        public uint Count, Flags;
        public Guid ClassId;
        public int SizeX, SizeY, PointX, PointY;
        public uint Attributes;
        public FILETIME Created, Accessed, Written;
        public uint LengthHigh, Length;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    private sealed class DragSource : IScreenshotDropSource
    {
        public int QueryContinueDrag(bool escape, uint keys) => escape ? 0x40101 : (keys & 1) == 0 ? 0x40100 : 0;
        public int GiveFeedback(uint effect) => 0x40102;
    }

    [DllImport("ole32.dll")] private static extern int DoDragDrop(
        [MarshalAs(UnmanagedType.Interface)] OleData data, [MarshalAs(UnmanagedType.Interface)] IScreenshotDropSource source,
        uint effects, out uint effect);

    [DllImport("shlwapi.dll")] private static extern nint SHCreateMemStream(byte[] bytes, uint size);
    [DllImport("shell32.dll")] private static extern int SHCreateStdEnumFmtEtc(uint count, FORMATETC[] formats, out IEnumFORMATETC result);

#if DEBUG
    internal static bool DebugFileDrop(ShotImage image, string root)
    {
        var data = new DragData(image, root); var request = DragData.Format(15, -1, TYMED.TYMED_HGLOBAL);
        if (data.QueryGetData(ref request) != 0 || Directory.Exists(root)) return false;
        data.GetData(ref request, out var medium);
        try { return Directory.EnumerateFiles(root, "*.png").Single() is { } file && File.ReadAllBytes(file).AsSpan().SequenceEqual(image.Png); }
        finally { ReleaseStgMedium(ref medium); }
    }
    public static bool DebugVirtualPng(ShotImage image)
    {
        var data = new DragData(image);
        var dataInterface = Marshal.GetComInterfaceForObject(data, typeof(OleData));
        Marshal.Release(dataInterface);
        var sourceInterface = Marshal.GetComInterfaceForObject(new DragSource(), typeof(IScreenshotDropSource));
        Marshal.Release(sourceInterface);
        var id = unchecked((short)DataFormats.GetDataFormat("FileContents").Id);
        var requested = DragData.Format(id, 0, TYMED.TYMED_ISTREAM);
        if (data.QueryGetData(ref requested) != 0)
            return false;
        var enumeration = data.EnumFormatEtc(DATADIR.DATADIR_GET);
        var record = new FORMATETC[1];
        var fetched = new int[1];
        var found = false;
        while (enumeration.Next(1, record, fetched) == 0)
            found |= record[0].cfFormat == id && record[0].lindex == 0;
        data.GetData(ref requested, out var stream);
        try { return found && stream.tymed == TYMED.TYMED_ISTREAM && stream.unionmember != 0; }
        finally { ReleaseStgMedium(ref stream); }
    }

    [DllImport("ole32.dll")] private static extern void ReleaseStgMedium(ref STGMEDIUM medium);
#endif
}
