using Velos.Core.Settings;
using Velos.Core.Translation;

namespace Velos;

public partial class App
{
    internal string TranslationField(EngineId engine, string field) => EngineDefinition.Get(engine).Fields.First(f => f.Id == field).Secret
        ? Credentials.Get(engine, field) : (Settings.TranslationOptions.EngineOptions ?? new()).Get(engine, field);
    internal bool HasTranslationField(EngineId engine, string field) => EngineDefinition.Get(engine).Fields.First(f => f.Id == field).Secret
        ? Credentials.Contains(engine, field) : !string.IsNullOrWhiteSpace(TranslationField(engine, field));

    private void MigrateTranslationOptions()
    {
        var options = Settings.TranslationOptions.EngineOptions ?? new TranslationEngineOptions();
        var migrated = new List<(EngineId Engine, string Field)>();
        try
        {
            foreach (var engine in EngineDefinition.All)
            foreach (var field in engine.Fields.Where(field => !field.Secret))
                if (Credentials.Contains(engine.Id, field.Id))
                {
                    if (string.IsNullOrWhiteSpace(options.Get(engine.Id, field.Id))) options = options.Set(engine.Id, field.Id, Credentials.Get(engine.Id, field.Id));
                    migrated.Add((engine.Id, field.Id));
                }
            if (migrated.Count == 0) return;
            if (!Save(Settings with { TranslationOptions = Settings.TranslationOptions with { EngineOptions = options } }, out var problem))
            { startupWarning ??= problem; return; }
            // 普通配置确认保存成功后，才移除旧版放在凭据管理器里的对应项；不读取机密字段。
            foreach (var item in migrated) Credentials.Set(item.Engine, item.Field, "");
        }
        catch { startupWarning ??= "旧版翻译服务配置暂未迁移完成，原凭据仍保留，请检查截屏翻译设置。"; }
    }
}
