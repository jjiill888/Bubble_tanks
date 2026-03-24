extends Control

signal update_channel_changed(channel: String)

const EXTERNAL_VERSION_INFO_FILE_NAME := "version.json"
const VERSION_INFO_PATH := "res://version.json"
const STATE_PATH := "user://update_state.json"
const DOWNLOAD_DIR := "user://updates"
const CHECK_DELAY_SECONDS := 1.5
const PANEL_WIDTH := 430.0
const PANEL_HEIGHT := 264.0
const TOAST_WIDTH := 320.0
const TOAST_HEIGHT := 92.0
const TOAST_DURATION_SECONDS := 2.8
const DOWNLOAD_SAMPLE_WINDOW_MS := 800
const UPDATE_LOG_PREFIX := "[UpdateManager]"

var _version_info: Dictionary = {}
var _state: Dictionary = {}
var _remote_manifest: Dictionary = {}
var _remote_package: Dictionary = {}
var _latest_version := ""
var _download_path := ""
var _download_started_at_ms := 0
var _last_sample_time_ms := 0
var _last_sample_bytes := 0
var _download_speed_bytes_per_second := 0.0
var _download_total_bytes := 0
var _status := "idle"
var _show_no_update_feedback := false
var _manual_check_in_progress := false

var _manifest_http: HTTPRequest = null
var _download_http: HTTPRequest = null
var _panel: PanelContainer = null
var _toast_panel: PanelContainer = null
var _toast_timer: Timer = null
var _title_label: Label = null
var _summary_label: Label = null
var _details_label: Label = null
var _toast_summary_label: Label = null
var _toast_details_label: Label = null
var _progress_bar: ProgressBar = null
var _progress_label: Label = null
var _primary_button: Button = null
var _secondary_button: Button = null
var _skip_button: Button = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(PRESET_FULL_RECT)
	_load_version_info()
	_load_state()
	_build_ui()
	print("%s version=%s channel=%s manifest=%s platform=%s" % [
		UPDATE_LOG_PREFIX,
		String(_version_info.get("version", "")),
		get_update_channel(),
		String(_version_info.get("manifest_url", "")).strip_edges(),
		_get_platform_key()
	])
	if _can_check_for_updates(true):
		_setup_http_nodes()
	if _can_run_update_flow():
		get_tree().create_timer(CHECK_DELAY_SECONDS, true).timeout.connect(_check_for_updates)
	else:
		print("%s update flow disabled" % UPDATE_LOG_PREFIX)

func _process(_delta: float) -> void:
	if _status != "downloading" or _download_http == null:
		return
	var downloaded_bytes := _download_http.get_downloaded_bytes()
	var body_size := _download_http.get_body_size()
	if _download_total_bytes <= 0:
		_download_total_bytes = int(_remote_package.get("size", 0))
		if _download_total_bytes <= 0 and body_size > 0:
			_download_total_bytes = body_size
	var now_ms := Time.get_ticks_msec()
	if now_ms - _last_sample_time_ms >= DOWNLOAD_SAMPLE_WINDOW_MS:
		var elapsed_seconds := maxf(float(now_ms - _last_sample_time_ms) / 1000.0, 0.001)
		_download_speed_bytes_per_second = maxf(float(downloaded_bytes - _last_sample_bytes) / elapsed_seconds, 0.0)
		_last_sample_time_ms = now_ms
		_last_sample_bytes = downloaded_bytes
	_update_download_ui(downloaded_bytes)

