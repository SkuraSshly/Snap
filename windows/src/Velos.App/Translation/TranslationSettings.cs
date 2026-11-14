using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using Velos.Core.Settings;
using Velos.Core.Translation;
using Velos.UI;
using Velos.Windows.Translation;

namespace Velos;

public partial class SettingsWindow
{
    private CancellationTokenSource? engineTest;
    private Action? cancelEngineTest;
    internal void SelectTranslationSettings() => TranslationTab.IsChecked = true;
    private void BuildTranslationSettings()
    {
        var ocr = AddGroup("文字识别", TranslationPage);
        var recognition = new ComboBox { MinWidth = 120, MaxWidth = 210, DisplayMemberPath = "Name" };
        var installed = new List<LanguageChoice> { new(null, "跟随系统") };
        try { installed.AddRange(OfflineOcr.Languages().Select(l => new LanguageChoice(l.Code, TranslateLanguage.FromLocale(l.Code)?.Name ?? l.Name))); } catch { }
        recognition.ItemsSource = installed; recognition.SelectedItem = installed.FirstOrDefault(l => l.Code == app.Settings.TranslationOptions.PreferredRecognitionLanguage) ?? installed[0];
        recognition.SelectionChanged += (_, _) => ChangeTranslation(p => p with { PreferredRecognitionLanguage = ((LanguageChoice)recognition.SelectedItem).Code });
        AddControl(ocr, "优先识别的语言", recognition, "文字较短、语言不好判断时优先按这种语言识别");
        TranslationSwitch(ocr, "智能排版", p => p.SmartLayout, (p, v) => p with { SmartLayout = v }, "合并长行断句，保留段落、列表和诗歌换行");
        var qr = new CheckBox { IsEnabled = false, Style = (Style)FindResource("Switch"), ToolTip = "Windows OCR 接口不提供二维码解码" };
        AddControl(ocr, "同时识别二维码", qr, "当前 Windows OCR 接口不支持，暂不提供此功能");
        var languageSettings = MakeButton("打开 Windows 语言设置…", () => { try { Process.Start(new ProcessStartInfo("ms-settings:regionlanguage") { UseShellExecute = true }); } catch { ShowStatus("请在 Windows 设置 › 时间和语言中添加 OCR 语言包。"); } });
        languageSettings.HorizontalAlignment = HorizontalAlignment.Right;
        TranslationPage.Children.Add(languageSettings);
        TranslationCaption("完全离线。依赖系统已安装的 OCR 语言包；识别进程按需启动，空闲 30 秒退出，关闭 Velos 时一起退出。");
        var engines = AddGroup("翻译引擎", TranslationPage);
        var defaultEngine = new ComboBox { DisplayMemberPath = "Name", MinWidth = 170 };
        AutomationProperties.SetAutomationId(defaultEngine, "TranslationDefaultEngine");
        var refreshingDefaults = false;
        Action? refreshEngine = null, rememberDraft = null;
        var drafts = new Dictionary<EngineId, Dictionary<string, string>>();
        RefreshDefaultEngines();
        defaultEngine.SelectionChanged += (_, _) => {
            if (!refreshingDefaults && defaultEngine.SelectedItem is EngineDefinition { Id: not EngineId.None } engine && engine.Id != app.Settings.TranslationOptions.DefaultEngine)
                ChangeTranslation(p => p with { DefaultEngine = engine.Id });
        };
        AddControl(engines, "默认引擎", defaultEngine, "未配置时引导填写 Key，失败时自动尝试其他已启用引擎");
        var order = new[] { EngineId.Tencent, EngineId.Volcengine, EngineId.Baidu, EngineId.Youdao, EngineId.DeepL, EngineId.Azure, EngineId.OpenAI, EngineId.Claude }.Select(EngineDefinition.Get).ToArray();
        var choice = new ComboBox { ItemsSource = order, DisplayMemberPath = "Name", SelectedItem = order.FirstOrDefault(e => app.Settings.TranslationOptions.EnabledEngines.HasFlag(e.Id)) ?? order[0], MinWidth = 170 };
        AutomationProperties.SetAutomationId(choice, "TranslationEnginePicker");
        AddControl(engines, "在线翻译", choice, "需要自己的 Key，默认全部关闭");
        var credentials = new StackPanel { Margin = new Thickness(66, 0, 13, 12) }; engines.Children.Add(credentials);
        preferenceRefreshers.Add(() => refreshEngine?.Invoke());
        choice.SelectionChanged += (_, _) => RenderEngine(); RenderEngine();
        void RefreshDefaultEngines()
        {
            if (refreshingDefaults) return;
            refreshingDefaults = true;
            try
            {
                var available = app.Translator.Available;
                if (available.Count == 0) { defaultEngine.ItemsSource = new[] { new EngineDefinition(EngineId.None, "尚未配置在线引擎", []) }; defaultEngine.SelectedIndex = 0; }
                else { defaultEngine.ItemsSource = available; defaultEngine.SelectedItem = available.FirstOrDefault(e => e.Id == app.Settings.TranslationOptions.DefaultEngine) ?? available[0]; }
                defaultEngine.IsEnabled = available.Count > 0;
            }
            catch { defaultEngine.IsEnabled = false; ShowStatus("无法检查已保存的凭据，请检查 Windows 凭据管理器。"); }
            finally { refreshingDefaults = false; }
        }
        void RenderEngine()
        {
            rememberDraft?.Invoke(); refreshEngine = null; engineTest?.Cancel(); engineTest = null; credentials.Children.Clear();
            if (choice.SelectedItem is not EngineDefinition engine) return;
            drafts.TryGetValue(engine.Id, out var draft);
            var enabled = new CheckBox { Style = (Style)FindResource("Switch"), IsChecked = app.Settings.TranslationOptions.EnabledEngines.HasFlag(engine.Id), Margin = new Thickness(6, 0, 8, 0) };
            AutomationProperties.SetAutomationId(enabled, "TranslationEngineEnabled"); AutomationProperties.SetName(enabled, "启用" + engine.Name);
            var enabledLabel = new TextBlock { FontSize = 11, Opacity = .75, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetAutomationId(enabledLabel, "TranslationEngineAvailability");
            var enableRow = new Grid { Margin = new Thickness(0, 0, 0, 6) };
            enableRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(60) }); enableRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); enableRow.ColumnDefinitions.Add(new ColumnDefinition());
            enableRow.Children.Add(new TextBlock { Text = "启用", VerticalAlignment = VerticalAlignment.Center });
            Grid.SetColumn(enabled, 1); enableRow.Children.Add(enabled); Grid.SetColumn(enabledLabel, 2); enableRow.Children.Add(enabledLabel); credentials.Children.Add(enableRow);
            var feedback = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 11, Margin = new Thickness(85, 5, 0, 0), Visibility = Visibility.Collapsed };
            AutomationProperties.SetAutomationId(feedback, "TranslationEngineFeedback");
            Button? test = null, cancelTest = null;
            var values = new Dictionary<string, Func<string>>(); var resetSecrets = new List<Action>();
            foreach (var field in engine.Fields)
            {
                var row = new Grid { Margin = new Thickness(0, 3, 0, 3) }; row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(85) }); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(new TextBlock { Text = field.Label, FontSize = 11, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0), Opacity = .7 });
                FrameworkElement editor;
                if (field.Secret)
                {
                    var password = new PasswordBox { Password = draft?.GetValueOrDefault(field.Id) ?? "", Padding = new Thickness(5, 3, 5, 3), BorderThickness = new Thickness(1), FontSize = 12 };
                    StyleEditor(password); values[field.Id] = () => password.Password;
                    var hint = new TextBlock { Margin = new Thickness(6, 0, 4, 0), FontSize = 11, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false, TextTrimming = TextTrimming.CharacterEllipsis };
                    hint.SetResourceReference(ForegroundProperty, "Secondary");
                    var clear = MakeButton("清除", () => {
                        engineTest?.Cancel(); app.CancelTranslationNetwork();
                        try { app.Credentials.Set(engine.Id, field.Id, ""); password.Clear(); RefreshState(); Feedback("已清除 " + field.Label + "，填写并保存后恢复可用。", true); }
                        catch { Feedback("无法清除此字段。"); }
                    });
                    AutomationProperties.SetAutomationId(clear, "TranslationClear." + field.Id); Grid.SetColumn(clear, 2); row.Children.Add(clear);
                    void RefreshSaved()
                    {
                        bool saved; try { saved = app.Credentials.Contains(engine.Id, field.Id); } catch { saved = false; Feedback("无法检查已保存的凭据。"); }
                        hint.Text = saved ? "已保存 · 输入新的值替换" : "输入 " + field.Label;
                        hint.Visibility = password.Password.Length == 0 ? Visibility.Visible : Visibility.Collapsed; clear.Visibility = saved ? Visibility.Visible : Visibility.Collapsed;
                    }
                    password.PasswordChanged += (_, _) => RefreshSaved(); clear.Click += (_, _) => RefreshSaved();
                    resetSecrets.Add(() => { password.Clear(); RefreshSaved(); }); RefreshSaved(); editor = new Grid { Children = { password, hint } };
                }
                else
                {
                    var text = new TextBox { Text = draft?.GetValueOrDefault(field.Id) ?? app.TranslationField(engine.Id, field.Id), Padding = new Thickness(5, 3, 5, 3), BorderThickness = new Thickness(1), FontSize = 12 };
                    StyleEditor(text); values[field.Id] = () => text.Text; editor = text;
                }
                AutomationProperties.SetAutomationId(field.Secret ? ((Grid)editor).Children[0] : editor, "TranslationField." + field.Id);
                AutomationProperties.SetName(field.Secret ? ((Grid)editor).Children[0] : editor, field.Label);
                editor.ToolTip = field.Label + (field.Secret ? "（保存在 Windows 凭据管理器，留空保留已保存值）" : "（保存在普通设置文件）"); Grid.SetColumn(editor, 1); row.Children.Add(editor); credentials.Children.Add(row);
            }
            rememberDraft = () => drafts[engine.Id] = values.ToDictionary(pair => pair.Key, pair => pair.Value());
            void StyleEditor(Control editor) { editor.SetResourceReference(Control.BackgroundProperty, "Card"); editor.SetResourceReference(Control.ForegroundProperty, "Ink"); editor.SetResourceReference(Control.BorderBrushProperty, "Hairline"); }
            void Feedback(string? message, bool success = false)
            {
                feedback.Text = message ?? ""; feedback.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
                feedback.SetResourceReference(ForegroundProperty, success ? "Secondary" : "Warning"); ShowStatus(message);
            }
            void RefreshState()
            {
                enabled.IsChecked = app.Settings.TranslationOptions.EnabledEngines.HasFlag(engine.Id);
                try {
                    var missing = engine.Fields.Where(field => !field.Optional && !app.HasTranslationField(engine.Id, field.Id)).Select(field => field.Label).ToArray();
                    enabledLabel.Text = enabled.IsChecked != true ? "未启用，不会联网" : missing.Length == 0 ? "已启用「" + engine.Name + "」" : "已启用 · 请填写并保存：" + string.Join("、", missing);
                    if (test is not null) { test.IsEnabled = engineTest is null && enabled.IsChecked == true && missing.Length == 0; test.Content = engineTest is null ? "测试" : "测试中…"; test.ToolTip = enabled.IsChecked != true ? "先启用此引擎" : missing.Length > 0 ? "先填写并保存完整配置" : "只发送 Hello Velos 测试文字"; }
                    if (cancelTest is not null) cancelTest.IsEnabled = engineTest is not null;
                }
                catch { enabledLabel.Text = "无法检查已保存的配置"; if (test is not null) test.IsEnabled = false; }
                RefreshDefaultEngines();
            }
            bool SaveCredentials()
            {
                engineTest?.Cancel(); app.CancelTranslationNetwork();
                try
                {
                    if (engine.Id == EngineId.OpenAI && values["baseURL"]().Trim() is { Length: > 0 } url && EngineSigning.OpenAIEndpoint(url) is null)
                    { Feedback("Base URL 无效，请填写 http:// 或 https:// 开头的完整地址。"); return false; }
                    if (engine.Fields.Where(field => field.Secret).Any(field => values[field.Id]().Trim().Length > 1280))
                    { Feedback("凭据过长，最多 1280 个字符。尚未保存此次修改。"); return false; }
                    var options = app.Settings.TranslationOptions.EngineOptions ?? new TranslationEngineOptions();
                    foreach (var field in engine.Fields.Where(field => !field.Secret)) options = options.Set(engine.Id, field.Id, values[field.Id]());
                    var problem = app.ChangeTranslationOptions(app.Settings.TranslationOptions with { EngineOptions = options });
                    if (problem is not null) { Feedback(problem); return false; }
                    foreach (var field in engine.Fields.Where(field => field.Secret)) { var replacement = values[field.Id](); if (!string.IsNullOrWhiteSpace(replacement)) app.Credentials.Set(engine.Id, field.Id, replacement); }
                    foreach (var reset in resetSecrets) reset(); rememberDraft(); RefreshState(); Feedback("已保存。Key 保存在凭据管理器，地址、模型和地域保存在设置文件。", true); return true;
                }
                catch (Exception error) { Feedback($"无法保存凭据。（0x{error.HResult:X8}）"); return false; }
            }
            enabled.Click += (_, _) => {
                var selected = enabled.IsChecked == true;
                if (!selected) engineTest?.Cancel();
                var problem = app.ChangeTranslationOptions(app.Settings.TranslationOptions with { EnabledEngines = selected ? app.Settings.TranslationOptions.EnabledEngines | engine.Id : app.Settings.TranslationOptions.EnabledEngines & ~engine.Id });
                RefreshState(); Feedback(problem);
            };
            var tools = new WrapPanel { Margin = new Thickness(85, 5, 0, 0) };
            var save = MakeButton("保存", () => SaveCredentials()); AutomationProperties.SetAutomationId(save, "TranslationEngineSave"); tools.Children.Add(save);
            test = MakeButton("测试", async () => {
                if (engineTest is not null || !SaveCredentials()) return;
                if (!app.Settings.TranslationOptions.EnabledEngines.HasFlag(engine.Id) || !engine.Fields.Where(field => !field.Optional).All(field => app.HasTranslationField(engine.Id, field.Id))) { Feedback("请先启用此引擎并保存全部必填字段。不会发送请求。"); return; }
                var operation = new CancellationTokenSource(); engineTest = operation; RefreshState();
                bool Current() => ReferenceEquals(engineTest, operation) && Equals(choice.SelectedItem, engine) && IsLoaded;
                try { Feedback("正在翻译测试文字 Hello Velos…", true); var output = await app.Translator.Translate(engine.Id, "Hello Velos", TranslateLanguage.English, TranslateLanguage.Chinese, null, operation.Token); if (Current()) Feedback("测试成功：" + output, true); }
                catch (OperationCanceledException) { if (Current()) Feedback("已取消测试。", true); }
                catch (Exception error) { if (Current()) Feedback("测试失败：" + error.Message); }
                finally { if (ReferenceEquals(engineTest, operation)) { engineTest = null; if (Equals(choice.SelectedItem, engine)) RefreshState(); } operation.Dispose(); }
            });
            AutomationProperties.SetAutomationId(test, "TranslationEngineTest"); tools.Children.Add(test);
            cancelTest = MakeButton("取消测试", () => engineTest?.Cancel()); AutomationProperties.SetAutomationId(cancelTest, "TranslationEngineCancelTest"); tools.Children.Add(cancelTest);
            var clearAll = MakeButton("清除凭据", () => {
                engineTest?.Cancel(); app.CancelTranslationNetwork();
                try { foreach (var field in engine.Fields.Where(field => field.Secret)) app.Credentials.Set(engine.Id, field.Id, ""); foreach (var reset in resetSecrets) reset(); RefreshState(); Feedback("已清除凭据，保留启用选择、地址、模型和地域；补齐凭据后恢复可用。", true); }
                catch { Feedback("无法清除凭据。"); }
            });
            AutomationProperties.SetAutomationId(clearAll, "TranslationEngineClear"); tools.Children.Add(clearAll);
            credentials.Children.Add(tools); credentials.Children.Add(feedback); refreshEngine = RefreshState; RefreshState();
            if (engine.IsLlm)
            {
                credentials.Children.Add(new TextBlock { Text = "自定义翻译提示词（{source}、{target} 会自动替换）", FontSize = 11, Margin = new Thickness(0, 10, 0, 4), Opacity = .7 });
                var prompt = new TextBox { Text = app.Settings.TranslationOptions.LlmPrompt, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 100, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
                prompt.SetResourceReference(BackgroundProperty, "Card"); prompt.SetResourceReference(ForegroundProperty, "Ink"); credentials.Children.Add(prompt);
                prompt.LostKeyboardFocus += (_, _) => ChangeTranslation(p => p with { LlmPrompt = prompt.Text });
            }
        }
        TranslationCaption("只有启用并填好 Key 的引擎才联网，只发送文字。Key、Secret 和 ID 保存在凭据管理器；地址、模型和地域保存在设置文件。默认引擎失败时自动尝试其他可用引擎。");
        var results = AddGroup("结果窗口", TranslationPage);
        var target = new ComboBox { MinWidth = 130, DisplayMemberPath = "Name" }; var targets = new[] { new LanguageChoice(null, "自动") }.Concat(LanguageRules.MenuLanguages.Select(l => new LanguageChoice(l.Code, l.Name))).ToArray();
        target.ItemsSource = targets; target.SelectedItem = targets.FirstOrDefault(l => l.Code == app.Settings.TranslationOptions.DefaultTargetLanguage) ?? targets[0];
        target.SelectionChanged += (_, _) => ChangeTranslation(p => p with { DefaultTargetLanguage = ((LanguageChoice)target.SelectedItem).Code });
        AddControl(results, "默认目标语言", target, "自动：中文译成英文，其他语言译成简体中文");
        TranslationSwitch(results, "翻译完成后自动复制译文", p => p.AutoCopy, (p, v) => p with { AutoCopy = v }, "复制到剪贴板，可以直接粘贴");
        var rates = new StackPanel { Orientation = Orientation.Horizontal };
        var rateButtons = new List<(double Rate, Button Button)>();
        foreach (var (rate, name) in new[] { (.8, "慢"), (1d, "正常"), (1.2, "快") })
        { var button = MakeButton(name, () => { ChangeTranslation(p => p with { SpeechRate = rate }); RefreshRates(); }); rates.Children.Add(button); rateButtons.Add((rate, button)); }
        void RefreshRates() { foreach (var (rate, button) in rateButtons) { var active = Math.Abs(rate - app.Settings.TranslationOptions.SpeechRate) < .01; button.SetResourceReference(BackgroundProperty, active ? "Apricot" : "Track"); button.SetResourceReference(ForegroundProperty, active ? "SelectedInk" : "Ink"); } }
        RefreshRates(); AddControl(results, "朗读语速", rates);
        TranslationSwitch(results, "默认钉住", p => p.PinnedByDefault, (p, v) => p with { PinnedByDefault = v }, "钉住的窗口置顶、点别处不会关闭，可以拖动、调整大小");
        TranslationCaption("窗口快捷键：Ctrl+C 复制译文，Ctrl+Shift+C 复制原文，Ctrl+R 重新翻译，Ctrl+P 钉住／取消钉住，Esc 关闭。");
        cancelEngineTest = () => engineTest?.Cancel();
    }
    private void ChangeTranslation(Func<TranslationPreferences, TranslationPreferences> change)
    { engineTest?.Cancel(); ShowStatus(app.ChangeTranslationOptions(change(app.Settings.TranslationOptions))); }
    private void TranslationSwitch(Panel group, string name, Func<TranslationPreferences, bool> read, Func<TranslationPreferences, bool, TranslationPreferences> change, string? caption = null)
    {
        var toggle = new CheckBox { Style = (Style)FindResource("Switch"), IsChecked = read(app.Settings.TranslationOptions) };
        preferenceRefreshers.Add(() => toggle.IsChecked = read(app.Settings.TranslationOptions));
        toggle.Click += (_, _) => { ChangeTranslation(p => change(p, toggle.IsChecked == true)); toggle.IsChecked = read(app.Settings.TranslationOptions); }; AddControl(group, name, toggle, caption);
    }
    private void TranslationCaption(string text) => TranslationPage.Children.Add(new TextBlock { Text = text, Style = (Style)FindResource("Caption"), Margin = new Thickness(7, 4, 7, 14) });
    private sealed record LanguageChoice(string? Code, string Name) { public override string ToString() => Name; }
}
