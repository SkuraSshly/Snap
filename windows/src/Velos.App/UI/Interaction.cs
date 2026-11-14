using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Media3D;

namespace Velos.UI;

internal static class Interaction
{
    // Routed events can originate in a glyph, border or thumb inside a control.
    internal static bool IsControl(object? origin)
    {
        for (var current = origin as DependencyObject; current is not null;)
        {
            if (current is ButtonBase or ScrollBar or Thumb or TextBoxBase or Slider or ComboBox) return true;
            current = current is Visual or Visual3D ? VisualTreeHelper.GetParent(current) : LogicalTreeHelper.GetParent(current);
        }
        return false;
    }
    internal static void SetAction(Button button, ActionIcon icon, string label)
    {
        button.Content = new ActionIconView(icon, 14); button.ToolTip = label;
        System.Windows.Automation.AutomationProperties.SetName(button, label);
        System.Windows.Automation.AutomationProperties.SetHelpText(button, label);
    }
}
