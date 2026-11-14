using System.Drawing;

namespace Velos.Core.Recording;

/// <summary>仅用于用户选择的 1080p 输出；原生录屏保持输入字节。</summary>
public sealed class VideoScaler
{
    private readonly Size input, output;
    private readonly int[] xs, ys, xWeights, yWeights;
    public VideoScaler(Size input, Size output)
    {
        this.input = input; this.output = output;
        xs = new int[output.Width]; ys = new int[output.Height]; xWeights = new int[output.Width]; yWeights = new int[output.Height];
        Map(input.Width, output.Width, xs, xWeights); Map(input.Height, output.Height, ys, yWeights);
    }
    private static void Map(int source, int target, int[] positions, int[] weights)
    {
        for (var i = 0; i < target; i++) { var at = Math.Clamp((i + .5) * source / target - .5, 0, source - 1d);
            positions[i] = (int)at; weights[i] = (int)Math.Round((at - positions[i]) * 256); }
    }
    public byte[] Scale(byte[] source)
    {
        if (input == output) return source;
        if (source.Length != checked(input.Width * input.Height * 4)) throw new ArgumentException("录屏帧尺寸变化。");
        var result = new byte[checked(output.Width * output.Height * 4)];
        Parallel.For(0, output.Height, y =>
        {
            var top = ys[y] * input.Width * 4; var bottom = Math.Min(ys[y] + 1, input.Height - 1) * input.Width * 4;
            var dy = yWeights[y]; var row = y * output.Width * 4;
            for (var x = 0; x < output.Width; x++)
            {
                var left = xs[x] * 4; var right = Math.Min(xs[x] + 1, input.Width - 1) * 4; var dx = xWeights[x];
                for (var c = 0; c < 3; c++)
                {
                    var a = source[top + left + c] * (256 - dx) + source[top + right + c] * dx;
                    var b = source[bottom + left + c] * (256 - dx) + source[bottom + right + c] * dx;
                    result[row + x * 4 + c] = (byte)((a * (256 - dy) + b * dy + 32768) >> 16);
                }
                result[row + x * 4 + 3] = 255;
            }
        });
        return result;
    }
}