func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -PANEL_WIDTH - 20.0
	_panel.offset_right = -20.0
	_panel.offset_top = -PANEL_HEIGHT - 20.0
	_panel.offset_bottom = -20.0
	add_child(_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	_panel.add_child(root)

	_title_label = Label.new()
	_title_label.text = "发现新版本"
	_title_label.add_theme_font_size_override("font_size", 26)
	root.add_child(_title_label)

	_summary_label = Label.new()
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary_label.text = ""
	root.add_child(_summary_label)

	_details_label = Label.new()
	_details_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details_label.text = ""
	root.add_child(_details_label)

	_progress_bar = ProgressBar.new()
	_progress_bar.visible = false
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 1.0
	_progress_bar.show_percentage = false
	root.add_child(_progress_bar)

	_progress_label = Label.new()
	_progress_label.visible = false
	_progress_label.text = ""
	root.add_child(_progress_label)

	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	root.add_child(action_row)

	_primary_button = Button.new()
	_primary_button.text = "立即更新"
	_primary_button.pressed.connect(_on_primary_pressed)
	action_row.add_child(_primary_button)

	_secondary_button = Button.new()
	_secondary_button.text = "稍后提醒"
	_secondary_button.pressed.connect(_on_secondary_pressed)
	action_row.add_child(_secondary_button)

	_skip_button = Button.new()
	_skip_button.text = "跳过此版本"
	_skip_button.pressed.connect(_on_skip_pressed)
	action_row.add_child(_skip_button)

	_toast_panel = PanelContainer.new()
	_toast_panel.visible = false
	_toast_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_panel.anchor_left = 1.0
	_toast_panel.anchor_right = 1.0
	_toast_panel.anchor_top = 1.0
	_toast_panel.anchor_bottom = 1.0
	_toast_panel.offset_left = -TOAST_WIDTH - 20.0
	_toast_panel.offset_right = -20.0
	_toast_panel.offset_top = -TOAST_HEIGHT - 20.0
	_toast_panel.offset_bottom = -20.0
	add_child(_toast_panel)

	var toast_root := VBoxContainer.new()
	toast_root.add_theme_constant_override("separation", 4)
	_toast_panel.add_child(toast_root)

	_toast_summary_label = Label.new()
	_toast_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_summary_label.add_theme_font_size_override("font_size", 20)
	toast_root.add_child(_toast_summary_label)

	_toast_details_label = Label.new()
	_toast_details_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toast_root.add_child(_toast_details_label)

	_toast_timer = Timer.new()
	_toast_timer.one_shot = true
	_toast_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_toast_timer.timeout.connect(_on_toast_timeout)
	add_child(_toast_timer)

func _set_prompt_visible(visible: bool) -> void:
	if _panel != null:
		_panel.visible = visible
	if visible:
		_hide_toast()

func request_manual_update_check() -> void:
	if not _can_check_for_updates(true):
		_show_manual_status("更新功能当前不可用。", "请确认当前平台支持联网检查，并且 version.json 中存在 manifest_url。")
		return
	if _status == "checking":
		_show_manual_status("正在检查更新。", "请稍候，检查完成后会在这里显示结果。")
		return
	_show_no_update_feedback = true
	_manual_check_in_progress = true
	_show_manual_status("正在检查更新。", "请稍候，检查完成后会在这里显示结果。", 1.6)
	_check_for_updates(true)

func get_update_channel_label() -> String:
	return "Nightly 渠道" if get_update_channel() == "night" else "Stable 渠道"

func _show_manual_status(summary: String, details: String = "", duration: float = TOAST_DURATION_SECONDS) -> void:
	_status = "idle"
	_show_toast(summary, details, duration)

func _show_toast(summary: String, details: String = "", duration: float = TOAST_DURATION_SECONDS) -> void:
	if _toast_summary_label == null or _toast_details_label == null or _toast_timer == null:
		return
	_set_prompt_visible(false)
	_toast_summary_label.text = summary
	_toast_details_label.text = details
	_toast_details_label.visible = not details.is_empty()
	_toast_panel.visible = true
	_toast_timer.stop()
	_toast_timer.start(maxf(duration, 0.1))

func _hide_toast() -> void:
	if _toast_panel != null:
		_toast_panel.visible = false
	if _toast_timer != null:
		_toast_timer.stop()

func _on_toast_timeout() -> void:
	_hide_toast()

func _setup_http_nodes() -> void:
	_manifest_http = HTTPRequest.new()
	_manifest_http.process_mode = Node.PROCESS_MODE_ALWAYS
	_manifest_http.timeout = 8.0
	_manifest_http.request_completed.connect(_on_manifest_request_completed)
	add_child(_manifest_http)

	_download_http = HTTPRequest.new()
	_download_http.process_mode = Node.PROCESS_MODE_ALWAYS
	_download_http.timeout = 0.0
	_download_http.request_completed.connect(_on_download_request_completed)
	add_child(_download_http)

func _load_version_info() -> void:
	_version_info.clear()
	var external_path := _get_external_version_info_path()
	if not external_path.is_empty():
		_version_info = _read_json_dictionary(external_path)
	if _version_info.is_empty():
		_version_info = _read_json_dictionary(VERSION_INFO_PATH)

func _get_external_version_info_path() -> String:
	if Engine.is_editor_hint() or OS.has_feature("editor"):
		return ""
	var executable_path := OS.get_executable_path().strip_edges()
	if executable_path.is_empty():
		return ""
	return executable_path.get_base_dir().path_join(EXTERNAL_VERSION_INFO_FILE_NAME)

func _read_json_dictionary(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed
	return {}

func _load_state() -> void:
	_state.clear()
	if not FileAccess.file_exists(STATE_PATH):
		return
	var file := FileAccess.open(STATE_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		_state = parsed

func _save_state() -> void:
	var file := FileAccess.open(STATE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(_state, "  "))

func _can_run_update_flow() -> bool:
	if _is_editor_runtime():
		return false
	return _can_check_for_updates(false)

func _can_check_for_updates(allow_editor: bool = false) -> bool:
	if not allow_editor and _is_editor_runtime():
		return false
	if OS.has_feature("web") or OS.has_feature("android") or OS.has_feature("ios"):
		return false
	var manifest_url := String(_version_info.get("manifest_url", "")).strip_edges()
	return not manifest_url.is_empty() and not _get_platform_key().is_empty()

func _is_editor_runtime() -> bool:
	return Engine.is_editor_hint() or OS.has_feature("editor")

func _get_platform_key() -> String:
	var architecture := "arm64" if OS.has_feature("arm64") else "x64"
	var os_name := OS.get_name().to_lower()
	if OS.has_feature("windows") or os_name == "windows":
		return "windows-%s" % architecture
	if OS.has_feature("linuxbsd") or os_name == "linux":
		return "linux-%s" % architecture
	return ""

func _build_manifest_request_url() -> String:
	var manifest_url := String(_version_info.get("manifest_url", "")).strip_edges()
	if manifest_url.is_empty():
		return ""
	var separator := "&" if manifest_url.contains("?") else "?"
	return "%s%scb=%d" % [manifest_url, separator, int(Time.get_unix_time_from_system())]

func _check_for_updates(allow_editor: bool = false) -> void:
	if not _can_check_for_updates(allow_editor) or _manifest_http == null:
		print("%s skipped update check; enabled=%s http_ready=%s allow_editor=%s" % [UPDATE_LOG_PREFIX, _can_check_for_updates(allow_editor), _manifest_http != null, allow_editor])
		if _manual_check_in_progress:
			_manual_check_in_progress = false
			_show_no_update_feedback = false
			_show_manual_status("无法检查更新。", "更新组件尚未准备完成，请稍后再试。")
		return
	_status = "checking"
	var headers := PackedStringArray(["Accept: application/json", "Cache-Control: no-cache"])
	var manifest_url := _build_manifest_request_url()
	print("%s checking manifest %s" % [UPDATE_LOG_PREFIX, manifest_url])
	var err := _manifest_http.request(manifest_url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		_status = "idle"
		print("%s manifest request failed to start: %s" % [UPDATE_LOG_PREFIX, err])
		if _manual_check_in_progress:
			_manual_check_in_progress = false
			_show_no_update_feedback = false
			_show_manual_status("无法检查更新。", "检查请求启动失败，请稍后重试。")

func _on_manifest_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_status = "idle"
	print("%s manifest completed result=%s code=%s bytes=%s" % [UPDATE_LOG_PREFIX, result, response_code, body.size()])
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		print("%s manifest request did not succeed" % UPDATE_LOG_PREFIX)
		_manual_check_in_progress = false
		if _show_no_update_feedback:
			_show_no_update_feedback = false
			_show_manual_status("无法检查更新。", "请稍后重试，或直接前往发布页下载。")
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		print("%s manifest JSON parse failed" % UPDATE_LOG_PREFIX)
		_manual_check_in_progress = false
		if _show_no_update_feedback:
			_show_no_update_feedback = false
			_show_manual_status("更新数据解析失败。", "请稍后重试。")
		return
	_remote_manifest = parsed
	_latest_version = String(_remote_manifest.get("latest_version", "")).strip_edges()
	print("%s latest=%s local=%s" % [UPDATE_LOG_PREFIX, _latest_version, String(_version_info.get("version", "0.0.0"))])
	if _latest_version.is_empty():
		_manual_check_in_progress = false
		if _show_no_update_feedback:
			_show_no_update_feedback = false
			_show_manual_status("暂时没有可用更新信息。")
		return
	if _compare_versions(_latest_version, String(_version_info.get("version", "0.0.0"))) <= 0:
		print("%s no newer version available" % UPDATE_LOG_PREFIX)
		_manual_check_in_progress = false
		if _show_no_update_feedback:
			_show_no_update_feedback = false
			_show_manual_status("当前已经是最新版本。", "当前版本 %s" % String(_version_info.get("version", "0.0.0")))
		return
	if String(_state.get("skipped_version", "")) == _latest_version:
		print("%s latest version previously skipped" % UPDATE_LOG_PREFIX)
		_manual_check_in_progress = false
		if _show_no_update_feedback:
			_show_no_update_feedback = false
			_show_manual_status("这个版本之前已被跳过。", "如需再次提醒，可切换渠道或等待下一个版本。")
		return
	var channels: Dictionary = _remote_manifest.get("channels", {})
	var channel_name := get_update_channel()
	var channel_manifest: Dictionary = channels.get(channel_name, {})
	_remote_package = channel_manifest.get(_get_platform_key(), {})
	if _remote_package.is_empty():
		print("%s missing package for channel=%s platform=%s" % [UPDATE_LOG_PREFIX, channel_name, _get_platform_key()])
		_manual_check_in_progress = false
		if _show_no_update_feedback:
			_show_no_update_feedback = false
			_show_manual_status("当前渠道没有适用于本机的更新包。", get_update_channel_label())
		return
	print("%s update available package=%s" % [UPDATE_LOG_PREFIX, JSON.stringify(_remote_package)])
	_manual_check_in_progress = false
	_show_no_update_feedback = false
	_show_update_prompt()

func get_update_channel() -> String:
	var configured_channel := String(_state.get("preferred_channel", "")).strip_edges().to_lower()
	if configured_channel in ["stable", "night"]:
		return configured_channel
	var default_channel := String(_version_info.get("channel", "stable")).strip_edges().to_lower()
	return default_channel if default_channel in ["stable", "night"] else "stable"

func toggle_update_channel() -> String:
	var next_channel := "night" if get_update_channel() == "stable" else "stable"
	_state["preferred_channel"] = next_channel
	_state.erase("skipped_version")
	_save_state()
	emit_signal("update_channel_changed", next_channel)
	if _can_run_update_flow():
		_remote_package.clear()
		_set_prompt_visible(false)
		_check_for_updates()
	return next_channel

func _show_update_prompt() -> void:
	var current_version := String(_version_info.get("version", "0.0.0"))
	var package_size := int(_remote_package.get("size", 0))
	_hide_toast()
	_title_label.text = "发现新版本 %s" % _latest_version
	_summary_label.text = "当前版本 %s，可更新到 %s。" % [current_version, _latest_version]
	var details := PackedStringArray()
	if package_size > 0:
		details.append("下载大小: %s" % _format_bytes(package_size))
	var notes := String(_remote_manifest.get("release_notes", "")).strip_edges()
	if not notes.is_empty():
		details.append(notes)
	var minimum_supported := String(_remote_manifest.get("minimum_supported_version", "")).strip_edges()
	if not minimum_supported.is_empty() and _compare_versions(current_version, minimum_supported) < 0:
		details.append("当前版本已低于最低支持版本，建议立即更新。")
	if _is_editor_runtime():
		details.append("当前在 Godot 编辑器中运行，只能检查更新并打开发布页，不能直接安装。")
	_details_label.text = "\n".join(details)
	_progress_bar.visible = false
	_progress_label.visible = false
	_primary_button.text = "打开发布页" if _is_editor_runtime() else "立即更新"
	_primary_button.disabled = false
	_secondary_button.text = "关闭" if _is_editor_runtime() else "稍后提醒"
	_secondary_button.disabled = false
	_skip_button.visible = not _is_editor_runtime()
	_skip_button.disabled = false
	_set_prompt_visible(true)

func _on_primary_pressed() -> void:
	if _primary_button.text == "知道了":
		_set_prompt_visible(false)
		return
	if _primary_button.text == "打开发布页":
		var release_page := String(_version_info.get("release_page", "")).strip_edges()
		if release_page.is_empty():
			release_page = String(_remote_manifest.get("release_page", "")).strip_edges()
		if release_page.is_empty():
			_show_manual_status("未配置发布页地址。", "请检查 version.json 中的 release_page。")
			return
		var err := OS.shell_open(release_page)
		if err != OK:
			_show_manual_status("无法打开发布页。", release_page)
			return
		_set_prompt_visible(false)
		return
	if _status == "downloading":
		return
	_start_download()

func _on_secondary_pressed() -> void:
	if _status == "downloading":
		_cancel_download()
	_set_prompt_visible(false)

func _on_skip_pressed() -> void:
	_state["skipped_version"] = _latest_version
	_save_state()
	_set_prompt_visible(false)

func _start_download() -> void:
	var url := String(_remote_package.get("url", "")).strip_edges()
	if url.is_empty() or _download_http == null:
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DOWNLOAD_DIR))
	var filename := String(_remote_package.get("filename", url.get_file())).strip_edges()
	if filename.is_empty():
		filename = "bubble-tanks-update.bin"
	_download_path = DOWNLOAD_DIR.path_join(filename)
	if FileAccess.file_exists(_download_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_download_path))
	_download_http.download_file = _download_path
	_download_total_bytes = int(_remote_package.get("size", 0))
	_download_started_at_ms = Time.get_ticks_msec()
	_last_sample_time_ms = _download_started_at_ms
	_last_sample_bytes = 0
	_download_speed_bytes_per_second = 0.0
	_status = "downloading"
	_progress_bar.visible = true
	_progress_label.visible = true
	_progress_bar.value = 0.0
	_primary_button.disabled = true
	_secondary_button.text = "取消下载"
	_skip_button.visible = false
	_summary_label.text = "正在下载更新包。"
	_details_label.text = ""
	var headers := PackedStringArray(["Accept: application/octet-stream"])
	var err := _download_http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		_show_error("更新下载启动失败。")

func _cancel_download() -> void:
	if _download_http != null:
		_download_http.cancel_request()
	_status = "idle"
	_primary_button.disabled = false
	_secondary_button.text = "稍后提醒"
	_skip_button.visible = true
	if not _download_path.is_empty() and FileAccess.file_exists(_download_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_download_path))

