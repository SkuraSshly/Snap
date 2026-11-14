using System.Runtime.InteropServices;

namespace Velos.Core.LongCapture;

/// <summary>移植自 Mac 2.3 ScrollStitcher.swift。只分析画面，不依赖滚轮事件。</summary>
public sealed partial class ScrollStitcher(ScrollAxis axis, int maxLength = 20_000, (int Leading, int Trailing) edgeMargin = default)
{
    public static class Tuning
    {
        public const int PixelTolerance = 6, BandMinPercent = 15, BandMaxPercent = 95, SidebarStreak = 3, ContentStreak = 2;
        public const int BarEndRun = 3, OutrunFrames = 15, SteadyPairs = 3;
        public const float UnchangedLine = 1.2f, MaxCost = 6, StartMaxCost = 4, ColumnMatchFraction = .8f, BarLineMatch = 2;
        public const float PriorSlackRatio = 1.3f, PriorSlackExtra = .5f, ClearlyBetterRatio = 1.6f, ClearlyBetterExtra = 1;
        public const double ExactMatchFraction = .85;
    }
    public enum EventKind { Started, Unchanged, Appended, Moved, Lost, LimitReached }
    public readonly record struct Result(EventKind Kind, int Added = 0);
    private readonly record struct SpanRange(int Start, int End)
    {
        public int Count => End - Start;
        public bool Contains(int position) => position >= Start && position < End;
    }
    private readonly record struct Line(ulong Hash, bool Flat);

    private ScrollFrame? first;
    private ScrollFrame? last;
    private Line[] lastLines = [];
    private float[]? lastProfiles;
    private int position;
    private int committedEnd;
    private int headerLength;
    private int movingHeader;
    private int? recentShift;
    private int lostFrames;
    private Line[]? lostLines;
    private int steadyPairs;
    private int footerLength;
    private int cross;
    private byte[] content = [];
    private SpanRange? band;
    private uint[] sideFill = [];
    private bool[] sideColumn = [];
    private int[] sideStreak = [];
    private int[] contentStreak = [];

    public ScrollAxis Axis => axis;
    public int Length => IsMoving ? ContentEnd + footerLength : first is null ? 0 : LineCount(first);
    public bool IsMoving => first is null && last is not null;
    public bool ReachedLimit { get; private set; }
    public int? LastShift { get; private set; }

    public Result Add(ScrollFrame frame, int? hint = null)
    {
        LastShift = null;
        if (last is { } previous && (previous.Width != frame.Width || previous.Height != frame.Height))
            return new(EventKind.Lost);
        var result = Stitch(frame);
        if (first is not null && result.Kind is EventKind.Lost or EventKind.Unchanged)
        {
            Rebaseline(frame);
            return new(EventKind.Unchanged);
        }
        if (result.Kind == EventKind.Lost)
            return RecoverIfOutrun(frame) ?? result;
        ResetLost();
        return result;
    }

    private Result Stitch(ScrollFrame frame)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(maxLength, 1);
        if (last is { } existing && (existing.Width != frame.Width || existing.Height != frame.Height))
            return new(EventKind.Lost);
        if (ReachedLimit)
            return new(EventKind.LimitReached);

        var lines = Lines(frame, axis, MatchSpan(frame));
        if (last is not { } previous)
        {
            first = last = frame;
            lastLines = lines;
            lastProfiles = null;
            cross = CrossCount(frame);
            if (LineCount(frame) >= maxLength)
            {
                var clipped = new byte[checked(maxLength * cross * 4)];
                Copy(frame, axis, new(0, maxLength), clipped, 0);
                first = ToRows(clipped, maxLength, cross, axis);
                ReachedLimit = true;
                return new(EventKind.LimitReached);
            }
            return new(EventKind.Started);
        }

        if (first is not null && AdoptScrollingBand(previous, frame) is { } found) lines = found;

        var shift = Shift(lastLines, lines);
        float[]? profiles = null;
        if (shift is null)
        {
            var span = MatchSpan(frame);
            lastProfiles ??= Profiles(previous, axis, span);
            profiles = Profiles(frame, axis, span);
            SpanRange? inner = first is null && headerLength < lines.Length - footerLength ? new(headerLength, lines.Length - footerLength) : null;
            shift = TolerantShift(lastLines, lastProfiles, lines, profiles, recentShift, previous, frame, axis, span, inner, first is not null ? Tuning.StartMaxCost : Tuning.MaxCost);
        }

        bool Implausible(int d) => recentShift is { } prior && (prior > 0 && d < -lines.Length / 2 || prior < 0 && d > lines.Length / 2);
        if (shift is { } candidate && Implausible(candidate)) shift = null;
        if (shift is null && first is null)
        {
            var saved = (band, sideFill, lastLines, lastProfiles, sideColumn, sideStreak, contentStreak);
            var adopted = AdoptScrollingBand(previous, frame);
            var d = adopted is null ? null : Shift(lastLines, adopted) ?? TolerantShift(lastLines,
                Profiles(previous, axis, MatchSpan(previous)), adopted, Profiles(frame, axis, MatchSpan(frame)), recentShift, previous, frame, axis, MatchSpan(frame));
            if (d is { } value && value != 0 && !Implausible(value))
            { lines = adopted!; profiles = null; shift = value; }
            else (band, sideFill, lastLines, lastProfiles, sideColumn, sideStreak, contentStreak) = saved;
        }

