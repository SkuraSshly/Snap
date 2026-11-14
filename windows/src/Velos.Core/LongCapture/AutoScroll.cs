using System.Drawing;

namespace Velos.Core.LongCapture;

/// <summary>与 Mac 2.3 自动滚动状态机保持一致；时钟、鼠标和实际输入由平台层提供。</summary>
public sealed class AutoScroll(RectangleF region)
{
    public static class Tuning
    {
        public const double RegionsPerSecond = .33, MinSpeed = 150, MaxSpeed = 450, TicksPerSecond = 60;
        public const double StallSeconds = 1.2, PointerSlack = 4;
        public const int BackwardFrames = 3;
    }
    public enum Status { Running, Paused, Stopped }
    public enum Reason { User, ReachedEnd, Limit, Unavailable }
    public Status State { get; private set; } = Status.Stopped;
    public Reason StopReason { get; private set; } = Reason.User;
    public bool Active => State != Status.Stopped;
    public double Speed { get; } = Math.Clamp(region.Height * Tuning.RegionsPerSecond, Tuning.MinSpeed, Tuning.MaxSpeed);
    public event Action? Changed;
    private int direction = 1, backwardFrames;
    private bool sawProgress;
    private double carry, lastProgress;
    private PointF? progressPointer;

    public void Start(PointF pointer, double now)
    {
        if (Active) return;
        direction = 1; sawProgress = false; backwardFrames = 0; carry = 0; lastProgress = now; progressPointer = null;
        Set(region.Contains(pointer) ? Status.Running : Status.Paused);
    }

    public void Stop(Reason reason = Reason.User)
    {
        var changedReason = StopReason != reason; StopReason = reason;
        if (State == Status.Stopped) { if (changedReason) Changed?.Invoke(); }
        else Set(Status.Stopped);
    }

    public void NoteMotion(int shift, PointF pointer, double now)
    {
        if (State != Status.Running) return;
        if (shift > 0)
        { sawProgress = true; backwardFrames = 0; lastProgress = now; progressPointer = pointer; }
        else if (shift < 0 && !sawProgress && ++backwardFrames >= Tuning.BackwardFrames)
        { backwardFrames = 0; direction = -direction; }
    }

    /// <returns>本拍向下滚动的 DIP 数，负数用于纠正方向。</returns>
    public int Tick(PointF pointer, double now)
    {
        if (!Active) return 0;
        if (!region.Contains(pointer)) { Set(Status.Paused); lastProgress = now; return 0; }
        if (State == Status.Paused) Set(Status.Running);
        if (progressPointer is { } spot && now - lastProgress > Tuning.StallSeconds &&
            Math.Pow(pointer.X - spot.X, 2) + Math.Pow(pointer.Y - spot.Y, 2) <= Tuning.PointerSlack * Tuning.PointerSlack)
        { Stop(Reason.ReachedEnd); return 0; }
        carry += Speed / Tuning.TicksPerSecond;
        var step = (int)carry; carry -= step;
        return step * direction;
    }

    private void Set(Status next)
    { if (State == next) return; State = next; Changed?.Invoke(); }
}