func _on_download_request_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if _status != "downloading":
		return
	_status = "verifying"
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_show_error("更新下载失败。")
		return
	var expected_sha256 := String(_remote_package.get("sha256", "")).to_lower().strip_edges()
	if not expected_sha256.is_empty():
		var actual_sha256 := _sha256_for_file(_download_path)
		if actual_sha256 != expected_sha256:
			_show_error("更新校验失败，已阻止安装。")
			return
	_summary_label.text = "下载完成，准备启动安装器。"
	_progress_label.text = "已完成 %s" % _format_bytes(maxi(_download_total_bytes, _download_http.get_downloaded_bytes()))
	_primary_button.disabled = true
	_secondary_button.disabled = true
	_skip_button.disabled = true
	_launch_installer()

func _launch_installer() -> void:
	var executable_path := OS.get_executable_path()
	if executable_path.is_empty():
		_show_error("未能解析当前安装目录。")
		return
	var install_dir := executable_path.get_base_dir()
	var executable_name := executable_path.get_file()
	var expected_sha256 := String(_remote_package.get("sha256", "")).strip_edges()
	var pid := -1
	if OS.has_feature("windows"):
		var script_path := install_dir.path_join("updater").path_join("install_update.ps1")
		if not FileAccess.file_exists(script_path):
			_show_error("未找到 Windows 安装脚本。")
			return
		var args := PackedStringArray([
			"-ExecutionPolicy",
			"Bypass",
			"-File",
			script_path,
			"-PackagePath",
			ProjectSettings.globalize_path(_download_path),
			"-InstallDir",
			install_dir,
			"-ExecutableName",
			executable_name
		])
		if not expected_sha256.is_empty():
			args.append("-ExpectedSha256")
			args.append(expected_sha256)
		pid = OS.create_process("powershell", args, false)
	elif OS.has_feature("linuxbsd"):
		var script_path := install_dir.path_join("updater").path_join("install_update.sh")
		if not FileAccess.file_exists(script_path):
			_show_error("未找到 Linux 安装脚本。")
			return
		var args := PackedStringArray([
			script_path,
			ProjectSettings.globalize_path(_download_path),
			install_dir,
			executable_name,
			expected_sha256
		])
		pid = OS.create_process("/bin/sh", args, false)
	if pid == -1:
		_show_error("启动安装器失败。")
		return
	get_tree().quit()

