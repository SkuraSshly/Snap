#if DEBUG
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using Velos.Core.Settings;
using Velos.Core.Translation;
using Velos.Windows.Capture;
using Velos.Windows.Translation;

namespace Velos;

public partial class App
{
    private async Task ReviewTranslationSettings(string profile, List<string> results)
    {
        var previous = credentials;
        var isolated = new CredentialStore("Velos/SelfTest/Settings/" + Guid.NewGuid().ToString("N") + "/");
        credentials = isolated;
        var calls = 0; var hold = false;
        translator = new TranslationService(() => Settings.TranslationOptions, TranslationField, HasTranslationField) {
            DebugHandler = () => new SettingsTranslationHandler(async token => {
                calls++; await Task.Delay(hold ? Timeout.Infinite : 100, token);
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("data: {\"choices\":[{\"delta\":{\"content\":\"合成测试译文\"}}]}\n\ndata: [DONE]\n\n", Encoding.UTF8, "text/event-stream") };
            }) };
        try
        {
            ChangeTranslationOptions(new TranslationPreferences());
            OpenSettings(); var window = settingsWindow!; window.SelectTranslationSettings(); await SettleUI();
            var picker = Find<ComboBox>("TranslationEnginePicker");
            picker.SelectedItem = EngineDefinition.Get(EngineId.OpenAI); await SettleUI();
            var toggle = Find<CheckBox>("TranslationEngineEnabled");
            ClickSwitch(toggle);
            Check(toggle.IsChecked == true && Settings.TranslationOptions.EnabledEngines.HasFlag(EngineId.OpenAI), "S01", "未填写配置也可保留启用意图，不自动关回去");
            Check(Translator.Available.Count == 0, "S02", "已启用但配置不全的引擎仍不可进入网络管线");
            picker.SelectedItem = EngineDefinition.Get(EngineId.Claude); picker.SelectedItem = EngineDefinition.Get(EngineId.OpenAI);
            Check(Find<CheckBox>("TranslationEngineEnabled").IsChecked == true, "S03", "切换服务商再回来，启用状态保持");
            Find<TextBox>("TranslationField.baseURL").Text = "https://example.invalid/v1";
            Find<TextBox>("TranslationField.model").Text = "synthetic-model";
            Find<PasswordBox>("TranslationField.apiKey").Password = "synthetic-test-only";
            Find<Button>("TranslationEngineSave").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            Check(Translator.Available.Single().Id == EngineId.OpenAI, "S04", "保存完整配置后默认引擎列表立即可用");
            Check(Find<PasswordBox>("TranslationField.apiKey").Password.Length == 0 && isolated.Contains(EngineId.OpenAI, "apiKey"), "S05", "保存后清空机密输入框，凭据独立保存");
            Check(!File.ReadAllText(Path.Combine(profile, "settings.json")).Contains("synthetic-test-only"), "S06", "API Key 不进入设置 JSON");
            Find<TextBox>("TranslationField.model").Text = "draft-model";
            picker.SelectedItem = EngineDefinition.Get(EngineId.Claude); picker.SelectedItem = EngineDefinition.Get(EngineId.OpenAI);
            Check(Find<TextBox>("TranslationField.model").Text == "draft-model", "S07", "切换服务商不丢失尚未保存的配置草稿");
            window.Close(); OpenSettings(); window = settingsWindow!; window.SelectTranslationSettings(); await SettleUI();
            Check(Find<CheckBox>("TranslationEngineEnabled").IsChecked == true && Find<TextBox>("TranslationField.model").Text == "synthetic-model", "S08", "重开设置加载已保存配置，不把草稿当作已保存");
            Find<Button>("TranslationClear.apiKey").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            Check(Find<CheckBox>("TranslationEngineEnabled").IsChecked == true && Translator.Available.Count == 0 && !Find<Button>("TranslationEngineTest").IsEnabled,
                "S09", "清除 Key 保留启用意图，但从可用列表移除且禁用测试");
            Check(Find<TextBlock>("TranslationEngineAvailability").Text.Contains("API Key") && Find<TextBlock>("TranslationEngineFeedback").Visibility == Visibility.Visible,
                "S10", "缺项和操作结果在当前引擎旁显示，不依赖页面底部提示");
            Find<TextBox>("TranslationField.baseURL").Text = "not-a-url";
            Find<TextBox>("TranslationField.model").Text = "must-not-save";
            Find<Button>("TranslationEngineSave").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            Check(Settings.TranslationOptions.EngineOptions.OpenAiModel == "synthetic-model" && Find<TextBlock>("TranslationEngineFeedback").Text.Contains("Base URL 无效"),
                "S11", "非法地址在保存前拦截，不部分覆盖已有公开配置");
            Find<TextBox>("TranslationField.baseURL").Text = "https://example.invalid/v1";
            Find<TextBox>("TranslationField.model").Text = "synthetic-model";
            Find<PasswordBox>("TranslationField.apiKey").Password = new string('x', 1281);
            Find<Button>("TranslationEngineSave").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            Check(!isolated.Contains(EngineId.OpenAI, "apiKey") && Find<TextBlock>("TranslationEngineFeedback").Text.Contains("过长"), "S12", "过长凭据不写入，也不会误报保存成功");
            Find<PasswordBox>("TranslationField.apiKey").Password = "synthetic-test-only";
            Find<Button>("TranslationEngineSave").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            Find<Button>("TranslationEngineTest").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            Check(!Find<Button>("TranslationEngineTest").IsEnabled && Find<Button>("TranslationEngineCancelTest").IsEnabled, "S13", "测试请求期间禁用重复发送，显示取消按钮");
            await Await(() => Find<Button>("TranslationEngineTest").IsEnabled);
            Check(calls == 1 && Find<TextBlock>("TranslationEngineFeedback").Text.Contains("合成测试译文"), "S14", "测试完成在引擎旁显示假服务返回结果，无真实联网");
            hold = true;
            Find<Button>("TranslationEngineTest").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            Find<Button>("TranslationEngineCancelTest").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            await Await(() => Find<Button>("TranslationEngineTest").IsEnabled);
            Check(calls == 2 && Find<TextBlock>("TranslationEngineFeedback").Text.Contains("已取消"), "S15", "取消终止在途请求并恢复测试按钮");
            Find<Button>("TranslationEngineTest").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            picker = Find<ComboBox>("TranslationEnginePicker"); picker.SelectedItem = EngineDefinition.Get(EngineId.Claude);
            await Task.Delay(150);
            Check(Find<TextBlock>("TranslationEngineFeedback").Text.Length == 0, "S16", "切换引擎取消旧测试，旧回调不污染新引擎提示");
            picker.SelectedItem = EngineDefinition.Get(EngineId.OpenAI);
            toggle = Find<CheckBox>("TranslationEngineEnabled"); ClickSwitch(toggle);
            var before = calls; Find<Button>("TranslationEngineTest").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent)); await Task.Delay(80);
            Check(calls == before && !Find<Button>("TranslationEngineTest").IsEnabled, "S17", "关闭的引擎即使触发测试处理也不会发请求");
            ClickSwitch(toggle);
            Find<Button>("TranslationEngineClear").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            Check(toggle.IsChecked == true && !isolated.Contains(EngineId.OpenAI, "apiKey") && Settings.TranslationOptions.EngineOptions.OpenAiModel == "synthetic-model",
                "S18", "清除所有凭据保留公开配置及启用选择");
            Check(new SettingsStore(Path.Combine(profile, "settings.json")).Load().Settings.TranslationOptions.EnabledEngines.HasFlag(EngineId.OpenAI), "S19", "启用意图实际写入磁盘，非仅界面状态");
            Find<PasswordBox>("TranslationField.apiKey").Password = "synthetic-test-only"; Find<Button>("TranslationEngineSave").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            Find<Button>("TranslationEngineTest").RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            ClickSwitch(toggle); await Await(() => !Find<Button>("TranslationEngineCancelTest").IsEnabled);
            Check(Find<TextBlock>("TranslationEngineFeedback").Text.Contains("已取消") && !Settings.TranslationOptions.EnabledEngines.HasFlag(EngineId.OpenAI),
                "S20", "在途测试期间关闭引擎会实际取消请求");
            if (Environment.GetCommandLineArgs().Contains("--verify-settings-input"))
            {
                ChangeTranslationOptions(new TranslationPreferences()); window.Close(); OpenSettings(); window = settingsWindow!; window.SelectTranslationSettings(); await SettleUI();
                Find<ComboBox>("TranslationEnginePicker").SelectedItem = EngineDefinition.Get(EngineId.OpenAI);
                Find<CheckBox>("TranslationEngineEnabled").BringIntoView(); await SettleUI();
                window.Title = "Velos 设置流程验收"; Desktop.ExcludeFromCapture(new WindowInteropHelper(window).Handle, false);
                File.WriteAllText(Path.Combine(profile, "等待设置操作.txt"), "独立设置与合成凭据；可切换引擎、点击开关。创建继续验收.txt 结束。");
                for (var i = 0; i < 3000 && !File.Exists(Path.Combine(profile, "继续验收.txt")); i++) await Task.Delay(100);
            }
            void Check(bool condition, string id, string message)
            { if (!condition) throw new InvalidOperationException($"[{id}] {message}"); results.Add($"通过  [{id}] {message}"); }
            T Find<T>(string id) where T : DependencyObject => Descendants(window).OfType<T>().Single(control => AutomationProperties.GetAutomationId(control) == id);
            async Task Await(Func<bool> done) { for (var i = 0; i < 100 && !done(); i++) await Task.Delay(30); if (!done()) throw new TimeoutException("设置流程未完成"); }
        }
        finally { settingsWindow?.Close(); isolated.ClearAll(); credentials = previous; translator = null; ChangeTranslationOptions(new TranslationPreferences()); }
    }
    private sealed class SettingsTranslationHandler(Func<CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
    { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => send(token); }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            foreach (var child in Descendants(VisualTreeHelper.GetChild(root, i))) yield return child;
    }
}
#endif
