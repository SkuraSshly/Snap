using Velos.Core.Hotkeys;
using Velos.Core.Settings;

var defaults = new AppSettings();
var testDirectory = Path.Combine(Path.GetTempPath(), "Velos.Tests", Guid.NewGuid().ToString("N"));
var settingsPath = Path.Combine(testDirectory, "settings.json");
var store = new SettingsStore(settingsPath);
const HotkeyAction screenshot = HotkeyAction.Screenshot;
const HotkeyModifiers ctrl = HotkeyModifiers.Control, alt = HotkeyModifiers.Alt, shift = HotkeyModifiers.Shift;

string? Problem(Hotkey key) => HotkeyConflicts.Validate(key, screenshot, defaults.GetHotkey);

(string Name, Action Run)[] tests =
[
    ("默认快捷键是 Alt+A、Alt+S、Alt+D", () =>
    {
        Check(defaults.Screenshot == new Hotkey('A', alt), "截图");
        Check(defaults.Recording == new Hotkey('S', alt), "录屏");
        Check(defaults.Translation == new Hotkey('D', alt), "截屏翻译");
    }),
    ("只保留四个修饰键", () =>
    {
        Check(new Hotkey('A', (HotkeyModifiers)0xffff).Modifiers == (HotkeyModifiers)15, "修饰键掩码");
    }),
    ("识别已知按键和 F1–F20", () =>
    {
        Check(new Hotkey(0x70, 0).IsFunctionKey, "F1");
        Check(new Hotkey(0x83, 0).KeyName == "F20", "F20");
        Check(new Hotkey(0x84, 0).KeyName is null, "超出范围的功能键");
        Check(new Hotkey(0xff, alt).KeyName is null, "未知键");
    }),
    ("无修饰键或只有 Shift 时拒绝普通按键", () =>
    {
        Check(Problem(new Hotkey('A', 0)) is not null, "无修饰键");
        Check(Problem(new Hotkey('A', shift)) is not null, "只有 Shift");
        Check(Problem(new Hotkey(0x70, 0)) is null, "允许 F1");
    }),
    ("和其他动作重复时说明是哪个动作", () =>
    {
        Check(Problem(defaults.Translation)?.Contains("截屏翻译") == true, "动作名称");
    }),
    ("设回本动作现有快捷键不冲突", () =>
    {
        Check(Problem(defaults.Screenshot) is null, "保留原快捷键");
    }),
    ("常用编辑键冲突", () =>
    {
        Check(Problem(new Hotkey('C', ctrl))?.Contains("常用的编辑快捷键") == true, "Ctrl+C");
        Check(Problem(new Hotkey('Y', ctrl))?.Contains("常用的编辑快捷键") == true, "Ctrl+Y");
    }),
    ("Windows 保留键冲突", () =>
    {
        Check(Problem(new Hotkey(0x7b, 0))?.Contains("F12") == true, "F12");
        Check(Problem(new Hotkey(0x09, alt))?.Contains("切换应用") == true, "Alt+Tab");
        Check(Problem(new Hotkey('D', HotkeyModifiers.Windows))?.Contains("Win 组合键") == true, "Win+D");
    }),
    ("可用的组合键通过规则检查", () =>
    {
        Check(Problem(new Hotkey('J', alt | ctrl)) is null, "Ctrl+Alt+J");
    }),
    ("初次启动加载默认设置", () =>
    {
        Check(store.Load() == (defaults, null), "默认值");
    }),
    ("设置和快捷键保存后可重新加载", () =>
    {
        var changed = defaults with { ShowTrayIcon = false, Screenshot = new Hotkey('J', ctrl | alt) };
        store.Save(changed);
        Check(new SettingsStore(settingsPath).Load() == (changed, null), "保存后重读");
        store.Save(defaults);
        Check(store.Load() == (defaults, null), "覆盖现有设置");
        Check(!File.Exists(settingsPath + ".tmp"), "保存完成后无临时文件");
    }),
    ("部分设置沿用默认值", () =>
    {
        File.WriteAllText(settingsPath, """{"showTrayIcon":false}""");
        Check(store.Load() == (defaults with { ShowTrayIcon = false }, null), "缺失字段");
    }),
    ("损坏的设置可回到默认值并提示", () =>
    {
        File.WriteAllText(settingsPath, "{");
        var result = store.Load();
        Check(result.Settings == defaults && result.Warning is not null, "无法解析");
    }),
    ("重复的快捷键可回到默认值并保留其他设置", () =>
    {
        store.Save(defaults with { Recording = defaults.Screenshot, ShowTrayIcon = false });
        var result = store.Load();
        Check(result.Settings == defaults with { ShowTrayIcon = false } && result.Warning is not null, "快捷键冲突");
    }),
    .. ScreenshotTests.Cases(Check),
    .. AnnotationColorCodeTests.Cases(Check),
    .. RoundedCornersTests.Cases(Check),
    .. ScrollStitcherTests.Cases(Check),
    .. RecordingTests.Cases(Check),
    .. TranslationTests.Cases(Check),
    .. ParityTests.Cases(Check)
];

var passed = 0;
foreach (var (name, run) in tests)
{
    try
    {
        run();
        passed++;
        Console.WriteLine($"通过  {name}");
    }
    catch (Exception error)
    {
        Console.Error.WriteLine($"失败  {name}：{error.Message}");
    }
}

Console.WriteLine($"通过 {passed}/{tests.Length}");
return passed == tests.Length ? 0 : 1;

static void Check(bool condition, string detail)
{
    if (!condition)
        throw new InvalidOperationException(detail);
}
