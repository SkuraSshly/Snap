using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Velos.Core.Translation;
using OcrLine = Velos.Core.Translation.OcrLine;

namespace Velos.Windows.Translation;

public sealed record RecognitionResult(string Text, string? Language, string? Error = null);

public static class OfflineOcr
{
    public static IReadOnlyList<(string Code, string Name)> Languages() => OcrEngine.AvailableRecognizerLanguages.Select(language => (language.LanguageTag, language.NativeName)).ToArray();
    public static TranslateLanguage? DetectLanguage(string text)
    {
        var detected = LanguageDetector.Detect(text) ?? LanguageRules.DetectScript(text);
        var han = new string(text.Where(c => c is >= '\u3400' and <= '\u9fff').ToArray());
        TranslateLanguage ChineseVariant() {
            var simplified = NormalizeChinese(han, TranslateLanguage.Chinese);
            var changed = han.Zip(simplified).Count(pair => pair.First != pair.Second);
            return (double)(han.Length - changed) / Math.Max(1, han.Length) >= .9 ? TranslateLanguage.Chinese : TranslateLanguage.All[1];
        }
        if (detected?.IsChinese == true && han.Length > 0) return ChineseVariant();
        if (detected == TranslateLanguage.English && han.Length > 0) {
            var words = System.Text.RegularExpressions.Regex.Matches(text, @"[A-Za-z]+(?:['-][A-Za-z]+)*").Count;
            if (words <= han.Length) return ChineseVariant();
        }
        return detected;
    }
    public static async Task<RecognitionResult> Recognize(byte[] bgra, int width, int height, string? preferred, bool smartLayout, CancellationToken token, double pixelScale = 1, bool bestCandidates = true)
    {
        if (width < 1 || height < 1 || bgra.Length != checked(width * height * 4) || !double.IsFinite(pixelScale) || pixelScale <= 0) throw new ArgumentException("识别图片尺寸无效。");
        var installed = OcrEngine.AvailableRecognizerLanguages;
        if (installed.Count == 0) throw new InvalidOperationException("没有可用的文字识别语言包。请在 Windows 设置 › 时间和语言 › 语言中安装所需语言的光学字符识别组件。");
        var choices = new List<Language>();
        void Add(string? tag) {
            var wanted = TranslateLanguage.FromLocale(tag); if (wanted is null) return;
            var available = installed.FirstOrDefault(language => language.LanguageTag.Equals(tag, StringComparison.OrdinalIgnoreCase))
                ?? installed.FirstOrDefault(language => TranslateLanguage.FromLocale(language.LanguageTag) == wanted);
            if (available is not null && !choices.Any(language => TranslateLanguage.FromLocale(language.LanguageTag) == wanted)) choices.Add(available);
        }
        // 与 Mac preferredLanguages 相同：优先，不是强制单一语言。
        Add(preferred); foreach (var tag in ApplicationLanguages.Languages) Add(tag);
        foreach (var tag in new[] { "zh-Hans", "en", "ja", "zh-Hant", "ko" }) Add(tag);
        if (choices.Count == 0) choices.Add(installed[0]);
        var candidates = new List<(string Text, TranslateLanguage? Language, int Letters, bool Trusted)>();
        for (var index = 0; index < choices.Count && index < (bestCandidates ? 6 : 1); index++)
        {
            token.ThrowIfCancellationRequested(); var language = choices[index]; var engine = OcrEngine.TryCreateFromLanguage(language); if (engine is null) continue;
            IReadOnlyList<OcrLine> lines;
            try { lines = await RecognizeLines(engine, bgra, width, height, token); }
            catch (COMException) when (index > 0) { continue; }
            var rough = string.Join('\n', lines.Select(line => line.Text)); var detected = DetectLanguage(rough) ?? TranslateLanguage.FromLocale(language.LanguageTag);
            var text = rough;
            if (smartLayout && lines.Count > 0) {
                using var native = new OcrTextServices(detected);
                text = new OcrLayoutComposer(width / pixelScale, null, DetectLanguage, native.Measure13, native.Spelled, native.CountWords).Compose(lines);
            }
            var letters = text.Count(char.IsLetterOrDigit);
            candidates.Add((text, detected, letters, detected == TranslateLanguage.FromLocale(language.LanguageTag)));
            // 检测出的语种即使不在系统首选里，也应作为下一候选；避免法文等一律按英语处理。
            var before = choices.Count; Add(detected?.Code);
            if (choices.Count > before) { var item = choices[^1]; choices.RemoveAt(choices.Count - 1); choices.Insert(index + 1, item); }
            // 长文在 Mac 中不进入短文本的多候选流程。Windows 单语模型发现另一语种时，
            // 最多再给对应已安装模型一次机会，不让每次整屏识别都跑完六个模型。
            if (new System.Globalization.StringInfo(rough).LengthInTextElements > 50 &&
                (detected == TranslateLanguage.FromLocale(language.LanguageTag) || index > 0 || !choices.Skip(index + 1).Any(choice => TranslateLanguage.FromLocale(choice.LanguageTag) == detected))) break;
        }
        if (candidates.Count == 0) return new RecognitionResult("", null);
        var minimumLetters = candidates[0].Letters;
        var complete = candidates.Where(candidate => candidate.Letters >= minimumLetters * .9 && OcrCandidateRules.KeepsScripts(candidates[0].Text, candidate.Text)).ToArray();
        var trusted = complete.Where(candidate => candidate.Trusted).ToArray();
        var best = (trusted.Length > 0 ? trusted : complete).OrderByDescending(candidate => candidate.Letters).First();
        return new RecognitionResult(best.Text.Trim(), best.Language?.Code);
    }
    private static async Task<IReadOnlyList<OcrLine>> RecognizeLines(OcrEngine engine, byte[] bgra, int width, int height, CancellationToken token)
    {
        var maximum = (int)OcrEngine.MaxImageDimension; var overlap = Math.Min(256, maximum / 4);
        var step = Math.Max(1, maximum - overlap);
        var fragments = new List<(string Text, double X, double Y, double Width, double Height)>();
        for (var top = 0; top < height; top += step)
        {
            var tileHeight = Math.Min(maximum, height - top);
            for (var left = 0; left < width; left += step)
            {
                token.ThrowIfCancellationRequested(); var tileWidth = Math.Min(maximum, width - left);
                var pixels = new byte[checked(tileWidth * tileHeight * 4)];
                for (var row = 0; row < tileHeight; row++) Buffer.BlockCopy(bgra, checked(((top + row) * width + left) * 4), pixels, row * tileWidth * 4, tileWidth * 4);
                using var bitmap = new SoftwareBitmap(BitmapPixelFormat.Bgra8, tileWidth, tileHeight, BitmapAlphaMode.Ignore); bitmap.CopyFromBuffer(pixels.AsBuffer());
                var result = await engine.RecognizeAsync(bitmap).AsTask(token);
                foreach (var line in result.Lines) {
                    var words = line.Words.Where(word => {
                        var centerX = word.BoundingRect.X + word.BoundingRect.Width / 2;
                        var centerY = word.BoundingRect.Y + word.BoundingRect.Height / 2;
                        return (left == 0 || centerX >= overlap / 2d) && (left + tileWidth >= width || centerX < tileWidth - overlap / 2d)
                            && (top == 0 || centerY >= overlap / 2d) && (top + tileHeight >= height || centerY < tileHeight - overlap / 2d);
                    }).ToArray();
                    if (words.Length == 0) continue;
                    var x = words.Min(word => word.BoundingRect.X) + left; var y = words.Min(word => word.BoundingRect.Y) + top;
                    var right = words.Max(word => word.BoundingRect.Right) + left; var bottom = words.Max(word => word.BoundingRect.Bottom) + top;
                    var raw = string.Join(" ", words.Select(word => word.Text)); var language = DetectLanguage(raw);
                    var builder = new System.Text.StringBuilder(words[0].Text);
                    foreach (var word in words.Skip(1)) {
                        var previous = builder.Length > 0 ? builder[^1] : ' '; var next = word.Text.FirstOrDefault();
                        bool LatinOrNumber(char value) => char.IsLetterOrDigit(value) && value < '\u2e80';
                        if (language?.NeedsWordSpacing != false || LatinOrNumber(previous) && LatinOrNumber(next)) builder.Append(' ');
                        builder.Append(word.Text);
                    }
                    var text = builder.ToString();
                    fragments.Add((text, x, y, right - x, bottom - y));
                }
                if (left + tileWidth >= width) break;
            }
            if (top + tileHeight >= height) break;
        }
        // 大于系统单次上限的图只分块识别，绝不把原生截图缩小再识别。
        // 将横跨分块边缘的同一行接回，重叠区按词中心归属，避免重复文字。
        var merged = new List<(string Text, double X, double Y, double Width, double Height)>();
        if (width <= maximum) return fragments.Select((line, id) => new OcrLine(id, line.Text,
            new OcrBox(line.X / width, (height - line.Y - line.Height) / height, line.Width / width, line.Height / height))).ToArray();
        foreach (var fragment in fragments.OrderBy(item => item.Y).ThenBy(item => item.X)) {
            var target = merged.FindIndex(previous => {
                var vertical = Math.Min(previous.Y + previous.Height, fragment.Y + fragment.Height) - Math.Max(previous.Y, fragment.Y);
                var gap = fragment.X - previous.X - previous.Width;
                return vertical >= Math.Min(previous.Height, fragment.Height) * .6 && gap >= -2 && gap <= Math.Max(previous.Height, fragment.Height) * 1.5;
            });
            if (target < 0) merged.Add(fragment);
            else {
                var previous = merged[target]; var text = DetectLanguage(previous.Text + fragment.Text)?.NeedsWordSpacing == false ? previous.Text + fragment.Text : previous.Text + " " + fragment.Text;
                var y = Math.Min(previous.Y, fragment.Y); merged[target] = (text, previous.X, y, fragment.X + fragment.Width - previous.X, Math.Max(previous.Y + previous.Height, fragment.Y + fragment.Height) - y);
            }
        }
        return merged.Select((line, id) => new OcrLine(id, line.Text, new OcrBox(line.X / width, (height - line.Y - line.Height) / height, line.Width / width, line.Height / height))).ToArray();
    }
    public static string NormalizeChinese(string text, TranslateLanguage language)
    {
        if (!language.IsChinese || text.Length == 0) return text;
        var flag = language.Code == "zh-Hans" ? 0x02000000u : 0x04000000u;
        var count = LCMapStringEx("zh-CN", flag, text, text.Length, null, 0, 0, 0, 0);
        if (count < 1) return text; var output = new char[count];
        return LCMapStringEx("zh-CN", flag, text, text.Length, output, output.Length, 0, 0, 0) > 0 ? new string(output) : text;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern int LCMapStringEx(string locale, uint flags, string source, int length, [Out] char[]? destination, int capacity, nint version, nint reserved, nint sort);
}
