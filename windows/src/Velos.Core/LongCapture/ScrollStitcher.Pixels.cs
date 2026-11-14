using System.Runtime.InteropServices;

namespace Velos.Core.LongCapture;

public sealed partial class ScrollStitcher
{
    private bool UpdateSidebars(ScrollFrame previous, ScrollFrame frame, int d, SpanRange rows)
    {
        var columns = CrossCount(frame);
        if (sideColumn.Length != columns)
        {
            sideColumn = Enumerable.Range(0, columns).Select(c => band is { } span && !span.Contains(c)).ToArray();
            sideStreak = new int[columns]; contentStreak = new int[columns];
        }
        var low = Math.Max(rows.Start, -d); var high = Math.Min(rows.End, Math.Min(rows.End - d, LineCount(frame) - d));
        if (high - low < 8) return false;
        var step = Math.Max(1, (high - low) / 160);
        uint Pixel(ScrollFrame source, int c, int i) => axis == ScrollAxis.Vertical ? source.At(c, i) : source.At(i, c);
        for (var c = 0; c < columns; c++)
        {
            int moved = 0, stayed = 0, total = 0;
            for (var i = low; i < high; i += step)
            {
                var now = Pixel(frame, c, i);
                if (Near(now, Pixel(previous, c, i + d))) moved++;
                if (Near(now, Pixel(previous, c, i))) stayed++;
                total++;
            }
            var follows = moved >= total * Tuning.ColumnMatchFraction; var still = stayed >= total * Tuning.ColumnMatchFraction;
            if (follows && still) continue;
            if (follows)
            { contentStreak[c]++; sideStreak[c] = 0; if (contentStreak[c] >= Tuning.ContentStreak) sideColumn[c] = false; }
            else
            { sideStreak[c]++; contentStreak[c] = 0; if (sideStreak[c] >= Tuning.SidebarStreak) sideColumn[c] = true; }
        }
        int left = 0, right = 0;
        while (left < columns && sideColumn[left]) left++;
        while (right < columns - left && sideColumn[columns - 1 - right]) right++;
        SpanRange? proposed = left == 0 && right == 0 ? null : new(left, columns - right);
        if (proposed is { } p && p.Count * 100 < columns * Tuning.BandMinPercent) proposed = band;
        if (proposed == band) return false;
        band = proposed;
        if (proposed is { } adopted) sideFill = SideFill(previous, axis, adopted);
        return true;
    }

    private int UnmovedTop(ScrollFrame previous, ScrollFrame frame, Line[] oldLines, Line[] lines, int d, SpanRange span)
    {
        var begin = Math.Max(0, -d); var end = Math.Min(lines.Length / 3, lines.Length - d);
        if (begin >= end) return 0;
        var step = Math.Max(1, span.Count / 240);
        float Distance(int i, int j)
        {
            int total = 0, count = 0;
            for (var x = span.Start; x < span.End; x += step)
            {
                var a = axis == ScrollAxis.Vertical ? frame.At(x, i) : frame.At(i, x);
                var b = axis == ScrollAxis.Vertical ? previous.At(x, j) : previous.At(j, x);
                for (var k = 0; k < 24; k += 8) total += Math.Abs((int)((a >> k) & 255) - (int)((b >> k) & 255));
                count++;
            }
            return count == 0 ? 0 : (float)total / (count * 3);
        }
        int header = 0, run = 0;
        for (var i = begin; i < end; i++)
        {
            if (lines[i].Flat) continue;
            var moved = lines[i] == oldLines[i + d] ? 0 : Distance(i, i + d);
            var stayed = lines[i] == oldLines[i] ? 0 : Distance(i, i);
            if (moved <= Tuning.BarLineMatch && stayed > moved + 1) { if (++run == Tuning.BarEndRun) break; }
            else if (stayed <= moved || moved > Tuning.BarLineMatch) { run = 0; header = i + 1; }
        }
        return header;
    }

