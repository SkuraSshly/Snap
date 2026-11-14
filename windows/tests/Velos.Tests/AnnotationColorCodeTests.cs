using Velos.Core.Screenshot;

internal static class AnnotationColorCodeTests
{
    public static IEnumerable<(string, Action)> Cases(Action<bool, string> check)
    {
        yield return ("Mac 调色盘：颜色代码与末尾 alpha", () =>
        {
            foreach (var code in new[] { "#FF5533", "ff5533", "#F53", "0xFF5533", "rgb(255,85,51)" })
                check(AnnotationColorCode.Parse(code) == new AnnotationColor(0xff5533, null), code);
            check(AnnotationColorCode.Parse("#FF553380") == new AnnotationColor(0xff5533, 128 / 255d), "alpha 在末尾");
            check(AnnotationColorCode.Parse("rgba(255, 85, 51, 0.35)") == new AnnotationColor(0xff5533, .35), "rgba 保留不透明度");
        });
        yield return ("Mac 调色盘：无效或越界代码不应用", () =>
        {
            foreach (var code in new[] { "", "#FFFF", "#GG5533", "rgb(256,0,0)", "rgba(1,2,3,1.1)", "rgb(NaN,2,3)", "rgb(1,2)", "secret" })
                check(AnnotationColorCode.Parse(code) is null, code);
        });
    }
}
