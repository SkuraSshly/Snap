using System.Runtime.Intrinsics;

namespace Velos.Core.LongCapture;

public sealed partial class ScrollStitcher
{
    private static Line[] Lines(ScrollFrame frame, ScrollAxis axis, SpanRange span)
    {
        const ulong offset = 0xcbf29ce484222325, prime = 0x00000100000001b3;
        if (axis == ScrollAxis.Vertical)
        {
            var result = new Line[frame.Height];
            for (var y = 0; y < frame.Height; y++)
            {
                var row = frame.Row(y).Slice(span.Start, span.Count);
                var hash = offset;
                var flat = true;
                var first = row[0];
                foreach (var value in row)
                {
                    hash = unchecked((hash ^ value) * prime);
                    if (flat && value != first && !Near(value, first))
                        flat = false;
                }
                result[y] = new Line(hash, flat);
            }
            return result;
        }

        // 横向也顺序读每一行，一次更新所有列的哈希。
        var columns = new Line[frame.Width];
        var firstRow = frame.Row(span.Start);
        Array.Fill(columns, new Line(offset, true));
        for (var y = span.Start; y < span.End; y++)
        {
            var row = frame.Row(y);
            for (var x = 0; x < frame.Width; x++)
            {
                var pixel = row[x];
                var column = columns[x];
                columns[x] = new Line(unchecked((column.Hash ^ pixel) * prime),
                    column.Flat && (pixel == firstRow[x] || Near(pixel, firstRow[x])));
            }
        }
        return columns;
    }

    private static bool Near(uint a, uint b)
    {
        for (var shift = 0; shift < 24; shift += 8)
            if (Math.Abs((int)((a >> shift) & 0xff) - (int)((b >> shift) & 0xff)) > Tuning.PixelTolerance)
                return false;
        return true;
    }

    private static float[] Profiles(ScrollFrame frame, ScrollAxis axis, SpanRange span)
    {
        const int bands = 16;
        var count = axis == ScrollAxis.Vertical ? frame.Height : frame.Width;
        var result = new float[count * bands];
        for (var line = 0; line < count; line++)
        for (var band = 0; band < bands; band++)
        {
            var start = band * span.Count / bands;
            var end = Math.Min(span.Count, Math.Max(start + 1, (band + 1) * span.Count / bands));
            float sum = 0;
            var samples = 0;
            for (var k = span.Start + start; k < span.Start + end; k += 2)
            {
                var pixel = axis == ScrollAxis.Vertical ? frame.At(k, line) : frame.At(line, k);
                sum += (((pixel >> 16) & 0xff) * 2 + ((pixel >> 8) & 0xff) * 5 + (pixel & 0xff)) / 8f;
                samples++;
            }
            result[line * bands + band] = samples > 0 ? sum / samples : 0;
        }
        return result;
    }

    /// <summary>当前第 i 行对应上一帧的第 i+d 行。</summary>
    private static int? Shift(Line[] previous, Line[] current)
    {
        var n = current.Length;
        if (n != previous.Length || n <= 4)
            return null;
        if (previous.AsSpan().SequenceEqual(current))
            return 0;

        var positions = new Dictionary<ulong, List<int>>();
        for (var j = 0; j < n; j++)
        {
            if (previous[j].Flat)
                continue;
            if (!positions.TryGetValue(previous[j].Hash, out var rows))
            {
                rows = [];
                positions.Add(previous[j].Hash, rows);
            }
            rows.Add(j);
        }

        var votes = new Dictionary<int, int>();
        for (var i = 0; i < n; i++)
        {
            if (current[i].Flat || !positions.TryGetValue(current[i].Hash, out var rows) || rows.Count > 4)
                continue;
            foreach (var j in rows)
                if (j != i)
                    votes[j - i] = votes.GetValueOrDefault(j - i) + 1;
        }
        foreach (var vote in votes.OrderByDescending(v => v.Value).ThenBy(v => Math.Abs(v.Key)).Take(3))
            if (vote.Value >= 3 && Verify(previous, current, vote.Key))
                return vote.Key;
        return null;
    }

