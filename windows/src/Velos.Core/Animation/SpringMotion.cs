namespace Velos.Core.Animation;

public readonly record struct SpringSample(double Value, double Velocity);

/// <summary>以秒为单位的阻尼弹簧；response 控制固有周期，damping 为临界阻尼比例。</summary>
public sealed class SpringMotion(double start, double target, double velocity, double response, double damping)
{
    private readonly double frequency = 2 * Math.PI / Math.Max(.01, response);
    private readonly double ratio = Math.Clamp(damping, .01, .9999);
    public double SettlingDuration {
        get {
            var a = ratio * frequency; var b = frequency * Math.Sqrt(1 - ratio * ratio);
            var displacement = start - target; var sine = (velocity + a * displacement) / b;
            var amplitude = Math.Sqrt(displacement * displacement + sine * sine);
            return Math.Max(.01, Math.Log(Math.Max(1, amplitude / (.001 * Math.Max(1, Math.Abs(displacement))))) / a);
        }
    }
    public SpringSample Sample(double seconds)
    {
        if (seconds <= 0) return new(start, velocity);
        var a = ratio * frequency; var b = frequency * Math.Sqrt(1 - ratio * ratio);
        var x = start - target; var sine = (velocity + a * x) / b;
        var decay = Math.Exp(-a * seconds); var cos = Math.Cos(b * seconds); var sin = Math.Sin(b * seconds);
        return new(target + decay * (x * cos + sine * sin),
            decay * ((-a * x + b * sine) * cos + (-a * sine - b * x) * sin));
    }
    /// <summary>Core Animation easeOut 的 (0,0,.58,1) 曲线。</summary>
    public static double EaseOut(double progress)
    {
        if (progress <= 0) return 0; if (progress >= 1) return 1;
        var low = 0d; var high = 1d;
        for (var i = 0; i < 24; i++) {
            var t = (low + high) / 2; var x = 3 * (1 - t) * t * t * .58 + t * t * t;
            if (x < progress) low = t; else high = t;
        }
        var u = (low + high) / 2; return 3 * (1 - u) * u * u + u * u * u;
    }
}