        if (shift is null)
            return new(MostlySame(lastLines, lines) ? EventKind.Unchanged : EventKind.Lost);
        if (shift == 0)
        {
            Refresh(frame);
            last = frame;
            lastLines = lines;
            lastProfiles = profiles;
            return new(EventKind.Unchanged);
        }

        var n = lines.Length;
        var footer = Footer(lastLines, lines, shift.Value);
        var scrollEnd = n - footer;
        movingHeader = Math.Max(movingHeader, UnmovedTop(previous, frame, lastLines, lines, shift.Value, MatchSpan(frame)));
        var header = Math.Min(Math.Max(first is not null ? Header(lastLines, lines, shift.Value) : headerLength, movingHeader), scrollEnd);
        var baseEnd = first is not null ? scrollEnd : committedEnd;
        var basePosition = first is not null ? 0 : position;
        if (baseEnd - (basePosition + shift.Value) < header)
            return new(MostlySame(lastLines, lines) ? EventKind.Unchanged : EventKind.Lost);
        recentShift = LastShift = shift;
        footerLength = footer;
        if (UpdateSidebars(previous, frame, shift.Value, new(header, scrollEnd)))
            lines = Lines(frame, axis, MatchSpan(frame));
        if (first is { } initial)
        {
            headerLength = header;
            EnsureCapacity(Math.Min(maxLength, checked(scrollEnd * 4)));
            Copy(initial, axis, new(0, scrollEnd), content, 0);
            committedEnd = scrollEnd;
            position = 0;
            first = null;
        }

        position += shift.Value;
        last = frame;
        lastLines = lines;
        lastProfiles = profiles;
        Refresh(frame);