    private static int? TolerantShift(Line[] previousLines, float[] previousProfiles, Line[] currentLines, float[] currentProfiles,
        int? prior, ScrollFrame previous, ScrollFrame current, ScrollAxis axis, SpanRange span, SpanRange? inner = null, float maxCost = Tuning.MaxCost)
    {
        var n = currentLines.Length;
        if (n != previousLines.Length || n * 16 != previousProfiles.Length || n * 16 != currentProfiles.Length)
            return null;
        var limit = n - Math.Max(8, n / 8);
        if (limit <= 0)
            return null;
        int low = -limit, high = limit;

        var sampleStep = Math.Max(1, span.Count / 240);
        float PixelDistance(int j, int i)
        {
            int total = 0, count = 0;
            for (var x = span.Start; x < span.End; x += sampleStep)
            {
                var p = axis == ScrollAxis.Vertical ? previous.At(x, j) : previous.At(j, x);
                var q = axis == ScrollAxis.Vertical ? current.At(x, i) : current.At(i, x);
                if (p != q)
                    for (var channel = 0; channel < 24; channel += 8)
                        total += Math.Abs((int)((p >> channel) & 0xff) - (int)((q >> channel) & 0xff));
                count++;
            }
            return count == 0 ? 0 : (float)total / (count * 3);
        }

        var fixedRows = new bool[n];
        int usable = 0, changedRows = 0;
        for (var i = 0; i < n; i++)
        {
            fixedRows[i] = currentLines[i].Flat || PixelDistance(i, i) <= Tuning.UnchangedLine;
            if (!currentLines[i].Flat)
            {
                usable++;
                if (!fixedRows[i]) changedRows++;
            }
        }
        if (changedRows < Math.Max(3, usable / 50))
            return 0;

        var step = n > 600 ? 2 : 1;
        float? ProfileCost(int d)
        {
            float total = 0;
            var count = 0;
            var start = Math.Max(0, -d);
            var end = Math.Min(n, n - d);
            for (var i = start; i < end; i += step)
            {
                if (fixedRows[i] || fixedRows[i + d])
                    continue;
                total += ProfileDistance(currentProfiles, i, previousProfiles, i + d);
                count++;
            }
            return count >= Math.Max(3, (end - start) / (10 * step)) ? total / count : null;
        }

        var scores = new List<(int Shift, float Cost)>();
        for (var d = low; d <= high; d++)
            if (d != 0 && ProfileCost(d) is { } cost)
                scores.Add((d, cost));
        var picks = new List<int>(6);
        foreach (var score in scores.OrderBy(s => s.Cost))
        {
            if (picks.Any(d => Math.Abs(d - score.Shift) <= 2))
                continue;
            picks.Add(score.Shift);
            if (picks.Count == 6)
                break;
        }
        if (prior is { } p && p != 0 && Math.Abs((long)p) <= limit && !picks.Any(d => Math.Abs(d - p) <= 2)) picks.Add(p);

        float PixelCost(int d)
        {
            float total = 0;
            var count = 0;
            for (var i = Math.Max(0, -d); i < Math.Min(n, n - d); i += step)
            {
                if (fixedRows[i] || fixedRows[i + d])
                    continue;
                total += PixelDistance(i + d, i);
                count++;
            }
            return count == 0 ? float.PositiveInfinity : total / count;
        }

        var refined = new List<(int Shift, float Cost)>();
        foreach (var pick in picks)
        {
            (int Shift, float Cost)? bestLocal = null;
            for (var d = Math.Max(-limit, pick - 2); d <= Math.Min(limit, pick + 2); d++)
            {
                if (d == 0)
                    continue;
                var cost = PixelCost(d);
                if (bestLocal is null || cost < bestLocal.Value.Cost)
                    bestLocal = (d, cost);
            }
            if (bestLocal is { } best)
                refined.Add(best);
        }

        int? localChange = null;
        if (inner is { } area)
        {
            var count = 0; var unchanged = 0;
            for (var i = area.Start; i < area.End; i++) if (!currentLines[i].Flat)
            { count++; if (fixedRows[i]) unchanged++; }
            if (count > 0 && unchanged * 2 >= count) localChange = 0;
        }
        var ranked = refined.OrderBy(r => r.Cost).ToArray();
        if (ranked.Length == 0 || ranked[0].Cost > maxCost)
            return localChange;
        var bestMatch = ranked[0];
        if (prior is { } recent && recent != 0)
        {
            var tolerance = Math.Max(24L, Math.Abs((long)recent) / 2);
            foreach (var near in ranked)
                if (Math.Abs((long)near.Shift - recent) <= tolerance && near.Cost <= maxCost && near.Cost <= bestMatch.Cost * Tuning.PriorSlackRatio + Tuning.PriorSlackExtra)
                    return near.Shift;
        }
        var second = ranked.Skip(1).Where(r => Math.Abs(r.Shift - bestMatch.Shift) > 2)
            .Select(r => r.Cost).FirstOrDefault(float.PositiveInfinity);
        return second >= bestMatch.Cost * Tuning.ClearlyBetterRatio + Tuning.ClearlyBetterExtra ? bestMatch.Shift : localChange;
    }

    private static float ProfileDistance(float[] a, int aLine, float[] b, int bLine)
    {
        var sum = Vector128<float>.Zero;
        for (var i = 0; i < 16; i += 4)
            sum += Vector128.Abs(Vector128.LoadUnsafe(ref a[aLine * 16 + i]) - Vector128.LoadUnsafe(ref b[bLine * 16 + i]));
        return Vector128.Sum(sum) / 16;
    }

    private static bool Verify(Line[] previous, Line[] current, int d)
    {
        var n = current.Length;
        int considered = 0, matched = 0;
        for (var i = Math.Max(0, -d); i < Math.Min(n, n - d); i++)
        {
            var line = current[i];
            if (line.Flat || line == previous[i] || current[i + d] == previous[i + d])
                continue;
            considered++;
            if (line == previous[i + d]) matched++;
        }
        return considered >= 3 && matched >= considered * Tuning.ExactMatchFraction;
    }

    private static bool MostlySame(Line[] previous, Line[] current)
    {
        var differing = 0;
        for (var i = 0; i < current.Length; i++)
            if (current[i] != previous[i] && !current[i].Flat)
                differing++;
        return differing < Math.Max(4, current.Length / 20);
    }

    private static int Footer(Line[] previous, Line[] current, int d)
    {
        var n = current.Length;
        var start = n;
        for (var i = n - 1; i >= n / 2 && current[i] == previous[i]; i--)
            if (i + d < 0 || i + d >= n || current[i] != previous[i + d])
                start = i;
        return n - start;
    }

    private static int Header(Line[] previous, Line[] current, int d)
    {
        var n = current.Length;
        var end = 0;
        for (var i = 0; i < n / 2 && current[i] == previous[i]; i++)
            if (i + d < 0 || i + d >= n || current[i] != previous[i + d])
                end = i + 1;
        return end;
    }
}
