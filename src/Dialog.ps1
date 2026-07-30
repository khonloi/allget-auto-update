# ==============================================================================
# Shared UI Component: WinUI 3 Styled Adaptive Prompt Dialog
# ==============================================================================

# Immediately hide console window if visible (ensures console-less background launch)
try {
    $win32 = Add-Type -Name 'Win32' -Namespace 'Console' -MemberDefinition '
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    ' -PassThru -ErrorAction SilentlyContinue
    if ($win32) {
        $hWnd = $win32::GetConsoleWindow()
        if ($hWnd -ne [IntPtr]::Zero) { $null = $win32::ShowWindow($hWnd, 0) } # 0 = SW_HIDE
    }
}
catch {}

<#
.SYNOPSIS
    Displays a modern, WinUI 3 styled adaptive prompt dialog to the user.
.DESCRIPTION
    This function creates a WPF window styled to look like a native Windows 11
    dialog box. It asks the user for permission to close a background application
    so it can be updated. It automatically adapts to the user's light/dark theme
    and system accent colors. It includes a countdown timer that defaults to
    skipping the update if the user does not respond.
.PARAMETER appName
    The display name of the application requesting to be closed.
.PARAMETER appId
    The package identifier of the application.
.PARAMETER timeoutSeconds
    The number of seconds to wait for user input before automatically aborting.
.OUTPUTS
    A boolean indicating whether the user approved closing the application.
