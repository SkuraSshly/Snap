using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;

namespace Velos.UI;

internal enum ActionIcon { Rectangle, Ellipse, Arrow, Line, Pen, Highlighter, Text, Counter, Mosaic, Blur, Pointer, Translate, FrameRate, Resolution, Quality, Gif, Record, Microphone, MicrophoneOff, Volume, Mute, Save, Copy, Pin, Unpin, Play, Pause, Stop, Undo, Redo, Close, Check, FillRectangle, FillEllipse, FillText, Palette, Minimize, Expand, Settings, Capture, Keyboard, Power, Tray, Folder, Delete, Switch, ChevronDown, Fullscreen, Edit, WindowMaximize, WindowRestore, PointerOff, PinFilled }

/// <summary>统一光学尺寸、圆端点与线重的原创几何图标；按动作含义对应 Mac，不提取或描摹 SF Symbols。</summary>
internal sealed class ActionIconView : FrameworkElement
{
    public static readonly DependencyProperty InkProperty = DependencyProperty.Register(nameof(Ink), typeof(Brush), typeof(ActionIconView), new FrameworkPropertyMetadata(Brushes.Black, FrameworkPropertyMetadataOptions.AffectsRender));
    public Brush Ink { get => (Brush)GetValue(InkProperty); set => SetValue(InkProperty, value); }
    public ActionIcon Kind { get; }
    public ActionIconView(ActionIcon kind, double size = 16)
    {
        Kind = kind; Width = Height = size; IsHitTestVisible = false;
        UseLayoutRounding = true; SnapsToDevicePixels = true;
        VerticalAlignment = VerticalAlignment.Center; HorizontalAlignment = HorizontalAlignment.Center;
        SetBinding(InkProperty, new Binding("Foreground") { RelativeSource = new RelativeSource(RelativeSourceMode.FindAncestor, typeof(Control), 1) });
    }
    internal static ActionIcon? FromGlyph(string glyph) => glyph switch
    {
        "\ue711" or "\ue8bb" => ActionIcon.Close, "\ue73e" => ActionIcon.Check,
        "\ue7a7" => ActionIcon.Undo, "\ue7a6" => ActionIcon.Redo, "\ue76d" => ActionIcon.Pen, "\ue7e6" => ActionIcon.Highlighter,
        "\ue718" => ActionIcon.Pin, "\ue77a" => ActionIcon.Unpin, "\ue74e" or "\ue896" => ActionIcon.Save, "\ue8c8" => ActionIcon.Copy,
        "\ue7c8" or "\ue714" => ActionIcon.Record, "\ue720" => ActionIcon.Microphone, "\uec54" => ActionIcon.MicrophoneOff,
        "\ue767" => ActionIcon.Volume, "\ue74f" => ActionIcon.Mute, "\ue768" => ActionIcon.Play, "\ue769" => ActionIcon.Pause, "\ue71a" => ActionIcon.Stop,
        "\ue713" => ActionIcon.Settings, "\ue722" => ActionIcon.Capture, "\ue765" => ActionIcon.Keyboard, "\ue8f2" => ActionIcon.Translate,
        "\ue8b7" => ActionIcon.Folder, "\ue74d" => ActionIcon.Delete, "\ue8ab" => ActionIcon.Switch, "\ue70d" => ActionIcon.ChevronDown,
        "\ue740" => ActionIcon.Fullscreen, "\ue70f" => ActionIcon.Edit, "\ue921" => ActionIcon.Minimize, "\ue922" => ActionIcon.Expand,
        "\ue7e8" => ActionIcon.Power, "\ue737" => ActionIcon.Tray, _ => null
    };
    protected override void OnRender(DrawingContext dc)
    {
        var size = Math.Min(ActualWidth, ActualHeight); if (size <= 0) return;
        dc.PushTransform(new ScaleTransform(size / 20, size / 20));
        var pen = new Pen(Ink, 1.85) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        void Line(double x, double y, double a, double b) => dc.DrawLine(pen, new Point(x, y), new Point(a, b));
        void Text(string text, double x, double y, double font = 12) => dc.DrawText(new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface(WarmTheme.Text, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal), font, Ink, 1), new Point(x, y));
        void Path(string path) => dc.DrawGeometry(null, pen, Shape(path));
        switch (Kind)
        {
            case ActionIcon.Rectangle: dc.DrawRoundedRectangle(null, pen, new Rect(2.8, 4.3, 14.4, 11.4), 2, 2); break;
            case ActionIcon.Ellipse: dc.DrawEllipse(null, pen, new Point(10, 10), 6.8, 6.8); break;
            case ActionIcon.Line: Line(4, 16, 16, 4); break;
            case ActionIcon.Arrow: Line(4, 16, 16, 4); Line(9, 4, 16, 4); Line(16, 4, 16, 11); break;
            case ActionIcon.Pen: Path("M 2.8,13.5 C 7.5,6 12.1,1.2 10.8,5.6 C 9.4,9.9 5.2,16.6 7.3,14.7 C 9.2,13 14,7.6 13,11.1 C 12,14.5 11.4,17.7 17.3,12.6"); break;
            case ActionIcon.Highlighter: Path("M 5.3,12.2 L 12.2,4.1 Q 13,3.2 13.9,4 L 16,5.8 Q 16.9,6.6 16.1,7.5 L 9.2,15.6 Z M 5.3,12.2 L 3.1,16.8 L 5.8,17.4 L 9.2,15.6 M 3,18.2 L 14,18.2"); break;
            case ActionIcon.Text: dc.DrawRoundedRectangle(null, pen, new Rect(2.8, 2.8, 14.4, 14.4), 2.1, 2.1); Line(6.3, 6.3, 13.7, 6.3); Line(10, 6.3, 10, 13.8); break;
            case ActionIcon.Counter: dc.DrawEllipse(null, pen, new Point(10, 10), 7.2, 7.2); Path("M 8,7.3 L 10.3,5.9 L 10.3,14 M 8.1,14 L 12.5,14"); break;
            case ActionIcon.Mosaic:
                dc.DrawRoundedRectangle(null, pen, new Rect(2.5, 4, 15, 12), 1.3, 1.3);
                dc.PushClip(new RectangleGeometry(new Rect(2.5, 4, 15, 12), 1.3, 1.3));
                for (var y = 0; y < 3; y++) for (var x = 0; x < 4; x++) if ((x + y) % 2 == 0) dc.DrawRectangle(Ink, null, new Rect(2.5 + x * 3.75, 4 + y * 4, 3.75, 4)); break;
            case ActionIcon.Blur:
                var drop = Geometry.Parse("M 10,2 C 8,5 4,8 4,12 A 6,6 0 0 0 16,12 C 16,8 12,5 10,2 Z");
                dc.PushClip(new RectangleGeometry(new Rect(0, 0, 10, 20))); dc.DrawGeometry(Ink, null, drop); dc.Pop(); dc.DrawGeometry(null, pen, drop); break;
            case ActionIcon.Pointer:
            case ActionIcon.PointerOff:
                dc.DrawGeometry(Kind == ActionIcon.Pointer ? Ink : null, Kind == ActionIcon.PointerOff ? pen : null, Shape("M 4,2 L 4,16 L 8.4,12 L 11,18 L 13.4,17 L 10.8,11 L 17,11 Z"));
                if (Kind == ActionIcon.PointerOff) Line(3, 3, 17, 17); break;
            case ActionIcon.Translate:
                dc.DrawGeometry(null, pen, Geometry.Parse("M 4,3 L 16,3 Q 18,3 18,5 L 18,13 Q 18,15 16,15 L 9,15 L 5,18 L 5,15 L 4,15 Q 2,15 2,13 L 2,5 Q 2,3 4,3 Z")); Text("A", 3.8, 3.8, 9); Text("文", 10, 5, 8); break;
            case ActionIcon.FrameRate: dc.DrawEllipse(null, pen, new Point(10, 10), 7.6, 7.6); Line(10, 10, 14, 6); dc.DrawEllipse(Ink, null, new Point(10, 10), 1.2, 1.2); Line(4.5, 12, 6, 11); Line(7, 5, 8, 7); break;
            case ActionIcon.Resolution: dc.DrawRoundedRectangle(null, pen, new Rect(2, 4, 16, 12), 1.8, 1.8); Line(6.5, 4, 6.5, 16); Line(6.5, 8.5, 18, 8.5); break;
            case ActionIcon.Quality: Line(5, 3, 5, 17); Line(10, 3, 10, 17); Line(15, 3, 15, 17); dc.DrawEllipse(Ink, null, new Point(5, 7), 2, 2); dc.DrawEllipse(Ink, null, new Point(10, 12), 2, 2); dc.DrawEllipse(Ink, null, new Point(15, 6), 2, 2); break;
            case ActionIcon.Close: Line(5, 5, 15, 15); Line(15, 5, 5, 15); break;
            case ActionIcon.Check: Path("M 3.7,10.1 L 8,14.3 L 16.5,5.5"); break;
            case ActionIcon.Undo: Path("M 7,3.5 L 3.5,7 L 7,10.5 M 3.5,7 L 11.5,7 C 18.5,7 18.5,16.5 11.5,16.5 L 9.5,16.5"); break;
            case ActionIcon.Redo: Path("M 13,3.5 L 16.5,7 L 13,10.5 M 16.5,7 L 8.5,7 C 1.5,7 1.5,16.5 8.5,16.5 L 10.5,16.5"); break;
            case ActionIcon.Save: Path("M 4,7 L 4,16 Q 4,17 5,17 L 15,17 Q 16,17 16,16 L 16,7 M 10,2.5 L 10,12 M 6.8,9 L 10,12.2 L 13.2,9"); break;
            case ActionIcon.Copy: dc.DrawRoundedRectangle(null, pen, new Rect(7, 3, 10, 11), 2, 2); Path("M 12,17 L 5,17 Q 3,17 3,15 L 3,8"); break;
            case ActionIcon.Pin:
            case ActionIcon.Unpin:
            case ActionIcon.PinFilled:
                dc.PushTransform(new RotateTransform(45, 10, 10));
                var head = Shape("M 7,3.5 L 13,3.5 L 12,8.2 L 14.1,11.4 L 5.9,11.4 L 8,8.2 Z");
                dc.DrawGeometry(Kind == ActionIcon.Pin ? null : Ink, pen, head); Line(10, 11.5, 10, 17.8); dc.Pop(); break;
            case ActionIcon.Record: dc.DrawEllipse(null, pen, new Point(10, 10), 7.2, 7.2); dc.DrawEllipse(Ink, null, new Point(10, 10), 3.5, 3.5); break;
            case ActionIcon.Microphone:
            case ActionIcon.MicrophoneOff:
                dc.DrawRoundedRectangle(null, pen, new Rect(7.2, 2.5, 5.6, 9.5), 2.8, 2.8); Path("M 4.8,9.3 L 4.8,10.3 C 4.8,17.3 15.2,17.3 15.2,10.3 L 15.2,9.3 M 10,15.7 L 10,18 M 7.3,18 L 12.7,18");
                if (Kind == ActionIcon.MicrophoneOff) Line(3, 3, 17, 17); break;
            case ActionIcon.Volume:
            case ActionIcon.Mute:
                dc.DrawGeometry(Ink, null, Shape("M 3,7 L 6,7 L 10.5,3.5 Q 11,3.2 11,4 L 11,16 Q 11,16.8 10.5,16.5 L 6,13 L 3,13 Q 2.4,13 2.4,12.4 L 2.4,7.6 Q 2.4,7 3,7 Z"));
                if (Kind == ActionIcon.Mute) { Line(14, 7.5, 18, 12.5); Line(18, 7.5, 14, 12.5); }
                else Path("M 14,6.6 Q 17.2,10 14,13.4 M 16.5,3.9 Q 20,10 16.5,16.1"); break;
            case ActionIcon.Play: dc.DrawGeometry(Ink, null, Shape("M 6,4 Q 6,3 7,3.6 L 16,9.1 Q 17.2,10 16,10.9 L 7,16.4 Q 6,17 6,16 Z")); break;
            case ActionIcon.Pause: dc.DrawRoundedRectangle(Ink, null, new Rect(5.2, 4, 3.3, 12), 1, 1); dc.DrawRoundedRectangle(Ink, null, new Rect(11.5, 4, 3.3, 12), 1, 1); break;
            case ActionIcon.Stop: dc.DrawRoundedRectangle(Ink, null, new Rect(4.2, 4.2, 11.6, 11.6), 2.2, 2.2); break;
            case ActionIcon.FillRectangle: dc.DrawRoundedRectangle(Ink, null, new Rect(3, 5, 14, 10), 2, 2); break;
            case ActionIcon.FillEllipse: dc.DrawEllipse(Ink, null, new Point(10, 10), 6.5, 6.5); break;
            case ActionIcon.FillText:
                var outer = new RectangleGeometry(new Rect(2.8, 2.8, 14.4, 14.4), 2.1, 2.1);
                var letter = Shape("M 6.4,6.4 L 13.6,6.4 M 10,6.4 L 10,13.8").GetWidenedPathGeometry(pen);
                dc.DrawGeometry(Ink, null, new CombinedGeometry(GeometryCombineMode.Exclude, outer, letter)); break;
            case ActionIcon.Palette:
                var hues = new[] { Colors.Red, Colors.Orange, Colors.Yellow, Colors.LimeGreen, Colors.DeepSkyBlue, Colors.RoyalBlue, Colors.MediumOrchid };
                for (var i = 0; i < hues.Length; i++)
                {
                    var a = i * Math.PI * 2 / hues.Length; var b = (i + 1) * Math.PI * 2 / hues.Length;
                    var geometry = new StreamGeometry(); using (var ctx = geometry.Open()) { ctx.BeginFigure(new Point(10, 10), true, true); ctx.LineTo(new Point(10 + 8 * Math.Cos(a), 10 + 8 * Math.Sin(a)), true, false); ctx.ArcTo(new Point(10 + 8 * Math.Cos(b), 10 + 8 * Math.Sin(b)), new Size(8, 8), 0, false, SweepDirection.Clockwise, true, false); }
                    dc.DrawGeometry(new SolidColorBrush(hues[i]), null, geometry);
                }
                dc.DrawEllipse(Brushes.White, null, new Point(10, 10), 3.8, 3.8); Line(8.5, 10, 11.5, 10); Line(10, 8.5, 10, 11.5); break;
            case ActionIcon.Minimize: Line(4.5, 10, 15.5, 10); break;
            case ActionIcon.WindowMaximize: dc.DrawRoundedRectangle(null, pen, new Rect(3, 3, 14, 14), .6, .6); break;
            case ActionIcon.WindowRestore: Path("M 7,5 L 7,3 L 17,3 L 17,13 L 15,13 M 3,7 L 13,7 L 13,17 L 3,17 Z"); break;
            case ActionIcon.Expand: Path("M 4.5,8 L 4.5,4.5 L 8,4.5 M 12,15.5 L 15.5,15.5 L 15.5,12 M 4.7,4.7 L 8.5,8.5 M 11.5,11.5 L 15.3,15.3"); break;
            case ActionIcon.Settings:
                dc.DrawGeometry(null, pen, Shape("M 8.2,2.5 L 11.8,2.5 L 12.4,4.3 L 14.2,5.4 L 16.1,5 L 17.9,8 L 16.5,9.5 L 16.5,11.2 L 17.7,12.7 L 15.9,15.7 L 14,15.3 L 12.4,16.3 L 11.8,18 L 8.2,18 L 7.6,16.3 L 6,15.3 L 4.1,15.7 L 2.3,12.7 L 3.5,11.2 L 3.5,9.5 L 2.1,8 L 3.9,5 L 5.8,5.4 L 7.6,4.3 Z")); dc.DrawEllipse(null, pen, new Point(10, 10.2), 2.6, 2.6); break;
            case ActionIcon.Capture: Path("M 7,3 L 5,3 Q 3,3 3,5 L 3,7 M 13,3 L 15,3 Q 17,3 17,5 L 17,7 M 3,13 L 3,15 Q 3,17 5,17 L 7,17 M 13,17 L 15,17 Q 17,17 17,15 L 17,13"); dc.DrawRoundedRectangle(null, pen, new Rect(6.4, 6.4, 7.2, 7.2), 1.5, 1.5); break;
            case ActionIcon.Keyboard: dc.DrawRoundedRectangle(null, pen, new Rect(2, 4.5, 16, 11.5), 2, 2); for (var y = 7; y <= 10; y += 3) for (var x = 5; x <= 15; x += 3) dc.DrawEllipse(Ink, null, new Point(x, y), .7, .7); Line(6, 13.5, 14, 13.5); break;
            case ActionIcon.Power: Path("M 6.2,4.2 A 7,7 0 1 0 13.8,4.2 M 10,2.5 L 10,9.5"); break;
            case ActionIcon.Tray: dc.DrawRoundedRectangle(null, pen, new Rect(2.5, 4.5, 15, 11), 2, 2); Line(3, 7.7, 17, 7.7); break;
            case ActionIcon.Folder: Path("M 2.5,6 Q 2.5,4.5 4,4.5 L 8,4.5 L 10,6.5 L 16,6.5 Q 17.5,6.5 17.5,8 L 17.5,15 Q 17.5,16.5 16,16.5 L 4,16.5 Q 2.5,16.5 2.5,15 Z"); break;
            case ActionIcon.Delete: Path("M 3.5,5.5 L 16.5,5.5 M 7,5.5 L 7.5,3 L 12.5,3 L 13,5.5 M 5,6 L 5.8,16 Q 5.9,17 7,17 L 13,17 Q 14.1,17 14.2,16 L 15,6 M 8,8.5 L 8.4,14 M 12,8.5 L 11.6,14"); break;
            case ActionIcon.Switch: Path("M 3,7 L 16.5,7 L 13,3.5 M 16.5,7 L 13,10.5 M 17,13 L 3.5,13 L 7,9.5 M 3.5,13 L 7,16.5"); break;
            case ActionIcon.ChevronDown: Path("M 5,7.5 L 10,12.5 L 15,7.5"); break;
            case ActionIcon.Fullscreen: Path("M 7,3 L 3,3 L 3,7 M 13,3 L 17,3 L 17,7 M 3,13 L 3,17 L 7,17 M 13,17 L 17,17 L 17,13"); break;
            case ActionIcon.Edit: Path("M 4,12.5 L 12.5,4 Q 13.5,3 14.5,4 L 16,5.5 Q 17,6.5 16,7.5 L 7.5,16 L 3.5,16.5 Z M 11.5,5 L 15,8.5"); break;
            case ActionIcon.Gif: dc.DrawRoundedRectangle(null, pen, new Rect(2.5, 4.5, 15, 11), 2, 2); Text("GIF", 4, 5.4, 6.5); break;
        }
        if (Kind == ActionIcon.Mosaic) dc.Pop();
        dc.Pop();
    }
    private static readonly Dictionary<string, Geometry> shapes = [];
    private static Geometry Shape(string path) { if (!shapes.TryGetValue(path, out var geometry)) { geometry = Geometry.Parse(path); geometry.Freeze(); shapes[path] = geometry; } return geometry; }
}
