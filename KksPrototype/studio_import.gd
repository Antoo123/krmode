extends Node

signal progress(message: String)
signal finished(result: Dictionary)

const DEFAULT_GAME := "D:/For my project/ScrewThisNoise_Koikatsu_Sunshine_EX_BetterRepack_R13"
const MESSAGES := {
	"checking": "Проверка PNG…",
	"preparing": "Подготовка копии CharaStudio…",
	"launching": "Запуск CharaStudio и загрузка модов…",
	"reading": "Чтение постановки и дорожек…",
	"encoding": "Подготовка моделей и анимации…",
	"saving": "Сохранение сцены…",
}

var library := "user://StudioScenes"
var deadline := 0
var job := ""
var pid := -1
var last_phase := ""
var cancelled := false


func _ready() -> void:
	set_process(false)
	# Allow an isolated scene library while testing the packaged game.
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--studio-library="):
			library = argument.trim_prefix("--studio-library=")


func _exit_tree() -> void:
	cancel()


func game_root() -> String:
	var settings := ConfigFile.new()
	if settings.load("user://library.cfg") == OK:
		var saved := String(settings.get_value("import", "game_root", ""))
		if FileAccess.file_exists(saved.path_join("CharaStudio.exe")):
			return saved
	return DEFAULT_GAME


func start(source: String, force: bool, workspace_only := false) -> bool:
	if pid >= 0:
		return false
	var tools_dir := OS.get_executable_path().get_base_dir().path_join("Tools")
	if not OS.has_feature("template"):
		tools_dir = ProjectSettings.globalize_path("res://").path_join("../Tools").simplify_path()
	var script := tools_dir.path_join("import_kks_scene_job.ps1")
	if not FileAccess.file_exists(script):
		finished.emit({"message": "Модуль импорта отсутствует в папке Tools."})
		return false
	var library_path := ProjectSettings.globalize_path(library)
	job = library_path.path_join(".jobs").path_join(Crypto.new().generate_random_bytes(16).hex_encode())
	if DirAccess.make_dir_recursive_absolute(job) != OK:
		finished.emit({"message": "Не удалось создать папку импорта."})
		return false
	var request := FileAccess.open(job.path_join("request.json"), FileAccess.WRITE)
	if not request:
		finished.emit({"message": "Не удалось записать параметры импорта."})
		return false
	request.store_string(JSON.stringify({
		"source": source, "force": force, "workspaceOnly": workspace_only, "library": library_path, "gameRoot": game_root(),
		"references": "--studio-references" in OS.get_cmdline_user_args()
	}))
	request.close()
	pid = OS.create_process("powershell.exe", [
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-JobDirectory", job
	], false)
	if pid < 0:
		finished.emit({"message": "Не удалось запустить конвертер сцен."})
		return false
	cancelled = false
	last_phase = ""
	deadline = 0
	progress.emit(MESSAGES.checking)
	set_process(true)
	return true


func cancel() -> void:
	if pid < 0 or cancelled:
		return
	var marker := FileAccess.open(job.path_join("cancel"), FileAccess.WRITE)
	if marker:
		marker.close()
		cancelled = true
		progress.emit("Отмена импорта…")


func _process(_delta: float) -> void:
	var tick := Time.get_ticks_msec()
	if tick < deadline:
		return
	deadline = tick + 300
	if OS.is_process_running(pid):
		if not cancelled:
			var phase := FileAccess.get_file_as_string(job.path_join("phase.txt"))
			if not phase.is_empty() and phase != last_phase:
				last_phase = phase
				var parts := phase.split(":")
				if parts.size() == 3 and parts[0] == "capturing":
					progress.emit("Захват кадра %d из %d…" % [int(parts[1]) + 1, int(parts[2])])
				else:
					progress.emit(MESSAGES.get(phase, "Импорт сцены…"))
		return
	var exit_code := OS.get_process_exit_code(pid)
	pid = -1
	set_process(false)
	var result: Variant = JSON.parse_string(FileAccess.get_file_as_string(job.path_join("result.json")).trim_prefix("\ufeff"))
	if not result is Dictionary:
		result = {"message": "Конвертер завершился без результата. Код %d." % exit_code}
	if result.has("manifest"):
		var absolute := String(result.manifest).replace("\\", "/")
		var base := ProjectSettings.globalize_path(library).replace("\\", "/").trim_suffix("/")
		if absolute.to_lower().begins_with(base.to_lower() + "/"):
			result.manifest = library.path_join(absolute.substr(base.length() + 1))
	finished.emit(result)