#>
function Dialog ($appName, $appId, $timeoutSeconds = 30) {
    try {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase
    }
    catch {
        $wshell = New-Object -ComObject Wscript.Shell
        $resp = $wshell.Popup("An update is available for '$appName'.`n`nThis application is currently running.`n`nDo you want to close '$appName' now and install the update?", $timeoutSeconds, "AllGet Auto-Update", 4 + 32 + 256 + 4096)
        return ($resp -eq 6)
    }

    # Detect Windows Light/Dark theme from registry
    $isDark = $true
    try {
        $themeVal = Get-ItemPropertyValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -ErrorAction SilentlyContinue
        if ($themeVal -eq 1) { $isDark = $false }
    }
    catch {}

    # Get Windows System Accent Color dynamically
    $accentHex = if ($isDark) { "#60CDFF" } else { "#005FB8" } # Default fallbacks
    try {
        $sysColor = [System.Windows.SystemParameters]::WindowGlassColor
        if ($sysColor) {
            $accentHex = "#{0:X2}{1:X2}{2:X2}" -f $sysColor.R, $sysColor.G, $sysColor.B
        }
    }
    catch {}

    # WinUI 3 Adaptive Color Tokens
    $bgContent = if ($isDark) { "#2B2B2B" } else { "#FBFBFB" }
    $bgFooter = if ($isDark) { "#272727" } else { "#F4F4F4" }
    $borderWin = if ($isDark) { "#424242" } else { "#C1C1C1" }
    $borderFooter = if ($isDark) { "#323232" } else { "#E5E5E5" }
    $textPrimary = if ($isDark) { "#FFFFFF" } else { "#1A1A1A" }
    $textSecondary = if ($isDark) { "#FFFFFF" } else { "#1A1A1A" }
    
    # Primary Accent Button
    $btnAccentBg = $accentHex
    $btnAccentText = "#FFFFFF"
    
    # Secondary Button (WinUI Light/Dark neutral button)
    $btnSecBg = if ($isDark) { "#2D2D2D" } else { "#FBFBFB" }
    $btnSecHoverBg = if ($isDark) { "#323232" } else { "#F6F6F6" }
    $btnSecPressedBg = if ($isDark) { "#272727" } else { "#F5F5F5" }
    $btnSecBorder = if ($isDark) { "#3D3D3D" } else { "#D1D1D1" }
    $btnSecText = if ($isDark) { "#FFFFFF" } else { "#1A1A1A" }
    $btnSecTextPressed = if ($isDark) { "#969696" } else { "#868686" }

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AllGet Auto-Update" Width="440" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" WindowStartupLocation="CenterScreen" ShowInTaskbar="True"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
    <Window.Resources>
        <!-- Primary Accent Button Style -->
        <Style x:Key="PrimaryButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="Segoe UI Variable, Segoe UI"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="Normal"/>
            <Setter Property="Height" Value="32"/>
            <Setter Property="Padding" Value="16,4,16,8"/>
            <Setter Property="HorizontalContentAlignment" Value="Center"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Foreground" Value="$btnAccentText"/>
            <Setter Property="Background" Value="$btnAccentBg"/>
            <Setter Property="BorderBrush" Value="$btnAccentBg"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" CornerRadius="4" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Opacity" Value="0.85"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Opacity" Value="0.7"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Secondary Button Style -->
        <Style x:Key="SecondaryButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="Segoe UI Variable, Segoe UI"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="Normal"/>
            <Setter Property="Height" Value="32"/>
            <Setter Property="Padding" Value="16,4,16,8"/>
            <Setter Property="HorizontalContentAlignment" Value="Center"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Foreground" Value="$btnSecText"/>
            <Setter Property="Background" Value="$btnSecBg"/>
            <Setter Property="BorderBrush" Value="$btnSecBorder"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" CornerRadius="4" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="$btnSecHoverBg"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="$btnSecPressedBg"/>
                                <Setter Property="Foreground" Value="$btnSecTextPressed"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    
    <!-- Outer WinUI ContentDialog Container -->
    <Border CornerRadius="8" Background="$bgContent" BorderBrush="$borderWin" BorderThickness="1" Margin="12">
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="20" ShadowDepth="4" Opacity="0.35"/>
        </Border.Effect>
        
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="*"/>      <!-- Main Content Area -->
                <RowDefinition Height="Auto"/>   <!-- Footer Button Bar -->
            </Grid.RowDefinitions>

            <!-- Top Content Area -->
            <StackPanel Grid.Row="0" Margin="24,32,24,24">
                <TextBlock Text="Close application to update?" FontFamily="Segoe UI Variable, Segoe UI" FontSize="20" LineHeight="28" FontWeight="SemiBold" Foreground="$textPrimary" Margin="0,0,0,12"/>
                
                <TextBlock FontFamily="Segoe UI Variable, Segoe UI" FontSize="14" LineHeight="20" Foreground="$textSecondary" TextWrapping="Wrap">
                    An update is available for <Run FontWeight="SemiBold" Foreground="$textPrimary">$appName</Run>. This application is currently running in the background.
                </TextBlock>
                
                <TextBlock Text="Would you like to close it now to install the update?" FontFamily="Segoe UI Variable, Segoe UI" FontSize="14" LineHeight="20" Foreground="$textSecondary" TextWrapping="Wrap" Margin="0,8,0,0"/>

                <!-- Countdown Timer Section -->
                <StackPanel Margin="0,20,0,0">
                    <Grid Margin="0,0,0,6">
                        <TextBlock x:Name="lblTimer" Text="Skipping in $timeoutSeconds seconds..." FontFamily="Segoe UI Variable, Segoe UI" FontSize="14" LineHeight="20" Foreground="$textSecondary"/>
                    </Grid>
                </StackPanel>
            </StackPanel>

            <!-- Bottom WinUI Footer Bar -->
            <Border Grid.Row="1" Background="$bgFooter" BorderBrush="$borderFooter" BorderThickness="0,1,0,0" CornerRadius="0,0,8,8" Padding="24">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="12"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Button x:Name="btnUpdate" Grid.Column="0" Content="Close &amp; Update" Style="{StaticResource PrimaryButtonStyle}" IsDefault="True"/>
                    <Button x:Name="btnSkip" Grid.Column="2" Content="Skip for Now" Style="{StaticResource SecondaryButtonStyle}" IsCancel="True"/>
                </Grid>
            </Border>
        </Grid>
    </Border>
</Window>
"@

    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::New($xaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)
    
    $btnUpdate = $window.FindName("btnUpdate")
    $btnSkip = $window.FindName("btnSkip")
    $lblTimer = $window.FindName("lblTimer")

    $state = @{
        Result    = $false
        Remaining = $timeoutSeconds
    }

    $btnUpdate.Add_Click({
            $state.Result = $true
            $window.Close()
        })
    $btnSkip.Add_Click({
            $state.Result = $false
            $window.Close()
        })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)

    $timer.Add_Tick({
            $state.Remaining--
            if ($state.Remaining -le 0) {
                $timer.Stop()
                $state.Result = $false
                $window.Close()
            }
            else {
                $lblTimer.Text = "Skipping in $($state.Remaining) seconds..."
            }
        })

    $timer.Start()
    $null = $window.ShowDialog()
    $timer.Stop()

    return $state.Result
}