        var start = Math.Max(header, committedEnd - position);
        if (start >= scrollEnd)
            return new(EventKind.Moved);
        return Append(frame, new(start, scrollEnd));
    }

    private Result Append(ScrollFrame frame, SpanRange range)
    {
        var count = range.Count;
        var room = maxLength - committedEnd - footerLength;
        if (count > room)
        {
            count = Math.Max(0, room);
            ReachedLimit = true;
        }
        if (count == 0)
            return new(EventKind.LimitReached);
        EnsureCapacity(committedEnd + count);
        Copy(frame, axis, new(range.Start, range.Start + count), content, committedEnd, band, band is null ? null : sideFill);
        committedEnd += count;
        return ReachedLimit ? new(EventKind.LimitReached) : new(EventKind.Appended, count);
    }

    private Result? RecoverIfOutrun(ScrollFrame frame)
    {
        var lines = Lines(frame, axis, MatchSpan(frame));
        if (lostLines is { } earlier && Shift(earlier, lines) is { } d && d != 0)
            steadyPairs = steadyPairs != 0 && (steadyPairs > 0) != (d > 0) ? Math.Sign(d) : steadyPairs + Math.Sign(d);
        else steadyPairs = 0;
        lostLines = lines; lostFrames++;
        if (lostFrames < Tuning.OutrunFrames || steadyPairs < Tuning.SteadyPairs || recentShift is not > 0) return null;
        var header = Math.Max(headerLength, movingHeader); var end = lines.Length - footerLength;
        if (header >= end) return null;
        position = committedEnd - header; last = frame; lastLines = lines; lastProfiles = null; ResetLost();
        return Append(frame, new(header, end));
    }

    private void ResetLost() { lostFrames = 0; lostLines = null; steadyPairs = 0; }
    private void Rebaseline(ScrollFrame frame)
    {
        first = last = null; lastLines = []; lastProfiles = null; position = committedEnd = headerLength = movingHeader = footerLength = 0;
        recentShift = null; band = null; sideFill = []; sideColumn = []; sideStreak = contentStreak = []; content = []; ResetLost();
        Stitch(frame);
    }

    private Line[]? AdoptScrollingBand(ScrollFrame previous, ScrollFrame frame)
    {
        if (ScrollingSpan(previous, frame) is not { } changed || changed.Count * 100 < CrossCount(frame) * Tuning.BandMinPercent ||
            changed.Count * 100 > CrossCount(frame) * Tuning.BandMaxPercent || changed == band) return null;
        var saved = band; band = changed; var span = MatchSpan(frame);
        var a = Lines(previous, axis, span); var b = Lines(frame, axis, span);
        var d = Shift(a, b) ?? TolerantShift(a, Profiles(previous, axis, span), b, Profiles(frame, axis, span), null, previous, frame, axis, span, null, first is not null ? Tuning.StartMaxCost : Tuning.MaxCost);
        if (d is null or 0) { band = saved; return null; }
        lastLines = a; lastProfiles = null; sideFill = SideFill(previous, axis, changed);
        sideColumn = Enumerable.Range(0, CrossCount(frame)).Select(c => !changed.Contains(c)).ToArray();
        sideStreak = new int[sideColumn.Length]; contentStreak = new int[sideColumn.Length]; return b;
    }

    private void Refresh(ScrollFrame frame)
    {
        if (first is not null)
            return;
        var low = Math.Max(headerLength, position + Math.Max(headerLength, movingHeader));
        var high = Math.Min(committedEnd, position + LineCount(frame) - footerLength);
        if (low < high)
            Copy(frame, axis, new(low - position, high - position), content, low, band);
    }

    private int CrossCount(ScrollFrame frame) => axis == ScrollAxis.Vertical ? frame.Width : frame.Height;
    private int LineCount(ScrollFrame frame) => axis == ScrollAxis.Vertical ? frame.Height : frame.Width;

    private SpanRange MatchSpan(ScrollFrame frame)
    {
        var basis = band ?? new SpanRange(0, CrossCount(frame));
        return basis.Count > (edgeMargin.Leading + edgeMargin.Trailing) * 4
            ? new SpanRange(basis.Start + edgeMargin.Leading, basis.End - edgeMargin.Trailing) : basis;
    }

    private void EnsureCapacity(int lines)
    {
        var needed = checked(lines * cross * 4);
        if (content.Length >= needed)
            return;
        var capped = Math.Min((long)maxLength * cross * 4, (long)content.Length * 3 / 2);
        Array.Resize(ref content, (int)Math.Max(needed, capped));
    }

    public ScrollFrame? MakeImage()
    {
        if (last is null)
            return null;
        if (first is not null)
            return first;
        var end = ContentEnd;
        var height = end + footerLength;
        var all = new byte[checked(height * cross * 4)];
        content.AsSpan(0, end * cross * 4).CopyTo(all);
        if (footerLength > 0)
        {
            var n = LineCount(last);
            Copy(last, axis, new(n - footerLength, n), all, end);
        }
        return ToRows(all, height, cross, axis);
    }

    private int ContentEnd
    {
        get
        {
            if (first is not null || last is null)
                return committedEnd;
            var end = position + LineCount(last) - footerLength;
            if (end <= 0 || end >= committedEnd)
                return committedEnd;
            var span = band ?? new SpanRange(0, cross);
            var words = MemoryMarshal.Cast<byte, uint>(content.AsSpan());
            var reference = words[end * cross + span.Start];
            for (var line = end; line < committedEnd; line++)
            for (var x = span.Start; x < span.End; x += 3)
                if (!Near(words[line * cross + x], reference))
                    return committedEnd;
            return end;
        }
    }

    /// <summary>取当前位置往上的预览；降采样直接读取拼接缓冲，不复制整张长图。</summary>
    public ScrollFrame? Preview(int maxLines = 3000, int sampleStep = 1)
    {
        if (last is null)
            return null;
        ArgumentOutOfRangeException.ThrowIfLessThan(maxLines, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(sampleStep, 1);
        if (first is not null && sampleStep == 1)
            return first;
        var viewportEnd = first is not null ? LineCount(first) : Math.Min(committedEnd, Math.Max(maxLines, position + LineCount(last) - footerLength));
        var length = first is not null ? LineCount(first) : Math.Min(viewportEnd, maxLines);
        var start = first is null ? viewportEnd - length : 0;
        var along = (length + sampleStep - 1) / sampleStep;
        var across = (cross + sampleStep - 1) / sampleStep;
        var width = axis == ScrollAxis.Vertical ? across : along;
        var height = axis == ScrollAxis.Vertical ? along : across;
        var pixels = new byte[checked(width * height * 4)];
        var output = MemoryMarshal.Cast<byte, uint>(pixels.AsSpan());
        var source = MemoryMarshal.Cast<byte, uint>(content.AsSpan());
        for (var line = 0; line < along; line++)
        for (var col = 0; col < across; col++)
        {
            var x = col * sampleStep;
            var y = start + line * sampleStep;
            long red = 0, green = 0, blue = 0;
            var lastX = Math.Min(cross, x + sampleStep);
            var lastY = Math.Min(start + length, y + sampleStep);
            for (var sampleY = y; sampleY < lastY; sampleY++)
            for (var sampleX = x; sampleX < lastX; sampleX++)
            {
                var pixel = first is null ? source[sampleY * cross + sampleX]
                    : axis == ScrollAxis.Vertical ? first.At(sampleX, sampleY) : first.At(sampleY, sampleX);
                red += (pixel >> 16) & 255;
                green += (pixel >> 8) & 255;
                blue += pixel & 255;
            }
            var count = (lastX - x) * (lastY - y);
            var value = 0xff000000u | (uint)(red / count) << 16 | (uint)(green / count) << 8 | (uint)(blue / count);
            output[axis == ScrollAxis.Vertical ? line * width + col : col * width + line] = value;
        }
        return new ScrollFrame(width, height, width * 4, pixels);
    }
}
