using System.Globalization;
using Microsoft.Windows.ApplicationModel.Resources;

namespace OBSMirror.ControlCenter.Localization;

/// <summary>
/// 本地化入口。
///
/// 设计约定（见 docs/LOCALIZATION.md）：
/// 1. 英文原文继续保留在 XAML 与 C# 代码中，同时写入 Strings/en-US/Resources.resw；
/// 2. 其他语言（如 Strings/zh-CN/Resources.resw）只提供覆盖值；
/// 3. 任何资源查找失败都静默回退到调用点传入的英文原文，因此缺少语言包绝不会产生空白界面；
/// 4. 语言默认跟随系统，可用环境变量 OBSMIRROR_LANG（例如 zh-CN / en-US）强制指定。
/// </summary>
internal static class Loc
{
    private const string LanguageOverrideVariable = "OBSMIRROR_LANG";

    private static readonly Dictionary<string, string> Cache = new(StringComparer.Ordinal);
    private static readonly ResourceLoader? Loader = CreateLoader();

    /// <summary>当前生效的资源语言标记，仅用于日志诊断。</summary>
    public static string CurrentLanguage { get; private set; } = "en-US";

    /// <summary>语言覆盖是否来自环境变量。</summary>
    public static bool IsOverridden { get; private set; }

    /// <summary>
    /// 在创建任何窗口之前调用。必须在 XAML 资源解析之前设置语言覆盖，
    /// 否则 x:Uid 会按系统语言解析。
    /// </summary>
    public static void Initialize()
    {
        try
        {
            var requested = Environment.GetEnvironmentVariable(LanguageOverrideVariable);
            if (!string.IsNullOrWhiteSpace(requested))
            {
                Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride = requested.Trim();
                IsOverridden = true;
            }
        }
        catch
        {
            // 非打包应用上语言覆盖可能不可用；这不是致命问题，继续跟随系统语言。
            IsOverridden = false;
        }

        CurrentLanguage = DescribeEffectiveLanguage();
    }

    /// <summary>按键取本地化文本；缺失或查找失败时返回 english。</summary>
    public static string S(string key, string english)
    {
        if (Cache.TryGetValue(key, out var cached))
        {
            return cached;
        }

        var resolved = english;
        try
        {
            var value = Loader?.GetString(key);
            if (!string.IsNullOrEmpty(value))
            {
                resolved = value;
            }
        }
        catch
        {
            // 资源键缺失或资源索引不可读时保持英文原文。
            resolved = english;
        }

        Cache[key] = resolved;
        return resolved;
    }

    /// <summary>按键取带占位符的本地化格式串并填充参数。</summary>
    public static string F(string key, string english, params object?[] args)
    {
        var format = S(key, english);
        try
        {
            return string.Format(CultureInfo.CurrentCulture, format, args);
        }
        catch (FormatException)
        {
            // 译文占位符写错时退回英文格式串，避免抛异常打断界面刷新。
            return string.Format(CultureInfo.CurrentCulture, english, args);
        }
    }

    private static ResourceLoader? CreateLoader()
    {
        try
        {
            return new ResourceLoader();
        }
        catch
        {
            return null;
        }
    }

    private static string DescribeEffectiveLanguage()
    {
        try
        {
            var languages = Windows.Globalization.ApplicationLanguages.Languages;
            if (languages.Count > 0)
            {
                return languages[0];
            }
        }
        catch
        {
            // 退回到 .NET 的当前 UI 区域性。
        }

        return CultureInfo.CurrentUICulture.Name;
    }
}
