namespace Velos.Core.Recording;

/// <summary>移植自 ScreenRecorder.swift，使用同一时钟扣除已完成和正在进行的暂停区间。</summary>
public sealed class RecordingTimeline
{
    private readonly object sync = new();
    private readonly List<(TimeSpan Start, TimeSpan End)> pauses = [];
    private TimeSpan? start;
    private TimeSpan? pausedAt;

    public void Start(TimeSpan time) { lock (sync) start ??= time; }
    public void Pause(TimeSpan time) { lock (sync) pausedAt ??= time; }
    public void Resume(TimeSpan time)
    {
        lock (sync)
        {
            if (pausedAt is not { } paused) return;
            pauses.Add((paused, time));
            pausedAt = null;
        }
    }

    public TimeSpan? Adjusted(TimeSpan time)
    {
        lock (sync)
        {
            if (start is not { } origin || time < origin || pausedAt is { } current && time >= current) return null;
            var offset = TimeSpan.Zero;
            foreach (var pause in pauses)
            {
                if (time >= pause.End) offset += pause.End - pause.Start;
                else if (time >= pause.Start) return null;
            }
            return time - origin - offset;
        }
    }

    public TimeSpan Elapsed(TimeSpan time)
    {
        lock (sync)
        {
            if (start is not { } origin) return TimeSpan.Zero;
            var end = pausedAt ?? time;
            var offset = pauses.Where(pause => pause.End <= end).Aggregate(TimeSpan.Zero, (sum, pause) => sum + pause.End - pause.Start);
            return end > origin ? end - origin - offset : TimeSpan.Zero;
        }
    }
}