    private static void Copy(ScrollFrame frame, ScrollAxis axis, SpanRange lines, byte[] output, int index,
        SpanRange? only = null, uint[]? fill = null)
    {
        var cross = axis == ScrollAxis.Vertical ? frame.Width : frame.Height;
        var part = only ?? new SpanRange(0, cross);
        var destination = MemoryMarshal.Cast<byte, uint>(output.AsSpan());
        for (var line = lines.Start; line < lines.End; line++)
        {
            var target = destination.Slice((index + line - lines.Start) * cross, cross);
            if (fill is not null)
            {
                fill.AsSpan(0, part.Start).CopyTo(target);
                fill.AsSpan(part.End).CopyTo(target[part.End..]);
            }
            if (axis == ScrollAxis.Vertical)
            {
                frame.Row(line).Slice(part.Start, part.Count).CopyTo(target[part.Start..]);
            }
            else
            {
                for (var y = part.Start; y < part.End; y++)
                    target[y] = frame.At(line, y);
            }
        }
    }

    private SpanRange? ScrollingSpan(ScrollFrame previous, ScrollFrame frame)
    {
        var runs = ChangedRuns(previous, frame, axis);
        if (runs.Count == 0)
            return null;
        var main = runs.MaxBy(run => run.Count);
        if (runs.Count == 1 || Shift(Lines(previous, axis, main), Lines(frame, axis, main)) is not { } d || d == 0)
            return main;

        int low = main.Start, high = main.End;
        foreach (var run in runs)
        {
            if (run == main)
                continue;
            var oldLines = Lines(previous, axis, run);
            var newLines = Lines(frame, axis, run);
            int moved = 0, considered = 0;
            for (var i = Math.Max(0, -d); i < Math.Min(newLines.Length, newLines.Length - d); i++)
            {
                if (newLines[i].Flat && oldLines[i + d].Flat)
                    continue;
                considered++;
                if (newLines[i] == oldLines[i + d]) moved++;
            }
            if (considered > 0 && moved * 2 >= considered)
            {
                low = Math.Min(low, run.Start);
                high = Math.Max(high, run.End);
            }
        }
        return new SpanRange(low, high);
    }

    private static List<SpanRange> ChangedRuns(ScrollFrame a, ScrollFrame b, ScrollAxis axis)
    {
        var changed = new bool[axis == ScrollAxis.Vertical ? a.Width : a.Height];
        for (var y = 0; y < a.Height; y++)
        {
            var rowA = a.Row(y);
            var rowB = b.Row(y);
            if (rowA.SequenceEqual(rowB))
                continue;
            if (axis == ScrollAxis.Horizontal)
            {
                changed[y] = true;
                continue;
            }
            for (var x = 0; x < a.Width; x++)
                if (!changed[x] && rowA[x] != rowB[x])
                    changed[x] = true;
        }

        var runs = new List<SpanRange>();
        int start = -1, last = -1;
        for (var i = 0; i < changed.Length; i++)
        {
            if (!changed[i])
                continue;
            if (start >= 0 && i - last > 12)
            {
                runs.Add(new SpanRange(start, last + 1));
                start = i;
            }
            else if (start < 0)
            {
                start = i;
            }
            last = i;
        }
        if (start >= 0)
            runs.Add(new SpanRange(start, last + 1));
        return runs;
    }

    private static uint[] SideFill(ScrollFrame frame, ScrollAxis axis, SpanRange band)
    {
        var cross = axis == ScrollAxis.Vertical ? frame.Width : frame.Height;
        var along = axis == ScrollAxis.Vertical ? frame.Height : frame.Width;
        var fill = new uint[cross];
        for (var c = 0; c < cross; c++)
        {
            if (band.Contains(c))
                continue;
            var counts = new Dictionary<uint, int>();
            for (var k = 0; k < along; k += 2)
            {
                var pixel = axis == ScrollAxis.Vertical ? frame.At(c, k) : frame.At(k, c);
                counts[pixel] = counts.GetValueOrDefault(pixel) + 1;
            }
            fill[c] = counts.MaxBy(pair => pair.Value).Key;
        }
        return fill;
    }

    private static ScrollFrame ToRows(byte[] data, int count, int cross, ScrollAxis axis)
    {
        if (axis == ScrollAxis.Vertical)
            return new ScrollFrame(cross, count, cross * 4, data);
        var rows = new byte[checked(count * cross * 4)];
        var dst = MemoryMarshal.Cast<byte, uint>(rows.AsSpan());
        var src = MemoryMarshal.Cast<byte, uint>(data.AsSpan());
        for (var x = 0; x < count; x++)
        for (var y = 0; y < cross; y++)
            dst[y * count + x] = src[x * cross + y];
        return new ScrollFrame(count, cross, count * 4, rows);
    }
}
