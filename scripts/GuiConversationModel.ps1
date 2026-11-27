Set-StrictMode -Version Latest

function ConvertFrom-AtaraxiaSvgGeometry([string]$SvgText) {
    if([string]::IsNullOrWhiteSpace($SvgText)){return ''}
    $document=[xml]$SvgText
    $geometry=[System.Collections.Generic.List[string]]::new()
    foreach($node in $document.SelectNodes("//*[local-name()='path']")){$data=[string]$node.GetAttribute('d');if(-not[string]::IsNullOrWhiteSpace($data)){$geometry.Add($data)}}
    foreach($node in $document.SelectNodes("//*[local-name()='circle']")){$cx=[double]$node.GetAttribute('cx');$cy=[double]$node.GetAttribute('cy');$radius=[double]$node.GetAttribute('r');if($radius -gt 0){$geometry.Add(('M{0},{1} A{2},{2} 0 1 0 {3},{1} A{2},{2} 0 1 0 {0},{1} Z' -f ($cx+$radius),$cy,$radius,($cx-$radius)))}}
    foreach($node in $document.SelectNodes("//*[local-name()='rect']")){$x=[double]$node.GetAttribute('x');$y=[double]$node.GetAttribute('y');$width=[double]$node.GetAttribute('width');$height=[double]$node.GetAttribute('height');if($width -gt 0 -and $height -gt 0){$geometry.Add(('M{0},{1} H{2} V{3} H{0} Z' -f $x,$y,($x+$width),($y+$height)))}}
    return ($geometry -join ' ')
}

function ConvertTo-AtaraxiaConversationView([object]$Conversation,[object]$State,[System.Collections.IDictionary]$RoleIconGeometry=@{}) {
    $items=[System.Collections.Generic.List[object]]::new()
    foreach($entry in @($Conversation.entries)){
        $items.Add([pscustomobject]@{heading='You';body=[string]$entry.body;kind='user';role_id='';icon_geometry='';timestamp=[string]$entry.timestamp;is_expanded=$false})
    }
    $lastReport=$null
    foreach($entry in @($State.history)){
        if($null -eq $entry.report){continue}
        $roleId=([string]$entry.role).ToLowerInvariant()
        $geometry=if($RoleIconGeometry.Contains($roleId)){$RoleIconGeometry[$roleId]}else{''}
        $reportItem=[pscustomobject]@{heading="[$($entry.role)] $($entry.report.heading)";body=[string]$entry.report.body;kind='report';role_id=$roleId;icon_geometry=$geometry;timestamp=[string]$entry.timestamp;is_expanded=$false}
        $items.Add($reportItem)
        $lastReport=$reportItem
    }
    if($null -ne $lastReport){$lastReport.is_expanded=$true}
    return @($items|Sort-Object {if([string]::IsNullOrWhiteSpace($_.timestamp)){''}else{$_.timestamp}})
}
