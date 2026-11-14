using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Velos.Core.Translation;

public readonly record struct OcrBox(double X, double Y, double Width, double Height)
{
    public double MinX => X;
    public double MaxX => X + Width;
    public double MidX => X + Width / 2;
    public double MinY => Y;
    public double MaxY => Y + Height;
}
public sealed record OcrLine(int Id, string Text, OcrBox Box, double Confidence = 1);

// Mac OCRKit 的 LayoutComposer / TextBlock / LineJoiner / PoetryClassifier。
// 输入统一为 Vision 的左下角归一化坐标；字体、拼写、分词和语言检测由平台适配器提供。
public sealed class OcrLayoutComposer(double imageWidth, TranslateLanguage? language, Func<string, TranslateLanguage?> detect,
    Func<string, double> measure13, Func<string, bool> spelled, Func<string, int> countWords)
{
    private enum Join { Newline, Paragraph, Space, Direct, RemoveHyphen }
    private static string Connect(string a, string b, Join join) => join switch
    { Join.Newline => a + "\n" + b, Join.Paragraph => a + "\n\n" + b, Join.Space => a + " " + b,
        Join.RemoveHyphen => (a.EndsWith('-') ? a[..^1] : a) + b, _ => a + b };
    private Join ByLanguage(string previous, string next) => detect(Traits.LastWord(previous) + Traits.FirstWord(next))?.NeedsWordSpacing == false ? Join.Direct : Join.Space;

    public string Compose(IReadOnlyList<OcrLine> lines)
    {
        var sorted = lines.OrderByDescending(line => line.Box.MinY).ToArray(); if (sorted.Length == 0) return "";
        var average = sorted.Average(line => line.Box.Height); var bands = new List<List<OcrLine>> { new() { sorted[0] } };
        for (var i = 1; i < sorted.Length; i++)
        {
            if (average > 0 && Block.Gap(sorted[i - 1], sorted[i]) / average > 1.45) bands.Add([]);
            bands[^1].Add(sorted[i]);
        }
        var output = new List<string>();
        foreach (var band in bands)
        {
            var columns = band.Any(line => line.Box.MinX < .5 && line.Box.MaxX > .5)
                ? new[] { band.ToArray() } : new[] { band.Where(line => line.Box.MinX < .5).ToArray(), band.Where(line => line.Box.MinX >= .5).ToArray() }.Where(column => column.Length > 0).ToArray();
            var blocks = columns.Select(column => {
                // 与 readingOrder 一样，同一行按 x，其余按 y。
                var ordered = column.OrderBy(line => line.Id).ToList();
                // 几何上的“同一行”不是全序；稳定插入，避免通用排序对交错识别框报比较器异常。
                for (var i = 1; i < ordered.Count; i++) {
                    var item = ordered[i]; var j = i;
                    while (j > 0 && (Block.NewLine(ordered[j - 1], item, 0) ? item.Box.MinY > ordered[j - 1].Box.MinY : item.Box.MinX < ordered[j - 1].Box.MinX))
                    { ordered[j] = ordered[j - 1]; j--; }
                    ordered[j] = item;
                }
                var block = new Block(ordered, language ?? detect(string.Join('\n', ordered.Select(line => line.Text))), imageWidth, measure13);
                block.IsPoetry = IsPoetry(block); return block;
            }).ToArray();
            var text = "";
            for (var i = 0; i < blocks.Length; i++) text = i == 0 ? ComposeBlock(blocks[i]) : Connect(text, ComposeBlock(blocks[i]), JoinColumns(blocks[i - 1], blocks[i]));
            if (!string.IsNullOrWhiteSpace(text)) output.Add(text.Trim());
        }
        return string.Join("\n\n", output).Trim();
    }
    private string ComposeBlock(Block block)
    {
        if (block.Lines.Count == 0) return "";
        var lines = block.Lines; var text = lines[0].Text; var paragraph = new List<OcrLine> { lines[0] }; var rightmost = lines[0];
        for (var i = 1; i < lines.Count; i++)
        {
            var next = Decide(block, lines[i - 1], lines[i], paragraph, rightmost); text = Connect(text, lines[i].Text, next);
            if (next is Join.Newline or Join.Paragraph) { paragraph = [lines[i]]; rightmost = lines[i]; }
            else { paragraph.Add(lines[i]); if (lines[i].Box.MaxX > rightmost.Box.MaxX) rightmost = lines[i]; }
        }
        return text.Trim();
    }
    private Join Decide(Block b, OcrLine previous, OcrLine current, IReadOnlyList<OcrLine> paragraph, OcrLine paragraphRightmost)
    {
        var first = paragraph.FirstOrDefault() ?? previous;
        var firstIndented = b.Indented(first); var previousIndented = previous == first ? firstIndented : b.Indented(previous);
        var reference = firstIndented ? paragraphRightmost : b.Rightmost ?? previous;
        var previousLong = b.Long(previous, current, reference); var absolutelyLong = b.Long(previous, current);
        var endsSentence = Traits.EndsSentence(previous.Text); var startsLower = Traits.StartsLower(current.Text);
        var currentList = Traits.List(current.Text); var previousList = Traits.List(previous.Text); var firstList = Traits.List(first.Text);
        var alignedPrevious = b.Aligned(current, previous); var alignedFirst = b.Aligned(current, first); var indentedPrevious = b.Indented(current, previous);
        var big = b.BigSpacing(previous, current); var veryBig = b.BigSpacing(previous, current, 1.5); var somewhatBig = b.BigSpacing(previous, current, .65);
        var mayParagraph = somewhatBig || b.DifferentFont(previous, current);
        Join Language() => ByLanguage(previous.Text, current.Text);
        if (!Block.NewLine(previous, current, b.AverageHeight)) return Join.Space;
        if (Hyphen(previous, current, b) is { } hyphen) return hyphen;
        if (b.DifferentFont(previous, current, 2)) return Join.Paragraph;
        if (b.Indented(current, previous, 1.5) && !previousLong) return Join.Paragraph;
        if (previousLong && b.WidestWidth > 0 && (previous.Box.MinX - current.Box.MinX) / b.WidestWidth > .45) return Join.Paragraph;
        if (veryBig && (!previousLong || endsSentence && !startsLower)) return Join.Paragraph;
        if (big)
        { if (previousLong && startsLower && !currentList) return Language(); if (currentList && firstList) return Join.Newline; return Join.Paragraph; }
        if (b.IsPoetry) return !b.Aligned(current, previous, strictness: 1.5) || big ? Join.Paragraph : Join.Newline;
        if (currentList)
        {
            if (firstList) {
                if (veryBig) return Join.Paragraph;
                if (alignedFirst) { if (b.Indented(current, previous)) return Join.Paragraph; if (!big) return Join.Newline; }
                else return Join.Paragraph;
            }
            else { if (indentedPrevious && !alignedFirst || big) return Join.Paragraph; }
            if (!alignedPrevious && firstIndented || previousIndented && !alignedFirst) return Join.Paragraph;
            return Join.Newline;
        }
        if (b.ChineseCouplet(previous, current)) return Join.Newline;
        if (!alignedPrevious)
        {
            if (!previousLong) return Join.Paragraph;
            if (!absolutelyLong) return previousIndented || previousList || b.Indented(current, previous, 1.5) ? Join.Paragraph : Join.Newline;
            var centered = b.Aligned(current, previous, edge: 2) && !endsSentence && !b.DifferentFont(previous, current, .7) && !somewhatBig && !currentList && indentedPrevious;
            if (centered) return Language();
            if (indentedPrevious && !previousList || b.Indented(current) && previousIndented && !indentedPrevious) return Join.Paragraph;
            return Language();
        }
        if (previousList && mayParagraph && !startsLower) return Join.Paragraph;
        if (!previousLong || previous == first && !previousIndented && !absolutelyLong) return mayParagraph ? Join.Paragraph : Join.Newline;
        if (b.Short(current) && b.Short(previous)) return Join.Newline;
        if (somewhatBig && b.DifferentFont(previous, current, .7)) return Join.Paragraph;
        return Language();
    }
    private Join? Hyphen(OcrLine previous, OcrLine current, Block block)
    {
        var upper = previous.Text; var lower = current.Text; if (upper.Length == 0 || lower.Length == 0) return null;
        var endsDash = "-–—".Contains(upper[^1]);
        if ((!endsDash && lower[0] != '-') || !block.Spacing || !block.Long(previous, current)) return null;
        if (endsDash && char.IsLetter(lower[0])) { var head = Traits.LastWord(upper[..^1]); if (head.Length > 0 && spelled(head + Traits.FirstWord(lower))) return Join.RemoveHyphen; }
        return upper.EndsWith(" -", StringComparison.Ordinal) || lower.StartsWith("- ", StringComparison.Ordinal) ? Join.Space : Join.Direct;
    }
    private Join JoinColumns(Block left, Block right)
    {
        if (left.Lines.Count == 0 || right.Lines.Count == 0) return Join.Paragraph;
        var last = left.Lines[^1]; var first = right.Lines[0];
        return Hyphen(last, first, left) ?? (!left.Long(last, first) || Traits.EndsSentence(last.Text) ? Join.Paragraph : ByLanguage(last.Text, first.Text));
    }
    private bool IsPoetry(Block block)
    {
        const string symbols = "《》一•·-#—"; var lines = block.Lines;
        if (lines.Count <= 1 || block.PunctuationPerLine > 2.5) return false;
        int sentenceEnds = 0, punctuationEnds = 0, unpunctuated = 0, words = 0, punctuation = 0, characters = 0;
        bool PoemLength(double w, double c, double scale) => w <= 7 * scale || c <= 12 * scale;
        for (var i = 0; i < lines.Count; i++)
        {
            var text = lines[i].Text;
            for (var j = 0; j < text.Length; j++) if ("。！？.!?;:…".Contains(text[j]) && text[(j + 1)..].FirstOrDefault(char.IsLetter) is var letter && char.IsUpper(letter)) return false;
            var count = Traits.Punctuation(text, symbols); if (count == 0) unpunctuated++; else punctuation += count;
            characters += Traits.Length(text) - count; words += countWords(text);
            if (text.Length > 0 && char.IsPunctuation(text[^1]) && !symbols.Contains(text[^1])) punctuationEnds++;
            var ends = Traits.EndsSentence(text); if (ends) sentenceEnds++;
            if (i > 0 && block.Long(lines[i - 1], lines[i])) {
                var previous = lines[i - 1].Text; var punctuated = previous.Length > 0 && char.IsPunctuation(previous[^1]);
                if (ends && !punctuated && (Traits.StartsLower(previous) || Traits.StartsUpper(previous) || !PoemLength(countWords(previous), Traits.Length(previous), 1.5))) return false;
                if (Traits.List(previous) && !punctuated && Traits.StartsLower(text)) return false;
            }
        }
        var n = (double)lines.Count; var chars = characters / n; var wpl = words / n; var ppl = punctuation / n;
        if (chars < 2 || ppl > 2 || !PoemLength(wpl, chars, 2)) return false;
        if (PoemLength(wpl, chars, 1) && ppl <= 1.5) return true;
        return PoemLength(wpl, chars, 1.5) && (sentenceEnds / n >= .8 || punctuationEnds / n >= .8 || unpunctuated / n >= .9 || ppl <= .1 || sentenceEnds == 0 && punctuationEnds / n < .2 && unpunctuated / n > .8 && ppl < .2);
    }

    private sealed class Block
    {
        public IReadOnlyList<OcrLine> Lines { get; }
        public bool Chinese { get; }
        public bool Spacing { get; }
        public bool IsPoetry;
        public OcrLine? Leftmost { get; }
        public OcrLine? Rightmost { get; }
        private OcrLine? Widest { get; }
        public double WidestWidth => Widest?.Box.Width ?? 0;
        public double AverageHeight { get; }
        public double PunctuationPerLine { get; }
        private readonly double imageWidth, spacingThreshold;
        private readonly Dictionary<int, double> fontSizes = [];
        public Block(IReadOnlyList<OcrLine> lines, TranslateLanguage? language, double imageWidth, Func<string, double> measure)
        {
            Lines = lines; Chinese = language?.IsChinese == true; Spacing = language?.NeedsWordSpacing ?? true; this.imageWidth = imageWidth;
            if (lines.Count == 0) return;
            Leftmost = lines.MinBy(line => line.Box.MinX); Rightmost = lines.MaxBy(line => line.Box.MaxX); Widest = lines.MaxBy(line => line.Box.Width);
            AverageHeight = lines.Average(line => line.Box.Height); var minimum = lines.Min(line => line.Box.Height);
            var gaps = Enumerable.Range(1, lines.Count - 1).Select(i => Gap(lines[i - 1], lines[i])).Where(gap => gap > 0).Select(gap => Math.Min(gap, AverageHeight * 1.2)).ToArray();
            var averageGap = gaps.Length > 0 ? gaps.Average() : 0;
            spacingThreshold = Math.Max(Math.Min(AverageHeight, minimum * 1.1), averageGap * 1.2);
            PunctuationPerLine = lines.Sum(line => Traits.Punctuation(line.Text)) / (double)lines.Count;
            foreach (var line in lines) { var width = measure(line.Text); fontSizes[line.Id] = width > 0 ? line.Box.Width * imageWidth * 13 / width : 13; }
        }
        public static double Gap(OcrLine upper, OcrLine lower) => upper.Box.MinY - lower.Box.MaxY;
        public static bool NewLine(OcrLine upper, OcrLine lower, double average)
        { var gap = Gap(upper, lower); return gap > 0 || Math.Abs(gap) <= Math.Max((upper.Box.Height + lower.Box.Height) / 2, average) * .4; }
        private double CharacterWidth(OcrLine line) => line.Box.Width * imageWidth / Math.Max(1, Traits.Length(line.Text) - (line.Text.Length > 0 && char.IsPunctuation(line.Text[^1]) ? .5 : 0));
        private double CharacterWidth(OcrLine line, OcrLine other, bool allowDifferent = false)
        { var own = CharacterWidth(line); return !allowDifferent && FontDifference(line, other) > 1.5 ? own : (own + CharacterWidth(other)) / 2; }
        private double Offset(OcrLine line, OcrLine reference, int edge = 0)
        { var delta = edge == 1 ? line.Box.MaxX - reference.Box.MaxX : edge == 2 ? line.Box.MidX - reference.Box.MidX : line.Box.MinX - reference.Box.MinX; return delta * imageWidth / Math.Max(.001, CharacterWidth(line, reference, true)); }
        public bool Indented(OcrLine line, OcrLine? reference = null, double strictness = 1) => (reference ?? Leftmost) is { } other && Offset(line, other) > 1.8 * strictness;
        public bool Aligned(OcrLine line, OcrLine reference, int edge = 0, double strictness = 1) => Math.Abs(Offset(line, reference, edge)) <= 1.8 * strictness;
        public bool Long(OcrLine line, OcrLine next, OcrLine? reference = null, double strictness = 1)
        {
            if ((reference ?? Rightmost) is not { } other) return false;
            var remaining = (other.Box.MaxX - line.Box.MaxX) * imageWidth / Math.Max(.001, CharacterWidth(line, other));
            double minimum;
            if (Spacing) { var text = next.Text.Trim(); minimum = text.Length == 0 ? 12 : Traits.Length(Traits.WordComponents(text).FirstOrDefault() ?? text) + 3; }
            else { minimum = 1.6; if (Chinese) { if (!Traits.EndsSentence(line.Text)) minimum += .7; if (next.Text.Length > 1 && !char.IsPunctuation(next.Text[0]) && char.IsPunctuation(next.Text[1])) minimum += .8; } }
            return remaining < minimum / strictness;
        }
        public bool Short(OcrLine line) => Widest is { } widest && line.Box.Width < widest.Box.Width * .5;
        public bool BigSpacing(OcrLine upper, OcrLine lower, double strictness = 1) => spacingThreshold > 0 && Gap(upper, lower) / spacingThreshold > strictness;
        private double FontDifference(OcrLine a, OcrLine b) => Math.Abs(fontSizes.GetValueOrDefault(a.Id, 13) - fontSizes.GetValueOrDefault(b.Id, 13));
        public bool DifferentFont(OcrLine a, OcrLine b, double strictness = 1) => a.Text.Count(char.IsLetter) >= 3 && b.Text.Count(char.IsLetter) >= 3 && FontDifference(a, b) >= (Chinese ? 4 : 5.5) * strictness;
        public bool ChineseCouplet(OcrLine a, OcrLine b)
        { var similarity = Traits.Similarity(a.Text, b.Text); return Chinese && (similarity >= .9 || similarity >= .7 && Traits.Length(a.Text) == Traits.Length(b.Text)) && Aligned(b, a) && Aligned(b, a, 1) && Traits.EndsSentence(a.Text) && Traits.EndsSentence(b.Text); }
    }
    private static class Traits
    {
        public static int Length(string text) => new StringInfo(text).LengthInTextElements;
        public static bool EndsSentence(string text) => text.Length > 0 && ".。?？!！;:：…".Contains(text[^1]);
        public static bool StartsLower(string text) => text.Length > 0 && char.IsLetter(text[0]) && char.IsLower(text[0]);
        public static bool StartsUpper(string text) => text.Length > 0 && char.IsLetter(text[0]) && char.IsUpper(text[0]);
        public static string FirstWord(string text) => text.Split(' ')[0];
        public static string LastWord(string text) => text.Split(' ')[^1];
        public static int Punctuation(string text, string excluded = "")
        { var rest = text; var count = 0; foreach (var mark in new[] { "...", "…" }) { var parts = rest.Split(mark, StringSplitOptions.None); count += parts.Length - 1; rest = string.Join("", parts); } return count + rest.Count(c => char.IsPunctuation(c) && !excluded.Contains(c)); }
        public static bool List(string text)
        { var line = text.TrimStart(); return Regex.IsMatch(line, @"^(?:[0-9]+[)）]|[0-9]+\.(?![0-9])|[a-gA-G][.)）]|[ivxIVX]+\.|[•\-*§¶►▪▫○●◦◾◽][ \t]|\[\p{N}+\][ \t])", RegexOptions.CultureInvariant); }
        public static IReadOnlyList<string> WordComponents(string text)
        {
            var words = new List<string>(); var current = new StringBuilder();
            void Flush() { if (current.Length > 0) { words.Add(current.ToString()); current.Clear(); } }
            foreach (var c in text) { if ((char.IsWhiteSpace(c) || char.IsPunctuation(c)) && !"@#/•\"-.".Contains(c)) Flush(); else if (c is >= '\u3400' and <= '\u9fff') { Flush(); words.Add(c.ToString()); } else current.Append(c); }
            Flush(); return words;
        }
        public static double Similarity(string a, string b)
        { var count = Math.Min(a.Length, b.Length); if (count == 0) return 0; var matches = 0; for (var i = 0; i < count; i++) { var x = char.IsPunctuation(a[i]); var y = char.IsPunctuation(b[i]); if (!x && !y || x && y && a[i] == b[i]) matches++; } return matches / (double)Math.Max(a.Length, b.Length); }
    }
}
