Set-StrictMode -Version Latest

function New-AtaraxiaWpfSmoothExpanderRegistry {return ,([System.Collections.Generic.HashSet[int]]::new())}

function Enable-AtaraxiaWpfSmoothExpander([Windows.Controls.Expander]$Expander,[object]$Port,[System.Collections.Generic.HashSet[int]]$RegisteredExpanders) {
    if($null -eq $Expander -or $null -eq $Port -or $null -eq $RegisteredExpanders){return}
    $Expander.ApplyTemplate()
    $clip=$Expander.Template.FindName('ExpandClip',$Expander);$content=$Expander.Template.FindName('ExpandSite',$Expander)
    if($null -eq $clip -or $null -eq $content){return}
    $id=[Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Expander)
    if(-not $RegisteredExpanders.Add($id)){return}
    if($Expander.IsExpanded){$clip.Visibility=[Windows.Visibility]::Visible;$clip.Height=[double]::NaN;$clip.Opacity=1}
    $Expander.Add_Expanded({
        $clipPart=$this.Template.FindName('ExpandClip',$this);$contentPart=$this.Template.FindName('ExpandSite',$this)
        if($null -eq $clipPart -or $null -eq $contentPart){return}
        $startHeight=if($clipPart.Visibility -eq [Windows.Visibility]::Visible){[Math]::Max(0,$clipPart.ActualHeight)}else{0}
        $startOpacity=if($clipPart.Visibility -eq [Windows.Visibility]::Visible){$clipPart.Opacity}else{0}
        $clipPart.BeginAnimation([Windows.FrameworkElement]::HeightProperty,$null);$clipPart.BeginAnimation([Windows.UIElement]::OpacityProperty,$null)
        $clipPart.Visibility=[Windows.Visibility]::Visible;$clipPart.Height=$startHeight;$clipPart.Opacity=$startOpacity;$owner=$this
        Schedule-AtaraxiaGuiViewCallback $Port 'normal' {
            $availableWidth=[Math]::Max(1,$owner.ActualWidth);$clipPart.Height=[double]::NaN
            $clipPart.Measure([Windows.Size]::new($availableWidth,[double]::PositiveInfinity));$targetHeight=$contentPart.DesiredSize.Height
            if($targetHeight -le 0){$targetHeight=$contentPart.ActualHeight}
            if($targetHeight -le 0){$clipPart.Height=[double]::NaN;$clipPart.Opacity=1;return}
            $clipPart.Height=$startHeight;$duration=[Windows.Duration]::new([TimeSpan]::FromMilliseconds(190));$ease=[Windows.Media.Animation.CubicEase]::new();$ease.EasingMode=[Windows.Media.Animation.EasingMode]::EaseOut
            $heightAnimation=[Windows.Media.Animation.DoubleAnimation]::new($startHeight,$targetHeight,$duration);$heightAnimation.EasingFunction=$ease
            $opacityAnimation=[Windows.Media.Animation.DoubleAnimation]::new($startOpacity,1,$duration);$opacityAnimation.EasingFunction=$ease
            $clipPart.BeginAnimation([Windows.FrameworkElement]::HeightProperty,$heightAnimation);$clipPart.BeginAnimation([Windows.UIElement]::OpacityProperty,$opacityAnimation)
        }.GetNewClosure()
    }.GetNewClosure())
    $Expander.Add_Collapsed({
        $clipPart=$this.Template.FindName('ExpandClip',$this)
        if($null -eq $clipPart -or $clipPart.Visibility -ne [Windows.Visibility]::Visible){return}
        $startHeight=[Math]::Max(0,$clipPart.ActualHeight);$startOpacity=$clipPart.Opacity
        $clipPart.BeginAnimation([Windows.FrameworkElement]::HeightProperty,$null);$clipPart.BeginAnimation([Windows.UIElement]::OpacityProperty,$null)
        $clipPart.Height=$startHeight;$clipPart.Visibility=[Windows.Visibility]::Visible;$duration=[Windows.Duration]::new([TimeSpan]::FromMilliseconds(160));$ease=[Windows.Media.Animation.CubicEase]::new();$ease.EasingMode=[Windows.Media.Animation.EasingMode]::EaseIn
        $heightAnimation=[Windows.Media.Animation.DoubleAnimation]::new($startHeight,0,$duration);$heightAnimation.EasingFunction=$ease;$expanderForCompletion=$this
        $heightAnimation.Add_Completed({$clipTarget=$expanderForCompletion.Template.FindName('ExpandClip',$expanderForCompletion);if($null -ne $clipTarget -and -not $expanderForCompletion.IsExpanded){$clipTarget.Visibility=[Windows.Visibility]::Collapsed;$clipTarget.Height=0;$clipTarget.Opacity=0}}.GetNewClosure())
        $opacityAnimation=[Windows.Media.Animation.DoubleAnimation]::new($startOpacity,0,$duration);$opacityAnimation.EasingFunction=$ease
        $clipPart.BeginAnimation([Windows.FrameworkElement]::HeightProperty,$heightAnimation);$clipPart.BeginAnimation([Windows.UIElement]::OpacityProperty,$opacityAnimation)
    }.GetNewClosure())
}

function Register-AtaraxiaWpfSmoothExpanders([Windows.DependencyObject]$Root,[object]$Port,[System.Collections.Generic.HashSet[int]]$RegisteredExpanders) {
    if($null -eq $Root){return}
    $pending=[System.Collections.Generic.Stack[Windows.DependencyObject]]::new();$pending.Push($Root)
    while($pending.Count -gt 0){$node=$pending.Pop();if($node -is [Windows.Controls.Expander]){Enable-AtaraxiaWpfSmoothExpander $node $Port $RegisteredExpanders};try{$count=[Windows.Media.VisualTreeHelper]::GetChildrenCount($node)}catch{continue};for($i=0;$i -lt $count;$i++){$child=[Windows.Media.VisualTreeHelper]::GetChild($node,$i);if($null -ne $child){$pending.Push($child)}}}
}
