using Velos.Core.Screenshot;

internal static class RoundedCornersTests
{
    public static IEnumerable<(string, Action)> Cases(Action<bool, string> check)
    {
        yield return ("Mac 2.2 圆角：DIP 转物理半径与短边限制", () =>
        {
            check(RoundedCorners.PhysicalRadius(12, 1.5, 100, 80) == 18, "原生比例");
            check(RoundedCorners.PhysicalRadius(80, 2, 30, 20) == 10, "限制 40 DIP 和短边一半");
            check(RoundedCorners.PhysicalRadius(double.NaN, 2, 30, 20) == 0, "无效设置安全回落");
        });
        yield return ("Mac 2.2 圆角：四角透明、内部原样、对称抗锯齿", () =>
        {
            var pixels = new byte[100 * 80 * 4];
            for (var i = 0; i < pixels.Length; i += 4) { pixels[i] = 41; pixels[i + 1] = 83; pixels[i + 2] = 127; pixels[i + 3] = 255; }
            RoundedCorners.Apply(pixels, 100, 80, 18);
            foreach (var index in new[] { 0, 99, 79 * 100, 80 * 100 - 1 }) check(pixels[index * 4 + 3] == 0 && pixels[index * 4 + 2] == 0, "透明角不残留不可见颜色");
            check(pixels[(40 * 100 + 50) * 4] == 41 && pixels[(40 * 100 + 50) * 4 + 3] == 255, "中心原像素");
            check(Enumerable.Range(0, pixels.Length / 4).Any(i => pixels[i * 4 + 3] is > 0 and < 255), "存在抗锯齿像素");
            for (var y = 0; y < 18; y++) for (var x = 0; x < 18; x++) check(pixels[(y * 100 + x) * 4 + 3] == pixels[(y * 100 + 99 - x) * 4 + 3], "左右对称");
        });
        yield return ("Mac 2.2 圆角：极小图像不重复乘透明度，直角不改像素", () =>
        {
            byte[] pixel = [20, 40, 60, 255]; RoundedCorners.Apply(pixel, 1, 1, .5);
            check(pixel[3] == 191, "1x1 圆形的 16 个子像素中有 12 个在内");
            byte[] original = [20, 40, 60, 255]; RoundedCorners.Apply(original, 1, 1, 0); check(original.SequenceEqual(new byte[] {20,40,60,255}), "直角无重采样");
        });
    }
}
