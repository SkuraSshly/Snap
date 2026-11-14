namespace Velos.Core.Recording;

internal static class GifLzw
{
    public static byte[] Encode(byte[] indices)
    {
        const int clearCode = 256, eofCode = 257, maxEntries = 4096;
        var table = new Dictionary<int, int>();
        var data = new List<byte>();
        var bits = 9;
        var maxCode = 511;
        var freeEntry = 258;
        var clearing = false;
        uint accumulator = 0;
        var accumulatedBits = 0;
        void Emit(int code)
        {
            accumulator |= (uint)code << accumulatedBits;
            accumulatedBits += bits;
            while (accumulatedBits >= 8)
            {
                data.Add((byte)accumulator);
                accumulator >>= 8;
                accumulatedBits -= 8;
            }
            if (freeEntry > maxCode || clearing)
            {
                if (clearing) { bits = 9; maxCode = 511; clearing = false; }
                else { bits++; maxCode = bits == 12 ? maxEntries : (1 << bits) - 1; }
            }
        }
        Emit(clearCode);
        if (indices.Length > 0)
        {
            var entry = (int)indices[0];
            for (var p = 1; p < indices.Length; p++)
            {
                var c = indices[p];
                var key = (c << 12) + entry;
                if (table.TryGetValue(key, out var existing)) { entry = existing; continue; }
                Emit(entry);
                entry = c;
                if (freeEntry < maxEntries) table.Add(key, freeEntry++);
                else
                {
                    table.Clear();
                    freeEntry = 258;
                    clearing = true;
                    Emit(clearCode);
                }
            }
            Emit(entry);
        }
        Emit(eofCode);
        if (accumulatedBits > 0) data.Add((byte)accumulator);
        var output = new List<byte>(data.Count + data.Count / 255 + 3) { 8 };
        for (var i = 0; i < data.Count; i += 255)
        {
            var count = Math.Min(255, data.Count - i);
            output.Add((byte)count);
            output.AddRange(data.GetRange(i, count));
        }
        output.Add(0);
        return output.ToArray();
    }
}
