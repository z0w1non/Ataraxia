Set-StrictMode -Version Latest

function New-AtaraxiaGuiLocalizedPresentation([scriptblock]$TextResolver) {
    if($TextResolver -isnot [scriptblock]){throw 'A GUI text resolver is required.'}
    $labelKeys=[ordered]@{
        settings_general='gui_task_settings';runtime_config='gui_runtime_config';theme='gui_theme';settings_model='gui_parameters';project_prompt='gui_project_prompt';session_prompt='gui_session_prompt';project_group='gui_projects';recent_sessions='gui_recent_sessions';task_name='gui_task_name';working_directory='gui_working_directory';model_file='gui_model_file';conversation='gui_conversation';parameter_preset_save='gui_parameter_preset_save';parameter_preset_save_as='gui_parameter_preset_save_as';parameter_preset_rename='gui_parameter_preset_rename';parameter_preset_delete='gui_parameter_preset_delete'
    }
    $tooltipKeys=[ordered]@{
        browse_config='gui_browse';new_session='gui_new_session';session_more='gui_session_more';project_prompt='gui_project_prompt';session_prompt='gui_session_prompt';new_project='gui_new_project';open_task='gui_open_task';browse_folder='gui_browse_folder';kobold_restart='gui_kobold_restart';refresh_models='gui_refresh_models';scroll_to_latest='gui_scroll_to_latest';new_task='gui_new_task';edit_last='gui_edit_last_query';send_run='gui_send_run'
    }
    $labels=[ordered]@{};foreach($name in $labelKeys.Keys){$labels[$name]=[string](& $TextResolver ([string]$labelKeys[$name]))}
    $menuLabels=[ordered]@{copy_request=[string](& $TextResolver 'gui_copy_request');copy_session_id=[string](& $TextResolver 'gui_copy_session_id');rename_session=[string](& $TextResolver 'gui_rename_session_button');session_prompt=[string](& $TextResolver 'gui_session_prompt')}
    $tooltips=[ordered]@{};foreach($name in $tooltipKeys.Keys){$tooltips[$name]=[string](& $TextResolver ([string]$tooltipKeys[$name]))}
    $themeOptions=@([pscustomobject]@{key='system';label=[string](& $TextResolver 'gui_theme_system')},[pscustomobject]@{key='light';label=[string](& $TextResolver 'gui_theme_light')},[pscustomobject]@{key='dark';label=[string](& $TextResolver 'gui_theme_dark')})
    return [pscustomobject][ordered]@{window_title='';window_tag=[string](& $TextResolver 'gui_copy_request');status_ready=[string](& $TextResolver 'gui_ready');labels=[pscustomobject]$labels;tooltips=[pscustomobject]$tooltips;menu_labels=[pscustomobject]$menuLabels;theme_options=$themeOptions}
}
