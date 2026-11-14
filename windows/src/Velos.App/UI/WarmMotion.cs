using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Velos.Core.Animation;

namespace Velos.UI;

/// <summary>按 Mac 控件分别使用 response / damping；完成后释放时钟，不做空闲轮询。</summary>
public static class WarmMotion
{
    private static readonly ConditionalWeakTable<DependencyObject, Dictionary<DependencyProperty, object>> animations = new();
    private sealed record Running(SpringMotion Motion, AnimationClock Clock);
    private static readonly ConditionalWeakTable<DependencyObject, Dictionary<DependencyProperty, Running>> springs = new();
    private static readonly DependencyProperty ClosingProperty = DependencyProperty.RegisterAttached("Closing", typeof(bool), typeof(WarmMotion), new PropertyMetadata(false));
    private static readonly DependencyProperty FeedbackProperty = DependencyProperty.RegisterAttached("Feedback", typeof(bool), typeof(WarmMotion), new PropertyMetadata(false));
    internal static async void Copied(Button button)
    {
        if ((bool)button.GetValue(FeedbackProperty)) return; button.SetValue(FeedbackProperty, true);
        var content = button.Content; var hint = button.ToolTip;
        button.Content = new ActionIconView(ActionIcon.Check, 14); button.ToolTip = "已复制";
        await Task.Delay(900);
        if (button.IsLoaded) { button.Content = content; button.ToolTip = hint; }
        button.SetValue(FeedbackProperty, false);
    }
    public static bool Allowed => SystemParameters.ClientAreaAnimation && !SystemParameters.HighContrast;
    internal static bool IsClosing(Window window) => (bool)window.GetValue(ClosingProperty);
    public static readonly DependencyProperty PressedScaleProperty = DependencyProperty.RegisterAttached("PressedScale", typeof(double), typeof(WarmMotion), new PropertyMetadata(.95));
    public static void SetPressedScale(DependencyObject target, double value) => target.SetValue(PressedScaleProperty, value);
    public static double GetPressedScale(DependencyObject target) => (double)target.GetValue(PressedScaleProperty);
    public static readonly DependencyProperty EnabledProperty = DependencyProperty.RegisterAttached("Enabled", typeof(bool), typeof(WarmMotion), new PropertyMetadata(false, Enable));
    public static void SetEnabled(DependencyObject target, bool value) => target.SetValue(EnabledProperty, value);
    public static bool GetEnabled(DependencyObject target) => (bool)target.GetValue(EnabledProperty);
    private static void Enable(DependencyObject target, DependencyPropertyChangedEventArgs args)
    {
        if (target is not ButtonBase button || args.NewValue is not true) return;
        button.RenderTransformOrigin = new Point(.5, .5);
        var scale = new ScaleTransform(1, 1); button.RenderTransform = scale;
        void Update(object? sender, EventArgs e) {
            var value = button.IsPressed && button.IsEnabled ? GetPressedScale(button) : 1;
            Spring(scale, ScaleTransform.ScaleXProperty, value, .2, .7);
            Spring(scale, ScaleTransform.ScaleYProperty, value, .2, .7);
        }
        var descriptor = DependencyPropertyDescriptor.FromProperty(ButtonBase.IsPressedProperty, button.GetType());
        var listening = false;
        button.Loaded += (_, _) => { if (!listening) { descriptor.AddValueChanged(button, Update); listening = true; } };
        button.IsEnabledChanged += (_, _) => Update(button, EventArgs.Empty);
        button.Unloaded += (_, _) => {
            if (listening) { descriptor.RemoveValueChanged(button, Update); listening = false; }
            StopSpring(scale, ScaleTransform.ScaleXProperty); StopSpring(scale, ScaleTransform.ScaleYProperty);
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, null); scale.BeginAnimation(ScaleTransform.ScaleYProperty, null); scale.ScaleX = scale.ScaleY = 1;
            animations.Remove(scale);
        };
    }
    public static readonly DependencyProperty ToggleSwitchProperty = DependencyProperty.RegisterAttached("ToggleSwitch", typeof(bool), typeof(WarmMotion), new PropertyMetadata(false, EnableSwitch));
    public static void SetToggleSwitch(DependencyObject target, bool value) => target.SetValue(ToggleSwitchProperty, value);
    public static bool GetToggleSwitch(DependencyObject target) => (bool)target.GetValue(ToggleSwitchProperty);
    private static void EnableSwitch(DependencyObject target, DependencyPropertyChangedEventArgs args)
    {
        if (target is not CheckBox box || args.NewValue is not true) return;
        void Update(bool animate) {
            if (!box.IsLoaded) return;
            if (box.Template.FindName("Knob", box) is FrameworkElement knob && knob.RenderTransform is TranslateTransform transform) {
                if (transform.IsFrozen) { transform = transform.Clone(); knob.RenderTransform = transform; }
                Spring(transform, TranslateTransform.XProperty, box.IsChecked == true ? 15 : 0, .3, .68, animate);
            }
            if (box.Template.FindName("TrackAccent", box) is UIElement accent) SpringOpacity(accent, box.IsChecked == true ? 1 : 0, animate);
        }
        box.Loaded += (_, _) => Update(false); box.Checked += (_, _) => Update(true); box.Unchecked += (_, _) => Update(true);
        box.Unloaded += (_, _) => {
            if (box.Template.FindName("Knob", box) is FrameworkElement knob && knob.RenderTransform is TranslateTransform t) { StopSpring(t, TranslateTransform.XProperty); t.BeginAnimation(TranslateTransform.XProperty, null); }
            if (box.Template.FindName("TrackAccent", box) is UIElement accent) { StopSpring(accent, UIElement.OpacityProperty); animations.Remove(accent); accent.BeginAnimation(UIElement.OpacityProperty, null); }
        };
    }
    private static void SpringOpacity(UIElement element, double value, bool animate)
        => SpringValue(element, element, UIElement.OpacityProperty, value, .3, .68, animate, null, clampOpacity: true);
    public static void Animate(Animatable target, DependencyProperty property, double value, int milliseconds, double? from = null)
    {
        var start = from ?? (double)target.GetValue(property); StopSpring(target, property); var marker = Mark(target, property);
        target.BeginAnimation(property, null); target.SetValue(property, value);
        if (!Allowed || milliseconds <= 0 || Math.Abs(start - value) < .0001) { Forget(target, property, marker); return; }
        var animation = new DoubleAnimation(start, value, TimeSpan.FromMilliseconds(milliseconds)) { EasingFunction = new EaseOutCurve(), FillBehavior = FillBehavior.Stop };
        animation.Completed += (_, _) => { if (Forget(target, property, marker)) target.BeginAnimation(property, null); };
        target.BeginAnimation(property, animation, HandoffBehavior.SnapshotAndReplace);
    }
    public static void Spring(Animatable target, DependencyProperty property, double value, double response, double damping, bool animate = true, double? from = null)
        => SpringValue(target, target, property, value, response, damping, animate, from);
    private static void SpringValue(DependencyObject target, IAnimatable animated, DependencyProperty property, double value, double response, double damping, bool animate, double? from, bool clampOpacity = false)
    {
        var start = from ?? (double)target.GetValue(property); var velocity = from is null ? SpringVelocity(target, property) : 0;
        StopSpring(target, property); var marker = Mark(target, property);
        animated.BeginAnimation(property, null); target.SetValue(property, value);
        if (!Allowed || !animate || Math.Abs(start - value) < .0001 && Math.Abs(velocity) < .001) { Forget(target, property, marker); return; }
        var motion = new SpringMotion(start, value, velocity, response, damping);
        var animation = new SpringAnimation { Motion = motion, ClampOpacity = clampOpacity, Duration = TimeSpan.FromSeconds(motion.SettlingDuration), FillBehavior = FillBehavior.Stop };
        var clock = (AnimationClock)animation.CreateClock(true); springs.GetOrCreateValue(target)[property] = new(motion, clock);
        clock.Completed += (_, _) => {
            if (Forget(target, property, marker)) { springs.GetOrCreateValue(target).Remove(property); animated.ApplyAnimationClock(property, null); }
            clock.Controller?.Remove();
        };
        animated.ApplyAnimationClock(property, clock, HandoffBehavior.SnapshotAndReplace);
        clock.Controller?.Begin();
        clock.Controller?.SeekAlignedToLastTick(TimeSpan.Zero, TimeSeekOrigin.BeginTime);
    }
    internal static double SpringVelocity(DependencyObject target, DependencyProperty property) =>
        springs.TryGetValue(target, out var properties) && properties.TryGetValue(property, out var run) ? run.Motion.Sample(run.Clock.CurrentTime?.TotalSeconds ?? 0).Velocity : 0;
    private static void StopSpring(DependencyObject target, DependencyProperty property) {
        if (springs.TryGetValue(target, out var properties) && properties.Remove(property, out var run)) run.Clock.Controller?.Remove();
    }
    private static object Mark(DependencyObject target, DependencyProperty property)
    { var marker = new object(); animations.GetOrCreateValue(target)[property] = marker; return marker; }
    private static bool Forget(DependencyObject target, DependencyProperty property, object marker) {
        if (!animations.TryGetValue(target, out var properties) || !properties.TryGetValue(property, out var current) || !ReferenceEquals(current, marker)) return false;
        properties.Remove(property); return true;
    }
    private sealed class SpringAnimation : DoubleAnimationBase
    {
        internal SpringMotion Motion { get; init; } = new(0, 1, 0, .3, .68);
        internal bool ClampOpacity { get; init; }
        protected override double GetCurrentValueCore(double origin, double destination, AnimationClock clock) {
            var value = Motion.Sample(clock.CurrentTime?.TotalSeconds ?? 0).Value;
            return ClampOpacity ? Math.Clamp(value, 0, 1) : value;
        }
        protected override Freezable CreateInstanceCore() => new SpringAnimation { Motion = Motion, ClampOpacity = ClampOpacity };
    }
    internal sealed class EaseOutCurve : EasingFunctionBase
    {
        protected override double EaseInCore(double normalizedTime) => SpringMotion.EaseOut(normalizedTime);
        protected override Freezable CreateInstanceCore() => new EaseOutCurve();
    }
    public static void Fade(UIElement element, double opacity, int milliseconds = 150, double? from = null)
    {
        var start = from ?? element.Opacity; var marker = Mark(element, UIElement.OpacityProperty);
        element.BeginAnimation(UIElement.OpacityProperty, null); element.Opacity = opacity;
        if (!Allowed || milliseconds <= 0 || Math.Abs(start - opacity) < .001) { Forget(element, UIElement.OpacityProperty, marker); return; }
        var animation = new DoubleAnimation(start, opacity, TimeSpan.FromMilliseconds(milliseconds)) { FillBehavior = FillBehavior.Stop, EasingFunction = new EaseOutCurve() };
        animation.Completed += (_, _) => { if (Forget(element, UIElement.OpacityProperty, marker)) element.BeginAnimation(UIElement.OpacityProperty, null); };
        element.BeginAnimation(UIElement.OpacityProperty, animation, HandoffBehavior.SnapshotAndReplace);
    }
    public static void SelectNavigation(TranslateTransform transform, double y, bool animate, bool horizontal = false) =>
        Spring(transform, horizontal ? TranslateTransform.XProperty : TranslateTransform.YProperty, y, horizontal ? .32 : .34, horizontal ? .74 : .8, animate);
    internal static void BounceSymbol(FrameworkElement icon)
    {
        if (!Allowed) return;
        if (icon.RenderTransform is not TranslateTransform transform) icon.RenderTransform = transform = new TranslateTransform();
        var start = transform.Y; var marker = Mark(transform, TranslateTransform.YProperty);
        transform.BeginAnimation(TranslateTransform.YProperty, null); transform.Y = 0;
        var animation = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromMilliseconds(480), FillBehavior = FillBehavior.Stop };
        animation.KeyFrames.Add(new DiscreteDoubleKeyFrame(start, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        foreach (var (value, milliseconds) in new[] { (-2.5, 140), (.6, 280), (-.2, 380), (0d, 480) })
            animation.KeyFrames.Add(new EasingDoubleKeyFrame(value, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(milliseconds)), new EaseOutCurve()));
        animation.Completed += (_, _) => { if (Forget(transform, TranslateTransform.YProperty, marker)) transform.BeginAnimation(TranslateTransform.YProperty, null); };
        transform.BeginAnimation(TranslateTransform.YProperty, animation, HandoffBehavior.SnapshotAndReplace);
    }
    public static void EnterWindow(Window window) => Fade(window, 1, 200, 0);
    public static void CloseWindow(Window window)
    {
        if ((bool)window.GetValue(ClosingProperty)) return; window.SetValue(ClosingProperty, true);
        ThumbnailShelf.Dismiss(window);
        if (!Allowed || !window.IsVisible) { window.Close(); return; }
        window.IsHitTestVisible = false;
        var animation = new DoubleAnimation(window.Opacity, 0, TimeSpan.FromMilliseconds(150)) { FillBehavior = FillBehavior.Stop, EasingFunction = new EaseOutCurve() };
        animation.Completed += (_, _) => window.Close(); window.BeginAnimation(UIElement.OpacityProperty, animation);
    }
}
