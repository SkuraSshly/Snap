namespace Velos.Core.Translation;

/// <summary>Mac 2.4 的候选完整性规则：不能用拉丁乱码替换原识别中的非拉丁文字。</summary>
public static class OcrCandidateRules
{
    public static bool KeepsScripts(string original, string candidate)
    {
        var before = Counts(original); var after = Counts(candidate);
        for (var i = 0; i < before.Length; i++) if (after[i] < before[i] * .9) return false;
        return true;
    }
    private static int[] Counts(string text)
    {
        var counts = new int[9];
        foreach (var rune in text.EnumerateRunes())
        {
            var script = rune.Value switch
            {
                >= 0x4E00 and <= 0x9FFF or >= 0x3400 and <= 0x4DBF or >= 0xF900 and <= 0xFAFF or >= 0x20000 and <= 0x2FA1F => 0,
                >= 0x3040 and <= 0x30FF or >= 0x31F0 and <= 0x31FF => 1,
                >= 0xAC00 and <= 0xD7AF or >= 0x1100 and <= 0x11FF or >= 0x3130 and <= 0x318F => 2,
                >= 0x0400 and <= 0x052F => 3,
                >= 0x0370 and <= 0x03FF => 4,
                >= 0x0600 and <= 0x06FF => 5,
                >= 0x0590 and <= 0x05FF => 6,
                >= 0x0E00 and <= 0x0E7F => 7,
                >= 0x0900 and <= 0x097F => 8,
                _ => -1
            };
            if (script >= 0) counts[script]++;
        }
        return counts;
    }
}