func _update_download_ui(downloaded_bytes: int) -> void:
	var total_bytes := _download_total_bytes
	if total_bytes > 0:
		_progress_bar.max_value = float(total_bytes)
		_progress_bar.value = clampf(float(downloaded_bytes), 0.0, float(total_bytes))
	else:
		_progress_bar.max_value = 1.0
		_progress_bar.value = 0.0
	var progress_text := "已下载 %s" % _format_bytes(downloaded_bytes)
	if total_bytes > 0:
		progress_text += " / %s" % _format_bytes(total_bytes)
	if _download_speed_bytes_per_second > 0.0:
		progress_text += "  |  %s/s" % _format_bytes(int(_download_speed_bytes_per_second))
		if total_bytes > 0 and downloaded_bytes < total_bytes:
			var remaining_seconds := int(ceil(float(total_bytes - downloaded_bytes) / _download_speed_bytes_per_second))
			progress_text += "  |  剩余 %ss" % remaining_seconds
	_progress_label.text = progress_text

func _show_error(message: String) -> void:
	_status = "idle"
	_summary_label.text = message
	_details_label.text = "如需更新，可前往发布页手动下载。"
	_progress_bar.visible = false
	_progress_label.visible = false
	_primary_button.disabled = false
	_secondary_button.disabled = false
	_secondary_button.text = "稍后提醒"
	_skip_button.visible = true
	_skip_button.disabled = false
	_set_prompt_visible(true)

func _format_bytes(value: int) -> String:
	var units := ["B", "KB", "MB", "GB"]
	var size := float(maxi(value, 0))
	var unit_index := 0
	while size >= 1024.0 and unit_index < units.size() - 1:
		size /= 1024.0
		unit_index += 1
	if unit_index == 0:
		return "%d %s" % [int(size), units[unit_index]]
	return "%.1f %s" % [size, units[unit_index]]

func _compare_versions(left: String, right: String) -> int:
	var left_parts := left.split(".", false)
	var right_parts := right.split(".", false)
	var max_count := maxi(left_parts.size(), right_parts.size())
	for i in range(max_count):
		var left_value := int(left_parts[i]) if i < left_parts.size() else 0
		var right_value := int(right_parts[i]) if i < right_parts.size() else 0
		if left_value == right_value:
			continue
		return 1 if left_value > right_value else -1
	return 0

func _sha256_for_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	while file.get_position() < file.get_length():
		context.update(file.get_buffer(1024 * 1024))
	return context.finish().hex_encode().to_lower()